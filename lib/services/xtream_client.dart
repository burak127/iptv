import 'dart:convert';

import '../models/category.dart';
import '../models/epg.dart';
import '../models/iptv_source.dart';
import '../models/live_channel.dart';
import '../models/movie.dart';
import '../models/series.dart';
import 'epg_time.dart';
import 'http_client.dart';
import 'json_util.dart';
import 'stream_url_builder.dart';

class XtreamUserInfo {
  final bool authorized;
  final int maxConnections;
  final int activeConnections;
  final DateTime? expiry;
  final String status;
  const XtreamUserInfo({
    required this.authorized,
    this.maxConnections = 1,
    this.activeConnections = 0,
    this.expiry,
    this.status = '',
  });
}

/// Xtream Codes API client: live, VOD, series, short-EPG. All requests go
/// through the shared [IptvHttpClient] (VLC UA + timeout + retry).
class XtreamClient {
  XtreamClient(this.source, this.http);
  final IptvSource source;
  final IptvHttpClient http;

  String get _host => normalizeHost(source.host!);
  String? get _ua => source.userAgent;

  Uri _api(Map<String, String> params) =>
      Uri.parse('$_host/player_api.php').replace(queryParameters: {
        'username': source.username ?? '',
        'password': source.password ?? '',
        ...params,
      });

  Future<XtreamUserInfo> authenticate() async {
    final data = await http.getJson(_api(const {}), userAgent: _ua);
    final info = (data is Map) ? data['user_info'] : null;
    final auth = (info is Map) ? info['auth'] : null;
    final ok = auth == 1 || auth == '1';
    if (info is! Map || !ok) {
      throw Exception('Forkert brugernavn eller adgangskode.');
    }
    final expUnix = asIntOrNull(info['exp_date']);
    return XtreamUserInfo(
      authorized: true,
      maxConnections: asIntOrNull(info['max_connections']) ?? 1,
      activeConnections: asIntOrNull(info['active_cons']) ?? 0,
      expiry: (expUnix != null && expUnix > 0)
          ? DateTime.fromMillisecondsSinceEpoch(expUnix * 1000, isUtc: true)
          : null,
      status: asString(info['status']),
    );
  }

  // ---- Live ----
  Future<List<IptvCategory>> getLiveCategories() =>
      _categories('get_live_categories');

  Future<List<LiveChannel>> getLiveStreams() async {
    final data = await http.getJson(
      _api(const {'action': 'get_live_streams'}),
      userAgent: _ua,
      timeout: const Duration(seconds: 40),
    );
    return asList(data)
        .whereType<Map>()
        .map((m) => LiveChannel(
              id: asString(m['stream_id']),
              name: asString(m['name'], 'Kanal'),
              categoryId: asString(m['category_id'], kUncategorizedId),
              logo: asStringOrNull(m['stream_icon']),
              number: asIntOrNull(m['num']),
              epgChannelId: asStringOrNull(m['epg_channel_id']),
              tvArchive: asBool(m['tv_archive']),
              tvArchiveDuration: asIntOrNull(m['tv_archive_duration']) ?? 0,
            ))
        .where((c) => c.id.isNotEmpty)
        .toList();
  }

  // ---- VOD ----
  Future<List<IptvCategory>> getVodCategories() =>
      _categories('get_vod_categories');

  Future<List<Movie>> getVodStreams() async {
    final data = await http.getJson(
      _api(const {'action': 'get_vod_streams'}),
      userAgent: _ua,
      timeout: const Duration(seconds: 40),
    );
    return asList(data)
        .whereType<Map>()
        .map((m) => Movie(
              id: asString(m['stream_id']),
              name: asString(m['name'], 'Film'),
              categoryId: asString(m['category_id'], kUncategorizedId),
              poster: asStringOrNull(m['stream_icon']) ?? asStringOrNull(m['cover']),
              containerExtension: asStringOrNull(m['container_extension']),
              rating: asDoubleOrNull(m['rating']),
              year: asStringOrNull(m['year']),
            ))
        .where((m) => m.id.isNotEmpty)
        .toList();
  }

  Future<Movie> getVodInfo(Movie base) async {
    final data =
        await http.getJson(_api({'action': 'get_vod_info', 'vod_id': base.id}), userAgent: _ua);
    final info = (data is Map) ? data['info'] : null;
    final movieData = (data is Map) ? data['movie_data'] : null;
    if (info is! Map) return base;
    return base.copyWith(
      plot: asStringOrNull(info['plot'] ?? info['description']),
      cast: asStringOrNull(info['cast'] ?? info['actors']),
      director: asStringOrNull(info['director']),
      genre: asStringOrNull(info['genre']),
      year: asStringOrNull(info['releasedate'] ?? info['year']),
      rating: asDoubleOrNull(info['rating']),
      durationSecs: asIntOrNull(info['duration_secs']),
      containerExtension:
          asStringOrNull((movieData is Map) ? movieData['container_extension'] : null),
    );
  }

