/// Selects when a state subscription receives committed changes.
///
/// These policies govern replaceable state notifications only. They are not a
/// substitute for a lossless event transport.
enum DeliveryPolicy {
  /// Invoke the listener synchronously after the owning transaction commits.
  ///
  /// A commit made while immediate dispatch is already publishing queues
  /// matching immediate calls in the store-wide bounded ring until that
  /// traversal finishes. A full ring replaces its oldest pending call; this
  /// affects replaceable state delivery only and never rejects the committed
  /// record state. A commit from a deferred [PulseStore.flush] callback invokes
  /// matching immediate listeners inline instead.
  immediate,

  /// Keep one merged newest state per subscription until [PulseStore.flush].
  ///
  /// A later matching commit replaces the pending version and merges its fields
  /// into that one delivery. Intermediate state is coalesced rather than
  /// reported as dropped.
  latest,

  /// Queue matching state changes until [PulseStore.flush], subject to a fixed
  /// store-wide bound.
  ///
  /// The shared ring preserves retained delivery order. When it is full, a new
  /// delivery replaces the oldest pending call without rejecting the record
  /// state commit.
  batched,
}
