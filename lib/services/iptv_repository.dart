import 'package:flutter/foundation.dart' show compute;

import '../models/category.dart';
import '../models/epg.dart';
import '../models/guide_entry.dart';
import '../models/iptv_source.dart';
import '../models/live_channel.dart';
import '../models/movie.dart';
import '../models/series.dart';
import 'cache_store.dart';
import 'http_client.dart';
import 'm3u_parser.dart';
import 'stream_url_builder.dart';
import 'xmltv_parser.dart';
import 'xtream_client.dart';

// Top-level helpers so compute() can rehydrate cached blobs in a background
// isolate. On a warm cache these build tens of thousands (guide: hundreds of
// thousands) of model objects on app start — on the UI isolate that froze the
// D-pad for up to seconds every launch.
Map<String, dynamic> _castMap(dynamic e) => (e as Map).cast<String, dynamic>();

Map<String, List<GuideEntry>> _guideModelsFromRaw(dynamic data) {
  final m = data as Map;
  return m.map((k, v) => MapEntry(
        k.toString(),
        (v as List).map((e) => GuideEntry.fromJson(_castMap(e))).toList(),
      ));
}

LiveData _liveModelsFromRaw(dynamic data) {
  final m = data as Map;
  return LiveData(
    (m['categories'] as List).map((e) => IptvCategory.fromJson(_castMap(e))).toList(),
    (m['channels'] as List).map((e) => LiveChannel.fromJson(_castMap(e))).toList(),
  );
}

VodData _vodModelsFromRaw(dynamic data) {
  final m = data as Map;
  return VodData(
    (m['categories'] as List).map((e) => IptvCategory.fromJson(_castMap(e))).toList(),
    (m['movies'] as List).map((e) => Movie.fromJson(_castMap(e))).toList(),
  );
}

SeriesData _seriesModelsFromRaw(dynamic data) {
  final m = data as Map;
  return SeriesData(
    (m['categories'] as List).map((e) => IptvCategory.fromJson(_castMap(e))).toList(),
    (m['series'] as List).map((e) => Series.fromJson(_castMap(e))).toList(),
  );
}

class LiveData {
  final List<IptvCategory> categories;
  final List<LiveChannel> channels;
  const LiveData(this.categories, this.channels);
}

class VodData {
  final List<IptvCategory> categories;
  final List<Movie> movies;
  const VodData(this.categories, this.movies);
}

class SeriesData {
  final List<IptvCategory> categories;
  final List<Series> series;
  const SeriesData(this.categories, this.series);
}

/// Loads catalogs cache-first with stale-while-revalidate. On a network error a
/// stale cache (any age) is returned so the app still opens offline.
class IptvRepository {
  IptvRepository({IptvHttpClient? httpClient, CacheStore? cache})
      : http = httpClient ?? IptvHttpClient(),
        _cache = cache ?? CacheStore();

  final IptvHttpClient http;
  final CacheStore _cache;

  static const _ttl = Duration(hours: 12);

  XtreamClient _xtream(IptvSource s) => XtreamClient(s, http);

  /// Append the synthetic "Ukategoriseret" category when any item points at it
  /// (panels return null/empty category_id for some content).
  static List<IptvCategory> _withUncategorized(
      List<IptvCategory> cats, Iterable<String> itemCategoryIds) {
    if (!itemCategoryIds.contains(kUncategorizedId)) return cats;
    if (cats.any((c) => c.id == kUncategorizedId)) return cats;
    return [...cats, const IptvCategory(id: kUncategorizedId, name: 'Ukategoriseret')];
  }

  // ---------------- LIVE ----------------
  Future<LiveData> loadLive(IptvSource s, {bool forceRefresh = false}) async {
    final key = '${s.id}_live';
    if (!forceRefresh) {
      final c = await _cache.read(key);
      if (c != null && c.age < _ttl) return compute(_liveModelsFromRaw, c.data);
    }
    try {
      final data = await _fetchLive(s);
      await _cache.write(key, {
        'categories': data.categories.map((e) => e.toJson()).toList(),
        'channels': data.channels.map((e) => e.toJson()).toList(),
      });
      return data;
    } catch (e) {
      // Fall back to stale cache only for a normal (non-forced) load, so a
      // user-initiated refresh surfaces the error instead of faking success.
      if (!forceRefresh) {
        final c = await _cache.read(key);
        if (c != null) return compute(_liveModelsFromRaw, c.data);
      }
      rethrow;
    }
  }

  Future<LiveData> _fetchLive(IptvSource s) async {
    if (s.isXtream) {
      final x = _xtream(s);
      await x.authenticate();
      final cats = await x.getLiveCategories();
      final chans = await x.getLiveStreams();
      return LiveData(
        _withUncategorized(cats, chans.map((c) => c.categoryId)),
        chans,
      );
    }
    // Full provider playlists are routinely tens of MB — give the download a
    // generous timeout and parse OFF the UI isolate so the app doesn't freeze.
    final body = await http.getText(
      Uri.parse(s.m3uUrl!),
      userAgent: s.userAgent,
      timeout: const Duration(seconds: 120),
    );
    final parsed = await compute(M3uParser.parse, body);
    if (parsed.channels.isEmpty) {
      throw Exception('Ingen kanaler fundet i playlisten.');
    }
    return LiveData(parsed.categories, parsed.channels);
  }

