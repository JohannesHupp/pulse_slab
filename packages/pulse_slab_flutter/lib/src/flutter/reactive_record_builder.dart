import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:pulse_slab/pulse_slab.dart';

import 'frame_coalescing_notifier.dart';

/// Builds a widget from the latest committed [RecordReader].
typedef ReactiveRecordWidgetBuilder = Widget Function(
  BuildContext context,
  RecordReader record,
);

/// Builds a replacement when the watched handle has become unavailable.
///
/// A released record is represented by a stale handle rather than an empty
/// record object. Supplying this callback makes that lifecycle explicit.
typedef ReactiveRecordUnavailableBuilder = Widget Function(
  BuildContext context,
  Object error,
);

/// A [ValueListenable] view of one record that coalesces committed store
/// changes before notifying Flutter consumers.
///
/// The underlying store watch uses immediate data-plane delivery and a
/// field-level filter. This object then delivers only the latest committed
/// state at the selected UI cadence. It owns its store subscription and must
/// be disposed when used outside [ReactiveRecordBuilder].
final class ReactiveRecordListenable extends FrameCoalescingNotifier
    implements ValueListenable<RecordReader> {
  /// Creates a record listenable bound to [store] and [handle].
  ReactiveRecordListenable({
    required this.store,
    required this.handle,
    int fields = 0,
    super.policy = FlutterDeliveryPolicy.frame,
    super.scheduleFrameCallback,
    super.cancelFrameCallback,
  }) : super(
          fields: fields,
        ) {
    _subscription = store.watch(
      handle,
      fields: fields,
      policy: DeliveryPolicy.immediate,
      listener: _onStoreChange,
      onInvalidated: _onStoreInvalidated,
    );
  }

  /// The source store. Multiple independent stores can be used in one tree.
  final PulseStore store;

  /// The stable record handle to read after each UI notification.
  final RecordHandle handle;

  late final StoreSubscription _subscription;
  var _isRecordAvailable = true;

  /// Returns the latest committed reader for [handle].
  @override
  RecordReader get value => store.read(handle);

  /// Whether the watched record has not been released or invalidated.
  ///
  /// This becomes false before the coalesced UI notification is delivered.
  /// Consumers normally read [value] in a listener or builder and handle its
  /// stale-handle error through an unavailable state.
  bool get isRecordAvailable => _isRecordAvailable;

  void _onStoreChange(RecordChange change) {
    markChanged(change.fieldMask);
  }

  void _onStoreInvalidated() {
    if (!_isRecordAvailable) {
      return;
    }
    _isRecordAvailable = false;
    // A zero mask means all or unknown fields for FrameCoalescingNotifier.
    // It therefore bypasses a field filter and schedules the unavailable UI.
    markChanged(0);
  }

  @override
  void dispose() {
    _subscription.dispose();
    super.dispose();
  }
}

/// Rebuilds only when selected fields of one record have a committed change.
///
/// By default the widget receives at most one notification per Flutter frame.
/// It reads the latest record on that notification, so a burst of input can be
/// fully processed by [PulseStore] while resulting in a single widget rebuild.
class ReactiveRecordBuilder extends StatefulWidget {
  /// Creates a record-specific, frame-coalesced builder.
  const ReactiveRecordBuilder({
    required this.store,
    required this.handle,
    required this.builder,
    this.fields = 0,
    this.deliveryPolicy = FlutterDeliveryPolicy.frame,
    this.unavailableBuilder,
    super.key,
  });

  /// The store which owns [handle].
  final PulseStore store;

  /// The record to observe.
  final RecordHandle handle;

  /// Field mask that can trigger a rebuild; zero selects all fields.
  final int fields;

  /// UI-facing notification cadence.
  final FlutterDeliveryPolicy deliveryPolicy;

  /// Called with the latest committed reader when this widget rebuilds.
  final ReactiveRecordWidgetBuilder builder;

  /// Optional fallback for a released or otherwise unreadable record.
  final ReactiveRecordUnavailableBuilder? unavailableBuilder;

  @override
  State<ReactiveRecordBuilder> createState() => _ReactiveRecordBuilderState();
}

final class _ReactiveRecordBuilderState extends State<ReactiveRecordBuilder> {
  late ReactiveRecordListenable _listenable;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant ReactiveRecordBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store ||
        oldWidget.handle != widget.handle ||
        oldWidget.fields != widget.fields ||
        oldWidget.deliveryPolicy != widget.deliveryPolicy) {
      _unbind();
      _bind();
    }
  }

  void _bind() {
    _listenable = ReactiveRecordListenable(
      store: widget.store,
      handle: widget.handle,
      fields: widget.fields,
      policy: widget.deliveryPolicy,
    );
    _listenable.addListener(_onUiChange);
  }

  void _unbind() {
    _listenable.removeListener(_onUiChange);
    _listenable.dispose();
  }

  void _onUiChange() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    try {
      final record = _listenable.value;
      return widget.builder(context, record);
    } on Object catch (error, stackTrace) {
      final unavailableBuilder = widget.unavailableBuilder;
      if (unavailableBuilder != null) {
        return unavailableBuilder(context, error);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}
