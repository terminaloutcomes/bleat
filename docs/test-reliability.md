# Test reliability

These rules apply to every test, including passing, disabled, conditional, and
opt-in cases. Issue [#362](https://github.com/terminaloutcomes/bleat/issues/362)
tracks the repository-wide audit. These rules are requirements, not a claim
that the existing suite has been fully reviewed or validated.

See the [current delivery and acceptance checkpoint](release-evidence/test-reliability-current-status.md)
for landed fixes, remaining record review and separately tracked configuration gaps.

## Review a test

Record its identifier and source path, purpose, dependencies and initial state,
action/postcondition pairs, synchronization, timeout/tolerance rationale, and
keep/fix/follow-up decision with a reason. Check each rule below, marking an
inapplicable rule explicitly. A passing execution or a search for sleeps cannot
replace this source review.

1. Assert the semantic result of each action. A delivered tap or visible player
   control does not prove playback readiness, completed seeking, downloaded
   media, or committed storage. Retain enabled and hittable checks before
   interactions that require them.
2. Wait for the condition the next action needs, with a bounded, asserted
   result. Use existence waits only when existence is sufficient, property
   waits for values, and completion contracts for async operations. Register
   callbacks before triggering work. A bounded polling interval is acceptable;
   a fixed sleep or guessed number of yields is not proof of completion.
3. Pause and confirm paused state before exact playback-position assertions,
   or use a controlled player/clock. Await seek completion. Intentionally
   playing tests need a defined observation window and a tolerance justified
   by playback rate, measurement granularity, and asynchronous sampling.
4. Await async APIs and clean up tasks and observers on failure as well as
   success. Preserve tests for cancellation, late/repeated callbacks and
   arbitrary-executor delivery. A structured task-group timeout cannot bound
   an operation that ignores cancellation and never completes.
5. Establish independent storage, account, preference, media and server state
   in setup. Cleanup is not the next test's setup. Keep intentional restoration
   state within the test that owns the relaunch scenario. Never use personal
   local state as a fixture.
6. Distinguish deterministic fixtures from real framework, HTTPS, server and
   device integration. Document prerequisites, readiness, failure budgets and
   expected failures for live cases. Preserve legitimate boundary coverage.
7. Diagnose failures before changing waits or tolerances. Do not use blind
   retries, dropped assertions or larger sleeps to hide instability. Keep the
   original failure and distinguish product, test and infrastructure defects.
8. Preserve the failing caller's location and report the action, expected and
   observed state, elapsed wait and timeout. Playback failures need readiness,
   rate, position and seek state. Retain UI screenshots, accessibility context,
   named activities, logs and result bundles with privacy redaction.
9. Repeat affected tests individually and in their owning suite. Use supported
   order/seed and configuration variations where relevant; record all outcomes.
   A retry-to-green is not a clean repetition sequence.

Delayed delivery can itself be the scenario under test, such as proving that
startup remains suspended after a former timeout. Document that purpose and
assert the resulting state. Do not replace real elapsed-time coverage with a
mock when elapsed-time behavior is the contract being tested.

## Change review checklist

For changes to tests, shared helpers/fixtures, UI/navigation, playback or async
coordination, the author records the following in the PR and an independent
reviewer checks the affected bodies and shared callers. Use the PR template;
mark an inapplicable item with a reason, not a blanket compliance claim.

- [ ] Name affected test identifiers, helpers and callers; pair each action with
  its semantic postcondition. Identify the native control type from the view
  and accessibility evidence (for example, SwiftUI Link is not necessarily an
  XCTest Button). Require a unique intended match and enabled/hittable state
  before interaction; retain the actual native-control exercise.
- [ ] Wait on one joint readiness condition when the next action requires
  simultaneous states. For browser handoff, observe Safari foreground and Bleat
  out of foreground together within the failure budget; separate successful
  observations do not establish that boundary.
- [ ] Name the measurement boundary. Exact seek/checkpoint assertions observe
  completed native seek before Play, confirmed paused state before the measured
  interval, or a controlled clock/player. Pausing after an awaited operation
  that already played does not restore the original checkpoint. For advancing
  playback record the observation window, rate and justified tolerance.
- [ ] Name the operation/session/generation owning each suspension and cleanup.
  Revalidate ownership after every await that precedes mutation or retirement.
  Hold each relevant suspension separately, admit a replacement, then release
  the old operation and prove replacement identity/state survive. Preserve
  progress-write ordering; release serialized work before awaiting a dependent
  replacement's completion.
- [ ] State whether a gate is one-shot or reusable. Verify entry, cancellation,
  repeated release, later waits and reuse as applicable. A one-shot release
  must not rearm or overwrite a suspended waiter. Register teardown before
  suspension, release and join owned tasks on failure, and isolate later tests.
- [ ] Record focused repetitions and the owning suite, then the required local
  broad UI receipt below. Preserve every failed/interrupted attempt and explain
  its disposition; do not replace it with a green retry.
- [ ] Revisit affected audit rows, shared rule profiles and current-status
  sign-offs against code and evidence. Preserve the historical decision and
  receipt; append the corrected scope, source revision and keep/fix/follow-up
  rationale. Separate implemented, source-reviewed and execution-verified
  status. Unmerged fixes and their results remain candidate evidence.

## Required local broad UI evidence

Changes affecting UI/navigation, shared UI fixtures or launch/reset/wait helpers,
playback lifecycle, or synchronization used by UI journeys require both focused
validation and the owning broad UI suite locally before handoff. This includes
production changes behind unchanged UI tests. Use the supported
[`scripts/test-core.sh` / `mise run test:local` workflow](development.md#local-validation);
run additional live/configuration gates required by the affected behavior.
The full UI suite is not added to CI: its two smoke journeys cannot substitute
for the local receipt. A docs-only review/checklist change requires the
[documentation checks](contributing.md#documentation-checks), not a fabricated UI rerun.

Record revision, command, toolchain/runtime/device and configuration, exact
selected identities/discovery, executed pass/fail/skip counts, skip reasons,
individual outcomes, warnings and result-bundle/log paths in a retained PR
comment or linked receipt. Distinguish inventory/discovery counts from executed
tests and source inputs that changed after execution. For a later docs-only
head, identify the earlier tested revision and unchanged relevant inputs rather
than calling its results an exact-head rerun. Verify CI separately on the final
published head through completion.

Use an isolated worktree, build/result paths and task-owned Simulator. Coordinate
shared host/Simulator capacity with concurrent owners; never cancel their runs,
reset their devices or remove their build artifacts. If resources or another
prerequisite prevent the required local gate, record the exact unexecuted gate
and limitation, retain draft status and do not claim verified completion.

## Suite responsibilities

| Suite | Runner and boundary |
| --- | --- |
| `BleatCoreTests`, `BleatTranscriptionTests` | Swift Testing host lane; deterministic fixtures and explicitly identified local framework integration |
| `BleatAppTests` | App-hosted Xcode/XCTest; Simulator or signed macOS according to platform guards |
| `BleatUITests` | Xcode/XCTest; fixture-backed journeys plus explicitly enabled live, accessibility, performance and screenshot journeys |
| `BleatCoreLiveTests` | XCTest with the disposable server and its HTTPS prerequisites |
| `Tests/ScriptTests`, `TestSupport/HostTests`, `TestSupport/SwiftTestingPrototype` | Python unittest and the prototype's documented runner; result-verifier regressions are part of the audit |
| `scripts`, `bleat-api` | Cargo targets and features; PostgreSQL/container prerequisites remain explicit |

Inspect shared launch/reset/wait helpers and every caller. Inventory fixture
packages, runner selection, result verification and `TestSupport/ServerHarness/`
alongside tests. Reconcile host discovery with
`TestSupport/HostTests/inventory.json`; that file does not inventory other suites.
Record compiler guards, enablement variables and skipped/disabled cases so a
default build cannot silently define the audit's scope.

Use the [development workflows](development.md) for commands. Verify exact
executed identifiers and individual outcomes, including repetitions. Zero tests,
unexpected bundles, missing tests and skipped required cases are not passing
coverage. Record revision, command, configuration, toolchain/platform, counts,
failures, warnings, skips and artifact paths. Separate host, Simulator, live
server, signed host and physical-device evidence.

## References

- Apple, [Write tests to fail](https://developer.apple.com/videos/play/wwdc2020/10091/):
  known setup, action/assertion pairs, condition waits and failure diagnostics.
- Apple, [Record, replay, and review: UI automation with Xcode](https://developer.apple.com/videos/play/wwdc2025/344/):
  existence/property assertions and explicit device setup.
- Apple, [Author fast and reliable tests for Xcode Cloud](https://developer.apple.com/videos/play/wwdc2022/110361/):
  independent setup, controlled dependencies and repetitions.
- Apple, [Asynchronous tests and expectations](https://developer.apple.com/documentation/xctest/asynchronous-tests-and-expectations):
  async tests and completion-based synchronization.
- Apple, [Xcode 16 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes):
  property-value and nonexistence waits; use APIs supported by the test toolchain.
- Apple, [Designing for adverse network and temperature conditions](https://developer.apple.com/videos/play/wwdc2019/422/):
  realistic integration conditions complement controlled tests.

## Scoped audit inventory check

Run the read-only name/record check with:

```sh
mise exec -- cargo run --quiet --locked --package scripts --bin validate-test-audit
```

It reconciles host inventory functions with current core audit and source-index
records, and ordinary `#[test]` functions in `build-scripts` source/tests plus
the checker's own regression file with other-audit/index records. Conditional
Rust declarations remain in source coverage when another platform does not
compile them. Missing, duplicate, stale or obvious placeholder entries and
empty required scopes fail. The regression target is included in normal Cargo
test discovery; its negative fixtures reproduce those failures directly.

This check does not certify semantic review, runtime discovery, argument
multiplicities, line-number freshness, macro-generated Rust tests or the whole
repository inventory. The host opt-in performance case is retained separately
from default runtime inventory. Keep source review, exact executed outcomes and
platform prerequisites explicit; passing this check cannot replace them.
