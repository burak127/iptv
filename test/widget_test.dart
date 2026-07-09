import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/models/iptv_source.dart';
import 'package:iptv_player/services/m3u_parser.dart';

void main() {
  group('xtreamFromM3uUrl', () {
    test('converts a get.php link with embedded credentials', () {
      final s = IptvSource.xtreamFromM3uUrl(
        id: '1',
        name: 'Tv',
        url:
            'http://line.example.ru/get.php?username=abc12&password=xyz9&type=m3u_plus&output=ts',
      );
      expect(s, isNotNull);
      expect(s!.type, SourceType.xtream);
      expect(s.host, 'http://line.example.ru');
      expect(s.username, 'abc12');
      expect(s.password, 'xyz9');
    });

    test('keeps a custom port', () {
      final s = IptvSource.xtreamFromM3uUrl(
        id: '1',
        name: 'x',
        url: 'http://srv.example.com:8080/get.php?username=u&password=p',
      );
      expect(s!.host, 'http://srv.example.com:8080');
    });

    test('returns null for a plain playlist link', () {
      final s = IptvSource.xtreamFromM3uUrl(
        id: '1',
        name: 'x',
        url: 'https://iptv-org.github.io/iptv/index.m3u',
      );
      expect(s, isNull);
    });
  });

  group('M3uParser', () {
    test('parses channels and their groups', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 tvg-id="id1" tvg-logo="http://logo/1.png" group-title="News",CNN\n'
          'http://server/cnn.m3u8\n'
          '#EXTINF:-1 group-title="Movies",HBO\n'
          'http://server/hbo.ts\n';
      final result = M3uParser.parse(m3u);
      expect(result.channels.length, 2);
      expect(result.categories.map((c) => c.name), containsAll(['News', 'Movies']));
      expect(result.channels.first.directUrl, 'http://server/cnn.m3u8');
    });

    test('keeps commas that appear inside the channel name', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 group-title="Movies",HBO 2, The Best\n'
          'http://server/hbo.ts\n';
      final result = M3uParser.parse(m3u);
      expect(result.channels.single.name, 'HBO 2, The Best');
    });

    test('ignores commas inside quoted attribute values', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 group-title="News, World",BBC\n'
          'http://server/bbc.m3u8\n';
      final result = M3uParser.parse(m3u);
      expect(result.channels.single.name, 'BBC');
      expect(result.channels.single.categoryId, 'News, World');
    });

    test('rejects an HTML error page instead of inventing junk channels', () {
      const html = '<!DOCTYPE html>\n<html><body>\n'
          'Your account has expired\n</body></html>\n';
      expect(() => M3uParser.parse(html), throwsException);
    });

    test('channel ids are stable across playlist reordering', () {
      const a = '#EXTM3U\n'
          '#EXTINF:-1 group-title="A",One\nhttp://server/one.ts\n'
          '#EXTINF:-1 group-title="A",Two\nhttp://server/two.ts\n';
      const b = '#EXTM3U\n'
          '#EXTINF:-1 group-title="A",Two\nhttp://server/two.ts\n'
          '#EXTINF:-1 group-title="A",One\nhttp://server/one.ts\n';
      final ra = M3uParser.parse(a);
      final rb = M3uParser.parse(b);
      final oneA = ra.channels.firstWhere((c) => c.name == 'One').id;
      final oneB = rb.channels.firstWhere((c) => c.name == 'One').id;
      expect(oneA, oneB); // favorites keep pointing at the same channel
    });

    test('skips non-URL lines after #EXTINF', () {
      const m3u = '#EXTM3U\n'
          '#EXTINF:-1 group-title="A",Real\n'
          'not a url line\n'
          'http://server/real.ts\n';
      final result = M3uParser.parse(m3u);
      expect(result.channels.single.directUrl, 'http://server/real.ts');
    });
  });
}
