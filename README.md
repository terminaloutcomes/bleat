# Bleat

Bleat is a native iPhone and iPad client for
[Audiobookshelf](https://www.audiobookshelf.org/). It targets iOS 17 and newer
and is being implemented in Swift 6 with strict concurrency checking.

The repository is currently at the core-foundation and authentication stage.
`BleatCore` builds and its URL, routing, discovery, local-login, OIDC/PKCE,
bearer-header, isolated authentication-cookie, and account-scoped Keychain
behavior is tested. The SwiftUI application target has not been created yet,
so there is not currently an app executable to launch.

## Requirements

- macOS with Xcode 26.x
- Swift 6.2 or newer
- An installed iOS Simulator runtime for simulator tests

Confirm the active toolchain:

```sh
xcodebuild -version
swift --version
```

If the command-line tools point at a different Xcode installation, select the
required one before building:

```sh
sudo xcode-select --switch /Applications/Xcode.app
```

## Compile

Build the core library in Debug mode:

```sh
swift build
```

Build the optimized Release configuration:

```sh
swift build -c release
```

Build for a generic iOS Simulator destination through Xcode:

```sh
xcodebuild \
  -scheme Bleat \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode-derived \
  build
```

Build products and intermediate files are written beneath `.build/`.

## Test

Run the host test suite with code coverage:

```sh
swift test --enable-code-coverage
```

Run the complete current validation gate—host tests, Release build, and iOS
Simulator tests:

```sh
./scripts/test-core.sh
```

The validation script defaults to an `iPhone 17 Pro` simulator. Select another
installed simulator by passing an Xcode destination:

```sh
BLEAT_SIMULATOR_DESTINATION='platform=iOS Simulator,name=iPad (A16)' \
  ./scripts/test-core.sh
```

List available simulator devices when choosing a destination:

```sh
xcrun simctl list devices available
```

To run only host validation, without starting a simulator:

```sh
BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh
```

## Open in Xcode

Open `Package.swift` in Xcode:

```sh
open Package.swift
```

Select the `Bleat` scheme and an iPhone or iPad simulator, then use
**Product → Test**. The current scheme tests `BleatCore`; it does not launch an
application.

## Run against Audiobookshelf

Docker is required for live contract tests. Run the pinned Audiobookshelf
2.36.0 root and path-prefix status and local-authentication suite with:

```sh
./scripts/test-live.sh
```

The script creates fresh root and `/audiobookshelf` instances, waits for both
services, initializes deterministic test-only root users, validates login and
bearer authorization, and removes the containers and volumes. On failure it
retains redacted diagnostic artifacts beneath
`TestSupport/ServerHarness/artifacts/`.

Control the environment directly when developing a contract test:

```sh
./scripts/live-test-environment.sh reset
./scripts/live-test-environment.sh status
./scripts/live-test-environment.sh down
```

The harness currently covers the pinned 2.36.0 status, login-token, and
authorization contracts. Seeded libraries/media, 2.26.x compatibility,
current-stable compatibility, HTTPS, and OIDC profiles will be added in
subsequent implementation slices.

OIDC unit and transport-contract tests cover PKCE S256, strict callback and
state validation, the external browser handoff, cookie-bound exchange,
validation-before-persistence, concurrent-attempt rejection, and terminal
cleanup. Run them directly with:

```sh
swift test --filter OpenIDAuthenticationTests
swift test \
  --filter HTTPTransportTests.testOpenIDTransportKeepsThenClearsSessionCookies
```

These tests model Audiobookshelf's two-client bridge locally. They do not
replace the planned Docker profile with a real identity provider.

There is not yet a supported command for connecting this checkout to a
personal Audiobookshelf server.

## Project documentation

- `audiobookshelf-ios-app-spec.md` is the product and protocol source of truth.
- `IMPLEMENTATION_PLAN.md` defines implementation phases and validation gates.
- `docs/requirements-traceability.md` links implemented requirements to tests.
- `AGENTS.md` contains repository implementation guidance.
