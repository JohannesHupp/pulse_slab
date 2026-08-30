import 'dart:math' as math;

import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';

/// Stable field descriptors used by the telemetry example.
final class TelemetrySchema {
  /// Timestamp of the generated sample in seconds.
  static final Float64Field timestamp = Float64Field('timestamp');

  /// Current simulated temperature.
  static final Float32Field temperature = Float32Field('temperature');

  /// Current simulated pressure.
  static final Float32Field pressure = Float32Field('pressure');

  /// Current simulated status bits.
  static final Uint16Field status = Uint16Field('status');

  /// Fixed layout shared by all simulated sensors.
  static final RecordLayout layout = RecordLayout(
    name: 'TelemetryRecord',
    fields: <Field<Object?>>[
      timestamp,
      temperature,
      pressure,
      status,
    ],
  );
}

/// Selects how one simulation batch is committed to the store.
enum TelemetryTransactionMode {
  /// Commits the whole batch in one transaction.
  merged(
    label: 'Merged transaction',
    description:
        'Processes one simulation batch as one transaction. Repeated writes '
        'to a sensor become one final record change.',
    transactionsPerBatch: 1,
  ),

  /// Commits several synchronous transactions before returning to Flutter.
  burst(
    label: 'Burst transactions',
    description:
        'Splits one simulation batch into several commits before Flutter can '
        'flush a frame. This makes frame coalescing observable.',
    transactionsPerBatch: 4,
  );

  const TelemetryTransactionMode({
    required this.label,
    required this.description,
    required this.transactionsPerBatch,
  });

  /// UI label for this mode.
  final String label;

  /// Explanation shown by the telemetry dashboard.
  final String description;

  /// Maximum number of transactions generated for one simulation batch.
  final int transactionsPerBatch;
}

/// Selects how the telemetry example observes its bounded change journal.
enum TelemetryJournalMode {
  /// Samples journal utilization and clears retained state observations.
  sampled(
    label: 'Sample and clear',
    description:
        'Uses a 1024-entry overwrite-oldest journal. The dashboard samples '
        'utilization every 250 ms and then clears replaceable observations.',
    capacity: 1024,
    overflowPolicy: JournalOverflowPolicy.overwriteOldest,
    clearsAfterSampling: true,
  ),

  /// Holds a small overwrite-oldest journal until it reaches pressure.
  overwritePressure(
    label: 'Overwrite pressure',
    description:
        'Uses a 64-entry overwrite-oldest journal and retains observations '
        'to demonstrate bounded replacement of older state changes.',
    capacity: 64,
    overflowPolicy: JournalOverflowPolicy.overwriteOldest,
    clearsAfterSampling: false,
  ),

  /// Holds a small reject-newest journal until it reaches pressure.
  rejectPressure(
    label: 'Reject-newest pressure',
    description:
        'Uses a 64-entry reject-newest journal and retains observations to '
        'demonstrate rejected journal admission while state commits continue.',
    capacity: 64,
    overflowPolicy: JournalOverflowPolicy.rejectNewest,
    clearsAfterSampling: false,
  );

  const TelemetryJournalMode({
    required this.label,
    required this.description,
    required this.capacity,
    required this.overflowPolicy,
    required this.clearsAfterSampling,
  });

  /// UI label for this mode.
  final String label;

  /// Explanation shown by the telemetry dashboard.
  final String description;

  /// Fixed journal capacity used by this diagnostic mode.
  final int capacity;

  /// Overflow behavior used by this diagnostic mode.
  final JournalOverflowPolicy overflowPolicy;

  /// Whether a metrics sample clears journal observations afterwards.
  final bool clearsAfterSampling;
}

/// Immutable configuration for one telemetry data-plane instance.
final class TelemetrySimulationConfiguration {
  /// Creates telemetry simulation configuration.
  const TelemetrySimulationConfiguration({
    this.sensorCount = 24,
    this.transactionMode = TelemetryTransactionMode.merged,
    this.journalMode = TelemetryJournalMode.sampled,
  });

  /// Number of simulated records.
  final int sensorCount;

  /// Transaction shape used for one input batch.
  final TelemetryTransactionMode transactionMode;

  /// Journal observation behavior used by the dashboard.
  final TelemetryJournalMode journalMode;
}

/// Immutable journal state observed at one metrics boundary.
final class TelemetryJournalSample {
  /// Creates a telemetry journal sample.
  const TelemetryJournalSample({
    required this.length,
    required this.capacity,
    required this.utilization,
    required this.overwrittenCount,
    required this.rejectedCount,
    required this.clearedAfterSampling,
  });

  /// Retained journal observations before any optional clear.
  final int length;

  /// Fixed capacity of the journal.
  final int capacity;

  /// Fraction of [capacity] currently occupied.
  final double utilization;

  /// Cumulative count of overwritten oldest journal observations.
  final int overwrittenCount;

  /// Cumulative count of rejected newest journal observations.
  final int rejectedCount;

  /// Whether the sample boundary clears replaceable observations afterwards.
  final bool clearedAfterSampling;
}

