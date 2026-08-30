# Changelog

## 0.3.0-beta.1

- Added portable `selection:` filtering for `ReactiveRecordListenable`,
  `ReactiveRecordBuilder`, and `FrameCoalescingNotifier` on layouts with more
  than 31 independently tracked fields.
- Expanded the telemetry example with clearer transaction, journal, and
  frame-delivery diagnostics.
- Added temperature history views for all simulated sensors and a rendered FPS
  indicator.
- Added deterministic example coverage for frame-rate calculation, journal
  pressure behavior, transaction coalescing, and sensor rendering.

## 0.2.0-beta.2

- Prepare the next prerelease after the initial manual pub.dev bootstrap
  publication.

## 0.2.0-beta.1

- Introduced the standalone Flutter adapter package for pulse_slab.
- Added frame-coalesced, field-filtered record listenables and builders.
- Added the high-frequency Flutter telemetry example and widget test coverage.
