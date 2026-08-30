import 'package:pulse_slab/pulse_slab.dart';

import 'sensor_state.dart';

void main() {
  final SensorState source = SensorState(
    sequence: 42,
    temperature: 21.5,
    active: true,
    identity: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]),
  );
  final Uint8List encoded = SensorStateLayout.serialize(source);
  final SensorState decoded = SensorStateLayout.deserialize(encoded);

  final PulseStore store = PulseStore();
  try {
    final RecordHandle handle = SensorStateLayout.allocate(store);
    store.update(handle, (TransactionRecordWriter writer) {
      SensorStateLayout.write(writer, decoded);
    });
    final SensorState current = SensorStateLayout.read(store.read(handle));
    print('Sensor ${current.sequence}: ${current.temperature} C');
  } finally {
    store.dispose();
  }
}
