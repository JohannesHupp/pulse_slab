/// Compact transactional typed-memory state storage for high-throughput Dart
/// and Flutter applications.
library;

export 'src/errors.dart';
export 'src/layout.dart';
export 'src/reactive/change_journal.dart';
export 'src/reactive/delivery_policy.dart';
export 'src/reactive/pulse_store.dart';
export 'src/record_handle.dart';
export 'src/segmented_memory.dart' show RecordReader;
export 'src/worker/byte_batch_worker.dart';
