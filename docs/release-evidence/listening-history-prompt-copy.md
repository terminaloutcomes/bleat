# Listening-history upgrade prompt copy

## Scope

The prompt uses **Update listening history**, a short explanation that listening
time is kept, and the existing minimum-version prerequisite (2026.10.27 on every
device). **Update now** and **Later** retain their existing actions. This is a
copy/presentation change, not a migration, consent-version, or reminder-frequency
change.

The root sheet uses a native **What changes?** disclosure for the retained
conversion/cleanup consent, compatible-record combination, measured totals and
meaningful boundaries, iCloud replacement confirmation, removed timer
checkpoints, and wider custom-reset ranges. The compatibility native Alert uses
the same copy and button labels, with the details inline because native Alerts
cannot contain a disclosure. No alert/sheet coordination was changed.

## Validation

Implementation: `1d96da364c725c9802f6cd1f7e14b98f8de9e00b`, based on PR #481
head `9592a80f86c8e5b23752105c8993bbe47b8a14a7`.

Toolchain: Xcode 27.0 (27A266a), macOS 27.0.1, task-owned iPhone 18 Pro
Simulator, iOS 27.0 (24A434). Ignored `.envrc` uses the documented unsigned
non-production `.invalid` telemetry endpoints.

Focused validation ran the same source/test contents before the implementation
commit was created. All five selected tests passed, with zero failures or skips:

- `BleatAppTests/AppModelTests/testCloudStorageUpgradeNoticeUsesFixedReleaseAndPersistsAcknowledgment`
- `BleatAppTests/AppModelTests/testRevisedCloudStorageNoticeRequiresNewAcknowledgmentAfterLegacyDismissal`
- `BleatUITests/BleatUITests/testCloudStorageNoticeAcknowledgmentSurvivesForegroundAndRelaunch`
- `BleatUITests/BleatUITests/testLegacyDismissedCloudStorageNoticeRequiresRevisedConfirmation`
- `BleatUITests/BleatUITests/testCloudStorageNoticeLaterAndAccountCancelRemainIndependent`

The UI tests open and close the actual disclosure, verify retained caveats,
defer, foreground, relaunch, explicitly confirm, and verify the durable result.
They also preserve the independent cloud-account chooser journey. No shared
launch/reset/wait helper or fixture was changed.

Command: `mise exec -- env TEST_RUNNER_BLEAT_UNIT_TEST_HOST=1 xcodebuild
-project Bleat.xcodeproj -scheme Bleat -destination 'platform=iOS Simulator,id=2A3DA61A-D0F9-4D4E-92C8-065383EEC10D'
-derivedDataPath .build/xcode-derived -resultBundlePath .build/history-copy/focused-configured.xcresult
-parallel-testing-enabled NO` with one `-only-testing:` argument for each
identity above, followed by `CODE_SIGNING_ALLOWED=NO test`.

Artifacts: `.build/history-copy/focused-configured.xcresult`,
`.build/history-copy/focused-configured.log`, and
`.build/history-copy/focused-summary.json`.

Broad Simulator validation of the same implementation source passed using:

```sh
mise exec -- env RUSTC_WRAPPER= BLEAT_SKIP_HOST=1 \
  BLEAT_SIMULATOR_DESTINATION='platform=iOS Simulator,id=2A3DA61A-D0F9-4D4E-92C8-065383EEC10D' \
  ./scripts/test-core.sh
```

- Release Simulator build: passed.
- App tests: 686 discovered, 686 passed, zero failures/skips.
- UI tests: 132 discovered, 125 passed, zero failures, seven allowed skips.
  All four cloud-storage notice journeys passed, including confirmation before
  current-account selection. The standard runner excludes
  `BleatAccessibilityAuditUITests`; no accessibility-audit result is claimed.

The seven skips match the runner's explicit allowlist and actual result reasons:

| Test (under `BleatUITests/`) | Reason |
| --- | --- |
| `BleatLiveUITests/testLiveExternalCoverReplacementSurvivesProcessRelaunch` | Requires `scripts/test-app-live.sh` live data |
| `BleatLiveUITests/testLiveOfflineCachedDownloadAndLocalProgress` | Requires `scripts/test-app-live.sh` live data |
| `BleatLiveUITests/testLiveOnlineLoginPlaybackAndDownload` | Requires `scripts/test-app-live.sh` live data |
| `BleatLiveUITests/testReleaseSecretScanLogout` | Requires `scripts/test-release-secret-leakage.sh` |
| `BleatLiveUITests/testReleaseSecretScanRefreshAfterTokenInvalidation` | Requires `scripts/test-release-secret-leakage.sh` |
| `BleatReleaseScreenshotTests/testReleaseScreenshots` | Requires `mise run screenshots` data |
| `BleatUITests/testAcceptsExternalURLConfirmationFromHost` | External URL driver belongs to `scripts/test-deep-links.sh` |

Broad log: `.build/history-copy/broad-uncached.log`. Result bundles and test
discovery inventories are under `.build/test-core-results/` with names
`app-tests-47314-1794075715647` and `ui-tests-47314-1794075715647`, respectively
(`.xcresult` and `.discovery.json`). Exact individual UI identities/outcomes are
also exported to `.build/history-copy/ui-tests.json`; summaries are
`.build/history-copy/app-summary.json` and `.build/history-copy/ui-summary.json`.
Both broad result bundles report no runtime warnings.

`mise run swift-lint`, `RUSTC_WRAPPER= mise run docs:check`, and
`git diff --check` passed. Changed and adjacent
production paths introduce no force unwrap/cast, forced try, fatal trap, or new
callback/executor boundary.

Initial invocation without mise failed before tests because the required
telemetry environment was not loaded. The corrected command above passed.
The initial broad runner stopped during Rust compilation because the optional
`sccache` wrapper reported `Operation not permitted`; its retry disables only
that wrapper (`RUSTC_WRAPPER=`), without changing cache locations or the runner.

Xcode emitted the existing App Intents metadata-extraction warning for targets
without an AppIntents dependency, and broad UI launches emitted debugger-version
lookup diagnostics (`noURL`/`no debugger version`). The focused result bundle
reports no runtime warnings. No physical-device, VoiceOver-session, live-server, production
CloudKit, signed-Keychain, or two-device conversion claim follows from these
Simulator results. The host lane was explicitly not rerun for this UI-only
change. No release or publication was performed. Later receipt/traceability
commits change only documentation, not the validated source/test inputs.
