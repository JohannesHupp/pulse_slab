import 'dart:io';

import 'package:pulse_slab/pulse_slab.dart';
import 'package:pulse_slab_persistence_io/pulse_slab_persistence_io.dart';
import 'package:test/test.dart';

void main() {
  group('FileStorePersistence', () {
    test(
        'persists ordered captures and replays unacknowledged data after reopen',
        () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));

      final StoreCaptureBatch first = _snapshotBatch(1, <int>[1, 2]);
      final StoreCaptureBatch second = _snapshotBatch(2, <int>[3, 4]);
      final int firstPayloadBytes = first.encode().lengthInBytes;
      final int secondPayloadBytes = second.encode().lengthInBytes;
      final int maxSegmentBytes = 48 +
          (firstPayloadBytes > secondPayloadBytes
              ? firstPayloadBytes
              : secondPayloadBytes);
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: 4096,
        maxJournalBytes: maxSegmentBytes * 3,
        maxSegmentBytes: maxSegmentBytes,
      );
      persistence.append(first);
      persistence.append(second);
      await persistence.flush();
      expect(await _journalSegmentFiles(directory), hasLength(2));

      final StorePersistenceReplayConsumer replay = persistence.replayConsumer;
      final StorePersistenceReplayDelivery firstDelivery =
          (await replay.take())!;
      expect(firstDelivery.sequence, 1);
      expect(_snapshotBytes(firstDelivery.batch), orderedEquals(<int>[1, 2]));
      await expectLater(replay.take(), throwsStateError);

      await replay.retry(firstDelivery);
      final StorePersistenceReplayDelivery retried = (await replay.take())!;
      expect(retried.sequence, 1);
      expect(_snapshotBytes(retried.batch), orderedEquals(<int>[1, 2]));
      await replay.acknowledge(retried);

      final StorePersistenceReplayDelivery secondDelivery =
          (await replay.take())!;
      expect(secondDelivery.sequence, 2);
      expect(_snapshotBytes(secondDelivery.batch), orderedEquals(<int>[3, 4]));
      await persistence.close();

      final FileStorePersistence reopened = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: 4096,
        maxJournalBytes: maxSegmentBytes * 3,
        maxSegmentBytes: maxSegmentBytes,
      );
      addTearDown(reopened.close);
      final StorePersistenceReplayDelivery replayed =
          (await reopened.replayConsumer.take())!;
      expect(replayed.sequence, 2);
      expect(_snapshotBytes(replayed.batch), orderedEquals(<int>[3, 4]));
      await reopened.replayConsumer.acknowledge(replayed);
      expect(await reopened.replayConsumer.take(), isNull);
    });

    test('recovers a flushed capture after a process exits without close',
        () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));

      final ProcessResult writer = await Process.run(
        Platform.resolvedExecutable,
        <String>[
          'run',
          'test/fixtures/write_unclosed_journal.dart',
          directory.path,
        ],
        workingDirectory: Directory.current.path,
      );
      expect(
        writer.exitCode,
        0,
        reason: 'Unclosed writer failed: ${writer.stderr}',
      );

      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
      );
      addTearDown(persistence.close);
      final StorePersistenceReplayDelivery delivery =
          (await persistence.replayConsumer.take())!;
      expect(delivery.sequence, 1);
      expect(_snapshotBytes(delivery.batch), orderedEquals(<int>[3, 1, 4]));
      await persistence.replayConsumer.acknowledge(delivery);
    });

    test('rejects a capture that cannot fit into an empty segment', () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final StoreCaptureBatch batch = _snapshotBatch(1, <int>[6, 7, 8]);
      final int payloadBytes = batch.encode().lengthInBytes;
      final int requiredSegmentBytes = 48 + payloadBytes;
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: payloadBytes,
        maxJournalBytes: requiredSegmentBytes * 2,
        maxSegmentBytes: requiredSegmentBytes - 1,
      );
      addTearDown(persistence.close);

      expect(
        () => persistence.append(batch),
        throwsA(
          isA<StorePersistenceBackpressureException>().having(
            (StorePersistenceBackpressureException error) => error.batchBytes,
            'batchBytes',
            requiredSegmentBytes,
          ),
        ),
      );
      expect(persistence.pendingBytes, 0);
      expect(persistence.journalBytes, 0);
      expect(await persistence.replayConsumer.take(), isNull);
    });

    test('requires journal capacity for two maximum-size segments', () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));

      await expectLater(
        FileStorePersistence.open(
          directory: directory,
          maxJournalBytes: 255,
          maxSegmentBytes: 128,
        ),
        throwsRangeError,
      );
    });

    test('enforces byte backpressure without dropping accepted captures',
        () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final StoreCaptureBatch batch = _snapshotBatch(1, <int>[1, 2, 3, 4]);
      final int batchBytes = batch.encode().lengthInBytes;
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: batchBytes * 2,
        maxJournalBytes: 4096,
        maxSegmentBytes: 512,
      );
      addTearDown(persistence.close);

      persistence.append(batch);
      persistence.append(batch);
      expect(persistence.pendingBytes, batchBytes * 2);
      expect(
        () => persistence.append(batch),
        throwsA(
          isA<StorePersistenceBackpressureException>().having(
            (StorePersistenceBackpressureException error) => error.pendingBytes,
            'pendingBytes',
            batchBytes * 2,
          ),
        ),
      );

      await persistence.flush();
      final StorePersistenceReplayDelivery first =
          (await persistence.replayConsumer.take())!;
      await persistence.replayConsumer.acknowledge(first);
      expect(persistence.pendingBytes, batchBytes);
      persistence.append(batch);
      expect(persistence.pendingBytes, batchBytes * 2);
    });

    test('bounds retained physical journal bytes and reclaims closed segments',
        () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final StoreCaptureBatch batch = _snapshotBatch(1, <int>[7, 8, 9]);
      final int payloadBytes = batch.encode().lengthInBytes;
      final int segmentBytes = 48 + payloadBytes;
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: payloadBytes * 4,
        maxJournalBytes: segmentBytes * 2,
        maxSegmentBytes: segmentBytes,
      );
      addTearDown(persistence.close);

      persistence.append(batch);
      persistence.append(batch);
      expect(persistence.journalBytes, segmentBytes * 2);
      expect(
        () => persistence.append(batch),
        throwsA(
          isA<StorePersistenceBackpressureException>().having(
            (StorePersistenceBackpressureException error) => error.pendingBytes,
            'pendingBytes',
            segmentBytes * 2,
          ),
        ),
      );

      final StorePersistenceReplayDelivery first =
          (await persistence.replayConsumer.take())!;
      await persistence.replayConsumer.acknowledge(first);
      expect(persistence.journalBytes, segmentBytes * 2);

      final StorePersistenceReplayDelivery second =
          (await persistence.replayConsumer.take())!;
      await persistence.replayConsumer.acknowledge(second);
      expect(persistence.journalBytes, segmentBytes);

      persistence.append(batch);
      expect(persistence.journalBytes, segmentBytes * 2);
      final StorePersistenceReplayDelivery third =
          (await persistence.replayConsumer.take())!;
      expect(third.sequence, 3);
    });

    test('reclaims only fully acknowledged closed segments', () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final StoreCaptureBatch batch = _snapshotBatch(1, <int>[2, 4]);
      final int payloadBytes = batch.encode().lengthInBytes;
      final int oneFrameSegmentBytes = 48 + payloadBytes;
      final int twoFrameSegmentBytes = 72 + (payloadBytes * 2);
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: payloadBytes * 4,
        maxJournalBytes: twoFrameSegmentBytes * 2,
        maxSegmentBytes: twoFrameSegmentBytes,
      );
      addTearDown(persistence.close);

      persistence.append(batch);
      persistence.append(batch);
      persistence.append(batch);
      await persistence.flush();
      expect(await _journalSegmentFiles(directory), hasLength(2));
      expect(
        persistence.journalBytes,
        twoFrameSegmentBytes + oneFrameSegmentBytes,
      );

      final StorePersistenceReplayDelivery first =
          (await persistence.replayConsumer.take())!;
      await persistence.replayConsumer.acknowledge(first);
      expect(
        persistence.journalBytes,
        twoFrameSegmentBytes + oneFrameSegmentBytes,
      );

      final StorePersistenceReplayDelivery second =
          (await persistence.replayConsumer.take())!;
      await persistence.replayConsumer.acknowledge(second);
      expect(
        persistence.journalBytes,
        twoFrameSegmentBytes + oneFrameSegmentBytes,
      );

      final StorePersistenceReplayDelivery third =
          (await persistence.replayConsumer.take())!;
      await persistence.replayConsumer.acknowledge(third);
      expect(persistence.journalBytes, oneFrameSegmentBytes);
      expect(await _journalSegmentFiles(directory), hasLength(1));
      final List<File> acknowledgementFiles =
          await _acknowledgementFiles(directory);
      expect(acknowledgementFiles, hasLength(2));
      for (final File acknowledgementFile in acknowledgementFiles) {
        expect(await acknowledgementFile.length(), 32);
      }
    });

    test('validates journal corruption instead of discarding bytes', () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
      );
      persistence.append(_snapshotBatch(1, <int>[9, 8, 7]));
      await persistence.flush();
      await persistence.close();

      final File segment = (await _journalSegmentFiles(directory)).single;
      final List<int> bytes = await segment.readAsBytes();
      bytes[bytes.length - 1] ^= 0xff;
      await segment.writeAsBytes(bytes, flush: true);

      await expectLater(
        FileStorePersistence.open(directory: directory),
        throwsA(isA<FileStorePersistenceException>()),
      );
    });

    test('falls back to the prior acknowledgement checkpoint after corruption',
        () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final StoreCaptureBatch batch = _snapshotBatch(1, <int>[4, 2]);
      final int payloadBytes = batch.encode().lengthInBytes;
      final int segmentBytes = 48 + payloadBytes;
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: payloadBytes * 4,
        maxJournalBytes: segmentBytes * 4,
        maxSegmentBytes: segmentBytes,
      );
      persistence.append(batch);
      persistence.append(batch);
      persistence.append(batch);
      for (var index = 0; index < 2; index++) {
        final StorePersistenceReplayDelivery delivery =
            (await persistence.replayConsumer.take())!;
        await persistence.replayConsumer.acknowledge(delivery);
      }
      await persistence.close();

      final File newestCheckpoint = File(
        '${directory.path}${Platform.pathSeparator}'
        'pulse_store.capture.journal.metadata${Platform.pathSeparator}'
        'pulse_store.capture.ack.b',
      );
      await newestCheckpoint.writeAsBytes(<int>[0], flush: true);

      final FileStorePersistence reopened = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: payloadBytes * 4,
        maxJournalBytes: segmentBytes * 4,
        maxSegmentBytes: segmentBytes,
      );
      addTearDown(reopened.close);
      final StorePersistenceReplayDelivery replayedSecond =
          (await reopened.replayConsumer.take())!;
      expect(replayedSecond.sequence, 2);
      await reopened.replayConsumer.acknowledge(replayedSecond);
      final StorePersistenceReplayDelivery replayedThird =
          (await reopened.replayConsumer.take())!;
      expect(replayedThird.sequence, 3);
    });

    test('fails open when every acknowledgement checkpoint is invalid',
        () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final StoreCaptureBatch batch = _snapshotBatch(1, <int>[5]);
      final int payloadBytes = batch.encode().lengthInBytes;
      final int segmentBytes = 48 + payloadBytes;
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: payloadBytes * 3,
        maxJournalBytes: segmentBytes * 3,
        maxSegmentBytes: segmentBytes,
      );
      persistence.append(batch);
      persistence.append(batch);
      for (var index = 0; index < 2; index++) {
        final StorePersistenceReplayDelivery delivery =
            (await persistence.replayConsumer.take())!;
        await persistence.replayConsumer.acknowledge(delivery);
      }
      await persistence.close();

      for (final File acknowledgementFile
          in await _acknowledgementFiles(directory)) {
        await acknowledgementFile.writeAsBytes(<int>[0], flush: true);
      }

      await expectLater(
        FileStorePersistence.open(
          directory: directory,
          maxPendingBytes: payloadBytes * 3,
          maxJournalBytes: segmentBytes * 3,
          maxSegmentBytes: segmentBytes,
        ),
        throwsA(isA<FileStorePersistenceException>()),
      );
    });

    test('scopes acknowledgement metadata to each journal name', () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final StoreCaptureBatch batch = _snapshotBatch(1, <int>[1]);
      final FileStorePersistence first = await FileStorePersistence.open(
        directory: directory,
        journalFileName: 'first.journal',
        acknowledgementFileName: 'shared.ack',
      );
      final FileStorePersistence second = await FileStorePersistence.open(
        directory: directory,
        journalFileName: 'second.journal',
        acknowledgementFileName: 'shared.ack',
      );
      addTearDown(first.close);
      addTearDown(second.close);

      first.append(batch);
      second.append(batch);
      final StorePersistenceReplayDelivery firstDelivery =
          (await first.replayConsumer.take())!;
      final StorePersistenceReplayDelivery secondDelivery =
          (await second.replayConsumer.take())!;
      await first.replayConsumer.acknowledge(firstDelivery);
      await second.replayConsumer.acknowledge(secondDelivery);

      expect(
        await File(
          '${directory.path}${Platform.pathSeparator}'
          'first.journal.metadata${Platform.pathSeparator}shared.ack.a',
        ).exists(),
        isTrue,
      );
      expect(
        await File(
          '${directory.path}${Platform.pathSeparator}'
          'second.journal.metadata${Platform.pathSeparator}shared.ack.a',
        ).exists(),
        isTrue,
      );
    });

    test('rejects concurrent or stale replay completion deterministically',
        () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
      );
      addTearDown(persistence.close);
      persistence.append(_snapshotBatch(1, <int>[1]));

      final StorePersistenceReplayDelivery delivery =
          (await persistence.replayConsumer.take())!;
      final StorePersistenceReplayDelivery stale =
          StorePersistenceReplayDelivery(
        sequence: delivery.sequence,
        batch: delivery.batch,
      );
      await expectLater(
        persistence.replayConsumer.acknowledge(stale),
        throwsStateError,
      );
      await persistence.replayConsumer.acknowledge(delivery);
      await expectLater(
        persistence.replayConsumer.retry(delivery),
        throwsStateError,
      );
    });

    test('recovers a checkpoint and multi-record store changes after restart',
        () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final Uint8Field value = Uint8Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'persistent-sensor',
        fields: <Field<Object?>>[value],
      );
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: 4096,
      );
      final PulseStore store = PulseStore(persistence: persistence);
      final RecordHandle first = store.allocate(layout);
      final RecordHandle second = store.allocate(layout);
      store.capturePersistenceCheckpoint();
      store.transaction((WriteTransaction transaction) {
        transaction.write(first).set(value, 41);
        transaction.write(second).set(value, 99);
      });
      store.release(first);
      store.dispose();
      await persistence.flush();
      await persistence.close();

      final FileStorePersistence reopened = await FileStorePersistence.open(
        directory: directory,
        maxPendingBytes: 4096,
      );
      addTearDown(reopened.close);
      final StoreCaptureReplayer replayer = StoreCaptureReplayer();
      var checkpoints = 0;
      var incrementals = 0;
      while (true) {
        final StorePersistenceReplayDelivery? delivery =
            await reopened.replayConsumer.take();
        if (delivery == null) {
          break;
        }
        switch (delivery.batch.kind) {
          case StoreCaptureBatchKind.checkpoint:
            checkpoints++;
          case StoreCaptureBatchKind.incremental:
            incrementals++;
        }
        replayer.apply(delivery.batch);
        await reopened.replayConsumer.acknowledge(delivery);
      }

      expect(checkpoints, 1);
      expect(incrementals, greaterThanOrEqualTo(4));
      expect(replayer.records, hasLength(1));
      final StoreCaptureSnapshot snapshot = replayer.records.single;
      expect(snapshot.record.segment, second.segment);
      expect(snapshot.record.slot, second.slot);
      expect(snapshot.record.generation, second.generation);
      expect(snapshot.layout.identity, 'persistent-sensor');
      expect(snapshot.layout.version, 1);
      expect(snapshot.version, 1);
      expect(snapshot.copyBytes(), orderedEquals(<int>[99]));
    });

    test('close releases the worker and rejects later appends', () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
      );
      persistence.append(_snapshotBatch(1, <int>[1]));
      await persistence.close();
      expect(persistence.isClosing, isTrue);
      expect(
        () => persistence.append(_snapshotBatch(2, <int>[2])),
        throwsStateError,
      );

      // Reopening proves the long-lived isolate released its exclusive lock.
      final FileStorePersistence reopened = await FileStorePersistence.open(
        directory: directory,
      );
      addTearDown(reopened.close);
      expect((await reopened.replayConsumer.take())!.sequence, 1);
    });

    test('rejects a second owner for the same journal in one isolate',
        () async {
      final Directory directory = await _temporaryDirectory();
      addTearDown(() => directory.delete(recursive: true));
      final FileStorePersistence persistence = await FileStorePersistence.open(
        directory: directory,
      );
      addTearDown(persistence.close);

      await expectLater(
        FileStorePersistence.open(directory: directory),
        throwsStateError,
      );
    });
  });
}

