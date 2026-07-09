import 'dart:convert';

import 'http_client.dart';
import 'gzip_stub.dart' if (dart.library.io) 'gzip_io.dart';
import 'json_util.dart';

/// One downloadable subtitle option.
class SubtitleResult {
  final String lang; // ISO code, e.g. 'dan', 'eng'
  final String langLabel; // human label, e.g. 'Dansk'
  final String url;
  const SubtitleResult({required this.lang, required this.langLabel, required this.url});
}

/// Finds external subtitles for a movie / series episode without API keys:
/// 1. Cinemeta (Stremio's public catalog) resolves the title to an IMDb id.
/// 2. The public OpenSubtitles v3 addon lists .srt URLs per language.
/// Everything is best-effort — callers show a friendly message on failure.
class SubtitleSearch {
  SubtitleSearch(this.http);
  final IptvHttpClient http;

  static const _langLabels = <String, String>{
    'dan': 'Dansk', 'da': 'Dansk',
    'eng': 'Engelsk', 'en': 'Engelsk',
    'tur': 'Tyrkisk', 'tr': 'Tyrkisk',
    'ara': 'Arabisk', 'ar': 'Arabisk',
    'ger': 'Tysk', 'de': 'Tysk', 'deu': 'Tysk',
    'fre': 'Fransk', 'fr': 'Fransk', 'fra': 'Fransk',
    'spa': 'Spansk', 'es': 'Spansk',
    'swe': 'Svensk', 'sv': 'Svensk',
    'nor': 'Norsk', 'no': 'Norsk',
  };

  /// Preferred ordering — Danish and Turkish first for this household.
  static const _langPriority = ['dan', 'da', 'tur', 'tr', 'eng', 'en'];

  /// Strip provider noise ("FR - Name (2025)" → "Name (2025)") so the catalog
  /// search actually matches.
  static String cleanTitle(String raw) {
    var t = raw.trim();
    t = t.replaceFirst(RegExp(r'^[A-Z]{2,3}\s*[-|:]\s*'), '');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  Future<List<SubtitleResult>> search({
    required String title,
    int? season,
    int? episode,
  }) async {
    final type = season != null ? 'series' : 'movie';
    final q = Uri.encodeComponent(cleanTitle(title));

    // 1) title → IMDb id
    final meta = await http.getJson(
      Uri.parse('https://v3-cinemeta.strem.io/catalog/$type/top/search=$q.json'),
      timeout: const Duration(seconds: 12),
    );
    final metas = (meta is Map) ? asList(meta['metas']) : const [];
    String? imdbId;
    for (final m in metas) {
      final id = (m is Map) ? asStringOrNull(m['id']) : null;
      if (id != null && id.startsWith('tt')) {
        imdbId = id;
        break;
      }
    }
    if (imdbId == null) {
      throw Exception('Kunne ikke finde titlen i kataloget.');
    }

    // 2) IMDb id → subtitle list
    final subId = season != null ? '$imdbId:$season:$episode' : imdbId;
    final data = await http.getJson(
      Uri.parse('https://opensubtitles-v3.strem.io/subtitles/$type/$subId.json'),
      timeout: const Duration(seconds: 15),
    );
    final subs = (data is Map) ? asList(data['subtitles']) : const [];
    final results = <SubtitleResult>[];
    for (final s in subs) {
      if (s is! Map) continue;
      final url = asStringOrNull(s['url']);
      final lang = (asStringOrNull(s['lang']) ?? '').toLowerCase();
      if (url == null || url.isEmpty) continue;
      results.add(SubtitleResult(
        lang: lang,
        langLabel: _langLabels[lang] ?? lang.toUpperCase(),
        url: url,
      ));
    }
    if (results.isEmpty) {
      throw Exception('Ingen undertekster fundet til denne titel.');
    }

    // Preferred languages first, stable within groups.
    int rank(String l) {
      final i = _langPriority.indexOf(l);
      return i < 0 ? _langPriority.length : i;
    }

    results.sort((a, b) => rank(a.lang).compareTo(rank(b.lang)));
    return results;
  }

  /// Download a subtitle file and return its text (handles gzip payloads and
  /// non-UTF-8 encodings leniently).
  Future<String> fetch(String url) async {
    final res = await http.getRaw(
      Uri.parse(url),
      timeout: const Duration(seconds: 20),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Kunne ikke hente underteksten (HTTP ${res.statusCode}).');
    }
    List<int> bytes = res.bodyBytes;
    // Some mirrors serve raw .gz payloads.
    if (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
      final unzipped = gunzip(bytes);
      if (unzipped == null) {
        throw Exception('Undertekst-formatet understøttes ikke her.');
      }
      bytes = unzipped;
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    if (!text.contains('-->')) {
      // Neither SRT nor VTT timing markers — probably an error page.
      throw Exception('Filen ligner ikke en undertekst.');
    }
    return text;
  }
}
