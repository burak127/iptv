// Web-safe facade: uses the dart:io file implementation on native platforms and
// a no-op stub on web (dart:io / path_provider are unavailable there).
export 'cache_models.dart';
export 'cache_store_stub.dart' if (dart.library.io) 'cache_store_io.dart';
