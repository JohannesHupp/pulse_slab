import 'layout.dart';

/// A stable capability for one allocated record in a [SegmentedMemory] store.
///
/// Handles identify a segment slot, allocation generation, and opaque memory
/// owner. Releasing a slot increments its generation, so an old handle cannot
/// accidentally access a later record that reuses the same slot. A handle from
/// another store is rejected even when its visible coordinates are identical.
final class RecordHandle {
  const RecordHandle._issued({
    required this.segment,
    required this.slot,
    required this.generation,
    required this.layout,
    required Object ownerToken,
  }) : _ownerToken = ownerToken;

  final Object _ownerToken;

  /// Stable index of the segment containing the record.
  final int segment;

  /// Slot index within [segment].
  final int slot;

  /// Allocation generation captured when this handle was created.
  final int generation;

  /// The record's immutable memory layout.
  final RecordLayout layout;

  @override
  bool operator ==(Object other) =>
      other is RecordHandle &&
      segment == other.segment &&
      slot == other.slot &&
      generation == other.generation &&
      identical(layout, other.layout) &&
      identical(_ownerToken, other._ownerToken);

  @override
  int get hashCode => Object.hash(
        segment,
        slot,
        generation,
        identityHashCode(layout),
        identityHashCode(_ownerToken),
      );

  @override
  String toString() =>
      'RecordHandle(segment: $segment, slot: $slot, generation: $generation, '
      'layout: ${layout.name})';
}

/// Issues and validates handles for one segmented-memory owner.
///
/// This type is intentionally not exported from the package's public library.
/// It supplies an opaque identity token so numerically identical handles from
/// separate stores cannot alias one another.
final class RecordHandleIssuer {
  final Object _ownerToken = Object();

  /// Issues a new handle owned by this issuer.
  RecordHandle issue({
    required int segment,
    required int slot,
    required int generation,
    required RecordLayout layout,
  }) {
    return RecordHandle._issued(
      segment: segment,
      slot: slot,
      generation: generation,
      layout: layout,
      ownerToken: _ownerToken,
    );
  }

  /// Whether [handle] was issued by this owner.
  bool owns(RecordHandle handle) => identical(handle._ownerToken, _ownerToken);
}
