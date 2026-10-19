import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:openplate_mobile/plate_identity.dart';
import 'package:openplate_mobile/plate_motion.dart';

PlateBox box(double scale, {double cx = .5, double cy = .5}) =>
    PlateBox(cx - .1 * scale, cy - .025 * scale, .2 * scale, .05 * scale);

void main() {
  test(
    'German umlauts remain distinct identities, including decomposed input',
    () {
      expect(normalizePlate('mü-ab 12'), 'MÜAB12');
      expect(normalizePlate('Mu\u0308-ab 12'), 'MÜAB12');
      expect(normalizePlate('MUAB12'), isNot(normalizePlate('MÜAB12')));
      expect(normalizePlate('MAB12'), isNot(normalizePlate('MÜAB12')));
    },
  );
  test('too few samples or too little elapsed time is unknown', () {
    final tracker = PlateMotionTracker();
    for (var i = 0; i < 3; i++) {
      expect(
        tracker.update('A', box(1 + i * .1), Duration(seconds: i)).direction,
        'unknown',
      );
    }
    tracker.reset();
    for (var i = 0; i < 4; i++) {
      expect(
        tracker
            .update('A', box(1 + i * .1), Duration(milliseconds: i * 200))
            .direction,
        'unknown',
      );
    }
  });
  test(
    'stable growth and shrinkage infer direction and normalized image velocity',
    () {
      for (final sign in [1, -1]) {
        final tracker = PlateMotionTracker();
        PlateMotion result = const PlateMotion();
        for (var i = 0; i < 4; i++) {
          result = tracker.update(
            'A',
            box(math.exp(sign * .08 * i), cx: .4 + i * .01),
            Duration(seconds: i),
          );
        }
        expect(result.direction, sign == 1 ? 'approaching' : 'receding');
        expect(result.scaleRate, closeTo(sign * .08, .000001));
        expect(result.dx, closeTo(.01, .000001));
        expect(result.samples, 4);
      }
    },
  );
  test('stationary plate does not become an approach through small jitter', () {
    final tracker = PlateMotionTracker();
    PlateMotion result = const PlateMotion();
    for (var i = 0; i < 5; i++) {
      result = tracker.update(
        'A',
        box(i.isEven ? 1.001 : .999),
        Duration(seconds: i),
      );
    }
    expect(result.direction, 'stationary');
  });
  test(
    'sideways travel with stable scale is not falsely called approach or stationary',
    () {
      final tracker = PlateMotionTracker();
      PlateMotion result = const PlateMotion();
      for (var i = 0; i < 4; i++) {
        result = tracker.update(
          'A',
          box(1, cx: .4 + i * .03),
          Duration(seconds: i),
        );
      }
      expect(result.direction, 'unknown');
    },
  );
  test(
    'clipping, pose change, association jump, gaps and lifecycle reset invalidate history',
    () {
      final tracker = PlateMotionTracker();
      for (var i = 0; i < 4; i++) {
        tracker.update('A', box(math.exp(.08 * i)), Duration(seconds: i));
      }
      expect(
        tracker
            .update(
              'A',
              const PlateBox(0, .4, .2, .05),
              const Duration(seconds: 4),
            )
            .direction,
        'unknown',
      );
      expect(
        tracker.update('A', box(1), const Duration(seconds: 5)).direction,
        'unknown',
      );
      tracker.reset();
      expect(
        tracker.update('A', box(1), const Duration(seconds: 6)).direction,
        'unknown',
      );
      expect(
        tracker.update('A', box(1.1), const Duration(seconds: 15)).direction,
        'unknown',
      );
      tracker.update('A', box(1.2), const Duration(seconds: 16));
      tracker.update('A', box(1.3), const Duration(seconds: 17));
      expect(
        tracker
            .update(
              'A',
              const PlateBox(.35, .45, .3, .05),
              const Duration(seconds: 18),
            )
            .direction,
        'unknown',
      );
      expect(
        tracker.update('A', null, const Duration(seconds: 19)).direction,
        'unknown',
      );
      expect(
        tracker
            .update('A', box(double.nan), const Duration(seconds: 20))
            .direction,
        'unknown',
      );
    },
  );
}
