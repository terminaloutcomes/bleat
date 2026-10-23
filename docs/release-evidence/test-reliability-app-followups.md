# App test reliability follow-ups

Issue [#362](https://github.com/terminaloutcomes/bleat/issues/362) owns this
work. This record tracks source-level findings from the `BleatAppTests` audit.
All follow-ups are owned by the Bleat maintainers; bounded remediation issues
are linked where created. The per-test source evidence is recorded in
`TestSupport/TestAudit/app.json`.

The original 593-record source audit is historical. The [#369 known-entry repair](test-reliability-audit.md#known-85-entry-reconciliation-369) adds 25 missing primary records after individual body/helper review, bringing `app.json` to 627 current records (602 already existed). New records retain specific rule assessments and follow-ups; they do not certify complete compliance or fresh execution. The separate 71 app semantic rechecks remain open, and new source concerns are not additional demonstrated bugs. The 10 async-gate
test declarations in `TestAsyncGateTests.swift` are excluded here and are covered
by the parent audit; shared gate helpers live in `TestAsyncGates.swift`. Open
items below are historical findings and their current dispositions after source review.

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


## Single incomplete-track recovery fixture (2026-10-23)

`AppModelTests/testNetworkRecoveryReplacesStaleBackgroundTransfer` failed in
PR #458's original CI run `39930304040` at dependency-only head
`6c8c5561081eff5e22b667b9f7604d166410a44e`. One test identity failed four
assertions: track 0 was scheduled instead of track 1, with range offset 0 and
length 4 instead of offset 5 and length 3, and the authorized request targeted
track 0. The dependency update did not establish a causal connection to this
failure. The original CI log and server-side iOS result artifact are retained.

The fixture left both tracks incomplete. Plan recovery prioritizes the partial
second track, while native cancellation recovery legitimately selects the first
incomplete track. A controlled diagnostic held the recovery planner at its
existing gate, admitted the real native cancellation callback at the existing
callback checkpoint, awaited callback completion and then released the planner.
Both modes reproduced the same four failures: one executed identity, eight
assertion failures, with every gate-entry/completion check passing. This is a
fixture assumption defect, not evidence of a production scheduling defect.

The final correction commits track 0's four synthetic bytes through
`DownloadStorage`, then asserts that track 1 is the only incomplete track and
the next manual-recovery identity. The shared interrupted-download helper is
unchanged. Every original postcondition remains: both startup and network-change
recovery, native cancellation completion, off-actor repeated retired callback,
exactly one new transfer ID for track 1's remaining three-byte suffix, five
retained bytes, one active admission and authorized request, empty pending
recovery, no model failure and final descriptor cleanup. Temporary gates/tasks
are absent from the final test. Existing teardown ownership and bounded waits
are unchanged. No production source changes or timing sleeps are added.

On Xcode 27.1 / iOS 26.5 Simulator, three unconditional native repetitions of
the corrected test passed (one unique identity, two recovery modes per
repetition), with zero failures, skips, expected failures or runtime warnings.
The supported `scripts/xctest.sh -c Debug -t BleatAppTests` owning run
passed all **641 distinct identities**, including this test, with zero failures,
skips, expected failures or runtime warnings. The runner verified native results
against built discovery. The Swift source SHA-256 remained
`233a2c51068218c1c4442e8e5a1107e167bedc529fa9c67854e536a70bbffe4a`
through both final runs. The focused log retains three Xcode host build-version
metadata diagnostics; the owning log retains nine. Neither final log contains
compiler warnings. These diagnostics are separate from structured runtime
warnings. Strict Swift lint, documentation and scoped audit consistency checks
passed. Independent review of the final correction/audit/evidence found no
actionable issues.

Retained artifacts are `.build/ctutils-recovery-order-baseline.xcresult`,
`.build/ctutils-recovery-fixture-focused.xcresult`,
`.build/ctutils-recovery-fixture-owning.xcresult`, their logs/execution receipts,
and the diagnostic source/input hashes. The original CI failure remains distinct
from the controlled diagnostic and corrected-source executions. This provides
Simulator fixture/callback evidence, not live-server, signed-host or physical
background-transfer acceptance. #362/#374 remain open.

## Fixed app context review and observable returns (#374)

This completes the final **71 app identities** in the fixed historical review cohort: **58 bounded KEEP conclusions and 13 corrected test gaps**. Together with the preserved 241 core dispositions, the [identity ledger](../../TestSupport/TestAudit/review-queue-reconciliation.json) now contains **312 completed scoped reviews and zero pending identities**. This is completion of that finite review cohort, not a claim that the whole epic, every native teardown path, security review or physical acceptance protocol is complete. No new production defect is inferred from a test gap.

Original source review used `ea413942`; the corrected code was committed as `ed91325` and rebased onto core `168e143` (current source commit `59b414e3069e73687f57027e620f2e4c74cd0b6f`). Earlier app audit fields and all partial/historical execution receipts remain unchanged. The additions below supersede only the specified current test findings.

The corrections register owned cleanup before failing waits/early returns, acknowledge actual callback/task returns before negative state assertions, remove an unwired expectation, and retain the original state/request/typed-error oracles. DEBUG return counters establish their named model/adapter boundaries; they do not certify complete native framework shutdown. Five Release-only cases receive scoped source decisions, not a fabricated Debug pass.

| Stable record | Test | Current disposition and boundary |
| --- | --- | --- |
| `AUD-A-f3103614053f` | `AppModelTests/testRemotePlaybackProgressSyncEmitsOneTypedAttempt` | KEEP: Starts a streamed preparation backed by local CAF; Pause initiates sync; exact one-span equality checks remote source/no retry/succeeded. Synthetic service and tracer; no real server metrics; subsequent Stop is intentionally outside the one-attempt oracle. |
| `AUD-A-bc8dafa98b06` | `AppModelTests/testDownloadHTTPMetricsAreRecordedOffMainActorWithoutCacheHits` | KEEP: Detached call submits two decoded transaction batches; exact three network spans require302/cancelled/cannotFindHost and correct download endpoint. Exercises decoded metrics-recording boundary, not actual URLSessionTaskMetrics collection/cache behavior. |
| `AUD-A-39aacc88949c` | `AppModelTests/testTranscriptDeletionWaitsForLateTranscriptSave` | KEEP: Held save gate precedes deletion task; .deleting admission must precede zero-deletion assertion; final persistence order saved then deleted plus cache absence. No filesystem transcript deletion/native speech-engine proof; task.value has no independent test deadline but is not a guessed drain. |
| `AUD-A-8bf36adc353e` | `AppModelTests/testAutomaticChapterFileIsPinnedUntilTranscriptionCompletes` | KEEP: Creates finalized automatic-cache second track; while transcriber held, requires cleanup evaluation acknowledged and both record/file retained; after success requires record removed. Injected transcriber with local media; no actual speech-service result; terminal/cache waits bounded. |
| `AUD-A-b85cd230fc25` | `AppModelTests/testRestoredDownloadCallbacksMissingAccountKeepTypedStageAndBytes` | KEEP: Native ephemeral URLProtocol delivers206suffix or401 off actor; wait on presented local-context missing-account; exact stage/cause/status plus retained5or7bytes. Native local URLProtocol callback; no live-server auth or physical daemon claim. |
| `AUD-A-09f8cb1a6760` | `AppModelTests/testRereadClearsPinnedCompletionEvenWhenPlanFails` | KEEP: Pinned after-book completed cache remains complete during ordinary progress, then explicit unfinished/reread clears date, deferred cleanup count0, pin release retains record and persisted nil. Failure is injected plan503; checks metadata/pin cleanup intent, not background-download network. |
| `AUD-A-b2f0a730936e` | `AppModelTests/testLocalCompletionWaitsForInFlightAutomaticWork` | KEEP: For finished and unfinished cases, hold plan lookup, start progress and completion; waiter count1 proves admission; unchanged old date before release and exact new date in model/storage after joins. Controlled service failure after release; joined caller operations, not unrelated queues. |
| `AUD-A-d61e73ebc315` | `AppModelTests/testTransportFailureWaitsForNetworkAndDropsTransientProgress` | KEEP: Observe7displayed bytes, terminal off-line callback completion+pending identity, require durable5/no tasks/typed offline telemetry; network recovery yields one track1 replacement. Manual delegate calls for progress/terminal, fake requests; not physical network or daemon evidence. |
| `AUD-A-569fea29b3dc` | `AppModelTests/testTransportRetryDoesNotScheduleAfterNetworkDropsDuringBackoff` | KEEP: Hold retry sleeper, require OS handoff on iOS while held, count1; set unavailable, release, require callback completion; no descriptors, exact pending ID, waiting state and Pause count0. PR447 partial evidence covers OS handoff only; explicit callback/fake sleep, no real timer/network recovery. |
| `AUD-A-ba0ed7ec9377` | `AppModelTests/testRetryAfterHeaderDelaysRetryableServerReplacement` | Corrected: Release retry gate and invalidate ephemeral session on every exit; bounded actual callback return before model/root cleanup; bounded gate admission with caller diagnostics. Reconstruction shares same filesystem; does not simulate real elapsed120seconds, server or process restart. |
| `AUD-A-b041657601bb` | `AppModelTests/testPauseIntentPrecedesConcurrentTerminalCallback` | KEEP: Pause task held at checkpoint; actual ephemeral terminal-failure callback acknowledged before checking paused intent/no failure; release joins Pause and final manifest paused. Real native callback delivery through URLProtocol, injected pause checkpoint; no physical transfer claim. |
| `AUD-A-f0514d112a2a` | `AppModelTests/testPauseStorageFailureIsVisibleAndDoesNotResume` | KEEP: Injected commit completes final track then throws persistenceFailed; exact storageUnavailable/failed manifest/complete finalized entry/no paused intent/no descriptors; new model remains failed; remove result exact. Controlled persistence failure; finalized entry state/placement asserted but not separate byte-content comparison. |
| `AUD-A-2fa08ca018dc` | `AppModelTests/testLateCancelledTaskCallbackDoesNotFailContinuedDownload` | KEEP: Pause/continue establish new transfer ID; real old-task URLProtocol callback processed; exact retained new transferID/count1/downloading/no failure/no recovery/partial5/no finalizedfile. Native old callback delivery with synthetic response; no real OS resume/physical background evidence. |
| `AUD-A-ca76784a5b3d` | `AppModelTests/testNetworkPathUpdateResumesInterruptedDownloadAfterOfflineRelaunch` | KEEP: Start with offline plan failure and no descriptor; register service path observer; switch plan then emit path; require one replacement track1 at durable offset5. AppModel wiring through fake path stream, no real NWPathMonitor/daemon. |
| `AUD-A-d1de5310f4fd` | `AppModelTests/testLargeCellularDownloadsPreserveEveryPendingConfirmation` | KEEP: Above-threshold plan queuesfirst/second; automatic work cannot bypass; cancel promotessecond; reset clears; later confirm registersone record before duplicate trigger and leaves no extra pending decision. Guard returns when policy selection unsupported; credit semantic assertions only on supported iOS, not a counted macOS acceptance pass. |
| `AUD-A-d43571547741` | `AppModelTests/testMediaServicesResetRestoresPlayingAndPausedIntent` | KEEP: Native CAF readiness established before reset; playing and paused branches require item ready, timeControlStatus/rate appropriate and exact1.35 preference/two activation calls. Calls production reset handler directly; fake audio-session activation. Not actual media-daemon reset or physical output. |
| `AUD-A-33ceeeb3bdc8` | `AppModelTests/testNaturalBookEndClearsPlayerPresentationAndSystemNowPlaying` | KEEP: Both ordinary/paused-then-resumed scenarios establish readiness; real local playback reaches ended/duration; exact flags and injected NowPlaying info/state clear plus canonical final position. Actual local AVPlayer natural end; injected system-info publisher, no physical lock-screen visibility proof. |
| `AUD-A-9befbe3000a2` | `AppModelTests/testNaturalStreamedBookEndSyncsAndClosesSession` | KEEP: Local CAF presented as streamed session; readiness then ended+close positive witness; synced contains session, exact one close; after Stop sync sequence unchanged and still one close. Fake service proves orchestration, not remote-server session acceptance or network completion. |
| `AUD-A-5f79d3db78e9` | `AppModelTests/testNaturalCompletionWaitsForPendingSyncBeforeFinalPositionAndClose` | KEEP: Held first sync admitted after Pause; resume to actual end; before release close listempty and sync count1; after release close plus exactlytwo positions with final duration and one close. Local AVPlayer + controlled service sync; does not prove real server ordering. |
| `AUD-A-237119884166` | `AppModelTests/testRestartAndAccountSwitchSkipSyncOfNaturallyClosedSessions` | KEEP: Two native completions require matching close counts and selected session; second start leaves prior sync list unchanged; account-switch stop adds no sync and leaves idle. Same synthetic account/session service; explicit closing identity/count test, not physical account switch. |
| `AUD-A-0aed5c2b14d5` | `AppModelTests/testMediaServicesResetRebuildsAcrossAudioFileBoundary` | KEEP: Two local tracks; establish ready, await seek to second boundary, reset, require requested playback/currentTime within0.1 plus ready/playing and fileindex1. Direct reset handler and fake activation, local native queue; no media-daemon reset evidence. |
| `AUD-A-a13faa56de0e` | `AppModelTests/testNetworkPathUpdateRetriesPendingLocalSessionsWithoutBlockingLaunch` | KEEP: Unique defaults/store retains session; initial started/completed/observer events and one request; success result/path event leads second started/completed and empty pendingstore/exact2requests. Source-reviewed app wiring and durable local state; no actual network/remote sync claim. |
| `AUD-A-c4f49c0f4d1f` | `AppModelTests/testQualityOnlyAndDuplicatePathsDoNotScheduleModelRecovery` | KEEP: Establish initial/recovery sync completions and subscriber; emit100qualitychanges + finalspecificstate marker; exact pendingstate and accounts/library/sync/start/stop counts unchanged. Bounded app-handler scope; no real NWPathMonitor/load/physical network evidence. |
| `AUD-A-ce1f0f16dbaa` | `AppModelTests/testLiveConnectionAttemptsTraceEndpointRoleRetryAndOutcome` | KEEP: Emit exact localfailed + primaryauthenticated attempts; four consumed markers precede exacttwo structured spans; pending third attempt consumed then owner restart synchronously cancels its span. Synthetic live-events service/tracer, not socket/collector/server; no string matching. |
| `AUD-A-6b0a476a5592` | `AppModelTests/testConstrainedPathControlsLiveUpdateLifecycleWithoutBlockingREST` | KEEP: Signals consumed eachconstrained/available/expensive/unavailable transition; exact lifecycle counts/subscriber and paused playback identity/time/rate/state/chapter; REST count increments; recovery finishes catchup exactlyonce. Fake path/REST/live service, local AVPlayer; no physical cellular/LowDataMode or audible route proof. |
| `AUD-A-787d21d32791` | `AppModelTests/testPendingLocalSessionUploadDoesNotBlockLaunch` | Corrected: Register gate-release and actual launch/upload terminal settlement before resource cleanup; retain launch budget and exact pending upload assertions. Controlled service upload; no real network stall/transport timeout proof. |
| `AUD-A-d2d7bfd79563` | `AppModelTests/testFetchedCallbackTimeoutKeepsRetryBlockedUntilDrain` | Corrected: Release held private-cloud drain on early exit; bounded request admission and cancellation return; retain typed timeout, stopping and blocked retry assertions. Synthetic CloudKit callback/drain service, not real CloudKit/device. |
| `AUD-A-dc6beab0fb21` | `AppModelTests/testLiveProgressPatchesOneItemWithoutReloadingBrowsing` | Corrected: Disable live updates on all method exits including guarded shelf return; retain exact state/request deltas. Three emitted updates are a synthetic stream/coalescing scenario, not a live-server or physical subscription test. |
| `AUD-A-8a47ca94b5e9` | `AppModelTests/testLiveProgressRefreshesOnlyAffectedOpenDetail` | KEEP: Unrelated item adds only one progress request; target duplicates update the exact loaded detail and last progress-request item, preserving other request counts. No real socket/server or account persistence claim. |
| `AUD-A-bd4b54bd4c5e` | `AppModelTests/testLiveRefreshStaysSuspendedAcrossBackgroundNetworkRecovery` | KEEP: Background path application leaves all request counters unchanged and no subscriber; foreground activation adds exactly one libraries/allProgress/page/shelves refresh. Background is model lifecycle injection, not OS suspension or physical network evidence. |
| `AUD-A-654080a16eac` | `AppModelTests/testLiveRefreshCancelsQueuedCatalogChangeOnBackground` | KEEP: Consumed catalog event and same-stream authentication marker precede backgrounding; cancelled refresh completion leaves full request-count tuple unchanged. Completion proves the queued batch returned; not arbitrary task-graph drainage. |
| `AUD-A-2141873a17d4` | `AppModelTests/testLiveRefreshStopsInFlightCatalogCascadeOnBackground` | KEEP: Held all-progress request is entered, then background/release completes the batch; only allProgress count increases, excluding downstream catalog cascade. Injected service cascade only; no live server. |
| `AUD-A-d9e021518ef2` | `AppModelTests/testLiveProgressDoesNotReplaceNewlySelectedDetail` | KEEP: Hold old-item progress refresh, select different exact detail, release old work, and require the new detail unchanged. Does not assert new-selection network latency or every item field independently beyond structural detail equality. |
| `AUD-A-65d7c7511b86` | `AppModelTests/testLiveProgressDoesNotCancelInFlightCatalogRefresh` | KEEP: Progress consumed while all-progress catalog work is held does not cancel it; final libraries/pages/shelves/progress deltas each match the intended merge. Merge/coalescing scope, not all refresh scheduling cases. |
| `AUD-A-484af081983b` | `AppModelTests/testLiveProgressInsertsReordersAndHidesContinueListeningItem` | Corrected: Disable live updates on every method exit; retain exact insertion/order/hide and request assertions. First shelf total2 is checked; second removal checks items, not a broader server shelf protocol. |
| `AUD-A-ab2f845cdf79` | `AppModelTests/testLiveProgressFetchesOnlyMissingItemToCreateContinueListening` | KEEP: Known empty page plus progress creates continue-listening shelf from exact detail summary with only one additional detail and one progress request. Synthetic missing-item recovery, not live-server/API compatibility. |
| `AUD-A-920b114f84af` | `AppModelTests/testLiveProgressRefreshesFilteredPagesOnlyWhenMembershipChanges` | KEEP: Progress entering notStarted filter removes item with one page refresh; subsequent progress movement only adds progress fetch, not a second page request. One progress filter and one membership transition, not all filter modes. |
| `AUD-A-277cf7888de6` | `AppModelTests/testLiveProgressClearsRemovedProgressFromOpenDetail` | KEEP: An event with absent fetched progress replaces exact open detail with progress nil. This intentionally tests missing progress, not corruption or every progress field. |
| `AUD-A-6eff52d3f3e7` | `AppModelTests/testLiveProgressEchoDoesNotRefreshStreamedPlayback` | Corrected: Register owned player stop/live cancellation before fixture file/default cleanup via LIFO blocks; preserve consumed-echo no-refresh assertions. Prepared-state witness is not physical advancing-audio/route evidence. |
| `AUD-A-a80d9b215ad7` | `AppModelTests/testLiveProgressSuppressionIsScopedToPlaybackAccount` | KEEP: Same item playing under other account must not suppress browsing-account progress refresh; exact counter tuple adds progress1 and playback ownership remains other account. One cross-account suppression boundary, with in-memory fake service and generated media. |
| `AUD-A-693a1222ca6d` | `AppModelTests/testLiveProgressUpdatesFinishedStateImmediately` | KEEP: Current account/item echo and finished event do not fetch/schedule; finished flag updates while selected book, position, rate, state and chapter stay unchanged and paused. Paused snapshot comparison uses .01seconds/.001rate; does not establish advancing clock, server or hardware behavior. |
| `AUD-A-e8184fe3c7ce` | `AppModelTests/testSeriesDownloadPreparationLoadsEveryPage` | KEEP: Three one-item pages yield exact ordered three-book list, accumulated page2/limit1/total3 and page-request suffix0,1,2. Pagination/accumulation scope only; does not execute download transfers. |
| `AUD-A-2e12f7b1c501` | `AppModelTests/testConcurrentSeriesPreparationsQueueGlobalConfirmationsByCompletion` | KEEP: Duplicate preparation rejected; second completed series stays presented while first finishes, then cancellation exposes first and empties queue. One-second modal predicates are bounded state waits; no real transfer or global OS queue proof. |
| `AUD-A-bc8b4cc2cb00` | `AppModelTests/testConfirmedSeriesSerializeSharedBookHandoffPerAccount` | Corrected: Release both gates on early exit and acknowledge both awaited series submissions via active-key retirement; preserve exact serialized handoff assertions. Current assertions establish admission serialization, not completed downstream download handoff or failure cleanup. |
| `AUD-A-73a4d8363725` | `AppModelTests/testBookDeletionSupersedesInFlightFailedPlaybackRetry` | KEEP: Initial playback starts, failed retry is held during close, deletion starts, competing start and retry return superseded; final player idle/mini hidden and every opened session closes in the expected order. One/two opens are explicitly allowed race paths and matched by exact corresponding close lists; does not prove a unique open cardinality or physical playback. |
| `AUD-A-da1186522406` | `AppModelTests/testSetFinishedNewerCommitRejectsOlderDetailReconciliation` | KEEP: Older finished reconciliation held while newer not-finished commit/reconciliation proceeds; after both completions model and loaded detail cannot regain finished status. False-or-nil progress is accepted intentionally by oracle; proves rejection of obsolete finished state, not preservation of every progress field. |
| `AUD-A-9fa0913e9070` | `AppModelTests/testSetFinishedReconciliationDoesNotRestoreObsoleteSearch` | KEEP: Hold reconciliation home refresh, issue new user search, release and complete; exact query list stays Old,New and current query New. Query ownership/count scope, not every search-result field or network cancellation mechanism. |
| `AUD-A-bc10091ed6c9` | `AppModelTests/testCompletedReconciliationDoesNotCancelLaterUserSearch` | KEEP: First reconciliation finishes; user search enters gate; second reconciliation enters final detail gate; user search completes before final reconciliation and remains loaded/User afterward. Loaded search and query are checked, not exact full result content. |
| `AUD-A-ac2df8b20a9f` | `AppModelTests/testCancelledReconciliationSearchPreservesLoadedResults` | KEEP: After initial exact search results, held reconciliation search is superseded by a denied newer update; final query/results equal initial and permissionDenied is retained. Synthetic403 and cancelled older reconciliation; not all operational errors or live search transports. |
| `AUD-A-9c5db95498ea` | `AppModelTests/testSetFinishedReconciliationFailureDoesNotReverseCommitOrAlert` | KEEP: After local finished commit, catalog/home refresh503 failures cannot reverse finished state or publish bookProgressFailure before/after acknowledged reconciliation. Checks committed bit and mutation failure channel, not all possible failure presenters. |
| `AUD-A-8dcf64c2a7f7` | `AppModelTests/testSetFinishedUsesRemoteOnlyDetailReconciliation` | KEEP: One remote-only refreshed-detail503 leaves committed loaded finished detail and no mutation failure, and emits typed loadBook/bookUnavailable diagnostic. Remote-only fetch count is1; diagnostic containment is existence, not an exactly-once log assertion. |
| `AUD-A-6908581917ff` | `AppModelTests/testSetFinishedReconciliationFailuresRecordTypedDiagnostics` | KEEP: Detail503 and search503 reconciliation emit distinct loadBook/bookUnavailable and search/serverUnavailable events while committed finished detail and loaded prior search survive. Checks loaded search state, not exact prior search payload; logs are required-presence rather than exclusivity. |
| `AUD-A-a15fb8f11595` | `AppModelTests/testCarPlayCellularCancelAndLateCallbacksPreserveNextRequest` | Corrected: DEBUG exact +2 actual stale action returns before negative request-state oracle. The helper can disconnect before late Tasks run, invalidating them and masking an adapter regression; no physical CarPlay claim. |
| `AUD-A-8f0895b3561b` | `AppModelTests/testCarPlayCellularReconnectAndDelayedPresentationKeepDecision` | Corrected: DEBUG exact +1 actual old Cancel return before replacement decision oracle. Synchronous presentation callback generation handling is partly checked; later success does not uniquely acknowledge the stale action return or transient clobbering. |
| `AUD-A-fa60d78c388b` | `AppModelTests/testCarPlayCellularAccountRemovalDismissesAndRejectsOldActions` | Corrected: DEBUG exact +2 actual stale action returns before empty state oracle. Does not establish that late registered adapters rejected work before teardown generation invalidation. |
| `AUD-A-0c89695330fa` | `AppModelTests/testCarPlaySearchVersionAndCapabilityGatePreservesBrowsing` | Corrected: Remove unwired expectation; disconnect native coordinators and disable live updates on every exit; retain positive native template push witness. Positive iOS27 branch was NOT executed in this review; no runtime failure or native27 acceptance is claimed. The source-level unwaited expectation is the finding. |
| `AUD-A-c09810d447f5` | `AppModelTests/testCarPlaySearchNativeRowsSurviveCapacityChanges` | KEEP: Retained row survives capacity0→2 selection and invokes play exactly once; shared results list has no sections when capacity returns0. Native templates under injected limits, not hardware head-unit capability or every row kind. |
| `AUD-A-fd64d5faa505` | `AppModelTests/testCarPlaySearchAuthorPopCompletesUncooperativeLoad` | Corrected: Preserve early public completion; DEBUG acknowledge actual selected task return before late negative oracle. Failure cleanup distinguishes outer adapter rejection from admitted inner task via callback/admission counters. Early pop-completion behavior is proven; post-response suppression and failure cleanup are not fully established. |
| `AUD-A-cff890f0aac9` | `AppModelTests/testCarPlaySearchRetryAndNoMatchesRemainExplicit` | KEEP: Enabled retry row from503 reruns same exact title query, then renders explicit No title or author matches after empty success; exact requests title,title. One typed retry/empty path; no live-server or hardware search evidence. |
| `AUD-A-8840b87e0c05` | `AppModelTests/testCarPlaySearchRapidQueriesSupersedeDebounceWithoutRequests` | KEEP: Three rapid a,ab,ab callbacks plus clearing all return empty; exactly3 rapid completions and no service request. Proves cancellation before debounce sends requests for these inputs, not every arrival timing or physical keyboard behavior. |
| `AUD-A-fa2c3526c02c` | `AppModelTests/testCarPlaySearchInvalidationCancelsDelayedDetailAndStreamPlayback` | KEEP: Both detail-held and stream-held selection invalidation complete callback once, clear target, finish superseded, leave playback unrequested; stream-opened path closes exactsession. Unlike author-pop negative case, terminal outcome changes fromnil tosuperseded after release. Not physical CarPlay/audio routing. |
| `AUD-A-de3733d19aea` | `AppModelTests/testCarPlayPresentationRetainsItemsAndSeedsReplacementArtwork` | KEEP: Initial image2x2 actually installed, same-context refresh retains identical row object/image, library switch replaces row identity while seeding exact cached image dimensions. Dimensions/identity prove install/reuse, not pixel identity or physical visual contrast; bottom-only disconnect is a cleanup limitation, not a newly demonstrated leaked held task. |
| `AUD-A-b77c9b0aea98` | `AppModelTests/testCarPlayCompletedDownloadIsPreferredOnline` | KEEP: Seeded complete local record selected from online CarPlay Home invokes callback, opens zero streamed sessions and pushes shared NowPlaying template. Local preference/navigation scope; does not prove physical playback, every verified byte or offline network behavior. |
| `AUD-A-aacdb75106c2` | `FrameworkCallbackTests/testActualPlayerKVOCallbackRunsOffMainActor` | KEEP: Real AVPlayer volume mutation in detached task delivers exact observed player through PlaybackObservation.handler to isolated MainActor. One real volume KVO boundary, not all player keys, removal races or physical outputs. |
| `AUD-A-6b4f6fa35042` | `NetworkPathTests/testStaleProbeCannotPromoteEndpointOrReviveStoppedSubscription` | Corrected: DEBUG actual probe-processing returns +1/+2 are acknowledged before stale/stopped negative state assertions; original Release scenario remains. A schedule where path2/stop occurs before subscription enters endpoint wait lets subscription return before oldprobe processes. This is a test-oracle gap, not an observed endpoint promotion bug. |
| `AUD-A-538fef482652` | `NetworkPathTests/testNetworkDiagnosticsContainOnlyTypedReasonAndStage` | KEEP: One typed qualityOnly/pathClassification event survives Codable round-trip structurally, retains exact reason/stage and renders expected typed keys without IP prefix. Factory only accepts typed reason/stage, confirmed in Diagnostics.swift494. This is not adversarial payload redaction or all diagnostic-production coverage. |
| `AUD-A-1221dc516879` | `ReleaseSecretLeakageTests/testCaptureInitialTokensAndForceRefresh` | KEEP: Exactlyone session credential is decoded; replacement retains refresh token and swaps access for unique rejected marker; TokenVault save plus initial manifest preserve three scanner canaries. Enabled only BLEAT_RELEASE_SECRET_SCAN&&iOS; alone prepares invalidation rather than independently proving refresh. Existing accepted full Release execution remains credited, not rerun. |
| `AUD-A-5f9c3a84dbe8` | `ReleaseSecretLeakageTests/testCaptureRotatedTokens` | KEEP: After required refresh journey, exactlyone credential has both access and refresh values different from initial manifest; writes rotated canaries. Stateful protocol case, not arbitrary-order independent test or generic token-validation proof; accepted Release execution preserved. |
| `AUD-A-c87e9af3f187` | `ReleaseSecretLeakageTests/testRemovePrivateCapture` | KEEP: Idempotently removes capture directory and asserts absence; outer workflow copies both required manifests immediately before this invocation, establishing positive prior capture. Standalone test could pass for already-absent directory; it is reviewed KEEP only in supported ordered Release gate. |
| `AUD-A-104c5ff3f088` | `ReleaseSecretLeakageTests/testLogoutRemovedSessionCredentials` | KEEP: After outer logout UI journey, queryall session-service Keychain items returns empty, including synchronizable-any match. No independent logout action here; checks session tokens only, not every credential class or native-login retention policy. |
| `AUD-A-31533ae4f845` | `ReleaseSecretLeakageTests/testPrivateCaptureRemainsRemovedAfterLogout` | KEEP: After explicit capture removal and later logout journey, capture directory remains absent across intervening app invocations. Conditional stateful Release-only test; no standard-suite execution or newly performed scan is claimed. |

Fresh retained Debug validation on the iPad Simulator passed **13 corrected cases plus two related cases** in each of three fixed focused runs, then the canonical **641 owning identities**, with zero failures, skips or structured runtime warnings. Exact identity intersection independently verifies **66 of these 71 cohort identities** in that owning receipt. The five absent identities are the ReleaseSecretLeakage cases listed below; their absence is configuration-specific, not a skipped Debug test or a new test omission.

- `ReleaseSecretLeakageTests/testCaptureInitialTokensAndForceRefresh`
- `ReleaseSecretLeakageTests/testCaptureRotatedTokens`
- `ReleaseSecretLeakageTests/testLogoutRemovedSessionCredentials`
- `ReleaseSecretLeakageTests/testPrivateCaptureRemainsRemovedAfterLogout`
- `ReleaseSecretLeakageTests/testRemovePrivateCapture`

Retained receipt: `.build/app-semantic-local-verified.json`; its source hashes and original execution epoch must remain attached to these runs. Same-process model mocks, local media, fake network/CloudKit/attestation, native-template adapters and controlled callback witnesses have their per-record limits above. Accepted AirPods, background recovery, VoiceOver and prior ordered Release results remain credited independently. macOS work remains deferred; #457/iBook and the separate zip findings are untouched.

Release build-for-testing passed on the restored source (23 October, 14:46:13–14:51:31 UTC), using the repository's existing Release-secret-test fixture configuration: testability enabled, fake telemetry attester with loopback endpoints, and `BLEAT_RELEASE_SECRET_SCAN`. This verifies compilation with DEBUG disabled, including the Release-only test bodies; no Release runtime, archive or secret scan was run. The preceding misconfigured attempt exited65 at metadata preflight because the required telemetry URL was absent; zero native tests ran, and that failure is retained. Existing package sysroot warnings remain retained. The3GiB guard did not trigger; free space was13.24GiB afterward. All five source hashes still match the15×3/641 Debug receipts.

The controlled stale-adapter witness produced native exit 0 with the old oracle and exit 65 with the corrected oracle, containing exactly one named completion-watchdog failure. In both phases, two stale adapters were positively admitted and remained held with zero returns while both negative state oracles were evaluated. Exported runner stdout verifies that cleanup subsequently released both and observed exactly two actual returns (verified true); both modified source files were restored byte-for-byte and the owned groups were absent. The witness-only 1-second watchdog isolates this sensitivity check; the real tests retain their 30-second budget. These intentional negative outcomes remain separate from the clean repetitions and owning run.

The second RetryDelayGate consumer, `testRetryAfterExpiryAndNetworkRecoveryScheduleOneTransfer`, passed in the 641-case owning run; it was not one of the 15 focused cases.
