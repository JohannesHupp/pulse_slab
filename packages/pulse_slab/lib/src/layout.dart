import 'dart:typed_data';

import 'errors.dart';

/// The largest number of fields supported by the compact [FieldMask] API.
///
/// This legacy constant intentionally remains at 31 for source compatibility.
/// [RecordLayout] itself can contain more fields: use [FieldSelection] for
/// portable dirty tracking and filtering when a layout exceeds this count.
///
/// A compact mask uses one Dart [int] and bitwise operators. JavaScript targets
/// apply 32-bit bitwise semantics, so reserving the sign bit keeps every compact
/// mask non-negative and exact.
const int maxFieldsPerLayout = 31;

const int _fieldSelectionWordBits = 31;
const int _maximumPortableFieldMask = 0x7fffffff;

// Typed-data offsets and lengths stay below this portable positive range.
const int _maximumPortableTypedDataLength = 0x7fffffff;

/// A compact bit set that identifies fields changed by a record write.
typedef FieldMask = int;

/// An immutable, layout-scoped field selection for layouts of any width.
///
/// Compact layouts use a single [FieldMask]. Wider layouts use 31-bit words so
/// that every operation remains portable to JavaScript targets. Obtain a
/// selection from [RecordLayout.selectionFor] or [Field.selection].
///
/// Unlike the legacy integer-mask APIs, an empty selection means no fields.
/// APIs that accept an optional selection use `null` to mean all fields.
final class FieldSelection {
  const FieldSelection._compact(this.layout, this._compactMask) : _words = null;

  FieldSelection._wide(this.layout, this._words) : _compactMask = 0;

  /// The layout whose field indexes this selection identifies.
  final RecordLayout layout;

  final FieldMask _compactMask;
  final Uint32List? _words;

  /// Whether this selection uses the compact integer representation.
  bool get isCompact => _words == null;

  /// Whether no fields are selected.
  bool get isEmpty {
    final Uint32List? words = _words;
    if (words == null) {
      return _compactMask == 0;
    }
    for (final int word in words) {
      if (word != 0) {
        return false;
      }
    }
    return true;
  }

  /// The compact integer mask.
  ///
  /// This is available only when [isCompact] is true. Wide selections must be
  /// used with [intersects], [union], or field descriptors rather than being
  /// truncated to an integer mask.
  FieldMask get fieldMask {
    if (!isCompact) {
      throw StateError(
        'Field selection for layout "${layout.name}" is wider than '
        '$maxFieldsPerLayout fields and has no portable integer mask.',
      );
    }
    return _compactMask;
  }

  /// Returns whether [field] is included in this selection.
  bool contains(Field<Object?> field) {
    field.requireOwner(layout);
    return _containsIndex(field.index);
  }

  /// Returns whether this selection shares at least one field with [other].
  ///
  /// Selections from different layouts cannot be compared because their field
  /// indexes have unrelated meanings.
  bool intersects(FieldSelection other) {
    _requireSameLayout(other);
    final Uint32List? words = _words;
    if (words == null) {
      return (_compactMask & other._compactMask) != 0;
    }
    final Uint32List otherWords = other._words!;
    for (var index = 0; index < words.length; index++) {
      if ((words[index] & otherWords[index]) != 0) {
        return true;
      }
    }
    return false;
  }

  /// Returns a selection containing the fields in this selection and [other].
  FieldSelection union(FieldSelection other) {
    _requireSameLayout(other);
    final Uint32List? words = _words;
    if (words == null) {
      return FieldSelection._compact(layout, _compactMask | other._compactMask);
    }
    final Uint32List otherWords = other._words!;
    final Uint32List merged = Uint32List(words.length);
    for (var index = 0; index < words.length; index++) {
      merged[index] = words[index] | otherWords[index];
    }
    return FieldSelection._wide(layout, merged);
  }

  bool _containsIndex(int index) {
    final Uint32List? words = _words;
    if (words == null) {
      return (_compactMask & (1 << index)) != 0;
    }
    final int wordIndex = index ~/ _fieldSelectionWordBits;
    final int bitIndex = index % _fieldSelectionWordBits;
    return (words[wordIndex] & (1 << bitIndex)) != 0;
  }

