import 'dart:ui' show FramePhase, FrameTiming, TimingsCallback;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Calculates a recent frames-per-second value from engine frame timestamps.
///
/// This class has no scheduler dependency, which keeps its timing behavior
/// deterministic in tests.
final class FrameRateAccumulator {
  /// Creates an accumulator that publishes a value after [window] elapsed.
  FrameRateAccumulator({this.window = const Duration(seconds: 1)}) {
    if (window.inMicroseconds <= 0) {
      throw ArgumentError.value(window, 'window', 'Must be positive.');
    }
  }

  /// Duration of the rolling measurement window.
  final Duration window;

  int? _windowStartMicroseconds;
  int? _lastTimestampMicroseconds;
  var _intervalCount = 0;

  /// Records one frame timestamp and returns a rounded FPS value when the
  /// measurement window has elapsed.
  ///
  /// Duplicate or out-of-order timestamps are ignored so an engine timing
  /// batch cannot distort the result.
  int? recordFrame(int timestampMicroseconds) {
    final windowStartMicroseconds = _windowStartMicroseconds;
    if (windowStartMicroseconds == null) {
      _windowStartMicroseconds = timestampMicroseconds;
      _lastTimestampMicroseconds = timestampMicroseconds;
      return null;
    }

    final lastTimestampMicroseconds = _lastTimestampMicroseconds!;
    if (timestampMicroseconds <= lastTimestampMicroseconds) {
      return null;
    }

    _lastTimestampMicroseconds = timestampMicroseconds;
    _intervalCount++;
    final elapsedMicroseconds = timestampMicroseconds - windowStartMicroseconds;
    if (elapsedMicroseconds < window.inMicroseconds) {
      return null;
    }

    final framesPerSecond =
        _intervalCount * Duration.microsecondsPerSecond / elapsedMicroseconds;
    _windowStartMicroseconds = timestampMicroseconds;
    _intervalCount = 0;
    return framesPerSecond.round();
  }

  /// Clears all timing state.
  void reset() {
    _windowStartMicroseconds = null;
    _lastTimestampMicroseconds = null;
    _intervalCount = 0;
  }
}

/// Registers a callback for engine frame timing batches.
typedef FrameTimingRegistrar = void Function(TimingsCallback callback);

/// Removes a callback previously registered for engine frame timing batches.
typedef FrameTimingRemover = void Function(TimingsCallback callback);

/// Owns a small, UI-facing rendered-frame-rate measurement.
///
/// Flutter batches engine timing records, so the displayed value is a recent
/// average rather than an instantaneous frame duration. It is most meaningful
/// in profile or release mode.
final class FrameRateMonitor {
  /// Creates a monitor without enabling timing observation yet.
  FrameRateMonitor({
    FrameTimingRegistrar? addTimingsCallback,
    FrameTimingRemover? removeTimingsCallback,
    FrameRateAccumulator? accumulator,
  })  : _addTimingsCallback =
            addTimingsCallback ?? SchedulerBinding.instance.addTimingsCallback,
        _removeTimingsCallback = removeTimingsCallback ??
            SchedulerBinding.instance.removeTimingsCallback,
        _accumulator = accumulator ?? FrameRateAccumulator();

  final FrameTimingRegistrar _addTimingsCallback;
  final FrameTimingRemover _removeTimingsCallback;
  final FrameRateAccumulator _accumulator;

  /// Recent rendered FPS, or `null` while paused or before the first sample.
  final ValueNotifier<int?> framesPerSecond = ValueNotifier<int?>(null);

  late final TimingsCallback _timingsCallback = _onFrameTimings;
  var _isActive = false;
  var _isDisposed = false;

  /// Starts engine timing observation.
  void start() {
    if (_isDisposed || _isActive) {
      return;
    }
    _accumulator.reset();
    framesPerSecond.value = null;
    _isActive = true;
    _addTimingsCallback(_timingsCallback);
  }

  /// Stops engine timing observation and clears the displayed value.
  void stop() {
    if (!_isActive) {
      return;
    }
    _removeTimingsCallback(_timingsCallback);
    _isActive = false;
    _accumulator.reset();
    framesPerSecond.value = null;
  }

  void _onFrameTimings(List<FrameTiming> timings) {
    if (_isDisposed || !_isActive) {
      return;
    }
    for (final timing in timings) {
      final framesPerSecond = _accumulator.recordFrame(
        timing.timestampInMicroseconds(FramePhase.vsyncStart),
      );
      if (framesPerSecond != null) {
        this.framesPerSecond.value = framesPerSecond;
      }
    }
  }

  /// Stops observation and releases the UI-facing notifier.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    stop();
    _isDisposed = true;
    framesPerSecond.dispose();
  }
}
