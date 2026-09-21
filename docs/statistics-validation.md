# Statistics validation

Issue #26 builds on the previously merged history and archive implementation.
The current change shares account-scoped reconciliation between summaries,
daily charts, books, and recent sessions; retains local-only rate/chapter
coverage; reads durable and live totals atomically; and persists a derived
snapshot cache with a versioned SwiftData migration.

## Regression evidence

- `StatisticsExplorationTests`: imported history in charts/books, account/range
  isolation, portable-session identity, idempotence after repository recreation,
  observed remote totals, chapter coverage under replay, distinct completion
  runtime, cache invalidation, and live totals across persistence.
- `AudiobookshelfAPITests`: root/prefix routes, interrupted import, safe replay
  from page zero, disappeared sessions, daily throttling, and structural page
  changes even when a server timestamp is unchanged.
- `PersistenceMigrationTests`: released schema migration to the derived cache.
- `AppModelTests`: older range requests cannot overwrite the current scope,
  failures retain their operation and specific cause, and history authentication
  failure preserves the cached summary.
- `BleatUITests`: imported book and recent-session detail at the largest
  accessibility text size.
- `LocalPlaybackSessionLiveTests`: production history adapter paging against
  both root-hosted and path-prefixed pinned Audiobookshelf servers.

## Large ledger

The opt-in Release benchmark stores 250,000 deterministic five-second slices in
an on-disk SwiftData store, rather than timing only an in-memory reduction.
The repeated measurement on an Apple M2 Max with 64 GiB memory, macOS 26.6.2,
and the Xcode Swift toolchain in Release mode was:

| Operation | Time |
| --- | ---: |
| Initial import | 43.767 s |
| Uncached fetch and aggregation | 15.746 s |
| Redacted JSON encode/decode | 17.492 s |
| Idempotent reimport | 6.886 s |
| Store reopen and cached Lifetime read | 2.469 ms |
| Reset 100 of 250,000 slices | 7.067 s |

These timings distinguish the section 19 cached-launch target of 500 ms from
an uncached rebuild. A first import or invalidated cache requires a rebuild;
this measurement does not claim that scanning 250,000 SwiftData rows takes
500 ms. A main-actor heartbeat during import recorded 3,533 ticks with a
maximum gap of 80.064 ms. No physical-device performance claim is made.

## Validation runs

- `scripts/test-core.sh`: signed host inventory verified 490 passed and zero
  skipped; Release build and paid-capability build checks passed. The existing
  cleanup-failure regression records one expected Swift Testing known issue.
  Simulator app tests executed 427 tests, all passed. The full UI run selected
  92 tests: 84 passed, six expected environment-dependent skips, and two
  statistics-test failures from the pre-correction test binary. Those two
  failures were the missing native popover Cancel button and a combined
  accessibility-label assertion. Both corrected tests passed in the final
  focused run below. The full UI run had zero runtime warnings. Consequently,
  the original full-gate command exited 65; it is not reported as an entirely
  successful single invocation.
- `scripts/test-live.sh`: 21 disposable-server tests selected: 14 passed and seven were
  skipped because their optional telemetry/environment configuration was absent.
- `scripts/test-app-live.sh`: the online and offline disposable-server Simulator
  journeys each executed and passed one test.
- Focused `xcodebuild` statistics UI run: both
  `testStatisticsShowsImportedBookAndSessionDetailsAtLargestTextSize` and
  `testStatisticsResetRequiresSelectedScopeAndDestructiveConfirmation` executed
  and passed, with zero skips and zero runtime warnings. Retained screenshots
  were inspected at the largest accessibility text size.
- `mise run swift-lint`: passed.
- The 250,000-slice Release benchmark executed and passed one test. Its command
  and the approved synchronous SwiftData boundary are in `docs/development.md`.

The initial Simulator app run reported priority-inversion runtime warnings in
`AppModelTests.testAccountRemovalDeletesDownloads` and
`testRemovingOneOfTwoRealAccountsSurvivesRelaunch`; the offline live journey
reported the same warning category. Retained call stacks were symbolicated to
`AccountStore.fetchRecords` / `activeAccount` and CoreData's
`NSSQLDefaultConnectionManager._checkoutConnectionOfType`, triggered by repeated
account fetches during startup. Combining account/selection reads exposed one
remaining identical wait during network-change refresh. AccountStore now retains
its actor-owned account records, maintains them after successful writes, and
invalidates them on rollback or whole-store reset. Priorities and the runtime
checker remain unchanged. The follow-up 430-test Simulator run and both live
app journeys passed with zero runtime warnings. No physical-device performance
or statistics-specific VoiceOver audit was performed.

