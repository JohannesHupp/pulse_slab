import 'dart:typed_data';

import 'package:pulse_slab/src/errors.dart';
import 'package:pulse_slab/src/layout.dart';
import 'package:pulse_slab/src/segmented_memory.dart';
import 'package:test/test.dart';

void main() {
  group('RecordLayout', () {
    test('calculates aligned offsets, record size, and stable masks', () {
      final Uint8Field kind = Uint8Field('kind');
      final Float64Field timestamp = Float64Field('timestamp');
      final Uint16Field status = Uint16Field('status');
      final RecordLayout layout = RecordLayout(
        name: 'Telemetry',
        fields: [kind, timestamp, status],
      );

      expect(kind.offset, 0);
      expect(timestamp.offset, 8);
      expect(status.offset, 16);
      expect(layout.alignment, 8);
      expect(layout.sizeInBytes, 24);
      expect(kind.mask, 1);
      expect(timestamp.mask, 2);
      expect(status.mask, 4);
      expect(
        layout.maskFor(<Field<Object?>>[timestamp, status]),
        timestamp.mask | status.mask,
      );
    });

    test('honors valid explicit offsets and rejects invalid layouts', () {
      final Uint8Field tag = Uint8Field('tag');
      final Uint16Field status = Uint16Field('status', byteOffset: 4);
      final RecordLayout layout = RecordLayout(
        name: 'Explicit',
        fields: <Field<Object?>>[tag, status],
      );

      expect(tag.offset, 0);
      expect(status.offset, 4);
      expect(layout.sizeInBytes, 6);

      expect(
        () => RecordLayout(
          name: 'Duplicate',
          fields: <Field<Object?>>[
            Uint8Field('same'),
            Uint16Field('same'),
          ],
        ),
        throwsA(isA<LayoutException>()),
      );
      expect(
        () => RecordLayout(
          name: 'Overlap',
          fields: <Field<Object?>>[
            Uint32Field('first'),
            Uint16Field('second', byteOffset: 2),
          ],
        ),
        throwsA(isA<LayoutException>()),
      );
      expect(
        () => RecordLayout(
          name: 'TooMany',
          fields: List<Field<Object?>>.generate(
            maxFieldsPerLayout + 1,
            (int index) => Uint8Field('field$index'),
          ),
        ),
        throwsA(isA<LayoutException>()),
      );
    });
  });

  group('typed record access', () {
    test('round-trips every scalar type, booleans, and fixed bytes', () {
      final Int8Field int8 = Int8Field('int8');
      final Uint8Field uint8 = Uint8Field('uint8');
      final Int16Field int16 = Int16Field('int16');
      final Uint16Field uint16 = Uint16Field('uint16');
      final Int32Field int32 = Int32Field('int32');
      final Uint32Field uint32 = Uint32Field('uint32');
      final Int64Field int64 = Int64Field('int64');
      final Uint64Field uint64 = Uint64Field('uint64');
      final Float32Field float32 = Float32Field('float32');
      final Float64Field float64 = Float64Field('float64');
      final BoolField enabled = BoolField('enabled');
      final FixedBytesField identity = FixedBytesField('identity', 4);
      final RecordLayout layout = RecordLayout(
        name: 'AllScalars',
        fields: <Field<Object?>>[
          int8,
          uint8,
          int16,
          uint16,
          int32,
          uint32,
          int64,
          uint64,
          float32,
          float64,
          enabled,
          identity,
        ],
      );
      final SegmentedMemory memory = SegmentedMemory();
      final handle = memory.allocate(layout);
      final writer = memory.writer(handle);

      expect(writer.set(int8, -128), isTrue);
      expect(writer.set(uint8, 255), isTrue);
      expect(writer.set(int16, -32768), isTrue);
      expect(writer.set(uint16, 65535), isTrue);
      expect(writer.set(int32, -2147483648), isTrue);
      expect(writer.set(uint32, 4294967295), isTrue);
      expect(writer.set(int64, -9223372036854775808), isTrue);
      expect(writer.set(uint64, -1), isTrue);
      expect(writer.set(float32, 42.5), isTrue);
      expect(writer.set(float64, -1234.25), isTrue);
      expect(writer.set(enabled, true), isTrue);
      expect(
        writer.set(identity, Uint8List.fromList(<int>[1, 2, 3, 4])),
        isTrue,
      );

      final reader = memory.read(handle);
      expect(reader.get(int8), -128);
      expect(reader.get(uint8), 255);
      expect(reader.get(int16), -32768);
      expect(reader.get(uint16), 65535);
      expect(reader.get(int32), -2147483648);
      expect(reader.get(uint32), 4294967295);
      expect(reader.get(int64), -9223372036854775808);
      expect(reader.get(uint64), -1);
      expect(reader.get(float32), 42.5);
      expect(reader.get(float64), -1234.25);
      expect(reader.get(enabled), isTrue);
      expect(reader.get(identity), orderedEquals(<int>[1, 2, 3, 4]));
      final Uint8List defensiveBytes = reader.get(identity);
      defensiveBytes[0] = 99;
      expect(reader.get(identity), orderedEquals(<int>[1, 2, 3, 4]));
      expect(
        reader.bytesView(identity).toUint8List(),
        orderedEquals(<int>[1, 2, 3, 4]),
      );
      expect(
        writer.changedMask,
        int8.mask |
            uint8.mask |
            int16.mask |
            uint16.mask |
            int32.mask |
            uint32.mask |
            int64.mask |
            uint64.mask |
            float32.mask |
            float64.mask |
            enabled.mask |
            identity.mask,
      );
    });

    test('uses configured endian order and validates integer ranges', () {
      final Uint16Field value = Uint16Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'LittleEndian',
        fields: <Field<Object?>>[value],
        byteOrder: Endian.little,
      );
      final SegmentedMemory memory = SegmentedMemory();
      final handle = memory.allocate(layout);
      final writer = memory.writer(handle);

      writer.set(value, 0x1234);
      expect(memory.copyRecordBytes(handle).sublist(0, 2), <int>[0x34, 0x12]);
      expect(writer.set(value, 0x1234), isFalse);
      expect(() => writer.set(value, 0x10000), throwsRangeError);
    });

    test('keeps readers read-only and rejects fields from another layout', () {
      final Uint32Field value = Uint32Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'Primary',
        fields: <Field<Object?>>[value],
      );
      final Uint32Field foreign = Uint32Field('foreign');
      RecordLayout(
        name: 'Foreign',
        fields: <Field<Object?>>[foreign],
      );
      final SegmentedMemory memory = SegmentedMemory();
      final handle = memory.allocate(layout);
      final writer = memory.writer(handle);

      writer.set(value, 7);
      final Uint8List snapshot = memory.copyRecordBytes(handle);
      final Uint8List readBytes = Uint8List.fromList(snapshot);
      readBytes[0] = 99;
      expect(memory.copyRecordBytes(handle), orderedEquals(snapshot));
      expect(
        () => writer.set(foreign, 3),
        throwsA(isA<FieldAccessException>()),
      );
    });
  });

  group('segmented allocation', () {
    test('grows without relocating live records and reuses released slots', () {
      final Uint32Field value = Uint32Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'Slots',
        fields: <Field<Object?>>[value],
      );
      final SegmentedMemory memory = SegmentedMemory(segmentCapacity: 2);
      final first = memory.allocate(layout);
      final second = memory.allocate(layout);
      final third = memory.allocate(layout);

      expect(first.segment, 0);
      expect(second.segment, 0);
      expect(third.segment, 1);
      expect(memory.segmentCount, 2);
      expect(memory.totalCapacity, 4);

      memory.writer(first).set(value, 99);
      memory.release(second);
      final reused = memory.allocate(layout);
      expect(reused.segment, second.segment);
      expect(reused.slot, second.slot);
      expect(reused.generation, second.generation + 1);
      expect(memory.read(first).get(value), 99);
      expect(
        () => memory.read(second),
        throwsA(isA<StaleRecordHandleException>()),
      );
      expect(memory.isLive(second), isFalse);
      expect(memory.isLive(reused), isTrue);
    });

    test('tracks versions and restores explicit transaction snapshots', () {
      final Uint32Field value = Uint32Field('value');
      final RecordLayout layout = RecordLayout(
        name: 'Rollback',
        fields: <Field<Object?>>[value],
      );
      final SegmentedMemory memory = SegmentedMemory();
      final handle = memory.allocate(layout);

      memory.writer(handle).set(value, 10);
      expect(memory.incrementVersion(handle), 1);
      final Uint8List snapshot = memory.copyRecordBytes(handle);
      memory.writer(handle).set(value, 99);
      memory.restoreRecordBytes(handle, snapshot);

      expect(memory.read(handle).get(value), 10);
      expect(memory.versionOf(handle), 1);
    });

    test('invalidates an outstanding byte view after release', () {
      final FixedBytesField bytes = FixedBytesField('bytes', 2);
      final RecordLayout layout = RecordLayout(
        name: 'ByteView',
        fields: <Field<Object?>>[bytes],
      );
      final SegmentedMemory memory = SegmentedMemory();
      final handle = memory.allocate(layout);
      memory.writer(handle).set(bytes, Uint8List.fromList(<int>[5, 6]));
      final ByteView view = memory.read(handle).bytesView(bytes);

      memory.release(handle);
      expect(() => view[0], throwsA(isA<StaleRecordHandleException>()));
    });
  });
}
