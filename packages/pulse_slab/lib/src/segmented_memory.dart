import 'dart:typed_data';

import 'errors.dart';
import 'layout.dart';
import 'record_handle.dart';

const int _maximumUint32 = 0xffffffff;
const int _maximumTypedDataBytes = 0x7fffffff;
const int _maximumSegmentSlots = _maximumTypedDataBytes ~/ 8;
// Keep versions exactly representable on both native and JavaScript targets.
const int _maximumVersion = 0x1fffffffffffff;

/// Reusable, layout-homogeneous typed-memory segments for Pulse Slab records.
///
/// A segment never changes its [RecordLayout]. Growth adds a new segment rather
/// than moving live records, preserving every existing [RecordHandle]. This is
/// an internal building block for [PulseStore]; it is intentionally useful to
/// transaction and journal layers without exposing raw memory addresses.
final class SegmentedMemory {
  /// Creates segmented storage with [segmentCapacity] slots per segment.
  ///
  /// [readAccessGuard] is an internal coordination hook used by [PulseStore]
  /// to prevent retained readers from observing bytes during an active write
  /// transaction. Standalone memory users can omit it.
  SegmentedMemory({
    this.segmentCapacity = 1024,
    void Function()? readAccessGuard,
  }) : _readAccessGuard = readAccessGuard {
    if (segmentCapacity <= 0) {
      throw RangeError.value(
        segmentCapacity,
        'segmentCapacity',
        'Segment capacity must be greater than zero.',
      );
    }
    if (segmentCapacity > _maximumSegmentSlots) {
      throw RangeError.value(
        segmentCapacity,
        'segmentCapacity',
        'Exceeds the portable typed-data metadata capacity.',
      );
    }
  }

  /// The number of record slots allocated in each new segment.
  final int segmentCapacity;

  final void Function()? _readAccessGuard;
  final RecordHandleIssuer _handleIssuer = RecordHandleIssuer();

  final List<_MemorySegment> _segments = <_MemorySegment>[];
  final Map<RecordLayout, _LayoutSegments> _pools =
      <RecordLayout, _LayoutSegments>{};
  var _isDisposed = false;
  var _liveRecords = 0;
  var _totalCapacity = 0;

  /// Number of allocated segments across all layouts.
  int get segmentCount => _segments.length;

  /// Total record capacity across all segments.
  int get totalCapacity => _totalCapacity;

  /// Number of currently allocated records.
  int get liveRecordCount => _liveRecords;

  /// Whether this memory owner has been disposed.
  bool get isDisposed => _isDisposed;

  /// Allocates a zero-initialized record with [layout].
  ///
  /// Segments are layout-homogeneous. A released slot is reused before a new
  /// segment is allocated, and a reused slot receives an incremented generation.
  RecordHandle allocate(RecordLayout layout) {
    _checkNotDisposed();
    final _LayoutSegments pool = _pools.putIfAbsent(
      layout,
      () => _LayoutSegments(),
    );
    final _MemorySegment segment = pool.acquire(
      () => _createSegment(layout, pool),
    );
    final int slot = segment.allocateSlot();
    _liveRecords += 1;
    return _handleIssuer.issue(
      segment: segment.index,
      slot: slot,
      generation: segment.generations[slot],
      layout: layout,
    );
  }

  /// Returns a checked immutable record accessor for [handle].
  RecordReader read(RecordHandle handle) {
    _resolve(handle);
    return RecordReader._(this, handle);
  }

  /// Returns a checked mutable record accessor for a controlled write scope.
  ///
  /// The caller is responsible for committing [RecordWriter.changedMask] and
  /// advancing the record version. Public application code receives writers
  /// through [WriteTransaction], not directly from a store.
  RecordWriter writer(RecordHandle handle) {
    _resolve(handle);
    return RecordWriter._(this, handle);
  }

  /// Validates that [handle] still refers to its original live slot.
  void validateHandle(RecordHandle handle) {
    _resolve(handle);
  }

