# Broader UI regression repair

This repair is based on main `0ed12585dc6726fce2aca2336e99272014810f5d`.
It is separate from PR #475 and does not change that PR's readiness or the
physical-device work deferred in #457.

## Causes and changes

| Boundary | Cause | Correction |
| --- | --- | --- |
| Diagnostics Settings link, including unavailable startup | The iOS 27 accessibility tree exposes the native SwiftUI Link as a Link; the tests queried Buttons after successfully scrolling to the same identifier. The saved baseline hierarchy contains the enabled, visible link. | Resolve the unique identifier without assuming a platform-specific element type; retain enabled/hittable checks and the system Settings control exercise. |
| Start while mini-player Stop cleanup is suspended | Stop retires playback to idle immediately. `canReusePreparedPlayback` still admitted its retained preparation, but `play()` rejects idle, so the new Start silently returned superseded. | Exclude idle players from reuse. An explicit new Start uses normal preparation, permission checks and serialized progress writes. Stop rechecks its generation after statistics completion before resetting or closing a replacement. Ordinary Play after Stop remains rejected. |
| Delayed sync fixture | Release reset the gate to hold again, blocking the replacement preparation's next serialized sync. A concurrent direct caller could also overwrite the single waiter. | Hold only the first sync. Subsequent serialized writes pass through after release; a direct concurrent waiter cannot replace the original continuation. |
| View on server browser handoff | The test waited for Safari foreground, then immediately sampled Bleat foreground independently during the transition. | Bound one joint postcondition: Safari is foreground and Bleat has left foreground. Retain the final Bleat assertion and action interactability checks. Runtime confirmation is recorded below. |

The mini-player journey now observes replacement-generation admission before
releasing the old sync, then verifies the actual Pause label, paused restored
mini-player, and resumed playback. It preserves progress-write serialization.
The generation is exposed only through existing testing diagnostics and the
launch-argument-controlled fixture control.

## Scoped test review

All four UI tests are in `Tests/BleatUITests/BleatUITests.swift`. Every launch
uses its own test-service account, preferences and download storage; system
Settings and Safari run only in the owned disposable Simulator. No personal
app/account/data, security setting or physical device is used.

| Identity | Setup, actions and postconditions | Synchronization and disposition |
| --- | --- | --- |
| `testDiagnosticTelemetryConsentLivesInSystemSettings` | Signed-in fixture with reset consent; open Diagnostics, operate native Settings link and actual default-off system toggle, return to consent display. | Identifier-based scroll and enabled/hittable link; existing bounded system-control waits. Keep system-control coverage; app preference reconciliation remains covered by app tests because XCTest isolates its preference domain. |
| `testSystemSettingsLinkAvailableWhenStartupUnavailable` | Unavailable-startup fixture; open Diagnostics and verify the link remains hittable without an in-app consent switch. | Existing bounded Diagnostics and scroll waits. Fix only the element query. |
| `testMiniPlayerRestoresWhenStopIsSuperseded` | Bundled playable AAC; start, dismiss/Stop with held sync, admit new Start, release old sync, pause replacement, verify restored mini-player and resume. | Bounded playback-label and generation waits establish each transition; no elapsed-time tolerance, blind retry or fixed delay. Gate release belongs to the owning app process; terminating it isolates subsequent tests. |
| `testViewOnServerOpensSystemBrowserWithoutEditPermission` | Limited-permission fixture; open book action menu and invoke View on server without edit authority. | Enabled/hittable action plus joint foreground handoff within the existing 15-second budget. Network page availability is outside this dispatch test. |

App regressions are
`AppModelTests.testPlaybackStartReplacesIdlePlayerWhileStopSyncIsPending`,
`testPlaybackStartRetainsReplacementWhileStopStatisticsFinishIsPending`, and
`UITestPlaybackFixturesTests.testDelayedSyncRetainsFirstWaiterAcrossReplacementAndRelease`.
The two AppModel cases own isolated storage and native media, holding either the
first progress sync or Stop's second statistics finish (outside progress-write
serialization). They verify two session opens, exact old-session closure, native
replacement-player identity, retained paused presentation and subsequent
active-player reuse. The fixture test observes the gate's actual state
change before exercising later waits and release. Owned tasks/gates are cleaned
up through teardown blocks. Position/rate tolerances are inapplicable: these
cases assert intent, identity, presentation and session lifecycle, not exact
advancing media position. No callback adapter changed. No test was skipped or
assertion removed.

## Validation

