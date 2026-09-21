# Development

This document is the canonical reference for Bleat's supported test and
validation commands. The workflows require normal host access to Xcode,
CoreSimulator, SwiftPM caches, Docker, local ports, and network resources.

## Focused tests

Run the narrowest relevant test first. Direct SwiftPM runs use the explicitly
unsigned lane and exclude synchronizable-Keychain validation:

```sh
BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter BleatCoreTests
BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter TokenVaultTests
```

For complete Keychain coverage, run `./scripts/test-host.sh` with the configured
development team; this uses the provisioned signed host and accepts no skips.

`BleatAppTests` is an app-hosted Xcode target, not a SwiftPM target. Run focused
app tests through the `Bleat` scheme and verify the requested test identifiers
and outcomes in an `.xcresult` bundle.

## Swift linting

Run the same read-only, strict formatter lint task used in GitHub Actions:

```sh
mise run swift-lint
```

The task discovers the repository's `.swift-format` configuration. It
reports formatting violations without modifying source files.

## Continuous integration

`Validate Bleat` runs on pull requests and pushes to `main`, without duplicate
branch-push runs. Its Apple gate runs strict lint through mise, one Debug iPhone
Simulator build, and two UI smoke tests: startup and the signed-in library
before playback. It checks the result bundle for both passing test identifiers.
After building, the gate waits for the selected Simulator to finish booting and
installs the built app before starting XCTest on that same Simulator ID.
This is a compile-and-launch gate, not the full app regression suite.
The startup fixture remains suspended until cancellation so slow automation
attachment cannot miss the launching screen. Its test waits beyond the former
five-second fixture timeout before inspecting the startup label.

Run the same smoke gate locally with `zsh scripts/test-ci-smoke.sh`. It uses
`BLEAT_SIMULATOR_DESTINATION` when set. Run `bundle install` followed by
`bundle exec slather coverage` to export coverage from that build. Swift
smoke coverage reflects only those UI journeys. The separate host job runs
`scripts/test-host.sh` and exports full host-suite LCOV for BleatCore and
BleatTranscription.

The Linux job checks Rust formatting and Clippy, then runs Tarpaulin with all
features and targets, including PostgreSQL container integration tests. Docker
must be available; these tests are not skipped when measuring coverage.
Run this coverage suite locally with `mise run api:coverage`.
`main.rs` is excluded from Tarpaulin coverage and its generated LCOV report
uploaded to Coveralls.

Swift smoke, Swift host, and Rust coverage artifacts are sent together to Coveralls using the
`COVERALLS_REPO_TOKEN` repository secret. Fork pull requests still generate
reports but do not upload them to Coveralls. Upload failures are warnings, not
test failures. No custom job timeout is imposed; GitHub's runner limits apply.

The manual `Full Apple validation` workflow retains host tests, iPhone and iPad
regression suites, accessibility checks, and unsigned archive validation.
Release automation remains separate. Smoke tests use non-routable telemetry
URLs and require neither production endpoints nor signing credentials.

## Local validation

Run every automated test that does not require a physical device:

```sh
mise run check
```

This runs the website checks, local host and Simulator gate, disposable-server
core integration tests, and disposable-server app journeys sequentially. Run an
individual stage with `mise run test:local`, `mise run test:live`, or
`mise run test:app-live`.

Run the host test suite with code coverage:

```sh
./scripts/test-host.sh
```

The local host gate requires `BLEAT_DEVELOPMENT_TEAM`, an available Apple
Development identity, and Xcode provisioning access. It generates a dedicated
`BleatHostRunner` macOS app under `.build/`, copies the selected toolchain's
Swift Testing helper into it, and lets Xcode sign and provision that app with
its own Keychain access group. It verifies the signature, embedded profile, and
entitlements before running tests. It never changes the installed Xcode helper
or exports signing keys. A missing signing configuration fails the gate.

The host uses Swift Testing with global serialization and selects each built
test product explicitly. This avoids XCTest subclass discovery and prevents a
later empty target from overwriting another target's XML report. It supports
the package-wide product from the native backend and per-target SwiftBuild
products. `scripts/test-live.sh` retains XCTest; app and UI targets remain on
Xcode/XCTest.

GitHub's unsigned coverage jobs explicitly set `BLEAT_HOST_SIGNING=unsigned`.
That lane uses SwiftPM with `--disable-xctest --no-parallel` and excludes only
the synchronizable-Keychain test. It is not signed-Keychain validation. Local
signing is required by default; there is no automatic fallback to this lane.

