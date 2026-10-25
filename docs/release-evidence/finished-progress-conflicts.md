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
  Account removal and local-data reset remove owned checkpoints.
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

Validation is ongoing; do not treat this receipt as final verification.

- Final focused core progress suite: nine tests passed, zero skips, including
  actor persistence/account isolation, a real prior-schema store upgrade, and
  incomplete-payload preservation. Earlier eight-test execution is superseded.
- Complete isolated native app lane: 573 tests passed, zero failures/skips/runtime
  warnings, in `.build/macos-signed/tests-70236-1792914966878.xcresult`. This includes
  all nine new conflict identities. The earlier 570-test lane is superseded.
  A subsequent view-only change removes a dismissal scheduling assumption;
  its UI journey and final-head CI evidence remain pending.
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

## Outstanding live and aggregate evidence

The extended `BleatLiveUITests.testLiveOnlineLoginPlaybackAndDownload` journey
checks actual server state around Cancel and server adoption, preserves a common
checkpoint across process relaunch, changes progress through a second fixture
client, verifies preservation while the typed conflict is visible, chooses this
device, and restores the flag before the existing playback journey. It is not
credited until the disposable root and prefixed runs pass.

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

Aggregate validation, disposable root/prefix server and app journeys, final
source/error-path review, draft PR publication, and exact-head CI are pending.
`APP-FINISHED-001` remains implemented until that evidence is recorded.

## Source review

A source pass independently of test outcomes checked the issue's data-preservation,
identity, access, clock, submission-stage, and cancellation boundaries. It found a
dialog dismissal ordering assumption and replaced it with a synchronously captured
handled-prompt UUID before asynchronous resolution. A dismissed old prompt cannot
consume a replacement. Adjacent progress paths retain typed failures and contain
no newly introduced traps, forced casts/throws, or blocking async wrappers.
The final GET/PATCH race remains explicit because the server has no conditional
write contract. Broader audit counts and signed/physical-device acceptance are
not inferred from these scoped checks.
