import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

void main() {
  group('PulseStore transactions', () {
    test('merges writes into one version, journal entry, and notification', () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore(journalCapacity: 8);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      final List<RecordChange> changes = <RecordChange>[];
      store.watch(handle, listener: changes.add);

      store.transaction<void>((WriteTransaction transaction) {
        final TransactionRecordWriter writer = transaction.write(handle);
        writer.set(schema.temperature, 21.5);
        writer.set(schema.status, 3);
        writer.set(schema.temperature, 22.0);
      });

      expect(store.read(handle).get(schema.temperature), 22.0);
      expect(store.read(handle).get(schema.status), 3);
      expect(store.versionOf(handle), 1);
      expect(store.committedChangeCount, 1);
      expect(changes, hasLength(1));
      expect(
        changes.single.fieldMask,
        schema.temperature.mask | schema.status.mask,
      );
      final ChangeRecord? journalChange = store.journal.take();
      expect(journalChange, isNotNull);
      expect(journalChange!.version, 1);
      expect(
        journalChange.fieldMask,
        schema.temperature.mask | schema.status.mask,
      );
    });

    test('does not commit unchanged values or a net-zero transaction', () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      var notifications = 0;
      store.watch(handle, listener: (_) => notifications++);

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(schema.temperature, 10.0);
      });
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(schema.temperature, 10.0);
      });
      store.transaction<void>((WriteTransaction transaction) {
        final TransactionRecordWriter writer = transaction.write(handle);
        writer.set(schema.temperature, 11.0);
        writer.set(schema.temperature, 10.0);
      });

      expect(store.versionOf(handle), 1);
      expect(store.committedChangeCount, 1);
      expect(notifications, 1);
      expect(store.journal.length, 1);
    });

    test('rolls back bytes and avoids publication when a transaction throws',
        () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(schema.temperature, 5.0);
      });
      final versionBeforeFailure = store.versionOf(handle);
      var notifications = 0;
      store.watch(handle, listener: (_) => notifications++);

      expect(
        () => store.transaction<void>((WriteTransaction transaction) {
          transaction.write(handle).set(schema.temperature, 42.0);
          throw StateError('Intentional rollback.');
        }),
        throwsStateError,
      );

      expect(store.read(handle).get(schema.temperature), 5.0);
      expect(store.versionOf(handle), versionBeforeFailure);
      expect(notifications, 0);
      expect(store.journal.length, 1);
    });

    test('rejects nested transactions and stale transaction writers', () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      late TransactionRecordWriter writer;

      store.transaction<void>((WriteTransaction transaction) {
        writer = transaction.write(handle);
        writer.set(schema.status, 1);
      });

      expect(() => writer.set(schema.status, 2), throwsStateError);
      expect(
        () => store.transaction<void>((WriteTransaction transaction) {
          store.transaction<void>((WriteTransaction nested) {});
        }),
        throwsStateError,
      );
    });

    test('exposes in-transaction state only through its transaction writer',
        () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);

      store.transaction<void>((WriteTransaction transaction) {
        final TransactionRecordWriter writer = transaction.write(handle);
        writer.set(schema.temperature, 18.0);

        expect(writer.get(schema.temperature), 18.0);
        expect(() => store.read(handle), throwsStateError);
        expect(() => store.versionOf(handle), throwsStateError);
        expect(
          () => store.watch(handle, listener: (_) {}),
          throwsStateError,
        );
        expect(() => store.flush(), throwsStateError);
      });

      expect(store.read(handle).get(schema.temperature), 18.0);
    });
  });

  group('PulseStore subscriptions', () {
    test('filters selected fields, supports disposal, and preserves order', () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      final List<String> calls = <String>[];
      final StoreSubscription temperatureSubscription = store.watch(
        handle,
        fields: schema.temperature.mask,
        listener: (_) => calls.add('temperature'),
      );
      store.watch(
        handle,
        fields: schema.status.mask,
        listener: (_) => calls.add('status'),
      );
      store.watch(handle, listener: (_) => calls.add('all'));

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(schema.temperature, 20.0);
      });
      expect(calls, <String>['temperature', 'all']);

      calls.clear();
      temperatureSubscription.dispose();
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(schema.status, 7);
      });
      expect(calls, <String>['status', 'all']);
    });

    test('allows listener removal during dispatch without skipping safety', () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      final List<String> calls = <String>[];
      late StoreSubscription second;

      store.watch(
        handle,
        listener: (_) {
          calls.add('first');
          second.dispose();
        },
      );
      second = store.watch(
        handle,
        listener: (_) => calls.add('second'),
      );
      store.watch(
        handle,
        listener: (_) => calls.add('third'),
      );

      store.update(
        handle,
        (TransactionRecordWriter writer) {
          writer.set(schema.status, 1);
        },
      );

      expect(calls, <String>['first', 'third']);
    });

    test('disposes record subscriptions on release and detects stale handles',
        () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore(segmentCapacity: 1);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      final StoreSubscription subscription =
          store.watch(handle, listener: (_) {});

      store.release(handle);

      expect(subscription.isActive, isFalse);
      expect(
        () => store.read(handle),
        throwsA(isA<StaleRecordHandleException>()),
      );
      expect(
        () => store.watch(handle, listener: (_) {}),
        throwsA(isA<StaleRecordHandleException>()),
      );
      final RecordHandle reused = store.allocate(schema.layout);
      expect(reused.slot, handle.slot);
      expect(reused.generation, handle.generation + 1);
    });
  });

  group('delivery policies', () {
    test('immediate delivery runs after every changed commit', () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      final List<int> versions = <int>[];
      store.watch(
        handle,
        policy: DeliveryPolicy.immediate,
        listener: (RecordChange change) => versions.add(change.version),
      );

      _setTemperature(store, handle, schema, 1.0);
      _setTemperature(store, handle, schema, 2.0);

      expect(versions, <int>[1, 2]);
      expect(store.flush(), 0);
    });

    test('latest delivery coalesces to the latest version and union mask', () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      final List<RecordChange> received = <RecordChange>[];
      store.watch(
        handle,
        policy: DeliveryPolicy.latest,
        listener: received.add,
      );

      _setTemperature(store, handle, schema, 1.0);
      _setStatus(store, handle, schema, 1);
      _setTemperature(store, handle, schema, 2.0);

      expect(received, isEmpty);
      expect(store.latestCoalescedDeliveryCount, 2);
      expect(store.flush(), 1);
      expect(received, hasLength(1));
      expect(received.single.version, 3);
      expect(
        received.single.fieldMask,
        schema.temperature.mask | schema.status.mask,
      );
    });

    test('batched delivery is bounded and overwrites oldest state delivery',
        () {
      final _TelemetrySchema schema = _TelemetrySchema();
      final PulseStore store = PulseStore(maxBatchedDeliveries: 2);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(schema.layout);
      final List<int> versions = <int>[];
      store.watch(
        handle,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) => versions.add(change.version),
      );

      _setTemperature(store, handle, schema, 1.0);
      _setTemperature(store, handle, schema, 2.0);
      _setTemperature(store, handle, schema, 3.0);

      expect(versions, isEmpty);
      expect(store.droppedBatchedDeliveryCount, 1);
      expect(store.flush(), 2);
      expect(versions, <int>[2, 3]);
    });
  });

  group('ChangeJournal', () {
    test('wraps by overwriting oldest changes with a defined counter', () {
      final ChangeJournal journal = ChangeJournal(capacity: 2);
      journal.append(_journalRecord(1));
      journal.append(_journalRecord(2));
      journal.append(_journalRecord(3));

      expect(journal.length, 2);
      expect(journal.overwrittenCount, 1);
      expect(
        journal.drain().map((ChangeRecord item) => item.version),
        <int>[2, 3],
      );
      expect(journal.isEmpty, isTrue);
    });

    test('can reject newest changes instead of overwriting', () {
      final ChangeJournal journal = ChangeJournal(
        capacity: 1,
        overflowPolicy: JournalOverflowPolicy.rejectNewest,
      );
      expect(journal.append(_journalRecord(1)), isTrue);
      expect(journal.append(_journalRecord(2)), isFalse);
      expect(journal.rejectedCount, 1);
      expect(journal.take()!.version, 1);
    });
  });

  test('handles high-frequency replaceable updates within bounded storage', () {
    final _TelemetrySchema schema = _TelemetrySchema();
    final PulseStore store = PulseStore(
      segmentCapacity: 16,
      journalCapacity: 32,
    );
    addTearDown(store.dispose);
    final List<RecordHandle> handles = List<RecordHandle>.generate(
      64,
      (_) => store.allocate(schema.layout),
    );
    var delivered = 0;
    for (final RecordHandle handle in handles) {
      store.watch(
        handle,
        fields: schema.temperature.mask,
        policy: DeliveryPolicy.latest,
        listener: (_) => delivered++,
      );
    }

    for (var round = 0; round < 200; round++) {
      for (var index = 0; index < handles.length; index++) {
        _setTemperature(store, handles[index], schema, round + index / 100.0);
      }
    }

    expect(store.journal.length, lessThanOrEqualTo(32));
    expect(store.liveRecordCount, 64);
    expect(store.flush(), 64);
    expect(delivered, 64);
    expect(store.latestCoalescedDeliveryCount, greaterThan(10000));
  });
}

