# Changelog

Repository-level changes are summarized here. Each publishable package maintains its own changelog:

- [`pulse_slab`](packages/pulse_slab/CHANGELOG.md)
- [`pulse_slab_flutter`](packages/pulse_slab_flutter/CHANGELOG.md)

## 0.2.0

- Split the Dart-only data plane from the Flutter UI adapter into independently publishable packages.
- Documented the package boundary, isolate ownership model, transaction and delivery behavior, and release workflow.
- Added CI coverage for formatting, analysis, tests, and publication dry runs for the core and Flutter adapter, plus analysis and tests for the example.
- Hardened lifecycle and delivery behavior around listener-side release, disposal, failures, bounded ordered reentrant immediate delivery, bounded journal admission, reusable transaction scratch storage, transaction net-change tracking, store-owned handles, and Dart web-compatible typed-memory storage.

## 0.1.0

- Established the `pulse_slab` repository and its initial typed-memory reactive-store implementation.