  /// Returns whether [handle] still refers to a live record.
  bool isLive(RecordHandle handle) {
    if (_isDisposed) {
      return false;
    }
    if (!_handleIssuer.owns(handle)) {
      return false;
    }
    if (handle.segment < 0 || handle.segment >= _segments.length) {
      return false;
    }
    final _MemorySegment segment = _segments[handle.segment];
    return identical(segment.layout, handle.layout) &&
        handle.slot >= 0 &&
        handle.slot < segment.capacity &&
        segment.active[handle.slot] != 0 &&
        segment.generations[handle.slot] == handle.generation;
  }

  /// Releases [handle]'s slot and invalidates all copies of that handle.
  void release(RecordHandle handle) {
    final _MemorySegment segment = _resolve(handle);
    segment.releaseSlot(handle.slot);
    _liveRecords -= 1;
    segment.pool.markAvailable(segment);
  }

  /// Returns the committed version of [handle].
  int versionOf(RecordHandle handle) {
    final _MemorySegment segment = _resolve(handle);
    return segment.versions[handle.slot].toInt();
  }

  /// Advances and returns [handle]'s committed version.
  ///
  /// Versions start at zero and advance once per committed transaction that
  /// changed this record. The counter never wraps: an exhausted record fails
  /// explicitly rather than letting a stale version appear current.
  int incrementVersion(RecordHandle handle) {
    final _MemorySegment segment = _resolve(handle);
    final int current = segment.versions[handle.slot].toInt();
    if (current == _maximumVersion) {
      throw const VersionOverflowException(
        'A record version reached the portable exact-integer limit.',
      );
    }
    final int next = current + 1;
    segment.versions[handle.slot] = next.toDouble();
    return next;
  }

  /// Copies one record's raw bytes for transactional rollback.
  ///
  /// This is intentionally not a general public raw-memory API. The returned
  /// bytes are independently owned and restoring them never changes a version.
  Uint8List copyRecordBytes(RecordHandle handle) {
    final _MemorySegment segment = _resolve(handle);
    final int start = segment.recordOffset(handle.slot);
    final Uint8List copy = Uint8List(handle.layout.sizeInBytes);
    copy.setRange(0, copy.length, segment.bytes, start);
    return copy;
  }

  /// Copies one record's raw bytes into a caller-owned [destination] buffer.
  ///
  /// This avoids allocating a separate [Uint8List] when a transaction can
  /// reuse an internal scratch arena. [destinationOffset] must leave enough
  /// contiguous bytes for the complete record image.
  void copyRecordBytesInto(
    RecordHandle handle,
    Uint8List destination,
    int destinationOffset,
  ) {
    final _MemorySegment segment = _resolve(handle);
    final int byteLength = handle.layout.sizeInBytes;
    _validateSnapshotRange(destination, destinationOffset, byteLength);
    final int sourceOffset = segment.recordOffset(handle.slot);
    destination.setRange(
      destinationOffset,
      destinationOffset + byteLength,
      segment.bytes,
      sourceOffset,
    );
  }

  /// Restores a transaction snapshot previously returned by [copyRecordBytes].
  ///
  /// Version ownership remains with the caller so rollback can preserve the
  /// version that was visible before a transaction began.
  void restoreRecordBytes(RecordHandle handle, Uint8List bytes) {
    final _MemorySegment segment = _resolve(handle);
    if (bytes.length != handle.layout.sizeInBytes) {
      throw ArgumentError.value(
        bytes.length,
        'bytes',
        'Snapshot length must equal ${handle.layout.sizeInBytes} bytes.',
      );
    }
    segment.bytes.setRange(
      segment.recordOffset(handle.slot),
      segment.recordOffset(handle.slot) + bytes.length,
      bytes,
    );
  }

