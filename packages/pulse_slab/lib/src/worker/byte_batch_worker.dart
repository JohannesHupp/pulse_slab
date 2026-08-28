import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

/// Selects the built-in operation performed by [ByteBatchWorker].
///
/// The worker deliberately supports a small, sendable configuration rather
/// than accepting an arbitrary callback. Arbitrary closures are not a sound
/// isolate API because they can capture main-isolate state.
enum ByteBatchTransform {
  /// Return the batch after calculating a checksum.
  passthrough,

  /// Require complete fixed-width frames, then return the batch and checksum.
  frameChecksum,
}

/// Immutable configuration for a long-lived [ByteBatchWorker].
final class ByteBatchWorkerConfig {
  /// Creates worker configuration.
  const ByteBatchWorkerConfig({
    this.transform = ByteBatchTransform.passthrough,
    this.frameSize = 1,
    this.maxInFlight = 2,
  })  : assert(frameSize > 0),
        assert(maxInFlight > 0),
        _frameSizeIsValid = frameSize > 0,
        _maxInFlightIsValid = maxInFlight > 0;

  /// The operation applied to each submitted batch.
  final ByteBatchTransform transform;

  /// The required frame size for [ByteBatchTransform.frameChecksum].
  final int frameSize;

  /// The maximum number of submitted batches that have not completed.
  final int maxInFlight;

  final bool _frameSizeIsValid;
  final bool _maxInFlightIsValid;

  void _validate() {
    if (!_frameSizeIsValid) {
      throw ArgumentError.value(
        frameSize,
        'frameSize',
        'Must be greater than zero.',
      );
    }
    if (!_maxInFlightIsValid) {
      throw ArgumentError.value(
        maxInFlight,
        'maxInFlight',
        'Must be greater than zero.',
      );
    }
  }
}

/// A processed byte batch returned by [ByteBatchWorker].
///
/// [bytes] is a zero-copy typed view over the materialized transferred buffer.
/// It is not shared mutable memory with the worker isolate.
final class ByteBatchResult {
  const ByteBatchResult({
    required this.sequence,
    required this.bytes,
    required this.checksum,
    required this.frameCount,
  });

  /// Monotonically increasing sequence assigned by the submitting isolate.
  final int sequence;

  /// The processed bytes owned by the receiving isolate.
  final Uint8List bytes;

  /// A deterministic checksum over [bytes].
  final int checksum;

  /// The number of frames processed by the configured operation.
  final int frameCount;
}

/// Thrown when an operation cannot be accepted without exceeding the bounded
/// worker queue.
final class WorkerBackpressureException implements Exception {
  const WorkerBackpressureException(this.maxInFlight);

  /// The configured in-flight limit.
  final int maxInFlight;

  @override
  String toString() {
    return 'WorkerBackpressureException: maximum in-flight batch count '
        '($maxInFlight) has been reached.';
  }
}

/// Thrown when the worker exits unexpectedly or rejects an individual batch.
final class ByteBatchWorkerException implements Exception {
  const ByteBatchWorkerException(this.message, [this.remoteStackTrace]);

  /// The error text produced by the worker.
  final String message;

  /// The stack trace captured in the worker, when available.
  final String? remoteStackTrace;

  @override
  String toString() {
    final stackTrace = remoteStackTrace;
    if (stackTrace == null || stackTrace.isEmpty) {
      return 'ByteBatchWorkerException: $message';
    }
    return 'ByteBatchWorkerException: $message\n$stackTrace';
  }
}

/// A bounded, long-lived worker isolate for raw byte batches.
///
/// The worker owns all decoded input while processing it. Batches cross the
/// isolate boundary through [TransferableTypedData], which transfers a binary
/// payload but does not turn ordinary Dart memory into shared memory. A caller
/// should use [inFlight] to apply its own source-level backpressure policy.
final class ByteBatchWorker {
  ByteBatchWorker._(this.config)
      : _responsePort = ReceivePort(),
        _errorPort = ReceivePort(),
        _exitPort = ReceivePort() {
    _responseSubscription = _responsePort.listen(_onResponse);
    _errorSubscription = _errorPort.listen(_onIsolateError);
    _exitSubscription = _exitPort.listen(_onIsolateExit);
  }

  /// Starts a worker isolate and waits until it is ready to accept batches.
  static Future<ByteBatchWorker> start({
    ByteBatchWorkerConfig config = const ByteBatchWorkerConfig(),
  }) async {
    config._validate();
    final worker = ByteBatchWorker._(config);
    await worker._launch();
    return worker;
  }

  /// Worker configuration.
  final ByteBatchWorkerConfig config;

