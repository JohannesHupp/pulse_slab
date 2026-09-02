import 'dart:convert';
import 'dart:typed_data';

import '../layout.dart';

const int _captureFormatVersion = 1;
const int _captureMagic = 0x50534350;
const int _maximumUint32 = 0xffffffff;
const int _maximumPortableVersion = 0x1fffffffffffff;
const int _uint32Base = 0x100000000;

/// Accepts immutable captures of committed [PulseStore] state.
///
/// `PulseStore` calls [append] synchronously at a completed-transaction or
/// record-lifecycle boundary. Implementations must either accept the complete
/// batch in order or throw; they must never overwrite or silently discard a
/// batch. A successful return means that the backend accepted the immutable
/// capture into its own bounded pipeline, not that an external durability
/// barrier has necessarily completed.
///
/// A backend instance belongs to one [PulseStore] for its lifetime. Open or
/// create a separate backend for another logical store stream so record
/// coordinates cannot collide during replay.
///
/// The core package intentionally has no dependency on a file system, database,
/// or broker. Platform-specific backends can implement this interface in an
/// optional package.
abstract interface class PulseStorePersistence {
  /// Accepts one complete, ordered capture batch.
  void append(StoreCaptureBatch batch);
}

/// Signals that a persistence backend cannot accept another capture batch.
///
/// A [PulseStore] rolls back a transaction when its synchronous capture
/// admission throws this exception. Record lifecycle operations similarly leave
/// the record unchanged when their capture cannot be admitted. A successful
/// admission is still not an atomic file-write guarantee.
final class StorePersistenceBackpressureException implements Exception {
  /// Creates an explicit bounded-capacity rejection.
  StorePersistenceBackpressureException({
    required this.pendingBytes,
    required this.maxPendingBytes,
    required this.batchBytes,
  }) {
    if (pendingBytes < 0 || maxPendingBytes <= 0 || batchBytes <= 0) {
      throw ArgumentError('Persistence byte counts must be positive.');
    }
  }

  /// Bytes currently occupying the capacity that rejected the append.
  ///
  /// The exact unit is backend-defined. For example, a backend can report
  /// unacknowledged encoded payload bytes for a logical replay limit or
  /// retained on-disk bytes for a physical journal limit.
  final int pendingBytes;

  /// Configured capacity corresponding to [pendingBytes], in bytes.
  final int maxPendingBytes;

  /// Bytes required by the rejected capture for that capacity.
  ///
  /// A physical journal backend can include frame and segment headers here.
  final int batchBytes;

  @override
  String toString() =>
      'StorePersistenceBackpressureException(pendingBytes: $pendingBytes, '
      'maxPendingBytes: $maxPendingBytes, batchBytes: $batchBytes)';
}

/// Resolves stable persistence metadata for a [RecordLayout].
///
/// A resolver is evaluated when a record is allocated while persistence is
/// enabled. Its result is carried by snapshots so a replay consumer can select
/// a compatible layout without relying on process-local object identity.
typedef StorePersistenceLayoutResolver = StorePersistenceLayout Function(
  RecordLayout layout,
);

/// Stable identity and schema version carried by persisted record snapshots.
final class StorePersistenceLayout {
  /// Creates persisted layout metadata.
  StorePersistenceLayout({required this.identity, this.version = 1}) {
    _validateStorePersistenceLayout(identity, version);
  }

  /// Stable application-defined layout identity.
  final String identity;

  /// Positive application-defined schema version for [identity].
  final int version;

  // Layout metadata is stable for the lifetime of a configured persistent
  // record. Encoding it once avoids repeated string-to-byte work on each
  // captured update while keeping the public layout value immutable.
  late final Uint8List _encodedIdentity =
      Uint8List.fromList(utf8.encode(identity));

  @override
  bool operator ==(Object other) =>
      other is StorePersistenceLayout &&
      identity == other.identity &&
      version == other.version;

  @override
  int get hashCode => Object.hash(identity, version);

  @override
  String toString() =>
      'StorePersistenceLayout(identity: $identity, version: $version)';
}

