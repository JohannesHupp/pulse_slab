import 'dart:io';

import 'package:pulse_slab/pulse_slab.dart';
import 'package:pulse_slab_persistence_io/pulse_slab_persistence_io.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Expected one journal directory path.');
    exitCode = 64;
    return;
  }

  final StoreCaptureBatch first = _batch(version: 1);
  final int payloadBytes = first.encode().lengthInBytes;
  final int maxSegmentBytes = 48 + payloadBytes;
  final FileStorePersistence persistence = await FileStorePersistence.open(
    directory: Directory(arguments.single),
    maxPendingBytes: payloadBytes * 2,
    maxJournalBytes: maxSegmentBytes * 2,
    maxSegmentBytes: maxSegmentBytes,
  );
  persistence.append(first);
  persistence.append(_batch(version: 2));

  final Directory segmentDirectory = Directory(
    '${arguments.single}${Platform.pathSeparator}'
    'pulse_store.capture.journal.segments',
  );
  for (var attempt = 0; attempt < 100; attempt++) {
    if (!await segmentDirectory.exists()) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      continue;
    }
    final List<File> files = <File>[];
    await for (final FileSystemEntity entity
        in segmentDirectory.list(followLinks: false)) {
      if (entity is File) {
        files.add(entity);
      }
    }
    final List<int> lengths = await Future.wait<int>(
      files.map((File file) => file.length()),
    );
    if (files.length == 2 &&
        lengths.every((int length) => length == maxSegmentBytes)) {
      // Deliberately bypass FileStorePersistence.close(). The parent test
      // verifies recovery of the unsealed, exactly-full final segment.
      exit(0);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  stderr.writeln('The worker did not write two full journal segments.');
  exitCode = 1;
}

StoreCaptureBatch _batch({required int version}) {
  return StoreCaptureBatch.incremental(<StoreCaptureOperation>[
    StoreCaptureSnapshot(
      record: StoreCaptureRecordId(segment: 0, slot: 1, generation: 1),
      layout: StorePersistenceLayout(identity: 'sensor', version: 1),
      version: version,
      bytes: Uint8List.fromList(<int>[4, 8]),
    ),
  ]);
}
