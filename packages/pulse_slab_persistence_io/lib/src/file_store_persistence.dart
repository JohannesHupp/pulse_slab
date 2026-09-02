import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:pulse_slab/pulse_slab.dart';

const int _journalMagic = 0x50534a46;
const int _segmentMagic = 0x50534a53;
const int _acknowledgementMagic = 0x5053414b;
const int _fileFormatVersion = 1;
const int _segmentHeaderLength = 24;
const int _journalFrameHeaderLength = 24;
const int _acknowledgementCheckpointLength = 32;
const int _acknowledgementCheckpointCount = 2;
const int _maximumPortableSequence = 0x1fffffffffffff;
const int _defaultMaxPendingBytes = 8 * 1024 * 1024;
const int _defaultMaxJournalBytes = 16 * 1024 * 1024;
const int _defaultMaxSegmentBytes = 1024 * 1024;
const String _defaultJournalFileName = 'pulse_store.capture.journal';
const String _defaultAcknowledgementFileName = 'pulse_store.capture.ack';

/// Signals an unusable native persistence journal or worker failure.
///
/// The exception is deliberately distinct from
/// [StorePersistenceBackpressureException]: backpressure is an expected
/// capacity result that can be retried after replay progresses or journal
/// segments are reclaimed, while this exception means the file backend needs
/// operator attention or a new instance.
final class FileStorePersistenceException implements Exception {
  /// Creates a file persistence failure.
  const FileStorePersistenceException(this.message, [this.remoteStackTrace]);

  /// Human-readable failure description.
  final String message;

  /// Stack trace text from the I/O isolate, when available.
  final String? remoteStackTrace;

  @override
  String toString() {
    final String? stackTrace = remoteStackTrace;
    if (stackTrace == null || stackTrace.isEmpty) {
      return 'FileStorePersistenceException: $message';
    }
    return 'FileStorePersistenceException: $message\n$stackTrace';
  }
}

/// Marks a worker-detected integrity failure as terminal.
///
/// Request validation errors are returned to the caller and leave the journal
/// usable. A corrupt, truncated, or internally inconsistent journal must stop
/// the worker instead: continuing to append would make its bounded replay
/// state unreliable.
final class _JournalIntegrityException implements Exception {
  const _JournalIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'FileStorePersistenceException: $message';
}

/// Native append-only persistence for optional [PulseStore] captures.
///
/// [append] synchronously admits an independently encoded capture into a
/// byte-bounded pipeline, then transfers its immutable bytes to one long-lived
/// I/O isolate. It neither reads a live store nor uses [ChangeJournal]. A
/// successful [append] is an admission result, not a file durability barrier;
/// await [flush] before treating all previously appended captures as durable.
///
/// [maxPendingBytes] bounds unacknowledged encoded capture payloads and
/// [maxJournalBytes] bounds retained physical segment bytes. A full limit
/// throws [StorePersistenceBackpressureException]; accepted captures are never
/// dropped or overwritten. Each retained segment is append-only. A durable
/// acknowledgement reclaims only fully consumed, closed segments.
///
/// Replay has one shared [replayConsumer] and at most one outstanding delivery.
/// Acknowledgements are flushed durably after the corresponding journal data,
/// so unacknowledged batches are offered again after reopening the backend.
final class FileStorePersistence implements PulseStorePersistence {
  FileStorePersistence._({
    required this.directory,
    required this.maxPendingBytes,
    required this.maxJournalBytes,
    required this.maxSegmentBytes,
    required this.journalFileName,
    required this.acknowledgementFileName,
    required String journalKey,
  })  : _journalKey = journalKey,
        _replyPort = ReceivePort(),
        _replayConsumer = _FileStoreReplayConsumer._() {
    _replySubscription = _replyPort.listen(_onReply);
    _replayConsumer._owner = this;
  }

  /// Opens or recovers an append-only journal in [directory].
  ///
  /// The directory is created when absent. Existing segments and acknowledgement
  /// checkpoints are fully validated before this future completes. Corruption,
  /// truncation, or acknowledgement progress inconsistent with the journal
  /// fails open explicitly instead of discarding bytes.
  ///
  /// [maxPendingBytes] bounds unacknowledged encoded capture payload bytes.
  /// [maxJournalBytes] bounds all retained journal segment bytes, including
  /// binary headers. [maxSegmentBytes] bounds one append-only segment and must
  /// be no more than half of [maxJournalBytes], leaving room to rotate safely.
  /// A batch must fit into an empty segment. Reopening fails if retained,
  /// unacknowledged data exceeds either configured limit; safely acknowledged
  /// closed segments may be reclaimed during recovery. [journalFileName] and
  /// [acknowledgementFileName] must be simple file names. The acknowledgement
  /// base is stored in a journal-specific metadata directory below
  /// [directory].
  static Future<FileStorePersistence> open({
    required Directory directory,
    int maxPendingBytes = _defaultMaxPendingBytes,
    int maxJournalBytes = _defaultMaxJournalBytes,
    int maxSegmentBytes = _defaultMaxSegmentBytes,
    String journalFileName = _defaultJournalFileName,
    String acknowledgementFileName = _defaultAcknowledgementFileName,
  }) async {
    if (maxPendingBytes <= 0) {
      throw RangeError.value(
        maxPendingBytes,
        'maxPendingBytes',
        'Must be greater than zero.',
      );
    }
    if (maxJournalBytes <= 0) {
      throw RangeError.value(
        maxJournalBytes,
        'maxJournalBytes',
        'Must be greater than zero.',
      );
    }
    if (maxSegmentBytes <= 0 || maxSegmentBytes > maxJournalBytes ~/ 2) {
      throw RangeError.value(
        maxSegmentBytes,
        'maxSegmentBytes',
        'Must be greater than zero and no greater than half of '
            'maxJournalBytes.',
      );
    }
    _validateFileName(journalFileName, 'journalFileName');
    _validateFileName(acknowledgementFileName, 'acknowledgementFileName');
    if (journalFileName == acknowledgementFileName) {
      throw ArgumentError.value(
        acknowledgementFileName,
        'acknowledgementFileName',
        'Must differ from journalFileName.',
      );
    }
    final String journalKey = _journalPathKey(directory, journalFileName);
    if (!_activeJournalKeys.add(journalKey)) {
      throw StateError(
        'A FileStorePersistence instance already owns this journal in the '
        'current isolate.',
      );
    }

    final FileStorePersistence persistence = FileStorePersistence._(
      directory: directory,
      maxPendingBytes: maxPendingBytes,
      maxJournalBytes: maxJournalBytes,
      maxSegmentBytes: maxSegmentBytes,
      journalFileName: journalFileName,
      acknowledgementFileName: acknowledgementFileName,
      journalKey: journalKey,
    );
    try {
      await persistence._start();
      return persistence;
    } on Object {
      _activeJournalKeys.remove(journalKey);
      await persistence._disposePorts();
      rethrow;
    }
  }

  /// Directory containing the journal and acknowledgement files.
  final Directory directory;

  /// Maximum retained, unacknowledged encoded capture bytes.
  final int maxPendingBytes;

  /// Maximum retained physical bytes across all journal segments.
  ///
  /// Segment and frame headers count against this strict capacity. It is
  /// independent of [maxPendingBytes]: acknowledged prefixes in the active
  /// segment can occupy physical capacity until that segment closes.
  final int maxJournalBytes;

  /// Maximum retained bytes in one append-only journal segment.
  ///
  /// This includes the segment header and every frame header. It is at most
  /// half of [maxJournalBytes], so a full segment can rotate while preserving
  /// safe acknowledgement progress. Lower values bound acknowledged-prefix
  /// fragmentation more tightly at the cost of more segment rotations.
  final int maxSegmentBytes;

  /// Base name for the append-only binary segment directory within [directory].
  final String journalFileName;

  /// Base name for alternating acknowledgement checkpoint files.
  ///
  /// The files are scoped beneath this instance's journal metadata directory,
  /// so separate journal names in one [directory] cannot share progress.
  final String acknowledgementFileName;

  final String _journalKey;

  static final Set<String> _activeJournalKeys = <String>{};

  final ReceivePort _replyPort;
  final Completer<_WorkerReady> _ready = Completer<_WorkerReady>();
  final Completer<void> _stopped = Completer<void>();
  final Map<int, Completer<Map<Object?, Object?>>> _requests =
      <int, Completer<Map<Object?, Object?>>>{};
  final _FileStoreReplayConsumer _replayConsumer;

