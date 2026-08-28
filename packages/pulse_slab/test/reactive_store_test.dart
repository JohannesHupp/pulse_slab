import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

void main() {
  group('PulseStore transactions', () {
    test(
        'merges field writes into one version, journal entry, and notification',
        () {
      final Float32Field temperature = Float32Field('temperature');
      final Uint16Field status = Uint16Field('status');
      final RecordLayout layout = RecordLayout(
        name: 'Sensor',
        fields: <Field<Object?>>[temperature, status],
      );
      final PulseStore store = PulseStore(journalCapacity: 8);
      final RecordHandle handle = store.allocate(layout);
      final List<RecordChange> observed = <RecordChange>[];
      store.watch(handle, listener: observed.add);

      store.transaction<void>((WriteTransaction transaction) {
        final TransactionRecordWriter writer = transaction.write(handle);
        expect(writer.set(temperature, 21.5), isTrue);
        expect(writer.set(status, 7), isTrue);
        expect(writer.set(temperature, 21.5), isFalse);
      });

      expect(store.versionOf(handle), 1);
      expect(store.read(handle).get(temperature), 21.5);
      expect(store.read(handle).get(status), 7);
      expect(store.committedChangeCount, 1);
      expect(observed, hasLength(1));
      expect(observed.single.version, 1);
      expect(observed.single.fieldMask, temperature.mask | status.mask);
      final ChangeRecord? journalChange = store.journal.take();
      expect(journalChange, isNotNull);
      expect(journalChange!.fieldMask, temperature.mask | status.mask);
      expect(journalChange.version, 1);
    });

    test('does not publish unchanged or reverted writes', () {
      final Uint32Field count = Uint32Field('count');
      final RecordLayout layout = RecordLayout(
        name: 'Counter',
        fields: <Field<Object?>>[count],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      final List<RecordChange> observed = <RecordChange>[];
      store.watch(handle, listener: observed.add);

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(count, 4);
      });
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(count, 4);
      });
      store.transaction<void>((WriteTransaction transaction) {
        final TransactionRecordWriter writer = transaction.write(handle);
        writer.set(count, 9);
        writer.set(count, 4);
      });

      expect(store.read(handle).get(count), 4);
      expect(store.versionOf(handle), 1);
      expect(store.committedChangeCount, 1);
      expect(observed, hasLength(1));
    });

    test('rolls back record bytes when the callback throws', () {
      final Uint32Field count = Uint32Field('count');
      final RecordLayout layout = RecordLayout(
        name: 'Rollback',
        fields: <Field<Object?>>[count],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(count, 5);
      });

      expect(
        () => store.transaction<void>((WriteTransaction transaction) {
          transaction.write(handle).set(count, 99);
          throw StateError('abort test transaction');
        }),
        throwsStateError,
      );

      expect(store.read(handle).get(count), 5);
      expect(store.versionOf(handle), 1);
      expect(store.committedChangeCount, 1);
    });

    test('rejects nested transactions', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'Nested',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);

      expect(
        () => store.transaction<void>((WriteTransaction transaction) {
          store.transaction<void>((WriteTransaction nested) {
            nested.write(handle).set(value, 1);
          });
        }),
        throwsStateError,
      );
      expect(store.versionOf(handle), 0);
    });
  });

  group('PulseStore subscriptions', () {
    test('filters fields and permits removal during deterministic dispatch',
        () {
      final Uint16Field temperature = Uint16Field('temperature');
      final Uint16Field status = Uint16Field('status');
      final RecordLayout layout = RecordLayout(
        name: 'Subscriptions',
        fields: <Field<Object?>>[temperature, status],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      final List<String> calls = <String>[];
      late StoreSubscription second;
      store.watch(
        handle,
        fields: temperature.mask,
        listener: (RecordChange change) {
          calls.add('first:${change.version}');
          second.dispose();
        },
      );
      second = store.watch(
        handle,
        fields: temperature.mask,
        listener: (RecordChange change) {
          calls.add('second:${change.version}');
        },
      );
      store.watch(
        handle,
        fields: status.mask,
        listener: (RecordChange change) {
          calls.add('status:${change.version}');
        },
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(status, 1);
      });
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(temperature, 2);
      });

      expect(calls, <String>['status:1', 'first:2']);
      expect(second.isActive, isFalse);
    });

    test('coalesces latest deliveries until explicit flush', () {
      final Uint16Field value = Uint16Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'Latest',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      final List<RecordChange> observed = <RecordChange>[];
      store.watch(
        handle,
        policy: DeliveryPolicy.latest,
        listener: observed.add,
      );

      for (var valueToWrite = 1; valueToWrite <= 3; valueToWrite++) {
        store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, valueToWrite);
        });
      }

      expect(observed, isEmpty);
      expect(store.latestCoalescedDeliveryCount, 2);
      expect(store.flush(), 1);
      expect(observed, hasLength(1));
      expect(observed.single.version, 3);
      expect(store.read(handle).get(value), 3);
    });

    test('bounds batched state deliveries by overwriting the oldest', () {
      final Uint16Field value = Uint16Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'Batched',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore(maxBatchedDeliveries: 2);
      final RecordHandle handle = store.allocate(layout);
      final List<int> deliveredVersions = <int>[];
      store.watch(
        handle,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) {
          deliveredVersions.add(change.version);
        },
      );

      for (var valueToWrite = 1; valueToWrite <= 3; valueToWrite++) {
        store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, valueToWrite);
        });
      }

      expect(store.droppedBatchedDeliveryCount, 1);
      expect(store.flush(), 2);
      expect(deliveredVersions, <int>[2, 3]);
    });

    test('disposes a record subscription when its handle is released', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'Release',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      final StoreSubscription subscription = store.watch(
        handle,
        listener: (RecordChange change) {},
      );

      store.release(handle);
      expect(subscription.isActive, isFalse);
      expect(
        () => store.read(handle),
        throwsA(isA<StaleRecordHandleException>()),
      );
    });
  });

  group('ChangeJournal', () {
    test('wraps by overwriting the oldest state update', () {
      final ChangeJournal journal = ChangeJournal(capacity: 2);
      journal.append(_change(version: 1));
      journal.append(_change(version: 2));
      journal.append(_change(version: 3));

      expect(journal.length, 2);
      expect(journal.overwrittenCount, 1);
      expect(journal.take()!.version, 2);
      expect(journal.take()!.version, 3);
      expect(journal.take(), isNull);
    });

    test('can reject newest state updates under explicit backpressure', () {
      final ChangeJournal journal = ChangeJournal(
        capacity: 1,
        overflowPolicy: JournalOverflowPolicy.rejectNewest,
      );
      expect(journal.append(_change(version: 1)), isTrue);
      expect(journal.append(_change(version: 2)), isFalse);
      expect(journal.rejectedCount, 1);
      expect(journal.take()!.version, 1);
    });
  });
}

ChangeRecord _change({required int version}) => ChangeRecord(
      segment: 0,
      slot: 0,
      generation: 1,
      version: version,
      fieldMask: 1,
    );
