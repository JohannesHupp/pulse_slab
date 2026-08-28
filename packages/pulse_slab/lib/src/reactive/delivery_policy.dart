/// Selects when a state subscription receives committed changes.
///
/// These policies govern replaceable state notifications only. They are not a
/// substitute for a lossless event transport.
enum DeliveryPolicy {
  /// Invoke the listener synchronously after the owning transaction commits.
  immediate,

  /// Keep only the newest committed state per subscription until [flush].
  latest,

  /// Queue compact state changes until [flush], subject to a fixed bound.
  batched,
}
