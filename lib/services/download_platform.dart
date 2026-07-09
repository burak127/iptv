// Web-safe facade: real dart:io downloader on native, no-op stub on web.
export 'download_stub.dart' if (dart.library.io) 'download_io.dart';
