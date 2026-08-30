// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'all_scalar_record.dart';

// **************************************************************************
// SlabLayoutGenerator
// **************************************************************************

/// Generated Pulse Slab schema for [AllScalarRecord].
abstract final class AllScalarRecordLayout {
  static final _AllScalarRecordLayoutSchema _schema =
      _AllScalarRecordLayoutSchema();

  /// Precomputed record alignment in bytes.
  static const int alignment = 8;

  /// Precomputed record size including trailing padding.
  static const int sizeInBytes = 56;

  /// Union of every generated field mask.
  static const int allFieldsMask = 4095;

  /// Stable generated record layout.
  static RecordLayout get layout => _schema.layout;

  /// Byte order selected for the generated layout.
  static Endian get byteOrder => _schema.layout.byteOrder;

  /// Precomputed byte offset for [int8].
  static const int int8Offset = 0;

  /// Precomputed dirty mask for [int8].
  static const int int8Mask = 1;

  /// Stable descriptor for [AllScalarRecord.int8].
  static Int8Field get int8 => _schema.int8;

  /// Precomputed byte offset for [uint8].
  static const int uint8Offset = 1;

  /// Precomputed dirty mask for [uint8].
  static const int uint8Mask = 2;

  /// Stable descriptor for [AllScalarRecord.uint8].
  static Uint8Field get uint8 => _schema.uint8;

  /// Precomputed byte offset for [int16].
  static const int int16Offset = 2;

  /// Precomputed dirty mask for [int16].
  static const int int16Mask = 4;

  /// Stable descriptor for [AllScalarRecord.int16].
  static Int16Field get int16 => _schema.int16;

  /// Precomputed byte offset for [uint16].
  static const int uint16Offset = 4;

  /// Precomputed dirty mask for [uint16].
  static const int uint16Mask = 8;

  /// Stable descriptor for [AllScalarRecord.uint16].
  static Uint16Field get uint16 => _schema.uint16;

  /// Precomputed byte offset for [int32].
  static const int int32Offset = 8;

  /// Precomputed dirty mask for [int32].
  static const int int32Mask = 16;

  /// Stable descriptor for [AllScalarRecord.int32].
  static Int32Field get int32 => _schema.int32;

  /// Precomputed byte offset for [uint32].
  static const int uint32Offset = 12;

  /// Precomputed dirty mask for [uint32].
  static const int uint32Mask = 32;

  /// Stable descriptor for [AllScalarRecord.uint32].
  static Uint32Field get uint32 => _schema.uint32;

  /// Precomputed byte offset for [int64].
  static const int int64Offset = 16;

  /// Precomputed dirty mask for [int64].
  static const int int64Mask = 64;

  /// Stable descriptor for [AllScalarRecord.int64].
  static Int64Field get int64 => _schema.int64;

  /// Precomputed byte offset for [uint64].
  static const int uint64Offset = 24;

  /// Precomputed dirty mask for [uint64].
  static const int uint64Mask = 128;

  /// Stable descriptor for [AllScalarRecord.uint64].
  static Uint64Field get uint64 => _schema.uint64;

  /// Precomputed byte offset for [float32].
  static const int float32Offset = 32;

  /// Precomputed dirty mask for [float32].
  static const int float32Mask = 256;

  /// Stable descriptor for [AllScalarRecord.float32].
  static Float32Field get float32 => _schema.float32;

  /// Precomputed byte offset for [float64].
  static const int float64Offset = 40;

  /// Precomputed dirty mask for [float64].
  static const int float64Mask = 512;

  /// Stable descriptor for [AllScalarRecord.float64].
  static Float64Field get float64 => _schema.float64;

  /// Precomputed byte offset for [boolean].
  static const int booleanOffset = 48;

  /// Precomputed dirty mask for [boolean].
  static const int booleanMask = 1024;

  /// Stable descriptor for [AllScalarRecord.boolean].
  static BoolField get boolean => _schema.boolean;

  /// Precomputed byte offset for [bytes].
  static const int bytesOffset = 49;

  /// Precomputed dirty mask for [bytes].
  static const int bytesMask = 2048;

  /// Stable descriptor for [AllScalarRecord.bytes].
  static FixedBytesField get bytes => _schema.bytes;

  /// Allocates a record using [layout].
  static RecordHandle allocate(PulseStore store) => store.allocate(layout);

  /// Reads a typed value through the stable descriptors.
  static AllScalarRecord read(RecordReader reader) {
    final _AllScalarRecordLayoutSchema schema = _schema;
    return AllScalarRecord(
      int8: reader.get(schema.int8),
      uint8: reader.get(schema.uint8),
      int16: reader.get(schema.int16),
      uint16: reader.get(schema.uint16),
      int32: reader.get(schema.int32),
      uint32: reader.get(schema.uint32),
      int64: reader.get(schema.int64),
      uint64: reader.get(schema.uint64),
      float32: reader.get(schema.float32),
      float64: reader.get(schema.float64),
      boolean: reader.get(schema.boolean),
      bytes: reader.get(schema.bytes),
    );
  }

