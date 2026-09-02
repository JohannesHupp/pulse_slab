# Release automation

This repository treats `integration` as the default integration branch and
`main` as the release branch. Feature work starts from
`feature/<short-description>` and must pass the same verification workflow as
every other branch.

The workflow deliberately separates verification, immutable release tags, and
pub.dev publishing. Pub.dev's GitHub Actions trusted publishing flow is
tag-triggered, so a verified push to `main` first creates package-specific tags.
Those tags then start the publishing workflow.

~~~mermaid
flowchart LR
  Feature[feature/*] --> Verify[Verify packages]
  Integration[integration] --> Verify
  Main[main] --> Verify
  Verify --> Coverage[Coverage table and reports]
  Coverage --> Snapshot[publish artifact]
  Snapshot --> Tags[Create version tags]
  Tags --> CoreTag[pulse_slab-vX.Y.Z]
  Tags --> PersistenceTag[pulse_slab_persistence_io-vX.Y.Z]
  Tags --> GeneratorTag[pulse_slab_generator-vX.Y.Z]
  Tags --> FlutterTag[pulse_slab_flutter-vX.Y.Z]
  CoreTag --> CorePublish[Publish pulse_slab]
  PersistenceTag --> Wait[Wait for required core version]
  GeneratorTag --> Wait[Wait for required core version]
  FlutterTag --> Wait[Wait for required core version]
  CorePublish --> PubDev[pub.dev]
  CorePublish --> CoreRelease[Create pulse_slab GitHub Release]
  CorePublish --> Wait
  Wait --> PersistencePublish[Publish pulse_slab_persistence_io]
  Wait --> GeneratorPublish[Publish pulse_slab_generator]
  Wait --> FlutterPublish[Publish pulse_slab_flutter]
  PersistencePublish --> PubDev
  PersistencePublish --> PersistenceRelease[Create pulse_slab_persistence_io GitHub Release]
  GeneratorPublish --> PubDev
  GeneratorPublish --> GeneratorRelease[Create pulse_slab_generator GitHub Release]
  FlutterPublish --> PubDev
  FlutterPublish --> FlutterRelease[Create pulse_slab_flutter GitHub Release]
~~~

## Verification on every branch

`.github/workflows/ci.yml` runs for pushes to every branch, pull requests, and
manual dispatches. It runs in this order:

1. Core VM unit and integration tests, its runnable developer example, and the
   browser portability test.
2. Native persistence VM unit and integration tests on Ubuntu, macOS, and
   Windows, plus its runnable developer example on Ubuntu.
3. Generator formatting, analysis, generated-source freshness, unit and
   generated-source tests, and its complete runnable example.
4. Flutter adapter unit and widget tests, plus the minimal published template.
5. Flutter telemetry demo integration tests.
6. LCOV collection for the core, native persistence, and Flutter adapter.
7. A compact Markdown coverage table added to the GitHub Actions job summary,
   plus the raw reports as a workflow artifact.
8. Creation and upload of `publish/`, an isolated workspace containing the
   four publishable packages: `packages/pulse_slab`,
   `packages/pulse_slab_persistence_io`, `packages/pulse_slab_generator`, and
   `packages/pulse_slab_flutter`.

The summary table contains line coverage for the core, native persistence, and
Flutter adapter plus their combined total. It also includes branch columns when
the underlying LCOV report supplies branch records; Dart and Flutter test
coverage commonly reports those values as `N/A`. Coverage is a measurement and
review signal; this workflow does not enforce an arbitrary percentage threshold.

Each archive retains a compact developer example: the core, native persistence,
generator, and Flutter packages all publish their supported starting points.
The high-rate Flutter telemetry demo stays outside the archive.

## Publication snapshot

Run the following from the repository root to create the same review artifact
locally:

~~~powershell
dart tools/prepare_publish_packages.dart
Push-Location publish
dart pub get
dart pub workspace list
Pop-Location
~~~

The generated `publish/` directory is ignored by Git and is replaced safely on
each run. It contains a root workspace manifest and only these directories:

~~~text
publish/
|-- pubspec.yaml
`-- packages/
    |-- pulse_slab/
    |-- pulse_slab_persistence_io/
    |-- pulse_slab_generator/
    `-- pulse_slab_flutter/
~~~

The core, native persistence, generator, and Flutter compact examples are
retained. The Flutter telemetry demo is excluded. The snapshot is a reviewable,
independently resolvable package workspace. It is not committed. CI copies it to
the runner's temporary directory before resolving dependencies, validating the
archives, or publishing. That detached copy has no Git checkout as an ancestor,
so Pub validates the exact staged files without being affected by a
working-tree status check. The source package `.pubignore` files remain a
second safeguard for files that must stay out of the actual pub.dev archives.

For a local archive check, copy the generated snapshot outside the repository
before running Pub:

~~~powershell
$publishWorkspace = Join-Path $env:TEMP ('pulse-slab-publish-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $publishWorkspace | Out-Null
Copy-Item -Path publish\* -Destination $publishWorkspace -Recurse -Force
Push-Location $publishWorkspace
flutter pub get
Push-Location packages/pulse_slab
flutter pub publish --dry-run
Pop-Location
Push-Location packages/pulse_slab_persistence_io
dart pub publish --dry-run
Pop-Location
Push-Location packages/pulse_slab_flutter
flutter pub publish --dry-run
Pop-Location
Push-Location packages/pulse_slab_generator
dart pub publish --dry-run
Pop-Location
Pop-Location
Remove-Item -LiteralPath $publishWorkspace -Recurse -Force
~~~

Remove local staging output with:

~~~powershell
dart tools/prepare_publish_packages.dart --clean
~~~

## Release rule

A verified push to `main` creates a release tag only for an existing publishable
package whose `pubspec.yaml` version changed relative to the previous `main`
revision. The `release_tags` job checks the matching package changelog heading
and creates a tag only when it does not already exist:

| Package | Release tag |
| --- | --- |
| `pulse_slab` | `pulse_slab-v<version>` |
| `pulse_slab_persistence_io` | `pulse_slab_persistence_io-v<version>` |
| `pulse_slab_generator` | `pulse_slab_generator-v<version>` |
| `pulse_slab_flutter` | `pulse_slab_flutter-v<version>` |

This supports an independent patch release of each package. If several versions
change together, all matching tags are created. Re-running a release after a
partial success is safe: existing tags are left unchanged and only missing tags
are created. A package-source change without a package-version change, a
maintenance-only merge, and the initial addition of a package all succeed
without creating tags or publishing packages. A new package is released by a
later, explicit package-version change after its required pub.dev bootstrap is
complete.

If repository rules limit the number of refs that a push can update, allow at
least four tag updates: a coordinated release can create the core, native
persistence, generator, and Flutter tags in one push.

The existing repository-wide `0.1.0-alpha` tag is a legacy tag. It is preserved
unchanged, does not match any package publishing trigger, and does not count as
`pulse_slab-v0.1.0-alpha`, `pulse_slab_generator-v0.1.0-alpha`, or
`pulse_slab_flutter-v0.1.0-alpha`, or
`pulse_slab_persistence_io-v0.1.0-alpha`. The release job emits a notice when
it encounters a legacy tag with the same version and continues with the
package-specific tag namespace.

## GitHub Releases

After a package has been successfully published to pub.dev, the matching
tag-triggered workflow creates one GitHub Release for the same package tag. The
release title is `<package> <version>`, its notes link to the package changelog,
and semantic prerelease versions such as `0.3.0-beta.1` are marked as GitHub
pre-releases. Versions without a prerelease suffix, such as `1.0.0`, are
regular GitHub Releases.

The publication and creation jobs are idempotent: an existing GitHub Release
is reused, and every package publication job detects an already-published
version after its dry-run and skips the immutable second upload. This also
allows a manually bootstrapped publication to receive its normal tag and GitHub
Release later. If only a release-creation job fails after pub.dev publication,
rerun that failed job; it does not rerun the immutable package upload.

For tags created before this automation existed, use the **Backfill GitHub
package releases** workflow from `main`. Provide one or more comma- or
whitespace-separated package tags, for example:

~~~text
pulse_slab-v<version>,pulse_slab_persistence_io-v<version>,pulse_slab_generator-v<version>,pulse_slab_flutter-v<version>
~~~

The backfill workflow validates that each tag exists, creates only missing
GitHub Releases, and never calls pub.dev.

## Version policy

Package versions on pub.dev are immutable. Every release must use a new
package version and matching changelog heading. Versions with a prerelease
suffix, such as `0.3.0-beta.1`, create GitHub pre-releases. Versions without a
prerelease suffix, such as `1.0.0`, create regular GitHub Releases.

The native persistence package, Flutter adapter, and generator have normal
hosted dependencies on `pulse_slab`. Before publishing any of their tags, the
workflow waits for the exact lower-bound core version in its caret dependency
constraint, including a semantic prerelease suffix when present, to appear on
pub.dev. This makes same-merge releases reliable without pretending that pub.dev
publication is instantly visible.

Before publishing `pulse_slab_persistence_io`, the workflow also verifies that
the checked-out core source matches the release tag named by that lower bound.
An I/O-only release can therefore proceed independently while the core source is
unchanged. If the core source has advanced, update the I/O package's lower bound
to the matching core release before tagging it.

Every `pulse_slab_persistence_io` release must target a core release that
exports the persistence contracts it imports. Its `pulse_slab` lower-bound
constraint must name that core release before either package is tagged;
workspace resolution alone is not a substitute for this hosted-package check.

## One-time maintainer setup

The workflow files require this setup before the first automated release of a
new package. Retain these steps when adding a publishable package or restoring
the release environment:

1. Publish the first version of each package manually from its source package
   directory. Pub.dev trusted publishing can automate later releases of an
   existing package, but cannot create its first package release.
2. In the pub.dev settings for each package, authorize this repository and
   configure its tag pattern:

   | Package | Authorized tag pattern |
   | --- | --- |
   | `pulse_slab` | `pulse_slab-v{{version}}` |
   | `pulse_slab_persistence_io` | `pulse_slab_persistence_io-v{{version}}` |
   | `pulse_slab_generator` | `pulse_slab_generator-v{{version}}` |
   | `pulse_slab_flutter` | `pulse_slab_flutter-v{{version}}` |

   Also require the GitHub Actions environment named `pub-dev` for all four
   packages so pub.dev verifies the protected deployment identity.

3. Create the protected GitHub environment named `pub-dev`. If deployment
   branches and tags are restricted, allow the `main` branch for release-tag
   creation and all four tag patterns for publication:
   `pulse_slab-v*`, `pulse_slab_persistence_io-v*`,
   `pulse_slab_generator-v*`, and `pulse_slab_flutter-v*`.
   If repository rules also limit ref updates per push, allow at least four
   updates for a coordinated package release. Add required reviewers if release
   approval is desired.
4. Add `RELEASE_TAG_TOKEN` as an environment secret in `pub-dev`. It must be a
   fine-grained personal access token or GitHub App token that can write
   repository contents, including tags. The default `GITHUB_TOKEN` is not
   sufficient here because tags it creates do not start a second tag-triggered
   workflow.
5. Keep the `id-token: write` permission in `publish.yml`. It is the
   short-lived credential used by pub.dev trusted publishing; no long-lived
   pub.dev token is stored in GitHub.

Before merging a release to `main`, confirm that the GitHub `pub-dev`
environment and each package's trusted publisher use the tag patterns above.
The release workflow performs a dry-run before every upload, so invalid metadata
or unexpected archive contents stop the release before publication.

## Local release checks

Run the checks below before merging a release pull request:

~~~powershell
dart pub get

Push-Location packages/pulse_slab
dart format --output=none --set-exit-if-changed lib test benchmark example ../../tools
dart analyze
dart test
dart test -p chrome test/web_portability_test.dart
dart run example/pulse_slab_core_example.dart
dart test --coverage=coverage
dart run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --package=. --report-on=lib
flutter pub publish --dry-run
Pop-Location

Push-Location packages/pulse_slab_persistence_io
dart format --output=none --set-exit-if-changed lib test example
dart analyze
dart test
dart run example/file_store_persistence_example.dart
dart test --coverage=coverage
dart run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --package=. --report-on=lib
dart pub publish --dry-run
Pop-Location

Push-Location packages/pulse_slab_generator
dart format --output=none --set-exit-if-changed lib test example
dart analyze
dart run build_runner build
git diff --exit-code -- example/sensor_state.g.dart test/fixtures/all_scalar_record.g.dart test/fixtures/wide_record.g.dart
dart test
dart test -p chrome test/generated_web_portability_test.dart
dart run example/main.dart
dart pub publish --dry-run
Pop-Location

Push-Location packages/pulse_slab_flutter
dart format --output=none --set-exit-if-changed lib test example
flutter analyze
flutter test --no-pub
flutter analyze example
flutter test --no-pub example/test/widget_test.dart
flutter test --coverage
flutter pub publish --dry-run
Pop-Location

Push-Location packages/pulse_slab_flutter/demo/telemetry
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test --no-pub
flutter build web
Pop-Location

dart run tools/coverage_summary.dart `
  --input pulse_slab=packages/pulse_slab/coverage/lcov.info `
  --input pulse_slab_persistence_io=packages/pulse_slab_persistence_io/coverage/lcov.info `
  --input pulse_slab_flutter=packages/pulse_slab_flutter/coverage/lcov.info `
  --output coverage/summary.md

dart tools/prepare_publish_packages.dart
~~~

Never modify or reuse a version already published on pub.dev. Release a new
semantic version and add the corresponding package changelog heading instead.
