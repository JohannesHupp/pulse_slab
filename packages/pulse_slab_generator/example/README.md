# Generated sensor-layout example

From `packages/pulse_slab_generator`, regenerate the checked-in part and run
the example:

```sh
dart run build_runner build --build-filter=example/sensor_state.g.dart
dart run example/main.dart
```

`sensor_state.dart` is the declaration users author. Its generated companion
contains literal offsets/masks, stable descriptors, binary serialization,
deserialization, and validation. The example then writes and reads the typed
model through a `PulseStore` transaction.