Future<Directory> _temporaryDirectory() =>
    Directory.systemTemp.createTemp('pulse_slab_persistence_io_test_');

StoreCaptureBatch _snapshotBatch(int version, List<int> bytes) {
  final StoreCaptureRecordId record = StoreCaptureRecordId(
    segment: 0,
    slot: 1,
    generation: 1,
  );
  return StoreCaptureBatch.incremental(<StoreCaptureOperation>[
    StoreCaptureSnapshot(
      record: record,
      layout: StorePersistenceLayout(identity: 'sensor', version: 1),
      version: version,
      bytes: Uint8List.fromList(bytes),
    ),
  ]);
}

Uint8List _snapshotBytes(StoreCaptureBatch batch) =>
    (batch.operations.single as StoreCaptureSnapshot).copyBytes();

Future<List<File>> _journalSegmentFiles(Directory directory) async {
  final Directory segmentDirectory = Directory(
    '${directory.path}${Platform.pathSeparator}'
    'pulse_store.capture.journal.segments',
  );
  if (!await segmentDirectory.exists()) {
    return <File>[];
  }
  final List<File> files = <File>[];
  await for (final FileSystemEntity entity
      in segmentDirectory.list(followLinks: false)) {
    if (entity is File) {
      files.add(entity);
    }
  }
  files.sort((File left, File right) => left.path.compareTo(right.path));
  return files;
}

Future<List<File>> _acknowledgementFiles(Directory directory) async {
  final List<File> files = <File>[];
  for (final String suffix in <String>['a', 'b']) {
    final File file = File(
      '${directory.path}${Platform.pathSeparator}'
      'pulse_store.capture.journal.metadata${Platform.pathSeparator}'
      'pulse_store.capture.ack.$suffix',
    );
    if (await file.exists()) {
      files.add(file);
    }
  }
  return files;
}
