# Roadmap

Version 0.3.0-beta.2 adds optional committed-record capture and replay to the
pure Dart data plane, with a separately publishable native persistence backend.
It retains the separately publishable Flutter adapter, deterministic bounded
delivery behavior, and release-oriented verification established in the
previous release line. Future work should remain driven by measured workloads
and preserve the ownership and lifecycle guarantees documented in this
repository.

## Optional generated layouts

The first-party
[`pulse_slab_generator`](https://pub.dev/packages/pulse_slab_generator) package
now provides
an optional `build_runner` workflow for annotated immutable schemas. It emits
stable field descriptors, precomputed layout metadata, typed store accessors,
serializers, deserializers, and validation hooks for supported scalar and
fixed-byte fields. Generated reads and writes address descriptors and offsets
directly rather than using field-name lookup or runtime reflection.

This workflow is deliberately not required: hand-authored `RecordLayout` and
`Field` descriptors remain supported, and the core package keeps no generator
or build-time dependency. Applications add the generator from pub.dev as a
development dependency. The core supports Dart 3.6 or later; applications
that add `pulse_slab_generator` need Dart 3.9 or later. Its
[complete example](../packages/pulse_slab_generator/example/) documents the
declaration and generation command.

Potential future work includes:

- Native shared-memory backends with explicit ownership, synchronization, and isolate constraints.
- C and Rust integration layers.
- Atomic snapshot protocols for readers that need coordinated multi-record views.
- Double buffering for producer and consumer pipelines.
- SIMD-specialized bulk operations where they are measurable and portable.
- Carefully specified multi-writer support.
- Additional delivery policies.
- Optional Riverpod and Bloc adapters as external packages, not core dependencies.
- Persistent journal adapters for acknowledged lossless domain events.
- More detailed allocation, latency, and memory telemetry in benchmark tooling.
- Automated cross-platform benchmark comparison and regression thresholds after a representative workload suite is established.

The project will not claim transparent shared Dart-heap memory between isolates or universal performance gains. Any future native or concurrency feature must document ownership, copying, synchronization, shutdown, and failure semantics before it becomes part of the public contract.
