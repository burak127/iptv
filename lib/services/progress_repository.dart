import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A recently-watched entry (enough to render a card + navigate back to it).
class RecentEntry {
  final String kind; // 'live' | 'vod' | 'series'
  final String id;
  final String name;
  final String? image;
  final int updatedAtMs;

  const RecentEntry({
    required this.kind,
    required this.id,
    required this.name,
    this.image,
    required this.updatedAtMs,
  });

  Map<String, dynamic> toJson() =>
      {'kind': kind, 'id': id, 'name': name, 'image': image, 'ts': updatedAtMs};

  factory RecentEntry.fromJson(Map<String, dynamic> j) => RecentEntry(
        kind: j['kind'] as String,
        id: j['id'] as String,
        name: j['name'] as String,
        image: j['image'] as String?,
        updatedAtMs: j['ts'] as int? ?? 0,
      );
}

class ResumePoint {
  final int positionSecs;
  final int durationSecs;
  const ResumePoint(this.positionSecs, this.durationSecs);

  double get fraction =>
      durationSecs <= 0 ? 0 : (positionSecs / durationSecs).clamp(0.0, 1.0);
}

/// An external subtitle the user picked for a specific movie/episode —
/// remembered so reopening that same item later (e.g. via "Fortsæt") can
/// silently reload it instead of starting the search from scratch every time.
class SubtitleChoice {
  final String url;
  final String lang; // display label, e.g. "Dansk"
  const SubtitleChoice(this.url, this.lang);
}

/// Favorites, recently-watched, resume positions and the parental PIN. Small
/// values only — backed by shared_preferences, keyed per source where relevant.
class ProgressRepository {
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // ---- Favorites (per source) ----
  String _favKey(String sourceId) => 'fav_$sourceId';

  Future<Set<String>> favorites(String sourceId) async {
    final p = await _prefs;
    return (p.getStringList(_favKey(sourceId)) ?? const []).toSet();
  }

  Future<void> toggleFavorite(String sourceId, String itemKey) async {
    final p = await _prefs;
    final list = (p.getStringList(_favKey(sourceId)) ?? const []).toList();
    if (!list.remove(itemKey)) list.add(itemKey);
    await p.setStringList(_favKey(sourceId), list);
  }

  // ---- Hidden categories (per source, per content kind) ----
  // 'live' keeps the original key for backwards compatibility.
  String _hiddenCatsKey(String sourceId, String kind) =>
      kind == 'live' ? 'hiddencats_$sourceId' : 'hiddencats_${kind}_$sourceId';

  Future<Set<String>> hiddenCategories(String sourceId,
      {String kind = 'live'}) async {
    final p = await _prefs;
    return (p.getStringList(_hiddenCatsKey(sourceId, kind)) ?? const []).toSet();
  }

  Future<void> setHiddenCategories(String sourceId, Set<String> ids,
      {String kind = 'live'}) async {
    final p = await _prefs;
    if (ids.isEmpty) {
      await p.remove(_hiddenCatsKey(sourceId, kind));
    } else {
      await p.setStringList(_hiddenCatsKey(sourceId, kind), ids.toList());
    }
  }

  // ---- Custom live-category order (per source) ----
  String _catOrderKey(String sourceId) => 'catorder_$sourceId';

  Future<List<String>> categoryOrder(String sourceId) async {
    final p = await _prefs;
    return p.getStringList(_catOrderKey(sourceId)) ?? const [];
  }

  Future<void> setCategoryOrder(String sourceId, List<String> ids) async {
    final p = await _prefs;
    if (ids.isEmpty) {
      await p.remove(_catOrderKey(sourceId));
    } else {
      await p.setStringList(_catOrderKey(sourceId), ids);
    }
  }

  // ---- Recently watched (per source, newest first, capped) ----
  String _recentKey(String sourceId) => 'recent_$sourceId';

