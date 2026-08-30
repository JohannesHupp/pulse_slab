import 'dart:async';

import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:pulse_slab/pulse_slab.dart';
import 'package:source_gen/source_gen.dart';

const TypeChecker _slabFieldChecker = TypeChecker.typeNamed(
  SlabField,
  inPackage: 'pulse_slab',
);

const int _maximumPortableTypedDataLength = 0x7fffffff;

/// Generates typed descriptors and codecs for one `@SlabRecord` declaration.
final class SlabLayoutGenerator extends GeneratorForAnnotation<SlabRecord> {
  /// Restricts recognition to the runtime annotation exported by Pulse Slab.
  @override
  TypeChecker get typeChecker =>
      const TypeChecker.typeNamed(SlabRecord, inPackage: 'pulse_slab');

  @override
  FutureOr<String> generateForAnnotatedElement(
    Element element,
    ConstantReader annotation,
    BuildStep buildStep,
  ) {
    if (element is! ClassElement) {
      _invalid(
        '@SlabRecord can only annotate a class declaration.',
        element: element,
      );
    }

    final ClassElement recordClass = element;
    final String className = _nameOf(recordClass);
    if (recordClass.isAbstract || !recordClass.isConstructable) {
      _invalid(
        'Generated record "$className" must be a concrete constructable class.',
        element: recordClass,
      );
    }
    if (recordClass.typeParameters.isNotEmpty) {
      _invalid(
        'Generated record "$className" cannot declare type parameters.',
        todo: 'Use a concrete record type for a generated layout.',
        element: recordClass,
      );
    }
    _validateGeneratedTopLevelNames(recordClass);
    _validateSlabFieldTargets(recordClass);

    final String layoutName = annotation.peek('name')?.stringValue ?? className;
    if (layoutName.trim().isEmpty) {
      _invalid(
        'The generated layout name for "$className" must not be empty.',
        element: recordClass,
      );
    }
    final String byteOrder = _enumValue(
      annotation.read('byteOrder'),
      member: 'byteOrder',
      element: recordClass,
    );
    final String generatedByteOrder = switch (byteOrder) {
      'host' => 'Endian.host',
      'little' => 'Endian.little',
      'big' => 'Endian.big',
      _ => _unexpectedEnumValue('byte order', byteOrder, recordClass),
    };

    final List<_GeneratedField> fields = _collectFields(recordClass);
    if (fields.isEmpty) {
      _invalid(
        'Generated record "$className" must declare at least one field.',
        element: recordClass,
      );
    }
    _validateGeneratedMemberNames(className, fields, recordClass);
    final _LayoutMetadata metadata = _precomputeLayout(
      recordClass: recordClass,
      fields: fields,
      requestedAlignment: annotation.peek('alignment')?.intValue,
    );
    final ConstructorElement constructor = _validateConstructor(
      recordClass,
      fields,
    );
    return _emit(
      className: className,
      layoutName: layoutName,
      generatedByteOrder: generatedByteOrder,
      fields: fields,
      metadata: metadata,
      constructor: constructor,
    );
  }

  List<_GeneratedField> _collectFields(ClassElement recordClass) {
    final String className = _nameOf(recordClass);
    final List<_GeneratedField> result = <_GeneratedField>[];

    for (final FieldElement field in recordClass.fields) {
      final List<DartObject> fieldAnnotations = _slabFieldChecker
          .annotationsOfExact(field, throwOnUnresolved: false)
          .toList(growable: false);
      if (fieldAnnotations.length > 1) {
        _invalid(
          'Field "${_nameOf(field)}" in "$className" has multiple '
          '@SlabField annotations.',
          todo: 'Keep exactly one @SlabField annotation on each field.',
          element: field,
        );
      }
      final DartObject? fieldAnnotation = fieldAnnotations.isEmpty
          ? null
          : fieldAnnotations.single;
      if (field.isStatic) {
        if (fieldAnnotation != null) {
          _invalid(
            'Static field "${_nameOf(field)}" in "$className" cannot use '
            '@SlabField.',
            element: field,
          );
        }
        continue;
      }
      if (fieldAnnotation == null) {
        _invalid(
          'Instance field "${_nameOf(field)}" in "$className" is missing '
          '@SlabField.',
          todo: 'Annotate every instance field or make it static.',
          element: field,
        );
      }
      if (!field.isFinal || field.isLate) {
        _invalid(
          'Generated field "${_nameOf(field)}" in "$className" must be '
          'non-late final.',
          todo: 'Declare it as a final constructor-initialized field.',
          element: field,
        );
      }
      result.add(_readField(field, ConstantReader(fieldAnnotation)));
    }

    return result;
  }

