# Development

This document is the canonical reference for Bleat's supported test and
validation commands. The workflows require normal host access to Xcode,
CoreSimulator, SwiftPM caches, Docker, local ports, and network resources.

## Focused tests

Run the narrowest relevant test first. SwiftPM covers `BleatCoreTests`:

```sh
swift test --filter BleatCoreTests
swift test --filter TokenVaultTests
```

`BleatAppTests` is an app-hosted Xcode target, not a SwiftPM target. Run focused
app tests through the `Bleat` scheme and verify the requested test identifiers
and outcomes in an `.xcresult` bundle.

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
swift test --enable-code-coverage
```

Run the core tests with coverage, Release build, and iOS Simulator application
unit and UI tests:

```sh
./scripts/test-core.sh
```

For host-only validation without starting a Simulator:

```sh
BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh
```

The complete gate defaults to an `iPhone 17 Pro` and one UI-test worker. Select
another installed Simulator or opt into more workers only on a stable host:

```sh
BLEAT_SIMULATOR_DESTINATION='platform=iOS Simulator,name=iPad (A16)' \
  ./scripts/test-core.sh
BLEAT_SIMULATOR_TEST_WORKERS=2 ./scripts/test-core.sh
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

CloudKit and App Attest default to `enabled`; CarPlay defaults to `disabled`
for every build workflow. Unsupported values fail the build. The selected
effective modes are embedded in `Info.plist`, and Xcode selects the exact
CloudKit, App Attest, and CarPlay entitlement combination. macOS and Personal
Team builds force the effective CarPlay mode to `disabled`.

Apple's managed entitlement and a matching profile are required before an
enabled build can sign. After approval, opt in explicitly for any supported
build, for example:

```sh
BLEAT_CARPLAY_MODE=enabled mise run iphone
BLEAT_CARPLAY_MODE=enabled mise run testflight:internal
```

Before approval, an enabled signed build is expected to fail provisioning.
Release, TestFlight, Simulator, and device workflows remain disabled unless the
flag is supplied; the GitHub release archive pins it to `disabled` explicitly.

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

The archive defaults to `BLEAT_CARPLAY_MODE=disabled`. An explicit enabled
archive is supported only after the App ID and provisioning profile authorize
the managed CarPlay Audio App entitlement.

Upload a signed build that can be installed only by internal App Store Connect
testers with:

```sh
mise run testflight:internal
```

The task uses the Apple account signed into Xcode and the ignored signing and
production telemetry settings from `.envrc`. It gives the upload a unique UTC
build number without changing `project.yml`, validates both the Release archive
and its distribution-signed IPA, and sets `testFlightInternalTestingOnly`, so
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

## Evidence requirements

A successful command exit is not sufficient evidence. Confirm that every
intended test executed and passed. Treat zero-test selections, unexpected test
bundles, runtime warnings, crashes, hangs, and unexpected skips as failed or
unresolved validation attempts. Distinguish host, Simulator, disposable-server,
signed-host, and physical-device evidence when reporting results.