Earlier focused attempts exposed a missing inventory update, test compilation
errors, and an incorrect same-timestamp history expectation, all corrected.
An unsigned app-test attempt crashed before test bootstrap at CloudKit container
initialization; normal Simulator signing allowed all four focused model tests
to execute and pass. The UI fixture initially attempted CloudKit integration;
its in-memory container now explicitly disables CloudKit. Subsequent UI-test
navigation, combined accessibility-label, and popover-dismissal assumptions
were corrected; both final focused journeys passed.
The diagnostic collector for one completed failed UI run stalled; only that
collector was interrupted, preserving the completed test result bundle.


## Known limitations from independent review

- The initial live-polling P2 triggered full-ledger rebuilds after five-second
  playback flushes. Polling now uses a cache-only API. Durable playback writes,
  session accounting, completion milestones, and remote upserts update compact
  persisted session/day/book/chapter aggregates transactionally. Bulk archive
  import and destructive reset invalidate the cache; only explicit loading can
  rebuild it. Follow-up playback measurements are recorded below.
- The initial review found device-calendar-dependent cached buckets (P2). At
  the user's request, daily buckets, date-range boundaries, and chart display
  now use UTC Gregorian days. A timezone-change regression covers cached
  reopening and range queries; this finding is resolved.
- Chapter grouping distinguishes exact metadata values; insignificant title or
  boundary changes can split the same chapter's coverage (P2). The user explicitly
  accepted this limitation for now; normalization is not part of this change.

The original three independent reviews found no P0/P1 findings. The timezone
finding is resolved; chapter identity is an accepted limitation. Follow-up
review and validation cover the requested live-polling and runtime-warning fixes.

## Requested follow-up

The user requested both cache-only polling and incremental updates, remediation
of the runtime warnings, and acceptance of exact chapter identity for now.

The expanded 250,000-slice Release benchmark passed with these measurements:

| Operation | Time |
| --- | ---: |
| Initial import | 56.523 s |
| Uncached aggregation | 11.377 s |
| Archive roundtrip | 13.463 s |
| Idempotent reimport | 7.099 s |
| Cached Lifetime after reopening | 3.163 ms |
| Worst playback record/flush across 15 seconds | 75.597 ms |
| Worst cache-only live poll | 1.533 ms |
| Reset 100 of 250,000 slices | 15.203 s |

The import heartbeat's maximum main-actor gap was 105.746 ms across 4,250 ticks.
The live loop asserts exact durable-plus-uncommitted totals through repeated
five-second flushes and a 500 ms upper bound on recording and polling calls.
Compact aggregates retain session totals, per-day contributions, per-book time,
and merged chapter coverage intervals rather than replaying ledger slices.
Lifetime and the most recently selected bounded range are retained per account;
a regression loads 25 different ranges and verifies that only two caches remain.

Two fresh full-diff review cycles were completed for this follow-up. The first
identified two P1 reset-coherence defects and one P2 unbounded-cache defect;
all were fixed and the final review reported no findings. Whole-app reset now
deletes derived snapshots in its persistence transaction and clears in-memory
account records and live statistics only after successful persistence. A real
storage regression checks the same service and a relaunched service.

Follow-up validation: the signed host gate verified 493 passed and zero skipped;
all 428 application-unit tests and both statistics UI tests passed without
warnings. Both disposable-server app journeys passed separately without warnings.
Strict Swift lint and diff checks passed. The host gate's Release build and
paid-capability build-mode checks passed. The final six-test simulator rerun
covered real-storage reset/relaunch, both warning-producing account-removal
cases, poll/load ordering, and both statistics UI journeys: six passed, zero
skips, zero runtime warnings.

## Uncertainty display and user device check

Uncertainty warnings and book/session ranges are hidden when the upper and lower
bounds differ by less than 15 minutes. Exactly 15 minutes remains visible. Raw
accounting bounds are unchanged; visible warnings explain the possible overlap
between this app's listening and imported server history. A boundary regression
covers zero, sub-minute, just-under-15-minute, exact-threshold, and larger gaps.

