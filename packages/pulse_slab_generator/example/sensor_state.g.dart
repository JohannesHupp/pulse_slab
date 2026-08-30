// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'sensor_state.dart';

// **************************************************************************
// SlabLayoutGenerator
// **************************************************************************

/// Generated Pulse Slab schema for [SensorState].
abstract final class SensorStateLayout {
  static final _SensorStateLayoutSchema _schema = _SensorStateLayoutSchema();

  /// Precomputed record alignment in bytes.
  static const int alignment = 4;

  /// Precomputed record size including trailing padding.
  static const int sizeInBytes = 20;

  /// Union of every generated field mask.
  static const int allFieldsMask = 15;

  /// Stable generated record layout.
  static RecordLayout get layout => _schema.layout;

  /// Byte order selected for the generated layout.
  static Endian get byteOrder => _schema.layout.byteOrder;

  /// Exact selection containing every generated field.
  static FieldSelection get allFieldsSelection => _schema.allFieldsSelection;

  /// Precomputed byte offset for [sequence].
  static const int sequenceOffset = 0;

  /// Precomputed field index for [sequence].
  static const int sequenceIndex = 0;

  /// Precomputed dirty mask for [sequence].
  static const int sequenceMask = 1;

  /// Stable descriptor for [SensorState.sequence].
  static Uint32Field get sequence => _schema.sequence;

  /// Exact selection for [sequence].
  static FieldSelection get sequenceSelection => _schema.sequence.selection;

  /// Precomputed byte offset for [temperature].
  static const int temperatureOffset = 4;

  /// Precomputed field index for [temperature].
  static const int temperatureIndex = 1;

  /// Precomputed dirty mask for [temperature].
  static const int temperatureMask = 2;

  /// Stable descriptor for [SensorState.temperature].
  static Float32Field get temperature => _schema.temperature;

  /// Exact selection for [temperature].
  static FieldSelection get temperatureSelection =>
      _schema.temperature.selection;

  /// Precomputed byte offset for [active].
  static const int activeOffset = 8;

  /// Precomputed field index for [active].
  static const int activeIndex = 2;

  /// Precomputed dirty mask for [active].
  static const int activeMask = 4;

  /// Stable descriptor for [SensorState.active].
  static BoolField get active => _schema.active;

  /// Exact selection for [active].
  static FieldSelection get activeSelection => _schema.active.selection;

  /// Precomputed byte offset for [identity].
  static const int identityOffset = 9;

  /// Precomputed field index for [identity].
  static const int identityIndex = 3;

  /// Precomputed dirty mask for [identity].
  static const int identityMask = 8;

  /// Stable descriptor for [SensorState.identity].
  static FixedBytesField get identity => _schema.identity;

  /// Exact selection for [identity].
  static FieldSelection get identitySelection => _schema.identity.selection;

  /// Allocates a record using [layout].
  static RecordHandle allocate(PulseStore store) => store.allocate(layout);

  /// Reads a typed value through the stable descriptors.
  static SensorState read(RecordReader reader) {
    final _SensorStateLayoutSchema schema = _schema;
    return SensorState(
      sequence: reader.get(schema.sequence),
      temperature: reader.get(schema.temperature),
      active: reader.get(schema.active),
      identity: reader.get(schema.identity),
    );
  }

  /// Writes a typed value through the stable descriptors.
  static void write(TransactionRecordWriter writer, SensorState value) {
    validate(value);
    final _SensorStateLayoutSchema schema = _schema;
    writer.set(schema.sequence, value.sequence);
    writer.set(schema.temperature, value.temperature);
    writer.set(schema.active, value.active);
    writer.set(schema.identity, value.identity);
  }

  /// Validates all values with their generated descriptors.
  static void validate(SensorState value) {
    final _SensorStateLayoutSchema schema = _schema;
    schema.sequence.validate(value.sequence);
    schema.temperature.validate(value.temperature);
    schema.active.validate(value.active);
    schema.identity.validate(value.identity);
  }