  void _requireSameLayout(FieldSelection other) {
    if (!identical(layout, other.layout)) {
      throw ArgumentError(
        'Field selections must belong to the same RecordLayout.',
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (other is! FieldSelection || !identical(layout, other.layout)) {
      return false;
    }
    final Uint32List? words = _words;
    final Uint32List? otherWords = other._words;
    if (words == null || otherWords == null) {
      return words == null &&
          otherWords == null &&
          _compactMask == other._compactMask;
    }
    if (words.length != otherWords.length) {
      return false;
    }
    for (var index = 0; index < words.length; index++) {
      if (words[index] != otherWords[index]) {
        return false;
      }
    }
    return true;
  }

  @override
  int get hashCode {
    final Uint32List? words = _words;
    var result = identityHashCode(layout);
    if (words == null) {
      return Object.hash(result, _compactMask);
    }
    for (final int word in words) {
      result = Object.hash(result, word);
    }
    return result;
  }

  @override
  String toString() {
    if (isCompact) {
      return 'FieldSelection(layout: ${layout.name}, '
          'mask: 0x${_compactMask.toRadixString(16)})';
    }
    return 'FieldSelection(layout: ${layout.name}, wide: true)';
  }
}

/// Incrementally builds a layout-scoped [FieldSelection].
///
/// This is useful when selected fields are discovered dynamically. It keeps a
/// compact integer for small layouts and allocates one 31-bit word buffer for a
/// wide layout, independent of how often the same field is added.
final class FieldSelectionBuilder {
  /// Creates a builder for [layout].
  FieldSelectionBuilder(this.layout);

  /// The layout whose fields may be added.
  final RecordLayout layout;

  FieldMask _compactMask = 0;
  Uint32List? _wideWords;

  /// Whether no fields have been added since construction or [clear].
  bool get isEmpty {
    if (layout.supportsFieldMasks) {
      return _compactMask == 0;
    }
    final Uint32List? words = _wideWords;
    if (words == null) {
      return true;
    }
    for (final int word in words) {
      if (word != 0) {
        return false;
      }
    }
    return true;
  }

  /// Adds [field] to this builder.
  ///
  /// Adding the same field more than once is safe and does not grow the
  /// resulting selection.
  void add(Field<Object?> field) {
    field.requireOwner(layout);
    if (layout.supportsFieldMasks) {
      _compactMask |= field.mask;
      return;
    }
    final Uint32List words = _wideWords ??= Uint32List(
      (layout.fields.length + _fieldSelectionWordBits - 1) ~/
          _fieldSelectionWordBits,
    );
    final int wordIndex = field.index ~/ _fieldSelectionWordBits;
    final int bitIndex = field.index % _fieldSelectionWordBits;
    words[wordIndex] |= 1 << bitIndex;
  }

  /// Returns an immutable snapshot of the selected fields.
  FieldSelection build() {
    if (layout.supportsFieldMasks) {
      return layout.selectionFromMask(_compactMask);
    }
    final Uint32List? words = _wideWords;
    if (words == null) {
      return layout.selectionFor(const <Field<Object?>>[]);
    }
    return FieldSelection._wide(layout, Uint32List.fromList(words));
  }

  /// Removes every accumulated field while retaining any allocated word buffer.
  void clear() {
    _compactMask = 0;
    final Uint32List? words = _wideWords;
    if (words != null) {
      words.fillRange(0, words.length, 0);
    }
  }
}

/// An exact, portable unsigned 64-bit value represented as two unsigned words.
///
/// Dart JavaScript targets cannot exactly represent every 64-bit integer as one
/// `int`. This value deliberately never combines its words into a 64-bit Dart
/// integer, so [highWord] and [lowWord] retain every bit on native and web
/// targets. This API intentionally does not accept or return one full-width
/// Dart [int]. Construct values with [Uint64Value.fromWords], and use
/// [Uint64ValueField] for typed-memory storage.
final class Uint64Value implements Comparable<Uint64Value> {
  /// Creates an exact unsigned value from two unsigned 32-bit words.
  ///
  /// [highWord] contains bits 63 through 32 and [lowWord] contains bits 31
  /// through 0. Both words must be from zero through `0xffffffff`, or this
  /// constructor throws a [RangeError].
  Uint64Value.fromWords({required this.highWord, required this.lowWord}) {
    _validateWord(highWord, 'highWord');
    _validateWord(lowWord, 'lowWord');
  }

  const Uint64Value._unchecked(this.highWord, this.lowWord);

  /// The value with every bit cleared.
  static const Uint64Value zero = Uint64Value._unchecked(0, 0);

  /// The value whose unsigned bit 63 is set and every other bit is clear.
  static const Uint64Value highBit = Uint64Value._unchecked(0x80000000, 0);

  /// The largest representable unsigned 64-bit value.
  static const Uint64Value maxValue =
      Uint64Value._unchecked(0xffffffff, 0xffffffff);

  /// Most-significant unsigned 32-bit word.
  final int highWord;

  /// Least-significant unsigned 32-bit word.
  final int lowWord;

  /// Returns whether every bit is zero.
  bool get isZero => highWord == 0 && lowWord == 0;

  /// Decodes eight bytes in [byteOrder] into an exact unsigned value.
  ///
  /// [bytes] must contain exactly eight bytes. Pass the same byte order to
  /// [toBytes] and [fromBytes] when round-tripping a wire value.
  factory Uint64Value.fromBytes(
    Uint8List bytes, {
    Endian byteOrder = Endian.big,
  }) {
    if (bytes.length != 8) {
      throw RangeError.value(
        bytes.length,
        'bytes.length',
        'Must contain exactly 8 bytes.',
      );
    }
    final ByteData data = ByteData.sublistView(bytes);
    return _readUint64Value(data, 0, byteOrder);
  }

  /// Encodes this exact bit pattern into a new eight-byte list in [byteOrder].
  Uint8List toBytes({Endian byteOrder = Endian.big}) {
    final ByteData data = ByteData(8);
    _writeUint64Value(data, 0, this, byteOrder);
    return data.buffer.asUint8List();
  }

  /// Compares this unsigned value with [other] by high word then low word.
  @override
  int compareTo(Uint64Value other) {
    final int highComparison = highWord.compareTo(other.highWord);
    if (highComparison != 0) {
      return highComparison;
    }
    return lowWord.compareTo(other.lowWord);
  }

  /// Returns this bit pattern as 16 lowercase hexadecimal digits.
  ///
  /// The result includes `0x` unless [includePrefix] is false.
  String toHexString({bool includePrefix = true}) {
    final String value = '${highWord.toRadixString(16).padLeft(8, '0')}'
        '${lowWord.toRadixString(16).padLeft(8, '0')}';
    return includePrefix ? '0x$value' : value;
  }

  @override
  bool operator ==(Object other) =>
      other is Uint64Value &&
      highWord == other.highWord &&
      lowWord == other.lowWord;

  @override
  int get hashCode => Object.hash(highWord, lowWord);

  @override
  String toString() => 'Uint64Value(${toHexString()})';

  static void _validateWord(int value, String name) {
    if (value < 0 || value > _maximumUint32) {
      throw RangeError.value(
        value,
        name,
        'Must be an unsigned 32-bit word.',
      );
    }
  }
}

const int _maximumUint32 = 0xffffffff;

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
  FieldMask? _compactMask;
  FieldSelection? _selection;

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

  /// The field's compact dirty bit in a change mask.
  ///
  /// This remains available for layouts with at most [maxFieldsPerLayout]
  /// fields. Use [selection] for wider layouts.
  FieldMask get mask {
    final FieldMask? compactMask = _compactMask;
    if (compactMask == null) {
      throw StateError(
        'Field "$name" belongs to wide layout "${layout.name}". '
        'Use Field.selection or RecordLayout.selectionFor instead of mask.',
      );
    }
    return compactMask;
  }

  /// This field as a layout-scoped [FieldSelection].
  ///
  /// Wide singleton selections are created lazily so constructing a large
  /// layout does not allocate one word set per field.
  FieldSelection get selection {
    final FieldSelection? current = _selection;
    if (current != null) {
      return current;
    }
    final RecordLayout owner = _layout ?? _unboundFieldStateError(name);
    final int fieldIndex = _index ?? _unboundFieldStateError(name);
    return _selection = owner._selectionForIndex(fieldIndex);
  }

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

  /// Validates that [value] can be stored by this field.
  ///
  /// The default implementation accepts every value. Built-in integer and
  /// fixed-byte fields override this to expose the same range and length
  /// checks performed by [write]. This lets generated serializers validate a
  /// model before choosing where to encode it.
  void validate(T value) {}

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
    if (owner.supportsFieldMasks) {
      _compactMask = 1 << fieldIndex;
    }
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
    validate(value);
    data.setInt8(absoluteOffset, value);
  }

