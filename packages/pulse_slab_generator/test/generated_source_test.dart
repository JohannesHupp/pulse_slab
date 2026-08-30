import 'package:build/build.dart';
import 'package:build_test/build_test.dart';
import 'package:pulse_slab_generator/pulse_slab_generator.dart';
import 'package:test/test.dart';

void main() {
  group('SlabLayoutGenerator generated source', () {
    test('emits stable typed descriptors and direct hot paths', () async {
      final String generated = await _generate(_allFieldSchema);

      expect(generated, contains('abstract final class AllFieldsLayout'));
      expect(generated, contains('static const int int8Offset = 0;'));
      expect(generated, contains('static const int bytesMask = 4096;'));
      expect(generated, contains('static const int sizeInBytes = 64;'));
      expect(generated, contains('static Int8Field get int8 => _schema.int8;'));
      expect(
        generated,
        contains(
          'static Uint64ValueField get uint64Value => _schema.uint64Value;',
        ),
      );
      expect(
        generated,
        contains('static FixedBytesField get bytes => _schema.bytes;'),
      );
      expect(
        generated,
        contains('static FieldSelection get allFieldsSelection => '),
      );
      expect(generated, contains('reader.get(schema.int8)'));
      expect(generated, contains('writer.set(schema.uint64, value.uint64);'));
      expect(generated, contains('schema.bytes.write('));
      expect(generated, contains('schema.bytes.read('));
      expect(generated, contains('static void validate(AllFields value)'));
      expect(generated, contains('static void validateBytes(Uint8List bytes)'));
      expect(generated, contains('    validate(value);'));
      expect(
        generated.indexOf('    validate(value);'),
        lessThan(generated.indexOf('writer.set(schema.int8, value.int8);')),
      );
      expect(
        generated,
        contains('if (int8.offset != AllFieldsLayout.int8Offset ||'),
      );
      expect(generated, contains('int8.index != AllFieldsLayout.int8Index'));
      expect(generated, contains('int8.mask != AllFieldsLayout.int8Mask'));
      expect(generated, isNot(contains('fieldByName')));
      expect(generated, isNot(contains('dart:mirrors')));
    });

    test('emits exact selections instead of masks for wide schemas', () async {
      final String generated = await _generate(_wideFieldSchema);

      expect(
        generated,
        contains('static FieldSelection get allFieldsSelection => '),
      );
      expect(generated, contains('static const int field0Index = 0;'));
      expect(generated, contains('static const int field31Index = 31;'));
      expect(generated, contains('static const int field62Index = 62;'));
      expect(
        generated,
        contains('static FieldSelection get field62Selection => '),
      );
      expect(
        generated,
        contains('field62.index != WideFieldsLayout.field62Index'),
      );
      expect(generated, isNot(contains('allFieldsMask')));
      expect(generated, isNot(contains('field31Mask')));
      expect(generated, isNot(contains('field62Mask')));
    });

    test('reports a clear fixed-byte declaration diagnostic', () async {
      final String diagnostic = await _diagnosticFor(
        _missingFixedByteLengthSchema,
      );
      expect(diagnostic, contains('must provide a positive length'));
    });

    test('reports type, alignment, and overlap diagnostics', () async {
      final String wrongType = await _diagnosticFor(_wrongTypeSchema);
      expect(wrongType, contains('must be declared as int'));

      final String badAlignment = await _diagnosticFor(_badAlignmentSchema);
      expect(badAlignment, contains('must be a positive power of two'));

      final String overlap = await _diagnosticFor(_overlappingOffsetSchema);
      expect(overlap, contains('overlaps or precedes'));

      final String wrongUint64Value = await _diagnosticFor(
        _wrongUint64ValueSchema,
      );
      expect(wrongUint64Value, contains('must be declared as Uint64Value'));
    });

    test('rejects transforming constructor initializers', () async {
      final String diagnostic = await _diagnosticFor(
        _transformingInitializerSchema,
      );

      expect(diagnostic, contains('must be an initializing formal'));
      expect(diagnostic, contains('this.value'));
    });

    test('reports annotation target and generated-name diagnostics', () async {
      final String duplicateField = await _diagnosticFor(
        _duplicateFieldAnnotationSchema,
      );
      expect(duplicateField, contains('has multiple @SlabField annotations'));

      final String reservedMember = await _diagnosticFor(
        _reservedSchemaMemberSchema,
      );
      expect(reservedMember, contains('generated member "_schema"'));

      final String publicTopLevel = await _diagnosticFor(
        _publicTopLevelCollisionSchema,
      );
      expect(
        publicTopLevel,
        contains('Generated declaration "PublicCollisionLayout"'),
      );

      final String privateTopLevel = await _diagnosticFor(
        _privateTopLevelCollisionSchema,
      );
      expect(
        privateTopLevel,
        contains('Generated declaration "_PrivateCollisionLayoutSchema"'),
      );

      final String getter = await _diagnosticFor(_annotatedGetterSchema);
      expect(getter, contains('getter "value"'));

      final String method = await _diagnosticFor(_annotatedMethodSchema);
      expect(method, contains('method "value"'));
    });
  });
}

Future<String> _diagnosticFor(String source) async {
  final TestReaderWriter readerWriter = TestReaderWriter(
    rootPackage: 'pulse_slab_generator',
  );
  await readerWriter.testing.loadIsolateSources();
  final List<String> diagnostics = <String>[];
  await testBuilder(
    pulseSlabLayoutBuilder(BuilderOptions.empty),
    <String, Object>{'pulse_slab_generator|lib/test_schema.dart': source},
    rootPackage: 'pulse_slab_generator',
    readerWriter: readerWriter,
    outputs: const <String, Object>{},
    onLog: (log) {
      diagnostics.add(log.message);
    },
  );
  return diagnostics.join('\n');
}

