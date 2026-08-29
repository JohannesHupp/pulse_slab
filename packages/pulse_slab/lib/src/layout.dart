import 'dart:typed_data';

import 'errors.dart';

/// The largest number of fields supported by one [RecordLayout].
///
/// A layout uses one Dart [int] and bitwise operators as its dirty-field mask.
/// JavaScript targets apply 32-bit bitwise semantics, so reserving the sign bit
/// keeps every portable mask non-negative and exact.
const int maxFieldsPerLayout = 31;

// Typed-data offsets and lengths stay below this portable positive range.
const int _maximumPortableTypedDataLength = 0x7fffffff;

/// A compact bit set that identifies fields changed by a record write.
typedef FieldMask = int;

/// A stable, typed descriptor for a value in a [RecordLayout].
///
/// Create field descriptors once, add them to exactly one layout, then use the
/// descriptor itself for all hot-path reads and writes. String names are only
/// metadata; records never look fields up by name during access.
abstract class Field<T> {
  /// Creates a field with a stable [name].
  ///
  /// Set [byteOffset] to place the field at an explicit position. Otherwise,
  /// [RecordLayout] places it at the next correctly aligned offset. An explicit
  /// offset must not overlap the preceding field.
  Field(
    this.name, {
    int? byteOffset,
    int? alignment,
  })  : _requestedByteOffset = byteOffset,
        _requestedAlignment = alignment {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'A field name must not be empty.',
      );
    }
    if (byteOffset != null &&
        (byteOffset < 0 || byteOffset >= _maximumPortableTypedDataLength)) {
      throw RangeError.value(
        byteOffset,
        'byteOffset',
        'A byte offset must be within the portable typed-data range.',
      );
    }
    if (alignment != null && !_isPowerOfTwo(alignment)) {
      throw ArgumentError.value(
        alignment,
        'alignment',
        'Alignment must be a positive power of two within the portable '
            'typed-data range.',
      );
    }
  }

  /// A descriptive name used in diagnostics and documentation.
  final String name;

  final int? _requestedByteOffset;
  final int? _requestedAlignment;
  RecordLayout? _layout;
  int? _offset;
  int? _index;

  /// The number of bytes occupied by this field.
  int get byteLength;

  /// The naturally efficient alignment for this field type.
  int get naturalAlignment;

  /// The requested explicit byte offset, if one was supplied.
  int? get requestedByteOffset => _requestedByteOffset;

  /// The alignment selected for this field before it is placed in a layout.
  int get alignment => _requestedAlignment ?? naturalAlignment;

  /// Whether this descriptor has been attached to a [RecordLayout].
  bool get isBound => _layout != null;

  /// The layout that owns this descriptor.
  ///
  /// Accessing this before the descriptor is added to a layout throws a
  /// [StateError]. A descriptor can belong to only one layout.
  RecordLayout get layout => _layout ?? _unboundFieldStateError(name);

  /// The byte offset within a record.
  int get offset => _offset ?? _unboundFieldStateError(name);

  /// The zero-based field position within [layout].
  int get index => _index ?? _unboundFieldStateError(name);

  /// The field's dirty bit in a change mask.
  ///
  /// Layouts are limited to [maxFieldsPerLayout], so this is always a
  /// non-negative bit that is portable to JavaScript targets.
  FieldMask get mask => 1 << index;

  /// Reads a value from [data] at [absoluteOffset].
  ///
  /// This primitive is exposed for custom field implementations. Application
  /// code should prefer [RecordReader.get], which checks handle and layout
  /// safety before calling it.
  T read(ByteData data, int absoluteOffset, Endian byteOrder);

  /// Writes [value] to [data] at [absoluteOffset].
  ///
  /// This primitive does not participate in dirty tracking. Application code
  /// should write through [RecordWriter.set].
  void write(ByteData data, int absoluteOffset, T value, Endian byteOrder);

  /// Returns whether encoding [value] would change the stored field bytes.
  ///
  /// The default scalar implementation uses value equality. Field types with
  /// byte-level equality semantics, such as floating point and fixed bytes,
  /// override this method. Custom fields should override it when their
  /// [writeIfChanged] implementation uses different comparison semantics.
  bool wouldChange(
    ByteData data,
    int absoluteOffset,
    T value,
    Endian byteOrder,
  ) =>
      read(data, absoluteOffset, byteOrder) != value;

  /// Writes [value] only when it differs from the stored value.
  ///
  /// Returns whether bytes changed. Scalar fields use value equality; floating
  /// point fields override this to compare their stored bit patterns.
  bool writeIfChanged(
    ByteData data,
    int absoluteOffset,
    T value,
    Endian byteOrder,
  ) {
    if (!wouldChange(data, absoluteOffset, value, byteOrder)) {
      return false;
    }
    write(data, absoluteOffset, value, byteOrder);
    return true;
  }

  void _bind(RecordLayout owner, int fieldOffset, int fieldIndex) {
    if (_layout != null) {
      throw LayoutException(
        'Field "$name" is already bound to layout "${_layout!.name}".',
      );
    }
    _layout = owner;
    _offset = fieldOffset;
    _index = fieldIndex;
  }

  /// Verifies that this descriptor belongs to [owner].
  ///
  /// This supports internal record access across package source libraries.
  void requireOwner(RecordLayout owner) {
    if (!identical(_layout, owner)) {
      throw FieldAccessException(
        'Field "$name" does not belong to layout "${owner.name}".',
      );
    }
  }
}

