# AC-22 background-download recovery device evidence

This document is the execution record for
[GitHub issue #33](https://github.com/terminaloutcomes/bleat/issues/33). It
covers the OS-managed behavior that host, live-server, and Simulator tests
cannot prove: a physical iPhone's background URL session, process relaunch,
network-path changes, and replacement of an expired download authorization.

## Evidence boundary

The automated foundation is already recorded by `DOWNLOAD-002` through
`DOWNLOAD-007` and the focused `AppModelTests` recovery cases. It proves the
durable manifest, account scoping, range construction, token replacement, and
network-recovery policy. It does not prove that iOS keeps or relaunches the
background session on a physical device.

Do not mark a matrix row complete from a Simulator run, a successful build, or
an ordinary foreground retry. A completed row requires the device, the
server-side request record, and the app's visible final download state.

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
| Suspend during download | Start a full-book download, wait for one completed range chunk, then background Bleat until iOS later resumes it. | The download continues or resumes; its final state is Complete. | The first resumed request starts at the durable byte offset, and no completed range is requested again. | pending |
| Terminate and relaunch | Start a full-book download after one committed chunk, then induce a non-user process termination and relaunch Bleat. Do not use the App Switcher force-quit gesture, which cancels background transfers by design. | The persisted record reconciles and reaches Complete; no duplicate transfer is visible. | The resumed range begins at the durable offset and there is only one request for each remaining range. | pending |
| Offline launch and recovery | Interrupt a non-paused download, launch Bleat while the device network is disabled, then re-enable the network. Repeat with a user-paused download. | The non-paused record resumes after a network-path change; the paused record stays Paused. | Only the non-paused record issues resumed ranges. | pending |
| Expired download authorization | Make the next range request return 401 after a committed chunk, then allow the replacement request. | Exactly one refresh and replacement occur; the download completes without re-downloading completed bytes. | The replacement retains the rejected request's `Range` and `If-Range`, records `Bearer` as its authorization scheme, and has no token query parameter. | pending |

## Recording completed rows

For each completed row, replace `pending` with the date and result, then add a
short redacted evidence note below. Identify the saved server log or screenshot
artifact by project-relative path. Do not include account names, device IDs,
token values, request URLs containing bearer-like material, or private local
paths.

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

No physical-device scenario has been recorded in this repository yet. The
paired-device build is a prerequisite only; it is not AC-22 evidence.

If a non-user termination cannot be induced reliably on the selected device,
record the row as blocked with that limitation; do not substitute a force-quit
result or mark the row complete.
