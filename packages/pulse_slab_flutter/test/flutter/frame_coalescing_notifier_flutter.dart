import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';

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

    testWidgets('filters and coalesces portable wide selections', (
      tester,
    ) async {
      final fields = List<Uint8Field>.generate(
        33,
        (index) => Uint8Field('field$index'),
      );
      final layout = RecordLayout(name: 'WideFrame', fields: fields);
      final first = layout.selectionFor(<Field<Object?>>[fields[31]]);
      final second = layout.selectionFor(<Field<Object?>>[fields[32]]);
      final accepted = layout.selectionFor(<Field<Object?>>[
        fields[31],
        fields[32],
      ]);
      final ignored = layout.selectionFor(<Field<Object?>>[fields[0]]);
      final notifier = FrameCoalescingNotifier(selection: accepted);
      addTearDown(notifier.dispose);
      var notifications = 0;
      notifier.addListener(() {
        notifications++;
      });

      notifier.markChangedSelection(ignored);
      notifier.markChangedSelection(first);
      notifier.markChangedSelection(second);

      expect(notifier.acceptedChanges, 2);
      expect(notifier.coalescedChanges, 1);
      expect(notifier.pendingFieldMask, 0);
      expect(notifier.pendingFieldSelection, isNotNull);
      expect(notifier.pendingFieldSelection!.intersects(first), isTrue);
      expect(notifier.pendingFieldSelection!.intersects(second), isTrue);

      await tester.pump();

      expect(notifications, 1);
      expect(notifier.lastDeliveredFieldSelection, isNotNull);
      expect(notifier.lastDeliveredFieldSelection!.intersects(first), isTrue);
      expect(notifier.lastDeliveredFieldSelection!.intersects(second), isTrue);
    });

    test('rejects combining legacy and portable filters', () {
      final field = Uint8Field('field');
      final layout = RecordLayout(
        name: 'CompactFrame',
        fields: <Field<Object?>>[field],
      );

      expect(
        () => FrameCoalescingNotifier(
          fields: field.mask,
          selection: layout.selectionFor(<Field<Object?>>[field]),
        ),
        throwsArgumentError,
      );
    });

    test('rejects coalescing wide selections from different layouts', () {
      final firstFields = List<Uint8Field>.generate(
        32,
        (index) => Uint8Field('first$index'),
      );
      final secondFields = List<Uint8Field>.generate(
        32,
        (index) => Uint8Field('second$index'),
      );
      final first = RecordLayout(name: 'FirstWideFrame', fields: firstFields);
      final second = RecordLayout(
        name: 'SecondWideFrame',
        fields: secondFields,
      );
      final notifier = FrameCoalescingNotifier(
        policy: FlutterDeliveryPolicy.manual,
      );
      addTearDown(notifier.dispose);

      notifier.markChangedSelection(
        first.selectionFor(<Field<Object?>>[firstFields.last]),
      );

      expect(
        () => notifier.markChangedSelection(
          second.selectionFor(<Field<Object?>>[secondFields.last]),
        ),
        throwsArgumentError,
      );
      expect(notifier.acceptedChanges, 1);
      expect(notifier.pendingFieldSelection!.layout, same(first));
    });
  });
}
