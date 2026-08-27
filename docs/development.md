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

## Evidence requirements

A successful command exit is not sufficient evidence. Confirm that every
intended test executed and passed. Treat zero-test selections, unexpected test
bundles, runtime warnings, crashes, hangs, and unexpected skips as failed or
unresolved validation attempts. Distinguish host, Simulator, disposable-server,
signed-host, and physical-device evidence when reporting results.
