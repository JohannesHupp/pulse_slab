import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

import '../example/sensor_state.dart';

void main() {
  group('generated SensorStateLayout', () {
    test('uses its precomputed metadata and round-trips binary values', () {
      final SensorState source = SensorState(
        sequence: 42,
        temperature: 21.5,
        active: true,
        identity: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
      );

      expect(SensorStateLayout.sequenceOffset, 0);
      expect(SensorStateLayout.temperatureOffset, 4);
      expect(SensorStateLayout.activeOffset, 8);
      expect(SensorStateLayout.identityOffset, 9);
      expect(SensorStateLayout.sizeInBytes, 20);
      expect(SensorStateLayout.allFieldsMask, 15);
      expect(
        SensorStateLayout.layout.sizeInBytes,
        SensorStateLayout.sizeInBytes,
      );
      expect(SensorStateLayout.sequence.mask, SensorStateLayout.sequenceMask);

      final Uint8List encoded = SensorStateLayout.serialize(source);
      final SensorState decoded = SensorStateLayout.deserialize(encoded);
      expect(decoded.sequence, source.sequence);
      expect(decoded.temperature, source.temperature);
      expect(decoded.active, source.active);
      expect(decoded.identity, orderedEquals(source.identity));
      expect(decoded.identity, isNot(same(source.identity)));
    });

    test('writes and reads without a name lookup', () {
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = SensorStateLayout.allocate(store);
      final SensorState source = SensorState(
        sequence: 7,
        temperature: -3.25,
        active: false,
        identity: Uint8List.fromList(<int>[8, 7, 6, 5, 4, 3, 2, 1]),
      );

      store.update(handle, (TransactionRecordWriter writer) {
        SensorStateLayout.write(writer, source);
      });

      final SensorState actual = SensorStateLayout.read(store.read(handle));
      expect(actual.sequence, 7);
      expect(actual.temperature, -3.25);
      expect(actual.active, isFalse);
      expect(actual.identity, orderedEquals(source.identity));
    });

    test(
      'validates the complete value before a caught write failure mutates',
      () {
        final PulseStore store = PulseStore();
        addTearDown(store.dispose);
        final RecordHandle handle = SensorStateLayout.allocate(store);
        final SensorState baseline = SensorState(
          sequence: 3,
          temperature: 2.5,
          active: false,
          identity: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
        );
        store.update(handle, (TransactionRecordWriter writer) {
          SensorStateLayout.write(writer, baseline);
        });
        final int versionBefore = store.versionOf(handle);
        final SensorState invalid = SensorState(
          sequence: 99,
          temperature: -7.5,
          active: true,
          identity: Uint8List(7),
        );

        store.update(handle, (TransactionRecordWriter writer) {
          try {
            SensorStateLayout.write(writer, invalid);
          } on ArgumentError {
            // A caller may handle validation failures and continue the transaction.
          }
        });

        final SensorState actual = SensorStateLayout.read(store.read(handle));
        expect(actual.sequence, baseline.sequence);
        expect(actual.temperature, baseline.temperature);
        expect(actual.active, baseline.active);
        expect(actual.identity, orderedEquals(baseline.identity));
        expect(store.versionOf(handle), versionBefore);
      },
    );

    test('uses runtime-equivalent generated validation hooks', () {
      expect(
        () => SensorStateLayout.validate(
          SensorState(
            sequence: 0x100000000,
            temperature: 1,
            active: true,
            identity: Uint8List(8),
          ),
        ),
        throwsRangeError,
      );
      expect(
        () => SensorStateLayout.validate(
          SensorState(
            sequence: 1,
            temperature: 1,
            active: true,
            identity: Uint8List(7),
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => SensorStateLayout.deserialize(Uint8List(19)),
        throwsArgumentError,
      );
    });
  });
}