/// Default layout metadata for persistence-enabled [PulseStore] instances.
///
/// The default uses [RecordLayout.name] and schema version one. Applications
/// should use it only for immutable schemas. Applications that evolve a
/// persisted layout must provide [StorePersistenceLayoutResolver] and advance
/// [StorePersistenceLayout.version] deliberately.
StorePersistenceLayout defaultStorePersistenceLayout(RecordLayout layout) =>
    StorePersistenceLayout(identity: layout.name);

/// Identifies one record across a capture stream.
///
/// This is a serializable record coordinate, not a live [RecordHandle]. It can
/// be used after the originating store has been disposed.
final class StoreCaptureRecordId {
  /// Creates a serializable record coordinate.
  StoreCaptureRecordId({
    required this.segment,
    required this.slot,
    required this.generation,
  }) {
    _validateUint32(segment, 'segment');
    _validateUint32(slot, 'slot');
    _validateUint32(generation, 'generation');
  }

  /// Segment coordinate from the originating store.
  final int segment;

  /// Slot coordinate from the originating store.
  final int slot;

  /// Allocation generation from the originating store.
  final int generation;

  @override
  bool operator ==(Object other) =>
      other is StoreCaptureRecordId &&
      segment == other.segment &&
      slot == other.slot &&
      generation == other.generation;

  @override
  int get hashCode => Object.hash(segment, slot, generation);

  @override
  String toString() => 'StoreCaptureRecordId(segment: $segment, slot: $slot, '
      'generation: $generation)';
}

/// The kind of a [StoreCaptureBatch].
enum StoreCaptureBatchKind {
  /// A complete snapshot of all records live at one capture boundary.
  checkpoint,

  /// Ordered changes after a checkpoint.
  incremental,
}

/// A record operation carried by a [StoreCaptureBatch].
sealed class StoreCaptureOperation {
  const StoreCaptureOperation._(this.record);

  /// Record affected by this operation.
  final StoreCaptureRecordId record;
}

/// A complete committed record image.
///
/// A snapshot represents both a newly allocated record and a later record
/// update. [copyBytes] returns an independently owned copy so a replay consumer
/// cannot mutate the capture retained by a backend.
final class StoreCaptureSnapshot extends StoreCaptureOperation {
  /// Creates a snapshot by copying [bytes].
  StoreCaptureSnapshot({
    required StoreCaptureRecordId record,
    required this.layout,
    required this.version,
    required Uint8List bytes,
  })  : _bytes = Uint8List.fromList(bytes),
        super._(record) {
    _validateVersion(version, 'version');
  }

  /// Creates a snapshot by taking ownership of an independently owned [bytes]
  /// buffer.
  ///
  /// Callers must not mutate [bytes] after this constructor returns. It avoids
  /// a second copy when a store has already copied committed record memory into
  /// an immutable transfer buffer.
  StoreCaptureSnapshot.takeBytes({
    required StoreCaptureRecordId record,
    required this.layout,
    required this.version,
    required Uint8List bytes,
  })  : _bytes = bytes,
        super._(record) {
    _validateVersion(version, 'version');
  }

  StoreCaptureSnapshot._owned({
    required StoreCaptureRecordId record,
    required this.layout,
    required this.version,
    required Uint8List bytes,
  })  : _bytes = bytes,
        super._(record) {
    _validateVersion(version, 'version');
  }

  /// Persisted layout identity and schema version.
  final StorePersistenceLayout layout;

  /// Committed record version represented by this image.
  final int version;

  final Uint8List _bytes;

  /// Number of raw record bytes in this snapshot.
  int get byteLength => _bytes.length;

  /// Returns an independently owned copy of the raw record image.
  Uint8List copyBytes() => Uint8List.fromList(_bytes);
}

/// Removes a record from replay state.
final class StoreCaptureRelease extends StoreCaptureOperation {
  /// Creates a release operation for [record].
  const StoreCaptureRelease({required StoreCaptureRecordId record})
      : super._(record);
}

