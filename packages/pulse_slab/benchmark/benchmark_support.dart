import 'dart:math';

/// Machine-specific measurement emitted by the benchmark executable.
final class BenchmarkResult {
  /// Creates one benchmark result.
  const BenchmarkResult({
    required this.name,
    required this.operations,
    required this.elapsed,
    required this.emittedNotifications,
    required this.coalescedNotifications,
    required this.checksum,
  });

  /// Descriptive workload name.
  final String name;

  /// Number of primary operations attempted.
  final int operations;

  /// Elapsed wall-clock duration.
  final Duration elapsed;

  /// Number of listener calls observed by the workload.
  final int emittedNotifications;

  /// Number of accepted changes intentionally merged before delivery.
  final int coalescedNotifications;

  /// A deterministic sink that helps prevent dead-code elimination.
  final int checksum;

  /// Primary operations per second.
  double get operationsPerSecond {
    final microseconds = elapsed.inMicroseconds;
    if (microseconds == 0) {
      return double.infinity;
    }
    return operations * Duration.microsecondsPerSecond / microseconds;
  }

  /// Writes a stable, human-readable result line.
  void printReport() {
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    print(
      '${name.padRight(34)} '
      '${seconds.toStringAsFixed(3)} s  '
      '${operationsPerSecond.toStringAsFixed(0)} ops/s  '
      'emitted=$emittedNotifications  '
      'coalesced=$coalescedNotifications  '
      'checksum=$checksum',
    );
  }
}

/// Times [body] after an optional warmup.
///
/// The Dart VM does not expose a portable, per-scope allocation counter. The
/// executable reports that limitation instead of inventing an allocation value.
BenchmarkResult measureBenchmark({
  required String name,
  required int operations,
  required BenchmarkWork body,
  int warmupOperations = 0,
}) {
  if (operations <= 0) {
    throw ArgumentError.value(
      operations,
      'operations',
      'Must be greater than zero.',
    );
  }

  if (warmupOperations > 0) {
    body(warmupOperations);
  }

  final stopwatch = Stopwatch()..start();
  final BenchmarkWorkResult workResult = body(operations);
  stopwatch.stop();

  return BenchmarkResult(
    name: name,
    operations: operations,
    elapsed: stopwatch.elapsed,
    emittedNotifications: workResult.emittedNotifications,
    coalescedNotifications: workResult.coalescedNotifications,
    checksum: workResult.checksum,
  );
}

/// Signature for a workload that can be warmed up and measured.
typedef BenchmarkWork = BenchmarkWorkResult Function(int operations);

/// Counters returned by one benchmark workload.
final class BenchmarkWorkResult {
  /// Creates a benchmark work result.
  const BenchmarkWorkResult({
    required this.emittedNotifications,
    required this.coalescedNotifications,
    required this.checksum,
  });

  /// Listener notifications delivered during the workload.
  final int emittedNotifications;

  /// State updates intentionally merged before delivery.
  final int coalescedNotifications;

  /// Deterministic side-effect sink.
  final int checksum;
}

/// A small mutable object model used as a conventional baseline.
final class ObjectBaselineRecord {
  /// Scalar value.
  double value = 0;

  /// Scalar status.
  int status = 0;
}

/// A minimal callback-list baseline resembling a ChangeNotifier.
///
/// It intentionally copies its listener list during notification so listener
/// removal during callbacks is safe. This is a benchmark baseline, not a
/// replacement for Flutter's ChangeNotifier.
final class ChangeNotifierStyleBaseline {
  final List<void Function()> _listeners = <void Function()>[];

  /// Adds a callback.
  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  /// Removes a callback.
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  /// Notifies a stable snapshot of callbacks.
  void notifyListeners() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }
}

/// A seeded source of deterministic record indexes and values.
final class DeterministicWorkload {
  /// Creates a deterministic workload generator.
  DeterministicWorkload([int seed = 17]) : _random = Random(seed);

  final Random _random;

  /// Returns an index in `[0, upperBound)`.
  int nextIndex(int upperBound) => _random.nextInt(upperBound);

  /// Returns a representative telemetry value.
  double nextValue() => _random.nextDouble() * 250 - 80;
}