/// An 8-bit signed integer field.
final class Int8Field extends Field<int> {
  /// Creates an 8-bit signed integer field.
  Int8Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 1;

  @override
  int get naturalAlignment => 1;

  @override
  int read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      data.getInt8(absoluteOffset);

  @override
  void write(ByteData data, int absoluteOffset, int value, Endian byteOrder) {
    _checkIntegerRange(value, -128, 127, name);
    data.setInt8(absoluteOffset, value);
  }
}

/// An 8-bit unsigned integer field.
final class Uint8Field extends Field<int> {
  /// Creates an 8-bit unsigned integer field.
  Uint8Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 1;

  @override
  int get naturalAlignment => 1;

  @override
  int read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      data.getUint8(absoluteOffset);

  @override
  void write(ByteData data, int absoluteOffset, int value, Endian byteOrder) {
    _checkIntegerRange(value, 0, 0xff, name);
    data.setUint8(absoluteOffset, value);
  }
}

/// A 16-bit signed integer field.
final class Int16Field extends Field<int> {
  /// Creates a 16-bit signed integer field.
  Int16Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 2;

  @override
  int get naturalAlignment => 2;

  @override
  int read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      data.getInt16(absoluteOffset, byteOrder);

  @override
  void write(ByteData data, int absoluteOffset, int value, Endian byteOrder) {
    _checkIntegerRange(value, -0x8000, 0x7fff, name);
    data.setInt16(absoluteOffset, value, byteOrder);
  }
}

/// A 16-bit unsigned integer field.
final class Uint16Field extends Field<int> {
  /// Creates a 16-bit unsigned integer field.
  Uint16Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 2;

  @override
  int get naturalAlignment => 2;

  @override
  int read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      data.getUint16(absoluteOffset, byteOrder);

  @override
  void write(ByteData data, int absoluteOffset, int value, Endian byteOrder) {
    _checkIntegerRange(value, 0, 0xffff, name);
    data.setUint16(absoluteOffset, value, byteOrder);
  }
}

/// A 32-bit signed integer field.
final class Int32Field extends Field<int> {
  /// Creates a 32-bit signed integer field.
  Int32Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 4;

  @override
  int get naturalAlignment => 4;

  @override
  int read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      data.getInt32(absoluteOffset, byteOrder);

  @override
  void write(ByteData data, int absoluteOffset, int value, Endian byteOrder) {
    _checkIntegerRange(value, -0x80000000, 0x7fffffff, name);
    data.setInt32(absoluteOffset, value, byteOrder);
  }
}

/// A 32-bit unsigned integer field.
final class Uint32Field extends Field<int> {
  /// Creates a 32-bit unsigned integer field.
  Uint32Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 4;

  @override
  int get naturalAlignment => 4;

  @override
  int read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      data.getUint32(absoluteOffset, byteOrder);

  @override
  void write(ByteData data, int absoluteOffset, int value, Endian byteOrder) {
    _checkIntegerRange(value, 0, 0xffffffff, name);
    data.setUint32(absoluteOffset, value, byteOrder);
  }
}

