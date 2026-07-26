import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/ui/screens/player_screen.dart';

/// Total distance covered after [taps] skips of a single burst — what the
/// on-screen badge counts up to while spam-tapping one side of the screen.
Duration totalAfter(int taps) {
  var total = Duration.zero;
  for (var i = 1; i <= taps; i++) {
    total += skipStepFor(i);
  }
  return total;
}

void main() {
  group('skipStepFor', () {
    test('an ordinary double-tap skips the familiar 10 seconds', () {
      expect(skipStepFor(1), const Duration(seconds: 10));
      expect(totalAfter(1), const Duration(seconds: 10));
    });

    test('the step escalates the longer a burst is spammed', () {
      expect(skipStepFor(4), const Duration(seconds: 10));
      expect(skipStepFor(5), const Duration(seconds: 20));
      expect(skipStepFor(7), const Duration(seconds: 20));
      expect(skipStepFor(8), const Duration(seconds: 30));
      expect(skipStepFor(50), const Duration(seconds: 30));
    });

    test('the step never shrinks as taps accumulate', () {
      for (var i = 2; i <= 30; i++) {
        expect(skipStepFor(i) >= skipStepFor(i - 1), isTrue,
            reason: 'step $i shrank below step ${i - 1}');
      }
    });

    test('running totals match the documented ladder', () {
      expect(totalAfter(2), const Duration(seconds: 20));
      expect(totalAfter(3), const Duration(seconds: 30));
      expect(totalAfter(4), const Duration(seconds: 40));
      expect(totalAfter(5), const Duration(seconds: 60));
      expect(totalAfter(7), const Duration(seconds: 100));
      expect(totalAfter(10), const Duration(seconds: 190));
    });

    test('spamming reaches minutes ahead in a handful of taps', () {
      // The whole point of the escalation: ~10 taps should be worth minutes,
      // not the 100 seconds a flat 10s-per-tap ladder would give.
      expect(totalAfter(10).inMinutes, greaterThanOrEqualTo(3));
    });
  });
}