/// A versioned checkpoint or ordered incremental capture.
///
/// A checkpoint contains snapshots only. An incremental batch contains one or
/// more snapshots or release operations in their completed store-operation
/// order.
final class StoreCaptureBatch {
  StoreCaptureBatch._(this.kind, Iterable<StoreCaptureOperation> operations)
      : _operations = List<StoreCaptureOperation>.unmodifiable(operations) {
    if (kind == StoreCaptureBatchKind.incremental && _operations.isEmpty) {
      throw ArgumentError.value(
        operations,
        'operations',
        'An incremental batch must contain at least one operation.',
      );
    }
    if (kind == StoreCaptureBatchKind.checkpoint &&
        _operations.any(
          (StoreCaptureOperation operation) =>
              operation is! StoreCaptureSnapshot,
        )) {
      throw ArgumentError.value(
        operations,
        'operations',
        'A checkpoint can contain only record snapshots.',
      );
    }
  }

  /// Creates a complete snapshot of the records live at one boundary.
  factory StoreCaptureBatch.checkpoint(
    Iterable<StoreCaptureSnapshot> snapshots,
  ) =>
      StoreCaptureBatch._(
        StoreCaptureBatchKind.checkpoint,
        List<StoreCaptureOperation>.of(snapshots),
      );

  /// Creates ordered changes after the most recent checkpoint.
  factory StoreCaptureBatch.incremental(
    Iterable<StoreCaptureOperation> operations,
  ) =>
      StoreCaptureBatch._(StoreCaptureBatchKind.incremental, operations);

  /// Capture format version used by [StoreCaptureCodec].
  static const int formatVersion = _captureFormatVersion;

  /// Whether this batch replaces replay state or extends it.
  final StoreCaptureBatchKind kind;

  final List<StoreCaptureOperation> _operations;

  /// Immutable operation order in this batch.
  List<StoreCaptureOperation> get operations => _operations;

  /// Encodes this batch into the versioned binary capture format.
  Uint8List encode() => StoreCaptureCodec.encode(this);
}

/// Encodes and decodes versioned [StoreCaptureBatch] values.
///
/// The format contains full committed record bytes, stable layout metadata, and
/// record release operations. It is platform-neutral and intentionally has no
/// file-system dependency.
final class StoreCaptureCodec {
  /// Encodes [batch] into an independently owned binary buffer.
  static Uint8List encode(StoreCaptureBatch batch) {
    var length = 10;
    for (var index = 0; index < batch.operations.length; index++) {
      final StoreCaptureOperation operation = batch.operations[index];
      length += 13;
      if (operation case StoreCaptureSnapshot snapshot) {
        final Uint8List identity = snapshot.layout._encodedIdentity;
        length += 4 + identity.length + 4 + 8 + 4 + snapshot._bytes.length;
      }
      if (length > _maximumUint32) {
        throw RangeError.value(
          length,
          'batch',
          'The encoded capture exceeds the portable binary format limit.',
        );
      }
    }

    final ByteData data = ByteData(length);
    var offset = 0;
    offset = _writeUint32(data, offset, _captureMagic);
    data.setUint8(offset++, _captureFormatVersion);
    data.setUint8(
      offset++,
      batch.kind == StoreCaptureBatchKind.checkpoint ? 0 : 1,
    );
    offset = _writeUint32(data, offset, batch.operations.length);

    for (var index = 0; index < batch.operations.length; index++) {
      final StoreCaptureOperation operation = batch.operations[index];
      if (operation case StoreCaptureSnapshot snapshot) {
        data.setUint8(offset++, 1);
        offset = _writeRecordId(data, offset, snapshot.record);
        final Uint8List identity = snapshot.layout._encodedIdentity;
        offset = _writeBytes(data, offset, identity);
        offset = _writeUint32(data, offset, snapshot.layout.version);
        offset = _writeVersion(data, offset, snapshot.version);
        offset = _writeBytes(data, offset, snapshot._bytes);
      } else if (operation case StoreCaptureRelease release) {
        data.setUint8(offset++, 2);
        offset = _writeRecordId(data, offset, release.record);
      }
    }

    assert(offset == length);
    return data.buffer.asUint8List();
  }