The gate verifies every test identity against `TestSupport/HostTests/inventory.json`.
Update that inventory when adding, renaming, or removing host tests. The signed
lane rejects every skip. Only the explicitly unsigned lane permits the named
Keychain exclusion; a runtime entitlement failure is never converted to a skip.
It merges each product's fresh
LLVM profile before exporting `.build/coverage/swift-host/lcov.info`, keeps only
project-relative production paths, and requires executed lines in both libraries.
The XML report is `.build/host-results/tests.xml`. Coveralls receives the host
report under `swift-host`, alongside existing `swift-smoke` and `rust-full` flags.

See the [Swift Testing evaluation](swift-testing-evaluation.md) for migration,
diagnostic evidence, and validation limitations. Test the report verifier with
`python3 -m unittest discover -s TestSupport/HostTests`.

Run the core tests with coverage, Release build, and iOS Simulator application
unit and UI tests:

```sh
./scripts/test-core.sh
```

For host-only validation without starting a Simulator:

```sh
BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh
```

For Simulator-only validation after host validation has run independently:

```sh
BLEAT_SKIP_HOST=1 ./scripts/test-core.sh
```

The complete gate defaults to an `iPhone 17 Pro` and one UI-test worker. Select
another installed Simulator:

```sh
BLEAT_SIMULATOR_DESTINATION='platform=iOS Simulator,name=iPad (A16)' \
  ./scripts/test-core.sh
```

List available Simulator devices with:

```sh
xcrun simctl list devices available
```

Run app-hosted tests in a development-signed macOS process with:

```sh
export BLEAT_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
mise run macos:test
```

### Paid developer capability build modes

`BUILD_WITHOUT_PAID_DEVELOPER` accepts exactly `YES` or `NO` and defaults to
`NO`. Set it to `YES` for a Personal Team build: it overrides the individual
capability settings, removes both CloudKit and App Attest from signing, and
forces CarPlay off while retaining the Keychain entitlement.

When the global setting is `NO`, the individual settings remain available:

- `BLEAT_CLOUDKIT_MODE=enabled|disabled` controls CloudKit signing and runtime
  synchronization.
- `BLEAT_APP_ATTEST_MODE=enabled|disabled` controls App Attest signing and
  whether the system App Attest telemetry attester is available.
- `BLEAT_CARPLAY_MODE=enabled|disabled` controls the managed CarPlay Audio App
  signing entitlement. It does not remove the implemented scene from the
  compiled application.

CloudKit, App Attest, and CarPlay default to `enabled`. Set
`BLEAT_CARPLAY_MODE=disabled` explicitly for a paid-team profile that does not
authorize CarPlay. The public GitHub release workflow also pins CarPlay to
`enabled`. Unsupported values fail the build. The selected
effective modes are embedded in `Info.plist`, and Xcode selects the exact
CloudKit, App Attest, and CarPlay entitlement combination. macOS and Personal
Team builds force the effective CarPlay mode to `disabled`.

Apple has approved the managed entitlement, and matching development and
distribution profiles have been verified. A matching profile is required for
an enabled build to sign. Opt out when using a paid-team profile without that
entitlement, for example:

```sh
BLEAT_CARPLAY_MODE=disabled mise run iphone
BLEAT_CARPLAY_MODE=disabled mise run testflight:internal
```

An enabled signed build without matching provisioning fails. Local archive,
TestFlight, Simulator, device, and test workflows default to enabled; the
GitHub release archive pins it to `enabled` explicitly.

### CloudKit schema management

`CloudKit/Bleat.ckdb` is the desired schema for
`iCloud.com.terminaloutcomes.Bleat`. `CloudKit/Production.ckdb` is the last
schema exported from the production environment. Changes to CloudKit record
types, fields, indexes, or grants must update the desired file in the same
change as the application code.

Run the local structural and code-consistency gate with:

```sh
mise run test:cloudkit-schema
```

To apply a reviewed desired schema to the development environment, save a
CloudKit management token in the macOS Keychain with `xcrun cktool save-token`,
then run this single import:

```sh
xcrun cktool import-schema \
  --team-id YOUR_TEAM_ID \
  --container-id iCloud.com.terminaloutcomes.Bleat \
  --environment development \
  --validate \
  --file CloudKit/Bleat.ckdb
```