/// A 64-bit signed integer field.
///
/// JavaScript targets cannot represent every 64-bit [int] exactly. Use a
/// [FixedBytesField] for portable full-width values in Flutter web.
final class Int64Field extends Field<int> {
  /// Creates a 64-bit signed integer field.
  Int64Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 8;

  @override
  int get naturalAlignment => 8;

  @override
  int read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      _readSignedInt64(data, absoluteOffset, byteOrder);

  @override
  void write(ByteData data, int absoluteOffset, int value, Endian byteOrder) {
    _writeSignedInt64(data, absoluteOffset, value, byteOrder, name);
  }
}

/// A 64-bit unsigned integer field.
///
/// This field accepts and returns a signed 64-bit bit pattern. A high-bit-set
/// value is represented as a negative [int], which preserves all raw bits on
/// native Dart. Use a domain-specific decimal or [BigInt] conversion at an API
/// boundary when a human-readable unsigned value above
/// `0x7fffffffffffffff` is required. JavaScript targets cannot represent every
/// 64-bit [int] exactly, so use a [FixedBytesField] for portable full-width
/// values in Flutter web.
final class Uint64Field extends Field<int> {
  /// Creates a 64-bit unsigned integer field.
  Uint64Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 8;

  @override
  int get naturalAlignment => 8;

  @override
  int read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      _readSignedInt64(data, absoluteOffset, byteOrder);

  @override
  void write(ByteData data, int absoluteOffset, int value, Endian byteOrder) {
    _writeSignedInt64(data, absoluteOffset, value, byteOrder, name);
  }
}

/// A 32-bit floating-point field.
final class Float32Field extends Field<double> {
  /// Creates a 32-bit floating-point field.
  Float32Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 4;

  @override
  int get naturalAlignment => 4;

  static final ByteData _comparisonData = ByteData(4);

  @override
  double read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      data.getFloat32(absoluteOffset, byteOrder);

  @override
  void write(
    ByteData data,
    int absoluteOffset,
    double value,
    Endian byteOrder,
  ) {
    data.setFloat32(absoluteOffset, value, byteOrder);
  }

  @override
  bool wouldChange(
    ByteData data,
    int absoluteOffset,
    double value,
    Endian byteOrder,
  ) {
    final ByteData comparisonData = _comparisonData;
    comparisonData.setFloat32(0, value, byteOrder);
    return data.getUint32(absoluteOffset, byteOrder) !=
        comparisonData.getUint32(0, byteOrder);
  }

  @override
  bool writeIfChanged(
    ByteData data,
    int absoluteOffset,
    double value,
    Endian byteOrder,
  ) {
    if (!wouldChange(data, absoluteOffset, value, byteOrder)) {
      return false;
    }
    write(data, absoluteOffset, value, byteOrder);
    return true;
  }
}

/// A 64-bit floating-point field.
final class Float64Field extends Field<double> {
  /// Creates a 64-bit floating-point field.
  Float64Field(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 8;

  @override
  int get naturalAlignment => 8;

  static final ByteData _comparisonData = ByteData(8);

  @override
  double read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      data.getFloat64(absoluteOffset, byteOrder);

  @override
  void write(
    ByteData data,
    int absoluteOffset,
    double value,
    Endian byteOrder,
  ) {
    data.setFloat64(absoluteOffset, value, byteOrder);
  }

  @override
  bool wouldChange(
    ByteData data,
    int absoluteOffset,
    double value,
    Endian byteOrder,
  ) {
    final ByteData comparisonData = _comparisonData;
    comparisonData.setFloat64(0, value, byteOrder);
    // A Dart JavaScript integer cannot represent every 64-bit bit pattern.
    // Compare exact 32-bit words instead, including the stored byte order.
    return data.getUint32(absoluteOffset, byteOrder) !=
            comparisonData.getUint32(0, byteOrder) ||
        data.getUint32(absoluteOffset + 4, byteOrder) !=
            comparisonData.getUint32(4, byteOrder);
  }

  @override
  bool writeIfChanged(
    ByteData data,
    int absoluteOffset,
    double value,
    Endian byteOrder,
  ) {
    if (!wouldChange(data, absoluteOffset, value, byteOrder)) {
      return false;
    }
    write(data, absoluteOffset, value, byteOrder);
    return true;
  }
}

/// A compact one-byte boolean field.
///
/// The stored representation is zero for `false` and one for `true`.
final class BoolField extends Field<bool> {
  /// Creates a one-byte boolean field.
  BoolField(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 1;

  @override
  int get naturalAlignment => 1;

  @override
  bool read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      data.getUint8(absoluteOffset) != 0;

  @override
  void write(
    ByteData data,
    int absoluteOffset,
    bool value,
    Endian byteOrder,
  ) {
    data.setUint8(absoluteOffset, value ? 1 : 0);
  }
}

/// A fixed-width byte field.
///
/// [read] returns a defensive copy so a reader cannot mutate store memory.
/// Use [RecordReader.bytesView] when a zero-copy, read-only access pattern is
/// appropriate; its result deliberately does not expose a mutable list.
class BytesField extends Field<Uint8List> {
  /// Creates a fixed-width byte field containing exactly [length] bytes.
  BytesField(
    super.name,
    this.length, {
    super.byteOffset,
    super.alignment,
  }) {
    if (length <= 0) {
      throw RangeError.value(
        length,
        'length',
        'A byte field length must be greater than zero.',
      );
    }
  }