  late final StreamSubscription<dynamic> _replySubscription;
  SendPort? _commandPort;
  Future<void>? _closeFuture;
  FileStorePersistenceException? _failure;
  var _pendingBytes = 0;
  var _journalBytes = 0;
  var _activeSegmentBytes = 0;
  var _nextSequence = 1;
  var _nextRequestId = 1;
  var _closing = false;
  var _portsDisposed = false;

  /// Current encoded bytes retained by unacknowledged captures.
  ///
  /// This includes batches accepted in the calling isolate but not yet written
  /// by the I/O isolate. It excludes private frame headers and acknowledgement
  /// metadata.
  int get pendingBytes => _pendingBytes;

  /// Physical bytes currently retained by the journal segment set.
  ///
  /// This includes segment and frame headers, plus acknowledged prefixes in
  /// the current active segment. It is the value bounded by
  /// [maxJournalBytes].
  int get journalBytes => _journalBytes;

  /// Whether [close] has been requested.
  bool get isClosing => _closing;

  /// The package's single ordered replay consumer.
  ///
  /// The same consumer instance is returned for every read. It enforces
  /// `maxInFlight: 1` across all callers.
  StorePersistenceReplayConsumer get replayConsumer => _replayConsumer;

  @override
  void append(StoreCaptureBatch batch) {
    final FileStorePersistenceException? failure = _failure;
    if (failure != null) {
      throw failure;
    }
    if (_closing) {
      throw StateError('The file persistence backend is closing or closed.');
    }
    final SendPort? commandPort = _commandPort;
    if (commandPort == null) {
      throw StateError('The file persistence backend is not ready.');
    }

    // Encoding owns a capture buffer before it crosses the isolate boundary.
    // It never reads mutable PulseStore memory in the I/O isolate.
    final Uint8List bytes = batch.encode();
    final int batchBytes = bytes.lengthInBytes;
    final int frameBytes = _journalFrameHeaderLength + batchBytes;
    if (_nextSequence > _maximumPortableSequence) {
      throw const FileStorePersistenceException(
        'The file journal has exhausted portable capture sequence numbers.',
      );
    }
    if (_pendingBytes > maxPendingBytes - batchBytes) {
      throw StorePersistenceBackpressureException(
        pendingBytes: _pendingBytes,
        maxPendingBytes: maxPendingBytes,
        batchBytes: batchBytes,
      );
    }
    final bool startsNewSegment = _activeSegmentBytes == 0 ||
        _activeSegmentBytes + frameBytes > maxSegmentBytes;
    final int requiredJournalBytes =
        frameBytes + (startsNewSegment ? _segmentHeaderLength : 0);
    if (requiredJournalBytes > maxSegmentBytes ||
        _journalBytes > maxJournalBytes - requiredJournalBytes) {
      throw StorePersistenceBackpressureException(
        pendingBytes: _journalBytes,
        maxPendingBytes: maxJournalBytes,
        batchBytes: requiredJournalBytes,
      );
    }

    // Build the transferable payload before changing local admission state.
    // If materialization or SendPort.send fails synchronously, PulseStore can
    // roll back without a leaked byte reservation or sequence number.
    final TransferableTypedData transfer =
        TransferableTypedData.fromList(<Uint8List>[bytes]);
    final int sequence = _nextSequence;
    commandPort.send(<String, Object?>{
      'type': 'append',
      'sequence': sequence,
      'startsNewSegment': startsNewSegment,
      'bytes': transfer,
    });
    _nextSequence = sequence + 1;
    _pendingBytes += batchBytes;
    _journalBytes += requiredJournalBytes;
    _activeSegmentBytes = startsNewSegment
        ? requiredJournalBytes
        : _activeSegmentBytes + frameBytes;
  }

  /// Flushes all captures appended before this call to the native journal.
  ///
  /// The worker processes commands in send-port order, so completing this
  /// future establishes a durability barrier for earlier accepted appends. It
  /// does not acknowledge replay deliveries.
  Future<void> flush() async {
    await _request('flush');
  }

  /// Flushes accepted captures and stops the long-lived I/O isolate.
  ///
  /// The method is idempotent. Calls to [append] are rejected as soon as close
  /// is requested. A failed backend completes this future with its original
  /// failure instead of pretending that accepted data was persisted.
  Future<void> close() {
    final Future<void>? existing = _closeFuture;
    if (existing != null) {
      return existing;
    }

    _closing = true;
    final FileStorePersistenceException? failure = _failure;
    if (failure != null) {
      _closeFuture = _disposePorts().then<void>((_) {
        _activeJournalKeys.remove(_journalKey);
        throw failure;
      });
      return _closeFuture!;
    }

    _closeFuture =
        _request('shutdown', allowClosing: true).then<void>((_) async {
      await _stopped.future;
      final FileStorePersistenceException? completedFailure = _failure;
      if (completedFailure != null) {
        throw completedFailure;
      }
    }).whenComplete(() async {
      _activeJournalKeys.remove(_journalKey);
      await _disposePorts();
    });
    return _closeFuture!;
  }

  Future<void> _start() async {
    try {
      await Isolate.spawn<_WorkerBootstrap>(
        _fileStorePersistenceWorkerMain,
        _WorkerBootstrap(
          replyTo: _replyPort.sendPort,
          directoryPath: directory.path,
          journalFileName: journalFileName,
          acknowledgementFileName: acknowledgementFileName,
          maxPendingBytes: maxPendingBytes,
          maxJournalBytes: maxJournalBytes,
          maxSegmentBytes: maxSegmentBytes,
        ),
        // Worker replies, errors, and exit notifications share one receive
        // port. That preserves the worker's terminal message before its exit
        // notification can be observed by the owning isolate.
        onError: _replyPort.sendPort,
        onExit: _replyPort.sendPort,
        errorsAreFatal: true,
        debugName: 'pulse_slab.file_store_persistence',
      );
    } on Object catch (error, stackTrace) {
      _fail(
        FileStorePersistenceException(
          'Unable to start file persistence worker: $error',
          stackTrace.toString(),
        ),
      );
    }
    final _WorkerReady ready = await _ready.future;
    _commandPort = ready.commandPort;
    _pendingBytes = ready.pendingBytes;
    _journalBytes = ready.journalBytes;
    _activeSegmentBytes = ready.activeSegmentBytes;
    _nextSequence = ready.nextSequence;
  }

  Future<Map<Object?, Object?>> _request(
    String type, {
    Map<String, Object?> values = const <String, Object?>{},
    bool allowClosing = false,
  }) {
    final FileStorePersistenceException? failure = _failure;
    if (failure != null) {
      return Future<Map<Object?, Object?>>.error(failure);
    }
    if (_closing && !allowClosing) {
      return Future<Map<Object?, Object?>>.error(
        StateError('The file persistence backend is closing or closed.'),
      );
    }
    final SendPort? commandPort = _commandPort;
    if (commandPort == null) {
      return Future<Map<Object?, Object?>>.error(
        StateError('The file persistence backend is not ready.'),
      );
    }
    final int requestId = _nextRequestId++;
    final Completer<Map<Object?, Object?>> completer =
        Completer<Map<Object?, Object?>>();
    _requests[requestId] = completer;
    try {
      commandPort.send(<String, Object?>{
        'type': type,
        'requestId': requestId,
        ...values,
      });
    } on Object catch (error, stackTrace) {
      _requests.remove(requestId);
      return Future<Map<Object?, Object?>>.error(error, stackTrace);
    }
    return completer.future;
  }

  Future<StorePersistenceReplayDelivery?> _takeReplay() async {
    final Map<Object?, Object?> response = await _request('take');
    final Object? sequenceValue = response['sequence'];
    if (sequenceValue == null) {
      return null;
    }
    final Object? bytesValue = response['bytes'];
    if (sequenceValue is! int || bytesValue is! TransferableTypedData) {
      _fail(
        const FileStorePersistenceException(
          'The file persistence worker sent an invalid replay delivery.',
        ),
      );
      throw _failure!;
    }
    final Uint8List bytes = bytesValue.materialize().asUint8List();
    final StoreCaptureBatch batch;
    try {
      batch = StoreCaptureCodec.decode(bytes);
    } on Object catch (error, stackTrace) {
      _fail(
        FileStorePersistenceException(
          'The file persistence worker returned an invalid capture: $error',
          stackTrace.toString(),
        ),
      );
      throw _failure!;
    }
    return StorePersistenceReplayDelivery(
      sequence: sequenceValue,
      batch: batch,
    );
  }

