import 'dart:typed_data';

import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

void main() {
  group('ByteBatchWorker', () {
    test('processes a transferred byte batch in a long-lived worker', () async {
      final worker = await ByteBatchWorker.start();
      addTearDown(worker.close);

      final result = await worker.submit(Uint8List.fromList(<int>[1, 2, 3]));

      expect(result.sequence, 0);
      expect(result.bytes, orderedEquals(<int>[1, 2, 3]));
      expect(result.checksum, 1026);
      expect(result.frameCount, 1);

      final second = await worker.submit(Uint8List.fromList(<int>[4, 5]));
      expect(second.sequence, 1);
      expect(second.bytes, orderedEquals(<int>[4, 5]));
    });

    test('enforces a bounded number of in-flight batches', () async {
      final worker = await ByteBatchWorker.start(
        config: const ByteBatchWorkerConfig(maxInFlight: 1),
      );
      addTearDown(worker.close);

      final first = worker.submit(Uint8List.fromList(<int>[1]));
      expect(worker.inFlight, 1);
      expect(
        () => worker.submit(Uint8List.fromList(<int>[2])),
        throwsA(isA<WorkerBackpressureException>()),
      );

      await first;
      expect(worker.inFlight, 0);
    });

    test('propagates per-batch worker errors and remains usable', () async {
      final worker = await ByteBatchWorker.start(
        config: const ByteBatchWorkerConfig(
          transform: ByteBatchTransform.frameChecksum,
          frameSize: 4,
        ),
      );
      addTearDown(worker.close);

      await expectLater(
        worker.submit(Uint8List.fromList(<int>[1, 2, 3])),
        throwsA(isA<ByteBatchWorkerException>()),
      );

      final result = await worker.submit(Uint8List.fromList(<int>[1, 2, 3, 4]));
      expect(result.frameCount, 1);
      expect(result.bytes, orderedEquals(<int>[1, 2, 3, 4]));
    });

    test('finishes accepted work before clean shutdown', () async {
      final worker = await ByteBatchWorker.start(
        config: const ByteBatchWorkerConfig(maxInFlight: 2),
      );

      final result = worker.submit(Uint8List.fromList(<int>[8, 13, 21]));
      await worker.close();

      expect((await result).bytes, orderedEquals(<int>[8, 13, 21]));
      expect(worker.isClosing, isTrue);
      expect(
        () => worker.submit(Uint8List.fromList(<int>[1])),
        throwsStateError,
      );
    });
  });
}
