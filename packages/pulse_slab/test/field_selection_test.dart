import 'package:pulse_slab/pulse_slab.dart';
import 'package:test/test.dart';

void main() {
  group('FieldSelection', () {
    test('keeps the 31-field compact mask fast path', () {
      final List<Field<Object?>> fields = List<Field<Object?>>.generate(
        maxFieldsPerLayout,
        (int index) => Uint8Field('field$index'),
      );
      final RecordLayout layout = RecordLayout(
        name: 'CompactBoundary',
        fields: fields,
      );

      expect(layout.supportsFieldMasks, isTrue);
      expect(fields.last.mask, 0x40000000);
      expect(layout.maskFor(fields), 0x7fffffff);

      final FieldSelection selection = layout.selectionFor(fields);
      expect(selection.isCompact, isTrue);
      expect(selection.fieldMask, 0x7fffffff);
      expect(selection.contains(fields.first), isTrue);
      expect(selection.contains(fields.last), isTrue);
    });

    test('uses a portable selection above the compact-mask boundary', () {
      final List<Field<Object?>> fields = List<Field<Object?>>.generate(
        maxFieldsPerLayout + 1,
        (int index) => Uint8Field('field$index'),
      );
      final RecordLayout layout = RecordLayout(
        name: 'WideBoundary',
        fields: fields,
      );
      final Field<Object?> first = fields.first;
      final Field<Object?> firstWide = fields.last;

      expect(layout.supportsFieldMasks, isFalse);
      expect(
        () => first.mask,
        throwsStateError,
      );
      expect(
        () => layout.maskFor(<Field<Object?>>[first]),
        throwsStateError,
      );

      final FieldSelection selection = layout.selectionFor(
        <Field<Object?>>[first, firstWide],
      );
      expect(selection.isCompact, isFalse);
      expect(selection.contains(first), isTrue);
      expect(selection.contains(firstWide), isTrue);
      expect(() => selection.fieldMask, throwsStateError);
      expect(firstWide.selection, equals(layout.selectionFor([firstWide])));
    });

    test('crosses 31-bit word boundaries without losing high fields', () {
      final List<Field<Object?>> fields = List<Field<Object?>>.generate(
        63,
        (int index) => Uint8Field('field$index'),
      );
      final RecordLayout layout = RecordLayout(
        name: 'ThreeWords',
        fields: fields,
      );
      final FieldSelection firstAndSecondWord = layout.selectionFor(
        <Field<Object?>>[fields[30], fields[31]],
      );
      final FieldSelection thirdWord = layout.selectionFor(
        <Field<Object?>>[fields[61], fields[62]],
      );
      final FieldSelection merged = firstAndSecondWord.union(thirdWord);

      expect(merged.contains(fields[30]), isTrue);
      expect(merged.contains(fields[31]), isTrue);
      expect(merged.contains(fields[61]), isTrue);
      expect(merged.contains(fields[62]), isTrue);
      expect(merged.intersects(firstAndSecondWord), isTrue);
      expect(merged.intersects(thirdWord), isTrue);
      expect(firstAndSecondWord.intersects(thirdWord), isFalse);
    });

    test('incremental wide selection building deduplicates repeated fields',
        () {
      final List<Field<Object?>> fields = List<Field<Object?>>.generate(
        63,
        (int index) => Uint8Field('field$index'),
      );
      final RecordLayout layout = RecordLayout(
        name: 'IncrementalWideSelection',
        fields: fields,
      );
      final FieldSelectionBuilder builder = FieldSelectionBuilder(layout);

      for (var index = 0; index < 1000; index++) {
        builder.add(fields[62]);
      }
      builder.add(fields[31]);

      final FieldSelection selection = builder.build();
      expect(selection.contains(fields[31]), isTrue);
      expect(selection.contains(fields[62]), isTrue);
      expect(selection.intersects(fields[0].selection), isFalse);

      builder.clear();
      expect(builder.isEmpty, isTrue);
      expect(builder.build().isEmpty, isTrue);
    });

    test('rejects selection combinations that do not belong to the layout', () {
      final List<Field<Object?>> firstFields = List<Field<Object?>>.generate(
        32,
        (int index) => Uint8Field('first$index'),
      );
      final List<Field<Object?>> secondFields = List<Field<Object?>>.generate(
        32,
        (int index) => Uint8Field('second$index'),
      );
      final RecordLayout first = RecordLayout(
        name: 'FirstWide',
        fields: firstFields,
      );
      final RecordLayout second = RecordLayout(
        name: 'SecondWide',
        fields: secondFields,
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(first);

      expect(
        () => first.selectionFor(<Field<Object?>>[secondFields.first]),
        throwsA(isA<FieldAccessException>()),
      );
      expect(
        () => store.watch(
          handle,
          fields: 1,
          listener: (RecordChange change) {},
        ),
        throwsArgumentError,
      );
      expect(
        () => store.watch(
          handle,
          selection: second.selectionFor(<Field<Object?>>[secondFields.last]),
          listener: (RecordChange change) {},
        ),
        throwsArgumentError,
      );
      expect(
        () => store.watch(
          handle,
          fields: 1,
          selection: first.selectionFor(<Field<Object?>>[firstFields.last]),
          listener: (RecordChange change) {},
        ),
        throwsArgumentError,
      );
    });
  });

  group('wide field selection transactions', () {
    test('tracks net changes, journals them, and filters high fields', () {
      final List<Field<Object?>> fields = List<Field<Object?>>.generate(
        63,
        (int index) => Uint8Field('field$index'),
      );
      final RecordLayout layout = RecordLayout(
        name: 'WideTransactions',
        fields: fields,
      );
      final PulseStore store = PulseStore(journalCapacity: 8);
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final List<RecordChange> observed = <RecordChange>[];
      store.watch(
        handle,
        selection: layout.selectionFor(<Field<Object?>>[fields[62]]),
        listener: observed.add,
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(fields[61], 1);
      });
      expect(observed, isEmpty);

      late FieldSelection provisional;
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(fields[62], 2);
        provisional = writer.changedFieldSelection;
      });

      expect(provisional.contains(fields[62]), isTrue);
      expect(observed, hasLength(1));
      final RecordChange change = observed.single;
      expect(change.hasWideFieldSelection, isTrue);
      expect(change.fieldSelection.contains(fields[62]), isTrue);
      expect(() => change.fieldMask, throwsStateError);

      final List<ChangeRecord> journal = store.journal.drain();
      expect(journal, hasLength(2));
      expect(journal.last.hasWideFieldSelection, isTrue);
      expect(journal.last.fieldSelection!.contains(fields[61]), isFalse);
      expect(journal.last.fieldSelection!.contains(fields[62]), isTrue);
      expect(() => journal.last.fieldMask, throwsStateError);

      final int versionBeforeRestore = store.versionOf(handle);
      store.transaction<void>((WriteTransaction transaction) {
        final TransactionRecordWriter writer = transaction.write(handle);
        writer.set(fields[62], 7);
        writer.set(fields[62], 2);
      });
      expect(store.versionOf(handle), versionBeforeRestore);
      expect(observed, hasLength(1));
    });

    test('merges latest deliveries and journal changes across word boundaries',
        () {
      final List<Field<Object?>> fields = List<Field<Object?>>.generate(
        63,
        (int index) => Uint8Field('field$index'),
      );
      final RecordLayout layout = RecordLayout(
        name: 'WideLatest',
        fields: fields,
      );
      final PulseStore store = PulseStore();
      addTearDown(store.dispose);
      final RecordHandle handle = store.allocate(layout);
      final List<RecordChange> observed = <RecordChange>[];
      final FieldSelection watched = layout.selectionFor(
        <Field<Object?>>[fields[31], fields[62]],
      );
      store.watch(
        handle,
        selection: watched,
        policy: DeliveryPolicy.latest,
        listener: observed.add,
      );

      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(fields[31], 1);
      });
      store.update(handle, (TransactionRecordWriter writer) {
        writer.set(fields[62], 1);
      });

      expect(store.flush(), 1);
      expect(observed, hasLength(1));
      expect(observed.single.fieldSelection.contains(fields[31]), isTrue);
      expect(observed.single.fieldSelection.contains(fields[62]), isTrue);

      final ChangeRecord merged = ChangeRecord(
        segment: 0,
        slot: 0,
        generation: 0,
        version: 1,
        fieldSelection: fields[31].selection,
      ).mergedWith(
        ChangeRecord(
          segment: 0,
          slot: 0,
          generation: 0,
          version: 2,
          fieldSelection: fields[62].selection,
        ),
      );
      expect(merged.fieldSelection!.contains(fields[31]), isTrue);
      expect(merged.fieldSelection!.contains(fields[62]), isTrue);
    });
  });
}
