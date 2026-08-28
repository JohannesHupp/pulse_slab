# pulse_slab

[![pub package](https://img.shields.io/pub/v/pulse_slab.svg)](https://pub.dev/packages/pulse_slab)

A compact, transactional reactive data store for high-throughput Dart and Flutter applications. `pulse_slab` stores fixed-layout scalar records in reusable typed-memory segments, assigns stable generation-checked handles, and delivers only the committed field changes each consumer selected.

## Why the name?

**pulse** describes a continuous real-time signal; **slab** describes reusable segmented memory. The name communicates the package's high-rate, memory-oriented focus without borrowing the identity of an existing state-management framework. It follows pub.dev's lowercase-underscore naming convention.

## Suitable use cases

- High-frequency telemetry, monitoring, simulation, gaming, and industrial-control views.
- Thousands of compact numeric record updates per second.
- Flutter surfaces where the UI should receive the newest relevant state once per frame, not every input update.
- Data pipelines that benefit from explicit record layouts, typed field descriptors, transaction boundaries, and bounded change retention.

## Not suitable for

- Arbitrary nested object graphs, richly relational domain models, or a general application-architecture framework.
- Lossless business-event delivery. A coalesced state update is intentionally replaceable; use an acknowledged event transport for events that must never be lost.
- Sharing normal Dart heap memory between isolates. The worker API transfers bytes and preserves isolate ownership.

## Installation

The package has not been published yet. Once it is available, use the released version from pub.dev:

```yaml
dependencies:
  pulse_slab: ^0.1.0
```

For local development in this repository, point a consuming package at `../packages/pulse_slab`.

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

Field descriptor names are metadata. Hot reads and writes use the stable descriptor and its resolved byte offset, not a string lookup. A layout permits at most 63 dirty-tracked fields because it uses a non-negative signed integer field mask.

## Delivery policies

| Policy | Behavior | Queue bound |
| --- | --- | --- |
| `immediate` | Calls matching listeners immediately after a successful commit. | No pending state queue. |
| `latest` | Keeps only the latest merged state change per subscription until `flush()`. | One pending change per subscription. |
| `batched` | Retains compact changes until `flush()`. | Fixed journal and subscription bounds. |

Subscriptions are scoped to one handle and may filter by a field mask. Dispatch order is registration order. Removing a subscription during dispatch is safe; a removed listener will not be invoked later in the same dispatch. A listener may start a new transaction after the original commit. With immediate delivery that nested change can dispatch synchronously; latest and batched delivery retain it until the next explicit flush. Prefer deferring feedback loops when a flat callback sequence is easier to reason about.

While a transaction callback is active, public `read`, `versionOf`, `watch`, and
`flush` calls reject access. Use the transaction writer's `get` method for an
in-transaction read. This prevents synchronous consumers from observing
partially written record bytes before the commit boundary.

## Flutter integration

Import the self-contained Flutter facade in Flutter code. It re-exports the core data-plane API as well as Flutter adapters:

```dart
import 'package:pulse_slab/pulse_slab_flutter.dart';

ReactiveRecordBuilder(
  store: store,
  handle: sensor,
  fields: temperature.mask,
  builder: (context, record) {
    return Text(record.get(temperature).toStringAsFixed(1) + ' C');
  },
);
```

The builder owns a field-filtered subscription and uses frame-coalesced notification by default. A temperature-only builder does not rebuild when only `status` changes. For deterministic widget tests, use `ReactiveRecordListenable` with `FlutterDeliveryPolicy.manual`, call its `flush()`, and then pump the test widget.

The separate [Flutter telemetry example](example) simulates multiple sensors at configurable high update rates. It displays processed input updates, UI-delivered updates, rebuild count, coalesced state updates, and journal utilization.

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

This package reduces allocations and redundant work through typed byte storage, reusable slots, field masks, transaction merging, bounded journals, targeted listener lists, and Flutter frame coalescing. Those techniques are workload-specific trade-offs, not a claim that every application will be faster. Benchmark on the target device and workload.

Run the included smoke benchmark:

```powershell
dart run benchmark/pulse_slab_benchmark.dart
```

## Current limitations

- Fixed record layouts are runtime descriptors; code generation is planned but not included.
- A layout is limited to 63 independently dirty-tracked fields.
- `Uint64Field` retains all raw bits, but values with bit 63 set read as signed two's-complement Dart `int` values; use it as a bit pattern when unsigned arithmetic is needed.
- Writes are single-isolate and single-writer; nested transactions are rejected, while listener-initiated follow-up transactions use the documented delivery policy semantics.
- The journal represents replaceable state, not lossless events.
- Zero-copy fixed-byte views are read-only aliases valid only while the record remains live.
- The worker supports focused byte-batch transforms rather than arbitrary closures.
- No FFI or native shared-memory backend is required or implied.

## Pub.dev readiness

The package includes pub.dev metadata, semantic versioning, license, changelog, example, tests, benchmarks, and analysis configuration. It is prepared for review and a dry run; it is not published by this repository.

## Further reading

- [Architecture](https://github.com/pulse-slab/pulse_slab/blob/main/docs/architecture.md)
- [Memory model](https://github.com/pulse-slab/pulse_slab/blob/main/docs/memory_model.md)
- [Performance](https://github.com/pulse-slab/pulse_slab/blob/main/docs/performance.md)
- [Concurrency](https://github.com/pulse-slab/pulse_slab/blob/main/docs/concurrency.md)
- [Roadmap](https://github.com/pulse-slab/pulse_slab/blob/main/docs/roadmap.md)
