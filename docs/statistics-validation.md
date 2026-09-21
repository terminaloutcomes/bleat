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
performance measurement. The statistics-specific VoiceOver audit remains open.

The display follow-up passed all 11 focused `StatisticsTests`, strict Swift
lint, and the largest-text statistics book/session UI journey (one passed,
zero skips, zero runtime warnings). Xcode emitted a debugger-version lookup
diagnostic during launch; the completed result bundle confirms the requested
UI test passed with no application runtime warnings. A fresh complete-diff
review reported no findings (six review cycles overall).
