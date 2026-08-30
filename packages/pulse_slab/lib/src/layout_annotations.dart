/// Declarative inputs for the optional Pulse Slab layout generator.
///
/// These annotations are inert at runtime. They describe a record schema to a
/// build-time generator, while applications that create [RecordLayout] and
/// [Field] descriptors manually continue to use the existing runtime API.
library;

import 'dart:typed_data';

import 'layout.dart';

/// Selects the byte order emitted for a generated record layout.
///
/// [host] maps to [Endian.host], while [little] and [big] map to their
/// respective explicit byte orders. The generator resolves this enum to the
/// `dart:typed_data` representation in generated code.
enum SlabByteOrder {
  /// Uses the host platform byte order.
  host,

  /// Uses little-endian byte order for multi-byte fields.
  little,

  /// Uses big-endian byte order for multi-byte fields.
  big,
}

/// Selects the encoded representation of a generated field.
///
/// Dart's [int] and [double] types each have more than one supported binary
/// representation, so generated schemas must select one of these kinds rather
/// than infer a width from the Dart type alone. [fixedBytes] represents a
/// [Uint8List] with the positive fixed [SlabField.length] declared alongside
/// the field.
enum SlabFieldKind {
  /// An 8-bit signed integer represented by [Int8Field].
  int8,

  /// An 8-bit unsigned integer represented by [Uint8Field].
  uint8,

  /// A 16-bit signed integer represented by [Int16Field].
  int16,

  /// A 16-bit unsigned integer represented by [Uint16Field].
  uint16,

  /// A 32-bit signed integer represented by [Int32Field].
  int32,

  /// A 32-bit unsigned integer represented by [Uint32Field].
  uint32,

  /// A 64-bit signed integer represented by [Int64Field].
  int64,

  /// A 64-bit unsigned bit pattern represented by [Uint64Field].
  uint64,

  /// A 32-bit floating-point value represented by [Float32Field].
  float32,

  /// A 64-bit floating-point value represented by [Float64Field].
  float64,

  /// A one-byte boolean represented by [BoolField].
  boolean,

  /// A fixed-width [Uint8List] represented by [FixedBytesField].
  fixedBytes,
}

/// Declares a Dart type as an optional generated Pulse Slab record schema.
///
/// The build-time generator turns this declaration and its [SlabField]
/// annotations into stable field descriptors, a [RecordLayout], and typed
/// read/write helpers. This annotation does not instantiate a layout or add a
/// runtime dependency on a generator.
///
/// When [name] is omitted, a generator may use the annotated type's name. An
/// explicitly supplied name must satisfy the same non-empty constraint as
/// [RecordLayout.name]. [alignment], when supplied, must be a positive power
/// of two and cannot be smaller than any declared field alignment.
final class SlabRecord {
  /// Creates a declaration for an optional generated record schema.
  const SlabRecord({
    this.name,
    this.byteOrder = SlabByteOrder.host,
    this.alignment,
  });

  /// The generated layout name, or the annotated type name when omitted.
  final String? name;

  /// Byte order for generated multi-byte scalar fields.
  final SlabByteOrder byteOrder;

  /// Optional explicit alignment for the generated record layout.
  final int? alignment;
}

/// Declares one field of an optional generated Pulse Slab record schema.
///
/// [kind] selects the exact binary field type. [byteOffset] and [alignment]
/// have the same meaning as their [Field] constructor counterparts. Set
/// [length] only for [SlabFieldKind.fixedBytes]; it must be greater than zero.
/// The generator reports invalid combinations and unsupported Dart field types
/// as declaration diagnostics.
final class SlabField {
  /// Creates a declaration for one generated record field.
  const SlabField({
    required this.kind,
    this.byteOffset,
    this.alignment,
    this.length,
  });

  /// The exact binary representation generated for this Dart field.
  final SlabFieldKind kind;

  /// Optional explicit byte offset within the generated record.
  final int? byteOffset;

  /// Optional explicit alignment for this generated field.
  final int? alignment;

  /// Required positive fixed byte length for [SlabFieldKind.fixedBytes].
  final int? length;
}
