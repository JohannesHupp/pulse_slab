import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../errors.dart';
import '../layout.dart';
import '../persistence/pulse_store_persistence.dart';
import '../record_handle.dart';
import '../segmented_memory.dart';
import 'change_journal.dart';
import 'delivery_policy.dart';

// Keep versions exactly representable on both native and JavaScript targets.
const int _maximumRecordVersion = 0x1fffffffffffff;

/// A field-filtered notification for one already committed record update.
///
/// Listeners should use [PulseStore.read] with [handle] to obtain the latest
/// state. A change object is intentionally compact: it does not copy record
/// bytes or materialize an intermediate state object.
final class RecordChange {
  RecordChange._({
    required this.handle,
    required this.version,
    FieldMask? fieldMask,
    FieldSelection? fieldSelection,
  })  : _fieldMask = fieldMask ?? 0,
        _fieldSelection = fieldSelection {
    if ((fieldMask == null) == (fieldSelection == null)) {
      throw ArgumentError(
        'Provide exactly one of fieldMask or fieldSelection.',
      );
    }
    if (fieldSelection != null &&
        !identical(fieldSelection.layout, handle.layout)) {
      throw ArgumentError.value(
        fieldSelection,
        'fieldSelection',
        'Must belong to the changed record layout.',
      );
    }
  }

  /// The stable identity of the changed record.
  final RecordHandle handle;

  /// The record version after its transaction committed.
  final int version;

  final FieldMask _fieldMask;
  final FieldSelection? _fieldSelection;

  /// Fields whose final encoded bytes differ from the pre-transaction state.
  ///
  /// This remains available for compact layouts. Wide changes have no portable
  /// integer mask and throw instead; use [fieldSelection].
  FieldMask get fieldMask => _fieldSelection?.fieldMask ?? _fieldMask;

  /// The exact changed fields for this record.
  ///
  /// Compact changes are converted lazily, preserving their integer-mask hot
  /// path until a caller explicitly asks for this representation.
  FieldSelection get fieldSelection =>
      _fieldSelection ?? handle.layout.selectionFromMask(_fieldMask);

  /// Whether this change was produced by a wide layout.
  bool get hasWideFieldSelection => _fieldSelection != null;

  @override
  String toString() {
    final FieldSelection? selection = _fieldSelection;
    final String fields = selection == null
        ? 'fieldMask: 0x${_fieldMask.toRadixString(16)}'
        : 'fieldSelection: $selection';
    return 'RecordChange(handle: $handle, version: $version, $fields)';
  }
}

/// Callback invoked by a [StoreSubscription].
///
/// Listener failures do not stop the current deterministic dispatch traversal.
/// Pulse Slab invokes every remaining eligible listener, then rethrows the
/// first failure with its original stack trace. A listener failure never rolls
/// back an already committed transaction.
typedef RecordChangeListener = void Function(RecordChange change);

/// Callback invoked once when a live record subscription becomes unavailable.
///
/// This is called synchronously after the subscription has been made inactive
/// because its record was released or its store was disposed. It is not called
/// when application code manually disposes the subscription. Failures do not
/// stop remaining invalidation callbacks; the first failure is rethrown after
/// the lifecycle operation finishes.
typedef StoreSubscriptionInvalidationListener = void Function();

/// Owns one subscription to a record in a [PulseStore].
///
/// Dispose subscriptions when they are no longer needed. Releasing the record
/// also disposes all of its subscriptions, so a released slot cannot retain
/// listener closures or notify a later record which reuses that slot.
final class StoreSubscription {
  StoreSubscription._({
    required PulseStore store,
    required this.handle,
    required this.fields,
    required this.selection,
    required this.policy,
    required RecordChangeListener listener,
    StoreSubscriptionInvalidationListener? onInvalidated,
  })  : _store = store,
        _listener = listener,
        _onInvalidated = onInvalidated;

  final PulseStore _store;
  final RecordChangeListener _listener;
  final StoreSubscriptionInvalidationListener? _onInvalidated;

  /// Handle this subscription observes.
  final RecordHandle handle;

  /// Bit mask accepted by this subscription; zero means all layout fields
  /// unless [selection] is set.
  final FieldMask fields;

  /// Wide-layout selection accepted by this subscription, when configured.
  final FieldSelection? selection;

  /// Delivery cadence selected for this subscription.
  final DeliveryPolicy policy;

  var _isActive = true;
  var _hasLatestPending = false;
  var _pendingFieldMask = 0;
  FieldSelection? _pendingFieldSelection;
  var _pendingVersion = 0;
  var _pendingDeliveries = 0;
  var _deliveredCount = 0;
  var _coalescedCount = 0;
  var _droppedCount = 0;

  /// Whether the listener can still receive notifications.
  bool get isActive => _isActive;

  /// Number of accepted deliveries currently waiting for this subscription.
  ///
  /// This is a live gauge rather than a cumulative counter. It is zero for
  /// normal immediate delivery, at most one for [DeliveryPolicy.latest], and
  /// can be greater for batched or reentrant immediate delivery. It becomes
  /// zero when this subscription is disposed or invalidated.
  int get pendingDeliveries => _pendingDeliveries;

  /// Number of listener invocation attempts for this subscription.
  ///
  /// This monotonically increases even when the listener throws. Filtered
  /// changes and cancelled pending work do not count as delivered.
  int get deliveredCount => _deliveredCount;

  /// Number of matching changes merged into an already pending latest delivery.
  ///
  /// This is a monotonic counter. It remains zero for immediate and batched
  /// policies because they do not merge pending subscription deliveries.
  int get coalescedCount => _coalescedCount;

  /// Number of this subscription's pending deliveries evicted by a full
  /// bounded delivery ring.
  ///
  /// This is a monotonic counter. It excludes latest coalescing, filtering,
  /// journal overwrite or rejection, and lifecycle cancellation caused by
  /// disposal or record release.
  int get droppedCount => _droppedCount;

  /// Stops future notifications. Calling this more than once is safe.
  void dispose() {
    if (!_isActive) {
      return;
    }
    _store._removeSubscription(this);
  }

  bool _matches(RecordChange change) {
    final FieldSelection? selected = selection;
    if (selected != null) {
      return selected.intersects(change.fieldSelection);
    }
    return fields == 0 || (fields & change.fieldMask) != 0;
  }

  /// Returns whether this was the first pending latest delivery.
  bool _mergeLatest(RecordChange change) {
    if (_hasLatestPending) {
      if (change.hasWideFieldSelection) {
        final FieldSelection changed = change.fieldSelection;
        _pendingFieldSelection = _pendingFieldSelection == null
            ? changed
            : _pendingFieldSelection!.union(changed);
      } else {
        _pendingFieldMask |= change.fieldMask;
      }
      _pendingVersion = change.version;
      _coalescedCount++;
      return false;
    }
    _hasLatestPending = true;
    if (change.hasWideFieldSelection) {
      _pendingFieldSelection = change.fieldSelection;
    } else {
      _pendingFieldMask = change.fieldMask;
    }
    _pendingVersion = change.version;
    _pendingDeliveries++;
    return true;
  }

