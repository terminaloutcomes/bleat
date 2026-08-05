# Bleat

Bleat is a native iPhone and iPad client for
[Audiobookshelf](https://www.audiobookshelf.org/). It targets iOS 26 and newer
and is being implemented in Swift 6 with strict concurrency checking. The same
application target can also produce a Mac Catalyst 18 build for macOS 15 and
newer. Development-signed Catalyst builds support native login and
account restoration through the macOS Keychain.

The repository now contains a runnable SwiftUI application and the tested
`BleatCore` package. The app restores a persisted native account, signs in with
an Audiobookshelf username and password, loads cached or live audiobook
libraries as bounded pages, searches the selected library, opens expanded book
details with progress and chapters, loads additional library pages on demand,
renders personalized Home shelves, and
streams direct-play or HLS audio through a background-capable player. Its
permission-gated book editor stages metadata and cover changes behind one Save
action and can either remove a book from the server library or permanently
delete its server files after confirmation. It presents the five-tab root shell
and removes accounts. The core implements URL, routing,
discovery, username/password login,
single-flight token refresh, local logout, bearer-header,
split account-scoped Keychain storage, durable multi-account SwiftData profiles,
transactional native onboarding, account lifecycle, typed authenticated
library listing, pagination, and search, account-scoped SwiftData library
caching including personalized shelves and expanded book details,
online-first/cache-fallback repository behavior, permission-derived book
action visibility, playback sessions, and background-download contracts.
Native Audiobookshelf username/password is the active authentication scope; the
earlier isolated OIDC spike is deferred. Bleat records local listening slices,
completion milestones, and lifetime summaries. Downloaded playback uses a
durable UUIDv4 local-session outbox and reports measured listening time.
Listening-history import/export remains deferred. Bookmark creates, renames,
and deletes also use a durable local
outbox when the server is unavailable.

Account setup currently uses manual HTTPS server entry. The Bonjour discovery
boundary is retained for further validation, but it has no user-facing control.
While the app is active, an authenticated Socket.IO subscription refreshes
visible libraries and progress after server-side changes. Progress events
refresh browse data, but never move or warn the foreground player: its local
timeline remains authoritative through pausing, rewinding, seeking, and
resuming.

## Requirements

- macOS with Xcode 26.x
- Swift 6.2 or newer
- An installed iOS Simulator runtime for simulator tests
- Docker Desktop or another Docker Compose 2-compatible runtime for live tests
- XcodeGen 2.46 or newer only when changing `project.yml`
- An Apple development team for signed Mac Catalyst runtime tests

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

Compile an unsigned Mac Catalyst Release app:

```sh
mise run macos:compile
```

### CloudKit build modes

`BLEAT_CLOUDKIT_MODE` is a build setting with two supported values:

- `enabled` is the default for paid-team, beta, and distribution builds. It
  selects the CloudKit entitlements and makes private iCloud synchronization
  available in Settings.
- `disabled` selects CloudKit-free entitlements for Personal Team builds. It
  leaves statistics local, keeps all credentials device-only, and omits the
  iCloud synchronization controls.

The repository's Xcode, test, archive, and `mise` workflows forward this
setting. For example:

```sh
BLEAT_CLOUDKIT_MODE=disabled mise run iphone:build
```

For direct Xcode command-line builds, pass the same build setting:

```sh
xcodebuild \
  -project Bleat.xcodeproj \
  -scheme Bleat \
  -destination 'generic/platform=iOS' \
  BLEAT_CLOUDKIT_MODE=disabled \
  build
```

Build and launch a development-signed Catalyst app:

```sh
export BLEAT_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
mise run macos
```

The signed app is written to
`.build/macos-signed/Build/Products/Release-maccatalyst/Bleat.app`. The task
verifies its signature, development team, and application-identifier
entitlement before launch. Set `BLEAT_BUNDLE_ID` when the default bundle
identifier is unavailable to the selected team. Keep the same team and bundle
identifier to retain access to existing Keychain credentials.

Signed Catalyst launch, native login, and account restoration are supported.
Notarization, distribution, Mac-specific interface adaptation, and unlisted
Mac media or background behavior are not release gates.

Build products and intermediate files are written beneath `.build/`.

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

## Website

The Zola site source lives in `site/`. Install its pinned toolchain with
`mise install`, then use:

- `mise run site-css` to install the locked frontend packages and generate CSS;
- `mise run site-check` to validate the Zola project;
- `mise run site-build` to build `site/public`;
- `mise run site-serve` to preview it locally.

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

UI tests use one Simulator worker by default for stable isolation. Opt into
additional workers when the host and test environment support it:

```sh
BLEAT_SIMULATOR_TEST_WORKERS=2 ./scripts/test-core.sh
```

List available simulator devices when choosing a destination:

```sh
xcrun simctl list devices available
```

To run only host validation, without starting a simulator:

```sh
BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh
```

Run the app-hosted tests in a development-signed Catalyst process:

```sh
export BLEAT_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
mise run macos:test
```

The live app test creates and deletes its own simulator, installs only its
disposable Caddy certificate, and runs against a freshly seeded
Audiobookshelf instance:

```sh
mise run test:app-live
```

### Release screenshots

Generate the publication-ready release screenshots from a fresh live Barnyard
server:

```sh
mise run screenshots
```

This is intentionally separate from `mise run check` and the ordinary live
fixtures. It builds `Bleat` and `BleatUITests` in Release with CloudKit
disabled, creates one iPhone 17 Pro Max and one 13-inch iPad Pro simulator,
uses trusted local HTTPS at `barnyard.terminaloutcomes.com`, and signs in as `kid` with a
fresh unprinted password. The fixture data and original cover art are versioned
under `TestSupport/ReleaseScreenshots/fixtures.json` and
`TestSupport/ReleaseScreenshots/covers/`.

Successful output contains only the screenshots and a non-sensitive manifest:

```text
.build/release-screenshots/
  manifest.json
  iphone/01-home.png … 07-settings.png
  ipad/01-home.png … 07-settings.png
```

On failure, redacted Compose logs and the relevant `.xcresult` bundles remain
under the same directory for inspection. Everything else—including generated
media, Caddy certificates, Docker volumes, credentials, and simulators—is
removed automatically.

The default task selects the latest installed iOS runtime. Override it when a
release requires a specific installed runtime or presentation:

```sh
BLEAT_SCREENSHOT_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-3 \
BLEAT_SCREENSHOT_DEVICES='com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max,com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB' \
BLEAT_SCREENSHOT_APPEARANCE=light \
BLEAT_SCREENSHOT_LOCALE=en_AU \
mise run screenshots
```

The device list must contain one supported iPhone and one supported iPad. The
harness reports the available runtime device types when a selection is
unavailable. Add a scene by extending the ordered `screenshots` list in the
fixture and adding a matching named attachment in
`BleatReleaseScreenshotTests`; bump `schemaVersion` when the fixture contract
changes. Validate fixture changes without Docker or a Simulator with `mise run
screenshots:check`.

## Open in Xcode

Open the generated project:

```sh
open Bleat.xcodeproj
```

Select the `Bleat` scheme and an iPhone or iPad simulator, then use
**Product → Run** to launch the app or **Product → Test** to run the application
unit and UI suites. Core package tests run through `swift test` or
`scripts/test-core.sh`.

If `xcodebuild -scheme Bleat` resolves to the Swift package's tests instead of
the app suites, a locally generated scheme is shadowing the project scheme.
Delete `.swiftpm/xcode/xcshareddata/xcschemes/Bleat.xcscheme` (a git-ignored
artifact created when the package is opened directly in Xcode) and retry.

Select the `BleatMac` scheme and **My Mac (Mac Catalyst)** to run the shared
application target or its app-hosted unit tests on macOS 15 or newer. UI tests
remain iOS-only.

The equivalent command-line simulator workflow is:

```sh
mise run simulator
```

The iOS target includes a `CPTemplateApplicationScene`, but the managed CarPlay
Audio App entitlement is intentionally omitted until Apple approves the
capability. The Catalyst target also uses a CarPlay-free entitlement file.
After approval, the entitlement and matching provisioning profile must be
enabled before a signed physical-device build or distribution can use CarPlay.
Follow Apple's
[entitlement request](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
and [CarPlay scene](https://developer.apple.com/documentation/carplay/displaying-content-in-carplay)
guidance when provisioning the app.

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

## Install on a personal iPhone or iPad

The device must run iOS 26 or newer, trust the Mac, and have Developer Mode
enabled. Xcode must have a Personal Team or paid development team available.
Inspect the current signing and device state:

```sh
mise run devices:status
```

Set the team ID plus the connected iPhone and iPad UDIDs without storing them
in the repository, then build, install, and launch the Release app:

```sh
export BLEAT_DEVELOPMENT_TEAM="YOUR_TEAM_ID"
export BLEAT_IPHONE_ID="YOUR_IPHONE_UDID"
export BLEAT_IPAD_ID="YOUR_IPAD_UDID"
export BLEAT_CLOUDKIT_MODE=disabled
mise run iphone
mise run ipad
```

The individual stages are available as `iphone:build`, `iphone:install`, and
`iphone:launch`, with matching `ipad:*` tasks. Personal Teams do not support
the CloudKit capability, so the physical-device tasks set
`BLEAT_CLOUDKIT_MODE=disabled`. The disabled mode selects CloudKit-free signing
entitlements, hides iCloud synchronization, leaves statistics local, and
stores native credentials in the device-only Keychain. Paid-team and
distribution builds default to `enabled`.

If Apple reports that `com.yaleman.Bleat` is unavailable for the selected team,
set a stable alternative such as
`BLEAT_BUNDLE_ID=com.yaleman.Bleat.personal` before running the tasks.

## Sign in

Launch Bleat, then enter:

- the complete HTTPS address of the Audiobookshelf server, including any path
  prefix;
- an Audiobookshelf username;
- that user's password.

Bleat discovers the server, requires Audiobookshelf 2.26.0 or newer, and uses
the server's native username/password login. The password is cleared from the
screen before the request starts. Rotating access/refresh tokens stay in a
non-synchronizing, device-only Keychain item. When iCloud sync is enabled, the
stable username/password credential uses iCloud Keychain so another device can
obtain its own token pair; tokens are never synchronized. If a reachable
refresh endpoint rejects the session or returns
an unusable response, Bleat silently performs one native login, verifies that
the same server user was returned, and retries the request. Network, malformed
recovery, and storage failures remain retryable; only a missing or conclusively
invalid saved login requires explicit sign-in. OIDC and third-party
identity-provider configuration are not part of the app.

## iCloud synchronization

Private iCloud synchronization is enabled by default and can be turned off in
Settings. It merges account descriptors, playback and download preferences,
listening slices, completion milestones, and imported server sessions in
`iCloud.com.yaleman.Bleat`. Turning synchronization off always keeps
local data and moves stable native credentials back to device-only Keychain
storage; the confirmation also offers to retain or delete the private CloudKit
copy.

Builds made with `BLEAT_CLOUDKIT_MODE=disabled` omit the CloudKit entitlement
entirely. They do not initialize CloudKit or show its Settings controls, and
their stable native credentials remain device-only.

Account removal distinguishes this device from all devices and asks separately
whether listening history should be retained. Downloaded audio is always
removed with its account, and launch cleanup removes any record whose account
is no longer saved.

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
fetches the next page using the active sort and filter. Collapsed server series
are shown as series entries; opening one uses the server's uncollapsed sequence
order, supports cached pages and pagination, and provides a swipeable cover
browser. A book's authors and series are separate accessible controls: an
author opens a named Library filter that can be cleared, while a series opens
its ordered series detail. Search presents separate Books, Authors, and Series
groups, with the same destinations.

## Open a Bleat link

Bleat registers the `bleat` URL scheme for scene-local navigation. It accepts
Home, Library, Downloads, Now Playing, Settings (including Diagnostics,
Listening Stats, and About), Search, and account/library-qualified Book,
Author, and Series routes. Entity routes resolve their display labels using the
selected account and library; they never search other accounts. Malformed links
leave the current screen unchanged, and a link received while the app is
starting opens once its account and library context is ready.

## Play an audiobook

Open a book from Home, Library, or Search and tap **Play**. Bleat opens a native
Audiobookshelf playback session and uses its session-scoped direct-play or HLS
URL without putting access tokens in media URLs. The mini-player floats in a
rounded material bar above the signed-in tab bar so tab navigation stays
unobstructed; tap its title or swipe upward to open Now Playing for
current-chapter seeking, configurable rewind and forward controls,
previous/next chapter controls, and speed control from 0.5× to 3×. Swipe the
mini-player downward to stop playback and dismiss it, whether playback is active
or paused. Rewind defaults to 15 seconds and forward defaults to 30 seconds.
Settings offers 5, 10, 15, 30, 45, and 60-second choices for either direction.
Current-chapter scrubber moves of 10 minutes or more in either direction require
confirmation; skip, chapter, audio-file, and system commands remain immediate.
Now Playing identifies the narrator and current chapter, offers a chapter list
for direct navigation, and shows an Audio Files menu for multi-file direct or
downloaded books. Selecting a file seeks to its whole-book start position. The
player also includes the native AirPlay route picker. Player content and
secondary controls scroll when the screen or text size is too small to show
them at once.
Bleat reports playback as active only after AVPlayer has a ready item and the
whole-book playhead is advancing. Initial loading and later stalls show as
buffering while Pause remains available. A stream that makes no progress for
12 seconds is rebuilt at its last confirmed position. Bleat can replace one
lost server session automatically, and a typed direct-play decoder failure
opens one forced-transcode session instead; exhausted recovery becomes a
visible playback failure rather than continuing to appear active.
The selected global speed persists across relaunches and can be adjusted in
0.05× steps.

Audio continues in the background. Lock-screen, Control Center, headset, and
Bluetooth controls can play, pause, seek, skip, and move between chapters.
Removing headphones pauses playback. Removing the signed-in account stops
playback and closes its server session before credentials are deleted.
The CarPlay audio scene shares the phone's active account, selected audiobook
library, downloads, and process-wide player. Its Home, Library, and Downloads
tabs provide personalized shelves, a library chooser, explicit pagination,
debounced search, and verified whole-book offline playback. Selecting a book
prefers a verified complete download, otherwise prepares one streaming
session, then opens the system Now Playing template. Play/pause, configured
skip intervals, whole-book seeking, chapter navigation, and a featured-speed
cycle are available in-car. Sign-in, account switching, bookmark editing,
sleep timers, Stop, and download management remain on the phone. Signed-out
users can play retained verified downloads.
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
Only forward audible playback contributes listening time; pauses, buffering,
interruptions, and seeks do not.

Home shelves, library/search rows, book detail, and Now Playing request bounded
cover images with `updatedAt` cache busting. SwiftUI, system Now Playing, and
CarPlay share an account-scoped memory and bounded disk cache, including
in-flight request deduplication. Cover URLs retain server path prefixes and
never contain access tokens.

## Edit book metadata

Accounts with Audiobookshelf's update permission see **Edit** in the top-right
book actions menu on book detail.
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
256 MB to be available. Downloads are grouped by saved account and show stored
versus expected bytes for each book and the stored total for that account.
Startup removes local records that have no saved owning account. A 401 transfer
response is replaced using the native account's rotating refresh token without
placing tokens in URLs.
Downloads default to **Wi-Fi Only** in Settings. Turning that off permits
expensive networks on newly created and replacement requests; books of 100 MB
or more still require explicit confirmation before Bleat schedules them.

Starting streamed playback also creates an automatic whole-file cache. Bleat
keeps the current file plus enough following files to cover the next configured
chapter window when file timing is available, and otherwise keeps the
configured number of files ahead. The default is five files ahead; a single
M4B is downloaded once in full. Automatic transfers wait for stable playback,
run at background priority, and suspend whenever the player needs bandwidth.
Their status and displayed byte count cover only the active file window, so a
fully cached window reads **Cached** at 100% without claiming the whole book is
available offline. Completed files outside the active window still count
toward device storage until cleanup removes them. Settings can delete
automatic cache files after each completed chapter, when the book finishes,
or—by default—24 hours after the book finishes. Cleanup never applies to an
explicit download. **Download Full Book** promotes an automatic cache in place,
keeps its verified files, and downloads only the remaining files.

Book detail keeps Play, Download, and finished-state actions above long
description and metadata content. It shows series and sequence, audio-file and
chapter counts, and a duration beside every chapter. When detail loading fails,
the screen distinguishes missing or forbidden items, expired authentication,
invalid server responses, local-storage failures, offline cache misses, and
temporary server failures. Retryable failures include a **Try Again** action;
diagnostics retain only the corresponding non-sensitive failure code. Existing
downloads show status, stored and expected bytes, and the relevant Pause,
Resume, Retry, Repair, Download Full Book, or Remove action there as well as in
Downloads.
Automatic cache failures retry only the active window and never appear as a
full-book repair. Books play directly from local files only after every source
file is verified, without opening a server playback session. Bleat audits
completed files when restoring downloads and before playback; a missing or
byte-corrupt track in an explicit download changes the book to Partial and
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
account. Tap a saved account to edit its primary server URL, optional local
server URL, username, and password, remove it, or make it the active account.
Leave password blank while editing to preserve the existing Keychain
credentials. Use **Add Account** for another standard Audiobookshelf
username/password login.
Switching the browsing account does not stop current playback or unrelated
background downloads.

Each account can also have an optional **Local Network** server URL. Bleat keeps
the primary URL as the account identity, tries the local URL first for matching
requests, and falls back to the primary URL when the local endpoint cannot be
reached. A network-path change clears the local failure cooldown and performs a
safe status probe so the local endpoint can be selected again. This applies to
all supported iOS and Mac Catalyst network interfaces; it does not assume that
the current path is Wi-Fi. A changed local URL is verified directly as the same saved
Audiobookshelf user. Changing only the primary URL does not require the local
server to be reachable. If changed local details cannot be verified, the edit
can still be saved with that local URL disabled. The local URL is not treated
as another account and does not split caches, credentials, downloads, or
playback state.

Settings also provides **Diagnostics**, which shows the app, operating-system,
server, connection, resource, playback, sync, and download state. It identifies
the primary or local hostname and port last used for authentication and API
traffic, plus the configured WebSocket endpoint and its connection state.
Endpoint activity updates live and is collected through the same account-aware
boundary for API and authentication requests, WebSockets, covers, streamed
playback, and foreground or restored background downloads. **Last Server
Activity** identifies which of those paths most recently selected or reached a
server.
**About** shows the app icon, version, build number, build timestamp, developer,
and bundle identifier.
Development builds add **Export Diagnostics** and **Export Recent Logs**. The
latter shares a text file containing up to 15 minutes of categorized app,
authentication, API, playback, download, and synchronization events, including
events from an earlier launch within that window. Release builds keep the
status screen but compile out both exports and the rolling log file. Snapshot
exports include these server hostnames and ports but exclude URL paths and
queries, account names, credentials, tokens, response bodies, media titles and
URLs, remote identifiers, playback session IDs, listening positions, and local
file paths. Recent logs continue to exclude server addresses.

Each visible failure retains both the operation and a specific safe cause—for
example authentication, permission, missing content, invalid server data,
offline cache state, local storage, or transient connectivity—rather than a
generic unavailable message. Read-only operations offer retry only when safely
repeatable; mutation recovery continues through its existing durable state.

**Remove Account** always asks for confirmation and removes the account's
local books, metadata, and device progress. It separately asks whether to keep
or delete listening history.

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
through the app's secure login form; they are never printed. Each invocation
uses a unique disposable Compose project, derived-data directory, and artifact
subdirectory, so its cleanup cannot remove another live run's state. The runner
deletes its generated test configuration, simulator, certificates, containers,
and volumes when it exits. Redacted Docker logs, screenshots on failure, and
complete XCTest result bundles are written beneath
`TestSupport/ServerHarness/app-live-artifacts/`.

Validate registered `bleat://` routes with a cold signed-in launch and warm
scene delivery using a disposable Simulator:

```sh
mise run test:deep-links
```

The runner uses `xcrun simctl openurl` and a DEBUG-only persisted test scenario.
It accepts the system route confirmation, validates only typed route outcomes,
and removes its Simulator and test state when it exits.

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
- CarPlay launch, Home shelves, library switching, pagination, search,
  online/offline selection, artwork, play/pause, configured skip, chapter
  controls, seeking, speed, background/locked playback, disconnect/reconnect,
  and simultaneous phone interaction;
- download continuation across backgrounding and relaunch, followed by local
  playback with the server unavailable;
- account removal deletes its downloads, plus progress conflict resolution;
- VoiceOver and the largest Dynamic Type setting across login, Library, Book
  Detail, Downloads, mini-player, and Now Playing.

Record the device, iOS build, server version, media fixture, and result for each
check. No script in this repository discovers, installs to, or controls a
physical device.

## Project documentation

- `audiobookshelf-ios-app-spec.md` is the product and protocol source of truth.
- `IMPLEMENTATION_PLAN.md` lists only remaining implementation and validation
  work, including the deferred product backlog.
- `docs/requirements-traceability.md` links implemented requirements to tests.
- `AGENTS.md` contains repository implementation guidance.