  final ReceivePort _responsePort;
  final ReceivePort _errorPort;
  final ReceivePort _exitPort;
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Completer<void> _stopped = Completer<void>();
  final Map<int, Completer<ByteBatchResult>> _pending =
      <int, Completer<ByteBatchResult>>{};

  late final StreamSubscription<dynamic> _responseSubscription;
  late final StreamSubscription<dynamic> _errorSubscription;
  late final StreamSubscription<dynamic> _exitSubscription;
  SendPort? _commandPort;
  Future<void>? _closeFuture;
  var _nextSequence = 0;
  var _closing = false;
  var _failed = false;

  /// Number of submitted batches that have not completed.
  int get inFlight => _pending.length;

  /// Whether [close] has been requested.
  bool get isClosing => _closing;

  Future<void> _launch() async {
    try {
      await Isolate.spawn<Map<String, Object?>>(
        _workerMain,
        <String, Object?>{
          'replyTo': _responsePort.sendPort,
          'transform': config.transform.index,
          'frameSize': config.frameSize,
        },
        onError: _errorPort.sendPort,
        onExit: _exitPort.sendPort,
        errorsAreFatal: true,
        debugName: 'pulse_slab.byte_batch_worker',
      );
    } on Object catch (error, stackTrace) {
      _failWorker(
        ByteBatchWorkerException(
          'Unable to start worker: $error',
          stackTrace.toString(),
        ),
      );
    }
    await _ready.future;
  }

  /// Submits [bytes] for background processing.
  ///
  /// The returned future completes with a worker error when the configured
  /// operation rejects this specific batch. It throws [WorkerBackpressureException]
  /// synchronously before allocating a queued task when the bounded limit is full.
  Future<ByteBatchResult> submit(Uint8List bytes) {
    final commandPort = _commandPort;
    if (_closing) {
      throw StateError('The byte batch worker is closing or already closed.');
    }
    if (_failed || commandPort == null) {
      throw StateError('The byte batch worker is not ready.');
    }
    if (_pending.length >= config.maxInFlight) {
      throw WorkerBackpressureException(config.maxInFlight);
    }

    final sequence = _nextSequence++;
    final completer = Completer<ByteBatchResult>();
    _pending[sequence] = completer;
    commandPort.send(<String, Object?>{
      'type': 'batch',
      'sequence': sequence,
      'bytes': TransferableTypedData.fromList(<Uint8List>[bytes]),
    });
    return completer.future;
  }

  /// Stops accepting work and shuts the worker down after already submitted
  /// messages have been processed in receive-port order.
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) {
      return existing;
    }

    _closing = true;
    final commandPort = _commandPort;
    if (commandPort == null) {
      _closeFuture = _stopped.future.whenComplete(_disposePorts);
      return _closeFuture!;
    }
    commandPort.send(const <String, Object?>{'type': 'shutdown'});
    _closeFuture = _stopped.future.whenComplete(_disposePorts);
    return _closeFuture!;
  }

  void _onResponse(dynamic message) {
    if (message is! Map<Object?, Object?>) {
      _failWorker(
        const ByteBatchWorkerException('Worker sent an invalid response.'),
      );
      return;
    }
    final type = message['type'];
    if (type == 'ready') {
      final commandPort = message['commandPort'];
      if (commandPort is! SendPort) {
        _failWorker(
          const ByteBatchWorkerException(
            'Worker did not provide a command port.',
          ),
        );
        return;
      }
      _commandPort = commandPort;
      if (!_ready.isCompleted) {
        _ready.complete(commandPort);
      }
      return;
    }
    if (type == 'result') {
      _completeResult(message);
      return;
    }
    if (type == 'failure') {
      _completeFailure(message);
      return;
    }
    if (type == 'stopped') {
      _completeStopped();
      return;
    }
    _failWorker(
      const ByteBatchWorkerException('Worker sent an unknown response type.'),
    );
  }

  void _completeResult(Map<Object?, Object?> message) {
    final sequence = message['sequence'];
    final data = message['bytes'];
    final checksum = message['checksum'];
    final frameCount = message['frameCount'];
    if (sequence is! int ||
        data is! TransferableTypedData ||
        checksum is! int ||
        frameCount is! int) {
      _failWorker(
        const ByteBatchWorkerException('Worker sent an invalid result.'),
      );
      return;
    }
    final completer = _pending.remove(sequence);
    if (completer == null) {
      return;
    }
    final bytes = data.materialize().asUint8List();
    completer.complete(
      ByteBatchResult(
        sequence: sequence,
        bytes: bytes,
        checksum: checksum,
        frameCount: frameCount,
      ),
    );
  }

  void _completeFailure(Map<Object?, Object?> message) {
    final sequence = message['sequence'];
    final error = message['error'];
    final stackTrace = message['stackTrace'];
    if (sequence is! int || error is! String || stackTrace is! String) {
      _failWorker(
        const ByteBatchWorkerException('Worker sent an invalid failure.'),
      );
      return;
    }
    final completer = _pending.remove(sequence);
    completer?.completeError(ByteBatchWorkerException(error, stackTrace));
  }

  void _onIsolateError(dynamic message) {
    if (message is List<Object?> && message.isNotEmpty) {
      final error = message.first;
      final stackTrace = message.length > 1 ? message[1] : null;
      _failWorker(
        ByteBatchWorkerException(
          'Worker isolate failed: $error',
          stackTrace?.toString(),
        ),
      );
      return;
    }
    _failWorker(ByteBatchWorkerException('Worker isolate failed: $message'));
  }

  void _onIsolateExit(dynamic _) {
    if (_stopped.isCompleted) {
      return;
    }
    if (_closing) {
      _completeStopped();
      return;
    }
    _failWorker(
      const ByteBatchWorkerException('Worker isolate exited unexpectedly.'),
    );
  }

  void _completeStopped() {
    if (_stopped.isCompleted) {
      return;
    }
    if (_pending.isNotEmpty) {
      final error = const ByteBatchWorkerException(
        'Worker stopped before all submitted batches completed.',
      );
      for (final completer in _pending.values) {
        completer.completeError(error);
      }
      _pending.clear();
    }
    _stopped.complete();
  }

  void _failWorker(ByteBatchWorkerException error) {
    if (_failed) {
      return;
    }
    _failed = true;
    if (!_ready.isCompleted) {
      _ready.completeError(error);
    }
    for (final completer in _pending.values) {
      completer.completeError(error);
    }
    _pending.clear();
    if (!_stopped.isCompleted) {
      _stopped.completeError(error);
    }
  }

  Future<void> _disposePorts() async {
    _responsePort.close();
    _errorPort.close();
    _exitPort.close();
    await Future.wait<void>(<Future<void>>[
      _responseSubscription.cancel(),
      _errorSubscription.cancel(),
      _exitSubscription.cancel(),
    ]);
  }
}

