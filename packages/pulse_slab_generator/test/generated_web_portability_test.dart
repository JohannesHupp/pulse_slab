import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

import 'fixtures/all_scalar_record.dart';
import 'fixtures/wide_record.dart';

void main() {
  test(
    'generated layouts preserve portable unsigned values and selections',
    () {
      for (final Uint64Value value in <Uint64Value>[
        Uint64Value.zero,
        Uint64Value.highBit,
        Uint64Value.maxValue,
      ]) {
        final AllScalarRecord decoded = AllScalarRecordLayout.deserialize(
          AllScalarRecordLayout.serialize(_allScalarRecord(value)),
        );
        expect(decoded.uint64Value, value);
      }

      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle scalarHandle = AllScalarRecordLayout.allocate(store);
      store.update(scalarHandle, (TransactionRecordWriter writer) {
        AllScalarRecordLayout.write(
          writer,
          _allScalarRecord(Uint64Value.maxValue),
        );
      });
      expect(
        AllScalarRecordLayout.read(store.read(scalarHandle)).uint64Value,
        Uint64Value.maxValue,
      );

      const WideRecord wide = WideRecord(field0: 1, field31: 2);
      final FieldSelection selected = WideRecordLayout.field0Selection.union(
        WideRecordLayout.field31Selection,
      );
      expect(selected.contains(WideRecordLayout.field0), isTrue);
      expect(selected.contains(WideRecordLayout.field31), isTrue);

      final RecordHandle wideHandle = WideRecordLayout.allocate(store);
      final List<RecordChange> changes = <RecordChange>[];
      store.watch(wideHandle, selection: selected, listener: changes.add);
      store.update(wideHandle, (TransactionRecordWriter writer) {
        WideRecordLayout.write(writer, wide);
      });

      expect(changes, hasLength(1));
      expect(
        changes.single.fieldSelection.contains(WideRecordLayout.field31),
        isTrue,
      );
    },
  );
}

AllScalarRecord _allScalarRecord(Uint64Value uint64Value) => AllScalarRecord(
  int8: -1,
  uint8: 2,
  int16: -3,
  uint16: 4,
  int32: -5,
  uint32: 6,
  int64: -7,
  uint64: 8,
  uint64Value: uint64Value,
  float32: 1.5,
  float64: 2.5,
  boolean: true,
  bytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
);
