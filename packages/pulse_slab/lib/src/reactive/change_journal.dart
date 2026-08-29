import 'dart:typed_data';

const int _maximumUint32 = 0xffffffff;
const int _maximumJournalCapacity = 0x7fffffff ~/ 8;
const int _maximumPortableVersion = 0x1fffffffffffff;
const int _maximumPortableFieldMask = 0x7fffffff;

/// A compact description of one committed record-state change.
///
/// A change journal contains replaceable state updates, not lossless domain
/// events. Applications that need acknowledged, lossless events should use a
/// separate protocol with explicit producer backpressure.
final class ChangeRecord {
  /// Creates a committed change description.
  ChangeRecord({
    required this.segment,
    required this.slot,
    required this.generation,
    required this.version,
    required this.fieldMask,
  }) {
    _validateUint32(segment, 'segment');
    _validateUint32(slot, 'slot');
    _validateUint32(generation, 'generation');
    if (version < 0 || version > _maximumPortableVersion) {
      throw RangeError.value(
        version,
        'version',
        'Must be a portable exact integer from zero through '
            '$_maximumPortableVersion.',
      );
    }
    if (fieldMask < 0 || fieldMask > _maximumPortableFieldMask) {
      throw RangeError.value(
        fieldMask,
        'fieldMask',
        'Must be a non-negative portable field mask through '
            '$_maximumPortableFieldMask.',
      );
    }
  }

  /// Globally unique segment identifier within the owning store.
  final int segment;

  /// Slot index within [segment].
  final int slot;

  /// Generation which makes a released-and-reused slot distinguishable.
  final int generation;

  /// Record version after the commit.
  final int version;

  /// Bit mask of fields changed by the commit.
  final int fieldMask;

  /// Returns a copy combining two changes to the same record.
  ChangeRecord mergedWith(ChangeRecord newer) {
    if (segment != newer.segment ||
        slot != newer.slot ||
        generation != newer.generation) {
      throw ArgumentError('Only changes for the same record can be merged.');
    }
    if (newer.version < version) {
      throw ArgumentError(
        'The newer change must not have a lower record version.',
      );
    }
    return ChangeRecord(
      segment: segment,
      slot: slot,
      generation: generation,
      version: newer.version,
      fieldMask: fieldMask | newer.fieldMask,
    );
  }

  @override
  String toString() {
    return 'ChangeRecord(segment: $segment, slot: $slot, '
        'generation: $generation, version: $version, '
        'fieldMask: 0x${fieldMask.toRadixString(16)})';
  }
}

/// Defines what a full [ChangeJournal] does with a replaceable state update.
enum JournalOverflowPolicy {
  /// Discard the oldest unread state change and retain the newest one.
  overwriteOldest,

  /// Reject the newest state change while keeping all currently buffered ones.
  rejectNewest,
}

/// Fixed-capacity ring buffer for compact record-state changes.
///
/// Internal columns use typed data rather than allocating one object per
/// journal entry. Reading an entry materializes a small [ChangeRecord] value.
/// Capacity is fixed for the journal lifetime, so an overwhelmed consumer
/// cannot make memory usage grow without bound.
final class ChangeJournal {
  /// Creates a ring journal with a positive, fixed [capacity].
  ChangeJournal({
    required this.capacity,
    this.overflowPolicy = JournalOverflowPolicy.overwriteOldest,
  })  : _segments = Uint32List(_validateCapacity(capacity)),
        _slots = Uint32List(capacity),
        _generations = Uint32List(capacity),
        _versions = Float64List(capacity),
        _fieldMasks = Uint32List(capacity);

  static int _validateCapacity(int capacity) {
    if (capacity <= 0) {
      throw ArgumentError.value(
        capacity,
        'capacity',
        'Must be greater than zero.',
      );
    }
    if (capacity > _maximumJournalCapacity) {
      throw RangeError.value(
        capacity,
        'capacity',
        'Exceeds the portable typed-data column capacity.',
      );
    }
    return capacity;
  }

  /// Maximum number of unread changes retained by this journal.
  final int capacity;

  /// Behavior used when [length] reaches [capacity].
  final JournalOverflowPolicy overflowPolicy;

  final Uint32List _segments;
  final Uint32List _slots;
  final Uint32List _generations;

  /// Versions remain exact because [ChangeRecord] caps them below 2^53.
  final Float64List _versions;
  final Uint32List _fieldMasks;

  var _readIndex = 0;
  var _writeIndex = 0;
  var _length = 0;
  var _overwrittenCount = 0;
  var _rejectedCount = 0;

  /// Number of changes ready to be read.
  int get length => _length;

  /// Whether no unread changes are present.
  bool get isEmpty => _length == 0;

  /// Whether the fixed buffer is currently full.
  bool get isFull => _length == capacity;

  /// Number of old state changes overwritten because the journal was full.
  int get overwrittenCount => _overwrittenCount;

  /// Number of new state changes rejected because the journal was full.
  int get rejectedCount => _rejectedCount;

  /// Ratio of retained entries to [capacity].
  double get utilization => _length / capacity;

  /// Appends [change], returning whether it was retained.
  ///
  /// An [JournalOverflowPolicy.overwriteOldest] journal always retains the new
  /// state update. A [JournalOverflowPolicy.rejectNewest] journal returns
  /// `false` when full; callers can surface that backpressure signal.
  bool append(ChangeRecord change) {
    if (_length == capacity) {
      if (overflowPolicy == JournalOverflowPolicy.rejectNewest) {
        _rejectedCount++;
        return false;
      }
      _readIndex = _next(_readIndex);
      _overwrittenCount++;
    } else {
      _length++;
    }

    _segments[_writeIndex] = change.segment;
    _slots[_writeIndex] = change.slot;
    _generations[_writeIndex] = change.generation;
    _versions[_writeIndex] = change.version.toDouble();
    _fieldMasks[_writeIndex] = change.fieldMask;
    _writeIndex = _next(_writeIndex);
    return true;
  }

  /// Removes and returns the oldest retained change, or `null` when empty.
  ChangeRecord? take() {
    if (_length == 0) {
      return null;
    }
    final index = _readIndex;
    final change = ChangeRecord(
      segment: _segments[index],
      slot: _slots[index],
      generation: _generations[index],
      version: _versions[index].toInt(),
      fieldMask: _fieldMasks[index],
    );
    _readIndex = _next(index);
    _length--;
    return change;
  }

  /// Materializes and removes every retained change in oldest-first order.
  List<ChangeRecord> drain() {
    final changes = <ChangeRecord>[];
    while (true) {
      final change = take();
      if (change == null) {
        return changes;
      }
      changes.add(change);
    }
  }

  /// Removes retained changes without resetting overflow counters.
  void clear() {
    _readIndex = 0;
    _writeIndex = 0;
    _length = 0;
  }

  int _next(int index) => index + 1 == capacity ? 0 : index + 1;
}

void _validateUint32(int value, String name) {
  if (value < 0 || value > _maximumUint32) {
    throw RangeError.value(
      value,
      name,
      'Must be an unsigned 32-bit integer.',
    );
  }
}
