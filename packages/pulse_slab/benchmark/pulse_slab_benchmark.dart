import 'dart:io';

import 'package:pulse_slab/pulse_slab.dart';

import 'benchmark_support.dart';

const int _defaultOperations = 50000;
const int _subscriptionCount = 8;
const int _randomRecordCount = 1024;
const int _frameStyleBatchSize = 120;

int _benchmarkSink = 0;

void main() {
  final operations = _readOperationCount();
  final schema = _BenchmarkSchema();
  final startRss = _currentRss();

  print('pulse_slab benchmark');
  print('Operations per workload: $operations');
  print('Dart runtime: ${Platform.version}');
  if (startRss != null) {
    print('Resident memory before benchmarks: $startRss bytes');
  }
  print(
    'Approximate allocation count: unavailable; Dart exposes no portable '
    'per-workload allocation counter.',
  );
  print('');

  final results = <BenchmarkResult>[
    _sequentialTypedWrites(schema, operations),
    _randomRecordUpdates(schema, operations),
    _transactionThroughput(schema, operations),
    _subscriptionDispatch(schema, operations),
    _fieldFilteredDispatch(schema, operations),
    _wideFieldFilteredDispatch(operations),
    _frameStyleCoalescing(schema, operations),
    _allocationAndSlotReuse(schema, operations),
    _objectBaseline(operations),
    _changeNotifierStyleBaseline(operations),
  ];

  for (final result in results) {
    result.printReport();
    _benchmarkSink ^= result.checksum;
  }

  final endRss = _currentRss();
  if (endRss != null && startRss != null) {
    final delta = endRss - startRss;
    print('');
    print('Resident memory after benchmarks: $endRss bytes');
    print('Process RSS delta: $delta bytes');
    print(
      'RSS is process-wide and includes the Dart VM, so it is not attributed '
      'to a single workload.',
    );
  }
  print('Benchmark sink: $_benchmarkSink');
}

BenchmarkResult _sequentialTypedWrites(
  _BenchmarkSchema schema,
  int operations,
) {
  final fixture = _Fixture(schema);
  try {
    return measureBenchmark(
      name: 'sequential typed writes',
      operations: operations,
      warmupOperations: _warmupCount(operations),
      body: (count) {
        var checksum = 0;
        for (var index = 0; index < count; index++) {
          fixture.store.update(fixture.primary, (writer) {
            writer.set(schema.value, index.toDouble());
            writer.set(schema.status, index & 0xffff);
          });
          checksum ^= fixture.store.versionOf(fixture.primary);
        }
        return BenchmarkWorkResult(
          emittedNotifications: 0,
          coalescedNotifications: 0,
          checksum: checksum,
        );
      },
    );
  } finally {
    fixture.dispose();
  }
}

BenchmarkResult _randomRecordUpdates(
  _BenchmarkSchema schema,
  int operations,
) {
  final fixture = _Fixture(schema);
  final handles = <RecordHandle>[
    fixture.primary,
    ...List<RecordHandle>.generate(
      _randomRecordCount - 1,
      (_) => fixture.store.allocate(schema.layout),
      growable: false,
    ),
  ];
  final workload = DeterministicWorkload();

  try {
    return measureBenchmark(
      name: 'random record updates',
      operations: operations,
      warmupOperations: _warmupCount(operations),
      body: (count) {
        var checksum = 0;
        for (var index = 0; index < count; index++) {
          final handle = handles[workload.nextIndex(handles.length)];
          final value = workload.nextValue();
          fixture.store.update(handle, (writer) {
            writer.set(schema.value, value);
            writer.set(schema.status, index & 0xffff);
          });
          checksum ^= fixture.store.versionOf(handle);
        }
        return BenchmarkWorkResult(
          emittedNotifications: 0,
          coalescedNotifications: 0,
          checksum: checksum,
        );
      },
    );
  } finally {
    fixture.dispose();
  }
}

BenchmarkResult _transactionThroughput(
  _BenchmarkSchema schema,
  int operations,
) {
  final fixture = _Fixture(schema);
  final second = fixture.store.allocate(schema.layout);

  try {
    return measureBenchmark(
      name: 'two-record transaction throughput',
      operations: operations,
      warmupOperations: _warmupCount(operations),
      body: (count) {
        var checksum = 0;
        for (var index = 0; index < count; index++) {
          fixture.store.transaction<void>((transaction) {
            transaction.write(fixture.primary).set(
                  schema.value,
                  index.toDouble() + 0.25,
                );
            transaction.write(second).set(schema.status, index & 0xffff);
          });
          checksum ^= fixture.store.versionOf(fixture.primary);
          checksum ^= fixture.store.versionOf(second);
        }
        return BenchmarkWorkResult(
          emittedNotifications: 0,
          coalescedNotifications: 0,
          checksum: checksum,
        );
      },
    );
  } finally {
    fixture.dispose();
  }
}

