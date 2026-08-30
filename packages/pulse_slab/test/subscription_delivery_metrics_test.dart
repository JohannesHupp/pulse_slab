import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

void main() {
  group('StoreSubscription delivery metrics', () {
    for (final DeliveryPolicy policy in DeliveryPolicy.values) {
      test('${policy.name} metrics ignore filtered changes', () {
        final Uint8Field temperature = Uint8Field('temperature');
        final Uint8Field status = Uint8Field('status');
        final RecordLayout layout = RecordLayout(
          name: 'Filtered${policy.name}',
          fields: <Field<Object?>>[temperature, status],
        );
        final PulseStore store = PulseStore();
        addTearDown(store.dispose);
        final RecordHandle handle = store.allocate(layout);
        final List<int> deliveredVersions = <int>[];
        late StoreSubscription subscription;
        subscription = store.watch(
          handle,
          fields: temperature.mask,
          policy: policy,
          listener: (RecordChange change) {
            _expectMetrics(
              subscription,
              pending: 0,
              delivered: 1,
              coalesced: 0,
              dropped: 0,
            );
            deliveredVersions.add(change.version);
          },
        );

        store.update(handle, (TransactionRecordWriter writer) {
          writer.set(status, 1);
        });

        _expectMetrics(
          subscription,
          pending: 0,
          delivered: 0,
          coalesced: 0,
          dropped: 0,
        );
        expect(deliveredVersions, isEmpty);

        store.update(handle, (TransactionRecordWriter writer) {
          writer.set(temperature, 2);
        });

        if (policy == DeliveryPolicy.immediate) {
          _expectMetrics(
            subscription,
            pending: 0,
            delivered: 1,
            coalesced: 0,
            dropped: 0,
          );
        } else {
          _expectMetrics(
            subscription,
            pending: 1,
            delivered: 0,
            coalesced: 0,
            dropped: 0,
          );
          expect(store.flush(), 1);
          _expectMetrics(
            subscription,
            pending: 0,
            delivered: 1,
            coalesced: 0,
            dropped: 0,
          );
        }
        expect(deliveredVersions, <int>[2]);
      });
    }

    test(
        'latest counts replacement as coalescing and clears pending before delivery',
        () {
      final Uint8Field temperature = Uint8Field('temperature');
      final Uint8Field status = Uint8Field('status');
      final RecordLayout layout = RecordLayout(
        name: 'LatestMetrics',
        fields: <Field<Object?>>[temperature, status],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final List<RecordChange> observed = <RecordChange>[];
      late StoreSubscription subscription;
      subscription = store.watch(
        handle,
        policy: DeliveryPolicy.latest,
        listener: (RecordChange change) {
          _expectMetrics(
            subscription,
            pending: 0,
            delivered: 1,
            coalesced: 2,
            dropped: 0,
          );
          observed.add(change);
        },
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(temperature, 1);
      });
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(status, 2);
      });
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(temperature, 3);
      });

      _expectMetrics(
        subscription,
        pending: 1,
        delivered: 0,
        coalesced: 2,
        dropped: 0,
      );
      expect(store.flush(), 1);
      expect(observed, hasLength(1));
      expect(observed.single.version, 3);
      expect(
        observed.single.fieldMask,
        temperature.mask | status.mask,
      );
      _expectMetrics(
        subscription,
        pending: 0,
        delivered: 1,
        coalesced: 2,
        dropped: 0,
      );
    });

    test('batched tracks each pending delivery and dequeues before callback',
        () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'BatchedMetrics',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore(maxBatchedDeliveries: 3);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final List<int> deliveredVersions = <int>[];
      late StoreSubscription subscription;
      subscription = store.watch(
        handle,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) {
          final int expectedPending = deliveredVersions.isEmpty ? 1 : 0;
          final int expectedDelivered = deliveredVersions.length + 1;
          _expectMetrics(
            subscription,
            pending: expectedPending,
            delivered: expectedDelivered,
            coalesced: 0,
            dropped: 0,
          );
          deliveredVersions.add(change.version);
        },
      );

      for (var valueToWrite = 1; valueToWrite <= 2; valueToWrite++) {
        store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, valueToWrite);
        });
      }

      _expectMetrics(
        subscription,
        pending: 2,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );
      expect(store.flush(), 2);
      expect(deliveredVersions, <int>[1, 2]);
      _expectMetrics(
        subscription,
        pending: 0,
        delivered: 2,
        coalesced: 0,
        dropped: 0,
      );
    });

    test('attributes batched ring eviction to the displaced subscription', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'BatchedEvictionMetrics',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore(maxBatchedDeliveries: 2);
      addTearDown(store.dispose);
      final RecordHandle first = store.allocate(layout);
      final RecordHandle second = store.allocate(layout);
      final RecordHandle third = store.allocate(layout);
      final List<String> calls = <String>[];
      final StoreSubscription firstSubscription = store.watch(
        first,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) => calls.add('first'),
      );
      final StoreSubscription secondSubscription = store.watch(
        second,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) => calls.add('second'),
      );
      final StoreSubscription thirdSubscription = store.watch(
        third,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) => calls.add('third'),
      );

      for (final RecordHandle handle in <RecordHandle>[first, second, third]) {
        store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, 1);
        });
      }

      _expectMetrics(
        firstSubscription,
        pending: 0,
        delivered: 0,
        coalesced: 0,
        dropped: 1,
      );
      _expectMetrics(
        secondSubscription,
        pending: 1,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );
      _expectMetrics(
        thirdSubscription,
        pending: 1,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );
      expect(store.droppedBatchedDeliveryCount, 1);
      expect(store.journal.overwrittenCount, 0);
      expect(store.rejectedJournalChangeCount, 0);

      expect(store.flush(), 2);
      expect(calls, <String>['second', 'third']);
    });

    test(
        'attributes reentrant immediate ring eviction to the displaced subscription',
        () {
      final Uint8Field triggerValue = Uint8Field('triggerValue');
      final Uint8Field targetValue = Uint8Field('targetValue');
      final RecordLayout triggerLayout = RecordLayout(
        name: 'ImmediateMetricTrigger',
        fields: <Field<Object?>>[triggerValue],
      );
      final RecordLayout targetLayout = RecordLayout(
        name: 'ImmediateMetricTarget',
        fields: <Field<Object?>>[targetValue],
      );
      final PulseStore store = PulseStore(maxReentrantImmediateDeliveries: 2);
      addTearDown(store.dispose);
      final RecordHandle trigger = store.allocate(triggerLayout);
      final RecordHandle first = store.allocate(targetLayout);
      final RecordHandle second = store.allocate(targetLayout);
      final RecordHandle third = store.allocate(targetLayout);
      final List<String> calls = <String>[];
      late StoreSubscription firstSubscription;
      late StoreSubscription secondSubscription;
      late StoreSubscription thirdSubscription;
      firstSubscription = store.watch(
        first,
        listener: (RecordChange change) => calls.add('first'),
      );
      secondSubscription = store.watch(
        second,
        listener: (RecordChange change) {
          _expectMetrics(
            secondSubscription,
            pending: 0,
            delivered: 1,
            coalesced: 0,
            dropped: 0,
          );
          calls.add('second');
        },
      );
      thirdSubscription = store.watch(
        third,
        listener: (RecordChange change) {
          _expectMetrics(
            thirdSubscription,
            pending: 0,
            delivered: 1,
            coalesced: 0,
            dropped: 0,
          );
          calls.add('third');
        },
      );
      store.watch(
        trigger,
        listener: (RecordChange change) {
          calls.add('trigger:start');
          for (final RecordHandle handle in <RecordHandle>[
            first,
            second,
            third,
          ]) {
            store.update(handle, (TransactionRecordWriter writer) {
              writer.set(targetValue, 1);
            });
          }
          _expectMetrics(
            firstSubscription,
            pending: 0,
            delivered: 0,
            coalesced: 0,
            dropped: 1,
          );
          _expectMetrics(
            secondSubscription,
            pending: 1,
            delivered: 0,
            coalesced: 0,
            dropped: 0,
          );
          _expectMetrics(
            thirdSubscription,
            pending: 1,
            delivered: 0,
            coalesced: 0,
            dropped: 0,
          );
          calls.add('trigger:end');
        },
      );

      store.update(trigger, (TransactionRecordWriter writer) {
        writer.set(triggerValue, 1);
      });

      expect(
        calls,
        <String>['trigger:start', 'trigger:end', 'second', 'third'],
      );
      _expectMetrics(
        firstSubscription,
        pending: 0,
        delivered: 0,
        coalesced: 0,
        dropped: 1,
      );
      _expectMetrics(
        secondSubscription,
        pending: 0,
        delivered: 1,
        coalesced: 0,
        dropped: 0,
      );
      _expectMetrics(
        thirdSubscription,
        pending: 0,
        delivered: 1,
        coalesced: 0,
        dropped: 0,
      );
      expect(store.droppedReentrantImmediateDeliveryCount, 1);
    });

    for (final DeliveryPolicy policy in <DeliveryPolicy>[
      DeliveryPolicy.latest,
      DeliveryPolicy.batched,
    ]) {
      test('${policy.name} flush delivery invokes immediate feedback inline',
          () {
        final Uint8Field value = Uint8Field('value');
        final RecordLayout layout = RecordLayout(
          name: 'InlineImmediate${policy.name}',
          fields: <Field<Object?>>[value],
        );
        final PulseStore store = PulseStore();
        addTearDown(store.dispose);
        final RecordHandle source = store.allocate(layout);
        final RecordHandle target = store.allocate(layout);
        final List<String> calls = <String>[];
        late StoreSubscription targetSubscription;
        targetSubscription = store.watch(
          target,
          listener: (RecordChange change) {
            _expectMetrics(
              targetSubscription,
              pending: 0,
              delivered: 1,
              coalesced: 0,
              dropped: 0,
            );
            calls.add('target');
          },
        );
        store.watch(
          source,
          policy: policy,
          listener: (RecordChange change) {
            calls.add('source:start');
            store.update(target, (TransactionRecordWriter writer) {
              writer.set(value, 1);
            });
            calls.add('source:end');
          },
        );

        store.update(source, (TransactionRecordWriter writer) {
          writer.set(value, 1);
        });

        expect(store.flush(), 1);
        expect(calls, <String>['source:start', 'target', 'source:end']);
        _expectMetrics(
          targetSubscription,
          pending: 0,
          delivered: 1,
          coalesced: 0,
          dropped: 0,
        );
        expect(store.pendingReentrantImmediateDeliveryCount, 0);
        expect(store.droppedReentrantImmediateDeliveryCount, 0);
      });
    }

    test('flush has deterministic latest and batched phase boundaries', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'FlushPhaseBoundaries',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle source = store.allocate(layout);
      final RecordHandle existingLatest = store.allocate(layout);
      final RecordHandle deferredLatest = store.allocate(layout);
      final RecordHandle firstBatched = store.allocate(layout);
      final RecordHandle laterBatched = store.allocate(layout);
      final List<String> calls = <String>[];
      late StoreSubscription existingLatestSubscription;
      late StoreSubscription deferredLatestSubscription;
      late StoreSubscription firstBatchedSubscription;
      late StoreSubscription laterBatchedSubscription;
      existingLatestSubscription = store.watch(
        existingLatest,
        policy: DeliveryPolicy.latest,
        listener: (RecordChange change) =>
            calls.add('existing:${change.version}'),
      );
      deferredLatestSubscription = store.watch(
        deferredLatest,
        policy: DeliveryPolicy.latest,
        listener: (RecordChange change) =>
            calls.add('deferred:${change.version}'),
      );
      laterBatchedSubscription = store.watch(
        laterBatched,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) => calls.add('batched:later'),
      );
      firstBatchedSubscription = store.watch(
        firstBatched,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) {
          calls.add('batched:first');
          store.update(laterBatched, (TransactionRecordWriter writer) {
            writer.set(value, 1);
          });
        },
      );
      store.watch(
        source,
        policy: DeliveryPolicy.latest,
        listener: (RecordChange change) {
          calls.add('source');
          store.update(existingLatest, (TransactionRecordWriter writer) {
            writer.set(value, 2);
          });
          store.update(deferredLatest, (TransactionRecordWriter writer) {
            writer.set(value, 1);
          });
          store.update(firstBatched, (TransactionRecordWriter writer) {
            writer.set(value, 1);
          });
        },
      );

      store.update(source, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });
      store.update(existingLatest, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });

      expect(store.flush(), 3);
      expect(calls, <String>['source', 'existing:2', 'batched:first']);
      _expectMetrics(
        existingLatestSubscription,
        pending: 0,
        delivered: 1,
        coalesced: 1,
        dropped: 0,
      );
      _expectMetrics(
        deferredLatestSubscription,
        pending: 1,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );
      _expectMetrics(
        firstBatchedSubscription,
        pending: 0,
        delivered: 1,
        coalesced: 0,
        dropped: 0,
      );
      _expectMetrics(
        laterBatchedSubscription,
        pending: 1,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );

      expect(store.flush(), 2);
      expect(
        calls,
        <String>[
          'source',
          'existing:2',
          'batched:first',
          'deferred:1',
          'batched:later',
        ],
      );
    });

    test('rejects a reentrant flush from a batched listener', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'BatchedReentrantFlush',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final List<String> calls = <String>[];
      store.watch(
        handle,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) {
          calls.add('first');
          store.flush();
        },
      );
      store.watch(
        handle,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) => calls.add('second'),
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });

      expect(store.flush, throwsStateError);
      expect(calls, <String>['first', 'second']);
    });

    test('disposal clears pending work without changing cumulative counters',
        () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'DisposalMetrics',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final StoreSubscription subscription = store.watch(
        handle,
        policy: DeliveryPolicy.latest,
        listener: (RecordChange change) {},
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 2);
      });

      _expectMetrics(
        subscription,
        pending: 1,
        delivered: 0,
        coalesced: 1,
        dropped: 0,
      );
      subscription.dispose();

      expect(subscription.isActive, isFalse);
      _expectMetrics(
        subscription,
        pending: 0,
        delivered: 0,
        coalesced: 1,
        dropped: 0,
      );
      expect(store.flush(), 0);
    });

    test('manual disposal cancels queued batched work without a drop', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'DisposedBatchedMetrics',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore(maxBatchedDeliveries: 1);
      addTearDown(store.dispose);
      final RecordHandle first = store.allocate(layout);
      final RecordHandle second = store.allocate(layout);
      final List<String> calls = <String>[];
      final StoreSubscription firstSubscription = store.watch(
        first,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) => calls.add('first'),
      );
      final StoreSubscription secondSubscription = store.watch(
        second,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) => calls.add('second'),
      );

      store.update(first, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });
      _expectMetrics(
        firstSubscription,
        pending: 1,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );
      firstSubscription.dispose();
      _expectMetrics(
        firstSubscription,
        pending: 0,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );

      store.update(second, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });

      _expectMetrics(
        secondSubscription,
        pending: 1,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );
      expect(store.droppedBatchedDeliveryCount, 0);
      expect(store.flush(), 1);
      expect(calls, <String>['second']);
    });

    test('record release and store disposal clear pending delivery metrics',
        () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'InvalidatedDeliveryMetrics',
        fields: <Field<Object?>>[value],
      );
      final PulseStore releaseStore = PulseStore();
      addTearDown(releaseStore.dispose);
      final RecordHandle releasedHandle = releaseStore.allocate(layout);
      final StoreSubscription releasedSubscription = releaseStore.watch(
        releasedHandle,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) {},
      );

      releaseStore.update(releasedHandle, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });
      _expectMetrics(
        releasedSubscription,
        pending: 1,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );
      releaseStore.release(releasedHandle);
      expect(releasedSubscription.isActive, isFalse);
      _expectMetrics(
        releasedSubscription,
        pending: 0,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );

      final PulseStore disposedStore = PulseStore();
      final RecordHandle disposedHandle = disposedStore.allocate(layout);
      final StoreSubscription disposedSubscription = disposedStore.watch(
        disposedHandle,
        policy: DeliveryPolicy.latest,
        listener: (RecordChange change) {},
      );
      disposedStore.update(disposedHandle, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });
      disposedStore.update(disposedHandle, (TransactionRecordWriter writer) {
        writer.set(value, 2);
      });
      disposedStore.dispose();

      expect(disposedSubscription.isActive, isFalse);
      _expectMetrics(
        disposedSubscription,
        pending: 0,
        delivered: 0,
        coalesced: 1,
        dropped: 0,
      );
    });

    test('keeps journal pressure separate from subscription delivery metrics',
        () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'JournalMetricSeparation',
        fields: <Field<Object?>>[value],
      );
      final PulseStore overwritingStore = PulseStore(
        journalCapacity: 1,
        maxBatchedDeliveries: 3,
      );
      addTearDown(overwritingStore.dispose);
      final RecordHandle overwritingHandle = overwritingStore.allocate(layout);
      final StoreSubscription batched = overwritingStore.watch(
        overwritingHandle,
        policy: DeliveryPolicy.batched,
        listener: (RecordChange change) {},
      );

      for (var valueToWrite = 1; valueToWrite <= 2; valueToWrite++) {
        overwritingStore.update(overwritingHandle, (
          TransactionRecordWriter writer,
        ) {
          writer.set(value, valueToWrite);
        });
      }

      expect(overwritingStore.journal.overwrittenCount, 1);
      _expectMetrics(
        batched,
        pending: 2,
        delivered: 0,
        coalesced: 0,
        dropped: 0,
      );

      final PulseStore rejectingStore = PulseStore(
        journalCapacity: 1,
        journalOverflowPolicy: JournalOverflowPolicy.rejectNewest,
      );
      addTearDown(rejectingStore.dispose);
      final RecordHandle rejectingHandle = rejectingStore.allocate(layout);
      final StoreSubscription immediate = rejectingStore.watch(
        rejectingHandle,
        listener: (RecordChange change) {},
      );

      for (var valueToWrite = 1; valueToWrite <= 2; valueToWrite++) {
        rejectingStore.update(rejectingHandle, (
          TransactionRecordWriter writer,
        ) {
          writer.set(value, valueToWrite);
        });
      }

      expect(rejectingStore.rejectedJournalChangeCount, 1);
      _expectMetrics(
        immediate,
        pending: 0,
        delivered: 2,
        coalesced: 0,
        dropped: 0,
      );
    });

    test('counts a throwing listener as a delivery attempt', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'ThrowingDeliveryMetric',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      late StoreSubscription subscription;
      subscription = store.watch(
        handle,
        listener: (RecordChange change) {
          _expectMetrics(
            subscription,
            pending: 0,
            delivered: 1,
            coalesced: 0,
            dropped: 0,
          );
          throw StateError('expected listener failure');
        },
      );

      expect(
        () => store.update(handle, (TransactionRecordWriter writer) {
          writer.set(value, 1);
        }),
        throwsStateError,
      );
      _expectMetrics(
        subscription,
        pending: 0,
        delivered: 1,
        coalesced: 0,
        dropped: 0,
      );
    });
  });
}

void _expectMetrics(
  StoreSubscription subscription, {
  required int pending,
  required int delivered,
  required int coalesced,
  required int dropped,
}) {
  expect(subscription.pendingDeliveries, pending);
  expect(subscription.deliveredCount, delivered);
  expect(subscription.coalescedCount, coalesced);
  expect(subscription.droppedCount, dropped);
}
