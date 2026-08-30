import 'dart:ui' show FrameTiming, TimingsCallback;

import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_slab_flutter_example/src/frame_rate_monitor.dart';

void main() {
  group('FrameRateAccumulator', () {
    test('uses frame intervals and ignores duplicate timestamps', () {
      final accumulator = FrameRateAccumulator();

      expect(accumulator.recordFrame(0), isNull);
      expect(accumulator.recordFrame(500000), isNull);
      expect(accumulator.recordFrame(500000), isNull);
      expect(accumulator.recordFrame(400000), isNull);
      expect(accumulator.recordFrame(1000000), 2);
    });
  });

  group('FrameRateMonitor', () {
    test('registers only while active and reports a rendered FPS estimate', () {
      TimingsCallback? addedCallback;
      TimingsCallback? removedCallback;
      final monitor = FrameRateMonitor(
        addTimingsCallback: (callback) {
          addedCallback = callback;
        },
        removeTimingsCallback: (callback) {
          removedCallback = callback;
        },
      );
      addTearDown(monitor.dispose);

      monitor.start();
      expect(addedCallback, isNotNull);
      expect(monitor.framesPerSecond.value, isNull);

      final timings = List<FrameTiming>.generate(
        61,
        (index) => _frameTiming(index * 1000000 ~/ 60),
        growable: false,
      );
      addedCallback!(timings);

      expect(monitor.framesPerSecond.value, 60);

      monitor.stop();
      expect(removedCallback, same(addedCallback));
      expect(monitor.framesPerSecond.value, isNull);

      addedCallback!(<FrameTiming>[_frameTiming(2000000)]);
      expect(monitor.framesPerSecond.value, isNull);
    });
  });
}

FrameTiming _frameTiming(int timestampMicroseconds) {
  return FrameTiming(
    vsyncStart: timestampMicroseconds,
    buildStart: timestampMicroseconds + 1,
    buildFinish: timestampMicroseconds + 2,
    rasterStart: timestampMicroseconds + 3,
    rasterFinish: timestampMicroseconds + 4,
    rasterFinishWallTime: timestampMicroseconds + 4,
  );
}
