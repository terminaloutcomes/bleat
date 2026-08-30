# Low Data Mode live-update device evidence

This document records physical-device evidence for
[GitHub issue #11](https://github.com/terminaloutcomes/bleat/issues/11).
Automated coverage proves the constrained-path lifecycle and local-player
boundary; this record covers real `NWPath.isConstrained` transitions.

## 2026-08-30 physical iPhone result

- App: Bleat 0.1.3 build 2, commit `63219944`.
- Device: iPhone17,1 running iOS 26.6.1.
- Network: cellular, with the configured validated local endpoint unavailable.
- Enabling Low Data Mode before a refresh changed Diagnostics to
  **Suspended — Low Data Mode**. A pull-to-refresh still completed normally.
- Disabling Low Data Mode returned Diagnostics to **Authenticated**.
- During downloaded playback, enabling Low Data Mode suspended the WebSocket
  while the same book continued without an item, chapter, rate, timeline, or
  play/pause-intent change. Home and Library remained usable.
- Disabling Low Data Mode again returned Diagnostics to **Authenticated** and
  preserved the active player's state.
- The user accepted all four transition results as passed.

The final reconnect visibly spent time trying the unavailable local endpoint
before authenticating through the primary endpoint. The installed build did
not emit a privacy-safe trace that could distinguish those attempts, so no
server address or server-side log was retained. The follow-up implementation
adds one consent-gated `bleat.live_update.connection` span per attempt with
only `local_server` or `primary_server` source, bounded retry bucket, elapsed
span time, typed outcome category, stable failure code, and rejection stage.
Hostname, URL, account, token, and playback route remain excluded.

## Instrumented reconnect investigation

The signed physical-device build from commit `9113ad66` emitted the reviewed
connection spans during a second cellular Low Data Mode recovery. The bounded
reconnect window contained 15 attempts in approximately 21 seconds: an
8.2-second local attempt was cancelled, then several local and primary attempts
were cancelled or failed at `socket_receive` before two primary attempts
authenticated. Every failed attempt reported `transport_unavailable`; no
endpoint value was collected.

This evidence identified two replacement paths rather than an ordinary single
client retry sequence. The app now starts or stops its subscription only when
the path crosses the realtime-allowed boundary, does not replace the
subscription for duplicate path states, and lets an endpoint probe reconnect
only a client that existed when that path change began. Simulator regression
coverage sends duplicate unconstrained and expensive-path updates and requires
the original single subscription to remain.

A repeat on `c27b5717` no longer produced the visible replacement storm, but
the connection remained `connecting` for more than a minute. Its trace showed
one local attempt failing at `socket_receive` after 56.56 seconds, followed by
a primary attempt authenticating in 0.87 seconds. That confirmed serial
local-first fallback was still using a pre-path-change reachability assumption.
The shared endpoint router now prefers the primary server while local
reachability is unknown after a path change and promotes local only after the
path probe succeeds.

## Automated evidence

- `LiveUpdatesTests` covers constrained-network request policy, endpoint and
  token handling, protocol decoding, and typed endpoint-role attempt events.
- `RemoteTelemetryTests` verifies the closed span-name and attribute allowlist.
- `AppModelTests.testLiveConnectionAttemptsTraceEndpointRoleRetryAndOutcome`
  verifies a local transport failure followed by a primary success produces
  two bounded spans without endpoint values.
- `AppModelTests.testConstrainedPathControlsLiveUpdateLifecycleWithoutBlockingREST`
  covers suspension, REST independence, downloaded-player stability, one
  reconnect, and one catch-up refresh.
- `AppModelTests.testLiveProgressUpdatesFinishedStateImmediately` proves a
  progress event cannot mutate active-player state.