BenchmarkResult _subscriptionDispatch(
  _BenchmarkSchema schema,
  int operations,
) {
  final fixture = _Fixture(schema);
  var delivered = 0;
  var checksum = 0;

  for (var index = 0; index < _subscriptionCount; index++) {
    fixture.store.watch(
      fixture.primary,
      listener: (change) {
        delivered++;
        checksum ^= change.version;
      },
    );
  }

  try {
    return measureBenchmark(
      name: 'immediate subscription dispatch',
      operations: operations,
      warmupOperations: _warmupCount(operations),
      body: (count) {
        delivered = 0;
        checksum = 0;
        for (var index = 0; index < count; index++) {
          fixture.store.update(fixture.primary, (writer) {
            writer.set(schema.value, index.toDouble() + 0.5);
          });
        }
        return BenchmarkWorkResult(
          emittedNotifications: delivered,
          coalescedNotifications: 0,
          checksum: checksum,
        );
      },
    );
  } finally {
    fixture.dispose();
  }
}

BenchmarkResult _fieldFilteredDispatch(
  _BenchmarkSchema schema,
  int operations,
) {
  final fixture = _Fixture(schema);
  var delivered = 0;
  var checksum = 0;

  for (var index = 0; index < _subscriptionCount; index++) {
    fixture.store.watch(
      fixture.primary,
      fields: schema.value.mask,
      listener: (change) {
        delivered++;
        checksum ^= change.version;
      },
    );
    fixture.store.watch(
      fixture.primary,
      fields: schema.status.mask,
      listener: (_) {
        throw StateError(
          'A status-only listener received a value-only change.',
        );
      },
    );
  }

  try {
    return measureBenchmark(
      name: 'field-filtered dispatch',
      operations: operations,
      warmupOperations: _warmupCount(operations),
      body: (count) {
        delivered = 0;
        checksum = 0;
        for (var index = 0; index < count; index++) {
          fixture.store.update(fixture.primary, (writer) {
            writer.set(schema.value, index.toDouble() + 0.75);
          });
        }
        return BenchmarkWorkResult(
          emittedNotifications: delivered,
          coalescedNotifications: 0,
          checksum: checksum,
        );
      },
    );
  } finally {
    fixture.dispose();
  }
}

BenchmarkResult _wideFieldFilteredDispatch(int operations) {
  final fixture = _WideFixture();
  final schema = fixture.schema;
  final FieldSelection selected = schema.layout.selectionFor(
    <Field<Object?>>[
      schema.fields[0],
      schema.fields[31],
      schema.changedField,
    ],
  );
  final FieldSelection notSelected = schema.layout.selectionFor(
    <Field<Object?>>[
      schema.fields[1],
      schema.fields[32],
    ],
  );
  var delivered = 0;
  var checksum = 0;
  var value = 0;

  for (var index = 0; index < _subscriptionCount; index++) {
    fixture.store.watch(
      fixture.primary,
      selection: selected,
      listener: (change) {
        delivered++;
        if (!change.fieldSelection.contains(schema.changedField)) {
          throw StateError('A selected wide field was not present in change.');
        }
        checksum ^= change.version;
      },
    );
    fixture.store.watch(
      fixture.primary,
      selection: notSelected,
      listener: (_) {
        throw StateError(
          'A non-matching wide selection received a changed-field update.',
        );
      },
    );
  }

  try {
    return measureBenchmark(
      name: 'wide (63-field) selection dispatch',
      operations: operations,
      warmupOperations: _warmupCount(operations),
      body: (count) {
        delivered = 0;
        checksum = 0;
        for (var index = 0; index < count; index++) {
          fixture.store.update(fixture.primary, (writer) {
            writer.set(schema.changedField, ++value);
          });
        }
        return BenchmarkWorkResult(
          emittedNotifications: delivered,
          coalescedNotifications: 0,
          checksum: checksum,
        );
      },
    );
  } finally {
    fixture.dispose();
  }
}

BenchmarkResult _frameStyleCoalescing(
  _BenchmarkSchema schema,
  int operations,
) {
  final fixture = _Fixture(schema);
  var delivered = 0;
  var checksum = 0;

  fixture.store.watch(
    fixture.primary,
    fields: schema.value.mask,
    policy: DeliveryPolicy.latest,
    listener: (change) {
      delivered++;
      checksum ^= change.version;
      checksum ^= change.fieldMask;
    },
  );

  try {
    return measureBenchmark(
      name: 'frame-style latest coalescing',
      operations: operations,
      warmupOperations: _warmupCount(operations),
      body: (count) {
        delivered = 0;
        checksum = 0;
        final beforeCoalesced = fixture.store.latestCoalescedDeliveryCount;
        for (var index = 0; index < count; index++) {
          fixture.store.update(fixture.primary, (writer) {
            writer.set(schema.value, index.toDouble() + 0.125);
          });
          if ((index + 1) % _frameStyleBatchSize == 0) {
            fixture.store.flush();
          }
        }
        fixture.store.flush();
        return BenchmarkWorkResult(
          emittedNotifications: delivered,
          coalescedNotifications:
              fixture.store.latestCoalescedDeliveryCount - beforeCoalesced,
          checksum: checksum,
        );
      },
    );
  } finally {
    fixture.dispose();
  }
}