  Future<void> _acknowledgeReplay(
    StorePersistenceReplayDelivery delivery,
  ) async {
    final Map<Object?, Object?> response = await _request(
      'acknowledge',
      values: <String, Object?>{'sequence': delivery.sequence},
    );
    final Object? releasedBytesValue = response['releasedBytes'];
    final Object? reclaimedJournalBytesValue =
        response['reclaimedJournalBytes'];
    if (releasedBytesValue is! int ||
        releasedBytesValue < 0 ||
        releasedBytesValue > _pendingBytes ||
        reclaimedJournalBytesValue is! int ||
        reclaimedJournalBytesValue < 0 ||
        reclaimedJournalBytesValue > _journalBytes) {
      _fail(
        const FileStorePersistenceException(
          'The file persistence worker sent an invalid acknowledgement.',
        ),
      );
      throw _failure!;
    }
    _pendingBytes -= releasedBytesValue;
    _journalBytes -= reclaimedJournalBytesValue;
  }

  Future<void> _retryReplay(StorePersistenceReplayDelivery delivery) async {
    await _request(
      'retry',
      values: <String, Object?>{'sequence': delivery.sequence},
    );
  }

  void _onReply(dynamic message) {
    if (message == null) {
      _onIsolateExit(null);
      return;
    }
    if (message is List<Object?>) {
      _onIsolateError(message);
      return;
    }
    if (message is! Map<Object?, Object?>) {
      _fail(
        const FileStorePersistenceException(
          'The file persistence worker sent an invalid response.',
        ),
      );
      return;
    }
    final Object? type = message['type'];
    switch (type) {
      case 'ready':
        _handleReady(message);
      case 'success':
        _completeRequest(message);
      case 'failure':
        _completeRequestFailure(message);
      case 'fatal':
        _handleFatal(message);
      case 'stopped':
        _completeStopped();
      default:
        _fail(
          const FileStorePersistenceException(
            'The file persistence worker sent an unknown response.',
          ),
        );
    }
  }

  void _handleReady(Map<Object?, Object?> message) {
    final Object? commandPortValue = message['commandPort'];
    final Object? pendingBytesValue = message['pendingBytes'];
    final Object? journalBytesValue = message['journalBytes'];
    final Object? activeSegmentBytesValue = message['activeSegmentBytes'];
    final Object? nextSequenceValue = message['nextSequence'];
    if (commandPortValue is! SendPort ||
        pendingBytesValue is! int ||
        pendingBytesValue < 0 ||
        pendingBytesValue > maxPendingBytes ||
        journalBytesValue is! int ||
        journalBytesValue < 0 ||
        journalBytesValue > maxJournalBytes ||
        activeSegmentBytesValue is! int ||
        activeSegmentBytesValue < 0 ||
        activeSegmentBytesValue > maxSegmentBytes ||
        nextSequenceValue is! int ||
        nextSequenceValue <= 0 ||
        nextSequenceValue > _maximumPortableSequence) {
      _fail(
        const FileStorePersistenceException(
          'The file persistence worker sent invalid startup state.',
        ),
      );
      return;
    }
    if (!_ready.isCompleted) {
      _ready.complete(
        _WorkerReady(
          commandPort: commandPortValue,
          pendingBytes: pendingBytesValue,
          journalBytes: journalBytesValue,
          activeSegmentBytes: activeSegmentBytesValue,
          nextSequence: nextSequenceValue,
        ),
      );
    }
  }

  void _completeRequest(Map<Object?, Object?> message) {
    final Object? requestIdValue = message['requestId'];
    if (requestIdValue is! int) {
      _fail(
        const FileStorePersistenceException(
          'The file persistence worker sent a response without a request ID.',
        ),
      );
      return;
    }
    final Completer<Map<Object?, Object?>>? completer =
        _requests.remove(requestIdValue);
    completer?.complete(message);
  }

  void _completeRequestFailure(Map<Object?, Object?> message) {
    final Object? requestIdValue = message['requestId'];
    final Object? errorValue = message['error'];
    final Object? stackTraceValue = message['stackTrace'];
    if (requestIdValue is! int ||
        errorValue is! String ||
        stackTraceValue is! String) {
      _fail(
        const FileStorePersistenceException(
          'The file persistence worker sent an invalid failure response.',
        ),
      );
      return;
    }
    final Completer<Map<Object?, Object?>>? completer =
        _requests.remove(requestIdValue);
    completer?.completeError(
      FileStorePersistenceException(errorValue, stackTraceValue),
    );
  }

  void _handleFatal(Map<Object?, Object?> message) {
    final Object? errorValue = message['error'];
    final Object? stackTraceValue = message['stackTrace'];
    if (errorValue is! String || stackTraceValue is! String) {
      _fail(
        const FileStorePersistenceException(
          'The file persistence worker failed with an invalid error response.',
        ),
      );
      return;
    }
    _fail(FileStorePersistenceException(errorValue, stackTraceValue));
  }

  void _onIsolateError(dynamic message) {
    if (message is List<Object?> && message.isNotEmpty) {
      final Object? error = message.first;
      final Object? stackTrace = message.length > 1 ? message[1] : null;
      _fail(
        FileStorePersistenceException(
          'The file persistence worker failed: $error',
          stackTrace?.toString(),
        ),
      );
      return;
    }
    _fail(
      FileStorePersistenceException(
        'The file persistence worker failed: $message',
      ),
    );
  }

  void _onIsolateExit(dynamic _) {
    if (_stopped.isCompleted) {
      return;
    }
    if (_closing && _failure == null) {
      _completeStopped();
      return;
    }
    _fail(
      const FileStorePersistenceException(
        'The file persistence worker exited unexpectedly.',
      ),
    );
  }

  void _completeStopped() {
    if (!_stopped.isCompleted) {
      _stopped.complete();
    }
  }

  void _fail(FileStorePersistenceException failure) {
    if (_failure != null) {
      return;
    }
    _failure = failure;
    if (!_ready.isCompleted) {
      _ready.completeError(failure);
    }
    for (final Completer<Map<Object?, Object?>> completer in _requests.values) {
      completer.completeError(failure);
    }
    _requests.clear();
    if (!_stopped.isCompleted) {
      // `_ready` and outstanding requests carry the failure. Completing this
      // lifecycle signal normally avoids an unobserved asynchronous error when
      // startup fails before a caller can invoke close.
      _stopped.complete();
    }
  }

  Future<void> _disposePorts() async {
    if (_portsDisposed) {
      return;
    }
    _portsDisposed = true;
    _replyPort.close();
    await _replySubscription.cancel();
  }
}

final class _FileStoreReplayConsumer implements StorePersistenceReplayConsumer {
  _FileStoreReplayConsumer._();

  late FileStorePersistence _owner;
  StorePersistenceReplayDelivery? _activeDelivery;
  var _taking = false;

  @override
  Future<StorePersistenceReplayDelivery?> take() async {
    if (_taking || _activeDelivery != null) {
      throw StateError(
        'A replay delivery is already outstanding; maxInFlight is one.',
      );
    }
    _taking = true;
    try {
      final StorePersistenceReplayDelivery? delivery =
          await _owner._takeReplay();
      _activeDelivery = delivery;
      return delivery;
    } finally {
      _taking = false;
    }
  }

  @override
  Future<void> acknowledge(StorePersistenceReplayDelivery delivery) async {
    _requireActive(delivery);
    await _owner._acknowledgeReplay(delivery);
    _activeDelivery = null;
  }

  @override
  Future<void> retry(StorePersistenceReplayDelivery delivery) async {
    _requireActive(delivery);
    await _owner._retryReplay(delivery);
    _activeDelivery = null;
  }

  void _requireActive(StorePersistenceReplayDelivery delivery) {
    if (!identical(_activeDelivery, delivery)) {
      throw StateError('The replay delivery is not the active delivery.');
    }
  }
}

final class _WorkerBootstrap {
  const _WorkerBootstrap({
    required this.replyTo,
    required this.directoryPath,
    required this.journalFileName,
    required this.acknowledgementFileName,
    required this.maxPendingBytes,
    required this.maxJournalBytes,
    required this.maxSegmentBytes,
  });

