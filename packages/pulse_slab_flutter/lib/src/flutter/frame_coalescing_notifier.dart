import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Selects how an accepted store change becomes a Flutter notification.
enum FlutterDeliveryPolicy {
  /// Notify synchronously for each accepted change.
  immediate,

  /// Retain the latest state and notify at most once per rendered frame.
  frame,

  /// Retain the latest state until [FrameCoalescingNotifier.flush] is called.
  manual,
}

/// Schedules a callback for a future Flutter frame.
typedef FrameCallbackScheduler = int Function(FrameCallback callback);

/// Cancels a callback returned by [FrameCallbackScheduler].
typedef ScheduledFrameCanceller = void Function(int callbackId);

/// A lightweight [ChangeNotifier] that converts many compatible data-plane
/// changes into at most one UI-plane notification.
///
/// A core store should call [markChanged] only after a committed change. The
/// optional [fields] filter provides a second safety check; the store-level
/// subscription filter remains the primary way to avoid unnecessary work.
/// A field mask of zero means "all or unknown fields" for this adapter.
class FrameCoalescingNotifier extends ChangeNotifier {
  /// Creates a Flutter notification coalescer.
  FrameCoalescingNotifier({
    this.policy = FlutterDeliveryPolicy.frame,
    this.fields = 0,
    FrameCallbackScheduler? scheduleFrameCallback,
    ScheduledFrameCanceller? cancelFrameCallback,
  })  : _scheduleFrameCallback =
            scheduleFrameCallback ?? _defaultScheduleFrameCallback,
        _cancelFrameCallback =
            cancelFrameCallback ?? _defaultCancelFrameCallback;

  /// The UI delivery policy.
  final FlutterDeliveryPolicy policy;

  /// The field mask this notifier accepts; zero accepts all fields.
  final int fields;

  final FrameCallbackScheduler _scheduleFrameCallback;
  final ScheduledFrameCanceller _cancelFrameCallback;

  int? _scheduledFrameId;
  var _hasPending = false;
  var _isDisposed = false;
  int _pendingFieldMask = 0;
  int _lastDeliveredFieldMask = 0;
  int _acceptedChanges = 0;
  int _coalescedChanges = 0;
  int _deliveredNotifications = 0;

  /// Mask accumulated since the last delivery.
  int get pendingFieldMask => _pendingFieldMask;

  /// Mask delivered by the most recent [flush].
  int get lastDeliveredFieldMask => _lastDeliveredFieldMask;

  /// Number of accepted store changes since creation or [resetCounters].
  int get acceptedChanges => _acceptedChanges;

  /// Number of accepted changes merged into a pending UI notification.
  int get coalescedChanges => _coalescedChanges;

  /// Number of times listeners were notified.
  int get deliveredNotifications => _deliveredNotifications;

  /// Accepts one committed change with [changedFields].
  ///
  /// Calls after [dispose] are ignored. This makes a late callback from a
  /// disposing subscription harmless without retaining the widget tree.
  void markChanged(int changedFields) {
    if (_isDisposed || !_matches(changedFields)) {
      return;
    }

    _acceptedChanges++;
    if (_hasPending) {
      _coalescedChanges++;
    } else {
      _hasPending = true;
    }
    _pendingFieldMask |= changedFields;

    switch (policy) {
      case FlutterDeliveryPolicy.immediate:
        flush();
      case FlutterDeliveryPolicy.frame:
        _scheduleFrameFlush();
      case FlutterDeliveryPolicy.manual:
        break;
    }
  }

  /// Delivers the current pending change, if any.
  ///
  /// Returns true when listeners were notified. Manual mode uses this method
  /// for deterministic tests and externally controlled render loops.
  bool flush() {
    _cancelScheduledFrame();
    return _flushPending();
  }

  bool _flushPending() {
    if (_isDisposed || !_hasPending) {
      return false;
    }
    _hasPending = false;
    _lastDeliveredFieldMask = _pendingFieldMask;
    _pendingFieldMask = 0;
    _deliveredNotifications++;
    notifyListeners();
    return true;
  }

  /// Clears delivery counters without changing any pending state.
  void resetCounters() {
    _acceptedChanges = 0;
    _coalescedChanges = 0;
    _deliveredNotifications = 0;
  }

  bool _matches(int changedFields) {
    return fields == 0 || changedFields == 0 || (fields & changedFields) != 0;
  }

  void _scheduleFrameFlush() {
    if (_scheduledFrameId != null) {
      return;
    }
    _scheduledFrameId = _scheduleFrameCallback((_) {
      _scheduledFrameId = null;
      _flushPending();
    });
  }

  void _cancelScheduledFrame() {
    final scheduledFrameId = _scheduledFrameId;
    if (scheduledFrameId != null) {
      _cancelFrameCallback(scheduledFrameId);
      _scheduledFrameId = null;
    }
  }

  @override
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _cancelScheduledFrame();
    super.dispose();
  }

  static int _defaultScheduleFrameCallback(FrameCallback callback) {
    return SchedulerBinding.instance.scheduleFrameCallback(callback);
  }

  static void _defaultCancelFrameCallback(int callbackId) {
    SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
  }
}
