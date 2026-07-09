import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'pip_service.dart';

/// True when running on an Android TV / Google TV (leanback) device.
/// Resolved once at startup; UI uses it for 10-foot font/focus/inset ramps.
bool isTvMode = false;

/// When true, the TV player renders the hardware decoder DIRECTLY onto the
/// surface (mpv `vo=mediacodec_embed`) — no per-frame CPU copy, so playback is
/// smooth on weak GPUs. BUT some Amlogic boxes show a black screen (audio only)
/// in this mode, so it's OFF by default and user-toggled per device in Settings.
bool directHwVideo = false;
const String kDirectHwVideoKey = 'direct_hw_video';

/// When true, LIVE playback on Android TV uses a native ExoPlayer + SurfaceView
/// (a hardware overlay, like TiviMate) instead of media_kit's Flutter texture —
/// far smoother on weak Amlogic boxes. Opt-in per device (some boxes/layouts
/// have platform-view quirks). Live only; VOD/subtitles stay on media_kit.
bool nativePlayer = false;
const String kNativePlayerKey = 'native_player';

/// Grandparent-friendly kiosk options.
/// Auto-launch the app when the box boots (read natively by BootReceiver too,
/// via the `flutter.`-prefixed key). Always return to the channel list on
/// turn-on instead of resuming the last-played channel.
bool autoStartOnBoot = false;
const String kAutoStartKey = 'auto_start_on_boot';

/// When true, the app auto-opens the last-watched live channel on startup
/// (instead of landing on the channel list) — nice for a grandparent box.
bool resumeLastChannel = false;
const String kResumeLastKey = 'resume_last_channel';

/// When true, the app registers itself as a HOME/launcher replacement
/// candidate (bulletproof grandparent kiosk — opens on every boot/HOME press,
/// no way to accidentally land elsewhere). OFF by default and only ever
/// enabled on a TV device via Settings — see PipService.setHomeReplacement
/// and AndroidManifest.xml's HomeAlias for why this must be opt-in.
bool homeReplacement = false;
const String kHomeReplacementKey = 'home_replacement';

Future<void> detectTvMode() async {
  try {
    isTvMode = await PipService.isTv()
        .timeout(const Duration(seconds: 2), onTimeout: () => false);
  } catch (_) {
    isTvMode = false;
  }
}

/// Load the persisted "smooth hardware video" preference into [directHwVideo]
/// at startup (before the first player is created, which reads it synchronously).
Future<void> loadVideoPrefs() async {
  try {
    final p = await SharedPreferences.getInstance();
    directHwVideo = p.getBool(kDirectHwVideoKey) ?? false;
    nativePlayer = p.getBool(kNativePlayerKey) ?? false;
    autoStartOnBoot = p.getBool(kAutoStartKey) ?? false;
    resumeLastChannel = p.getBool(kResumeLastKey) ?? false;
    homeReplacement = p.getBool(kHomeReplacementKey) ?? false;
    // Re-apply on every startup — Android may have reset the component's
    // enabled state (e.g. after an app update / OEM ROM component reset), so
    // relying only on the one-time setter call would silently desync from
    // the persisted preference the user actually chose.
    if (homeReplacement) unawaited(PipService.setHomeReplacement(true));
  } catch (_) {
    directHwVideo = false;
    nativePlayer = false;
    autoStartOnBoot = false;
    resumeLastChannel = false;
    homeReplacement = false;
  }
}

Future<void> setAutoStartOnBoot(bool value) async {
  autoStartOnBoot = value;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kAutoStartKey, value);
  } catch (_) {/* best-effort */}
  // BootReceiver's full-screen-intent fallback (needed on Android 10+, which
  // blocks a background BroadcastReceiver from starting an activity directly
  // — confirmed via logcat on a real Android 14 box) can't show anything
  // without POST_NOTIFICATIONS, and a background receiver can't request a
  // runtime permission itself — ask here, in the foreground, while the user
  // is right there turning the feature on.
  if (value) {
    unawaited(PipService.requestNotificationPermission());
  }
}

Future<void> setResumeLastChannel(bool value) async {
  resumeLastChannel = value;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kResumeLastKey, value);
  } catch (_) {/* best-effort */}
}

/// Returns false when the change was refused (turning the toggle OFF while
/// no other launcher is enabled would leave the box with no home screen —
/// the caller should tell the user why nothing happened).
Future<bool> setHomeReplacement(bool value) async {
  final applied = await PipService.setHomeReplacement(value);
  if (!applied) return false;
  homeReplacement = value;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kHomeReplacementKey, value);
  } catch (_) {/* best-effort */}
  return true;
}

/// Persist + apply the "native ExoPlayer" toggle (effective on next open).
Future<void> setNativePlayer(bool value) async {
  nativePlayer = value;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kNativePlayerKey, value);
  } catch (_) {/* best-effort */}
}

/// Persist + apply the "smooth hardware video" toggle. Takes effect the next
/// time a channel/movie is opened (a new player is created).
Future<void> setDirectHwVideo(bool value) async {
  directHwVideo = value;
  try {
    final p = await SharedPreferences.getInstance();
    await p.setBool(kDirectHwVideoKey, value);
  } catch (_) {/* best-effort */}
}
