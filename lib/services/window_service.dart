// Web-safe facade: uses the real window_manager-backed implementation on
// native desktop platforms and a no-op stub everywhere else (web, and
// Android/iOS where "OS window fullscreen" isn't a meaningful concept —
// gated inside window_service_io.dart itself).
export 'window_service_stub.dart' if (dart.library.io) 'window_service_io.dart';
