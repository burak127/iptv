import 'dart:io';

import 'package:window_manager/window_manager.dart';

/// True OS-level fullscreen for the player, native desktop only. Flutter's own
/// SystemChrome immersive modes (used elsewhere for the TV/mobile fullscreen
/// player) only hide the status/nav bars on Android — on Windows/macOS/Linux
/// the app just stays in its normal window, so playing a channel/movie never
/// actually filled the screen without this.
bool get isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<void> enterPlayerFullscreen() async {
  if (!isDesktop) return;
  try {
    await windowManager.ensureInitialized();
    await windowManager.setFullScreen(true);
  } catch (_) {/* best-effort */}
}

Future<void> exitPlayerFullscreen() async {
  if (!isDesktop) return;
  try {
    await windowManager.setFullScreen(false);
  } catch (_) {/* best-effort */}
}
