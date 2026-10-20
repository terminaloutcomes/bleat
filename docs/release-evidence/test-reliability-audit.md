# Test reliability audit

Source review is complete for **1,552 test declarations**, plus the shell cases
and shared runners listed below. Issue
[#362](https://github.com/terminaloutcomes/bleat/issues/362) remains open for the
explicit reliability follow-ups and missing execution evidence. Source review
does not mean full compliance. Rules and the required per-test record are in
[Test reliability](../test-reliability.md).

Baseline: `d33a30a767d047b6a12e6f737b07e513e57aaf1c`.
Audit date: 2026-10-16. Source-review decisions below do not imply execution.

The parallel audit records are
[`app.json`](../../TestSupport/TestAudit/app.json),
[`core.json`](../../TestSupport/TestAudit/core.json), and
[`other.json`](../../TestSupport/TestAudit/other.json). All 1,542 JSON records are source-reviewed; the ten gate tests are recorded
individually below. No source-review records remain pending. Read the
[runner and shell-case review](test-reliability-runners.md) alongside them;
source-function discovery alone omits shell scenarios.

Concrete follow-ups are recorded for
[app tests](test-reliability-app-followups.md),
[core tests](test-reliability-core-followups.md), and
[UI/live/tooling tests](test-reliability-other-followups.md).

## Inventory reconciliation

`BLEAT_HOST_SIGNING=unsigned swift test list` discovered 561 host identities.
Comparing the full `suite/function(signature)` identity sets with
`TestSupport/HostTests/inventory.json` found exactly 561 expected identities,
zero missing and zero unexpected. This is discovery evidence only; no tests
were executed by that command. An upstream OpenTelemetry manifest emitted a
deprecated watchOS minimum warning.

The portable [source index](../../TestSupport/TestAudit/source-index.json) has
1,552 unique path/function pairs: 603 app, 557 core, five transcription, 124 UI,
21 core-live, 97 API, 112 scripts (including six Python), 11 `Tests/ScriptTests`,
and 22 test-support
declarations. It is a navigation aid; individual reviews are the evidence.
The source sets reconcile exactly to app 593 plus ten gate cases, core 562,
and other 387. The host inventory excludes the opt-in statistics benchmark.

Built Debug/iOS discovery (`xcodebuild test-without-building -enumerate-tests
-test-enumeration-style flat -test-enumeration-format json`) reports 721 enabled
identities, no disabled identities and no errors: 598 app and 123 UI. The app
target includes three transcription exporter cases already reviewed in core.
Eight app source declarations are excluded from this configuration: three
macOS-only cases and five release-secret-capture cases. The UI statistics
validation case requires its explicit compiler configuration. Four live UI
cases are declared in `BleatUITests.swift` but belong to `BleatLiveUITests`;
file names alone are not runtime suite identities. Each excluded case remains
in its source audit with enabling conditions. Runtime discovery does not claim
execution or remove opt-in prerequisites.

| Inventory | Keep | Fixed | Follow-up | Source reviewed |
| --- | ---: | ---: | ---: | ---: |
| App JSON | 509 | 4 | 80 | 593 |
| Core/transcription JSON | 508 | 2 | 52 | 562 |
| UI/live/tooling JSON | 368 | 11 | 8 | 387 |
| Gate cases below | 5 | 5 (including four added regressions) | 0 | 10 |

The 140 follow-up decisions remain explicitly open. A fixed decision records a concrete change; it does not erase shared-helper
or configuration evidence gaps. A keep decision means the inspected scenario
can remain, not that every real-system configuration was run.

## Shared helpers

| Path / helper | Review and decision |
| --- | --- |
| `Tests/BleatAppTests/TestAsyncGates.swift` / `AsyncGate.waitUntilEntered()` | Fix: replace the unbounded entry continuation with an asserted 30-second condition wait; preserve the caller location. The deadline is a failure budget, not evidence of entry. The condition remains observable for repeated callers. |
| Same file / `waitUntilEntered(timeout:)` | Fix: honor cancellation rather than swallowing it and spinning until the deadline. The 20 ms polling interval only yields between checks of the actor-owned entry state. Timeout and cancellation return false without entering or releasing the gate. |
| Same file / `enterAndWait`, `release`, `reset` | Entry notification precedes suspension; release is idempotent. Reset assumes the previous operation has drained. Follow-up: audit every caller's cleanup and reset ordering, including failure paths. A bounded observer alone cannot make an uncooperative operation finish. |
| Same file / `OneShotPipelineBuildGate` | Keep its synchronous-only worker boundary and one-shot release semantics; tests exercise real off-main-queue delivery. Remove the redundant polling loop from its entry test, which already has an entry expectation. Follow-up: all blocked workers must be released on every test exit. |

## Reviewed test records

The ten gate tests below are in
`Tests/BleatAppTests/TestAsyncGateTests.swift`, suite
`BleatAppTests/TestAsyncGateTests`. Each constructs a fresh gate and owns its
worker/task. They test synchronization helpers, not network or device behavior.
Playback tolerance and live-server prerequisites do not apply. Normal completion
releases and joins the worker. The throwing context-download reuse case also
registers awaited cancellation teardown before its first suspension, so a
cancelled polling sleep cannot leave its operation suspended. Other gate
callers' cleanup remains covered by their individual app audit.
All waits use a 30-second scheduling budget unless explicitly testing timeout.
Pipeline and context-download gate cases compile only for `DEBUG && os(iOS)`.

The ten records apply the nine rules as follows: (1) their named semantic
postconditions are in the table; (2) entry/finish observations have asserted
budgets; (3) playback timing is not applicable; (4) async tasks are joined and
pipeline workers signal completion, with cancellation teardown on the throwing
new fixture test; (5) each case constructs a fresh gate; (6) these are
deterministic synchronization tests, with intentional real dispatch delivery
for pipeline cases, not device/network integration; (7) delayed-entry cases
preserve their regression stimulus and no retry-to-green is added; (8) XCTest
assertions/expectations identify the missing transition and retain the caller
location, while screenshots/player diagnostics are not applicable; (9) exact
executed outcomes and repetitions are recorded below.

| Function | Action and semantic postcondition | Synchronization / decision |
| --- | --- | --- |
| `testAsyncEntryTimeoutDoesNotPoisonLaterEntry` | Observe an unentered gate with a zero budget; require false. Start an operation, observe entry twice, release and join; require entered state. | Add: covers timeout without damaging subsequent entry and repeated observation. No scheduling-delay assumption. |
| `testCancelledEntryWaitReturnsWithoutReleasingGate` | Cancel the observing task before its wait; require false and no entry. Start a separate operation, observe, release and join. | Add: covers cancellation before waiting and later reuse. Cancellation during suspension remains additional coverage to consider. |
| `testAsyncEntryBeforeWaitingAndRepeatedRelease` | Start operation; observe entry, then wait on the already fulfilled expectation. Release twice and require finished notification and joined task. | Keep: proves latched entry and idempotent release with semantic notifications. |
| `testAsyncEntryAfterWaiting` | Capture entry expectation, start operation, await entry, require entered state, then release/join. | Keep: expectation is registered before launch; no guessed yields. Scheduling may deliver entry before the waiter itself runs, which is supported by XCTest. |
| `testAsyncEntryBeyondFormerTwoSecondDeadline` | Delay entry three seconds, then require entered state and release/join. | Keep: delay deliberately crosses the former two-second bug threshold; it is the scenario stimulus, not a completion assertion. |
| `testContextDownloadGateReleaseAndReuse` | Start a fresh fixture gate operation, assert pending within a 30-second condition budget, release twice and join, require no pending operation; repeat with the same gate. | Add: verifies observable entry, repeated release and independent reuse. The 20 ms interval yields between state checks. |
| `testContextDownloadGateCancellationCleansPendingOperation` | Pre-cancel the task, enter the stream gate and join; require no retained pending operation, then release harmlessly. | Add: verifies cancellation removes its continuation instead of leaving fixture state waiting. Cancellation after entry remains follow-up coverage. |
| `testPipelineEntryBeforeWaitingAndRepeatedRelease` | Worker blocks; observe entry, require blocked state, release twice, await finish, call block again and require released state. | Fix: remove duplicate state polling and use the existing entry expectation. |
| `testPipelineEntryAfterWaitingAndReleaseBeforeEntry` | Release twice before worker enters; require both entry and finish, then released state. | Keep: verifies release-before-entry cannot strand the worker. |
| `testPipelineEntryBeyondFormerFiveSecondDeadline` | Schedule entry after six seconds; require blocked state, release, await finish. | Keep: deliberate delayed delivery crosses the former deadline; entry and finish are independently asserted. |

The following tests are in `Tests/BleatUITests/BleatUITests.swift`, suite
`BleatUITests/BleatUITests`. Both launch an isolated fixture-backed app; the
slow-context flag holds metadata preparation in `UITestContextDownloadGate`
until the test taps the debug-only completion control. Neither provides a
working media server. Playback timing and real transfer-completion evidence are
not applicable. The 20-second condition budget bounds record preparation after
release; it is not a minimum delay. Existing context-menu enabled-state
assertions remain and run while preparation is deterministically suspended.

| Function | Initial state, action and postcondition | Decision |
| --- | --- | --- |
| `testBookContextMenuDownloadRunsInBackground` | Signed-in fixture without a completed download; start a context download, verify browsing is usable and the pending action is disabled. Open Downloads, require its prepared record's progress element, remove all, and require the empty state. | Fix: replace the nine-second sleep with the row's observable preparation state. Do not claim media bytes completed. |
| `testContextDownloadAndRemovalAreMutuallyExclusive` | Fixture with a completed automatic cache; remove it and observe Download replacing Remove. Start a replacement; verify Download disabled and Remove absent while preparing. Open Downloads and require a new record's progress element. | Fix: replace the trailing nine-second sleep with an asserted prepared-record condition. The fixture contains only the relevant record. |

## Remaining implementation and evidence

Owner: Bleat maintainers handling issue #362. Keep the issue open until its full
acceptance criteria have evidence. Every JSON follow-up references a concrete
action, rationale and remaining risk in the linked app/core/tooling documents;
runner gaps are listed separately. No additional issues were created.

- Replace remaining guessed yields, fixed-delay completion assumptions and
  unbounded fake gates with observable, bounded completion contracts. Preserve
  cancellation, late-callback and real elapsed-time scenarios.
- Improve the identified assertion and diagnostic gaps, including complete
  failure cleanup and playback readiness/rate/position evidence.
- Make runner selection verification compare exact identities, multiplicities
  and typed outcomes; source discovery alone cannot prove execution.
- Complete owning-suite repetitions and relevant opt-in configurations, live
  server/Collector, signed macOS, accessibility, performance and device evidence.
  Ordinary Simulator results cannot establish CarPlay, audio routes, background
  behavior, spoken VoiceOver output or physical-device behavior.

## Validation evidence

Validation applies to the working-tree changes based on the revision above.
Source-review decisions and execution outcomes are separate.

- `mise exec -- ./scripts/test-host.sh`: signed host lane verified **561 passed,
  zero skipped**, with executed LCOV for BleatCore and BleatTranscription.
  Artifacts: `.build/host-results/tests.xml`, `.build/coverage/swift-host/`.
  The one known issue is intentionally recorded by
  `TestCleanupTests.retainsOperationFailureWhenCleanupAlsoFails`; it checks that
  the original operation failure survives a second cleanup failure. SwiftData
  permission errors are expected read-only-store injections in the chapter job,
  private-cloud persistence/sync, and statistics history tests (`allowsSave: false`).
  An upstream OpenTelemetry watchOS-minimum deprecation warning remains.
- `./scripts/test-testflight-export-options.sh`,
  `./scripts/test-live-profiles.sh`, and
  `./scripts/test-release-screenshot-harness.sh`: each completed successfully.
  Their individual shell scenarios are inventoried in the runner review; these
  commands do not report XCTest case counts.
- Python and Rust executions and counts are in the
  [tooling audit](test-reliability-other-followups.md#execution-status).

### Simulator attempts retained

All Simulator attempts use the Bleat scheme, Debug, iPhone 17 Pro / iOS 26.5,
Xcode 27.0 (27A266a), nonparallel execution, and `.build/xcode-derived`.
`mise exec -- xcodebuild` with `RUSTC` explicitly set to the installed Homebrew
compiler selects Rust consistently for the successful compilation attempts; the checkout's
configuration and caches were not redirected.

1. `.build/issue-362-gates.xcresult`: build failed before tests because Rust
   rejected `--check-cfg` without unstable options. The precise compiler-selection
   mismatch remains unresolved; explicitly selecting the installed Rust compiler
   passed that stage. No test coverage claimed.
2. `.build/issue-362-focused.xcresult`: build failed with no disk space while
   archiving the scripts library. Result summary confirmed **zero tests**.
   Available disk space later recovered; no user data was deleted by this audit.
3. `.build/issue-362-focused-repeat.xcresult`: compilation caught a missing
   explicit return in the changed telemetry fake. Fixed before execution; no
   test coverage claimed.
4. `.build/issue-362-focused-repeat-fixed.xcresult`: 18 unique selected tests,
   **35 runs: 34 passed, one failed, zero skipped**. All 13 selected app tests
   and four of five UI tests passed twice.
   `testBookContextMenuDownloadRunsInBackground` failed its first run at the
   second context-menu Download existence check. The eight-second fixture delay
   expired before that assertion; it failed before the changed final record wait.
   The replacement gate above holds preparation until explicit release. This
   original failed run is retained and is not counted as clean repetition.

The focused selection in attempt 4 was all eight original `TestAsyncGateTests`,
`AppModelTests/testScrubberSeekDecisionConfirmsTenMinuteJumpsInEitherDirection`,
`testSignedInAlertQueueSerializesAndResetsForAccountChange`,
`testTranscriptDeletionWaitsForInitialCheckpoint`,
`RemoteTelemetryConsentTests/testAppModelMonitorsTokenAcquiredAfterDiagnosticsAppears`,
`testTelemetryTokenAvailabilityDiscardsResultAfterWithdrawal`, and UI tests
`testBookContextMenuDownloadRunsInBackground`,
`testContextDownloadAndRemovalAreMutuallyExclusive`,
`testMiniPlayerSwipesDownToStopWhilePlayingAndPaused`,
`testMiniPlayerRestoresWhenStopIsSuperseded`,
`testChapterPickerOpensAtSoleCurrentChapter`.
The command passed each as `-only-testing:<target>/<suite>/<method>` (the gate
suite as `-only-testing:BleatAppTests/TestAsyncGateTests`), with
`-parallel-testing-enabled NO -test-iterations 2 test` and the result path above.

Xcode emitted debugger-version lookup warnings (`noURL`). The result bundle
reported no runtime warnings; tests launched and executed. The tooling warning's
underlying cause remains unresolved and is retained separately from test failures.

5. `.build/issue-362-controlled-download.xcresult`: new fixture-gate tests initially
   failed compilation because their file lacked `@testable import Bleat`. Added
   the import; no test coverage is claimed for this attempt.

6. `.build/issue-362-controlled-download-fixed.xcresult`: **13 identities,
   26 passing runs, zero failed/skipped**. Each of the ten gate tests, corrected
   scrubber boundary test and two controlled-download UI tests passed twice with
   fresh app setup. Exact identities/outcomes were inspected in the result tree.
   Same destination/toolchain and `-parallel-testing-enabled NO -test-iterations 2`
   configuration as above.

The original failed UI attachment showed `Remove Download` in the second menu,
confirming preparation had finished before the pending-action assertion. The
event log records more than 16 seconds between initiating Download and reopening
the menu, beyond the original eight-second fixture delay. The new gate addresses
that observed race without increasing the delay or dropping the assertion.

### Owning-suite run and installation interference

The owning run selected all `BleatAppTests` and `BleatUITests/BleatUITests`,
with `-parallel-testing-enabled NO` and result bundle
`.build/issue-362-owning-suites.xcresult`. UI output reports 102 cases,
101 passed and the intentional external-URL-driver skip
(`testAcceptsExternalURLConfirmationFromHost`, requires `EXTERNAL_URL_DRIVER`).
The result bundle reconciles all 700 expected identities exactly: **698 passed,
one failed, one skipped**, with no missing/unexpected identities and no runtime
warnings. The command exited 65; this is not a passing gate.

The app process received SIGKILL during
`AppModelTests/testPendingLocalSessionUploadDoesNotBlockLaunch`, and Xcode
restarted to run the remaining cases. Captured Simulator system logs identify
`installcoordinationd` requesting termination of the app at the same instant;
this establishes installation interference, not an assertion failure. The
initiating installation client is not identified. Xcode's crash reporter could
not synchronize, and no matching application crash report was captured. The
restarted app also logged an unknown-model-version store error; this run's
shared Simulator state is not clean evidence of persistence behavior.

A separate disposable iPhone 17 Pro / iOS 26.5 Simulator named `Bleat I362 Audit`
was created for the final app-suite repetitions. The command selects all
`BleatAppTests` with `-parallel-testing-enabled NO -test-iterations 2` and
`.build/issue-362-app-final-repeat.xcresult`; it includes the final awaited
gate teardown and interrupted case. The previous run is retained as unsuccessful,
not replaced by a clean retry claim. Its tests had ended before this run began;
only diagnostic collection overlapped. The final run passed **598 identities,
1,196 executions: every case passed twice, zero failed/skipped**. Its exact
identity set matches discovery with no omissions/extras; each result-tree case
has two passing repetition nodes. This includes all ten gate tests and the
previously interrupted case. No runtime warnings or test failures were recorded.
The owned Simulator was shut down and removed after evidence collection;
existing Simulators were preserved.

Both commands used `mise exec -- xcodebuild -quiet -project Bleat.xcodeproj
-scheme Bleat -derivedDataPath .build/xcode-derived`, the destinations above,
and the explicit installed Homebrew `RUSTC` selection. The final run selected
`-only-testing:BleatAppTests test`; the original also selected
`-only-testing:BleatUITests/BleatUITests`. The default test order was retained;
no randomized order or unsupported parallel selection is claimed. A simultaneous
first read of the original bundle with two `xcresulttool` processes collided
while initializing its SQLite cache; sequential extraction succeeded without
rerunning tests. Both summaries and complete result trees are retained.

### Tooling discovery and artifact retention

`cargo test --locked --package scripts -- --list` discovered 109 compiled cases
representing 106 unique source names. The three `ci_smoke::tests` cases appear
in two targets; they are intentional compiled multiplicities, not additional
source declarations. All 106 source cases match discovery without omissions.
`cargo test --locked --package bleat-api -- --list` discovered all 97 source
cases without omissions or extras. Its first build exposed an undeclared
`tempfile` dev dependency introduced by the cleanup change. `cargo add --package
bleat-api --dev tempfile@3.27.0` repaired the manifest and lockfile; discovery
then passed. No test execution is inferred from `--list`.

On that interim fixture revision, the API HTTP integration target passed **12/12**, and its changed
`production_router_preserves_the_signing_configuration_failure` case passed
again **1/1** with eleven filtered. It uses disposable PostgreSQL containers;
pre-existing app-live containers were left untouched.

The final review identified synchronous `TempDir` creation/destruction inside async
API tests. That fixture patch was reverted to obey the explicit concurrency rule;
its pre-existing filesystem lifecycle is now tooling follow-up 8. Cargo removed
the temporary dependency, and both manifests/lockfiles match the baseline.
`cargo test --locked --package bleat-api --test http_api` then passed all
**12 current-source cases**, zero failed/ignored, with each identity checked.

Local command logs, discovery JSON, result-summary/tree JSON and the original
failed UI hierarchy are retained under `.build/test-audit-evidence/`. They are
ignored local artifacts; result bundles listed above remain beside them. Raw
local artifacts can contain host paths and device identifiers and are not
committed or attached to the public pull request. The audit documents retain
only project-relative evidence locations and fixture data.

### Disposable telemetry gate

`mise exec -- ./scripts/test-telemetry.sh` initially failed before live execution
because Docker uses `bleat-api/Cargo.lock`, separate from the workspace lock.
Cargo regenerated the standalone lockfile in an isolated copy of the package;
the sole change was adding the existing `tempfile` dependency to the API package.
The first failure and redacted harness artifacts are retained under
`.build/test-audit-evidence/telemetry-first-failure/`.

The corrected gate completed successfully: four Python artifact-verifier tests;
18 authentication, 19 exporter and 39 remote-telemetry host tests; three live
configuration tests; 97 Rust API tests (75 unit, nine enrollment, twelve HTTP,
one server-startup); and **six actual live telemetry tests**. Individual live
identities verified in output were:

- `TelemetryAuthenticationLiveTests/testSwiftDevelopmentAttesterObtainsVerifiableJWT`
- `AuthenticatedOtlpSpanExporterLiveTests/testExportsWithRealJWTOverOTLPHTTP`
- `OpenTelemetryCollectorLiveTests/testStockCollectorValidatesBleatTokenAndBoundsIngress`
- `TelemetryRecoveryLiveTests/testApiShutdownKillSwitchRetainsThenRelaunchDrainsWithoutReenrollment`
- `TelemetryRecoveryLiveTests/testCollectorOutageRetainsAndDrainsAfterReconnect`
- `TelemetryRecoveryLiveTests/testExistingPipelineRefreshesJWTAndDrainsQueuedSpan`

All passed without skips. Empty auxiliary XCTest bundles and Rust main/doc-test
targets are not counted as coverage; the requested named suites did execute.
The gate also checked effective Collector configuration, redacted capture
structure, outage/retry behavior and owned-resource cleanup. This is local
disposable integration, not physical App Attest, production, or device evidence.

The corrected telemetry command passed a second time with a fresh Compose
project and disposable state: the same 4 Python, 76 host, 3 configuration,
97 Rust and 6 live cases passed again, with zero skips/failures. Each live
identity and outcome was checked in both logs. This is clean repeated evidence
after the retained standalone-lock failure, not a retry substituted for that
failed attempt. Runs used the repository's API test concurrency of four and
normal nonparallel Swift host selection while the owning Simulator suite was
active; no unsupported parallel UI configuration was introduced.

Both successful telemetry runs used the interim API temporary-file fixture and
dependency described above. The final fixture revert does not change the live
exporter or API production implementation; the current HTTP target was rerun
separately after the revert.


## Independent review record

Seven fresh independent review cycles inspected the evolving complete change.
The initial P1 finding (waiting for completed media when the UI fixture has no
media server) was fixed by observing preparation, then the observed eight-second
fixture race was fixed with an explicitly released gate. The latest completed
review, including the final fixture revert and awaited gate cleanup, reports
**no P0/P1 findings**.

- **P2**, `bleat-api/src/http.rs`,
  `health_remains_available_while_protected_capacity_is_exhausted`: a notification
  proved entry but the 40 ms handler could finish before the probe. Initially
  retained as tooling follow-up 6; subsequently fixed on explicit user request
  with a gated handler and before/after semaphore assertions. This later local
  fix is separate from the seven historical independent review cycles.
- **P2**, `bleat-api/tests/http_api.rs`, interim signing-key fixtures: synchronous
  `TempDir` setup/drop inside async tests violated the explicit concurrency rule.
  Reverted the fixture change and its dependency; the pre-existing filesystem
  lifecycle remains actionable tooling follow-up 8.
- **P3**, `TestSupport/TestAudit/core.json`, `source_index`: originally referenced
  a temporary host file. Corrected to the tracked project-relative navigation
  index to comply with the user's explicit repository documentation-path rule.
  The original finding remains recorded here.

The final reviewer also found that the written source breakdown omitted the 11
`Tests/ScriptTests` declarations already present in the inventory and total.
Corrected that documentation reconciliation to satisfy the exact-inventory
requirement; no declarations or audit decisions were missing.

No other lower-priority independent findings were raised. Source-audit findings
are separately enumerated in the linked follow-ups; they are not silently
classified as resolved by the independent review.

Changed-file Swift format lint, `cargo fmt --check`, `git diff --check` and
`mise run docs:check` completed successfully.

## Follow-up 6 remediation

The health-capacity test now holds its protected request through the health
response and verifies both saturation and cleanup. The handler uses a release
notification instead of elapsed time; joined request futures provide structured
cancellation under a five-second failure budget. The existing route deadline
remains and early expiry fails the postconditions.

Validation of the local follow-up on 2026-10-16:

- `cargo test --locked --package bleat-api --lib http::tests::health_remains_available_while_protected_capacity_is_exhausted -- --exact`: one passed, 74 filtered.
- `cargo test --locked --package bleat-api --lib`: all 75 passed, zero failed/ignored; the fixed test ran again in its owning suite.
- `cargo fmt --all -- --check` passed.

The first focused attempt failed at the five-second budget because the revised
fixture omitted request-ID instrumentation required by admission middleware,
so its handler never entered. Restoring the same middleware used by the original
fixture resolved that setup defect; this failed attempt is retained separately
from the subsequent passing focused and suite runs. These are in-process Rust
unit tests, not new live-server or device evidence.

## Timing and synchronization batch (2026-10-16)

This batch follows runner-verification commit `09908d5`. It replaces guessed
scheduler turns and unbounded fixture-entry waits in selected core tests with
bounded signals, explicit caller-arrival barriers, and observed completion.
Private CloudKit callback deadline tests advance an injected clock; production
uses `ContinuousClock` and asynchronous sleeping. Statistics tests check the UTC
reporting calendar without changing the process-wide default time zone.

Application coverage in this batch is limited to cancelled selection resume,
late completed-download callbacks, and retired Now Playing command callbacks.
Their negative assertions now wait for the actual owning operation to finish.
The edit-during-download UI changes were attempted but excluded from this
checkpoint after the failures documented below. Their original follow-ups remain open.

This is a partial remediation batch. Historical review decisions and counts
above remain the original audit snapshot. The per-test `timing_batch` annotations
record later source changes without erasing unrelated findings. Remaining work
includes app live-update/reconciliation/playback synchronization, UI playback
menu tick evidence, live JWT expiry timing, deep-link readiness, telemetry runner
request deadlines, and core waits not converted here. The cache-read watchdog
now reports timeout, but an uncooperative detached read can still outlive the
test after cancellation; that cleanup gap remains open.

### Completed host checks

- `BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel
  --xunit-output .build/timing-state.xml --filter
  'HTTPTransportTests|LibrarySearchCoordinatorTests|PrivateCloudSyncTests|PrivateCloudPersistenceTests|StatisticsExplorationTests|LibraryCachePerformanceTests'`:
  114 tests passed, zero failures or skips.
- `BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel
  --filter 'TelemetryAuthenticationTests|OpenIDAuthenticationTests|LogoutTests|AuthenticatedRequestTests|AuthenticatedOtlpSpanExporterTests|RemoteTelemetryTests'
  --xunit-output .build/timing-auth.xml`: 130 tests passed, zero failures or skips.
- `mise exec -- ./scripts/test-host.sh` (with the Homebrew Rust compiler selected through `RUSTC`):
  all 561 signed host identities passed, zero failures or skips; exact inventory
  verified. XML and coverage are under `.build/host-results/` and
  `.build/coverage/swift-host/`; console log `.build/timing-signed-host.log`.
  This owning-suite run repeats the affected core cases after their focused runs.

The dependency build emits the upstream OpenTelemetry watchOS minimum-version
deprecation. SwiftData permission diagnostics belong to deliberately read-only
store/save-failure fixtures that passed. Initial compilation attempts caught a
missing `await`, initializer argument order, and an actor-owned iterator access;
these were corrected before the successful runs. Two redundant-await warnings
were removed before the auth and signed-host runs. No failed compile is counted
as executed coverage.

### Simulator attempts and review

The initial focused build rejected an unsupported generic XCTest `value` wait;
that now uses a bounded predicate. A second build caught the missing telemetry
`await` noted above. Neither attempt executed tests. Their result bundles and
logs remain `.build/timing-focused.*` and
`.build/timing-focused-corrected.*`.

The first completed focused run used two repetitions and retained
`.build/timing-focused-final.xcresult`: 11 app identities passed twice (22
executions), while both edit-download UI identities failed twice (four failures).
The failures measured a 60-second menu interaction: continuous accessibility
value changes prevented XCTest from observing UI idleness. A subsequent attempted fixture requested exactly two progress callbacks through
a non-dismissing test menu command, with editor-controlled completion. That
attempt also failed because the native menu did not expose the progress
accessibility value (`-1` sentinel at the initial observation). All UI fixture
and UI test edits were excluded from this checkpoint; their unfinished patch
is retained locally at `.build/timing-ui-unfinished.patch`. Neither attempt is
counted as successful UI coverage. The run's result
summary reports no runtime warnings; the console also emits Xcode debugger
version lookup diagnostics, which are retained with the log.

One full independent review cycle found no P0/P1 findings. Its P2 finding remains
open: the detached cache-read task may survive the timeout cleanup branch if
cancellation is not observed. An earlier partial review also noted stale audit
wording; the subsequent batch annotations and explicit historical-snapshot
wording distinguish original findings from current changes.

The second full independent review also found no P0/P1 findings and retained
four P2 findings, which remain open under the review-and-ship publication policy:

- `Tests/BleatCoreTests/LibraryCachePerformanceTests.swift`: cancellation followed
  by a failed cleanup watchdog can leave the detached workload alive.
- `Tests/BleatCoreTests/PrivateCloudSyncTests.swift`, `CloudKitCancellationProbe`:
  entry is signaled before the release continuation is installed. A release in
  that suspension window can be lost. The changed logout transport fakes have
  the same signal-before-continuation ordering.
- `Tests/BleatCoreTests/OpenIDAuthenticationTests.swift`: a failed bounded session
  start expectation continues into `sessions[0]`, which can trap if no session
  exists.
- `Tests/BleatCoreTests/LogoutTests.swift`: a failed bounded transport-entry
  expectation can continue into a no-op release and an unbounded task join.

Passing executions do not close these adverse-scheduling and failure-path gaps.

The excluded controlled-progress attempt is retained at
`.build/timing-ui-controlled.xcresult` and `.build/timing-ui-controlled.log`:
both UI identities failed both repetitions (four failures), with no runtime
warnings in the result summary. After all test cases had completed, its
post-test `simctl diagnose` collection was stopped after three minutes so Xcode
could finalize the result bundle; partial diagnostics remain in that bundle.

A third complete read-only review checked the final checkpoint after removing
all UI edits. It confirmed no P0/P1 findings and the same four open P2s.
Changed Swift sources pass strict `swift-format` lint; documentation references
and `git diff --check` pass. No live-server, app-live, physical-device, archive,
or broad UI-suite evidence is claimed for this checkpoint.

Final owning app-suite validation used `mise exec -- ./scripts/xctest.sh -d
'platform=iOS Simulator,id=<disposable-simulator>' -t BleatAppTests -r
.build/timing-app-suite.xcresult` (Homebrew Rust selected through `RUSTC`).
Built-product discovery found exactly 598 identities, and result verification
confirmed all 598 passed with zero skips. Results are
`.build/timing-app-suite.xcresult`, its `.discovery.json` companion, and
`.build/timing-app-suite.log`. This repeats the changed app cases in their owning
suite after the earlier 22 focused executions. The final checkpoint includes
no UI fixture or UI test changes.

## Follow-on timing batch (2026-10-16)

This batch follows `4c9d1c3`. Core fakes retain release-before-entry requests,
OpenID browser setup stops after failed readiness instead of indexing an empty
session array, and staged authentication and telemetry withdrawal use bounded
async observations. Logout refresh-race tasks retain cancellation handles and
observe completion before joining. The cache workload checks cancellation
between reads; its existing P2 remains open because an in-flight framework read
may ignore cancellation and outlive the five-second cleanup watchdog.

Application changes add typed operation notifications for live-event consumption,
refresh/reconciliation completion, series admission and session uploads. Download,
transcription, network and CarPlay cases use asserted state or callback-processing
conditions. Real-player scenarios include readiness, playback rate and position
diagnostics. The historical audit snapshot is unchanged; follow-on annotations
record source remediation separately from execution evidence.

Runner changes replace the deep-link seed delay with an observation of the
persisted scenario and cleared receipt, retain a redacted driver log, bound
telemetry HTTP requests including response bodies, and allocate separate telemetry
artifact directories per run. The JWT integration test explicitly checks refresh
eligibility; its remaining 1.1-second delay crosses the issuer's whole-second
claim boundary, rather than waiting for an asynchronous operation to complete.

Initial focused core execution passed 151 tests across six suites, with zero
failures or skips (`.build/core-timing-focused.xml`). A cache/logout rerun passed
15 tests across two suites (`.build/core-timing-final.xml`). A final failure-only
cancellation-handle edit followed those runs; the owning signed run is separate
evidence. The upstream OpenTelemetry watchOS minimum-version deprecation and
expected read-only SwiftData fixture diagnostics remain recorded. No failed
compilation or incomplete run counts as executed coverage.

The subsequent signed owning gate passed all 561 identities with zero skips
(`.build/timing-followon-signed-host.log`, XML in `.build/host-results/`).
The Rust scripts library passed all 50 tests, followed by seven passing readiness
regressions (`.build/timing-runner-final.log` and
`.build/timing-runner-focused-final.log`). The earlier 48-test run predates the
last two readiness regressions and is retained at `.build/timing-runner-all.log`.
Documentation references passed after the source annotations were updated.

The first simulator follow-on build caught malformed diagnostic string
interpolations. The corrected build caught a teardown actor-isolation error,
two initializer argument-order errors and a missing fake network-path argument.
Both attempts executed zero tests; logs and result bundles are retained under
`.build/timing-ui-event-driven.*` and `.build/timing-ui-event-driven-fixed.*`.

A third simulator build retained at `.build/timing-ui-final-source.*` caught an
incomplete network-state fixture initializer. After supplying explicit path
fields, `.build/timing-ui-compiled.xcresult` ran all four changed UI identities
twice: eight passes, zero failures or skips. The menu cases observe the existing
playback slider changing while the overlay remains open; the download cases
observe two requested progress callbacks and explicit fixture completion.
The simulator console also reports Apple launch-measurement failures, duplicate
`UIAccessibilityLoaderWebShared` definitions in Apple accessibility bundles, and
Xcode debugger-version lookup diagnostics. These system diagnostics remain
unresolved; the eight executions completed without an application crash.

The telemetry runner initially failed its Rust doctest phase because Homebrew
`rustc` and rustup `rustdoc` were mixed. Its log and redacted, per-run failure
artifacts are retained. Repeating with matching Homebrew `RUSTC` and `RUSTDOC`
passed (`.build/timing-telemetry-runner-corrected.log`): four Python artifact
checks; 76 Swift Testing host cases; three XCTest configuration cases; 75 Rust
library tests, nine PostgreSQL, twelve HTTP and one OTLP integration tests; and
six exact live telemetry XCTest identities. Empty Rust binary/doctest targets
are not counted as coverage. The workflow's disposable-container, volume and
raw-capture cleanup checks completed successfully.

The first focused app run selected 71 annotated identities and reported four
failed cases (eight assertions). The failures exposed test setup/order problems:
startup catch-up was not drained before a missing-item live update; the isolated
session store was not injected into `AppModel`; playback advanced before an
exact reset-position assertion; and download recovery was allowed before the
offline assertion. The fixes preserve each semantic assertion by observing the
right lifecycle or holding the intended path state. The original run remains
`.build/timing-app-followon-focused.xcresult` and its console log; it is not a
passing repetition sequence.

Three independent full merge-diff reviews of this follow-on batch found no P0/P1
issues. Their retained P2 findings are:

- `Tests/BleatCoreTests/LibraryCachePerformanceTests.swift`: an uncooperative
  detached cache read can outlive its bounded cancellation cleanup.
- `Tests/BleatAppTests/AppModelTests.swift`,
  `testLiveProgressEchoDoesNotRefreshStreamedPlayback` and
  `testLiveProgressUpdatesFinishedStateImmediately`: observing event consumption
  alone does not drain a mistakenly scheduled 250 ms refresh debounce before
  the negative request-count assertion. Those negative assertions remain an
  evidence gap even if the tests pass.
- `scripts/src/runner_readiness.rs`, `redact_driver_log`: bare `Bearer` credential
  lines without an `Authorization` label are not covered by the current
  redaction patterns. Driver-log retention is not a complete credential scrubber.

These P2 findings remain open under the review-and-ship publication policy;
passing executions do not close them. The third review covered the runtime corrections, including isolated-store
injection, refresh completion, reset-position ordering and offline retry state.

The failed app run's post-test `simctl diagnose` collector was stopped after four
minutes; all 71 test cases had already completed. Its partial diagnostics remain
in the result bundle. This limits diagnostic collection, not test execution.

The supported deep-link workflow passed with matching Homebrew Rust tools and a
separate derived-data directory. The seed check observed the persisted scenario
and cleared receipt before termination; route outcomes and the malformed-route
observation window completed; exact verification found one passed driver identity
and zero skips. Its bundle is
`.build/deep-link-results-379ca373-9df5-4ca4-bc25-12c777c2cf08.xcresult`, with a
retained redacted `.log` companion and `.build/timing-deep-link-runner.log`.
That retained log contains no bare Bearer marker; this execution does not close
the general redaction-pattern P2. The workflow removed its disposable Simulator
and raw driver log on exit. The malformed-route check observes a bounded
10-second window and does not claim that no later event is possible.

The first corrected four-case run executed eight repetitions: the isolated-session
and playback-reset cases passed twice each, while the missing-item and transport
cases still failed twice each (ten assertions total). The missing-item setup
registered its observer expectation after startup; that expectation now precedes
startup. Transport callback recovery remained unresolved in this attempt.
Evidence is retained in `.build/timing-app-corrected.xcresult` and its log.

## Build-helper dependency isolation (2026-10-16)

The Xcode metadata phase now builds `build-scripts`, which owns configuration
validation, release versions, build-number resolvers and plist generation.
The operational `scripts` package depends on this small package; the reverse
dependency is forbidden. Normal/build dependency-tree checks reject the HTTP,
TLS, async runtime and native compiler stacks previously pulled into the phase.
Both launch paths preserve the caller's compiler and SDK environment.
Historical audit paths for moved Rust tests refer to the original audit snapshot;
the current tests are under `build-scripts/tests/`, with upload/device integration
coverage retained under `scripts/tests/`.

The ordinary shell build and the actual Xcode `build-for-testing` command passed
without `RUSTC`, `RUSTDOC`, SDK-selection or wrapper-clearing overrides. The Xcode
log is `.build/build-scripts-xcode.log`; this proves compilation, not app test
execution. The initial consumer check found a stale package-local binary
reference; the CLI regression moved with its binary, while all three remaining
consumer tests passed. The original failure and corrected results remain in
`.build/build-scripts-consumers.log`.

Final package verification passed 26 tests with zero failures or skips;
`cargo check --locked --package scripts --all-targets`, formatting, release
metadata and documentation checks also passed. Xcode emitted its existing
AppIntents metadata-extraction warning (no framework dependency). The extraction
review found the already-reproduced stale CLI test reference and one stale SDK
documentation paragraph; both were corrected to complete the requested move
and accurate documentation.

The earlier owning UI run completed independently of the package extraction:
100 cases passed, the external-URL driver opt-in case skipped, and
`testTranscriptCurrentPositionWaitsForCacheLoad` failed. Exact-result verification
rejected the run (`.build/timing-ui-owning.xcresult` and companion log). This
remains an unresolved timing-batch gate; the successful helper build does not
resolve it.

A further extraction review caught release-workflow path filters still naming
the moved resolver sources; those filters now follow the new package. The final
independent extraction review reported no findings.

## Transcript cache gate correction (2026-10-16)

`testTranscriptCurrentPositionWaitsForCacheLoad` originally depended on a
five-second sleep in `UITestAppService.cachedChapterTranscripts`. In the retained
owning-run log, navigation occurred at 6.49 seconds, while accessibility queries
delayed the negative action assertion until 20.31 seconds. The fixture could
complete normally before that assertion; this was a test synchronization race,
not evidence that the loaded-state UI guard was missing. The view exposes the
action only after `hasLoadedTranscriptCache` becomes true.

The fixture now waits on an explicit, cancellation-aware async gate. A debug/UI
testing-only release button appears only while a cache request is waiting. The
test observes that state, checks the action is absent, releases the gate, and
checks both the action and cached chapter segment appear. Cleanup releases a
still-visible gate, and cancellation removes an owned waiter. The prior audit's
keep decision missed this timing dependency; its follow-up annotation corrects
that assessment without treating the earlier passing reruns as a fix.

The rebuilt test passed three consecutive executions (13.318, 13.777 and
13.656 seconds), with exact result verification reporting three passes and zero
skips in `.build/transcript-cache-gate.xcresult`. Strict Swift formatting passed
and independent review found no findings. No compiler overrides were used.
This focused rerun does not claim a new full UI-suite pass. Existing Apple
Simulator launch-measurement/accessibility diagnostics remain in the log.

## Post-extraction app verification (2026-10-16)

The four corrected app cases and the unchanged cache-load UI case initially
passed twice each: ten exact outcomes with zero skips in
`.build/post-extraction-focused.xcresult`. The owning app target then passed
all 598 discovered identities with zero skips in
`.build/post-extraction-app-owning.xcresult`. Neither command used compiler
overrides. The later explicit cache gate has its separate three-run evidence
above; a full UI suite has not been rerun after that gate change.

## Requested P2 remediation (2026-10-16)

The live-refresh negative assertions now observe scheduling synchronously,
before the debounce starts, and compare that count after update consumption.
The two focused identities passed three repetitions each with zero skips in
`.build/p2-live-refresh.xcresult`; the owning app suite verified all 598
identities passing with zero skips in `.build/p2-app-owning.xcresult`. Existing
AVFoundation fixture diagnostics remain in the focused log.

Driver-log redaction now removes whole lines containing unlabeled Bearer
credentials, including mixed-case schemes and tab separators. Focused coverage
passed eight readiness tests, and the owning Rust library passed all 51 tests
(`.build/p2-redaction.log`, `.build/p2-rust-owning.log`).

The cache-child harness initially failed its own checks: its first invocation
selected no child test, and a later invocation exposed a mismatched readiness
marker and an intentionally suspended checked continuation that emitted a leak
warning. Those attempts are not passing cache evidence. The fixture was
corrected to use a retained async-stream gate and structural child-result
verification, with explicit termination observation.

The final cache test uses process isolation with a retained termination observer.
The parent never returns while the child is still running: it joins a completed
workload or kills and reaps the timed-out process. Startup has its own bounded
readiness check; output drains asynchronously; XML verifies one matching child
test. The intentional hang uses a retained async-stream continuation. Focused
unsigned and signed runs each passed one parent test, which also verifies the
controlled timeout path and one successful workload child. Logs are
`.build/p2-cache-unsigned-final.log` and `.build/p2-cache-signed.log`; the signed
report is `.build/p2-cache-signed.xml`. Earlier compilation failures from an
unnecessary FoundationXML import and missing `try` on pipe closure are retained
in the preceding unsigned attempt logs.

All three requested P2 findings are now addressed in source. Independent review
of the combined fixes reported no findings. No compiler overrides were used.

The final signed owning `LibraryCachePerformanceTests` suite passed all four
identities with zero failures or skips (`.build/p2-cache-suite-signed.xml` and
companion log). Swift strict-format lint, Rust formatting and documentation
references were checked after the fixes.

## PR review corrections (2026-10-17)

The three review findings on PR #367 were confirmed against `cb3caba` and
corrected in the current bounded PR #367 batch. Remaining work is staged under
issues #369 through #376; this batch can integrate independently of epic or
release completion:

- Search fixture entry could precede continuation registration. Its explicit
  not-registered/waiting/released state now retains an early release and makes
  repeated release harmless. The first-call decision is captured before the
  actor hop. Two bounded regressions cover release before and after registration.
- Cache-child supervision treated cancellation as a fake process exit and could
  hang during task-group teardown. Cancellation now has its own outcome and
  shares termination/reaping cleanup with timeout. Retained observers drain
  output before cancellation propagates and owned reports are removed. The
  externally supervised regression covers cancellation before launch, during
  startup and after readiness. Independent rescue watchdogs contain nested
  children if cleanup regresses; needing a rescue is a test failure.
- The default Audiobookshelf runner omitted the collector-outage recovery case
  from its exact skip declarations. That identity is now allowed there, while
  the configured telemetry runner still requires it to pass. The regression
  checks exact allowance, unrelated-skip rejection and strict default behavior.

Validation artifacts:

- `pr367-review-focused-typed.xml` under `.build/`: both affected host suites,
  15 identities passed, zero failures/errors/skips.
- `pr367-review-repeated.xml` and its log under `.build/`: five selected
  cancellation/release identities ran three native repetitions each. The XML
  contains five aggregate records; the log verifies all 15 executions.
- `pr367-review-signed-host.log` under `.build/`: the signed host gate verified
  all 564 inventory identities passing with zero skips and exported coverage.
- `cargo test --locked --package scripts --test swift_test_results`: 11 tests
  passed. Strict Clippy for that target, strict Swift formatting, shell syntax
  and diff checks passed.
- Three earlier focused build attempts failed at the regression's inferred
  catch type and executed zero tests. Their logs are retained under `.build/`
  as `pr367-review-focused.log`, `pr367-review-focused-corrected.log` and
  `pr367-review-focused-final.log`. An explicit typed `do` boundary corrected
  the error; those attempts are not counted as test evidence.

Independent read-only review of the complete corrections returned no findings.
Live validation:

- Default `mise exec -- ./scripts/test-live.sh`: 13 passed and eight exact
  expected skips, including collector outage, from 21 discovered XCTest cases.
  `pr367-review-live.log` under `.build/` retains the verified selection and
  cleanup. The current-stable 2.37.0 compatibility profile independently passed
  the same 13/8 selection in `pr367-review-compatibility.log`.
- `mise run test:compatibility` did not pass overall. The minimum 2.26.0
  profile executed no tests: GHCR denied the pinned image manifest pull before
  startup. The command used normal host access. Its original output remains in
  `pr367-review-compatibility.log`; no image pin or authentication setting was
  changed to conceal the blocker.
- `mise run test:telemetry` passed: four Python checks, 76 Swift Testing cases,
  three configuration XCTest cases, 97 Rust API cases, and six live telemetry
  XCTest cases. Collector outage passed with no skip allowance. Reports and
  native observations are under `.build/swiftpm-test-results/`; the final log
  is `.build/pr367-review-telemetry.log`. Owned containers, volumes and raw
  temporary capture data were removed by the gate.

The minimum-profile image remains an external compatibility-validation
prerequisite, owned by the Bleat maintainers under issue #376. It is not a
failed test or an unmet development-merge gate for this bounded batch. Broader
configuration and release evidence remains owned by the staged follow-ups;
issue #369 reconciles current dispositions against the historical audit.

CI for review-fix head `39fd45a` passed all five workflows, including 608 verified
iOS smoke passes and zero skips in [Validate Bleat run 39021211739](https://github.com/terminaloutcomes/bleat/actions/runs/39021211739).
Subsequent branch updates require their own normal CI; the PR records its final
head and checks. This batch does not close issue #362 or claim new physical-device,
full app-live, signed macOS authentication or release archive evidence.

## Missing audit entry repair (#369)

The bounded repair adds substantive records for five existing host functions:
three DownloadStorage fixture-cleanup contracts (including both deletion-failure
arguments), unexpected OpenID route cleanup, and cache-child cancellation/reap
supervision. Nine build-helper functions gain individual records: six typed
paid-build validation cases and three caller-environment/dependency/sandbox-input
checks. Each has concrete setup, actions/postconditions, applicable rule
assessments, compiler/argument conditions, rationale and version-specific
execution evidence. No underlying test or application implementation changes.

Current declaration matching also reconciles 18 moved build-helper records and
index locations. Some old `scripts` files still exist with different consumer
tests, so checking only path existence was insufficient. The obsolete SDK
compiler-override test is preserved in explicit historical arrays, with its
removal commit and three replacement contracts; it is not a current missing
function. Existing unrelated assessments remain unchanged. The current core
record set has 606 default runtime identities plus the retained opt-in
250,000-slice case; the historical 562-record source-review count remains a
baseline, not a new current-discovery claim.

The Rust `validate-test-audit` check requires current audit/index presence for
host inventory and ordinary Rust tests in build-helper source/tests and its own
regression file. Eight new audited/indexed regressions cover the actual
checkout, missing host/Rust audits, missing indexes, stale identities/source,
duplicates, placeholder reviews and empty required scopes. Active scoped Rust
audit/index records are also checked in reverse against declarations. The checker performs
no builds, network calls or writes; compiler discovery, argument cases, semantic
truth and the remaining repository inventory require separate evidence.

Source review found no per-child deadline in the three newly recorded command
boundary tests. They retain actionable follow-ups under #370 with owner,
remaining risk and next verification action; a passing Cargo command is not
claimed as kill/reap proof. This is not an exhaustive subprocess-lifecycle audit.
Broader #362/#369 reconciliation and other lifecycle/configuration gates remain
open.

Validation on m2 after integration of the reviewed #416 main merge:

- Final checker regression target: **8/8** exact native function identities,
  zero failures, ignored or filtered tests. Unknown decisions/unreviewed states
  and empty build-helper sources are rejected as well as the original missing,
  stale, duplicate and placeholder cases.
- Existing build-helper all-target suite: **27/27** exact module-qualified
  identities, zero failures or skips, with unchanged package source.
- Final parity command: **606 host functions and 35 scoped Rust functions**
  (27 build-helper declarations plus eight checker regressions). These are
  source/record counts, not an additional runtime execution count.
- Strict all-target scripts Clippy, workspace formatting, documentation,
  scope/preservation and diff checks pass. Detailed source hashes, commands,
  identities and retained attempts are in `.build/i369-audit-verification.json`.

The initial checker runs passed seven negative fixture identities but correctly
rejected the current repository for stale release-version audit/index paths.
Both failed attempts remain retained; mappings were corrected using actual
function declarations, and no assertion or case was removed. Retained signed
host evidence has 606 exact passing identities, including both known-issue
cleanup arguments; it is tied to unchanged Swift source and is not a fresh run
caused by these metadata edits. The retired SDK record and all 602 existing core
assessments are preserved; unrelated source/index/other records are unchanged.
Fresh exact-head CI and independent review remain separate requirements.

Independent local review of `aef2911` found a P2 in the checker: removing a
Rust test attribute while retaining its audit/index rows still passed with 34
Rust declarations. The local correction checks active scoped Rust records in
both directions. The existing stale-record regression now removes the attribute,
the declaration and the source file in isolated fixtures; each case requires
the exact typed orphaned-audit error, then the orphaned-index error after the
audit is removed. A surviving build test prevents empty-scope rejection from
masking these assertions. Historical arrays remain outside active comparison.
The original eight-pass evidence is retained separately from review-corrected
validation; exact-head re-review and CI are still required before clearance.
