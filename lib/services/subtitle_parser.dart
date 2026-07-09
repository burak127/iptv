/// One timed subtitle line, ready to display.
class SubtitleCue {
  const SubtitleCue({required this.start, required this.end, required this.text});
  final Duration start;
  final Duration end;
  final String text;
}

/// Parses raw SRT or WebVTT text into timed cues.
///
/// Needed only for the native-ExoPlayer on-demand path (TV, "Native
/// afspiller" on): that path bypasses mpv/libass entirely, so nothing else in
/// the app parses subtitle timing — [PlaybackController.loadExternalSubtitle]
/// on the normal media_kit path hands mpv the raw text and lets libass do
/// this internally instead. Here we own it, rendering cues as a plain-text
/// overlay driven by the native player's position stream.
List<SubtitleCue> parseSubtitle(String raw) {
  // Normalize line endings and strip a WebVTT header block (everything up to
  // the first blank line, e.g. "WEBVTT\nKind: captions\n\n...").
  var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n').trim();
  if (text.startsWith('WEBVTT')) {
    final firstBlank = text.indexOf('\n\n');
    text = firstBlank >= 0 ? text.substring(firstBlank + 2) : '';
  }

  final cues = <SubtitleCue>[];
  for (final block in text.split(RegExp(r'\n\s*\n'))) {
    final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final timingIndex = lines.indexWhere((l) => l.contains('-->'));
    if (timingIndex < 0) continue;

    final match = _timingPattern.firstMatch(lines[timingIndex]);
    if (match == null) continue;
    final start = _parseTimestamp(match.group(1)!);
    final end = _parseTimestamp(match.group(2)!);
    if (start == null || end == null) continue;

    final textLines = lines.sublist(timingIndex + 1);
    if (textLines.isEmpty) continue;
    final cueText = textLines.join('\n').replaceAll(_tagPattern, '').trim();
    if (cueText.isEmpty) continue;

    cues.add(SubtitleCue(start: start, end: end, text: cueText));
  }
  // Blocks aren't guaranteed to already be chronological (rare, but seen in
  // the wild with hand-edited/merged files) — the caller does a position
  // lookup that assumes ordering.
  cues.sort((a, b) => a.start.compareTo(b.start));
  return cues;
}

/// Matches both SRT ("00:00:01,000") and VTT ("00:00:01.000" or "00:01.000",
/// hours optional) timestamps, plus any trailing VTT cue-settings on the
/// timing line ("align:start position:10%").
final RegExp _timingPattern = RegExp(
  r'((?:\d+:)?\d{2}:\d{2}[.,]\d{3})\s*-->\s*((?:\d+:)?\d{2}:\d{2}[.,]\d{3})',
);

/// Strips HTML-ish styling tags (`<i>`, `<b>`, `<font ...>`) and ASS-style
/// position overrides (`{\an8}`) sometimes embedded in subtitle text — this
/// is a plain Text overlay, not a styled renderer.
final RegExp _tagPattern = RegExp(r'<[^>]*>|\{\\[^}]*\}');

Duration? _parseTimestamp(String raw) {
  final parts = raw.replaceAll(',', '.').split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  try {
    final secAndMs = parts.last.split('.');
    final seconds = int.parse(secAndMs[0]);
    final millis = secAndMs.length > 1 ? int.parse(secAndMs[1].padRight(3, '0').substring(0, 3)) : 0;
    final minutes = int.parse(parts[parts.length - 2]);
    final hours = parts.length == 3 ? int.parse(parts[0]) : 0;
    return Duration(hours: hours, minutes: minutes, seconds: seconds, milliseconds: millis);
  } catch (_) {
    return null;
  }
}

/// Finds the cue active at [position] (already includes any user delay
/// offset), or null between/outside cues. Cues are sorted by [parseSubtitle],
/// so this could binary-search, but subtitle lists are small (hundreds, not
/// thousands) and this runs once per position tick — linear scan is plenty.
SubtitleCue? activeCue(List<SubtitleCue> cues, Duration position) {
  for (final cue in cues) {
    if (position >= cue.start && position < cue.end) return cue;
    if (cue.start > position) break; // sorted — nothing further can match
  }
  return null;
}
