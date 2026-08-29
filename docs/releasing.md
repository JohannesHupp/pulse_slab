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
  Coverage --> Snapshot[publish artifact without examples]
  Snapshot --> Tags[Create version tags]
  Tags --> CoreTag[pulse_slab-vX.Y.Z]
  Tags --> FlutterTag[pulse_slab_flutter-vX.Y.Z]
  CoreTag --> CorePublish[Publish pulse_slab]
  FlutterTag --> Wait[Wait for required core version]
  CorePublish --> PubDev[pub.dev]
  CorePublish --> CoreRelease[Create pulse_slab GitHub Release]
  CorePublish --> Wait
  Wait --> FlutterPublish[Publish pulse_slab_flutter]
  FlutterPublish --> PubDev
  FlutterPublish --> FlutterRelease[Create pulse_slab_flutter GitHub Release]
~~~

## Verification on every branch

`.github/workflows/ci.yml` runs for pushes to every branch, pull requests, and
manual dispatches. It runs in this order:

1. Core VM unit and integration tests, including the browser portability test.
2. Flutter adapter unit and widget tests.
3. Flutter telemetry example integration tests.
4. LCOV collection for the core and Flutter adapter.
5. A compact Markdown coverage table added to the GitHub Actions job summary,
   plus the raw reports as a workflow artifact.
6. Creation and upload of `publish/`, an isolated workspace containing exactly
   `packages/pulse_slab` and `packages/pulse_slab_flutter`.

