/// A single EPG programme entry. Times are always stored in UTC; render local.
class EpgEntry {
  final String title;
  final String? description;
  final DateTime startUtc;
  final DateTime endUtc;

  const EpgEntry({
    required this.title,
    this.description,
    required this.startUtc,
    required this.endUtc,
  });

  bool isLiveAt(DateTime nowUtc) =>
      !nowUtc.isBefore(startUtc) && nowUtc.isBefore(endUtc);

  /// 0..1 progress through the programme at [nowUtc].
  double progressAt(DateTime nowUtc) {
    final total = endUtc.difference(startUtc).inSeconds;
    if (total <= 0) return 0;
    final elapsed = nowUtc.difference(startUtc).inSeconds;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => {
        'title': title,
        'description': description,
        'startUtc': startUtc.toUtc().toIso8601String(),
        'endUtc': endUtc.toUtc().toIso8601String(),
      };

  factory EpgEntry.fromJson(Map<String, dynamic> j) => EpgEntry(
        title: j['title'] as String,
        description: j['description'] as String?,
        startUtc: DateTime.parse(j['startUtc'] as String).toUtc(),
        endUtc: DateTime.parse(j['endUtc'] as String).toUtc(),
      );
}
