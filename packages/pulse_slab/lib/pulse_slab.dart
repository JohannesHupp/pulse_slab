/// Compact transactional typed-memory state storage for high-throughput Dart
/// applications.
library;

export 'dart:typed_data';

export 'src/errors.dart';
export 'src/layout_annotations.dart';
export 'src/layout.dart';
export 'src/reactive/change_journal.dart';
export 'src/reactive/delivery_policy.dart';
export 'src/reactive/pulse_store.dart';
export 'src/record_handle.dart' show RecordHandle;
export 'src/segmented_memory.dart' show RecordReader;
export 'src/worker/byte_batch_worker.dart';
