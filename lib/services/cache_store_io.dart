import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:path_provider/path_provider.dart';

import 'cache_models.dart';

// Top-level so they can run in a background isolate via compute().
dynamic _decodeJson(String source) => jsonDecode(source);
String _encodeJson(Object data) => jsonEncode(data);

/// JSON-file disk cache under the app support dir. One file per key; each holds
/// {fetchedAt, data}. All operations swallow errors — cache is best-effort.
class CacheStore {
  Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/iptv_cache');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> write(String key, Object data) async {
    try {
      final d = await _dir();
      final f = File('${d.path}/$key.json');
      // Serialize the (possibly multi-MB) blob off the UI isolate.
      final encoded = await compute(_encodeJson, {
        'fetchedAt': DateTime.now().millisecondsSinceEpoch,
        'data': data,
      });
      // Write to a temp file, then atomically rename over the target. Writing
      // straight to `f` truncates the previous good cache first — a process kill
      // mid-write would then leave a corrupt file AND destroy the last valid
      // one, breaking the offline fallback. rename() on the same dir is atomic.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      await tmp.rename(f.path);
    } catch (_) {/* best-effort */}
  }

  Future<CachedBlob?> read(String key) async {
    try {
      final d = await _dir();
      final f = File('${d.path}/$key.json');
      if (!await f.exists()) return null;
      // Decode the (possibly multi-MB) blob off the UI isolate.
      final content = await f.readAsString();
      final m = (await compute(_decodeJson, content)) as Map<String, dynamic>;
      return CachedBlob(
        m['data'],
        DateTime.fromMillisecondsSinceEpoch(m['fetchedAt'] as int),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(String key) async {
    try {
      final d = await _dir();
      final f = File('${d.path}/$key.json');
      if (await f.exists()) await f.delete();
    } catch (_) {/* best-effort */}
  }

  Future<void> clear() async {
    try {
      final d = await _dir();
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {/* best-effort */}
  }
}