void _setTemperature(
  PulseStore store,
  RecordHandle handle,
  _TelemetrySchema schema,
  double value,
) {
  store.update(handle, (TransactionRecordWriter writer) {
    writer.set(schema.temperature, value);
  });
}

void _setStatus(
  PulseStore store,
  RecordHandle handle,
  _TelemetrySchema schema,
  int value,
) {
  store.update(handle, (TransactionRecordWriter writer) {
    writer.set(schema.status, value);
  });
}

ChangeRecord _journalRecord(int version) => ChangeRecord(
      segment: 0,
      slot: 0,
      generation: 1,
      version: version,
      fieldMask: 1,
    );

final class _TelemetrySchema {
  factory _TelemetrySchema() {
    final Float64Field temperature = Float64Field('temperature');
    final Uint16Field status = Uint16Field('status');
    final BoolField enabled = BoolField('enabled');
    final RecordLayout layout = RecordLayout(
      name: 'Telemetry',
      fields: <Field<Object?>>[temperature, status, enabled],
    );
    return _TelemetrySchema._(temperature, status, enabled, layout);
  }

  const _TelemetrySchema._(
    this.temperature,
    this.status,
    this.enabled,
    this.layout,
  );

  final Float64Field temperature;
  final Uint16Field status;
  final BoolField enabled;
  final RecordLayout layout;
}
