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
| `AppModelTests/testTenKBooksLoadNextBooksPagePerformance` | Remove the force unwrap constructing `AuthorID` in generated fixture data; make fixture creation report a test failure instead of trapping. | A constructor change or malformed fixture input can terminate the test process before XCTest records a useful failure. | Bleat maintainers |
| `AppModelTests/testSeriesPaginationCoalescesAnInFlightPageWithoutBlockingMainActor`; `testConcurrentSeriesPreparationsQueueGlobalConfirmationsByCompletion`; `testConfirmedSeriesSerializeSharedBookHandoffPerAccount` | Replace one `Task.yield()` used as a competing-task barrier with an explicit admission/queue signal before checking coalescing or request ordering. | Yield only schedules cooperatively and does not establish that the other task reached the intended state; request-count and order assertions can pass before the competing operation is admitted. | Bleat maintainers |
| `AppModelTests/testSetFinishedNewerCommitRejectsOlderDetailReconciliation`; `testSetFinishedReconciliationDoesNotRestoreObsoleteSearch`; `testCompletedReconciliationDoesNotCancelLaterUserSearch`; `testCancelledReconciliationSearchPreservesLoadedResults` | Expose and await reconciliation/search completion (and propagate cancellation) instead of using swallowed `try?` sleeps or yield-count polling before asserting stale work was rejected. | A 100ms delay or up to 50 sleeps does not prove the reconciliation task finished; a late detail/search result could overwrite the assertion after the test returns. One polling loop also suppresses cancellation. | Bleat maintainers |

