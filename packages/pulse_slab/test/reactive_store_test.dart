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

    test('reports only net field differences after a field is restored', () {
      final Uint16Field temperature = Uint16Field('temperature');
      final Uint16Field status = Uint16Field('status');
      final RecordLayout layout = RecordLayout(
        name: 'NetDirtyMask',
        fields: <Field<Object?>>[temperature, status],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      final List<RecordChange> observed = <RecordChange>[];
      store.watch(handle, listener: observed.add);

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(temperature, 20);
      });
      observed.clear();
      store.journal.drain();

      store.transaction<void>((WriteTransaction transaction) {
        final TransactionRecordWriter writer = transaction.write(handle);
        writer.set(temperature, 21);
        writer.set(temperature, 20);
        writer.set(status, 3);
      });

      expect(store.versionOf(handle), 2);
      expect(observed, hasLength(1));
      expect(observed.single.fieldMask, status.mask);
      expect(store.journal.take()!.fieldMask, status.mask);
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

    test('rejects a field selection outside the portable mask range', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'PortableSelection',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);

      expect(
        () => store.watch(
          handle,
          fields: 0x100000000,
          listener: (RecordChange change) {},
        ),
        throwsArgumentError,
      );
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

    test('invalidation callbacks run only for release or store disposal', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'Invalidation',
        fields: <Field<Object?>>[value],
      );
      final List<String> invalidations = <String>[];
      final PulseStore releaseStore = PulseStore();
      final RecordHandle releaseHandle = releaseStore.allocate(layout);
      final StoreSubscription manuallyDisposed = releaseStore.watch(
        releaseHandle,
        onInvalidated: () => invalidations.add('manual'),
        listener: (RecordChange change) {},
      );
      manuallyDisposed.dispose();
      releaseStore.watch(
        releaseHandle,
        onInvalidated: () => invalidations.add('released'),
        listener: (RecordChange change) {},
      );

      releaseStore.release(releaseHandle);

      final PulseStore disposalStore = PulseStore();
      final RecordHandle disposalHandle = disposalStore.allocate(layout);
      disposalStore.watch(
        disposalHandle,
        onInvalidated: () => invalidations.add('disposed'),
        listener: (RecordChange change) {},
      );
      disposalStore.dispose();
      disposalStore.dispose();

      expect(invalidations, <String>['released', 'disposed']);
    });

    test('invalidation callbacks continue after one throws', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'InvalidationFailure',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      final List<String> callbacks = <String>[];
      store.watch(
        handle,
        onInvalidated: () {
          callbacks.add('first');
          throw StateError('invalidation failure');
        },
        listener: (RecordChange change) {},
      );
      final StoreSubscription second = store.watch(
        handle,
        onInvalidated: () => callbacks.add('second'),
        listener: (RecordChange change) {},
      );

      expect(() => store.release(handle), throwsStateError);
      expect(callbacks, <String>['first', 'second']);
      expect(second.isActive, isFalse);
      expect(
        () => store.read(handle),
        throwsA(isA<StaleRecordHandleException>()),
      );
    });

    test('invalidation callbacks tolerate subscription disposal', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'InvalidationSubscriptionDisposal',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      final List<String> callbacks = <String>[];
      late StoreSubscription second;

      store.watch(
        handle,
        onInvalidated: () {
          callbacks.add('first');
          second.dispose();
        },
        listener: (RecordChange change) {},
      );
      second = store.watch(
        handle,
        onInvalidated: () => callbacks.add('second'),
        listener: (RecordChange change) {},
      );
      store.watch(
        handle,
        onInvalidated: () => callbacks.add('third'),
        listener: (RecordChange change) {},
      );

      expect(() => store.release(handle), returnsNormally);
      expect(callbacks, <String>['first', 'third']);
    });

    test('store disposal tolerates cross-record subscription disposal', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'CrossRecordInvalidation',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      final RecordHandle firstHandle = store.allocate(layout);
      final RecordHandle secondHandle = store.allocate(layout);
      final List<String> callbacks = <String>[];
      late StoreSubscription second;

      store.watch(
        firstHandle,
        onInvalidated: () {
          callbacks.add('first');
          second.dispose();
        },
        listener: (RecordChange change) {},
      );
      second = store.watch(
        secondHandle,
        onInvalidated: () => callbacks.add('second'),
        listener: (RecordChange change) {},
      );

      expect(store.dispose, returnsNormally);
      expect(callbacks, <String>['first']);
      expect(second.isActive, isFalse);
    });

    test('queues reentrant immediate delivery after the active traversal', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'OrderedImmediateReentrancy',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      final List<String> calls = <String>[];

      store.watch(
        handle,
        listener: (RecordChange change) {
          calls.add('first:${change.version}');
          if (change.version == 1) {
            store.update(handle, (TransactionRecordWriter writer) {
              writer.set(value, 2);
            });
          }
        },
      );
      store.watch(
        handle,
        listener: (RecordChange change) =>
            calls.add('second:${change.version}'),
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });

      expect(
        calls,
        <String>['first:1', 'second:1', 'first:2', 'second:2'],
      );
      expect(store.read(handle).get(value), 2);
      expect(store.versionOf(handle), 2);
    });

    test('bounds reentrant immediate delivery by replacing oldest state', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'BoundedImmediateReentrancy',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore(maxReentrantImmediateDeliveries: 1);
      final RecordHandle handle = store.allocate(layout);
      final List<String> calls = <String>[];

      store.watch(
        handle,
        listener: (RecordChange change) {
          calls.add('first:${change.version}');
          if (change.version == 1) {
            store.update(handle, (TransactionRecordWriter writer) {
              writer.set(value, 2);
            });
            store.update(handle, (TransactionRecordWriter writer) {
              writer.set(value, 3);
            });
          }
        },
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });

      expect(calls, <String>['first:1', 'first:3']);
      expect(store.droppedReentrantImmediateDeliveryCount, 1);
      expect(store.pendingReentrantImmediateDeliveryCount, 0);
      expect(store.read(handle).get(value), 3);
      expect(store.versionOf(handle), 3);
    });

    test('routes reentrant latest deliveries before immediate queue draining',
        () {
      final Uint8Field triggerValue = Uint8Field('triggerValue');
      final Uint8Field targetValue = Uint8Field('targetValue');
      final RecordLayout triggerLayout = RecordLayout(
        name: 'ImmediateTrigger',
        fields: <Field<Object?>>[triggerValue],
      );
      final RecordLayout targetLayout = RecordLayout(
        name: 'LatestTarget',
        fields: <Field<Object?>>[targetValue],
      );
      final PulseStore store = PulseStore(maxReentrantImmediateDeliveries: 1);
      final RecordHandle trigger = store.allocate(triggerLayout);
      final RecordHandle target = store.allocate(targetLayout);
      final List<RecordChange> latestChanges = <RecordChange>[];

      store.watch(
        trigger,
        listener: (RecordChange change) {
          if (change.version == 1) {
            store.update(target, (TransactionRecordWriter writer) {
              writer.set(targetValue, 1);
            });
            store.update(trigger, (TransactionRecordWriter writer) {
              writer.set(triggerValue, 2);
            });
          }
        },
      );
      store.watch(
        target,
        policy: DeliveryPolicy.latest,
        listener: latestChanges.add,
      );

      store.update(trigger, (TransactionRecordWriter writer) {
        writer.set(triggerValue, 1);
      });

      expect(store.flush(), 1);
      expect(latestChanges, hasLength(1));
      expect(latestChanges.single.version, 1);
      expect(store.read(target).get(targetValue), 1);
    });

    test('rejects a non-positive reentrant immediate delivery capacity', () {
      expect(
        () => PulseStore(maxReentrantImmediateDeliveries: 0),
        throwsArgumentError,
      );
    });

    for (final DeliveryPolicy policy in DeliveryPolicy.values) {
      test('${policy.name} delivery permits a listener to release its record',
          () {
        final Uint8Field value = Uint8Field('value');
        final RecordLayout layout = RecordLayout(
          name: 'ReleaseDuring${policy.name}',
          fields: <Field<Object?>>[value],
        );
        final PulseStore store = PulseStore();
        final RecordHandle handle = store.allocate(layout);
        final List<String> calls = <String>[];

        store.watch(
          handle,
          policy: policy,
          listener: (RecordChange change) {
            calls.add('first');
            store.release(handle);
          },
        );
        final StoreSubscription second = store.watch(
          handle,
          policy: policy,
          listener: (RecordChange change) => calls.add('second'),
        );

        expect(
          () {
            store.update(handle, (TransactionRecordWriter writer) {
              writer.set(value, 1);
            });
            if (policy != DeliveryPolicy.immediate) {
              store.flush();
            }
          },
          returnsNormally,
        );
        expect(calls, <String>['first']);
        expect(second.isActive, isFalse);
        expect(
          () => store.read(handle),
          throwsA(isA<StaleRecordHandleException>()),
        );
      });

      test('${policy.name} delivery permits a listener to dispose its store',
          () {
        final Uint8Field value = Uint8Field('value');
        final RecordLayout layout = RecordLayout(
          name: 'DisposeDuring${policy.name}',
          fields: <Field<Object?>>[value],
        );
        final PulseStore store = PulseStore();
        final RecordHandle handle = store.allocate(layout);
        final List<String> calls = <String>[];

        store.watch(
          handle,
          policy: policy,
          listener: (RecordChange change) {
            calls.add('first');
            store.dispose();
          },
        );
        final StoreSubscription second = store.watch(
          handle,
          policy: policy,
          listener: (RecordChange change) => calls.add('second'),
        );

        expect(
          () {
            store.update(handle, (TransactionRecordWriter writer) {
              writer.set(value, 1);
            });
            if (policy != DeliveryPolicy.immediate) {
              store.flush();
            }
          },
          returnsNormally,
        );
        expect(calls, <String>['first']);
        expect(store.isDisposed, isTrue);
        expect(second.isActive, isFalse);
        expect(
          () => store.read(handle),
          throwsA(isA<StoreDisposedException>()),
        );
      });

      test('${policy.name} delivery continues after a listener throws', () {
        final Uint8Field value = Uint8Field('value');
        final RecordLayout layout = RecordLayout(
          name: 'ListenerFailure${policy.name}',
          fields: <Field<Object?>>[value],
        );
        final PulseStore store = PulseStore();
        final RecordHandle handle = store.allocate(layout);
        final List<String> calls = <String>[];
        store.watch(
          handle,
          policy: policy,
          listener: (RecordChange change) {
            calls.add('first');
            throw StateError('listener failure');
          },
        );
        store.watch(
          handle,
          policy: policy,
          listener: (RecordChange change) => calls.add('second'),
        );

        if (policy == DeliveryPolicy.immediate) {
          expect(
            () => store.update(handle, (TransactionRecordWriter writer) {
              writer.set(value, 1);
            }),
            throwsStateError,
          );
        } else {
          store.update(handle, (TransactionRecordWriter writer) {
            writer.set(value, 1);
          });
          expect(store.flush, throwsStateError);
        }

        expect(calls, <String>['first', 'second']);
        expect(store.read(handle).get(value), 1);
        expect(store.versionOf(handle), 1);
        expect(store.deliveredNotificationCount, 2);
      });
    }

    test('rejects a reentrant flush from a latest listener', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'ReentrantFlush',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore();
      final RecordHandle handle = store.allocate(layout);
      final List<String> calls = <String>[];
      store.watch(
        handle,
        policy: DeliveryPolicy.latest,
        listener: (RecordChange change) {
          calls.add('first');
          store.flush();
        },
      );
      store.watch(
        handle,
        policy: DeliveryPolicy.latest,
        listener: (RecordChange change) => calls.add('second'),
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });

      expect(store.flush, throwsStateError);
      expect(calls, <String>['first', 'second']);
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

    test('a rejecting full journal does not reject a state commit', () {
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'JournalCommit',
        fields: <Field<Object?>>[value],
      );
      final PulseStore store = PulseStore(
        journalCapacity: 1,
        journalOverflowPolicy: JournalOverflowPolicy.rejectNewest,
      );
      final RecordHandle handle = store.allocate(layout);
      final List<int> deliveredVersions = <int>[];
      store.watch(
        handle,
        listener: (RecordChange change) {
          deliveredVersions.add(change.version);
        },
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 1);
      });
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(value, 2);
      });

      expect(store.read(handle).get(value), 2);
      expect(store.versionOf(handle), 2);
      expect(store.committedChangeCount, 2);
      expect(deliveredVersions, <int>[1, 2]);
      expect(store.rejectedJournalChangeCount, 1);
      expect(store.journal.rejectedCount, 1);
      expect(store.journal.take()!.version, 1);
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