  /// Restores a complete record image from a range of [source] bytes.
  ///
  /// This is the allocation-free counterpart to [restoreRecordBytes] used by
  /// transaction rollback. Version ownership remains with the caller.
  void restoreRecordBytesFromBuffer(
    RecordHandle handle,
    Uint8List source,
    int sourceOffset,
  ) {
    final _MemorySegment segment = _resolve(handle);
    final int byteLength = handle.layout.sizeInBytes;
    _validateSnapshotRange(source, sourceOffset, byteLength);
    final int destinationOffset = segment.recordOffset(handle.slot);
    segment.bytes.setRange(
      destinationOffset,
      destinationOffset + byteLength,
      source,
      sourceOffset,
    );
  }

  /// Returns the subset of [candidateMask] whose field bytes differ from
  /// [snapshot].
  ///
  /// Transactions use this to derive an exact net dirty mask without making a
  /// second full-record copy after writing. [snapshot] must be a record image
  /// returned by [copyRecordBytes] for the same layout.
  FieldMask changedFieldMask(
    RecordHandle handle,
    Uint8List snapshot,
    FieldMask candidateMask,
  ) {
    if (snapshot.length != handle.layout.sizeInBytes) {
      throw ArgumentError.value(
        snapshot.length,
        'snapshot',
        'Snapshot length must equal ${handle.layout.sizeInBytes} bytes.',
      );
    }
    return changedFieldMaskFromBuffer(handle, snapshot, 0, candidateMask);
  }

  /// Returns changed fields against a record image stored in [snapshotBuffer].
  ///
  /// [snapshotOffset] identifies the start of the complete pre-transaction
  /// record image. This lets the transaction layer compare against a reusable
  /// scratch arena instead of allocating one snapshot object per record.
  FieldMask changedFieldMaskFromBuffer(
    RecordHandle handle,
    Uint8List snapshotBuffer,
    int snapshotOffset,
    FieldMask candidateMask,
  ) {
    if (!handle.layout.supportsFieldMasks) {
      throw StateError(
        'Layout "${handle.layout.name}" requires FieldSelection for dirty '
        'tracking.',
      );
    }
    final _MemorySegment segment = _resolve(handle);
    _validateSnapshotRange(
      snapshotBuffer,
      snapshotOffset,
      handle.layout.sizeInBytes,
    );
    if (candidateMask == 0) {
      return 0;
    }

    final int recordOffset = segment.recordOffset(handle.slot);
    var result = 0;
    for (final Field<Object?> field in handle.layout.fields) {
      if ((candidateMask & field.mask) == 0) {
        continue;
      }
      final int fieldOffset = field.offset;
      final int fieldEnd = fieldOffset + field.byteLength;
      for (var index = fieldOffset; index < fieldEnd; index++) {
        if (snapshotBuffer[snapshotOffset + index] !=
            segment.bytes[recordOffset + index]) {
          result |= field.mask;
          break;
        }
      }
    }
    return result;
  }

  /// Returns changed fields selected by [candidateSelection] against a record
  /// image stored in [snapshotBuffer].
  ///
  /// This is the wide-layout counterpart to [changedFieldMaskFromBuffer].
  FieldSelection changedFieldSelectionFromBuffer(
    RecordHandle handle,
    Uint8List snapshotBuffer,
    int snapshotOffset,
    FieldSelection candidateSelection,
  ) {
    if (!identical(candidateSelection.layout, handle.layout)) {
      throw ArgumentError.value(
        candidateSelection,
        'candidateSelection',
        'Must belong to layout "${handle.layout.name}".',
      );
    }
    final _MemorySegment segment = _resolve(handle);
    _validateSnapshotRange(
      snapshotBuffer,
      snapshotOffset,
      handle.layout.sizeInBytes,
    );
    if (candidateSelection.isEmpty) {
      return handle.layout.selectionFor(const <Field<Object?>>[]);
    }

    final int recordOffset = segment.recordOffset(handle.slot);
    final List<Field<Object?>> changed = <Field<Object?>>[];
    for (final Field<Object?> field in handle.layout.fields) {
      if (!candidateSelection.contains(field)) {
        continue;
      }
      final int fieldOffset = field.offset;
      final int fieldEnd = fieldOffset + field.byteLength;
      for (var index = fieldOffset; index < fieldEnd; index++) {
        if (snapshotBuffer[snapshotOffset + index] !=
            segment.bytes[recordOffset + index]) {
          changed.add(field);
          break;
        }
      }
    }
    return handle.layout.selectionFor(changed);
  }

