import '../models/epg.dart';
import '../models/guide_entry.dart';

/// Xtream's server_info is usable even when a channel has no EPG at all.
Duration? archiveServerClockOffset(String? localClock, int? unixSeconds) {
  if (localClock == null || unixSeconds == null || unixSeconds <= 0 ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}$')
          .hasMatch(localClock)) {
    return null;
  }
  final wall = DateTime.tryParse('${localClock.replaceFirst(' ', 'T')}Z');
  if (wall == null) return null;
  final absolute = DateTime.fromMillisecondsSinceEpoch(
      unixSeconds * 1000, isUtc: true);
  final offset = wall.difference(absolute);
  return offset.abs() <= const Duration(hours: 14) ? offset : null;
}

/// Xtream timeshift uses the panel's wall clock, not a UTC timestamp. Its
/// short-EPG response supplies both the local clock and an absolute epoch.
Duration? archiveClockOffset(Iterable<EpgEntry> entries) {
  for (final entry in entries) {
    final raw = entry.serverStart?.trim();
    if (raw == null ||
        !RegExp(r'^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}$')
            .hasMatch(raw)) {
      continue;
    }
    final wall = DateTime.tryParse('${raw.replaceFirst(' ', 'T')}Z');
    if (wall == null) continue;
    final offset = wall.difference(entry.startUtc);
    if (offset.abs() <= const Duration(hours: 14)) return offset;
  }
  return null;
}

/// XMLTV is a fallback for panels whose short EPG omits unix timestamps.
/// Pick the entry closest to the requested archive start, so an overnight DST
/// change does not apply today's UTC offset to yesterday's recording.
Duration? archiveGuideClockOffset(
    Iterable<GuideEntry> entries, DateTime targetUtc) {
  GuideEntry? nearest;
  for (final entry in entries) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}:\d{2}-\d{2}$')
        .hasMatch(entry.timeshiftStart)) {
      continue;
    }
    if (nearest == null ||
        (entry.startUtc.difference(targetUtc)).abs() <
            (nearest.startUtc.difference(targetUtc)).abs()) {
      nearest = entry;
    }
  }
  if (nearest == null) return null;
  final raw = nearest.timeshiftStart;
  final wall = DateTime.tryParse(
      '${raw.substring(0, 10)}T${raw.substring(11, 13)}:${raw.substring(14, 16)}Z');
  if (wall == null) return null;
  final offset = wall.difference(nearest.startUtc);
  return offset.abs() <= const Duration(hours: 14) ? offset : null;
}

/// Format an absolute UTC instant as the panel-local Xtream timeshift path.
String archiveStart(DateTime utc, Duration panelOffset) {
  final wall = utc.toUtc().add(panelOffset);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${wall.year}-${two(wall.month)}-${two(wall.day)}:'
      '${two(wall.hour)}-${two(wall.minute)}';
}
