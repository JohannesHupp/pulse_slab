import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_slab/pulse_slab_flutter.dart';

void runFrameCoalescingNotifierTests() {
  group('FrameCoalescingNotifier', () {
    testWidgets('coalesces compatible changes into one frame notification', (
      tester,
    ) async {
      final notifier = FrameCoalescingNotifier(fields: 0x03);
      addTearDown(notifier.dispose);
      var notifications = 0;
      notifier.addListener(() {
        notifications++;
      });

      notifier.markChanged(0x01);
      notifier.markChanged(0x02);
      notifier.markChanged(0x04);

      expect(notifier.acceptedChanges, 2);
      expect(notifier.coalescedChanges, 1);
      expect(notifications, 0);

      await tester.pump();

      expect(notifications, 1);
      expect(notifier.deliveredNotifications, 1);
      expect(notifier.lastDeliveredFieldMask, 0x03);
    });

    testWidgets('manual mode delivers only when flushed', (tester) async {
      final notifier = FrameCoalescingNotifier(
        policy: FlutterDeliveryPolicy.manual,
      );
      addTearDown(notifier.dispose);
      var notifications = 0;
      notifier.addListener(() {
        notifications++;
      });

      notifier.markChanged(0x01);
      notifier.markChanged(0x04);
      await tester.pump();

      expect(notifications, 0);
      expect(notifier.flush(), isTrue);
      expect(notifications, 1);
      expect(notifier.lastDeliveredFieldMask, 0x05);
      expect(notifier.flush(), isFalse);
    });

    testWidgets('disposal cancels a pending frame delivery', (tester) async {
      final notifier = FrameCoalescingNotifier();
      var notifications = 0;
      notifier.addListener(() {
        notifications++;
      });

      notifier.markChanged(1);
      notifier.dispose();
      await tester.pump();

      expect(notifications, 0);
    });
  });
}