  void _validateSnapshotRange(
    Uint8List bytes,
    int offset,
    int byteLength,
  ) {
    if (offset < 0 ||
        offset > bytes.length ||
        byteLength > bytes.length - offset) {
      throw RangeError.value(
        offset,
        'offset',
        'The buffer does not contain $byteLength bytes at the requested offset.',
      );
    }
  }

  /// Releases segment metadata owned by this memory instance.
  ///
  /// Existing readers and writers become invalid immediately. This operation
  /// does not claim to synchronously reclaim bytes retained by external Dart
  /// references; normal garbage collection determines that lifetime.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _segments.clear();
    _pools.clear();
    _liveRecords = 0;
    _totalCapacity = 0;
  }

  _MemorySegment _resolve(RecordHandle handle) {
    _checkNotDisposed();
    if (!_handleIssuer.owns(handle)) {
      throw const StaleRecordHandleException(
        'Record handle belongs to a different segmented-memory owner.',
      );
    }
    if (handle.segment < 0 || handle.segment >= _segments.length) {
      throw RecordBoundsException(
        'Segment ${handle.segment} is outside this store.',
      );
    }
    final _MemorySegment segment = _segments[handle.segment];
    if (!identical(segment.layout, handle.layout)) {
      throw StaleRecordHandleException(
        'Handle layout "${handle.layout.name}" does not match segment '
        '${handle.segment}.',
      );
    }
    if (handle.slot < 0 || handle.slot >= segment.capacity) {
      throw RecordBoundsException(
        'Slot ${handle.slot} is outside segment ${handle.segment}.',
      );
    }
    if (segment.generations[handle.slot] != handle.generation ||
        segment.active[handle.slot] == 0) {
      throw StaleRecordHandleException(
        'Handle for segment ${handle.segment}, slot ${handle.slot} is stale.',
      );
    }
    return segment;
  }

  _MemorySegment _createSegment(
    RecordLayout layout,
    _LayoutSegments pool,
  ) {
    if (layout.sizeInBytes > _maximumTypedDataBytes ~/ segmentCapacity) {
      throw LayoutException(
        'Layout "${layout.name}" and segment capacity $segmentCapacity '
        'exceed the portable typed-data byte limit.',
      );
    }
    final _MemorySegment segment = _MemorySegment(
      index: _segments.length,
      layout: layout,
      capacity: segmentCapacity,
      pool: pool,
    );
    _segments.add(segment);
    _totalCapacity += segmentCapacity;
    return segment;
  }

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw const StoreDisposedException(
        'The segmented memory owner is disposed.',
      );
    }
  }

  void _ensureReadAccess() {
    _readAccessGuard?.call();
  }
}

/// A checked, immutable view of the latest committed record memory.
///
/// A reader revalidates its handle on every access. It never exposes a mutable
/// numeric buffer, so ordinary reads cannot bypass dirty tracking.
class RecordReader {
  RecordReader._(this._memory, this.handle);

  final SegmentedMemory _memory;

  /// The stable handle for this record.
  final RecordHandle handle;

  /// The immutable record format.
  RecordLayout get layout => handle.layout;

  /// The current committed record version.
  int get version {
    _memory._ensureReadAccess();
    return _memory.versionOf(handle);
  }

  /// Reads [field] from the current committed record state.
  T get<T>(Field<T> field) {
    _memory._ensureReadAccess();
    final _MemorySegment segment = _memory._resolve(handle);
    field.requireOwner(layout);
    return field.read(
      segment.data,
      segment.recordOffset(handle.slot) + field.offset,
      layout.byteOrder,
    );
  }

