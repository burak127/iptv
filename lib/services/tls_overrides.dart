// Web-safe facade: dart:io HttpOverrides on native, no-op on web.
export 'tls_overrides_stub.dart' if (dart.library.io) 'tls_overrides_io.dart';