Future<String> _generate(String source) async {
  final TestReaderWriter readerWriter = TestReaderWriter(
    rootPackage: 'pulse_slab_generator',
  );
  await readerWriter.testing.loadIsolateSources();
  final TestBuilderResult result = await testBuilder(
    pulseSlabLayoutBuilder(BuilderOptions.empty),
    <String, Object>{'pulse_slab_generator|lib/test_schema.dart': source},
    rootPackage: 'pulse_slab_generator',
    readerWriter: readerWriter,
    outputs: null,
    flattenOutput: true,
  );
  final AssetId output = result.outputs.singleWhere(
    (AssetId id) => id.path.endsWith('.pulse_slab.g.part'),
  );
  return readerWriter.testing.readString(output);
}

const String _allFieldSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord(byteOrder: SlabByteOrder.little, alignment: 8)
final class AllFields {
  const AllFields({
    required this.int8,
    required this.uint8,
    required this.int16,
    required this.uint16,
    required this.int32,
    required this.uint32,
    required this.int64,
    required this.uint64,
    required this.uint64Value,
    required this.float32,
    required this.float64,
    required this.boolean,
    required this.bytes,
  });

  @SlabField(kind: SlabFieldKind.int8)
  final int int8;
  @SlabField(kind: SlabFieldKind.uint8)
  final int uint8;
  @SlabField(kind: SlabFieldKind.int16)
  final int int16;
  @SlabField(kind: SlabFieldKind.uint16)
  final int uint16;
  @SlabField(kind: SlabFieldKind.int32)
  final int int32;
  @SlabField(kind: SlabFieldKind.uint32)
  final int uint32;
  @SlabField(kind: SlabFieldKind.int64)
  final int int64;
  @SlabField(kind: SlabFieldKind.uint64)
  final int uint64;
  @SlabField(kind: SlabFieldKind.uint64Value)
  final Uint64Value uint64Value;
  @SlabField(kind: SlabFieldKind.float32)
  final double float32;
  @SlabField(kind: SlabFieldKind.float64)
  final double float64;
  @SlabField(kind: SlabFieldKind.boolean)
  final bool boolean;
  @SlabField(kind: SlabFieldKind.fixedBytes, length: 5)
  final Uint8List bytes;
}
''';

const String _missingFixedByteLengthSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class MissingLength {
  const MissingLength({required this.value});

  @SlabField(kind: SlabFieldKind.fixedBytes)
  final Uint8List value;
}
''';

const String _wrongTypeSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class WrongType {
  const WrongType({required this.value});

  @SlabField(kind: SlabFieldKind.uint16)
  final String value;
}
''';

const String _wrongUint64ValueSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class WrongUint64Value {
  const WrongUint64Value({required this.value});

  @SlabField(kind: SlabFieldKind.uint64Value)
  final int value;
}
''';

const String _badAlignmentSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class BadAlignment {
  const BadAlignment({required this.value});

  @SlabField(kind: SlabFieldKind.uint16, alignment: 3)
  final int value;
}
''';

const String _overlappingOffsetSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class Overlap {
  const Overlap({required this.first, required this.second});

  @SlabField(kind: SlabFieldKind.uint32)
  final int first;
  @SlabField(kind: SlabFieldKind.uint16, byteOffset: 2)
  final int second;
}
''';

const String _transformingInitializerSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class TransformingInitializer {
  TransformingInitializer({required int value}) : value = value + 1;

  @SlabField(kind: SlabFieldKind.uint32)
  final int value;
}
''';

const String _duplicateFieldAnnotationSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class DuplicateFieldAnnotation {
  const DuplicateFieldAnnotation({required this.value});

  @SlabField(kind: SlabFieldKind.uint8)
  @SlabField(kind: SlabFieldKind.uint16)
  final int value;
}
''';

const String _reservedSchemaMemberSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class ReservedSchemaMember {
  const ReservedSchemaMember({required this._schema});

  @SlabField(kind: SlabFieldKind.uint8)
  final int _schema;
}
''';

const String _publicTopLevelCollisionSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

final class PublicCollisionLayout {}

@SlabRecord()
final class PublicCollision {
  const PublicCollision({required this.value});

  @SlabField(kind: SlabFieldKind.uint8)
  final int value;
}
''';

const String _privateTopLevelCollisionSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

final class _PrivateCollisionLayoutSchema {}

@SlabRecord()
final class PrivateCollision {
  const PrivateCollision({required this.value});

  @SlabField(kind: SlabFieldKind.uint8)
  final int value;
}
''';

const String _annotatedGetterSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class AnnotatedGetter {
  const AnnotatedGetter();

  @SlabField(kind: SlabFieldKind.uint8)
  int get value => 1;
}
''';

const String _annotatedMethodSchema = r'''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class AnnotatedMethod {
  const AnnotatedMethod();

  @SlabField(kind: SlabFieldKind.uint8)
  int value() => 1;
}
''';

String get _wideFieldSchema {
  final String parameters = List<String>.generate(
    63,
    (int index) => '    this.field$index = 0,',
  ).join('\n');
  final String fields = List<String>.generate(
    63,
    (int index) =>
        '  @SlabField(kind: SlabFieldKind.uint8)\n'
        '  final int field$index;',
  ).join('\n\n');
  return '''
import 'package:pulse_slab/pulse_slab.dart';

part 'test_schema.g.dart';

@SlabRecord()
final class WideFields {
  const WideFields({
$parameters
  });

$fields
}
''';
}
