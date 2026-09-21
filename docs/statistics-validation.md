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

The Simulator app run reported priority-inversion runtime warnings in
`AppModelTests.testAccountRemovalDeletesDownloads` and
`testRemovingOneOfTwoRealAccountsSurvivesRelaunch`; the offline live journey
reported the same warning category. Their assertions passed, but the cause is
unresolved and these are not warning-free results. No physical-device or
VoiceOver audit was performed.

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

- Live polling can rebuild an invalidated large-ledger snapshot after each
  five-second playback flush. The rebuild shares the statistics actor with
  recording, so the cached-launch measurement does not prove live-playback
  durability or smooth counters with this ledger size (P2).
- The initial review found device-calendar-dependent cached buckets (P2). At
  the user's request, daily buckets, date-range boundaries, and chart display
  now use UTC Gregorian days. A timezone-change regression covers cached
  reopening and range queries; this finding is resolved.
- Chapter grouping distinguishes exact metadata values; insignificant title or
  boundary changes can split the same chapter's coverage (P2).

The live-polling and chapter-identity findings remain open under the requested
review-and-ship workflow. Three independent reviews found no P0/P1 findings;
the timezone finding is resolved.