  RecordChange? _takeLatest() {
    if (!_isActive || !_hasLatestPending) {
      return null;
    }
    final FieldSelection? selection = _pendingFieldSelection;
    final RecordChange change = selection == null
        ? RecordChange._(
            handle: handle,
            version: _pendingVersion,
            fieldMask: _pendingFieldMask,
          )
        : RecordChange._(
            handle: handle,
            version: _pendingVersion,
            fieldSelection: selection,
          );
    _hasLatestPending = false;
    _pendingFieldMask = 0;
    _pendingFieldSelection = null;
    _pendingVersion = 0;
    _removePendingDelivery();
    return change;
  }

  void _markDisposed() {
    _isActive = false;
    _hasLatestPending = false;
    _pendingFieldMask = 0;
    _pendingFieldSelection = null;
    _pendingVersion = 0;
    _pendingDeliveries = 0;
  }

  void _enqueuePendingDelivery() {
    _pendingDeliveries++;
  }

  void _removePendingDelivery() {
    if (_pendingDeliveries != 0) {
      _pendingDeliveries--;
    }
  }

  void _dropPendingDelivery() {
    if (_pendingDeliveries == 0) {
      return;
    }
    _pendingDeliveries--;
    _droppedCount++;
  }

  void _recordDelivered() {
    _deliveredCount++;
  }

  _ListenerFailure? _invalidate() {
    if (!_isActive) {
      return null;
    }
    _markDisposed();
    try {
      _onInvalidated?.call();
      return null;
    } on Object catch (error, stackTrace) {
      return _ListenerFailure(error, stackTrace);
    }
  }
}

/// A transaction-scoped facade used to obtain controlled writers.
///
/// Nested transactions are rejected. A transaction that throws restores byte
/// snapshots made for its touched records and does not publish any changes.
/// Its writers stop accepting reads and writes as soon as the action returns,
/// before persistence capture admission begins.
final class WriteTransaction {
  WriteTransaction._(this._state);

  final _TransactionState _state;

  /// Obtains a mutable accessor for [handle] during this transaction.
  TransactionRecordWriter write(RecordHandle handle) =>
      _state.writerFor(handle);
}

/// A mutable record view valid only during its owning [WriteTransaction].
///
/// Its API is deliberately separate from [RecordReader]. Holding an instance
/// after the transaction returns is harmless, but reads and writes then throw
/// instead of bypassing commit, version, and dirty-mask tracking.
final class TransactionRecordWriter {
  TransactionRecordWriter._(this._state, this._pending);

  final _TransactionState _state;
  final _PendingWrite _pending;

  /// The record this writer changes.
  RecordHandle get handle => _pending.handle;

  /// The fixed layout of [handle].
  RecordLayout get layout => handle.layout;

  /// The current record version. It advances when the transaction commits.
  int get version {
    _state._ensureActive();
    return _state._store._memory.versionOf(handle);
  }

  /// Reads the in-transaction value of [field].
  T get<T>(Field<T> field) {
    _state._ensureActive();
    return _pending.writer.get(field);
  }

  /// Stores [value] when its encoded bytes differ, returning whether it did.
  ///
  /// The record receives at most one version increment at commit regardless of
  /// how many successful calls are made through this writer.
  bool set<T>(Field<T> field, T value) => _state._set(_pending, field, value);

  /// Fields whose writes differed at least once during this transaction.
  ///
  /// The committed [RecordChange.fieldMask] or
  /// [RecordChange.fieldSelection] is more precise: it contains only fields
  /// whose final encoded bytes differ from their bytes before the transaction
  /// began.
  FieldMask get changedMask {
    _state._ensureActive();
    return _pending.writer.changedMask;
  }

  /// Fields whose writes differed at least once during this transaction.
  ///
  /// This works for layouts of any width. The committed change is still more
  /// precise because it removes fields restored before commit.
  FieldSelection get changedFieldSelection {
    _state._ensureActive();
    return _pending.writer.changedFieldSelection;
  }
}

/// A segmented, transactional store for fixed-layout records.
///
/// `PulseStore` processes writes synchronously on its owning isolate. It does
/// not expose raw addresses and it does not make ordinary Dart memory shared
/// between isolates. Create one store for each independent ownership domain.
final class PulseStore {
  /// Creates a store with bounded journal and delivery capacity.
  ///
  /// With [JournalOverflowPolicy.rejectNewest], a full journal omits new
  /// journal entries but never rejects record-state commits. Observe
  /// [rejectedJournalChangeCount] when that distinction matters.
  PulseStore({
    this.segmentCapacity = 1024,
    int journalCapacity = 4096,
    JournalOverflowPolicy journalOverflowPolicy =
        JournalOverflowPolicy.overwriteOldest,
    int maxBatchedDeliveries = 1024,
    int maxReentrantImmediateDeliveries = 1024,
    this.persistence,
    StorePersistenceLayoutResolver? persistenceLayoutResolver,
  })  : _persistenceLayoutResolver = persistence == null
            ? null
            : persistenceLayoutResolver ?? defaultStorePersistenceLayout,
        _persistenceLayouts = persistence == null
            ? null
            : <RecordHandle, StorePersistenceLayout>{},
        _persistenceOwnerToken = persistence == null ? null : Object(),
        maxBatchedDeliveries = _positive(
          maxBatchedDeliveries,
          'maxBatchedDeliveries',
        ),
        maxReentrantImmediateDeliveries = _positive(
          maxReentrantImmediateDeliveries,
          'maxReentrantImmediateDeliveries',
        ),
        journal = ChangeJournal(
          capacity: journalCapacity,
          overflowPolicy: journalOverflowPolicy,
        ),
        _batchedQueue = List<_BatchedDelivery?>.filled(
          _positive(maxBatchedDeliveries, 'maxBatchedDeliveries'),
          null,
        ),
        _reentrantImmediateQueue = List<_ImmediateDelivery?>.filled(
          _positive(
            maxReentrantImmediateDeliveries,
            'maxReentrantImmediateDeliveries',
          ),
          null,
        ) {
    if (persistence == null && persistenceLayoutResolver != null) {
      throw ArgumentError.value(
        persistenceLayoutResolver,
        'persistenceLayoutResolver',
        'Requires a persistence backend.',
      );
    }
    _memory = SegmentedMemory(
      segmentCapacity: segmentCapacity,
      readAccessGuard: _ensureRetainedReaderAccess,
    );
    final PulseStorePersistence? configuredPersistence = persistence;
    if (configuredPersistence != null) {
      try {
        _attachPersistence(configuredPersistence);
      } on Object {
        _memory.dispose();
        rethrow;
      }
    }
  }