  final SendPort replyTo;
  final String directoryPath;
  final String journalFileName;
  final String acknowledgementFileName;
  final int maxPendingBytes;
  final int maxJournalBytes;
  final int maxSegmentBytes;
}

final class _WorkerReady {
  const _WorkerReady({
    required this.commandPort,
    required this.pendingBytes,
    required this.journalBytes,
    required this.activeSegmentBytes,
    required this.nextSequence,
  });

  final SendPort commandPort;
  final int pendingBytes;
  final int journalBytes;
  final int activeSegmentBytes;
  final int nextSequence;
}

void _fileStorePersistenceWorkerMain(_WorkerBootstrap bootstrap) async {
  _FileJournalWorker? worker;
  ReceivePort? commandPort;
  var stopping = false;
  try {
    final _FileJournalWorker openedWorker =
        await _FileJournalWorker.open(bootstrap);
    worker = openedWorker;
    final ReceivePort openedCommandPort = ReceivePort();
    commandPort = openedCommandPort;
    bootstrap.replyTo.send(<String, Object?>{
      'type': 'ready',
      'commandPort': openedCommandPort.sendPort,
      'pendingBytes': openedWorker.pendingBytes,
      'journalBytes': openedWorker.journalBytes,
      'activeSegmentBytes': openedWorker.activeSegmentBytes,
      'nextSequence': openedWorker.nextSequence,
    });

    Future<void> commandChain = Future<void>.value();
    openedCommandPort.listen((dynamic message) {
      if (stopping) {
        return;
      }
      commandChain = commandChain.then<void>((_) async {
        final int? shutdownRequestId = await openedWorker.handle(message);
        if (shutdownRequestId != null) {
          stopping = true;
          openedCommandPort.close();
          try {
            await openedWorker.close();
          } on Object catch (error, stackTrace) {
            bootstrap.replyTo.send(<String, Object?>{
              'type': 'fatal',
              'error': error.toString(),
              'stackTrace': stackTrace.toString(),
            });
            return;
          }
          bootstrap.replyTo.send(<String, Object?>{
            'type': 'success',
            'requestId': shutdownRequestId,
          });
          bootstrap.replyTo.send(const <String, Object?>{'type': 'stopped'});
        }
      }).catchError((Object error, StackTrace stackTrace) async {
        if (stopping) {
          return;
        }
        stopping = true;
        openedCommandPort.close();
        try {
          await openedWorker.close();
        } on Object {
          // The original worker failure is the useful failure to surface.
        }
        bootstrap.replyTo.send(<String, Object?>{
          'type': 'fatal',
          'error': error.toString(),
          'stackTrace': stackTrace.toString(),
        });
      });
    });
  } on Object catch (error, stackTrace) {
    try {
      await worker?.close();
    } on Object {
      // Preserve the original startup failure.
    }
    bootstrap.replyTo.send(<String, Object?>{
      'type': 'fatal',
      'error': error.toString(),
      'stackTrace': stackTrace.toString(),
    });
    commandPort?.close();
  }
}

final class _FileJournalWorker {
  _FileJournalWorker._({
    required this.replyTo,
    required this.directory,
    required this.journalFileName,
    required this.acknowledgementFileName,
    required this.maxPendingBytes,
    required this.maxJournalBytes,
    required this.maxSegmentBytes,
    required this.lock,
    required List<_JournalSegment> segments,
    required List<_JournalFrame> pendingFrames,
    required this.pendingBytes,
    required this.journalBytes,
    required this.nextSequence,
    required this.acknowledgedSequence,
    required this.nextAcknowledgementGeneration,
    required this.nextAcknowledgementSlot,
    required this.acknowledgementSequences,
  })  : segments = ListQueue<_JournalSegment>.of(segments),
        pendingFrames = ListQueue<_JournalFrame>.of(pendingFrames);

  static Future<_FileJournalWorker> open(_WorkerBootstrap bootstrap) async {
    final Directory directory = Directory(bootstrap.directoryPath);
    await directory.create(recursive: true);
    final File lockFile = File(
      _joinPath(directory.path, '${bootstrap.journalFileName}.lock'),
    );
    final RandomAccessFile lock = await lockFile.open(mode: FileMode.append);
    _FileJournalWorker? worker;
    try {
      // One process owns append ordering for one journal. A second opener fails
      // explicitly instead of interleaving frames from another worker.
      await lock.lock(FileLock.exclusive);
      await _rejectLegacyJournalFiles(
        directory,
        bootstrap.journalFileName,
        bootstrap.acknowledgementFileName,
      );
      final _RecoveredJournal recovered = await _recoverJournal(
        directory: directory,
        journalFileName: bootstrap.journalFileName,
        acknowledgementFileName: bootstrap.acknowledgementFileName,
        maxPendingBytes: bootstrap.maxPendingBytes,
        maxJournalBytes: bootstrap.maxJournalBytes,
        maxSegmentBytes: bootstrap.maxSegmentBytes,
      );
      worker = _FileJournalWorker._(
        replyTo: bootstrap.replyTo,
        directory: directory,
        journalFileName: bootstrap.journalFileName,
        acknowledgementFileName: bootstrap.acknowledgementFileName,
        maxPendingBytes: bootstrap.maxPendingBytes,
        maxJournalBytes: bootstrap.maxJournalBytes,
        maxSegmentBytes: bootstrap.maxSegmentBytes,
        lock: lock,
        segments: recovered.segments,
        pendingFrames: recovered.pendingFrames,
        pendingBytes: recovered.pendingBytes,
        journalBytes: recovered.journalBytes,
        nextSequence: recovered.nextSequence,
        acknowledgedSequence: recovered.acknowledgedSequence,
        nextAcknowledgementGeneration: recovered.nextAcknowledgementGeneration,
        nextAcknowledgementSlot: recovered.nextAcknowledgementSlot,
        acknowledgementSequences: recovered.acknowledgementSequences,
      );
      await worker._reclaimAcknowledgedClosedSegments();
      if (worker.journalBytes > bootstrap.maxJournalBytes) {
        throw const FileStorePersistenceException(
          'Recovered journal segments exceed maxJournalBytes.',
        );
      }
      await worker._restoreActiveSegment();
      return worker;
    } on Object {
      await worker?.close();
      await _closeQuietly(lock);
      rethrow;
    }
  }

  final SendPort replyTo;
  final Directory directory;
  final String journalFileName;
  final String acknowledgementFileName;
  final int maxPendingBytes;
  final int maxJournalBytes;
  final int maxSegmentBytes;
  final RandomAccessFile lock;
  final ListQueue<_JournalSegment> segments;
  final ListQueue<_JournalFrame> pendingFrames;
  int pendingBytes;
  int journalBytes;
  int nextSequence;
  int acknowledgedSequence;
  int nextAcknowledgementGeneration;
  int nextAcknowledgementSlot;
  final List<int?> acknowledgementSequences;
  RandomAccessFile? _activeJournal;
  _JournalSegment? _activeSegment;
  int? _outstandingSequence;
  var _hasUnflushedJournalWrites = false;
  var _closed = false;

  int get activeSegmentBytes => _activeSegment?.byteLength ?? 0;

  Future<int?> handle(dynamic message) async {
    if (message is! Map<Object?, Object?>) {
      throw const FileStorePersistenceException('Invalid worker command.');
    }
    final Object? type = message['type'];
    switch (type) {
      case 'append':
        await _append(message);
        return null;
      case 'flush':
        await _respond(message, _flush);
        return null;
      case 'take':
        await _respond(message, _take);
        return null;
      case 'acknowledge':
        await _respond(message, () => _acknowledge(message));
        return null;
      case 'retry':
        await _respond(message, () => _retry(message));
        return null;
      case 'shutdown':
        final Object? requestIdValue = message['requestId'];
        if (requestIdValue is! int) {
          throw const FileStorePersistenceException(
            'A worker request is missing its request ID.',
          );
        }
        await _flush();
        return requestIdValue;
      default:
        throw FileStorePersistenceException('Unknown worker command $type.');
    }
  }

