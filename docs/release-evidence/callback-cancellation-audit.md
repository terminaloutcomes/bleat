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