  // ---------------- VOD (Xtream only) ----------------
  Future<VodData> loadVod(IptvSource s, {bool forceRefresh = false}) async {
    final key = '${s.id}_vod';
    if (!forceRefresh) {
      final c = await _cache.read(key);
      if (c != null && c.age < _ttl) return compute(_vodModelsFromRaw, c.data);
    }
    try {
      final x = _xtream(s);
      final rawCats = await x.getVodCategories();
      final movies = await x.getVodStreams();
      final cats = _withUncategorized(rawCats, movies.map((m) => m.categoryId));
      await _cache.write(key, {
        'categories': cats.map((e) => e.toJson()).toList(),
        'movies': movies.map((e) => e.toJson()).toList(),
      });
      return VodData(cats, movies);
    } catch (e) {
      if (!forceRefresh) {
        final c = await _cache.read(key);
        if (c != null) return compute(_vodModelsFromRaw, c.data);
      }
      rethrow;
    }
  }

  // ---------------- SERIES (Xtream only) ----------------
  Future<SeriesData> loadSeries(IptvSource s, {bool forceRefresh = false}) async {
    final key = '${s.id}_series';
    if (!forceRefresh) {
      final c = await _cache.read(key);
      if (c != null && c.age < _ttl) return compute(_seriesModelsFromRaw, c.data);
    }
    try {
      final x = _xtream(s);
      final rawCats = await x.getSeriesCategories();
      final series = await x.getSeriesList();
      final cats = _withUncategorized(rawCats, series.map((e) => e.categoryId));
      await _cache.write(key, {
        'categories': cats.map((e) => e.toJson()).toList(),
        'series': series.map((e) => e.toJson()).toList(),
      });
      return SeriesData(cats, series);
    } catch (e) {
      if (!forceRefresh) {
        final c = await _cache.read(key);
        if (c != null) return compute(_seriesModelsFromRaw, c.data);
      }
      rethrow;
    }
  }

  // ---------------- Full guide (XMLTV) ----------------
  /// Per-EPG-channel-id programme lists covering roughly -3..+2 days.
  Future<Map<String, List<GuideEntry>>> loadGuide(
    IptvSource s, {
    bool forceRefresh = false,
  }) async {
    final key = '${s.id}_guide';
    if (!forceRefresh) {
      final c = await _cache.read(key);
      if (c != null && c.age < const Duration(hours: 6)) {
        return compute(_guideModelsFromRaw, c.data);
      }
    }
    try {
      final url = Uri.parse('${normalizeHost(s.host!)}/xmltv.php').replace(
        queryParameters: {
          'username': s.username ?? '',
          'password': s.password ?? '',
        },
      );
      // Guide files are routinely tens of MB.
      final body = await http.getText(
        url,
        userAgent: s.userAgent,
        timeout: const Duration(seconds: 180),
      );
      if (!body.contains('<programme')) {
        throw Exception('Udbyderen leverer ingen programguide (XMLTV).');
      }
      final now = DateTime.now().toUtc();
      final parsed = await compute(
        parseXmltv,
        XmltvParseRequest(
          body,
          now.subtract(const Duration(days: 3)).millisecondsSinceEpoch,
          now.add(const Duration(days: 2)).millisecondsSinceEpoch,
        ),
      );
      if (parsed.isEmpty) {
        throw Exception('Programguiden var tom.');
      }
      await _cache.write(key, parsed);
      return compute(_guideModelsFromRaw, parsed);
    } catch (e) {
      if (!forceRefresh) {
        final c = await _cache.read(key);
        if (c != null) return compute(_guideModelsFromRaw, c.data);
      }
      rethrow;
    }
  }

  // ---------------- Detail / EPG pass-throughs ----------------
  Future<Movie> movieInfo(IptvSource s, Movie m) => _xtream(s).getVodInfo(m);

  Future<List<Season>> seriesInfo(IptvSource s, String seriesId) =>
      _xtream(s).getSeriesInfo(seriesId);

  Future<List<EpgEntry>> shortEpg(IptvSource s, String streamId) =>
      _xtream(s).getShortEpg(streamId);

  Future<void> clearCache() => _cache.clear();

  /// Delete all cached catalogs for a removed source.
  Future<void> purgeSource(String sourceId) async {
    await _cache.remove('${sourceId}_live');
    await _cache.remove('${sourceId}_vod');
    await _cache.remove('${sourceId}_series');
    await _cache.remove('${sourceId}_guide');
  }

  void dispose() => http.close();
}
