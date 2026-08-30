import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

@SlabRecord(
  name: 'AnnotatedTelemetry',
  byteOrder: SlabByteOrder.little,
  alignment: 8,
)
final class _AnnotatedTelemetry {
  const _AnnotatedTelemetry(this.temperature, this.identity);

  @SlabField(kind: SlabFieldKind.float32)
  final double temperature;

  @SlabField(kind: SlabFieldKind.fixedBytes, length: 16)
  final Uint8List identity;
}

void main() {
  group('layout generation annotations', () {
    test('are usable as const Dart metadata through the public library', () {
      const SlabRecord record = SlabRecord(
        name: 'Telemetry',
        byteOrder: SlabByteOrder.big,
        alignment: 16,
      );
      const SlabField field = SlabField(
        kind: SlabFieldKind.fixedBytes,
        byteOffset: 32,
        alignment: 8,
        length: 12,
      );
      final _AnnotatedTelemetry telemetry = _AnnotatedTelemetry(
        21.5,
        Uint8List(16),
      );

      expect(record.name, 'Telemetry');
      expect(record.byteOrder, SlabByteOrder.big);
      expect(record.alignment, 16);
      expect(field.kind, SlabFieldKind.fixedBytes);
      expect(field.byteOffset, 32);
      expect(field.alignment, 8);
      expect(field.length, 12);
      expect(telemetry.temperature, 21.5);
      expect(telemetry.identity, hasLength(16));
    });

    test('exposes all supported generated field encodings', () {
      expect(
        SlabFieldKind.values,
        orderedEquals(<SlabFieldKind>[
          SlabFieldKind.int8,
          SlabFieldKind.uint8,
          SlabFieldKind.int16,
          SlabFieldKind.uint16,
          SlabFieldKind.int32,
          SlabFieldKind.uint32,
          SlabFieldKind.int64,
          SlabFieldKind.uint64,
          SlabFieldKind.uint64Value,
          SlabFieldKind.float32,
          SlabFieldKind.float64,
          SlabFieldKind.boolean,
          SlabFieldKind.fixedBytes,
        ]),
      );
    });
  });
}
