import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Picture-in-picture bridge to MainActivity. Best-effort: every call is a
/// no-op on web / platforms without the channel.
class PipService {
  static const _ch = MethodChannel('iptv/pip');

  /// True while the activity is in picture-in-picture mode.
  static final ValueNotifier<bool> inPip = ValueNotifier(false);

  static bool _handlerSet = false;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'pipChanged') {
        inPip.value = call.arguments == true;
      }
    });
  }

  static Future<bool> isSupported() async {
    if (kIsWeb) return false;
    _ensureHandler();
    try {
      return await _ch.invokeMethod<bool>('isSupported') == true;
    } catch (_) {
      return false;
    }
  }

  /// True on Android TV / Google TV (leanback devices).
  static Future<bool> isTv() async {
    if (kIsWeb) return false;
    _ensureHandler();
    try {
      return await _ch.invokeMethod<bool>('isTv') == true;
    } catch (_) {
      return false;
    }
  }

  /// While enabled, pressing home enters PiP instead of pausing playback.
  static Future<void> setAutoPip(bool enabled) async {
    if (kIsWeb) return;
    _ensureHandler();
    try {
      await _ch.invokeMethod('setAutoPip', enabled);
    } catch (_) {/* channel unavailable */}
  }

  static Future<bool> enterPip() async {
    if (kIsWeb) return false;
    _ensureHandler();
    try {
      return await _ch.invokeMethod<bool>('enterPip') == true;
    } catch (_) {
      return false;
    }
  }

  /// Flips the disabled-by-default HOME/launcher-replacement component on or
  /// off (grandparent kiosk mode). Opt-in only — see AndroidManifest.xml's
  /// HomeAlias for why this must never be a static, always-on capability.
  ///
  /// Returns false when the native side REFUSED the change — currently only
  /// one case: disabling the alias while no other launcher is enabled on the
  /// device, which would leave the box with no home screen at all.
  static Future<bool> setHomeReplacement(bool enabled) async {
    if (kIsWeb) return true;
    _ensureHandler();
    try {
      return await _ch.invokeMethod<bool>('setHomeReplacement', enabled) ?? true;
    } catch (_) {
      return true; // channel unavailable (non-Android) — nothing to refuse
    }
  }

  /// Whether POST_NOTIFICATIONS (a runtime permission on Android 13+) is
  /// granted — needed by BootReceiver's full-screen-intent fallback for
  /// "Start automatisk" (see MainActivity.kt). True on older Android/other
  /// platforms where it isn't required at all.
  static Future<bool> hasNotificationPermission() async {
    if (kIsWeb) return true;
    _ensureHandler();
    try {
      return await _ch.invokeMethod<bool>('hasNotificationPermission') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Shows the system permission dialog if not already granted. Returns the
  /// resulting grant state (or true immediately if already granted / not
  /// required on this Android version).
  static Future<bool> requestNotificationPermission() async {
    if (kIsWeb) return true;
    _ensureHandler();
    try {
      return await _ch.invokeMethod<bool>('requestNotificationPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Android 14 added a separate gate on top of POST_NOTIFICATIONS
  /// specifically for full-screen-intent notifications. True on every
  /// earlier Android version (not applicable there).
  static Future<bool> canUseFullScreenIntent() async {
    if (kIsWeb) return true;
    _ensureHandler();
    try {
      return await _ch.invokeMethod<bool>('canUseFullScreenIntent') ?? true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the exact Android 14 settings screen for granting the
  /// full-screen-intent permission — a background receiver can't request
  /// this itself, so Settings offers a direct link when it's missing.
  static Future<void> openFullScreenIntentSettings() async {
    if (kIsWeb) return;
    _ensureHandler();
    try {
      await _ch.invokeMethod('openFullScreenIntentSettings');
    } catch (_) {/* channel unavailable */}
  }
}
