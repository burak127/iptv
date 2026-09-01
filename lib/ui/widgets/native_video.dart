import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// An ExoPlayer playback error, classified as [transient] (a network/IO
/// hiccup worth retrying) or permanent (malformed stream, missing codec/DRM
/// support — retrying the identical source will never succeed).
class NativeVideoError {
  const NativeVideoError(this.code, this.transient);
  final String code;
  final bool transient;
}

/// A position/duration tick pushed from the native player — used to drive an
/// on-demand seek bar, resume persistence and subtitle-cue timing, mirroring
/// what media_kit's `Player.stream.position`/`.duration` give the mpv path.
class NativeVideoPosition {
  const NativeVideoPosition(this.position, this.duration);
  final Duration position;
  final Duration duration;
}

/// One embedded track inside the stream container, as reported by ExoPlayer's
/// onTracksChanged — [group]/[track] are the indexes the selection commands
/// take, `"$group:$track"` is the stable persistence key (see SubtitleChoice).
class NativeTrackInfo {
  const NativeTrackInfo({
    required this.group,
    required this.track,
    this.language,
    this.label,
    this.selected = false,
  });
  final int group;
  final int track;
  final String? language;
  final String? label;
  final bool selected;

  String get id => '$group:$track';
}

/// The embedded text + audio track lists pushed on every onTracksChanged.
class NativeTracks {
  const NativeTracks({this.text = const [], this.audio = const []});
  final List<NativeTrackInfo> text;
  final List<NativeTrackInfo> audio;
}

/// Controls a single native ExoPlayer instance over its per-view MethodChannel.
class NativeVideoController {
  NativeVideoController._(int id)
      : _channel = MethodChannel('iptv/native_video_$id') {
    _channel.setMethodCallHandler(_onCall);
  }

  final MethodChannel _channel;
  final StreamController<String> _state = StreamController<String>.broadcast();
  final StreamController<NativeVideoError> _error =
      StreamController<NativeVideoError>.broadcast();
  final StreamController<NativeVideoPosition> _position =
      StreamController<NativeVideoPosition>.broadcast();
  final StreamController<double> _aspectRatio = StreamController<double>.broadcast();
  final StreamController<NativeTracks> _tracks =
      StreamController<NativeTracks>.broadcast();
  final StreamController<String> _cues = StreamController<String>.broadcast();

  /// "buffering" | "ready" | "ended" | "idle".
  Stream<String> get stateStream => _state.stream;
  Stream<NativeVideoError> get errorStream => _error.stream;
  Stream<NativeVideoPosition> get positionStream => _position.stream;

  /// Embedded track lists (text + audio), re-pushed on every change.
  Stream<NativeTracks> get tracksStream => _tracks.stream;

  /// Currently-displayed embedded cue text, pushed by ExoPlayer AT display
  /// time (perfect sync, no Dart-side timing). Empty string = nothing shown.
  Stream<String> get cuesStream => _cues.stream;

