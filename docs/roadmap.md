# Roadmap

The current release focuses on fixed-layout scalar records and honest delivery semantics. Potential future work includes:

- Layout code generation for static field descriptors and serializers.
- A native shared-memory backend with explicit ownership and synchronization.
- C and Rust integration layers.
- An atomic snapshot protocol for readers that need coordinated multi-record views.
- Double buffering for producer/consumer pipelines.
- SIMD-specialized bulk operations where they are measurable and portable.
- Carefully specified multi-writer support.
- Additional delivery policies and per-subscriber backpressure instrumentation.
- Optional Riverpod and Bloc adapters in separate packages, not core dependencies.
- Persistent journal adapters for acknowledged lossless domain events.
- More detailed allocation and memory telemetry in benchmark tooling.