  /// Writes a typed value through the stable descriptors.
  static void write(TransactionRecordWriter writer, AllScalarRecord value) {
    validate(value);
    final _AllScalarRecordLayoutSchema schema = _schema;
    writer.set(schema.int8, value.int8);
    writer.set(schema.uint8, value.uint8);
    writer.set(schema.int16, value.int16);
    writer.set(schema.uint16, value.uint16);
    writer.set(schema.int32, value.int32);
    writer.set(schema.uint32, value.uint32);
    writer.set(schema.int64, value.int64);
    writer.set(schema.uint64, value.uint64);
    writer.set(schema.float32, value.float32);
    writer.set(schema.float64, value.float64);
    writer.set(schema.boolean, value.boolean);
    writer.set(schema.bytes, value.bytes);
  }

  /// Validates all values with their generated descriptors.
  static void validate(AllScalarRecord value) {
    final _AllScalarRecordLayoutSchema schema = _schema;
    schema.int8.validate(value.int8);
    schema.uint8.validate(value.uint8);
    schema.int16.validate(value.int16);
    schema.uint16.validate(value.uint16);
    schema.int32.validate(value.int32);
    schema.uint32.validate(value.uint32);
    schema.int64.validate(value.int64);
    schema.uint64.validate(value.uint64);
    schema.float32.validate(value.float32);
    schema.float64.validate(value.float64);
    schema.boolean.validate(value.boolean);
    schema.bytes.validate(value.bytes);
  }

  /// Validates the fixed binary size used by [deserialize].
  static void validateBytes(Uint8List bytes) {
    if (bytes.length != sizeInBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'Expected exactly $sizeInBytes bytes for AllScalarRecord.',
      );
    }
  }

  /// Serializes [value] using the precomputed field offsets.
  static Uint8List serialize(AllScalarRecord value) {
    final _AllScalarRecordLayoutSchema schema = _schema;
    final Uint8List bytes = Uint8List(sizeInBytes);
    final ByteData data = ByteData.sublistView(bytes);
    schema.int8.write(data, int8Offset, value.int8, schema.layout.byteOrder);
    schema.uint8.write(data, uint8Offset, value.uint8, schema.layout.byteOrder);
    schema.int16.write(data, int16Offset, value.int16, schema.layout.byteOrder);
    schema.uint16.write(
      data,
      uint16Offset,
      value.uint16,
      schema.layout.byteOrder,
    );
    schema.int32.write(data, int32Offset, value.int32, schema.layout.byteOrder);
    schema.uint32.write(
      data,
      uint32Offset,
      value.uint32,
      schema.layout.byteOrder,
    );
    schema.int64.write(data, int64Offset, value.int64, schema.layout.byteOrder);
    schema.uint64.write(
      data,
      uint64Offset,
      value.uint64,
      schema.layout.byteOrder,
    );
    schema.float32.write(
      data,
      float32Offset,
      value.float32,
      schema.layout.byteOrder,
    );
    schema.float64.write(
      data,
      float64Offset,
      value.float64,
      schema.layout.byteOrder,
    );
    schema.boolean.write(
      data,
      booleanOffset,
      value.boolean,
      schema.layout.byteOrder,
    );
    schema.bytes.write(data, bytesOffset, value.bytes, schema.layout.byteOrder);
    return bytes;
  }

  /// Deserializes one fixed-size record into [AllScalarRecord].
  static AllScalarRecord deserialize(Uint8List bytes) {
    validateBytes(bytes);
    final _AllScalarRecordLayoutSchema schema = _schema;
    final ByteData data = ByteData.sublistView(bytes);
    return AllScalarRecord(
      int8: schema.int8.read(data, int8Offset, schema.layout.byteOrder),
      uint8: schema.uint8.read(data, uint8Offset, schema.layout.byteOrder),
      int16: schema.int16.read(data, int16Offset, schema.layout.byteOrder),
      uint16: schema.uint16.read(data, uint16Offset, schema.layout.byteOrder),
      int32: schema.int32.read(data, int32Offset, schema.layout.byteOrder),
      uint32: schema.uint32.read(data, uint32Offset, schema.layout.byteOrder),
      int64: schema.int64.read(data, int64Offset, schema.layout.byteOrder),
      uint64: schema.uint64.read(data, uint64Offset, schema.layout.byteOrder),
      float32: schema.float32.read(
        data,
        float32Offset,
        schema.layout.byteOrder,
      ),
      float64: schema.float64.read(
        data,
        float64Offset,
        schema.layout.byteOrder,
      ),
      boolean: schema.boolean.read(
        data,
        booleanOffset,
        schema.layout.byteOrder,
      ),
      bytes: schema.bytes.read(data, bytesOffset, schema.layout.byteOrder),
    );
  }
}