  static int _positive(int value, String name) {
    if (value <= 0) {
      throw ArgumentError.value(value, name, 'Must be greater than zero.');
    }
    return value;
  }

  /// Slot count used for every newly allocated segment.
  final int segmentCapacity;

  /// Fixed maximum number of queued [DeliveryPolicy.batched] deliveries across
  /// all subscriptions in this store.
  final int maxBatchedDeliveries;

  /// Fixed maximum number of reentrant immediate listener deliveries awaiting
  /// traversal.
  ///
  /// The queue is used only while an immediate listener commits another state
  /// change. When it fills, the oldest replaceable listener delivery is
  /// overwritten and [droppedReentrantImmediateDeliveryCount] increases.
  final int maxReentrantImmediateDeliveries;

  /// Ring journal for compact, replaceable record-state changes.
  final ChangeJournal journal;

  /// Optional ordered capture sink for committed record snapshots.
  ///
  /// When this is `null`, which is the default, completed transactions take the
  /// existing in-memory path without allocating capture batches, copying record
  /// bytes, encoding values, creating persistence queues, or performing I/O.
  /// When non-null, a single guard at the completed-transaction boundary builds
  /// immutable snapshot batches for this sink. The sink is independent from
  /// [journal] and from Flutter or subscription delivery. A backend instance can
  /// be attached to one store lifetime. Calls that re-enter this store while a
  /// backend is synchronously accepting a batch are rejected.
  final PulseStorePersistence? persistence;

  final StorePersistenceLayoutResolver? _persistenceLayoutResolver;
  final Map<RecordHandle, StorePersistenceLayout>? _persistenceLayouts;
  final Object? _persistenceOwnerToken;

  late final SegmentedMemory _memory;
  static final Expando<Object> _persistenceOwners = Expando<Object>(
    'PulseStore.persistenceOwner',
  );
  static final Object _persistenceCaptureSentinel = Object();
  final Map<RecordHandle, _SubscriptionBucket> _subscriptionBuckets =
      <RecordHandle, _SubscriptionBucket>{};
  final List<StoreSubscription> _latestQueue = <StoreSubscription>[];
  final List<_BatchedDelivery?> _batchedQueue;
  final List<_ImmediateDelivery?> _reentrantImmediateQueue;
  final _TransactionScratchArena _transactionScratch =
      _TransactionScratchArena();

  // A real [_TransactionState] protects a transaction. The private sentinel
  // temporarily applies the same access gate while a lifecycle capture is
  // synchronously admitted, without adding a persistence branch to reads.
  Object? _activeTransaction;
  var _batchedReadIndex = 0;
  var _batchedWriteIndex = 0;
  var _batchedLength = 0;
  var _isDisposed = false;
  var _committedChangeCount = 0;
  var _deliveredNotificationCount = 0;
  var _latestCoalescedDeliveryCount = 0;
  var _droppedBatchedDeliveryCount = 0;
  var _droppedReentrantImmediateDeliveryCount = 0;
  var _rejectedJournalChangeCount = 0;
  var _isFlushingLatest = false;
  var _isFlushingBatched = false;
  var _isPublishingCommittedChanges = false;
  var _isCapturingPersistence = false;
  var _reentrantImmediateReadIndex = 0;
  var _reentrantImmediateWriteIndex = 0;
  var _reentrantImmediateLength = 0;

  /// Whether this store has been disposed.
  bool get isDisposed => _isDisposed;

  /// Number of live records across all layouts and segments.
  int get liveRecordCount => _memory.liveRecordCount;

  /// Number of currently allocated memory segments.
  int get segmentCount => _memory.segmentCount;

  /// Total available slots across allocated segments.
  int get totalCapacity => _memory.totalCapacity;

  /// Number of record changes successfully committed since creation.
  int get committedChangeCount => _committedChangeCount;

  /// Number of listener invocations performed by this store.
  int get deliveredNotificationCount => _deliveredNotificationCount;

  /// Number of [DeliveryPolicy.latest] updates merged into existing pending
  /// deliveries.
  int get latestCoalescedDeliveryCount => _latestCoalescedDeliveryCount;

  /// Number of oldest state deliveries overwritten in the bounded batched
  /// delivery queue.
  int get droppedBatchedDeliveryCount => _droppedBatchedDeliveryCount;

  /// Number of oldest replaceable listener deliveries overwritten from the
  /// bounded reentrant immediate-delivery queue.
  int get droppedReentrantImmediateDeliveryCount =>
      _droppedReentrantImmediateDeliveryCount;

  /// Number of reentrant immediate listener deliveries awaiting the active
  /// traversal.
  int get pendingReentrantImmediateDeliveryCount => _reentrantImmediateLength;

  /// Number of committed changes not retained by a full rejecting journal.
  ///
  /// This increases only when [journal] uses
  /// [JournalOverflowPolicy.rejectNewest]. The record state, its version, and
  /// its matching subscription deliveries still commit successfully; the
  /// bounded journal is a replaceable state observation channel, not a
  /// transaction acceptance gate.
  int get rejectedJournalChangeCount => _rejectedJournalChangeCount;

  /// Retained capacity, in bytes, of the reusable transaction snapshot arena.
  ///
  /// The arena grows only when a transaction needs more rollback bytes than
  /// it has previously retained. It is reset between transactions and released
  /// when this store is disposed.
  int get transactionScratchCapacityInBytes => _transactionScratch.capacity;

  /// Greatest rollback-snapshot footprint observed for one transaction.
  ///
  /// This diagnostic is useful when sizing layouts and assessing transaction
  /// fan-out. It is not a count of live record memory.
  int get transactionScratchPeakBytes => _transactionScratch.peakBytes;

  /// Allocates a zero-initialized record with [layout].
  RecordHandle allocate(RecordLayout layout) {
    _ensureOpen();
    _ensureNoActiveLifecycleMutation('allocate');
    final PulseStorePersistence? persistence = this.persistence;
    if (persistence == null) {
      return _memory.allocate(layout);
    }
    final StorePersistenceLayout persistenceLayout =
        _persistenceLayoutResolver!(layout);
    final RecordHandle handle = _memory.allocate(layout);
    final Map<RecordHandle, StorePersistenceLayout> layouts =
        _persistenceLayouts!;
    layouts[handle] = persistenceLayout;
    try {
      _appendLifecyclePersistence(
        StoreCaptureBatch.incremental(
          <StoreCaptureOperation>[
            _captureSnapshot(handle, persistenceLayout, version: 0),
          ],
        ),
      );
    } on Object {
      layouts.remove(handle);
      _memory.release(handle);
      rethrow;
    }
    return handle;
  }

  /// Returns a checked, immutable reader for [handle].
  RecordReader read(RecordHandle handle) {
    _ensureOpen();
    _ensureCommittedAccess('read records');
    return _memory.read(handle);
  }

  /// Returns the latest committed version for [handle].
  int versionOf(RecordHandle handle) {
    _ensureOpen();
    _ensureCommittedAccess('read record versions');
    return _memory.versionOf(handle);
  }

