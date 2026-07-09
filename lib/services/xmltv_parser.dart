import '../models/guide_entry.dart';
import 'epg_time.dart';

/// Input for the isolate: the raw XMLTV document plus the retention window
/// (epoch ms) so huge files boil down to a few days of programmes.
class XmltvParseRequest {
  final String xml;
  final int windowStartMs;
  final int windowEndMs;
  const XmltvParseRequest(this.xml, this.windowStartMs, this.windowEndMs);
}

/// Parses XMLTV into per-channel programme lists. Top-level so it can run in a
/// background isolate via compute() — panel files are routinely tens of MB.
Map<String, List<Map<String, dynamic>>> parseXmltv(XmltvParseRequest req) {
  final windowStart =
      DateTime.fromMillisecondsSinceEpoch(req.windowStartMs, isUtc: true);
  final windowEnd =
      DateTime.fromMillisecondsSinceEpoch(req.windowEndMs, isUtc: true);

  final byChannel = <String, List<Map<String, dynamic>>>{};

  final programmeRe = RegExp(
    r'<programme\s+([^>]*)>(.*?)</programme>',
    dotAll: true,
  );
  final attrRe = RegExp(r'(start|stop|channel)="([^"]*)"');
  final titleRe = RegExp(r'<title[^>]*>(.*?)</title>', dotAll: true);
  final descRe = RegExp(r'<desc[^>]*>(.*?)</desc>', dotAll: true);

  for (final m in programmeRe.allMatches(req.xml)) {
    final attrs = <String, String>{};
    for (final a in attrRe.allMatches(m.group(1)!)) {
      attrs[a.group(1)!] = a.group(2)!;
    }
    final startRaw = attrs['start'];
    final stopRaw = attrs['stop'];
    final channel = attrs['channel']?.toLowerCase().trim();
    if (startRaw == null || stopRaw == null || channel == null || channel.isEmpty) {
      continue;
    }

    final start = EpgTime.fromXmltv(startRaw);
    final end = EpgTime.fromXmltv(stopRaw);
    if (start == null || end == null) continue;
    if (end.isBefore(windowStart) || start.isAfter(windowEnd)) continue;

    final body = m.group(2)!;
    final title = _decodeEntities(titleRe.firstMatch(body)?.group(1) ?? '').trim();
    if (title.isEmpty) continue;
    final desc = descRe.firstMatch(body)?.group(1);

    (byChannel[channel] ??= []).add(GuideEntry(
      title: title,
      description: desc == null ? null : _decodeEntities(desc).trim(),
      startUtc: start,
      endUtc: end,
      timeshiftStart: _timeshiftFormat(startRaw),
    ).toJson());
  }

  // Chronological order per channel.
  for (final list in byChannel.values) {
    list.sort((a, b) => (a['s'] as int).compareTo(b['s'] as int));
  }
  return byChannel;
}

/// 'YYYYMMDDHHMMSS +ZZZZ' → 'YYYY-MM-DD:HH-MM' (panel-local, as timeshift wants).
String _timeshiftFormat(String xmltvStamp) {
  final s = xmltvStamp.trim();
  if (s.length < 12) return '';
  return '${s.substring(0, 4)}-${s.substring(4, 6)}-${s.substring(6, 8)}'
      ':${s.substring(8, 10)}-${s.substring(10, 12)}';
}

String _decodeEntities(String s) => s
    .replaceAll('<![CDATA[', '')
    .replaceAll(']]>', '')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&#39;', "'");
