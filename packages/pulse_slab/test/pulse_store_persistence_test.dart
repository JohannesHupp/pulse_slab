import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

void main() {
  group('StoreCaptureCodec', () {
    test('round-trips versioned checkpoint and incremental operations', () {
      final StoreCaptureRecordId first = StoreCaptureRecordId(
        segment: 2,
        slot: 3,
        generation: 4,
      );
      final StoreCaptureRecordId second = StoreCaptureRecordId(
        segment: 5,
        slot: 6,
        generation: 7,
      );
      final StorePersistenceLayout layout = StorePersistenceLayout(
        identity: 'sensor/v1',
        version: 3,
      );
      final Uint8List sourceBytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final StoreCaptureBatch checkpoint = StoreCaptureBatch.checkpoint(
        <StoreCaptureSnapshot>[
          StoreCaptureSnapshot(
            record: first,
            layout: layout,
            version: 42,
            bytes: sourceBytes,
          ),
        ],
      );
      sourceBytes[0] = 99;

      final StoreCaptureBatch decoded = StoreCaptureCodec.decode(
        StoreCaptureCodec.encode(checkpoint),
      );
      expect(decoded.kind, StoreCaptureBatchKind.checkpoint);
      final StoreCaptureSnapshot snapshot =
          decoded.operations.single as StoreCaptureSnapshot;
      expect(snapshot.record, first);
      expect(snapshot.layout, layout);
      expect(snapshot.version, 42);
      expect(snapshot.copyBytes(), <int>[1, 2, 3, 4]);

      final StoreCaptureBatch incremental = StoreCaptureBatch.incremental(
        <StoreCaptureOperation>[
          StoreCaptureSnapshot.takeBytes(
            record: second,
            layout: layout,
            version: 1,
            bytes: Uint8List.fromList(<int>[8]),
          ),
          StoreCaptureRelease(record: first),
        ],
      );
      final StoreCaptureBatch decodedIncremental = StoreCaptureCodec.decode(
        incremental.encode(),
      );
      expect(decodedIncremental.kind, StoreCaptureBatchKind.incremental);
      expect(decodedIncremental.operations, hasLength(2));
      expect(decodedIncremental.operations.first, isA<StoreCaptureSnapshot>());
      expect(decodedIncremental.operations.last, isA<StoreCaptureRelease>());
    });

    test('rejects corrupt and truncated binary captures', () {
      final StoreCaptureBatch batch = StoreCaptureBatch.incremental(
        <StoreCaptureOperation>[
          StoreCaptureRelease(
            record: StoreCaptureRecordId(segment: 0, slot: 0, generation: 1),
          ),
        ],
      );
      final Uint8List encoded = batch.encode();

      final Uint8List corrupt = Uint8List.fromList(encoded);
      corrupt[0] ^= 0xff;
      expect(() => StoreCaptureCodec.decode(corrupt), throwsFormatException);
      expect(
        () => StoreCaptureCodec.decode(encoded.sublist(0, encoded.length - 1)),
        throwsFormatException,
      );

      final Uint8List emptyCheckpoint =
          StoreCaptureBatch.checkpoint(const <StoreCaptureSnapshot>[]).encode();
      emptyCheckpoint[5] = 1;
      expect(
        () => StoreCaptureCodec.decode(emptyCheckpoint),
        throwsFormatException,
      );
    });
  });

  group('StoreCaptureReplayer', () {
    test('uses a checkpoint then applies ordered updates and releases', () {
      final StoreCaptureRecordId first = StoreCaptureRecordId(
        segment: 0,
        slot: 0,
        generation: 1,
      );
      final StoreCaptureRecordId second = StoreCaptureRecordId(
        segment: 0,
        slot: 1,
        generation: 1,
      );
      final StorePersistenceLayout layout = StorePersistenceLayout(
        identity: 'sensor',
      );
      final StoreCaptureReplayer replayer = StoreCaptureReplayer();

      replayer.apply(
        StoreCaptureBatch.checkpoint(
          <StoreCaptureSnapshot>[
            _snapshot(first, layout, 1, <int>[10]),
          ],
        ),
      );
      replayer.apply(
        StoreCaptureBatch.incremental(
          <StoreCaptureOperation>[
            _snapshot(first, layout, 2, <int>[11]),
            _snapshot(second, layout, 1, <int>[20]),
          ],
        ),
      );
      replayer.apply(
        StoreCaptureBatch.incremental(
          <StoreCaptureOperation>[StoreCaptureRelease(record: first)],
        ),
      );

      expect(replayer.records, hasLength(1));
      expect(replayer.records.single.record, second);
      expect(replayer.records.single.version, 1);
      expect(replayer.records.single.copyBytes(), <int>[20]);
    });
  });

  group('PulseStore optional persistence', () {
    test('keeps the default store on the native in-memory path', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'DisabledPersistence',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      var delivered = 0;
      store.watch(handle, listener: (RecordChange change) => delivered++);

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 12);
      });

      expect(store.persistence, isNull);
      expect(store.read(handle).get(value), 12);
      expect(store.versionOf(handle), 1);
      expect(store.journal.take()!.version, 1);
      expect(delivered, 1);
      expect(
        store.capturePersistenceCheckpoint,
        throwsStateError,
      );
    });

    test('binds a persistence instance to one store lifetime', () {
      final _RecordingPersistence persistence = _RecordingPersistence();
      final PulseStore first = PulseStore(persistence: persistence);
      addTearDown(first.dispose);

      expect(
        () => PulseStore(persistence: persistence),
        throwsStateError,
      );
    });

    test('captures allocation, committed snapshots, checkpoint, and release',
        () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'PersistentSensor',
        fields: <Field<Object?>>[value],
      );
      final _RecordingPersistence persistence = _RecordingPersistence();
      final PulseStore store = PulseStore(
        persistence: persistence,
        persistenceLayoutResolver: (RecordLayout resolved) =>
            StorePersistenceLayout(
          identity: 'telemetry/${resolved.name}',
          version: 2,
        ),
      );
      addTearDown(store.dispose);

      final RecordHandle handle = store.allocate(layout);
      expect(persistence.batches, hasLength(1));
      final StoreCaptureSnapshot allocated = _onlySnapshot(
        persistence.batches.single,
      );
      expect(allocated.version, 0);
      expect(allocated.layout.identity, 'telemetry/PersistentSensor');
      expect(allocated.layout.version, 2);
      expect(allocated.copyBytes(), everyElement(0));

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 44);
      });

      expect(persistence.batches, hasLength(2));
      final StoreCaptureSnapshot committed = _onlySnapshot(
        persistence.batches.last,
      );
      expect(committed.version, 1);
      expect(committed.copyBytes().first, 44);

      store.capturePersistenceCheckpoint();
      final StoreCaptureBatch checkpoint = persistence.batches.last;
      expect(checkpoint.kind, StoreCaptureBatchKind.checkpoint);
      expect(_onlySnapshot(checkpoint).copyBytes().first, 44);

      store.release(handle);
      expect(persistence.batches.last.kind, StoreCaptureBatchKind.incremental);
      expect(
        persistence.batches.last.operations.single,
        isA<StoreCaptureRelease>(),
      );
    });

    test('retains immutable snapshots and groups multi-record commits', () {
      final Uint8Field firstValue = Uint8Field('firstValue');
      final Uint8Field secondValue = Uint8Field('secondValue');
      final RecordLayout firstLayout = RecordLayout(
        name: 'FirstPersistentRecord',
        fields: <Field<Object?>>[firstValue],
      );
      final RecordLayout secondLayout = RecordLayout(
        name: 'SecondPersistentRecord',
        fields: <Field<Object?>>[secondValue],
      );
      final _RecordingPersistence persistence = _RecordingPersistence();
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      final RecordHandle first = store.allocate(firstLayout);
      final RecordHandle second = store.allocate(secondLayout);

      store.transaction<void>((WriteTransaction transaction) {
        transaction.write(first).set(firstValue, 10);
        transaction.write(second).set(secondValue, 20);
      });
      final StoreCaptureBatch committed = persistence.batches.last;
      expect(committed.operations, hasLength(2));
      final StoreCaptureSnapshot firstSnapshot =
          committed.operations.first as StoreCaptureSnapshot;
      final StoreCaptureSnapshot secondSnapshot =
          committed.operations.last as StoreCaptureSnapshot;
      expect(firstSnapshot.copyBytes(), orderedEquals(<int>[10]));
      expect(secondSnapshot.copyBytes(), orderedEquals(<int>[20]));

      store.update(first, (TransactionRecordWriter writer) {
        writer.set(firstValue, 11);
      });
      expect(firstSnapshot.copyBytes(), orderedEquals(<int>[10]));
    });

    test('resolves persistence layout metadata once per allocation', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'ResolverFrequency',
        fields: <Field<Object?>>[value],
      );
      final _RecordingPersistence persistence = _RecordingPersistence();
      var resolverCalls = 0;
      final PulseStore store = PulseStore(
        persistence: persistence,
        persistenceLayoutResolver: (RecordLayout resolved) {
          resolverCalls++;
          return StorePersistenceLayout(identity: resolved.name);
        },
      );
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);

      for (var index = 0; index < 3; index++) {
        store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, index + 1);
        });
      }
      store.capturePersistenceCheckpoint();

      expect(resolverCalls, 1);
    });

    test('rolls back a transaction when capture admission rejects it', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'CaptureBackpressure',
        fields: <Field<Object?>>[value],
      );
      final _RecordingPersistence persistence = _RecordingPersistence();
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      persistence.reject = true;
      var delivered = 0;
      store.watch(handle, listener: (RecordChange change) => delivered++);

      expect(
        () => store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, 99);
        }),
        throwsA(isA<StorePersistenceBackpressureException>()),
      );

      expect(store.read(handle).get(value), 0);
      expect(store.versionOf(handle), 0);
      expect(store.journal.isEmpty, isTrue);
      expect(delivered, 0);
      expect(persistence.batches, hasLength(1));
    });

    test('rolls back allocation and preserves release on capture rejection',
        () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'LifecycleBackpressure',
        fields: <Field<Object?>>[value],
      );
      final _RecordingPersistence persistence = _RecordingPersistence()
        ..reject = true;
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);

      expect(
        () => store.allocate(layout),
        throwsA(isA<StorePersistenceBackpressureException>()),
      );
      expect(store.liveRecordCount, 0);

      persistence.reject = false;
      final RecordHandle handle = store.allocate(layout);
      persistence.reject = true;
      expect(
        () => store.release(handle),
        throwsA(isA<StorePersistenceBackpressureException>()),
      );
      expect(store.read(handle).get(value), 0);
      expect(store.liveRecordCount, 1);
    });

    test('does not capture rolled-back or reverted writes', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'RollbackCapture',
        fields: <Field<Object?>>[value],
      );
      final _RecordingPersistence persistence = _RecordingPersistence();
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final int afterAllocation = persistence.batches.length;

      expect(
        () => store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, 1);
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 2);
        writer.set(value, 0);
      });

      expect(persistence.batches, hasLength(afterAllocation));
      expect(store.versionOf(handle), 0);
    });

    test('rejects lifecycle reentrancy from a persistence sink', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'PersistenceReentrancy',
        fields: <Field<Object?>>[value],
      );
      late PulseStore store;
      late RecordHandle handle;
      final _ReentrantPersistence persistence = _ReentrantPersistence();
      store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      handle = store.allocate(layout);
      persistence.onAppend = () => store.release(handle);

      expect(
        () => store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, 7);
        }),
        throwsStateError,
      );
      expect(store.read(handle).get(value), 0);
      expect(store.liveRecordCount, 1);
      expect(persistence.batches, hasLength(1));

      persistence.onAppend = null;
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 7);
      });
      expect(store.read(handle).get(value), 7);
    });

    test('closes retained transaction APIs before persistence admission', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'PersistenceWriterReentrancy',
        fields: <Field<Object?>>[value],
      );
      late WriteTransaction retainedTransaction;
      late TransactionRecordWriter retainedWriter;
      final _ReentrantPersistence persistence = _ReentrantPersistence();
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final RecordHandle other = store.allocate(layout);
      persistence.onAppend = () {
        expect(() => retainedWriter.set(value, 9), throwsStateError);
        expect(() => retainedWriter.get(value), throwsStateError);
        expect(() => retainedWriter.version, throwsStateError);
        expect(() => retainedWriter.changedMask, throwsStateError);
        expect(
          () => retainedWriter.changedFieldSelection,
          throwsStateError,
        );
        expect(
          () => retainedTransaction.write(other).set(value, 9),
          throwsStateError,
        );
      };

      store.transaction<void>((WriteTransaction transaction) {
        retainedTransaction = transaction;
        final TransactionRecordWriter writer = transaction.write(handle);
        retainedWriter = writer;
        writer.set(value, 7);
      });

      expect(store.read(handle).get(value), 7);
      expect(store.versionOf(handle), 1);
      expect(store.read(other).get(value), 0);
      expect(store.versionOf(other), 0);
      final StoreCaptureSnapshot captured = _onlySnapshot(
        persistence.batches.last,
      );
      expect(captured.copyBytes(), orderedEquals(<int>[7]));
    });

    test('guards every lifecycle capture admission from reentrant access', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'LifecycleCaptureReentrancy',
        fields: <Field<Object?>>[value],
      );
      final _ReentrantPersistence persistence = _ReentrantPersistence();
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      final RecordHandle retained = store.allocate(layout);
      final RecordReader reader = store.read(retained);
      var admissionCount = 0;

      persistence.onAppend = () {
        admissionCount++;
        expect(() => reader.get(value), throwsStateError);
        expect(() => store.read(retained), throwsStateError);
        expect(() => store.allocate(layout), throwsStateError);
      };

      final RecordHandle released = store.allocate(layout);
      store.capturePersistenceCheckpoint();
      store.release(released);

      expect(admissionCount, 3);
      persistence.onAppend = null;
      expect(reader.get(value), 0);
      expect(store.liveRecordCount, 1);
    });

    test('allows subscription disposal from a normal transaction action', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'TransactionSubscriptionDisposal',
        fields: <Field<Object?>>[value],
      );
      final _RecordingPersistence persistence = _RecordingPersistence();
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final StoreSubscription subscription = store.watch(
        handle,
        listener: (_) {},
      );

      store.update(handle, (TransactionRecordWriter writer) {
        subscription.dispose();
        writer.set(value, 1);
      });

      expect(subscription.isActive, isFalse);
      expect(store.read(handle).get(value), 1);
    });

    test('allows persistent immediate delivery to start a later transaction',
        () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'PersistentImmediateReentrancy',
        fields: <Field<Object?>>[value],
      );
      final _RecordingPersistence persistence = _RecordingPersistence();
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      var deliveries = 0;
      store.watch(
        handle,
        listener: (RecordChange change) {
          deliveries++;
          if (change.version == 1) {
            store.update(handle, (TransactionRecordWriter writer) {
              writer.set(value, 2);
            });
          }
        },
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });

      expect(store.versionOf(handle), 2);
      expect(store.read(handle).get(value), 2);
      expect(deliveries, 2);
      expect(persistence.batches, hasLength(3));
    });

    test('rolls back when a persistence sink rejects reentrant writer use', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'PersistenceWriterRollback',
        fields: <Field<Object?>>[value],
      );
      late TransactionRecordWriter retainedWriter;
      final _ReentrantPersistence persistence = _ReentrantPersistence();
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      persistence.onAppend = () => retainedWriter.set(value, 9);

      expect(
        () => store.update(handle, (TransactionRecordWriter writer) {
          retainedWriter = writer;
          writer.set(value, 7);
        }),
        throwsStateError,
      );

      expect(store.read(handle).get(value), 0);
      expect(store.versionOf(handle), 0);
      expect(store.journal.isEmpty, isTrue);
      expect(persistence.batches, hasLength(1));
    });

    test('rejects subscription disposal reentrancy from a persistence sink',
        () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'PersistenceSubscriptionReentrancy',
        fields: <Field<Object?>>[value],
      );
      late StoreSubscription subscription;
      final _ReentrantPersistence persistence = _ReentrantPersistence();
      final PulseStore store = PulseStore(persistence: persistence);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      var delivered = 0;
      subscription = store.watch(
        handle,
        listener: (RecordChange change) => delivered++,
      );
      persistence.onAppend = subscription.dispose;

      expect(
        () => store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, 7);
        }),
        throwsStateError,
      );

      expect(store.read(handle).get(value), 0);
      expect(subscription.isActive, isTrue);
      expect(delivered, 0);

      persistence.onAppend = null;
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 7);
      });
      expect(delivered, 1);
    });
  });
}

StoreCaptureSnapshot _snapshot(
  StoreCaptureRecordId record,
  StorePersistenceLayout layout,
  int version,
  List<int> bytes,
) =>
    StoreCaptureSnapshot(
      record: record,
      layout: layout,
      version: version,
      bytes: Uint8List.fromList(bytes),
    );

StoreCaptureSnapshot _onlySnapshot(StoreCaptureBatch batch) {
  expect(batch.operations, hasLength(1));
  return batch.operations.single as StoreCaptureSnapshot;
}

final class _RecordingPersistence implements PulseStorePersistence {
  final List<StoreCaptureBatch> batches = <StoreCaptureBatch>[];
  var reject = false;

  @override
  void append(StoreCaptureBatch batch) {
    if (reject) {
      throw StorePersistenceBackpressureException(
        pendingBytes: 1,
        maxPendingBytes: 1,
        batchBytes: 1,
      );
    }
    batches.add(batch);
  }
}

final class _ReentrantPersistence implements PulseStorePersistence {
  final List<StoreCaptureBatch> batches = <StoreCaptureBatch>[];
  void Function()? onAppend;

  @override
  void append(StoreCaptureBatch batch) {
    onAppend?.call();
    batches.add(batch);
  }
}
