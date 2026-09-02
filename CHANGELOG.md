# Changelog

Repository-level changes are summarized here. Each publishable package
maintains its own changelog:

- [`pulse_slab`](packages/pulse_slab/CHANGELOG.md)
- [`pulse_slab_persistence_io`](packages/pulse_slab_persistence_io/CHANGELOG.md)
- [`pulse_slab_generator`](packages/pulse_slab_generator/CHANGELOG.md)
- [`pulse_slab_flutter`](packages/pulse_slab_flutter/CHANGELOG.md)

[`pulse_slab_generator`](packages/pulse_slab_generator/CHANGELOG.md) is an
optional first-party pub.dev development dependency. It is released alongside
compatible `pulse_slab` versions, while the manual runtime API stays build-free.

## Unreleased

## 0.3.0-beta.2 (`pulse_slab`)

- Documented bounded state-delivery semantics and added allocation-free
  per-subscription delivery diagnostics for the core package.
- Added opt-in committed-record persistence and replay contracts in the core,
  for use with an optional native backend.

## 0.1.0-beta.1 (`pulse_slab_persistence_io`)

- Added the optional native `pulse_slab_persistence_io` backend.
- Added workspace, verification, coverage, publication snapshot, and tagged
  release automation for the native persistence package.

## 0.3.0-beta.2 (`pulse_slab_generator`)

- Restored compatibility with the current analyzer element API used by pub.dev
  package analysis.
- Declared the generator's native build-time platform support while preserving
  generated-layout portability to every `pulse_slab` runtime target.

## 0.3.0-beta.1

- Added the optional `pulse_slab_generator` pub.dev package for build-time
  typed layouts, serializers, deserializers, and validation hooks. The Dart
  3.6+ core retains its manual `RecordLayout` API and no build dependency.
- Added portable `FieldSelection` filtering for layouts with more than 31
  independently tracked fields while retaining the compact mask fast path.
- Added `Uint64Value` and `Uint64ValueField` for exact portable unsigned
  64-bit values, while retaining legacy `Uint64Field` raw-bit compatibility.
- Create one package-specific GitHub Release after each successful tag-triggered
  pub.dev publication, marking semantic prereleases as GitHub pre-releases.
- Add an idempotent manual workflow for backfilling GitHub Releases for existing
  package tags without calling pub.dev again.

- Expanded the Flutter telemetry example with clearer state-update diagnostics,
  sensor history views, and a rendered FPS indicator.
- Added deterministic telemetry-example coverage and documentation for the
  updated diagnostics.
- Stabilized line endings for tracked Flutter desktop registrant files.

## 0.2.0-beta.2

- Prepare the first tag-triggered pub.dev publication after the manual
  `0.2.0-beta.1` bootstrap releases.

## 0.2.0-beta.1

- Split the Dart-only data plane from the Flutter UI adapter into independently publishable packages.
- Documented the package boundary, isolate ownership model, transaction and delivery behavior, and release workflow.
- Added branch-wide CI for formatting, unit and integration tests, coverage summaries, publication dry runs, and example validation; verified `main` revisions create package tags for pub.dev trusted publishing.
- Added a reviewable `publish/` workflow artifact containing only the core and Flutter packages, with every example directory excluded.
- Hardened lifecycle and delivery behavior around listener-side release, disposal, failures, bounded ordered reentrant immediate delivery, bounded journal admission, reusable transaction scratch storage, transaction net-change tracking, store-owned handles, and Dart web-compatible typed-memory storage.

## 0.1.0

- Established the `pulse_slab` repository and its initial typed-memory reactive-store implementation.