  /// The fixed byte count for values in this field.
  final int length;

  @override
  int get byteLength => length;

  @override
  int get naturalAlignment => 1;

  @override
  Uint8List read(ByteData data, int absoluteOffset, Endian byteOrder) {
    final Uint8List source = data.buffer.asUint8List(
      data.offsetInBytes + absoluteOffset,
      length,
    );
    return Uint8List.fromList(source);
  }

  @override
  void write(
    ByteData data,
    int absoluteOffset,
    Uint8List value,
    Endian byteOrder,
  ) {
    _checkLength(value);
    final Uint8List destination = data.buffer.asUint8List(
      data.offsetInBytes + absoluteOffset,
      length,
    );
    destination.setRange(0, length, value);
  }

  @override
  bool writeIfChanged(
    ByteData data,
    int absoluteOffset,
    Uint8List value,
    Endian byteOrder,
  ) {
    if (!wouldChange(data, absoluteOffset, value, byteOrder)) {
      return false;
    }
    write(data, absoluteOffset, value, byteOrder);
    return true;
  }

  @override
  bool wouldChange(
    ByteData data,
    int absoluteOffset,
    Uint8List value,
    Endian byteOrder,
  ) {
    _checkLength(value);
    final Uint8List destination = data.buffer.asUint8List(
      data.offsetInBytes + absoluteOffset,
      length,
    );
    for (var index = 0; index < length; index++) {
      if (destination[index] != value[index]) {
        return true;
      }
    }
    return false;
  }

  /// Creates a non-mutating, zero-copy view for this field.
  ByteView view(
    ByteData data,
    int absoluteOffset, {
    void Function()? validate,
  }) =>
      ByteView._(
        data.buffer.asUint8List(),
        data.offsetInBytes + absoluteOffset,
        length,
        validate,
      );

  void _checkLength(Uint8List value) {
    if (value.length != length) {
      throw ArgumentError.value(
        value.length,
        'value',
        'Field "$name" requires exactly $length bytes.',
      );
    }
  }
}

/// A descriptive alias for [BytesField].
final class FixedBytesField extends BytesField {
  /// Creates a fixed-width byte field containing exactly [length] bytes.
  FixedBytesField(
    super.name,
    super.length, {
    super.byteOffset,
    super.alignment,
  });
}

/// A read-only, zero-copy byte range backed by a record segment.
///
/// A view is valid only while its associated record remains allocated. It is
/// intentionally not a [Uint8List], so callers cannot bypass write tracking by
/// mutating store memory through a reader.
final class ByteView {
  const ByteView._(
    this._backing,
    this._start,
    this.length,
    this._validate,
  );

  final Uint8List _backing;
  final int _start;
  final void Function()? _validate;

  /// The byte count in this view.
  final int length;

  /// Returns the byte at [index].
  int operator [](int index) {
    _validate?.call();
    RangeError.checkValidIndex(index, this, 'index', length);
    return _backing[_start + index];
  }

