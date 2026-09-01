import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/services/stream_url_builder.dart';
import 'package:iptv_player/services/subtitle_search.dart';
import 'package:iptv_player/services/xtream_client.dart';

void main() {
  group('SubtitleSearch.cleanTitle', () {
    test('strips provider prefixes separated by - or |', () {
      expect(SubtitleSearch.cleanTitle('FR - Heat (1995)'), 'Heat (1995)');
      expect(SubtitleSearch.cleanTitle('EN | Friends'), 'Friends');
      expect(SubtitleSearch.cleanTitle('DK- Borgen'), 'Borgen');
    });

    test('keeps real titles that contain a colon', () {
      // A ":" separator used to turn these into "Miami" / "Chapter Two".
      expect(SubtitleSearch.cleanTitle('CSI: Miami'), 'CSI: Miami');
      expect(SubtitleSearch.cleanTitle('IT: Chapter Two'), 'IT: Chapter Two');
      expect(SubtitleSearch.cleanTitle('MIB: International'),
          'MIB: International');
    });

    test('collapses whitespace', () {
      expect(SubtitleSearch.cleanTitle('  The   Office '), 'The Office');
    });
  });

  group('normalizeUrlScheme / normalizeHost', () {
    test('adds http:// when missing', () {
      expect(normalizeUrlScheme('server.com:8080'), 'http://server.com:8080');
      expect(normalizeHost('server.com/'), 'http://server.com');
    });

    test('accepts a capitalised scheme from a phone keyboard', () {
      expect(normalizeUrlScheme('Http://server.com'), 'http://server.com');
      expect(normalizeUrlScheme('HTTPS://server.com'), 'https://server.com');
      expect(normalizeHost('Http://server.com:8080/'), 'http://server.com:8080');
    });

    test('leaves a correct scheme untouched', () {
      expect(normalizeUrlScheme('https://a.b/c?d=e'), 'https://a.b/c?d=e');
    });
  });

  group('XtreamClient.decodeEpgText', () {
    test('short plain titles are returned verbatim, not decoded', () {
      for (final t in ['Kids', 'WWE', 'News', 'Nyheder', 'Sport1']) {
        expect(XtreamClient.decodeEpgText(t), t, reason: t);
      }
    });

    test('genuine base64 decodes', () {
      // "Aftenshowet med Danmark" — a realistic padded panel payload.
      expect(XtreamClient.decodeEpgText('QWZ0ZW5zaG93ZXQgbWVkIERhbm1hcms='),
          'Aftenshowet med Danmark');
      expect(XtreamClient.decodeEpgText('U8O4bmRhZ3NuYXR0ZW4='), 'Søndagsnatten');
    });

    test('text with spaces or punctuation is passed through', () {
      expect(XtreamClient.decodeEpgText('Tour de France 2026'),
          'Tour de France 2026');
      expect(XtreamClient.decodeEpgText(''), isNull);
      expect(XtreamClient.decodeEpgText(null), isNull);
    });
  });
}