  /// Releases [handle] and disposes only subscriptions attached to it.
  ///
  /// A released handle cannot be read, written, watched, or released again.
  /// Its slot can later be reused with a new generation. Calling this from a
  /// change listener is safe: the current delivery traversal skips every
  /// invalidated subscription that has not run yet.
  void release(RecordHandle handle) {
    _ensureOpen();
    _ensureNoActiveLifecycleMutation('release');
    final PulseStorePersistence? persistence = this.persistence;
    if (persistence != null) {
      _memory.validateHandle(handle);
      final StorePersistenceLayout? layout = _persistenceLayouts![handle];
      if (layout == null) {
        throw StateError('Missing persistence metadata for $handle.');
      }
      _appendLifecyclePersistence(
        StoreCaptureBatch.incremental(
          <StoreCaptureOperation>[
            StoreCaptureRelease(record: _captureRecordId(handle)),
          ],
        ),
      );
      _persistenceLayouts.remove(handle);
    }
    _memory.release(handle);
    final _SubscriptionBucket? bucket = _subscriptionBuckets.remove(handle);
    final _ListenerFailure? invalidationFailure = bucket?.invalidateAll();
    if (!_isFlushingLatest) {
      _latestQueue.removeWhere(
        (StoreSubscription subscription) => subscription.handle == handle,
      );
    }
    if (!_isFlushingBatched) {
      _purgeInactiveBatched();
    }
    invalidationFailure?.throwWithOriginalStack();
  }

  /// Runs [action] in one non-nestable transaction.
  ///
  /// Dirty field masks merge per record. At successful commit each changed
  /// record advances one version, produces at most one journal entry, and is
  /// then delivered to matching subscriptions. If [action] throws, bytes
  /// changed through transaction writers are restored and no changes publish.
  ///
  /// A full [JournalOverflowPolicy.rejectNewest] journal does not reject the
  /// state commit. Instead, the committed state is omitted from the journal and
  /// [rejectedJournalChangeCount] increases. Listener failures happen after
  /// commit: every eligible listener is attempted and the first failure is
  /// rethrown after traversal.
  ///
  /// When [persistence] is configured, the store first asks its bounded sink to
  /// accept an immutable post-write capture at this completed-transaction
  /// boundary. A synchronous admission failure rolls the transaction back.
  /// Successful admission does not make the state commit and an eventual file
  /// write atomic; backend-specific flush and failure APIs define durability.
  ///
  /// [action] must complete synchronously. Returning a [Future] is rejected
  /// and rolls back its synchronous prefix. Any deferred code runs outside the
  /// transaction boundary and must not use its transaction writer.
  R transaction<R>(R Function(WriteTransaction transaction) action) {
    _ensureOpen();
    if (_activeTransaction != null) {
      throw StateError('Nested PulseStore transactions are not supported.');
    }

    _transactionScratch.reset();
    final _TransactionState state = _TransactionState(this);
    _activeTransaction = state;
    late R result;
    try {
      result = action(WriteTransaction._(state));
      // No caller code may use retained transaction facades after the action
      // returns. Closing the existing transaction state here keeps that
      // guarantee during synchronous persistence admission without a separate
      // per-field persistence predicate.
      state.deactivate();
      if (result is Future<Object?>) {
        // The call throws synchronously, so this rejected future has no normal
        // caller. Ignore a later writer-lifetime failure instead of surfacing
        // it as an unrelated unhandled asynchronous error.
        result.ignore();
        throw ArgumentError.value(
          action,
          'action',
          'PulseStore.transaction actions must complete synchronously.',
        );
      }
      state.prepareCommit();
    } on Object {
      state.rollback();
      rethrow;
    } finally {
      state.deactivate();
      _activeTransaction = null;
    }

    final _ListenerFailure? listenerFailure = state.publish();
    listenerFailure?.throwWithOriginalStack();
    return result;
  }

  /// Captures a complete persistence checkpoint of every live record.
  ///
  /// This is available only when [persistence] is configured. A checkpoint
  /// contains full committed record images and can be followed by ordered
  /// incremental captures during recovery. Calling it does not flush a backend;
  /// use backend-specific durability APIs for that boundary.
  void capturePersistenceCheckpoint() {
    _ensureOpen();
    _ensureNoActiveLifecycleMutation('capture a persistence checkpoint');
    final PulseStorePersistence? persistence = this.persistence;
    if (persistence == null) {
      throw StateError(
        'PulseStore.capturePersistenceCheckpoint requires persistence.',
      );
    }
    final List<StoreCaptureSnapshot> snapshots = <StoreCaptureSnapshot>[];
    for (final MapEntry<RecordHandle, StorePersistenceLayout> entry
        in _persistenceLayouts!.entries) {
      snapshots.add(
        _captureSnapshot(
          entry.key,
          entry.value,
          version: _memory.versionOf(entry.key),
        ),
      );
    }
    _appendLifecyclePersistence(StoreCaptureBatch.checkpoint(snapshots));
  }

  /// Convenience wrapper for one synchronous controlled record update.
  ///
  /// The return value of [action] is forwarded after the transaction commits.
  /// If [action] returns a [Future], the transaction rejects it and rolls back
  /// its synchronous prefix just as [transaction] does. [action] must not
  /// retain its writer beyond the synchronous callback.
  R update<R>(
    RecordHandle handle,
    R Function(TransactionRecordWriter writer) action,
  ) {
    return transaction<R>((WriteTransaction transaction) {
      return action(transaction.write(handle));
    });
  }

  /// Subscribes to committed changes for [handle].
  ///
  /// [fields] is a union of [Field.mask] values for a compact layout. A value
  /// of zero watches all fields. For wide layouts, pass a layout-scoped
  /// [selection] from [RecordLayout.selectionFor]; the legacy [fields] fast
  /// path intentionally remains integer-only.
  ///
  /// Subscription order is insertion order for a record. A listener added
  /// during notification starts with a later change; a listener disposed during
  /// notification is not called again in that traversal.
  ///
  /// [onInvalidated] is called once when [handle] is released or this store is
  /// disposed. It is not called by [StoreSubscription.dispose]. This makes it
  /// suitable for UI adapters that need to render an unavailable record state.
  /// If it throws, all remaining invalidation callbacks still run before the
  /// lifecycle operation rethrows the first failure.
  StoreSubscription watch(
    RecordHandle handle, {
    FieldMask fields = 0,
    FieldSelection? selection,
    DeliveryPolicy policy = DeliveryPolicy.immediate,
    StoreSubscriptionInvalidationListener? onInvalidated,
    required RecordChangeListener listener,
  }) {
    _ensureOpen();
    _ensureCommittedAccess('subscribe');
    _memory.validateHandle(handle);
    _validateSelectedFields(handle.layout, fields, selection);
    final StoreSubscription subscription = StoreSubscription._(
      store: this,
      handle: handle,
      fields: fields,
      selection: selection,
      policy: policy,
      listener: listener,
      onInvalidated: onInvalidated,
    );
    final _SubscriptionBucket bucket = _subscriptionBuckets.putIfAbsent(
      handle,
      _SubscriptionBucket.new,
    );
    bucket.add(subscription);
    return subscription;
  }

