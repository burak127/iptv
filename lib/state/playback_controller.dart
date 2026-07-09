import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/iptv_source.dart';
import '../models/live_channel.dart';
import '../services/http_client.dart';
import '../services/stream_url_builder.dart';
import '../services/tv_mode.dart';

enum PlaybackMode { live, onDemand }

/// Owns the media_kit player lifecycle so the player screen stays a thin view.
/// Handles single-connection discipline (debounced zap + stop-before-open),
/// auto-reconnect for live, resume persistence for on-demand, sleep timer and
/// aspect-fit cycling.
class PlaybackController extends ChangeNotifier {
  PlaybackController() {
    _subs.add(_player.stream.buffering.listen((b) {
      buffering = b;
      notifyListeners();
    }));
    _subs.add(_player.stream.error.listen(_onError));
    _subs.add(_player.stream.completed.listen((c) {
      if (c) _onCompleted();
    }));
    _subs.add(_player.stream.position.listen((p) {
      position = p;
      // A live stream that is actually advancing is healthy — reset the budget.
      if (mode == PlaybackMode.live && p > Duration.zero) reconnectAttempt = 0;
      // stop() resets the position stream to 0 — don't let that transient
      // overwrite resume. The resume offset itself is now applied via mpv's
      // own `start` file option (see _play()), so the first genuine tick
      // already reflects it — no separate "seek still pending" state needed.
      if (_suppressResume) {
        if (p > Duration.zero) _suppressResume = false;
      } else {
        _maybeSaveResume();
      }
      // This stream ticks multiple times per second (mpv's raw time-pos) —
      // notifying on every one rebuilds the whole player overlay that often,
      // competing with decode for CPU on weak boxes. A progress bar/clock only
      // needs whole-second granularity; skip redundant notifies in between.
      final sec = p.inSeconds;
      if (sec != _lastNotifiedSecond) {
        _lastNotifiedSecond = sec;
        notifyListeners();
      }
    }));
    _subs.add(_player.stream.duration.listen((d) {
      duration = d;
      notifyListeners();
    }));
    // mpv's own aspect-corrected video size — reported directly by the
    // decoder, so unlike media_kit_video's Windows texture-rect plumbing
    // (which has a known bug reporting an all-zero/stale rect there, making
    // the widget's own BoxFit have no visible effect), this is reliable on
    // every platform. Used to implement the aspect-ratio cycle ourselves on
    // desktop instead of trusting the widget's built-in fit there.
    _subs.add(_player.stream.videoParams.listen((p) {
      final w = p.dw ?? p.w;
      final h = p.dh ?? p.h;
      videoAspect = (w != null && h != null && h > 0) ? w / h : null;
      notifyListeners();
    }));
    // Keep the screen awake only while actually playing. Tying the wakelock to
    // the playing state means a paused stream, the sleep timer firing, or the
    // terminal error state all release it — the screen no longer stays lit all
    // night on a frozen frame. (playing stays true through buffering, so this
    // never lets the screen sleep mid-rebuffer.)
    _subs.add(_player.stream.playing.listen((p) {
      if (!_disposed) WakelockPlus.toggle(enable: p);
    }));
    // Buffer more of the stream so bursty IPTV-over-WiFi (a Chromecast has a
    // weaker antenna than a phone/tablet) rides out network jitter instead of
    // micro-stuttering. A few seconds of read-ahead is the standard live-TV
    // trade — slightly slower first frame, far smoother playback.
    _setMpvProperty('cache', 'yes');
    _setMpvProperty('demuxer-readahead-secs', '8');
    _setMpvProperty('demuxer-max-bytes', '64MiB');
    _setMpvProperty('demuxer-max-back-bytes', '32MiB');
    // Restore the persisted subtitle font size (mpv default is 55).
    SharedPreferences.getInstance().then((p) {
      final size = p.getDouble('sub_font_size');
      if (size != null && !_disposed) {
        subFontSize = size;
        _setMpvProperty('sub-font-size', '${size.round()}');
      }
    });
  }

