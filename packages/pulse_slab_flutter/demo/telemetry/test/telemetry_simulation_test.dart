import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';
import 'package:pulse_slab_flutter_telemetry_demo/src/telemetry_simulation.dart';

void main() {
  group('TelemetrySimulation', () {
    test('reports raw inputs, committed records, and sampled journal state',
        () {
      final simulation = TelemetrySimulation();
      addTearDown(simulation.dispose);

      simulation.processBatch(rawInputCount: 480, timestamp: 1.0);

      expect(simulation.rawInputUpdateCount, 480);
      expect(simulation.committedRecordChangeCount, greaterThan(0));
      expect(
        simulation.transactionCompactedInputCount,
        480 - simulation.committedRecordChangeCount,
      );
      expect(simulation.lastTickDistinctRecords, inInclusiveRange(1, 24));

      final sample = simulation.sampleJournal();
      expect(sample.clearedAfterSampling, isTrue);
      expect(sample.length, greaterThan(0));
      expect(sample.capacity, 1024);
      expect(simulation.store.journal.isEmpty, isTrue);
    });

    testWidgets('burst transactions deterministically coalesce before flush', (
      tester,
    ) async {
      final simulation = TelemetrySimulation(
        configuration: const TelemetrySimulationConfiguration(
          transactionMode: TelemetryTransactionMode.burst,
        ),
      );
      final listenable = ReactiveRecordListenable(
        store: simulation.store,
        handle: simulation.handles.first,
        fields: TelemetrySchema.temperature.mask,
        policy: FlutterDeliveryPolicy.manual,
      );
      addTearDown(() {
        listenable.dispose();
        simulation.dispose();
      });

      simulation.processBatch(rawInputCount: 8, timestamp: 1.0);

      expect(listenable.acceptedChanges, greaterThanOrEqualTo(4));
      expect(listenable.coalescedChanges, greaterThanOrEqualTo(3));
      expect(listenable.deliveredNotifications, 0);
      expect(listenable.flush(), isTrue);
      expect(listenable.deliveredNotifications, 1);
    });

    test('overwrite pressure retains the newest bounded observations', () {
      final simulation = TelemetrySimulation(
        configuration: const TelemetrySimulationConfiguration(
          transactionMode: TelemetryTransactionMode.burst,
          journalMode: TelemetryJournalMode.overwritePressure,
        ),
      );
      addTearDown(simulation.dispose);

      _fillPressureJournal(simulation);

      final sample = simulation.sampleJournal();
      expect(sample.clearedAfterSampling, isFalse);
      expect(sample.capacity, 64);
      expect(sample.length, sample.capacity);
      expect(sample.overwrittenCount, greaterThan(0));
      expect(sample.rejectedCount, 0);
      expect(simulation.store.journal.length, sample.capacity);
      expect(simulation.store.rejectedJournalChangeCount, 0);
    });

    test('reject-newest pressure keeps state commits and reports rejection',
        () {
      final simulation = TelemetrySimulation(
        configuration: const TelemetrySimulationConfiguration(
          transactionMode: TelemetryTransactionMode.burst,
          journalMode: TelemetryJournalMode.rejectPressure,
        ),
      );
      addTearDown(simulation.dispose);

      _fillPressureJournal(simulation);

      final sample = simulation.sampleJournal();
      expect(sample.clearedAfterSampling, isFalse);
      expect(sample.capacity, 64);
      expect(sample.length, sample.capacity);
      expect(sample.overwrittenCount, 0);
      expect(sample.rejectedCount, greaterThan(0));
      expect(simulation.committedRecordChangeCount, greaterThan(sample.length));
      expect(
        simulation.store.rejectedJournalChangeCount,
        sample.rejectedCount,
      );
    });
  });
}

void _fillPressureJournal(TelemetrySimulation simulation) {
  for (var batch = 0; batch < 24; batch++) {
    simulation.processBatch(
      rawInputCount: 4,
      timestamp: batch.toDouble() + 1.0,
    );
  }
}