  /// Flushes pending [DeliveryPolicy.latest] and [DeliveryPolicy.batched]
  /// state deliveries in deterministic order.
  ///
  /// Call this from a render loop, a test, or another explicit scheduling
  /// boundary. It snapshots latest queue membership before it starts, then
  /// snapshots batched deliveries after latest callbacks complete. An earlier
  /// latest callback can merge into a subscription that was already in the
  /// latest snapshot, and that subscription receives the merged state in this
  /// call. A subscription made latest-pending after the membership boundary
  /// waits for the next call. Batched work created by a latest callback can run
  /// in this call's batched phase; work created by a batched callback waits for
  /// the next call.
  ///
  /// Listener failures do not stop other eligible pending deliveries; the first
  /// failure is rethrown after both queues have been traversed.
  int flush() {
    _ensureOpen();
    _ensureCommittedAccess('flush deliveries');
    if (_isFlushingLatest || _isFlushingBatched) {
      throw StateError(
        'PulseStore.flush cannot be called from a delivery callback.',
      );
    }
    final _FlushResult latest = _flushLatest();
    final _FlushResult batched = _isDisposed
        ? const _FlushResult(delivered: 0, listenerFailure: null)
        : _flushBatched();
    (latest.listenerFailure ?? batched.listenerFailure)
        ?.throwWithOriginalStack();
    return latest.delivered + batched.delivered;
  }

  /// Disposes subscriptions, bounded queues, and typed-memory segments.
  ///
  /// Multiple calls are safe. Existing readers and writers fail safely after
  /// disposal because their underlying memory owner is disposed. Calling this
  /// from a change listener is safe: current and pending deliveries become
  /// inactive and no later record changes are published.
  void dispose() {
    _ensureNoPersistenceReentrancy('dispose the store');
    if (_isDisposed) {
      return;
    }
    if (_activeTransaction != null) {
      throw StateError('A PulseStore cannot be disposed during a transaction.');
    }
    _isDisposed = true;
    _ListenerFailure? invalidationFailure;
    final List<_SubscriptionBucket> buckets =
        List<_SubscriptionBucket>.of(_subscriptionBuckets.values);
    for (final _SubscriptionBucket bucket in buckets) {
      final _ListenerFailure? bucketFailure = bucket.invalidateAll();
      invalidationFailure ??= bucketFailure;
    }
    _subscriptionBuckets.clear();
    if (!_isFlushingLatest) {
      _latestQueue.clear();
    }
    if (!_isFlushingBatched) {
      _clearBatchedDeliveries();
    }
    if (!_isPublishingCommittedChanges) {
      _clearReentrantImmediateDeliveries();
    }
    _transactionScratch.dispose();
    _persistenceLayouts?.clear();
    _memory.dispose();
    invalidationFailure?.throwWithOriginalStack();
  }

  void _ensureOpen() {
    if (_isDisposed) {
      throw const StoreDisposedException('The PulseStore is disposed.');
    }
  }

  void _ensureNoActiveLifecycleMutation(String operation) {
    if (_activeTransaction != null) {
      throw StateError(
        'Cannot $operation records while a PulseStore transaction is active.',
      );
    }
  }

  void _ensureCommittedAccess(String operation) {
    if (_activeTransaction != null) {
      throw StateError(
        'Cannot $operation while a PulseStore transaction is active. '
        'Use TransactionRecordWriter for in-transaction reads.',
      );
    }
  }

  void _ensureRetainedReaderAccess() {
    if (_activeTransaction != null) {
      throw StateError(
        'Cannot access a retained record reader while a PulseStore '
        'transaction is active. Use TransactionRecordWriter for '
        'in-transaction reads.',
      );
    }
  }

  void _validateSelectedFields(
    RecordLayout layout,
    FieldMask fields,
    FieldSelection? selection,
  ) {
    if (selection != null) {
      if (fields != 0) {
        throw ArgumentError(
          'Provide either fields or selection, not both.',
        );
      }
      if (!identical(selection.layout, layout)) {
        throw ArgumentError.value(
          selection,
          'selection',
          'Must belong to layout "${layout.name}".',
        );
      }
      return;
    }
    if (fields < 0 || fields > 0x7fffffff) {
      throw ArgumentError.value(
        fields,
        'fields',
        'Must be a non-negative portable field mask.',
      );
    }
    if (fields == 0) {
      return;
    }
    if (!layout.supportsFieldMasks) {
      throw ArgumentError.value(
        fields,
        'fields',
        'Layout "${layout.name}" has more than $maxFieldsPerLayout fields. '
            'Use selection instead.',
      );
    }
    layout.selectionFromMask(fields);
  }

  void _removeSubscription(StoreSubscription subscription) {
    _ensureNoPersistenceReentrancy('dispose a subscription');
    if (!subscription._isActive) {
      return;
    }
    subscription._markDisposed();
    if (!_isFlushingLatest) {
      _latestQueue.remove(subscription);
    }
    if (!_isFlushingBatched) {
      _purgeInactiveBatched();
    }
    final _SubscriptionBucket? bucket =
        _subscriptionBuckets[subscription.handle];
    if (bucket == null) {
      return;
    }
    bucket.remove(subscription);
    if (bucket.isEmpty) {
      _subscriptionBuckets.remove(subscription.handle);
    }
  }

  void _capturePreparedWrites(List<_PendingWrite> changed) {
    final PulseStorePersistence? persistence = this.persistence;
    if (persistence == null || changed.isEmpty) {
      return;
    }
    final Map<RecordHandle, StorePersistenceLayout> layouts =
        _persistenceLayouts!;
    final List<StoreCaptureOperation> operations = <StoreCaptureOperation>[];
    for (final _PendingWrite pending in changed) {
      final StorePersistenceLayout? layout = layouts[pending.handle];
      if (layout == null) {
        throw StateError('Missing persistence metadata for ${pending.handle}.');
      }
      operations.add(
        _captureSnapshot(
          pending.handle,
          layout,
          version: _memory.versionOf(pending.handle) + 1,
        ),
      );
    }
    _appendPersistence(StoreCaptureBatch.incremental(operations));
  }

  void _appendPersistence(StoreCaptureBatch batch) {
    final PulseStorePersistence? persistence = this.persistence;
    if (persistence == null) {
      return;
    }
    _ensureNoPersistenceReentrancy('capture persistence');
    _isCapturingPersistence = true;
    try {
      persistence.append(batch);
    } finally {
      _isCapturingPersistence = false;
    }
  }

