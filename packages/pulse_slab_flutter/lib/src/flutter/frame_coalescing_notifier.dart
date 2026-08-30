import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:pulse_slab/pulse_slab.dart';

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
/// For layouts with more than 31 fields, use the layout-scoped [selection]
/// filter and call [markChangedSelection]. A field mask of zero means "all or
/// unknown fields" for this adapter.
class FrameCoalescingNotifier extends ChangeNotifier {
  /// Creates a Flutter notification coalescer.
  FrameCoalescingNotifier({
    this.policy = FlutterDeliveryPolicy.frame,
    this.fields = 0,
    FieldSelection? selection,
    FrameCallbackScheduler? scheduleFrameCallback,
    ScheduledFrameCanceller? cancelFrameCallback,
  })  : selection = _validateSelection(fields, selection),
        _scheduleFrameCallback =
            scheduleFrameCallback ?? _defaultScheduleFrameCallback,
        _cancelFrameCallback =
            cancelFrameCallback ?? _defaultCancelFrameCallback;

  /// The UI delivery policy.
  final FlutterDeliveryPolicy policy;

  /// The field mask this notifier accepts; zero accepts all fields.
  final int fields;

  /// The layout-scoped field selection this notifier accepts.
  ///
  /// Use this instead of [fields] for layouts with more than 31 fields. It
  /// must not be combined with a nonzero [fields] filter.
  final FieldSelection? selection;

  final FrameCallbackScheduler _scheduleFrameCallback;
  final ScheduledFrameCanceller _cancelFrameCallback;

  int? _scheduledFrameId;
  var _hasPending = false;
  var _isDisposed = false;
  int _pendingFieldMask = 0;
  int _lastDeliveredFieldMask = 0;
  FieldSelection? _pendingFieldSelection;
  FieldSelection? _lastDeliveredFieldSelection;
  var _hasLegacyPendingChange = false;
  int _acceptedChanges = 0;
  int _coalescedChanges = 0;
  int _deliveredNotifications = 0;

  /// Mask accumulated since the last delivery.
  int get pendingFieldMask => _pendingFieldMask;

  /// Mask delivered by the most recent [flush].
  int get lastDeliveredFieldMask => _lastDeliveredFieldMask;

  /// Exact layout-scoped fields accumulated since the last delivery.
  ///
  /// This is null when no accepted selection change is pending, or when an
  /// integer-mask change has been coalesced into the same notification.
  FieldSelection? get pendingFieldSelection =>
      _hasLegacyPendingChange ? null : _pendingFieldSelection;

  /// Exact layout-scoped fields delivered by the most recent [flush].
  ///
  /// This is null for a delivery that included a legacy integer-mask change.
  FieldSelection? get lastDeliveredFieldSelection =>
      _lastDeliveredFieldSelection;

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
    _hasLegacyPendingChange = true;
    _pendingFieldSelection = null;
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

  /// Accepts one committed layout-scoped field [changedFields].
  ///
  /// This is the portable counterpart to [markChanged] for layouts whose
  /// field selection cannot be represented by the legacy 31-bit [FieldMask].
  /// An empty selection describes no field change and is ignored.
  void markChangedSelection(FieldSelection changedFields) {
    if (_isDisposed ||
        changedFields.isEmpty ||
        !_matchesSelection(changedFields)) {
      return;
    }
    final FieldSelection? pendingSelection = _pendingFieldSelection;
    if (!_hasLegacyPendingChange &&
        pendingSelection != null &&
        !identical(pendingSelection.layout, changedFields.layout)) {
      throw ArgumentError.value(
        changedFields,
        'changedFields',
        'Cannot coalesce selections from different RecordLayouts.',
      );
    }

    _acceptedChanges++;
    if (_hasPending) {
      _coalescedChanges++;
    } else {
      _hasPending = true;
    }
    if (!_hasLegacyPendingChange) {
      if (pendingSelection == null) {
        _pendingFieldSelection = changedFields;
      } else {
        _pendingFieldSelection = pendingSelection.union(changedFields);
      }
    }

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
    _lastDeliveredFieldSelection = pendingFieldSelection;
    _pendingFieldMask = 0;
    _pendingFieldSelection = null;
    _hasLegacyPendingChange = false;
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
    final FieldSelection? selectedFields = selection;
    if (selectedFields != null) {
      if (changedFields == 0) {
        return true;
      }
      if (!selectedFields.isCompact) {
        throw ArgumentError.value(
          changedFields,
          'changedFields',
          'A wide selection filter requires markChangedSelection.',
        );
      }
      return (selectedFields.fieldMask & changedFields) != 0;
    }
    return fields == 0 || changedFields == 0 || (fields & changedFields) != 0;
  }

  bool _matchesSelection(FieldSelection changedFields) {
    final selectedFields = selection;
    if (selectedFields != null) {
      return selectedFields.intersects(changedFields);
    }
    if (fields == 0) {
      return true;
    }
    if (!changedFields.isCompact) {
      throw ArgumentError.value(
        changedFields,
        'changedFields',
        'A wide FieldSelection requires a layout-scoped selection filter.',
      );
    }
    return _matches(changedFields.fieldMask);
  }

  static FieldSelection? _validateSelection(
    int fields,
    FieldSelection? selection,
  ) {
    if (fields != 0 && selection != null) {
      throw ArgumentError(
        'Specify either fields or selection, not both.',
      );
    }
    return selection;
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