  /// Decodes a binary batch produced by [encode].
  static StoreCaptureBatch decode(Uint8List bytes) {
    final _CaptureReader reader = _CaptureReader(bytes);
    if (reader.readUint32() != _captureMagic) {
      throw const FormatException('Invalid PulseStore capture magic.');
    }
    final int version = reader.readUint8();
    if (version != _captureFormatVersion) {
      throw FormatException('Unsupported PulseStore capture version $version.');
    }
    final int kindByte = reader.readUint8();
    final StoreCaptureBatchKind kind;
    switch (kindByte) {
      case 0:
        kind = StoreCaptureBatchKind.checkpoint;
      case 1:
        kind = StoreCaptureBatchKind.incremental;
      default:
        throw FormatException(
          'Unknown PulseStore capture batch kind $kindByte.',
        );
    }
    final int count = reader.readUint32();
    if (kind == StoreCaptureBatchKind.incremental && count == 0) {
      throw const FormatException(
        'A PulseStore incremental capture must contain an operation.',
      );
    }
    if (count > reader.remainingBytes ~/ 13) {
      throw const FormatException('Truncated PulseStore capture operations.');
    }
    final List<StoreCaptureOperation> operations = <StoreCaptureOperation>[];
    for (var index = 0; index < count; index++) {
      final int tag = reader.readUint8();
      if (kind == StoreCaptureBatchKind.checkpoint && tag != 1) {
        throw const FormatException(
          'A PulseStore checkpoint contains a non-snapshot operation.',
        );
      }
      final StoreCaptureRecordId record = reader.readRecordId();
      switch (tag) {
        case 1:
          final String identity = reader.readString();
          final int layoutVersion = reader.readUint32();
          final int recordVersion = reader.readVersion();
          final Uint8List snapshotBytes = reader.readBytes();
          operations.add(
            StoreCaptureSnapshot._owned(
              record: record,
              layout: StorePersistenceLayout(
                identity: identity,
                version: layoutVersion,
              ),
              version: recordVersion,
              bytes: snapshotBytes,
            ),
          );
        case 2:
          operations.add(StoreCaptureRelease(record: record));
        default:
          throw FormatException('Unknown PulseStore capture operation $tag.');
      }
    }
    reader.expectEnd();
    return kind == StoreCaptureBatchKind.checkpoint
        ? StoreCaptureBatch.checkpoint(
            operations.whereType<StoreCaptureSnapshot>(),
          )
        : StoreCaptureBatch.incremental(operations);
  }
}

/// Applies checkpoints and incremental batches to recover logical record state.
///
/// The replayer intentionally reconstructs portable captured state rather than
/// issuing live [RecordHandle] values. An application can resolve each
/// [StoreCaptureSnapshot.layout] to its current schema before materializing a
/// new store projection.
final class StoreCaptureReplayer {
  final Map<StoreCaptureRecordId, StoreCaptureSnapshot> _records =
      <StoreCaptureRecordId, StoreCaptureSnapshot>{};

  /// Current recovered records in deterministic insertion order.
  List<StoreCaptureSnapshot> get records =>
      List<StoreCaptureSnapshot>.unmodifiable(_records.values);

  /// Applies [batch] in capture order.
  void apply(StoreCaptureBatch batch) {
    if (batch.kind == StoreCaptureBatchKind.checkpoint) {
      _records.clear();
    }
    for (final StoreCaptureOperation operation in batch.operations) {
      switch (operation) {
        case StoreCaptureSnapshot snapshot:
          _records[snapshot.record] = snapshot;
        case StoreCaptureRelease release:
          _records.remove(release.record);
      }
    }
  }
}

/// One replay batch offered by an ordered persistence backend.
final class StorePersistenceReplayDelivery {
  /// Creates a replay delivery with a backend-assigned positive [sequence].
  StorePersistenceReplayDelivery({
    required this.sequence,
    required this.batch,
  }) {
    if (sequence <= 0 || sequence > _maximumPortableVersion) {
      throw RangeError.value(
        sequence,
        'sequence',
        'Must be a positive portable exact integer.',
      );
    }
  }

  /// Monotonic backend-assigned sequence number.
  final int sequence;

