# pulse_slab

[![pub package](https://img.shields.io/pub/v/pulse_slab.svg)](https://pub.dev/packages/pulse_slab)

A compact, transactional reactive data store for high-throughput Dart applications. `pulse_slab` stores fixed-layout scalar records in reusable typed-memory segments, assigns stable generation-checked handles, and delivers only the committed field changes each consumer selected. Flutter UI bindings live in the separate `pulse_slab_flutter` package.

## Why the name?

**pulse** describes a continuous real-time signal; **slab** describes reusable segmented memory. The name communicates the package's high-rate, memory-oriented focus without borrowing the identity of an existing state-management framework. It follows pub.dev's lowercase-underscore naming convention.

## Suitable use cases

- High-frequency telemetry, monitoring, simulation, gaming, and industrial-control views.
- Thousands of compact numeric record updates per second.
- Flutter applications through the separate `pulse_slab_flutter` adapter, which can deliver the newest relevant state once per frame instead of rebuilding for every input update.
- Data pipelines that benefit from explicit record layouts, typed field descriptors, transaction boundaries, and bounded change retention.

## Not suitable for

- Arbitrary nested object graphs, richly relational domain models, or a general application-architecture framework.
- Lossless business-event delivery. A coalesced state update is intentionally replaceable; use an acknowledged event transport for events that must never be lost.
- Sharing normal Dart heap memory between isolates. The worker API transfers bytes and preserves isolate ownership.

## Installation

Use the release version selected on pub.dev:

```yaml
dependencies:
  pulse_slab: ^0.3.0-beta.1
```

For local development in this repository, point a consuming package at `../packages/pulse_slab`.

For a paired release, `pulse_slab` must be available before
`pulse_slab_flutter`. The Flutter adapter declares a normal pub dependency on
this core package. The repository release automation publishes the core first
and makes the adapter wait until the required core version is visible on
pub.dev.

## Quick start

```dart
import 'package:pulse_slab/pulse_slab.dart';

final timestamp = Float64Field('timestamp');
final temperature = Float32Field('temperature');
final status = Uint16Field('status');

final sensorLayout = RecordLayout(
  name: 'SensorState',
  fields: <Field<Object?>>[timestamp, temperature, status],
);

final store = PulseStore(
  segmentCapacity: 256,
  journalCapacity: 1024,
);
final sensor = store.allocate(sensorLayout);

store.transaction((transaction) {
  final writer = transaction.write(sensor);
  writer.set(timestamp, 1234.0);
  writer.set(temperature, 42.5);
  writer.set(status, 2);
});

final reader = store.read(sensor);
final currentTemperature = reader.get(temperature);

final subscription = store.watch(
  sensor,
  fields: temperature.mask | status.mask,
  policy: DeliveryPolicy.latest,
  listener: (change) {
    // Read the latest committed state; do not retain an old reader.
    final latest = store.read(sensor);
    print(change.version);
    print(latest.get(temperature));
  },
);

// DeliveryPolicy.latest and DeliveryPolicy.batched are explicit.
store.flush();

subscription.dispose();
store.release(sensor);
store.dispose();
```

Field descriptor names are metadata. Hot reads and writes use the stable descriptor and its resolved byte offset, not a string lookup. A layout permits at most 31 dirty-tracked fields because it uses a portable, non-negative integer field mask.

## Portable unsigned 64-bit values

Use `Uint64ValueField` when a value can use all 64 unsigned bits on both the
Dart VM and JavaScript targets. `Uint64Value` keeps the exact bit pattern as
two validated 32-bit words rather than converting it to one potentially lossy
Dart `int`.

```dart
import 'dart:typed_data';

import 'package:pulse_slab/pulse_slab.dart';

final store = PulseStore();
final counter = Uint64ValueField('counter');
final counterLayout = RecordLayout(
  name: 'Counter',
  fields: <Field<Object?>>[counter],
);
final counterHandle = store.allocate(counterLayout);
final value = Uint64Value.fromWords(
  highWord: 0x80000000, // Bits 63 through 32.
  lowWord: 0, // Bits 31 through 0.
);

store.update(counterHandle, (writer) {
  writer.set(counter, value);
});

final Uint64Value current = store.read(counterHandle).get(counter);
final bytesForWire = current.toBytes(byteOrder: Endian.big);

store.dispose();
```

`compareTo` compares the high word and then the low word as an unsigned value.
Use matching `Endian` values with `toBytes` and `Uint64Value.fromBytes` at a
wire boundary. `Uint64Field` remains available without behavior changes for
existing raw signed two's-complement `int` bit patterns; choose the new field
for new portable identifiers, counters, and unsigned values.

## Delivery policies

| Policy | Behavior | Queue bound |
| --- | --- | --- |
| `immediate` | Calls matching listeners immediately after a successful commit. | No normal queue; reentrant listener calls use a fixed replaceable queue. |
| `latest` | Keeps only the latest merged state change per subscription until `flush()`. | One pending change per subscription. |
| `batched` | Retains compact changes until `flush()`. | Fixed journal and subscription bounds. |

Subscriptions are scoped to one handle and may filter by a field mask. Dispatch order is registration order. Removing a subscription during dispatch is safe; a removed listener will not be invoked later in the same dispatch. A listener may start a new transaction after the original commit. A reentrant immediate change commits synchronously but its immediate listener calls wait until the active traversal finishes. The fixed `maxReentrantImmediateDeliveries` queue replaces its oldest pending state delivery when full and increments `droppedReentrantImmediateDeliveryCount`; it never rejects a committed write. Reentrant `latest` and `batched` subscriptions are routed into their own bounded policy queues immediately, so their coalescing semantics are preserved. Latest and batched delivery retain changes until the next explicit flush. `flush()` rejects reentrant calls from a latest or batched delivery callback. Prefer deferring feedback loops when a flat callback sequence is easier to reason about.

If a queued reentrant immediate listener fails, the first failure is rethrown
when the outermost delivery traversal completes. It never rolls back either
already committed state change.

Transaction and `update` actions must be synchronous; a returned `Future` is
rejected and the synchronous prefix is rolled back. Record listeners and
invalidation callbacks are also synchronous APIs: their returned futures are
not awaited or routed through the store's listener-failure behavior. Start
asynchronous work only after capturing the committed data it needs.

While a transaction callback is active, public `read`, `versionOf`, `watch`, and
`flush` calls reject access. Retained readers and fixed-byte views reject access
as well. Use the transaction writer's `get` method for an in-transaction read.
This prevents synchronous consumers from observing partially written record
bytes before the commit boundary.

## Flutter integration

This package intentionally has no Flutter SDK dependency. Flutter applications
should depend on the separately publishable adapter, which re-exports this core
API:

~~~yaml
dependencies:
  pulse_slab_flutter: ^0.3.0-beta.1
~~~

~~~dart
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';
~~~

`ReactiveRecordBuilder` in that package owns a field-filtered subscription and
uses frame-coalesced notification by default. A temperature-only builder does
not rebuild when only `status` changes. The [Flutter telemetry example](https://github.com/JohannesHupp/pulse_slab/tree/main/packages/pulse_slab_flutter/example)
simulates multiple sensors at configurable high update rates and displays
raw input updates, net committed record changes, transaction compaction, frame
deliveries, rebuilds, coalescing, and bounded journal behavior.

## Background byte batches

```dart
import 'dart:typed_data';

final worker = await ByteBatchWorker.start(
  config: const ByteBatchWorkerConfig(
    transform: ByteBatchTransform.frameChecksum,
    frameSize: 16,
    maxInFlight: 2,
  ),
);

final result = await worker.submit(Uint8List(64));
await worker.close();
```

The worker is long-lived and has a bounded in-flight limit. Submitted bytes cross the isolate boundary through `TransferableTypedData`; they are transferred by ownership, not shared as mutable memory. Backpressure raises `WorkerBackpressureException`, and worker failures complete with `ByteBatchWorkerException`.

## Performance philosophy

The central principle is:

> Process every important input, but deliver only the state changes that each consumer can use.

This package reduces allocations and redundant work through typed byte storage, reusable slots, field masks, transaction merging, bounded journals, and targeted listener lists. The separate Flutter adapter adds frame coalescing. Those techniques are workload-specific trade-offs, not a claim that every application will be faster. Benchmark on the target device and workload.

Run the included smoke benchmark:

```powershell
dart run benchmark/pulse_slab_benchmark.dart
```

When Chrome is available, run the browser smoke test as well:

```powershell
dart test -p chrome test/web_portability_test.dart
```

## Current limitations

- Fixed record layouts are runtime descriptors; code generation is planned but not included.
- A layout is limited to 31 independently dirty-tracked fields so masks remain exact on native and JavaScript targets.
- `Int64Field` and legacy `Uint64Field` encode two 32-bit words, so the core remains runnable on Flutter web. `Uint64Field` keeps its signed two's-complement `int` bit-pattern behavior for compatibility. Use `Uint64ValueField` for new portable full-width unsigned identifiers, counters, or comparisons.
- Writes are single-isolate and single-writer; nested transactions are rejected, while listener-initiated follow-up transactions use the documented delivery policy semantics.
- Transaction actions, record listeners, and invalidation callbacks are synchronous APIs.
- The journal represents replaceable state, not lossless events.
- Zero-copy fixed-byte views are read-only aliases valid only while the record remains live.
- The worker supports focused byte-batch transforms rather than arbitrary closures.
- No FFI or native shared-memory backend is required or implied.

## Pub.dev readiness

The package includes pub.dev metadata, semantic versioning, license, changelog, a Dart example, tests, benchmarks, and analysis configuration. It is ready for release verification; see the repository [release automation guide](../../docs/releasing.md) for the tagged publishing process. The Flutter adapter is separately publishable and the telemetry example is independently runnable from `packages/pulse_slab_flutter`.

## Further reading

- [Architecture](https://github.com/JohannesHupp/pulse_slab/blob/main/docs/architecture.md)
- [Memory model](https://github.com/JohannesHupp/pulse_slab/blob/main/docs/memory_model.md)
- [Performance](https://github.com/JohannesHupp/pulse_slab/blob/main/docs/performance.md)
- [Concurrency](https://github.com/JohannesHupp/pulse_slab/blob/main/docs/concurrency.md)
- [Roadmap](https://github.com/JohannesHupp/pulse_slab/blob/main/docs/roadmap.md)
