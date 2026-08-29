import 'package:pulse_slab/pulse_slab.dart';

void main() {
  final Float64Field timestamp = Float64Field('timestamp');
  final Float32Field temperature = Float32Field('temperature');
  final Uint16Field status = Uint16Field('status');
  final RecordLayout layout = RecordLayout(
    name: 'SensorState',
    fields: <Field<Object?>>[timestamp, temperature, status],
  );
  final PulseStore store = PulseStore(
    segmentCapacity: 64,
    journalCapacity: 128,
  );

  try {
    final RecordHandle handle = store.allocate(layout);
    store.transaction<void>((WriteTransaction transaction) {
      final TransactionRecordWriter writer = transaction.write(handle);
      writer
        ..set(timestamp, 1234.0)
        ..set(temperature, 21.5)
        ..set(status, 2);
    });

    final RecordReader record = store.read(handle);
    print(
      'Temperature: ${record.get(temperature)} C '
      '(version ${record.version})',
    );
  } finally {
    store.dispose();
  }
}