  void _validateSlabFieldTargets(ClassElement recordClass) {
    final String className = _nameOf(recordClass);
    for (final GetterElement getter in recordClass.getters) {
      if (_slabFieldChecker.hasAnnotationOfExact(
        getter,
        throwOnUnresolved: false,
      )) {
        _invalid(
          '@SlabField can only annotate instance fields; getter '
          '"${_nameOf(getter)}" in "$className" is not supported.',
          element: getter,
        );
      }
    }
    for (final SetterElement setter in recordClass.setters) {
      if (_slabFieldChecker.hasAnnotationOfExact(
        setter,
        throwOnUnresolved: false,
      )) {
        _invalid(
          '@SlabField can only annotate instance fields; setter '
          '"${_nameOf(setter)}" in "$className" is not supported.',
          element: setter,
        );
      }
    }
    for (final MethodElement method in recordClass.methods) {
      if (_slabFieldChecker.hasAnnotationOfExact(
        method,
        throwOnUnresolved: false,
      )) {
        _invalid(
          '@SlabField can only annotate instance fields; method '
          '"${_nameOf(method)}" in "$className" is not supported.',
          element: method,
        );
      }
    }
  }

  _GeneratedField _readField(FieldElement field, ConstantReader annotation) {
    final String fieldName = _nameOf(field);
    final String kindName = _enumValue(
      annotation.read('kind'),
      member: 'kind',
      element: field,
    );
    final _FieldEncoding encoding = _FieldEncoding.fromAnnotation(
      kindName,
      field,
    );
    final int? length = annotation.peek('length')?.intValue;

    if (encoding.isFixedBytes) {
      if (length == null || length <= 0) {
        _invalid(
          'Fixed-byte field "$fieldName" must provide a positive length.',
          todo: 'Use @SlabField(kind: SlabFieldKind.fixedBytes, length: N).',
          element: field,
        );
      }
    } else if (length != null) {
      _invalid(
        'Only fixedBytes fields may declare a length; "$fieldName" uses '
        '$kindName.',
        element: field,
      );
    }

    if (!_matchesExpectedType(field.type, encoding)) {
      _invalid(
        'Field "$fieldName" uses $kindName and must be declared as '
        '${encoding.dartType}, but is '
        '${field.type.getDisplayString()}.',
        element: field,
      );
    }

    final int? requestedAlignment = annotation.peek('alignment')?.intValue;
    if (requestedAlignment != null && !_isValidAlignment(requestedAlignment)) {
      _invalid(
        'Field "$fieldName" alignment $requestedAlignment must be a positive '
        'power of two within the portable typed-data range.',
        element: field,
      );
    }
    final int? requestedOffset = annotation.peek('byteOffset')?.intValue;
    if (requestedOffset != null &&
        (requestedOffset < 0 ||
            requestedOffset >= _maximumPortableTypedDataLength)) {
      _invalid(
        'Field "$fieldName" byteOffset $requestedOffset must be within the '
        'portable typed-data range.',
        element: field,
      );
    }

    return _GeneratedField(
      element: field,
      name: fieldName,
      encoding: encoding,
      byteLength: length ?? encoding.byteLength,
      requestedAlignment: requestedAlignment,
      requestedOffset: requestedOffset,
    );
  }

