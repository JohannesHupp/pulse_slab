# pulse_slab_generator

`pulse_slab_generator` is an internal, optional build-time companion to
[`pulse_slab`](https://pub.dev/packages/pulse_slab). It emits stable typed
field descriptors, precomputed layout metadata, store access helpers, binary
serializers/deserializers, and validation hooks from annotated Dart records.

It is intentionally **not** a separately published pub.dev package. Consume
it from this repository with a Git or local path dependency. This keeps the
generator's build-time toolchain out of the core package and avoids a separate
package release lifecycle.

The core package remains fully usable with hand-authored `RecordLayout` and
`Field` descriptors. Add this package only in applications that want generated
schemas. The generator requires Dart 3.9 or later; `pulse_slab` itself keeps
its Dart 3.6 runtime floor and has no build-time dependencies.

## Usage

Add the runtime package normally and the builder only as a development
dependency. Pin `ref` to a commit or a repository tag appropriate for your
application rather than following a moving branch in a release build:

```yaml
dependencies:
  pulse_slab: ^0.3.0-beta.1

dev_dependencies:
  build_runner: ^2.14.1
  pulse_slab_generator:
    git:
      url: https://github.com/JohannesHupp/pulse_slab.git
      path: packages/pulse_slab_generator
      ref: main
```

For an application developed in or next to a checkout of this repository, use
the equivalent local dependency instead (adjust the relative path to match
your repository layout):

```yaml
dev_dependencies:
  build_runner: ^2.14.1
  pulse_slab_generator:
    path: ../pulse_slab/packages/pulse_slab_generator
```

The local form keeps the normal hosted `pulse_slab` dependency shown above. If
you are changing both packages from local sources outside this repository's Pub
workspace, add a development-only override in the consuming app so both use
the same checkout:

```yaml
dependency_overrides:
  pulse_slab:
    path: ../pulse_slab/packages/pulse_slab
```

Declare an immutable record and add a part directive:

```dart
import 'package:pulse_slab/pulse_slab.dart';

part 'sensor_state.g.dart';

@SlabRecord(byteOrder: SlabByteOrder.little)
final class SensorState {
  const SensorState({
    required this.sequence,
    required this.temperature,
    required this.active,
    required this.identity,
  });

  @SlabField(kind: SlabFieldKind.uint32)
  final int sequence;

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
exposes `layout`, stable typed field
descriptors, field offsets and masks, `read`, `write`, `serialize`,
`deserialize`, `validate`, and `validateBytes`. Its read/write helpers use the
descriptor objects directly; they never perform name lookups or reflection.
Offsets, masks, field order, and record size are literal generated metadata.
The singleton `RecordLayout` still performs its existing one-time runtime
validation and descriptor binding when the schema is first used.

Use `dart run build_runner watch` while editing declarations. Generated source
is deterministic and may be checked into source control. See
[the complete runnable schema example](example/).

## Supported declarations

All non-static instance fields must be `final` and annotated. The generator
supports `int` (`int8` through `uint64`), `double` (`float32` and `float64`),
`bool` (`boolean`), and `Uint8List` (`fixedBytes` with a positive `length`).
An unnamed generative constructor must accept every declared field as its
matching initializing formal (for example, `this.sequence`), so the generated
deserializer can rebuild the value object without transforming encoded values.

Declaration errors are reported by `build_runner` with the field and reason.
Generated `validate` uses the same integer-range and fixed-byte-length rules
as the corresponding runtime fields. `uint64` retains Pulse Slab's signed
two's-complement `int` representation and web precision caveat.