  void _appendLifecyclePersistence(StoreCaptureBatch batch) {
    assert(_activeTransaction == null);
    _activeTransaction = _persistenceCaptureSentinel;
    try {
      _appendPersistence(batch);
    } finally {
      _activeTransaction = null;
    }
  }

  void _attachPersistence(PulseStorePersistence persistence) {
    if (_persistenceOwners[persistence] != null) {
      throw StateError(
        'A PulseStorePersistence instance can be attached to only one '
        'PulseStore for its lifetime.',
      );
    }
    _persistenceOwners[persistence] = _persistenceOwnerToken!;
  }

  void _ensureNoPersistenceReentrancy(String operation) {
    if (_isCapturingPersistence) {
      throw StateError(
        'Cannot $operation while a persistence backend is accepting a '
        'capture from this PulseStore.',
      );
    }
  }

  StoreCaptureSnapshot _captureSnapshot(
    RecordHandle handle,
    StorePersistenceLayout layout, {
    required int version,
  }) =>
      StoreCaptureSnapshot.takeBytes(
        record: _captureRecordId(handle),
        layout: layout,
        version: version,
        bytes: _memory.copyRecordBytes(handle),
      );

  StoreCaptureRecordId _captureRecordId(RecordHandle handle) =>
      StoreCaptureRecordId(
        segment: handle.segment,
        slot: handle.slot,
        generation: handle.generation,
      );

  _ListenerFailure? _publishChanges(List<RecordChange> changes) {
    if (changes.isEmpty || _isDisposed) {
      return null;
    }
    if (_isPublishingCommittedChanges) {
      for (final RecordChange change in changes) {
        final _SubscriptionBucket? bucket = _subscriptionBuckets[change.handle];
        bucket?.routeReentrant(this, change);
      }
      return null;
    }

    _isPublishingCommittedChanges = true;
    _ListenerFailure? listenerFailure;
    try {
      for (final RecordChange change in changes) {
        if (_isDisposed) {
          break;
        }
        final _SubscriptionBucket? bucket = _subscriptionBuckets[change.handle];
        final _ListenerFailure? dispatchFailure =
            bucket?.dispatch(this, change);
        listenerFailure ??= dispatchFailure;
      }
      while (!_isDisposed) {
        final _ImmediateDelivery? delivery = _dequeueReentrantImmediate();
        if (delivery == null) {
          break;
        }
        final _ListenerFailure? invocationFailure = _invoke(
          delivery.subscription,
          delivery.change,
        );
        listenerFailure ??= invocationFailure;
      }
    } finally {
      _isPublishingCommittedChanges = false;
      _clearReentrantImmediateDeliveries();
    }
    return listenerFailure;
  }

  void _enqueueReentrantImmediate(
    StoreSubscription subscription,
    RecordChange change,
  ) {
    final _ImmediateDelivery delivery =
        _ImmediateDelivery(subscription, change);
    if (_reentrantImmediateLength == _reentrantImmediateQueue.length) {
      final _ImmediateDelivery? evicted =
          _reentrantImmediateQueue[_reentrantImmediateReadIndex];
      evicted?.subscription._dropPendingDelivery();
      _reentrantImmediateQueue[_reentrantImmediateReadIndex] = delivery;
      subscription._enqueuePendingDelivery();
      _reentrantImmediateReadIndex =
          _nextReentrantImmediateIndex(_reentrantImmediateReadIndex);
      _reentrantImmediateWriteIndex = _reentrantImmediateReadIndex;
      _droppedReentrantImmediateDeliveryCount++;
      return;
    }
    _reentrantImmediateQueue[_reentrantImmediateWriteIndex] = delivery;
    subscription._enqueuePendingDelivery();
    _reentrantImmediateWriteIndex =
        _nextReentrantImmediateIndex(_reentrantImmediateWriteIndex);
    _reentrantImmediateLength++;
  }

  _ImmediateDelivery? _dequeueReentrantImmediate() {
    if (_reentrantImmediateLength == 0) {
      return null;
    }
    final int index = _reentrantImmediateReadIndex;
    final _ImmediateDelivery? delivery = _reentrantImmediateQueue[index];
    _reentrantImmediateQueue[index] = null;
    _reentrantImmediateReadIndex = _nextReentrantImmediateIndex(index);
    _reentrantImmediateLength--;
    delivery?.subscription._removePendingDelivery();
    return delivery;
  }

  void _clearReentrantImmediateDeliveries() {
    for (var index = 0; index < _reentrantImmediateQueue.length; index++) {
      _reentrantImmediateQueue[index] = null;
    }
    _reentrantImmediateReadIndex = 0;
    _reentrantImmediateWriteIndex = 0;
    _reentrantImmediateLength = 0;
  }

  int _nextReentrantImmediateIndex(int index) =>
      index + 1 == _reentrantImmediateQueue.length ? 0 : index + 1;

  _ListenerFailure? _route(
    StoreSubscription subscription,
    RecordChange change,
  ) {
    if (!subscription._isActive) {
      return null;
    }
    switch (subscription.policy) {
      case DeliveryPolicy.immediate:
        return _invoke(subscription, change);
      case DeliveryPolicy.latest:
      case DeliveryPolicy.batched:
        _routeDeferred(subscription, change);
        return null;
    }
  }

  void _routeDeferred(
    StoreSubscription subscription,
    RecordChange change,
  ) {
    if (!subscription._isActive) {
      return;
    }
    switch (subscription.policy) {
      case DeliveryPolicy.immediate:
        throw StateError(
          'Immediate subscriptions must be delivered through the immediate '
          'delivery path.',
        );
      case DeliveryPolicy.latest:
        if (subscription._mergeLatest(change)) {
          _latestQueue.add(subscription);
        } else {
          _latestCoalescedDeliveryCount++;
        }
        return;
      case DeliveryPolicy.batched:
        _enqueueBatched(subscription, change);
        return;
    }
  }

  _ListenerFailure? _invoke(
    StoreSubscription subscription,
    RecordChange change,
  ) {
    if (!subscription._isActive) {
      return null;
    }
    _deliveredNotificationCount++;
    subscription._recordDelivered();
    try {
      subscription._listener(change);
      return null;
    } on Object catch (error, stackTrace) {
      return _ListenerFailure(error, stackTrace);
    }
  }

  void _enqueueBatched(StoreSubscription subscription, RecordChange change) {
    final _BatchedDelivery delivery = _BatchedDelivery(subscription, change);
    if (_batchedLength == _batchedQueue.length) {
      final _BatchedDelivery? evicted = _batchedQueue[_batchedReadIndex];
      evicted?.subscription._dropPendingDelivery();
      _batchedQueue[_batchedReadIndex] = delivery;
      subscription._enqueuePendingDelivery();
      _batchedReadIndex = _nextBatchedIndex(_batchedReadIndex);
      _batchedWriteIndex = _batchedReadIndex;
      _droppedBatchedDeliveryCount++;
      return;
    }
    _batchedQueue[_batchedWriteIndex] = delivery;
    subscription._enqueuePendingDelivery();
    _batchedWriteIndex = _nextBatchedIndex(_batchedWriteIndex);
    _batchedLength++;
  }

