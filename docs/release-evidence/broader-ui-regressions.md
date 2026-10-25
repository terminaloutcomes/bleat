# Broader UI regression repair

This repair is based on main `0ed12585dc6726fce2aca2336e99272014810f5d`.
It is separate from PR #475 and does not change that PR's readiness or the
physical-device work deferred in #457.

## Causes and changes

| Boundary | Cause | Correction |
| --- | --- | --- |
| Diagnostics Settings link, including unavailable startup | The iOS 27 accessibility tree exposes the native SwiftUI Link as a Link; the tests queried Buttons after successfully scrolling to the same identifier. The saved baseline hierarchy contains the enabled, visible link. | Resolve the unique identifier without assuming a platform-specific element type; retain enabled/hittable checks and the system Settings control exercise. |
| Start while mini-player Stop cleanup is suspended | Stop retires playback to idle immediately. `canReusePreparedPlayback` still admitted its retained preparation, but `play()` rejects idle, so the new Start silently returned superseded. | Exclude idle players from reuse. An explicit new Start uses normal preparation, permission checks, serialized progress writes and generation guards. Ordinary Play after Stop remains rejected. |
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
`AppModelTests.testPlaybackStartReplacesIdlePlayerWhileStopSyncIsPending` and
`UITestPlaybackFixturesTests.testDelayedSyncRetainsFirstWaiterAcrossReplacementAndRelease`.
The first owns isolated storage, native media and a controlled first-sync gate;
it verifies two session opens, old-session closure, retained paused presentation
and subsequent active-player reuse. The second observes the gate's actual state
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

Clean UI repetitions and the required aggregate validation are still pending.
This draft evidence does not claim complete validation or physical-device
acceptance.
