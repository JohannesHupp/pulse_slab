# Performance

## Performance model

`pulse_slab` aims to reduce work in workloads where input changes are more frequent than useful consumer delivery. Its expected advantages come from:

- Typed contiguous segment buffers for scalar data.
- Stable field descriptors and precomputed offsets rather than name lookup during reads and writes.
- One merged dirty mask and version increment per changed record per transaction.
- Per-record subscription lists and field-mask filtering.
- Bounded journals and delivery policies that coalesce replaceable state.
- Flutter frame coalescing, which limits UI-facing notifications to at most one per frame by default.

These are trade-offs, not universal wins. Fixed layouts suit scalar records but not arbitrary object graphs. Typed-memory access can be less convenient than immutable Dart model classes. Coalescing deliberately discards intermediate *state observations* for a consumer; it must not be used for lossless event semantics.

## Batching and coalescing

Use an explicit transaction when multiple field writes form one logical update. The store compares values where practical and omits a commit when no field changed. `immediate` delivery notifies after commit, `latest` replaces pending state for a consumer with the newest version, and `batched` retains compact changes until `flush` is called.

The Flutter adapter uses a frame scheduler by default. It can accept thousands of store commits per second while a widget receives only relevant, latest state once per rendered frame.

## Allocation strategy

Segments and their slot metadata are reused. Release returns a slot to a free list. Transaction bookkeeping and journal entries use compact scalar metadata. Application listeners, layout descriptors, and subscription objects still allocate normally; applications should create them at setup time rather than per input update.

## Running benchmarks

From the package directory:

```powershell
dart run benchmark/pulse_slab_benchmark.dart
```

The benchmark covers sequential typed writes, random updates, transaction throughput, unfiltered and field-filtered dispatch, frame-style coalescing, slot reuse, an object-model baseline, and a small notifier-style baseline. It reports elapsed time, operations per second, notifications, and coalesced notifications. It does not fabricate allocation or memory numbers: those fields are shown only when the runtime exposes a measured value.

Benchmark output is machine-, SDK-, build-mode-, and workload-dependent. Treat it as a regression signal, not a package-wide performance claim.

## Profiling the example

```powershell
cd example
flutter run --profile
```

Use Flutter DevTools to inspect frame time, rebuild counts, CPU samples, and allocations. Raise the simulated update rate until input work or UI work becomes visible, then compare processed updates to UI-delivered updates. The difference should come from intentional field filtering and frame coalescing, not dropped input processing.

## Why input frequency is not UI frequency

A screen cannot use every intermediate value that arrives between two frames. Rebuilding a widget for each incoming update wastes build, layout, paint, and garbage-collection budget. The data plane should process every important input to keep state current; the UI plane should receive the newest relevant state when it can render it.

