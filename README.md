# pulse_slab

`pulse_slab` is a high-throughput reactive data plane for fixed-layout scalar state. It processes frequent writes in compact typed-memory segments, commits logical updates transactionally, and delivers only the field-level state changes that each consumer selected.

Version 0.2.0-beta.2 separates the repository into two independently publishable packages:

| Package | Purpose | Runtime dependency |
| --- | --- | --- |
| [`pulse_slab`](packages/pulse_slab) | Pure Dart data plane: layouts, typed memory, handles, transactions, journals, subscriptions, and byte-batch workers. | Dart SDK only |
| [`pulse_slab_flutter`](packages/pulse_slab_flutter) | Flutter UI adapter: frame-coalesced listenables and field-filtered widgets. It re-exports the core API. | Flutter and `pulse_slab` |

Flutter applications can depend on `pulse_slab_flutter` alone when they want both the core and UI adapter. Dart-only services, command-line tools, and workers can depend on `pulse_slab` without pulling in Flutter.

The repository is a Dart Pub workspace. It resolves the versioned local core and
Flutter adapter together during development without publishing either package.
Workspace development requires Dart 3.6 or later.

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
|   `-- pulse_slab_flutter/       # Flutter adapter and telemetry example
|       `-- example/              # Independently runnable Flutter application
|-- .github/workflows/            # CI for both packages and the example
`-- tools/                        # Repository maintenance tooling
```

See the core [README](packages/pulse_slab/README.md), the Flutter adapter [README](packages/pulse_slab_flutter/README.md), and the [design documentation](docs/architecture.md).

## Release automation

Every push and pull request runs core, Flutter adapter, and telemetry-example tests before coverage collection and publication validation. The GitHub Actions summary includes a compact per-package coverage table, and the workflow uploads an isolated `publish/` artifact containing the two packages without their examples.

A verified push to `main` is a release: it creates versioned package tags and publishes the corresponding package to pub.dev through GitHub OIDC trusted publishing. The core is published before the Flutter adapter, and the adapter workflow waits for its required core version to become visible on pub.dev.

The first release of each package still requires the one-time pub.dev bootstrap and GitHub environment configuration described in [Release automation](docs/releasing.md). After that setup, maintainers release by updating the relevant package version and changelog, then merging the release change to `main`. The telemetry application remains an independently runnable example and is never published.

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
