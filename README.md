# Bleat

Bleat is a native iPhone and iPad client for
[Audiobookshelf](https://www.audiobookshelf.org/). It targets iOS 26 and newer
and is being implemented in Swift 6 with strict concurrency checking.

The repository now contains a runnable SwiftUI application and the tested
`BleatCore` package. The app restores a persisted native account, signs in with
an Audiobookshelf username and password, loads cached or live audiobook
libraries and their first pages, searches the selected library, opens expanded
book details with progress and chapters, renders personalized Home shelves, and
streams direct-play or HLS audio through a background-capable player. It
allows update-permitted accounts to edit supported book metadata, presents the
five-tab root shell, and removes accounts. The core implements URL, routing,
discovery, username/password login,
single-flight token refresh, local logout, bearer-header,
account-scoped Keychain, durable multi-account SwiftData profiles,
transactional native onboarding, account lifecycle, typed authenticated
library listing, pagination, and search, account-scoped SwiftData library
caching including personalized shelves and expanded book details,
online-first/cache-fallback repository behavior, permission-derived book
action visibility, playback sessions, and background-download contracts.
Native Audiobookshelf username/password is the active authentication scope; the
earlier isolated OIDC spike is deferred. The MVP also defers local time
tracking, lifetime statistics, and listening-history import/export. Durable
offline bookmark reconciliation remains under active development.

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

## Play an audiobook

Open a book from Home, Library, or Search and tap **Play**. Bleat opens a native
Audiobookshelf playback session and uses its session-scoped direct-play or HLS
URL without putting access tokens in media URLs. The mini-player remains above
the tab bar; tap its title for whole-book seeking, 15-second rewind, 30-second
forward, speed control from 0.5× to 3×, and Stop.

Audio continues in the background. Lock-screen, Control Center, headset, and
Bluetooth controls can play, pause, seek, skip, and move between chapters.
Removing headphones pauses playback. Removing the signed-in account stops
playback and closes its server session before credentials are deleted.
The full player includes 15, 30, 45, and 60-minute sleep timers.
Its Bookmarks menu loads the current book's server bookmarks, creates a
bookmark at the current whole-book position, and supports rename and delete.
The same controls remain available during local-file playback when the server
is reachable.
While streaming, Bleat sends the whole-book position to Audiobookshelf every
15 seconds and after pause, seek, backgrounding, interruption, and completion.
The MVP deliberately reports zero additional listening time.

Home shelves, library/search rows, book detail, and Now Playing request bounded
cover images with `updatedAt` cache busting. Cover URLs retain server path
prefixes and never contain access tokens.

## Edit book metadata

Accounts with Audiobookshelf's update permission see **Edit** on book detail.
The editor supports title, subtitle, authors, narrators, series and sequence,
genres, tags, publishing fields, description, explicit status, and abridged
status. Saving sends only changed scalar fields and complete replacement arrays
through the native account's bearer-authenticated metadata endpoint.

Bleat refetches the item immediately before saving. If the server's `updatedAt`
value changed since the editor opened, Bleat offers to load the server version,
review the current draft, or overwrite it. This is a best-effort conflict check
because Audiobookshelf does not expose an atomic metadata precondition.

Accounts with both update and upload permissions also see **Cover** on book
detail. Bleat uses the system photo picker, applies orientation, strips source
metadata by redrawing the image, limits the longest edge to 1600 pixels, encodes
JPEG, uploads it as the server's `cover` multipart field, and refetches the book
before replacing the displayed cached cover.

## Download an audiobook

Accounts with Audiobookshelf's download permission see **Download** on book
detail. Bleat schedules every original audio file through a stable background
URL session with bearer headers, limits each host to three concurrent transfers,
persists an offline metadata snapshot and byte-exact manifest, and restores
system-owned tasks after relaunch. The Downloads tab shows durable state and
supports book-scoped deletion. A 401 transfer response is replaced using the
native account's rotating refresh token without placing tokens in URLs.

Completed books play directly from their verified local files without opening a
server playback session. Failed or cancelled books expose Retry, active books
expose Pause and Cancel, paused books expose Resume, and completed books can be
removed from the Downloads tab.

## Use multiple accounts

Settings lists every saved username/server pair and marks the active browsing
account. Choose another account to reload Home, Library, and Search in that
account's isolated context, or use **Add Account** for another standard
Audiobookshelf username/password login. Switching the browsing account does not
stop current playback or unrelated background downloads.

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
downloads and metadata updates, and verifies that native-login account profiles
survive store recreation, fetch typed libraries, and load their first paginated
audiobook summaries, a matching search result, personalized audiobook shelves,
and an expanded audiobook detail with chapters and authenticated-user progress.
It then removes the containers and volumes. On failure it retains redacted
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

The metadata suite covers changed-field patch generation, replacement arrays,
explicit nulls, server revision detection, prefix-safe bearer authentication,
and the exact update route:

```sh
swift test --filter MetadataEditingTests
```

The background-download foundation covers expanded-item plan decoding, safe
file identities, stable task restoration, bearer-only per-file requests, 401
replacement, opaque account/book storage paths, protected atomic records,
byte-exact final placement, relaunch recovery, and scoped deletion:

```sh
swift test --filter BackgroundDownloadTests
swift test --filter DownloadStorageTests
```

The earlier OIDC spike remains in the repository as isolated research code, but
it is deferred and is not used by the app or Docker harness.

## Project documentation

- `audiobookshelf-ios-app-spec.md` is the product and protocol source of truth.
- `IMPLEMENTATION_PLAN.md` defines implementation phases and validation gates.
- `docs/requirements-traceability.md` links implemented requirements to tests.
- `AGENTS.md` contains repository implementation guidance.
