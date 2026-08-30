# Generated sensor-layout example

From a checkout of `pulse_slab_generator` (including this repository),
regenerate the checked-in part and run the example:

```sh
dart run build_runner build --build-filter=example/sensor_state.g.dart
dart run example/main.dart
```

`sensor_state.dart` is the declaration users author. Its generated companion
contains literal offsets/masks, stable descriptors, binary serialization,
deserialization, and validation. The example then writes and reads the typed
model through a `PulseStore` transaction.