  _LayoutMetadata _precomputeLayout({
    required ClassElement recordClass,
    required List<_GeneratedField> fields,
    required int? requestedAlignment,
  }) {
    final String className = _nameOf(recordClass);
    if (requestedAlignment != null && !_isValidAlignment(requestedAlignment)) {
      _invalid(
        'Layout "$className" alignment $requestedAlignment must be a positive '
        'power of two within the portable typed-data range.',
        element: recordClass,
      );
    }

    var cursor = 0;
    var maximumFieldAlignment = 1;
    for (var index = 0; index < fields.length; index++) {
      final _GeneratedField field = fields[index];
      final int fieldAlignment =
          field.requestedAlignment ?? field.encoding.naturalAlignment;
      final int offset;
      if (field.requestedOffset case final int requestedOffset) {
        if (requestedOffset < cursor) {
          _invalid(
            'Field "${field.name}" at offset $requestedOffset overlaps or '
            'precedes the current record extent $cursor.',
            element: field.element,
          );
        }
        if (requestedOffset.remainder(fieldAlignment) != 0) {
          _invalid(
            'Field "${field.name}" offset $requestedOffset is not aligned to '
            '$fieldAlignment bytes.',
            element: field.element,
          );
        }
        offset = requestedOffset;
      } else {
        offset = _alignUp(cursor, fieldAlignment, field.element);
      }
      if (offset > _maximumPortableTypedDataLength - field.byteLength) {
        _invalid(
          'Generated layout "$className" exceeds the portable typed-data '
          'byte limit.',
          element: field.element,
        );
      }
      field.index = index;
      field.offset = offset;
      if (fields.length <= maxFieldsPerLayout) {
        field.compactMask = 1 << index;
      }
      cursor = offset + field.byteLength;
      if (fieldAlignment > maximumFieldAlignment) {
        maximumFieldAlignment = fieldAlignment;
      }
    }

    if (requestedAlignment != null &&
        requestedAlignment < maximumFieldAlignment) {
      _invalid(
        'Layout "$className" alignment $requestedAlignment is smaller than '
        'the required field alignment $maximumFieldAlignment.',
        element: recordClass,
      );
    }
    final int alignment = requestedAlignment ?? maximumFieldAlignment;
    return _LayoutMetadata(
      alignment: alignment,
      sizeInBytes: _alignUp(cursor, alignment, recordClass),
    );
  }

  ConstructorElement _validateConstructor(
    ClassElement recordClass,
    List<_GeneratedField> fields,
  ) {
    final String className = _nameOf(recordClass);
    final ConstructorElement? constructor = recordClass.unnamedConstructor;
    if (constructor == null || !constructor.isGenerative) {
      _invalid(
        'Generated record "$className" needs an unnamed generative '
        'constructor.',
        todo: 'Add $className(...) accepting every generated field.',
        element: recordClass,
      );
    }

    final Map<String, _GeneratedField> fieldsByName = <String, _GeneratedField>{
      for (final _GeneratedField field in fields) field.name: field,
    };
    final List<FormalParameterElement> parameters =
        constructor.formalParameters;
    if (parameters.length != fields.length) {
      _invalid(
        'The unnamed constructor for "$className" must accept exactly its '
        '${fields.length} generated fields.',
        todo: 'Match constructor parameters to every @SlabField by name.',
        element: constructor,
      );
    }
    final Set<String> parameterNames = <String>{};
    for (final FormalParameterElement parameter in parameters) {
      final String parameterName = _nameOf(parameter);
      final _GeneratedField? field = fieldsByName[parameterName];
      if (field == null) {
        _invalid(
          'Constructor parameter "$parameterName" in "$className" does not '
          'match a generated field.',
          element: parameter,
        );
      }
      if (!parameterNames.add(parameterName)) {
        _invalid(
          'Constructor "$className" repeats parameter "$parameterName".',
          element: parameter,
        );
      }
      if (parameter is! FieldFormalParameterElement) {
        _invalid(
          'Constructor parameter "$parameterName" in "$className" must be '
          'an initializing formal (`this.$parameterName`).',
          todo:
              'Declare `this.$parameterName` so generated deserialization '
              'preserves the encoded field value.',
          element: parameter,
        );
      }
      final String parameterType = parameter.type.getDisplayString();
      if (parameterType != field.encoding.dartType) {
        _invalid(
          'Constructor parameter "$parameterName" in "$className" must be '
          '${field.encoding.dartType}, but is $parameterType.',
          element: parameter,
        );
      }
    }
    for (final _GeneratedField field in fields) {
      if (!parameterNames.contains(field.name)) {
        _invalid(
          'The unnamed constructor for "$className" is missing generated '
          'field "${field.name}".',
          element: constructor,
        );
      }
    }
    return constructor;
  }

