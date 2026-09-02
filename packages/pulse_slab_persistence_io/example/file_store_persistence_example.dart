import 'dart:io';

import 'package:pulse_slab/pulse_slab.dart';
import 'package:pulse_slab_persistence_io/pulse_slab_persistence_io.dart';

Future<void> main() async {
  final Float32Field temperature = Float32Field('temperature');
  final RecordLayout sensorLayout = RecordLayout(
    name: 'SensorState',
    fields: <Field<Object?>>[temperature],
  );
  final Directory journalDirectory = await Directory.systemTemp.createTemp(
    'pulse-slab-capture-',
  );

  try {
    final FileStorePersistence persistence = await FileStorePersistence.open(
      directory: journalDirectory,
    );
    try {
      final PulseStore store = PulseStore(persistence: persistence);
      try {
        final RecordHandle sensor = store.allocate(sensorLayout);

        store.capturePersistenceCheckpoint();
        store.update(sensor, (TransactionRecordWriter writer) {
          writer.set(temperature, 21.5);
        });
      } finally {
        store.dispose();
      }
      await persistence.flush();
    } finally {
      await persistence.close();
    }

    final FileStorePersistence reopened = await FileStorePersistence.open(
      directory: journalDirectory,
    );
    try {
      final StoreCaptureReplayer replayer = StoreCaptureReplayer();
      while (true) {
        final StorePersistenceReplayDelivery? delivery =
            await reopened.replayConsumer.take();
        if (delivery == null) {
          break;
        }
        replayer.apply(delivery.batch);
        await reopened.replayConsumer.acknowledge(delivery);
      }

      print('Recovered ${replayer.records.length} record(s).');
    } finally {
      await reopened.close();
    }
  } finally {
    await journalDirectory.delete(recursive: true);
  }
}