  @override
  void validate(int value) => _checkIntegerRange(value, -128, 127, name);
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
    validate(value);
    data.setUint8(absoluteOffset, value);
  }

  @override
  void validate(int value) => _checkIntegerRange(value, 0, 0xff, name);
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
    validate(value);
    data.setInt16(absoluteOffset, value, byteOrder);
  }

  @override
  void validate(int value) => _checkIntegerRange(value, -0x8000, 0x7fff, name);
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
    validate(value);
    data.setUint16(absoluteOffset, value, byteOrder);
  }

  @override
  void validate(int value) => _checkIntegerRange(value, 0, 0xffff, name);
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
    validate(value);
    data.setInt32(absoluteOffset, value, byteOrder);
  }

  @override
  void validate(int value) =>
      _checkIntegerRange(value, -0x80000000, 0x7fffffff, name);
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
    validate(value);
    data.setUint32(absoluteOffset, value, byteOrder);
  }

  @override
  void validate(int value) => _checkIntegerRange(value, 0, 0xffffffff, name);
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
    validate(value);
    _writeSignedInt64Unchecked(data, absoluteOffset, value, byteOrder);
  }

  @override
  void validate(int value) => _checkSignedInt64Range(value, name);
}

/// A 64-bit unsigned integer field.
///
/// This legacy field accepts and returns a signed 64-bit raw two's-complement
/// bit pattern. A high-bit-set value is represented as a negative [int], which
/// preserves existing behavior on native Dart. JavaScript targets cannot
/// exactly represent every 64-bit [int].
///
/// Use [Uint64ValueField] for new data that needs portable full-width unsigned
/// comparison and serialization. It uses two exact 32-bit words instead of a
/// full-width Dart [int].
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
    validate(value);
    _writeSignedInt64Unchecked(data, absoluteOffset, value, byteOrder);
  }

  @override
  void validate(int value) => _checkSignedInt64Range(value, name);
}