Test the development environment before opening CloudKit Console. Select the
same container, review **Deploy Schema Changes**, and promote the additive
changes to production. Export the resulting production schema, replace
`CloudKit/Production.ckdb`, and run:

```sh
python3 scripts/validate-cloudkit-schema.py --require-production
```

The production snapshot is deliberately separate from the desired schema so a
code review cannot accidentally claim that manual promotion occurred. A
CloudKit-enabled Release or TestFlight archive refuses to build while the two
schemas differ, and the CloudKit schema pull-request check requires the same
parity. CloudKit-disabled and Personal Team archives still validate the desired
schema against the code but do not require production parity.

The physical-device workflows use paid capabilities by default:

```sh
mise run iphone:build
```

For a direct Personal Team Xcode build, pass the global setting:

```sh
xcodebuild \
  -project Bleat.xcodeproj \
  -scheme Bleat \
  -destination 'generic/platform=iOS' \
  BUILD_WITHOUT_PAID_DEVELOPER=YES \
  build
```

Build and launch a development-signed macOS app:

```sh
export BLEAT_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
mise run macos
```

The signed app is written to
`.build/macos-signed/Build/Products/Release/Bleat.app`. The task
verifies its signature, development team, and application-identifier
entitlement before launch. Set `BLEAT_BUNDLE_ID` when the default bundle
identifier is unavailable to the selected team. Keep the same team and bundle
identifier to retain access to existing Keychain credentials.

