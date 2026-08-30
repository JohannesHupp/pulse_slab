# Performance

## Performance model

`pulse_slab` targets workloads in which inputs change more frequently than consumers can usefully observe them. The core package and Flutter adapter reduce unnecessary work through:

- Typed contiguous segment buffers for scalar data.
- Stable field descriptors and precomputed offsets instead of name lookup in reads and writes.
- One net dirty mask and version increment per changed record per transaction.
- Per-record subscription lists and field-mask filtering.
- Bounded journals and delivery policies for replaceable state.
- Flutter frame coalescing, which limits UI-facing notifications to at most one per frame by default.

These are workload-specific trade-offs, not universal wins. Fixed layouts suit scalar records but not arbitrary object graphs. Typed-memory access is less convenient than immutable Dart model classes. Coalescing deliberately discards intermediate *state observations* for a consumer and must not be used for lossless event semantics.

## Transaction allocation behavior

The transaction path avoids a second full-record copy during final net-change detection. It captures an original record image lazily only after a field write actually changes bytes, stores that image in a reusable store-owned typed-data scratch arena, uses it for rollback when needed, and compares the final record against it at commit. The arena grows only when a transaction reaches a new high-water byte requirement and reuses its capacity for later transactions. A write-then-restore sequence therefore produces no version increment, journal entry, or notification.

Segments, slot metadata, free-list entries, and journal storage are reused. Application layouts, listeners, subscriptions, and transaction objects still allocate at their normal setup boundaries; applications should create them during setup rather than per input update. Measure the entire producer-to-consumer path before drawing conclusions about allocation pressure.

The scratch arena retains its largest observed transaction footprint until the
store is disposed. This trades a predictable high-water allocation for steady
state reuse; isolate unusually large bulk transactions in a short-lived store
when retaining that capacity would be undesirable.

## Batching and coalescing

Use an explicit transaction when multiple field writes form one logical update. The store compares values where practical and omits a commit when no field has a net change:

| Delivery policy | Consumer behavior | Bound |
| --- | --- | --- |
| `immediate` | Matching listeners run after the commit. | No normal queue; reentrant listener calls use a fixed replaceable queue. |
| `latest` | Each subscription retains only its latest relevant change until a flush. | One pending change per subscription. |
| `batched` | Compact changes accumulate until an explicit flush. | Journal and subscription bounds apply. |

The Flutter adapter uses a frame scheduler by default. It can accept many core commits while a widget receives only the latest state for its selected fields once per rendered frame. Manual flushing remains available for deterministic widget tests.

## Journals, overflow, and metrics

Journal capacity is fixed. Overwrite behavior discards the oldest replaceable observation when full. Reject-newest behavior preserves the committed state but rejects journal admission and increments `PulseStore.rejectedJournalChangeCount`. Neither policy silently turns a lossless event into a best-effort state update.

Treat journal utilization, overwrite counts, rejected admissions, raw input
count, committed record count, and UI delivery count as distinct operational
signals. The Flutter telemetry example is designed to make their relationship
visible at high configured input rates. Its default journal mode samples and
clears every 250 ms, so stable utilization represents a recent observation
window rather than accumulated backlog. Its retained pressure modes use a small
fixed journal to demonstrate overwrite-oldest and reject-newest behavior.

## Running benchmarks

Run the core benchmarks from the pure Dart package:

```powershell
dart pub get
cd packages/pulse_slab
dart run benchmark/pulse_slab_benchmark.dart
```

The suite covers sequential typed writes, random record updates, transaction throughput, unfiltered and field-filtered dispatch, frame-style coalescing, slot reuse, an object-model baseline, and a small notifier-style baseline. It reports elapsed time, operations per second, notifications, and coalesced notifications. Allocation and memory fields are reported only when the runtime exposes measured values.

Benchmark output is machine-, SDK-, build-mode-, and workload-dependent. Treat it as a regression signal rather than a package-wide performance claim.

## Profiling the Flutter example

```powershell
dart pub get
cd packages/pulse_slab_flutter/example
flutter run --profile
```

Use Flutter DevTools to inspect frame time, rebuild counts, CPU samples, and
allocations. Raise the simulated update rate until input or UI work becomes
visible, then compare raw inputs, committed records, transaction-compacted
inputs, frame deliveries, frame-coalesced changes, simulation drops, and
journal metrics. Select Burst transactions to make several synchronous commits
arrive before one Flutter frame. The difference should come from intentional
filtering and coalescing, not an unbounded queue or hidden lossless-event
assumption.

The example intentionally keeps all 24 sensor charts mounted in a two-column
grid, which creates a controlled widget and paint workload. Each chart records
at most one latest-state sample per frame-coalesced delivery rather than one
sample per raw producer input. Its top-right FPS indicator is derived from
Flutter engine timing records and is most useful in profile or release mode.

## Why input frequency is not UI frequency

A screen cannot use every intermediate value that arrives between two frames. Rebuilding a widget for each incoming update wastes build, layout, paint, and garbage-collection budget. The data plane should process every important input to keep state current; the UI plane should receive the newest relevant state when it can render it.