  /// Returns a safe, zero-copy read-only view of a fixed byte [field].
  ///
  /// The view checks the handle before every public access. Calling [get] for a
  /// [BytesField] instead returns a defensive [Uint8List] copy.
  ByteView bytesView(BytesField field) {
    _memory._ensureReadAccess();
    final _MemorySegment segment = _memory._resolve(handle);
    field.requireOwner(layout);
    return field.view(
      segment.data,
      segment.recordOffset(handle.slot) + field.offset,
      validate: () {
        _memory._ensureReadAccess();
        _memory.validateHandle(handle);
      },
    );
  }
}

/// A controlled mutable record view used during a write transaction.
///
/// Each [set] updates compact dirty masks or wide field selections only if the
/// stored bytes changed. Versioning and notification are deliberately left to
/// the transaction commit layer so several writes merge into one change record.
class RecordWriter extends RecordReader {
  // ignore: use_super_parameters
  RecordWriter._(SegmentedMemory memory, RecordHandle handle)
      : super._(memory, handle);

  FieldMask _changedMask = 0;
  FieldSelectionBuilder? _wideChangedFields;
  late final bool _usesCompactFieldMasks = layout.supportsFieldMasks;

  @override
  int get version => _memory.versionOf(handle);

  @override
  T get<T>(Field<T> field) {
    final _MemorySegment segment = _memory._resolve(handle);
    field.requireOwner(layout);
    return field.read(
      segment.data,
      segment.recordOffset(handle.slot) + field.offset,
      layout.byteOrder,
    );
  }

  /// The union of compact field bits changed through this writer.
  ///
  /// This is available only for layouts with at most [maxFieldsPerLayout]
  /// fields. Use [changedFieldSelection] for a layout of any width.
  FieldMask get changedMask {
    if (!_usesCompactFieldMasks) {
      throw StateError(
        'Layout "${layout.name}" requires changedFieldSelection instead of '
        'changedMask.',
      );
    }
    return _changedMask;
  }

  /// The fields changed through this writer, including wide layouts.
  FieldSelection get changedFieldSelection {
    if (_usesCompactFieldMasks) {
      return layout.selectionFor(
        _changedMask == 0
            ? const <Field<Object?>>[]
            : layout.fields.where(
                (Field<Object?> field) => (_changedMask & field.mask) != 0,
              ),
      );
    }
    return _wideChangedFields?.build() ??
        layout.selectionFor(const <Field<Object?>>[]);
  }

  /// Whether at least one field changed through this writer.
  bool get hasChanges => _usesCompactFieldMasks
      ? _changedMask != 0
      : !(_wideChangedFields?.isEmpty ?? true);

  /// Returns whether [value] would change [field] without writing it.
  ///
  /// Transaction code uses this preflight to avoid allocating a rollback image
  /// for a no-op field write.
  bool wouldChange<T>(Field<T> field, T value) {
    final _MemorySegment segment = _memory._resolve(handle);
    field.requireOwner(layout);
    return field.wouldChange(
      segment.data,
      segment.recordOffset(handle.slot) + field.offset,
      value,
      layout.byteOrder,
    );
  }

  /// Writes [value] to [field] and returns whether its stored bytes changed.
  bool set<T>(Field<T> field, T value) {
    final _MemorySegment segment = _memory._resolve(handle);
    field.requireOwner(layout);
    final bool changed = field.writeIfChanged(
      segment.data,
      segment.recordOffset(handle.slot) + field.offset,
      value,
      layout.byteOrder,
    );
    if (changed) {
      _markChanged(field);
    }
    return changed;
  }

  /// Writes [value] after [wouldChange] has already returned `true`.
  ///
  /// This avoids repeating an equality check in the transaction hot path. It
  /// is an internal coordination primitive; callers must not use it without a
  /// preceding successful [wouldChange] check for the same field and value.
  void setKnownChanged<T>(Field<T> field, T value) {
    final _MemorySegment segment = _memory._resolve(handle);
    field.requireOwner(layout);
    field.write(
      segment.data,
      segment.recordOffset(handle.slot) + field.offset,
      value,
      layout.byteOrder,
    );
    _markChanged(field);
  }

