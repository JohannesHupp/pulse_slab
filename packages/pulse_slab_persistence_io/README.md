# pulse_slab_persistence_io

Native append-only file persistence and ordered replay for optional
[`PulseStore`](https://pub.dev/packages/pulse_slab) captures.

This package is a persistence-and-replay plane for committed typed-record
state. It is not a domain-event broker, FIFO, or transactional outbox. The
core package remains browser-safe; this optional package imports `dart:io` and
supports Android, iOS, Linux, macOS, and Windows.

## Installation

```yaml
dependencies:
  pulse_slab: ^0.3.0-beta.2
  pulse_slab_persistence_io: ^0.1.0-beta.1
```

## Usage

```dart
import 'dart:io';

import 'package:pulse_slab/pulse_slab.dart';
import 'package:pulse_slab_persistence_io/pulse_slab_persistence_io.dart';

final persistence = await FileStorePersistence.open(
  directory: Directory('capture-journal'),
  maxPendingBytes: 8 * 1024 * 1024,
  maxJournalBytes: 16 * 1024 * 1024,
  maxSegmentBytes: 1024 * 1024,
);
final store = PulseStore(
  persistence: persistence,
);

// The store remains synchronous. Capture admission happens at a completed
// transaction or lifecycle boundary and may throw explicit backpressure.
store.capturePersistenceCheckpoint();
await persistence.flush();

final replay = persistence.replayConsumer;
final delivery = await replay.take();
if (delivery != null) {
  // Materialize delivery.batch durably in the consumer.
  await replay.acknowledge(delivery);
}

await persistence.close();
```

## Semantics

- Persistence is opt-in: `PulseStore` has no I/O worker, capture batches,
  record copies, queues, or I/O when no backend is supplied.
- One backend instance is attached to one `PulseStore` lifetime. Use a separate
  backend and journal directory for another logical record stream.
- `append` synchronously encodes and admits a complete capture batch, then
  transfers immutable bytes to one long-lived I/O isolate. Its return does not
  claim an atomic store-and-file commit or a file durability barrier.
- `flush` completes after all earlier accepted batches have been written and
  flushed to the journal in order.
- `maxPendingBytes` bounds unacknowledged encoded capture payload bytes.
  `maxJournalBytes` separately bounds retained physical segment bytes,
  including binary headers, and `maxSegmentBytes` bounds one append-only
  segment. Every capture must fit into an empty segment, and a segment can be
  at most half of the journal capacity.
- A full logical or physical limit throws
  `StorePersistenceBackpressureException`; accepted captures are never
  dropped, overwritten, or coalesced.
- The binary journal contains the versioned core capture payload, which carries
  actual record bytes, stable layout identity/version, snapshots, and releases.
  It does not persist `ChangeJournal` entries.
- The default layout identity is `RecordLayout.name` at version `1` and is
  suitable for an immutable schema. Supply `persistenceLayoutResolver` when a
  persisted layout has a separately managed identity or schema version.
- `replayConsumer` offers one ordered delivery at a time (`maxInFlight: 1`).
  Acknowledgement uses two alternating fixed-size checkpoints. An
  unacknowledged batch is replayed after reopening, and a damaged newest
  checkpoint can replay a previously acknowledged batch, so consumers must be
  idempotent.
- Acknowledging releases logical payload capacity. Physical capacity is
  reclaimed only after a complete closed segment is covered by both durable
  checkpoints; acknowledged prefixes in the active segment remain until it
  rotates.
- Journal segments and checkpoints are validated at open. Invalid journal data
  fails explicitly rather than being silently repaired or truncated.

Use `StoreCaptureReplayer` or an application-specific projection to apply a
checkpoint followed by incremental captures. Persist that projection before
acknowledging each delivery.