| `AppModelTests/testRemotePlaybackProgressSyncEmitsOneTypedAttempt`; `testDownloadHTTPMetricsAreRecordedOffMainActorWithoutCacheHits`; `testContinueDownloadMissingLocalAccountHasTypedFailureAndPreservesBytes`; `testRestoredDownloadCallbacksMissingAccountKeepTypedStageAndBytes`; `testDownloadRestorePreservesQuarantinedLegacyTrackAndPresentsTypedCause`; `testNetworkPathUpdateResumesInterruptedDownloadAfterOfflineRelaunch` | Use an asserted bounded condition helper at each asynchronous observation, retaining the wait result, elapsed budget, source location, and observed state in XCTest failures; ensure session and observer cleanup runs on failure. | Current polling is time-bounded but some loops discard whether they observed the condition, or check a nearby but different state. A later callback may arrive after the test or an ordinary failure can lack actionable timeout context. Preserve typed failure and real legacy-persistence assertions. | Bleat maintainers |
| `AppModelTests/testLateTerminalSaveCannotSetFailureForReplacementBatch`; `testTranscriptDeletionWaitsForLateTranscriptSave`; `testAutomaticChapterFileIsPinnedUntilTranscriptionCompletes`; `testRereadClearsPinnedCompletionEvenWhenPlanFails`; `testLocalCompletionWaitsForInFlightAutomaticWork`; `testTransportFailureWaitsForNetworkAndDropsTransientProgress`; `testTransportRetryDoesNotScheduleAfterNetworkDropsDuringBackoff`; `testRetryAfterHeaderDelaysRetryableServerReplacement`; `testPauseIntentPrecedesConcurrentTerminalCallback`; `testLateCancelledTaskCallbackDoesNotRestartDownload`; `testLargeCellularDownloadsPreserveEveryPendingConfirmation`; `testConcurrentDownloadTriggersShareOneBookOperation`; `testFetchedCallbackTimeoutKeepsRetryBlockedUntilDrain` | Replace yield counts and short absence sleeps with a gate entry/completion signal for the operation under test. Make timeout cleanup release continuations, cancel owned tasks, and join their completion before checking absence or ordering. | Scheduler opportunities and short delays do not prove callback processing, retry cancellation, deletion admission, or pin cleanup has settled. Late work can invalidate the asserted result or leave a suspended task behind. Keep each existing late-callback, queue-reset, and persistence assertion. | Bleat maintainers |
| `AppModelTests/testPauseStorageFailureIsVisibleAndDoesNotResume` | Replace the unasserted 100ms settling delay with an asserted bounded wait for the typed storage failure and include caller-site timeout diagnostics; retain relaunch durability assertions. | The delay does not prove the asynchronous pause reached its failure state, so assertions can race and failure evidence is weak. | Bleat maintainers |
| `AppModelTests/testMediaServicesResetRestoresPlayingAndPausedIntent`; `testNaturalBookEndClearsPlayerPresentationAndSystemNowPlaying`; `testNaturalStreamedBookEndSyncsAndClosesSession`; `testNaturalCompletionWaitsForPendingSyncBeforeFinalPositionAndClose`; `testRestartAndAccountSwitchSkipSyncOfNaturallyClosedSessions`; `testMediaServicesResetRebuildsAcrossAudioFileBoundary` | Add explicit AVPlayer readiness, rate, elapsed playback, and relevant position diagnostics before reset/end/boundary assertions; retain bounded playback deadlines and position tolerances. | These scenarios depend on real simulator audio progression. Without readiness and timing diagnostics, a fixture or simulator scheduling failure is hard to distinguish from a product regression, and boundary assertions can run before playback is ready. Simulator evidence is still required. | Bleat maintainers |
| `AppModelTests/testNetworkPathUpdateRetriesPendingLocalSessionsWithoutBlockingLaunch`; `testQualityOnlyAndDuplicatePathsDoNotScheduleModelRecovery`; `testLiveConnectionAttemptsTraceEndpointRoleRetryAndOutcome`; `testConstrainedPathControlsLiveUpdateLifecycleWithoutBlockingREST`; `testPendingLocalSessionUploadDoesNotBlockLaunch` | Isolate defaults from `UserDefaults.standard`; replace break-only polling with asserted transition waits; on failure, release upload gates and cancel/join observer tasks. | Shared preferences can leak between parallel tests or survive abnormal teardown. Break-only loops can continue into assertions without proving the intended transition, and a blocked observer can outlive the test. | Bleat maintainers |
| `AppModelTests/testBookDeletionSupersedesInFlightFailedPlaybackRetry`; `testSetFinishedReconciliationFailureDoesNotReverseCommitOrAlert`; `testSetFinishedUsesRemoteOnlyDetailReconciliation`; `testSetFinishedReconciliationFailuresRecordTypedDiagnostics` | Await the owned retry/reconciliation completion through a signal, then assert one exact request/session outcome and final committed state. | Deadline-bounded polling is better than an unbounded wait but does not establish that independent work finished; accepting a request-count range can hide a duplicate or missing path. | Bleat maintainers |
| `AppModelTests/testCarPlayCellularCancelAndLateCallbacksPreserveNextRequest`; `testCarPlayCellularReconnectAndDelayedPresentationKeepDecision`; `testCarPlayCellularAccountRemovalDismissesAndRejectsOldActions`; `testCarPlaySearchVersionAndCapabilityGatePreservesBrowsing`; `testCarPlaySearchNativeRowsSurviveCapacityChanges`; `testCarPlaySearchAuthorPopCompletesUncooperativeLoad`; `testCarPlaySearchRetryAndNoMatchesRemainExplicit`; `testCarPlaySearchInvalidationCancelsDelayedDetailAndStreamPlayback`; `testCarPlayPresentationRetainsItemsAndSeedsReplacementArtwork` | Use completion/admission signals for stale callbacks and queue transitions; replace artwork-render polling with an observable publication signal or an asserted bounded condition. | The current yield/sleep barriers do not prove the retired callback or artwork update has been processed. A late callback could mutate the next request after the test returns, while a short render poll gives weak failure evidence. | Bleat maintainers |
| `AppModelTests/testTenKBooksLoadNextBooksPagePerformance`; `DeepLinkTests/testParserRejectsMalformedOrAmbiguousLinks`; `AppModelTests/testCarPlaySearchAuthorPopCompletesUncooperativeLoad`; `testCarPlaySearchNewAuthorDoesNotRenderPreviousAuthorDuringLoad`; `testCarPlaySearchAuthorZeroCapacityHasNoStatusSections`; `testCarPlaySearchStaleAuthorRetryAndFailureCapacity`; `testCarPlaySearchAuthorUsesIndependentFilteredPage` | Replace force-unwrapped fixture IDs and URLs with `try XCTUnwrap` or another XCTest failure path before exercising the behavior. | Malformed fixtures or constructor changes currently can terminate the test process instead of recording the failing fixture and allowing XCTest diagnostics. | Bleat maintainers |
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
`Documentation references verified`. Local focused
repetitions and the local owning `BleatAppTests` run are **unexecuted**: destination
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

Focused ten-iteration execution remains required after local Xcode component
installation is authorized. The owning CI suite does not establish those
repetitions. Independent source review cleared this source revision; the PR
remains draft with no merge clearance while that evidence is outstanding.
