# Changelog

## 0.3.0-beta.1

- Aligned the core package release line with the Flutter adapter at `0.3.0-beta.1`.
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
