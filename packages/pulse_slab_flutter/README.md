# pulse_slab_flutter

[![pub package](https://img.shields.io/pub/v/pulse_slab_flutter.svg)](https://pub.dev/packages/pulse_slab_flutter)

Frame-coalesced Flutter bindings for the pulse_slab typed-memory reactive data
store. The adapter keeps high-rate store writes in the data plane while Flutter
widgets receive only relevant, committed record changes at a chosen UI cadence.

## Installation

Once published, add the adapter to a Flutter application:

~~~yaml
dependencies:
  pulse_slab_flutter: ^0.2.0
~~~

The adapter depends on pulse_slab and re-exports its public Dart API. Import one
library in Flutter code:

~~~dart
import 'package:pulse_slab_flutter/pulse_slab_flutter.dart';
~~~

For local development in this repository, run `dart pub get` from the
repository root. Its Pub workspace resolves the adjacent 0.2.0 core package
without an override file. Publish `pulse_slab` 0.2.0 before publishing this
adapter's 0.2.0 release so normal pub resolution can use the core package.

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

Use unavailableBuilder when a released record needs a lifecycle-specific
replacement. The builder otherwise rethrows a stale-handle read error, which
makes unexpected record lifetime violations visible during development.

## Package boundaries

- pulse_slab is a Flutter-free Dart data-plane package containing layouts,
  segmented memory, transactions, subscriptions, journals, and worker support.
- pulse_slab_flutter contains Flutter framework imports and UI-plane adapters
  only.

The [telemetry example](example) drives multiple records at configurable rates
up to 1,000,000 updates per second. It shows processed updates, frame-delivered
UI updates, coalescing, widget rebuilds, journal utilization, and bounded
simulation drops.

## Limitations

This package is a UI adapter for replaceable state updates, not a lossless event
transport. It does not make Dart heap memory shared between isolates, and it
does not add a state-management architecture or global singleton.
