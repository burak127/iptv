/// Parses the assorted timestamp shapes IPTV backends return into UTC. Always
/// prefer the unix timestamp (unambiguous UTC); fall back to string parsing.
class EpgTime {
  /// Xtream get_short_epg gives `start`/`end` ("YYYY-MM-DD HH:MM:SS", server
  /// local) plus `start_timestamp`/`stop_timestamp` (unix seconds, UTC).
  static DateTime? fromXtream({String? isoish, int? unixTimestamp}) {
    if (unixTimestamp != null && unixTimestamp > 0) {
      return DateTime.fromMillisecondsSinceEpoch(unixTimestamp * 1000, isUtc: true);
    }
    if (isoish != null && isoish.trim().isNotEmpty) {
      final normalized = isoish.trim().replaceFirst(' ', 'T');
      // Treat as UTC (best-effort when no offset/timestamp is provided).
      return DateTime.tryParse('${normalized}Z') ??
          DateTime.tryParse(normalized)?.toUtc();
    }
    return null;
  }

  /// XMLTV format: `YYYYMMDDHHMMSS +ZZZZ` (offset optional).
  static DateTime? fromXmltv(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.length < 14) return null;
    try {
      final year = int.parse(s.substring(0, 4));
      final month = int.parse(s.substring(4, 6));
      final day = int.parse(s.substring(6, 8));
      final hour = int.parse(s.substring(8, 10));
      final minute = int.parse(s.substring(10, 12));
      final second = int.parse(s.substring(12, 14));

      // Optional " +ZZZZ" / " -ZZZZ" offset.
      var offset = Duration.zero;
      final tz = s.substring(14).trim();
      if (tz.length >= 5 && (tz[0] == '+' || tz[0] == '-')) {
        final sign = tz[0] == '-' ? -1 : 1;
        final oh = int.parse(tz.substring(1, 3));
        final om = int.parse(tz.substring(3, 5));
        offset = Duration(hours: sign * oh, minutes: sign * om);
      }
      final asUtc = DateTime.utc(year, month, day, hour, minute, second);
      return asUtc.subtract(offset);
    } catch (_) {
      return null;
    }
  }
}
