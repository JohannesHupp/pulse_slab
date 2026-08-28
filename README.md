# pulse_slab

`pulse_slab` is a high-throughput reactive data-store MVP for Dart and Flutter. It keeps frequently changing scalar state in compact typed-memory segments, commits writes transactionally, and delivers only the field-level changes a consumer selected.

The publishable package lives in [`packages/pulse_slab`](packages/pulse_slab). This repository uses a small monorepo layout so the package, its Flutter example, benchmarks, and repository-level design notes can evolve together. The package itself is independently publishable.

## Name rationale

**pulse** represents a continuous high-frequency signal and **slab** represents reusable segmented memory. The name is short, descriptive, follows pub.dev's lowercase-underscore convention, and does not imply affiliation with another state-management package. A quick pub.dev search performed during initial development found no package using this exact name.

## What it is for

- Telemetry dashboards, monitoring panels, simulations, games, industrial controls, and other workloads with many scalar updates.
- State that can be represented as fixed-size records with stable handles.
- Flutter UIs that should consume coalesced projections rather than rebuild for every input update.

## What it is not for

- A replacement for general application architecture, navigation, dependency injection, or arbitrary object graphs.
- A lossless domain-event bus. Replaceable state changes can be coalesced; lossless events need a separately acknowledged channel.
- A shared mutable heap between Dart isolates. Isolates retain ownership of their own stores.

## Repository layout

```text
.
├── docs/                         # Design and operating documentation
├── packages/
│   └── pulse_slab/               # Independently publishable Flutter-compatible package
│       ├── benchmark/
│       ├── example/              # Separate Flutter telemetry application
│       ├── lib/
│       └── test/
└── tools/                        # Repository helper scripts
```

See the package [README](packages/pulse_slab/README.md) for installation and usage, and the design notes in [`docs/`](docs/architecture.md).

## Development

```powershell
cd packages/pulse_slab
flutter pub get
flutter analyze
flutter test
dart run benchmark/pulse_slab_benchmark.dart
dart pub publish --dry-run
```

The commands and benchmark results are intentionally machine-specific; they are not performance claims.