  final Player _player = Player();
  // "Smooth hardware video" (opt-in, TV only): render the hardware decoder
  // DIRECTLY onto the surface (mpv `vo=mediacodec_embed`) instead of copying
  // every decoded frame CPU->GPU. That copy (default `mediacodec-copy`, output
  // "video/raw") saturates weak Amlogic GPUs and stutters silently. Direct mode
  // is far smoother — but on SOME boxes it shows a black screen (audio only) and
  // it disables mpv subtitle overlay, so it's OFF by default and toggled per
  // device in Settings ([directHwVideo]). Default = the safe copy path.
  late final VideoController videoController = VideoController(
    _player,
    configuration: (isTvMode && directHwVideo)
        ? const VideoControllerConfiguration(
            vo: 'mediacodec_embed',
            hwdec: 'mediacodec',
            // Some Amlogic boxes (e.g. Strong HY4600) show a black screen with
            // embed unless the surface is attached AFTER the video params are
            // known — the same timing the gpu vo uses.
            androidAttachSurfaceAfterVideoParameters: true,
          )
        : const VideoControllerConfiguration(),
  );
  Player get player => _player;

  final List<StreamSubscription> _subs = [];

  PlaybackMode mode = PlaybackMode.live;
  IptvSource? _source;
  String _userAgent = kDefaultUserAgent;
  String? _lastUrl;

  // Live playlist
  List<LiveChannel> _live = const [];
  int _index = 0;
  int get index => _index;
  List<LiveChannel> get playlist => _live;
  LiveChannel? get currentChannel =>
      (_index >= 0 && _index < _live.length) ? _live[_index] : null;

  // On-demand
  String? _resumeKey;
  int _resumeDurationHint = 0;
  void Function(String key, int pos, int dur)? _onSaveResume;

  /// Fired when on-demand content plays to the end (drives auto-next-episode).
  VoidCallback? onDemandCompleted;

  // UI state
  bool buffering = false;
  bool hasError = false;
  String? errorMessage;
  int reconnectAttempt = 0;
  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  BoxFit fit = BoxFit.contain;
  /// width/height of the current video, mpv-reported (see constructor). Null
  /// until the first frame's params arrive, or for audio-only content.
  double? videoAspect;
  Duration? sleepRemaining;

  Timer? _zapDebounce;
  Timer? _reconnectTimer;
  Timer? _sleepTimer;
  int _lastSavedSecond = -10;
  int _lastNotifiedSecond = -1; // throttles position-tick notifyListeners()
  Duration? _pendingStartAt; // requested resume offset for the current open()
  int _playingIndex = -1; // last index actually opened (not just selected)
  bool _suppressResume = false; // no resume-saves during stop/open/seek
  bool _inBackground = false;
  bool _wasPlaying = true; // playing state captured when backgrounded
  bool _disposed = false;
  // Optimistic play/pause intent for the external on-demand path — ExoPlayer
  // has no toggle command and STATE_READY doesn't distinguish paused vs
  // playing, so this is tracked here instead of asked of the native player.
  bool _externalPlaying = true;

  bool get isPlaying =>
      _routeToExternal ? _externalPlaying : _player.state.playing;

  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  // When true, live video plays through a native ExoPlayer + SurfaceView (the
  // player screen owns it); media_kit is NOT used for live in this mode. Only
  // the index/zap/state bookkeeping below runs.
  bool _externalVideo = false;
  bool get externalVideo => _externalVideo;

  /// URL of the channel that should actually be on screen (follows the settled
  /// [_playingIndex], not the mid-zap selection) — drives the native player.
  String? get currentLiveUrl {
    if (_source == null || _playingIndex < 0 || _playingIndex >= _live.length) {
      return null;
    }
    return StreamUrlBuilder.live(_source!, _live[_playingIndex]);
  }

  /// URL of the on-demand item currently open — drives the native player, the
  /// on-demand equivalent of [currentLiveUrl].
  String? get currentOnDemandUrl =>
      mode == PlaybackMode.onDemand ? _lastUrl : null;

