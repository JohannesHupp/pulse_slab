# Repository tools

This directory is reserved for repository-level maintenance tooling. The project keeps its executable benchmark with the publishable package so it can run after checking out only `packages/pulse_slab`.

Initialize the shared Pub workspace from the repository root, then run Dart
core checks from `packages/pulse_slab`:

~~~powershell
dart pub get
dart pub workspace list
cd packages/pulse_slab
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
dart test -p chrome test/web_portability_test.dart
dart run benchmark/pulse_slab_benchmark.dart
dart pub publish --dry-run
~~~

Run Flutter adapter and telemetry example checks from
`packages/pulse_slab_flutter` and `packages/pulse_slab_flutter/example`.
The root README contains the complete verification command set.