/// Testable, synchronous telemetry producer and store owner.
///
/// The dashboard supplies time and batches into this class. Keeping timer and
/// widget code outside the producer makes transaction compaction, frame bursts,
/// and journal pressure deterministic in tests.
final class TelemetrySimulation {
  /// Creates a telemetry data plane with deterministic random input.
  TelemetrySimulation({
    this.configuration = const TelemetrySimulationConfiguration(),
    int randomSeed = 7,
  }) : _random = math.Random(randomSeed) {
    if (configuration.sensorCount <= 0) {
      throw ArgumentError.value(
        configuration.sensorCount,
        'configuration.sensorCount',
        'Must be greater than zero.',
      );
    }

    store = PulseStore(
      segmentCapacity: 128,
      journalCapacity: configuration.journalMode.capacity,
      journalOverflowPolicy: configuration.journalMode.overflowPolicy,
    );
    handles = List<RecordHandle>.generate(
      configuration.sensorCount,
      (_) => store.allocate(TelemetrySchema.layout),
      growable: false,
    );
  }

  /// Fixed configuration for this store instance.
  final TelemetrySimulationConfiguration configuration;

  /// Store receiving all generated telemetry writes.
  late final PulseStore store;

  /// Stable handles for the simulated sensors.
  late final List<RecordHandle> handles;

  final math.Random _random;
  var _rawInputUpdateCount = 0;
  var _lastTickDistinctRecords = 0;

  /// Number of raw simulation updates submitted since construction.
  int get rawInputUpdateCount => _rawInputUpdateCount;

  /// Number of records with a net committed change since construction.
  int get committedRecordChangeCount => store.committedChangeCount;

  /// Raw inputs that did not become independent committed record changes.
  ///
  /// This includes repeated writes to one record within a transaction and any
  /// net-neutral writes. It is a compaction diagnostic, not a loss counter.
  int get transactionCompactedInputCount {
    final compacted = _rawInputUpdateCount - committedRecordChangeCount;
    return compacted < 0 ? 0 : compacted;
  }

  /// Number of distinct records with at least one changed field in the last
  /// processed simulation batch.
  int get lastTickDistinctRecords => _lastTickDistinctRecords;

  /// Processes one synthetic input batch at [timestamp] seconds.
  ///
  /// In burst mode, the batch is split into synchronous transactions before
  /// this method returns. The first update of each burst transaction targets
  /// Sensor 0 so a matching frame-coalesced listener deterministically sees
  /// several committed changes before a Flutter frame can flush.
  void processBatch({
    required int rawInputCount,
    required double timestamp,
  }) {
    if (rawInputCount < 0) {
      throw ArgumentError.value(
        rawInputCount,
        'rawInputCount',
        'Must not be negative.',
      );
    }
    if (rawInputCount == 0) {
      _lastTickDistinctRecords = 0;
      return;
    }

    final transactionCount = math.min(
      rawInputCount,
      configuration.transactionMode.transactionsPerBatch,
    );
    var remainingUpdates = rawInputCount;
    var changedRecordMask = 0;

    for (var transactionIndex = 0;
        transactionIndex < transactionCount;
        transactionIndex++) {
      final remainingTransactions = transactionCount - transactionIndex;
      final updatesInTransaction = remainingUpdates ~/ remainingTransactions;
      remainingUpdates -= updatesInTransaction;

      store.transaction((transaction) {
        for (var updateIndex = 0;
            updateIndex < updatesInTransaction;
            updateIndex++) {
          final forceSensorZero =
              configuration.transactionMode == TelemetryTransactionMode.burst &&
                  updateIndex == 0;
          final sensorIndex =
              forceSensorZero ? 0 : _random.nextInt(configuration.sensorCount);
          final phase = timestamp * (0.8 + sensorIndex * 0.03) + sensorIndex;
          final temperature =
              23.0 + math.sin(phase) * 7.0 + _random.nextDouble();
          final pressure = 1.0 + math.cos(phase * 0.5) * 0.12;
          final status = (temperature > 28.5 ? 0x01 : 0) |
              (pressure < 0.93 ? 0x02 : 0) |
              (_random.nextInt(80) == 0 ? 0x04 : 0);
          final writer = transaction.write(handles[sensorIndex]);
          var recordChanged = writer.set(TelemetrySchema.timestamp, timestamp);
          if (writer.set(TelemetrySchema.temperature, temperature)) {
            recordChanged = true;
          }
          if (writer.set(TelemetrySchema.pressure, pressure)) {
            recordChanged = true;
          }
          if (writer.set(TelemetrySchema.status, status)) {
            recordChanged = true;
          }
          if (recordChanged) {
            changedRecordMask |= 1 << sensorIndex;
          }
        }
      });
    }

    _rawInputUpdateCount += rawInputCount;
    _lastTickDistinctRecords = _countSetBits(changedRecordMask);
  }

  /// Captures journal state at a metrics boundary.
  ///
  /// Normal sampled mode clears only replaceable journal observations after the
  /// snapshot. Pressure modes retain them so their bounded behavior is visible.
  TelemetryJournalSample sampleJournal() {
    final journal = store.journal;
    final sample = TelemetryJournalSample(
      length: journal.length,
      capacity: journal.capacity,
      utilization: journal.utilization,
      overwrittenCount: journal.overwrittenCount,
      rejectedCount: journal.rejectedCount,
      clearedAfterSampling: configuration.journalMode.clearsAfterSampling,
    );
    if (sample.clearedAfterSampling) {
      journal.clear();
    }
    return sample;
  }

  /// Disposes all store-owned state.
  void dispose() => store.dispose();

  static int _countSetBits(int value) {
    var count = 0;
    var remaining = value;
    while (remaining != 0) {
      remaining &= remaining - 1;
      count++;
    }
    return count;
  }
}
