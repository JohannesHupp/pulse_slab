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

  test('round-trips portable full-width unsigned values on web', () {
    final Uint64ValueField zero = Uint64ValueField('zero');
    final Uint64ValueField highBit = Uint64ValueField('highBit');
    final Uint64ValueField maximum = Uint64ValueField('maximum');
    final RecordLayout layout = RecordLayout(
      name: 'WebPortableUint64',
      fields: <Field<Object?>>[zero, highBit, maximum],
      byteOrder: Endian.little,
    );
    final PulseStore store = PulseStore();
    addTearDown(store.dispose);
    final RecordHandle handle = store.allocate(layout);

    store.update(handle, (TransactionRecordWriter writer) {
      expect(writer.set(zero, Uint64Value.zero), isFalse);
      expect(writer.set(highBit, Uint64Value.highBit), isTrue);
      expect(writer.set(maximum, Uint64Value.maxValue), isTrue);
    });

    final RecordReader reader = store.read(handle);
    expect(reader.get(zero), Uint64Value.zero);
    expect(reader.get(highBit), Uint64Value.highBit);
    expect(reader.get(maximum), Uint64Value.maxValue);

    final ChangeRecord change = store.journal.drain().single;
    expect(change.fieldMask, highBit.mask | maximum.mask);

    expect(
      Uint64Value.zero.toBytes(byteOrder: Endian.little),
      orderedEquals(Uint8List(8)),
    );
    expect(
      Uint64Value.highBit.toBytes(byteOrder: Endian.little),
      orderedEquals(<int>[0, 0, 0, 0, 0, 0, 0, 0x80]),
    );
    expect(
      Uint64Value.maxValue.toBytes(byteOrder: Endian.little),
      orderedEquals(<int>[0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]),
    );
    for (final Uint64Value value in <Uint64Value>[
      Uint64Value.zero,
      Uint64Value.highBit,
      Uint64Value.maxValue,
    ]) {
      expect(
        Uint64Value.fromBytes(
          value.toBytes(byteOrder: Endian.little),
          byteOrder: Endian.little,
        ),
        value,
      );
    }
  });
}
