# Repository tools

This directory is reserved for repository-level maintenance tooling. The initial MVP keeps its executable benchmark with the publishable package so it can run after checking out only `packages/pulse_slab`.

Run package checks from `packages/pulse_slab`:

```powershell
flutter pub get
dart format .
flutter analyze
flutter test
dart run benchmark/pulse_slab_benchmark.dart
dart pub publish --dry-run
```

