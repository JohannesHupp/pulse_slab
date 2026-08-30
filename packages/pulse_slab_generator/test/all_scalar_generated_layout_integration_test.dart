import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

import 'fixtures/all_scalar_record.dart';

void main() {
  group('compiled all-scalar generated layout', () {
    test(
      'round-trips, validates, and reads/writes every supported field kind',
      () {
        final AllScalarRecord source = _record();

        expect(() => AllScalarRecordLayout.validate(source), returnsNormally);
        _expectMetadata();

        final Uint8List encoded = AllScalarRecordLayout.serialize(source);
        final AllScalarRecord decoded = AllScalarRecordLayout.deserialize(
          encoded,
        );
        _expectSameValues(decoded, source);
        expect(decoded.bytes, isNot(same(source.bytes)));

        final PulseStore store = PulseStore();
        addTearDown(store.dispose);
        final RecordHandle handle = AllScalarRecordLayout.allocate(store);
        store.update(handle, (TransactionRecordWriter writer) {
          AllScalarRecordLayout.write(writer, source);
        });

        _expectSameValues(
          AllScalarRecordLayout.read(store.read(handle)),
          source,
        );
      },
    );

    test(
      'uses compiled validation for scalar ranges and fixed-byte lengths',
      () {
        expect(
          () => AllScalarRecordLayout.validate(_record(int8: 128)),
          throwsRangeError,
        );
        expect(
          () => AllScalarRecordLayout.validate(_record(bytes: Uint8List(4))),
          throwsArgumentError,
        );
      },
    );
  });
}

AllScalarRecord _record({int int8 = -12, Uint8List? bytes}) => AllScalarRecord(
  int8: int8,
  uint8: 250,
  int16: -1234,
  uint16: 60000,
  int32: -123456789,
  uint32: 4000000000,
  int64: -1234567890123,
  uint64: 1234567890123,
  uint64Value: Uint64Value.maxValue,
  float32: -3.25,
  float64: 123.5,
  boolean: true,
  bytes: bytes ?? Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
);

void _expectMetadata() {
  expect(AllScalarRecordLayout.int8.offset, AllScalarRecordLayout.int8Offset);
  expect(AllScalarRecordLayout.int8.mask, AllScalarRecordLayout.int8Mask);
  expect(AllScalarRecordLayout.uint8.offset, AllScalarRecordLayout.uint8Offset);
  expect(AllScalarRecordLayout.uint8.mask, AllScalarRecordLayout.uint8Mask);
  expect(AllScalarRecordLayout.int16.offset, AllScalarRecordLayout.int16Offset);
  expect(AllScalarRecordLayout.int16.mask, AllScalarRecordLayout.int16Mask);
  expect(
    AllScalarRecordLayout.uint16.offset,
    AllScalarRecordLayout.uint16Offset,
  );
  expect(AllScalarRecordLayout.uint16.mask, AllScalarRecordLayout.uint16Mask);
  expect(AllScalarRecordLayout.int32.offset, AllScalarRecordLayout.int32Offset);
  expect(AllScalarRecordLayout.int32.mask, AllScalarRecordLayout.int32Mask);
  expect(
    AllScalarRecordLayout.uint32.offset,
    AllScalarRecordLayout.uint32Offset,
  );
  expect(AllScalarRecordLayout.uint32.mask, AllScalarRecordLayout.uint32Mask);
  expect(AllScalarRecordLayout.int64.offset, AllScalarRecordLayout.int64Offset);
  expect(AllScalarRecordLayout.int64.mask, AllScalarRecordLayout.int64Mask);
  expect(
    AllScalarRecordLayout.uint64.offset,
    AllScalarRecordLayout.uint64Offset,
  );
  expect(AllScalarRecordLayout.uint64.mask, AllScalarRecordLayout.uint64Mask);
  expect(
    AllScalarRecordLayout.uint64Value.offset,
    AllScalarRecordLayout.uint64ValueOffset,
  );
  expect(
    AllScalarRecordLayout.uint64Value.mask,
    AllScalarRecordLayout.uint64ValueMask,
  );
  expect(
    AllScalarRecordLayout.float32.offset,
    AllScalarRecordLayout.float32Offset,
  );
  expect(AllScalarRecordLayout.float32.mask, AllScalarRecordLayout.float32Mask);
  expect(
    AllScalarRecordLayout.float64.offset,
    AllScalarRecordLayout.float64Offset,
  );
  expect(AllScalarRecordLayout.float64.mask, AllScalarRecordLayout.float64Mask);
  expect(
    AllScalarRecordLayout.boolean.offset,
    AllScalarRecordLayout.booleanOffset,
  );
  expect(AllScalarRecordLayout.boolean.mask, AllScalarRecordLayout.booleanMask);
  expect(AllScalarRecordLayout.bytes.offset, AllScalarRecordLayout.bytesOffset);
  expect(AllScalarRecordLayout.bytes.mask, AllScalarRecordLayout.bytesMask);
}

void _expectSameValues(AllScalarRecord actual, AllScalarRecord expected) {
  expect(actual.int8, expected.int8);
  expect(actual.uint8, expected.uint8);
  expect(actual.int16, expected.int16);
  expect(actual.uint16, expected.uint16);
  expect(actual.int32, expected.int32);
  expect(actual.uint32, expected.uint32);
  expect(actual.int64, expected.int64);
  expect(actual.uint64, expected.uint64);
  expect(actual.uint64Value, expected.uint64Value);
  expect(actual.float32, expected.float32);
  expect(actual.float64, expected.float64);
  expect(actual.boolean, expected.boolean);
  expect(actual.bytes, orderedEquals(expected.bytes));
}