  _FlushResult _flushLatest() {
    final int count = _latestQueue.length;
    var delivered = 0;
    var processed = 0;
    _ListenerFailure? listenerFailure;
    _isFlushingLatest = true;
    try {
      for (var index = 0; index < count; index++) {
        final StoreSubscription subscription = _latestQueue[index];
        processed++;
        final RecordChange? change = subscription._takeLatest();
        if (change != null) {
          final _ListenerFailure? invocationFailure = _invoke(
            subscription,
            change,
          );
          listenerFailure ??= invocationFailure;
          delivered++;
        }
      }
    } finally {
      _isFlushingLatest = false;
      if (_isDisposed) {
        _latestQueue.clear();
      } else {
        if (processed != 0) {
          _latestQueue.removeRange(0, processed);
        }
        _latestQueue.removeWhere(
          (StoreSubscription subscription) => !subscription._isActive,
        );
      }
    }
    return _FlushResult(
      delivered: delivered,
      listenerFailure: listenerFailure,
    );
  }

  _FlushResult _flushBatched() {
    final int count = _batchedLength;
    var delivered = 0;
    _ListenerFailure? listenerFailure;
    _isFlushingBatched = true;
    try {
      for (var index = 0; index < count; index++) {
        final _BatchedDelivery? delivery = _dequeueBatched();
        if (delivery == null || !delivery.subscription._isActive) {
          continue;
        }
        final _ListenerFailure? invocationFailure = _invoke(
          delivery.subscription,
          delivery.change,
        );
        listenerFailure ??= invocationFailure;
        delivered++;
      }
    } finally {
      _isFlushingBatched = false;
      if (_isDisposed) {
        _clearBatchedDeliveries();
      } else {
        _purgeInactiveBatched();
      }
    }
    return _FlushResult(
      delivered: delivered,
      listenerFailure: listenerFailure,
    );
  }

  void _clearBatchedDeliveries() {
    for (var index = 0; index < _batchedQueue.length; index++) {
      _batchedQueue[index] = null;
    }
    _batchedLength = 0;
    _batchedReadIndex = 0;
    _batchedWriteIndex = 0;
  }

  void _purgeInactiveBatched() {
    if (_batchedLength == 0) {
      return;
    }
    final List<_BatchedDelivery> retained = <_BatchedDelivery>[];
    for (var count = 0, index = _batchedReadIndex;
        count < _batchedLength;
        count++, index = _nextBatchedIndex(index)) {
      final _BatchedDelivery? delivery = _batchedQueue[index];
      if (delivery != null && delivery.subscription._isActive) {
        retained.add(delivery);
      }
    }
    for (var index = 0; index < _batchedQueue.length; index++) {
      _batchedQueue[index] = null;
    }
    for (var index = 0; index < retained.length; index++) {
      _batchedQueue[index] = retained[index];
    }
    _batchedReadIndex = 0;
    _batchedLength = retained.length;
    _batchedWriteIndex =
        retained.length == _batchedQueue.length ? 0 : retained.length;
  }

  _BatchedDelivery? _dequeueBatched() {
    if (_batchedLength == 0) {
      return null;
    }
    final int index = _batchedReadIndex;
    final _BatchedDelivery? delivery = _batchedQueue[index];
    _batchedQueue[index] = null;
    _batchedReadIndex = _nextBatchedIndex(index);
    _batchedLength--;
    delivery?.subscription._removePendingDelivery();
    return delivery;
  }

  int _nextBatchedIndex(int index) =>
      index + 1 == _batchedQueue.length ? 0 : index + 1;
}

final class _TransactionState {
  _TransactionState(this._store);

  final PulseStore _store;
  final LinkedHashMap<RecordHandle, _PendingWrite> _pending =
      LinkedHashMap<RecordHandle, _PendingWrite>();
  final List<RecordChange> _committedChanges = <RecordChange>[];
  var _isActive = true;
  var _prepared = false;

  TransactionRecordWriter writerFor(RecordHandle handle) {
    _ensureActive();
    _store._memory.validateHandle(handle);
    final _PendingWrite pending = _pending.putIfAbsent(
      handle,
      () => _PendingWrite(handle, _store._memory.writer(handle)),
    );
    return TransactionRecordWriter._(this, pending);
  }

  bool _set<T>(_PendingWrite pending, Field<T> field, T value) {
    _ensureActive();
    if (!pending.writer.wouldChange(field, value)) {
      return false;
    }
    pending.snapshotOffset ??= _store._transactionScratch.capture(
      _store._memory,
      pending.handle,
    );
    pending.writer.setKnownChanged(field, value);
    return true;
  }

  void prepareCommit() {
    if (_prepared) {
      throw StateError('The transaction commit was already prepared.');
    }

    final List<_PendingWrite> changed = <_PendingWrite>[];
    for (final _PendingWrite pending in _pending.values) {
      if (pending.handle.layout.supportsFieldMasks) {
        final FieldMask netChangedMask = _netChangedMask(pending);
        if (netChangedMask == 0) {
          continue;
        }
        pending.netChangedMask = netChangedMask;
      } else {
        final FieldSelection netChangedSelection =
            _netChangedFieldSelection(pending);
        if (netChangedSelection.isEmpty) {
          continue;
        }
        pending.netChangedSelection = netChangedSelection;
      }
      if (_store._memory.versionOf(pending.handle) == _maximumRecordVersion) {
        throw const VersionOverflowException(
          'A record version reached the portable exact-integer limit.',
        );
      }
      changed.add(pending);
    }

    _store._capturePreparedWrites(changed);

    for (final _PendingWrite pending in changed) {
      final int version = _store._memory.incrementVersion(pending.handle);
      final FieldSelection? selection = pending.netChangedSelection;
      final RecordChange change = selection == null
          ? RecordChange._(
              handle: pending.handle,
              version: version,
              fieldMask: pending.netChangedMask,
            )
          : RecordChange._(
              handle: pending.handle,
              version: version,
              fieldSelection: selection,
            );
      final bool journalRetained = _store.journal.append(
        selection == null
            ? ChangeRecord(
                segment: pending.handle.segment,
                slot: pending.handle.slot,
                generation: pending.handle.generation,
                version: version,
                fieldMask: pending.netChangedMask,
              )
            : ChangeRecord(
                segment: pending.handle.segment,
                slot: pending.handle.slot,
                generation: pending.handle.generation,
                version: version,
                fieldSelection: selection,
              ),
      );
      if (!journalRetained) {
        _store._rejectedJournalChangeCount++;
      }
      _store._committedChangeCount++;
      _committedChanges.add(change);
    }
    _prepared = true;
  }

