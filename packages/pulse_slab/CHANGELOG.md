# Changelog

## Unreleased

## 0.3.0-beta.3

- Added the compact core developer example to the pub.dev archive.

## 0.3.0-beta.2

- Added opt-in versioned committed-record capture, checkpoints, and ordered
  replay contracts, while leaving the default store on its in-memory path.
- Documented the bounded `immediate`, `latest`, and `batched` state-delivery
  contract, including reentrancy, flush, and lifecycle behavior.
- Added allocation-free per-subscription `pendingDeliveries`, `deliveredCount`,
  `coalescedCount`, and `droppedCount` diagnostics.

## 0.3.0-beta.1

- Aligned the core package release line with the Flutter adapter at `0.3.0-beta.1`.
- Added an optional `pulse_slab_generator` workflow for annotated record
  schemas. It emits stable descriptors and precomputed layout metadata plus
  typed access, serialization, deserialization, and validation helpers. The
  first-party generator is available as an opt-in pub.dev development
  dependency; the manual `RecordLayout` API remains supported with no build
  dependency, and the generator requires Dart 3.9 or later.
- Documented the expanded telemetry diagnostics available through the Flutter
  adapter example.
- Added portable `FieldSelection` support for layouts with more than 31
  independently tracked fields while retaining the compact `FieldMask` fast
  path for existing layouts.
- Added `Uint64Value` and `Uint64ValueField` for exact portable unsigned
  64-bit values on Dart VM and web targets, while retaining legacy
  `Uint64Field` raw signed two's-complement compatibility.

## 0.2.0-beta.2

- Prepare the next prerelease after the initial manual pub.dev bootstrap
  publication.

## 0.2.0-beta.1

- Split Flutter framework bindings into the separately publishable `pulse_slab_flutter` package.
- Kept this package Flutter-free for Dart-only data-plane consumers.
- Added lifecycle invalidation callbacks for released records and disposed stores.
- Hardened transaction, journal, and listener delivery behavior, including reusable transaction scratch storage, synchronous callback boundaries, store-owned handles, portable field masks, bounded ordered reentrant immediate delivery, and Dart web-compatible typed-memory columns and 64-bit field encoding.

## 0.1.0

- Initial release.
- Added fixed-layout typed-memory records with stable generation-checked handles.
- Added transactions, dirty-field masks, bounded journals, and field-filtered subscriptions.
- Added immediate, latest, and explicit batched delivery policies.
- Added a frame-coalesced Flutter adapter and a bounded byte-batch worker.
