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
