/// Base class for predictable failures raised by Pulse Slab.
sealed class PulseSlabException implements Exception {
  /// Creates a Pulse Slab exception with a diagnostic message.
  const PulseSlabException(this.message);

  /// A human-readable explanation of the failure.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when a record layout is invalid or used inconsistently.
final class LayoutException extends PulseSlabException {
  /// Creates a layout exception.
  const LayoutException(super.message);
}

/// Thrown when a field does not belong to the record being accessed.
final class FieldAccessException extends PulseSlabException {
  /// Creates a field access exception.
  const FieldAccessException(super.message);
}

/// Thrown when a record handle points at a released or reused slot.
final class StaleRecordHandleException extends PulseSlabException {
  /// Creates a stale-handle exception.
  const StaleRecordHandleException(super.message);
}

/// Thrown when an operation addresses a record outside the store's segments.
final class RecordBoundsException extends PulseSlabException {
  /// Creates a record-bounds exception.
  const RecordBoundsException(super.message);
}

/// Thrown when an operation requires a live record but the slot is released.
final class ReleasedRecordException extends PulseSlabException {
  /// Creates a released-record exception.
  const ReleasedRecordException(super.message);
}

/// Thrown when a version counter cannot advance without wrapping.
final class VersionOverflowException extends PulseSlabException {
  /// Creates a version-overflow exception.
  const VersionOverflowException(super.message);
}

/// Thrown when an operation is attempted after its memory owner is disposed.
final class StoreDisposedException extends PulseSlabException {
  /// Creates a disposed-store exception.
  const StoreDisposedException(super.message);
}