  String _emit({
    required String className,
    required String layoutName,
    required String generatedByteOrder,
    required List<_GeneratedField> fields,
    required _LayoutMetadata metadata,
    required ConstructorElement constructor,
  }) {
    final String layoutClassName = '${className}Layout';
    final String schemaClassName = '_${className}LayoutSchema';
    final bool usesCompactMasks = fields.length <= maxFieldsPerLayout;
    final StringBuffer output = StringBuffer()
      ..writeln('/// Generated Pulse Slab schema for [$className].')
      ..writeln('abstract final class $layoutClassName {')
      ..writeln('  static final $schemaClassName _schema = $schemaClassName();')
      ..writeln()
      ..writeln('  /// Precomputed record alignment in bytes.')
      ..writeln('  static const int alignment = ${metadata.alignment};')
      ..writeln()
      ..writeln('  /// Precomputed record size including trailing padding.')
      ..writeln('  static const int sizeInBytes = ${metadata.sizeInBytes};');

    if (usesCompactMasks) {
      output
        ..writeln()
        ..writeln('  /// Union of every generated field mask.')
        ..writeln(
          '  static const int allFieldsMask = ${_allFieldsMask(fields)};',
        );
    }

    output
      ..writeln()
      ..writeln('  /// Stable generated record layout.')
      ..writeln('  static RecordLayout get layout => _schema.layout;')
      ..writeln()
      ..writeln('  /// Byte order selected for the generated layout.')
      ..writeln('  static Endian get byteOrder => _schema.layout.byteOrder;')
      ..writeln()
      ..writeln('  /// Exact selection containing every generated field.')
      ..writeln(
        '  static FieldSelection get allFieldsSelection => '
        '_schema.allFieldsSelection;',
      );

    for (final _GeneratedField field in fields) {
      output
        ..writeln()
        ..writeln('  /// Precomputed byte offset for [${field.name}].')
        ..writeln('  static const int ${field.name}Offset = ${field.offset};')
        ..writeln()
        ..writeln('  /// Precomputed field index for [${field.name}].')
        ..writeln('  static const int ${field.name}Index = ${field.index};');
      if (usesCompactMasks) {
        output
          ..writeln()
          ..writeln('  /// Precomputed dirty mask for [${field.name}].')
          ..writeln(
            '  static const int ${field.name}Mask = ${field.compactMask};',
          );
      }
      output
        ..writeln()
        ..writeln('  /// Stable descriptor for [$className.${field.name}].')
        ..writeln(
          '  static ${field.encoding.descriptorType} get ${field.name} => '
          '_schema.${field.name};',
        )
        ..writeln()
        ..writeln('  /// Exact selection for [${field.name}].')
        ..writeln(
          '  static FieldSelection get ${field.name}Selection => '
          '_schema.${field.name}.selection;',
        );
    }

    output
      ..writeln()
      ..writeln('  /// Allocates a record using [layout].')
      ..writeln(
        '  static RecordHandle allocate(PulseStore store) => '
        'store.allocate(layout);',
      )
      ..writeln()
      ..writeln('  /// Reads a typed value through the stable descriptors.')
      ..writeln('  static $className read(RecordReader reader) {')
      ..writeln('    final $schemaClassName schema = _schema;')
      ..writeln(
        '    return ${_constructorInvocation('reader.get(schema', fields, constructor)};',
      )
      ..writeln('  }')
      ..writeln()
      ..writeln('  /// Writes a typed value through the stable descriptors.')
      ..writeln('  static void write(')
      ..writeln('    TransactionRecordWriter writer,')
      ..writeln('    $className value,')
      ..writeln('  ) {')
      ..writeln('    validate(value);')
      ..writeln('    final $schemaClassName schema = _schema;');
    for (final _GeneratedField field in fields) {
      output.writeln(
        '    writer.set(schema.${field.name}, value.${field.name});',
      );
    }
    output
      ..writeln('  }')
      ..writeln()
      ..writeln('  /// Validates all values with their generated descriptors.')
      ..writeln('  static void validate($className value) {')
      ..writeln('    final $schemaClassName schema = _schema;');
    for (final _GeneratedField field in fields) {
      output.writeln('    schema.${field.name}.validate(value.${field.name});');
    }
    output
      ..writeln('  }')
      ..writeln()
      ..writeln('  /// Validates the fixed binary size used by [deserialize].')
      ..writeln('  static void validateBytes(Uint8List bytes) {')
      ..writeln('    if (bytes.length != sizeInBytes) {')
      ..writeln('      throw ArgumentError.value(')
      ..writeln('        bytes.length,')
      ..writeln("        'bytes',")
      ..writeln(
        "        'Expected exactly \$sizeInBytes bytes for $layoutName.',",
      )
      ..writeln('      );')
      ..writeln('    }')
      ..writeln('  }')
      ..writeln()
      ..writeln('  /// Serializes [value] using the precomputed field offsets.')
      ..writeln('  static Uint8List serialize($className value) {')
      ..writeln('    final $schemaClassName schema = _schema;')
      ..writeln('    final Uint8List bytes = Uint8List(sizeInBytes);')
      ..writeln('    final ByteData data = ByteData.sublistView(bytes);');
    for (final _GeneratedField field in fields) {
      output.writeln(
        '    schema.${field.name}.write('
        'data, ${field.name}Offset, value.${field.name}, '
        'schema.layout.byteOrder);',
      );
    }
    output
      ..writeln('    return bytes;')
      ..writeln('  }')
      ..writeln()
      ..writeln('  /// Deserializes one fixed-size record into [$className].')
      ..writeln('  static $className deserialize(Uint8List bytes) {')
      ..writeln('    validateBytes(bytes);')
      ..writeln('    final $schemaClassName schema = _schema;')
      ..writeln('    final ByteData data = ByteData.sublistView(bytes);')
      ..writeln(
        '    return ${_constructorInvocation('schema', fields, constructor, fromData: true)};',
      )
      ..writeln('  }')
      ..writeln('}')
      ..writeln()
      ..writeln('final class $schemaClassName {')
      ..writeln('  $schemaClassName() {');
    for (final _GeneratedField field in fields) {
      output
        ..writeln('    ${field.name} = ${field.encoding.descriptorType}(')
        ..writeln('      ${_stringLiteral(field.name)},');
      if (field.encoding.isFixedBytes) {
        output.writeln('      ${field.byteLength},');
      }
      output.writeln('      byteOffset: $layoutClassName.${field.name}Offset,');
      if (field.requestedAlignment != null) {
        output.writeln('      alignment: ${field.requestedAlignment},');
      }
      output.writeln('    );');
    }
    output
      ..writeln('    layout = RecordLayout(')
      ..writeln('      name: ${_stringLiteral(layoutName)},')
      ..writeln('      fields: <Field<Object?>>[');
    for (final _GeneratedField field in fields) {
      output.writeln('        ${field.name},');
    }
    output
      ..writeln('      ],')
      ..writeln('      byteOrder: $generatedByteOrder,')
      ..writeln('      alignment: $layoutClassName.alignment,')
      ..writeln('    );')
      ..writeln('    if (layout.sizeInBytes != $layoutClassName.sizeInBytes) {')
      ..writeln('      throw StateError(')
      ..writeln(
        "        'Generated size metadata for $layoutName does not match the runtime layout.',",
      )
      ..writeln('      );')
      ..writeln('    }');
    for (final _GeneratedField field in fields) {
      output
        ..writeln(
          '    if (${field.name}.offset != '
          '$layoutClassName.${field.name}Offset ||',
        )
        ..writeln(
          '        ${field.name}.index != '
          '$layoutClassName.${field.name}Index',
        );
      if (usesCompactMasks) {
        output.writeln(
          '        || ${field.name}.mask != '
          '$layoutClassName.${field.name}Mask',
        );
      }
      output
        ..writeln('    ) {')
        ..writeln('      throw StateError(')
        ..writeln(
          "        'Generated metadata for $layoutName field \"${field.name}\" does not match the runtime layout.',",
        )
        ..writeln('      );')
        ..writeln('    }');
    }
    output
      ..writeln('    allFieldsSelection = layout.selectionFor(layout.fields);')
      ..writeln('  }')
      ..writeln();
    for (final _GeneratedField field in fields) {
      output.writeln(
        '  late final ${field.encoding.descriptorType} ${field.name};',
      );
    }
    output
      ..writeln()
      ..writeln('  late final RecordLayout layout;')
      ..writeln('  late final FieldSelection allFieldsSelection;')
      ..writeln('}');
    return output.toString();
  }

  String _constructorInvocation(
    String source,
    List<_GeneratedField> fields,
    ConstructorElement constructor, {
    bool fromData = false,
  }) {
    final Map<String, _GeneratedField> fieldsByName = <String, _GeneratedField>{
      for (final _GeneratedField field in fields) field.name: field,
    };
    final String className = _nameOf(constructor.enclosingElement);
    final List<String> arguments = <String>[];
    for (final FormalParameterElement parameter
        in constructor.formalParameters) {
      final _GeneratedField field = fieldsByName[_nameOf(parameter)]!;
      final String value = fromData
          ? '$source.${field.name}.read('
                'data, ${field.name}Offset, $source.layout.byteOrder)'
          : '$source.${field.name})';
      arguments.add(parameter.isNamed ? '${field.name}: $value' : value);
    }
    if (arguments.isEmpty) {
      return '$className()';
    }
    return '$className(${arguments.join(', ')})';
  }

  void _validateGeneratedMemberNames(
    String className,
    List<_GeneratedField> fields,
    ClassElement element,
  ) {
    const Set<String> reserved = <String>{
      'alignment',
      'allFieldsMask',
      'allFieldsSelection',
      '_schema',
      'allocate',
      'byteOrder',
      'deserialize',
      'layout',
      'read',
      'serialize',
      'sizeInBytes',
      'validate',
      'validateBytes',
      'write',
    };
    final Set<String> generatedNames = <String>{...reserved};
    for (final _GeneratedField field in fields) {
      final List<String> names = <String>[
        field.name,
        '${field.name}Index',
        '${field.name}Offset',
        '${field.name}Mask',
        '${field.name}Selection',
      ];
      for (final String name in names) {
        if (!generatedNames.add(name)) {
          _invalid(
            'Field "${field.name}" in "$className" conflicts with generated '
            'member "$name".',
            todo: 'Rename the field to avoid generated layout API names.',
            element: field.element,
          );
        }
      }
    }
  }

  void _validateGeneratedTopLevelNames(ClassElement recordClass) {
    final String className = _nameOf(recordClass);
    final LibraryElement library = recordClass.library;
    for (final String generatedName in <String>[
      '${className}Layout',
      '_${className}LayoutSchema',
    ]) {
      final Element? existing = _topLevelDeclarationNamed(
        library,
        generatedName,
      );
      if (existing != null && !_isGeneratedPartDeclaration(existing)) {
        _invalid(
          'Generated declaration "$generatedName" for "$className" '
          'conflicts with an existing top-level declaration.',
          todo: 'Rename the existing declaration or the generated record.',
          element: existing,
        );
      }
    }
  }
}

Element? _topLevelDeclarationNamed(LibraryElement library, String name) =>
    library.getClass(name) ??
    library.getEnum(name) ??
    library.getMixin(name) ??
    library.getExtension(name) ??
    library.getExtensionType(name) ??
    library.getTypeAlias(name) ??
    library.getTopLevelVariable(name) ??
    library.getTopLevelFunction(name) ??
    library.getGetter(name) ??
    library.getSetter(name);

bool _isGeneratedPartDeclaration(Element element) =>
    element.firstFragment.libraryFragment?.source.uri.path.endsWith(
      '.g.dart',
    ) ??
    false;

final class _FieldEncoding {
  const _FieldEncoding({
    required this.descriptorType,
    required this.dartType,
    required this.byteLength,
    required this.naturalAlignment,
    this.isFixedBytes = false,
  });

