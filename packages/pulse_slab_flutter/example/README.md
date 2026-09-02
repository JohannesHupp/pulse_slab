# Minimal Flutter example

This directory is a compact source template for a Flutter application that
uses `pulse_slab_flutter`. Copy `lib/main.dart` into an application that has
the package as a dependency. It creates one typed record, updates it from a
button, and displays the latest committed value with `ReactiveRecordBuilder`.

The repository validates the template from `packages/pulse_slab_flutter`:

```sh
flutter test example/test/widget_test.dart
```

The high-rate telemetry integration demo is kept separately in
`demo/telemetry` and is not part of the pub.dev archive.
