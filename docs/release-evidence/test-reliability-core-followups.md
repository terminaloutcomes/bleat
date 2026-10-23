# Core test reliability follow-ups

These are source-review findings for [issue #362](https://github.com/terminaloutcomes/bleat/issues/362). Owner for each item: Bleat maintainers handling #362. None is claimed fixed or validated here unless noted.

| Test | Follow-up | Rationale and remaining risk |
| --- | --- | --- |
| `Tests/BleatCoreTests/TelemetryAuthenticationTests.swift::testCachedTokenAvailabilityReportsActiveAcquisition` | Replace the unbounded `Task.yield()` loop waiting for `tokenCount > 0` with a bounded, asserted notification from the fake transport. | If acquisition never reaches the transport, the test hangs instead of reporting the failed stage and elapsed timeout. |
| `Tests/BleatCoreTests/TelemetryAuthenticationTests.swift::testCancellingOnlyWaiterCancelsUnderlyingRefresh` | Replace both unbounded `Task.yield()` loops (token request and cancellation observation) with registered, bounded completion signals and useful timeout failures. | A regression before token request or cancellation can hang the host suite indefinitely. |
| `Tests/BleatCoreTests/TelemetryAuthenticationTests.swift::testDisablingCancelsRefreshAndClearsMemoryToken` | Replace the unbounded `Task.yield()` wait for a token challenge with a bounded transport-start signal. | If refresh never starts, the test hangs before it can assert disable behavior. |
| `Tests/BleatCoreTests/OpenIDAuthenticationTests.swift::OpenIDWebSessionFactory.waitUntilSessionStarts` (callers include browser lifecycle tests) | Use a registered start notification and bounded wait, then assert session start with the caller's source location. | The helper loops forever if the session never starts and relies on scheduler yields instead of an event contract. Audit every caller when changing the helper. |
| `Tests/BleatCoreTests/LogoutTests.swift::testLogoutSettlesRefreshAndInvalidatesTheRotatedToken` | Replace the 1,000-yield loop polling `isSigningOut` with a state-change signal or bounded predicate wait. | The bound is a scheduler-iteration count, not a time budget; failure diagnostics do not report elapsed time or a meaningful timeout. |
| `Tests/BleatCoreTests/TranscriptExportTests.swift::testCanonicalTranscriptExportIsRepeatable` | Implemented: name and local variables describe repeatable WebVTT bytes. | See [scoped identity evidence](#transcript-export-repeatability-issue-372); this does not establish distinct local/imported source-path coverage. |
| `Tests/BleatCoreTests/LogoutTests.swift::testConcurrentLogoutAndAuthenticatedRequestAreRejected`, `testLogoutRejectsAnOverlappingLocalLogin`, `testLogoutSettlesRefreshAndInvalidatesTheRotatedToken`, `testRequestCannotStartRefreshAfterLogoutBegins`, `testSuccessfulResponseStartedBeforeCompletedLogoutIsInvalidated` | Replace unbounded fake-entry continuation waits with bounded condition signals; replace the 1,000-yield `isSigningOut` loop with a typed state-change notification. | Missing login/logout/refresh transition can currently suspend a test forever. The yield loop uses scheduler iteration count rather than a deadline or observed state event and may be flaky under load. Preserve the ordering and late-result race assertions. |
| `Tests/BleatCoreTests/AuthenticatedOtlpSpanExporterTests.swift::testCancellingAsyncExportCancelsTokenWaitBeforeRPC`, `testCancelActiveExportsCancelsAsyncTokenWaitBeforeRPC`, `testCancellationUnblocksTokenWaitAndShutsTransportOnce`, `testCancellationAfterTokenCompletionPreventsRPCAndAllowsLaterExport` | Replace `DispatchSemaphore.wait` readiness helpers with bounded async signals and source-located timeout failures. | These async tests synchronously block their executor while waiting up to two seconds for token/RPC entry; a semaphore is not an async completion contract and can starve work under constrained test scheduling. |
| `Tests/BleatCoreTests/AuthenticatedOtlpSpanExporterTests.swift::testConcurrentExportsUseProviderSafelyAndReuseOneClient` | Replace the token fake’s 50ms sleep window with a barrier proving concurrent callers have joined before token release. | A sleep approximates overlap but does not guarantee all eight export tasks join the same refresh under slow scheduling. |
| `Tests/BleatCoreTests/AuthenticatedOtlpSpanExporterTests.swift::testAsyncTransportShutdownWaitsForClosureCompletion` | Bound the fake shutdown gate’s entry notification and report if the close closure is never entered. | `waitUntilEntered()` uses an unbounded continuation; the explicit release only happens after that wait returns. |
| `Tests/BleatCoreTests/AuthenticatedOtlpSpanExporterTests.swift::testBearerNeverAppearsInCapturedProcessLogs` | Capture output in a subprocess or enforce process-wide exclusive serialization, and restore both file descriptors through guaranteed cleanup. | `captureStandardOutput` redirects process-global stdout/stderr while other Swift Testing suites can execute concurrently; a restoration failure can also leave a descriptor redirected. |
| `Tests/BleatCoreTests/AuthenticatedRequestTests.swift::testTwentyUnauthorizedRequestsShareOneRotatingRefresh`, `testTwentyUnauthorizedRequestsShareOneRejectedRefresh`, `testConcurrentRejectionJoinsInFlightRefreshInsteadOfStaleStoreRead`, `testJoinerRecordsOriginatorRejectedTokenInCompletedRefresh`, `testConcurrentRejectionJoinsFailingInFlightRefresh`, `testTwentyUnauthorizedRequestsShareOneSavedPasswordRecovery` | Add bounded, diagnostic arrival notifications to the concurrent HTTP fake barriers and staged refresh gates. | Count barriers currently suspend with checked continuations until all request calls arrive, and gated tests wait for refresh/save/initial-send states indefinitely. If a regression prevents a stage from occurring, the test process hangs rather than reporting which transition timed out. Preserve each cancellation/coalescing race scenario. The three staged-refresh cases have [bounded final-outcome evidence](#bounded-in-flight-refresh-caller-outcomes-issue-372); the other concurrent-barrier cases remain outside that slice. |
| `Tests/BleatCoreTests/AuthenticatedRequestTests.swift::testConclusiveRefreshStatusFailureIsMemoized` | Implemented: renamed to describe conclusive refresh-status failure memoization. | The existing old access/refresh credentials, 401/503/401 responses, two typed failure assertions, exact three request paths and reauthentication assertion are unchanged. Separate `testCredentialFailuresAreTyped` retains missing-credentials coverage. See [rename evidence](#refresh-status-test-identity-issue-372). |
| `Tests/BleatCoreTests/HTTPTransportTests.swift::testEndpointRouterStreamsEveryServerConnectionPurpose` | Bound each `AsyncStream` event read and report the missing snapshot stage on timeout. | Three awaited `iterator.next()` calls have no deadline, so a missing initial/update yield can hang the suite. |
| `Tests/BleatCoreTests/HTTPTransportTests.swift::testOpenIDTransportKeepsThenClearsSessionCookies` | Replace the test URLProtocol helper’s `preconditionFailure` for unexpected route with a captured typed test failure. | An unexpected adapter request currently traps the process instead of reporting the failing route as a test issue. |
| `Tests/BleatCoreTests/OpenIDAuthenticationTests.swift::testNativeBrowserCallbackAdapterRunsOffMainActor` | Bound the continuation awaiting the detached framework callback and report missing callback completion. | The test invokes the actual callback adapter off MainActor, but a regression that drops the callback leaves the test suspended indefinitely. Preserve all success/cancel/failure adapter cases. |
| `Tests/BleatCoreTests/OpenIDAuthenticationTests.swift::testConcurrentAttemptIsRejectedWithoutDisturbingActiveFlow` | Bound OpenIDBrowserGate entry notification and retain source-located timeout diagnostics. | The gate’s checked continuation has no deadline, so failure to enter browser authentication can hang before concurrency assertions. |
| `Tests/BleatCoreTests/LibrarySearchCoordinatorTests.swift` (all callers of `SearchTestSleeper.waitForSleepCount` and `SearchTestService.waitForFirstCall`) | Add bounded, source-location-preserving start signals to fake sleeper/service gates and assert each signal before release/cancellation. | The actor continuation helpers correctly coordinate the intended concurrency order, but wait forever if the coordinator stops scheduling debounce or never invokes the repository. This can hang all eight tests rather than fail at the missing transition. Keep the deterministic sleeper and cancellation race scenarios. |
| `Tests/BleatCoreTests/PrivateCloudSyncTests.swift::testFetchedCallbackDeadlinePausesInBackgroundAndBlocksRetryUntilDrain` and `testFetchedCallbackProgressResetsNoProgressDeadline` | Replace wall-clock sleeps/manual deadline probes with a controlled clock where feasible, or add a typed notification to observe deadline reset/expiry. Preserve the actual background pause and elapsed no-progress contract. | Both tests use intended elapsed-time coverage, but the progress case sleeps 600 ms, checks for non-expiry, sleeps another 600 ms, then expects expiry for a one-second deadline; scheduler delay before the progress check can turn the first expectation flaky. The background case also relies on 50 ms sleeps for deadline propagation. Keep the cancellation/drain postconditions; make the timing boundary controllable and diagnostic. |
| `Tests/BleatCoreTests/LibraryCachePerformanceTests.swift::testCacheReadsDoNotBlockTheMainActor` | Bound and diagnose the final `readsTask.value` wait, and retain the current observable start/finish probe. | The two 30-second loops are bounded, but after either expires the test still awaits the detached task without a bound. A stuck cache read can hang the process. Recheck the heartbeat observation window after adding a completion contract. |
| `Tests/BleatCoreTests/DownloadStorageTests.swift::Fixture.removeRoot` (all 31 root-owning callers) | Implemented: awaited fixture scope reports deletion failures at the calling test and preserves the original operation failure. | See [scoped cleanup evidence](#downloadstorage-fixture-cleanup-issue-372); historical audit findings remain retained. |
| `Tests/BleatCoreTests/PrivateCloudSyncTests.swift::CloudKitCancellationProbe.waitForEntry` (callers `testCallbackCancellationCompletesBeforeLifecycleAllowsRetry`, `testCallbackWatchdogCancellationEscapesDelegateTaskLocals`) | Add a bounded actor-entry notification with test-site timeout diagnostics; keep the cancellation release/drain ordering. | If cancellation never enters the probe, its checked continuation suspends indefinitely before either test can assert its lifecycle/watchdog outcome. |
| `Tests/BleatCoreTests/RemoteTelemetryTests.swift::testConcurrentLogShutdownCallersAwaitSharedCompletion` | Implemented: bounded per-caller return observations precede task-result awaits after the controlled downstream release. | Entry/join checks were already bounded at this slice's base; [scoped completion evidence](#bounded-shared-log-shutdown-completion-issue-372) records the remaining final-wait fix without re-claiming that earlier work. |
| `Tests/BleatCoreTests/RemoteTelemetryTests.swift::CancellableBlockingSpanExporter.waitUntilStarted` and `waitUntilFinished` (caller `testWithdrawalCancelsAnActiveDownstreamExport`) | Replace synchronous semaphore waits inside the async test with bounded async notifications and source-located timeout failures. | The two calls can block the test executor for up to two seconds each; a missing stage is reported only as a semaphore result and can starve constrained test scheduling. |
| `Tests/BleatCoreTests/RemoteTelemetryTests.swift::testSynchronousSpanWitnessReturnsBeforePersistenceAndAsyncFlushWaits` | Add an explicit signal that the flush task reached its queued persistence wait before asserting it remains incomplete; preserve the semaphore-controlled queue and post-release persisted-file assertion. | The 50 ms sleep does not prove the flush task was scheduled before the incomplete assertion, so a scheduling delay can make that negative check pass without exercising the wait. |
| `Tests/BleatCoreTests/RemoteTelemetryTests.swift` (temporary directory cleanup in test defers and `makeRecordedSpan`) | Route temporary telemetry directory deletion through checked cleanup support instead of suppressing errors with `try?`. | UUID paths isolate tests, but cleanup failures silently accumulate telemetry files and consume host disk. |
| `Tests/BleatCoreTests/PrivateCloudPersistenceTests.swift::MigrationCancellationProbe.waitForEntry` (caller `cancelledMigrationRetainsCommittedProgressAndCoalescesCallers`) | Add a bounded checkpoint-entry notification preserving the exact 200-row commit boundary and coalesced-cancellation checks. | If migration never reaches the checkpoint, the checked continuation suspends indefinitely and the cancellation/recovery assertions never run. |
| `Tests/BleatCoreTests/PrivateCloudPersistenceTests.swift::fixture` | Implemented: caller-scoped ownership retains and removes exact data/configuration domains, including restored/restarted/read-only stores and throwing exits. | See [scoped defaults evidence](#private-cloud-defaults-lifecycle-issue-372). File-backed root deletion and historical synchronization findings remain separate. |
| `Tests/BleatCoreTests/PrivateCloudPersistenceTests.swift::failedMigrationSaveRetainsLegacyPreferences` | Implemented: isolate the real migration in the current host executable and require observed process exit plus closed owned IO before checked root/domain removal. | [Process-boundary evidence](#read-only-migration-process-boundary-issue-372) retains the historical lifetime investigation and typed migration assertions; checkpoint synchronization remains separate. |
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


## DownloadStorage fixture cleanup (issue 372)

This slice addresses only the `Fixture.removeRoot` finding under
[issue #372](https://github.com/terminaloutcomes/bleat/issues/372).
All 31 root-owning tests now await `withFixture`, which uses `withTestCleanup`
to complete deletion on successful and throwing exits. `removeRoot` throws;
the cleanup boundary records failures at the caller's `SourceLocation` and
retains the original operation error. Its dedicated error value exposes only
the Foundation domain and numeric code, omitting filesystem paths. Each test
still owns an independent UUID root. All original download actions and assertions
remain; three catches explicitly match `DownloadStorageError` because the
closure scope otherwise erases Swift's inferred thrown type.

Three new inventory identities cover deletion after success, deletion after an
operation error, and deterministic deletion failure on both operation outcomes.
The last identity first removes its owned root, then requires a cleanup issue
matching both its exact calling location and structured missing-file code.
Unexpected issues do not match the known-issue handler. It separately verifies
the original typed operation error and absence of the root. No permissions,
sleeps, background work, arbitrary scheduler windows or production changes are
involved. The historical audit's 31 caller records gain separate follow-up
annotations; their original review decisions and counts are preserved.

Final-source validation on 19 October 2026 used macOS 26.6.2, Xcode 27.1
(27A9275), Swift 6.4 and Swift Testing 2084:

- Focused cleanup regressions: 3/3 exact identities passed, including both
  deletion-failure arguments (`.build/download-cleanup-redacted.xml`).
- Three independent invocations each of the three cleanup identities,
  `testCancellationPersistsIntentAndDiscardsPartialBytes` and
  `testLegacyManifestDefaultsToManualPurpose`: 15/15 exact single-identity
  reports passed (18 argument executions), zero failures/errors/skips.
  Commands used `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
  --skip-build --disable-xctest --no-parallel --filter DownloadStorageTests.<name>
  --xunit-output .build/download-<name>-<1...3>.xml`; sibling logs are retained.
- Owning DownloadStorage suite: all 35 inventory identities passed, zero
  failures/errors/skips (`.build/download-storage-suite-final.xml`).
- `mise exec -- ./scripts/test-host.sh`: all 577 exact inventory identities
  passed, zero failures/errors/skips, including all 35 DownloadStorage identities.
  Signature, provisioned profile, Keychain entitlements and coverage checks
  passed. Artifacts: `.build/download-storage-signed-host.log`,
  `.build/host-results/tests.xml`, per-product XML in `.build/host-results/`,
  and `.build/coverage/swift-host/lcov.info`.
- Strict formatting lint on the changed Swift file, `mise run docs:check`
  (`.build/download-storage-docs-check.log`) and `git diff --check` passed.

Every focused, repeated, owning-suite and signed-host report was parsed for exact
identities, uniqueness and individual outcomes. The two new known issues are
required missing-file injections, matched by exact source location/domain/code;
the existing `TestCleanupTests` dual-failure regression contributes the third
known issue. The signed gate also emitted the pinned OpenTelemetry watchOS
minimum-version deprecation and intentional SwiftData code 513 diagnostics from
read-only-store failure tests; their individual outcomes passed. No unexpected
warning or skip was observed in DownloadStorage tests. This is host filesystem
and signed-host evidence; no local Simulator, live Audiobookshelf server or
physical-device journey is claimed.

The initial focused build failed before executing tests because three catches
lost their inferred `DownloadStorageError` type inside the closure
(`.build/download-cleanup-focused.log`). Explicit typed catches resolve that
compile failure. The subsequent focused run passed 3/3 identities and the
owning suite passed 35/35, but the intentionally failed deletion diagnostic
included the synthetic root path. The final-source error presentation retains
only domain/code; the earlier successful runs are superseded evidence
(`.build/download-cleanup-focused-final.xml`,
`.build/download-storage-suite.xml`). No setup script exit status was exposed;
configured environment loading and the marked temporary build link were
verified before editing.

## Refresh-status test identity (issue #372)

On 2026-10-19, `AuthenticatedRequestTests.testMissingSavedCredentialsMemoizesConclusiveFailure`
was renamed to `testConclusiveRefreshStatusFailureIsMemoized`. The fixture still
uses synthetic old access/refresh tokens and responses 401, 503, 401. Both sends
assert `.unexpectedRefreshStatus(503)`, the exact request paths remain
`/api/libraries`, `/auth/refresh`, `/api/libraries`, and reauthentication remains
required. `testCredentialFailuresAreTyped` separately covers `.missingCredentials`.
Only the function identity changed in Swift; no production/helper or test-body
change and no added coverage is claimed. Inventory and source-index declaration
counts are unchanged; the renamed source location and active references match.
This resolves only the misleading-name finding. Staged-gate/concurrency findings
and issues #372/#362 remain open.

Validation uses base `539e2926a5766b37f2fb1b887c373d0b01558332` plus this scoped
rename, Xcode 27.1 (27A9275), macOS 26.6.2, Swift Testing 2084, serial order and
fresh fixture state per invocation. Three independent unsigned invocations each
passed the exact renamed identity (3/3 total); the owning suite passed all 24
inventory identities. XML identity multisets and every individual outcome were
checked with zero failures, errors or skips. Empty unselected SwiftPM suites
are excluded from these counts. Artifacts: `.build/i372-refresh-identity/focused-1.xml`,
`focused-2.xml`, `focused-3.xml` and `owning.xml` in that directory.

Commands: `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--disable-xctest --no-parallel --filter
'AuthenticatedRequestTests.testConclusiveRefreshStatusFailureIsMemoized'
--xunit-output .build/i372-refresh-identity/focused-1.xml`; subsequent independent
runs use `--skip-build` and separate output names. The owning invocation uses
`--skip-build --filter AuthenticatedRequestTests` with its own XML path.

Strict `mise run swift-lint` passed. The initial package build emitted the upstream
OpenTelemetry deprecated watchOS minimum warning. The first `mise run docs:check`
failed on this evidence section's not-yet-written anchor; that attempt is retained
here. No test failure or zero-test attempt occurred. Host-only evidence adds no
Simulator, live-server, physical-device, release or broader lifecycle claim.

The complete signed owning-host gate, `mise exec -- ./scripts/test-host.sh`,
passed **577/577 inventory identities**, zero failures/errors/skips, including
the renamed identity. The count is unchanged from the base inventory; this is
572 core plus five transcription identities. The repository verifier and a
separate XML multiset/outcome check both accepted `.build/host-results/tests.xml`.
Per-product XML remains in `.build/host-results/`; the full local log is
`.build/i372-refresh-identity/signed-host.log`, and coverage is under
`.build/coverage/swift-host/`. The gate verified the signed host's identity,
Keychain entitlement and profile presence before execution.

The signed log retains the upstream watchOS deprecation, nine deliberate
read-only SwiftData save diagnostics (ChapterTranscriptionJob, PrivateCloudPersistence,
PrivateCloudSync and StatisticsExploration failure fixtures), and three intentional
known issues from DownloadStorage/TestCleanup cleanup-error regressions. Their
owning tests passed; these diagnostics are expected failure-boundary coverage,
not failures of the renamed test. Documentation checking passed after adding
this section; `git diff --check` and scoped source/index/inventory checks passed.
The adjacent refresh error mapping and fixture were inspected for typed error
handling and process-terminating constructs; no production change was needed.

## Transcript export repeatability (issue #372)

On 2026-10-19, `TranscriptExportTests.testCanonicalTranscriptExportHasSourceIndependentSemantics`
was renamed to `testCanonicalTranscriptExportIsRepeatable`; its local values are
now `firstExport` and `repeatedExport`. The canonical array, segment values,
WebVTT format, two exporter calls and equality assertion are unchanged.
Byte equality is intentional here: the contract under test is repeatable encoded
WebVTT bytes for identical canonical input. The adjacent fixed-output WebVTT
encoding tests remain separate. This test does not exercise distinct local and
imported source paths, and no new coverage is claimed.

The matching audit disposition is now keep, and the active follow-up row,
host inventory and source-index identity agree. Historical audit revisions and
counts remain unchanged. Issues #372 and #362 remain open, including unrelated
lifecycle, staged-gate and cleanup findings.

Validation is against base `6e62417281980f0185c1eb812def220e5c82bd66` plus this
scoped change, using Xcode 27.1 (27A9275), macOS 26.6.2 and serial Swift Testing.
Artifacts are retained under `.build/i372-transcript-repeatability/`;
three independent focused invocations passed 3/3 and the owning suite passed
7/7. XML identity multisets and each outcome were independently checked, with
zero failures/errors/skips. No Simulator,
live-server, physical-device or release evidence is claimed.

The synchronous exporter and adjacent test fixtures were inspected: invalid
input uses typed `TranscriptExportError.noSegments` / `.invalidSegment` cases;
no process-terminating constructs or framework callback boundary was found.
Production and helper code are unchanged. Supported app setup supplied the
linked `.envrc` and marked temporary build directory; environment loading was
verified before editing. No setup script exit status was exposed.

Commands: `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--disable-xctest --no-parallel --filter
TranscriptExportTests.testCanonicalTranscriptExportIsRepeatable
--xunit-output .build/i372-transcript-repeatability/focused-1.xml`;
subsequent independent invocations use `--skip-build` and `focused-2.xml` /
`focused-3.xml`. The owning invocation uses `--skip-build --filter
TranscriptExportTests` and `owning.xml`. Each log has the corresponding basename.
The literal local fixture has no order, timing, load or external-state dependency;
serial fresh invocations are the applicable variation for this name-only change.
The host inventory remains 577 identities; the portable source index remains
1,561 declarations. Normalizing only the new name reproduces each base inventory
structurally. Normalizing the function and two local variable names reproduces
the entire base Swift file exactly.

Strict changed-file Swift lint and repository `mise run swift-lint` passed.
The initial build emitted the upstream OpenTelemetry deprecated watchOS minimum
warning; no focused or owning test failure, skip or runtime warning occurred.

The complete signed owning-host command, `mise exec -- ./scripts/test-host.sh`,
passed **577/577 exact inventory identities** (572 core and five transcription),
zero failures/errors/skips, including the renamed test. The repository verifier
and an independent XML identity-multiset/outcome check both accepted
`.build/host-results/tests.xml`; per-product reports remain alongside it.
The log is `.build/i372-transcript-repeatability/signed-host.log`; production
coverage is retained under `.build/coverage/swift-host/`. The gate verified
signed identity, Keychain entitlement and provisioning-profile presence.

The signed log retains the upstream watchOS deprecation, nine intentional
read-only SwiftData save diagnostics, and three known issues from the
DownloadStorage/TestCleanup deletion-failure regressions. Their owning tests
passed. There were no unsuccessful test invocations or zero-test selections.
The initial branch-creation attempt was blocked by shared Git filesystem access;
the same operation succeeded with host access before editing. Documentation
checking passed, as did `git diff --check` and scoped source/index/inventory
consistency checks. No setup, environment, security or production changes were
needed.


## Private Cloud defaults lifecycle (issue 372)

This slice under #372/#362 changes only defaults ownership in
`Tests/BleatCoreTests/PrivateCloudPersistenceTests.swift`. Every allocating
caller registers a `defer` before fixture construction; the local owner retains
exact UUID suite names and calls nonthrowing
`removePersistentDomain(forName:)` for each. Data and configuration remain
separate, including restored/restarted stores and the read-only fixture.
A throwing fixture construction leaves any already-created domains under its
caller's cleanup. No process-global defaults, deinitialization-based lifetime,
production seam, clock or synchronization behavior is introduced.

The parameterized `ownedDefaultsAreRemovedOnSuccessAndThrowingExit(failure:)`
regression seeds persistent data/configuration domains and an unrelated-domain
sentinel. Success, a typed throw after only data allocation, and a typed throw
after configuration allocation all verify owned-domain absence and unrelated
preservation; thrown error identity is checked structurally. The unrelated
suite has independent deferred cleanup. This finite synchronous operation has
no wait or timing budget. Domain removal is an API-level postcondition, not a
claim that UserDefaults reports filesystem deletion failures.

Every fixture caller and direct restored/restarted/read-only construction was
reviewed. All migration/retry/error assertions, the 200/201-row checkpoint,
coalesced cancellation and 58,404-row sentinel workload remain intact. The
best-effort file-backed root deletion finding remains **open**: closing store
lifetimes before checked directory removal requires separate evidence. The
historical checkpoint/synchronization findings and counts are preserved.
Production paths and callback adapters are unchanged; adjacent storage failures
retain their existing typed errors. No broader persistence, signed-device,
live-server, release or epic-completion claim is made.

Supported app setup supplied the linked `.envrc` and marked temporary `.build`;
the worktree began at current remote main `c7bb381` before scoped branch
creation. The app exposes no numeric setup exit. Initial branch creation was
blocked by shared Git metadata access and succeeded unchanged with host access
before edits. No environment, trust or security settings were modified.

The first focused build failed strict concurrency checking before test execution:
retaining configuration `UserDefaults` instances in the owner prevented their
transfer to `CloudConfigurationStore`. The corrected owner retains only names;
cleanup uses a fresh defaults instance to remove each explicitly named domain,
without reading or writing standard-domain keys. The unsuccessful build log is
`.build/i372-defaults-focused-1.log`; subsequent attempts use distinct files.

Local configuration: Xcode 27.1 (27A9275), macOS 26.6.2; mise environment
readiness was checked without printing configuration values. Final-source
unsigned Swift Testing evidence:

- Focused cleanup: **1/1 identity**, all three parameter cases passed, in
  `.build/i372-defaults-focused-2.xml` (matching `.log`).
- Five separate serial invocations of the cleanup identity plus migration
  copy/restore, cancellation/restart, read-only failure and partial-resume
  identities: **25/25 executions**, five exact identities per invocation,
  zero failures/errors/skips. Reports/logs are
  `.build/i372-defaults-repeat-1.xml` through
  `.build/i372-defaults-repeat-5.xml` and their matching `.log` files. The
  cleanup identity exercises all three argument cases per invocation.
- Complete owning suite: **13/13 identities**, zero failures/errors/skips, in
  `.build/i372-defaults-owning.xml` and matching `.log`; includes the full
  58,404-row test. XML outcomes and exact identity sets were inspected.
- Built discovery in `.build/i372-defaults-discovery.txt` exactly equals all
  **578** host inventory identities. The source index contains **1,562**
  declarations; only this file's entries and the new test were updated.
  Historical audit counts remain tied to their original revision.

Focused command: `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--disable-xctest --no-parallel --filter
PrivateCloudPersistenceTests.ownedDefaultsAreRemovedOnSuccessAndThrowingExit
--xunit-output .build/i372-defaults-focused-2.xml`. Repetitions use
`--skip-build`, a regex selecting the five identities listed above, and distinct
report paths. The owning command uses `--skip-build --filter
PrivateCloudPersistenceTests`. Each invocation starts fresh UUID domains;
serial independent runs are the relevant state-isolation variation. There is
no shared state, ordering or timing assumption in the new regression.

An attempted `--repetitions 5` invocation was rejected as an unknown option
before execution; `.build/i372-defaults-repeated.log` is retained, and it is
not counted as coverage. The five supported independent invocations above
replaced it. The original compile failure is also retained above. Each
read-only test run emitted its expected SwiftData Cocoa 513 save diagnostic;
its exact typed-error and retained-source assertions passed. The upstream
OpenTelemetry watchOS minimum deprecation appeared during dependency planning
(including repeat 2); no test failure or unexpected skip occurred. Strict
repository Swift lint and documentation checking passed (logs
`.build/i372-defaults-swift-lint-final.log` and `.build/i372-defaults-docs.log`).

The complete signed owning-host gate, `mise exec -- ./scripts/test-host.sh`,
passed **578/578 exact inventory identities** (573 core, five transcription),
zero failures/errors/skips. Both the supported verifier and an independent XML
identity multiset/outcome comparison accepted `.build/host-results/tests.xml`;
per-product reports are retained alongside it. The full log is
`.build/i372-defaults-signed-host.log`; merged production LCOV is under
`.build/coverage/swift-host/`. The gate verified the signed host identity,
Keychain entitlement and provisioning-profile presence. Parameterized XML is
counted once per function identity, not once per argument or duplicate report.
The signed log retains nine intentional read-only SwiftData Cocoa 513 save
diagnostics, the upstream watchOS deprecation, and three intentional known
issues from DownloadStorage/TestCleanup failure-injection regressions; all
owning tests passed. No new runtime warning or unhandled failure was observed.

Final diff and scoped structural checks confirmed exactly one added host
identity/audit declaration, unchanged unrelated inventory/index entries, and
preserved checkpoint/sentinel constants. The `.envrc` link and marked temporary
build link remain intact. Strict repository lint, docs and `git diff --check`
passed; no production, generated project or environment files changed.

## Read-only migration fixture lifetime blocker (issue 372)

Investigation base: `47f9af5b72676cae18b7d90bc17319f1a6153bbe` (merged
PR #396). This is an evidence-only checkpoint under #372/#362; the cleanup
finding remains **open**. No test/helper, host inventory, source index or
production code changes are delivered. Prior revision-bound counts above are
unchanged.

Supported app worktree setup supplied `.envrc` and a `.build` symlink to a
marked temporary build directory. Mise confirmed required application/signing
configuration presence without printing its values. The worktree began detached
at independently verified remote main, then a scoped named branch was created
before edits. No numeric setup exit is exposed by the app. Main checkout,
other worktrees, configuration and security settings were preserved.

The candidate used the existing `withTestCleanup` pattern and a separate async
operation scope. It created the initial writable ModelContainer in a nested
synchronous scope, then the read-only container, separate owned defaults domains
and PrivateCloudSyncStore. The operation awaited `prepareStorage()` and kept
all original assertions: typed `metadataWriteFailed`, exact
`NSCocoaErrorDomain`/`NSFileWriteNoPermissionError`, retained legacy metadata,
and incomplete migration. Defaults cleanup remained registered before allocation.
Before root removal, weak references checked release of both containers and the
sync store. This checked ownership, not explicit framework-store closure.

A new four-case diagnostic regression exercised normal/typed-throw operation
exit crossed with successful/missing-root removal. Missing-root injection ran
only after owner-release checks, removed the owned root and attempted a second
removal; it did not change permissions or silently accept a missing root.
Caller-located issues retained only native domain/code in a dedicated error
struct. Matching required `NSCocoaErrorDomain`/4 and the exact caller location;
when operation and cleanup both failed, the original typed operation error
was preserved. All four argument cases passed in the candidate experiment,
including its two intentional known cleanup issues. This is diagnostic evidence
for the abandoned candidate, not delivered coverage or inventory additions.

The actual migration failure **did not pass the lifetime requirement**:

- Writable ModelContainer released: **true**.
- PrivateCloudSyncStore released: **true**.
- Read-only ModelContainer released: **false**.

The candidate withheld directory removal and failed at the caller's location.
The original migration assertions passed before this failure. The expected
SwiftData Cocoa 513 diagnostic was retained locally. This establishes retention
at the cleanup boundary, not its internal cause or eventual duration. Source
inspection confirms `prepareStorage()` awaits its migration task and clears its
task handle on both exits. The installed SwiftData ModelContainer public
interface exposes `deinit` and destructive `erase()`, but no close/shutdown API.
No existing repository seam establishes the retained container's completion.
Erasing this read-only store is not a supported substitute for closing it.

The requested implementation cannot safely be completed within the existing
APIs/seams established here. A follow-up needs an evidenced framework lifetime
boundary or a separately reviewed isolation/seam change before claiming checked
cleanup after resource release. No arbitrary sleep, polling, process-global
output redirection, production redesign or weakened persistence assertion was
introduced. Broader callback/checkpoint, configuration, device and epic
acceptance remain open.

Retained local investigation artifacts:

- `.build/i372-root-candidate.swift` and `.build/i372-root-candidate.patch`:
  final diagnostic candidate, excluded from the committed source.
- `.build/i372-root-focused-1.log`: initial compile failure (missing `try` at
  the throwing `withKnownIssue` call); zero tests executed, no coverage credit.
  A preceding formatter parse error from an incomplete closing brace was
  corrected before this build; it is not test evidence.
- `.build/i372-root-focused-2.xml` and matching `.log`: exactly two function
  identities, one passed (four argument cases) and one failed (lifetime check),
  zero XML errors/skips. The two known cleanup issues are not test failures.
- `.build/i372-root-lifetime.xml` and matching `.log`: exactly the original
  migration identity, one failure, zero XML errors/skips; diagnostic separates
  the three owner-release results above.

Both diagnostic processes exited before a separate checked cleanup removed
only their two UUID roots identified by their read-only-store diagnostics.
No deletion occurred while either diagnostic process was alive. Raw framework
logs containing temporary store paths remain local and must not be published.
The candidate source, inventory and source-index changes were restored exactly
to the base after retaining the experiment; no new regression is delivered.

Restored-baseline validation (Xcode 27.1 / 27A9275, macOS 26.6.2):

- Three independent unsigned, serial executions of
  `PrivateCloudPersistenceTests.failedMigrationSaveRetainsLegacyPreferences`:
  **3/3** exact outcomes, zero failures/errors/skips. XML/log pairs are
  `.build/i372-root-baseline-focused-1` through
  `.build/i372-root-baseline-focused-3` with `.xml`/`.log` extensions.
- Unsigned owning `PrivateCloudPersistenceTests`: **13/13** exact inventory
  identities, zero failures/errors/skips, in
  `.build/i372-root-baseline-owning.xml` and matching `.log`. The three-case
  existing defaults regression remains present; the full sentinel test ran.
- `mise exec -- ./scripts/test-host.sh`: **578/578** exact signed host inventory
  identities, zero failures/errors/skips, independently compared as an XML
  identity multiset. Signed host identity, Keychain entitlement and provisioning
  profile were verified by the supported gate. Reports remain in
  `.build/host-results/`, with log
  `.build/i372-root-baseline-signed-host.log` and production LCOV under
  `.build/coverage/swift-host/`. Duplicate aggregate/product XML is not extra
  execution. These passes validate the restored baseline, not the candidate.

Focused command: `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--disable-xctest --no-parallel --filter
PrivateCloudPersistenceTests.failedMigrationSaveRetainsLegacyPreferences
--xunit-output .build/i372-root-baseline-focused-1.xml`. Repetitions add
`--skip-build` with distinct outputs. Owning selection changes the filter to
`PrivateCloudPersistenceTests`. Candidate runs used the same runner and their
recorded distinct output paths; the first executable candidate selected the
original identity plus `readOnlyMigrationFixtureCleansUpAfterExit`.

Baseline logs retain the upstream OpenTelemetry watchOS minimum deprecation,
expected read-only SwiftData Cocoa 513 diagnostics (nine in the complete signed
gate), and the three existing intentional known cleanup issues in the signed
gate. No new runtime warning, unexpected skip or unhandled failure occurred in
baseline validation. Strict repository Swift lint and documentation checking
passed (`.build/i372-root-swift-lint.log`, `.build/i372-root-docs.log`); final
diff/JSON checks confirm only the owning audit record and linked evidence/
traceability changed. Fixture source, inventory and source index exactly match
the base; historical counts are preserved. Built discovery exactly matches all
578 inventory identities (`.build/i372-root-baseline-discovery.txt`); the
independent outcome summary is `.build/i372-root-verification.json`. No new
discovery identity is claimed.
Simulator, live-server and physical-device gates were not run for this
evidence-only change; they cannot resolve the observed local owner retention.


## Read-only migration process boundary (issue #372)

PR #397 now delivers the test-only process boundary following the historical
[blocked lexical-lifetime experiment](#read-only-migration-fixture-lifetime-blocker-issue-372).
That experiment and its failed/restored-baseline results above remain historical
evidence. No SwiftData retention cause, permanent leak or framework defect is
claimed. Production persistence and the bearer subprocess helper are unchanged.

The original `failedMigrationSaveRetainsLegacyPreferences()` identity invokes
the current host executable, retaining its required signed bundle/library
arguments and replacing inherited selection/report arguments. In that child, a
writable store is reopened read-only and actual `prepareStorage()` must produce
`metadataWriteFailed`, Cocoa domain/code 513, byte-identical retained archive
and an incomplete migration marker. No rollback changes the scenario.

The parent owns a UUID root and two UUID defaults domains before launch. A
versioned nonce marker prevents accidental recursive execution. Success requires
normal observed exit zero, closed owned descriptors, complete bounded output,
exactly one non-skipped passing XML identity, a nonce-bound typed report derived
from the actual migration, and fresh cross-process preferences observations.
Checked cleanup removes only those resources after exit and IO closure; fresh
observers prove domain removal. Unrelated root/domain and parent descriptor
sentinels remain intact. Coverage profiles use unique names outside the removed
root while retaining the signed gate's product-prefix merge patterns.

Native termination callbacks and DispatchIO drive supervision without global
stdout/stderr redirection or blocking descriptor reads. Output/XML/typed limits
are 1 MiB/64 KiB/16 KiB; parsers reject ambiguous identities/counts, entities,
duplicate JSON keys and unbounded nesting/strings. Operation and cleanup errors
are distinct. The deadline starts before launch (20 seconds, followed by a
5-second teardown bound), but Foundation's synchronous `Process.run()` cannot
be interrupted. Bounded Foundation parsing and owned filesystem metadata/removal
are also synchronous boundaries. Caller cancellation does not cancel the exit
observer. Unconfirmed exit or IO closure preserves resources; test-only recovery
requires a separate real native termination and closure proof.

Thirteen new supervisor test identities include 27 argument cases: 16 actual
helper modes, four explicitly injected XML report faults, five deterministic
cancellation phases and two injected IO-acknowledgment failures. The helper
controls exercise actual assertion/throw/skip/known-issue/zero-selection/signal
outcomes plus malformed, missing, duplicate, oversized and wrong-nonce reports.
The normal migration branch contains no known-issue suppression; the deliberate
known-issue control derives its count from the actual matcher and is rejected
even when this runner represents it as passing XML. Launch/partial setup,
timeout, pre-cancellation, injected launch cancellation, uncertain exit, uncertain
IO and independent operation/cleanup failures have separate regressions. A lost
supervisor event is labeled injection; it does not claim native SIGKILL failure.

Validation at `410e92682bf5e48926fee7505c16da4ccb361e6a` on m2
(macOS 26.6.2, Xcode 27.1 build 27A9275), before the parent diagnostic
[review correction](#bounded-parent-diagnostic-write-review-correction):

- Three independent unsigned serial focused invocations: **14/14 each**,
  zero failures/errors/skips, exact identity multisets independently compared
  against the inventory. Reports: `.build/i372-isolation-repeat-1` through
  `-3`, each with `.xml` and `.log` extensions.
- Owning persistence, new supervisor and unchanged bearer suites: **35/35**,
  zero failures/errors/skips, exact expected identities in
  `.build/i372-isolation-owning-bearer-1.xml` and matching `.log`.
- Final formatted-source signed host gate: **591/591**, zero failures/errors/
  skips, exact inventory identity multiset independently compared from the two
  product XML reports in `.build/host-results/`. The supported gate verified
  signed runner identity, entitlement and provisioning profile and exported
  production LCOV under `.build/coverage/swift-host/`. Log:
  `.build/i372-isolation-signed-host-final.log`. The preceding signed run also
  passed 591/591 before lint-only source corrections.
- Built host discovery: **591/591** declarations, compared by canonical suite
  and declaration names in `.build/i372-isolation-discovery.txt`. Product XML,
  aggregate XML and parameter cases are not counted as extra identities.
- Repository strict Swift lint and documentation references pass; diff/JSON
  checks pass. Logs: `.build/i372-isolation-swift-lint-final.log` and
  `.build/i372-isolation-docs-final.log`. Independent outcome summary:
  `.build/i372-isolation-verification.json`. Initial strict lint found enum
  case layout, for-each style and long trailing comments; corrected before
  the final signed gate. An early XML inspection during gate execution found
  incomplete output; it was discarded and repeated after process completion.

Expected warnings remain the upstream OpenTelemetry watchOS minimum deprecation,
read-only SwiftData Cocoa 513 diagnostics in the existing fault cases, and three
intentional known cleanup issues. New child control failures are captured and
asserted privately; they are not unexpected parent-suite failures or skips.

Focused command: `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--skip-build --disable-xctest --no-parallel --filter
'PrivateCloudPersistenceTests.failedMigrationSaveRetainsLegacyPreferences|ReadOnlyMigrationChildTests'
--xunit-output .build/i372-isolation-repeat-1.xml`. Repetitions use distinct
report names; the owning filter is
`PrivateCloudPersistenceTests|ReadOnlyMigrationChildTests|BearerLogChildTests`.
The complete signed lane uses `mise exec -- ./scripts/test-host.sh`.

Earlier attempts remain local and receive no passing coverage credit: initial
compile failures (unavailable Skip type, non-Sendable defaults alias, enum typo
and a missing result argument), a canonical-URL guard failure corrected using
validated file paths, and the first controls run's incorrect expected category
for actual zero selection. A failed temporary editing assertion also reran the
old guard once. Final repeats supersede these attempts without erasing them.
Raw child/framework diagnostics, temporary paths and setup traces remain private.

At `410e926`, the source index added thirteen declarations (1,575 entries), the host
inventory adds thirteen identities (591 total), and the core audit adds thirteen
individual nine-rule reviews plus the specific owning-test/helper review.
Historical audit counts remain revision-bound. Broader checkpoint/cancellation,
configuration, Simulator, live-server and physical-device acceptance is unchanged.
Fresh review of the final implementation SHA and green CI are required; the
previous documentation-only review does not clear this implementation.


## Bounded parent diagnostic write review correction

Fresh independent review of `410e926` found one P2: after leaving the process/
reader event loop, the parent awaited a diagnostic writer whose continuation
waited indefinitely for DispatchIO completion. The child report writer remains
process-contained; the parent invocation was outside that boundary. Existing
selection, typed migration and cleanup assertions otherwise passed review.

The parent now persists diagnostics in a separately bounded phase using the
same native event stream. Its deadline is the earlier of the remaining operation
budget and one second. Deadline/cancellation explicitly stops the owned channel
and allows at most one additional second for native close acknowledgment. The
parent awaits only finite timers, never an IO continuation after that bound.
Native channel/descriptor ownership survives an unconfirmed close; the descriptor
is closed only in its native cleanup callback. Original operation failures remain
intact, with distinct diagnostic write, close, deadline, cancellation and
unconfirmed-close failures. Missing close acknowledgment sets writersClosed
false and preserves the root/domains. Test-only recovery also requires the
separate native diagnostic-close proof. Already-latched cancellation skips the
optional diagnostic write and retains the existing cancellation/cleanup contract.

A new two-case regression injects loss of the write-completion close action on a
real owned diagnostic channel, then separately injects loss of its close
acknowledgment. This simulates missing notifications, not a physical disk stall
or native close failure. The test uses a 100 ms diagnostic deadline, a 500 ms
close-acknowledgment bound and a separate 30-second completion notification;
there is no elapsed-time performance assertion or sleep used as readiness. It
requires bounded return with the original malformed-XML failure, real normal
child exit and retained archive/incomplete-migration evidence. Confirmed closure
permits checked cleanup; uncertain acknowledgment preserves the root/domains
until independently proven native closure authorizes explicit recovery. Parent
descriptor identity sentinels remain unchanged. All prior thirteen supervisor
regression identities are preserved.

Correction validation on the same m2 toolchain:

- Three independent focused passes: **15/15 each**, exact identity multisets,
  zero failures/errors/skips. The new identity executed both argument cases.
- Owning persistence, all new regressions and unchanged bearer suite: **36/36**,
  exact identity multiset, zero failures/errors/skips.
- Supported complete signed host gate: **592/592**, exact inventory identities,
  zero failures/errors/skips. Signing, entitlements and provisioning verified
  by the gate; production LCOV exported. Existing three intentional known
  cleanup issues and upstream/read-only warnings remain unchanged.
- Built discovery matches all **592** host declarations. Strict repository
  Swift lint, documentation references and final diff checks passed.

Reports use `.build/i372-diagnostic-repeat-1` through `-3` and
`.build/i372-diagnostic-owning`, each with `.xml` and `.log` extensions; signed
log `.build/i372-diagnostic-signed-host.log`, discovery
`.build/i372-diagnostic-discovery.txt`, lint
`.build/i372-diagnostic-lint-final.log`, documentation
`.build/i372-diagnostic-docs.log` and independent summary
`.build/i372-diagnostic-verification.json`. Commands are the same supported
serial focused/owning and signed commands above, with these distinct report names.
The diagnostic-only first run passed one identity/two argument cases. The first
full corrected candidate then failed two existing cancellation cases because
optional diagnostics started after cancellation was already latched; the writer
path was corrected without weakening those assertions. An initial strict lint
trailing-comment violation was corrected before final gates. Those unsuccessful
attempts remain local and receive no passing coverage credit.

The current host inventory is 592, source index 1,576 and core audit 586 individual
records; historical counts and the `410e926` evidence remain revision-bound.
The added declaration is reviewed under all nine rules. The complete `410e926`
CI run passed, including the unsigned host's sole named Keychain exclusion; its
review/CI evidence does not clear this changed implementation. Fresh exact-head
review and CI remain required. No merge or auto-merge is enabled.


## Bounded shared log shutdown completion (issue #372)

At merged base `1695a4071633ef43898d741213d9c37a378bd91c`, the concurrent
log-shutdown test already had bounded downstream-entry and shared-join checks.
After releasing the downstream fake, however, it awaited both task values
without completion bounds. A lost caller response could hang before the final
completion assertions. This source-verified gap is separate from the already
delivered entry/join remediation; the historical source audit remains retained.

Each caller now publishes to its own existing `AuthTelemetryTestCompletion`
actor only after the actual queued exporter shutdown returns. The test observes
both bounded values concurrently, using the existing ten-second failure budgets
and separate source-located stage diagnostics. Only observed caller returns
allow the existing task-value awaits. Timeout records the missing caller stage,
cancels both task handles and returns without awaiting an unconfirmed caller.
It does not claim that a genuinely stuck operation was drained on failure.

The two pre-release incomplete flags, proven second-caller join, single downstream
shutdown, explicit downstream release and final complete flags remain unchanged.
There is no production change, new helper, new declaration, process-global
mutation or sleep used as readiness. Each completion actor has one waiter; the
controlled downstream one-shot gate retains its existing latch semantics.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused executions: **1/1 each**, exact original identity,
  zero failures/errors/skips.
- Owning `RemoteTelemetryTests`: **39/39**, exact inventory identities, zero
  failures/errors/skips.
- Supported complete signed host gate: **592/592**, exact inventory identities,
  zero failures/errors/skips. Signing/entitlements/provisioning checked by the
  gate; production LCOV exported. Existing upstream watchOS deprecation,
  read-only Cocoa 513 diagnostics and three intentional cleanup known issues
  remain retained; no new runtime warning or unexpected issue was observed.
- Built discovery: **592/592** host declarations. Repository strict Swift lint,
  documentation references and final diff/JSON checks passed. No unsuccessful
  or zero-test validation attempt occurred for this slice.

Focused command: `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--disable-xctest --no-parallel --filter
RemoteTelemetryTests.testConcurrentLogShutdownCallersAwaitSharedCompletion
--xunit-output .build/i372-shutdown-focused-1.xml`. Independent repetitions add
`--skip-build` and distinct outputs `-2` and `-3`; owning selection changes the
filter to `RemoteTelemetryTests` and writes `.build/i372-shutdown-owning.xml`.
The complete signed lane uses `mise exec -- ./scripts/test-host.sh`, retaining
`.build/i372-shutdown-signed-host.log`. All XML files have matching log files.
Discovery, lint, documentation and outcome summary are retained in
`.build/i372-shutdown-discovery.txt`, `.build/i372-shutdown-lint.log`,
`.build/i372-shutdown-docs.log` and `.build/i372-shutdown-verification.json`.

One current test disposition is updated with a nine-rule completion review;
source-index line locations follow the edited file. Inventory 592, source-index
1,576 and core audit 586 counts remain unchanged, with no new identity or
configuration/device/live-server acceptance claim. Broader #372/#362 criteria
and unrelated telemetry cleanup findings remain open. Fresh exact-head source
review and CI are required before merging this slice.


## Bounded in-flight refresh caller outcomes (issue #372)

At merged base `c33a5605858bb022ecccd6cfc65f90df2142c9c7`, three authenticated
request tests already used bounded fake stage gates, but still awaited their
originator/joiner task outcomes without final completion bounds:

- `testConcurrentRejectionJoinsInFlightRefreshInsteadOfStaleStoreRead`
- `testJoinerRecordsOriginatorRejectedTokenInCompletedRefresh`
- `testConcurrentRejectionJoinsFailingInFlightRefresh`

Each actual send/recovery call now reports completion to its own existing
`AuthTelemetryTestCompletion` actor after returning or throwing. Success values
return unchanged and caught errors are rethrown unchanged. Concurrent bounded
observations precede all six existing task-value consumptions. The existing
ten-second failure budgets and source-located originator/joiner diagnostics are
used without adding a timing assertion or sleep as readiness. If an outcome is
missing, the test releases all fake gates, requests cancellation of both handles
and returns without awaiting unconfirmed work. Cancellation is not proof that a
genuinely stuck task terminated; asynchronous drainage remains open when unproven.

Original refresh-entry/mid-save/initial-send gating and release ordering remain
unchanged. The success case still requires both HTTP 200 outcomes, exactly one
refresh, zero mid-token requests, two final-token requests and stored final
credentials. The provenance case retains both exact refreshRejected outcomes,
the originator's recorded rejected token and subsequent cached rejection. The
failing-join case retains both exact refreshRejected outcomes, one refresh,
zero mid-token retries and reauthentication state. Completion signals carry only
a Boolean; new timeout diagnostics do not include result/token payloads.

All fixtures are fresh in-memory stores/transports/coordinators with synthetic
accounts and tokens. There is no new helper, production change or declaration.
Earlier bounded stage-gate work is not re-claimed by this final-outcome slice.
Historical audit gate findings remain retained; three current dispositions gain
individual nine-rule reviews. Inventory 592, source-index 1,576 and core audit 586
counts remain unchanged. Broader lifecycle/configuration/device/live-server and
file-backed cleanup criteria remain open.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused executions: **3/3 each**, exact original
  identities, zero failures/errors/skips.
- Owning `AuthenticatedRequestTests`: **24/24**, exact inventory identities,
  zero failures/errors/skips.
- Supported complete signed host gate: **592/592**, exact inventory identities,
  zero failures/errors/skips. Signing/entitlements/provisioning checked by the
  gate and production LCOV exported. Existing watchOS deprecation, read-only
  Cocoa 513 diagnostics and three intentional cleanup known issues remain
  retained; no new runtime warning or unexpected issue was observed.
- Built discovery matches all **592** host declarations. Strict repository
  Swift lint, documentation references and final diff/JSON checks passed.
  No unsuccessful or zero-test validation attempt occurred for this slice.

Commands use supported serial Swift Testing: `mise exec -- env
BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter`
with the three exact names above prefixed by `AuthenticatedRequestTests.` and
joined by `|`, writing `.build/i372-refresh-focused-1.xml`. Repetitions add
`--skip-build` and distinct `-2`/`-3` reports. Owning selection is
`AuthenticatedRequestTests`, writing `.build/i372-refresh-owning.xml`. Each XML
has a matching log. Complete signed validation uses
`mise exec -- ./scripts/test-host.sh`, retaining
`.build/i372-refresh-signed-host.log`. Discovery/lint/docs/outcome evidence is
`.build/i372-refresh-discovery.txt`, `.build/i372-refresh-lint.log`,
`.build/i372-refresh-docs.log` and `.build/i372-refresh-verification.json`.
Fresh exact-head source review and CI are required before merge.


## Controlled telemetry token response lifecycles (issue #372)

At merged base `20442b3d2ea6473f85c6f12bd7762adb267f9cd5`, three token-provider
tests had bounded entry signals but used five/thirty-second fake delays to hold
responses and consumed caller task values without final completion bounds:

- `testCachedTokenAvailabilityReportsActiveAcquisition`
- `testCancellingOnlyWaiterCancelsUnderlyingRefresh`
- `testDisablingCancelsRefreshAndClearsMemoryToken`

Each now uses the existing controlled response gate: acquiring state is observed
while a response is explicitly held, rather than within a timed success window.
Existing typed-result/completion helpers signal only after actual provider
return/throw; bounded observations precede original task-value consumptions.
Values/errors and availability, cancelled/disabled and cancellation assertions
remain.

Awaited `withTestCleanup` cancels the caller, disables the provider and retires
the response on normal and throwing exits. Existing retirement rejects late
entry and bounds observation of a response body already waiting. Cleanup never
awaits an unconfirmed caller and does not establish termination of the whole
underlying provider task graph. Unproven drainage remains open.

The sole-waiter case observes removal through the existing actor property before
retiring the response. Removal and underlying cancellation occur in one
synchronous provider actor operation. Retirement releases without cancelling
that task; the fake must observe its actual cancellation flag to emit the
cancellation signal/count. Original cancellation assertions execute before scope
cleanup disables the provider, so cleanup cannot manufacture the tested action.

Existing ten-second helper deadlines are failure bounds, not timing tolerances
or readiness sleeps. No helper/production implementation, new declaration or
inventory change. Two methods become async throwing to propagate awaited cleanup
failures; discovery identities remain unchanged. Three current dispositions have
individual nine-rule reviews; historical notes remain retained. Inventory 592,
source index 1,576 and core audit 586 counts are unchanged.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused executions: **3/3 each**, exact original identities,
  zero failures/errors/skips.
- Owning `TelemetryAuthenticationTests`: **18/18**, exact inventory identities,
  zero failures/errors/skips.
- Supported complete signed host gate: **592/592**, exact inventory identities,
  zero failures/errors/skips. Signing/entitlements/provisioning verified by the
  gate and production LCOV exported. Existing watchOS deprecation, read-only
  Cocoa 513 diagnostics and three intentional cleanup known issues remain
  retained; no new runtime warning or unexpected issue was observed.
- Built discovery: **592/592** host declarations. Strict repository Swift lint,
  documentation references and final diff/JSON checks passed.

Supported serial Swift Testing commands use `mise exec -- env
BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter`
with the three exact names above prefixed by `TelemetryAuthenticationTests.` and
joined by `|`, writing `.build/i372-token-focused-1.xml`. Repetitions add
`--skip-build` and distinct `-2`/`-3` reports. Owning selection is
`TelemetryAuthenticationTests`, writing `.build/i372-token-owning.xml`; each XML
has a matching log. Complete signed validation uses
`mise exec -- ./scripts/test-host.sh`, retaining
`.build/i372-token-signed-host.log`. Discovery/lint/docs/outcome evidence is
`.build/i372-token-discovery.txt`, `.build/i372-token-lint.log`,
`.build/i372-token-docs.log` and `.build/i372-token-verification.json`.
A transient m2 execution disconnect prevented the audit-update command from
starting; a harmless read recovered connectivity. The already-running focused
command exited zero and its exact 3/3 XML outcomes were independently verified.
No failed/interrupted test is credited through that environment event.
Broader lifecycle/configuration/device/live-server and file-backed cleanup
acceptance remains open. Fresh exact-head source review and CI are required.


## Bounded OTLP cancellation caller outcomes (issue #372)

At merged base `18a02ebfadb1f3797161584560526f98591b3e5e`, three memory-only
OTLP cancellation tests had bounded phase-entry signals but awaited their final
export task values without caller-completion bounds:

- `testCancellingAsyncExportCancelsTokenWaitBeforeRPC`
- `testCancelActiveExportsCancelsAsyncTokenWaitBeforeRPC`
- `testCancellationAfterTokenCompletionPreventsRPCAndAllowsLaterExport`

Each now signals its own existing completion actor only after the actual public
export returns, forwards that result unchanged, and observes the bounded signal
before consuming the task value. Missing completion records a caller-specific
source-located failure, requests task/exporter cancellation and returns without
awaiting unconfirmed work. This does not prove underlying token/provider/export
task termination; asynchronous drainage remains open when unproven.

Original cancellation actions and phase-entry/release ordering remain. Direct
caller cancellation still requires failure and zero RPC; lifecycle cancellation
still requires failure, zero RPC and one client cancellation. The post-token
registration case still releases its controlled registration gate before result
observation, then requires first failure/zero RPC, later success/one RPC and two
provider requests. The gate is already released before the new failure guard.

Existing thirty-second operation/fake settings remain unchanged. The ten-second
completion deadline bounds waiting after cancellation, but does not timestamp
completion or rule out natural fake expiry during a long scheduler pause. The
two token-wait cases therefore retain follow-up dispositions for that timing/
provider-cancellation ambiguity. No new elapsed-time assertion or readiness sleep.
Providers/clients are fresh memory fakes, with no file or native-session fixture
here. No helper/production code, new declaration or inventory change. Three
records gain scoped nine-rule reviews while historical notes remain retained.
Inventory 592, source index 1,576 and core audit 586 counts remain unchanged.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused executions: **3/3 each**, exact original identities,
  zero failures/errors/skips.
- Owning `AuthenticatedOtlpSpanExporterTests`: **19/19**, exact inventory
  identities, zero failures/errors/skips; the original bearer privacy scenario
  remains present and executed.
- Complete supported signed host gate: **592/592**, exact inventory identities,
  zero failures/errors/skips. Signing/entitlements/provisioning verified by the
  gate and production LCOV exported. Existing watchOS deprecation, read-only
  Cocoa 513 diagnostics and three intentional cleanup known issues remain
  retained; no new runtime warning or unexpected issue was observed.
- Built discovery: **592/592** host declarations. Strict repository Swift lint,
  documentation references and final diff/JSON checks passed. No unsuccessful
  or zero-test validation attempt occurred for this slice.

Supported serial Swift Testing commands use `mise exec -- env
BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter`
with the three names above prefixed by `AuthenticatedOtlpSpanExporterTests.` and
joined by `|`, writing `.build/i372-otlp-focused-1.xml`. Repetitions add
`--skip-build` and distinct `-2`/`-3` reports. Owning selection is
`AuthenticatedOtlpSpanExporterTests`, writing `.build/i372-otlp-owning.xml`; each
XML has a matching log. Complete signed validation uses
`mise exec -- ./scripts/test-host.sh`, retaining
`.build/i372-otlp-signed-host.log`. Discovery/lint/docs/outcome evidence is
`.build/i372-otlp-discovery.txt`, `.build/i372-otlp-lint.log`,
`.build/i372-otlp-docs.log` and `.build/i372-otlp-verification.json`.
Broader lifecycle, drainage, configuration/device/live-server and file-backed
cleanup acceptance remains open. Fresh exact-head source review and CI required.


## Controlled OTLP token-wait lifecycle (issue #372)

At merged base `48392b30738a1dc7142477286376b71dcf5379a8` (#402), the
`SuspendedTokenProvider` fake could finish naturally after thirty seconds. A
bounded caller-return wait alone could therefore pass after scheduler delay
without proving provider cancellation. This test-only slice replaces that fake
with a one-shot actor whose installed cancellation handler opens a controlled
release signal. Natural signal timeout records an issue; genuine cancellation
is independently observed through `Task.isCancelled`, a signal and an exact
count before cleanup can cancel anything. No production leak or production
cancellation bug was observed or changed.

Four existing cases retain their typed export outcomes and client counters:

- `testCancellingAsyncExportCancelsTokenWaitBeforeRPC`
- `testCancelActiveExportsCancelsAsyncTokenWaitBeforeRPC`
- `testCancellationUnblocksTokenWaitAndShutsTransportOnce`
- `testCancellationAfterTokenCompletionPreventsRPCAndAllowsLaterExport`

The three suspended-provider users now await scoped retirement on every
operation exit. Retirement rejects late entry, releases existing waiters and
observes logical fake-body exit; it never cancels a task or manufactures the
cancellation count. The first two retain failure/zero RPC and the second retains
one client cancellation. The shutdown case retains failure plus two client
cancellations, one shutdown, zero synchronous shutdowns and one async shutdown.
Its export and two shutdown calls now have bounded actual caller-return signals.
The post-token case retains registration release ordering, first failure/zero
RPC, then later success/one RPC/two token requests; its later export also has a
bounded actual caller-return signal. Missing completion records a stage issue
and returns without awaiting an unconfirmed task value.

New parameterized
`testSuspendedTokenProviderDistinguishesCancellationFromRetirement(mode:)`
executes cancellation before entry, cancellation after handler installation,
retirement before entry and retirement after handler installation. It requires
the typed cancelled result and exact request/cancellation counts: retirement
alone must leave cancellation zero. The controlled start and installed-handler
signals make both registration orderings explicit. Every parameter owns its own
fake and awaits cleanup. Existing ten-second bounds fail missing transitions;
there is no readiness sleep.

Independent review of initial head `d5d940f5d00c44206d5d028ee7d9dc237fea9cf0`
found a P2 causality gap: the default fixture timeout was two seconds and clamped
`explicitTimeout: 30`, so ordinary deadline cancellation could satisfy the
provider observation within ten seconds. The three lifecycle cases now explicitly
configure thirty seconds as well as requesting thirty seconds. Before starting
export, each captures a monotonic lower bound on the possible operation deadline;
the fake records the monotonic instant when it actually observes cancellation.
That instant must precede the lower bound. The ten-second failure bounds are
unchanged. This proves deadline exclusion for a passing run rather than accepting
any eventual cancellation; a long scheduler delay fails conservatively instead
of turning deadline cancellation into success. No wall-clock speed assertion.

Two temporary production mutations retain ordinary `awaitTask` timeout
cancellation: one removes span lifecycle callback invocation and rejection-path
cancellation; the other removes caller cancellation propagation (including the
early-cancel guard). The lifecycle mutation must fail both lifecycle-cancel and
shutdown identities; the caller mutation must fail the direct-caller identity.
Mutation XML/logs and `.build/i372-otlp-control-mutation-verification.json` retain
exact failed identities and outcomes. Production bytes are restored exactly before
post-mutation passing validation; no mutation enters the commit.

Only the four existing test bodies, this shared fake, its local contract
test and the fixture timeout parameter change. Five records receive individual nine-rule reviews, while historical
assessments stay revision-bound. The two timed-fake follow-ups are superseded
by observed genuine cancellation; whole production task-graph drainage is not
claimed. Inventory is now 593 identities, source index 1,577 declarations, core
audit 587 records, owning suite 20 identities. No production/shared synchronization
helper change, global output redirection or broad tracker reconciliation.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused runs: **5/5 identities each**, including all four
  parameter cases each run; zero failures/errors/skips.
- Owning `AuthenticatedOtlpSpanExporterTests`: **20/20**, exact identities, zero
  failures/errors/skips; original bearer privacy tests remain executed.
- Supported full signed host gate: **593/593**, exact inventory identities,
  zero failures/errors/skips; built discovery **593/593**.
- Strict Swift lint, documentation references, scoped source-index/JSON and diff
  checks passed. Initial compilation found a typed-catch inference error in the
  new test; it was corrected with typed `do throws(...)` before any test ran.
  That unsuccessful build remains retained and is not credited as execution.

Revised validation uses the `i372-otlp-control-revised-` prefix for focused,
owning, discovery, signed-host, lint/docs and outcome records.

Focused serial command: `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift
test --disable-xctest --no-parallel --filter` selecting the five names above,
writing `.build/i372-otlp-control-focused-1.xml`; repeats add `--skip-build`
and distinct `-2`/`-3` reports. Owning filter is
`AuthenticatedOtlpSpanExporterTests`, report
`.build/i372-otlp-control-owning.xml`. Complete signed command is
`mise exec -- ./scripts/test-host.sh`, log
`.build/i372-otlp-control-signed-host.log`; discovery, lint, docs and outcome
manifest use the same `i372-otlp-control-` prefix. Raw logs/build artifacts stay
private. Fresh exact-head source review and CI remain required. Broader
#372/#362 lifecycle, native configuration/device/live-server and unproven
drainage criteria remain open; cache implementation is separate.


## Remaining OTLP caller-completion bounds (issue #372)

At merged base `dfd389478c1707bf725bccebfb15f9ced9350442`, two existing
`AuthenticatedOtlpSpanExporterTests` cases retained unbounded final caller
consumption despite already bounded entry signals:

- `testConcurrentExportsUseProviderSafelyAndReuseOneClient` awaited a structured
  task-group exit for eight exports. It now owns eight caller tasks, each with a
  distinct existing completion actor signalled after actual export returns. All
  eight token entries are still required before release; each original success
  Bool is observed before its task value. Refresh count one, eight client
  exports and exact shared bearer metadata remain asserted before cleanup.
- `testAsyncTransportShutdownWaitsForClosureCompletion` awaited shutdown's task
  value after releasing its close gate. It now observes a completion signal
  after actual transport shutdown and the original completed-state mark before
  consuming that value. Bounded close entry, completed false before release
  and completed true after release remain.

Both tests await existing `withTestCleanup` on normal and failing exits. The
concurrent case cancels owned callers, requests exporter cancellation and
releases the provider gate. The transport case cancels its shutdown caller,
releases its close gate and invalidates its owned ephemeral session. Missing
completion records a stage/source-located failure (including concurrent caller
index) and skips unconfirmed task-value consumption. The release controls latch
late arrivals; no underlying production task-graph drainage or native session
delegate termination is claimed.

Existing ten-second helper bounds, exporter timeouts and fake implementations
remain unchanged. No readiness sleep, retry or threshold relaxation. No new
helper, production code, declaration or inventory identity. Only these two test
bodies and scoped evidence/locations change. Two records receive individual
nine-rule reviews; older findings stay revision-bound, including already
remediated entry-gate history. Counts remain host593, source index1,577, core
audit587 and owning suite20.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused runs: **2/2 each**, exact original identities, zero
  failures/errors/skips.
- Owning suite: **20/20**, including original bearer privacy and controlled
  token-fake contract cases, zero failures/errors/skips.
- Complete supported signed host gate: **593/593**, exact inventory identities,
  zero failures/errors/skips; built discovery **593/593**.
- Strict Swift lint, docs, source-index/audit scope and final diff checks passed.

Focused supported serial command is `mise exec -- env
BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter`
with the two names above, report `.build/i372-otlp-remaining-focused-1.xml`;
repeat independently with `--skip-build` and `-2`/`-3` reports. Owning filter is
`AuthenticatedOtlpSpanExporterTests`, report
`.build/i372-otlp-remaining-owning.xml`. Signed command is
`mise exec -- ./scripts/test-host.sh`; discovery, signed-host log, lint/docs and
outcome manifest use the `i372-otlp-remaining-` prefix. Raw framework/build logs
stay private. Fresh independent exact-head review and CI are required. Broader
#372/#362 lifecycle, configuration/device/live-server and unproven drainage
criteria remain open; #400 cache implementation is separate.


## OTLP retry and privacy caller bounds (issue #372)

At merged base `8d31dd0d5666488f0d55a598a50581d04d39b52c`, two existing
OTLP tests directly awaited public export/flush operations without final caller
observation bounds:

- `testCancellationAfterUnauthenticatedResponsePreventsRefreshAndRetry` now
  observes each of its two sequential exports independently before consuming
  the original typed result. First failure, client/token counts one and empty
  invalidations remain; the later epoch still requires success, client/token
  counts two and no invalidation. The existing client's unauthenticated callback
  and lifecycle cancellation action are unchanged.
- `testBearerNeverAppearsInExporterOrFailureDescriptions` now separately
  observes actual export and flush return before original result consumption.
  Export failure and the existing synthetic-marker non-disclosure checks across
  externally visible failure/configuration/flush descriptions and span
  description remain unchanged. No observed production leak is alleged.

Each operation owns an existing completion actor, signalled only after the
actual call returns; typed results are forwarded unchanged through the task.
Missing completion records a stage/source-located issue, cancels the owned
caller and requests exporter cancellation, then returns without awaiting an
unconfirmed task value or launching later work. Prior confirmed operations
have already returned. There is no claim that all underlying production tasks
are drained.

Existing ten-second observation bounds, exporter timeout and fake responses
remain unchanged. No readiness sleep, retry, latency success threshold, global
output capture, new helper, production code, declaration or inventory identity.
Only these two existing bodies plus scoped audit/evidence and required source
locations change. Two records receive individual nine-rule reviews while older
assessments stay revision-bound. Counts remain host593, source index1,577, core
audit587 and owning suite20. Broader privacy/configuration acceptance remains
separate from this caller-boundary change.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused executions: **2/2 each**, exact original identities,
  zero failures/errors/skips.
- Owning suite **20/20**, including original process-isolated bearer privacy and
  controlled-token contract coverage, zero failures/errors/skips.
- Complete supported signed host gate **593/593**, exact inventory identities,
  zero failures/errors/skips; built discovery **593/593**.
- Strict Swift lint, docs, exact two-body/audit-scope/source-index and final diff
  checks passed.

Focused serial command uses `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift
test --disable-xctest --no-parallel --filter` with the two names above, report
`.build/i372-otlp-retry-privacy-focused-1.xml`; repetitions add `--skip-build`
and distinct `-2`/`-3` reports. Owning filter is
`AuthenticatedOtlpSpanExporterTests`, report
`.build/i372-otlp-retry-privacy-owning.xml`. Signed command is
`mise exec -- ./scripts/test-host.sh`; discovery, signed-host log, lint/docs and
outcome manifest use the `i372-otlp-retry-privacy-` prefix. Raw logs/build
artifacts remain private. Fresh independent exact-head review and CI required.
Broader #372/#362 lifecycle, configuration/device/live-server and unproven
drainage criteria remain open; #400 implementation is separate.


## OTLP lifecycle phase bounds and timeout follow-up (issue #372)

At merged base `36da41d8921046f0cada2ac1a208cad0ec42a7d2`,
`testAsyncLifecycleMethodsPreserveShutdownState` directly awaited six lifecycle
calls. It now observes three sequential caller phases through separate existing
completion actors: initial span flush/log forceFlush, span/log shutdown, then
post-shutdown span flush/log forceFlush. Each phase signals only after both
actual calls return; typed results are forwarded unchanged and consumed only
after the bounded observation.

Original order and assertions remain: initial flushes succeed, post-shutdown
flushes fail, both clients shut down once, synchronous shutdown counts stay
zero, and asynchronous counts equal one. Missing phase completion records a
stage/source issue, cancels that owned phase task and requests cancellation on
both exporters, then returns without consuming unconfirmed values or launching
later phases. No claim that all underlying production tasks have drained. No
production/helper/inventory/new declaration change or new wall-clock threshold.
Only this existing test body and scoped evidence/locations change. Counts stay
host 593, source index 1,577, core audit 587 and owning suite 20.

The specifically reviewed timeout test remains an explicit unresolved follow-up:
`testAsyncTokenTimeoutDoesNotWaitForCancellationIgnoringProvider` requests a
real 50 ms deadline and asserts return within 500 ms while its fake polls for one
second. The 50 ms production deadline begins before async provider entry, so a
readiness observation added afterward can still race expiration. The 500 ms upper
wall-clock check measures scheduler delay as well as exporter behavior. Widening
that threshold would not establish the intended causal property: deadline return
while uncooperative provider work is still held.

The exporter hardcodes a Date deadline with no controllable clock seam. A
deterministic public integration needs a deliberate deadline-control strategy;
calling the existing internal `awaitTask` only after a provider is ready would
exercise a narrower boundary and must not silently replace public integration
coverage. A controlled fake/contract replacement was prepared outside the
repository but is unapplied and untested. Neither timing threshold nor that test's
source is changed here, and current passing runs are not evidence of its
scheduler-independent reliability. No production bug is inferred. Its audit
disposition is now source-assessed follow-up; the lifecycle case has its own
individual nine-rule fix review.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused runs: **1/1 each**, exact original identity, zero
  failures/errors/skips.
- Owning suite **20/20**, including existing timeout, process-isolated bearer and
  controlled-token contracts, zero failures/errors/skips. This execution does not
  resolve the timeout design finding above.
- Complete supported signed host gate **593/593**, exact inventory identities,
  zero failures/errors/skips; built discovery **593/593**.
- Strict Swift lint, docs, exact one-body/audit-scope/source-index and final diff
  checks passed.

Focused supported serial command is `mise exec -- env
BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter
AuthenticatedOtlpSpanExporterTests.testAsyncLifecycleMethodsPreserveShutdownState`,
report `.build/i372-otlp-lifecycle-focused-1.xml`. Independent repeats add
`--skip-build` and distinct `-2`/`-3` reports. Owning filter is
`AuthenticatedOtlpSpanExporterTests`, report `.build/i372-otlp-lifecycle-owning.xml`.
Signed command is `mise exec -- ./scripts/test-host.sh`; discovery, signed-host
log, lint/docs and outcome manifest use the `i372-otlp-lifecycle-` prefix. Raw logs
and build artifacts stay private. Fresh exact-head review and CI required.
Broader #372/#362 drainage/configuration/device/live-server criteria remain
open; #400 implementation is separate.


## Controlled OTLP deadline and uncooperative provider (issue #372)

At merged base `3a27e78f9ae55a02c31a2305751f02e1e289933e`, the public token
timeout test requested 50 ms before provider entry and asserted return inside
500 ms while a cancellation-ignoring fake polled for one second. That mixed a
real deadline contract with scheduler latency and left the fake unretired. This
slice replaces that particular source-assessed follow-up from #406; it does not
widen the old threshold or claim a real-time scheduling guarantee.

The explicitly approved production seam is internal `OtlpExportClock`, a
Sendable pair of `now() -> Date` and cancellation-aware async throwing `sleep`.
Live defaults remain `Date()` and native `Task.sleep(for:)`. Defaulted parameters
are added only to the internal span-exporter initializer and existing `awaitTask`.
The same injected clock reaches span deadline creation, remaining RPC budget,
token acquisition and invalidation waits. Public APIs, log/runtime call sites and
transport behavior stay unchanged. Remaining-budget calculation placement,
Date semantics, first-result-wins actor and unstructured value/timeout observers
are retained; this is no generic Clock or runtime rewrite. Live wall-clock
adjustment behavior is unchanged and not newly verified.

`testAsyncTokenTimeoutDoesNotWaitForCancellationIgnoringProvider` remains an
actual public-export integration with configured two-second ceiling and explicit
0.05-second request. It now freezes logical time, positively observes provider
entry and actual timeout continuation registration, and checks the recorded
50 ms budget with floating-point precision tolerance only. It advances logical
time and fires that timer while the provider stays held. Actual export return
must be failure with zero RPCs; genuine token cancellation is acknowledged
separately while provider exit count is still zero, before cleanup. No caller or
lifecycle cancellation manufactures the asserted timeout result. The old 500 ms
scheduler-speed assertion is removed, not widened. Existing ten-second waits
are diagnostic failure bounds, not latency acceptance.

The new actor fake acknowledges cancellation without releasing its checked
continuation. Only retirement opens the hold; there is no natural fake expiry
or polling/spin. Retirement latches before late entry, releases an installed
continuation once, and positively observes logical body exit. The one-shot manual
clock caches a single settlement across cancellation before/after continuation
registration, resumes outside locks and rejects late entry after retirement.
Its ready notification follows actual continuation installation; post-registration
contract cases positively require one pending continuation before acting. Repeated
fire/retire is safe. Cleanup releases owned controls and awaits entered fake/sleep
body exits; whole production observer/task-graph drainage is not claimed.

Four new identities provide direct contracts/boundaries:

- `testCancellationIgnoringTokenProviderRequiresExplicitRetirement(mode:)`: four
  cancellation/retirement cases before entry or after handler installation, exact
  request/exit counts and typed cancellation. Acknowledged cancellation alone
  must leave the body held.
- `testManualOtlpClockSettlesSleepExactlyOnce(mode:)`: six pre/post registration
  cancellation, firing and retirement cases, exact finished/resolution counts,
  zero pending continuations and idempotent repeated operations.
- `testSuccessfulTokenAcquisitionCancelsManualDeadlineSleeper`: public export
  succeeds with one token/RPC; positively observes registered sleeper exit and
  cancelled settlement without manually firing the timer.
- `testExpiredControlledDeadlinePreventsRPC`: after provider and timer entry,
  advances time to expiry without firing the timer, releases the token, and
  requires public failure/zero RPC plus cancelled sleeper exit. This isolates
  the remaining RPC-budget guard from timer/caller/lifecycle cancellation.

Required negative evidence is retained for the exact final source: removing
only timeout resolution (keeping token cancellation) fails caller completion;
removing only deadline token cancellation fails its separate acknowledgement;
using configured two seconds instead of explicit 50 ms fails the numerical budget;
bypassing expired RPC budget fails zero-RPC/original failure assertions. Every
mutation must fail its exact selected identity at that observation. Approved
production bytes are restored exactly before final passing validation. Earlier
passing/mutation evidence before the stronger continuation-registration witness
is retained separately; final evidence is regenerated and bound to both source
hashes. No observed production leak or unrelated runtime bug is alleged.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent final focused runs: **5/5 identities each**, including all
  four provider and six manual-clock arguments (13 logical cases per run), zero
  failures/errors/skips.
- Owning suite **24/24**, including original process-isolated bearer, cancellation,
  retry and live-default behavior; zero failures/errors/skips.
- Shared `RemoteTelemetryTests` callers **39/39**, exact identities and zero
  failures/errors/skips; log-exporter coverage is included in the owning suite.
- Full supported signed gate **597/597**, exact inventory identities, zero
  failures/errors/skips; built discovery **597/597**.
- Four final mutations killed at their specified observations; strict Swift
  lint, docs, exact inventory/argument/source-index/audit scope and final diff
  checks passed. Inventory adds four identities; source index is 1,581 and core
  audit 591. Each new/current record has an individual nine-rule review.

Supported serial commands use `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift
test --disable-xctest --no-parallel --filter` selecting the five names above,
report `.build/i372-otlp-clock-focused-1.xml`; independent repeats add
`--skip-build` with `-2`/`-3`. Owning and shared-runtime filters are
`AuthenticatedOtlpSpanExporterTests` and `RemoteTelemetryTests`, reports
`.build/i372-otlp-clock-owning.xml` and `.build/i372-otlp-clock-shared-runtime.xml`.
The final first focused run rebuilds restored source after mutations. Signed
command is `mise exec -- ./scripts/test-host.sh`; final logs/discovery/lint/docs
use `i372-otlp-clock-`. Mutation reports use the same prefix plus `mutation-`;
`.build/i372-otlp-clock-mutation-verification.json` binds production/test hashes
and failures, and `.build/i372-otlp-clock-verification.json` records final outcomes.
Raw logs remain private. Fresh exact-head review and CI remain required; broader
#372/#362 device/live/configuration and unproven drainage criteria stay open.
#400 implementation is separate.


## Search release timeout exits and missing audit records (issue #372)

At merged base `404175aed7d2dac50fb91f668f0ff653e37380cd`, two existing
`LibrarySearchCoordinatorTests` helper contracts had bounded call/registration/
completion observations but joined unconfirmed tasks on failed observations:

- `testEarlyAndRepeatedReleaseDoesNotStrandCancellationIgnoringCall`
- `testRepeatedReleaseAfterCallRegistrationCompletesBlockedCall`

Both now guard every failed observation before task-value consumption and use
existing awaited `withTestCleanup` for success, guard return and throw. Cleanup
requests owned caller cancellation and awaits `resumeBlockedCall`; it does not
pretend cancellation alone terminates the intentionally uncooperative service.
The existing release latch handles late entry and repeated release. Unknown
task values/results are never joined on a failed wait; whole underlying task
graph drainage remains unproven.

The first case retains two releases before caller creation, its original typed
success/remote-source assertion, another release and exact one service call.
The second retains positive call/blocked registration before two releases,
observes actual completion, and now explicitly consumes successful typed value
with remote-source/one-call assertions. Producers increment the completion counter
only after actual service return; cleanup never manufactures completion. Helper
implementation, production code and existing failure bounds are unchanged. No
readiness sleep, new latency threshold or retry-to-green.

These are existing host-inventory identities, not new tests. Both were absent
from the source index and core audit; add exactly their two declaration rows and
individual nine-rule records. Refresh only required source locations in this
changed file, preserving other dispositions. Host inventory stays 597, owning
suite 10; source-index rows rise from 1,581 to 1,583 and core audit from 591 to
593 by repairing those omissions. No broad tracker/index reconciliation.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused runs: **2/2 each**, exact existing identities, zero
  failures/errors/skips.
- Owning `LibrarySearchCoordinatorTests`: **10/10**, exact inventory, zero
  failures/errors/skips.
- Supported full signed host gate **597/597**, exact inventory, zero
  failures/errors/skips; built discovery **597/597**.
- Strict Swift lint, docs, exact two-body/helper/production/audit scope and final
  diff checks passed. No new declaration or inventory change.

Focused serial command uses `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift
test --disable-xctest --no-parallel --filter` selecting the two names above,
report `.build/i372-search-release-focused-1.xml`; independent repeats add
`--skip-build` with distinct `-2`/`-3`. Owning filter is
`LibrarySearchCoordinatorTests`, report `.build/i372-search-release-owning.xml`.
Signed command is `mise exec -- ./scripts/test-host.sh`; discovery, signed-host
log, lint/docs and verified outcome manifest use the `i372-search-release-`
prefix. Raw framework/build logs remain private. Fresh independent exact-head
review and CI required. Other search follow-ups and broader #372/#362 lifecycle/
drainage/configuration/device/live criteria remain open. #400 is separate.

## Coalesced request caller and private waiter ownership (issue #372)

The three existing twenty-request `AuthenticatedRequestTests` retain successful
rotation, rejected refresh and saved-password recovery behavior. Their bounded
arrival observations previously led to structured task-group joins with no
bounded caller-completion observation. Their three private transports also
retained a checked continuation after resuming an already-released late request;
a later release could try to resume that continuation again. This is a private
test-fixture ownership finding, not an observed production authentication defect.

Each case now owns twenty unstructured callers and observes actual send return
or throw with the existing bounded counter. A ten-second batch completion budget
covers all twenty results together, matching the existing auth arrival failure
budget rather than imposing a speed target. Failed arrival/completion observations return
before unknown task values are joined. Awaited existing cleanup requests every
owned caller's cancellation and releases the fake latch on success, guard return
and throw. Late calls see the permanently open latch without entering its waiter
array; release detaches the current array before resuming it. Repeated release is
explicitly exercised. No claim that cancellation/control release drains the whole
production task graph is made.

All original successful response, typed twenty-error, single refresh, recovery
login/authorization, token/store and paired-correlation assertions remain. One
new parameterized helper identity exercises rotating/rejected/saved-login private
transports, each with registered-and-cancelled versus early-release/late-entry
phases. It checks the actual 401 result, empty terminal waiter storage and safe
repeated release. Only these private transports change; production authentication
and shared synchronization helpers remain untouched. No readiness sleep or
scheduler-speed threshold is added.

Seven neighboring startup-position tests are explicitly marked unresolved in
`TestSupport/TestAudit/app.json`. They sample positions after startup begins
playing. Their initial-position forwarding coverage needs a true independent
clock/player or direct initial-seek oracle; replacing that observation with a
later seek would erase the oracle. Their source is unchanged, their prior audit
decisions are retained as history, and no observed failure of these seven tests
is claimed. This is a bounded neighbor review, not a repository-wide playback
clock reconciliation or closure of the category.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Final focused runs **4/4 function identities each, three independent runs**;
  helper contract has three enum cases, each with two control-order phases.
- Owning `AuthenticatedRequestTests`: **25/25** exact function identities.
- Post-mutation restored-source focus: **4/4**; full supported signed host gate:
  **598/598** exact inventory. All final runs have zero failures/errors/skips.
- Four separately retained mutations were killed: restoring each of the three
  old late-waiter retention paths fails the pending-ownership assertion without
  a continuation trap; omitting the rotating callers' completion observation
  fails the bounded completion assertion. Every mutation restores the exact
  final source hash before final verification.
- Strict Swift lint, documentation, source/audit scope and original postcondition
  preservation checks passed. Existing dependency deployment-target deprecation
  warnings remain; no warning suppression was added. The signed run retains
  three declared known issues in existing fixture-cleanup tests (two download
  cleanup cases and one operation-versus-cleanup-failure case), plus intentional
  read-only SwiftData failure diagnostics. Those fixture tests passed; these
  outputs are distinct from unexpected failures and the four negative mutations.

Focused command uses `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--disable-xctest --no-parallel --filter
'AuthenticatedRequestTests/(testTwentyUnauthorizedRequestsShareOne|testCoalescingTransportReleasesRegisteredAndLateCallersOnce)'
--xunit-output ...`. Final focus XML/logs use
`.build/i372-coalescing-final-focused-{1,2,3}`; owning uses
`i372-coalescing-final-owning`, restoration uses `i372-coalescing-restored`.
Signed command is `mise exec -- ./scripts/test-host.sh`; retained exact XML is
`.build/i372-coalescing-signed-results`. Verification manifest and separate
expected-failing mutation manifest are
`.build/i372-coalescing-verification.json` and
`.build/i372-coalescing-mutations.json`. Preliminary focused/owning passes are
retained separately and superseded by final postcondition/cleanup-reviewed source.

One function identity is added to inventory/source/core audit: host inventory is
598, source index 1,584 and core records 594 including the reviewed #408 parent.
This slice is stacked on #408 while its merge awaits authorization; it does not
advance `main`. Fresh exact-head CI and independent review remain required.
Broader #372/#362 acceptance and unrelated follow-ups remain open.

## Search caller completion and private fixture retirement (issue #372)

Seven remaining controlled `LibrarySearchCoordinatorTests` bounded registration
but still joined caller task values without a terminal observation; their failed
registration guards also cancelled then joined unconfirmed results. The default
zero-duration native-sleeper case directly awaited the coordinator without a
bounded terminal observation. These are test-lifecycle findings, not observed
production search defects.

All eight now observe actual coordinator return/throw with existing bounded
counters before consuming task values. Failed readiness or completion observations
return without unknown joins. Existing awaited `withTestCleanup` requests every
owned caller's cancellation, permanently retires the private sleeper and releases
service holds on normal, guard and throwing exits. Completion is produced after
the real API returns; cleanup never manufactures it. Cancellation/control release
does not prove whole production-task graph drainage.

The exact requested 300 ms debounce, zero pre-release calls, latest-query pending
count, first-query supersession, account/library call order, cooperative
cancellation count, cancellation-ignoring stale-result rejection and both typed
repository failure mappings remain. The default case still uses the actual
zero-duration sleeper. Positive blocked registration is added where an in-flight
repository hold is the scenario. Five-second caller failure budgets match the
existing registration bounds; they are not scheduler-speed assertions.

Private `SearchTestSleeper` now distinguishes final retirement from ordinary
resume between debounce generations and checks cancellation at entry/registration.
Private `SearchTestService` replaces its deliberate thirty-second cancellable hold
with a controlled checked continuation; its cancellation-ignoring latch is
preserved. All release/cancellation paths detach retained state before resuming.
Two new parameterized helper contracts each exercise four orderings: caller
cancellation versus fixture cleanup, before entry versus after positive
registration. They check actual typed outcomes, exact service cancellation counts,
empty terminal storage and safe repeated cleanup. Entry order is explicitly gated;
there is no readiness sleep or guessed yield count.

Only eight existing cases, two private fixtures, their result helper, two new
helper contracts and required inventory/audit/navigation/evidence change.
Production coordinator/authentication and the seven unresolved app-clock oracles
are untouched. Source-index/audit reconciliation is confined to this file; it is
not a broad tracker reconciliation.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused serial runs: **10/10 exact function identities each**;
  both new helper identities have four parameter cases each.
- Owning `LibrarySearchCoordinatorTests`: **12/12**; restored-source focus:
  **10/10**. Complete supported signed host gate: **600/600** exact inventory.
  Every final run has zero failures/errors/skips.
- Four expected-failing mutations were killed at required assertions: omitted
  caller terminal witness, omitted sleeper retirement guard, omitted early
  service-release latch, and omitted service cancellation delivery. Each has an
  executed failed test/result XML, bounded failure diagnostic and no continuation
  trap. The exact final source hash was restored after every attempt.
- Strict Swift lint, docs, all-original-postconditions, unchanged prior two helper
  contracts/cancellation-ignoring boundary and source/audit scope checks passed.
  Existing dependency deployment-target warnings, three declared fixture-cleanup
  known issues and intentional read-only SwiftData failure diagnostics remain
  separately documented; no warning suppression was added.

Focused commands use `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--disable-xctest --no-parallel --filter` selecting the eight cases and two new
helpers, XML/logs `.build/i372-search-caller-focused-{1,2,3}`. Owning selection is
`LibrarySearchCoordinatorTests`, reports `i372-search-caller-owning`; restored
selection uses `i372-search-caller-restored`. Signed command is
`mise exec -- ./scripts/test-host.sh`, retained XML in
`.build/i372-search-caller-signed-results`. Exact verification and negative
mutation manifests are `.build/i372-search-caller-verification.json` and
`.build/i372-search-caller-mutations.json`; raw logs remain private.

One preparation failure left a baseline-only ten-test run, and the first edited
build failed at two helper typing annotations without running new tests. Both
are retained and excluded from final coverage. The corrected preliminary owning
suite passed twelve identities and is separate from the final repetitions.
Two function identities are added: inventory **600**, source index **1,586** and
core audit **596**. Only the eight selected dispositions and changed-file source
locations are refreshed, plus two helper records. Fresh exact-head CI and
independent review are required before merge; broader #372/#362 acceptance,
production drainage and seven startup clock oracles remain open.

## Logout caller completion and private response latching (issue #372)

Four `LogoutTests` concurrency cases bounded transport entry but consumed caller
task values without a terminal bound. The refresh/logout case already bounded
actual typed outcomes with thirty-second completions; its entry and signing-out
observations needed guarded exits and cleanup on every path. Older descriptions
of unbounded entry signals and guessed yields were stale. These are test-lifecycle
findings, not observed production authentication defects.

These four cases now retain every original and overlap caller's actual return or
error in `Result`, emit a five-second terminal witness only after the coordinator
API returns or throws, and consume task values only after that witness. Existing
typed-error assertions remain. In both overlap tests, all four rejection probes
run in owned tasks and must return while the original transport gate stays held.
Normal execution independently asserts exactly one transport admission. Awaited
outer cleanup cancels every started original/probe, releases all fake arrivals,
bounds every actual terminal before joining and asserts zero pending storage.

All five cases guard readiness and use awaited `withTestCleanup` on normal,
guard and throwing exits. The refresh case retains its existing thirty-second
signing-out and outcome budgets. Cleanup never manufactures completion. This
bounds test-owned callers; it does not prove whole production-task graph drainage.

`BlockingLogoutTransport` and `BlockingLoginTransport` count admission before any
signal await, collect all pending continuations, and detach/resume every arrival
on latched release. Unexpected extra sends cannot overwrite the original waiter.
Late arrivals see the release latch. Their deliberate cancellation-ignoring
behavior remains: explicit fixture release must settle cancelled callers.

Private `InitialRequestRaceTransport` previously retained only a release Boolean.
An HTTP 200 release before continuation registration therefore delivered HTTP 401,
while release after registration delivered HTTP 200. It now latches the first
actual response, preserves it across conflicting repeated release and detaches
continuation storage before resume. The stale-success case independently asserts
that HTTP 200 was actually delivered after completed logout.

Three parameterized contracts cover eight initial-response scenarios (HTTP
200/401, early/registered release, cancelled/normal), twelve single-caller
logout/login/refresh scenarios and eight two-caller logout/login scenarios.
Explicit entry gates control early ordering; late release requires every expected
continuation to be registered. Every scenario bounds all actual returns and
checks exact response/cancellation state, repeated release and zero pending
storage. The two-caller contract also checks exactly two admissions. There are
no readiness sleeps or guessed yield counts.

Original overlap errors, invalid-credential failure, credential deletion,
rotated refresh token, one refresh/logout, zero forbidden refreshes and old-request
ordering remain. The six neighboring logout tests are byte-for-byte unchanged.
Scope is five existing dispositions, three helper records, private fixtures and
required inventory/navigation/traceability evidence. Production authentication,
separate cover work, broad tracker reconciliation, seven app startup clock
oracles and issue comments remain outside this slice.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three final independent serial focused runs: **8/8 exact function identities
  each**; owning `LogoutTests`: **14/14**; restored-source focus: **8/8**. All
  8/12/8 parameter scenarios execute in every run. Zero failures/errors/skips.
- Supported complete signed host gate: **603/603** exact inventory identities,
  zero failures/errors/skips, including synchronizable Keychain. Per-target and
  combined XML aliases reconcile without double counting.
- Eight expected-failing mutations are killed at executed assertions: missing
  actual caller terminal witness, early HTTP 200 becoming HTTP 401, repeated
  response overwrite, retained released continuation, and all four production
  overlap rejection paths (logout during logout/login, authenticated request
  during logout and duplicate login). Each rejection mutation has exactly one
  ordinary assertion failure and no cleanup failure, retained waiter diagnostic,
  hang or continuation trap. Production/test bytes are restored exactly after
  every attempt; production sources are unchanged in the final diff.
- Strict Swift lint, docs, original semantic postconditions, unchanged six
  neighboring tests and scoped audit/index checks pass. Existing dependency
  deployment warnings, three declared fixture-cleanup known issues and intentional
  read-only SwiftData diagnostics remain visible; no suppression is added.

Focused commands use `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--disable-xctest --no-parallel --filter` selecting the five cases and three
contracts; XML/logs are `.build/i413-overlap-focused-{1,2,3}`. Owning selection is
`LogoutTests` with `i413-overlap-owning` reports; restored selection uses
`i413-overlap-restored`. The signed command is
`mise exec -- ./scripts/test-host.sh`, retained XML in
`.build/i413-overlap-signed-results`. Verification/mutation manifests use
`.build/i413-overlap-verification.json` and
`.build/i413-overlap-mutations.json`; raw logs remain private.

Independent review rejected initial head `63dd249` because four inline overlap
probes remained unbounded and two private single-slot fakes could strand original
callers when rejection regressed. Its earlier 7/7 repetitions, 13/13 owner,
602/602 signed gate and green CI remain retained as superseded evidence, not
proof that the review finding was covered. Two initial compile-only typing
failures are excluded from coverage. Corrected preflight passed 14 identities.
Three new function identities bring host inventory to **603**, source index to
**1,589** and core audit to **599**. Fresh revised-head CI and independent
re-review are required; broader #372/#362 acceptance remains open.


## Refresh join admission and late-arrival provenance

`AuthenticatedRequestTests.testJoinerRecordsOriginatorRejectedTokenInCompletedRefresh`
previously created its joiner task and released the originator gates without
observing join admission. Main CI and the cover PR CI both reported a successful
joiner where the test expected `refreshRejected`. Caller-completion bounds did
not establish the earlier admission condition.

The coordinator now has an internal, optional, nonblocking native stream
observation immediately after capturing an existing attempt. Its value carries
only account and attempt identity, with no credential values. It adds no public
API, authentication decision, request, error translation or suspension point.
The observation is unset in ordinary operation. The test registers it before
starting callers and requires the matching attempt before releasing either
originator gate. Both original typed errors, originating rejected-token
provenance, cached original-token rejection and one-refresh assertion remain.

`testLateRecoveryAfterRejectedRefreshRetainsOriginatorProvenance` independently
drives the originator to completion and confirms attempt retirement before
starting the late caller. Both argument cases are required: matching provenance
uses the cached typed rejection; a different rejected token uses the newer store
value. Both retain the originating completed record and issue no new refresh or
HTTP retry. This keeps the late-arrival control separate from the admitted-join
contract.

File-private callers retain their exact API results, use the existing ten-second
completion failure budget, then drain owned tasks. Cleanup cancels callers, opens
all fake latches, removes the observation and finishes/drains its stream on
normal, throwing and early-return exits. Cancellation alone is never proof of
completion. Fresh in-memory state is constructed per test/argument; no sleeps or
guessed yields establish ordering. The inventory adds one identity, and the
scoped audit records all nine rules.

Validation on source commit `9ae4087a8a381ed07840475f4ed537b3a1158b43`:

- Three independent serial focused repetitions each passed **2/2 exact function
  identities** and all **three argument cases**, with zero failures/errors/skips.
  The initial focused pass is retained separately. The owning suite passed
  **26/26**.
- Complete unsigned host verification passed **603**, with one expected
  synchronizable-Keychain skip; complete signed host verification passed
  **604/604**, zero failures/errors/skips. Both XML inventories match exactly.
- Strict Swift lint and documentation validation passed. Aggregate formatting
  left the worktree unchanged. Changed Swift source hashes match the tested
  commit after the aggregate and focused repetitions.
- `mise run check` exited **1**. It completed site/documentation/schema checks,
  Rust checks/tests, telemetry integration, signed host tests, Swift Release and
  paid developer builds. Its app runner discovered **608** identities but
  executed **zero** app tests: the isolated Simulator failed to launch Bleat,
  with SpringBoard `Busy / Application failed preflight checks`. The result
  bundle records one runner failure. No rerun or global Simulator cleanup was
  performed; core live, app live and subsequent UI execution were not reached.
- The aggregate dependency audit also reported a registry timeout while checking
  yanked crates, despite its task finishing successfully. That check is
  **unverified**, not a clean security result. Existing dependency deployment,
  Swift Testing macro and SDK build-version warnings, three declared fixture
  cleanup known issues and intentional read-only SwiftData diagnostics remain
  visible; no suppression was added.

Focused artifacts use `.build/auth-join-repeat-{1,2,3}.{xml,log}`; owning evidence
uses `.build/auth-join-owning.{xml,log}`. Preserved complete host XML is in
`.build/auth-join-unsigned-results` and `.build/auth-join-signed-results`.
Aggregate log, failed app summary and exact source/inventory verification are
`.build/auth-join-aggregate.log`,
`.build/auth-join-aggregate-app-summary.json` and
`.build/auth-join-verification.json`. Raw artifacts remain local.

This change remains local, with no push, new PR, issue comment, merge or CI
acceptance claim. Final evidence-only documentation changes preserve the tested
Swift bytes. Simulator launch and dependency registry verification remain open;
broader #362/#372 and framework/device acceptance remain separate.

## OpenID caller outcomes and private fixture retirement (issue #372)

Two active-session/concurrent-attempt tests used `async let` for their original
calls and awaited competing rejection probes inline. A missing callback could
therefore hang either the direct probe, the final original outcome, or implicit
structured-child cleanup after a failed readiness guard. Entry signals were
already bounded; their older unbounded/yield descriptions were stale.

Both original and rejection callers now own actual `Result` tasks and independent
five-second terminal counters emitted only after the real browser/coordinator API
returns or throws. Rejection must complete while the original browser remains
held. Readiness and positive registration are guarded; task values are consumed
only after a terminal witness. Awaited `withTestCleanup` cancels every started
handle, retires fixture state on normal/guard/throwing exits, and bounds actual
completion before joins. Failed observations never join unknown results.

Private `OpenIDWebSessionFactory` retains retirement before late session creation;
each session also retains it before `start()`. Retirement delivers the existing
typed cancellation callback to every waiting session. Admission is recorded in
the session array before start/signal delivery. `OpenIDBrowserGate` records entry
before awaiting its signal, collects all continuation waiters, latches its first
failure before detaching/resuming every waiter, and preserves that failure across
repeated conflicting release and late calls. No production cancellation or
browser lifecycle contract changes.

Two new four-scenario contracts cross retirement before entry/after both positive
registrations and cancellation/normal caller state. Each owns two simultaneous
browser calls and a third late call, bounds their actual typed `.cancelled`
outcomes, repeats retirement and checks three admissions plus zero pending
fixture state. Task cancellation is a separate stimulus; explicit fixture
retirement supplies cancellation callbacks. Cancellation alone is not claimed
to terminate native browser work.

Completed fake web-session objects remain retained for synthetic late callback
delivery. Conflicting callbacks are delivered only after actual native API
completion, without assuming main-actor Task FIFO ordering. This does not prove
those internal callback Tasks have exited. The gate's conflicting first-failure
behavior is independently checked through a fresh late caller. Test-owned caller
return and zero pending fixture state do not establish whole AppAuth/native or
private-worker/timeout-observer drainage. Those stronger per-owner lifecycle
requirements remain for a separately scoped design; existing async lifecycle
boundaries should be used where they already expose the needed completion.

Original typed `.alreadyActive`, `.cancelled`, `.attemptAlreadyInProgress` and
`.browserCancelled` assertions remain, as do two cookie clears, one request and
nil coordinator attempt. Added exact admission/pending counts establish that the
original flow remains held through the rejection. All seventeen neighboring test
bodies are unchanged, including three real off-main callback-adapter variants
and completion/refusal-start behavior. The already-bounded off-main adapter's
stale audit label is not an implementation finding fixed by this slice.

Validation on m2 (macOS 26.6.2, Xcode 27.1 / 27A9275):

- Three independent focused serial runs: **4/4 exact function identities each**;
  both helper identities execute all four parameter scenarios. Owning
  `OpenIDAuthenticationTests`: **21/21**; restored focus: **4/4**. Zero
  failures/errors/skips in every final run.
- Complete supported signed host gate: **605/605** exact inventory identities,
  zero failures/errors/skips, including synchronizable Keychain. Combined and
  per-target XML aliases reconcile without double counting.
- Six expected-failing mutations are killed at required executed observations:
  omitted original/probe terminal witnesses, omitted factory/gate retirement
  latches and both production overlap rejection guards. No hang or continuation
  trap; production/test bytes are restored exactly after each attempt.
- Strict Swift lint, docs, all original semantic postconditions, seventeen
  unchanged neighboring tests, source/audit scope and production-byte checks pass.
  Existing dependency deployment warnings, three declared fixture-cleanup known
  issues and intentional read-only SwiftData diagnostics remain visible.

Focused commands use `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test
--disable-xctest --no-parallel --filter` selecting the two original and two helper
identities; reports use `.build/i415-compat-focused-{1,2,3}`. Owning selection is
`OpenIDAuthenticationTests`, reports `i415-compat-owning`; restored focus uses
`i415-compat-restored`. Signed command is `mise exec -- ./scripts/test-host.sh`,
retained XML `.build/i415-compat-signed-results`. Exact verification/mutation
manifests are `.build/i415-compat-verification.json` and
`.build/i415-compat-mutations.json`; raw logs remain private.

Two preliminary compile-only attempts failed at main-actor/global assertion
closure isolation without running tests; the corrected preliminary owner passed
21 identities separately from final repetitions. Two added function identities
bring host inventory to **605**, source index to **1,591** and core audit to
**601**. Only the two selected dispositions, two helper records and changed-file
navigation/inventory/evidence change. Fresh exact-head CI and independent review
are required. Broader #372/#362 acceptance, whole private-worker/timeout-observer
drainage, seven app startup clock oracles and separate cover work remain open.


### Swift 6.3.3 task-capture compatibility correction

Published head `2f03cca` passed local Swift 6.4 / Xcode 27.1 validation but failed
CI host compilation under Swift 6.3.3 / Xcode 26.6 (`17F113`): the region-based
isolation checker could not check the new `firstAttempt = Task` pattern. No Swift
host tests ran and no host XML artifact was produced. This is retained failure
evidence, not a passing unsigned lane.

The corrected concurrent-attempt test snapshots the same immutable `Sendable`
callback URL before either task, rather than accessing dynamic `Self` metadata
inside nested sending closures. Both tasks now have explicit result types and
capture lists of their immutable values/actors. They retain inherited task
isolation/context; no detached task, reduced isolation checking, changed CI
compiler, new timeout or assertion change is introduced. Production bytes and
all seventeen neighboring test bodies remain unchanged. Host inventory/discovery
identities remain 605/21; only changed-file navigation and the corrected record
are refreshed.

The revised m2 lane uses the same full focus/repetition/owner/signed/restored and
six-mutation checks above, with `i415-compat-` artifact names. The local machine
has only Xcode 27.1 / Swift 6.4; Swift 6.3.3 is unavailable locally, so its result
must come from fresh exact-head CI. Initial `i372-openid-` local evidence remains
tied to the earlier source hash and is not substituted for compatibility proof.

The same earlier CI run also recorded an unchanged app failure in
`testTranscriptDeletionPreservesDownloadAndActivePlayback`: current position
0.519404209 differed from the pre-deletion 0.5 snapshot beyond 0.01. Its bundle
reports 609 passes, one failure and zero skips. That test calls `pause()` then
immediately captures the model's position before awaited transcript operations;
it does not establish a settled pause/seek observation. This is a separate timing
hypothesis, not proof transcript deletion moves playback. That OpenID-only correction made no app-test or
production playback edit. The separately authorized correction below confirms
paused state/native rate zero, awaits an explicit paused seek, then captures the
baseline and retain every original deletion/download/account/item/position
postcondition and the same tolerance. Such a seek establishes a deletion
invariant, not initial-position forwarding; independent startup oracles remain
required. Neither a source correction nor a later passing run erases this
recorded failure. Full CI must not be described as green while any failure
remains.

## Transcript deletion playback-position stability correction

CI run `39387568129` at `2f03cca` recorded one unchanged app failure:
`testTranscriptDeletionPreservesDownloadAndActivePlayback` sampled
0.519404209 after transcript deletion against a pre-deletion 0.5 snapshot, with
its unchanged 0.01 tolerance. Calling `pause()` alone did not establish a
completed position-observation boundary before that immediate snapshot. The
failure remains retained; it is not evidence that transcript deletion itself
moves playback. No other task or open PR owned this test when the correction
started.

The existing test now bounds and asserts paused state/native rate zero with the
existing diagnostic waiter, guards a changed observation with an explicit failure
and awaited stop, then awaits the existing async seek to 0.5. It asserts paused
state, zero rate, no playing intent and the completed seek result before capturing
the baseline. Both new guard exits stop playback before deferred fixture removal.
All original started/deleted/active-book/account/item/position/download-record
assertions remain, with the same 0.01 precision. After those paused invariants,
the test resumes playback and bounds actual playing state, requested intent,
positive native rate and playing time-control status before stopping. Active
playback coverage therefore includes real resumability after deletion, rather
than only a retained model flag. No numeric position is asserted while that
resumed clock advances.

The explicit seek establishes a deletion-preservation invariant. It is not proof
of initial-position forwarding. All seven separately recorded startup oracles,
every other test body, production playback/authentication and test identities
remain unchanged. Only this app audit disposition and the changed method's navigation
are refreshed; no broad tracker reconciliation or new test is claimed.

Validation uses the supported `scripts/xctest.sh` discovery/result gate on an
owned iPhone 17 Pro Simulator running iOS 26.5, with Xcode 27.1 / Swift 6.4:

- Final source passes three independent focused runs, **1/1 each**, the owning
  `AppModelTests` suite **505/505**, and restored-source focus **1/1**. Every run
  has zero failures, expected failures, skips or structured runtime warnings,
  and the canonical runner verifies exact built discovery.
- One expected-failing mutation performs a completed seek to 0.75 after deletion.
  The original position-preservation assertion rejects 0.75 versus the 0.5
  baseline using the unchanged tolerance. The outcome is an ordinary single
  test failure, not a compile failure, hang or crash. Exact final source bytes
  are restored before the final focused run.
- After integrating already-merged #414 (`d9c7dcc`), the signed host gate passes
  **606/606** exact identities with zero failures/errors/skips. The OpenID
  source hash remains the independently repeated/six-mutation-checked capture
  correction. CI `39392756147` at intermediate head `80c722e` separately confirms
  Swift 6.3.3 / Xcode 26.6 compilation and execution: **605 passes plus only the
  documented unsigned Keychain skip**, including both affected original cases
  and both four-scenario contracts. That head does not include this app fix and
  is not final-head CI evidence.
- Strict Swift lint/docs, preservation of every original assertion and all other
  app test bodies, unchanged startup-oracle records, and single-disposition/targeted
  method navigation scope are verified. Raw Xcode SDK build-version parser
  diagnostics remain in local logs; structured runtime-warning arrays are empty.
  Existing host dependency warnings, three declared fixture-cleanup known issues
  and intentional read-only SwiftData diagnostics remain separate.

A preliminary source passed a focused preflight, three repetitions and the owner
suite before adding the explicit diagnostic to a guard exit. Those bundles are
retained separately; final-source results use `i415-transcript-final-` prefixes.
The final command selects
`BleatAppTests/AppModelTests/testTranscriptDeletionPreservesDownloadAndActivePlayback`
(or owning `BleatAppTests/AppModelTests`) with `mise exec -- ./scripts/xctest.sh
-s Bleat -d <owned Simulator destination> -t <selector> -r <result bundle>`.
Final bundles/logs use `.build/i415-transcript-final-{focused-1,focused-2,focused-3,owning}`;
the restored bundle uses `.build/i415-transcript-restored.xcresult`. Mutation
artifacts use `.build/i415-transcript-position-mutation`, and verification is
`.build/i415-transcript-verification.json`. Integrated signed XML is retained in
`.build/i415-integrated-signed-results`. The owned Simulator is separate from the
existing cover/auth-join/user devices; no global reset or process termination is
used. Final-head CI and independent review are still required before any merge.

## Concurrent export caller cleanup on failure (issue #372)

At `f8237eedd5d023d292d71bc8a3c947d2f7119c95`, the eight-caller OTLP test
observed and joined every caller on success. Its throwing exit cancelled those
callers, requested exporter cancellation and released the token provider, but
returned without observing their completion. This is a test ownership gap;
no production leak was observed.

A private retirement helper keeps that cancellation/release order, then uses
each caller's existing ten-second completion observation before consuming its
task value. The completion is the caller's actual export result, signalled
immediately before that task returns. Missing completion records the caller
index and source location, skips the unconfirmed join, and continues observing
the other callers. The original success operation block is byte-identical:
eight positive admission/return observations, all eight success assertions,
one refresh, eight client exports and exact bearer metadata remain. The
original exporter timeout and all 23 neighboring test bodies remain unchanged.

One new parameterized test covers two controlled operation failures:

- `beforeEntry` holds all caller entry behind a latched signal, throws the typed
  fixture error, and lets cleanup cancel and release even late arrivals.
- `afterAllEntries` first positively observes all eight registered provider
  continuations, asserts that pending count, then throws the same error.

Both cases require the original typed error, eight false caller results,
zero pending provider continuations and zero RPCs after cleanup. Repeating
retirement must preserve those results and empty provider state. Only the new
failure fixture uses a thirty-second exporter timeout, longer than the existing
ten-second admission observation; the original success fixture is unchanged.
There is no readiness sleep, retry, process-global capture or production change.
Observing these eight caller tasks does not establish complete drainage of the
exporter's internal workers, timer observers or unrelated #372 owners.

The retained baseline extracts the old cancel/release actions into the new
private helper without completion consumption. Both controlled arguments fail
`completed.count == 8`, reporting zero consumed callers: one native function,
two failed argument cases, two issues. This is not an untouched-base execution.
The initial compile failed before tests because the new test method needed
private visibility for its private argument type; that log remains separate.

Final source validation on m2 verified 25/25 owning function identities and
three focused runs with 6/6 function executions and 9/9 scenarios. Both failure
arguments and the original success identity passed each repetition. The complete
required-signing host gate verified 607/607 unique identities, zero failures or
skips, including the synchronizable-Keychain case. XML aliases are not added.
Three declared cleanup known issues remain matched. Eight intentional read-only
SwiftData save diagnostics occurred in the same three passing negative tests:
transcript/checkpoint rollback, pending-state retry preservation, and failed
history save. The upstream OpenTelemetry watchOS-minimum deprecation remains;
the optional-require ambiguity is absent. Strict Swift lint, documentation and
diff checks passed. Source hashes bind these executions to the committed source;
no fresh post-commit local executions are implied.

Commands and private artifacts:

- Owning suite: `mise exec -- env BLEAT_HOST_SIGNING=unsigned swift test --disable-xctest --no-parallel --filter AuthenticatedOtlpSpanExporterTests --xunit-output .build/i372-caller-owning.xml`.
- Three focused executions use the same native runner with
  `--filter AuthenticatedOtlpSpanExporterTests.testConcurrentExport` and distinct
  `.build/i372-caller-focused-1.xml` through `-3.xml` reports. Both parameter
  values must appear and the original success identity must pass each time.
- Required-signing host: `mise exec -- ./scripts/test-host.sh`, with the log
  `.build/i372-caller-signed-host.log` and canonical inventory/XML verification.
- Baseline, source reconstruction, scoped audit changes and final outcomes are
  retained in `.build/i372-caller-verification.json` and its linked artifacts.
  Raw machine/signing logs remain private. Exact-head independent review and
  CI are separate gates. Broader #362/#369/#372 acceptance remains open.

Only the relevant existing core disposition receives a current annotation;
the new test has an individual nine-rule audit and host inventory entry. Eight
following navigation entries move seven lines and retain both prior histories;
they are not eight semantic findings. All unrelated audit/index rows and the
historical declared baseline counts are preserved.


## CloudKit cancellation caller completion (#372)

This bounded review starts from `82875e205a99987893013c3a6aaafbe0a179b700`.
It covers exactly three existing `PrivateCloudSyncTests` identities:

- `testCallbackCancellationEscapesDelegateTaskLocalsAndRunsOnce`
- `testCallbackCancellationCompletesBeforeLifecycleAllowsRetry`
- `testCallbackWatchdogCancellationEscapesDelegateTaskLocals`

The probe entry notification and latched early release were already delivered.
Current source still awaited final cancellation directly in two tests and joined
an unbounded lifecycle caller in the third. This is a test failure-diagnostic gap,
not a demonstrated production CloudKit defect. Each caller now signals only after
its actual awaited cancellation API sequence returns; the lifecycle sequence also
finishes/completes the run before signalling. Five-second observations precede
all task-value joins. The budget diagnoses a missing phase rather than imposing
a product execution-speed requirement. Inline test assertions retain phase,
elapsed time and timeout at the caller.

Awaited cleanup cancels only owned callers, releases the existing latched probe,
and observes return within the same bounded budget on normal, guard and throwing
exits. The watchdog callback is ended on every exit. An unconfirmed task is never
joined after timeout; cancellation does not prove an uncooperative operation or
whole production watchdog/task graph terminated. Original exact coalesced call
count, escaped task-local context, typed `callbackTimedOut`, held `.stopping` and
post-release retry assertions remain. Production and shared helper bytes are
unchanged. These are synthetic host state-machine tests, with no personal
CloudKit account, device, network, persistence or playback operation.

The three audit rows receive scoped current dispositions; their historical
follow-up decisions and timing receipts remain. No declaration or inventory count
changes, broader queue subtraction, or #372/#362 completion is claimed.

Final local validation on Xcode 27.1 / macOS passed all three exact identities
in three independent focused executions, all 54 owning `PrivateCloudSyncTests`,
and all 609 exact signed-host identities. There were zero failures/errors/skips
in those final runs; the signed inventory verifier and coverage export exited 0.
Results and per-command disk-guard receipts are retained under
`.build/cloud-cancellation-*`, with signed XML in `.build/host-results/tests.xml`.
The guard retained its 3 GiB floor; the signed run used 14.48 GiB free before and
14.14 GiB afterward. Strict changed-file Swift formatting, scoped audit/index
parity (609 host / 46 Rust functions), documentation references and diff checks
passed. Those structural checks do not certify whole-repository semantics.

A controlled test-only negative witness withheld the lifecycle probe release:
its exact selected identity failed the intended terminal assertion at the test
caller after 5.30 seconds, with one issue and nonzero exit. Cleanup then released
the latched probe and returned without a second cleanup failure. The final test
source was restored byte-for-byte before owning/signed validation. This is a
witness for missing completion observation, not a production fault injection or
proof that arbitrary stuck operations terminate.

Independent review of all five changed files found no actionable findings and
cleared publication after local evidence verification; published-head CI remains
a separate gate. The first command spelling for formatting could not locate
`swift-format`; the supported `xcrun swift-format` invocation succeeded. The
initial native build failed before executing tests because a cleanup closure
erased inferred catch typing. An explicit `PrivateCloudSyncError` catch preserves
the original `.stopping` assertion; that compile-only attempt is retained, not
counted as coverage. Existing upstream watchOS deprecation, native toolchain and
intentional storage/cleanup-fixture diagnostics remain in the raw logs; no broad
warning-free or physical CloudKit acceptance claim is made.


## OpenID browser failure helper-context review (#372)

This slice starts from main `f564e367912c644444f8962bca78a8f0e1466d88`.
It rechecks exactly four members of the historical 241-record core
helper-context snapshot at `58223214`. None had a later per-record current
annotation; the delivered OpenID caller-lifecycle changes covered different
bodies. The historical queue is a review snapshot, not 241 present defects.

| Stable record | Existing test | Current disposition |
| --- | --- | --- |
| AUD-C-f87b4159e6a7 | `testSystemBrowserFactoryMapsProviderCompletions` | Keep: three synchronous success/cancel/failure mapping cases and actual native session construction. Anchor/browser construction does not assert anchor delivery or provider presentation. |
| AUD-C-7eed9f01bd1b | `testSystemBrowserSessionMapsCancellationAndFailure` | Keep: four immediate completion/refused-start behaviors preserve exact typed error results, including callback-then-refused-start. No held session is used. |
| AUD-C-78c4d96ca21d | `testBrowserCancellationAndFailureCleanUp` | Keep after one subcase assertion fix: four typed failures already checked cleanup; the existing unexpected-error subcase now retains its credential actor and also checks two clears, no cookie session and zero saves. Exact error mapping remains. |
| AUD-C-48b9ad8348a7 | `testExchangeFailuresNeverPersistAndAlwaysCleanUp` | Keep: six exchange status/JSON/token failures retain exact typed errors, two clears and zero saves. |

Reviewed dependencies are the locked completion recorder, native completion mapper
and factory, MainActor fake session factory, immediate `OpenIDTestBrowser`, actor
`OpenIDTestTransport`/`OpenIDCredentialStore`, and source-located
`assertThrowsErrorAsync`. The fake transport's clear operation resets its cookie
flag before returning. Inputs and actor state are fresh per case; no network,
personal browser session, Keychain or durable account data is involved. No
`.wait` browser gate, cancellation-ignoring operation or detached test caller is
introduced. The factory's start-notification tasks do not establish complete
internal task drainage. Current annotations narrow the old generic helper and
anchor claims while preserving every historical field and receipt.

The measured slice is four records reviewed: three no-change conclusions and one
missing cleanup-oracle fix. There are zero unresolved records within this selected
scope after delivery. This does not recalculate the global remaining review
count: the other historical members may have later evidence and must not be
called current defects or blindly subtracted. #455 separately rechecked three
CloudKit records, only one of which belongs to that original helper-context
subset; its other two were historical follow-ups. The two slices therefore
identify five distinct reviewed subset members, not seven queue removals.

On Xcode 27.1 / macOS, all four exact selected identities passed in three
independent fixed runs. The owning OpenID suite passed 21/21 and the complete
signed host gate passed all 609 unique inventory identities with zero skips;
the four selected identities were present and passed. Logs, exact identity
verification and execution receipts are retained under
`.build/openid-browser-review-*`, with signed XML in `.build/host-results/tests.xml`.
The 3 GiB active guard remained enabled; the signed run used 11.85 GiB free before
and 11.76 GiB afterward. Strict changed-file Swift formatting, audit/index parity
(609 host / 46 scoped Rust functions), documentation and diff checks passed.
Existing upstream/native toolchain and deliberate storage/cleanup-fixture
diagnostics remain retained; no broad warning-free claim is added.

The controlled negative witness temporarily isolated only the existing unexpected
browser-error subcase and made its actor fake ignore the post-failure second
clear. With that identical fake fault, the prior error-only oracle passed one
selected identity; the improved oracle failed one identity with exactly two
issues at the caller (clear count 1 instead of 2, and retained cookie state).
This checks the cleanup oracle, not a production cookie leak, actual browser
presentation or a passing whole-case matrix. Normal runs separately cover the
zero-save assertion. All temporary case isolation and fake edits were restored
byte-for-byte before repeated/owning/signed validation; production source was
never modified. Independent source and full-diff reviews found no actionable
issues, and local exact outcomes were verified before publication. Published-head
CI is a separate gate. This changes no shared helper, declares no new test, and
closes neither #372 nor #362.


## Router helper-context and six-purpose stream review (#372)

This bounded slice starts from main `d2c4f85f0224b72eb34a49d8b791c23d730ab21e`. It rechecks
12 unchanged router records from the historical 241-record helper-context
snapshot and strengthens one separate existing stream test. These are 12
justified no-change conclusions and one explicit assertion-coverage gap, not
13 production bugs. No production source or shared helper changes.

| Stable record | Existing test | Current disposition |
| --- | --- | --- |
| `AUD-C-48ba1e7cc272` | `testEndpointRouterUsesLocalServerAndPreservesPathPrefix` | Keep: Exact candidate order, local marker and prefix rewrite. |
| `AUD-C-11015166c55a` | `testEndpointRouterSkipsFailedLocalServerUntilRevalidated` | Keep: Unavailable local leaves the exact primary candidate. |
| `AUD-C-57127d923054` | `testFailedLocalSyncStaysOnPrimaryUntilSuccessfulProbe` | Keep: Both prefix arguments preserve exact request/destination/body/auth counts, stale-success rejection and controlled probe recovery. |
| `AUD-C-3017c6e05cc8` | `testEndpointRouterUsesPrimaryUntilLocalIsRevalidatedAfterPathChange` | Keep: Failed, unknown and matching-generation validated selections remain explicit. |
| `AUD-C-f25967d01929` | `testRouteConfiguredDuringPathEvaluationRemainsPrimaryUntilValidated` | Keep: Configuration during evaluation retains primary until validation. |
| `AUD-C-1b5a0c5d8b4f` | `testPreChangeLocalSuccessCannotCompleteCurrentPathEvaluation` | Keep: Old candidate success cannot clear current unknown/primary state. |
| `AUD-C-2b9d7df9fc09` | `testURLOnlyCompletionCannotMutateCurrentPathSelection` | Keep: Generation-less completion preserves validated selection/availability; this does not assert activity suppression. |
| `AUD-C-c1592a648e2e` | `testUnresolvedPathEvaluationLeavesLocalTemporarilyUnavailable` | Keep: Unresolved evaluation finishes on primary with temporarily-unavailable local state. |
| `AUD-C-4c12eaefd8b1` | `testEndpointRouterBuildsPrimaryFallbackFromResolvedLocalURL` | Keep: Exact rewritten URL, primary identity and non-local flag. |
| `AUD-C-236184fd37ae` | `testPrimaryFallbackRequestPreservesAuthenticationAndNetworkPolicy` | Keep: Exact URL, GET/auth and constrained/expensive-network flags. |
| `AUD-C-01c113f50339` | `testSuccessfulProbeRestoresFailedLocalServer` | Keep: Matching successful probe restores local selection. |
| `AUD-C-55493a7ad63f` | `testEndpointRouterTracksAPIAndAuthenticationUsageSeparately` | Keep: Local API and primary authentication remain independent. |
| `AUD-C-ca5591e818c7` | `testEndpointRouterStreamsEveryServerConnectionPurpose` | Keep after coverage correction: All six typed purposes publish checked snapshots; added API/authentication/cover/download cases preserve existing playback/WebSocket assertions and accumulated dedicated fields. |

Each router is fresh and its state transitions are awaited. Eleven unchanged
cases are direct actor-state checks. The parameterized sync case executes both
root and prefixed paths using real URLSession calls handled by the immediate,
locked URLProtocol fixture in a serialized suite; its handler is reset with
`defer`. It retains exact request counts, method/auth fields, structurally
decoded body and availability/probe assertions. These fixtures do not establish
live-server or physical-network behavior. No held caller or cancellation-ignoring
fake is introduced, and no complete framework-session drainage is claimed.

The existing stream test previously covered only playback and WebSocket. The
specification's Diagnostics contract requires publication for all six purposes.
Four typed cases now also assert API, authentication, cover and download
snapshots, including exact latest usage/purpose and preservation of dedicated
API/authentication/WebSocket state. Initial/playback/WebSocket assertions remain
unchanged. Every added read uses the existing five-second bounded reader and
stage/caller-located failure helper. The reader joins its timeout/read children;
this does not prove completion of the router's asynchronous observer-removal
callback. No sleeps, retries or observer-drain machinery are added. This is
router publication coverage, not evidence that the four real asset/request
adapters or physical connections were exercised.

Playback timing/seek tolerances are inapplicable to these state/event cases.
Setup uses independent local actors and synthetic HTTPS values; postconditions
are typed and immediate or use the existing bounded event wait. Original audit
fields and receipts remain historical; `routerReview20261023` explicitly records
the current per-record disposition, including superseding the stream's old
unbounded-read finding that the earlier timing batch already addressed.

The 12 unchanged cases are distinct from the five historical-cohort members
identified by #455/#456, yielding 17 named cohort members with those three
slices' evidence. The stream case is outside that cohort. This does not recalculate
the whole remaining queue or turn unmatched historical records into defects.
No declarations are added/renamed; audit/index identities and historical global
counts remain unchanged. #372/#374/#362 remain open.

On Xcode 27.1 / macOS, the changed stream identity passed in three fixed,
independent Swift Testing runs. The owning HTTP transport suite passed all
**19 function identities**, including both root and `/audiobookshelf` arguments
of the sync-recovery case. The complete signed host gate passed **609 unique
inventory identities with zero skips**; all 13 selected identities were present
and passed. Native XML, built-in inventory verification, exact selected identities
and source hashes were inspected. The final Swift SHA-256 remained
`0634493393c56b561f637b4ffc6ec6d3fed5811773180f48ed4dfd6014883dd6`
through focused, owning and signed runs. These successful executions have no
test failures; the host log retains four deliberate cleanup-fixture known issues
and existing upstream/toolchain/storage-fixture diagnostics. No broad
warning-free claim is made.

The first signed attempt executed zero tests: the cached generated host runner
failed `codesign --verify --strict` with a missing-resource-envelope error.
Direct verification reproduced that error. Its 1.8 MiB owned derived output was
retained under `.build/router-purpose-failed-host-runner-derived`; the supported
gate then rebuilt that runner at its original path and verified signature,
Keychain entitlement and provisioning-profile presence before the passing run.
No signer/account/security settings, production source or other caches changed.
This is a distinct pre-test infrastructure failure, not a failed 609-test run
or a passing signature check by omission.

Retained evidence is `.build/router-purpose-focused-{1,2,3}.{log,xml}`,
`.build/router-purpose-owning.{log,xml}`, both signed-attempt logs and execution
receipts, `.build/router-purpose-signed-host-tests.xml` and corresponding
`*-verified.json` records. The 3 GiB active disk guard stayed enabled; the clean
signed run used 12.08 GiB before and 11.98 GiB after. Strict changed-file Swift
lint, documentation, scoped audit/index parity (609 host / 46 Rust functions)
and diff checks passed. Independent full three-file review found no actionable
issues and revalidated the 12 no-change conclusions. Published-head CI remains
a separate gate. Existing traceability names are unchanged; this slice adds no
product behavior or physical acceptance evidence.

## Account store and default OpenID context review (#372)

At source `32bfe60226290c4cd9a784b9d9fa6b65e1f9b148`, the fixed historical cohorts reconcile by exact identity to 45 completed scoped reviews and 267 pending decisions (196 core, 71 app). Earlier merged evidence, including #455/#456/#459, is credited by identity rather than blindly subtracting recent PR counts. The [versioned ledger](../../TestSupport/TestAudit/review-queue-reconciliation.json) retains all 312 identities and evidence boundaries. Nine cleanup-only core notes and three narrow app findings do not certify full rechecks. Neither accepted runtime/device evidence nor the previously fixed #387 corruption/duplicate-onboarding cases is reopened.

This slice completes 17 pending decisions: all 16 AccountStore members of the historical cohort and the final default-configuration HTTPTransport member. Independent source review found no actionable test or production defect. All are **keep, no code change**. The remaining fixed-cohort review count is **179 core + 71 app = 250**; these are review candidates, not 250 bugs or implementation tasks.

| Stable record | Existing test | Scoped conclusion |
| --- | --- | --- |
| `AUD-C-c5fe015b40e3` | `testStoresMultipleUsersAndServersWithOneActiveContext` | Exact identities, active selection/snapshot, removal and re-addition state; reconstructed actor shares the in-memory container. |
| `AUD-C-1dc60179dabf` | `testRejectsDuplicateRemoteUserOnSameNormalizedServer` | Typed duplicate rejection after normalized server matching preserves the exact existing account. |
| `AUD-C-9d22308aa1ca` | `testConnectionStateAndActiveSelectionPersistAcrossStoreActors` | Reauthentication state and selected identity survive reconstruction of a store actor over the same in-memory container. |
| `AUD-C-702ca0822f7e` | `testLegacyIdentityMigrationRekeysAccountAndStatistics` | Legacy identity is removed; canonical account, statistics account ID and alias are checked. |
| `AUD-C-1d3b4961b1f2` | `testPendingRestoredAccountSurvivesRelaunchInactive` | Pending restoration remains inactive across store actor reconstruction over the same in-memory container. |
| `AUD-C-d41ba54cfad5` | `testContradictoryAliasIsTypedAndPreservesOriginal` | Typed contradictory-alias failure preserves the original canonical alias mapping. |
| `AUD-C-751894e965e5` | `testLocalServerPersistsWithoutChangingPrimaryIdentity` | Local-server configuration is returned without changing primary identity. |
| `AUD-C-cf716d4447e3` | `testReplacingPrimaryServerRekeysExistingAccountData` | Primary-server replacement checks new canonical identity, old absence and active selection. |
| `AUD-C-529f3734caf7` | `testRemovingActiveAccountSelectsDeterministicReplacement` | Active-account removal selects the deterministic replacement, preserves exact survivors and returns false for repeated removal. |
| `AUD-C-8186b6d8e60e` | `testMissingAccountOperationsRemainTyped` | Missing-account operations preserve typed accountNotFound errors and absent account/active state. |
| `AUD-C-c70121a484c2` | `testServerAccountValidationAndCodableExcludeCredentials` | Valid account Codable round-trip, credential-field/marker exclusions, invalid identity/schema errors and OpenID capability flags; no real token-store privacy claim. |
| `AUD-C-be639693d5e4` | `testLoginPersistsAccountAndCredentialsTransactionally` | Login returns canonical identity, stores the active account and exact synthetic credentials, with zero deletions; failure rollback is a separate previously fixed test. |
| `AUD-C-f4b5abe85518` | `testOnboardingRejectsNonLocalServerBeforeTransport` | Non-local onboarding returns the typed unavailable outcome before any transport call and leaves no account. |
| `AUD-C-ed66e20b6514` | `testOnboardingReportsCredentialRollbackFailure` | Credential rollback failure preserves its typed cause, remaining synthetic credentials and the exact original account. |
| `AUD-C-654ca95d156e` | `testPersistedSignOutAndRemovalUseStoredServerAndClearCredentials` | Sign-out/removal exercise the stored-account coordinator path and assert remote status, reauthentication, credential removal, logout token values and account removal. No explicit logout-host/prefix oracle is claimed. |
| `AUD-C-28592b4c6004` | `testPersistedLifecycleRejectsUnknownAccountBeforeLogout` | Unknown-account sign-out returns the typed missing-account outcome before transport; this case does not exercise the removal branch. |
| `AUD-C-996b8e3c1d6b` | `testOpenIDTransportDefaultConfigurationIsInitiallyEmpty` | Fresh default ephemeral OpenID transport has zero cookies before and after awaited empty clearing. No request, nonempty clear, browser or provider termination is exercised. |

The complete current-schema `StoreFixture` owns a fresh in-memory ModelContainer. Reconstructed actors share that container: the relaunch-named cases do not establish filesystem durability or app-process relaunch. Immediate actor transport/credential fakes retain synthetic local values; they do not establish live HTTPS, Keychain atomicity or a complete network-session shutdown contract. Store/coordinator calls are awaited, with no held child, callback, timer or observer requiring new cancellation machinery. OpenID default configuration sends no request and checks only initially empty cookie state and empty clearing.

Rules 1–2 cover exact typed/state postconditions and awaited operations; rule 3 playback/time tolerance is inapplicable. Rules 4–6 cover scoped ownership, independent fixture state and the framework/fake boundaries above. Rules 7–8 require no retry, tolerance or timing change and retain caller-located assertions; there is no timed observation to diagnose. Rule 9 execution evidence is recorded below. Original audit fields, findings and receipts remain revision-bound; the new `accountContextReview20261023` fields contain the current scoped decisions. No Swift, production source, helper, manifest, resource, entitlement, inventory or source-index identity changes.

Fresh unsigned host validation on Xcode 27.1/macOS ran the fixed selection `AccountStoreTests|testOpenIDTransportDefaultConfigurationIsInitiallyEmpty` three times: **19 exact function identities passed in each**, zero failures/skips. The selection includes the two already-fixed AccountStore cases for regression coverage; only 17 new review dispositions are counted. The two owning suites (`AccountStoreTests|HTTPTransportTests`) passed **37 exact identities**, with both parameter arguments retained in the HTTP suite. XML identity sets and individual outcomes were inspected, not just command exits. The first compile retained the existing OpenTelemetry watchOS-minimum deprecation warning; no source/build setting was changed to suppress it.

The earlier complete **609-pass, zero-skip signed host receipt at `f22479658a18601b319af13acf3824d4e5426c16`** is reused explicitly, not reported as a fresh run. Its tree equals this slice's source baseline `32bfe602`; the diff changes only audit/documentation files. All 17 selected identities are present and passed in that retained XML; test sources, helpers, manifests, resources, entitlements and inventory inputs are unchanged. Its original pre-test cached-runner signature failure, recovery and deliberate fixture/upstream diagnostics remain in the preceding receipt. This documentation-only slice adds no physical, live-server, browser, Keychain or keyboard acceptance.

Retained local evidence: `.build/account-context-focused-{1,2,3}.{log,xml}`, `.build/account-context-owning.{log,xml}`, disk-guard execution receipts and `.build/account-context-verified.json`; reused signed XML is `.build/router-purpose-signed-host-tests.xml`. The 3 GiB active disk guard remained enabled; the first compile began at 13.37 GiB and finished at 13.04 GiB. No new worktree or native build tree was created. Documentation checks, scoped audit/index parity and independent full-diff review are separate validation gates before publication. Published-head CI will be verified separately.

## Authentication contract context and canonical credential oracle (#372)

At source `c1a7777f170783823d575ea0ccd155dc66b3dd64`, the identity ledger had 62 completed scoped reviews and 250 pending candidates. This related batch completes 17 request, 12 OpenID and six logout records: **34 keep/no-code-change conclusions and one corrected test oracle**. The fixed historical cohorts now have **97 completed and 215 pending (144 core, 71 app)**. These are review candidates, not implementation-defect counts. All older records, partial evidence and accepted device/configuration outcomes are preserved; #372/#374/#362 remain open.

| Stable record | Existing test | Current scoped conclusion |
| --- | --- | --- |
| `AUD-C-3b314c19bd26` | `testRejectedRefreshUsesSavedPasswordAndRetriesRequest` | Exact prefixed recovery routes, login body, recovered authorization headers/tokens, retained native login and cleared reauthentication; synthetic recovery only. |
| `AUD-C-622220378853` | `testRefreshContractFailuresUseSavedPasswordAndRetryRequest` | Nine refresh-contract/persistence scenarios retain successful recovery sequence, exact persisted credentials and state; recovered request headers are not individually checked in this matrix. |
| `AUD-C-d01791aa85e6` | `testSavedPasswordRejectionRemainsTyped` | Two sequential typed invalid-credential outcomes retain tokens/native login, require reauthentication and perform exactly one refresh/login; sequential memoization only. |
| `AUD-C-cc79ee9b8bb0` | `testSavedLoginCannotChangeRemoteUserIdentity` | Exact expected/actual user mismatch, original tokens and reauthentication state; native-login retention is not separately asserted. |
| `AUD-C-d54d0553b4a6` | `testSavedLoginAuthorizationRejectionRequiresReauthentication` | Typed validation failure preserves original tokens and requires reauthentication. |
| `AUD-C-cba3b9ff809b` | `testForbiddenResponseDoesNotRefresh` | Returned 403, one request, zero refreshes and no reauthentication requirement. |
| `AUD-C-dcfcd57c6084` | `testAuthenticationEndpointsNeverEnterRefresh` | All six authentication routes return the exact typed rejection with zero total transport calls. |
| `AUD-C-16cc2737c80e` | `testOrdinaryRequestRetriesOnlyOnce` | Typed repeated-401 failure, three requests, one refresh and reauthentication required. |
| `AUD-C-a45370be3a44` | `testRefreshFailuresAreTypedAndAccountScoped` | Eight typed error mappings and selected-account reauthentication states; cross-account isolation is the separate isolation case. |
| `AUD-C-5e38411cf5a6` | `testRefreshTransportFailureIsNotCachedAndRetries` | Initial typed transport failure, exact five-path second-attempt sequence and success without reauthentication; sequential retry only. |
| `AUD-C-4ce37e9d8b96` | `testTransientSavedLoginFailuresAreNotCachedAndRetry` | Transient saved-login transport/contract/persistence failures remain typed and retryable; second success, two refreshes, exact recovered tokens and state. |
| `AUD-C-31003d23f77f` | `testMissingSessionTokensUseSynchronizedNativeLogin` | Missing session tokens recover from existing actor-fake native credentials; exact login/authorize/request sequence, persisted tokens/native login and state; no real cloud or concurrent synchronization claim. |
| `AUD-C-d28987f12c52` | `testCredentialFailuresAreTyped` | Missing/read/save credential failures retain precise typed mappings and distinct reauthentication states; no physical Keychain claim. |
| `AUD-C-878c5af5d19e` | `testRequestValidationAndTransportFailuresAreTyped` | Invalid account, mismatched/missing/invalid route, token-bearing URL and transport errors remain typed; transport failure is non-reauthenticating. Validation subcases do not assert total transport calls. |
| `AUD-C-7fdac98a049a` | `testAlreadyRotatedCredentialsAvoidAnotherRefresh` | Credential save completes before the external-rotation fake returns401; exact old/new bearer counts1/1, zero refreshes and success. |
| `AUD-C-9283d5e197d4` | `testCompletedRotationCoversAStaleCredentialRead` | Deliberately stale reads still produce two sequential successes, one refresh and exact saved rotated tokens; the scripted transport does not inspect retry Authorization headers. |
| `AUD-C-1cd56b49a278` | `testRefreshFailureDoesNotAffectAnotherAccount` | Failed account receives refreshRejected and reauthentication while the healthy account succeeds without it; not exhaustive credential or concurrent-isolation coverage. |
| `AUD-C-6f22f7f475ff` | `testOnlineLogoutUsesRefreshHeaderAndClearsCredentials` | Exact prefixed POST URL, refresh header, absent Authorization/query, provider URL, credential removal, deletion counts and second no-credentials outcome. |
| `AUD-C-c23ef15fd810` | `testLogoutRejectsUnsafeProviderRedirectWithoutBlockingCleanup` | Insecure provider redirect is suppressed while remote completion and credential removal remain asserted; not exhaustive redirect-policy coverage. |
| `AUD-C-f65da14ee399` | `testRemoteFailuresStillDeleteLocalCredentials` | Transport/401/503 failures map to exact remote statuses; each fresh fixture removes credentials and deletes once. |
| `AUD-C-0c0e1e8df027` | `testMissingOrUnreadableCredentialsStillRunDeletion` | Missing/unreadable credentials retain distinct statuses, zero requests and one deletion each; unreadable case proves deletion invocation, not a later readable snapshot. |
| `AUD-C-873ba73d3551` | `testCredentialDeletionFailureIsTypedAndRequiresReauthentication` | Typed deletion failure retains credentials and requires reauthentication; no deletion-count assertion is claimed. |
| `AUD-C-63df1c89614d` | `testInvalidAccountDoesNotReadDeleteOrSend` | Exact invalid-account failure occurs with zero read/delete/send counters. |
| `AUD-C-aee7bc42f859` | `testSystemBrowserSessionCompletesAndConfiguresSession` | Fake session completion, configuration and exact presentation-anchor identity; no real provider/browser presentation or complete helper-task drainage claim. |
| `AUD-C-2fc27386472f` | `testSystemBrowserSessionRejectsMissingPresentationAnchor` | Missing presentation anchor is rejected before any session is created; no held session is admitted. |
| `AUD-C-3f1623384088` | `testPKCEUsesRFC7636ChallengeAndSecureShapes` | Known RFC challenge vector and generated PKCE shapes; no statistical entropy claim. |
| `AUD-C-b7e8b147de83` | `testPKCERandomFailureRemainsTyped` | Exact injected PKCE random failure and zero requests. |
| `AUD-C-2976cd29258d` | `testCallbackURLValidation` | Exact callback URL validation matrix. |
| `AUD-C-d229dd7d8c0e` | `testCallbackRequiresExactURLStateAndCode` | Valid callback values and exact URL/state/code rejection matrix. |
| `AUD-C-bd80aab48650` | `testCompleteCookieBoundFlowValidatesThenPersists` | Synthetic cookie flag, request sequence/payload and canonical credential persistence; not a real cookie jar or Keychain. |
| `AUD-C-464ba3e270f5` | `testBeginRejectsInvalidResponsesAndCleansUp` | Typed begin failures, two clears, attempt removal and zero saves. |
| `AUD-C-256507ec04db` | `testInvalidBrowserCallbacksNeverReachExchange` | Invalid callback typed failures, one request, two clears and zero saves prove no exchange. |
| `AUD-C-145dcd9aefad` | `testCallbackWithoutCodeNeverReachesExchange` | Missing callback code returns the exact error with one request and two clears; no extra storage assertion is claimed. |
| `AUD-C-aae4619dd61e` | `testAuthorizationAndPersistenceFailuresRemainTyped` | After correcting the wrong-key oracle, typed authorization/persistence errors and two clears remain; explicit distinct provisional/canonical identities both have absent synthetic credentials. A write-before-throw mutation is now detected. |
| `AUD-C-a012d02e56d1` | `testInvalidAccountDoesNotTouchAttemptOrCookies` | Exact invalid-account error, zero clears and absent attempt; no asserted request count is claimed. |

The OpenID failure matrix checked only provisional `account` credentials, while production saves the authenticated fixture user under `AccountID.canonical(server:userID:)`. The original typed errors and empty provisional slot could therefore pass despite retained canonical credentials. A temporary isolated actor-fake mutation wrote canonical credentials immediately before throwing its existing save error: the old test passed. Adding the distinct canonical-slot absence assertion made the same mutation fail exactly at `canonicalStored == nil`. The fake was then restored byte-for-byte; no production behavior or real credentials were mutated and no production credential leak was observed. The final patch retains every existing error/clear/provisional assertion and adds only explicit identity setup and canonical absence.

Request/logout fixtures use independent local actors, immediate scripted values/errors and awaited coordinator completion. Refresh-result tasks are awaited by the coordinator; these selected cases create no held fake or private continuation requiring new cancellation machinery. The OpenID browser cases use fake factory completion or fail before session creation; the factory's separate one-shot start-notification Task is not joined by the selected completed-session test, so this review does not certify whole helper/production task-graph drainage. Synthetic cookie flags, stored native-login fakes and local error mappings are not real browser, cookie-jar, cloud synchronization, Keychain, network or physical-device evidence. No arbitrary sleeps, retry loops, tolerance changes or new declarations are introduced.

Rules 1–2 retain exact semantic postconditions and awaited completion; playback/rate/elapsed-time tolerance is inapplicable (3). Per-record ownership/setup and fake/framework limits address 4–6; original failure witnesses and caller-located typed/state assertions address 7–8. Rule 9 execution evidence follows. Historical primary audit fields stay intact; `authenticationContextReview20261023` records these current scoped decisions. #457 and the installed iBook build, macOS deferral and separate workspace zip advisory findings remain untouched.

Fresh validation on Xcode 27.1/macOS: the corrected identity passed three fixed independent runs; the exact selected set passed **35 identities**; the three owning suites passed **61 unique function identities** (26 request, 21 OpenID, 14 logout), retaining their parameterized contract cases. Fresh complete signed host validation passed **609 exact inventory identities, zero skips**, including all 35 selected cases. XML class/function identities and individual outcomes, built-in host inventory/signature/profile/entitlement verification and disk-guard receipts were inspected. The final changed-file SHA-256 stayed `aa9d98f38891f68a85cc9e003170b88c3e896bb02c1e7b18f9f8566864e71b9d` through these successful runs.

The old-oracle mutant passed its one exact identity; the corrected-oracle mutant failed exactly once at canonical credential absence. Both are retained as deliberate negative-witness evidence, not clean production runs. The fake was restored exactly before the passing repetitions and owning/signed gates. An initial private report checker expected 60 owning functions from a literal source grep; actual XML and the audit identity set agree on 61, including a declaration whose formatting escaped that grep. This was a count-check correction, not a native test failure or rerun.

The successful signed log retains the existing OpenTelemetry watchOS deprecation, deliberate cleanup-fixture known issues and storage-fixture diagnostics. Xcode also reported stale generated-runner paths using the alternate temporary-root spelling; both spellings resolve to this same worktree, and the supported runner rebuilt/verified its signed product and passed all 609 identities. No signing/security setting, source configuration or broad cache cleanup was changed, and no warning-free claim is made.

Retained evidence: `.build/auth-context-{old-oracle-mutant,fixed-oracle-mutant,fixed-1,fixed-2,fixed-3,selected,owning}.{log,xml}`, `.build/auth-context-mutation-verified.json`, `.build/auth-context-signed-host.log`, copied `.build/auth-context-signed-host-tests.xml` and `.build/auth-context-verified.json`, with execution receipts. The 3 GiB active guard stayed enabled; the signed run began at 12.28 GiB and ended at 11.82 GiB. No new worktree or archive was created; only existing build outputs were reused. Strict changed-file lint, documentation and audit/index parity checks and independent full-diff review precede publication; published-head CI remains a separate gate.