On 2026-09-21 the user reported that Statistics loaded essentially instantly on
an iPhone 16 Pro and accepted that loading performance. This is manual device
loading evidence; the build, ledger size, cache state, and elapsed time were not
recorded. It is not a timed 250,000-slice device benchmark or a sustained-playback
performance measurement.

On 2026-09-21 the user also confirmed that VoiceOver is fine for Statistics.
The statistics-specific manual VoiceOver check is accepted as passed. The exact
build, OS version, and individual gestures were not recorded; this confirmation
does not claim completion of the separate whole-application accessibility audit.

The display follow-up passed all 11 focused `StatisticsTests`, strict Swift
lint, and the largest-text statistics book/session UI journey (one passed,
zero skips, zero runtime warnings). Xcode emitted a debugger-version lookup
diagnostic during launch; the completed result bundle confirms the requested
UI test passed with no application runtime warnings. A fresh complete-diff
review reported no findings (six review cycles overall).

Statistics account selection, history rows, and reset scope now identify accounts
as `username@servername`. The focused account-selection/reset UI journey passed
(one test, zero skips/runtime warnings), as did Swift lint and diff checks. Xcode
again emitted the launch-time debugger-version lookup diagnostic. A seventh
complete-diff review reported no findings.

## Duration and CPU evidence