The summary table contains line coverage for each package and their combined
total. It also includes branch columns when the underlying LCOV report supplies
branch records; Dart and Flutter test coverage commonly reports those values as
`N/A`. Coverage is a measurement and review signal; this workflow does not
enforce an arbitrary percentage threshold.

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
    `-- pulse_slab_flutter/
~~~

Every `example` directory is excluded. The snapshot is a reviewable,
independently resolvable package workspace. It is not committed. CI copies it
to the runner's temporary directory before resolving dependencies, validating
the archives, or publishing. That detached copy has no Git checkout as an
ancestor, so Pub validates the exact staged files without being affected by a
working-tree status check. The source package `.pubignore` files remain a
second safeguard that excludes examples from the actual pub.dev archives.

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
Push-Location packages/pulse_slab_flutter
flutter pub publish --dry-run
Pop-Location
Pop-Location
Remove-Item -LiteralPath $publishWorkspace -Recurse -Force
~~~

Remove local staging output with:

~~~powershell
dart tools/prepare_publish_packages.dart --clean
~~~

## Release rule

A verified push to `main` that changes either publishable package directory
must contain at least one new package version. The `release_tags` job checks
the matching package changelog heading and creates a tag only when it does not
already exist:

| Package | Release tag |
| --- | --- |
| `pulse_slab` | `pulse_slab-v<version>` |
| `pulse_slab_flutter` | `pulse_slab_flutter-v<version>` |

This supports an independent patch release of either package. If both versions
change together, both tags are created. Re-running a release after a partial
success is safe: existing tags are left unchanged and only missing tags are
created. A merge to `main` that changes a package but has no new package
version fails the release-tag job rather than silently creating a non-versioned
release. A maintenance-only merge that does not change either package directory
succeeds without creating tags or publishing packages.

The existing repository-wide `0.1.0-alpha` tag is a legacy tag. It is preserved
unchanged, does not match either package publishing trigger, and does not count
as `pulse_slab-v0.1.0-alpha` or `pulse_slab_flutter-v0.1.0-alpha`. The release
job emits a notice when it encounters a legacy tag with the same version and
continues with the package-specific tag namespace.

## GitHub Releases

After a package has been successfully published to pub.dev, the matching
tag-triggered workflow creates one GitHub Release for the same package tag. The
release title is `<package> <version>`, its notes link to the package changelog,
and semantic prerelease versions such as `0.2.0-beta.2` are marked as GitHub
pre-releases. Stable versions such as `1.0.0` are regular GitHub Releases.

The creation jobs are idempotent: an existing GitHub Release for the tag is
reused. If only a release-creation job fails after pub.dev publication, rerun
that failed job; it does not rerun the immutable package upload.

For tags created before this automation existed, use the **Backfill GitHub
package releases** workflow from `main`. Provide one or more comma- or
whitespace-separated package tags, for example:

~~~text
pulse_slab-v0.2.0-beta.2,pulse_slab_flutter-v0.2.0-beta.2
~~~

The backfill workflow validates that each tag exists, creates only missing
GitHub Releases, and never calls pub.dev.

## Version policy

The current published prerelease is `0.2.0-beta.2`. The initial
`0.2.0-beta.1` releases were published manually to create the pub.dev package
records required before trusted publishing can be enabled. Subsequent pre-1.0
development releases use numbered semantic prerelease identifiers such as
`0.2.0-beta.3`; numbering makes beta releases unambiguous and preserves normal
Pub version ordering.

The first stable public release is planned as `1.0.0`, without a `-beta`
suffix. Once that version is released, it is immutable on pub.dev. Later
prerelease work, if needed, must use a subsequent version rather than changing
the `1.0.0` release.

The Flutter adapter has a normal hosted dependency on `pulse_slab`. Before
publishing an adapter tag, the workflow waits for the exact lower-bound core
version in its caret dependency constraint, including a semantic prerelease
suffix when present, to appear on pub.dev. This makes same-merge core and
adapter releases reliable without pretending that pub.dev publication is
instantly visible.

## One-time maintainer setup

The workflow files are ready to use, but pub.dev and GitHub must be configured
once by a repository maintainer before the first automated release:

1. Publish the first version of each package manually from its source package
   directory. Pub.dev trusted publishing can automate later releases of an
   existing package, but cannot create its first package release.
2. In the pub.dev settings for each package, authorize this repository and
   configure its tag pattern:

   | Package | Authorized tag pattern |
   | --- | --- |
   | `pulse_slab` | `pulse_slab-v{{version}}` |
   | `pulse_slab_flutter` | `pulse_slab_flutter-v{{version}}` |

   Also require the GitHub Actions environment named `pub-dev` for both
   packages so pub.dev verifies the protected deployment identity.

3. Create the protected GitHub environment named `pub-dev`. If deployment
   branches and tags are restricted, allow the `main` branch for release-tag
   creation and both tag patterns for publication:
   `pulse_slab-v*` and `pulse_slab_flutter-v*`. Add required reviewers if
   release approval is desired.
4. Add `RELEASE_TAG_TOKEN` as an environment secret in `pub-dev`. It must be a
   fine-grained personal access token or GitHub App token that can write
   repository contents, including tags. The default `GITHUB_TOKEN` is not
   sufficient here because tags it creates do not start a second tag-triggered
   workflow.
5. Keep the `id-token: write` permission in `publish.yml`. It is the
   short-lived credential used by pub.dev trusted publishing; no long-lived
   pub.dev token is stored in GitHub.

Do not merge a release to `main` until the first manual releases and
trusted-publisher settings have been completed. The release workflow performs
`flutter pub publish --dry-run` before every publish, so invalid metadata or
unexpected archive contents stop the release before upload.

## Local release checks

Run the checks below before merging a release pull request:

~~~powershell
dart pub get

Push-Location packages/pulse_slab
dart test
dart test -p chrome test/web_portability_test.dart
dart test --coverage=coverage
dart run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --package=. --report-on=lib
flutter pub publish --dry-run
Pop-Location

Push-Location packages/pulse_slab_flutter
flutter test
flutter test --coverage
flutter pub publish --dry-run
Pop-Location

dart run tools/coverage_summary.dart --input pulse_slab=packages/pulse_slab/coverage/lcov.info --input pulse_slab_flutter=packages/pulse_slab_flutter/coverage/lcov.info --output coverage/summary.md

dart tools/prepare_publish_packages.dart
~~~

Never modify or reuse a version already published on pub.dev. Release a new
semantic version and add the corresponding package changelog heading instead.
