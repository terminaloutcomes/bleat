# Callback and cancellation audit

Audit date: 2026-10-12. Related work: [issue #339](https://github.com/terminaloutcomes/bleat/issues/339) and [PR #340](https://github.com/terminaloutcomes/bleat/pull/340).

## Findings and corrections

| Boundary | Finding | Correction and regression |
| --- | --- | --- |
| MediaPlayer remote commands | Arbitrary-thread handler used `DispatchQueue.main.sync` and `MainActor.assumeIsolated`, risking a main-thread wait cycle. | A sendable callback acknowledges admission using a locked snapshot and delivers asynchronously. Clearing playback invalidates queued commands. `FrameworkCallbackTests` invokes the exact registered adapter both on and off the main actor, checks non-inline delivery, invalid events, and clear/replacement rejection. |
| AVFoundation KVO and notifications | KVO closures created on the main actor could inherit isolation even though the framework can invoke them from the changing thread. Queued player and item callbacks could outlive their registration. | Nonisolated sendable KVO adapter hops to the main actor; handlers check player/item ownership before mutating playback. Notification and periodic callbacks are explicitly sendable. A real off-thread AVPlayer KVO mutation exercises the adapter; adjacent playback lifecycle tests cover observation and natural completion. |
| DNS-SD resolution | Resolution registered on a concurrent global queue; cancellation/timeout could deallocate the reference from a different queue while its unretained callback context was in use. | A dedicated serial callback queue owns deallocation. Completion and retained context release follow queued cleanup. A substitutable native deallocator regression verifies same-queue, after-callback, exactly-once teardown and repeated completion ordering. Apple SDK `dns_sd.h` documents both serial registration and same-queue deallocation requirements. |
| Audiobookshelf live stream | An old stream's termination called unscoped `stop()`, potentially cancelling its replacement. Cancelled endpoint/credential restoration could continue into connection creation. Early authentication returns leaked an open socket. | Stream-scoped termination, checks after restoration, and unconditional socket teardown on exit. Tests hold real client endpoint/credential providers across cancellation and replacement; stopped credential work remains cancellation rather than credential failure. |
| Retained browser authentication | Native completion blocks created by a main-actor factory were not explicitly sendable; the AppAuth callback moved its reference DTO into a main-actor task. | Native callback factory returns a sendable adapter, and AppAuth extracts a sendable grant before hopping actors. `OpenIDAuthenticationTests.testNativeBrowserCallbackAdapterRunsOffMainActor` exercises success, cancellation, and failure through the exact native adapter. This research code remains disconnected from application login. |

## Other boundaries inspected

Reviewed CloudKit delegate callbacks, run/watchdog cancellation and drain ownership;
URLSession download delegate proxy, transfer invalidation and background completion;
HTTP redirect delegates; network path and Bonjour browser handlers; CarPlay delegates
and list/search completions; authentication browser callbacks and completion gates;
App Attest's native async APIs; telemetry request cancellation, completion signals
and shutdown ownership; statistics/endpoint observation termination; and image-load
cancellation and stale-result guards. No production force casts, forced throws,
`fatalError`, or main-actor synchronous callback dispatch remain in the app/core
search scope. Inspection is not a proof that every framework interaction is safe.

## Validation

- Final complete host gate: `BLEAT_SKIP_SIMULATOR=1 scripts/test-core.sh`
  passed with 533 executed signed host tests, zero skips, verified inventory and
  coverage, a Release build, and paid-capability build-mode checks. Its intentional
  read-only SwiftData fixtures emitted permission failures; its cleanup-failure
  fixture recorded the existing expected known issue. These are passing failure
  tests, not unexplained runtime failures.
- Focused final host checks: nine `LiveUpdatesTests` and 19
  `OpenIDAuthenticationTests` passed, including the new native browser adapter.
- Exact PR branch: nine selected simulator tests passed; individual identifiers,
  counts, and outcomes were inspected in `.build/callback-audit-pr-final.xcresult`.
  Six are the new `FrameworkCallbackTests`; three cover adjacent playback
  observation, remote control, and natural completion. Zero skips or runtime
  warnings.
- `scripts/test-app-live.sh` passed against disposable Audiobookshelf 2.37.0:
  `testLiveOnlineLoginPlaybackAndDownload` and
  `testLiveOfflineCachedDownloadAndLocalProgress` each executed and passed.
  Both result bundles had zero skips or runtime warnings, and the runner finished
  cleanup successfully. Artifacts are under
  `TestSupport/ServerHarness/app-live-artifacts/a47beb9d-3639-437b-ba23-0a84bf5b6b3b/`.
  These journeys preceded the final disconnected browser-authentication change,
  which was then validated by its host suite and final PR simulator build.
- Strict Swift formatting, `git diff --check`, `mise run release:check`, and
  `mise run security:validate` passed. The generated Xcode project includes both
  new app/test files.

Initial simulator attempts were unexecuted because the development environment
was not loaded, then because the new adapter had compile errors. A subsequent
run failed four tests because the fixture constructed system-owned
`MPRemoteCommandEvent` objects, which Apple explicitly forbids at runtime. The
fixture now feeds decoded test inputs through the same generic callback adapter
registered by MediaPlayer; it does not fabricate framework events. Those failed
attempts are not counted as passing coverage. The initial host run with 531 tests
and the intermediate 532-test run are superseded by the final 533-test gate.
Xcode printed debugger-version lookup diagnostics during live journeys; both
completed and their result bundles report no runtime warnings.

Simulator and disposable-server tests do not establish physical headphone/CarPlay
behavior, actual Bonjour resolution on a user's network, dedicated live WebSocket
authentication/reconnect behavior, actual CloudKit deletion, or original-device
CloudKit crash recovery. Those evidence gaps remain open under issue #339.

## Audio interruption intent (2026-10-22)

Controlled policy input against baseline `4b5829d2` reproduced stale interruption
resume intent: playing → interruption began → user Pause or output removal →
interruption ended with `shouldResume` requested playback again. In each later-
pause case the activation count changed from one to two and the native silent
player rate became 1.0 instead of remaining 0. Normal interruption resumption
passed its control. One exact test failed, with zero skips or runtime warnings;
its eight assertion failures are retained in
`.build/audio-interruption-before.xcresult` and its exported activity tree.

The fix retires pending interruption resume intent on Pause/output removal,
preserves the prior intent when the interruption itself performs the pause,
and consumes the saved intent before resuming. This follows the
[Apple interruption guidance](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/HandlingAudioInterruptions/HandlingAudioInterruptions.html)
without changing audio-session categories or route policies.

The regression invokes the exact main-actor production policy handlers directly;
only their access changed from private to internal. It uses independently owned
local CAF media with explicitly zeroed samples, fake session activation, an
isolated Now Playing publisher, and disabled system remote-command registration.
It does not broadcast synthetic global notifications or operate personal devices.
It proves app-side intent/rate behavior, not NotificationCenter adapter delivery,
physical output routing, audible speaker playback, or the full Overcast/CarPlay/
AirPods handoff. #341's accepted AirPods-only result and original background-
recovery/VoiceOver evidence remain credited. Physical protocols stay separate.

Post-fix focused validation passed one exact identity in
`.build/audio-interruption-after.xcresult`. The owning app suite passed all 630
identities in `.build/audio-interruption-owner.xcresult`, with zero failures,
skips, expected failures or runtime warnings. Its exact result tree includes the
new regression and adjacent reset, resume-activation, resolving-remote-Play and
preparation-cancellation cases. Strict Swift formatting and documentation checks
passed. Xcode retained its existing OS-build parsing/debugger diagnostics; native
runtime warnings were empty. Final published-head CI is recorded on the PR.

A separate Stop diagnostic-suspension witness also failed against the baseline
while a ready silent player remained requested at rate 1.0 and its
Now Playing snapshot stayed published. That witness is preserved separately in
`.build/audio-stop-before.xcresult`; its fix is not included in this interruption
slice. No Stop resolution or whole audio acceptance is claimed here.

## Explicit Stop retirement (2026-10-22)

A separate controlled baseline witness held `.closePlayback` diagnostic recording
after Stop entered. The ready silent native player retained requested playback
at rate 1.0 and its Now Playing snapshot stayed published. The initial one-test
result failed three assertions in `.build/audio-stop-before.xcresult`. The
extended playing/interrupted witness also failed its one exact identity in
`.build/audio-stop-retirement-before.xcresult`, including retained interruption
resume and direct-Play behavior while Stop was held.

A distinct replacement witness started book B successfully while book A's Stop
remained held. Releasing that old Stop cleared B's identity, active/requested
state and snapshot and changed its native rate to 0. One exact test failed five
assertions in `.build/audio-stop-replacement-before.xcresult`. Both A and B's
ready/playing/positive-rate preconditions and B's pre-release published identity
passed. Xcode's insight grouping describes duplicate assertion text as multiple
“runs”; the canonical test tree contains one identity with five failure-message
children, not multiple test executions. All baseline results had zero skips and
native runtime warnings. The added instrumentation source is preserved in
`.build/audio-stop-before-source.patch` against `8c0b5ff`; Stop behavior was
unchanged by that instrumentation or the preceding interruption fix.

Stop now pauses and retires interruption intent, presentation and command
admission before its first diagnostic suspension. It enters the existing idle
state, so queued player-state observations cannot republish the stopped book;
direct Play rejects that retained idle preparation. Immediately after diagnostic
recording, an ownership check abandons the old Stop if a newer generation has
started. Later cleanup behavior is unchanged at that historical revision. This proves
the diagnostic suspension boundary only. The
[#476 reassessment](test-reliability-current-status.md#sign-offs-revisited-after-476-26-october-2026)
records the subsequently demonstrated statistics-await ownership gap and idle
reuse defect; its unmerged candidate adds separate regression coverage.

Both corrected focused identities passed separately in
`.build/audio-stop-retirement-after.xcresult` and
`.build/audio-stop-replacement-after.xcresult`. The owning app suite passed
all 632 identities in `.build/audio-stop-owner.xcresult`, with zero failures,
skips, expected failures or runtime warnings. Its exact tree verifies both new
regressions, three-start serialization, interruption intent, Stop/preparation
cancellation and natural-end Now Playing cleanup. Strict Swift formatting and
documentation checks passed; final published-head CI is recorded on the PR.
Existing Xcode OS-build/debugger metadata diagnostics remain retained.

These regressions use explicitly silent local CAF media, fake audio-session
activation, independent defaults, isolated system-info publishers and disabled
remote-command registration. They prove controlled app-side player/intent and
diagnostic-ordering behavior, not physical call/Siri notifications, speaker
output, headset reconnection or OS selection of Bleat instead of Overcast.
The accepted AirPods-only result remains credited; the full cross-app/CarPlay/
AirPods and broader route/interruption protocols in #341 remain unverified.
Neither paired physical iPhone was available, and no personal playback, device
settings or physical test was changed.