  /// Clears the locally accumulated dirty bits without changing record memory.
  void clearChangedMask() {
    _changedMask = 0;
    _wideChangedFields?.clear();
  }

  /// Returns and clears the locally accumulated dirty mask.
  FieldMask takeChangedMask() {
    final FieldMask result = changedMask;
    clearChangedMask();
    return result;
  }

  /// Returns and clears the changed field selection for a layout of any width.
  FieldSelection takeChangedFieldSelection() {
    final FieldSelection result = changedFieldSelection;
    clearChangedMask();
    return result;
  }

  void _markChanged(Field<Object?> field) {
    if (_usesCompactFieldMasks) {
      _changedMask |= field.mask;
      return;
    }
    (_wideChangedFields ??= FieldSelectionBuilder(layout)).add(field);
  }
}

final class _LayoutSegments {
  final List<_MemorySegment> _segments = <_MemorySegment>[];
  _MemorySegment? _available;
  _MemorySegment? _reusable;

  _MemorySegment acquire(_MemorySegment Function() create) {
    final _MemorySegment? reusable = _reusable;
    if (reusable != null && reusable.hasReleasedSlot) {
      return reusable;
    }
    for (final _MemorySegment segment in _segments) {
      if (segment.hasReleasedSlot) {
        _reusable = segment;
        return segment;
      }
    }
    final _MemorySegment? preferred = _available;
    if (preferred != null && preferred.hasSpace) {
      return preferred;
    }
    for (final _MemorySegment segment in _segments) {
      if (segment.hasSpace) {
        _available = segment;
        return segment;
      }
    }
    final _MemorySegment segment = create();
    _segments.add(segment);
    _available = segment;
    return segment;
  }

  void markAvailable(_MemorySegment segment) {
    if (segment.hasReleasedSlot) {
      _reusable = segment;
    }
    if (_available == null || !_available!.hasSpace) {
      _available = segment;
    }
  }
}

final class _MemorySegment {
  _MemorySegment({
    required this.index,
    required this.layout,
    required this.capacity,
    required this.pool,
  })  : bytes = Uint8List(layout.sizeInBytes * capacity),
        generations = Uint32List(capacity),
        versions = Float64List(capacity),
        active = Uint8List(capacity),
        _freeSlots = Int32List(capacity);

  final int index;
  final RecordLayout layout;
  final int capacity;
  final _LayoutSegments pool;
  final Uint8List bytes;
  final Uint32List generations;

  /// Exact record versions through the portable 2^53 - 1 cap.
  final Float64List versions;
  final Uint8List active;
  final Int32List _freeSlots;
  late final ByteData data = ByteData.sublistView(bytes);
  var _nextUnusedSlot = 0;
  var _freeSlotCount = 0;

  bool get hasSpace => _freeSlotCount > 0 || _nextUnusedSlot < capacity;

  bool get hasReleasedSlot => _freeSlotCount > 0;

  int allocateSlot() {
    final int slot;
    if (_freeSlotCount > 0) {
      _freeSlotCount -= 1;
      slot = _freeSlots[_freeSlotCount];
    } else {
      if (_nextUnusedSlot >= capacity) {
        throw StateError('Attempted to allocate from a full memory segment.');
      }
      slot = _nextUnusedSlot;
      _nextUnusedSlot += 1;
      generations[slot] = 1;
    }

    final int start = recordOffset(slot);
    bytes.fillRange(start, start + layout.sizeInBytes, 0);
    versions[slot] = 0.0;
    active[slot] = 1;
    return slot;
  }

  void releaseSlot(int slot) {
    active[slot] = 0;
    versions[slot] = 0.0;
    final int start = recordOffset(slot);
    bytes.fillRange(start, start + layout.sizeInBytes, 0);

    final int generation = generations[slot];
    if (generation == _maximumUint32) {
      return;
    }
    generations[slot] = generation + 1;
    _freeSlots[_freeSlotCount] = slot;
    _freeSlotCount += 1;
  }

  int recordOffset(int slot) => slot * layout.sizeInBytes;
}