  final String descriptorType;
  final String dartType;
  final int byteLength;
  final int naturalAlignment;
  final bool isFixedBytes;

  static _FieldEncoding fromAnnotation(String name, Element element) {
    final _FieldEncoding? encoding = _encodings[name];
    if (encoding == null) {
      _invalid('Unsupported SlabFieldKind "$name".', element: element);
    }
    return encoding;
  }
}

const Map<String, _FieldEncoding> _encodings = <String, _FieldEncoding>{
  'int8': _FieldEncoding(
    descriptorType: 'Int8Field',
    dartType: 'int',
    byteLength: 1,
    naturalAlignment: 1,
  ),
  'uint8': _FieldEncoding(
    descriptorType: 'Uint8Field',
    dartType: 'int',
    byteLength: 1,
    naturalAlignment: 1,
  ),
  'int16': _FieldEncoding(
    descriptorType: 'Int16Field',
    dartType: 'int',
    byteLength: 2,
    naturalAlignment: 2,
  ),
  'uint16': _FieldEncoding(
    descriptorType: 'Uint16Field',
    dartType: 'int',
    byteLength: 2,
    naturalAlignment: 2,
  ),
  'int32': _FieldEncoding(
    descriptorType: 'Int32Field',
    dartType: 'int',
    byteLength: 4,
    naturalAlignment: 4,
  ),
  'uint32': _FieldEncoding(
    descriptorType: 'Uint32Field',
    dartType: 'int',
    byteLength: 4,
    naturalAlignment: 4,
  ),
  'int64': _FieldEncoding(
    descriptorType: 'Int64Field',
    dartType: 'int',
    byteLength: 8,
    naturalAlignment: 8,
  ),
  'uint64': _FieldEncoding(
    descriptorType: 'Uint64Field',
    dartType: 'int',
    byteLength: 8,
    naturalAlignment: 8,
  ),
  'uint64Value': _FieldEncoding(
    descriptorType: 'Uint64ValueField',
    dartType: 'Uint64Value',
    byteLength: 8,
    naturalAlignment: 8,
  ),
  'float32': _FieldEncoding(
    descriptorType: 'Float32Field',
    dartType: 'double',
    byteLength: 4,
    naturalAlignment: 4,
  ),
  'float64': _FieldEncoding(
    descriptorType: 'Float64Field',
    dartType: 'double',
    byteLength: 8,
    naturalAlignment: 8,
  ),
  'boolean': _FieldEncoding(
    descriptorType: 'BoolField',
    dartType: 'bool',
    byteLength: 1,
    naturalAlignment: 1,
  ),
  'fixedBytes': _FieldEncoding(
    descriptorType: 'FixedBytesField',
    dartType: 'Uint8List',
    byteLength: 0,
    naturalAlignment: 1,
    isFixedBytes: true,
  ),
};

final class _GeneratedField {
  _GeneratedField({
    required this.element,
    required this.name,
    required this.encoding,
    required this.byteLength,
    required this.requestedAlignment,
    required this.requestedOffset,
  });