  Future<List<RecentEntry>> recents(String sourceId) async {
    final p = await _prefs;
    final raw = p.getString(_recentKey(sourceId));
    if (raw == null) return const [];
    try {
      final list = (jsonDecode(raw) as List)
          .map((e) => RecentEntry.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      list.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<void> pushRecent(String sourceId, RecentEntry entry) async {
    final p = await _prefs;
    final current = await recents(sourceId);
    final deduped = current.where((e) => !(e.kind == entry.kind && e.id == entry.id)).toList();
    deduped.insert(0, entry);
    final capped = deduped.take(30).toList();
    await p.setString(
        _recentKey(sourceId), jsonEncode(capped.map((e) => e.toJson()).toList()));
  }

  // ---- Resume positions (per source) ----
  String _resumeKey(String sourceId) => 'resume_$sourceId';

  Future<Map<String, ResumePoint>> _resumeMap(String sourceId) async {
    final p = await _prefs;
    final raw = p.getString(_resumeKey(sourceId));
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(
          k, ResumePoint((v['p'] as num).toInt(), (v['d'] as num).toInt())));
    } catch (_) {
      return {};
    }
  }

  Future<ResumePoint?> resume(String sourceId, String itemKey) async {
    final m = await _resumeMap(sourceId);
    return m[itemKey];
  }

  Future<void> setResume(
      String sourceId, String itemKey, int positionSecs, int durationSecs) async {
    final p = await _prefs;
    final m = await _resumeMap(sourceId);
    // Drop near-finished items so they don't clutter Continue Watching.
    if (durationSecs > 0 && positionSecs > durationSecs - 30) {
      m.remove(itemKey);
    } else {
      m[itemKey] = ResumePoint(positionSecs, durationSecs);
    }
    await p.setString(_resumeKey(sourceId),
        jsonEncode(m.map((k, v) => MapEntry(k, {'p': v.positionSecs, 'd': v.durationSecs}))));
  }

  // ---- Subtitle choice (per source, per item) ----
  String _subtitleKey(String sourceId) => 'subtitle_$sourceId';

  Future<Map<String, SubtitleChoice>> _subtitleMap(String sourceId) async {
    final p = await _prefs;
    final raw = p.getString(_subtitleKey(sourceId));
    if (raw == null) return {};
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(
          k, SubtitleChoice(v['url'] as String, v['lang'] as String)));
    } catch (_) {
      return {};
    }
  }

  Future<SubtitleChoice?> subtitleChoice(String sourceId, String itemKey) async {
    final m = await _subtitleMap(sourceId);
    return m[itemKey];
  }

  Future<void> setSubtitleChoice(
      String sourceId, String itemKey, String url, String lang) async {
    final p = await _prefs;
    final m = await _subtitleMap(sourceId);
    m[itemKey] = SubtitleChoice(url, lang);
    await p.setString(_subtitleKey(sourceId),
        jsonEncode(m.map((k, v) => MapEntry(k, {'url': v.url, 'lang': v.lang}))));
  }

  Future<void> clearSubtitleChoice(String sourceId, String itemKey) async {
    final p = await _prefs;
    final m = await _subtitleMap(sourceId);
    if (m.remove(itemKey) == null) return;
    await p.setString(_subtitleKey(sourceId),
        jsonEncode(m.map((k, v) => MapEntry(k, {'url': v.url, 'lang': v.lang}))));
  }

  /// Delete every persisted key belonging to a removed source.
  Future<void> purgeSource(String sourceId) async {
    final p = await _prefs;
    await p.remove(_favKey(sourceId));
    await p.remove(_recentKey(sourceId));
    await p.remove(_resumeKey(sourceId));
    await p.remove(_subtitleKey(sourceId));
    await p.remove(_catOrderKey(sourceId));
    await p.remove(_hiddenCatsKey(sourceId, 'live'));
    await p.remove(_hiddenCatsKey(sourceId, 'vod'));
    await p.remove(_hiddenCatsKey(sourceId, 'series'));
  }

  // ---- Parental PIN (global, hashed) ----
  static const _pinKey = 'parental_pin_sha256';

  Future<bool> hasPin() async => (await _prefs).getString(_pinKey) != null;

  Future<void> setPin(String pin) async {
    final p = await _prefs;
    await p.setString(_pinKey, _hash(pin));
  }

  Future<void> clearPin() async {
    final p = await _prefs;
    await p.remove(_pinKey);
  }

  Future<bool> checkPin(String pin) async {
    final p = await _prefs;
    final stored = p.getString(_pinKey);
    return stored != null && stored == _hash(pin);
  }

  String _hash(String pin) => sha256.convert(utf8.encode('iptv:$pin')).toString();
}
