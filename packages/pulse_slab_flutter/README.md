# pulse_slab_flutter

[![pub package](https://img.shields.io/pub/v/pulse_slab_flutter.svg)](https://pub.dev/packages/pulse_slab_flutter)

Frame-coalesced Flutter bindings for the pulse_slab typed-memory reactive data
store. The adapter keeps high-rate store writes in the data plane while Flutter
widgets receive only relevant, committed record changes at a chosen UI cadence.

## Installation

Add the adapter to a Flutter application:

~~~yaml
dependencies:
  pulse_slab_flutter: ^0.3.0-beta.1
~~~

The adapter depends on pulse_slab and re-exports its public Dart API. Import one
library in Flutter code:

~~~dart
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';
~~~

For local development in this repository, run `dart pub get` from the
repository root. Its Pub workspace resolves the adjacent 0.3.0-beta.1 core package
without an override file. The repository release automation publishes
`pulse_slab` before this adapter and waits until the required core version is
available from pub.dev.

## Quick start

~~~dart
import 'package:flutter/widgets.dart';
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';

final temperature = Float32Field('temperature');
final layout = RecordLayout(
  name: 'Sensor',
  fields: <Field<Object?>>[temperature],
);
final store = PulseStore();
final handle = store.allocate(layout);

ReactiveRecordBuilder(
  store: store,
  handle: handle,
  fields: temperature.mask,
  builder: (context, record) {
    return Text(record.get(temperature).toStringAsFixed(1));
  },
);
~~~

ReactiveRecordBuilder owns a field-filtered store subscription. Its default
FlutterDeliveryPolicy.frame policy coalesces compatible changes and rebuilds at
most once per rendered frame. Use FlutterDeliveryPolicy.manual and flush on the
underlying ReactiveRecordListenable for deterministic widget tests or an
externally managed render loop.

## Layouts with more than 31 fields

The legacy `fields:` argument is an integer-mask fast path and remains the
best choice for compact layouts. For a layout with more than 31 independently
tracked fields, derive a portable, layout-scoped selection and pass it through
`selection:` instead:

~~~dart
final watched = layout.selectionFor(<Field<Object?>>[highIndexField]);

ReactiveRecordBuilder(
  store: store,
  handle: handle,
  selection: watched,
  builder: (context, record) => Text('${record.get(highIndexField)}'),
);
~~~

`selection:` cannot be combined with a nonzero `fields:` mask. The Flutter
adapter passes the selection to `PulseStore`, filters the resulting committed
changes, and coalesces their exact changed-field selection for the next frame.

Use unavailableBuilder when a released record needs a lifecycle-specific
replacement. The builder otherwise rethrows a stale-handle read error, which
makes unexpected record lifetime violations visible during development.

## Package boundaries

- pulse_slab is a Flutter-free Dart data-plane package containing layouts,
  segmented memory, transactions, subscriptions, journals, and worker support.
- pulse_slab_flutter contains Flutter framework imports and UI-plane adapters
  only.

The [telemetry example](example) drives multiple records at configurable rates
up to 1,000,000 updates per second. It distinguishes raw producer inputs,
net committed record changes, transaction compaction, frame delivery,
frame coalescing, widget rebuilds, and bounded journal behavior. Its controls
also demonstrate why a sampled-and-cleared journal can show stable utilization
while a retained pressure journal eventually overwrites or rejects observations.
The example also includes per-sensor charts and an FPS indicator for inspecting
UI behavior at high input rates.

## Limitations

This package is a UI adapter for replaceable state updates, not a lossless event
transport. It does not make Dart heap memory shared between isolates, and it
does not add a state-management architecture or global singleton.
