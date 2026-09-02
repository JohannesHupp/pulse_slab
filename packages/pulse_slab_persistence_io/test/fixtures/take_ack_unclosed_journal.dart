import 'dart:io';

import 'package:pulse_slab/pulse_slab.dart';
import 'package:pulse_slab_persistence_io/pulse_slab_persistence_io.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Expected one journal directory path.');
    exitCode = 64;
    return;
  }

  final FileStorePersistence persistence = await FileStorePersistence.open(
    directory: Directory(arguments.single),
  );
  persistence.append(_batch(version: 1, bytes: <int>[1, 6, 1]));
  persistence.append(_batch(version: 2, bytes: <int>[2, 7, 1]));

  final StorePersistenceReplayDelivery delivery =
      (await persistence.replayConsumer.take())!;
  if (delivery.sequence != 1) {
    stderr.writeln('Expected the first replay delivery.');
    exitCode = 1;
    return;
  }
  await persistence.replayConsumer.acknowledge(delivery);

  // Deliberately bypass FileStorePersistence.close(). The parent integration
  // test verifies that take establishes the capture durability boundary and
  // that the durable acknowledgement survives process termination.
  exit(0);
}

StoreCaptureBatch _batch({required int version, required List<int> bytes}) {
  return StoreCaptureBatch.incremental(<StoreCaptureOperation>[
    StoreCaptureSnapshot(
      record: StoreCaptureRecordId(segment: 0, slot: 1, generation: 1),
      layout: StorePersistenceLayout(identity: 'take-ack-recovery'),
      version: version,
      bytes: Uint8List.fromList(bytes),
    ),
  ]);
}
