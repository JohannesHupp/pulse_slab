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

Field descriptor names are metadata. Hot reads and writes use the stable descriptor and its resolved byte offset, not a string lookup.

## Field selection for wide layouts

Layouts with at most 31 fields retain the compact, non-negative integer-mask
fast path used above: `Field.mask`, `RecordLayout.maskFor`, and
`watch(fields: ...)` continue to work without a new representation or
per-change selection allocation. Layouts can now contain more fields. For a
wide layout, create a layout-scoped `FieldSelection` and pass it through the
`selection:` parameter instead:

```dart
final metrics = List<Uint32Field>.generate(
  63,
  (index) => Uint32Field('metric_$index'),
);
final metricsLayout = RecordLayout(
  name: 'Metrics',
  fields: metrics,
);
final metricsStore = PulseStore();
final metricsHandle = metricsStore.allocate(metricsLayout);

final visibleMetrics = metricsLayout.selectionFor(<Field<Object?>>[
  metrics[0],
  metrics[31],
  metrics[62],
]);
final metricsSubscription = metricsStore.watch(
  metricsHandle,
  selection: visibleMetrics,
  listener: (change) {
    if (change.fieldSelection.contains(metrics[62])) {
      // Refresh the part of the view that consumes metric 62.
    }
  },
);

metricsSubscription.dispose();
metricsStore.dispose();
```

`FieldSelection` is tied to its `RecordLayout`, so selections from unrelated
layouts cannot be merged or compared. Use `Field.selection` when selecting one
bound field, or `layout.selectionFor(...)` for a setup-time union. Do not use
the legacy `Field.mask`, `layout.maskFor`, or `watch(fields: ...)` filtering
APIs for a wide layout: they deliberately remain compact-only and reject a
wide selection rather than truncate it.

`RecordChange.fieldSelection` always reports the exact changed fields and is
the portable change representation for a wide layout. Its integer
`fieldMask` accessor throws for a wide change. Likewise, a wide
`ChangeRecord` has a non-null `fieldSelection`, while accessing its
`fieldMask` throws. Compact journal records continue to use their integer
mask column.

## Optional generated layouts

The manual `RecordLayout` and `Field` API shown above remains fully supported
and needs no build step. For stable schemas that benefit from generated
boilerplate, add the first-party
[`pulse_slab_generator`](https://pub.dev/packages/pulse_slab_generator) tool.
It is an opt-in pub.dev development dependency: `pulse_slab` has no
`build_runner` or generator dependency and continues to support Dart 3.6 or
later, while `pulse_slab_generator` requires Dart 3.9 or later.

```yaml
dependencies:
  pulse_slab: ^0.3.0-beta.1

dev_dependencies:
  build_runner: ^2.14.1
  pulse_slab_generator: ^0.3.0-beta.1
```

The generator's own README contains the full hosted and local-development
workflow. When developing local core and generator changes outside this
repository's Pub workspace, add development-only overrides in the consuming
app to keep both packages on the same checkout:

```yaml
dependency_overrides:
  pulse_slab:
    path: ../pulse_slab/packages/pulse_slab
  pulse_slab_generator:
    path: ../pulse_slab/packages/pulse_slab_generator
```

Annotate an immutable schema in the core package's public API and declare its
generated part:

```dart
import 'package:pulse_slab/pulse_slab.dart';

part 'sensor_state.g.dart';

@SlabRecord(byteOrder: SlabByteOrder.little)
final class SensorState {
  const SensorState({required this.sequence, required this.identity});

  @SlabField(kind: SlabFieldKind.uint32)
  final int sequence;

  @SlabField(kind: SlabFieldKind.fixedBytes, length: 16)
  final Uint8List identity;
}
```

Generate the part with:

```sh
dart run build_runner build
```

The generated `SensorStateLayout` provides stable typed descriptors,
precomputed offsets, indexes, and size metadata, plus compact masks for layouts
through 31 fields or exact selections for wider layouts. It also provides a
singleton `RecordLayout`, typed store reads and writes, and `serialize`,
`deserialize`, `validate`, and `validateBytes` helpers. Its hot reads and
writes use the generated descriptors and offsets directly, with no field-name
lookup or runtime reflection. Supported declarations cover integer and
floating-point scalar fields, `Uint64Value`, `bool`, and fixed-length
`Uint8List` fields; invalid declarations are reported by `build_runner`.
Generated source is deterministic and may be checked in. See the
[complete generated-layout example](https://pub.dev/packages/pulse_slab_generator/example)
for the full workflow and API. Generated records use `final` fields and an
unnamed generative constructor with matching `this.field` initializing formals,
so a deserializer cannot transform an encoded value while rebuilding the
object.

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
| `batched` | Retains bounded state changes until `flush()`. | Fixed journal and subscription bounds. |

Subscriptions are scoped to one handle and may filter by a compact field mask or
a wide `FieldSelection`. Dispatch order is registration order. Removing a
subscription during dispatch is safe; a removed listener will not be invoked
later in the same dispatch. A listener may start a new transaction after the
original commit. A reentrant immediate change commits synchronously but its
immediate listener calls wait until the active traversal finishes. The fixed
`maxReentrantImmediateDeliveries` queue replaces its oldest pending state
delivery when full and increments `droppedReentrantImmediateDeliveryCount`; it
never rejects a committed write. Reentrant `latest` and `batched`
subscriptions are routed into their own bounded policy queues immediately, so
their coalescing semantics are preserved. Latest and batched delivery retain
changes until the next explicit flush. `flush()` rejects reentrant calls from a
latest or batched delivery callback. Prefer deferring feedback loops when a
flat callback sequence is easier to reason about.

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

This package reduces allocations and redundant work through typed byte storage,
reusable slots, compact masks or wide field selections, transaction merging,
bounded journals, and targeted listener lists. The separate Flutter adapter
adds frame coalescing. Those techniques are workload-specific trade-offs, not a
claim that every application will be faster. Benchmark on the target device and
workload.

Run the included smoke benchmark:

```powershell
dart run benchmark/pulse_slab_benchmark.dart
```

When Chrome is available, run the browser smoke test as well:

```powershell
dart test -p chrome test/web_portability_test.dart
```

## Current limitations

- Generated layouts are optional. Hand-authored `RecordLayout` and `Field`
  descriptors remain the supported build-free API; projects that opt into
  `pulse_slab_generator` need Dart 3.9 or later.
- Integer-mask filtering is intentionally limited to compact layouts with at
  most 31 fields. Wider layouts use layout-scoped `FieldSelection` values;
  this preserves portable exactness at the cost of word-based selection work.
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
