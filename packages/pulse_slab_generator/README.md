# pulse_slab_generator

`pulse_slab_generator` is the optional, first-party build-time companion to
[`pulse_slab`](https://pub.dev/packages/pulse_slab). It emits stable typed
field descriptors, precomputed layout metadata, store access helpers, binary
serializers/deserializers, and validation hooks from annotated Dart records.

The core package remains fully usable with hand-authored `RecordLayout` and
`Field` descriptors. Add this package only in applications that want generated
schemas. The generator requires Dart 3.9 or later; `pulse_slab` itself keeps
its Dart 3.6 runtime floor and has no build-time dependencies. The generator
belongs in `dev_dependencies`, so it is never a runtime dependency of the app.

## Usage

Add matching hosted versions of the runtime package and builder. The generator
is used only at build time:

```yaml
dependencies:
  pulse_slab: ^0.3.0-beta.1

dev_dependencies:
  build_runner: ^2.14.1
  pulse_slab_generator: ^0.3.0-beta.1
```

For development against a checkout, override both packages to the same local
source. This avoids mixing unreleased generator APIs with an older hosted core:

```yaml
dependency_overrides:
  pulse_slab:
    path: ../pulse_slab/packages/pulse_slab
  pulse_slab_generator:
    path: ../pulse_slab/packages/pulse_slab_generator
```

Declare an immutable record and add a part directive:

```dart
import 'package:pulse_slab/pulse_slab.dart';

part 'sensor_state.g.dart';

@SlabRecord(byteOrder: SlabByteOrder.little)
final class SensorState {
  const SensorState({
    required this.sequence,
    required this.counter,
    required this.temperature,
    required this.active,
    required this.identity,
  });

  @SlabField(kind: SlabFieldKind.uint32)
  final int sequence;

  @SlabField(kind: SlabFieldKind.uint64Value)
  final Uint64Value counter;

  @SlabField(kind: SlabFieldKind.float32)
  final double temperature;

  @SlabField(kind: SlabFieldKind.boolean)
  final bool active;

  @SlabField(kind: SlabFieldKind.fixedBytes, length: 16)
  final Uint8List identity;
}
```

Run the generator:

```sh
dart run build_runner build
```

The generated `sensor_state.g.dart` file contains `SensorStateLayout`, which
exposes `layout`, stable typed field descriptors, field offsets and indexes,
compact masks where applicable, `read`, `write`, `serialize`, `deserialize`,
`validate`, and `validateBytes`. Its read/write helpers use the
descriptor objects directly; they never perform name lookups or reflection.
Offsets, indexes, field order, and record size are literal generated metadata.
The singleton `RecordLayout` still performs its existing one-time runtime
validation and descriptor binding when the schema is first used.

Schemas with at most 31 fields also expose `allFieldsMask` and
`<field>Mask`. Wider generated schemas instead expose the portable
`allFieldsSelection` and `<field>Selection` getters, plus `<field>Index`.
Pass those selections to `PulseStore.watch(selection: ...)`; no generated
wide-layout access needs a string lookup or an imprecise JavaScript mask.

Use `dart run build_runner watch` while editing declarations. Generated source
is deterministic and may be checked into source control. See
[the complete runnable schema example](example/).

## Supported declarations

All non-static instance fields must be `final` and annotated. The generator
supports `int` (`int8` through `uint64`), `Uint64Value` (`uint64Value`),
`double` (`float32` and `float64`), `bool` (`boolean`), and `Uint8List`
(`fixedBytes` with a positive `length`).
An unnamed generative constructor must accept every declared field as its
matching initializing formal (for example, `this.sequence`), so the generated
deserializer can rebuild the value object without transforming encoded values.

Declaration errors are reported by `build_runner` with the field and reason.
Generated `validate` uses the same integer-range and fixed-byte-length rules
as the corresponding runtime fields. `uint64` retains Pulse Slab's legacy
signed two's-complement `int` representation and web precision caveat. Use
`uint64Value` with `Uint64Value.fromWords(highWord: ..., lowWord: ...)` for
exact full-width unsigned identifiers, counters, comparison, and byte
serialization on web targets.