  /// Copies this view to an independently owned byte list.
  Uint8List toUint8List() {
    _validate?.call();
    final Uint8List copy = Uint8List(length);
    copy.setRange(0, length, _backing, _start);
    return copy;
  }
}

/// Defines a compact, aligned record format for one family of store records.
///
/// Field offsets are calculated once during construction. The package supports up
/// to [maxFieldsPerLayout] fields because one signed Dart [int] carries dirty
/// field bits. A descriptor may be attached to only one layout.
final class RecordLayout {
  /// Creates a layout from stable typed [fields].
  ///
  /// [byteOrder] controls multi-byte scalar encoding. [alignment], when set,
  /// must be a power of two and cannot be smaller than a field's alignment.
  RecordLayout({
    required this.name,
    required Iterable<Field<Object?>> fields,
    Endian? byteOrder,
    int? alignment,
  })  : _requestedAlignment = alignment,
        byteOrder = byteOrder ?? Endian.host {
    if (name.trim().isEmpty) {
      throw ArgumentError.value(
        name,
        'name',
        'A layout name must not be empty.',
      );
    }
    if (alignment != null && !_isPowerOfTwo(alignment)) {
      throw ArgumentError.value(
        alignment,
        'alignment',
        'Alignment must be a positive power of two within the portable '
            'typed-data range.',
      );
    }

    final List<Field<Object?>> selectedFields =
        List<Field<Object?>>.of(fields, growable: false);
    if (selectedFields.isEmpty) {
      throw LayoutException('Layout "$name" must contain at least one field.');
    }
    if (selectedFields.length > maxFieldsPerLayout) {
      throw LayoutException(
        'Layout "$name" has ${selectedFields.length} fields; '
        'the current limit is $maxFieldsPerLayout.',
      );
    }

    final Set<String> names = <String>{};
    final Set<Field<Object?>> descriptors = <Field<Object?>>{};
    final List<({Field<Object?> field, int offset, int index})> bindings =
        <({Field<Object?> field, int offset, int index})>[];
    var cursor = 0;
    var maximumFieldAlignment = 1;

    for (var index = 0; index < selectedFields.length; index++) {
      final Field<Object?> field = selectedFields[index];
      if (!names.add(field.name)) {
        throw LayoutException(
          'Layout "$name" contains the duplicate field name "${field.name}".',
        );
      }
      if (!descriptors.add(field)) {
        throw LayoutException(
          'Layout "$name" contains field "${field.name}" more than once.',
        );
      }
      if (field.isBound) {
        throw LayoutException(
          'Field "${field.name}" is already bound to layout '
          '"${field.layout.name}".',
        );
      }
      if (!_isPowerOfTwo(field.alignment)) {
        throw LayoutException(
          'Field "${field.name}" has invalid alignment ${field.alignment}.',
        );
      }
      final int fieldByteLength = field.byteLength;
      if (fieldByteLength <= 0 ||
          fieldByteLength > _maximumPortableTypedDataLength) {
        throw LayoutException(
          'Field "${field.name}" has invalid byte length $fieldByteLength.',
        );
      }

      final int requestedOffset = field.requestedByteOffset ?? -1;
      final int offset;
      if (requestedOffset >= 0) {
        if (requestedOffset < cursor) {
          throw LayoutException(
            'Field "${field.name}" at offset $requestedOffset overlaps or '
            'precedes the current record extent $cursor.',
          );
        }
        if (requestedOffset % field.alignment != 0) {
          throw LayoutException(
            'Field "${field.name}" offset $requestedOffset is not aligned to '
            '${field.alignment} bytes.',
          );
        }
        offset = requestedOffset;
      } else {
        offset = _alignUp(cursor, field.alignment);
      }
      if (offset > _maximumPortableTypedDataLength - fieldByteLength) {
        throw LayoutException(
          'Layout "$name" exceeds the portable typed-data byte limit.',
        );
      }
      cursor = offset + fieldByteLength;
      if (field.alignment > maximumFieldAlignment) {
        maximumFieldAlignment = field.alignment;
      }
      bindings.add((field: field, offset: offset, index: index));
    }

    if (alignment != null && alignment < maximumFieldAlignment) {
      throw LayoutException(
        'Layout "$name" alignment $alignment is smaller than the required '
        'field alignment $maximumFieldAlignment.',
      );
    }
    this.alignment = alignment ?? maximumFieldAlignment;
    sizeInBytes = _alignUp(cursor, this.alignment);
    _fields = List<Field<Object?>>.unmodifiable(selectedFields);

    for (final binding in bindings) {
      binding.field._bind(this, binding.offset, binding.index);
    }
  }