  /// Validates the fixed binary size used by [deserialize].
  static void validateBytes(Uint8List bytes) {
    if (bytes.length != sizeInBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'Expected exactly $sizeInBytes bytes for GeneratedSensorState.',
      );
    }
  }

  /// Serializes [value] using the precomputed field offsets.
  static Uint8List serialize(SensorState value) {
    final _SensorStateLayoutSchema schema = _schema;
    final Uint8List bytes = Uint8List(sizeInBytes);
    final ByteData data = ByteData.sublistView(bytes);
    schema.sequence.write(
      data,
      sequenceOffset,
      value.sequence,
      schema.layout.byteOrder,
    );
    schema.temperature.write(
      data,
      temperatureOffset,
      value.temperature,
      schema.layout.byteOrder,
    );
    schema.active.write(
      data,
      activeOffset,
      value.active,
      schema.layout.byteOrder,
    );
    schema.identity.write(
      data,
      identityOffset,
      value.identity,
      schema.layout.byteOrder,
    );
    return bytes;
  }

  /// Deserializes one fixed-size record into [SensorState].
  static SensorState deserialize(Uint8List bytes) {
    validateBytes(bytes);
    final _SensorStateLayoutSchema schema = _schema;
    final ByteData data = ByteData.sublistView(bytes);
    return SensorState(
      sequence: schema.sequence.read(
        data,
        sequenceOffset,
        schema.layout.byteOrder,
      ),
      temperature: schema.temperature.read(
        data,
        temperatureOffset,
        schema.layout.byteOrder,
      ),
      active: schema.active.read(data, activeOffset, schema.layout.byteOrder),
      identity: schema.identity.read(
        data,
        identityOffset,
        schema.layout.byteOrder,
      ),
    );
  }
}

final class _SensorStateLayoutSchema {
  _SensorStateLayoutSchema() {
    sequence = Uint32Field(
      'sequence',
      byteOffset: SensorStateLayout.sequenceOffset,
    );
    temperature = Float32Field(
      'temperature',
      byteOffset: SensorStateLayout.temperatureOffset,
    );
    active = BoolField('active', byteOffset: SensorStateLayout.activeOffset);
    identity = FixedBytesField(
      'identity',
      8,
      byteOffset: SensorStateLayout.identityOffset,
    );
    layout = RecordLayout(
      name: 'GeneratedSensorState',
      fields: <Field<Object?>>[sequence, temperature, active, identity],
      byteOrder: Endian.little,
      alignment: SensorStateLayout.alignment,
    );
    if (layout.sizeInBytes != SensorStateLayout.sizeInBytes) {
      throw StateError(
        'Generated size metadata for GeneratedSensorState does not match the runtime layout.',
      );
    }
    if (sequence.offset != SensorStateLayout.sequenceOffset ||
        sequence.index != SensorStateLayout.sequenceIndex ||
        sequence.mask != SensorStateLayout.sequenceMask) {
      throw StateError(
        'Generated metadata for GeneratedSensorState field "sequence" does not match the runtime layout.',
      );
    }
    if (temperature.offset != SensorStateLayout.temperatureOffset ||
        temperature.index != SensorStateLayout.temperatureIndex ||
        temperature.mask != SensorStateLayout.temperatureMask) {
      throw StateError(
        'Generated metadata for GeneratedSensorState field "temperature" does not match the runtime layout.',
      );
    }
    if (active.offset != SensorStateLayout.activeOffset ||
        active.index != SensorStateLayout.activeIndex ||
        active.mask != SensorStateLayout.activeMask) {
      throw StateError(
        'Generated metadata for GeneratedSensorState field "active" does not match the runtime layout.',
      );
    }
    if (identity.offset != SensorStateLayout.identityOffset ||
        identity.index != SensorStateLayout.identityIndex ||
        identity.mask != SensorStateLayout.identityMask) {
      throw StateError(
        'Generated metadata for GeneratedSensorState field "identity" does not match the runtime layout.',
      );
    }
    allFieldsSelection = layout.selectionFor(layout.fields);
  }

  late final Uint32Field sequence;
  late final Float32Field temperature;
  late final BoolField active;
  late final FixedBytesField identity;

  late final RecordLayout layout;
  late final FieldSelection allFieldsSelection;
}