  /// The resume offset requested for the item currently open — the native
  /// player reads this once (on initial [NativeVideo] creation) instead of
  /// racing a separate seek call, mirroring the `Media.start` fix on the
  /// mpv/media_kit path.
  Duration? get pendingStartAt => _pendingStartAt;

  /// Set by the player screen when it opens the native ExoPlayer path for
  /// ON-DEMAND content — routes [seek]/[seekBy]/[playPause] to the ExoPlayer
  /// instance instead of mpv while set. Live already bypasses mpv entirely via
  /// [_externalVideo] + [currentLiveUrl]; on-demand still needs real command
  /// routing since (unlike live zapping) the user actively seeks/pauses.
  /// Cleared by the player screen on dispose/teardown. The bool tells the
  /// handler the NEW intended state (already flipped in [playPause]) so it
  /// just calls play()/pause() without tracking its own copy of the flag.
  void Function(Duration to)? externalSeekHandler;
  void Function(bool playing)? externalPlayPauseHandler;

  /// Reflect the native player's state in the shared player UI.
  void setExternalBuffering(bool v) {
    if (buffering != v) {
      buffering = v;
      notifyListeners();
    }
  }

  void setExternalError(bool v, [String? msg]) {
    if (hasError != v || errorMessage != msg) {
      hasError = v;
      errorMessage = msg;
      notifyListeners();
    }
  }

  /// Drive the wakelock for the native ExoPlayer path. mpv's own
  /// `_player.stream.playing` never fires while [_externalVideo] is true (the
  /// media_kit player is never started), so without this the wakelock listener
  /// above would disable it moments after `openLive()`'s one-shot enable —
  /// letting the screen/box sleep mid-broadcast even while ExoPlayer plays fine.
  void setExternalPlaying(bool playing) {
    if (_externalVideo && !_disposed) WakelockPlus.toggle(enable: playing);
  }

  /// Reflect the native player's position/duration in the shared player UI —
  /// the on-demand equivalent of the internal mpv position-stream listener
  /// below, for when [_externalVideo] is true in on-demand mode.
  void setExternalPosition(Duration pos, Duration dur) {
    position = pos;
    if (dur > Duration.zero) duration = dur;
    // Same "don't save a transient/pre-start 0" guard as the mpv path.
    if (_suppressResume) {
      if (pos > Duration.zero) _suppressResume = false;
    } else {
      _maybeSaveResume();
    }
    final sec = pos.inSeconds;
    if (sec != _lastNotifiedSecond) {
      _lastNotifiedSecond = sec;
      notifyListeners();
    }
  }

  /// The native player reported STATE_ENDED for on-demand content — the
  /// on-demand equivalent of mpv's `stream.completed` listener below.
  void setExternalEnded() {
    if (mode != PlaybackMode.onDemand) return;
    _onCompleted();
  }

  /// The player screen parsed+loaded an external subtitle for the native
  /// on-demand path (rendered as a Flutter overlay there — see
  /// subtitle_parser.dart — since mpv/libass isn't in the loop). Mirrors what
  /// [loadExternalSubtitle] does for the mpv path, without touching mpv.
  void setExternalSubtitleTitle(String? title) {
    externalSubtitleTitle = title;
    notifyListeners();
  }

  // ---------------- open ----------------
  void openLive({
    required List<LiveChannel> playlist,
    required int index,
    required IptvSource source,
    bool externalVideo = false,
  }) {
    mode = PlaybackMode.live;
    _externalVideo = externalVideo;
    _source = source;
    _userAgent = source.userAgent ?? kDefaultUserAgent;
    _live = playlist;
    _resumeKey = null;
    _pendingStartAt = null;
    _lastSavedSecond = -10; // stale resume from a previous item must not leak
    _lastNotifiedSecond = -1;
    reconnectAttempt = 0;
    WakelockPlus.enable();
    _openIndex(index);
  }

