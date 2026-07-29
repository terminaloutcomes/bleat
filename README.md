# Bleat

Bleat is a native iPhone and iPad client for
[Audiobookshelf](https://www.audiobookshelf.org/). It targets iOS 26 and newer
and is being implemented in Swift 6 with strict concurrency checking.

The repository now contains a runnable SwiftUI application and the tested
`BleatCore` package. The app restores a persisted native account, signs in with
an Audiobookshelf username and password, loads cached or live audiobook
libraries and their first pages, searches the selected library, opens expanded
book details with progress and chapters, presents the five-tab root shell, and
removes accounts. The core implements URL, routing, discovery,
username/password login,
single-flight token refresh, local logout, bearer-header,
account-scoped Keychain, durable multi-account SwiftData profiles,
transactional native onboarding, account lifecycle, typed authenticated
library listing, pagination, and search, account-scoped SwiftData library
caching including personalized shelves and expanded book details,
online-first/cache-fallback repository behavior, permission-derived book
action visibility, playback-session, and background-download contract behavior
is tested. Native Audiobookshelf username/password is the active
authentication scope; the earlier isolated OIDC spike is deferred. The MVP
also defers local time tracking, lifetime statistics, and listening-history
import/export. Playback, downloads, and editing remain under active
development.

## Requirements

- macOS with Xcode 26.x
- Swift 6.2 or newer
- An installed iOS Simulator runtime for simulator tests
- XcodeGen 2.46 or newer only when changing `project.yml`

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
  -project Bleat.xcodeproj \
  -scheme Bleat \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/xcode-derived \
  build
```

Build products and intermediate files are written beneath `.build/`.

If `project.yml` changes, regenerate the checked-in project before building:

```sh
brew install xcodegen
xcodegen generate
```

## Test

Run the host test suite with code coverage:

```sh
swift test --enable-code-coverage
```

Run the complete current validation gate—core unit tests with coverage, Release
build, and iOS Simulator application unit and UI tests:

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

Open the generated project:

```sh
open Bleat.xcodeproj
```

Select the `Bleat` scheme and an iPhone or iPad simulator, then use
**Product → Run** to launch the app or **Product → Test** to run the application
unit and UI suites. Core package tests run through `swift test` or
`scripts/test-core.sh`.

## Sign in

Launch Bleat, then enter:

- the complete HTTPS address of the Audiobookshelf server, including any path
  prefix;
- an Audiobookshelf username;
- that user's password.

Bleat discovers the server, requires Audiobookshelf 2.26.0 or newer, and uses
the server's native username/password login. The password is cleared before the
request starts and is never stored. Access and refresh tokens are stored in the
device Keychain. OIDC and third-party identity-provider configuration are not
part of the app.

The current app target requires HTTPS. The Docker harness below intentionally
tests the lower-level HTTP contracts and is not a server intended for manual
app sign-in yet.

## Run against Audiobookshelf

Docker is required for live contract tests. Run the pinned Audiobookshelf
2.36.0 root and path-prefix status and local-authentication suite with:

```sh
./scripts/test-live.sh
```

The script creates fresh root and `/audiobookshelf` instances, waits for both
services, initializes deterministic test-only root users and a three-book media
library, validates username/password login, bearer authorization,
rotating-token recovery, logout, playback routes, and authenticated per-file
downloads, and verifies that native-login account profiles survive store
recreation, fetch typed libraries, and load their first paginated audiobook
summaries, a matching search result, personalized audiobook shelves, and an
expanded audiobook detail with chapters and authenticated-user progress. It
then removes the containers and volumes. On failure it retains redacted
diagnostic artifacts beneath `TestSupport/ServerHarness/artifacts/`.

Control the environment directly when developing a contract test:

```sh
./scripts/live-test-environment.sh reset
./scripts/live-test-environment.sh status
./scripts/live-test-environment.sh down
```

The harness currently covers the pinned 2.36.0 status, login-token,
authorization, refresh-rotation, logout, seeded-library, and media contracts.
The 2.26.x compatibility, current-stable compatibility, and HTTPS profiles will
be added in subsequent implementation slices.

The deterministic refresh suite exercises 20 simultaneous 401 responses,
single-flight rotation, retry limits, 403 behavior, typed failures, and
account isolation:

```sh
swift test --filter AuthenticatedRequestTests
swift test --filter LogoutTests
swift test --filter AccountStoreTests
swift test --filter AudiobookshelfAPITests
```

The library persistence and repository suites cover relaunch, empty snapshots,
account/library/query isolation, replacement and invalidation, corrupt stored
records, exact-page, exact-search, exact-personalized-shelf, and
account/user-scoped expanded-detail offline reads, online persistence,
fallback, cancellation, and typed cache/remote failures:

```sh
swift test --filter LibraryCacheTests
swift test --filter LibraryRepositoryTests
swift test --filter LibrarySearchCoordinatorTests
swift test --filter BookActionPolicyTests
```

The playback unit suite covers exact request fields, typed session decoding,
direct/HLS route resolution, path prefixes, unsafe returned paths, and typed
failures:

```sh
swift test --filter PlaybackSessionTests
```

The background-download spike covers expanded-item plan decoding, safe file
identities, stable task restoration, bearer-only per-file requests, 401
replacement, and the finalized-file manifest completion invariant:

```sh
swift test --filter BackgroundDownloadTests
```

The earlier OIDC spike remains in the repository as isolated research code, but
it is deferred and is not used by the app or Docker harness.

## Project documentation

- `audiobookshelf-ios-app-spec.md` is the product and protocol source of truth.
- `IMPLEMENTATION_PLAN.md` defines implementation phases and validation gates.
- `docs/requirements-traceability.md` links implemented requirements to tests.
- `AGENTS.md` contains repository implementation guidance.