  Future<void> _append(Map<Object?, Object?> message) async {
    final Object? sequenceValue = message['sequence'];
    final Object? startsNewSegmentValue = message['startsNewSegment'];
    final Object? bytesValue = message['bytes'];
    if (sequenceValue is! int ||
        startsNewSegmentValue is! bool ||
        bytesValue is! TransferableTypedData) {
      throw const FileStorePersistenceException('Invalid append command.');
    }
    if (sequenceValue != nextSequence ||
        sequenceValue <= 0 ||
        sequenceValue > _maximumPortableSequence) {
      throw FileStorePersistenceException(
        'Out-of-order capture sequence $sequenceValue; expected $nextSequence.',
      );
    }
    final Uint8List bytes = bytesValue.materialize().asUint8List();
    if (bytes.lengthInBytes > 0xffffffff) {
      throw const FileStorePersistenceException(
        'A capture exceeds the native journal frame limit.',
      );
    }

    final int frameBytes = _journalFrameHeaderLength + bytes.lengthInBytes;
    final _JournalSegment? activeSegment = _activeSegment;
    final bool startsNewSegment = activeSegment == null ||
        activeSegment.byteLength + frameBytes > maxSegmentBytes;
    if (startsNewSegment != startsNewSegmentValue) {
      throw const FileStorePersistenceException(
        'The owner and I/O isolate disagreed about journal segment rotation.',
      );
    }
    final int requiredJournalBytes =
        frameBytes + (startsNewSegment ? _segmentHeaderLength : 0);
    if (requiredJournalBytes > maxSegmentBytes ||
        journalBytes > maxJournalBytes - requiredJournalBytes) {
      throw const FileStorePersistenceException(
        'A synchronously admitted capture exceeded native journal capacity.',
      );
    }
    if (pendingBytes > maxPendingBytes - bytes.lengthInBytes) {
      throw const FileStorePersistenceException(
        'A synchronously admitted capture exceeded pending replay capacity.',
      );
    }

    if (startsNewSegment) {
      await _sealActiveSegment();
      await _createSegment(sequenceValue);
    }
    final int checksum = _checksum(bytes);
    final Uint8List header = _encodeJournalHeader(
      sequenceValue,
      bytes.lengthInBytes,
      checksum,
    );
    final _JournalSegment segment = _activeSegment!;
    final RandomAccessFile journal = _activeJournal!;
    final int offset = segment.byteLength;
    await journal.writeFrom(header);
    await journal.writeFrom(bytes);
    segment.byteLength += frameBytes;
    segment.endSequence = sequenceValue;
    pendingFrames.add(
      _JournalFrame(
        sequence: sequenceValue,
        segment: segment,
        payloadOffset: offset + _journalFrameHeaderLength,
        payloadLength: bytes.lengthInBytes,
        checksum: checksum,
      ),
    );
    pendingBytes += bytes.lengthInBytes;
    journalBytes += frameBytes;
    _hasUnflushedJournalWrites = true;
    nextSequence++;
  }

  Future<Map<String, Object?>> _flush() async {
    if (!_hasUnflushedJournalWrites) {
      return const <String, Object?>{};
    }
    final RandomAccessFile? journal = _activeJournal;
    if (journal == null) {
      throw const _JournalIntegrityException(
        'Journal writes are pending without an active journal file.',
      );
    }
    await journal.flush();
    _hasUnflushedJournalWrites = false;
    return const <String, Object?>{};
  }

  Future<Map<String, Object?>> _take() async {
    if (_outstandingSequence != null) {
      throw const FileStorePersistenceException(
        'A replay delivery is already outstanding; maxInFlight is one.',
      );
    }
    if (pendingFrames.isEmpty) {
      return const <String, Object?>{};
    }
    final _JournalFrame frame = pendingFrames.first;
    // Do not offer a replay delivery until its journal frame survives the
    // backend's durability barrier. This also makes an unacknowledged delivery
    // available after a process restart.
    await _flush();
    final Uint8List bytes = await _readFrame(frame);
    if (bytes.lengthInBytes != frame.payloadLength ||
        _checksum(bytes) != frame.checksum) {
      throw const _JournalIntegrityException(
        'The journal changed or is truncated while reading a replay delivery.',
      );
    }
    // Decode in the I/O isolate before claiming a delivery. This validates the
    // core format while retaining an immutable byte-only boundary to the caller.
    StoreCaptureCodec.decode(bytes);
    _outstandingSequence = frame.sequence;
    return <String, Object?>{
      'sequence': frame.sequence,
      'bytes': TransferableTypedData.fromList(<Uint8List>[bytes]),
    };
  }

  Future<Map<String, Object?>> _acknowledge(
    Map<Object?, Object?> message,
  ) async {
    final Object? sequenceValue = message['sequence'];
    if (sequenceValue is! int || sequenceValue != _outstandingSequence) {
      throw const FileStorePersistenceException(
        'The acknowledgement does not match the outstanding replay delivery.',
      );
    }
    if (pendingFrames.isEmpty ||
        pendingFrames.first.sequence != sequenceValue) {
      throw const _JournalIntegrityException(
        'The outstanding replay delivery is missing from the journal.',
      );
    }

    // An acknowledgement is durable only after its capture bytes are durable.
    await _flush();
    await _persistAcknowledgement(sequenceValue);
    final _JournalFrame frame = pendingFrames.removeFirst();
    pendingBytes -= frame.payloadLength;
    acknowledgedSequence = sequenceValue;
    _outstandingSequence = null;
    final int reclaimedJournalBytes =
        await _reclaimAcknowledgedClosedSegments();
    return <String, Object?>{
      'releasedBytes': frame.payloadLength,
      'reclaimedJournalBytes': reclaimedJournalBytes,
    };
  }

  Future<Map<String, Object?>> _retry(Map<Object?, Object?> message) async {
    final Object? sequenceValue = message['sequence'];
    if (sequenceValue is! int || sequenceValue != _outstandingSequence) {
      throw const FileStorePersistenceException(
        'The retry does not match the outstanding replay delivery.',
      );
    }
    _outstandingSequence = null;
    return const <String, Object?>{};
  }

  Future<void> _respond(
    Map<Object?, Object?> message,
    Future<Map<String, Object?>> Function() operation,
  ) async {
    final Object? requestIdValue = message['requestId'];
    if (requestIdValue is! int) {
      throw const FileStorePersistenceException(
        'A worker request is missing its request ID.',
      );
    }
    try {
      final Map<String, Object?> values = await operation();
      replyTo.send(<String, Object?>{
        'type': 'success',
        'requestId': requestIdValue,
        ...values,
      });
    } on FileStorePersistenceException catch (error, stackTrace) {
      replyTo.send(<String, Object?>{
        'type': 'failure',
        'requestId': requestIdValue,
        'error': error.message,
        'stackTrace': stackTrace.toString(),
      });
    }
  }

  Future<void> close() async {
    if (_closed) {
      return;
    }
    _closed = true;
    await _sealActiveSegment();
    await lock.close();
  }

  Future<void> _restoreActiveSegment() async {
    if (segments.isEmpty) {
      return;
    }
    final _JournalSegment segment = segments.last;
    if (segment.byteLength >= maxSegmentBytes) {
      // A process can terminate after filling its active segment but before
      // sealing it. Establish its durability boundary without retaining it as
      // active, so acknowledged full segments remain reclaimable immediately.
      final RandomAccessFile journal = await File(segment.path).open(
        mode: FileMode.append,
      );
      try {
        await journal.flush();
      } finally {
        await journal.close();
      }
      return;
    }
    _activeJournal = await File(segment.path).open(mode: FileMode.append);
    _activeSegment = segment;
    // Recovery cannot prove that bytes observed from an unclosed prior worker
    // crossed the native durability boundary. Force that boundary before an
    // acknowledgement can advance or this segment is sealed.
    _hasUnflushedJournalWrites = true;
  }

  Future<void> _createSegment(int firstSequence) async {
    final Directory segmentDirectory = Directory(
      _segmentDirectoryPath(directory.path, journalFileName),
    );
    await segmentDirectory.create(recursive: true);
    final String path = _joinPath(
      segmentDirectory.path,
      _segmentFileName(firstSequence),
    );
    final File file = File(path);
    if (await file.exists()) {
      throw FileStorePersistenceException(
        'Journal segment already exists for capture sequence $firstSequence.',
      );
    }
    final RandomAccessFile journal = await file.open(mode: FileMode.write);
    try {
      await journal.writeFrom(_encodeSegmentHeader(firstSequence));
    } on Object {
      await _closeQuietly(journal);
      rethrow;
    }
    final _JournalSegment segment = _JournalSegment(
      path: path,
      startSequence: firstSequence,
      byteLength: _segmentHeaderLength,
    );
    segments.add(segment);
    _activeSegment = segment;
    _activeJournal = journal;
    journalBytes += _segmentHeaderLength;
  }

