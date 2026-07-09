import 'package:shared_preferences/shared_preferences.dart';

import '../models/iptv_source.dart';

/// Persists saved sources + which one is active, using shared_preferences.
class SourceRepository {
  static const _kSources = 'iptv_sources';
  static const _kActiveId = 'iptv_active_source_id';

  Future<List<IptvSource>> loadSources() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSources);
    if (raw == null || raw.isEmpty) return [];
    try {
      return IptvSource.decodeList(raw);
    } catch (_) {
      return [];
    }
  }

  Future<void> saveSources(List<IptvSource> sources) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSources, IptvSource.encodeList(sources));
  }

  Future<String?> loadActiveId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kActiveId);
  }

  Future<void> saveActiveId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_kActiveId);
    } else {
      await prefs.setString(_kActiveId, id);
    }
  }
}
