# Persistent capture and replay

`PulseStore` can capture committed typed-record state through an optional
`PulseStorePersistence` backend. The core package defines the portable capture
and replay contracts. Native file storage is provided by the separately
publishable `pulse_slab_persistence_io` package.

Capture stores record state. It is not a domain-event queue: application event
payloads, arbitrary FIFO messages, and outbox delivery are outside this API.

## Enable file persistence

Persistence is disabled by default. A store without `persistence:` continues
to use its synchronous in-memory path.

```dart
import 'dart:io';

import 'package:pulse_slab/pulse_slab.dart';
import 'package:pulse_slab_persistence_io/pulse_slab_persistence_io.dart';

final persistence = await FileStorePersistence.open(
  directory: Directory('sensor-captures'),
  maxPendingBytes: 8 * 1024 * 1024,
  maxJournalBytes: 16 * 1024 * 1024,
  maxSegmentBytes: 1024 * 1024,
);
final store = PulseStore(
  persistence: persistence,
  persistenceLayoutResolver: (RecordLayout layout) => StorePersistenceLayout(
    identity: layout.name,
    version: 1,
  ),
);

// Allocate and initialize the records that form the initial state.
final sensor = store.allocate(sensorLayout);
store.update(sensor, (TransactionRecordWriter writer) {
  writer.set(temperature, 21.5);
});

// Establish a complete state boundary after initialization.
store.capturePersistenceCheckpoint();
await persistence.flush();
```

`pulse_slab` itself does not import `dart:io`; browser applications can import
the core package without loading the native backend.

Attach one backend instance to one `PulseStore` lifetime. Use a separate
backend and journal directory for another logical record stream. The store
rejects a second attachment so record coordinates from independent stores
cannot share one replay stream.

## Capture boundary

When no backend is configured, a completed transaction performs only the
predictable persistence-null check at its commit boundary. It does not start a
worker, create capture batches or queues, copy record bytes, encode values, or
perform I/O. Field writes do not perform persistence checks.

With a backend, the store performs synchronous capture admission after it has
computed each transaction's net changes and before it increments versions,
updates `ChangeJournal`, or invokes subscriptions. One accepted incremental
batch contains a complete post-write record image for every changed record.
The record image carries its record coordinate, committed version, layout
identity, and layout version. Transactions that roll back or restore all bytes
to their original values do not emit a capture.

Record allocation emits a version-zero snapshot. Record release emits an
ordered release operation. If capture admission throws, allocation is undone,
release leaves the record live, and a transaction restores its bytes without
publishing a journal or subscription change.

`PulseStore` rejects re-entry from a backend's synchronous `append` call. A
backend must treat `append` as a byte-admission callback and must not read,
write, release, dispose, or otherwise call the owning store from that callback.

`capturePersistenceCheckpoint()` emits snapshots of every live record. It is
an explicit state boundary and does not flush the backend. A layout resolver is
evaluated once when each record is allocated. The default resolver uses
`RecordLayout.name` and version `1`; applications with evolving schemas should
provide stable identities and versions explicitly.

Capture is independent of `ChangeJournal`, subscription delivery policies, and
Flutter frame coalescing. A journal entry describes changed memory locations;
it is not used as persisted data because it cannot reconstruct record bytes
after later writes.

## Binary capture and replay

`StoreCaptureCodec` encodes a versioned, platform-neutral binary batch. A batch
is either a checkpoint of snapshots or ordered incremental snapshot and release
operations. Snapshot operations contain raw committed record bytes plus layout
identity/version and record identity/version. `StoreCaptureCodec.decode`
validates the format before replay.

Use `StoreCaptureReplayer` for a logical recovered record set, or apply each
`StoreCaptureSnapshot` to an application-specific projection that resolves its
layout metadata. A replay consumer offers one delivery at a time:

```dart
final StoreCaptureReplayer replayer = StoreCaptureReplayer();
final StorePersistenceReplayConsumer replay = persistence.replayConsumer;

while (true) {
  final StorePersistenceReplayDelivery? delivery = await replay.take();
  if (delivery == null) {
    break;
  }

  replayer.apply(delivery.batch);
  // Persist the projection before this acknowledgement.
  await replay.acknowledge(delivery);
}
```

`acknowledge` persists replay progress. An unacknowledged delivery is offered
again after the backend is reopened, so replay consumers must be idempotent.
Call `retry` to make the active delivery available again without acknowledging
it. The contract enforces `maxInFlight: 1`.

## Native file backend

`FileStorePersistence` writes the core capture payload into ordered,
checksummed append-only binary frames in a long-lived I/O isolate. The owning
isolate encodes each accepted batch into an independently owned byte buffer and
transfers it with `TransferableTypedData`. The I/O isolate never accesses live
store memory.

`maxPendingBytes` bounds the encoded payload bytes retained for
unacknowledged replay. `maxJournalBytes` separately bounds the retained
physical bytes of journal segments, including segment and frame headers.
`maxSegmentBytes` bounds one append-only segment, so every capture batch must
fit into an empty segment and must be no more than half of
`maxJournalBytes`. That leaves room to rotate a full segment while advancing
durable acknowledgement progress. The fixed-size acknowledgement checkpoint
files are separate from the journal-byte limit.

Admission checks both limits before the capture is sent to the I/O isolate. A
new batch that exceeds either bound throws
`StorePersistenceBackpressureException`; accepted captures are never
overwritten, coalesced, or silently dropped. Acknowledging the oldest replay
delivery releases its logical payload capacity. Physical capacity is reclaimed
only when an entire closed segment has been acknowledged. The active segment
can therefore retain acknowledged prefixes until it rotates.

Acknowledgement progress uses two alternating, fixed-size durable checkpoints.
A closed segment is removed only after both checkpoints cover its final
capture. If the newest checkpoint is torn or corrupt, the older checkpoint
causes already processed captures to be replayed rather than allowing data
loss. Existing segments, frames, and checkpoints are validated when the
backend opens; invalid journal data fails open explicitly.

`append` reports synchronous admission into the backend pipeline. It is not a
file-durability barrier and it is not atomic with the store transaction. Use
`flush()` to wait until all earlier accepted batches have been written and
flushed. A successful store transaction can therefore be captured for later
I/O but cannot be claimed to be atomically committed with a filesystem write.

Call `close()` during orderly shutdown. It flushes accepted batches, stops the
I/O isolate, and rejects later appends.