  Future<void> _sealActiveSegment() async {
    final RandomAccessFile? journal = _activeJournal;
    if (journal == null) {
      return;
    }
    if (_hasUnflushedJournalWrites) {
      await journal.flush();
      _hasUnflushedJournalWrites = false;
    }
    await journal.close();
    _activeJournal = null;
    _activeSegment = null;
  }

  Future<Uint8List> _readFrame(_JournalFrame frame) async {
    final RandomAccessFile input = await File(frame.segment.path).open(
      mode: FileMode.read,
    );
    try {
      await input.setPosition(frame.payloadOffset);
      return await input.read(frame.payloadLength);
    } finally {
      await input.close();
    }
  }

  Future<void> _persistAcknowledgement(int sequence) async {
    if (nextAcknowledgementGeneration > _maximumPortableSequence) {
      throw const _JournalIntegrityException(
        'The journal has exhausted acknowledgement checkpoint generations.',
      );
    }
    final int slot = nextAcknowledgementSlot;
    final File checkpoint = File(
      _acknowledgementCheckpointPath(
        directory.path,
        journalFileName,
        acknowledgementFileName,
        slot,
      ),
    );
    await checkpoint.parent.create(recursive: true);
    await checkpoint.writeAsBytes(
      _encodeAcknowledgement(
        slot: slot,
        generation: nextAcknowledgementGeneration,
        sequence: sequence,
      ),
      flush: true,
    );
    nextAcknowledgementGeneration++;
    acknowledgementSequences[slot] = sequence;
    nextAcknowledgementSlot =
        (nextAcknowledgementSlot + 1) % _acknowledgementCheckpointCount;
  }

  Future<int> _reclaimAcknowledgedClosedSegments() async {
    var reclaimedBytes = 0;
    while (segments.isNotEmpty) {
      final _JournalSegment segment = segments.first;
      if (identical(segment, _activeSegment) ||
          segment.endSequence == null ||
          segment.endSequence! > _safeReclamationSequence) {
        break;
      }
      try {
        await File(segment.path).delete();
      } on FileSystemException {
        // The acknowledgement is already durable. Keep physical capacity
        // reserved until a later recovery or acknowledgement can reclaim it.
        break;
      }
      segments.removeFirst();
      journalBytes -= segment.byteLength;
      reclaimedBytes += segment.byteLength;
    }
    return reclaimedBytes;
  }

  int get _safeReclamationSequence {
    int? lowest;
    for (final int? sequence in acknowledgementSequences) {
      if (sequence == null) {
        return 0;
      }
      if (lowest == null || sequence < lowest) {
        lowest = sequence;
      }
    }
    return lowest ?? 0;
  }
}

final class _RecoveredJournal {
  const _RecoveredJournal({
    required this.segments,
    required this.pendingFrames,
    required this.pendingBytes,
    required this.journalBytes,
    required this.nextSequence,
    required this.acknowledgedSequence,
    required this.nextAcknowledgementGeneration,
    required this.nextAcknowledgementSlot,
    required this.acknowledgementSequences,
  });

  final List<_JournalSegment> segments;
  final List<_JournalFrame> pendingFrames;
  final int pendingBytes;
  final int journalBytes;
  final int nextSequence;
  final int acknowledgedSequence;
  final int nextAcknowledgementGeneration;
  final int nextAcknowledgementSlot;
  final List<int?> acknowledgementSequences;
}

final class _JournalSegment {
  _JournalSegment({
    required this.path,
    required this.startSequence,
    required this.byteLength,
  });

  final String path;
  final int startSequence;
  int byteLength;
  int? endSequence;
}

final class _JournalFrame {
  const _JournalFrame({
    required this.sequence,
    required this.segment,
    required this.payloadOffset,
    required this.payloadLength,
    required this.checksum,
  });

  final int sequence;
  final _JournalSegment segment;
  final int payloadOffset;
  final int payloadLength;
  final int checksum;
}

Future<_RecoveredJournal> _recoverJournal({
  required Directory directory,
  required String journalFileName,
  required String acknowledgementFileName,
  required int maxPendingBytes,
  required int maxJournalBytes,
  required int maxSegmentBytes,
}) async {
  final _AcknowledgementState acknowledgement = await _recoverAcknowledgement(
    directory,
    journalFileName,
    acknowledgementFileName,
  );
  final List<_JournalSegment> discoveredSegments = await _listJournalSegments(
    directory,
    journalFileName,
  );
  final List<_JournalSegment> segments = <_JournalSegment>[];
  final List<_JournalFrame> frames = <_JournalFrame>[];
  final int safeReclamationSequence = acknowledgement.safeReclamationSequence;
  int? previousEndSequence;
  var journalBytes = 0;

  for (final _JournalSegment segment in discoveredSegments) {
    final int segmentLength = await File(segment.path).length();
    if (segmentLength > maxSegmentBytes) {
      throw FileStorePersistenceException(
        'Journal segment ${_baseName(segment.path)} exceeds maxSegmentBytes.',
      );
    }
    final List<_JournalFrame> segmentFrames = await _scanJournalSegment(
      segment,
      maxSegmentBytes: maxSegmentBytes,
    );
    final int? previous = previousEndSequence;
    if (previous == null) {
      if (segment.startSequence > acknowledgement.sequence + 1) {
        throw const FileStorePersistenceException(
          'Journal segments omit unacknowledged capture sequences.',
        );
      }
    } else if (segment.startSequence <= previous ||
        (segment.startSequence != previous + 1 &&
            segment.startSequence - 1 > acknowledgement.sequence)) {
      throw const FileStorePersistenceException(
        'Journal segment sequences are overlapping or omit unacknowledged '
        'captures.',
      );
    }
    previousEndSequence = segment.endSequence;
    if (segment.endSequence! <= safeReclamationSequence) {
      try {
        await File(segment.path).delete();
        continue;
      } on FileSystemException {
        // The acknowledgement is durable. Retain the segment and charge its
        // bytes until a later acknowledgement or recovery can delete it.
      }
    }
    journalBytes += segment.byteLength;
    if (journalBytes > maxJournalBytes) {
      throw const FileStorePersistenceException(
        'Recovered journal segments exceed maxJournalBytes.',
      );
    }
    segments.add(segment);
    frames.addAll(segmentFrames);
  }

  if (acknowledgement.sequence > 0 &&
      (frames.isEmpty || acknowledgement.sequence > frames.last.sequence)) {
    throw const FileStorePersistenceException(
      'Acknowledgement progress is beyond the retained journal.',
    );
  }

  final List<_JournalFrame> pendingFrames = <_JournalFrame>[];
  var pendingBytes = 0;
  for (final _JournalFrame frame in frames) {
    if (frame.sequence <= acknowledgement.sequence) {
      continue;
    }
    if (pendingBytes > maxPendingBytes - frame.payloadLength) {
      throw const FileStorePersistenceException(
        'Recovered unacknowledged captures exceed maxPendingBytes.',
      );
    }
    pendingBytes += frame.payloadLength;
    pendingFrames.add(frame);
  }

  final int highestSequence = frames.isEmpty
      ? acknowledgement.sequence
      : frames.last.sequence > acknowledgement.sequence
          ? frames.last.sequence
          : acknowledgement.sequence;
  final int nextSequence = highestSequence + 1;
  if (nextSequence > _maximumPortableSequence) {
    throw const FileStorePersistenceException(
      'The journal has exhausted portable capture sequence numbers.',
    );
  }
  return _RecoveredJournal(
    segments: segments,
    pendingFrames: pendingFrames,
    pendingBytes: pendingBytes,
    journalBytes: journalBytes,
    nextSequence: nextSequence,
    acknowledgedSequence: acknowledgement.sequence,
    nextAcknowledgementGeneration: acknowledgement.nextGeneration,
    nextAcknowledgementSlot: acknowledgement.nextSlot,
    acknowledgementSequences: acknowledgement.sequences,
  );
}