  final FieldElement element;
  final String name;
  final _FieldEncoding encoding;
  final int byteLength;
  final int? requestedAlignment;
  final int? requestedOffset;
  late int index;
  late int offset;
  int? compactMask;
}

final class _LayoutMetadata {
  const _LayoutMetadata({required this.alignment, required this.sizeInBytes});

  final int alignment;
  final int sizeInBytes;
}

bool _matchesExpectedType(DartType type, _FieldEncoding encoding) {
  if (type.nullabilitySuffix != NullabilitySuffix.none) {
    return false;
  }
  return switch (encoding.dartType) {
    'int' => type.isDartCoreInt,
    'double' => type.isDartCoreDouble,
    'bool' => type.isDartCoreBool,
    'Uint8List' =>
      type.element?.name == 'Uint8List' &&
          type.element?.library?.uri.toString() == 'dart:typed_data',
    'Uint64Value' =>
      type.element?.name == 'Uint64Value' &&
          type.element?.library?.uri.toString() ==
              'package:pulse_slab/src/layout.dart',
    _ => false,
  };
}

int _alignUp(int value, int alignment, Element element) {
  final int remainder = value.remainder(alignment);
  final int padding = remainder == 0 ? 0 : alignment - remainder;
  if (value > _maximumPortableTypedDataLength - padding) {
    _invalid(
      'Generated layout exceeds the portable typed-data byte limit.',
      element: element,
    );
  }
  return value + padding;
}

bool _isValidAlignment(int value) {
  if (value <= 0 || value > _maximumPortableTypedDataLength) {
    return false;
  }
  while (value > 1) {
    if (value.remainder(2) != 0) {
      return false;
    }
    value ~/= 2;
  }
  return true;
}

int _allFieldsMask(List<_GeneratedField> fields) {
  var mask = 0;
  for (final _GeneratedField field in fields) {
    mask |= field.compactMask!;
  }
  return mask;
}

String _enumValue(
  ConstantReader reader, {
  required String member,
  required Element element,
}) {
  final String accessor = reader.revive().accessor;
  final int separator = accessor.lastIndexOf('.');
  if (separator < 0 || separator == accessor.length - 1) {
    _invalid(
      'Could not read @$member as a Pulse Slab enum value.',
      element: element,
    );
  }
  return accessor.substring(separator + 1);
}

Never _unexpectedEnumValue(String kind, String value, Element element) {
  _invalid('Unsupported generated $kind "$value".', element: element);
}

String _nameOf(Element element) {
  final String? name = element.name;
  if (name == null || name.isEmpty) {
    _invalid('Expected a named declaration.', element: element);
  }
  return name;
}

String _stringLiteral(String value) {
  final StringBuffer output = StringBuffer("'");
  for (final int unit in value.codeUnits) {
    switch (unit) {
      case 0x5c:
        output.write(r'\\');
        break;
      case 0x27:
        output.write(r"\'");
        break;
      case 0x24:
        output.write(r'\$');
        break;
      case 0x0a:
        output.write(r'\n');
        break;
      case 0x0d:
        output.write(r'\r');
        break;
      case 0x09:
        output.write(r'\t');
        break;
      default:
        if (unit < 0x20 || unit == 0x7f) {
          output
            ..write(r'\u')
            ..write(unit.toRadixString(16).padLeft(4, '0'));
        } else {
          output.writeCharCode(unit);
        }
    }
  }
  return '${output.toString()}\'';
}

Never _invalid(String message, {String todo = '', required Element element}) =>
    throw InvalidGenerationSourceError(message, todo: todo, element: element);
