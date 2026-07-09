// Web-safe facade: real dart:io HTTP server on native, no-op stub on web.
export 'pairing_models.dart';
export 'pairing_stub.dart' if (dart.library.io) 'pairing_io.dart';