Future<List<_JournalSegment>> _listJournalSegments(
  Directory directory,
  String journalFileName,
) async {
  final Directory segmentDirectory = Directory(
    _segmentDirectoryPath(directory.path, journalFileName),
  );
  if (!await segmentDirectory.exists()) {
    return <_JournalSegment>[];
  }
  final List<_JournalSegment> segments = <_JournalSegment>[];
  await for (final FileSystemEntity entity
      in segmentDirectory.list(followLinks: false)) {
    if (entity is! File) {
      throw const FileStorePersistenceException(
        'The journal segment directory contains a non-file entry.',
      );
    }
    final int? startSequence =
        _segmentStartFromFileName(_baseName(entity.path));
    if (startSequence == null) {
      throw FileStorePersistenceException(
        'Unexpected journal segment file ${_baseName(entity.path)}.',
      );
    }
    segments.add(
      _JournalSegment(
        path: entity.path,
        startSequence: startSequence,
        byteLength: 0,
      ),
    );
  }
  segments.sort(
    (_JournalSegment left, _JournalSegment right) =>
        left.startSequence.compareTo(right.startSequence),
  );
  for (var index = 1; index < segments.length; index++) {
    if (segments[index - 1].startSequence == segments[index].startSequence) {
      throw const FileStorePersistenceException(
        'Journal segment names repeat a capture sequence.',
      );
    }
  }
  return segments;
}

Future<List<_JournalFrame>> _scanJournalSegment(
  _JournalSegment segment, {
  required int maxSegmentBytes,
}) async {
  final RandomAccessFile input = await File(segment.path).open(
    mode: FileMode.read,
  );
  try {
    final int length = await input.length();
    if (length < _segmentHeaderLength) {
      throw const FileStorePersistenceException(
        'A journal segment ends in a truncated header.',
      );
    }
    if (length > maxSegmentBytes) {
      throw FileStorePersistenceException(
        'Journal segment ${_baseName(segment.path)} exceeds maxSegmentBytes.',
      );
    }
    await input.setPosition(0);
    final Uint8List segmentHeader = await input.read(_segmentHeaderLength);
    if (segmentHeader.lengthInBytes != _segmentHeaderLength ||
        _decodeSegmentHeader(segmentHeader) != segment.startSequence) {
      throw const FileStorePersistenceException(
        'A journal segment header does not match its file name.',
      );
    }

    var offset = _segmentHeaderLength;
    var expectedSequence = segment.startSequence;
    final List<_JournalFrame> frames = <_JournalFrame>[];
    while (offset < length) {
      if (length - offset < _journalFrameHeaderLength) {
        throw const FileStorePersistenceException(
          'A journal segment ends in a truncated frame header.',
        );
      }
      await input.setPosition(offset);
      final Uint8List header = await input.read(_journalFrameHeaderLength);
      if (header.lengthInBytes != _journalFrameHeaderLength) {
        throw const FileStorePersistenceException(
          'Unable to read a complete journal frame header.',
        );
      }
      final _DecodedJournalHeader decoded = _decodeJournalHeader(header);
      if (decoded.sequence != expectedSequence) {
        throw FileStorePersistenceException(
          'Journal sequence ${decoded.sequence} is not the expected '
          '$expectedSequence.',
        );
      }
      if (decoded.payloadLength > length - offset - _journalFrameHeaderLength) {
        throw const FileStorePersistenceException(
          'A journal segment ends in a truncated capture payload.',
        );
      }
      final int payloadOffset = offset + _journalFrameHeaderLength;
      final Uint8List payload = await input.read(decoded.payloadLength);
      if (payload.lengthInBytes != decoded.payloadLength ||
          _checksum(payload) != decoded.checksum) {
        throw const FileStorePersistenceException(
          'A journal capture checksum does not match.',
        );
      }
      try {
        StoreCaptureCodec.decode(payload);
      } on Object catch (error, stackTrace) {
        throw FileStorePersistenceException(
          'A journal capture is not a valid PulseStore capture: $error',
          stackTrace.toString(),
        );
      }
      frames.add(
        _JournalFrame(
          sequence: decoded.sequence,
          segment: segment,
          payloadOffset: payloadOffset,
          payloadLength: decoded.payloadLength,
          checksum: decoded.checksum,
        ),
      );
      offset = payloadOffset + decoded.payloadLength;
      expectedSequence++;
    }
    if (frames.isEmpty) {
      throw const FileStorePersistenceException(
        'A journal segment contains no complete capture frame.',
      );
    }
    segment.byteLength = length;
    segment.endSequence = expectedSequence - 1;
    return frames;
  } finally {
    await input.close();
  }
}

Future<_AcknowledgementState> _recoverAcknowledgement(
  Directory directory,
  String journalFileName,
  String acknowledgementFileName,
) async {
  final List<_AcknowledgementCheckpoint> checkpoints =
      <_AcknowledgementCheckpoint>[];
  final List<int?> sequences = List<int?>.filled(
    _acknowledgementCheckpointCount,
    null,
  );
  var foundCheckpointFile = false;
  for (var slot = 0; slot < _acknowledgementCheckpointCount; slot++) {
    final File file = File(
      _acknowledgementCheckpointPath(
        directory.path,
        journalFileName,
        acknowledgementFileName,
        slot,
      ),
    );
    if (!await file.exists()) {
      continue;
    }
    foundCheckpointFile = true;
    try {
      final _AcknowledgementCheckpoint checkpoint = _decodeAcknowledgement(
        await _readAcknowledgementCheckpoint(file),
        expectedSlot: slot,
      );
      checkpoints.add(checkpoint);
      sequences[slot] = checkpoint.sequence;
    } on FileStorePersistenceException {
      // A torn newest checkpoint can fall back to the other valid slot and
      // replay an already processed batch. That is safe at-least-once recovery.
    }
  }
  if (checkpoints.isEmpty) {
    if (foundCheckpointFile) {
      throw const FileStorePersistenceException(
        'No acknowledgement checkpoint is valid.',
      );
    }
    return _AcknowledgementState(
      sequence: 0,
      nextGeneration: 1,
      nextSlot: 0,
      sequences: sequences,
    );
  }
  checkpoints.sort(
    (_AcknowledgementCheckpoint left, _AcknowledgementCheckpoint right) =>
        left.generation.compareTo(right.generation),
  );
  final _AcknowledgementCheckpoint latest = checkpoints.last;
  _AcknowledgementCheckpoint? previous;
  for (final _AcknowledgementCheckpoint checkpoint in checkpoints) {
    final _AcknowledgementCheckpoint? earlier = previous;
    if (earlier != null &&
        (checkpoint.generation <= earlier.generation ||
            checkpoint.sequence <= earlier.sequence)) {
      throw const FileStorePersistenceException(
        'Acknowledgement checkpoint progress is not strictly ordered.',
      );
    }
    previous = checkpoint;
  }
  return _AcknowledgementState(
    sequence: latest.sequence,
    nextGeneration: latest.generation + 1,
    nextSlot: (latest.slot + 1) % _acknowledgementCheckpointCount,
    sequences: sequences,
  );
}

Future<Uint8List> _readAcknowledgementCheckpoint(File file) async {
  final RandomAccessFile input = await file.open(mode: FileMode.read);
  try {
    if (await input.length() != _acknowledgementCheckpointLength) {
      throw const FileStorePersistenceException(
        'Invalid acknowledgement checkpoint length.',
      );
    }
    return await input.read(_acknowledgementCheckpointLength);
  } finally {
    await input.close();
  }
}

Future<void> _rejectLegacyJournalFiles(
  Directory directory,
  String journalFileName,
  String acknowledgementFileName,
) async {
  final List<File> legacyFiles = <File>[
    File(_joinPath(directory.path, journalFileName)),
    File(_joinPath(directory.path, acknowledgementFileName)),
    File(_joinPath(directory.path, '$acknowledgementFileName.a')),
    File(_joinPath(directory.path, '$acknowledgementFileName.b')),
  ];
  for (final File legacyFile in legacyFiles) {
    if (!await legacyFile.exists()) {
      continue;
    }
    throw const FileStorePersistenceException(
      'An unsupported unscoped journal or acknowledgement file is present. '
      'Open it with the earlier backend before migrating.',
    );
  }
}

Uint8List _encodeJournalHeader(
  int sequence,
  int payloadLength,
  int checksum,
) {
  final Uint8List bytes = Uint8List(_journalFrameHeaderLength);
  final ByteData data = ByteData.sublistView(bytes);
  data.setUint32(0, _journalMagic, Endian.big);
  data.setUint8(4, _fileFormatVersion);
  data.setUint8(5, 0);
  data.setUint16(6, 0, Endian.big);
  data.setUint64(8, sequence, Endian.big);
  data.setUint32(16, payloadLength, Endian.big);
  data.setUint32(20, checksum, Endian.big);
  return bytes;
}

