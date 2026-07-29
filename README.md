# Bleat

Bleat is a native iPhone and iPad client for
[Audiobookshelf](https://www.audiobookshelf.org/). It targets iOS 26 and newer
and is being implemented in Swift 6 with strict concurrency checking.

The repository now contains a runnable SwiftUI application and the tested
`BleatCore` package. The app restores a persisted native account, signs in with
an Audiobookshelf username and password, loads cached or live audiobook
libraries as bounded pages, searches the selected library, opens expanded book
details with progress and chapters, loads additional library pages on demand,
renders personalized Home shelves, and
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
tracking, lifetime statistics, and listening-history import/export. Downloaded
playback uses a durable UUIDv4 local-session outbox while reporting zero
listening time. Bookmark creates, renames, and deletes also use a durable local
outbox when the server is unavailable.

## Requirements

- macOS with Xcode 26.x
- Swift 6.2 or newer
- An installed iOS Simulator runtime for simulator tests
- Docker Desktop or another Docker Compose 2-compatible runtime for live tests
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

The live app test creates and deletes its own simulator, installs only its
disposable Caddy certificate, and runs against a freshly seeded
Audiobookshelf instance:

```sh
./scripts/test-app-live.sh
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

The equivalent command-line simulator workflow is:

```sh
mise run iphone
```

## Archive a beta

Validate a Release archive without signing:

```sh
mise run archive
```

The archive is written to `.build/Bleat.xcarchive` and is checked for a valid
bundle plus the required `PrivacyInfo.xcprivacy` manifest. The manifest
declares only the app's local preferences, app-container file metadata, and
download-space preflight uses. Bleat declares no tracking domains or collected
data.

For a signed archive, provide the Apple development team at invocation time.
The team identifier is not stored in the repository:

```sh
BLEAT_DEVELOPMENT_TEAM=YOURTEAMID \
  BLEAT_ALLOW_PROVISIONING_UPDATES=1 \
  mise run archive
```

Open `.build/Bleat.xcarchive` in Xcode Organizer, choose **Distribute App**,
then **TestFlight & App Store** to upload build `0.1.0 (1)`. Upload requires a
paid Apple Developer team, a matching App Store Connect application, and an
account permitted to distribute it.

## Install on a personal iPhone

The iPhone must run iOS 26 or newer, trust the Mac, and have Developer Mode
enabled. Xcode must have a Personal Team or paid development team available.
Inspect the current signing and device state:

```sh
mise run device:status
```

Set the team ID and connected iPhone UDID without storing either value in the
repository, then build, install, and launch the Release app:

```sh
export BLEAT_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export BLEAT_DEVICE_ID="YOUR_IPHONE_UDID"
mise run device
```

The individual stages are also available as `device:build`, `device:install`,
and `device:launch`. If Apple reports that `com.yaleman.Bleat` is unavailable
for the selected team, set a stable alternative such as
`BLEAT_BUNDLE_ID=com.yaleman.Bleat.personal` before running the tasks.

## Sign in

Launch Bleat, then enter:

- the complete HTTPS address of the Audiobookshelf server, including any path
  prefix;
- an Audiobookshelf username;
- that user's password.

Bleat discovers the server, requires Audiobookshelf 2.26.0 or newer, and uses
the server's native username/password login. The password is cleared from the
screen before the request starts. The username/password credential and rotating
access/refresh tokens are stored only in a non-synchronizing, device-only
Keychain item. If refresh-token recovery is rejected, Bleat silently performs
one native login, verifies that the same server user was returned, and retries
the request. OIDC and third-party identity-provider configuration are not part
of the app.

Accounts created by an older Bleat build contain only tokens because those
builds discarded the password. Enter the password once with **Sign In Again**
to migrate that account; subsequent refresh-session failures recover silently.

## Browse the library

Home identifies the active username, server host, and audiobook library above
the server's personalized shelves. Completed books for that account appear in
a local **Downloaded** shelf after **Continue Listening** and
**Recently Added**, before the remaining personalized shelves, and start
offline playback directly. That shelf remains usable while personalized
shelves are loading or unavailable.
Shelf cards are compact enough to scan several books without losing title and
author context. Pull down on Home to refresh the current library page and its
personalized shelves.

The Library tab loads 50 books at a time. Its controls sort server-side by
title, author, recently added, recently updated, or duration in either
direction. The progress filter shows all, finished, in-progress, not-started,
or not-finished books without downloading the entire library first. Pull down
to reload accessible libraries and the selected library's content. **Load More**
fetches the next page using the active sort and filter.

## Play an audiobook

Open a book from Home, Library, or Search and tap **Play**. Bleat opens a native
Audiobookshelf playback session and uses its session-scoped direct-play or HLS
URL without putting access tokens in media URLs. The mini-player remains at the
top of the signed-in tab shell so tab navigation stays unobstructed; tap its
title for whole-book seeking, configurable rewind and forward controls,
previous/next chapter controls, speed control from 0.5× to 3×, and Stop. Rewind
defaults to 15 seconds and forward defaults to 30 seconds;
Settings offers 5, 10, 15, 30, 45, and 60-second choices for either direction.
Now Playing identifies the narrator and current chapter, offers a chapter list
for direct navigation, and shows an Audio Files menu for multi-file direct or
downloaded books. Selecting a file seeks to its whole-book start position. The
player also includes the native AirPlay route picker. Player content and
secondary controls scroll when the screen or text size is too small to show
them at once.
The selected global speed persists across relaunches and can be adjusted in
0.05× steps.

Audio continues in the background. Lock-screen, Control Center, headset, and
Bluetooth controls can play, pause, seek, skip, and move between chapters.
Removing headphones pauses playback. Removing the signed-in account stops
playback and closes its server session before credentials are deleted.
The full player includes 5, 10, 15, 30, 45, 60, 90, and 120-minute sleep
timers plus an end-of-current-chapter option. Settings also configures an
optional 5, 10, 15, or 30-second rewind when resuming after a pause longer than
five minutes.
Its Bookmarks menu loads the current book's server bookmarks, creates a
bookmark at the current whole-book position, and supports rename and delete.
The same controls remain available during local-file playback. Changes appear
immediately, survive relaunch, and reconcile in order when the playback
account can reach the server. Ambiguous create retries refetch first and do not
duplicate an already-created bookmark. Failed synchronization remains visible
in Now Playing with an explicit retry action.
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
supports book-scoped deletion. Its storage section shows the total number of
books, device storage used, and books ready offline. Confirmed bulk removal
cancels matching transfers but preserves the currently playing download;
Settings links to the same management screen and storage total. Before
scheduling, Bleat requires the expected audio bytes plus the larger of 10% or
256 MB to be available. Downloads are grouped by account and show stored versus
expected bytes for each book and the stored total for that account. A 401
transfer response is replaced using the native account's rotating refresh token
without placing tokens in URLs.
Downloads default to **Wi-Fi Only** in Settings. Turning that off permits
expensive networks on newly created and replacement requests; books of 100 MB
or more still require explicit confirmation before Bleat schedules them.

Starting streamed playback also creates an automatic whole-file cache. Bleat
keeps the current file plus enough following files to cover the next configured
chapter window when file timing is available, and otherwise keeps the
configured number of files ahead. The default is five files ahead; a single
M4B is downloaded once in full. Automatic transfers wait for stable playback,
run at background priority, and suspend whenever the player needs bandwidth.
Their displayed byte count advances during the transfer. Settings can delete
automatic cache files after each completed chapter, when the book finishes,
or—by default—24 hours after the book finishes. Cleanup never applies to an
explicit download.

Book detail keeps Play, Download, and finished-state actions above long
description and metadata content. It shows series and sequence, audio-file and
chapter counts, and a duration beside every chapter. Existing downloads show
status, stored and expected bytes, and the relevant Pause, Resume, Retry,
Repair, or Remove action there as well as in Downloads. Completed books play
directly from their verified local files without opening a server playback
session. Bleat audits completed files when restoring downloads and before
playback; a missing or byte-corrupt track changes the book to Partial and
exposes Repair. Repair preserves verified tracks, downloads only damaged
entries, and refuses to mix files when the server's plan changed.
Local-file playback saves an account-scoped
position every five seconds and on pause, seek, backgrounding, completion, and
stop, then resumes from that durable position after relaunch. Position updates
are queued as Audiobookshelf local sessions and retried with the same UUID until
the server acknowledges them, including after app or account restoration. When
both the
saved device position and server position changed after the download snapshot,
Now Playing asks which position to keep before syncing. Book detail also
supports explicit **Mark Finished** and **Mark Unfinished** actions.

## Use multiple accounts

Settings lists every saved username/server pair and marks the active browsing
account. Choose another account to reload Home, Library, and Search in that
account's isolated context, or use **Add Account** for another standard
Audiobookshelf username/password login. **Sign In Again** replaces credentials
for the active saved account using only its password while preserving its
downloads and local state. Switching the browsing account does not stop current
playback or unrelated background downloads.

Settings also provides **Diagnostics**, which shows the app, operating-system,
server, connection, resource, playback, sync, and download state. Development
builds add **Export Diagnostics** and **Export Recent Logs**. The latter shares
a text file containing up to 15 minutes of categorized app, authentication,
API, playback, download, and synchronization events, including events from an
earlier launch within that window. Release builds keep the status screen but
compile out both exports and the rolling log file. Exports exclude account
names, server addresses, credentials, tokens, response bodies, media titles
and URLs, remote identifiers, playback session IDs, listening positions, and
local file paths.

**Remove Account** always asks for confirmation. If that account owns local
books, choose whether to keep or delete them. Keeping them cancels unfinished
transfers but preserves local files, metadata, and device progress. When no
account remains, **Offline Downloads** on the sign-in screen still opens and
plays those books. Bookmark changes made to that retained account-free copy are
stored on the device, but server bookmarks and synchronization remain
unavailable.

The app requires HTTPS. The live app harness below supplies a trusted,
disposable local CA to its temporary simulator; production builds continue to
use normal system trust validation and contain no trust bypass.

## Run against Audiobookshelf

Docker is required for live contract tests. Run the pinned Audiobookshelf
2.36.0 root and path-prefix status and local-authentication suite with:

```sh
./scripts/test-live.sh
```

The script creates fresh root and `/audiobookshelf` instances, waits for both
services, generates disposable test credentials at runtime, and seeds a
three-book media library. It validates username/password login, bearer
authorization, rotating-token recovery, logout, playback routes, and
authenticated per-file downloads, bookmarks, and metadata updates, and
verifies that native-login account profiles survive store recreation, fetch
typed libraries, and load their first paginated
audiobook summaries, a matching search result, personalized audiobook shelves,
and an expanded audiobook detail with chapters and authenticated-user progress.
It then removes the containers and volumes. On failure it retains redacted
diagnostic artifacts beneath `TestSupport/ServerHarness/artifacts/`.

Run the real SwiftUI application through native username/password login,
streaming, chapter and multi-file navigation, download completion, relaunch,
cached browsing, and server-offline playback with:

```sh
./scripts/test-app-live.sh
```

This runner adds a pinned Caddy HTTPS proxy, builds the real app service,
creates a throwaway iPhone simulator, installs Caddy's local root certificate,
and runs separate online and offline XCUITest phases without deleting the
app's account, cache, or downloaded media between them. Disposable credentials
are passed only through the generated `.xctestrun` test environment and entered
through the app's secure login form; they are never printed. The runner deletes
the generated test configuration, simulator, certificates, containers, and
volumes when it exits. Redacted Docker logs, screenshots on failure, and
XCTest result bundles are written beneath
`TestSupport/ServerHarness/app-live-artifacts/`.

Control the environment directly when developing a contract test:

```sh
export BLEAT_TEST_USERNAME="bleat-$(uuidgen)"
export BLEAT_TEST_PASSWORD="$(uuidgen)"
./scripts/live-test-environment.sh reset
./scripts/live-test-environment.sh status
./scripts/live-test-environment.sh down
unset BLEAT_TEST_USERNAME BLEAT_TEST_PASSWORD
```

The harness covers pinned 2.36.0 status, login-token, authorization,
refresh-rotation, logout, seeded-library, media, root/prefix, and HTTPS app
profiles. The 2.26.x and current-stable compatibility profiles remain later
release work.

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
direct/HLS route resolution, durable local-session batches, path prefixes,
unsafe returned paths, and typed failures:

```sh
swift test --filter PlaybackSessionTests
swift test --filter LocalPlaybackSessionTests
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

## Manual device beta checks

Physical-device testing is intentionally manual. Enable Developer Mode on the
device, select the configured Apple team in Xcode, and install the Release
candidate. On AP16, verify:

- MP3, M4B/AAC, FLAC, transcoded, and multi-file playback;
- whole-book seeking, chapter/file transitions, and persisted playback speed;
- background, lock-screen, Control Center, wired/headset, Bluetooth, and
  AirPlay controls, including removed-output pause behavior;
- download continuation across backgrounding and relaunch, followed by local
  playback with the server unavailable;
- account removal with both retained and deleted downloads, plus progress
  conflict resolution;
- VoiceOver and the largest Dynamic Type setting across login, Library, Book
  Detail, Downloads, mini-player, and Now Playing.

Record the device, iOS build, server version, media fixture, and result for each
check. No script in this repository discovers, installs to, or controls a
physical device.

## Project documentation

- `audiobookshelf-ios-app-spec.md` is the product and protocol source of truth.
- `IMPLEMENTATION_PLAN.md` defines implementation phases and validation gates.
- `docs/requirements-traceability.md` links implemented requirements to tests.
- `AGENTS.md` contains repository implementation guidance.
