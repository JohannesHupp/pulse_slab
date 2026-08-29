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

## Publication staging

Create an isolated workspace containing only the two publishable packages:

~~~powershell
dart tools/prepare_publish_packages.dart
~~~

The command replaces the repository-local `publish/` directory after checking
that it is a safe direct child of the repository. The staged workspace contains
`packages/pulse_slab` and `packages/pulse_slab_flutter`, excludes every
`example` directory, and removes the adapter's nested example workspace entry.
It is the reviewable publication artifact uploaded by CI; do not commit
generated `publish/` output.

CI copies this snapshot to the runner's temporary directory before resolving
dependencies and running `flutter pub publish --dry-run`. The temporary copy
has no Git checkout as an ancestor, which prevents Pub's Git-state validation
from treating the generated, Git-ignored snapshot as source checkout content.
Use the same pattern locally when validating the staged archive:

~~~powershell
$publishWorkspace = Join-Path $env:TEMP ('pulse-slab-publish-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $publishWorkspace | Out-Null
Copy-Item -Path publish\* -Destination $publishWorkspace -Recurse -Force
Push-Location $publishWorkspace
flutter pub get
Push-Location packages/pulse_slab
flutter pub publish --dry-run
Pop-Location
Push-Location packages/pulse_slab_flutter
flutter pub publish --dry-run
Pop-Location
Pop-Location
Remove-Item -LiteralPath $publishWorkspace -Recurse -Force
~~~

The source package `.pubignore` files remain a second safeguard that excludes
examples from actual pub.dev archives.

Remove generated staging output with:

~~~powershell
dart tools/prepare_publish_packages.dart --clean
~~~

## Coverage summary

The CI workflow writes a compact per-package LCOV table to the GitHub Actions
job summary. Generate the same Markdown report locally after collecting core
and Flutter coverage:

~~~powershell
dart run tools/coverage_summary.dart --input pulse_slab=packages/pulse_slab/coverage/lcov.info --input pulse_slab_flutter=packages/pulse_slab_flutter/coverage/lcov.info --output coverage/summary.md
~~~
