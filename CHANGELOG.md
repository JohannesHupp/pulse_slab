# Changelog

Repository-level changes are summarized here. Each publishable package maintains its own changelog:

- [`pulse_slab`](packages/pulse_slab/CHANGELOG.md)
- [`pulse_slab_flutter`](packages/pulse_slab_flutter/CHANGELOG.md)

## Unreleased

- Create one package-specific GitHub Release after each successful tag-triggered
  pub.dev publication, marking semantic prereleases as GitHub pre-releases.
- Add an idempotent manual workflow for backfilling GitHub Releases for existing
  package tags without calling pub.dev again.

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