  void openOnDemand({
    required String url,
    required IptvSource source,
    String? resumeKey,
    Duration? startAt,
    int durationHintSecs = 0,
    void Function(String key, int pos, int dur)? saveResume,
    bool externalVideo = false,
  }) {
    mode = PlaybackMode.onDemand;
    _externalVideo = externalVideo;
    _source = source;
    _userAgent = source.userAgent ?? kDefaultUserAgent;
    _resumeKey = resumeKey;
    _resumeDurationHint = durationHintSecs;
    _onSaveResume = saveResume;
    // Reset per-item resume state so an error-before-first-tick retry falls back
    // to THIS item's requested offset — never the previous episode's position.
    _pendingStartAt = startAt;
    _lastSavedSecond = -10;
    _lastNotifiedSecond = -1;
    WakelockPlus.enable();
    if (externalVideo) {
      // Native ExoPlayer path: notifying updates currentOnDemandUrl, which the
      // player screen feeds to the SurfaceView player. media_kit stays idle.
      _lastUrl = url;
      _externalPlaying = true; // fresh item always starts playing
      externalSubtitleTitle = null; // belongs to the previous item, not this one
      hasError = false;
      errorMessage = null;
      _suppressResume = true;
      notifyListeners();
      return;
    }
    _play(url, startAt: startAt);
  }

  void _openIndex(int i) {
    if (_live.isEmpty || _source == null) return;
    _index = i.clamp(0, _live.length - 1);
    _playingIndex = _index;
    if (_externalVideo) {
      // Native ExoPlayer path: notifying updates currentLiveUrl, which the
      // player screen feeds to the SurfaceView player. media_kit stays idle.
      hasError = false;
      errorMessage = null;
      notifyListeners();
      return;
    }
    _play(StreamUrlBuilder.live(_source!, _live[_index]));
  }

  Future<void> _play(String url, {Duration? startAt}) async {
    if (_disposed || _inBackground) return;
    _lastUrl = url;
    _reconnectTimer?.cancel();
    _suppressResume = true;
    hasError = false;
    errorMessage = null;
    videoAspect = null; // stale shape from the previous item must not leak
    // New content: timing offset and external subtitle belong to the old one.
    if (subDelaySecs != 0) {
      subDelaySecs = 0;
      unawaited(_setMpvProperty('sub-delay', '0'));
    }
    externalSubtitleTitle = null;
    notifyListeners();
    await _player.stop(); // free the single connection before opening the next
    if (_disposed) return;
    // Pass the resume offset as mpv's own `start` file option instead of
    // open()-then-seek(). The old approach raced a manual _player.seek() call
    // against mpv's own internal jump to the file's start position — on
    // slower TV hardware, `stream.duration` sometimes emitted an early/stale
    // value (still carrying over from the PREVIOUS file) before the new file
    // had actually begun loading. That fired our seek immediately, mpv then
    // finished loading the new file afterwards and reset to position 0,
    // silently overwriting our earlier seek: the UI briefly jumped to the
    // resume point and then restarted from the beginning once truly loaded.
    // `start` is applied atomically as part of the file-open sequence itself
    // (the same mechanism mpv/media_kit expose for exactly this use case), so
    // there's no separate command to race against.
    await _player.open(
      Media(
        url,
        httpHeaders: {'User-Agent': _userAgent},
        start: (startAt != null && startAt > Duration.zero) ? startAt : null,
      ),
    );
    if (_disposed) {
      // The screen was closed while open() was in flight — the stream just
      // started on a dead controller. Kill it so audio can't keep playing.
      unawaited(_teardownPlayer());
      return;
    }
    if (_inBackground) {
      // The app was backgrounded while open() was in flight — open(play:true)
      // would un-pause it, so silence it again.
      await _player.pause();
      return;
    }
  }

  /// Pause when the app goes to the background; resume live on return.
  void onAppBackground() {
    if (_disposed || _inBackground) return;
    _wasPlaying = _player.state.playing; // don't auto-resume a user-paused movie
    _inBackground = true;
    // Pending timers must not fire while backgrounded — a reconnect/zap that
    // lands after home is pressed would restart audio in the background.
    _reconnectTimer?.cancel();
    _zapDebounce?.cancel();
    _player.pause();
  }

