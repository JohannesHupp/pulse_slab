import 'package:pulse_slab/pulse_slab.dart';

part 'all_scalar_record.g.dart';

@SlabRecord(byteOrder: SlabByteOrder.little)
final class AllScalarRecord {
  const AllScalarRecord({
    required this.int8,
    required this.uint8,
    required this.int16,
    required this.uint16,
    required this.int32,
    required this.uint32,
    required this.int64,
    required this.uint64,
    required this.uint64Value,
    required this.float32,
    required this.float64,
    required this.boolean,
    required this.bytes,
  });

  @SlabField(kind: SlabFieldKind.int8)
  final int int8;

  @SlabField(kind: SlabFieldKind.uint8)
  final int uint8;

  @SlabField(kind: SlabFieldKind.int16)
  final int int16;

  @SlabField(kind: SlabFieldKind.uint16)
  final int uint16;

  @SlabField(kind: SlabFieldKind.int32)
  final int int32;

  @SlabField(kind: SlabFieldKind.uint32)
  final int uint32;

  @SlabField(kind: SlabFieldKind.int64)
  final int int64;

  @SlabField(kind: SlabFieldKind.uint64)
  final int uint64;

  @SlabField(kind: SlabFieldKind.uint64Value)
  final Uint64Value uint64Value;

  @SlabField(kind: SlabFieldKind.float32)
  final double float32;

  @SlabField(kind: SlabFieldKind.float64)
  final double float64;

  @SlabField(kind: SlabFieldKind.boolean)
  final bool boolean;

  @SlabField(kind: SlabFieldKind.fixedBytes, length: 5)
  final Uint8List bytes;
}