The fresh unchanged-main reproduction in `.build/four-baseline.xcresult`
executed exactly the four reported UI cases: four failures, zero skips and zero
runtime warnings, with the same failure text as the saved #475 comparison.
Xcode's failure diagnostics collection used its bounded 600-second allowance;
the complete baseline operation took 850.611 seconds.

The corrected focused run in `.build/four-focused-v1.xcresult` executed and
passed all 14 selected cases: the four UI journeys above, the new pending-Stop
restart regression, existing explicit-Stop diagnostic suspension, newer-selection
protection and matching-active-player reuse tests, plus all six
`UITestPlaybackFixturesTests`. Zero failures, skips or runtime warnings; exact
identities and individual outcomes were inspected using `xcresulttool`.

The run used the `Bleat` scheme with a task-owned iPhone 17 Pro Simulator on
iOS 27.0, serial testing, inert telemetry URLs, and a separate derived-data
folder in this worktree. The selection was the four UI methods above,
`BleatAppTests/UITestPlaybackFixturesTests`, and these app methods:

- `testPlaybackStartReplacesIdlePlayerWhileStopSyncIsPending`
- `testPlaybackStartReusesMatchingActivePlayerAndResumes`
- `testExplicitStopPausesBeforeDiagnosticSuspension`
- `testStopCompletionDoesNotRetireNewerSelection`

Strict scoped Swift formatting, `git diff --check` and `mise run docs:check`
passed. Independent read-only review found two defects in the initial test draft
(an unavailable fixture helper and awaiting replacement completion before gate
release); both were corrected before execution. Review of the revised complete
diff found no code findings. A final documentation review raised one P2:
the initial receipt described waiter overwrite as a scoped cause despite progress
serialization. The receipt now identifies rearming after release as the scoped
cause and concurrent overwrite as a prevented latent fixture hazard. That finding
is resolved; no other P2/P3 findings were raised.

The clean repetition run in `.build/four-repetitions.xcresult` passed all four
identities twice (eight executions). Both per-identity `Repetition` nodes were
inspected and passed; zero skips or runtime warnings. This used the same scheme,
owned Simulator and four UI selectors with `-test-iterations 2`.

The required `mise run check` aggregate is running with
`BLEAT_SIMULATOR_DESTINATION` targeting that owned Simulator. It has verified
609 signed host tests with zero skips, Swift Release and Simulator Release
builds, paid-capability configuration contracts, and 663 Simulator app tests
with zero failures, skips or runtime warnings. The app bundle is
`.build/test-core-results/app-tests-37712-1792930492668.xcresult`.
The 126-case UI lane passed with 119 passed, seven existing approved opt-in
skips, zero failures and zero runtime warnings. All four repaired identities
individually passed in the broad bundle:
`.build/test-core-results/ui-tests-37712-1792930492668.xcresult`.
Core live validation passed its unchanged result verifier with 13 passed and
eight configuration-dependent skips. Both disposable app-live journeys then passed with zero skips and runtime
warnings; online/offline bundles are beneath
`TestSupport/ServerHarness/app-live-artifacts/caa19d96-55f6-4939-9c2e-665709752180/`.
The original complete `mise run check` exited successfully in 4886.37 seconds.

A final lifecycle audit subsequently identified the outer statistics-finish
suspension: a same-book replacement can finish while old Stop is held outside
progress serialization, then stale Stop could reset/close it before its next
generation check. The final guard now checks immediately after that await.
The new held-second-finish regression requires replacement completion and native
player identity before releasing old Stop. Independent review found no issues in
this revised source. Final-source focused revalidation passed all 15 selected identities in
`.build/four-final-focused.xcresult`, including both pending-Stop boundaries and
all four UI journeys. Zero skips or runtime warnings; individual outcomes were
inspected. The required aggregate is being repeated on that final source;
the earlier aggregate remains earlier-source evidence.

The original aggregate continued through a model-capacity interruption without
a duplicate run. Process and artifact inspection recovered its active UI lane;
no completed tests were restarted.

CI passed on exact code commit
`e747435ae57a809dd305ed58b5fb8893648a83ba`:
[Validate Bleat](https://github.com/terminaloutcomes/bleat/actions/runs/40190889241),
[release security](https://github.com/terminaloutcomes/bleat/actions/runs/40190889303),
[CloudKit schema](https://github.com/terminaloutcomes/bleat/actions/runs/40190889227),
and [website build](https://github.com/terminaloutcomes/bleat/actions/runs/40190889235).
PR deployment jobs were skipped by their existing event conditions. The final
evidence commit will receive its own exact-head CI verification.

Independent read-only review of that exact code commit confirmed no remaining
findings after the documentation correction.
This draft evidence does not claim complete validation or physical-device
acceptance.