Uint8List _encodeSegmentHeader(int firstSequence) {
  final Uint8List bytes = Uint8List(_segmentHeaderLength);
  final ByteData data = ByteData.sublistView(bytes);
  data.setUint32(0, _segmentMagic, Endian.big);
  data.setUint8(4, _fileFormatVersion);
  data.setUint8(5, 0);
  data.setUint16(6, 0, Endian.big);
  data.setUint64(8, firstSequence, Endian.big);
  data.setUint32(16, _checksumRange(bytes, 0, 16), Endian.big);
  data.setUint32(20, 0, Endian.big);
  return bytes;
}

int _decodeSegmentHeader(Uint8List bytes) {
  if (bytes.lengthInBytes != _segmentHeaderLength) {
    throw const FileStorePersistenceException(
      'Invalid journal segment header.',
    );
  }
  final ByteData data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.big) != _segmentMagic ||
      data.getUint8(4) != _fileFormatVersion ||
      data.getUint8(5) != 0 ||
      data.getUint16(6, Endian.big) != 0 ||
      data.getUint32(16, Endian.big) != _checksumRange(bytes, 0, 16) ||
      data.getUint32(20, Endian.big) != 0) {
    throw const FileStorePersistenceException(
      'Unsupported or corrupt journal segment header.',
    );
  }
  final int sequence = data.getUint64(8, Endian.big);
  if (sequence <= 0 || sequence > _maximumPortableSequence) {
    throw const FileStorePersistenceException(
      'Invalid journal segment first sequence.',
    );
  }
  return sequence;
}

final class _DecodedJournalHeader {
  const _DecodedJournalHeader({
    required this.sequence,
    required this.payloadLength,
    required this.checksum,
  });

  final int sequence;
  final int payloadLength;
  final int checksum;
}

_DecodedJournalHeader _decodeJournalHeader(Uint8List bytes) {
  if (bytes.lengthInBytes != _journalFrameHeaderLength) {
    throw const FileStorePersistenceException('Invalid journal frame header.');
  }
  final ByteData data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.big) != _journalMagic ||
      data.getUint8(4) != _fileFormatVersion ||
      data.getUint8(5) != 0 ||
      data.getUint16(6, Endian.big) != 0) {
    throw const FileStorePersistenceException('Unsupported journal frame.');
  }
  final int sequence = data.getUint64(8, Endian.big);
  if (sequence <= 0 || sequence > _maximumPortableSequence) {
    throw const FileStorePersistenceException('Invalid journal sequence.');
  }
  return _DecodedJournalHeader(
    sequence: sequence,
    payloadLength: data.getUint32(16, Endian.big),
    checksum: data.getUint32(20, Endian.big),
  );
}

Uint8List _encodeAcknowledgement({
  required int slot,
  required int generation,
  required int sequence,
}) {
  if (slot < 0 ||
      slot >= _acknowledgementCheckpointCount ||
      generation <= 0 ||
      generation > _maximumPortableSequence ||
      sequence <= 0 ||
      sequence > _maximumPortableSequence) {
    throw const FileStorePersistenceException(
      'Invalid acknowledgement checkpoint values.',
    );
  }
  final Uint8List bytes = Uint8List(_acknowledgementCheckpointLength);
  final ByteData data = ByteData.sublistView(bytes);
  data.setUint32(0, _acknowledgementMagic, Endian.big);
  data.setUint8(4, _fileFormatVersion);
  data.setUint8(5, slot);
  data.setUint16(6, 0, Endian.big);
  data.setUint64(8, generation, Endian.big);
  data.setUint64(16, sequence, Endian.big);
  data.setUint32(24, _checksumRange(bytes, 0, 24), Endian.big);
  data.setUint32(28, 0, Endian.big);
  return bytes;
}

final class _AcknowledgementCheckpoint {
  const _AcknowledgementCheckpoint({
    required this.slot,
    required this.generation,
    required this.sequence,
  });

  final int slot;
  final int generation;
  final int sequence;
}

final class _AcknowledgementState {
  const _AcknowledgementState({
    required this.sequence,
    required this.nextGeneration,
    required this.nextSlot,
    required this.sequences,
  });

  final int sequence;
  final int nextGeneration;
  final int nextSlot;
  final List<int?> sequences;

  int get safeReclamationSequence {
    int? lowest;
    for (final int? sequence in sequences) {
      if (sequence == null) {
        return 0;
      }
      if (lowest == null || sequence < lowest) {
        lowest = sequence;
      }
    }
    return lowest ?? 0;
  }
}

_AcknowledgementCheckpoint _decodeAcknowledgement(
  Uint8List bytes, {
  required int expectedSlot,
}) {
  if (bytes.lengthInBytes != _acknowledgementCheckpointLength) {
    throw const FileStorePersistenceException(
      'Invalid acknowledgement checkpoint length.',
    );
  }
  final ByteData data = ByteData.sublistView(bytes);
  if (data.getUint32(0, Endian.big) != _acknowledgementMagic ||
      data.getUint8(4) != _fileFormatVersion ||
      data.getUint8(5) != expectedSlot ||
      data.getUint16(6, Endian.big) != 0 ||
      data.getUint32(24, Endian.big) != _checksumRange(bytes, 0, 24) ||
      data.getUint32(28, Endian.big) != 0) {
    throw const FileStorePersistenceException(
      'Invalid acknowledgement checkpoint.',
    );
  }
  final int generation = data.getUint64(8, Endian.big);
  final int sequence = data.getUint64(16, Endian.big);
  if (generation <= 0 ||
      generation > _maximumPortableSequence ||
      sequence <= 0 ||
      sequence > _maximumPortableSequence) {
    throw const FileStorePersistenceException(
      'Invalid acknowledgement checkpoint sequence.',
    );
  }
  return _AcknowledgementCheckpoint(
    slot: expectedSlot,
    generation: generation,
    sequence: sequence,
  );
}

int _checksum(Uint8List bytes) => _checksumRange(bytes, 0, bytes.lengthInBytes);

int _checksumRange(Uint8List bytes, int start, int end) {
  var value = 0x811c9dc5;
  for (var index = start; index < end; index++) {
    value ^= bytes[index];
    value = (value * 0x01000193) & 0xffffffff;
  }
  return value;
}

String _joinPath(String directory, String fileName) =>
    '$directory${Platform.pathSeparator}$fileName';

String _segmentDirectoryPath(String directory, String journalFileName) =>
    _joinPath(directory, '$journalFileName.segments');

String _journalMetadataDirectoryPath(
  String directory,
  String journalFileName,
) =>
    _joinPath(directory, '$journalFileName.metadata');

String _segmentFileName(int firstSequence) =>
    'segment-${firstSequence.toString().padLeft(16, '0')}.psjs';

int? _segmentStartFromFileName(String value) {
  final RegExpMatch? match = RegExp(
    r'^segment-([0-9]{16})\.psjs$',
  ).firstMatch(value);
  if (match == null) {
    return null;
  }
  final int? sequence = int.tryParse(match.group(1)!);
  if (sequence == null ||
      sequence <= 0 ||
      sequence > _maximumPortableSequence) {
    return null;
  }
  return sequence;
}

String _acknowledgementCheckpointPath(
  String directory,
  String journalFileName,
  String acknowledgementFileName,
  int slot,
) =>
    _joinPath(
      _journalMetadataDirectoryPath(directory, journalFileName),
      '$acknowledgementFileName.${slot == 0 ? 'a' : 'b'}',
    );

String _baseName(String path) {
  var separator = path.lastIndexOf('/');
  final int backslash = path.lastIndexOf('\\');
  if (backslash > separator) {
    separator = backslash;
  }
  return separator < 0 ? path : path.substring(separator + 1);
}

String _journalPathKey(Directory directory, String journalFileName) =>
    _joinPath(directory.absolute.path, journalFileName);

Future<void> _closeQuietly(RandomAccessFile? file) async {
  if (file == null) {
    return;
  }
  try {
    await file.close();
  } on Object {
    // The original open failure is more useful to the caller.
  }
}

void _validateFileName(String value, String name) {
  if (value.trim().isEmpty ||
      value.contains('/') ||
      value.contains('\\') ||
      value == '.' ||
      value == '..') {
    throw ArgumentError.value(
      value,
      name,
      'Must be a simple non-empty file name.',
    );
  }
}
