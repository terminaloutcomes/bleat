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

## Validation and execution evidence

The source is based on main `0ed12585dc6726fce2aca2336e99272014810f5d`.
Production code is `c19f8d459abd09bef088e23eb0267e6b6a98a0b9`.
A later CI-discovered checkpoint-test oracle correction changes only that
existing test and this receipt; production, UI, host and live inputs remain
unchanged. Its focused/owning-app revalidation and exact final head are recorded
in the validation comment. The authoritative completed aggregate outcomes, final SHA,
artifact paths and exact-final-head CI links are kept in the
[PR validation comment](https://github.com/terminaloutcomes/bleat/pull/476#issuecomment-6397997492).
That comment distinguishes running stages from completed results. This receipt
credits only the completed outcomes stated below.

| Selection/revision | Verified result | Artifact |
| --- | --- | --- |
| Four unchanged-main UI cases | All four reproduced the reported failures; zero skips/runtime warnings. Failure text matches the saved #475 comparison. | `.build/four-baseline.xcresult` |
| Initial repair, focused | 14 passed; zero failures, skips or runtime warnings. All requested identities and individual outcomes inspected. | `.build/four-focused-v1.xcresult` |
| Clean UI repetitions | All four identities passed twice: eight executions, with both Repetition nodes inspected; zero skips/runtime warnings. | `.build/four-repetitions.xcresult` |
| Initial code `e747435`, complete `mise run check` | Passed in 4886.37 seconds: 609 signed host tests, 663 app tests, broader UI 119 passed/7 existing approved skips, core live 13 passed/8 configuration-dependent skips, and two app-live journeys. Native result warnings empty. | `.build/test-core-results/app-tests-37712-1792930492668.xcresult`, `.build/test-core-results/ui-tests-37712-1792930492668.xcresult`; app-live bundles beneath `TestSupport/ServerHarness/app-live-artifacts/caa19d96-55f6-4939-9c2e-665709752180/` |
| Final code `c19f8d4`, focused | 15 passed, including both pending-Stop boundaries and all four UI journeys; zero failures, skips or runtime warnings. | `.build/four-final-focused.xcresult` |
| Final code `c19f8d4`, recovered aggregate host/app stages | 609 signed host tests passed with zero skips; all 664 app tests passed with zero failures, skips or runtime warnings. | `.build/host-results/`; `.build/test-core-results/app-tests-67662-1792935944052.xcresult` |
| Final code, complete UI/live aggregate and evidence-head CI | See the validation comment for the final outcomes and exact artifact/run links; do not infer completion from the earlier-source pass. | [Authoritative final record](https://github.com/terminaloutcomes/bleat/pull/476#issuecomment-6397997492) |

The narrow runs used the `Bleat` scheme, a task-owned iPhone 17 Pro Simulator on
iOS 27.0, serial testing, inert telemetry URLs, a separate worktree and
`.build/xcode-derived`. The four UI selectors are the exact methods in the
review table above. The final focused selection also includes the complete
six-case `BleatAppTests/UITestPlaybackFixturesTests` and these AppModel methods:

- `testPlaybackStartReplacesIdlePlayerWhileStopSyncIsPending`
- `testPlaybackStartRetainsReplacementWhileStopStatisticsFinishIsPending`
- `testPlaybackStartReusesMatchingActivePlayerAndResumes`
- `testExplicitStopPausesBeforeDiagnosticSuspension`
- `testStopCompletionDoesNotRetireNewerSelection`

The repetition run adds `-test-iterations 2`. Every focused command writes a
fresh result bundle with `-resultBundlePath`; `xcresulttool` summary and test
node results were inspected rather than relying on the process exit code.
The aggregate command is the supported workflow with only an owned destination
override:

```sh
BLEAT_SIMULATOR_DESTINATION='platform=iOS Simulator,id=69211698-B640-4827-B900-BA513D7A6179' mise run check
```

The seven broad-UI skips are the existing runner-approved opt-in cases; the
core-live configuration-dependent telemetry cases execute separately in the
aggregate's configured telemetry stage. No new skip, waiver, assertion removal or
blind retry was added. No existing timeout or tolerance was enlarged. Signed-host tests retain complete
Keychain evidence; unsigned CI coverage is separate. Physical-device, AirPlay,
Bluetooth, CarPlay and background acceptance are not inferred from these runs.

### Final lifecycle audit and independent review

The initial uncommitted test draft had two P1 review findings: a nonexistent
fixture helper and awaiting replacement completion before releasing serialized
progress. Both were corrected before execution. A P2 receipt finding corrected
the delayed-sync cause: rearming after release is the scoped defect; concurrent
waiter overwrite is a prevented latent fixture hazard.

A final audit identified a further scoped P1: after the outer statistics-finish
await, old Stop could reset/close a fully prepared replacement before checking
its generation. The new guard runs immediately after that await. The regression
holds statistics-finish call two, outside progress serialization, and requires
replacement completion and native player identity before releasing old Stop.
Independent review of the revised complete change found no remaining code
findings. Changed and adjacent Stop/reuse/link paths were inspected for traps,
actor assumptions and stale-operation admission; no callback adapter or blocking
async fallback was introduced.

The local accounting wait is legitimate: it flushes listening samples before
reading and sending pending listened-seconds. Audio pause and Now Playing
retirement occur before any await. The accounting completion does not confer
ownership of replacement playback. See the
[source-grounded architecture explanation](https://github.com/terminaloutcomes/bleat/pull/476#issuecomment-6398292113)
for the exact functions and why a broader session-retirement refactor is outside
this fix.

### Runner recovery and expected diagnostic output

The unchanged-main negative reproduction used Xcode's bounded 600-second
failure-diagnostic collection allowance; the complete operation took 850.611
seconds. That collection was not an unbounded app hang. The original complete
aggregate also survived a model-capacity interruption: its active process and
artifacts were recovered and the healthy run was allowed to finish without a
duplicate run. Source inputs changed only after it completed.

The first final-code aggregate attempt exited before host-test execution at
`VerifySignature`. The generated host-runner app contained the ad hoc SwiftPM
helper executable alongside a stale signed-bundle resource envelope/profile.
The project recopies that helper in a pre-build script; the incremental artifact
failed strict signature verification. This attempt provided no host coverage.
The failed directory remains at
`.build/host-runner-derived-signature-failure-c19f8d4`. After the failed process
exited, only that generated derived directory was moved aside. A normal fresh
build verified signing identity, Keychain entitlement and provisioning profile,
then passed all 609 signed host tests. No signing, trust or security check was
disabled or bypassed. Failed and recovered execution logs are retained separately.

Expected output includes upstream OpenTelemetry manifest deprecation warnings,
intentional read-only SwiftData fixture errors and explicitly matched cleanup
failure known-issue fixtures. Source inspection confirmed those injected error
paths. Native app/UI/live result warning arrays are checked separately; unexpected
warnings fail the supported verifier.

CI passed on exact code commit `c19f8d4`:
[Validate Bleat](https://github.com/terminaloutcomes/bleat/actions/runs/40197656674),
[release security](https://github.com/terminaloutcomes/bleat/actions/runs/40197656547),
[CloudKit schema](https://github.com/terminaloutcomes/bleat/actions/runs/40197656756),
and [website build](https://github.com/terminaloutcomes/bleat/actions/runs/40197656801).
PR deployment jobs are skipped by their existing event conditions. Evidence-head
CI and final aggregate completion are recorded in the linked validation comment.


### Final-CI checkpoint oracle correction

The evidence-only `89c1cb2` head's
[iOS CI job](https://github.com/terminaloutcomes/bleat/actions/runs/40202358640/job/121196022308)
failed the unchanged
`AppModelTests.testLastPlayingFailureSurvivesRelaunchAndRetriesLocalCheckpoint`
on iOS 26.5: post-play position `0.7886353` was compared with the original
`0.5 ± 0.15` checkpoint. Retry returns after playback has started and bookmark
loading has completed, so the measured position can legitimately advance while
that awaited work completes. This is a concrete test-oracle failure, not an
infrastructure-only failure or a reason for a blind rerun.

The corrected test injects the existing `StartupPlaybackDiagnosticRecorder`,
which captures model and actual native AVPlayer positions after the awaited
initial seek and before `play()`. It asserts that captured checkpoint with the
unchanged tolerance, verifies the actual native Play request, then verifies Pause,
cleared persisted failure and Stop clearing the last-playing selection. No
production code, timeout, tolerance, UI assertion, skip or waiver changes.
All three clean repetitions passed in
`.build/checkpoint-oracle-repetitions.xcresult`, with all three repetition nodes
inspected and zero skips/runtime warnings. Independent review confirmed that the
actual seek/tolerance and playback guarantees are preserved without weakening.
Owning app-bundle results and new exact-head CI are recorded in the validation
comment. The already completed host/UI/live aggregate
remains applicable to unchanged production and suite inputs.
