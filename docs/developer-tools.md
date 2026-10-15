# Developer tools and detailed workflows

Read [contributor setup](contributing.md) and the canonical [development guide](development.md) first.
This page retains detailed tool examples formerly in the README.

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
BLEAT_LOGS_BASE_URL=https://logs.example.invalid ./scripts/bleat-logs.py health
BLEAT_LOGS_BASE_URL=https://logs.example.invalid ./scripts/bleat-logs.py search 'query text'
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
unit and UI suites. Core package tests use Swift Testing through `scripts/test-host.sh` (including
verified coverage export), or the full `scripts/test-core.sh` gate. Local host
tests require the configured `BLEAT_DEVELOPMENT_TEAM` and a provisioned signing
identity; see [host validation](development.md#local-validation).

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

The iOS target includes a `CPTemplateApplicationScene`. Apple has approved the
managed CarPlay Audio App entitlement, and matching development and
distribution profiles have been verified. Build workflows default to
`BLEAT_CARPLAY_MODE=enabled`; set it to `disabled` explicitly when using a paid
team whose profile does not authorize CarPlay. macOS and Personal Team builds
force the effective mode off even when `enabled` is requested. A signed enabled
build without a matching profile fails provisioning.
Follow Apple's
[entitlement request](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
and [CarPlay scene](https://developer.apple.com/documentation/carplay/displaying-content-in-carplay)
guidance when provisioning the app. Entitlement enablement and real-environment
validation are recorded in [GitHub issue #24](https://github.com/terminaloutcomes/bleat/issues/24)
and `docs/release-evidence/carplay.md`.

## Archive a beta

Use the [release packaging procedure](development.md#release-packaging) for
unsigned/signed archives, version metadata, privacy manifests, and upload.
GitHub release automation is separate from App Store Connect distribution.


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
omits those capabilities, forces CarPlay off, and retains device-only Keychain
access. CarPlay defaults on for paid-team iOS workflows; pass
`BLEAT_CARPLAY_MODE=disabled` explicitly when the profile does not authorize
the managed entitlement.

## Run against Audiobookshelf

Use [disposable-server validation](development.md#disposable-server-validation)
for root/prefix tests and live app journeys, and the
[compatibility guide](audiobookshelf-compatibility.md) for pinned server profiles.


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

Book Detail's **…** menu includes **View on server** for all users. It opens
that book's Audiobookshelf web page in the system browser, preserving the
configured server path prefix. The browser uses its own login session; if
needed, Audiobookshelf prompts for login and returns to the book. Bleat does
not pass app credentials or tokens to the browser.

On iOS 26, Book Detail's actions menu exposes **Transcribe Audiobook** when
`SpeechTranscriber` is available and a disabled availability message when it
is not. The transcription screen supports one explicit chapter or a Select
mode with Select All and multi-selection. A batch always runs one chapter at a
time in ascending chapter-index order, regardless of selection order. Chapters
with an existing cached transcription remain readable and searchable but are
excluded from new single-chapter and batch transcription work. Bleat reads
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

The first transcription action can jump to the nearest cached transcript
segment for the current audiobook position. It prefers the exact account and
book's active player, falls back to that account and book's saved position,
selects the matching chapter, scrolls the segment into view, and highlights it
briefly. If the containing chapter has not been transcribed, contains no speech,
or the position is unavailable or outside the book, the screen explains that
state without starting playback or network work.

When cached transcript segments exist, the screen can export all currently
available chapters as WebVTT or SRT using whole-book timestamps and the native
share sheet. If some book chapters have no cached transcript, Bleat reports the
available chapter count before generating the partial export. Export runs
entirely from the local canonical transcript cache, replaces Bleat's previous
temporary transcript artifact, and does not require the server.

Loaded transcript text is retained in memory while its transcription screen is
visible or its batch is active. Otherwise it is evicted after five idle minutes
or immediately when iOS reports memory pressure, and reloads from the durable
local cache when needed.

Local transcript data can be deleted independently from the transcription
screen or Book Detail after destructive confirmation. Bleat cancels and awaits
matching transcription work before removing the exact account and audiobook's
transcript segments and latest task result. Downloaded audio, bookmarks, and
playback state remain unchanged.

Interrupted transcription selections now retain durable chapter checkpoints.
After cancellation or relaunch, the top of the transcription screen names every
unfinished chapter and provides a Retry Remaining Chapters action. A persisted
failure is also shown above the chapter selector with the attempted chapter names,
the chapter that failed, and a Retry Failed Transcription action when the typed
failure can be retried immediately. Failures requiring a download, changed source,
valid checkpoint, or supported device retain their specific recovery message
without offering a retry that would immediately fail again. Retry continues
unfinished chapters in ascending chapter-index order with the original language;
opening the screen never restarts Speech. Each chapter's final text and completed
state are committed together; earlier text remains readable, searchable, and
exportable after a later failure. Replacing an unfinished selection requires
confirmation and keeps saved text. Older terminal history remains readable but is
not converted into resumable jobs.

Retry requires the original selection's downloaded tracks, including tracks used
by completed chapters. Bleat compares download identity, chapter boundaries,
track timelines, and local file identity, length, and modification metadata.
Missing, changed, or unverifiable audio produces a specific failure without
removing transcript text or fetching media automatically. This uses metadata,
not content hashes, so changes preserving all compared metadata are not detected.
SwiftData checkpoint operations and local metadata inspection run off the main
actor. Removing account, book, or local transcript data drains matching writes
before purging the saved job.

## Manual device beta checks

Physical-device testing is intentionally manual. Enable Developer Mode on the
device, select the configured Apple team in Xcode, and install the Release
candidate. On AP16, verify:

- MP3, M4B/AAC, FLAC, transcoded, and multi-file playback;
- whole-book seeking, chapter/file transitions, and persisted playback speed;
- background, lock-screen, Control Center, wired/headset, Bluetooth, and
  AirPlay controls, including removed-output pause behavior;
- the [AC-22 background-download recovery matrix](release-evidence/download-recovery.md), including suspension, termination/relaunch, offline recovery, and a mid-range 401 replacement.
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

Use the [API guide](https://github.com/terminaloutcomes/bleat/blob/main/bleat-api/README.md) for configuration, routes,
PostgreSQL persistence, Collector behavior, and key rotation. The
[development guide](development.md) documents telemetry integration validation.
