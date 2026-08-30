import 'package:pulse_slab/pulse_slab.dart';
import 'package:pulse_slab/src/segmented_memory.dart';
import 'package:test/test.dart';

void main() {
  group('Uint64Value', () {
    test('constructs, compares, and exposes exact bit patterns', () {
      final Uint64Value low = Uint64Value.fromWords(highWord: 0, lowWord: 1);
      final Uint64Value highBit = Uint64Value.highBit;
      final Uint64Value maximum = Uint64Value.maxValue;

      expect(Uint64Value.zero.isZero, isTrue);
      expect(
        Uint64Value.zero,
        Uint64Value.fromWords(highWord: 0, lowWord: 0),
      );
      expect(low.compareTo(Uint64Value.zero), greaterThan(0));
      expect(highBit.compareTo(low), greaterThan(0));
      expect(maximum.compareTo(highBit), greaterThan(0));
      expect(highBit.highWord, 0x80000000);
      expect(highBit.lowWord, 0);
      expect(maximum.toHexString(), '0xffffffffffffffff');
      expect(maximum.toHexString(includePrefix: false), 'ffffffffffffffff');
      expect(
        maximum.hashCode,
        Uint64Value.fromWords(
          highWord: 0xffffffff,
          lowWord: 0xffffffff,
        ).hashCode,
      );

      expect(
        () => Uint64Value.fromWords(highWord: -1, lowWord: 0),
        throwsRangeError,
      );
      expect(
        () => Uint64Value.fromWords(highWord: 0, lowWord: 0x100000000),
        throwsRangeError,
      );
    });

    test('serializes and deserializes exact values in both byte orders', () {
      final Uint64Value value = Uint64Value.fromWords(
        highWord: 0x01234567,
        lowWord: 0x89abcdef,
      );

      expect(
        value.toBytes(byteOrder: Endian.big),
        orderedEquals(<int>[0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]),
      );
      expect(
        value.toBytes(byteOrder: Endian.little),
        orderedEquals(<int>[0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01]),
      );

      for (final Endian byteOrder in <Endian>[Endian.big, Endian.little]) {
        for (final Uint64Value candidate in <Uint64Value>[
          Uint64Value.zero,
          Uint64Value.highBit,
          Uint64Value.maxValue,
          value,
        ]) {
          expect(
            Uint64Value.fromBytes(
              candidate.toBytes(byteOrder: byteOrder),
              byteOrder: byteOrder,
            ),
            candidate,
          );
        }
      }

      expect(
        () => Uint64Value.fromBytes(Uint8List(7)),
        throwsRangeError,
      );
    });
  });

  group('Uint64ValueField', () {
    test('round-trips zero, high bit, and maximum without unsafe int math', () {
      for (final Endian byteOrder in <Endian>[Endian.big, Endian.little]) {
        final Uint64ValueField value = Uint64ValueField('value');
        final RecordLayout layout = RecordLayout(
          name: 'PortableUint64$byteOrder',
          fields: <Field<Object?>>[value],
          byteOrder: byteOrder,
        );
        final SegmentedMemory memory = SegmentedMemory();
        final RecordHandle handle = memory.allocate(layout);
        final writer = memory.writer(handle);

        expect(memory.read(handle).get(value), Uint64Value.zero);
        expect(writer.set(value, Uint64Value.zero), isFalse);
        expect(writer.set(value, Uint64Value.highBit), isTrue);
        expect(memory.read(handle).get(value), Uint64Value.highBit);
        expect(writer.set(value, Uint64Value.maxValue), isTrue);
        expect(memory.read(handle).get(value), Uint64Value.maxValue);

        writer.clearChangedMask();
        expect(writer.set(value, Uint64Value.maxValue), isFalse);
        expect(writer.changedMask, 0);
      }
    });

    test('writes word pairs with the declared byte order', () {
      final Uint64Value valueToStore = Uint64Value.fromWords(
        highWord: 0x01234567,
        lowWord: 0x89abcdef,
      );
      for (final Endian byteOrder in <Endian>[Endian.big, Endian.little]) {
        final Uint64ValueField value = Uint64ValueField('value');
        final RecordLayout layout = RecordLayout(
          name: 'WordPair$byteOrder',
          fields: <Field<Object?>>[value],
          byteOrder: byteOrder,
        );
        final SegmentedMemory memory = SegmentedMemory();
        final RecordHandle handle = memory.allocate(layout);
        memory.writer(handle).set(value, valueToStore);

        expect(
          memory.copyRecordBytes(handle),
          orderedEquals(
            byteOrder == Endian.big
                ? <int>[0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]
                : <int>[0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01],
          ),
        );
      }
    });
  });
}
