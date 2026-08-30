# pulse_slab

`pulse_slab` is a high-throughput reactive data plane for fixed-layout scalar state. It processes frequent writes in compact typed-memory segments, commits logical updates transactionally, and delivers only the field-level state changes that each consumer selected.

Layouts of any width are supported. The existing integer mask remains the
allocation-free filtering fast path for layouts with at most 31 fields; wider
layouts use a portable, layout-scoped `FieldSelection`. See the core
[field-selection guide](packages/pulse_slab/README.md#field-selection-for-wide-layouts)
for the API and migration details.

Version 0.3.0-beta.1 contains three independently publishable packages:

| Component | Purpose | Distribution |
| --- | --- | --- |
| [`pulse_slab`](packages/pulse_slab) | Pure Dart data plane: layouts, typed memory, handles, transactions, journals, subscriptions, and byte-batch workers. | pub.dev |
| [`pulse_slab_generator`](packages/pulse_slab_generator) | Optional `build_runner` companion for typed layouts, serialization, and validation source. | pub.dev development dependency |
| [`pulse_slab_flutter`](packages/pulse_slab_flutter) | Flutter UI adapter: frame-coalesced listenables and field-filtered widgets. It re-exports the core API. | pub.dev |

Flutter applications can depend on `pulse_slab_flutter` alone when they want both the core and UI adapter. Dart-only services, command-line tools, and workers can depend on `pulse_slab` without pulling in Flutter.

Applications opt into `pulse_slab_generator` only when they want build-time
schema generation; hand-authored `RecordLayout` descriptors remain the
build-free runtime API. The generator is published on pub.dev and belongs only
in an application's `dev_dependencies`; it does not become a runtime
dependency. Its [README](packages/pulse_slab_generator/README.md) shows the
hosted installation and local development workflow.

The repository is a Dart Pub workspace. It resolves the local core, generator,
and Flutter adapter together during development. Workspace development requires
Dart 3.9 or later because of the generator's analyzer/source_gen dependencies.
The standalone `pulse_slab` runtime package remains compatible with Dart 3.6
or later.

## Name rationale

**pulse** represents a continuous high-frequency signal, and **slab** represents reusable segmented memory. The name is concise, describes the package's real-time and memory-oriented focus, follows pub.dev's lowercase-underscore convention, and does not imply affiliation with another state-management package.

## Suitable workloads

- Telemetry dashboards, monitoring panels, simulations, games, and industrial controls with frequent scalar updates.
- State that fits fixed-size records with stable handles and explicit field layouts.
- Applications that need to process every important input while coalescing replaceable state for downstream consumers.
- Flutter views that should receive the latest relevant state once per frame instead of rebuilding for every input update.

## Deliberate boundaries

- This is not a general application-architecture, navigation, dependency-injection, or arbitrary-object-graph framework.
- The bounded change journal represents replaceable state, not lossless domain events. Lossless events need a separately acknowledged transport.
- Ordinary Dart heap memory is not shared between isolates. The worker APIs transfer byte ownership; they do not expose a shared mutable store.
- The core is single-isolate and single-writer. Multi-writer synchronization is outside the current contract.

## Repository layout

```text
.
|-- docs/                         # Design, performance, and ownership notes
|-- packages/
|   |-- pulse_slab/               # Pure Dart, independently publishable core
|   |-- pulse_slab_generator/     # Optional typed-layout code generator
|   `-- pulse_slab_flutter/       # Flutter adapter and telemetry example
|       `-- example/              # Independently runnable Flutter application
|-- .github/workflows/            # CI for all packages and the example
`-- tools/                        # Repository maintenance tooling
```

See the core [README](packages/pulse_slab/README.md), the
[generator README](packages/pulse_slab_generator/README.md), the Flutter
adapter [README](packages/pulse_slab_flutter/README.md), and the [design
documentation](docs/architecture.md).

## Release automation

Every push and pull request runs core, generator, Flutter adapter, and
telemetry-example tests before coverage collection and publication validation.
Generator verification includes a checked-in generated-source freshness check
and its runnable example. The GitHub Actions summary includes a compact core
and Flutter-adapter coverage table, and the workflow uploads an isolated
`publish/` artifact containing all three pub.dev packages. The generator's
compact, runnable Dart example is retained in its archive; the core and Flutter
examples remain excluded.

A verified push to `main` is a release for a publishable package: it creates
versioned package tags and publishes the corresponding package to pub.dev
through GitHub OIDC trusted publishing. The core is published first; the
Flutter adapter and generator wait for their required core version to become
visible before publishing.

The first release of a new package requires the one-time pub.dev bootstrap and
GitHub environment configuration described in [Release
automation](docs/releasing.md). The three package records already exist on
pub.dev; before a release, maintainers still confirm the trusted-publisher and
GitHub environment settings. They then release by updating the relevant package
version and changelog, then merging the release change to `main`. The telemetry
application remains a repository component and is never published.

Repository and issue tracker:

- https://github.com/JohannesHupp/pulse_slab
- https://github.com/JohannesHupp/pulse_slab/issues

## Development and verification

Resolve the shared workspace once from the repository root. The individual
commands below can then run from their named package directory.

```powershell
dart pub get
dart pub workspace list

# Pure Dart core
cd packages/pulse_slab
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
dart test -p chrome test/web_portability_test.dart
dart pub publish --dry-run

# Optional build-time generator
cd ../pulse_slab_generator
dart format --output=none --set-exit-if-changed lib test example
dart analyze
dart run build_runner build
git diff --exit-code -- example/sensor_state.g.dart test/fixtures/all_scalar_record.g.dart test/fixtures/wide_record.g.dart
dart test
dart test -p chrome test/generated_web_portability_test.dart
dart run example/main.dart
dart pub publish --dry-run

# Flutter adapter
cd ../pulse_slab_flutter
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
dart pub publish --dry-run

# Flutter telemetry example
cd example
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter run --profile
```

Run the core benchmark separately:

```powershell
cd packages/pulse_slab
dart run benchmark/pulse_slab_benchmark.dart
```

Benchmark output is machine-, SDK-, build-mode-, and workload-dependent. It is a regression signal rather than a universal performance claim.