  FieldMask _netChangedMask(_PendingWrite pending) {
    final FieldMask changedMask = pending.writer.changedMask;
    if (changedMask == 0) {
      return 0;
    }
    final int? snapshotOffset = pending.snapshotOffset;
    if (snapshotOffset == null) {
      return 0;
    }
    return _store._memory.changedFieldMaskFromBuffer(
      pending.handle,
      _store._transactionScratch.bytes,
      snapshotOffset,
      changedMask,
    );
  }

  FieldSelection _netChangedFieldSelection(_PendingWrite pending) {
    final FieldSelection changedSelection =
        pending.writer.changedFieldSelection;
    if (changedSelection.isEmpty) {
      return changedSelection;
    }
    final int? snapshotOffset = pending.snapshotOffset;
    if (snapshotOffset == null) {
      return pending.handle.layout.selectionFor(const <Field<Object?>>[]);
    }
    return _store._memory.changedFieldSelectionFromBuffer(
      pending.handle,
      _store._transactionScratch.bytes,
      snapshotOffset,
      changedSelection,
    );
  }

  void rollback() {
    if (_prepared) {
      return;
    }
    for (final _PendingWrite pending in _pending.values) {
      final int? snapshotOffset = pending.snapshotOffset;
      if (snapshotOffset != null) {
        _store._memory.restoreRecordBytesFromBuffer(
          pending.handle,
          _store._transactionScratch.bytes,
          snapshotOffset,
        );
      }
    }
  }

  void deactivate() {
    _isActive = false;
  }

  _ListenerFailure? publish() {
    if (!_prepared) {
      throw StateError('Cannot publish a transaction before it commits.');
    }
    return _store._publishChanges(_committedChanges);
  }

  void _ensureActive() {
    if (!_isActive) {
      throw StateError('This transaction is no longer active.');
    }
  }
}

final class _PendingWrite {
  _PendingWrite(this.handle, this.writer);

  final RecordHandle handle;
  final RecordWriter writer;
  int? snapshotOffset;
  FieldMask netChangedMask = 0;
  FieldSelection? netChangedSelection;
}

/// Reuses rollback storage between synchronous transactions in one store.
///
/// Record images are addressed by offsets rather than per-record [Uint8List]
/// instances. The arena is never exposed outside the transaction lifecycle, so
/// it can grow by replacing its backing buffer without invalidating callers.
final class _TransactionScratchArena {
  Uint8List _bytes = Uint8List(0);
  var _used = 0;
  var _peakBytes = 0;

  Uint8List get bytes => _bytes;

  int get capacity => _bytes.length;

  int get peakBytes => _peakBytes;

  void reset() {
    _used = 0;
  }

  int capture(SegmentedMemory memory, RecordHandle handle) {
    final int byteLength = handle.layout.sizeInBytes;
    final int offset = _used;
    final int required = offset + byteLength;
    _ensureCapacity(required);
    memory.copyRecordBytesInto(handle, _bytes, offset);
    _used = required;
    if (_used > _peakBytes) {
      _peakBytes = _used;
    }
    return offset;
  }

  void dispose() {
    _bytes = Uint8List(0);
    _used = 0;
    _peakBytes = 0;
  }

  void _ensureCapacity(int required) {
    if (required <= _bytes.length) {
      return;
    }
    var newCapacity = _bytes.isEmpty ? 64 : _bytes.length;
    while (newCapacity < required) {
      newCapacity *= 2;
    }
    final Uint8List grown = Uint8List(newCapacity);
    if (_used != 0) {
      grown.setRange(0, _used, _bytes);
    }
    _bytes = grown;
  }
}

final class _SubscriptionBucket {
  final List<StoreSubscription> _subscriptions = <StoreSubscription>[];
  var _dispatchDepth = 0;

  bool get isEmpty =>
      !_subscriptions.any((StoreSubscription item) => item._isActive);

  void add(StoreSubscription subscription) {
    _subscriptions.add(subscription);
  }

  void remove(StoreSubscription subscription) {
    if (_dispatchDepth == 0) {
      _subscriptions.remove(subscription);
    }
  }

  _ListenerFailure? dispatch(PulseStore store, RecordChange change) {
    final int boundary = _subscriptions.length;
    _ListenerFailure? listenerFailure;
    _dispatchDepth++;
    try {
      for (var index = 0; index < boundary; index++) {
        final StoreSubscription subscription = _subscriptions[index];
        if (subscription._isActive && subscription._matches(change)) {
          final _ListenerFailure? dispatchFailure = store._route(
            subscription,
            change,
          );
          listenerFailure ??= dispatchFailure;
        }
      }
    } finally {
      _dispatchDepth--;
      if (_dispatchDepth == 0) {
        _subscriptions.removeWhere((StoreSubscription item) => !item._isActive);
      }
    }
    return listenerFailure;
  }

  /// Routes deferred policies immediately, then queues only matching immediate
  /// listeners for the traversal that is already in progress. Capturing the
  /// subscription object here ensures a listener added after this commit does
  /// not observe an older change.
  void routeReentrant(PulseStore store, RecordChange change) {
    final int boundary = _subscriptions.length;
    _dispatchDepth++;
    try {
      for (var index = 0; index < boundary; index++) {
        final StoreSubscription subscription = _subscriptions[index];
        if (!subscription._isActive || !subscription._matches(change)) {
          continue;
        }
        if (subscription.policy == DeliveryPolicy.immediate) {
          store._enqueueReentrantImmediate(subscription, change);
        } else {
          store._routeDeferred(subscription, change);
        }
      }
    } finally {
      _dispatchDepth--;
      if (_dispatchDepth == 0) {
        _subscriptions.removeWhere((StoreSubscription item) => !item._isActive);
      }
    }
  }

  _ListenerFailure? invalidateAll() {
    final List<StoreSubscription> subscriptions =
        List<StoreSubscription>.of(_subscriptions);
    _ListenerFailure? invalidationFailure;
    for (final StoreSubscription subscription in subscriptions) {
      final _ListenerFailure? subscriptionFailure = subscription._invalidate();
      invalidationFailure ??= subscriptionFailure;
    }
    if (_dispatchDepth == 0) {
      _subscriptions.clear();
    }
    return invalidationFailure;
  }
}

final class _BatchedDelivery {
  const _BatchedDelivery(this.subscription, this.change);

  final StoreSubscription subscription;
  final RecordChange change;
}

/// A bounded deferred call to an immediate subscription.
final class _ImmediateDelivery {
  const _ImmediateDelivery(this.subscription, this.change);

  final StoreSubscription subscription;
  final RecordChange change;
}

final class _ListenerFailure {
  const _ListenerFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  Never throwWithOriginalStack() =>
      Error.throwWithStackTrace(error, stackTrace);
}

final class _FlushResult {
  const _FlushResult({
    required this.delivered,
    required this.listenerFailure,
  });

  final int delivered;
  final _ListenerFailure? listenerFailure;
}
