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
  persistence.append(
    StoreCaptureBatch.incremental(<StoreCaptureOperation>[
      StoreCaptureSnapshot(
        record: StoreCaptureRecordId(segment: 0, slot: 1, generation: 1),
        layout: StorePersistenceLayout(identity: 'crash-recovery'),
        version: 1,
        bytes: Uint8List.fromList(<int>[3, 1, 4]),
      ),
    ]),
  );
  await persistence.flush();

  // Deliberately bypass FileStorePersistence.close(). The parent integration
  // test verifies that a new process can recover the flushed capture.
  exit(0);
}