final class _AllScalarRecordLayoutSchema {
  _AllScalarRecordLayoutSchema() {
    int8 = Int8Field('int8', byteOffset: AllScalarRecordLayout.int8Offset);
    uint8 = Uint8Field('uint8', byteOffset: AllScalarRecordLayout.uint8Offset);
    int16 = Int16Field('int16', byteOffset: AllScalarRecordLayout.int16Offset);
    uint16 = Uint16Field(
      'uint16',
      byteOffset: AllScalarRecordLayout.uint16Offset,
    );
    int32 = Int32Field('int32', byteOffset: AllScalarRecordLayout.int32Offset);
    uint32 = Uint32Field(
      'uint32',
      byteOffset: AllScalarRecordLayout.uint32Offset,
    );
    int64 = Int64Field('int64', byteOffset: AllScalarRecordLayout.int64Offset);
    uint64 = Uint64Field(
      'uint64',
      byteOffset: AllScalarRecordLayout.uint64Offset,
    );
    float32 = Float32Field(
      'float32',
      byteOffset: AllScalarRecordLayout.float32Offset,
    );
    float64 = Float64Field(
      'float64',
      byteOffset: AllScalarRecordLayout.float64Offset,
    );
    boolean = BoolField(
      'boolean',
      byteOffset: AllScalarRecordLayout.booleanOffset,
    );
    bytes = FixedBytesField(
      'bytes',
      5,
      byteOffset: AllScalarRecordLayout.bytesOffset,
    );
    layout = RecordLayout(
      name: 'AllScalarRecord',
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
        boolean,
        bytes,
      ],
      byteOrder: Endian.little,
      alignment: AllScalarRecordLayout.alignment,
    );
    if (layout.sizeInBytes != AllScalarRecordLayout.sizeInBytes) {
      throw StateError(
        'Generated size metadata for AllScalarRecord does not match the runtime layout.',
      );
    }
    if (int8.offset != AllScalarRecordLayout.int8Offset ||
        int8.mask != AllScalarRecordLayout.int8Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "int8" does not match the runtime layout.',
      );
    }
    if (uint8.offset != AllScalarRecordLayout.uint8Offset ||
        uint8.mask != AllScalarRecordLayout.uint8Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "uint8" does not match the runtime layout.',
      );
    }
    if (int16.offset != AllScalarRecordLayout.int16Offset ||
        int16.mask != AllScalarRecordLayout.int16Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "int16" does not match the runtime layout.',
      );
    }
    if (uint16.offset != AllScalarRecordLayout.uint16Offset ||
        uint16.mask != AllScalarRecordLayout.uint16Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "uint16" does not match the runtime layout.',
      );
    }
    if (int32.offset != AllScalarRecordLayout.int32Offset ||
        int32.mask != AllScalarRecordLayout.int32Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "int32" does not match the runtime layout.',
      );
    }
    if (uint32.offset != AllScalarRecordLayout.uint32Offset ||
        uint32.mask != AllScalarRecordLayout.uint32Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "uint32" does not match the runtime layout.',
      );
    }
    if (int64.offset != AllScalarRecordLayout.int64Offset ||
        int64.mask != AllScalarRecordLayout.int64Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "int64" does not match the runtime layout.',
      );
    }
    if (uint64.offset != AllScalarRecordLayout.uint64Offset ||
        uint64.mask != AllScalarRecordLayout.uint64Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "uint64" does not match the runtime layout.',
      );
    }
    if (float32.offset != AllScalarRecordLayout.float32Offset ||
        float32.mask != AllScalarRecordLayout.float32Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "float32" does not match the runtime layout.',
      );
    }
    if (float64.offset != AllScalarRecordLayout.float64Offset ||
        float64.mask != AllScalarRecordLayout.float64Mask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "float64" does not match the runtime layout.',
      );
    }
    if (boolean.offset != AllScalarRecordLayout.booleanOffset ||
        boolean.mask != AllScalarRecordLayout.booleanMask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "boolean" does not match the runtime layout.',
      );
    }
    if (bytes.offset != AllScalarRecordLayout.bytesOffset ||
        bytes.mask != AllScalarRecordLayout.bytesMask) {
      throw StateError(
        'Generated metadata for AllScalarRecord field "bytes" does not match the runtime layout.',
      );
    }
  }

  late final Int8Field int8;
  late final Uint8Field uint8;
  late final Int16Field int16;
  late final Uint16Field uint16;
  late final Int32Field int32;
  late final Uint32Field uint32;
  late final Int64Field int64;
  late final Uint64Field uint64;
  late final Float32Field float32;
  late final Float64Field float64;
  late final BoolField boolean;
  late final FixedBytesField bytes;

  late final RecordLayout layout;
}
