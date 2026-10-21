# App test reliability follow-ups

Issue [#362](https://github.com/terminaloutcomes/bleat/issues/362) owns this
work. This record tracks source-level findings from the `BleatAppTests` audit.
All follow-ups are owned by the Bleat maintainers; bounded remediation issues
are linked where created. The per-test source evidence is recorded in
`TestSupport/TestAudit/app.json`.

The app source audit is complete: all 593 in-scope test bodies have individual
purpose, setup, action/postcondition, synchronization, nine-rule, compiler/skip,
and decision assessments in `TestSupport/TestAudit/app.json` (510 keep, 4 fix,
79 follow-up). The 10 async-gate
test declarations in `TestAsyncGateTests.swift` are excluded here and are covered
by the parent audit; shared gate helpers live in `TestAsyncGates.swift`. Open
items below are specific reliability defects that remain after source review.

## Open items

| Tests or helpers | Required work | Rationale and remaining risk | Owner |
| --- | --- | --- | --- |
| `AppModelTests/testLastPlayingStopAndPauseCancelResolvingRemotePlay`; `AppModelTests/testLastPlayingStopCancelsFirstPreparationSuspension` | Replace each fixed 100-`Task.yield()` drain after gate release with an observable completion signal for the suspended resume/preparation operation. Register the signal before releasing the gate, then assert the final playback/session state after that completion. | Yield count does not establish that the cancelled resolver has completed. A late continuation could issue a playback request after the assertion, so cancellation behavior is not yet proven. | Bleat maintainers |
| `AppModelTests/testLateTransportFailureCannotRetryCompletedTrack` | Give the delegate callback path an awaitable completion/diagnostic signal, or another event tied to processing that callback; assert it before checking no retry was scheduled. | The test invokes the URL-session delegate and then yields 20 times. That only gives the main actor scheduling opportunities; it does not prove the callback's queued work finished. A retry could be accepted after the test's assertion. | Bleat maintainers |
| `FrameworkCallbackTests/testRemotePlayAdmitsBootstrapSelectionAndClearInvalidatesIt`; `FrameworkCallbackTests/testRetiringBootstrapAdmissionRejectsQueuedCommandsAfterReplacement`; `FrameworkCallbackTests/testClearRejectsQueuedCommandsAndLateCallbacks` | Replace the `Task { @MainActor in expectation.fulfill() }` queue barrier with an awaitable drain/completion signal tied to the coordinator's admitted callback. Keep the semantic assertion that no retired command reaches the handler. | Main-actor task scheduling order is not a completion contract. The assertion can race a queued command, weakening stale-command rejection evidence. | Bleat maintainers |
| `AppModelTests/testLiveProgressPatchesOneItemWithoutReloadingBrowsing`; `testLiveProgressRefreshesOnlyAffectedOpenDetail`; `testLiveRefreshStaysSuspendedAcrossBackgroundNetworkRecovery`; `testLiveRefreshCancelsQueuedCatalogChangeOnBackground`; `testLiveRefreshStopsInFlightCatalogCascadeOnBackground`; `testLiveProgressDoesNotReplaceNewlySelectedDetail`; `testLiveProgressDoesNotCancelInFlightCatalogRefresh`; `testLiveProgressInsertsReordersAndHidesContinueListeningItem`; `testLiveProgressRefreshesFilteredPagesOnlyWhenMembershipChanges`; `testLiveProgressClearsRemovedProgressFromOpenDetail`; `testLiveProgressEchoDoesNotRefreshStreamedPlayback`; `testLiveProgressSuppressionIsScopedToPlaybackAccount`; `testLiveProgressUpdatesFinishedStateImmediately` | Replace fixed 350–400ms post-event sleeps and yield-count readiness loops with bounded waits for the specific stream delivery, refresh completion, or model postcondition. | Scheduler delay does not prove the asynchronous live-update consumer or refresh cascade completed. Assertions may run before a late update/request. Keep exact request-count and playback-state checks after the new completion signal. | Bleat maintainers |
| `AppModelTests/testSeriesPaginationCoalescesAnInFlightPageWithoutBlockingMainActor`; `testConcurrentSeriesPreparationsQueueGlobalConfirmationsByCompletion`; `testConfirmedSeriesSerializeSharedBookHandoffPerAccount` | Replace one `Task.yield()` used as a competing-task barrier with an explicit admission/queue signal before checking coalescing or request ordering. | Yield only schedules cooperatively and does not establish that the other task reached the intended state; request-count and order assertions can pass before the competing operation is admitted. | Bleat maintainers |
| `AppModelTests/testSetFinishedNewerCommitRejectsOlderDetailReconciliation`; `testSetFinishedReconciliationDoesNotRestoreObsoleteSearch`; `testCompletedReconciliationDoesNotCancelLaterUserSearch`; `testCancelledReconciliationSearchPreservesLoadedResults` | Expose and await reconciliation/search completion (and propagate cancellation) instead of using swallowed `try?` sleeps or yield-count polling before asserting stale work was rejected. | A 100ms delay or up to 50 sleeps does not prove the reconciliation task finished; a late detail/search result could overwrite the assertion after the test returns. One polling loop also suppresses cancellation. | Bleat maintainers |

| `AppModelTests/testRemotePlaybackProgressSyncEmitsOneTypedAttempt`; `testDownloadHTTPMetricsAreRecordedOffMainActorWithoutCacheHits`; `testContinueDownloadMissingLocalAccountHasTypedFailureAndPreservesBytes`; `testRestoredDownloadCallbacksMissingAccountKeepTypedStageAndBytes`; `testDownloadRestorePreservesQuarantinedLegacyTrackAndPresentsTypedCause`; `testNetworkPathUpdateResumesInterruptedDownloadAfterOfflineRelaunch` | Use an asserted bounded condition helper at each asynchronous observation, retaining the wait result, elapsed budget, source location, and observed state in XCTest failures; ensure session and observer cleanup runs on failure. | Current polling is time-bounded but some loops discard whether they observed the condition, or check a nearby but different state. A later callback may arrive after the test or an ordinary failure can lack actionable timeout context. Preserve typed failure and real legacy-persistence assertions. | Bleat maintainers |
| `AppModelTests/testLateTerminalSaveCannotSetFailureForReplacementBatch`; `testTranscriptDeletionWaitsForLateTranscriptSave`; `testAutomaticChapterFileIsPinnedUntilTranscriptionCompletes`; `testRereadClearsPinnedCompletionEvenWhenPlanFails`; `testLocalCompletionWaitsForInFlightAutomaticWork`; `testTransportFailureWaitsForNetworkAndDropsTransientProgress`; `testTransportRetryDoesNotScheduleAfterNetworkDropsDuringBackoff`; `testRetryAfterHeaderDelaysRetryableServerReplacement`; `testPauseIntentPrecedesConcurrentTerminalCallback`; `testLateCancelledTaskCallbackDoesNotRestartDownload`; `testLargeCellularDownloadsPreserveEveryPendingConfirmation`; `testConcurrentDownloadTriggersShareOneBookOperation`; `testFetchedCallbackTimeoutKeepsRetryBlockedUntilDrain` | Replace yield counts and short absence sleeps with a gate entry/completion signal for the operation under test. Make timeout cleanup release continuations, cancel owned tasks, and join their completion before checking absence or ordering. | Scheduler opportunities and short delays do not prove callback processing, retry cancellation, deletion admission, or pin cleanup has settled. Late work can invalidate the asserted result or leave a suspended task behind. Keep each existing late-callback, queue-reset, and persistence assertion. | Bleat maintainers |
| `AppModelTests/testPauseStorageFailureIsVisibleAndDoesNotResume` | Replace the unasserted 100ms settling delay with an asserted bounded wait for the typed storage failure and include caller-site timeout diagnostics; retain relaunch durability assertions. | The delay does not prove the asynchronous pause reached its failure state, so assertions can race and failure evidence is weak. | Bleat maintainers |
| `AppModelTests/testMediaServicesResetRestoresPlayingAndPausedIntent`; `testNaturalBookEndClearsPlayerPresentationAndSystemNowPlaying`; `testNaturalStreamedBookEndSyncsAndClosesSession`; `testNaturalCompletionWaitsForPendingSyncBeforeFinalPositionAndClose`; `testRestartAndAccountSwitchSkipSyncOfNaturallyClosedSessions`; `testMediaServicesResetRebuildsAcrossAudioFileBoundary` | Add explicit AVPlayer readiness, rate, elapsed playback, and relevant position diagnostics before reset/end/boundary assertions; retain bounded playback deadlines and position tolerances. | These scenarios depend on real simulator audio progression. Without readiness and timing diagnostics, a fixture or simulator scheduling failure is hard to distinguish from a product regression, and boundary assertions can run before playback is ready. Simulator evidence is still required. | Bleat maintainers |
| `AppModelTests/testNetworkPathUpdateRetriesPendingLocalSessionsWithoutBlockingLaunch`; `testQualityOnlyAndDuplicatePathsDoNotScheduleModelRecovery`; `testLiveConnectionAttemptsTraceEndpointRoleRetryAndOutcome`; `testConstrainedPathControlsLiveUpdateLifecycleWithoutBlockingREST`; `testPendingLocalSessionUploadDoesNotBlockLaunch` | Isolate defaults from `UserDefaults.standard`; replace break-only polling with asserted transition waits; on failure, release upload gates and cancel/join observer tasks. | Shared preferences can leak between parallel tests or survive abnormal teardown. Break-only loops can continue into assertions without proving the intended transition, and a blocked observer can outlive the test. | Bleat maintainers |
| `AppModelTests/testBookDeletionSupersedesInFlightFailedPlaybackRetry`; `testSetFinishedReconciliationFailureDoesNotReverseCommitOrAlert`; `testSetFinishedUsesRemoteOnlyDetailReconciliation`; `testSetFinishedReconciliationFailuresRecordTypedDiagnostics` | Await the owned retry/reconciliation completion through a signal, then assert one exact request/session outcome and final committed state. | Deadline-bounded polling is better than an unbounded wait but does not establish that independent work finished; accepting a request-count range can hide a duplicate or missing path. | Bleat maintainers |
| `AppModelTests/testCarPlayCellularCancelAndLateCallbacksPreserveNextRequest`; `testCarPlayCellularReconnectAndDelayedPresentationKeepDecision`; `testCarPlayCellularAccountRemovalDismissesAndRejectsOldActions`; `testCarPlaySearchVersionAndCapabilityGatePreservesBrowsing`; `testCarPlaySearchNativeRowsSurviveCapacityChanges`; `testCarPlaySearchAuthorPopCompletesUncooperativeLoad`; `testCarPlaySearchRetryAndNoMatchesRemainExplicit`; `testCarPlaySearchInvalidationCancelsDelayedDetailAndStreamPlayback`; `testCarPlayPresentationRetainsItemsAndSeedsReplacementArtwork` | Use completion/admission signals for stale callbacks and queue transitions; replace artwork-render polling with an observable publication signal or an asserted bounded condition. | The current yield/sleep barriers do not prove the retired callback or artwork update has been processed. A late callback could mutate the next request after the test returns, while a short render poll gives weak failure evidence. | Bleat maintainers |
| `AppModelTests/testCarPlaySearchAuthorPopCompletesUncooperativeLoad`; `testCarPlaySearchNewAuthorDoesNotRenderPreviousAuthorDuringLoad` | Replace force-unwrapped fixture IDs and URLs with `try XCTUnwrap` or another XCTest failure path before exercising the behavior. | Malformed fixtures or constructor changes currently can terminate the test process instead of recording the failing fixture and allowing XCTest diagnostics. | Bleat maintainers |
| `NetworkPathTests/testStaleProbeCannotPromoteEndpointOrReviveStoppedSubscription` | Ensure all probe gates and subscription tasks are released/cancelled and joined in `defer`, then assert the retired generation cannot be promoted. | A failed intermediate assertion can strand the probe task and contaminate later network tests; stale-generation rejection must remain the semantic postcondition. | Bleat maintainers |
| `ReleaseSecretLeakageTests/testCaptureInitialTokensAndForceRefresh`; `testCaptureRotatedTokens`; `testRemovePrivateCapture`; `testLogoutRemovedSessionCredentials`; `testPrivateCaptureRemainsRemovedAfterLogout` | Add failure-safe cleanup for the private capture directory and real Keychain test credentials, while preserving the cross-launch capture/rotation/logout sequence. | These tests deliberately use persistent host state across launches. An early assertion failure can leave sensitive test artifacts or credentials behind and affect a later run. Signed host evidence remains required. | Bleat maintainers |
| `FrameworkCallbackTests/testActualPlayerKVOCallbackRunsOffMainActor`; `KeychainEntitlementTests/testApplicationHostCanPersistCredentialsInKeychain` | Replace queue-marker assumptions with a signal tied to the actual KVO callback or Keychain operation completion before reading final state. | Main-actor task ordering is not proof that the callback/operation finished; the assertion can race delivery and report a false pass. Preserve the off-main callback and application-host Keychain coverage. | Bleat maintainers |

## Source fixes with focused Xcode evidence

- `AppModelTests/testScrubberSeekDecisionConfirmsTenMinuteJumpsInEitherDirection`
  now checks the positive threshold for forward seeking and the negative threshold
  for backward seeking, including the exact threshold in both directions.
- `RemoteTelemetryConsentTests/testAppModelMonitorsTokenAcquiredAfterDiagnosticsAppears`
  and
  `RemoteTelemetryConsentTests/testTelemetryTokenAvailabilityDiscardsResultAfterWithdrawal`
  now use asserted, three-second condition waits instead of unbounded yield
  loops. The deferred controller latches a completion if timeout cleanup runs
  before the fake request enters, and wait helpers stop on cancellation.
- `AppModelTests/testTranscriptDeletionWaitsForInitialCheckpoint` now waits
  for the `.deleting` state with a bounded condition wait.
- `AppModelTests/testSignedInAlertQueueSerializesAndResetsForAccountChange`
  retains its post-yield assertion because `SignedInAlertQueue.finish` schedules
  a later `showNext` task; the second assertion checks that reset prevents that
  task from restoring an alert.
- Shared AppModel transcription and cover waits and the NetworkPathTests
  availability wait now fail with the caller's location, observed value, and
  timeout when their condition is not met.

The four fixed selectors above passed both focused Xcode repetitions; their
per-record execution overrides link to the exact run record in
`docs/release-evidence/test-reliability-audit.md`. The owning BleatAppTests suite
subsequently passed all 598 identities twice (1,196 executions) on an isolated
Simulator after the retained installation-interrupted attempt. Simulator, signed-host, and device evidence remains distinct
where those suites require it.

## Timing batch status

The table above retains the original source-review findings. The subsequent
[timing and synchronization batch](test-reliability-audit.md#timing-and-synchronization-batch-2026-10-16)
records partial remediation and its execution evidence. Per-test `timing_batch`
annotations in the linked audit JSON identify updated test bodies; unchanged
findings remain open. Do not interpret the original table as a description of
those updated implementations or as evidence that the whole backlog is closed.

## Follow-on source batch 2026-10-16

The current source diff changes 71 app test bodies recorded individually in
`TestSupport/TestAudit/app.json`: 69 `AppModelTests` records and two
`NetworkPathTests` records. Their original review decisions, historical
counts, and unrelated findings remain intact. The batch also adds a bounded
source-located `assertEventually` helper and an `AppModelOperationEventProbe`
in `Tests/BleatAppTests/TestAsyncGates.swift`; the audit inventory describes
the changed selectors and helper review.

The post-extraction owning app run verified all 598 identities passing with zero
skips (`.build/post-extraction-app-owning.xcresult`), including all 71 annotated
cases. Four corrected app cases also passed twice each in the focused run
(`.build/post-extraction-focused.xcresult`). Unrelated follow-up rows remain open; the negative-assertion P2 is resolved
by the scheduling-boundary change below.

The negative request-count P2 in
`testLiveProgressEchoDoesNotRefreshStreamedPlayback` and
`testLiveProgressUpdatesFinishedStateImmediately` is now resolved: the tests
snapshot a synchronous `liveRefreshScheduled` event count and assert it remains
unchanged after each `liveUpdateConsumed` event. Scheduling is observed before
the 250 ms debounce, so an erroneous refresh cannot hide behind that delay.
The existing request and model-state assertions remain. Both tests passed three
repetitions each (six exact outcomes, zero skips), and the owning app suite
passed all 598 identities with zero skips (`.build/p2-live-refresh.xcresult`,
`.build/p2-app-owning.xcresult`).

## Concurrent transcript export assertions (#384)

Child [#384](https://github.com/terminaloutcomes/bleat/issues/384) of
[#374](https://github.com/terminaloutcomes/bleat/issues/374) resolves only
`TranscriptExportArtifactTests/testConcurrentFirstWritesSafelyShareOrphanCleanup`.
The test joins eight writes with distinct UTF-8 payloads, alternating VTT/SRT
formats and identical titles. It retains every artifact lease through assertions
of eight distinct URLs, exact expected subtitle bytes, format/content type, file
existence, and shared orphan cleanup. Byte equality intentionally verifies the
file encoding and line-ending contract. No production exporter defect is claimed.
The nine-rule source review is updated in `TestSupport/TestAudit/app.json`; test
identities are unchanged, so the navigation and host inventories need no update.

Validation on 2026-10-19, based on `07cd9bae` (PR #383), Xcode 27.1
(`27A9275`): `mise run swift-lint`, `mise run docs:check`, and
`git diff --check` passed. The documentation checker reported
`Documentation references verified`. Initially, local focused
repetitions and the local owning `BleatAppTests` run were **unexecuted**: destination
discovery with `xcrun simctl list devices available` invoked Xcode's
`xcodebuild -runFirstLaunch`, waiting for macOS authorization to install
components (installed CoreSimulator `1171.7`, toolchain expects `1174.9.2`). A
process sample identifies `DVTFirstLaunchPackageInstaller` →
`PKInstallRequest authorizeForRight` → `AuthorizationCopyRights`; this is an
environment blocker, not a source/test failure. No tests, skips, or passing
runtime results are claimed for that discovery attempt; no Simulator `.xcresult`
was produced.

After local component-install authorization, the required focused command is:

```sh
mise exec -- xcodebuild -project Bleat.xcodeproj -scheme Bleat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -resultBundlePath .build/export-focused.xcresult \
  -only-testing:BleatAppTests/TranscriptExportArtifactTests/testConcurrentFirstWritesSafelyShareOrphanCleanup \
  -test-iterations 10 test
```

Then run the owning `BleatAppTests` bundle with a fresh result-bundle path and
`-only-testing:BleatAppTests`. Inspect every executed identity and iteration via
`xcrun xcresulttool get test-results tests --path <bundle>` and the corresponding
summary before recording results. Exact commands/destination may need the
installed runtime's UDID per the development guide. Broader #374 and #362
requirements remain open; signed macOS and physical-device evidence are separate.

The supported development-signed macOS app-hosted route was also attempted
with `BleatMac`, `platform=macOS`, ten iterations, and the same focused identity.
It failed during compilation of unchanged `App/RootView.swift:4669`: SwiftUI
`MenuActionDismissBehavior.disabled` is unavailable on macOS. The retained
`.build/export-macos-focused.xcresult` records a build failure and zero executed
tests, not a failing test or runtime coverage. The log additionally reports the
CoreSimulator version mismatch and an arm64/x86_64 destination ambiguity. This
PR does not change the unrelated platform compatibility path.

Independent review corrected the source audit's unsupported runner-timeout claim. The task group joins finite local
writes; there is no test-local or explicitly enabled runner timeout, so a
filesystem hang remains a runner-level risk.

CI run `39135127213` at `5c44d38` failed during app-test compilation: its
toolchain requires `try` on `withExtendedLifetime` around the throwing file
reads. The review-directed removal was incorrect; no tests executed and no
`ios-smoke-results` artifact was available. The correction binds the throwing
`Data(contentsOf:)` read outside the XCTest autoclosure and retains the required
outer `try`, making error propagation explicit. Updated-head CI is required.

### Verified CI owning-suite evidence

[CI run 39136376326](https://github.com/terminaloutcomes/bleat/actions/runs/39136376326)
passed at `aaca43befcc7820c8f1545efa6110dc1766abcbc` with Xcode 26.6
(`17F113`) on iPhone 17 Pro, iOS Simulator 26.5. The downloaded
`ios-smoke-results` bundle
`.build/export-evidence/ci-smoke-corrected/5645-1792334208001.xcresult`
was inspected with `xcresulttool` summary/tests and reverified with the
repository's `verify-test-results` against its build-derived discovery and
actual smoke selectors: **608 passed outcomes, zero skips, failures, expected
failures, or runtime warnings**. These comprise 606 `BleatAppTests` outcomes
(including all eight `TranscriptExportArtifactTests`) and two UI smoke outcomes.
`testConcurrentFirstWritesSafelyShareOrphanCleanup` passed once (0.030153s).
The initial local verifier invocation used an unmatched guessed UI selector and
was rejected; using the actual selectors from `scripts/src/ci_smoke.rs` verified
all 608 outcomes. That rejected verification is not test coverage.

All PR CI checks passed on this tested revision; website deployment was
intentionally skipped. The unsigned host job reported 573 tests in 43 suites,
with one known issue and the signed-Keychain case excluded. Rust coverage
reported 3.865%, below its advisory 80% threshold; that job passed. These are
separate CI lanes, not local signed-host or device evidence.

The owning CI suite does not establish focused repetitions. Independent source
review cleared this source revision. The subsequently completed local evidence
is recorded below; broader #374 and #362 requirements remain open.

### Verified local repetitions and owning suite

After the user authorized Apple's component update on 2026-10-19, installed
CoreSimulator `1174.9.2` matched Xcode 27.1 (`27A9275`). Simulator discovery
completed successfully. At unchanged source revision
`53836c2a4b6015712e3217f0d3da2417f9655fbf`, the selected iPhone 17 Pro
(iOS Simulator 26.5) ran the exact concurrent export identity **10 times: all
10 passed**, zero skips, failures, expected failures or runtime warnings.
The bundle `.build/export-ios-focused-10.xcresult` was inspected with
`xcresulttool` summary/tests and `verify-test-results --expected
BleatAppTests/TranscriptExportArtifactTests/testConcurrentFirstWritesSafelyShareOrphanCleanup
--repetitions 10`. The summary contains one unique identity and ten run
outcomes; these are ten repetitions, not ten different tests.

The first local full-owning attempt, `.build/export-ios-owning.xcresult`,
executed no actual test case: SpringBoard denied test-host launch with
`Busy / Application failed preflight checks`. Its summary records one synthetic
runner failure. That failed attempt is retained and is not passing coverage.
Explicit `simctl bootstatus -b` then found the device needed booting and waited
through data migration and system-app readiness to terminal `Finished` (9s).
The built test host was installed after readiness, then the existing build was
enumerated using the repository runner's flat JSON enumeration options.

With a fresh result bundle, `test-without-building -only-testing:BleatAppTests
-parallel-testing-enabled NO` passed the full owning suite: **606 outcomes,
zero skips, failures, expected failures or runtime warnings**, including all
eight transcript artifact tests. `.build/export-ios-owning-ready.xcresult` was
inspected with `xcresulttool` summary/tests and strictly verified against
`.build/export-evidence/ios-owning.discovery.json` with `--only BleatAppTests`.
All assertions were unchanged; no timing sleep, tolerance increase, or product
workaround was added. `.envrc` retained its original checksum. This is local
Simulator evidence; the earlier macOS compile blocker and lack of physical-device
validation remain explicit.

## Deep-link invalid-route fixture construction (#374)

`DeepLinkTests/testParserRejectsMalformedOrAmbiguousLinks` now throws and
constructs each URL with `try XCTUnwrap` before entering `XCTAssertThrowsError`.
All 14 literal inputs and parser-rejection assertions remain. Both assertion
messages identify the input, so fixture construction failure is an XCTest
setup failure and cannot be mistaken for parser rejection. Production parser
and navigation code are unchanged. The scoped nine-rule disposition in
`TestSupport/TestAudit/app.json` is updated; historical aggregate counts and
unrelated follow-ups are retained.

The adjacent parser and navigation paths were inspected for recoverable traps
and executor assumptions; this synchronous fixture change introduces no
callback or cancellation boundary. No specification, public route contract,
host-test inventory or test identity changes are needed. Broader #374 and
#362 acceptance, signed-host, live-server and physical-device evidence remain
separate.

Validation on 2026-10-19 used the configured m2 worktree based on `c12bdc68`,
Xcode 27.1 (`27A9275`), iPhone 17 Pro and iOS Simulator 26.5:

| Selection | Verified passed outcomes | Result bundle |
| --- | --- | --- |
| `BleatAppTests/DeepLinkTests/testParserRejectsMalformedOrAmbiguousLinks` | 10 repetitions of one identity | `.build/deeplink-focused-10.xcresult` |
| `BleatAppTests/DeepLinkTests` | All five identities | `.build/deeplink-suite.xcresult` |
| `BleatAppTests` | All 608 build-discovered identities | `.build/deeplink-owning.xcresult` |

Every bundle's summary and test tree were inspected with `xcresulttool` and
strictly verified using `verify-test-results`: zero skips, failures, expected
failures or runtime warnings. The owning inventory was enumerated from the
built products into `.build/deeplink-owning.discovery.json`; no historical
suite-count arithmetic was used. The five class identities are canonical-route
round-trip, invalid-route rejection, latest-valid-link queueing, startup-inbox
queueing and the Settings shortcut.

The focused command was the contributor-guide `mise exec -- xcodebuild
-project Bleat.xcodeproj -scheme Bleat` app runner with the installed Simulator
destination, `-derivedDataPath .build/deeplink-derived`, the table's result path,
the exact `-only-testing:` selector, `-test-iterations 10`,
`-parallel-testing-enabled NO` and `test`. The class run used its class selector
without repetitions. The owning run used `test-without-building` and the bundle
selector after flat JSON enumeration of those same built products. Logs are
retained beside the bundles as `.build/deeplink-focused-10.log`,
`.build/deeplink-suite.log` and `.build/deeplink-owning.log`.

The first strict-lint attempt failed on one new assertion line exceeding 80
columns; splitting the arguments fixed it, and `mise run swift-lint` passed.
`mise run docs:check` and `git diff --check` passed. The focused and owning
logs contain no build warnings. The intervening class rebuild emitted 1,608
Xcode stale-file warnings for paths through the configured `.build` symlink
being outside allowed build roots. They are retained in the class log as a
tooling warning, not erased by the later warning-free owning execution. The
class result still verified all five outcomes and no runtime warnings. No
source/configuration workaround or test rerun was used to hide these warnings.

## 10,000-book fixture and heartbeat cleanup (#374)

`AppModelTests/testTenKBooksLoadNextBooksPagePerformance` now checks its eight
immutable `AuthorID` values with throwing `XCTUnwrap` before creating the
nonthrowing `@Sendable` book/provider closures and before the measured sweep.
The original `author-0` through `author-7` IDs, corresponding author names,
modulo-eight distribution and all generated book fields are preserved. Invalid
fixture construction reports the author index through XCTest rather than
trapping, returning a service error, or substituting data.

Immediately after creating the main-actor heartbeat, the test registers XCTest
async teardown that cancels and awaits it. Both early returns after creation
(the stalled-page guard and unloaded-final-state guard) therefore join the owned
task during teardown. Success still cancels and awaits the heartbeat before
asserting its tick count. The earlier first-page guard runs before heartbeat
creation. The yield loop measures responsiveness during the real awaited sweep;
it is not used as a readiness barrier. No detached teardown or new helper is
introduced.

All 10,000-book uniqueness, overlapping-page deduplication, 499 pagination calls,
final page/limit/no-next/idle state, main-actor responsiveness, timing samples
and the 30-second ceiling remain unchanged. Fixture checks and cleanup remain
outside the measured sweep. Adjacent fixture and pagination failure paths were
inspected for traps and unjoined owned tasks. Production code, test identities,
configuration and the performance contract are unchanged; no specification or
host inventory update is needed. Only this test's audit record and matching
open-item entries are reconciled; historical aggregate counts are retained.

Validation on 2026-10-19 used base `935b5af24c701fa03fe0defa9747655209983f1d`,
Xcode 27.1 (`27A9275`), iPhone 17 Pro and iOS Simulator 26.5:

| Selection | Verified passed outcomes | Result bundle |
| --- | --- | --- |
| Exact performance test, fresh build | One identity | `.build/tenk-focused-1.xcresult` |
| Exact performance test, native repetitions | Ten repetitions of one identity | `.build/tenk-focused-10.xcresult` |
| `BleatAppTests/AppModelTests` | All 505 build-discovered identities | `.build/tenk-appmodel.xcresult` |
| `BleatAppTests` | All 608 build-discovered identities | `.build/tenk-app-unit.xcresult` |

Each bundle was inspected with `xcresulttool` and checked with the repository's
`verify-test-results`: zero failures, expected failures, skips or runtime
warnings. The owning selections were verified against flat JSON discovery of
those exact built products in `.build/tenk-owning.discovery.json`, not historical
count arithmetic. Every local test attempt passed; none was superseded.

The runner was `mise exec -- xcodebuild -quiet -project Bleat.xcodeproj -scheme
Bleat -configuration Debug -derivedDataPath .build/tenk-derived`, with the
installed Simulator destination, `-parallel-testing-enabled NO`, the table's
result path and exact `-only-testing:` selection. The fresh focused run used
`test`; subsequent runs used `test-without-building`, with `-test-iterations 10`
for the repetition selection. Logs use the same stems as their result bundles.
Discovery used `-enumerate-tests -test-enumeration-style flat
-test-enumeration-format json` on the same products; its log is
`.build/tenk-discovery.log`.

Strict changed-file lint, `mise run swift-lint`, `mise run docs:check` and
`git diff --check` passed. The logs retain Xcode's
`IDESchemeActionSDKRecord` diagnostic for host build `24A94232`
(`invalidDigitCount(94232)`); all result bundles report no runtime warnings,
and the build log contains no compiler or stale-file warnings. No shared build
files were removed. The worktree's configured temporary build symlink and
marker were preserved.

This is app-hosted Simulator evidence. Signed-host, physical-device energy,
external-server, full live journeys, configuration and release evidence remain
separate; issues #374 and #362 remain open.

## Three ungated CarPlay author fixtures (#374)

Only these `AppModelTests` cases are reconciled in this slice:

- `testCarPlaySearchAuthorZeroCapacityHasNoStatusSections`
- `testCarPlaySearchStaleAuthorRetryAndFailureCapacity`
- `testCarPlaySearchAuthorUsesIndependentFilteredPage`

Each author ID now uses caller-located `try XCTUnwrap`, preserving the exact
`author`/`search-author` IDs, author names and injected service fixtures. The
first two cases check the first result with `XCTUnwrap(rows.first)` before
selection (including reopening the author page); the third retains its existing
checked selection. Each controller immediately registers a direct synchronous
`defer { controller.invalidate() }`, inside each source iteration where relevant,
so throwing setup, row, list or retry-handler checks still invalidate it.

Remote/cache zero-capacity cases, failure-row 5→0→5 capacity changes, pop/reopen,
stale retry exact request-count equality, exact-once callback expectations,
independent typed author filter, uncollapsed page and unchanged phone browsing
assertions remain. No timing budget, production code or test identity changes.
The three audit records now reflect current source; historical aggregate counts
remain historical. The host inventory is unaffected.

Adjacent source review covered the selected fixtures, search-row helper and
controller selection, author loading, stale-generation checks and invalidation.
No new production defect was found in this slice. The helper's main-actor row
publication assumption and asynchronous callback/drain contracts are not newly
validated by synchronous invalidation. The two gated fixture findings
(`testCarPlaySearchAuthorPopCompletesUncooperativeLoad` and
`testCarPlaySearchNewAuthorDoesNotRenderPreviousAuthorDuringLoad`) and all
remaining callback-synchronization findings stay open in the table above.

Validation uses base `781acf161ef3e955d8fcd8a8aa255f53260d72fd`, Xcode 27.1
(`27A9275`), Debug, iPhone 17 Pro and iOS Simulator 26.5. Result bundles and
logs use `.build/carplay-author-` prefixes. The Xcode command is `mise exec --
xcodebuild -quiet -project Bleat.xcodeproj -scheme Bleat -configuration Debug
-derivedDataPath .build/carplay-author-derived`, with the installed Simulator
destination, `-parallel-testing-enabled NO`, explicit result bundle and selection.

| Selection | Verified passed outcomes | Result bundle |
| --- | --- | --- |
| Exact three author cases, fresh build | Three identities | `.build/carplay-author-focused.xcresult` |
| Same exact cases, native repetitions after final line wrap | Ten each, 30 outcomes | `.build/carplay-author-repeated.xcresult` |
| `BleatAppTests/AppModelTests` | All 505 built identities | `.build/carplay-author-appmodel.xcresult` |
| `BleatAppTests` | All 608 built identities | `.build/carplay-author-app-unit.xcresult` |

The focused/repetition commands used `test` (the repetition command added
`-test-iterations 10`); owning selections use `test-without-building`. The first
run preceded a line-wrap-only lint correction; the repetition build and owning
runs use the final Swift source. `verify-test-results` checked exact focused
identities with `--expected` and `--repetitions 10` for repetitions. Owning runs
use `--discovery .build/carplay-author-owning.discovery.json` and the exact
`--only` selection. Discovery is flat JSON from `test-without-building
-enumerate-tests` on the same built products, with 505 AppModel and 608 app
identities. Source/product SHA-256 evidence is retained in
`.build/carplay-author-source-products.json`.

Strict changed-file lint initially found one overlong selection line, corrected
by wrapping it. Changed-file lint and repository-wide `mise run swift-lint`
subsequently passed. Logs retain Xcode's `IDESchemeActionSDKRecord` diagnostic
for host build `24A94232` (`invalidDigitCount(94232)`). The repetition rebuild
also emitted 1,608 stale-file warnings for paths through the configured `.build`
symlink outside allowed build roots, matching the documented tooling warning
from the preceding slice. There were no other compiler warnings in that rebuild;
no shared build/cache files were removed or configuration changed. The fresh
focused build, AppModel execution and full app execution have no compiler/stale-file warnings.
All verified bundles have zero failures, expected failures, skips and runtime
warnings; no test attempt failed or was retried to green.

This is app-hosted Simulator evidence only. Signed-host, physical CarPlay,
iOS 27 input/head-unit, live-server and release evidence remain separate.
`mise run docs:check` and `git diff --check` passed after the final evidence update.
Issues #374 and #362 remain open.


## Cached-window paused seek observation (PR #408)

CI run `39313500827` on `74d2884beca770f0c1ec238b97dd4d65aaa6609d`
reported the sole Simulator failure in
`AppModelTests/testPlaybackStartExcludesIncompleteAndUsesAutomaticCachedWindow`:
`0.805220208` versus `0.75 +/- 0.01`. The retained result bundle reports
609 passes, one failure and no skips. This failed run is not passing evidence.

Both streamed and downloaded starts call `play` before returning; this test
then awaited service observations before reading `currentTime`. Source therefore
supports an advancing-clock observation defect. No production change or observed
production regression is claimed. The two download-purpose/completeness cases,
initial absolute-position request, typed source outcome, one open request and
absence of detail requests remain. An explicit playback-request assertion retains
startup intent coverage. The test pauses, confirms paused state, no playback
request and zero native rate, awaits a seek to 0.75 seconds, reconfirms those
states and checks position with the unchanged 0.01-second precision tolerance.
This exact position check covers the paused seek; it does not independently prove
that startup forwarded its initial position. There is no timing sleep, tolerance
increase or unchanged-CI rerun.

Only this app audit disposition/navigation record and its source-index location
are refreshed; other stale app locations/dispositions are outside this correction.
Validation on m2, Xcode 27.1 / 27A9275, iPhone 17 Pro iOS 26.5 Simulator:

- Supported `xcode-test-runner xctest` with the exact app test selector and fresh
  `i408-paused-seek-focused-{1,2,3}.xcresult` bundles: **1/1 each**, zero skips.
- Supported `ci-smoke` app/Simulator owning gate: **610/610**, zero failures,
  expected failures or skips. Bundle `.build/ci-smoke/77944-1792441186727.xcresult`;
  canonical discovery/result verification plus independent exact target outcome
  check passed.
- Fresh supported signed `./scripts/test-host.sh`: **597/597** exact inventory,
  zero failures/errors/skips; retained XML in
  `.build/i408-paused-seek-signed-results`.
- Strict Swift lint, docs, source/audit scope and diff checks passed. The initial
  lint caught two new long lines; both were formatted before final repetitions.
  Xcode emitted SDK/stale-build warnings; no warning suppression was added.

Commands use `mise exec -- cargo run --quiet --locked --package scripts --bin`
with `xcode-test-runner -- xctest --test-id
BleatAppTests/AppModelTests/testPlaybackStartExcludesIncompleteAndUsesAutomaticCachedWindow
--result-bundle ...`, or `ci-smoke --` for the owning gate. Verification manifest
`.build/i408-paused-seek-verification.json` binds the final Swift source hash,
exact identities, retained bundles and signed inventory. Private raw logs remain
local. Original failed CI bundle stays under `.build/i408-failed-ci-smoke`.
Fresh changed-head CI and independent review remain required before merge.

## Independent native startup-position oracles (#374)

The seven identifiers in `app.json`'s `startupClockNeighborReview` previously
sampled `currentTime` after startup had called `play()`. Their original seek is
now observed at the existing awaited `openPlayback` completion diagnostic,
before playback is requested. The file-local recorder copies the snapshot while
the model is ready, native rate is zero and time-control status is paused. It
owns no tasks, continuations or player controls and issues no corrective seek.

The read-only `PlaybackRuntimeSnapshotForTesting` adds actual AVPlayerItem time
plus its registered track offset. Every original target and precision is
retained, including the second-track whole-book position and the automatic-cache
case's 0.05-second tolerance. Each test requires one completion snapshot and
checks both model and independent native position. A caller-located three-second
condition wait observes the existing completed-play diagnostic, which follows
the native play request; unlike post-return intent sampling, this evidence
survives a short fixture naturally ending. It does not establish audible progress.

Native seek, queue planning, playback scheduling, production diagnostics and
cancellation contracts are unchanged. Original typed source, account,
persistence, track-index, request-count and navigation assertions remain. The
relaunch scenario retains the earlier seek that creates its saved checkpoint;
the new oracle observes only the relaunched player's original startup. The
automatic-cache case preserves the held remote response and original
started-before-network assertion. The other 498 AppModel test bodies and all
other app audit/navigation records are unchanged. Aggregate decisions reflect
only the seven follow-up-to-keep transitions; historical assessments remain
linked to their baseline.

Validation on m2, Xcode 27.1 / Swift 6.4, iPhone 17 Pro iOS 26.5 Simulator:

- Supported `scripts/xctest.sh` with each exact selector: **1/1 x3 for each of
  seven identities**, retained in `i374-startup-final-focus-*` result bundles.
- Owning `AppModelTests`: **505/505**. After all mutations, the restored full
  `BleatAppTests` target passed **608/608**, including all seven corrected cases.
  Every successful app bundle has zero failures, skips, expected failures and
  structured runtime warnings; built discovery is verified by the runner.
- Signed `scripts/test-host.sh`: **606/606** exact host inventory, zero
  failures/errors/skips. XML aliases are not added together. This is separate
  signed-Keychain evidence, not a macOS application or device run.
- Replacing the original native queue seek with zero independently failed each
  of the seven native-position oracles while model targets stayed unchanged.
  Omitting startup play separately failed the bounded completed-play witness.
  All eight were ordinary executed assertion failures, without supervisor
  timeout. Application bytes were restored exactly before the 608-pass gate.
- Final lint required naming the existing condition closure argument explicitly
  instead of trailing-closure syntax. An exact whole-file transformation check
  confirms no predicate, argument, budget or assertion change. The 21 focused,
  505 owning and eight mutation outcomes precede that syntax-only correction;
  the full 608-case app suite is rerun on the final text. Both source hashes
  and bundles are retained separately.
- Strict Swift lint, docs, source/audit scope and diff verification are retained
  in `.build/i374-startup-verification.json` and its referenced artifacts.

Earlier attempts remain separate: the multi-selector wrapper command rejected
its arguments before execution; a preliminary case and intermediate 21 focused /
505 owning passes preceded the stable completed-play witness. One final-source
attempt failed before test launch with Simulator preflight `Busy`; the owned
device was confirmed shutdown, booted explicitly and awaited through
`simctl bootstatus -b` before a fresh sequence. The first mutation's expected
native-position failure was initially rejected by an artifact check naming
`XCTAssertEqual` instead of `XCTAssertEqualWithAccuracy`; only the artifact check
was corrected, reusing that failure without another test invocation.

Existing SDK build-version parsing diagnostics remain in raw app logs. Signed
host logs retain the upstream watchOS deprecation, an unrelated optional-Bool
`#require` ambiguity warning (followed by its explicit Boolean expectation),
read-only SwiftData diagnostics and three intentional cleanup known issues.
No warning suppression or blind retry was added. Fresh exact-head CI and
independent review remain required. Broader #362/#369/#374 lifecycle, native
worker/callback/timeout-observer drainage, live and physical-device/configuration
acceptance remains open. The separately tracked fourteen missing audit entries
are not repaired or claimed complete by this startup slice.

## Final prepared-playback pause callback (#374)

`FrameworkCallbackTests/testRetiringBootstrapAdmissionRejectsQueuedCommandsAfterReplacement`
previously returned immediately after the final pause callback reported admission.
It now captures a second processing-sequence baseline before invoking pause,
asserts its bounded completion, then checks the handler received exactly
`[.pause]`. The retired bootstrap Play callback still drains before the original
empty-command assertion; every earlier admission and replacement assertion is
retained. Immediately deferred `coordinator.clear()` invalidates admission and
clears playback state on every exit; the coordinator retains the handler until
deallocation.

The existing sequence advances in the callback task's `defer`, after generation
rejection or synchronous handler delivery. No production code or callback seam
changed. The two 30-second budgets are failure watchdogs; neither adds a fixed
settling delay. This test uses a fresh coordinator, local command capture and a
synthetic snapshot, without network, preferences, storage or native audio.
`app.json` preserves the historical assessment and adds only this test's
`finalPauseReview`. Other callback callers, asynchronous task drainage, signed
macOS, live-server and physical-device evidence remain separate; #374/#362 stay
open.

Validation on Xcode 27.1, iPhone 17 Pro iOS 26.5 Simulator, based on
`3deee8a748e0f7acac54f563abd07d5b36933e41`:

- Supported `mise exec -- ./scripts/xctest.sh` with the exact selector,
  `-c Debug` and a fresh result bundle: **1/1** passed.
- The same built products with `xcodebuild test-without-building`, the exact
  selector, parallel testing disabled and `-test-iterations 10`: **10/10**
  passed. `verify-test-results` checked all repetitions against the retained
  built discovery; the summary alone reports one unique test.
- Supported `scripts/xctest.sh -t BleatAppTests` owning gate: **624/624**
  identities passed, including the changed callback. The runner verified exact
  discovered identities and outcomes. All three bundles contain zero failures,
  skips, expected failures and structured runtime warnings.
- Final strict Swift lint, documentation references and `git diff --check`
  passed. The initial lint failure caught one new overlong assertion line;
  wrapping it changed no assertion, budget or behavior. The compiled callback
  object is newer than the final source, whose SHA-256 is
  `f87173ec96570116b8842a3c81327dc7efc16b448c2499bfcf28175874bd66f1`.

Retained bundles are `.build/final-pause/focused.xcresult`,
`repetitions.xcresult` and `owning-app.xcresult`; their built discovery, private
logs, structured summaries and source hash are retained alongside
`.build/final-pause/verification.json`. All commands ran from repository root;
no result-bundle guard correction from a separate PR is included.

Xcode's existing host build-version `invalidDigitCount` diagnostics remain in
all three logs (nine, three and nine respectively). The owning incremental
rebuild also emitted **1,610 stale-file warnings** associated with the temporary
build symlink; no cache or other worktree was deleted. The focused and repetition
logs contain no compiler warning lines. These build diagnostics are distinct
from the zero structured runtime warnings. No host, signed macOS application,
live-server or physical-device run is claimed. Independent final-head review
and exact-head CI remain required before merge.


## Primary fallback recovery completion (#374)

[Validate Bleat run 39562779417](https://github.com/terminaloutcomes/bleat/actions/runs/39562779417),
at `1f7ee5bdea23415178d7dc81dc942b8d4458ac4a`, recorded one failure
among 626 outcomes: `AppModelTests/testTransportFailureUsesChangedPrimaryFallbackExactlyOnce`
observed two fallback tasks before asserting empty pending recovery. The other
625 tests passed, with zero skips, expected failures or structured runtime
warnings. The failing test body is unchanged on baseline `58223214`. An
unchanged-source focused local execution passed once; that pass does not erase
the CI failure.

A private experiment used the existing `replacementTaskStartCheckpoint` to hold
recovery after replacement task registration. It retained the old readiness
predicate and every original transfer assertion. The test failed only at the
intentionally retained pending-empty assertion in **0.94 seconds**: two
replacement tasks were visible while the original callback-completion sequence
remained unchanged. The checkpoint entry assertion proves at least one entry,
not both. Xcode separately timed out after **600 seconds** collecting failure
diagnostics; the raw log and result bundle retain that infrastructure failure.
It is not the test duration or evidence of a cleanup deadlock.

The final test contains no checkpoint instrumentation or production changes.
Its original two-second deadline now waits for both replacement registration
and cleared pending recovery. Exact two-task, primary URL, `Range`, `If-Range`,
descriptor count and track-index assertions remain. Failure diagnostics include
elapsed time, budget, request count, pending recovery, callback sequence and
record state. The sequence is diagnostic, not a completion proxy. Deferred
synthetic-session invalidation and reverse-ordered XCTest teardown ensure
awaited model cleanup precedes checked storage deletion, including thrown waits.
No full framework-callback drainage is claimed.

Retained local artifacts are `.build/primary-fallback-baseline.xcresult`,
`.build/primary-fallback-private-witness.xcresult`, the private witness patch,
source hashes, native summaries and verification records. The baseline has one
compiler sysroot warning for the transcription dynamic product and nine Xcode
host build-version parsing diagnostics. The private witness rebuild emitted
1,610 stale-file warnings plus the same sysroot warning, nine host metadata
diagnostics and the separate 600-second diagnostic timeout. These diagnostics
are distinct from zero structured runtime warnings; no cache was deleted or
warning suppressed.

Final Swift source SHA-256 is
`0427dfe8b9a16b676bd5d63df3fbe15b3a64bb24d6196ba3116a04cd3c40b0c5`.
On Xcode 27.1 / iOS 26.5 Simulator:

- Supported focused `scripts/xctest.sh -c Debug` execution: **1/1** passed.
- Existing built products, exact selector, parallel testing disabled and ten
  unconditional native iterations: **10/10** passed. The summary reports one
  unique test; the canonical verifier checked all ten outcomes.
- Supported `scripts/xctest.sh -c Debug -t BleatAppTests` owning execution:
  **627/627 distinct identities** passed, including the changed test. Native
  outcomes and canonical verification against built discovery with the actual
  `BleatAppTests` selection passed.
- All final bundles have zero failures, skips, expected failures and structured
  runtime warnings. Final focused, repetition and owning logs have zero compiler
  warnings, with respectively nine, three and nine host metadata diagnostics.
- Strict changed-file Swift lint, documentation, audit consistency and diff
  checks passed. The initial lint failure caught one new overlong assertion;
  its wrap-only correction preceded all final test executions. The first
  standalone baseline verification lacked the not-yet-built verifier binary;
  building it completed verification without rerunning the test. An initial
  owning verification used unfiltered discovery and expected unselected UI
  tests; applying the actual app-only selector verified the same bundle without
  a test rerun. Both verification corrections are retained in local evidence.

Final bundles are `.build/primary-fallback-final-focused.xcresult`,
`.build/primary-fallback-final-repetitions.xcresult` and
`.build/primary-fallback-final-owning.xcresult`, with discovery, native summaries,
source hashes, command exits and verification records alongside them. Independent
four-file source review found no actionable issues. Exact-head publication/CI
and final merge remain the coordinator's responsibility. No signed macOS,
live-server or physical-device evidence is added; #374/#362 remain open.