  /// Captured checkpoint or incremental changes.
  final StoreCaptureBatch batch;
}

/// A single-consumer ordered replay contract.
///
/// Backends expose at most one outstanding [StorePersistenceReplayDelivery].
/// Call [acknowledge] only after processing the delivery durably, or [retry] to
/// make the same unacknowledged delivery available again. After a process
/// restart, an unacknowledged delivery is replayed, so consumers must tolerate
/// at-least-once delivery.
abstract interface class StorePersistenceReplayConsumer {
  /// Returns the next unacknowledged delivery, or `null` when none is retained.
  Future<StorePersistenceReplayDelivery?> take();

  /// Persists acknowledgement progress for [delivery].
  Future<void> acknowledge(StorePersistenceReplayDelivery delivery);

  /// Releases [delivery] for another ordered attempt without acknowledging it.
  Future<void> retry(StorePersistenceReplayDelivery delivery);
}

int _writeRecordId(ByteData data, int offset, StoreCaptureRecordId record) {
  offset = _writeUint32(data, offset, record.segment);
  offset = _writeUint32(data, offset, record.slot);
  return _writeUint32(data, offset, record.generation);
}

int _writeVersion(ByteData data, int offset, int value) {
  _validateVersion(value, 'value');
  final int high = value ~/ _uint32Base;
  final int low = value - high * _uint32Base;
  offset = _writeUint32(data, offset, high);
  return _writeUint32(data, offset, low);
}

int _writeUint32(ByteData data, int offset, int value) {
  _validateUint32(value, 'value');
  data.setUint32(offset, value, Endian.big);
  return offset + 4;
}

int _writeBytes(ByteData data, int offset, Uint8List bytes) {
  offset = _writeUint32(data, offset, bytes.length);
  data.buffer.asUint8List().setRange(offset, offset + bytes.length, bytes);
  return offset + bytes.length;
}

void _validateUint32(int value, String name) {
  if (value < 0 || value > _maximumUint32) {
    throw RangeError.value(value, name, 'Must be an unsigned 32-bit integer.');
  }
}

void _validateStorePersistenceLayout(String identity, int version) {
  if (identity.trim().isEmpty) {
    throw ArgumentError.value(
      identity,
      'identity',
      'Must not be empty.',
    );
  }
  if (version <= 0 || version > _maximumUint32) {
    throw RangeError.value(
      version,
      'version',
      'Must be a positive unsigned 32-bit integer.',
    );
  }
}

void _validateVersion(int value, String name) {
  if (value < 0 || value > _maximumPortableVersion) {
    throw RangeError.value(
      value,
      name,
      'Must be a portable exact integer from zero through '
      '$_maximumPortableVersion.',
    );
  }
}

final class _CaptureReader {
  _CaptureReader(this._bytes) : _data = ByteData.sublistView(_bytes);

  final Uint8List _bytes;
  final ByteData _data;
  var _offset = 0;

  int readUint8() {
    _ensure(1);
    return _data.getUint8(_offset++);
  }

  int readUint32() {
    _ensure(4);
    final int value = _data.getUint32(_offset, Endian.big);
    _offset += 4;
    return value;
  }

  StoreCaptureRecordId readRecordId() => StoreCaptureRecordId(
        segment: readUint32(),
        slot: readUint32(),
        generation: readUint32(),
      );

  int readVersion() {
    final int high = readUint32();
    final int low = readUint32();
    final int value = high * _uint32Base + low;
    _validateVersion(value, 'recordVersion');
    return value;
  }

  String readString() => utf8.decode(readBytes());

  Uint8List readBytes() {
    final int length = readUint32();
    _ensure(length);
    final Uint8List result = Uint8List(length);
    result.setRange(0, length, _bytes, _offset);
    _offset += length;
    return result;
  }

  int get remainingBytes => _bytes.length - _offset;

  void expectEnd() {
    if (_offset != _bytes.length) {
      throw const FormatException('Trailing bytes in PulseStore capture.');
    }
  }

  void _ensure(int count) {
    if (count < 0 || count > _bytes.length - _offset) {
      throw const FormatException('Truncated PulseStore capture.');
    }
  }
}
