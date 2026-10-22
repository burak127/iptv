import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';

import '../../models/epg.dart';
import '../../models/iptv_source.dart';
import '../../models/live_channel.dart';
import '../../models/media_item.dart' show MediaKind;
import '../../models/movie.dart';
import '../../models/series.dart';
import '../../services/download_manager.dart';
import '../../services/archive_window.dart';
import '../../services/http_client.dart';
import '../../services/pip_service.dart';
import '../../services/progress_repository.dart' show SubtitleChoice;
import '../../services/stream_url_builder.dart';
import '../../services/subtitle_parser.dart';
import '../../services/subtitle_search.dart';
import '../../services/tv_mode.dart';
import '../../services/window_service.dart';
import '../../state/app_state.dart';
import '../../state/playback_controller.dart';
import '../widgets/focus_ring.dart';
import '../widgets/native_video.dart';

/// Fixed surf-drawer row height so scroll-to-current is exact.
const double _kSurfRowHeight = 48;

/// How far the [nth] skip of one burst jumps (see [_PlayerScreenState._skip]).
///
/// A burst is a run of double-taps on the same side of the screen — or a held
/// D-pad arrow — with less than ~0.9s between them. The first steps are the
/// familiar 10s so an ordinary double-tap behaves exactly like Netflix's;
/// sustained spamming grows the step, so reaching several minutes ahead takes
/// a handful of taps instead of thirty. Cumulative totals: 10, 20, 30, 40, 60,
/// 80, 100, 130, 160, 190…
///
/// Top-level (not a private method) purely so it can be unit-tested.
Duration skipStepFor(int nth) {
  if (nth <= 4) return const Duration(seconds: 10);
  if (nth <= 7) return const Duration(seconds: 20);
  return const Duration(seconds: 30);
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen.live({
    super.key,
    required this.source,
    required this.playlist,
    required this.initialIndex,
  })  : mode = PlaybackMode.live,
        url = null,
        title = null,
        resumeKey = null,
        startAt = null,
        durationHint = 0,
        searchTitle = null,
        season = null,
        episode = null,
        episodes = null,
        episodeIndex = null,
        movies = null,
        movieIndex = null,
        favoriteKind = null,
        favoriteId = null,
        archivePlaylist = null,
        archiveIndex = null,
        archiveWindowStartUtc = null;

  const PlayerScreen.onDemand({
    super.key,
    required this.source,
    required this.url,
    required this.title,
    this.resumeKey,
    this.startAt,
    this.durationHint = 0,
    this.searchTitle,
    this.season,
    this.episode,
    this.episodes,
    this.episodeIndex,
    this.movies,
    this.movieIndex,
    this.favoriteKind,
    this.favoriteId,
    this.archivePlaylist,
    this.archiveIndex,
    this.archiveWindowStartUtc,
  })  : mode = PlaybackMode.onDemand,
        playlist = const [],
        initialIndex = 0;

  final PlaybackMode mode;
  final IptvSource source;
  final List<LiveChannel> playlist;
  final int initialIndex;
  final String? url;
  final String? title;
  final String? resumeKey;
  final Duration? startAt;
  final int durationHint;

  /// Metadata for external subtitle search (movie name / series name + S/E).
  final String? searchTitle;
  final int? season;
  final int? episode;

  /// Flat episode list + current index (enables auto-next-episode).
  final List<Episode>? episodes;
  final int? episodeIndex;

  /// Sibling movie list (the category/browse list the movie was opened from)
  /// + current index — enables "switch movie like a channel" (prev/next
  /// buttons + swipe). Null when opened from a context with no stable list
  /// (e.g. search results).
  final List<Movie>? movies;
  final int? movieIndex;

  /// What the in-player favorite star toggles for on-demand content — the
  /// movie ([MediaKind.vod]) or the series ([MediaKind.series]) being watched.
  /// Null when the opener doesn't know a stable id (e.g. a local download),
  /// in which case the star simply doesn't show. Live uses the current
  /// channel instead (see [_favId]).
  final MediaKind? favoriteKind;
  final String? favoriteId;

  /// Set only for a 12-hour catch-up window opened from live TV.
  final List<LiveChannel>? archivePlaylist;
  final int? archiveIndex;
  final DateTime? archiveWindowStartUtc;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  final PlaybackController _pc = PlaybackController();
  final FocusNode _focus = FocusNode(debugLabel: 'player-root');
  // Targets so the D-pad can actually reach overlay actions on TV (autofocus is
  // discarded while the fullscreen root node holds focus — we move focus in
  // explicitly instead).
  final FocusNode _retryFocus = FocusNode(debugLabel: 'player-retry');
  final FocusNode _playNowFocus = FocusNode(debugLabel: 'player-play-now');
  // Landing spot when OK opens the controls bar: the Spor (subtitles) button
  // on live, the play/pause circle button on-demand.
  final FocusNode _controlsFocus = FocusNode(debugLabel: 'player-controls');
  // Dedicated nodes for every top-bar button, so on-demand can explicitly jump
  // Up/Down between the icon row and the seek/playback row below it — Flutter's
  // automatic directional traversal is unreliable across rows this different in
  // shape (a slim icon row vs. a full-width Slider vs. big circle buttons), so
  // relying on it left the top row effectively unreachable while watching a
  // movie/series.
  final FocusNode _backFocus = FocusNode(debugLabel: 'player-back');
  final FocusNode _pipFocus = FocusNode(debugLabel: 'player-pip');
  final FocusNode _aspectFocus = FocusNode(debugLabel: 'player-aspect');
  final FocusNode _tracksFocus = FocusNode(debugLabel: 'player-tracks');
  final FocusNode _sleepFocus = FocusNode(debugLabel: 'player-sleep');
  final FocusNode _favFocus = FocusNode(debugLabel: 'player-fav');
  Set<FocusNode> get _topRowFocusNodes => {
        _backFocus,
        if (_canFavorite) _favFocus,
        if (_pipSupported) _pipFocus,
        _aspectFocus,
        _tracksFocus,
        _sleepFocus,
      };

  /// Kind/id the in-player favorite star acts on. Live = the current channel;
  /// on-demand = the movie/series passed in (and, while browsing sibling
  /// movies, the movie currently on screen — so favoriting after a swipe hits
  /// the right film).
  MediaKind? get _favKind => _isLive ? MediaKind.live : widget.favoriteKind;
  String? get _favId {
    if (_isLive) return _pc.currentChannel?.id;
    final list = widget.movies;
    final i = _movieIdx;
    if (list != null && i != null && i >= 0 && i < list.length) {
      return list[i].id;
    }
    return widget.favoriteId;
  }

  bool get _canFavorite => _favKind != null && _favId != null;

  /// Star button in the player top bar — favorite the thing you're watching
  /// (channel / movie / series) without leaving playback. Reflects + toggles
  /// the same favorites the grids use. Hidden when there's no stable id.
  Widget _favoriteButton() {
    final kind = _favKind;
    final id = _favId;
    if (kind == null || id == null) return const SizedBox.shrink();
    return Consumer<AppState>(
      builder: (context, appState, _) {
        final fav = appState.isFavorite(kind, id);
        return FocusRing(
          shape: BoxShape.circle,
          child: IconButton(
            focusNode: _favFocus,
            tooltip: fav ? 'Fjern favorit' : 'Tilføj favorit',
            onPressed: () {
              appState.toggleFavorite(kind, id);
              _snack(fav ? 'Fjernet fra favoritter' : 'Tilføjet til favoritter');
            },
            icon: Icon(fav ? Icons.star : Icons.star_border,
                color: fav ? Colors.amber : Colors.white),
          ),
        );
      },
    );
  }
  // Live's bottom row (prev/next/channel-list) has the exact same "far apart,
  // differently-shaped rows" geometry as on-demand's slider+circle-buttons —
  // give it the same explicit-jump treatment instead of default traversal.
  final FocusNode _livePrevFocus = FocusNode(debugLabel: 'player-live-prev');
  final FocusNode _liveNextFocus = FocusNode(debugLabel: 'player-live-next');
  final FocusNode _liveSurfFocus = FocusNode(debugLabel: 'player-live-surf');
  final FocusNode _liveArchiveFocus = FocusNode(debugLabel: 'player-live-archive');
  Set<FocusNode> get _liveBottomFocusNodes =>
      {_livePrevFocus, _liveNextFocus, _liveSurfFocus, _liveArchiveFocus};
  final FocusScopeNode _surfScope = FocusScopeNode(debugLabel: 'player-surf');

  bool _showControls = true;
  bool _showSurf = false;
  ScrollController? _surfScroll;
  Timer? _hideTimer;
  // TV "navigate mode" idle-hide — separate from _hideTimer (which never ran
  // while navigating at all) so the controls bar auto-hides after a period of
  // no interaction instead of staying up forever once opened with OK.
  Timer? _navIdleTimer;

  String _numberBuffer = '';
  Timer? _numberTimer;

  final Map<String, List<EpgEntry>> _epg = {};
  // EPG throttling: only fetch when the channel actually changes, and back off
  // for 60s after a failure — otherwise a panel that 404s get_short_epg gets
  // hammered on every sub-second position tick for the whole session.
  final Map<String, DateTime> _epgFailedAt = {};
  int _lastEpgIndex = -1;
  bool _hadError = false;

  // Mutable playback metadata — updated when auto-next advances the episode,
  // or when the user switches to an adjacent movie (see _playAdjacentMovie).
  late String? _title = widget.title;
  late String? _searchTitle = widget.searchTitle;
  late int? _season = widget.season;
  late int? _episodeNum = widget.episode;
  late int? _epIndex = widget.episodeIndex;
  late int? _movieIdx = widget.movieIndex;
  late String? _resumeKey = widget.resumeKey;
  late AppState _appState;
  late DownloadManager _downloads;

  int? _nextCountdown;
  Timer? _nextTimer;
  bool _pipSupported = false;

  // On-demand scrub: buffer key-repeat seek deltas (D-pad hold), double-tap
  // skips and slider drag updates, and only issue ONE real seek after things
  // settle. Each mpv seek is a synchronous, FIFO-serialized native call —
  // dispatching one per drag-pixel/tap/key-repeat tick queued dozens of seeks
  // back-to-back and froze playback for a second or more afterwards.
  Duration? _dragPosition;

  // ---------------- skip (double-tap / D-pad, escalating) ----------------
  // Netflix-style: double-tap the right or left side of the screen to jump
  // 10s, and keep tapping to jump further — every extra tap in the same burst
  // adds to the SAME pending jump, so spamming lands one big seek instead of
  // a dozen small ones. The same burst logic backs the D-pad arrows on TV, so
  // holding ▶ fast-forwards instead of crawling 10s per repeat.

  /// Where the pending jump is heading — also what the seek bar previews
  /// while the burst is still open (the player is still sitting at the old
  /// position until the debounce fires).
  Duration? _skipTarget;
  /// -1 = backwards, +1 = forwards, 0 = no burst in progress.
  int _skipDirection = 0;
  /// Skips accumulated in the current burst (drives the escalating step).
  int _skipCount = 0;
  /// Total of the current burst — the number shown in the on-screen badge.
  Duration _skipAccum = Duration.zero;
  Timer? _skipCommitTimer; // fires the one real seek once the burst settles
  Timer? _skipBadgeTimer; // clears the badge (and ends the burst) after it
  Timer? _skipPreviewTimer; // safety net: drop the preview if the seek never lands

  /// True while seeking makes any sense at all — live has no timeline, and an
  /// error/auto-next overlay owns the screen instead.
  bool get _canSkip =>
      !_isLive && !_pc.hasError && _nextCountdown == null;

  /// Add one skip to the current burst. [direction] is +1 (forward) or -1
  /// (back). [step] overrides the escalating ladder (dedicated ⏩/⏪ media
  /// keys use their own bigger fixed step).
  void _skip(int direction, {Duration? step}) {
    if (!_canSkip) return;
    // Reversing mid-burst restarts the count, so the badge reads "10 sek"
    // again rather than continuing the old direction's total.
    if (direction != _skipDirection) {
      _skipDirection = direction;
      _skipCount = 0;
      _skipAccum = Duration.zero;
    }
    _skipCount++;
    final delta = step ?? skipStepFor(_skipCount);
    _skipAccum += delta;
    // Chain off the pending target, not the (still stale) player position —
    // otherwise every tap of a burst would recompute the same +10s.
    final base = _skipTarget ?? _pc.position;
    _skipTarget = _pc.clampSeek(base + delta * direction);
    _revealControls(); // also setState()s, so the badge + seek bar redraw

    // A fresh input supersedes the previous commit's safety timer — left
    // running, it could null _skipTarget out from under this new burst.
    _skipPreviewTimer?.cancel();
    _skipPreviewTimer = null;
    _skipCommitTimer?.cancel();
    _skipCommitTimer = Timer(const Duration(milliseconds: 320), () {
      _skipCommitTimer = null;
      final t = _skipTarget;
      if (t != null) _pc.seek(t);
      // Keep previewing the target until the player actually reports landing
      // there (see _onControllerTick) — clearing it the instant the seek is
      // issued made the bar snap back to the old spot for a frame or two.
      _armSkipPreviewSafety();
    });
    _skipBadgeTimer?.cancel();
    _skipBadgeTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() {
        _skipDirection = 0;
        _skipCount = 0;
        _skipAccum = Duration.zero;
      });
    });
  }

  /// Safety net for a previewed seek target: if the player never reports
  /// landing near it (see _onControllerTick), stop previewing after 5s.
  void _armSkipPreviewSafety() {
    _skipPreviewTimer?.cancel();
    _skipPreviewTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _skipTarget = null);
    });
  }

  /// Position the seek bar/clock should show: a live slider drag wins, then a
  /// pending skip target, then the player's own position.
  Duration get _displayPosition => _dragPosition ?? _skipTarget ?? _pc.position;

  // Fraction of the width at each edge that acts as a double-tap skip zone.
  // The middle band stays a plain "show/hide the controls" tap.
  static const double _kSkipZoneFraction = 0.35;

  /// Side zone whose double-tap window is currently open (see [_onTapUpAt]).
  int _armedTapZone = 0;
  Timer? _tapArmTimer;

  /// Single entry point for every tap on the video surface.
  ///
  /// The middle band is a plain show/hide-the-controls tap. In a side zone
  /// the FIRST tap also toggles the controls immediately — deferring it until
  /// the double-tap window expired would put a dead ~250ms in front of the
  /// most common gesture in the app — and arms the window instead. A second
  /// tap inside the window is the skip; from there the burst is open and
  /// every further tap skips again (the spam case), no double-tap needed.
  ///
  /// The eager toggle costs nothing visually in the case that matters: while
  /// watching, the controls are hidden, so tap 1 reveals them and tap 2's
  /// [_skip] keeps them up via its own [_revealControls].
  void _onTapUpAt(Offset local, double width) {
    var zone = 0;
    if (_canSkip && width > 0) {
      if (local.dx < width * _kSkipZoneFraction) {
        zone = -1;
      } else if (local.dx > width * (1 - _kSkipZoneFraction)) {
        zone = 1;
      }
    }
    if (zone == 0) {
      _cancelArmedTap();
      _toggleControls();
      return;
    }
    // Burst already running in this zone (or its badge still up) — keep going.
    if (_skipDirection == zone && _skipCount > 0) {
      _cancelArmedTap();
      _skip(zone);
      return;
    }
    // Second tap of a fresh double-tap in the same zone: the first real skip.
    if (_armedTapZone == zone) {
      _cancelArmedTap();
      _skip(zone);
      return;
    }
    _cancelArmedTap();
    _armedTapZone = zone;
    _tapArmTimer = Timer(const Duration(milliseconds: 300), () {
      _tapArmTimer = null;
      _armedTapZone = 0;
    });
    _toggleControls();
  }

  void _cancelArmedTap() {
    _tapArmTimer?.cancel();
    _tapArmTimer = null;
    _armedTapZone = 0;
  }

  /// Abandon the current burst without seeking. Grabbing the seek slider has
  /// to do this: otherwise the buffered skip fires ~300ms later and yanks
  /// playback to where the taps had been heading instead of where the user
  /// just scrubbed to.
  void _cancelPendingSkip() {
    _skipCommitTimer?.cancel();
    _skipCommitTimer = null;
    _skipPreviewTimer?.cancel();
    _skipPreviewTimer = null;
    _skipBadgeTimer?.cancel();
    _skipTarget = null;
    _skipDirection = 0;
    _skipCount = 0;
    _skipAccum = Duration.zero;
  }

  /// Drop every per-item overlay/pending-seek scrap when the screen switches
  /// to another movie/episode. Call from inside the caller's setState. A
  /// pending skip especially must not survive: its target is a position in
  /// the item that just left, and committing it would seek the NEW one there.
  void _resetForNewItem() {
    _cancelPendingSkip();
    _cancelArmedTap();
    _dragPosition = null;
    // Stale shape from the previous item must not leak — the mpv path already
    // resets its own videoAspect in PlaybackController._play().
    _nativeVideoAspect = null;
    _nativeSubtitleCues = null;
  }

  // Native ExoPlayer + SurfaceView path for smooth playback on weak boxes —
  // live TV and (see [_useNative]) on-demand movies/series both use it.
  NativeVideoController? _nativeController;
  StreamSubscription<String>? _nativeStateSub;
  StreamSubscription<NativeVideoError>? _nativeErrSub;
  StreamSubscription<NativeVideoPosition>? _nativePosSub;
  Timer? _nativeReconnectTimer;
  // Capped like the media_kit reconnect loop (playback_controller.dart's
  // reconnectAttempt) — without this, a permanently dead stream (off-air,
  // wrong URL, DRM) retried forever every 2s with no error ever surfaced.
  int _nativeReconnectAttempt = 0;
  static const int _kMaxNativeReconnects = 5;

  // Subtitles on the native path are rendered as a plain Flutter overlay (see
  // _nativeSubtitleOverlay), from one of two sources: EXTERNAL SRT/VTT parsed
  // into [_nativeSubtitleCues] and timed against [_nativeClock], or an
  // EMBEDDED text track whose current line ExoPlayer pushes at display time
  // into [_nativeEmbeddedCue] (perfect sync, no Dart-side timing).
  List<SubtitleCue>? _nativeSubtitleCues;
  final ValueNotifier<String> _nativeEmbeddedCue = ValueNotifier('');
  // Position clock for the external-cue lookup — its own ValueNotifier so the
  // overlay follows every 250ms native tick without rebuilding the whole
  // player (PlaybackController deliberately notifies only once per second).
  final ValueNotifier<Duration> _nativeClock = ValueNotifier(Duration.zero);
  StreamSubscription<NativeTracks>? _nativeTracksSub;
  StreamSubscription<String>? _nativeCuesSub;
  // 'group:track' of the embedded native selection (persistence + sheet check).
  String? _nativeSelectedTextId;
  // Set on any manual pick (track/Fra/external) — the best-effort auto-restore
  // of the saved choice must never clobber what the user just chose, no matter
  // how slowly its network fetch lands.
  bool _userPickedSubtitle = false;
  // Bumped per item change so a stale in-flight auto-restore for the PREVIOUS
  // episode/movie can't install its subtitle onto the new one.
  int _subtitleEpoch = 0;

  // Display aspect ratio pushed from the native player (see
  // NativeVideoController.aspectRatioStream) — a SurfaceView has no "fit" of
  // its own, so _nativeVideo() does the contain/cover/fill sizing itself in
  // Flutter (FittedBox+SizedBox) using this, same approach as _mediaKitVideo().
  double? _nativeVideoAspect;
  StreamSubscription<double>? _nativeAspectSub;

  bool get _isLive => widget.mode == PlaybackMode.live;
  bool get _canArchive =>
      _isLive &&
      widget.source.isXtream &&
      _pc.currentChannel?.tvArchive == true &&
      _pc.currentChannel?.directUrl == null;

  bool _openingArchive = false;
  bool _returningToLive = false;

  Future<void> _openArchive() async {
    if (!_canArchive || _openingArchive) return;
    final ch = _pc.currentChannel!;
    final index = _pc.playingIndex;
    _openingArchive = true;
    try {
      // Short EPG provides both a panel-local clock and a UTC epoch. This
      // avoids assuming that the provider and the device share a time zone.
      var entries = _epg[ch.id] ?? const <EpgEntry>[];
      if (archiveClockOffset(entries) == null) {
        try {
          entries = await _appState.repository.shortEpg(widget.source, ch.id);
        } catch (_) {
          // Some panels expose XMLTV but not get_short_epg.
        }
      }
      if (!mounted || _pc.currentChannel?.id != ch.id) return;
      final now = DateTime.now().toUtc();
      final end = DateTime.utc(now.year, now.month, now.day, now.hour, now.minute);
      final start = end.subtract(const Duration(hours: 12));
      var offset = archiveClockOffset(entries);
      if (offset == null) {
        try {
          offset = await _appState.repository.archiveClockOffset(widget.source);
        } catch (_) {
          // Fall through to XMLTV when the panel omits server_info.
        }
      }
      if (!mounted || _pc.currentChannel?.id != ch.id) return;
      if (offset == null && ch.epgChannelId != null) {
        final guide = await _appState.repository.loadGuide(widget.source);
        if (!mounted || _pc.currentChannel?.id != ch.id) return;
        offset = archiveGuideClockOffset(
            guide[ch.epgChannelId!.toLowerCase().trim()] ?? const [], start);
      }
      if (offset == null) {
        _snack('Kan ikke fastslå udbyderens arkivtid for denne kanal.');
        return;
      }
      // Keep the URL's minute resolution aligned with the slider's origin.
      final url = StreamUrlBuilder.timeshift(
        widget.source, ch, 12 * 60, archiveStart(start, offset));
      // Silence the outgoing live player before the replacement route opens a
      // second connection (many Xtream accounts allow only one).
      if (_useNative) await _nativeController?.stop();
      await _pc.stopForNavigation();
      if (!mounted) return;
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => PlayerScreen.onDemand(
          source: widget.source,
          url: url,
          title: '${ch.name} · Arkiv',
          durationHint: 12 * 60 * 60,
          startAt: const Duration(hours: 11, minutes: 30),
          archivePlaylist: widget.playlist,
          archiveIndex: index,
          archiveWindowStartUtc: start,
        ),
      ));
    } catch (_) {
      if (mounted) _snack('Kunne ikke åbne kanalens TV-arkiv.');
    } finally {
      _openingArchive = false;
    }
  }

  Future<void> _returnToLive() async {
    final playlist = widget.archivePlaylist;
    final index = widget.archiveIndex;
    if (playlist == null || index == null || !mounted || _returningToLive) return;
    _returningToLive = true;
    if (_useNative) await _nativeController?.stop();
    await _pc.stopForNavigation();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => PlayerScreen.live(
        source: widget.source,
        playlist: playlist,
        initialIndex: index,
      ),
    ));
  }

  /// TV box with the native-player toggle on — covers both live TV and
  /// on-demand movies/series, both routed through the same ExoPlayer +
  /// SurfaceView path (see [_nativeUrl]/[_nativeVideo]).
  bool get _useNative => isTvMode && nativePlayer;

  /// URL that should be on screen for the native player, live or on-demand.
  String? get _nativeUrl =>
      _isLive ? _pc.currentLiveUrl : _pc.currentOnDemandUrl;

  Episode? get _nextEpisode {
    final eps = widget.episodes;
    final i = _epIndex;
    if (eps == null || i == null || i + 1 >= eps.length) return null;
    return eps[i + 1];
  }

  /// "Switch movie like a channel" — next/prev within the sibling list the
  /// movie was opened from (see [PlayerScreen.movies]). Clamped, not wrapped,
  /// mirroring live channel zap (_zapTo) — stepping past either end is a
  /// no-op rather than jumping to the other side of the list.
  Movie? get _nextMovie {
    final list = widget.movies;
    final i = _movieIdx;
    if (list == null || i == null || i + 1 >= list.length) return null;
    return list[i + 1];
  }

  Movie? get _prevMovie {
    final list = widget.movies;
    final i = _movieIdx;
    if (list == null || i == null || i - 1 < 0) return null;
    return list[i - 1];
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // True fullscreen: hide status + navigation bars while watching
    // (swipe from an edge reveals them temporarily). Android/mobile only —
    // SystemUiMode has no effect on desktop, which has no such system bars.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    // Desktop: actually fullscreen the OS window — without this the player
    // just sat inside the normal app window on Windows/macOS/Linux.
    unawaited(enterPlayerFullscreen());
    // Home button → picture-in-picture while this screen is open.
    PipService.setAutoPip(true);
    PipService.isSupported().then((v) {
      if (mounted && v) setState(() => _pipSupported = true);
    });
    // Resolved for BOTH modes now — the in-player favorite star needs it on
    // live too (previously only the on-demand branch set it).
    _appState = context.read<AppState>();
    if (_isLive) {
      _pc.openLive(
        playlist: widget.playlist,
        index: widget.initialIndex,
        source: widget.source,
        externalVideo: _useNative,
      );
      _loadEpg();
    } else {
      // Resolve DownloadManager NOW — the saveResume callback also fires from
      // dispose(), where context lookups throw and would abort the player
      // teardown (leaving audio playing after the screen pops).
      _downloads = context.read<DownloadManager>();
      _pc.onDemandCompleted = widget.archivePlaylist != null
          ? () => unawaited(_returnToLive())
          : _onEpisodeCompleted;
      _pc.openOnDemand(
        url: widget.url!,
        source: widget.source,
        resumeKey: widget.resumeKey,
        startAt: widget.startAt,
        durationHintSecs: widget.durationHint,
        saveResume: (k, p, d) =>
            _appState.saveResume(k, p, d, sourceId: widget.source.id),
        externalVideo: _useNative,
      );
      unawaited(_autoLoadSavedSubtitle(widget.resumeKey));
    }
    _pc.addListener(_onControllerTick);
    // PopScope.canPop is captured at build time and depends on where focus
    // is (_inControlsNav) — rebuild when the root node gains/loses focus, or
    // BACK could be swallowed for up to 4s after leaving the controls bar.
    _focus.addListener(_onRootFocusChanged);
    if (_isLive) _persistedPlayingIndex = widget.initialIndex;
    _scheduleHide();
  }

  void _onRootFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerTick() {
    // Refresh EPG only when the live channel actually changes — NOT on every
    // sub-second position tick (that flooded the panel with requests).
    if (_isLive && _pc.index != _lastEpgIndex) {
      _lastEpgIndex = _pc.index;
      // A zap is a fresh start for the native player's capped retry budget —
      // without this, a permanently dead channel left the counter maxed out,
      // and the NEXT channel's first transient hiccup surfaced an instant
      // error instead of quietly reconnecting.
      _nativeReconnectAttempt = 0;
      _loadEpg();
    }
    if (_isLive) _trackWatchedChannel();
    // A pending skip stops being a preview once the player has actually
    // landed near it — from here the seek bar follows the real position
    // again. (No setState needed: the same notification the AnimatedBuilder
    // is listening to drives the rebuild, and this listener runs first.)
    final target = _skipTarget;
    if (target != null &&
        _skipCommitTimer == null &&
        (_pc.position - target).abs() <= const Duration(seconds: 3)) {
      _skipTarget = null;
      _skipPreviewTimer?.cancel();
      _skipPreviewTimer = null;
    }
    _arbitrateOverlayFocus();
  }

  /// On TV, move D-pad focus onto an overlay's primary action the instant it
  /// appears (error retry), and hand focus back to the player when it clears —
  /// otherwise the stock remote can't reach the button at all.
  ///
  /// LIVE errors are the exception: focus must STAY on the player so the
  /// remote keeps zapping straight through a dead channel (grandparent-proof
  /// — a focus-trapping retry button meant up/down suddenly stopped changing
  /// channels). The live error overlay is informational only; OK retries.
  void _arbitrateOverlayFocus() {
    if (!isTvMode) return;
    if (_pc.hasError != _hadError) {
      _hadError = _pc.hasError;
      if (_pc.hasError && !_isLive) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pc.hasError) _retryFocus.requestFocus();
        });
      } else {
        _focus.requestFocus();
      }
    }
  }

  Timer? _watchedSettleTimer;
  int _persistedPlayingIndex = -1;

  /// "Fortsæt på sidste kanal" must remember the channel actually being
  /// WATCHED, not the one the player was opened with — every in-player
  /// change (CH±, digits, the surf drawer) used to leave the persisted id at
  /// the channel from hours ago. Persisted 5s after the playing channel
  /// settles, so zapping past a channel doesn't spam the recents list.
  void _trackWatchedChannel() {
    final idx = _pc.playingIndex;
    if (idx < 0 || idx == _persistedPlayingIndex) return;
    _watchedSettleTimer?.cancel();
    _watchedSettleTimer = Timer(const Duration(seconds: 5), () {
      if (!mounted || _pc.playingIndex != idx) return;
      final ch = _pc.playingChannel;
      if (ch == null) return;
      _persistedPlayingIndex = idx;
      // The category recorded when the player was opened is still the list
      // this player is zapping through.
      unawaited(_appState.markWatchedInCategory(
          ch, _appState.lastLiveCategoryId));
    });
  }

  Future<void> _loadEpg() async {
    final ch = _pc.currentChannel;
    if (ch == null || !widget.source.isXtream) return;
    if (_epg.containsKey(ch.id)) return;
    // Back off after a recent failure instead of retrying immediately.
    final failedAt = _epgFailedAt[ch.id];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(seconds: 60)) {
      return;
    }
    _epg[ch.id] = const []; // mark in-flight
    try {
      final list = await context.read<AppState>().repository.shortEpg(widget.source, ch.id);
      if (mounted) setState(() => _epg[ch.id] = list);
    } catch (_) {
      // EPG is best-effort; record the failure time so we retry at most once a
      // minute rather than on every controller notification.
      _epgFailedAt[ch.id] = DateTime.now();
      final v = _epg[ch.id];
      if (v != null && v.isEmpty) _epg.remove(ch.id);
    }
  }

  // ---------------- media_kit video (fit workaround on desktop) ----------------
  /// On Windows, media_kit_video's own BoxFit has no visible effect (a known
  /// upstream issue: the native ANGLE/D3D texture's reported rect can be
  /// stale/all-zero there, so the widget's internal FittedBox has nothing
  /// correctly-sized to scale) — confirmed by the user: identical code works
  /// fine on Android/TV, does nothing on the Windows build. Sidestep it on
  /// desktop by sizing the video ourselves using mpv's OWN aspect report
  /// ([PlaybackController.videoAspect], reliable cross-platform since it comes
  /// straight from the decoder, not the platform texture-rect plumbing) and
  /// applying [PlaybackController.fit] with a plain FittedBox we control.
  Widget _mediaKitVideo() {
    // First attempt at the Windows fix wrapped the widget in our OWN extra
    // FittedBox+SizedBox layer, forcing the widget's internal fit to a fixed
    // BoxFit.fill underneath it — structurally reasonable but added a second,
    // redundant fit layer on top of the widget's own (also real) FittedBox,
    // and the user confirmed after testing that cycling still visibly did
    // nothing. Switched to the library's OWN documented mechanism for this
    // instead: [Video.aspectRatio] feeds directly into the widget's single
    // internal FittedBox, replacing only the texture's width calculation
    // (`rect.height * aspectRatio` instead of the possibly-stale `rect.width`
    // on Windows) while leaving [fit] as the one real, un-duplicated knob.
    final aspect = _pc.videoAspect;
    return _withAspectZoom(Video(
      controller: _pc.videoController,
      controls: NoVideoControls,
      fit: _pc.fit,
      aspectRatio: (isDesktop && aspect != null && aspect > 0) ? aspect : null,
    ));
  }

  /// The zoom/wide half of [PlaybackController.aspectMode]: a centred scale
  /// of the already contain-fitted frame, clipped to the viewport. Shared by
  /// both backends so the button behaves identically on mpv and ExoPlayer.
  /// ALWAYS present (identity scale for the plain modes) — toggling a wrapper
  /// in and out would change the widget tree's shape and, on the native
  /// path, recreate the platform view (the exact class of bug as bug-024).
  Widget _withAspectZoom(Widget child) {
    return ClipRect(
      child: Transform.scale(
        scaleX: _pc.aspectScaleX,
        scaleY: _pc.aspectScaleY,
        child: child,
      ),
    );
  }

  Timer? _aspectToastTimer;
  bool _showAspectToast = false;

  /// Cycle the picture format AND say which mode is now active. For 16:9
  /// content on a 16:9 screen several modes look the same, so without the
  /// label the button reads as broken (it was reported that way three times).
  void _cycleAspect() {
    _pc.cycleFit();
    _aspectToastTimer?.cancel();
    setState(() => _showAspectToast = true);
    _aspectToastTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _showAspectToast = false);
    });
  }

  /// Desktop: moving the mouse reveals the controls (and restarts the
  /// auto-hide), and the cursor hides together with them — the standard
  /// fullscreen-player behaviour. Before, only a click showed the bar and
  /// the cursor sat on the picture forever.
  void _onMouseHover(PointerHoverEvent _) {
    if (!_showControls) setState(() => _showControls = true);
    // While the pointer rests ON the bar (see _hoverHold) the bar stays.
    if (!_controlsHovered) _scheduleHide();
  }

  bool _controlsHovered = false;

  /// Desktop: while the pointer rests on the controls bar itself, the 4s
  /// auto-hide must not pull the bar out from under it. Identity on
  /// touch/TV (isDesktop is fixed for the process, so the tree shape never
  /// flips at runtime).
  Widget _hoverHold(Widget child) {
    if (!isDesktop) return child;
    return MouseRegion(
      onEnter: (_) {
        _controlsHovered = true;
        _hideTimer?.cancel();
      },
      onExit: (_) {
        _controlsHovered = false;
        _scheduleHide();
      },
      child: child,
    );
  }

  // ---------------- native ExoPlayer (live + on-demand) ----------------
  Widget _nativeVideo() {
    final url = _nativeUrl;
    if (url == null) return const ColoredBox(color: Colors.black);
    final video = NativeVideo(
      url: url,
      userAgent: widget.source.userAgent ?? kDefaultUserAgent,
      // Live has no "resume" concept. On-demand: the offset for whatever URL
      // is current — NativeVideo applies it on the initial open AND on every
      // URL change (adjacent-movie resume), and PlaybackController resets it
      // per item, so next-episode correctly sees null here.
      startAt: _isLive ? null : _pc.pendingStartAt,
      onCreated: _onNativeCreated,
    );
    // A SurfaceView always stretches to fill exactly whatever box it's given
    // — there's no "fit" concept inside it. A first attempt resized the
    // native view itself (an AspectRatioFrameLayout wrapper + a "setFit"
    // channel command) but the user tested it and nothing changed; the most
    // likely explanation is that Flutter's hybrid-composition hosting always
    // gives a platform view the FULL size it allocated regardless of what
    // the Android view's own onMeasure() would prefer, so a smaller native
    // measurement never actually shows through. Sidestep that uncertainty
    // entirely by doing the sizing on the FLUTTER side instead — the same
    // FittedBox+SizedBox approach already used for _mediaKitVideo() — using
    // the aspect ratio pushed from NativeVideoView.kt's onVideoSizeChanged.
    //
    // The wrapper chain below has the SAME shape whether or not the ratio is
    // known yet. An earlier version returned the bare NativeVideo until
    // onVideoSizeChanged arrived and only then wrapped it — but Flutter can't
    // reconcile a widget that moves from being the RepaintBoundary's direct
    // child to sitting three levels deeper, so it disposed the old element
    // (platform view gone, ExoPlayer released) and inflated a fresh one that
    // re-opened the stream from its creation params. Every native open thus
    // restarted itself about a second after the first frame: a black flash,
    // a second connection to the provider (fatal on single-connection
    // accounts) and, on-demand, the seconds already played thrown away.
    // Until the ratio is known the box simply matches the viewport, which is
    // a no-op under every BoxFit.
    return _withAspectZoom(LayoutBuilder(builder: (context, c) {
      final aspect = _nativeVideoAspect;
      final double w, h;
      if (aspect != null && aspect > 0) {
        const base = 1000.0; // arbitrary reference size — FittedBox rescales it
        w = base;
        h = base / aspect;
      } else {
        w = c.maxWidth.isFinite ? c.maxWidth : 1920;
        h = c.maxHeight.isFinite ? c.maxHeight : 1080;
      }
      return ClipRect(
        child: FittedBox(
          fit: _pc.fit,
          child: SizedBox(width: w, height: h, child: video),
        ),
      );
    }));
  }

  /// Plain-text subtitle overlay for the native on-demand path — ExoPlayer
  /// isn't asked to render text tracks here at all (see the field doc on
  /// [_nativeSubtitleCues]), so this stands in for what mpv/libass draws
  /// internally on the normal media_kit path. Sized/offset approximately from
  /// the same [PlaybackController.subFontSize]/[PlaybackController.subDelaySecs]
  /// the subtitle settings sheet already controls — mpv's `sub-font-size` unit
  /// isn't a 1:1 logical-pixel value, so the scale factor here is an
  /// approximation, not pixel parity with the mpv path. The size sheet steps
  /// subFontSize by ±5 (of a 30-110 range) per press — the first version of
  /// this factor (0.42) made that a ~2px change, clamped into a narrow 16-44
  /// window, which read as "nothing happens" from a couch. 0.8 (clamp 24-88)
  /// makes each press a clearly visible ~4px step, default size 55 -> 44px.
  Widget _nativeSubtitleOverlay() {
    return Positioned(
      left: 24,
      right: 24,
      bottom: 32,
      child: ValueListenableBuilder<String>(
        valueListenable: _nativeEmbeddedCue,
        builder: (context, embedded, _) {
          return ValueListenableBuilder<Duration>(
            valueListenable: _nativeClock,
            builder: (context, pos, _) {
              String? text;
              if (embedded.isNotEmpty) {
                // Embedded track: ExoPlayer pushed this at display time —
                // inherently synced to the same mux, no user timing applied.
                text = embedded;
              } else {
                final cues = _nativeSubtitleCues;
                if (cues != null) {
                  // External file: the same math mpv applies for
                  // sub-delay/sub-speed — a cue displays while
                  // (position - delay) / speed falls inside its window.
                  final effMs = ((pos.inMilliseconds -
                              _pc.subDelaySecs * 1000) /
                          _pc.subSpeed)
                      .round();
                  text =
                      activeCue(cues, Duration(milliseconds: effMs))?.text;
                }
              }
              if (text == null || text.isEmpty) {
                return const SizedBox.shrink();
              }
              return Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: (_pc.subFontSize * 0.8).clamp(24, 88),
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                  shadows: const [
                    Shadow(color: Colors.black, blurRadius: 6),
                    Shadow(color: Colors.black, offset: Offset(1, 1)),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _onNativeCreated(NativeVideoController c) {
    _nativeController = c;
    _nativeStateSub?.cancel();
    _nativeStateSub = c.stateStream.listen((s) {
      if (!mounted) return;
      _pc.setExternalBuffering(s == 'buffering');
      // mpv's own playing-stream never fires for the native path — drive the
      // wakelock from ExoPlayer's own state instead (see setExternalPlaying).
      // ExoPlayer stays READY across play/pause, so a paused movie must not
      // re-arm the lock on the next state event (a seek while paused emits
      // buffering→ready) — gate on the play/pause intent for on-demand.
      _pc.setExternalPlaying(
          (s == 'ready' || s == 'buffering') && (_isLive || _pc.isPlaying));
      if (s == 'ready') {
        _pc.setExternalError(false);
        _nativeReconnectAttempt = 0;
        _nativeReconnectTimer?.cancel();
      }
      if (s == 'ended') {
        if (_isLive) {
          // A live stream that ends cleanly (provider restarted it, socket
          // rotated, single-connection kick) drains to STATE_ENDED — the mpv
          // path treats that as a drop and reconnects; this one silently
          // froze on the last frame with the wakelock released.
          _scheduleNativeReconnect();
        } else {
          _pc.setExternalEnded();
        }
      }
    });
    _nativeErrSub?.cancel();
    _nativeErrSub = c.errorStream.listen(
      (err) => _scheduleNativeReconnect(transient: err.transient),
    );
    _nativeAspectSub?.cancel();
    _nativeAspectSub = c.aspectRatioStream.listen((ratio) {
      if (mounted) setState(() => _nativeVideoAspect = ratio);
    });
    // Embedded tracks: lists for the Spor sheet, current line for the overlay.
    _nativeTracksSub?.cancel();
    _nativeTracksSub = c.tracksStream.listen((_) {
      if (mounted) setState(() {});
    });
    _nativeCuesSub?.cancel();
    _nativeCuesSub = c.cuesStream.listen((txt) {
      _nativeEmbeddedCue.value = txt;
    });
    // Play/pause is wired for BOTH modes: live has no button for it, but the
    // sleep timer pauses through this same handler (see
    // PlaybackController.setSleepTimer) — it used to pause the idle mpv
    // instance instead, i.e. do nothing at all on the native path.
    _pc.externalPlayPauseHandler = (playing) {
      if (playing) {
        c.play();
      } else {
        c.pause();
      }
    };
    if (!_isLive) {
      // Live has no seek bar / position display, so this plumbing is
      // on-demand only.
      _nativePosSub?.cancel();
      _nativePosSub = c.positionStream.listen((p) {
        _nativeClock.value = p.position;
        if (mounted) _pc.setExternalPosition(p.position, p.duration);
      });
      _pc.externalSeekHandler = (to) => c.seekTo(to);
    }
  }

  /// Retry the native ExoPlayer up to [_kMaxNativeReconnects] times, then give
  /// up and surface the real error overlay — mirroring the media_kit path's
  /// capped reconnect loop. A permanent failure (malformed stream, missing
  /// codec/DRM support — [transient] false) skips the retry loop entirely and
  /// surfaces the error immediately, since re-issuing the identical setSource()
  /// can never succeed. Without any of this, a dead stream was retried every 2s
  /// forever with zero indication anything was wrong, and the D-pad couldn't
  /// reach any retry/error UI since hasError could never become true.
  void _scheduleNativeReconnect({bool transient = true}) {
    if (!mounted) return;
    if (!transient || _nativeReconnectAttempt >= _kMaxNativeReconnects) {
      _pc.setExternalBuffering(false);
      _pc.setExternalPlaying(false);
      _pc.setExternalError(
        true,
        _isLive
            ? 'Kunne ikke afspille streamen. Prøv en anden kanal.'
            : 'Kunne ikke afspille. Prøv igen.',
      );
      return;
    }
    _nativeReconnectAttempt++;
    _pc.setExternalBuffering(true);
    _nativeReconnectTimer?.cancel();
    // Bound to the item that failed: if the user zaps (or auto-next moves on)
    // before the 2s elapse, this must NOT re-issue setSource on the NEW item
    // — that restarted the fresh channel ~2s in, right as it was buffering.
    final scheduledFor = _nativeUrl;
    _nativeReconnectTimer = Timer(const Duration(seconds: 2), () {
      final u = _nativeUrl;
      if (mounted && u != null && u == scheduledFor) {
        _nativeController?.setSource(
          u,
          userAgent: widget.source.userAgent ?? kDefaultUserAgent,
          // On-demand: a reconnect that drops the resume offset would restart
          // the movie from 0:00 on every transient network hiccup — the same
          // class of bug just fixed on the mpv path (see _play()'s doc).
          startAt: _isLive ? null : _onDemandRetryOffset,
        );
      }
    });
  }

  /// Where an on-demand reconnect/retry should resume from: wherever
  /// playback actually reached, or (if the error hit before the first
  /// position tick ever arrived) the originally-requested resume offset —
  /// never a hard 0:00 restart.
  Duration? get _onDemandRetryOffset =>
      _pc.position > Duration.zero ? _pc.position : _pc.pendingStartAt;

  /// Retry button handler: for the native path, `_pc.retry()` alone only
  /// clears the error flag (PlaybackController.openIndex's externalVideo
  /// branch never touches the ExoPlayer) — it must also reset the attempt
  /// counter and actually re-issue setSource, or "Prøv igen" silently does
  /// nothing while the ExoPlayer sits on the last failed source forever.
  void _retry() {
    if (_useNative) {
      _nativeReconnectAttempt = 0;
      _pc.retry();
      final u = _nativeUrl;
      if (u != null) {
        _nativeController?.setSource(
          u,
          userAgent: widget.source.userAgent ?? kDefaultUserAgent,
          startAt: _isLive ? null : _onDemandRetryOffset,
        );
      }
    } else {
      _pc.retry();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Desktop: a minimized or covered window is not "leaving the app" the
    // way the home button is on a phone — every desktop player keeps going
    // (VLC, a browser tab) — and Flutter reports minimize as `hidden`, which
    // the branch below would treat as backgrounding and pause/reopen the
    // stream on every alt-tab-and-minimize. Closing the window disposes the
    // screen and stops playback regardless.
    if (isDesktop) return;
    // Stop the sound when the user leaves the app (home button / app switch);
    // pick live streams back up on return. In picture-in-picture the video is
    // still visible, so playback must keep running.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (!PipService.inPip.value) {
        _pc.onAppBackground();
        _nativeController?.pause(); // don't keep ExoPlayer audio in the background
        _pc.setExternalPlaying(false);
        // A reconnect scheduled just before backgrounding must not fire later
        // and resume playback (and audio) while the app is in the background.
        _nativeReconnectTimer?.cancel();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (!PipService.inPip.value) {
        _pc.onAppForeground();
        if (_useNative) {
          if (_isLive) {
            // A live stream is stale on return — reload it fresh.
            _nativeReconnectAttempt = 0;
            final u = _nativeUrl;
            if (u != null) {
              _nativeController?.setSource(u,
                  userAgent: widget.source.userAgent ?? kDefaultUserAgent);
            }
          } else if (_pc.isPlaying) {
            // On-demand: ExoPlayer kept its buffer/position while paused in
            // the background — just resume, mirroring the mpv path's
            // _wasPlaying check (don't auto-resume a movie the user had
            // manually paused before backgrounding).
            _nativeController?.play();
            _pc.setExternalPlaying(true); // re-arm the wakelock too
          }
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    unawaited(exitPlayerFullscreen());
    PipService.setAutoPip(false);
    _hideTimer?.cancel();
    _navIdleTimer?.cancel();
    _numberTimer?.cancel();
    _nextTimer?.cancel();
    _skipCommitTimer?.cancel();
    _skipBadgeTimer?.cancel();
    _skipPreviewTimer?.cancel();
    _tapArmTimer?.cancel();
    _aspectToastTimer?.cancel();
    _watchedSettleTimer?.cancel();
    _nativeReconnectTimer?.cancel();
    _nativeStateSub?.cancel();
    _nativeErrSub?.cancel();
    _nativePosSub?.cancel();
    _nativeAspectSub?.cancel();
    _nativeTracksSub?.cancel();
    _nativeCuesSub?.cancel();
    _nativeEmbeddedCue.dispose();
    _nativeClock.dispose();
    _pc.externalSeekHandler = null;
    _pc.externalPlayPauseHandler = null;
    _pc.removeListener(_onControllerTick);
    _focus.removeListener(_onRootFocusChanged);
    _focus.dispose();
    _retryFocus.dispose();
    _playNowFocus.dispose();
    _controlsFocus.dispose();
    _backFocus.dispose();
    _pipFocus.dispose();
    _aspectFocus.dispose();
    _tracksFocus.dispose();
    _sleepFocus.dispose();
    _favFocus.dispose();
    _livePrevFocus.dispose();
    _liveNextFocus.dispose();
    _liveSurfFocus.dispose();
    _liveArchiveFocus.dispose();
    _surfScope.dispose();
    _surfScroll?.dispose();
    _pc.dispose();
    super.dispose();
  }

  // ---------------- auto-next episode ----------------
  void _onEpisodeCompleted() {
    if (!mounted || _nextEpisode == null) return;
    setState(() => _nextCountdown = 10);
    if (isTvMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _nextCountdown != null) _playNowFocus.requestFocus();
      });
    }
    _nextTimer?.cancel();
    _nextTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final v = (_nextCountdown ?? 1) - 1;
      if (v <= 0) {
        t.cancel();
        _playNextEpisode();
      } else {
        setState(() => _nextCountdown = v);
      }
    });
  }

  void _cancelAutoNext() {
    _nextTimer?.cancel();
    setState(() => _nextCountdown = null);
    if (isTvMode) _focus.requestFocus();
  }

  void _playNextEpisode() {
    final next = _nextEpisode;
    if (next == null) return;
    _nextTimer?.cancel();
    if (isTvMode) _focus.requestFocus();
    final key = 'ep:${next.id}';
    setState(() {
      _nextCountdown = null;
      _epIndex = _epIndex! + 1;
      _title = 'S${next.seasonNumber}E${next.episodeNumber} · ${next.title}';
      _season = next.seasonNumber;
      _episodeNum = next.episodeNumber;
      _resumeKey = key;
      _resetForNewItem(); // subtitles/aspect/pending skip belonged to the old episode
    });
    // Prefer an already-downloaded copy — auto-next must not require network
    // just because the CURRENT episode happened to stream (e.g. it was played
    // from the Series screen while episodes 2+ were downloaded for offline).
    final local =
        _downloads.playableLocalPath(key, sourceId: widget.source.id);
    _pc.openOnDemand(
      url: local ?? StreamUrlBuilder.episode(widget.source, next),
      source: widget.source,
      resumeKey: key,
      durationHintSecs: next.durationSecs ?? 0,
      saveResume: (k, p, d) =>
          _appState.saveResume(k, p, d, sourceId: widget.source.id),
      externalVideo: _useNative,
    );
    unawaited(_autoLoadSavedSubtitle(key));
  }

  /// Swipe left (finger moves right→left) = next, mirroring paging forward
  /// through a list; swipe right = previous. Requires real velocity so a
  /// slow accidental drag (or a seek-slider drag that strayed off the
  /// slider) doesn't fire a switch — same rough threshold class as Flutter's
  /// own dismissible/page-view gestures.
  void _onMovieSwipe(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    if (v.abs() < 200) return;
    _playAdjacentMovie(v < 0 ? 1 : -1);
  }

  /// "Switch movie like a channel" — buttons and swipe both call this.
  /// [direction] is +1 (next) or -1 (previous). Unlike _playNextEpisode this
  /// looks up the target's own saved resume position first (a movie you
  /// switch away from and back to should pick up where YOU left it, the same
  /// as opening it fresh from the Film screen would) — an async gap live
  /// channel zapping never needs.
  Future<void> _playAdjacentMovie(int direction) async {
    final target = direction > 0 ? _nextMovie : _prevMovie;
    if (target == null) return;
    final key = 'vod:${target.id}';
    final resume = await _appState.resumeFor(key, sourceId: widget.source.id);
    if (!mounted) return;
    if (isTvMode) _focus.requestFocus();
    setState(() {
      _movieIdx = _movieIdx! + direction;
      _title = target.name;
      _searchTitle = target.name;
      _resumeKey = key;
      _resetForNewItem(); // subtitles/aspect/pending skip belonged to the old movie
    });
    unawaited(_appState.markWatched(target));
    // Prefer an already-downloaded copy, same reasoning as _playNextEpisode.
    final local = _downloads.playableLocalPath(key, sourceId: widget.source.id);
    _pc.openOnDemand(
      url: local ?? StreamUrlBuilder.movie(widget.source, target),
      source: widget.source,
      resumeKey: key,
      startAt: resume != null ? Duration(seconds: resume.positionSecs) : null,
      durationHintSecs: target.durationSecs ?? 0,
      saveResume: (k, p, d) =>
          _appState.saveResume(k, p, d, sourceId: widget.source.id),
      externalVideo: _useNative,
    );
    unawaited(_autoLoadSavedSubtitle(key));
  }

  /// Open the surf drawer scrolled to the playing channel.
  void _openSurf() {
    _surfScroll?.dispose();
    _surfScroll = ScrollController(
      initialScrollOffset:
          ((_pc.index - 2) * _kSurfRowHeight).clamp(0.0, double.infinity),
    );
    setState(() => _showSurf = true);
    if (isTvMode) {
      // Move focus into the drawer so up/down/OK actually browse it.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _showSurf) _surfScope.requestFocus();
      });
    }
  }

  void _closeSurf() {
    setState(() => _showSurf = false);
    if (isTvMode) _focus.requestFocus();
  }

  void _revealControls() {
    // Transient reveal (from a zap/seek shortcut) — keep focus on the player so
    // the remote can keep zapping; don't drag focus into the controls bar.
    setState(() => _showControls = true);
    _scheduleHide();
  }

  /// TV: reveal the controls bar AND move focus into it so the remote can reach
  /// tracks / sleep timer / aspect / slider. The normal 4s quick-mode hide
  /// timer doesn't apply here (it explicitly refuses to fire while focus is
  /// inside the bar — see _scheduleHide) — instead a longer idle timer runs
  /// (_scheduleNavIdleHide), reset on every keypress while navigating, so the
  /// bar disappears on its own after real inactivity instead of sitting there
  /// forever until BACK is pressed.
  void _enterControlsNav() {
    setState(() => _showControls = true);
    if (isTvMode) {
      _scheduleNavIdleHide();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            _showControls &&
            !_showSurf &&
            !_pc.hasError &&
            _nextCountdown == null) {
          // Live lands directly on Spor (subtitles/audio one press away);
          // on-demand lands on play/pause (the natural first action) — Up from
          // there explicitly jumps to Spor too, see _onKey.
          (_isLive ? _tracksFocus : _controlsFocus).requestFocus();
        }
      });
    } else {
      _scheduleHide();
    }
  }

  /// Fires 10s after the last interaction while navigating the controls bar
  /// on TV (reset on every keypress that reaches _onKey's navigate-mode
  /// branch) — hides the bar and returns focus to the player, exactly like
  /// the normal quick-mode auto-hide but usable from inside the bar too.
  void _scheduleNavIdleHide() {
    _navIdleTimer?.cancel();
    _navIdleTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted || _showSurf) return;
      setState(() => _showControls = false);
      _focus.requestFocus();
    });
  }

  // Depth counter for _withIdleSuspended — _searchSubtitles can be invoked
  // FROM WITHIN the tracks sheet (tapping "Søg eksterne undertekster" pops
  // the tracks sheet and immediately opens the search flow's own dialog/
  // sheet), so these nest. Only resume the idle timer once the OUTERMOST
  // suspend scope actually finishes, or the tracks sheet's own cleanup would
  // reschedule it while the search dialog is still up, reproducing the exact
  // race this exists to fix.
  int _idleSuspendDepth = 0;

  /// Suspends the idle-hide timer for the duration of a bottom-sheet/dialog
  /// flow (subtitle tracks, subtitle search, sleep timer). Those are separate
  /// Navigator routes with their own focus scope — interacting with buttons
  /// inside them never reaches _onKey, so _scheduleNavIdleHide's per-keypress
  /// reset never fires there, and the timer (still counting from whatever it
  /// last saw on the player screen itself, e.g. the "Spor" button press that
  /// opened the sheet) could fire mid-use and hide the bar out from under an
  /// open sheet. Resumed with a fresh 10s window once the OUTERMOST flow
  /// closes, if the bar is still up in navigate mode by then.
  Future<T> _withIdleSuspended<T>(Future<T> Function() body) async {
    _idleSuspendDepth++;
    _navIdleTimer?.cancel();
    try {
      return await body();
    } finally {
      _idleSuspendDepth--;
      if (_idleSuspendDepth == 0 &&
          mounted &&
          isTvMode &&
          _showControls &&
          !_focus.hasPrimaryFocus) {
        _scheduleNavIdleHide();
      }
    }
  }

  /// True while the D-pad has genuinely moved focus INTO the controls bar
  /// (as opposed to the bar just being visible, which is the normal resting
  /// state) — used to give BACK a "close the menu first" step here too, the
  /// same one-off exception already made for the surf drawer.
  bool get _inControlsNav =>
      isTvMode &&
      _showControls &&
      !_showSurf &&
      // Focus on the error/auto-next overlay's buttons is NOT the bar — BACK
      // there must leave the player, not "close the menu".
      !_pc.hasError &&
      _nextCountdown == null &&
      !_focus.hasPrimaryFocus;

  /// BACK while genuinely navigating the controls bar used to fall straight
  /// through to PopScope and exit the movie — closing what's really just an
  /// open menu. Return focus to the player and let it settle back into the
  /// normal quick-mode bar (still visible, now auto-hiding on the usual timer)
  /// instead.
  void _exitControlsNav() {
    _navIdleTimer?.cancel();
    _focus.requestFocus();
    _scheduleHide();
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _scheduleHide();
    } else {
      _controlsHovered = false; // MouseRegion.onExit never fires on unmount
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      // Only auto-hide in "quick mode" — never yank the bar out from under a
      // remote user who has focus inside the controls.
      if (mounted && !_showSurf && (!isTvMode || _focus.hasPrimaryFocus)) {
        _controlsHovered = false;
        setState(() => _showControls = false);
      }
    });
  }

  void _pushDigit(String d) {
    _numberBuffer += d;
    _revealControls();
    setState(() {});
    _numberTimer?.cancel();
    _numberTimer = Timer(const Duration(milliseconds: 1800), () {
      final n = int.tryParse(_numberBuffer);
      if (n != null) _pc.zapToNumber(n);
      setState(() => _numberBuffer = '');
    });
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    // Accept repeats too (holding a seek/zap key on the remote), but never
    // key-up.
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;

    // ---- discrete media / menu keys: always work, whatever is on screen ----
    if (k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      if (!_isLive) _pc.playPause();
      _revealControls();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaStop) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (!_isLive &&
        (k == LogicalKeyboardKey.mediaRewind ||
            k == LogicalKeyboardKey.mediaFastForward)) {
      // Dedicated ⏪/⏩ keys keep their bigger fixed 30s step, but go through
      // the same burst accumulator as everything else — held down they used
      // to fire one un-debounced native seek per key-repeat.
      _skip(k == LogicalKeyboardKey.mediaRewind ? -1 : 1,
          step: const Duration(seconds: 30));
      return KeyEventResult.handled;
    }
    if (_isLive &&
        (k == LogicalKeyboardKey.mediaTrackNext ||
            k == LogicalKeyboardKey.mediaTrackPrevious)) {
      k == LogicalKeyboardKey.mediaTrackNext ? _pc.next() : _pc.prev();
      _revealControls();
      return KeyEventResult.handled;
    }
    // Menu / context-menu opens the tracks & subtitle sheet directly.
    if (k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.f1) {
      _showTracks();
      return KeyEventResult.handled;
    }

    // ---- overlays own the D-pad ----
    // Once focus has moved into the error or auto-next overlay, let normal
    // traversal + button activation drive it instead of swallowing keys here.
    // LIVE errors are deliberately excluded: a dead channel must never trap a
    // D-pad user (grandparents zapping with up/down) on a retry button — the
    // arrows keep zapping (opening a new channel clears the error by itself)
    // and OK retries the current one; see the quick-mode branches below.
    if ((_pc.hasError && !_isLive) || _nextCountdown != null) {
      return KeyEventResult.ignored;
    }
    if (_showSurf) {
      if (k == LogicalKeyboardKey.escape ||
          k == LogicalKeyboardKey.goBack) {
        _closeSurf();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // list handles arrows/enter
    }
    // Controls bar in "navigate mode" (TV): focus is inside the bar, so hand
    // arrows + OK to focus traversal so the remote can reach every control —
    // EXCEPT the Up/Down jump between the top icon row and the seek/playback
    // row below, which we resolve explicitly: Flutter's geometry-based
    // directional traversal is unreliable jumping between rows this different
    // in shape (a slim icon row vs. a full-width Slider vs. big circle
    // buttons), which left the top row effectively unreachable on-demand.
    if (isTvMode && _showControls && !_focus.hasPrimaryFocus) {
      // Any interaction while navigating resets the idle-hide timer — the bar
      // only disappears on its own after real inactivity (see
      // _scheduleNavIdleHide), not mid-use.
      _scheduleNavIdleHide();
      // BACK here closes the menu (like the surf drawer above) instead of
      // falling through to PopScope and exiting the movie — this is also
      // handled at the PopScope level (_inControlsNav) as a fallback for
      // devices where the hardware back key doesn't reach onKeyEvent at all.
      if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
        _exitControlsNav();
        return KeyEventResult.handled;
      }
      if (!_isLive) {
        final inTopRow = _topRowFocusNodes.contains(FocusManager.instance.primaryFocus);
        if (k == LogicalKeyboardKey.arrowUp && !inTopRow) {
          _tracksFocus.requestFocus();
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowDown && inTopRow) {
          _controlsFocus.requestFocus();
          return KeyEventResult.handled;
        }
      } else {
        final inTopRow = _topRowFocusNodes.contains(FocusManager.instance.primaryFocus);
        final inBottomRow =
            _liveBottomFocusNodes.contains(FocusManager.instance.primaryFocus);
        if (k == LogicalKeyboardKey.arrowDown && inTopRow) {
          _liveSurfFocus.requestFocus();
          return KeyEventResult.handled;
        }
        if (k == LogicalKeyboardKey.arrowUp && inBottomRow) {
          _tracksFocus.requestFocus();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }

    // ---- quick mode: the player holds focus, arrows are shortcuts ----

    // Digit zap (live).
    if (_isLive && e is KeyDownEvent) {
      final digit = _digitOf(k);
      if (digit != null) {
        _pushDigit(digit);
        return KeyEventResult.handled;
      }
    }

    if (_isLive) {
      if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.channelUp) {
        _pc.prev();
        _revealControls();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowDown || k == LogicalKeyboardKey.channelDown) {
        _pc.next();
        _revealControls();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        _openSurf();
        return KeyEventResult.handled;
      }
    } else {
      // Debounced + escalating (see _skip): holding the key fires many
      // KeyRepeatEvents (only KeyUpEvent is filtered above), and each seekBy
      // was reaching mpv's FIFO-serialized native seek immediately — one real
      // seek per repeat tick froze playback for a second-plus after any hold.
      // Buffer into one seek, and grow the step so a held arrow actually
      // fast-forwards instead of crawling 10s at a time.
      if (k == LogicalKeyboardKey.arrowLeft) {
        _skip(-1);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowRight) {
        _skip(1);
        return KeyEventResult.handled;
      }
    }

    // Space = play/pause on movies/series — the universal keyboard
    // expectation on a desktop, where it used to merely reveal the controls
    // bar like OK does. Sits before the OK block so it wins there; TV
    // navigate mode already returned above, so a focused button in the bar
    // still gets its Space.
    if (e is KeyDownEvent && k == LogicalKeyboardKey.space && !_isLive) {
      _pc.playPause();
      _revealControls();
      return KeyEventResult.handled;
    }
    if (e is KeyDownEvent &&
        (k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.space)) {
      // Live error state: the controls bar is hidden and the error overlay is
      // deliberately non-focusable on TV (see _errorOverlay) — OK means
      // "prøv igen" here, matching the on-screen hint.
      if (_isLive && _pc.hasError) {
        _retry();
        return KeyEventResult.handled;
      }
      // Desktop/tablet keyboard: a control inside the bar reached with Tab
      // must receive its own Enter (activation) — swallowing it here just
      // re-revealed the bar and the focused button never fired.
      if (!isTvMode && !_focus.hasPrimaryFocus) return KeyEventResult.ignored;
      // OK reveals the controls bar and moves focus into it, so tracks / sleep
      // timer / aspect / slider are reachable with the remote. (On touch this
      // path is unused — the GestureDetector toggles the bar directly.)
      _enterControlsNav();
      return KeyEventResult.handled;
    }
    // Desktop keyboard's "go back" — a D-pad remote's physical Back key
    // reaches Navigator via the platform back channel, not a KeyEvent, so this
    // is mainly for Escape on a Windows/desktop keyboard. _showSurf already
    // returned earlier above, so this is safe to pop directly.
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String? _digitOf(LogicalKeyboardKey k) {
    for (var i = 0; i <= 9; i++) {
      if (k == LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i) ||
          k == LogicalKeyboardKey(LogicalKeyboardKey.numpad0.keyId + i)) {
        return '$i';
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // The surf drawer and (TV) genuinely-navigating-the-controls-bar are
      // the only two sub-states that need a dedicated close-first step —
      // both are real navigational sub-states the user is actively inside,
      // not just the bar being passively visible. `_showControls` alone used
      // to gate this too ("hide the bar, THEN leave"), but that's the normal,
      // most-common resting state (defaults to visible) — it meant the very
      // first Back press, on a TV remote, a mouse click on the back arrow, or
      // the Escape key, appeared to do nothing but hide the bar, with no
      // visible way to tell a second press was needed. Effectively "locked"
      // from the user's perspective. Just leave immediately in that case;
      // closing an open drawer/menu first is still a sensible one-off
      // exception when the user is actually inside one of them.
      canPop: !_showSurf && !_inControlsNav,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showSurf) {
          _closeSurf();
        } else if (_inControlsNav) {
          _exitControlsNav();
        }
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: _onKey,
        child: MouseRegion(
          // Desktop only (isDesktop is fixed for the process, so this never
          // flips the tree shape at runtime): cursor hides with the controls,
          // mouse movement brings both back — see _onMouseHover.
          cursor: (isDesktop &&
                  !_showControls &&
                  !_showSurf &&
                  !_pc.hasError &&
                  _nextCountdown == null)
              ? SystemMouseCursors.none
              : MouseCursor.defer,
          onHover: isDesktop ? _onMouseHover : null,
          // The skip zones are a fraction of the player's WIDTH, so the tap
          // handler needs the real box — MediaQuery would also include
          // whatever the Scaffold trimmed off.
          child: LayoutBuilder(builder: (context, constraints) {
          return GestureDetector(
          // onTapUp (not onTap) so the tap's x position is available: the
          // left/right thirds are double-tap skip zones on movies/series, the
          // middle band is the plain show/hide-the-controls tap. See
          // _onTapUpAt for the tap/double-tap/spam state machine.
          onTapUp: (d) => _onTapUpAt(d.localPosition, constraints.maxWidth),
          // Touch shortcut for "switch movie like a channel" — the button
          // pair above covers D-pad/TV; a horizontal swipe is the faster,
          // more natural gesture on phone/tablet. Only wired up when there's
          // actually a sibling list to page through (movies only, not live
          // or series — series already has its own next-episode flow), AND
          // only while the controls bar is hidden: the seek Slider lower in
          // this same widget tree has its own horizontal-drag recognizer, and
          // stacking a second one of the SAME gesture type risks stealing a
          // scrub drag. When the bar is hidden there's nothing else on
          // screen claiming horizontal drags.
          onHorizontalDragEnd: (!_isLive && !_showControls && widget.movies != null)
              ? _onMovieSwipe
              : null,
          child: AnimatedBuilder(
            animation: Listenable.merge([_pc, PipService.inPip]),
            builder: (context, _) {
              final inPip = PipService.inPip.value;
              return Stack(
                fit: StackFit.expand,
                children: [
                  // Isolated so the video plane never re-diffs/repaints just
                  // because the overlay above it rebuilds on a position tick —
                  // on a weak box that competed with decode for every frame.
                  RepaintBoundary(
                    child: _useNative ? _nativeVideo() : _mediaKitVideo(),
                  ),
                  // Not gated on !_isLive anymore: embedded text tracks can
                  // exist on live streams too now that ExoPlayer pushes cues.
                  if (_useNative && !inPip) _nativeSubtitleOverlay(),
                  if (_pc.buffering && !_pc.hasError)
                    const Center(child: CircularProgressIndicator()),
                  // The PiP window only shows the bare video.
                  if (!inPip) ...[
                    if (_pc.reconnectAttempt > 0 && !_pc.hasError)
                      Positioned(
                        top: 40,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: _toast('Genopretter forbindelse… (${_pc.reconnectAttempt}/5)'),
                        ),
                      ),
                    if (_showAspectToast)
                      Positioned(
                        top: 40,
                        left: 0,
                        right: 0,
                        child: IgnorePointer(
                          child: Center(
                            child: _toast(
                                'Billedformat: ${_pc.aspectMode.label}'),
                          ),
                        ),
                      ),
                    if (_pc.hasError) _errorOverlay(),
                    if (_numberBuffer.isNotEmpty)
                      Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(_numberBuffer,
                              style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold)),
                        ),
                      ),
                    if (_showControls && !_pc.hasError) _overlay(),
                    // Above the controls bar: while spam-tapping, the badge
                    // is the thing the user is actually reading.
                    if (_skipDirection != 0) _skipIndicator(),
                    if (_nextCountdown != null) _autoNextOverlay(),
                    if (_showSurf) _surfDrawer(),
                  ],
                ],
              );
            },
          ),
        );
        }),
        ),
      ),
      ),
    );
  }

  /// Netflix-style skip badge — shows the running total of the current tap
  /// burst on the side being skipped, so spam-tapping has visible feedback
  /// ("10 sek" → "20 sek" → …) before the one real seek is issued.
  /// [IgnorePointer] matters: it sits over the skip zone it belongs to, and
  /// must not swallow the very next tap of the burst.
  Widget _skipIndicator() {
    final forward = _skipDirection > 0;
    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: forward ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(60),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(forward ? Icons.fast_forward : Icons.fast_rewind,
                      color: Colors.white, size: 40),
                  const SizedBox(height: 4),
                  Text(
                    '${_skipAccum.inSeconds} sek',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _autoNextOverlay() {
    final next = _nextEpisode;
    if (next == null) return const SizedBox.shrink();
    return Positioned(
      right: 24,
      bottom: 24,
      child: Container(
        width: 340,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF171C26).withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Næste afsnit om $_nextCountdown…',
                style: const TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 6),
            Text(
              'S${next.seasonNumber}E${next.episodeNumber} · ${next.title}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  focusNode: _playNowFocus,
                  onPressed: _playNextEpisode,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Afspil nu'),
                ),
                const SizedBox(width: 10),
                TextButton(
                  onPressed: _cancelAutoNext,
                  child: const Text('Annuller'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _toast(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text, style: const TextStyle(color: Colors.white)),
      );

  Widget _errorOverlay() {
    // Live on TV: informational only, NO focusable buttons — focus stays on
    // the player so up/down keep zapping through a dead channel and OK
    // retries (see _onKey + _arbitrateOverlayFocus). Everywhere else (VOD,
    // or live on a touch device) the buttons remain.
    final passive = _isLive && isTvMode;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
        const SizedBox(height: 12),
        Text(_pc.errorMessage ?? 'Afspilningsfejl',
            style: const TextStyle(color: Colors.white)),
        const SizedBox(height: 16),
        if (passive)
          const Text(
            'Skift kanal med ▲ / ▼  ·  OK prøver igen',
            style: TextStyle(color: Colors.white70, fontSize: 14),
          )
        else ...[
          FilledButton.icon(
            focusNode: _retryFocus,
            onPressed: _retry,
            icon: const Icon(Icons.refresh),
            label: const Text('Prøv igen'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Tilbage'),
          ),
        ],
      ],
    );
    return Center(child: passive ? ExcludeFocus(child: content) : content);
  }

  Widget _overlay() {
    final ch = _pc.currentChannel;
    final title = _isLive ? (ch?.name ?? '') : (_title ?? '');
    final now = _isLive && ch != null ? _nowNext(ch.id) : null;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.6),
            Colors.transparent,
            Colors.black.withValues(alpha: 0.75),
          ],
          stops: const [0, 0.45, 1],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _hoverHold(Row(
              children: [
                FocusRing(
                  shape: BoxShape.circle,
                  child: IconButton(
                    focusNode: _backFocus,
                    iconSize: 30,
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w600)),
                      if (now != null)
                        Text(now,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70, fontSize: 13)),
                    ],
                  ),
                ),
                _favoriteButton(),
                if (_pipSupported)
                  FocusRing(
                    shape: BoxShape.circle,
                    child: IconButton(
                      focusNode: _pipFocus,
                      tooltip: 'Minivindue (PiP)',
                      onPressed: PipService.enterPip,
                      icon: const Icon(Icons.picture_in_picture_alt,
                          color: Colors.white),
                    ),
                  ),
                FocusRing(
                  shape: BoxShape.circle,
                  child: IconButton(
                    focusNode: _aspectFocus,
                    tooltip: 'Billedformat',
                    onPressed: _cycleAspect,
                    icon: const Icon(Icons.aspect_ratio, color: Colors.white),
                  ),
                ),
                FocusRing(
                  shape: BoxShape.circle,
                  child: IconButton(
                    // Landing spot when OK opens the bar on live TV — see
                    // _enterControlsNav. On-demand reaches this button via the
                    // explicit Up-jump in _onKey instead (see _topRowFocusNodes).
                    focusNode: _tracksFocus,
                    tooltip: 'Spor',
                    onPressed: _showTracks,
                    icon: const Icon(Icons.subtitles, color: Colors.white),
                  ),
                ),
                FocusRing(
                  shape: BoxShape.circle,
                  child: IconButton(
                    focusNode: _sleepFocus,
                    tooltip: 'Sleep-timer',
                    onPressed: _showSleep,
                    icon: Icon(
                      _pc.sleepRemaining != null
                          ? Icons.bedtime
                          : Icons.bedtime_outlined,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            )),
            const Spacer(),
            _hoverHold(_isLive ? _liveBottom() : _onDemandBottom()),
          ],
        ),
      ),
    );
  }

  Widget _liveBottom() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: [
          _circleBtn(Icons.skip_previous, _pc.prev, focusNode: _livePrevFocus),
          Text('${_pc.index + 1} / ${_pc.playlist.length}',
              style: const TextStyle(color: Colors.white70)),
          _circleBtn(Icons.skip_next, _pc.next, focusNode: _liveNextFocus),
          _circleBtn(Icons.list, _openSurf, focusNode: _liveSurfFocus),
          FocusRing(
            borderRadius: 12,
            child: _canArchive
                ? FilledButton.icon(
                    focusNode: _liveArchiveFocus,
                    onPressed: _openArchive,
                    icon: const Icon(Icons.history),
                    label: const Text('Spol 12 timer'),
                  )
                : OutlinedButton.icon(
                    focusNode: _liveArchiveFocus,
                    onPressed: () => _snack(
                      'Udbyderen tilbyder ikke TV-arkiv for denne kanal. '
                      'Spoling kræver arkiv eller lokal optagelse.',
                    ),
                    icon: const Icon(Icons.history_toggle_off),
                    label: const Text('Intet arkiv'),
                  ),
          ),
        ],
      ),
    );
  }

  String? _archiveClock(Duration position) {
    final start = widget.archiveWindowStartUtc;
    if (start == null) return null;
    final local = start.add(position).toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }

  Widget _onDemandBottom() {
    // Follows a pending skip burst too (see _displayPosition) — otherwise the
    // bar sat frozen at the old spot while the badge counted up, and only
    // jumped once the debounced seek finally landed.
    final pos = _displayPosition;
    final dur = _pc.duration;
    final max = dur.inMilliseconds.toDouble();
    final value = max <= 0 ? 0.0 : pos.inMilliseconds.clamp(0, dur.inMilliseconds).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(_archiveClock(pos) ?? _fmt(pos),
                  style: const TextStyle(color: Colors.white70)),
              Expanded(
                child: FocusRing(
                  borderRadius: 10,
                  child: Slider(
                    value: max <= 0 ? 0 : value,
                    max: max <= 0 ? 1 : max,
                    // Only follow the drag locally (immediate visual feedback,
                    // zero native calls) and issue the ONE real mpv seek on
                    // release — dragging fired a synchronous, FIFO-serialized
                    // native seek per pixel, freezing playback for a
                    // second-plus after every scrub.
                    // Hold the bar for the whole scrub: the 4s auto-hide used
                    // to fire mid-drag and unmount the Slider before
                    // onChangeEnd — no seek was ever issued, and the stuck
                    // _dragPosition pinned the bar/clock at the abandoned spot.
                    onChangeStart: (_) => _hideTimer?.cancel(),
                    onChanged: (v) {
                      // The scrub is now the user's intent — drop any skip
                      // burst still waiting to commit (see _cancelPendingSkip).
                      _cancelPendingSkip();
                      setState(
                          () => _dragPosition = Duration(milliseconds: v.toInt()));
                    },
                    onChangeEnd: (v) {
                      // Preview the target until the player lands there (same
                      // mechanism as a skip burst): the bar no longer snaps
                      // back to the stale pre-scrub position on release, and
                      // a skip tapped right after chains off the scrub target
                      // instead of seeking BACKWARDS from the old position.
                      final t = _pc.clampSeek(Duration(milliseconds: v.toInt()));
                      _pc.seek(t);
                      setState(() {
                        _dragPosition = null;
                        _skipTarget = t;
                      });
                      _armSkipPreviewSafety();
                      _scheduleHide();
                    },
                  ),
                ),
              ),
              Text(_archiveClock(dur) ?? _fmt(dur),
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // "Switch movie like a channel" — mirrors live TV's prev/next
              // channel buttons. Never coexists with next-episode below (a
              // screen is either playing a movie or a series episode).
              if (_prevMovie != null) ...[
                _circleBtn(Icons.skip_previous, () => _playAdjacentMovie(-1)),
                const SizedBox(width: 16),
              ],
              // Through _skip, not a raw seekBy: mashing these buttons is the
              // same gesture as spam double-tapping the sides, so it gets the
              // same accumulate-into-one-seek + escalating step + badge.
              _circleBtn(Icons.replay_10, () => _skip(-1)),
              const SizedBox(width: 16),
              // Landing spot when OK opens the bar on VOD/series.
              _circleBtn(_pc.isPlaying ? Icons.pause : Icons.play_arrow, _pc.playPause,
                  big: true, focusNode: _controlsFocus),
              const SizedBox(width: 16),
              _circleBtn(Icons.forward_10, () => _skip(1)),
              if (widget.archivePlaylist != null) ...[
                const SizedBox(width: 16),
                FocusRing(
                  borderRadius: 12,
                  child: FilledButton.icon(
                    onPressed: _returnToLive,
                    icon: const Icon(Icons.live_tv),
                    label: const Text('Live'),
                  ),
                ),
              ],
              // Manually skip ahead mid-episode — previously the ONLY way to
              // advance was waiting for the episode to finish and the 10s
              // auto-next countdown to fire.
              if (_nextEpisode != null) ...[
                const SizedBox(width: 16),
                _circleBtn(Icons.skip_next, _playNextEpisode),
              ],
              if (_nextMovie != null) ...[
                const SizedBox(width: 16),
                _circleBtn(Icons.skip_next, () => _playAdjacentMovie(1)),
              ],
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget _surfDrawer() {
    final channels = _pc.playlist;
    return Align(
      alignment: Alignment.centerRight,
      // Its own scope so the selected row's autofocus actually applies on TV
      // (the fullscreen root scope already has a focused child otherwise).
      child: FocusScope(
        node: _surfScope,
        child: Container(
          width: 340,
          color: Colors.black.withValues(alpha: 0.85),
          child: SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      const Text('Kanaler',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                      const Spacer(),
                      IconButton(
                        onPressed: _closeSurf,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _surfScroll,
                    itemExtent: _kSurfRowHeight,
                    itemCount: channels.length,
                    itemBuilder: (context, i) {
                      final c = channels[i];
                      final selected = i == _pc.index;
                      return FocusRing(
                        borderRadius: 10,
                        child: ListTile(
                          autofocus: selected && isTvMode,
                          selected: selected,
                          dense: true,
                          leading: Text(c.number != null ? '${c.number}' : '${i + 1}',
                              style: const TextStyle(color: Colors.white54)),
                          title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () {
                            // Zap by INDEX — channel numbers repeat in real playlists.
                            _pc.zapToIndex(i);
                            _closeSurf();
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTracks() => _withIdleSuspended(_showTracksBody);

  Future<void> _showTracksBody() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF171C26),
      builder: (sheetContext) {
        return SafeArea(
          child: StatefulBuilder(
            builder: (sheetContext, setSheetState) {
              // Live-updating lists on BOTH backends: mpv probes tracks
              // asynchronously (a sheet opened early used to show a frozen
              // empty snapshot forever), and the native player pushes its
              // lists whenever ExoPlayer reports them.
              return StreamBuilder<NativeTracks>(
                initialData: _nativeController?.tracks,
                stream: _nativeController?.tracksStream,
                builder: (context, nativeSnap) {
                  final native = nativeSnap.data ?? const NativeTracks();
                  return StreamBuilder<Tracks>(
                    initialData: _pc.player.state.tracks,
                    stream: _pc.player.stream.tracks,
                    builder: (context, snap) {
                      final tracks = snap.data ?? _pc.player.state.tracks;
                      // Hide mpv's pseudo entries — they rendered as dead
                      // "Spor auto"/"Spor no" rows ('Fra' already covers off).
                      final mpvAudio = [
                        for (final a in tracks.audio)
                          if (a.id != 'auto' && a.id != 'no') a,
                      ];
                      final mpvSubs = [
                        for (final s in tracks.subtitle)
                          if (s.id != 'auto' && s.id != 'no') s,
                      ];
                      return ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(title: Text('Lyd', style: TextStyle(fontWeight: FontWeight.bold))),
                  if (_useNative)
                    for (final a in native.audio)
                      FocusRing(
                        borderRadius: 8,
                        child: ListTile(
                          dense: true,
                          title: Text(_trackLabel(a.label, a.language, a.id)),
                          trailing: a.selected
                              ? const Icon(Icons.check, size: 18)
                              : null,
                          onTap: () {
                            unawaited(_nativeController?.setAudioTrack(a));
                            Navigator.pop(sheetContext);
                          },
                        ),
                      )
                  else
                    for (final a in mpvAudio)
                      FocusRing(
                        borderRadius: 8,
                        child: ListTile(
                          dense: true,
                          title: Text(_trackLabel(a.title, a.language, a.id)),
                          onTap: () {
                            _pc.player.setAudioTrack(a);
                            Navigator.pop(sheetContext);
                          },
                        ),
                      ),
                  const Divider(),
                  const ListTile(title: Text('Undertekster', style: TextStyle(fontWeight: FontWeight.bold))),
                  if (!_isLive && _searchTitle != null)
                    FocusRing(
                      borderRadius: 8,
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.download_outlined, size: 20),
                        title: const Text('Søg eksterne undertekster…'),
                        subtitle: _pc.externalSubtitleTitle != null
                            ? Text('Aktiv: ${_pc.externalSubtitleTitle}',
                                style: const TextStyle(fontSize: 12))
                            : null,
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _searchSubtitles();
                        },
                      ),
                    ),
                  FocusRing(
                    borderRadius: 8,
                    child: ListTile(
                      dense: true,
                      // Always renders (even with zero tracks reported), so
                      // it's a safe universal initial-focus target — without
                      // it the modal's first D-pad press had no defined
                      // starting point.
                      autofocus: isTvMode,
                      title: const Text('Fra'),
                      onTap: () {
                        _userPickedSubtitle = true;
                        _pc.player.setSubtitleTrack(SubtitleTrack.no());
                        if (_useNative) {
                          unawaited(_nativeController?.disableTextTrack());
                          _nativeSelectedTextId = null;
                          _nativeEmbeddedCue.value = '';
                          setState(() => _nativeSubtitleCues = null);
                        }
                        // Both paths: the "Aktiv: <sprog>" label used to keep
                        // lying on the mpv path after turning subtitles off.
                        _pc.setExternalSubtitleTitle(null);
                        // Also forget the saved choice — otherwise turning
                        // subtitles off here would still come back next time
                        // this item is reopened (see _autoLoadSavedSubtitle).
                        if (_resumeKey != null) {
                          unawaited(_appState.clearSubtitleChoice(_resumeKey!,
                              sourceId: widget.source.id));
                        }
                        Navigator.pop(sheetContext);
                      },
                    ),
                  ),
                  if (_useNative)
                    for (final s in native.text)
                      FocusRing(
                        borderRadius: 8,
                        child: ListTile(
                          dense: true,
                          title: Text(_trackLabel(s.label, s.language, s.id)),
                          trailing: s.id == _nativeSelectedTextId
                              ? const Icon(Icons.check, size: 18)
                              : null,
                          onTap: () {
                            _userPickedSubtitle = true;
                            unawaited(_nativeController?.setTextTrack(s));
                            _nativeSelectedTextId = s.id;
                            // External parsed cues would double-draw under
                            // the pushed embedded line.
                            setState(() => _nativeSubtitleCues = null);
                            _pc.setExternalSubtitleTitle(null);
                            if (_resumeKey != null) {
                              unawaited(_saveSubtitleChoice(
                                _resumeKey!,
                                SubtitleChoice(
                                  '',
                                  _trackLabel(s.label, s.language, s.id),
                                  kind: 'embedded',
                                  trackId: s.id,
                                ),
                              ));
                            }
                            Navigator.pop(sheetContext);
                          },
                        ),
                      )
                  else
                    for (final s in mpvSubs)
                      FocusRing(
                        borderRadius: 8,
                        child: ListTile(
                          dense: true,
                          title: Text(_trackLabel(s.title, s.language, s.id)),
                          onTap: () {
                            // Mark BEFORE selecting: the auto-restore of a
                            // saved external choice used to land seconds
                            // later and silently clobber this embedded pick —
                            // the "I select a track and nothing happens" bug.
                            _userPickedSubtitle = true;
                            _pc.player.setSubtitleTrack(s);
                            _pc.setExternalSubtitleTitle(null);
                            if (_resumeKey != null) {
                              unawaited(_saveSubtitleChoice(
                                _resumeKey!,
                                SubtitleChoice(
                                  '',
                                  _trackLabel(s.title, s.language, s.id),
                                  kind: 'embedded',
                                  trackId: s.id,
                                ),
                              ));
                            }
                            Navigator.pop(sheetContext);
                          },
                        ),
                      ),
                  const Divider(),
                  const ListTile(
                    title: Text('Undertekst-justering',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  // Full-width, evenly-spread rows (not a cramped ListTile.trailing
                  // cluster) so each +/- control is individually reachable and
                  // visibly focus-ringed — a tight icon cluster pinned to one edge
                  // made D-pad Up/Down traversal from the track list above land
                  // unpredictably, and the bare IconButtons had no focus ring.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.format_size, size: 20, color: Colors.white70),
                            SizedBox(width: 10),
                            Text('Størrelse'),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            FocusRing(
                              shape: BoxShape.circle,
                              child: IconButton(
                                icon: const Icon(Icons.remove),
                                onPressed: () async {
                                  await _pc.setSubtitleFontSize(_pc.subFontSize - 5);
                                  setSheetState(() {});
                                },
                              ),
                            ),
                            Expanded(
                              child: Center(
                                  child: Text('${_pc.subFontSize.round()}')),
                            ),
                            FocusRing(
                              shape: BoxShape.circle,
                              child: IconButton(
                                icon: const Icon(Icons.add),
                                onPressed: () async {
                                  await _pc.setSubtitleFontSize(_pc.subFontSize + 5);
                                  setSheetState(() {});
                                },
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.schedule, size: 20, color: Colors.white70),
                            SizedBox(width: 10),
                            Text('Timing'),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.only(left: 30),
                          child: Text('Minus = tidligere, plus = senere',
                              style: TextStyle(fontSize: 11, color: Colors.white54)),
                        ),
                        const SizedBox(height: 6),
                        // Two step sizes: ±0.25s was the ONLY step before,
                        // which made fixing a 5-10s offset a 20-40 press
                        // ordeal. Tap the value to reset offset AND drift.
                        Row(
                          children: [
                            _timingBtn(sheetContext, '−5 s', () async {
                              await _pc.nudgeSubtitleDelay(-5);
                              setSheetState(() {});
                            }),
                            _timingBtn(sheetContext, '−0,5', () async {
                              await _pc.nudgeSubtitleDelay(-0.5);
                              setSheetState(() {});
                            }),
                            Expanded(
                              child: Center(
                                child: FocusRing(
                                  borderRadius: 8,
                                  child: TextButton(
                                    onPressed: () async {
                                      await _pc.resetSubtitleDelay();
                                      setSheetState(() {});
                                    },
                                    child: Text(
                                      '${_pc.subDelaySecs >= 0 ? '+' : ''}${_pc.subDelaySecs.toStringAsFixed(2)}s',
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            _timingBtn(sheetContext, '+0,5', () async {
                              await _pc.nudgeSubtitleDelay(0.5);
                              setSheetState(() {});
                            }),
                            _timingBtn(sheetContext, '+5 s', () async {
                              await _pc.nudgeSubtitleDelay(5);
                              setSheetState(() {});
                            }),
                          ],
                        ),
                      ],
                    ),
                  ),
                  // Linear drift correction — a constant offset can't fix a
                  // file authored for another framerate/cut ("5s early at one
                  // point, 10s late later in the same movie"). Hidden on the
                  // embedded-native selection, where cues are inherently
                  // synced by ExoPlayer itself.
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(
                          children: [
                            Icon(Icons.speed, size: 20, color: Colors.white70),
                            SizedBox(width: 10),
                            Text('Glidning'),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.only(left: 30),
                          child: Text(
                              'Brug hvis teksten glider mere og mere gennem filmen',
                              style: TextStyle(fontSize: 11, color: Colors.white54)),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            _timingBtn(sheetContext, '−', () async {
                              await _pc.nudgeSubtitleSpeed(-0.005);
                              setSheetState(() {});
                            }),
                            Expanded(
                              child: Center(
                                child: Text(
                                  '${_pc.subSpeed >= 1 ? '+' : ''}${((_pc.subSpeed - 1) * 100).toStringAsFixed(1)} %',
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ),
                            ),
                            _timingBtn(sheetContext, '+', () async {
                              await _pc.nudgeSubtitleSpeed(0.005);
                              setSheetState(() {});
                            }),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                      );
                    },
                  );
                },
              );
            },
          ),
        );
      },
    );
    // Sheet closed: persist the calibration onto the saved choice (if any) so
    // a painstakingly synced subtitle is still synced on the next open.
    if (_resumeKey != null) {
      unawaited(_appState.saveSubtitleTiming(
          _resumeKey!, _pc.subDelaySecs, _pc.subSpeed,
          sourceId: widget.source.id));
    }
  }

  /// Compact labeled step button for the timing rows.
  Widget _timingBtn(BuildContext context, String label, VoidCallback onTap) {
    return FocusRing(
      borderRadius: 8,
      child: TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(44, 40),
          padding: const EdgeInsets.symmetric(horizontal: 10),
        ),
        onPressed: onTap,
        child: Text(label),
      ),
    );
  }

  /// If the user previously picked a subtitle for this exact item (external
  /// file OR embedded track — see SubtitleChoice), silently restore it — along
  /// with the persisted timing calibration — instead of requiring the whole
  /// flow again every time they come back to it. Best-effort: a dead link or
  /// missing track never surfaces an error or blocks playback.
  ///
  /// Called once per item (open / next-episode / adjacent-movie); doubles as
  /// the per-item reset point for all subtitle state. Two clobber guards
  /// learned the hard way: [_subtitleEpoch] kills a stale in-flight restore
  /// when the item changes under it, and [_userPickedSubtitle] makes a manual
  /// pick always win over this automatic one.
  Future<void> _autoLoadSavedSubtitle(String? key) async {
    final epoch = ++_subtitleEpoch;
    _userPickedSubtitle = false;
    _nativeSelectedTextId = null;
    _nativeEmbeddedCue.value = '';
    if (_nativeSubtitleCues != null && mounted) {
      setState(() => _nativeSubtitleCues = null);
    }
    if (key == null) return;
    final choice =
        await _appState.subtitleChoiceFor(key, sourceId: widget.source.id);
    if (choice == null) return;
    bool stale() =>
        !mounted || epoch != _subtitleEpoch || _userPickedSubtitle;
    if (stale()) return;
    // Wait for the item to genuinely start loading before attaching anything —
    // issued too early, the command is silently dropped rather than queued.
    await _waitForPlaybackReady();
    if (stale()) return;
    try {
      if (choice.kind == 'embedded') {
        if (_useNative) {
          final t = await _waitForNativeTextTrack(choice.trackId, epoch);
          if (t == null || stale()) return;
          await _nativeController?.setTextTrack(t);
          _nativeSelectedTextId = t.id;
        } else {
          final t = await _waitForMpvSubtitleTrack(choice.trackId, epoch);
          if (t == null || stale()) return;
          await _pc.player.setSubtitleTrack(t);
        }
      } else {
        final search = SubtitleSearch(_appState.repository.http);
        final srt = await search.fetch(choice.url);
        if (stale()) return;
        if (_useNative) {
          setState(() => _nativeSubtitleCues = parseSubtitle(srt));
          _pc.setExternalSubtitleTitle(choice.lang);
        } else {
          await _pc.loadExternalSubtitle(srt, title: choice.lang);
        }
      }
      // The calibration is part of the choice — restoring the file but
      // forgetting the painstaking sync made "gem valget" feel broken.
      if (choice.offsetSecs != 0 || choice.speed != 1.0) {
        await _pc.applySubtitleTiming(choice.offsetSecs, choice.speed);
      }
    } catch (_) {
      // Best-effort only — see doc comment above.
    }
  }

  /// Polls until the native player has reported its embedded text tracks,
  /// then resolves the saved id — or null if the track no longer exists.
  Future<NativeTrackInfo?> _waitForNativeTextTrack(String? id, int epoch) async {
    for (var i = 0; i < 40; i++) {
      if (!mounted || epoch != _subtitleEpoch) return null;
      final list = _nativeController?.tracks.text ?? const <NativeTrackInfo>[];
      if (list.isNotEmpty) {
        for (final t in list) {
          if (t.id == id) return t;
        }
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  /// Same idea for the mpv path: waits for mpv's track probe to surface real
  /// embedded tracks (the list starts as pseudo 'auto'/'no' only).
  Future<SubtitleTrack?> _waitForMpvSubtitleTrack(String? id, int epoch) async {
    for (var i = 0; i < 40; i++) {
      if (!mounted || epoch != _subtitleEpoch) return null;
      final list = [
        for (final t in _pc.player.state.tracks.subtitle)
          if (t.id != 'auto' && t.id != 'no') t,
      ];
      if (list.isNotEmpty) {
        for (final t in list) {
          if (t.id == id) return t;
        }
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  /// Resolves once the current item has a genuine first position tick (or
  /// hits an error) — mirrors PlaybackController's own "is this actually
  /// playing yet" signal (see _suppressResume there) rather than guessing a
  /// fixed delay. Times out after 8s so a stream that never starts can't
  /// hang the caller forever.
  Future<void> _waitForPlaybackReady() async {
    if (_pc.position > Duration.zero || _pc.hasError) return;
    final completer = Completer<void>();
    void listener() {
      if (_pc.position > Duration.zero || _pc.hasError) {
        if (!completer.isCompleted) completer.complete();
      }
    }

    _pc.addListener(listener);
    try {
      await completer.future.timeout(const Duration(seconds: 8), onTimeout: () {});
    } finally {
      _pc.removeListener(listener);
    }
  }

  Future<void> _searchSubtitles() => _withIdleSuspended(_searchSubtitlesBody);

  Future<void> _searchSubtitlesBody() async {
    final search =
        SubtitleSearch(context.read<AppState>().repository.http);
    // Fetch the list with a progress dialog.
    List<SubtitleResult>? results;
    String? error;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        search
            .search(
          title: _searchTitle!,
          season: _season,
          episode: _episodeNum,
        )
            .then((r) {
          results = r;
          if (dialogContext.mounted) Navigator.pop(dialogContext);
        }).catchError((Object e) {
          error = e.toString().replaceFirst('Exception: ', '');
          if (dialogContext.mounted) Navigator.pop(dialogContext);
        });
        return const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Expanded(child: Text('Søger undertekster…')),
            ],
          ),
        );
      },
    );
    if (!mounted) return;
    if (results == null) {
      _snack(error ?? 'Søgningen mislykkedes.');
      return;
    }

    // Number the alternatives per language ("Dansk 1 af 4") — timing problems
    // are usually a mismatched RELEASE, and the real fix is trying another
    // file for the same language; identical unnumbered rows hid that option.
    final list = results!;
    final totals = <String, int>{};
    for (final r in list) {
      totals[r.langLabel] = (totals[r.langLabel] ?? 0) + 1;
    }
    final seen = <String, int>{};
    final labels = <String>[
      for (final r in list)
        (totals[r.langLabel] ?? 1) > 1
            ? '${r.langLabel} ${seen[r.langLabel] = (seen[r.langLabel] ?? 0) + 1} af ${totals[r.langLabel]}'
            : r.langLabel,
    ];

    // Pick one from the list (grouped by language, preferred first).
    final pickedIndex = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF171C26),
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: list.length + 1,
            itemBuilder: (sheetContext, i) {
              if (i == 0) {
                return const ListTile(
                  title: Text('Undertekster',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(
                      'Passer timingen ikke? Prøv en anden af samme sprog.',
                      style: TextStyle(fontSize: 11)),
                );
              }
              final r = list[i - 1];
              return FocusRing(
                borderRadius: 8,
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.subtitles_outlined, size: 20),
                  title: Text(labels[i - 1]),
                  subtitle: Text(r.lang, style: const TextStyle(fontSize: 11)),
                  onTap: () => Navigator.pop(sheetContext, i - 1),
                ),
              );
            },
          ),
        );
      },
    );
    if (pickedIndex == null || !mounted) return;
    final picked = list[pickedIndex];
    final pickedLabel = labels[pickedIndex];

    try {
      final srt = await search.fetch(picked.url);
      if (!mounted) return;
      _userPickedSubtitle = true;
      if (_useNative) {
        // The native ExoPlayer path never asks mpv/libass to render text
        // tracks — parse the cues ourselves and drive a plain overlay from
        // the position stream instead (see _nativeSubtitleOverlay). An active
        // embedded track would double-draw under it — turn it off.
        unawaited(_nativeController?.disableTextTrack());
        _nativeSelectedTextId = null;
        _nativeEmbeddedCue.value = '';
        setState(() => _nativeSubtitleCues = parseSubtitle(srt));
        _pc.setExternalSubtitleTitle(pickedLabel);
      } else {
        await _pc.loadExternalSubtitle(srt, title: pickedLabel);
      }
      // Remembered per item (movie/episode) so reopening it later — e.g. via
      // "Fortsæt" — silently reloads this same choice instead of requiring
      // the whole search+pick flow again. See _autoLoadSavedSubtitle.
      if (_resumeKey != null) {
        unawaited(_saveSubtitleChoice(
            _resumeKey!, SubtitleChoice(picked.url, pickedLabel)));
      }
      if (mounted) _snack('Undertekster indlæst ($pickedLabel).');
    } catch (e) {
      if (mounted) {
        _snack(e.toString().replaceFirst('Exception: ', ''));
      }
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Every persisted resume/subtitle call from this screen is namespaced by
  /// the source the item was opened FROM (`widget.source`), never by whatever
  /// source happens to be active — they're the same thing for streamed
  /// content, but a downloaded episode from source B played while A is
  /// active used to read and write its progress under A.
  Future<void> _saveSubtitleChoice(String key, SubtitleChoice choice) =>
      _appState.saveSubtitleChoice(key, choice, sourceId: widget.source.id);

  Future<void> _showSleep() => _withIdleSuspended(_showSleepBody);

  Future<void> _showSleepBody() async {
    final choice = await showModalBottomSheet<int?>(
      context: context,
      backgroundColor: const Color(0xFF171C26),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in [15, 30, 45, 60, 90])
              FocusRing(
                borderRadius: 8,
                child: ListTile(
                  dense: true,
                  title: Text('$m minutter'),
                  onTap: () => Navigator.pop(context, m),
                ),
              ),
            FocusRing(
              borderRadius: 8,
              child: ListTile(
                dense: true,
                title: const Text('Slå fra'),
                onTap: () => Navigator.pop(context, 0),
              ),
            ),
          ],
        ),
      ),
    );
    if (choice == null) return;
    _pc.setSleepTimer(choice == 0 ? null : Duration(minutes: choice));
  }

  String _trackLabel(String? title, String? language, String id) {
    final parts = [if (title != null && title.isNotEmpty) title, if (language != null && language.isNotEmpty) language];
    return parts.isEmpty ? 'Spor $id' : parts.join(' · ');
  }

  String? _nowNext(String channelId) {
    final list = _epg[channelId];
    if (list == null || list.isEmpty) return null;
    final nowUtc = DateTime.now().toUtc();
    final current = list.where((e) => e.isLiveAt(nowUtc)).toList();
    if (current.isNotEmpty) {
      final e = current.first;
      return 'Nu: ${e.title}';
    }
    return 'Næste: ${list.first.title}';
  }

  Widget _circleBtn(IconData icon, VoidCallback onTap,
      {bool big = false, FocusNode? focusNode}) {
    return FocusRing(
      shape: BoxShape.circle,
      child: Material(
        color: Colors.white.withValues(alpha: 0.14),
        shape: const CircleBorder(),
        child: InkWell(
          focusNode: focusNode,
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.all(big ? 16 : 12),
            child: Icon(icon, color: Colors.white, size: big ? 34 : 26),
          ),
        ),
      ),
    );
  }

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
