# Explicit finished-progress conflict checks

Scope: [issue #146](https://github.com/terminaloutcomes/bleat/issues/146).
This receipt concerns explicit Mark Played, Unplayed, Finished, and Unfinished.
It does not close broader test-reliability, iPad, signed-device, or playback
acceptance work.

## Baseline finding

Current main at investigation was `0ed12585dc6726fce2aca2336e99272014810f5d`.
`AppModel.performBookProgressMutation` fetched canonical detail and checked access,
then marked the operation submitted and PATCHed without fetching current-user
progress or loading a persisted common checkpoint. All four actions share this
path. [PR #147](https://github.com/terminaloutcomes/bleat/pull/147) explicitly
deferred that pre-existing conflict discrepancy from
[issue #78](https://github.com/terminaloutcomes/bleat/issues/78).

## Implemented boundaries

- `FinishedProgressCheckpointRecord` retains device-local account/item common
  snapshots independently of evictable browse data. The 0.1.8 to 0.1.9 lightweight
  schema upgrade adds the record without inventing a checkpoint for older data.
  Account removal (including legacy identity aliases) and local-data reset remove
  owned checkpoints without deleting another account's checkpoint.
- `FinishedProgressCheckpoint` compares decoded structural values, including
  server timestamps. Equal or regressed timestamps do not hide changed values.
  Explicit null represents confirmed absence; absent metadata is invalid and
  remains preserved for a typed storage failure.
- The model fetches current progress after access preparation and before PATCH.
  Missing or changed baselines preserve the intended flag and server snapshot.
  Cancel and server adoption send no PATCH; the device choice changes only the
  finished flag. Resolution refetches and another change re-prompts.
- Account generations, per-item revisions, mutation tokens, and prompt UUIDs
  reject retired requests. Another item can proceed while one awaits a choice.
- HTTP 200 commits local state. Detached readback persists a server-issued
  snapshot only when it confirms the intended flag. Rejection and submitted
  transport uncertainty retain their existing distinct outcomes. There is no
  server-side conditional mutation, so the final GET/PATCH race remains possible.

## Executed evidence

The required aggregate remains failed; do not treat this receipt as final verification.

- Final focused core progress suite: nine tests passed, zero skips, including
  actor persistence/account isolation, a real prior-schema store upgrade, and
  incomplete-payload preservation. Earlier eight-test execution is superseded.
- Complete isolated native app lane: 573 tests passed, zero failures/skips/runtime
  warnings, in `.build/macos-signed/tests-70236-1792914966878.xcresult`. This includes
  all nine new conflict identities. The earlier 570-test lane is superseded.
  Subsequent source review separated queued prompt presentation and froze the
  historical schema model list. The nine affected native regressions passed
  again in `.build/issue-146-native-nine-final.xcresult`, with zero failures,
  skips, or runtime warnings; the nine core progress tests also passed again
  after freezing the schema. Unchanged complete lanes are not rerun solely
  to inflate evidence. Completed code-head CI and live journeys are recorded below.
- Independent focused repetition: six first conflict identities passed in
  `.build/issue-146-native-exact.xcresult`.
- Three additional exact identities passed in
  `.build/issue-146-native-extra.xcresult`: typed rejection/uncertainty preserves
  the checkpoint; a pending choice does not block another item; confirmed
  readback stores the server clock. These are deterministic app-model boundaries.
- `validate-test-audit` passed name/record parity for 612 host functions and 47
  scoped Rust functions. This is inventory evidence only.

The first direct native build did not execute tests because the team was omitted.
The first supported native build then caught two diagnostics compile errors;
those were fixed before the passing results above. The shell macOS entry point
ignores focused arguments and ran the complete native lane; exact repetitions
used `xcode-test-runner macos --test-id` directly. Native Xcode emitted its existing
multiple-destination warning; inspected passing results had no runtime warnings.
SwiftPM emitted a dependency watchOS-version deprecation warning.

## Completed live evidence

The corrected online application journey passed separately against both layouts
on disposable Audiobookshelf 2.37.0. Each result contains one passed exact identity,
zero failures/skips/expected failures, and no runtime warnings:

- Root: `TestSupport/ServerHarness/app-live-artifacts/issue-146-root-1debc2fa-42c2-486e-9a68-3f36ef08803a/root-online.xcresult`.
- Prefix: `TestSupport/ServerHarness/app-live-artifacts/issue-146-prefix-9d9dba86-8e98-40f3-90a3-2bb62bc86ff2/prefix-online.xcresult`.

Both use `BleatLiveUITests.testLiveOnlineLoginPlaybackAndDownload`, the existing
seed/reset/CA workflow, a fresh owned Simulator, and the current built products.
The root invocation points the same journey at the root HTTPS base; the prefix
invocation retains `/audiobookshelf`. Both complete fixture cleanup. These are
application/HTTPS/server journeys, not physical-device evidence.

`ProgressSyncLiveTests.testPinnedRootAndPrefixProgressContracts` also passed as
one focused XCTest with zero skips through `mise run test:live` and the supported
`BLEAT_LIVE_TEST_FILTER=ProgressSyncLiveTests` selection. It persists server-issued
common snapshots and compares subsequent Finished/Unfinished responses on both
layouts. The exact selection is retained in
`.build/swiftpm-test-results/live-fc7205a6-03ff-474f-bd72-a90e6e5d548e-selection.json`.
Its first fixture start executed no tests because the shared OIDC port was already
allocated; the supported `BLEAT_OIDC_HTTPS_PORT` override resolved the collision.

A final focused account-store/progress run passed 27 tests with zero skips after
adding canonical and legacy-alias checkpoint removal. The existing removal test
retains another account's checkpoint. The strengthened nine-test progress suite
then passed again after reopening a full non-null checkpoint from a UUID-owned
on-disk store and a separate container/actor.

Validation used Xcode 27.0 (27A266a), Apple Swift 6.4, arm64 macOS 27.0.1, and iOS
27.0 Simulator. No production app, account, server, trust setting, or dependency
pin was changed.

## Aggregate and preparation history

The extended `BleatLiveUITests.testLiveOnlineLoginPlaybackAndDownload` journey
checks actual server state around Cancel and server adoption, preserves a common
checkpoint across process relaunch, changes progress through a second fixture
client, verifies preservation while the typed conflict is visible, chooses this
device, and restores the flag before the existing playback journey. The corrected
root and prefix passes above supply that evidence.

The initial `mise run test:app-live` attempt stopped before app build/test because
Docker denied the pinned Audiobookshelf 2.37.0 image manifest. A host-side anonymous
manifest request returned HTTP 200 with the exact pinned digest, but a temporary
credential-free Docker configuration still received denial. The exact image was then obtained through the host with a temporary credential-free
configuration, preserving its digest. Docker's legacy loader did not accept the
OCI layout; a read-only public registry token supplied only in memory through
Docker's documented RegistryToken API then populated the exact pinned digest.
The normal app-live workflow was restarted after that prerequisite succeeded.
A temporary Docker configuration omitted the Compose plugin and caused one
additional pre-execution failure; normal configuration was restored for the run.
No saved credentials, trust settings, pinned images, or live application state
were changed.

The first prefixed online journey built and reached the conflict prompt. Its
server-readback preservation checks passed, then its Cancel-button hittability
assertion failed because the iOS 27 native popover omitted the cancel-role button.
The recording shows the two choice buttons and unchanged server progress.
Xcode subsequently timed out after 600 seconds gathering diagnostics. The failed
one-test bundle is retained in
`TestSupport/ServerHarness/app-live-artifacts/79ceafd1-5ad5-4bbb-b634-e93e28a92583/online.xcresult`.
The corrected test exercises native outside dismissal when Cancel is omitted,
then still requires the prompt to close and server state to remain unchanged.
No wait was increased and no semantic postcondition was dropped.

Draft [PR #475](https://github.com/terminaloutcomes/bleat/pull/475) preserves the
implementation. The aggregate check passed 612 signed host tests and 670
simulator app tests, then failed its 126-test broader UI lane: 115 passed, four
failed, and seven approved skips, with zero runtime warnings. Its four
host known issues are intentional cleanup-failure reporter fixtures, not new
failures. Rust workspace tests passed 381 cases; telemetry validation passed 107
Rust cases and its separately verified Swift selections (91 executed across the
selected runs), with zero failures/skips. Release/package/build-mode, schema,
format and documentation prerequisites have passed. The aggregate stopped before
its full live stages; both stages subsequently completed separately. The full
server suite passed 13 tests with eight approved optional skips. The standard
online/offline app-live gate passed both exact tests with zero failures, skips,
or runtime warnings, including verified 401 refresh/range recovery. Its retained
artifacts are in
`TestSupport/ServerHarness/app-live-artifacts/2a825e82-68a5-45d4-91a2-981f460bdd65/`.
Its owned containers, simulator, and derived build directory were cleaned up.

Exact-code-head [CI at `fa5e6ada`](https://github.com/terminaloutcomes/bleat/actions/runs/40180915280)
completed successfully, including iOS, Rust, host tests and coverage publication;
security, schema and site checks also passed. Documentation-only follow-ups
record their own CI in the PR. `APP-FINISHED-001` remains implemented because the
required aggregate has not passed; these results do not certify broader acceptance.

## Source review

A source pass independently of test outcomes checked the issue's data-preservation,
identity, access, clock, submission-stage, and cancellation boundaries. It found a
dialog dismissal ordering assumption and replaced it with a synchronously captured
handled-prompt UUID before asynchronous resolution. A dismissed old prompt cannot
consume a replacement. The presented prompt is separate from queued conflicts,
matching the established failure-queue dismissal lifecycle; a bounded regression
checks the next item after cancellation. The historical 0.1.8 catalog is an
explicit fixed list, independent of additions to the current catalog. Adjacent progress paths retain typed failures and contain
no newly introduced traps, forced casts/throws, or blocking async wrappers.
The final GET/PATCH race remains explicit because the server has no conditional
write contract. Broader audit counts and signed/physical-device acceptance are
not inferred from these scoped checks.

An independent reviewer subsequently reviewed exact code head
`fa5e6ada6de6837f75cb08f306dc2f54f5b3f6b1` read-only, without rerunning tests.
They found no scoped code correctness issues across persistence/migration,
account/item isolation, typed comparisons, conflict choices, stale guards,
rejection, uncertainty, readback and regression coverage. They identified stale
pending/baseline statements in this receipt; this documentation update addresses
that finding. The reviewer independently inspected the saved comparison summaries
and successful GitHub validation jobs. Physical-device behavior and broader
acceptance were outside that review.

## Aggregate UI failures retained

`mise run check` exited unsuccessfully after the full UI lane. Its native result
ran from 2026-10-25 08:20:10 UTC to 09:12:43 UTC, followed by additional Xcode
diagnostics collection. The failed bundle is
`.build/test-core-results/ui-tests-73882-1792915950918.xcresult`.

| Exact identity | Failed postcondition |
| --- | --- |
| `BleatUITests.testDiagnosticTelemetryConsentLivesInSystemSettings` | Could not find/tap `diagnostics.telemetry.settings`. |
| `BleatUITests.testSystemSettingsLinkAvailableWhenStartupUnavailable` | The same System Settings link was not hittable. |
| `BleatUITests.testMiniPlayerRestoresWhenStopIsSuperseded` | The playback label did not become Pause within its three-second semantic wait. |
| `BleatUITests.testViewOnServerOpensSystemBrowserWithoutEditPermission` | Bleat was still foreground after the Safari-open check. |

Source inspection confirms these cases exercise Settings, playback Stop/resume,
and external browser handling; they do not call explicit finished-state actions.
All four were then selected in narrow paired runs on unchanged main
`0ed12585dc6726fce2aca2336e99272014810f5d` and exact code head
`fa5e6ada6de6837f75cb08f306dc2f54f5b3f6b1`, using separate fresh owned iPhone 17
Pro simulators on iOS 27.0. Both runs selected exactly four tests; all four failed,
with identical failure text, zero skips and zero runtime warnings. The baseline
bundle is `.build/issue-146-baseline-four-v2.xcresult` relative to the separate
baseline worktree;
the head bundle is `.build/issue-146-head-four.xcresult`. Baseline elapsed time was
746.349 seconds, including Xcode's 600-second diagnostic collection timeout;
head elapsed time was 289.639 seconds. An initial baseline setup attempt ran zero
tests because direct `xcodebuild` omitted the inert telemetry environment; the
corrected run exported the existing worktree environment. Both comparison
simulators were deleted after their results were captured.

These failures reproduce without the #146 diff. No assertions, waits, security
settings, or unrelated features were changed to hide them. The aggregate remains
failed. Readiness remains pending explicit acceptance of the demonstrated
baseline failures or separate resolution of those failures; the existing approval
was conditional on passing required validation. The PR remains draft.

The invalid-checkpoint source audit also retained a distinct
`progressCheckpointInvalid` presentation and
`finished_progress_checkpoint_invalid` diagnostic at
`load_finished_progress_checkpoint`. The typed failure is published after the
logical operation retires and before diagnostics are awaited, so logging cannot
replace it with a timeout. The existing failure-boundary regression passed again
as one exact native test in
`.build/issue-146-native-checkpoint-failure-final.xcresult`.
