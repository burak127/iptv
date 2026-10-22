import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/models/epg.dart';
import 'package:iptv_player/models/guide_entry.dart';
import 'package:iptv_player/services/archive_window.dart';

void main() {
  test('derives provider clock without channel EPG from server_info', () {
    expect(archiveServerClockOffset('2026-09-26 12:00:00',
        DateTime.utc(2026, 9, 26, 10).millisecondsSinceEpoch ~/ 1000),
        const Duration(hours: 2));
    expect(archiveServerClockOffset('bad', 1), isNull);
  });

  test('derives the provider clock from epoch and panel-local EPG time', () {
    final entries = [
      EpgEntry(
        title: 'News',
        startUtc: DateTime.utc(2026, 9, 26, 10),
        endUtc: DateTime.utc(2026, 9, 26, 11),
        serverStart: '2026-09-26 12:00:00',
      ),
    ];
    final offset = archiveClockOffset(entries);
    expect(offset, const Duration(hours: 2));
    expect(archiveStart(DateTime.utc(2026, 9, 25, 23, 7), offset!),
        '2026-09-26:01-07');
  });

  test('does not guess a panel offset from unusable EPG data', () {
    final entries = [
      EpgEntry(
        title: 'News',
        startUtc: DateTime.utc(2026, 9, 26, 10),
        endUtc: DateTime.utc(2026, 9, 26, 11),
      ),
    ];
    expect(archiveClockOffset(entries), isNull);
  });

  test('XMLTV fallback uses the entry closest to the archive start', () {
    final entries = [
      GuideEntry(
        title: 'Now',
        startUtc: DateTime.utc(2026, 10, 25, 12),
        endUtc: DateTime.utc(2026, 10, 25, 13),
        timeshiftStart: '2026-10-25:13-00',
      ),
      GuideEntry(
        title: 'Earlier',
        startUtc: DateTime.utc(2026, 10, 25, 0),
        endUtc: DateTime.utc(2026, 10, 25, 1),
        timeshiftStart: '2026-10-25:02-00',
      ),
    ];
    expect(archiveGuideClockOffset(entries, DateTime.utc(2026, 10, 25, 0)),
        const Duration(hours: 2));
  });
}
