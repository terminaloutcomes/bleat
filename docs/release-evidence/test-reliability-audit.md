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
| UI/live/tooling JSON | 368 | 10 | 9 | 387 |
| Gate cases below | 5 | 5 (including four added regressions) | 0 | 10 |

The 141 follow-up decisions remain explicitly open. A fixed decision records a concrete change; it does not erase shared-helper
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
  proves entry but the 40 ms handler can finish before the probe. Retained as
  tooling follow-up 6; not fixed under the review-and-ship lower-priority rule.
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
