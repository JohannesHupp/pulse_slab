import 'dart:async';
import 'dart:typed_data';

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

    test('does not accept a handle issued by an independent store', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'StoreOwnership',
        fields: <Field<Object?>>[value],
      );
      final PulseStore firstStore = PulseStore();
      final PulseStore secondStore = PulseStore();
      addTearDown(firstStore.dispose);
      addTearDown(secondStore.dispose);
      final RecordHandle firstHandle = firstStore.allocate(layout);
      final RecordHandle secondHandle = secondStore.allocate(layout);

      expect(firstHandle, isNot(equals(secondHandle)));
      expect(
        () => firstStore.read(secondHandle),
        throwsA(isA<StaleRecordHandleException>()),
      );
      expect(
        () => firstStore.update(secondHandle, (TransactionRecordWriter writer) {
          writer.set(value, 1);
        }),
        throwsA(isA<StaleRecordHandleException>()),
      );
      expect(
        () => firstStore.release(secondHandle),
        throwsA(isA<StaleRecordHandleException>()),
      );
      expect(firstStore.versionOf(firstHandle), 0);
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

    test('reuses one growable scratch arena for transaction snapshots', () {
      final FixedBytesField payload = FixedBytesField('payload', 48);
      final RecordLayout layout = RecordLayout(
        name: 'ScratchArena',
        fields: <Field<Object?>>[payload],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle first = store.allocate(layout);
      final RecordHandle second = store.allocate(layout);

      expect(store.transactionScratchCapacityInBytes, 0);
      store.transaction<void>((WriteTransaction transaction) {
        transaction.write(first).set(payload, _filledBytes(48, 1));
        transaction.write(second).set(payload, _filledBytes(48, 2));
      });

      final int retainedCapacity = store.transactionScratchCapacityInBytes;
      final int snapshotBytes = layout.sizeInBytes * 2;
      expect(retainedCapacity, greaterThanOrEqualTo(snapshotBytes));
      expect(store.transactionScratchPeakBytes, snapshotBytes);

      store.transaction<void>((WriteTransaction transaction) {
        transaction.write(first).set(payload, _filledBytes(48, 3));
        transaction.write(second).set(payload, _filledBytes(48, 4));
      });

      expect(store.transactionScratchCapacityInBytes, retainedCapacity);
      expect(store.transactionScratchPeakBytes, snapshotBytes);

      expect(
        () => store.transaction<void>((WriteTransaction transaction) {
          transaction.write(first).set(payload, _filledBytes(48, 5));
          transaction.write(second).set(payload, _filledBytes(48, 6));
          throw StateError('Intentional scratch-arena rollback.');
        }),
        throwsStateError,
      );
      expect(
        store.read(first).get(payload),
        orderedEquals(_filledBytes(48, 3)),
      );
      expect(
        store.read(second).get(payload),
        orderedEquals(_filledBytes(48, 4)),
      );
      expect(store.transactionScratchCapacityInBytes, retainedCapacity);

      store.dispose();
      expect(store.transactionScratchCapacityInBytes, 0);
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

    test('blocks retained readers and byte views during a transaction', () {
      final Uint16Field value = Uint16Field('value');
      final FixedBytesField bytes = FixedBytesField('bytes', 2);
      final RecordLayout layout = RecordLayout(
        name: 'RetainedReader',
        fields: <Field<Object?>>[value, bytes],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 7);
        writer.set(bytes, Uint8List.fromList(<int>[3, 4]));
      });
      final RecordReader reader = store.read(handle);
      final ByteView byteView = reader.bytesView(bytes);

      store.transaction<void>((WriteTransaction transaction) {
        transaction.write(handle).set(value, 8);

        expect(() => reader.get(value), throwsStateError);
        expect(() => reader.version, throwsStateError);
        expect(() => byteView[0], throwsStateError);
      });

      expect(reader.get(value), 8);
      expect(byteView[0], 3);
    });

    test('rejects asynchronous transaction actions and rolls back writes',
        () async {
      final Uint16Field value = Uint16Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'SynchronousTransactions',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      late Future<void> asynchronousAction;

      expect(
        () => store.transaction<Future<void>>((WriteTransaction transaction) {
          asynchronousAction = _asynchronousWrite(transaction, handle, value);
          return asynchronousAction;
        }),
        throwsArgumentError,
      );
      await asynchronousAction;

      expect(store.read(handle).get(value), 0);
      expect(store.versionOf(handle), 0);
      expect(store.committedChangeCount, 0);
    });

    test('contains deferred writer failures from a rejected transaction',
        () async {
      final Uint16Field value = Uint16Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'RejectedDeferredWrite',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final Completer<Object> deferredFailure = Completer<Object>();
      late Future<void> asynchronousAction;

      expect(
        () => store.transaction<Future<void>>((WriteTransaction transaction) {
          asynchronousAction = _asynchronousWriteAfterBoundary(
            transaction,
            handle,
            value,
            deferredFailure,
          );
          return asynchronousAction;
        }),
        throwsArgumentError,
      );

      expect(await deferredFailure.future, isA<StateError>());
      expect(store.read(handle).get(value), 0);
      expect(store.versionOf(handle), 0);
    });

    test('rejects asynchronous update actions and rolls back writes', () async {
      final Uint16Field value = Uint16Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'SynchronousUpdates',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      late Future<void> asynchronousAction;

      expect(
        () => store.update(handle, (TransactionRecordWriter writer) {
          asynchronousAction = _asynchronousUpdate(writer, value);
          return asynchronousAction;
        }),
        throwsArgumentError,
      );
      await asynchronousAction;

      expect(store.read(handle).get(value), 0);
      expect(store.versionOf(handle), 0);
      expect(store.committedChangeCount, 0);
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

    test('validates public typed-column values before journal admission', () {
      expect(
        () => ChangeRecord(
          segment: -1,
          slot: 0,
          generation: 1,
          version: 1,
          fieldMask: 1,
        ),
        throwsRangeError,
      );
      expect(
        () => ChangeRecord(
          segment: 0,
          slot: 0,
          generation: 1,
          version: 1,
          fieldMask: 0x80000000,
        ),
        throwsRangeError,
      );
    });

    test('rejects merging a change with a lower record version', () {
      expect(
        () => _journalRecord(2).mergedWith(_journalRecord(1)),
        throwsArgumentError,
      );
    });

    test('rejects a journal capacity beyond portable typed-data columns', () {
      expect(
        () => ChangeJournal(capacity: 0x10000000),
        throwsRangeError,
      );
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

Future<void> _asynchronousWrite(
  WriteTransaction transaction,
  RecordHandle handle,
  Uint16Field value,
) async {
  transaction.write(handle).set(value, 7);
  await Future<void>.value();
}

Future<void> _asynchronousUpdate(
  TransactionRecordWriter writer,
  Uint16Field value,
) async {
  writer.set(value, 9);
  await Future<void>.value();
}

Future<void> _asynchronousWriteAfterBoundary(
  WriteTransaction transaction,
  RecordHandle handle,
  Uint16Field value,
  Completer<Object> deferredFailure,
) async {
  transaction.write(handle).set(value, 7);
  await Future<void>.value();
  try {
    transaction.write(handle).set(value, 8);
  } on Object catch (error) {
    deferredFailure.complete(error);
    rethrow;
  }
}

Uint8List _filledBytes(int length, int value) {
  final Uint8List bytes = Uint8List(length);
  bytes.fillRange(0, length, value);
  return bytes;
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