  /// Last pushed track lists — so UI opened after the push still sees them.
  NativeTracks tracks = const NativeTracks();
  /// Display aspect ratio (width/height, already folding in non-square
  /// pixels) — a SurfaceView always stretches to fill its own bounds with no
  /// "fit" concept of its own, so the caller uses this to do the actual
  /// contain/cover/fill sizing on the Flutter side (FittedBox+SizedBox), the
  /// same approach already used for the media_kit path.
  Stream<double> get aspectRatioStream => _aspectRatio.stream;

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'state':
        if (!_state.isClosed) _state.add(call.arguments as String? ?? 'idle');
        break;
      case 'error':
        if (_error.isClosed) break;
        final args = call.arguments;
        if (args is Map) {
          _error.add(NativeVideoError(
            args['code'] as String? ?? 'error',
            args['transient'] as bool? ?? true,
          ));
        } else {
          _error.add(NativeVideoError(args as String? ?? 'error', true));
        }
        break;
      case 'position':
        if (_position.isClosed) break;
        final args = call.arguments;
        if (args is Map) {
          final posMs = (args['position'] as num?)?.toInt() ?? 0;
          final durMs = (args['duration'] as num?)?.toInt() ?? 0;
          _position.add(NativeVideoPosition(
            Duration(milliseconds: posMs),
            Duration(milliseconds: durMs),
          ));
        }
        break;
      case 'videoSize':
        if (_aspectRatio.isClosed) break;
        final args = call.arguments;
        if (args is Map) {
          final ratio = (args['aspectRatio'] as num?)?.toDouble();
          if (ratio != null && ratio > 0) _aspectRatio.add(ratio);
        }
        break;
      case 'tracks':
        if (_tracks.isClosed) break;
        final args = call.arguments;
        if (args is Map) {
          List<NativeTrackInfo> parse(dynamic raw) => [
                for (final t in (raw is List ? raw : const []))
                  if (t is Map)
                    NativeTrackInfo(
                      group: (t['group'] as num?)?.toInt() ?? 0,
                      track: (t['track'] as num?)?.toInt() ?? 0,
                      language: t['language'] as String?,
                      label: t['label'] as String?,
                      selected: t['selected'] as bool? ?? false,
                    ),
              ];
          tracks = NativeTracks(
            text: parse(args['text']),
            audio: parse(args['audio']),
          );
          _tracks.add(tracks);
        }
        break;
      case 'cues':
        if (!_cues.isClosed) _cues.add(call.arguments as String? ?? '');
        break;
    }
  }

  Future<void> setSource(String url, {String? userAgent, Duration? startAt}) {
    // The old item's track lists are stale the moment a new source is set —
    // a saved-subtitle restore that polled [tracks] right after next-episode
    // resolved the PREVIOUS episode's group/track indexes and selected a
    // wrong (or no) track on the new one. Cleared here; ExoPlayer re-pushes
    // the real lists via onTracksChanged once the new item is prepared.
    tracks = const NativeTracks();
    if (!_tracks.isClosed) _tracks.add(tracks);
    return _channel.invokeMethod('setSource', {
      'url': url,
      if (userAgent != null) 'userAgent': userAgent,
      if (startAt != null && startAt > Duration.zero)
        'startPositionMs': startAt.inMilliseconds,
    }).catchError((_) {});
  }
  Future<void> seekTo(Duration position) => _channel
      .invokeMethod('seekTo', {'position': position.inMilliseconds}).catchError((_) {});
  Future<void> play() => _channel.invokeMethod('play').catchError((_) {});
  Future<void> pause() => _channel.invokeMethod('pause').catchError((_) {});
  Future<void> stop() => _channel.invokeMethod('stop').catchError((_) {});
  Future<void> setTextTrack(NativeTrackInfo t) => _channel.invokeMethod(
      'setTextTrack', {'group': t.group, 'track': t.track}).catchError((_) {});
  Future<void> disableTextTrack() =>
      _channel.invokeMethod('disableTextTrack').catchError((_) {});
  Future<void> setAudioTrack(NativeTrackInfo t) => _channel.invokeMethod(
      'setAudioTrack', {'group': t.group, 'track': t.track}).catchError((_) {});

  void dispose() {
    _channel.setMethodCallHandler(null);
    _state.close();
    _error.close();
    _position.close();
    _aspectRatio.close();
    _tracks.close();
    _cues.close();
  }
}

typedef NativeVideoCreated = void Function(NativeVideoController controller);

/// Hosts a native ExoPlayer + SurfaceView (hardware overlay) via hybrid
/// composition. The video is composited by SurfaceFlinger as its own plane —
/// NOT copied into a Flutter texture — so it stays smooth on weak TV boxes.
class NativeVideo extends StatefulWidget {
  const NativeVideo({
    super.key,
    required this.url,
    required this.userAgent,
    this.startAt,
    this.onCreated,
  });

  final String url;
  final String userAgent;
  /// Resume offset for whatever [url] currently points at — ignored for live
  /// (always null there). Applied on the initial open AND on every later
  /// [url] change, so switching to an adjacent movie picks up that movie's
  /// own saved position. The caller is responsible for clearing it when the
  /// new item should genuinely start at 0 (next-episode does exactly that —
  /// see PlaybackController.openOnDemand, which resets `pendingStartAt` per
  /// item from the `startAt` it was handed).
  final Duration? startAt;
  final NativeVideoCreated? onCreated;

  @override
  State<NativeVideo> createState() => _NativeVideoState();
}

class _NativeVideoState extends State<NativeVideo> {
  NativeVideoController? _controller;

  @override
  void didUpdateWidget(NativeVideo old) {
    super.didUpdateWidget(old);
    // Zapping to another channel, or advancing to the next episode: just hand
    // the new URL to the running player (no teardown of the platform view).
    // The resume offset MUST ride along — dropping it here meant "switch movie
    // like a channel" always restarted the next film from 0:00 on the native
    // TV path, silently discarding the saved position _playAdjacentMovie had
    // just looked up and handed to openOnDemand.
    if (old.url != widget.url) {
      _controller?.setSource(widget.url,
          userAgent: widget.userAgent, startAt: widget.startAt);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const viewType = 'iptv/native_video';
    final creationParams = <String, dynamic>{
      'url': widget.url,
      'userAgent': widget.userAgent,
      if (widget.startAt != null && widget.startAt! > Duration.zero)
        'startPositionMs': widget.startAt!.inMilliseconds,
    };
    return PlatformViewLink(
      viewType: viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        );
      },
      onCreatePlatformView: (params) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: creationParams,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        )
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..addOnPlatformViewCreatedListener((id) {
            final c = NativeVideoController._(id);
            _controller = c;
            widget.onCreated?.call(c);
          })
          ..create();
        return controller;
      },
    );
  }
}
