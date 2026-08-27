# Bleat

Bleat is a native iPhone and iPad client for
[Audiobookshelf](https://www.audiobookshelf.org/). It targets iOS 26 and newer
and is being implemented in Swift 6 with strict concurrency checking. The same
application target can also produce a native macOS 26 build for macOS 26 and
newer. Development-signed macOS builds support native login and
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
Native Audiobookshelf username/password and server-advertised OpenID Connect
login are supported authentication methods. Bleat records local listening slices,
completion milestones, and lifetime summaries. Downloaded playback uses a
durable UUIDv4 local-session outbox and reports measured listening time.
Listening-history import/export and richer statistics views remain deferred in
[GitHub issue #26](https://github.com/terminaloutcomes/bleat/issues/26).
Bookmark creates, renames, and deletes also use a durable local
outbox when the server is unavailable.

Account setup automatically browses `_audiobookshelf._tcp`, resolves its SRV
hostname, port, and optional TXT `path` into a trusted HTTPS base URL, and
verifies the server through `/status`. Verified nearby servers are selectable
in the add-server form, while the HTTPS server field remains directly editable.
Diagnostics on iPhone, iPad, and Mac can run the same pipeline and show the
service instance, SRV host and port, TXT path, resolved URL, and verification
result.
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
- Optionally, an Apple development team for signed native macOS runtime tests

See the [development guide](docs/development.md) for the supported test and
validation workflows.

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

Compile an unsigned native macOS Release app:

```sh
mise run macos:compile
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

Run the app-hosted tests in a development-signed macOS process:

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

## Clickstack logs helper

Use this repository's helper to call the local Clickstack/HyperDX backend:

```sh
./scripts/bleat-logs.py health
./scripts/bleat-logs.py request GET /api/health
./scripts/bleat-logs.py search 'query text' 25
```

The script uses `BLEAT_LOGS_BASE_URL` and `BLEAT_LOGS_TOKEN`.

```sh
BLEAT_LOGS_BASE_URL=https://bleat-logs.terminaloutcomes.com ./scripts/bleat-logs.py health
BLEAT_LOGS_BASE_URL=https://bleat-logs.housenet.yaleman.org ./scripts/bleat-logs.py search 'query text'
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

For the screenshot app process only, the journey disables Bonjour nearby-server
browsing and resolution so `00-login.png` always has an empty server field and
the deterministic “No nearby servers found” state. It still uses the real
`LiveAppService` and signs in to the disposable HTTPS Barnyard fixture after
capturing that screen. Normal application launches continue to discover nearby
Audiobookshelf servers.

Successful output contains only the screenshots and a non-sensitive manifest:

```text
.build/release-screenshots/
  manifest.json
  iphone/00-login.png … 09-settings.png
  iphone/00-login-dark.png … 09-settings-dark.png
  ipad/00-login.png … 09-settings.png
  ipad/00-login-dark.png … 09-settings-dark.png
  iphone/landscapeLeft/00-login.png … 09-settings.png
  ipad/landscapeLeft/00-login.png … 09-settings.png
```

By default the harness captures both light and dark appearances in a single
run, in portrait and landscape-left; dark screenshots use a `-dark` filename
suffix (for example `01-home-dark.png`). Landscape screenshots sit below the
device's `landscapeLeft/` directory, and the manifest records each capture's
actual orientation and pixel dimensions. On failure, redacted Compose logs and the relevant
`.xcresult` bundles remain under the same directory for inspection. Everything
else—including generated media, Caddy certificates, Docker volumes, credentials,
and simulators—is removed automatically.

The default task selects the latest installed iOS runtime. Override it when a
release requires a specific installed runtime or presentation:

```sh
BLEAT_SCREENSHOT_RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-26-3 \
BLEAT_SCREENSHOT_DEVICES='com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max,com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5-12GB' \
BLEAT_SCREENSHOT_APPEARANCES=light,dark \
BLEAT_SCREENSHOT_ORIENTATIONS=portrait,landscapeLeft \
BLEAT_SCREENSHOT_LOCALE=en_AU \
mise run screenshots
```

`BLEAT_SCREENSHOT_APPEARANCES` accepts a comma-separated list of `light` and/or
`dark` (default `light,dark`). Set it to a single appearance to capture only
that set. `BLEAT_SCREENSHOT_ORIENTATIONS` accepts `portrait` and/or
`landscapeLeft` (default `portrait,landscapeLeft`). For a focused landscape
audit, set the appearance to `light` and the orientation to `landscapeLeft`.
The device list must contain one supported iPhone and one supported iPad. The
harness reports the available runtime device types when a selection is
unavailable. Add a scene by extending the ordered `screenshots` list in the
fixture and adding a matching named attachment in `BleatReleaseScreenshotTests`;
the harness derives the `-dark` filename for each scene automatically. Bump
`schemaVersion` when the fixture contract changes. Validate fixture changes
without Docker or a Simulator with `mise run screenshots:check`.

Run `mise run test:landscape` for the focused functional landscape audit. It
uses `.landscapeLeft` on representative iPhone and iPad simulators, while its
rotation test returns to portrait to verify that active playback and navigation
state are retained.

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

Select the `BleatMac` scheme and **My Mac** to run the shared application
target or its app-hosted unit tests on macOS 26 or newer. UI tests
remain iOS-only.

The equivalent command-line simulator workflow is:

```sh
mise run simulator
```

The iOS target includes a `CPTemplateApplicationScene`, but the managed CarPlay
Audio App entitlement is intentionally omitted until Apple approves the
capability. The macOS target also uses a CarPlay-free entitlement file.
After approval, the entitlement and matching provisioning profile must be
enabled before a signed physical-device build or distribution can use CarPlay.
Follow Apple's
[entitlement request](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
and [CarPlay scene](https://developer.apple.com/documentation/carplay/displaying-content-in-carplay)
guidance when provisioning the app. Entitlement enablement and real-environment
validation are tracked in [GitHub issue #24](https://github.com/terminaloutcomes/bleat/issues/24)
as post-1.0 work and do not block the 1.0 release.

## Archive a beta

Validate a Release archive without signing:

```sh
mise run archive
```

Release archives and physical-device builds require
`BLEAT_TELEMETRY_AUTH_BASE_URL` and `BLEAT_TELEMETRY_OTLP_ENDPOINT` to be
exported as HTTPS URLs. Keep local values in an ignored environment file such
as `.envrc`; the supported build scripts pass them to Xcode and verify the
values embedded in the built application. iOS builds fail before producing an
app when either value is absent, the OTLP URL is not HTTPS, or the
authentication URL is not HTTPS (except Debug loopback). Direct Xcode GUI
builds do not read `.envrc` and must receive these build settings through Xcode
instead.

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
then **TestFlight & App Store** to upload the archive. Upload requires a paid
Apple Developer team, a matching App Store Connect application, and an account
permitted to distribute it.

Pushing `main` with a changed `MARKETING_VERSION` in `project.yml` validates an
unsigned Release archive and publishes `v<version>` as a GitHub Release. The
release notes come from the matching `## <version> - YYYY-MM-DD` section in
`CHANGELOG.md`. Configure GitHub repository variables named
`BLEAT_TELEMETRY_AUTH_BASE_URL` and `BLEAT_TELEMETRY_OTLP_ENDPOINT` before a
version-changing push. This GitHub release does not upload to App Store Connect.

Remaining first-release delivery work is tracked in
[GitHub issue #35](https://github.com/terminaloutcomes/bleat/issues/35) for CI,
[issue #34](https://github.com/terminaloutcomes/bleat/issues/34) for scheduled
compatibility and reliability jobs, and
[issue #36](https://github.com/terminaloutcomes/bleat/issues/36) for final
signed and App Store distribution readiness.

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
mise run iphone
mise run ipad
```

The individual stages are available as `iphone:build`, `iphone:install`, and
`iphone:launch`, with matching `ipad:*` tasks. The physical-device tasks and
direct `scripts/build-device.sh` usage default to
`BUILD_WITHOUT_PAID_DEVELOPER=NO`, enabling CloudKit and App Attest. Set
`BUILD_WITHOUT_PAID_DEVELOPER=YES` explicitly for a Personal Team build that
omits those capabilities while retaining device-only Keychain access.

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
invalid saved login requires explicit sign-in. OIDC uses the configured
Audiobookshelf identity-provider bridge and does not expose provider
configuration in the app.

## iCloud synchronization

Private iCloud synchronization is enabled by default and can be turned off in
Settings. It merges account descriptors, playback and download preferences,
listening slices, completion milestones, and imported server sessions in
`iCloud.com.terminaloutcomes.Bleat`. Turning synchronization off always keeps
local data and moves stable native credentials back to device-only Keychain
storage; the confirmation also offers to retain or delete the private CloudKit
copy.

Account identity is deterministic from the normalized primary server URL and
Audiobookshelf user ID, so the same server user is one account on every device;
an optional local-network URL does not change that identity. On upgrade, Bleat
rekeys legacy device-generated account IDs across local persistence, pending
mutations, downloads, caches, Keychain credentials, and private CloudKit data.
Canonical CloudKit replacements are saved before obsolete legacy records are
deleted. This migration changes record data only and requires no CloudKit
Dashboard schema deployment.

Launch restores local accounts and downloads before starting private iCloud
synchronization as background maintenance. A slow CloudKit operation never
holds the app on its launch screen. Settings exposes active synchronization,
allows it to be cancelled, and offers an explicit retry after cancellation or
failure. CloudKit failures remain distinct from Audiobookshelf failures:
Settings names iCloud as the failing service, chooses retry behavior from the
typed CloudKit code, and local diagnostics retain the operation, exact code,
partial-failure codes, and retry delay without recording record identifiers or
localized error descriptions. Stage diagnostics also report privacy-safe
durations and available record counts, including failed stages, for zone setup,
fetch, fetched-record application, local preparation, and upload. Bleat retains
each successful record's CloudKit
system fields, mutable-record payload digests, per-row statistics sync state,
and account-scoped deletion tombstones across launches, so an unchanged sync
does not scan or re-enqueue the complete statistics archive and interrupted
deletions retry.
Legacy rows without synchronization state are reconciled, pending local
deletions win over racing fetched records, and deleting the iCloud zone marks
retained local statistics for upload if synchronization is enabled again.
Fetched statistics are decoded and
written in one batch instead of opening a persistence transaction per record,
and the iCloud status stops spinning before the independent statistics-summary
refresh completes. A stale-change-tag response is reconciled from
the returned server record: identical data adopts the current server version,
a newer unambiguous local edit is rebased and retried once, and an ambiguous
preference conflict pauses synchronization. Bleat shows only the settings that
differ and asks whether to upload this device's complete current settings or
apply the complete iCloud settings. The pending choice survives relaunch and
blocks automatic configuration uploads until it is resolved.

On a fresh installation, the signed-out form shows **Sync from iCloud** while
CloudKit is enabled. Automatic and manual restore share one synchronization
task and visibly report progress, an empty private zone, or the typed iCloud
failure. Restored account alternatives appear together as selectable cards
showing only the main server, optional local server, and username. A restored
descriptor remains inactive until this device authenticates the expected
Audiobookshelf user; if no synchronized native password is available, Bleat
prefills a dedicated password-required continuation. Rotating tokens remain
device-only.

Saving an account's primary or local server settings immediately pushes that
account descriptor to CloudKit. A different account descriptor fetched from
CloudKit is never applied silently: Bleat aggregates the structurally distinct
choices and requires one complete server configuration to be selected.
Each pushed descriptor carries a generation ID and its predecessor identity, so
a delayed predecessor is ignored instead of prompting or reverting the device.
Keeping the device settings pushes them back to CloudKit.

Builds whose effective CloudKit mode is `disabled`, whether selected directly
or forced by `BUILD_WITHOUT_PAID_DEVELOPER=YES`, omit the CloudKit entitlement
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
personalized shelves. Refresh keeps the loaded shelves visible and replaces
them only when the normalized content changes. **Continue Listening** is
ordered by the most recently updated listening progress, with stable book-ID
ordering when progress timestamps are equal.

The Library tab loads 50 books at a time. Its controls sort server-side by
title, author, recently added, recently updated, or duration in either
direction. The progress filter shows all, finished, in-progress, not-started,
or not-finished books without downloading the entire library first. Pull down
to reload accessible libraries and the selected library's content without
clearing the loaded page; unchanged results are not republished. **Load More**
fetches the next page using the active sort and filter. Collapsed server series
are shown as series entries; opening one uses the server's uncollapsed sequence
order, supports cached pages and pagination, and provides a swipeable cover
browser. A book's authors and series are separate accessible controls: an
author opens a named Library filter that can be cleared, while a series opens
its ordered series detail. Search presents separate Books, Authors, and Series
groups, with the same destinations.

## Open a Bleat link

Bleat uses `bleat://` as its sole canonical custom URL scheme for every
app-owned URL, including scene-local navigation and OIDC callbacks. It accepts
Home, Library, Downloads, Now Playing, Settings (including Diagnostics,
Listening Stats, and About), Search, and account/library-qualified Book,
Author, and Series routes. Entity routes resolve their display labels using the
selected account and library; they never search other accounts. Malformed links
leave the current screen unchanged, and a link received while the app is
starting opens once its account and library context is ready.

## Play an audiobook

Single-book covers on Home, Library, Search, and Series provide a separate
Play/Pause control without changing the current screen; tapping the rest of a
card opens Book Detail. The same control discovers a verified complete download
or opens streamed playback without making the browsing screen choose the media
source. While preparation is in progress, only that book's control is disabled.
Collapsed-series covers remain navigation-only because they do not identify one
book. Book Detail retains its larger primary playback action.

Long-press a single-book card or row on Home, Library, Search, or Series to use
the same actions as Book Detail without navigating first. The menu offers one
of **Mark Played** or **Mark Unplayed**, plus permitted Download and Edit
actions; on iPhone and iPad it also reports whether on-device transcription is
available. Played-state changes dismiss the menu and run without a preparation
sheet: Bleat loads canonical detail, re-checks account access, and changes local
state only after the server confirms the mutation. Preparation and mutation
failures use a dismissible alert, while successful server reconciliation runs
separately. Download, Edit, and Transcribe retain their existing preparation
presentation. Collapsed series remain navigation-only, and long-pressing never
starts playback.

Bleat opens native Audiobookshelf playback sessions and uses session-scoped
direct-play or HLS URLs without putting access tokens in media URLs. The
mini-player floats in a
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
downloaded books. The chapter list opens with the current chapter visible and
as its only selected row. Selecting a chapter or file seeks directly to its
whole-book start position. The player also includes the native AirPlay route
picker. Player content and secondary controls scroll when the screen or text
size is too small to show them at once.
Bleat reports playback as active only after AVPlayer has a ready item and the
whole-book playhead is advancing. Initial loading and later stalls show as
buffering while Pause remains available. A stream that makes no progress for
12 seconds is rebuilt at its last confirmed position. Bleat can replace one
lost server session automatically, and a typed direct-play decoder failure
opens one forced-transcode session instead; exhausted recovery becomes a
visible playback failure rather than continuing to appear active.
The selected global speed persists across relaunches and can be adjusted in
0.05× steps.

Playable-cover verification is provided by
`BleatUITests.testPlayableHomeCoverSeparatesPlaybackFromNavigation`,
`testPlayableCoverPreparationDisablesOnlyMatchingAction`,
`testPlayableCoverPresentsTypedPlaybackFailure`,
`testPlayableCoverPresentsTypedPermissionDenial`,
`testPlayableCoversAppearOnEverySingleBookBrowseSurface`,
`testBookEditorOwnsCoverAndServerDeletionControls`,
`testCoreJourneyAtLargestDynamicType`, and
`testSeriesCoverBrowserDisablesDepthMotionWhenRequested`. The disposable live
journeys `BleatLiveUITests.testLiveOnlineLoginPlaybackAndDownload` and
`testLiveOfflineCachedDownloadAndLocalProgress` cover remote and completed
download quick-play, including offline local transport with every server
stopped. Component-specific manual checks confirm separate VoiceOver and
keyboard targets on iPad and Mac, legible increased-contrast presentation,
reduced carousel motion without playback-state changes, and no overlap at the
largest Dynamic Type size. These checks do not replace the broader application
accessibility audits or physical-device audio-route validation.

Audio continues in the background. Lock-screen, Control Center, headset, and
Bluetooth controls can play, pause, seek, and skip. Settings independently maps
the system Previous and Next commands to skip back, skip forward, previous
chapter, or next chapter; they default to the configured back and forward
intervals. AirPods report only Previous or Next to Bleat, not the originating
ear or tap count.
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
system-owned tasks after relaunch. An interrupted non-paused transfer that could
not be restored because Bleat launched offline resumes automatically from its
durable partial bytes when connectivity returns; user-paused downloads stay
paused. Unavailable paths show **Waiting for network**, and satisfied-path
recovery shows **Retrying download**. Bleat does not infer failure from gaps in
progress callbacks; delegate-reported failures enter its bounded replacement
flow. The Downloads tab shows durable state and
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
available offline. Play starts immediately from a finalized, byte-verified
cached window when it covers the requested position. Bleat keeps filling the
window and prepares any later streaming continuation in the background; a
full-book download remains the only guarantee that playback can reach the end
without a connection. Completed files outside the active window still count
toward device storage until cleanup removes them. Settings can delete
automatic cache files after each completed chapter, when the book finishes,
or—by default—24 hours after the book finishes. Cleanup never applies to an
explicit download. **Download Full Book** promotes an automatic cache in place,
keeps its verified files, and downloads only the remaining files.

Book detail keeps Play, Download, and finished-state actions above long
description and metadata content. Its Details and Chapters sections are
collapsible; the Chapters header shows the count, and each chapter shows its
duration and asks for confirmation before moving playback there. Bookmarks
follow Chapters. When detail loading fails,
the screen distinguishes missing or forbidden items, expired authentication,
invalid server responses, local-storage failures, offline cache misses, and
temporary server failures. Retryable failures include a **Try Again** action;
diagnostics retain only the corresponding non-sensitive failure code. Existing
downloads show status, stored and expected bytes, and the relevant Pause,
Continue, Cancel, Retry, Repair, Download Full Book, or Remove action there as
well as in Downloads. Pause retains completed 16 MiB range chunks in durable
partial files, and Continue starts at that on-disk byte offset after either a
short pause or an app relaunch. Cancel discards unfinished partial bytes while
retaining already completed tracks.
Automatic cache failures retry only the active window and never appear as a
full-book repair. Explicit full-book downloads play directly from local files
without opening a server playback session. Automatic cached windows can also
begin locally while later streaming continuation is prepared without blocking
local controls. Bleat audits completed files when restoring downloads and
before playback; a missing or byte-corrupt track in an explicit download
changes the book to Partial and exposes Repair. Repair preserves verified
tracks, downloads only damaged
entries, and refuses to mix files when the server's plan changed.
Local-file playback saves an account-scoped
position every five seconds and on pause, seek, backgrounding, completion, and
stop, then resumes from that durable position after relaunch. Position updates
are queued as Audiobookshelf local sessions and retried with the same UUID until
the server acknowledges them, including after app or account restoration. When
both the
saved device position and server position changed after the download snapshot,
Now Playing asks which position to keep before syncing. Book detail also
supports explicit **Mark Finished** and **Mark Unfinished** actions through the
same account- and item-scoped non-modal mutation coordinator used by browsing
menus.

## Use multiple accounts

Settings lists every saved username/server pair and marks the active browsing
account. Tap a saved account to edit its primary server URL, optional local
server URL, username, and password, remove it, or make it the active account.
Leave password blank while editing to preserve the existing Keychain
credentials, including when verifying a local server. Use **Add Account** for
another standard Audiobookshelf username/password login.
Switching the browsing account does not stop current playback or unrelated
background downloads.

Each account can also have an optional **Local Network** server URL. Bleat uses
the primary URL together with the remote user ID as the account identity and
tries the local URL first for matching
requests, and falls back to the primary URL when the local endpoint cannot be
reached. Every launch and network-path change clears the current local failure
state and tries any configured local endpoint. An endpoint that has not yet
been validated uses the saved native username and password for direct identity
validation without sending its existing bearer token. A successful validation
is retained; a temporary failure affects only the current network lifecycle and
never revokes an earlier validation. This applies to
all supported iOS and native macOS network interfaces; it does not assume that
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
Activity** identifies which of those paths most recently reached a server.
Diagnostics also distinguishes a local endpoint that is not yet validated,
being checked, available, or temporarily unavailable.

The Diagnostics **Privacy** section also records device-local, default-off
consent for **Share diagnostic telemetry** and whether a current OpenTelemetry
export token is available. The token status reads the exporter's in-memory
state without requesting a refresh and never exposes credential material. It
distinguishes disabled, acquiring, missing, expiring, expired, available,
invalid authentication configuration, invalid authentication response, invalid
export configuration, unavailable App Attest, authentication rejection, rate
limiting, temporary unavailability, retry backoff, unsupported platform, and
inactive-controller states. The reviewed schema permits only
bounded technical operation, outcome, timing, app-version, and operating-system data;
it excludes audiobook content, credentials, accounts, servers, searches,
transcripts, paths, and hardware or advertising identifiers. A random
installation identifier authenticates uploads and is included as the standard
OpenTelemetry `service.instance.id` resource attribute so related spans and logs
can be correlated. Turning the setting off does not affect local Diagnostics. The
Diagnostics screen remains available while signed out and when application
startup is unavailable. On iOS, the
opted-in runtime batches completed OpenTelemetry spans and reviewed CloudKit
lifecycle log records away from the main actor, retaining failed span batches
under the bounded persistence policy before authenticated OTLP export. Remote
telemetry authentication is traced end to end, with challenge, enrolment, and
token client spans correlated to the matching `bleat-api` server spans through
W3C trace context. Remote OpenTelemetry export is out of scope on native macOS:
that build does not create
App Attest keys, request telemetry tokens, retain export batches, or send OTLP.

Foreground Socket.IO updates are suspended while the current path is marked
constrained by Low Data Mode and resume with a catch-up refresh when the path
becomes unconstrained. REST requests, downloads, covers, and playback remain
independent of that optional realtime connection, and socket progress never
changes the foreground player's timeline.
**About** shows the app icon, version, build timestamp, developer,
and bundle identifier.
Diagnostics shows live, privacy-safe operational status and keeps the
**Share diagnostic telemetry** control and Bonjour troubleshooter available.
Bleat emits typed diagnostic events through the system log; it does not create
or share an app-owned diagnostic snapshot or rolling log file.

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

The harness covers pinned 2.36.0 status, native login-token, authorization,
refresh-rotation, logout, seeded-library, media, root/prefix, and HTTPS app
profiles. The 2.26.x and current-stable compatibility profiles remain later
release work tracked in
[GitHub issue #31](https://github.com/terminaloutcomes/bleat/issues/31). It also
provisions a disposable Keycloak realm and runs the real PKCE browser bridge,
token exchange, and account authorization for root and path-prefixed
Audiobookshelf servers.

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
ranged task identities, bearer-only per-file requests, 401 replacement,
opaque account/book storage paths, protected atomic records, byte-exact final
placement, relaunch reconciliation, invalid-state cleanup, and scoped deletion:

```sh
swift test --filter BackgroundDownloadTests
swift test --filter DownloadStorageTests
```

The OIDC flow uses the server-provided button label and the registered
`bleat://oauth2redirect` callback. This deliberately uses the same canonical
`bleat://` scheme as navigation; Bleat does not use or recommend a separate
bundle-derived callback scheme. OpenID Foundation AppAuth-iOS
`2.0.0` is pinned exactly for authorization-response, state, and PKCE handling;
Bleat exposes no AppAuth types outside its internal adapter. Provider URLs,
callback values, codes, verifiers, cookies, and tokens are excluded from
diagnostics.

## Chapter transcription CLI

The `bleat-transcribe` Swift executable is a developer harness for testing
Apple's on-device `SpeechTranscriber` against one local chapter audio file. It
requires macOS 26 or newer and does not use a fallback transcription engine.
Running the command is the explicit action that may install Apple's language
asset for the selected locale.

```sh
swift run bleat-transcribe \
    --locale en-AU \
    --chapter-start 3600 \
    path/to/chapter.m4b
```

Final segments are written to standard output with whole-book timestamps. Use
`--chapter-start` when the chapter begins after zero on the book timeline; omit
it when the input file is already a standalone chapter and relative timestamps
are sufficient. Preparation and completion status are written to standard
error, so the transcript can be redirected independently.

On iOS 26, Book Detail's actions menu exposes **Transcribe Audiobook** when
`SpeechTranscriber` is available and a disabled availability message when it
is not. The transcription screen supports one explicit chapter or a Select
mode with Select All and multi-selection. A batch always runs one chapter at a
time in ascending chapter-index order, regardless of selection order. It reads
the verified downloaded files covering every selected chapter, including files
held by the automatic playback cache, maps chapters across source-file
boundaries, and displays final segments with whole-book timestamps. Automatic
cache files used by transcription are pinned until the batch finishes, fails,
or is cancelled so ordinary cache cleanup cannot remove them mid-chapter.

The app owns active transcription work rather than the sheet. Dismissing the
sheet or navigating elsewhere leaves the batch running; reopening the same
book shows its current progress. Explicit cancellation, account removal, or
book deletion stops the relevant work. Playback and transcription can run at
the same time. Completed chapters are cached locally
by account, book, and chapter, survive relaunch, and replace the prior cached
result when transcribed again. The latest batch's success, typed privacy-safe
failure, or cancellation result is also stored by account and book with its
completion time and monotonic elapsed time, then reloaded after relaunch. The
screen marks cached chapters and provides case-insensitive, order-independent
all-term search across every cached chapter for the current book. Every search
term must occur within the same transcript segment. Tapping a transcript
segment or search result opens actions to copy its text or move the matching
book's playback to its whole-book start timestamp. Existing playback seeks in
place; otherwise Bleat prepares the book through the normal downloaded-first
playback flow. If the audio is not downloaded, the screen asks before
scheduling the existing audiobook download.

Loaded transcript text is retained in memory while its transcription screen is
visible or its batch is active. Otherwise it is evicted after five idle minutes
or immediately when iOS reports memory pressure, and reloads from the durable
local cache when needed.

This is the chapter-level capability slice of GitHub issue #5. Partial-result
resume and independent transcript deletion are tracked as follow-up work.

## Manual device beta checks

Physical-device testing is intentionally manual. Enable Developer Mode on the
device, select the configured Apple team in Xcode, and install the Release
candidate. On AP16, verify:

- MP3, M4B/AAC, FLAC, transcoded, and multi-file playback;
- whole-book seeking, chapter/file transitions, and persisted playback speed;
- background, lock-screen, Control Center, wired/headset, Bluetooth, and
  AirPlay controls, including removed-output pause behavior;
- the [AC-22 background-download recovery matrix](docs/release-evidence/download-recovery.md), including suspension, termination/relaunch, offline recovery, and a mid-range 401 replacement.
  Record the required redacted device and server evidence rather than treating a
  build or Simulator result as completion;
- Low Data Mode suspends the foreground WebSocket without blocking REST or
  downloaded playback, then reconnects once with a catch-up refresh after Low
  Data Mode is disabled;
- account removal deletes its downloads, plus progress conflict resolution;
- VoiceOver and the largest Dynamic Type setting across login, Library, Book
  Detail, Downloads, mini-player, and Now Playing.

Record the device, iOS build, server version, media fixture, and result for each
check. No script in this repository discovers, installs to, or controls a
physical device.

## Run bleat-api

The Rust telemetry-authentication service lives in `bleat-api/`. It provides
database-aware health/readiness, PostgreSQL-backed installation state, and
single-use opaque attestation and token challenges. Its development mode also
verifies deterministic fake P-256 evidence and issues ephemeral ES256 tokens
for local Swift-to-PostgreSQL testing. Production mode validates Apple App
Attest enrollment and replay-safe assertions, then issues the same narrow
short-lived JWT from a mounted P-256 signing key. Public-only overlap keys,
OIDC discovery, and JWKS support bounded signing-key rotation without embedding
private deployment material in the repository or container image.

On iOS, the authentication service URL comes from
`BLEAT_TELEMETRY_AUTH_BASE_URL` and the OTLP/HTTP origin comes from
`BLEAT_TELEMETRY_OTLP_ENDPOINT`; Release requires HTTPS and Debug permits HTTP
only on loopback. OTLP/HTTP protobuf is intentional: the production public
hostname is carried by Cloudflare Tunnel, whose
[public-hostname mode does not support gRPC](https://developers.cloudflare.com/network/grpc-connections/).
This changes the OTLP transport framing, not the HTTPS requirement. Native
macOS ignores these telemetry settings because remote export is out of scope on
that platform.

Run the disposable PostgreSQL and API stack locally with:

```sh
mise run api:run
```

Run its formatting, type-checking, strict Clippy, independently containerized
PostgreSQL tests, and Release build with:

```sh
mise run api:validate
```

Run the disposable fake-attester-to-private-sink integration gate separately:

```sh
mise run test:telemetry
```

That command first runs the focused Swift telemetry suites and the complete
Rust authentication-service suite. It then creates isolated PostgreSQL, API,
authenticated stock Collector, outage Collector, and private capture containers
with generated test credentials and random loopback ports. It drives the
reviewed Swift telemetry pipeline through enrollment, JWT issuance,
authenticated OTLP/HTTP protobuf export, and sink capture; validates
issuer/audience authentication, missing or malformed credentials, the 1 MiB
request limit, bounded exporter outage, authentication-service and Collector
restart recovery, exact Collector resource bounds, private capture isolation,
and the exact privacy allowlist; then verifies removal of its containers,
volumes, and unredacted temporary capture.
Privacy-safe artifacts from a failed run are retained beneath
`TestSupport/ServerHarness/artifacts/telemetry/`.

The single-purpose token carries `telemetry:write`, but stock Collector cannot
hard-reject arbitrary custom claims at RPC authentication time. The issuer
creates only this narrow token, and the baseline deliberately adds neither a
separate gateway nor per-installation accounting.

`docs/architecture-logging.md` is the source of truth for the production log
and trace topology, including the separate authenticated device and internal API
receivers hosted by one Collector process.

Local structured logs remain active when optional OTLP/HTTP trace and log
export is configured. See `bleat-api/README.md` for the complete configuration
and route contract.

## Project documentation

- `docs/audiobookshelf-ios-app-spec.md` is the product and protocol source of truth.
- The [First Release milestone](https://github.com/terminaloutcomes/bleat/milestone/1)
  tracks remaining version 1.0 implementation and validation work; deferred
  issues are linked from the specification and traceability matrix.
- `docs/requirements-traceability.md` links implemented requirements to tests.
- `AGENTS.md` contains repository implementation guidance.
