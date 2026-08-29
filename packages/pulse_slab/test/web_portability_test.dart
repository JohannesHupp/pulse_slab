import 'dart:typed_data';

import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

void main() {
  test('runs a typed-memory commit and journal round trip on web-safe columns',
      () {
    final Int64Field signedValue = Int64Field('signedValue');
    final Uint64Field rawUnsignedValue = Uint64Field('rawUnsignedValue');
    final Float64Field measurement = Float64Field('measurement');
    final RecordLayout layout = RecordLayout(
      name: 'WebPortableRecord',
      fields: <Field<Object?>>[
        signedValue,
        rawUnsignedValue,
        measurement,
      ],
      byteOrder: Endian.little,
    );
    final PulseStore store = PulseStore(journalCapacity: 2);
    addTearDown(store.dispose);
    final RecordHandle handle = store.allocate(layout);

    store.update(handle, (TransactionRecordWriter writer) {
      writer.set(signedValue, -1234567890123);
      writer.set(rawUnsignedValue, -1);
      writer.set(measurement, 1.0);
    });
    store.update(handle, (TransactionRecordWriter writer) {
      writer.set(measurement, 1.0000000000000002);
    });

    final RecordReader reader = store.read(handle);
    expect(reader.get(signedValue), -1234567890123);
    expect(reader.get(rawUnsignedValue), -1);
    expect(reader.get(measurement), 1.0000000000000002);
    final List<ChangeRecord> changes = store.journal.drain();
    expect(changes, hasLength(2));
    expect(
      changes.first.fieldMask,
      signedValue.mask | rawUnsignedValue.mask | measurement.mask,
    );
    final ChangeRecord change = changes.last;
    expect(change.version, 2);
    expect(change.fieldMask, measurement.mask);
  });
}