void _workerMain(Map<String, Object?> bootstrap) {
  final replyTo = bootstrap['replyTo'];
  final transformIndex = bootstrap['transform'];
  final frameSize = bootstrap['frameSize'];
  if (replyTo is! SendPort || transformIndex is! int || frameSize is! int) {
    throw ArgumentError('Invalid byte batch worker bootstrap message.');
  }
  if (transformIndex < 0 ||
      transformIndex >= ByteBatchTransform.values.length) {
    throw ArgumentError.value(
      transformIndex,
      'transform',
      'Unknown transform.',
    );
  }
  if (frameSize <= 0) {
    throw ArgumentError.value(
      frameSize,
      'frameSize',
      'Must be greater than zero.',
    );
  }

  final transform = ByteBatchTransform.values[transformIndex];
  final commandPort = ReceivePort();
  replyTo.send(<String, Object?>{
    'type': 'ready',
    'commandPort': commandPort.sendPort,
  });

  commandPort.listen((dynamic message) {
    if (message is! Map<Object?, Object?>) {
      return;
    }
    final type = message['type'];
    if (type == 'shutdown') {
      commandPort.close();
      replyTo.send(const <String, Object?>{'type': 'stopped'});
      return;
    }
    if (type != 'batch') {
      return;
    }

    final sequence = message['sequence'];
    final data = message['bytes'];
    if (sequence is! int || data is! TransferableTypedData) {
      return;
    }
    try {
      final bytes = data.materialize().asUint8List();
      final checksum = _checksum(bytes, transform, frameSize);
      final frameCount = transform == ByteBatchTransform.frameChecksum
          ? bytes.lengthInBytes ~/ frameSize
          : 1;
      replyTo.send(<String, Object?>{
        'type': 'result',
        'sequence': sequence,
        'bytes': TransferableTypedData.fromList(<Uint8List>[bytes]),
        'checksum': checksum,
        'frameCount': frameCount,
      });
    } on Object catch (error, stackTrace) {
      replyTo.send(<String, Object?>{
        'type': 'failure',
        'sequence': sequence,
        'error': error.toString(),
        'stackTrace': stackTrace.toString(),
      });
    }
  });
}

int _checksum(Uint8List bytes, ByteBatchTransform transform, int frameSize) {
  if (transform == ByteBatchTransform.frameChecksum &&
      bytes.lengthInBytes % frameSize != 0) {
    throw FormatException(
      'Byte batch length (${bytes.lengthInBytes}) is not divisible by frameSize ($frameSize).',
    );
  }

  var checksum = 0;
  for (final byte in bytes) {
    checksum = ((checksum * 31) + byte) & 0x7fffffff;
  }
  return checksum;
}
