import 'layout.dart';

/// A stable capability for one allocated record in a [SegmentedMemory] store.
///
/// Handles identify a segment slot and its allocation generation. Releasing a
/// slot increments its generation, so an old handle cannot accidentally access
/// a later record that reuses the same slot.
final class RecordHandle {
  /// Creates an internal store-issued handle.
  ///
  /// Applications receive handles from [PulseStore.allocate]. Constructing a
  /// handle manually cannot grant access because generation checks remain
  /// enforced by the owning store.
  const RecordHandle.internal({
    required this.segment,
    required this.slot,
    required this.generation,
    required this.layout,
  });

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
      identical(layout, other.layout);

  @override
  int get hashCode =>
      Object.hash(segment, slot, generation, identityHashCode(layout));

  @override
  String toString() =>
      'RecordHandle(segment: $segment, slot: $slot, generation: $generation, '
      'layout: ${layout.name})';
}
