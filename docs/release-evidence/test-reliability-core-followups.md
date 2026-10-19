# Core test reliability follow-ups

These are source-review findings for [issue #362](https://github.com/terminaloutcomes/bleat/issues/362). Owner for each item: Bleat maintainers handling #362. None is claimed fixed or validated here unless noted.

| Test | Follow-up | Rationale and remaining risk |
| --- | --- | --- |
| `Tests/BleatCoreTests/TelemetryAuthenticationTests.swift::testCachedTokenAvailabilityReportsActiveAcquisition` | Replace the unbounded `Task.yield()` loop waiting for `tokenCount > 0` with a bounded, asserted notification from the fake transport. | If acquisition never reaches the transport, the test hangs instead of reporting the failed stage and elapsed timeout. |
| `Tests/BleatCoreTests/TelemetryAuthenticationTests.swift::testCancellingOnlyWaiterCancelsUnderlyingRefresh` | Replace both unbounded `Task.yield()` loops (token request and cancellation observation) with registered, bounded completion signals and useful timeout failures. | A regression before token request or cancellation can hang the host suite indefinitely. |
| `Tests/BleatCoreTests/TelemetryAuthenticationTests.swift::testDisablingCancelsRefreshAndClearsMemoryToken` | Replace the unbounded `Task.yield()` wait for a token challenge with a bounded transport-start signal. | If refresh never starts, the test hangs before it can assert disable behavior. |
| `Tests/BleatCoreTests/OpenIDAuthenticationTests.swift::OpenIDWebSessionFactory.waitUntilSessionStarts` (callers include browser lifecycle tests) | Use a registered start notification and bounded wait, then assert session start with the caller's source location. | The helper loops forever if the session never starts and relies on scheduler yields instead of an event contract. Audit every caller when changing the helper. |
| `Tests/BleatCoreTests/LogoutTests.swift::testLogoutSettlesRefreshAndInvalidatesTheRotatedToken` | Replace the 1,000-yield loop polling `isSigningOut` with a state-change signal or bounded predicate wait. | The bound is a scheduler-iteration count, not a time budget; failure diagnostics do not report elapsed time or a meaningful timeout. |
| `Tests/BleatCoreTests/TranscriptExportTests.swift::testCanonicalTranscriptExportHasSourceIndependentSemantics` | Rename this test to state that it checks repeatability, or make its two inputs originate from distinct local/imported paths and compare their semantic output. | Both current variables call the same exporter with the same canonical array, so the equality assertion does not establish source-independent behavior named by the test. |
| `Tests/BleatCoreTests/LogoutTests.swift::testConcurrentLogoutAndAuthenticatedRequestAreRejected`, `testLogoutRejectsAnOverlappingLocalLogin`, `testLogoutSettlesRefreshAndInvalidatesTheRotatedToken`, `testRequestCannotStartRefreshAfterLogoutBegins`, `testSuccessfulResponseStartedBeforeCompletedLogoutIsInvalidated` | Replace unbounded fake-entry continuation waits with bounded condition signals; replace the 1,000-yield `isSigningOut` loop with a typed state-change notification. | Missing login/logout/refresh transition can currently suspend a test forever. The yield loop uses scheduler iteration count rather than a deadline or observed state event and may be flaky under load. Preserve the ordering and late-result race assertions. |
| `Tests/BleatCoreTests/AuthenticatedOtlpSpanExporterTests.swift::testCancellingAsyncExportCancelsTokenWaitBeforeRPC`, `testCancelActiveExportsCancelsAsyncTokenWaitBeforeRPC`, `testCancellationUnblocksTokenWaitAndShutsTransportOnce`, `testCancellationAfterTokenCompletionPreventsRPCAndAllowsLaterExport` | Replace `DispatchSemaphore.wait` readiness helpers with bounded async signals and source-located timeout failures. | These async tests synchronously block their executor while waiting up to two seconds for token/RPC entry; a semaphore is not an async completion contract and can starve work under constrained test scheduling. |
| `Tests/BleatCoreTests/AuthenticatedOtlpSpanExporterTests.swift::testConcurrentExportsUseProviderSafelyAndReuseOneClient` | Replace the token fake’s 50ms sleep window with a barrier proving concurrent callers have joined before token release. | A sleep approximates overlap but does not guarantee all eight export tasks join the same refresh under slow scheduling. |
| `Tests/BleatCoreTests/AuthenticatedOtlpSpanExporterTests.swift::testAsyncTransportShutdownWaitsForClosureCompletion` | Bound the fake shutdown gate’s entry notification and report if the close closure is never entered. | `waitUntilEntered()` uses an unbounded continuation; the explicit release only happens after that wait returns. |
| `Tests/BleatCoreTests/AuthenticatedOtlpSpanExporterTests.swift::testBearerNeverAppearsInCapturedProcessLogs` | Capture output in a subprocess or enforce process-wide exclusive serialization, and restore both file descriptors through guaranteed cleanup. | `captureStandardOutput` redirects process-global stdout/stderr while other Swift Testing suites can execute concurrently; a restoration failure can also leave a descriptor redirected. |
| `Tests/BleatCoreTests/AuthenticatedRequestTests.swift::testTwentyUnauthorizedRequestsShareOneRotatingRefresh`, `testTwentyUnauthorizedRequestsShareOneRejectedRefresh`, `testConcurrentRejectionJoinsInFlightRefreshInsteadOfStaleStoreRead`, `testJoinerRecordsOriginatorRejectedTokenInCompletedRefresh`, `testConcurrentRejectionJoinsFailingInFlightRefresh`, `testTwentyUnauthorizedRequestsShareOneSavedPasswordRecovery` | Add bounded, diagnostic arrival notifications to the concurrent HTTP fake barriers and staged refresh gates. | Count barriers currently suspend with checked continuations until all request calls arrive, and gated tests wait for refresh/save/initial-send states indefinitely. If a regression prevents a stage from occurring, the test process hangs rather than reporting which transition timed out. Preserve each cancellation/coalescing race scenario. |
| `Tests/BleatCoreTests/AuthenticatedRequestTests.swift::testMissingSavedCredentialsMemoizesConclusiveFailure` | Rename to describe memoization of conclusive refresh status failure, or construct an actual missing-credentials fixture and assert that typed result. | The current fixture has old access/refresh tokens and the scripted refresh returns 503; it does not exercise missing credentials despite the test title. |
| `Tests/BleatCoreTests/HTTPTransportTests.swift::testEndpointRouterStreamsEveryServerConnectionPurpose` | Bound each `AsyncStream` event read and report the missing snapshot stage on timeout. | Three awaited `iterator.next()` calls have no deadline, so a missing initial/update yield can hang the suite. |
| `Tests/BleatCoreTests/HTTPTransportTests.swift::testOpenIDTransportKeepsThenClearsSessionCookies` | Replace the test URLProtocol helper’s `preconditionFailure` for unexpected route with a captured typed test failure. | An unexpected adapter request currently traps the process instead of reporting the failing route as a test issue. |
| `Tests/BleatCoreTests/OpenIDAuthenticationTests.swift::testNativeBrowserCallbackAdapterRunsOffMainActor` | Bound the continuation awaiting the detached framework callback and report missing callback completion. | The test invokes the actual callback adapter off MainActor, but a regression that drops the callback leaves the test suspended indefinitely. Preserve all success/cancel/failure adapter cases. |
| `Tests/BleatCoreTests/OpenIDAuthenticationTests.swift::testConcurrentAttemptIsRejectedWithoutDisturbingActiveFlow` | Bound OpenIDBrowserGate entry notification and retain source-located timeout diagnostics. | The gate’s checked continuation has no deadline, so failure to enter browser authentication can hang before concurrency assertions. |
| `Tests/BleatCoreTests/LibrarySearchCoordinatorTests.swift` (all callers of `SearchTestSleeper.waitForSleepCount` and `SearchTestService.waitForFirstCall`) | Add bounded, source-location-preserving start signals to fake sleeper/service gates and assert each signal before release/cancellation. | The actor continuation helpers correctly coordinate the intended concurrency order, but wait forever if the coordinator stops scheduling debounce or never invokes the repository. This can hang all eight tests rather than fail at the missing transition. Keep the deterministic sleeper and cancellation race scenarios. |
| `Tests/BleatCoreTests/PrivateCloudSyncTests.swift::testFetchedCallbackDeadlinePausesInBackgroundAndBlocksRetryUntilDrain` and `testFetchedCallbackProgressResetsNoProgressDeadline` | Replace wall-clock sleeps/manual deadline probes with a controlled clock where feasible, or add a typed notification to observe deadline reset/expiry. Preserve the actual background pause and elapsed no-progress contract. | Both tests use intended elapsed-time coverage, but the progress case sleeps 600 ms, checks for non-expiry, sleeps another 600 ms, then expects expiry for a one-second deadline; scheduler delay before the progress check can turn the first expectation flaky. The background case also relies on 50 ms sleeps for deadline propagation. Keep the cancellation/drain postconditions; make the timing boundary controllable and diagnostic. |
| `Tests/BleatCoreTests/LibraryCachePerformanceTests.swift::testCacheReadsDoNotBlockTheMainActor` | Bound and diagnose the final `readsTask.value` wait, and retain the current observable start/finish probe. | The two 30-second loops are bounded, but after either expires the test still awaits the detached task without a bound. A stuck cache read can hang the process. Recheck the heartbeat observation window after adding a completion contract. |
| `Tests/BleatCoreTests/DownloadStorageTests.swift::Fixture.removeRoot` (all `DownloadStorageTests` callers) | Route temporary-root cleanup through the checked cleanup helper or surface cleanup failure as a test issue instead of suppressing `removeItem` errors with `try?`. | A failed cleanup silently leaks the test's unique temporary directory. Per-test UUID roots prevent state collision, but resource cleanup failure is currently invisible and can consume host disk over repeated runs. |
| `Tests/BleatCoreTests/PrivateCloudSyncTests.swift::CloudKitCancellationProbe.waitForEntry` (callers `testCallbackCancellationCompletesBeforeLifecycleAllowsRetry`, `testCallbackWatchdogCancellationEscapesDelegateTaskLocals`) | Add a bounded actor-entry notification with test-site timeout diagnostics; keep the cancellation release/drain ordering. | If cancellation never enters the probe, its checked continuation suspends indefinitely before either test can assert its lifecycle/watchdog outcome. |
| `Tests/BleatCoreTests/RemoteTelemetryTests.swift::GatedShutdownLogExporter.waitUntilShutdownStarts` / `TestAsyncSignal.wait` (caller `testConcurrentLogShutdownCallersAwaitSharedCompletion`) | Add a bounded start signal that reports a test issue if downstream shutdown is never entered, and an arrival signal proving the second caller joined before releasing the shared shutdown. | The first wait currently suspends on an unbounded continuation; the second caller is only given 50 ms of sleep, so under load it may not have joined before the assertion/release. |
| `Tests/BleatCoreTests/RemoteTelemetryTests.swift::CancellableBlockingSpanExporter.waitUntilStarted` and `waitUntilFinished` (caller `testWithdrawalCancelsAnActiveDownstreamExport`) | Replace synchronous semaphore waits inside the async test with bounded async notifications and source-located timeout failures. | The two calls can block the test executor for up to two seconds each; a missing stage is reported only as a semaphore result and can starve constrained test scheduling. |
| `Tests/BleatCoreTests/RemoteTelemetryTests.swift::testSynchronousSpanWitnessReturnsBeforePersistenceAndAsyncFlushWaits` | Add an explicit signal that the flush task reached its queued persistence wait before asserting it remains incomplete; preserve the semaphore-controlled queue and post-release persisted-file assertion. | The 50 ms sleep does not prove the flush task was scheduled before the incomplete assertion, so a scheduling delay can make that negative check pass without exercising the wait. |
| `Tests/BleatCoreTests/RemoteTelemetryTests.swift` (temporary directory cleanup in test defers and `makeRecordedSpan`) | Route temporary telemetry directory deletion through checked cleanup support instead of suppressing errors with `try?`. | UUID paths isolate tests, but cleanup failures silently accumulate telemetry files and consume host disk. |
| `Tests/BleatCoreTests/PrivateCloudPersistenceTests.swift::MigrationCancellationProbe.waitForEntry` (caller `cancelledMigrationRetainsCommittedProgressAndCoalescesCallers`) | Add a bounded checkpoint-entry notification preserving the exact 200-row commit boundary and coalesced-cancellation checks. | If migration never reaches the checkpoint, the checked continuation suspends indefinitely and the cancellation/recovery assertions never run. |
| `Tests/BleatCoreTests/PrivateCloudPersistenceTests.swift::fixture` | Retain and remove the unique UserDefaults suite names created by each fixture during test cleanup. | The suites isolate test state, but are never explicitly removed; repeated runs can leave inaccessible test domains behind. |
| `Tests/BleatCoreTests/PrivateCloudPersistenceTests.swift::failedMigrationSaveRetainsLegacyPreferences`, `Tests/BleatCoreTests/PrivateCloudPersistenceTests.swift::MigrationCancellationProbe.waitForEntry` | The file-backed fixture cleanup also uses best-effort `try?`; use checked cleanup reporting after closing the read-only ModelContainer. | A failed temporary store removal can silently leave a large persistent test database and invalidate the cleanup claim. |
| `Tests/BleatCoreTests/StatisticsExplorationTests.swift::observedPresentationIsCoherentAcrossLiveSamplesAndSliceCommit`, `boundedObservationRetainsInvalidationAndHistoryAcrossLiveSamples`, `observationHistoryAndPresentationAreAccountScoped` | Replace awaited AsyncStream iterator reads with bounded, source-located update/termination waits that assert the expected revision or close event. | If repository publication or termination regresses, `iterator.next()` suspends indefinitely instead of reporting which update was missing. |
| `Tests/BleatCoreTests/StatisticsExplorationTests.swift::dailyBucketsAndCachedRangesUseUTCReportingCalendar` | Avoid changing process-global `NSTimeZone.default` while unrelated test suites may run concurrently; inject a calendar/time-zone or otherwise serialize the global mutation across all tests. | `.serialized` only orders this suite; other suites can observe the temporary Brisbane/Los Angeles process setting and become order-sensitive. |

The PrivateCloudSync deadline cases cover intentional elapsed-time contracts and typed callback/drain outcomes; the follow-up above addresses their scheduler-sensitive timing window without removing the real deadline behavior. `LiveUpdatesTests.testRetiredStreamTerminationCannotStopReplacement` uses a two-second task-group timeout as a bounded failure path for stream delivery and asserts the received typed event.

The opt-in `StatisticsExplorationTests.stored250000SlicesArchiveResetAndCachedRelaunch` is guarded by `BLEAT_STATISTICS_PERFORMANCE`; it intentionally measures real elapsed import and main-actor heartbeat behavior over 250,000 records. Its 10 ms sleep is the sampling interval, not a completion signal. It was not executed in this audit.

## Timing batch status

The table above retains the original source-review findings. The subsequent
[timing and synchronization batch](test-reliability-audit.md#timing-and-synchronization-batch-2026-10-16)
records partial remediation and its execution evidence. Per-test `timing_batch`
annotations in the linked audit JSON identify updated test bodies; unchanged
findings remain open. Do not interpret the original table as a description of
those updated implementations or as evidence that the whole backlog is closed.

## Follow-on source batch 2026-10-16

The current follow-on diff annotates 13 core test records in
`TestSupport/TestAudit/core.json`; their original source-review decisions and
counts are preserved. The affected records cover the CloudKit cancellation
probe’s early-release race, five logout race tests, three staged authenticated
request tests, the OpenID second-session guard, cache-read cancellation/cleanup,
and remote-telemetry withdrawal. The JSON records carry the exact test
identifiers and per-test source notes.

Focused unsigned host runs passed 151 tests across the six owning suites
(`.build/core-timing-focused.xml`) and a 15-test Logout/cache rerun
(`.build/core-timing-final.xml`); both reports recorded zero failures, errors,
or skips. The final `AuthenticatedRequestTests` failure-path cleanup edit was
made after these focused runs. The subsequent signed owning gate verified all 561 identities passing with
zero skips, including that final edit (`.build/timing-followon-signed-host.log`,
XML in `.build/host-results/`).

`LibraryCachePerformanceTests.testCacheReadsDoNotBlockTheMainActor` now resolves
the worker-lifetime P2 with process isolation. The parent observes child
readiness, enforces a deadline, kills and observes termination before returning,
and structurally verifies one matching successful child test. An intentional
non-completing child exercises the kill/reap path before the real workload.
The child owns and joins its read task; an uncooperative synchronous read is
bounded by the parent process watchdog. Focused unsigned and signed executions
passed with zero skips. Other unrelated follow-up rows remain unchanged.

## Bearer-log subprocess (issue 382)

[Issue #382](https://github.com/terminaloutcomes/bleat/issues/382) implements
only the bearer-log row above. The historical assessment and execution records
remain unchanged; this does not complete #372 or #362.

`AuthenticatedOtlpSpanExporterTests.testBearerNeverAppearsInCapturedProcessLogs()`
retains its identity. Its child executes the real exporter with a controlled
token provider and failing recording transport, asserting one asynchronous
transport export, one token request and the expected failure. The separate
exporter/failure-description privacy test remains intact. The parent captures
both stream sentinels, checks both raw-secret and full-bearer exclusions, and
requires a complete xUnit document containing exactly the expected successful
child identity. Missing, duplicate, unexpected, skipped, failed, unknown and
incomplete evidence are rejected with typed causes.

`Tests/BleatCoreTests/BearerLogChild.swift` uses Foundation's asynchronous process
termination callback and native DispatchIO reads. It never changes parent
stdout/stderr. The independent supervisor is owned and joined: caller
cancellation requests termination without cancelling the stream consumer that
must observe process reaping and reader closure. Output is drained while the
child writes, with a 1 MiB retained-output limit and 64 KiB report limit;
overflow and incomplete reads fail rather than silently truncating a privacy
check. Raw output is discarded after checking and is absent from returned
results and test diagnostics. Cleanup failures remain separate from the
original operation failure, with elapsed time and the requested budget retained.

The 20-second execution/capture budget allows instrumented helper startup and
the exporter's two-second timeout. A separate five-second cleanup budget bounds
SIGKILL/reap and reader cancellation; a cleanup deadline is an explicit failure,
never a successful cleanup claim. Report directories and owned writer handles
are removed/closed on every path. The existing cache-process helper was inspected
but remains separate because its readiness/SwiftData workload contract differs.
Both direct SwiftPM binaries and the provisioned signed helper's bundle/library
arguments are supported. No dependency or general host-runner change is needed.

Nine `BearerLogChildTests` identities exercise success with 2 MiB of pipe output,
child failure, a deliberately non-completing child's deadline, caller
cancellation, overflow, launch failure, zero exit with incomplete runner
evidence, secret-bearing stderr, and structural report rejection. Lifecycle
cases assert observed termination/reaping (except when launch creates no child),
reader/writer closure and report removal. Parent descriptor identities are
compared across success, failure, timeout and cancellation. The exceptional
OS cleanup-deadline fallback is not fault-injected.

Implementation is based on `523f4b2e1a58aaf247d45567af10deacf1ee60f6` in the
issue-382 branch. Validation used macOS 26.6.2 (25G83), Xcode 27.1 (27A9275),
Swift 6.4.0 and Swift Testing 2084 on arm64. Execution evidence and tested
implementation commit are recorded below separately from the source review.

Initial development attempts are retained: the original baseline passed 1/1;
the first changed attempt did not compile because of an incorrect AsyncStream
initializer; the next run passed 8/9 with cancellation cleanup failing three
assertions. The owned supervisor corrected that cancellation bug, and the next
run passed 9/9. After adding the incomplete-report fixture, 9/10 passed: the
runner creates its report before executing the test, so early exit produces
malformed XML rather than a missing file. The expectation now matches that
observed typed rejection. The next focused run passed 10/10. No retry-to-green
claim is made for these implementation attempts.

The final sequential repetition matrix used:

```sh
BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter '<selection>' --xunit-output '.build/issue-382/sequential/<selection>-<repetition>.xml'
```

For repetitions 1, 2 and 3, selections were the original privacy function,
each of the nine function names in `BearerLogChildTests` (listed exactly in
`TestSupport/HostTests/inventory.json`, without trailing parentheses), and
both owning suites `AuthenticatedOtlpSpanExporterTests` and `BearerLogChildTests`.
All 36 reports were parsed and compared to their exact expected inventory
identities, rejecting failures, errors and skips: 30 individual executions,
57 exporter-suite executions and 27 helper-suite executions all passed (114/114).
The first matrix used `--skip-build` and also verified 114 passing executions,
but overlapped the signed build's SwiftPM scheduling. It remains retained and
is superseded by the sequential matrix for repetition acceptance; this is not
parallel signed-host evidence.

`mise exec -- env BLEAT_HOST_SIGNING=required ./scripts/test-host.sh` passed the
complete signed host gate: 573 expected identities passed with zero skips,
including the retained description-privacy test and all nine added identities.
The report verifier independently rechecked both product XML files against the
inventory. The signed helper profile/entitlements were verified by the gate;
coverage exported executed lines for both libraries. The final sequential
confirmation reran that exact command at implementation commit
`629d90064b8cea5031a2ca91f9067437a7d16030`: 573/573 passed, zero skips,
with XML identities independently reverified. Its artifacts are
`.build/issue-382/signed-final.log` and
`.build/issue-382/signed-final-verified.xml`. Two fresh independent read-only
review-agent cycles reported no findings (no P0/P1 or lower-priority findings).
This evidence-only follow-up changes no tested source.

Artifacts are `.build/issue-382/sequential/<selection>-<repetition>.xml` and
sibling `.log` files, `.build/issue-382/signed-host.log`,
`.build/issue-382/signed-verified.xml`, `.build/host-results/tests.xml`, and
`.build/coverage/swift-host/lcov.info`. Initial attempts are retained as
`.build/issue-382/bleat-382-focused-1.log` through `bleat-382-focused-5.log`
(with XML where a run executed), and `.build/issue-382/baseline.xml`.
Child XML is structurally checked before its isolated temporary directory is
removed; captured output is not retained. All repetition logs were checked for
absence of the synthetic bearer. `.envrc`'s SHA-256 was unchanged after the gate.

`mise run docs:check` and strict `xcrun swift-format lint` of the three changed
Swift files passed. The first lint attempt rejected three associated-value
cases sharing declarations; splitting those declarations corrected it.
The signed build emitted the existing dependency watchOS deployment deprecation.
Xcode also reported CoreSimulator 1171.7.0 older than its required 1174.9.2 and
disabled Simulator support; the macOS host gate still completed. That host
installation warning remains unresolved and no Simulator validation is claimed.
SwiftData permission error 513 messages occurred inside existing deliberately
read-only store tests, whose expected rollback/failure assertions passed.
No live-server, app/device or release-validation claim follows from this change.

## AccountStore coverage 2026-10-19

Bounded follow-up under [#372](https://github.com/terminaloutcomes/bleat/issues/372),
reviewed against `90d5471ce7ed3577a2d8e9ee90f0ad8ddae66e9a`:

- `AccountStoreTests.testCorruptStoredProfileIsRejectedWithoutLeakingPayload`
  retains the typed `invalidStoredAccount` assertion and checks three synthetic
  credential markers against error description, reflection, localized description
  and NSError reflection. The current decode boundary emits no diagnostic event;
  this tests exposed error representations without process-global log capture.
- `AccountStoreTests.testDuplicateOnboardingRollsBackOnlyNewCredentials` seeds
  existing-account token sentinels, verifies the canonical destination is empty,
  observes the new login tokens through the existing awaited authentication
  callback, then proves duplicate failure preserves existing credentials and the
  account row while removing new credentials with exactly one deletion.

Only these two dispositions in `TestSupport/TestAudit/core.json` change to
`keep`. There is no production credential change or observed production leak.
The existing in-memory SwiftData fixture and actor credential fake isolate state;
no sleeps, tasks, callbacks requiring teardown, or global output redirection were
added. Adjacent decode and rollback paths retain typed errors with awaited
credential deletion and no process-terminating constructs.

Focused unsigned validation used SwiftPM Swift Testing with `--disable-xctest
--no-parallel`, first selecting both identities (2 passed), then selecting each
identity separately in three independent invocations (6 passes total). All exact
identities were checked in `.build/account-store-focused-1.xml` and
`.build/account-store-<identity>-<1...3>.xml`; zero failures, errors or skips.
An earlier `--repetitions 3` attempt was rejected as an unknown option before
execution and supplies no test evidence. No identities were added or renamed.

`mise exec -- ./scripts/test-host.sh` passed the complete signed owning-host
suite: 573 exact identities, zero failures/errors/skips, including all 18
AccountStore identities and both changed tests. The gate verified signing,
profile and Keychain entitlements, inventory completeness, and executed coverage
in both libraries. Reports: `.build/host-results/tests.xml`, per-product XML,
and `.build/coverage/swift-host/lcov.info`.

Retained diagnostics: the upstream OpenTelemetry package manifest warns about a
deprecated watchOS deployment version. SwiftData permission errors belong to
intentional read-only save-failure fixtures (transcript checkpoint, migration,
pending progress, and history); each owning test passed. The cleanup regression
`retainsOperationFailureWhenCleanupAlsoFails` intentionally records one known
issue through `withKnownIssue`; it passed. No unexpected warning or crash was
observed in the changed cases.

`mise run docs:check`, strict Swift formatting lint for the changed file, and
`git diff --check` passed. Validation platform: macOS 26.6.2 arm64, Apple Swift
6.4. The final revision is recorded in the pull request. Simulator, live server
and physical-device validation are outside this test-only change.

## Telemetry response gate 2026-10-19

PR [#387](https://github.com/terminaloutcomes/bleat/pull/387), under
[#372](https://github.com/terminaloutcomes/bleat/issues/372), also addresses the
separately authorized test response race in
`TelemetryAuthenticationTests.testCancellingOneWaiterPreservesRefreshForConcurrentWaiter`.
The fake previously returned automatically after 100 ms even while the test was
asserting waiter admission and cancellation. The response now remains gated until
two waiters are observed, one returns typed `.cancelled`, and exactly one remains.
The survivor then receives `token-1`; one challenge, one token request, zero
transport cancellations and zero final waiters remain asserted.

Both waiter outcomes use existing bounded completion observations. Awaited
`withTestCleanup` cancels both waiter tasks, disables the provider, releases the
gate and drains both tasks on success, failed setup, throw or cancellation.
Cleanup also retires fake response admission and observes the synchronous token
exit state with a bounded condition when a response had entered. Calls queued
after retirement fail immediately; cleanup does not wait for a never-entered
response. Cleanup runs in an owned, directly awaited task so cancellation of
the test task cannot short-circuit its bounded exit observation. The exit state
is assigned in synchronous `defer`, after the last
suspension, so observing it proves the admitted fake token method has exited. A
gate timeout records its elapsed duration and throws a transport failure; it
cannot silently return a successful response. No production code or shared
synchronization helper changed, and no test identity was added or renamed.

The original PR head `94242f5` failed the unsigned host job
[117845478447](https://github.com/terminaloutcomes/bleat/actions/runs/39185008750/job/117845478447)
with “operation unexpectedly succeeded” in this test. The same unchanged test
and helper failed at earlier main revision `f6a6360` in job
[117817541807](https://github.com/terminaloutcomes/bleat/actions/runs/39175616101/job/117817541807),
while exact base `90d5471` passed in job
[117838643938](https://github.com/terminaloutcomes/bleat/actions/runs/39182696069/job/117838643938).
These logs establish intermittence, not the precise event ordering of either
failure. No blind rerun replaced that evidence.

Final-source validation: the exact cancellation identity passed one focused
Swift Testing run plus ten independent invocations, each with one exact identity
and zero failures/errors/skips. Reports: `.build/telemetry-gate-final.xml` and
`.build/telemetry-gate-final-repetition-<1...10>.xml`. Earlier development versions
also passed focused runs; only these final-source reports count for this revision.

`mise exec -- ./scripts/test-host.sh` then verified 573 signed host identities,
zero failures/errors/skips, including all 18 telemetry and 18 AccountStore tests.
Signing, profile, Keychain entitlements, inventory and coverage checks passed.
Reports remain `.build/host-results/tests.xml` and
`.build/coverage/swift-host/lcov.info`. No identities changed, so the host
inventory is unchanged. Strict formatting lint, documentation checks and
`git diff --check` passed on macOS 26.6.2 arm64 / Apple Swift 6.4.

An earlier signed build emitted Xcode stale-file warnings for generated host-runner
artifacts under the linked build directory. The two logical worktree path aliases
resolve to the same cache; signing/profile verification and all tests completed.
Those generated-path warnings are retained, not claimed fixed; the final-source
signed run emitted none. Nine SwiftData
permission diagnostics came from intentional read-only fixtures; the cleanup
regression recorded its declared known issue. No warning or crash was observed
in the changed telemetry case. Final revision and CI outcomes are recorded in
PR #387; no physical-device or live-server evidence is claimed.

## OpenID cookie fixture (issue 372)

This scoped follow-up addresses only the OpenID cookie-fixture trap row above
under [#372](https://github.com/terminaloutcomes/bleat/issues/372). Historical
audit records remain revision-specific; tracker reconciliation is separate.

`HTTPTransportTests.testOpenIDTransportKeepsThenClearsSessionCookies` retains
its redirect status/location, two-cookie, callback-cookie and explicit
session-clear assertions. The shared test-only `OpenIDCookieFixture` throws
typed missing-request-URL, invalid-response and unexpected-route failures;
`URLProtocolStub` forwards them through `didFailWithError`. Adjacent response
fixtures replace forced unwraps with throwing Swift Testing requirements.
No production code changes.

`testOpenIDTransportUnexpectedRouteThrowsAndCleansUp` first awaits the begin
response and requires two stored cookies. It then awaits an unexpected route,
checks the typed domain/code and structured path at the caller, and verifies zero cookies
and removal of the static handler. The fixture uses the existing `withTestCleanup` to await session clearing before
returning or rethrowing; handler removal runs in `defer`. The serialized suite
and lock-protected handler/recorder preserve ownership. There are no added
background tasks, sleeps, polling windows or elapsed-time correctness conditions.
These are deterministic Foundation/URLProtocol host fixtures, with no external
identity provider, Simulator or device evidence.

Final-source validation on 19 October 2026 used macOS 26.6.2, Xcode 27.1
(27A9275), Swift 6.4 and Swift Testing 2084:

- Focused OpenID selection: three exact identities passed, zero failures/errors/skips
  (`.build/issue-372-openid-bridged.xml`).
- Three independent invocations each of
  `testOpenIDTransportKeepsThenClearsSessionCookies`,
  `testOpenIDTransportUnexpectedRouteThrowsAndCleansUp`,
  `testURLSessionTransportReturnsTypedHTTPResponse`,
  `testURLSessionTransportRejectsNonHTTPResponse`, and
  `testURLSessionTransportRecordsTypedRequestOutcome`: 15/15 exact single-identity
  reports passed, zero failures/errors/skips
  (`.build/issue-372-<test-name>-<1...3>.xml`).
- Owning HTTPTransport suite: all 19 inventory identities passed, zero
  failures/errors/skips (`.build/issue-372-http-suite-final.xml`).
- `mise exec -- ./scripts/test-host.sh`: all 574 exact inventory identities passed,
  zero failures/errors/skips, including all 19 HTTPTransport identities. The
  signing/profile/Keychain entitlement and coverage checks passed. Reports:
  `.build/host-results/tests.xml`, `.build/issue-372-signed-host-final.log`, and
  `.build/coverage/swift-host/lcov.info`.
- Strict Swift formatting lint on the changed file, `mise run docs:check` and
  `git diff --check` passed.

Every report was parsed for exact identities and individual outcomes, including
all 15 single-test repetition reports. These are host/signed-host results;
Simulator, disposable-server, external identity-provider and physical-device
journeys were not run for this test-only change.

Earlier attempts remain distinct from this evidence. Automatic approval review
initially blocked commands before execution (capacity errors and deadlines).
The first executed owning-suite build and initial PR head `fc8d540` failed
because nested Swift Testing `#require` macros do not compile; its iOS lint job
also rejected formatting. Separate URL/response requirements and Swift formatting
resolve those failures. The next local focused selection executed three tests:
two passed and the new regression failed because Foundation bridges the thrown
Swift enum to `NSError`; a diagnostic single-test run confirmed the domain/code
survived while the enum cast and route payload did not. Those failed reports
remain `.build/issue-372-openid-final.xml` and
`.build/issue-372-error-diagnostic.xml`. `CustomNSError` now explicitly preserves
the typed failure domain, distinct case code and structured path/status metadata.
The regression checks domain, case code and path without comparing descriptions.
The subsequent clean repetitions are final-source evidence, not retries of an
unchanged failing fixture.

The signed gate emitted the pinned `opentelemetry-swift-core` watchOS-minimum
deprecation warning. SwiftData code 513 messages came from the intentional
read-only-store failure tests (`testReadOnlyCommitFailureRollsBackTranscriptAndCheckpoint`,
`failedMigrationSaveRetainsLegacyPreferences`,
`testFailedPendingStateSavesPreserveRetryState`, and
`failedHistorySaveDoesNotReplaceObservedProgress`); each passed. The one known
issue is deliberately recorded by
`TestCleanupTests.retainsOperationFailureWhenCleanupAlsoFails`. No new runtime
warning or unexpected skip was found in the affected tests.

Final revision and final-head CI results are recorded in draft
[PR #388](https://github.com/terminaloutcomes/bleat/pull/388). This disposition
resolves only the cookie-fixture source finding and retains unrelated #372 work.