  // ---- Series ----
  Future<List<IptvCategory>> getSeriesCategories() =>
      _categories('get_series_categories');

  Future<List<Series>> getSeriesList() async {
    final data = await http.getJson(
      _api(const {'action': 'get_series'}),
      userAgent: _ua,
      timeout: const Duration(seconds: 40),
    );
    return asList(data)
        .whereType<Map>()
        .map((m) => Series(
              id: asString(m['series_id']),
              name: asString(m['name'], 'Serie'),
              categoryId: asString(m['category_id'], kUncategorizedId),
              poster: asStringOrNull(m['cover']),
              plot: asStringOrNull(m['plot']),
              cast: asStringOrNull(m['cast']),
              director: asStringOrNull(m['director']),
              genre: asStringOrNull(m['genre']),
              year: asStringOrNull(m['releaseDate'] ?? m['year']),
              rating: asDoubleOrNull(m['rating']),
            ))
        .where((s) => s.id.isNotEmpty)
        .toList();
  }

  Future<List<Season>> getSeriesInfo(String seriesId) async {
    final data = await http
        .getJson(_api({'action': 'get_series_info', 'series_id': seriesId}), userAgent: _ua);
    final episodesRaw = (data is Map) ? data['episodes'] : null;
    final seasons = <Season>[];
    if (episodesRaw is Map) {
      final keys = episodesRaw.keys.toList()
        ..sort((a, b) => (int.tryParse('$a') ?? 0).compareTo(int.tryParse('$b') ?? 0));
      for (final k in keys) {
        final seasonNum = int.tryParse('$k') ?? 0;
        final eps = asList(episodesRaw[k])
            .whereType<Map>()
            .map((m) {
              final info = (m['info'] is Map) ? m['info'] as Map : const {};
              return Episode(
                id: asString(m['id']),
                title: asString(m['title'], 'Afsnit ${asString(m['episode_num'])}'),
                seasonNumber: asIntOrNull(m['season']) ?? seasonNum,
                episodeNumber: asIntOrNull(m['episode_num']) ?? 0,
                containerExtension: asStringOrNull(m['container_extension']),
                plot: asStringOrNull(info['plot']),
                poster: asStringOrNull(info['movie_image']),
                durationSecs: asIntOrNull(info['duration_secs']),
              );
            })
            .where((e) => e.id.isNotEmpty)
            .toList();
        if (eps.isNotEmpty) seasons.add(Season(number: seasonNum, episodes: eps));
      }
    }
    return seasons;
  }

  // ---- EPG ----
  Future<List<EpgEntry>> getShortEpg(String streamId, {int limit = 2}) async {
    final data = await http.getJson(
      _api({'action': 'get_short_epg', 'stream_id': streamId, 'limit': '$limit'}),
      userAgent: _ua,
      timeout: const Duration(seconds: 10),
    );
    final listings = (data is Map) ? data['epg_listings'] : null;
    return asList(listings)
        .whereType<Map>()
        .map((m) {
          final start = EpgTime.fromXtream(
              isoish: asStringOrNull(m['start']),
              unixTimestamp: asIntOrNull(m['start_timestamp']));
          final end = EpgTime.fromXtream(
              isoish: asStringOrNull(m['end']),
              unixTimestamp: asIntOrNull(m['stop_timestamp']));
          if (start == null || end == null) return null;
          return EpgEntry(
            title: _b64(asStringOrNull(m['title'])) ?? 'Program',
            description: _b64(asStringOrNull(m['description'])),
            startUtc: start,
            endUtc: end,
          );
        })
        .whereType<EpgEntry>()
        .toList();
  }

  Future<List<IptvCategory>> _categories(String action) async {
    final data = await http.getJson(_api({'action': action}), userAgent: _ua);
    return asList(data)
        .whereType<Map>()
        .map((m) => IptvCategory(
              id: asString(m['category_id']),
              name: asString(m['category_name'], 'Ukendt'),
            ))
        .where((c) => c.id.isNotEmpty)
        .toList();
  }

  /// Xtream EPG titles are base64 on some panels and plaintext on others.
  /// Only decode when the string genuinely looks like base64 AND decodes to
  /// clean UTF-8 without control-char garbage; otherwise return it verbatim.
  static String? _b64(String? s) {
    if (s == null) return null;
    final raw = s.trim();
    if (raw.isEmpty) return null;
    if (!RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(raw)) return raw;
    try {
      final decoded = utf8.decode(base64.decode(base64.normalize(raw)));
      final hasControl = decoded.runes.any(
        (r) => r < 0x20 && r != 0x09 && r != 0x0a && r != 0x0d,
      );
      return hasControl ? raw : decoded;
    } catch (_) {
      return raw;
    }
  }
}
