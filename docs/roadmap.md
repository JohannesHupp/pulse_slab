# Roadmap

Version 0.2.0-beta.2 establishes a pure Dart data plane, a separately publishable Flutter adapter, deterministic bounded delivery behavior, and release-oriented verification. Future work should remain driven by measured workloads and preserve the ownership and lifecycle guarantees documented in this repository.

Potential future work includes:

- Layout code generation for static field descriptors, serializers, and validation.
- Native shared-memory backends with explicit ownership, synchronization, and isolate constraints.
- C and Rust integration layers.
- Atomic snapshot protocols for readers that need coordinated multi-record views.
- Double buffering for producer and consumer pipelines.
- SIMD-specialized bulk operations where they are measurable and portable.
- Carefully specified multi-writer support.
- Additional delivery policies and per-subscriber backpressure instrumentation.
- Optional Riverpod and Bloc adapters as external packages, not core dependencies.
- Persistent journal adapters for acknowledged lossless domain events.
- More detailed allocation, latency, and memory telemetry in benchmark tooling.
- Automated cross-platform benchmark comparison and regression thresholds after a representative workload suite is established.

The project will not claim transparent shared Dart-heap memory between isolates or universal performance gains. Any future native or concurrency feature must document ownership, copying, synchronization, shutdown, and failure semantics before it becomes part of the public contract.
