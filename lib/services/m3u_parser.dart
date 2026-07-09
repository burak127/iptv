import 'dart:convert';

import '../models/category.dart';
import '../models/live_channel.dart';

class ParsedPlaylist {
  final List<IptvCategory> categories;
  final List<LiveChannel> channels;
  const ParsedPlaylist(this.categories, this.channels);
}

/// Parses an M3U / M3U8 playlist into live channels grouped by `group-title`.
/// Keeps tvg-id (for EPG) and tvg-chno (channel number).
class M3uParser {
  static ParsedPlaylist parse(String content) {
    // Providers sometimes return an HTML/text error page with HTTP 200
    // (Cloudflare challenge, "account expired" page). Without this check every
    // HTML line would become a junk "Channel" entry — and get cached for 12h.
    if (!content.contains('#EXTINF')) {
      throw Exception(
        'Svaret er ikke en M3U-playliste. Tjek at URL\'en er korrekt '
        '(og at din udbyder ikke blokerer download).',
      );
    }

    final lines = const LineSplitter().convert(content);

    final channels = <LiveChannel>[];
    final categoryNames = <String>{};
    final usedIds = <String>{};

    String? name;
    String? logo;
    String? tvgId;
    String? chno;
    String group = 'Uncategorized';
    var pendingEntry = false;

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTINF')) {
        logo = _attr(line, 'tvg-logo');
        tvgId = _attr(line, 'tvg-id');
        chno = _attr(line, 'tvg-chno');
        final g = _attr(line, 'group-title');
        group = (g != null && g.isNotEmpty) ? g : 'Uncategorized';

        final commaIdx = _nameSeparatorIndex(line);
        name = commaIdx >= 0 ? line.substring(commaIdx + 1).trim() : 'Channel';
        pendingEntry = true;
      } else if (!line.startsWith('#')) {
        // Only a URL-looking line following an #EXTINF is a stream.
        if (!pendingEntry || !_looksLikeUrl(line)) continue;

        categoryNames.add(group);
        channels.add(LiveChannel(
          // Content-derived id (stable when the provider reorders/adds
          // entries) so favorites/recents keep pointing at the same channel.
          id: _stableId(line, usedIds),
          name: (name != null && name.isNotEmpty) ? name : 'Channel',
          categoryId: group,
          logo: logo,
          number: int.tryParse(chno ?? ''),
          epgChannelId: (tvgId != null && tvgId.isNotEmpty) ? tvgId : null,
          directUrl: line,
        ));

        name = null;
        logo = null;
        tvgId = null;
        chno = null;
        group = 'Uncategorized';
        pendingEntry = false;
      }
    }

    if (channels.isEmpty) {
      throw Exception('Ingen kanaler fundet i playlisten.');
    }

    final categories = categoryNames
        .map((n) => IptvCategory(id: n, name: n))
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return ParsedPlaylist(categories, channels);
  }

  static bool _looksLikeUrl(String line) =>
      line.contains('://') || line.startsWith('rtp:') || line.startsWith('udp:');

  /// Deterministic FNV-1a hash of the stream URL (Dart's String.hashCode is
  /// not guaranteed stable across runs). Duplicate URLs get a suffix.
  static String _stableId(String url, Set<String> used) {
    var h = 0x811c9dc5;
    for (final unit in url.codeUnits) {
      h ^= unit;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    var id = 'ch_${h.toRadixString(16)}';
    var n = 1;
    while (!used.add(id)) {
      id = 'ch_${h.toRadixString(16)}_${n++}';
    }
    return id;
  }

  static String? _attr(String line, String key) {
    final match = RegExp('$key="([^"]*)"').firstMatch(line);
    return match?.group(1);
  }

  /// First comma NOT inside a quoted attribute value — keeps names with commas.
  static int _nameSeparatorIndex(String line) {
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final c = line[i];
      if (c == '"') {
        inQuotes = !inQuotes;
      } else if (c == ',' && !inQuotes) {
        return i;
      }
    }
    return -1;
  }
}
