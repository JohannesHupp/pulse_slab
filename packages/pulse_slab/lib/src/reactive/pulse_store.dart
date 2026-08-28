import 'dart:collection';
import 'dart:typed_data';

import '../errors.dart';
import '../layout.dart';
import '../record_handle.dart';
import '../segmented_memory.dart';
import 'change_journal.dart';
import 'delivery_policy.dart';

const int _maximumRecordVersion = 0x7fffffffffffffff;

/// A field-filtered notification for one already committed record update.
///
/// Listeners should use [PulseStore.read] with [handle] to obtain the latest
/// state. A change object is intentionally compact: it does not copy record
/// bytes or materialize an intermediate state object.
final class RecordChange {
  const RecordChange._({
    required this.handle,
    required this.version,
    required this.fieldMask,
  });

  /// The stable identity of the changed record.
  final RecordHandle handle;

  /// The record version after its transaction committed.
  final int version;

  /// Union of the fields changed in the transaction.
  final FieldMask fieldMask;

  @override
  String toString() {
    return 'RecordChange(handle: $handle, version: $version, '
        'fieldMask: 0x${fieldMask.toRadixString(16)})';
  }
}

/// Callback invoked by a [StoreSubscription].
typedef RecordChangeListener = void Function(RecordChange change);

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
    required this.policy,
    required RecordChangeListener listener,
  })  : _store = store,
        _listener = listener;

  final PulseStore _store;
  final RecordChangeListener _listener;

  /// Handle this subscription observes.
  final RecordHandle handle;

  /// Bit mask accepted by this subscription; zero means all layout fields.
  final FieldMask fields;

  /// Delivery cadence selected for this subscription.
  final DeliveryPolicy policy;

  var _isActive = true;
  var _hasLatestPending = false;
  var _pendingFieldMask = 0;
  var _pendingVersion = 0;

  /// Whether the listener can still receive notifications.
  bool get isActive => _isActive;

  /// Stops future notifications. Calling this more than once is safe.
  void dispose() {
    if (!_isActive) {
      return;
    }
    _store._removeSubscription(this);
  }

  bool _matches(FieldMask changedFields) =>
      fields == 0 || (fields & changedFields) != 0;

  /// Returns whether this was the first pending latest delivery.
  bool _mergeLatest(RecordChange change) {
    if (_hasLatestPending) {
      _pendingFieldMask |= change.fieldMask;
      _pendingVersion = change.version;
      return false;
    }
    _hasLatestPending = true;
    _pendingFieldMask = change.fieldMask;
    _pendingVersion = change.version;
    return true;
  }

  RecordChange? _takeLatest() {
    if (!_isActive || !_hasLatestPending) {
      return null;
    }
    final change = RecordChange._(
      handle: handle,
      version: _pendingVersion,
      fieldMask: _pendingFieldMask,
    );
    _hasLatestPending = false;
    _pendingFieldMask = 0;
    _pendingVersion = 0;
    return change;
  }

  void _markDisposed() {
    _isActive = false;
    _hasLatestPending = false;
    _pendingFieldMask = 0;
    _pendingVersion = 0;
  }
}

/// A transaction-scoped facade used to obtain controlled writers.
///
/// Nested transactions are rejected. A transaction that throws restores byte
/// snapshots made for its touched records and does not publish any changes.
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

  /// Fields changed through this writer so far in the transaction.
  FieldMask get changedMask {
    _state._ensureActive();
    return _pending.writer.changedMask;
  }
}

/// A segmented, transactional store for fixed-layout records.
///
/// `PulseStore` processes writes synchronously on its owning isolate. It does
/// not expose raw addresses and it does not make ordinary Dart memory shared
/// between isolates. Create one store for each independent ownership domain.
final class PulseStore {
  /// Creates a store with bounded journal and batched-delivery capacity.
  PulseStore({
    this.segmentCapacity = 1024,
    int journalCapacity = 4096,
    JournalOverflowPolicy journalOverflowPolicy =
        JournalOverflowPolicy.overwriteOldest,
    int maxBatchedDeliveries = 1024,
  })  : maxBatchedDeliveries = _positive(
          maxBatchedDeliveries,
          'maxBatchedDeliveries',
        ),
        _memory = SegmentedMemory(segmentCapacity: segmentCapacity),
        journal = ChangeJournal(
          capacity: journalCapacity,
          overflowPolicy: journalOverflowPolicy,
        ),
        _batchedQueue = List<_BatchedDelivery?>.filled(
          _positive(maxBatchedDeliveries, 'maxBatchedDeliveries'),
          null,
        );

