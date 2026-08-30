import 'package:pulse_slab/pulse_slab.dart';

part 'sensor_state.g.dart';

/// A complete generated schema with scalar and fixed-byte fields.
@SlabRecord(name: 'GeneratedSensorState', byteOrder: SlabByteOrder.little)
final class SensorState {
  const SensorState({
    required this.sequence,
    required this.temperature,
    required this.active,
    required this.identity,
  });

  @SlabField(kind: SlabFieldKind.uint32)
  final int sequence;

  @SlabField(kind: SlabFieldKind.float32)
  final double temperature;

  @SlabField(kind: SlabFieldKind.boolean)
  final bool active;

  @SlabField(kind: SlabFieldKind.fixedBytes, length: 8)
  final Uint8List identity;
}