The manual evidence requested by
[GitHub issue #245](https://github.com/terminaloutcomes/bleat/issues/245) was
collected on 2026-09-21 from commit `c03e31ee`. The host was an Apple M2 Max
MacBook Pro with 64 GiB memory running macOS 26.6.2. The dedicated Simulator was
an iPhone 17 Pro running iOS 26.5 (23F77). These are host/Simulator results, not
physical-phone CPU, battery, lock-screen, or thermal evidence.

### Reproducible environment

The run reused the pinned Audiobookshelf 2.36.0 and Caddy services from
`TestSupport/ServerHarness/compose.yaml`, controlled by
`scripts/live-test-environment.sh`. It used a unique Compose project, media
directory, port range, and disposable account. The setup sequence was:

1. Generate stereo 44.1 kHz AAC in an M4A container from FFmpeg `anullsrc` with
   an explicit 14,400-second duration. `ffprobe` reported exactly
   `14400.000000` seconds and a complete FFmpeg decode succeeded.
2. Start, wait for, and seed the run-owned backend with the existing live-test
   environment script. Mount the generated book into its media root, scan it,
   and verify the expanded pinned API item reports 14,400 seconds and
   `audio/mp4`.
3. Create and boot a dedicated Simulator using the device/runtime selection
   approach in `scripts/test-app-live.sh`, install its Caddy CA, build and
   install the Release app, sign in to the disposable prefixed HTTPS server,
   download the book, and verify downloaded playback.
4. Keep that backend and Simulator alive for the duration run. For CPU runs,
   stop only the run-owned Docker services after the download so local playback
   is identical and the backend cannot add periodic activity.
5. Retain redacted trace-table exports, load snapshots, and the duration-run
   timing/screenshot attachments below
   `TestSupport/ServerHarness/artifacts/issue-245/`. This directory is ignored
   and remains local. Raw `.trace` and `.xcresult` bundles were inspected and
   then removed because they embed sensitive absolute host paths; the retained
   XML exports replace those paths and the Simulator identifier with explicit
   redaction markers. Cleanup deletes only the dedicated Simulator, Compose
   project/volumes, generated media, and temporary build products.

The reproducible duration and profiling driver is compile-gated XCUITest code
in `Tests/BleatUITests/BleatUITests.swift`. A second Release build uses the
compile condition at the start of
`PlaybackModel.recordStatisticsSample` to omit only statistics recording. The
ordinary player, downloaded media, 2x rate, UI state, account data, and all
other build settings are unchanged. Neither gate is present in ordinary builds.
Set the existing `BLEAT_LIVE_APP_URL`, `BLEAT_LIVE_USERNAME`, and
`BLEAT_LIVE_PASSWORD` inputs from ignored local configuration, then build the
two Release test products with these flag sets:

```sh
OTHER_SWIFT_FLAGS='$(inherited) -D BLEAT_STATISTICS_VALIDATION'
OTHER_SWIFT_FLAGS='$(inherited) -D BLEAT_STATISTICS_VALIDATION -D BLEAT_STATISTICS_RECORDING_DISABLED'
```

Use `xcodebuild build-for-testing` with the `Bleat` scheme, Release
configuration, dedicated Simulator destination, and separate derived-data
directories. Locate the generated `.xctestrun`, then inject the test process
environment exactly as the supported live-app script does; exporting shell
variables alone is insufficient:

```sh
plutil -insert 'BleatUITests.EnvironmentVariables.BLEAT_LIVE_APP_URL' \
  -string "$BLEAT_LIVE_APP_URL" "$BLEAT_STATS_XCTESTRUN"
plutil -insert 'BleatUITests.EnvironmentVariables.BLEAT_LIVE_USERNAME' \
  -string "$BLEAT_LIVE_USERNAME" "$BLEAT_STATS_XCTESTRUN"
plutil -insert 'BleatUITests.EnvironmentVariables.BLEAT_LIVE_PASSWORD' \
  -string "$BLEAT_LIVE_PASSWORD" "$BLEAT_STATS_XCTESTRUN"
plutil -insert \
  'BleatUITests.EnvironmentVariables.BLEAT_STATISTICS_VALIDATION_MODE' \
  -string "$BLEAT_STATISTICS_VALIDATION_MODE" "$BLEAT_STATS_XCTESTRUN"
plutil -insert \
  'BleatUITests.EnvironmentVariables.BLEAT_STATISTICS_VALIDATION_SECONDS' \
  -string "$BLEAT_STATISTICS_VALIDATION_SECONDS" "$BLEAT_STATS_XCTESTRUN"
plutil -insert \
  'BleatUITests.EnvironmentVariables.BLEAT_STATISTICS_BACKGROUND_SECONDS' \
  -string "$BLEAT_STATISTICS_BACKGROUND_SECONDS" \
  "$BLEAT_STATS_XCTESTRUN"
```

`prepare` downloads and configures the book and may use zero for both numeric
inputs. `duration` uses 3,600 seconds and 900 background seconds. `profile` uses
360 seconds and zero background seconds. Execute only
`BleatUITests/BleatLiveUITests/testStatisticsValidationRun` with
`xcodebuild test-without-building -xctestrun "$BLEAT_STATS_XCTESTRUN"`. For
each profile, wait through the declared warm-up, attach Time Profiler to Bleat
on the dedicated Simulator for five minutes, alternate enabled then disabled,
and export the `time-profile` table with `xcrun xctrace export`. CPU time is the
sum of its `weight` column; divide by the trace TOC duration for CPU percentage.

### One real hour at 2x

The downloaded four-hour book played at 2x for a monotonic elapsed
`3602.723243` seconds. The app was foregrounded for the first and last portions
and backgrounded in the Simulator for 900 seconds. No seek, pause, interruption,
or buffering stall was observed inside the measured interval; the persisted
advancing time stayed within the declared tolerance. The tolerances were at most
five seconds from 3,600 real seconds and ten seconds from 7,200 audiobook
seconds.

The disposable account began with one 2.499901-second setup slice and position
`0.500177` to `3.000138`. Reacquiring the already downloaded player immediately
before starting the monotonic clock added one separately identifiable
3.250677-real-second / 6.501590-audiobook-second slice. The redacted persistence
query recorded these exact local-ledger stages:

| Stage | Persisted real | Persisted audiobook | Position | Evidence |
| --- | ---: | ---: | ---: | --- |
| Before playback reacquisition | 2.499900625 s | 2.499960958 s | 3.000137596 s | Direct pre-run store query |
| Monotonic timer start | 5.750577333 s | 9.001551208 s | 10.001911932 s | Setup plus the structurally identified pre-clock slice |
| Paused flush | 3,607.706789917 s | 7,213.001798538 s | 7,214.500477376 s | Sum of the 700 persisted local slices in the final store |
| After relaunch and history refresh | 3,607.706789917 s | 7,213.001798538 s | 7,214.500477376 s | Direct post-refresh store query; two sessions, zero uncertain seconds |

The paused-flush row is reconstructed from the same final persisted slice rows,
not a separate copy of the store taken before termination. Relaunch and history
refresh do not rewrite those local slices; their exact sum and row count remained
the post-refresh values shown above. Excluding the pre-clock slice, the measured
interval persisted these exact values:

| Measure | Expected | Recorded | Difference |
| --- | ---: | ---: | ---: |
| Real listening time | 3,600 s | 3,601.956213 s | +1.956213 s |
| Audiobook time | 7,200 s | 7,204.000247 s | +4.000247 s |
| Position advance | 7,200 s | 7,204.000247 s | +4.000247 s |

The measured session contained zero uncertain seconds. After pausing, Bleat was
terminated and relaunched. Its Statistics screen reported 1 hr 0 min real,
2 hr 0 min audiobook time, and 2.00x average speed. Pull-to-refresh reconciled
server history without changing or duplicating the exact local totals. The
duration Xcode result executed one test, passed it, skipped none, and recorded
no application runtime warnings. The retained timing and screenshot attachments
record the monotonic endpoints and the post-relaunch display.

### Paired Simulator CPU comparison

For pass/fail, the ambiguous 1% target is interpreted as an absolute increase
of at most 1.00 CPU percentage point: Instruments reports app
CPU time divided by elapsed time, so this directly bounds the additional host
CPU capacity consumed by sampling. Relative overhead against the disabled
baseline is also reported, but is not the pass/fail threshold. Under a relative
interpretation the mean result would be 2.60% and would not satisfy a 1%
threshold.

After discarded warm-up captures, three enabled/disabled pairs alternated in the
order shown. Every counted interval used local downloaded playback at 2x with
the player foregrounded and Docker stopped. Time Profiler assigned 1 ms to each
sample row; CPU percentage is summed sample weight divided by trace duration.

| Pair | Recording | Elapsed | CPU time | App CPU | 1-minute host load, before -> after |
| ---: | --- | ---: | ---: | ---: | --- |
| 1 | enabled | 300.587 s | 18.588 s | 6.184% | 4.73 -> 2.95 |
| 1 | disabled | 300.593 s | 18.278 s | 6.081% | 2.95 -> 5.14 |
| 2 | enabled | 300.642 s | 19.444 s | 6.467% | 5.14 -> 6.53 |
| 2 | disabled | 300.703 s | 18.488 s | 6.148% | 6.53 -> 4.11 |
| 3 | enabled | 300.643 s | 18.355 s | 6.105% | 6.43 -> 5.16 |
| 3 | disabled | 300.600 s | 18.188 s | 6.051% | 5.12 -> 5.67 |

| Pair | Absolute difference | Relative overhead |
| ---: | ---: | ---: |
| 1 | 0.103 percentage points | 1.70% |
| 2 | 0.319 percentage points | 5.19% |
| 3 | 0.055 percentage points | 0.90% |
| Mean | 0.159 percentage points | 2.60% |
| Sample standard deviation | 0.141 percentage points | 2.28% |
| Range | 0.265 percentage points | 4.29% |

The enabled mean was 6.252% CPU (sample standard deviation 0.191 percentage
points); the disabled mean was 6.093% (standard deviation 0.050 percentage
points). Every paired absolute result and the mean are below the declared
1.00-percentage-point limit, so this Simulator measurement passes that
interpretation. The relative result is reported separately and does not pass a
1% relative threshold.

Rows whose resolved backtrace contained either `recordStatisticsSample` or a
`StatisticsRepository` method accounted for 282 ms, 262 ms, and 247 ms of the
enabled traces. The dominant frames were
`PlaybackModel.recordStatisticsSample`, `LiveAppService.recordStatisticsSample`,
and `StatisticsRepository.record`/`saveMutation`. Disabled traces contained no
Bleat statistics-recording stack; one or two unrelated UIKit/Foundation symbols
with “Statistics” in their names were present. This confirms the comparison
removed the intended work rather than inferring it from total CPU alone.

All six counted Xcode result bundles executed one test and passed with zero
failures, skips, expected failures, and application runtime warnings.
Instruments emitted the same warning that one configured table lacked a known
input source for each trace; the `time-profile` table, weights, stacks, start/end
times, and 300-second durations were present and exported successfully. An
earlier third enabled attachment attempt ended before five minutes and was
discarded; its replacement above reached the specified five-minute limit.