  /// A descriptive layout name.
  final String name;

  /// Byte order used by multi-byte fields in this layout.
  final Endian byteOrder;

  final int? _requestedAlignment;

  /// Record alignment in bytes.
  late final int alignment;

  /// Total record size including trailing alignment padding.
  late final int sizeInBytes;

  late final List<Field<Object?>> _fields;

  /// Stable field descriptors in their layout order.
  List<Field<Object?>> get fields => _fields;

  /// The alignment explicitly requested by the caller, if any.
  int? get requestedAlignment => _requestedAlignment;

  /// Returns the union mask for [selectedFields].
  ///
  /// This setup-time helper verifies that every descriptor belongs to this
  /// layout. The returned mask can be passed directly to subscriptions.
  FieldMask maskFor(Iterable<Field<Object?>> selectedFields) {
    var result = 0;
    for (final Field<Object?> field in selectedFields) {
      field.requireOwner(this);
      result |= field.mask;
    }
    return result;
  }

  @override
  String toString() =>
      'RecordLayout(name: $name, sizeInBytes: $sizeInBytes, alignment: $alignment)';
}

Never _unboundFieldStateError(String name) => throw StateError(
      'Field "$name" must be bound to a RecordLayout before use.',
    );

int _alignUp(int value, int alignment) {
  final int remainder = value.remainder(alignment);
  final int padding = remainder == 0 ? 0 : alignment - remainder;
  if (value > _maximumPortableTypedDataLength - padding) {
    throw LayoutException('Layout exceeds the portable typed-data byte limit.');
  }
  return value + padding;
}

bool _isPowerOfTwo(int value) {
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

void _checkIntegerRange(int value, int minimum, int maximum, String fieldName) {
  if (value < minimum || value > maximum) {
    throw RangeError.value(
      value,
      fieldName,
      'Value must fit in the range $minimum through $maximum.',
    );
  }
}

void _checkSignedInt64Range(int value, String fieldName) {
  // Use arithmetic rather than a bitwise shift. JavaScript back ends apply
  // 32-bit semantics to bitwise operations, while this retains native 64-bit
  // range validation without a non-exact 64-bit literal.
  final int upperWord = value ~/ _int64WordSize;
  final int remainder = value.remainder(_int64WordSize);
  if (upperWord < -0x80000000 ||
      upperWord > 0x7fffffff ||
      (upperWord == -0x80000000 && remainder < 0)) {
    throw RangeError.value(
      value,
      fieldName,
      'Value must fit in a signed 64-bit bit pattern.',
    );
  }
}

int _readSignedInt64(ByteData data, int offset, Endian byteOrder) {
  final int highWord;
  final int lowWord;
  if (byteOrder == Endian.little) {
    lowWord = data.getUint32(offset, Endian.little);
    highWord = data.getInt32(offset + 4, Endian.little);
  } else {
    highWord = data.getInt32(offset, Endian.big);
    lowWord = data.getUint32(offset + 4, Endian.big);
  }
  return highWord * _int64WordSize + lowWord;
}

void _writeSignedInt64(
  ByteData data,
  int offset,
  int value,
  Endian byteOrder,
  String fieldName,
) {
  _checkSignedInt64Range(value, fieldName);
  final int quotient = value ~/ _int64WordSize;
  final int remainder = value.remainder(_int64WordSize);
  final int highWord;
  final int lowWord;
  if (remainder < 0) {
    highWord = quotient - 1;
    lowWord = remainder + _int64WordSize;
  } else {
    highWord = quotient;
    lowWord = remainder;
  }
  if (byteOrder == Endian.little) {
    data.setUint32(offset, lowWord, Endian.little);
    data.setInt32(offset + 4, highWord, Endian.little);
  } else {
    data.setInt32(offset, highWord, Endian.big);
    data.setUint32(offset + 4, lowWord, Endian.big);
  }
}

const int _int64WordSize = 0x100000000;
