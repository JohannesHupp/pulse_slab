import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

import 'fixtures/wide_record.dart';

void main() {
  test('uses generated selections for a layout beyond the mask boundary', () {
    expect(WideRecordLayout.layout.supportsFieldMasks, isFalse);
    expect(WideRecordLayout.field0Index, 0);
    expect(WideRecordLayout.field31Index, 31);
    expect(
      identical(
        WideRecordLayout.allFieldsSelection,
        WideRecordLayout.allFieldsSelection,
      ),
      isTrue,
    );
    expect(
      WideRecordLayout.allFieldsSelection.contains(WideRecordLayout.field0),
      isTrue,
    );
    expect(
      WideRecordLayout.allFieldsSelection.contains(WideRecordLayout.field31),
      isTrue,
    );
    expect(
      WideRecordLayout.field31Selection.contains(WideRecordLayout.field31),
      isTrue,
    );
    expect(() => WideRecordLayout.field31.mask, throwsStateError);

    const WideRecord source = WideRecord(field0: 7, field31: 255);
    final Uint8List encoded = WideRecordLayout.serialize(source);
    expect(encoded, hasLength(WideRecordLayout.sizeInBytes));
    final WideRecord decoded = WideRecordLayout.deserialize(encoded);
    expect(decoded.field0, source.field0);
    expect(decoded.field31, source.field31);

    final PulseStore store = PulseStore();
    addTearDown(store.dispose);
    final RecordHandle handle = WideRecordLayout.allocate(store);
    final FieldSelection observedFields = WideRecordLayout.field0Selection
        .union(WideRecordLayout.field31Selection);
    final List<RecordChange> changes = <RecordChange>[];
    store.watch(handle, selection: observedFields, listener: changes.add);

    store.update(handle, (TransactionRecordWriter writer) {
      WideRecordLayout.write(writer, source);
    });

    expect(changes, hasLength(1));
    expect(
      changes.single.fieldSelection.contains(WideRecordLayout.field0),
      isTrue,
    );
    expect(
      changes.single.fieldSelection.contains(WideRecordLayout.field31),
      isTrue,
    );
    final WideRecord read = WideRecordLayout.read(store.read(handle));
    expect(read.field0, source.field0);
    expect(read.field31, source.field31);
  });
}
