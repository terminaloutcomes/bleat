# Mini-player Reduce Motion

Issue [#201](https://github.com/terminaloutcomes/bleat/issues/201) follows the
maintainer-completed general Reduce Motion audit in #41.

`MiniPlayerView` reads SwiftUI's system `accessibilityReduceMotion` value. With
Reduce Motion enabled, its transition is opacity-only and dismissal/restoration
state changes have no explicit animation. Otherwise the existing bottom-edge
movement and 0.2-second animations remain. Swipe and accessibility actions use
the same stop-and-dismiss path.

Dismissal state belongs to the shared `PlaybackModel`, so native accessory
instances agree about an in-progress stop. The flag resets after every stop,
including successful stops, allowing subsequent playback to show its player.

## Recorded result

The final 2026-09-08 run used Xcode 26.6 (17F113), Debug app version 0.1.3,
build 2. All 16 test executions passed, with no failed or skipped tests. Exact
identifiers were verified in each result bundle under
`.build/mini-player-motion/results-20260908T041308Z/`.

| Simulator | Reduce Motion | OS/build | Result |
| --- | --- | --- | --- |
| iPhone 17 Pro | Disabled | iOS 26.5 (23F77) | 4/4 passed |
| iPhone 17 Pro | Enabled | iOS 26.5 (23F77) | 4/4 passed |
| iPad Pro 13-inch (M5) | Disabled | iOS 26.5 (23F77) | 4/4 passed |
| iPad Pro 13-inch (M5) | Enabled | iOS 26.5 (23F77) | 4/4 passed |

`mise run swift-lint`, shell syntax validation, and `git diff --check` also
passed. The disposable diagnostic and audit Simulators were removed.

## Automated coverage

Run `mise run test:mini-player-motion`. Each disposable iPhone/iPad pass sets the
system preference, reboots, and verifies the effective SwiftUI value against the
requested setting forwarded to XCTest. All four exact test identifiers and
outcomes must pass in each `.xcresult` bundle:

- System-setting propagation.
- Downward-swipe dismissal while playing and paused, including restarting after
  a successful stop.
- Restoration after resume/pause supersedes a stop awaiting progress sync,
  including continued operation of the restored mini-player.
- Upward-swipe navigation to Now Playing and return to the mini-player.

The restoration fixture holds synchronization at a test-only async gate. The
test verifies hidden controls, supersedes the stop, then explicitly releases the
gate. It does not rely on a timed service delay. Both swipe directions use native
XCTest targeting.

## Unsuccessful attempts and diagnosis

The 2026-09-08 validation retained unsuccessful attempts before the final gate:

- The initial existing-iPhone run failed to launch its test runner with Mach
  error -308 (`server died`), also recording a killed test process. It provided
  no passing-test evidence.
- The first disposable iPhone pass executed four tests: setting propagation and
  upward navigation passed; two tests failed on stale Book Detail accessibility
  labels. Assertions were corrected to the existing title-qualified labels.
- Intermediate runs passed both iPhone modes but failed iPad coordinate-drag
  journeys. The recorded transport frame put the old downward endpoint below
  the window. Bounding the drag and lengthening the upward drag did not resolve
  all failures. A temporary probe recorded no completed SwiftUI callback for
  the upward coordinate drag; native XCTest upward targeting passed on the same
  Simulator. The probe was removed.
- Native ordinary dismissal/navigation passed, but the timed restoration
  fixture remained unreliable. Replacing its timer with an explicit async gate
  exposed view-local dismissal state: synchronization was held while the visible
  iPad accessory remained present. Moving dismissal state into `PlaybackModel`
  made the focused gated restoration test pass.
- Review caught a P2 mistake while introducing the gate: it initially replaced
  the unrelated launch fixture's delay. That delay was restored, and the gate
  moved to the flagged playback-sync branch. Subsequent review found no
  remaining P0–P3 findings.

Xcode emitted device-discovery and debugger-version snapshot warnings despite
`xcrun lldb --version` returning an installed debugger. It also reported stale
intermediates when the initial checkout alias changed to its canonical path.
These tool warnings are retained separately from assertion outcomes.

## Evidence limits

These checks validate Simulator behavior and setting propagation. They do not
measure rendered animation trajectories or establish physical-device VoiceOver
spoken-output/custom-action operation. No live-server, physical-device, or full
repository regression gate is claimed by this focused change.
