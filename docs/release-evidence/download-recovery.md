# AC-22 background-download recovery device evidence

This document is the execution record for
[GitHub issue #33](https://github.com/terminaloutcomes/bleat/issues/33). It
covers a physical iPhone's OS-managed background URL session, process relaunch,
and network-path changes. Expired download authorization is covered by the
deterministic disposable app-live harness because it is an application/server
contract rather than physical-device lifecycle behavior.

## Evidence boundary

The automated foundation is already recorded by `DOWNLOAD-002` through
`DOWNLOAD-007` and the focused `AppModelTests` recovery cases. It proves the
durable manifest, account scoping, range construction, token replacement, and
network-recovery policy. It does not prove that iOS keeps or relaunches the
background session on a physical device.

Do not mark an OS-lifecycle matrix row complete from a Simulator run, a
successful build, or an ordinary foreground retry. Those rows require the
device, the server-side request record, and the app's visible final download
state. The authorization row requires the deterministic app-live fault,
privacy-safe request evidence, and the app's visible final download state.

## Preconditions

- Build and install the Release candidate on a signed iPhone with
  `mise run iphone`.
- Use a disposable account and a downloadable audiobook containing at least
  two files. One source file must exceed 32 MiB so an interrupted transfer has
  a committed 16 MiB range chunk to preserve.
- Enable a redacted server request log that records request path, status,
  `Range`/`If-Range` headers, and only the authorization scheme. Never retain
  an `Authorization` value, token, cookie, or playback route.
- Record the app version and commit, device model, iOS version/build,
  Audiobookshelf version, media fixture identifier and sizes, and whether the
  server is root-hosted or path-prefixed.

## Execution matrix

| Scenario | Device procedure | Required result | Server-side assertion | Status |
| --- | --- | --- | --- | --- |
| Suspend during download | Start a full-book download, wait for one completed range chunk, then background Bleat until iOS later resumes it. | The download continues or resumes; its final state is Complete. | The first resumed request starts at the durable byte offset, and no completed range is requested again. | passed 2026-08-28 |
| Terminate and relaunch | Start a full-book download after one committed chunk, then induce a non-user process termination and relaunch Bleat. Do not use the App Switcher force-quit gesture, which cancels background transfers by design. | The persisted record reconciles and reaches Complete; no duplicate transfer is visible. | The resumed range begins at the durable offset and there is only one request for each remaining range. | passed 2026-08-28 |
| Offline launch and recovery | Interrupt a non-paused download, launch Bleat while the device network is disabled, then re-enable the network. Repeat with a user-paused download. | The non-paused record resumes after a network-path change; the paused record stays Paused. | Only the non-paused record issues resumed ranges. | passed 2026-08-28 |
| Expired download authorization | Make the next range request return 401 after a committed chunk, then allow the replacement request. | Exactly one refresh and replacement occur; the download completes without re-downloading completed bytes. | The replacement retains the rejected request's `Range` and `If-Range`, records `Bearer` as its authorization scheme, and has no token query parameter. | app-live passed 2026-08-28 |

## Recording completed rows

For each completed row, replace `pending` with the date and result, then add a
short redacted evidence note below. Identify the saved server log or screenshot
artifact by project-relative path. Do not include account names, device IDs,
token values, request URLs containing bearer-like material, or private local
paths.

### 2026-08-28 terminate-and-relaunch device result

- A signed physical-iPhone build from commit `0ffc54df` was terminated with
  `scripts/iphone-terminate-app.sh` during a full-book download.
- After Bleat was opened again, the persisted partial download automatically
  resumed and completed without a Repair action, visible duplicate transfer,
  or progress reset.
- The user accepted the complete scenario as passed. Separate server-log
  capture was waived as unnecessary for acceptance.

### 2026-08-28 suspend-and-resume device result

- A full-book download was allowed to pass approximately 40 MB before Bleat
  was backgrounded normally without using the App Switcher force-quit gesture.
- After the phone remained locked with Bleat in the background for
  approximately five minutes, reopening Bleat showed that the download had
  continued or resumed and completed successfully without Repair, Failed, or
  regressing progress.
- The user accepted the complete scenario as passed. Separate server-log
  capture was waived as unnecessary for acceptance.

### 2026-08-28 expired-authorization app-live result

- `scripts/test-app-live.sh` enlarged the disposable multi-track fixture,
  committed its first 16 MiB range, and injected one 401 on the next range.
- The privacy-safe evidence recorded exactly one refresh. The single
  replacement returned 206 with the rejected request's
  `Range: bytes=16777216-33554431`, unchanged `If-Range`, `Bearer` scheme, and
  no query.
- The real SwiftUI app completed the download, then played it in the separate
  server-offline phase. Both XCUITest result bundles passed one test with no
  failures or skips.
- Reproducible artifacts are written beneath
  `TestSupport/ServerHarness/app-live-artifacts/<run-id>/` as
  `download-401-evidence.json`, `online.xcresult`, and `offline.xcresult`.

### 2026-08-28 pause-transition device result

- A signed physical-iPhone Release build from commit `0484f9da` was installed
  and launched with `mise run iphone`.
- The user reported that the foreground Pause workflow passed on the device.
- This result verifies the corrected Pause transition only. It does not complete
  the offline-launch row by itself.

### 2026-08-28 offline-launch device result

- The user accepted the non-paused recovery and user-paused preservation
  scenarios as passed on the signed physical iPhone build.
- Exact device model, iOS build, and server version were not retained. Separate
  server-log capture was waived as unnecessary for acceptance.

```md
### YYYY-MM-DD — scenario name

- App: `MARKETING_VERSION` / commit
- Device: model, iOS version/build
- Server: Audiobookshelf version, root or path-prefixed deployment
- Fixture: opaque fixture name and byte lengths
- Result: completed or failed, including final app state
- Server evidence: project-relative redacted artifact path
- Notes: exact observed durable offset and any unexpected behavior
```

## Current record

All four recovery scenarios were accepted as passed on 2026-08-28. The 401
result has retained deterministic app-live artifacts. The physical-device
results are user-attested. Separate physical-run server logs were waived, and
complete environment metadata was not retained for those runs.

If a non-user termination cannot be induced reliably on the selected device,
record the row as blocked with that limitation; do not substitute a force-quit
result or mark the row complete.

## Background-event completion ordering (2026-10-22)

A controlled native delegate regression against baseline `d8670295` demonstrated
that the OS completion could run while delivered chunk reconciliation remained
held. This violates the [background-session completion contract](https://developer.apple.com/documentation/uikit/uiapplicationdelegate/application(_:handleeventsforbackgroundurlsession:completionhandler:)).
It is a processing-order defect; no physical transfer loss or stall was observed.
The four accepted scenarios above and their user-approved evidence waivers remain
unchanged.

The fix synchronously admits durable callback work before returning from each
delegate method. Finish-events captures that admitted set and awaits its durable
processing. Later callbacks are excluded. A retry releases its admission after
its retry deadline/state is saved, before waiting for future backoff.

The corrected regression completes the fixture's first track, delivers the last
three bytes of its second track through native URLSession/URLProtocol, and holds
manifest reconciliation. Both the pre-handoff and completion-time observations
read saved JSON directly; `storage.records()` is deliberately excluded because
it reconciles files itself. The original-ordering control failed with premature
completion and `[false]` versus `[true]` for the delivery-time durable snapshot; the fixed run passed one exact test with zero skips, expected failures
or runtime warnings. The final assertion requires the saved manifest to be
complete inside the completion closure, exactly one completion and an 8-byte file.

Retained local bundles: `.build/background-completion-corrected-red.xcresult` and
`.build/background-completion-corrected-green.xcresult`. Earlier attempts remain
retained: the rejected repeated selector and missing fixture argument executed
zero tests; two fixture-invalid post-fix attempts each failed one test (a queued
first track, then a mutating precondition read). The initial red result is
superseded as causal proof by the corrected original-ordering control.

Owning validation: `.build/background-completion-owner.xcresult` executed all
629 app tests with zero failures, skips, expected failures or runtime warnings.
The exact result tree includes both new tests and the extended retry case.
The durability identity also passed in the isolated corrected-green bundle.
Strict Swift formatting and `mise run docs:check` passed. Xcode emitted its
existing operating-system-build parsing (`invalidDigitCount`) diagnostic; the
native result reported no runtime warnings. Final PR checks are recorded on the
delivery PR, separately from these local runs.

The companion fence test holds a later callback while requiring the earlier
handoff to complete. The existing retry/network-loss case now requires handoff
while its retry sleeper remains gated and retains its recovery/pause assertions.
These are controlled app-hosted callback tests with explicit finish-events
delivery; they do not establish physical daemon wake, suspension or relaunch.
Both paired iPhones were unavailable during this investigation. A new physical
OS-wake receipt would require an available controlled signed iPhone and a
multi-range download, without using the App Switcher force-quit gesture.
