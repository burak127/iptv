import 'dart:io';

/// Native gzip decode; null when the payload isn't valid gzip.
List<int>? gunzip(List<int> bytes) {
  try {
    return gzip.decode(bytes);
  } catch (_) {
    return null;
  }
}