Signed macOS launch, native login, and account restoration are supported.
The signed login/relaunch evidence is tracked in
[GitHub issue #25](https://github.com/terminaloutcomes/bleat/issues/25) as
post-1.0 work and does not block the 1.0 release. Notarization, distribution,
Mac-specific interface adaptation, and unlisted Mac media or background
behavior are also not release gates.

Build products and intermediate files are written beneath `.build/`.
Remove all repository-owned build and app-live artifacts with:

```sh
mise run clean
```

Use `mise run clean -- --dry-run` to preview the cleanup. The cleanup does not
touch tracked fixtures, `.git`, or caches outside the repository.

If `project.yml` changes, regenerate the checked-in project before building:

```sh
brew install xcodegen
xcodegen generate
```

## Test

Run every automated test that does not require a physical device:

```sh
mise run check
```

The exhaustive check validates the website, then runs the local host and
Simulator gate, disposable-server core integration tests, and disposable-server
app journeys sequentially. It requires Xcode with an iOS Simulator runtime and
Docker, but does not require development signing or a connected iPhone. Run an
individual app stage with `mise run test:local`, `mise run test:live`, or
`mise run test:app-live`.

## Disposable-server validation

Contract or server-behavior changes require the disposable live suite:

```sh
./scripts/test-live.sh
```

Changes spanning the app, HTTPS trust, playback, downloads, offline state, or
pending synchronization require the disposable live app journeys when
practical:

```sh
./scripts/test-app-live.sh
```

The app-live workflow creates and deletes its own Simulator and installs only
its disposable certificate.

## Release secret-leakage validation

Run the deterministic Release native-authentication secret-leakage gate with:

```sh
mise run test:release-secrets
```

The gate uses disposable Audiobookshelf, telemetry, and Simulator resources;
exercises login, token refresh, authenticated browsing, download, offline
playback, diagnostics, telemetry, and logout; creates a normal unsigned Release
archive; and scans the collected production-relevant surfaces for private
sentinels. Collected unified logs are decoded to NDJSON before their messages
are scanned. Private manifests, the raw log archive, and raw server artifacts
are deleted during cleanup. The retained non-secret result is
`.build/release-secret-scan/report.json`.

## Release packaging

Validate the normal unsigned Release archive with production HTTPS telemetry
origins configured in the environment:

```sh
./scripts/archive-beta.sh
```

The local archive defaults to `BLEAT_CARPLAY_MODE=enabled`, matching the public
GitHub release workflow. A signed enabled archive needs a profile that
authorizes the managed CarPlay Audio App entitlement; set the mode to
`disabled` explicitly for a paid-team profile without it.

Every archive defaults to one UTC build number in `YYYYMMDD.HHmm.SS` format,
generated once and reused for the complete archive, inspection, export, and
evidence chain. `MARKETING_VERSION` uses the release date in `YYYY.MM.DD`
format, with zero-padded month and day (for example, `2026.09.18`). Add a
matching dated changelog section and regenerate the Xcode project when changing
it. Set `BLEAT_BUILD_NUMBER` to a valid one-to-three-component numeric
value only when a reproducible or otherwise explicit build identifier is
required; the supplied value is propagated unchanged.

Upload a signed build that can be installed only by internal App Store Connect
testers with:

```sh
mise run testflight:internal
```

The task uses the Apple account signed into Xcode and the ignored signing and
production telemetry settings from `.envrc`. It uses the same UTC build-number
policy as every other archive without changing `project.yml`, validates both
the Release archive
and its distribution-signed IPA, requires the tracked production CloudKit
schema to match the desired schema when CloudKit is enabled, and sets
`testFlightInternalTestingOnly`, so
that exact build can never be promoted to external TestFlight testing or the
App Store. Local archive, dSYM, IPA checksum, redacted delivery logs, export
options, and upload metadata are retained below
`.build/testflight-internal/`. A successful upload is only delivery evidence;
wait for the matching version and build to finish App Store Connect processing
before treating it as installable.

## Release screenshots

The release screenshot journey can optionally record the Simulator screen for
local inspection:

```sh
BLEAT_SCREENSHOT_RECORD_VIDEO=1 mise run screenshots
```

Recordings are disabled by default. When enabled, the harness writes one H.264
MP4 for each device, orientation, and appearance to
`.build/release-screenshots/recordings/`. Videos are local developer artifacts
and are not included in the release screenshot manifest.

## Accessibility UI audits

Run the largest Dynamic Type journeys on the release-audit iPhone and iPad
Simulators with:

```sh
mise run test:dynamic-type
```

The audit exercises login, Home, Library, Search, Book Detail, Downloads,
mini-player, Now Playing, and Settings with the system content-size category set
to Accessibility Extra Extra Extra Large. It fails when an essential audited
element is outside the application window or cannot be reached and operated.
The result bundles are written beneath `.build/dynamic-type-ui-results/`.

Run the Bold Text, Increase Contrast, and minimum interaction-target journeys
with:

```sh
mise run test:accessibility
```

The harness creates disposable iPhone and iPad Simulators, enables Bold Text and
Increase Contrast separately, and verifies the effective setting inside the
running app. Each pass exercises login, primary browsing, Book Detail, the book
editor, Downloads, Settings, Search, mini-player, Now Playing, chapters, and
bookmarks. App-owned controls are measured against the 44-point target, while
native controls are verified through their system-provided visible and hittable
regions. The four verified result bundles are written beneath
`.build/accessibility-ui-results/`. Each pass also retains 12 named review
screenshots beneath `.build/accessibility-ui-results/screenshots/` for visual
clipping, overlap, emphasis, and colour-only checks. The disposable Simulators
are deleted on exit.

Run the VoiceOver semantic journeys with:

```sh
mise run test:voiceover
```

The harness creates disposable iPhone and iPad Simulators and exercises login,
Home, Library, Search, Book Detail, Downloads, Settings, mini-player, Now
Playing, chapters, and the destructive local-data confirmation. It verifies
the labels and values VoiceOver receives for actions, titles, selected state,
chapter state, playback time, and playback speed, plus Apple's sufficient
description and trait audits on each journey. The result bundles are written
beneath `.build/voiceover-ui-results/`. This deterministic gate validates the
accessibility tree; spoken output and gesture operation still require the
manual VoiceOver audit tracked in issue #39.

### Mini-player Reduce Motion audit

Run dismissal while playing and paused, restoration after a superseded stop,
and upward-swipe navigation on disposable iPhone and iPad Simulators:

```sh
mise run test:mini-player-motion
```

The audit sets the system Reduce Motion preference to disabled and enabled,
reboots each Simulator, and verifies the effective SwiftUI value inside the app
against the requested value. Every pass verifies all four test identifiers and
outcomes in its `.xcresult` bundle under `.build/mini-player-motion/`.
These automated checks verify behavior and setting propagation; visual motion
and physical-device VoiceOver action operation require manual observation.

## Evidence requirements

A successful command exit is not sufficient evidence. Confirm that every
intended test executed and passed. Treat zero-test selections, unexpected test
bundles, runtime warnings, crashes, hangs, and unexpected skips as failed or
unresolved validation attempts. Distinguish host, Simulator, disposable-server,
signed-host, and physical-device evidence when reporting results.