  void onAppForeground() {
    if (_disposed) return;
    // Only act if we actually backgrounded. Expanding a PiP window back to
    // fullscreen fires `resumed` without a preceding background, and reopening
    // here would needlessly tear down and rebuffer a perfectly healthy stream.
    if (!_inBackground) return;
    _inBackground = false;
    // A paused live stream is stale by the time we return — reopen it.
    if (mode == PlaybackMode.live) {
      _openIndex(_index);
    } else if (_wasPlaying) {
      _player.play();
    }
  }

  // ---------------- live zap (debounced) ----------------
  void next() => _zapTo(_index + 1);
  void prev() => _zapTo(_index - 1);

  void _zapTo(int i) {
    if (_live.isEmpty) return;
    final target = i.clamp(0, _live.length - 1);
    // Bumping the edge of the list must not tear down a working stream.
    if (target == _index && target == _playingIndex && !hasError) return;
    _index = target;
    notifyListeners();
    _zapDebounce?.cancel();
    _zapDebounce = Timer(const Duration(milliseconds: 350), () {
      if (_index != _playingIndex || hasError) _openIndex(_index);
    });
  }

  /// Zap directly to a playlist index (surf drawer taps a concrete row —
  /// channel numbers are NOT unique in real playlists).
  void zapToIndex(int i) => _zapTo(i);

  void zapToNumber(int number) {
    final idx = _live.indexWhere((c) => c.number == number);
    if (idx >= 0) {
      _zapTo(idx);
    } else if (number >= 1 && number <= _live.length) {
      _zapTo(number - 1);
    }
  }

  // ---------------- on-demand controls ----------------
  bool get _routeToExternal => _externalVideo && mode == PlaybackMode.onDemand;

  void playPause() {
    if (_routeToExternal) {
      _externalPlaying = !_externalPlaying;
      notifyListeners();
      externalPlayPauseHandler?.call(_externalPlaying);
    } else {
      _player.playOrPause();
    }
  }

  void seek(Duration to) {
    if (_routeToExternal) {
      externalSeekHandler?.call(to);
    } else {
      _player.seek(to);
    }
  }

  void seekBy(Duration delta) {
    final t = position + delta;
    final clamped = t < Duration.zero ? Duration.zero : t;
    if (_routeToExternal) {
      externalSeekHandler?.call(clamped);
    } else {
      _player.seek(clamped);
    }
  }

  // ---------------- error / reconnect ----------------
  void _onError(String err) {
    if (mode == PlaybackMode.onDemand) {
      hasError = true;
      errorMessage = err;
      notifyListeners();
    } else {
      _scheduleReconnect();
    }
  }

  void _onCompleted() {
    if (mode == PlaybackMode.live) {
      _scheduleReconnect(); // a live stream shouldn't end — treat as a drop
    } else {
      _saveResumeFinal(finished: true);
      onDemandCompleted?.call();
    }
  }

