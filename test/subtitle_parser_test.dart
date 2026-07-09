import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/services/subtitle_parser.dart';

void main() {
  group('parseSubtitle (SRT)', () {
    test('parses basic cues with comma-millisecond timestamps', () {
      const srt = '1\n'
          '00:00:01,000 --> 00:00:04,000\n'
          'Hello world\n'
          '\n'
          '2\n'
          '00:00:05,500 --> 00:00:07,000\n'
          'Second line\n'
          'with two rows\n';
      final cues = parseSubtitle(srt);
      expect(cues, hasLength(2));
      expect(cues[0].start, const Duration(seconds: 1));
      expect(cues[0].end, const Duration(seconds: 4));
      expect(cues[0].text, 'Hello world');
      expect(cues[1].text, 'Second line\nwith two rows');
    });

    test('strips styling tags', () {
      const srt = '1\n00:00:00,000 --> 00:00:02,000\n<i>Italic</i> and <b>bold</b>\n';
      final cues = parseSubtitle(srt);
      expect(cues.single.text, 'Italic and bold');
    });

    test('handles hour component', () {
      const srt = '1\n01:02:03,500 --> 01:02:05,000\nLate in the file\n';
      final cues = parseSubtitle(srt);
      expect(cues.single.start, const Duration(hours: 1, minutes: 2, seconds: 3, milliseconds: 500));
    });

    test('skips malformed blocks without a timing line', () {
      const srt = 'Not a subtitle file at all, just some text.\n\nMore junk.';
      expect(parseSubtitle(srt), isEmpty);
    });

    test('sorts out-of-order blocks', () {
      const srt = '2\n00:00:10,000 --> 00:00:11,000\nLater\n'
          '\n'
          '1\n00:00:01,000 --> 00:00:02,000\nEarlier\n';
      final cues = parseSubtitle(srt);
      expect(cues.map((c) => c.text).toList(), ['Earlier', 'Later']);
    });
  });

  group('parseSubtitle (WebVTT)', () {
    test('strips the WEBVTT header and dot-millisecond timestamps', () {
      const vtt = 'WEBVTT\n'
          'Kind: captions\n'
          '\n'
          '00:00:01.000 --> 00:00:04.000\n'
          'Hello from VTT\n';
      final cues = parseSubtitle(vtt);
      expect(cues, hasLength(1));
      expect(cues.single.start, const Duration(seconds: 1));
      expect(cues.single.text, 'Hello from VTT');
    });

    test('ignores trailing cue-settings on the timing line', () {
      const vtt = 'WEBVTT\n\n'
          '00:00:01.000 --> 00:00:04.000 align:start position:10%\n'
          'Positioned cue\n';
      final cues = parseSubtitle(vtt);
      expect(cues.single.text, 'Positioned cue');
    });

    test('handles minute:second-only timestamps (no hour component)', () {
      const vtt = 'WEBVTT\n\n00:01.500 --> 00:03.000\nShort form\n';
      final cues = parseSubtitle(vtt);
      expect(cues.single.start, const Duration(seconds: 1, milliseconds: 500));
    });
  });

  group('activeCue', () {
    final cues = [
      const SubtitleCue(
        start: Duration(seconds: 1),
        end: Duration(seconds: 3),
        text: 'First',
      ),
      const SubtitleCue(
        start: Duration(seconds: 5),
        end: Duration(seconds: 7),
        text: 'Second',
      ),
    ];

    test('returns the cue containing the position', () {
      expect(activeCue(cues, const Duration(seconds: 2))?.text, 'First');
      expect(activeCue(cues, const Duration(seconds: 6))?.text, 'Second');
    });

    test('returns null in the gap between cues', () {
      expect(activeCue(cues, const Duration(seconds: 4)), isNull);
    });

    test('returns null before the first and after the last cue', () {
      expect(activeCue(cues, Duration.zero), isNull);
      expect(activeCue(cues, const Duration(seconds: 10)), isNull);
    });

    test('end boundary is exclusive', () {
      expect(activeCue(cues, const Duration(seconds: 3)), isNull);
    });
  });
}
