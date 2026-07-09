/// One programme in the full EPG guide. [timeshiftStart] is the start time
/// exactly as the panel emitted it ('YYYY-MM-DD:HH-MM'), which is what the
/// Xtream timeshift URL expects for catch-up.
class GuideEntry {
  final String title;
  final String? description;
  final DateTime startUtc;
  final DateTime endUtc;
  final String timeshiftStart;

  const GuideEntry({
    required this.title,
    this.description,
    required this.startUtc,
    required this.endUtc,
    required this.timeshiftStart,
  });

  int get durationMinutes => endUtc.difference(startUtc).inMinutes;

  bool isLiveAt(DateTime nowUtc) =>
      !nowUtc.isBefore(startUtc) && nowUtc.isBefore(endUtc);

  Map<String, dynamic> toJson() => {
        't': title,
        'd': description,
        's': startUtc.millisecondsSinceEpoch,
        'e': endUtc.millisecondsSinceEpoch,
        'x': timeshiftStart,
      };

  factory GuideEntry.fromJson(Map<String, dynamic> j) => GuideEntry(
        title: j['t'] as String,
        description: j['d'] as String?,
        startUtc:
            DateTime.fromMillisecondsSinceEpoch(j['s'] as int, isUtc: true),
        endUtc: DateTime.fromMillisecondsSinceEpoch(j['e'] as int, isUtc: true),
        timeshiftStart: j['x'] as String? ?? '',
      );
}