  void _scheduleReconnect() {
    if (reconnectAttempt >= 5) {
      hasError = true;
      errorMessage = 'Kunne ikke afspille streamen. Prøv en anden kanal.';
      notifyListeners();
      return;
    }
    reconnectAttempt++;
    notifyListeners();
    final delay = Duration(seconds: (1 << (reconnectAttempt - 1)).clamp(1, 8));
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () => _openIndex(_index));
  }

  void retry() {
    reconnectAttempt = 0;
    hasError = false;
    errorMessage = null;
    notifyListeners();
    if (mode == PlaybackMode.live) {
      _openIndex(_index);
    } else if (_routeToExternal) {
      // Native path: touching mpv here would do nothing useful anyway (it's
      // idle). The player screen owns re-issuing setSource on the actual
      // ExoPlayer instance — see its own retry wrapper.
    } else if (_lastUrl != null) {
      // Resume where the error struck — never restart the movie from 0:00.
      // If the error hit before the first position tick, fall back to this
      // item's own resume point (_lastSavedSecond, reset per open) or the
      // originally-requested start offset — not a stale previous-episode value.
      final at = position > Duration.zero
          ? position
          : (_lastSavedSecond > 0
              ? Duration(seconds: _lastSavedSecond)
              : _pendingStartAt);
      _play(_lastUrl!, startAt: at);
    }
  }

  // ---------------- resume persistence ----------------
  void _maybeSaveResume() {
    if (mode != PlaybackMode.onDemand || _resumeKey == null) return;
    final sec = position.inSeconds;
    if ((sec - _lastSavedSecond).abs() >= 5) {
      _lastSavedSecond = sec;
      _onSaveResume?.call(_resumeKey!, sec, _durationSecs);
    }
  }

  void _saveResumeFinal({bool finished = false}) {
    if (mode != PlaybackMode.onDemand || _resumeKey == null) return;
    // Playback never actually started (still opening/seeking) — keep the
    // stored position instead of overwriting it with a transient 0.
    if (_suppressResume && !finished) return;
    try {
      _onSaveResume?.call(
        _resumeKey!,
        finished ? _durationSecs : position.inSeconds,
        _durationSecs,
      );
    } catch (_) {
      // A throwing callback must never abort dispose/teardown.
    }
  }

  int get _durationSecs =>
      duration.inSeconds > 0 ? duration.inSeconds : _resumeDurationHint;

  // ---------------- subtitles (external / style / timing) ----------------
  double subFontSize = 55; // mpv default
  double subDelaySecs = 0;
  String? externalSubtitleTitle; // name of the loaded external subtitle

  Future<void> _setMpvProperty(String name, String value) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty(name, value);
      } catch (_) {/* property not available on this backend */}
    }
  }

  /// Load a downloaded SRT/VTT as the active subtitle track.
  Future<void> loadExternalSubtitle(String content, {String? title}) async {
    if (_disposed) return;
    externalSubtitleTitle = title;
    await _player.setSubtitleTrack(
      SubtitleTrack.data(content, title: title ?? 'Ekstern', language: null),
    );
    notifyListeners();
  }

  Future<void> setSubtitleFontSize(double size) async {
    subFontSize = size.clamp(30, 110);
    await _setMpvProperty('sub-font-size', '${subFontSize.round()}');
    notifyListeners();
    final p = await SharedPreferences.getInstance();
    await p.setDouble('sub_font_size', subFontSize);
  }

  /// Shift subtitle timing; positive = subtitles later, negative = earlier.
  Future<void> nudgeSubtitleDelay(double deltaSecs) async {
    subDelaySecs = double.parse((subDelaySecs + deltaSecs).toStringAsFixed(2));
    await _setMpvProperty('sub-delay', '$subDelaySecs');
    notifyListeners();
  }

  Future<void> resetSubtitleDelay() async {
    subDelaySecs = 0;
    await _setMpvProperty('sub-delay', '0');
    notifyListeners();
  }

  // ---------------- fit / sleep timer ----------------
  void cycleFit() {
    const order = [BoxFit.contain, BoxFit.cover, BoxFit.fill];
    fit = order[(order.indexOf(fit) + 1) % order.length];
    notifyListeners();
  }

  void setSleepTimer(Duration? d) {
    _sleepTimer?.cancel();
    sleepRemaining = d;
    notifyListeners();
    if (d == null) return;
    final end = DateTime.now().add(d);
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final rem = end.difference(DateTime.now());
      if (rem <= Duration.zero) {
        t.cancel();
        sleepRemaining = null;
        _player.pause();
      } else {
        sleepRemaining = rem;
      }
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _saveResumeFinal();
    _zapDebounce?.cancel();
    _reconnectTimer?.cancel();
    _sleepTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    WakelockPlus.disable();
    _teardownPlayer();
    super.dispose();
  }

  /// Silence immediately, then stop and dispose — each step guarded, so a
  /// command that throws can't leave the native player playing in the
  /// background (the audio-keeps-playing-after-exit bug).
  Future<void> _teardownPlayer() async {
    try {
      await _player.pause();
    } catch (_) {}
    try {
      await _player.stop();
    } catch (_) {}
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