BenchmarkResult _allocationAndSlotReuse(
  _BenchmarkSchema schema,
  int operations,
) {
  final store = PulseStore(
    segmentCapacity: 64,
    journalCapacity: 64,
  );

  try {
    return measureBenchmark(
      name: 'allocation and slot reuse',
      operations: operations,
      warmupOperations: _warmupCount(operations),
      body: (count) {
        var checksum = 0;
        for (var index = 0; index < count; index++) {
          final handle = store.allocate(schema.layout);
          checksum ^= handle.generation;
          store.release(handle);
        }
        checksum ^= store.segmentCount;
        checksum ^= store.totalCapacity;
        return BenchmarkWorkResult(
          emittedNotifications: 0,
          coalescedNotifications: 0,
          checksum: checksum,
        );
      },
    );
  } finally {
    store.dispose();
  }
}

BenchmarkResult _objectBaseline(int operations) {
  final record = ObjectBaselineRecord();

  return measureBenchmark(
    name: 'conventional object baseline',
    operations: operations,
    warmupOperations: _warmupCount(operations),
    body: (count) {
      var checksum = 0;
      for (var index = 0; index < count; index++) {
        record.value = index.toDouble() + 0.5;
        record.status = index & 0xffff;
        checksum ^= record.status;
      }
      return BenchmarkWorkResult(
        emittedNotifications: 0,
        coalescedNotifications: 0,
        checksum: checksum,
      );
    },
  );
}

BenchmarkResult _changeNotifierStyleBaseline(int operations) {
  final record = ObjectBaselineRecord();
  final notifier = ChangeNotifierStyleBaseline();
  var delivered = 0;
  var checksum = 0;

  for (var index = 0; index < _subscriptionCount; index++) {
    notifier.addListener(() {
      delivered++;
      checksum ^= record.status;
    });
  }

  return measureBenchmark(
    name: 'ChangeNotifier-style baseline',
    operations: operations,
    warmupOperations: _warmupCount(operations),
    body: (count) {
      delivered = 0;
      checksum = 0;
      for (var index = 0; index < count; index++) {
        record.value = index.toDouble() + 0.5;
        record.status = index & 0xffff;
        notifier.notifyListeners();
      }
      return BenchmarkWorkResult(
        emittedNotifications: delivered,
        coalescedNotifications: 0,
        checksum: checksum,
      );
    },
  );
}

int _readOperationCount() {
  final raw = Platform.environment['PULSE_SLAB_BENCHMARK_OPERATIONS'];
  if (raw == null || raw.isEmpty) {
    return _defaultOperations;
  }
  final parsed = int.tryParse(raw);
  if (parsed == null || parsed <= 0) {
    throw ArgumentError.value(
      raw,
      'PULSE_SLAB_BENCHMARK_OPERATIONS',
      'Must be a positive integer.',
    );
  }
  return parsed;
}

int _warmupCount(int operations) {
  if (operations < 1000) {
    return operations;
  }
  return 1000;
}

int? _currentRss() {
  try {
    return ProcessInfo.currentRss;
  } on UnsupportedError {
    return null;
  }
}

final class _BenchmarkSchema {
  final Float64Field value = Float64Field('value');
  final Uint16Field status = Uint16Field('status');

  late final RecordLayout layout = RecordLayout(
    name: 'BenchmarkRecord',
    fields: <Field<Object?>>[value, status],
  );
}

final class _Fixture {
  _Fixture(this.schema)
      : store = PulseStore(
          segmentCapacity: 256,
          journalCapacity: 2048,
        ) {
    primary = store.allocate(schema.layout);
  }

  final _BenchmarkSchema schema;
  final PulseStore store;
  late final RecordHandle primary;

  void dispose() {
    store.dispose();
  }
}

final class _WideBenchmarkSchema {
  static const int fieldCount = 63;

  final List<Uint32Field> fields = List<Uint32Field>.generate(
    fieldCount,
    (index) => Uint32Field('wide_value_$index'),
    growable: false,
  );

  late final RecordLayout layout = RecordLayout(
    name: 'WideBenchmarkRecord',
    fields: fields,
  );

  Uint32Field get changedField => fields.last;
}

final class _WideFixture {
  _WideFixture()
      : store = PulseStore(
          segmentCapacity: 256,
          journalCapacity: 2048,
        ) {
    primary = store.allocate(schema.layout);
  }

  final _WideBenchmarkSchema schema = _WideBenchmarkSchema();
  final PulseStore store;
  late final RecordHandle primary;

  void dispose() {
    store.dispose();
  }
}
