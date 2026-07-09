import 'cache_models.dart';

/// Web fallback — no filesystem cache (dart:io/path_provider unavailable).
class CacheStore {
  Future<void> write(String key, Object data) async {}
  Future<CachedBlob?> read(String key) async => null;
  Future<void> remove(String key) async {}
  Future<void> clear() async {}
}