/// An exact unsigned 64-bit field backed by [Uint64Value] words.
///
/// Unlike the legacy [Uint64Field], this field never exposes an imprecise
/// 64-bit Dart [int] on JavaScript targets. Reads materialize one immutable
/// [Uint64Value]; no-op change checks compare stored words directly and do not
/// allocate a value object. Its bytes use the owning [RecordLayout.byteOrder].
final class Uint64ValueField extends Field<Uint64Value> {
  /// Creates a portable unsigned 64-bit field.
  Uint64ValueField(
    super.name, {
    super.byteOffset,
    super.alignment,
  });

  @override
  int get byteLength => 8;

  @override
  int get naturalAlignment => 8;

  @override
  Uint64Value read(ByteData data, int absoluteOffset, Endian byteOrder) =>
      _readUint64Value(data, absoluteOffset, byteOrder);

  @override
  void write(
    ByteData data,
    int absoluteOffset,
    Uint64Value value,
    Endian byteOrder,
  ) {
    _writeUint64Value(data, absoluteOffset, value, byteOrder);
  }

  @override
  bool wouldChange(
    ByteData data,
    int absoluteOffset,
    Uint64Value value,
    Endian byteOrder,
  ) {
    if (byteOrder == Endian.little) {
      return data.getUint32(absoluteOffset, Endian.little) != value.lowWord ||
          data.getUint32(absoluteOffset + 4, Endian.little) != value.highWord;
    }
    return data.getUint32(absoluteOffset, Endian.big) != value.highWord ||
        data.getUint32(absoluteOffset + 4, Endian.big) != value.lowWord;
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
    validate(value);
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
    validate(value);
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

  @override
  void validate(Uint8List value) => _checkLength(value);

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
/// Field offsets are calculated once during construction. Layouts with up to
/// [maxFieldsPerLayout] fields use compact integer dirty masks; wider layouts
/// use [FieldSelection]. A descriptor may be attached to only one layout.
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

  /// Whether this layout can use the legacy compact [FieldMask] API.
  bool get supportsFieldMasks => _fields.length <= maxFieldsPerLayout;

  /// Returns the union mask for [selectedFields].
  ///
  /// This setup-time helper verifies that every descriptor belongs to this
  /// layout. The returned mask can be passed directly to compact-layout
  /// subscriptions. Use [selectionFor] for wider layouts.
  FieldMask maskFor(Iterable<Field<Object?>> selectedFields) {
    if (!supportsFieldMasks) {
      throw StateError(
        'Layout "$name" has more than $maxFieldsPerLayout fields. '
        'Use selectionFor instead of maskFor.',
      );
    }
    var result = 0;
    for (final Field<Object?> field in selectedFields) {
      field.requireOwner(this);
      result |= field.mask;
    }
    return result;
  }

  /// Returns a portable selection for [selectedFields].
  ///
  /// Every descriptor must belong to this layout. This is the preferred API
  /// for layouts wider than [maxFieldsPerLayout], and is also available for
  /// compact layouts when one uniform representation is useful.
  FieldSelection selectionFor(Iterable<Field<Object?>> selectedFields) {
    if (supportsFieldMasks) {
      var result = 0;
      for (final Field<Object?> field in selectedFields) {
        field.requireOwner(this);
        result |= field.mask;
      }
      return FieldSelection._compact(this, result);
    }

    final Uint32List words = Uint32List(
      (_fields.length + _fieldSelectionWordBits - 1) ~/ _fieldSelectionWordBits,
    );
    for (final Field<Object?> field in selectedFields) {
      field.requireOwner(this);
      final int wordIndex = field.index ~/ _fieldSelectionWordBits;
      final int bitIndex = field.index % _fieldSelectionWordBits;
      words[wordIndex] |= 1 << bitIndex;
    }
    return FieldSelection._wide(this, words);
  }

  FieldSelection _selectionForIndex(int index) {
    if (supportsFieldMasks) {
      return FieldSelection._compact(this, 1 << index);
    }
    final Uint32List words = Uint32List(
      (_fields.length + _fieldSelectionWordBits - 1) ~/ _fieldSelectionWordBits,
    );
    final int wordIndex = index ~/ _fieldSelectionWordBits;
    final int bitIndex = index % _fieldSelectionWordBits;
    words[wordIndex] = 1 << bitIndex;
    return FieldSelection._wide(this, words);
  }

  /// Converts a validated compact [mask] into a [FieldSelection].
  ///
  /// This is useful when adapting an existing compact-mask API. Wider layouts
  /// must use [selectionFor] because an integer cannot represent every field.
  FieldSelection selectionFromMask(FieldMask mask) {
    if (!supportsFieldMasks) {
      throw StateError(
        'Layout "$name" has more than $maxFieldsPerLayout fields and '
        'cannot create a compact field selection.',
      );
    }
    if (mask < 0 || mask > _maximumPortableFieldMask) {
      throw ArgumentError.value(
        mask,
        'mask',
        'Must be a non-negative portable field mask.',
      );
    }
    final int supportedMask = _fields.length == maxFieldsPerLayout
        ? _maximumPortableFieldMask
        : (1 << _fields.length) - 1;
    if ((mask & ~supportedMask) != 0) {
      throw ArgumentError.value(
        mask,
        'mask',
        'Contains bits outside layout "$name".',
      );
    }
    return FieldSelection._compact(this, mask);
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

Uint64Value _readUint64Value(
  ByteData data,
  int offset,
  Endian byteOrder,
) {
  final int highWord;
  final int lowWord;
  if (byteOrder == Endian.little) {
    lowWord = data.getUint32(offset, Endian.little);
    highWord = data.getUint32(offset + 4, Endian.little);
  } else {
    highWord = data.getUint32(offset, Endian.big);
    lowWord = data.getUint32(offset + 4, Endian.big);
  }
  return Uint64Value._unchecked(highWord, lowWord);
}

void _writeUint64Value(
  ByteData data,
  int offset,
  Uint64Value value,
  Endian byteOrder,
) {
  if (byteOrder == Endian.little) {
    data.setUint32(offset, value.lowWord, Endian.little);
    data.setUint32(offset + 4, value.highWord, Endian.little);
  } else {
    data.setUint32(offset, value.highWord, Endian.big);
    data.setUint32(offset + 4, value.lowWord, Endian.big);
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

void _writeSignedInt64Unchecked(
  ByteData data,
  int offset,
  int value,
  Endian byteOrder,
) {
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