  static int _positive(int value, String name) {
    if (value <= 0) {
      throw ArgumentError.value(value, name, 'Must be greater than zero.');
    }
    return value;
  }

  /// Slot count used for every newly allocated segment.
  final int segmentCapacity;

  /// Fixed maximum number of queued [DeliveryPolicy.batched] deliveries.
  final int maxBatchedDeliveries;

  /// Ring journal for compact, replaceable record-state changes.
  final ChangeJournal journal;

  final SegmentedMemory _memory;
  final Map<RecordHandle, _SubscriptionBucket> _subscriptionBuckets =
      <RecordHandle, _SubscriptionBucket>{};
  final List<StoreSubscription> _latestQueue = <StoreSubscription>[];
  final List<_BatchedDelivery?> _batchedQueue;

  _TransactionState? _activeTransaction;
  var _batchedReadIndex = 0;
  var _batchedWriteIndex = 0;
  var _batchedLength = 0;
  var _isDisposed = false;
  var _committedChangeCount = 0;
  var _deliveredNotificationCount = 0;
  var _latestCoalescedDeliveryCount = 0;
  var _droppedBatchedDeliveryCount = 0;
  var _isFlushingLatest = false;
  var _isFlushingBatched = false;

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

  /// Allocates a zero-initialized record with [layout].
  RecordHandle allocate(RecordLayout layout) {
    _ensureOpen();
    _ensureNoActiveLifecycleMutation('allocate');
    return _memory.allocate(layout);
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
  /// Its slot can later be reused with a new generation.
  void release(RecordHandle handle) {
    _ensureOpen();
    _ensureNoActiveLifecycleMutation('release');
    _memory.release(handle);
    final _SubscriptionBucket? bucket = _subscriptionBuckets.remove(handle);
    bucket?.disposeAll();
    if (!_isFlushingLatest) {
      _latestQueue.removeWhere(
        (StoreSubscription subscription) => subscription.handle == handle,
      );
    }
    if (!_isFlushingBatched) {
      _purgeInactiveBatched();
    }
  }

  /// Runs [action] in one non-nestable transaction.
  ///
  /// Dirty field masks merge per record. At successful commit each changed
  /// record advances one version, produces at most one journal entry, and is
  /// then delivered to matching subscriptions. If [action] throws, bytes
  /// changed through transaction writers are restored and no changes publish.
  R transaction<R>(R Function(WriteTransaction transaction) action) {
    _ensureOpen();
    if (_activeTransaction != null) {
      throw StateError('Nested PulseStore transactions are not supported.');
    }

    final _TransactionState state = _TransactionState(this);
    _activeTransaction = state;
    late R result;
    try {
      result = action(WriteTransaction._(state));
      state.prepareCommit();
    } on Object {
      state.rollback();
      rethrow;
    } finally {
      state.deactivate();
      _activeTransaction = null;
    }

    state.publish();
    return result;
  }

  /// Convenience wrapper for one controlled record update.
  void update(
    RecordHandle handle,
    void Function(TransactionRecordWriter writer) action,
  ) {
    transaction<void>((WriteTransaction transaction) {
      action(transaction.write(handle));
    });
  }

  /// Subscribes to committed changes for [handle].
  ///
  /// [fields] is a union of [Field.mask] values. A value of zero watches all
  /// fields. Subscription order is insertion order for a record. A listener
  /// added during notification starts with a later change; a listener disposed
  /// during notification is not called again in that traversal.
  StoreSubscription watch(
    RecordHandle handle, {
    FieldMask fields = 0,
    DeliveryPolicy policy = DeliveryPolicy.immediate,
    required RecordChangeListener listener,
  }) {
    _ensureOpen();
    _ensureCommittedAccess('subscribe');
    _memory.validateHandle(handle);
    _validateSelectedFields(handle.layout, fields);
    final StoreSubscription subscription = StoreSubscription._(
      store: this,
      handle: handle,
      fields: fields,
      policy: policy,
      listener: listener,
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
  /// boundary. Changes submitted while a listener runs wait for the next call.
  int flush() {
    _ensureOpen();
    _ensureCommittedAccess('flush deliveries');
    return _flushLatest() + _flushBatched();
  }

  /// Disposes subscriptions, bounded queues, and typed-memory segments.
  ///
  /// Multiple calls are safe. Existing readers and writers fail safely after
  /// disposal because their underlying memory owner is disposed.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    if (_activeTransaction != null) {
      throw StateError('A PulseStore cannot be disposed during a transaction.');
    }
    _isDisposed = true;
    for (final _SubscriptionBucket bucket in _subscriptionBuckets.values) {
      bucket.disposeAll();
    }
    _subscriptionBuckets.clear();
    _latestQueue.clear();
    for (var index = 0; index < _batchedQueue.length; index++) {
      _batchedQueue[index] = null;
    }
    _batchedLength = 0;
    _batchedReadIndex = 0;
    _batchedWriteIndex = 0;
    _memory.dispose();
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

  void _validateSelectedFields(RecordLayout layout, FieldMask fields) {
    if (fields < 0) {
      throw ArgumentError.value(fields, 'fields', 'Must not be negative.');
    }
    if (fields == 0) {
      return;
    }
    final int supportedMask = (1 << layout.fields.length) - 1;
    if ((fields & ~supportedMask) != 0) {
      throw ArgumentError.value(
        fields,
        'fields',
        'Contains bits outside layout "${layout.name}".',
      );
    }
  }

  void _removeSubscription(StoreSubscription subscription) {
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

  void _publishChanges(List<RecordChange> changes) {
    for (final RecordChange change in changes) {
      final _SubscriptionBucket? bucket = _subscriptionBuckets[change.handle];
      bucket?.dispatch(this, change);
    }
  }

  void _route(StoreSubscription subscription, RecordChange change) {
    if (!subscription._isActive) {
      return;
    }
    switch (subscription.policy) {
      case DeliveryPolicy.immediate:
        _invoke(subscription, change);
      case DeliveryPolicy.latest:
        if (subscription._mergeLatest(change)) {
          _latestQueue.add(subscription);
        } else {
          _latestCoalescedDeliveryCount++;
        }
      case DeliveryPolicy.batched:
        _enqueueBatched(subscription, change);
    }
  }

  void _invoke(StoreSubscription subscription, RecordChange change) {
    if (!subscription._isActive) {
      return;
    }
    _deliveredNotificationCount++;
    subscription._listener(change);
  }

  void _enqueueBatched(StoreSubscription subscription, RecordChange change) {
    final _BatchedDelivery delivery = _BatchedDelivery(subscription, change);
    if (_batchedLength == _batchedQueue.length) {
      _batchedQueue[_batchedReadIndex] = delivery;
      _batchedReadIndex = _nextBatchedIndex(_batchedReadIndex);
      _batchedWriteIndex = _batchedReadIndex;
      _droppedBatchedDeliveryCount++;
      return;
    }
    _batchedQueue[_batchedWriteIndex] = delivery;
    _batchedWriteIndex = _nextBatchedIndex(_batchedWriteIndex);
    _batchedLength++;
  }

  int _flushLatest() {
    final int count = _latestQueue.length;
    var delivered = 0;
    var processed = 0;
    _isFlushingLatest = true;
    try {
      for (var index = 0; index < count; index++) {
        final StoreSubscription subscription = _latestQueue[index];
        processed++;
        final RecordChange? change = subscription._takeLatest();
        if (change != null) {
          _invoke(subscription, change);
          delivered++;
        }
      }
    } finally {
      _isFlushingLatest = false;
      if (processed != 0) {
        _latestQueue.removeRange(0, processed);
      }
      _latestQueue.removeWhere(
        (StoreSubscription subscription) => !subscription._isActive,
      );
    }
    return delivered;
  }

  int _flushBatched() {
    final int count = _batchedLength;
    var delivered = 0;
    _isFlushingBatched = true;
    try {
      for (var index = 0; index < count; index++) {
        final _BatchedDelivery? delivery = _dequeueBatched();
        if (delivery == null || !delivery.subscription._isActive) {
          continue;
        }
        _invoke(delivery.subscription, delivery.change);
        delivered++;
      }
    } finally {
      _isFlushingBatched = false;
      _purgeInactiveBatched();
    }
    return delivered;
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
    pending.snapshot ??= _store._memory.copyRecordBytes(pending.handle);
    return pending.writer.set(field, value);
  }

  void prepareCommit() {
    _ensureActive();
    if (_prepared) {
      throw StateError('The transaction commit was already prepared.');
    }

    final List<_PendingWrite> changed = <_PendingWrite>[];
    for (final _PendingWrite pending in _pending.values) {
      if (pending.writer.changedMask == 0 || _matchesSnapshot(pending)) {
        continue;
      }
      if (_store._memory.versionOf(pending.handle) == _maximumRecordVersion) {
        throw const VersionOverflowException(
          'A record version reached the supported signed 64-bit limit.',
        );
      }
      changed.add(pending);
    }

    for (final _PendingWrite pending in changed) {
      final int version = _store._memory.incrementVersion(pending.handle);
      final RecordChange change = RecordChange._(
        handle: pending.handle,
        version: version,
        fieldMask: pending.writer.changedMask,
      );
      _store.journal.append(
        ChangeRecord(
          segment: pending.handle.segment,
          slot: pending.handle.slot,
          generation: pending.handle.generation,
          version: version,
          fieldMask: pending.writer.changedMask,
        ),
      );
      _store._committedChangeCount++;
      _committedChanges.add(change);
    }
    _prepared = true;
  }

  bool _matchesSnapshot(_PendingWrite pending) {
    final Uint8List? snapshot = pending.snapshot;
    if (snapshot == null) {
      return false;
    }
    final Uint8List current = _store._memory.copyRecordBytes(pending.handle);
    if (snapshot.length != current.length) {
      return false;
    }
    for (var index = 0; index < snapshot.length; index++) {
      if (snapshot[index] != current[index]) {
        return false;
      }
    }
    return true;
  }

  void rollback() {
    if (_prepared) {
      return;
    }
    for (final _PendingWrite pending in _pending.values) {
      final Uint8List? snapshot = pending.snapshot;
      if (snapshot != null) {
        _store._memory.restoreRecordBytes(pending.handle, snapshot);
      }
    }
  }

  void deactivate() {
    _isActive = false;
  }

  void publish() {
    if (!_prepared) {
      throw StateError('Cannot publish a transaction before it commits.');
    }
    _store._publishChanges(_committedChanges);
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
  Uint8List? snapshot;
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

  void dispatch(PulseStore store, RecordChange change) {
    final int boundary = _subscriptions.length;
    _dispatchDepth++;
    try {
      for (var index = 0; index < boundary; index++) {
        final StoreSubscription subscription = _subscriptions[index];
        if (subscription._isActive && subscription._matches(change.fieldMask)) {
          store._route(subscription, change);
        }
      }
    } finally {
      _dispatchDepth--;
      if (_dispatchDepth == 0) {
        _subscriptions.removeWhere((StoreSubscription item) => !item._isActive);
      }
    }
  }

  void disposeAll() {
    for (final StoreSubscription subscription in _subscriptions) {
      subscription._markDisposed();
    }
    _subscriptions.clear();
  }
}

final class _BatchedDelivery {
  const _BatchedDelivery(this.subscription, this.change);

  final StoreSubscription subscription;
  final RecordChange change;
}
