# Test runner and shell-case review

This source review is part of [issue #362](https://github.com/terminaloutcomes/bleat/issues/362).
It supplements the per-function inventories: shell assertions and runner
verification are not Swift, Rust or Python test declarations. Baseline is
`d33a30a767d047b6a12e6f737b07e513e57aaf1c`; execution evidence belongs in the
[audit record](test-reliability-audit.md).

## Shell cases

All rows below were inspected. Unless specified, these are deterministic command
integration checks: synchronous command exit is the completion contract,
temporary directories are created before use and removed by EXIT traps, and
playback timing, async callbacks and network readiness are not applicable.
Assertions use parsed plist/JSON values where the result is structured.
The individual cases in each row are the script's test inventory; these scripts
do not emit XCTest-style test identities. Repetition evidence is separate.

| Script / cases | Setup, action and postconditions | Decision |
| --- | --- | --- |
| `scripts/test-testflight-export-options.sh`: upload; export; invalid team; invalid bundle; invalid destination | Synthetic team/bundle, fresh temporary plist. Upload asserts all eight expected values and exactly eight keys; export asserts destination. Each invalid input must return failure. | Keep. CLI parsing and structural output are observable; no signing or upload occurs. Shell assertion failures could identify the expected/actual value more clearly, tracked under diagnostics below. |
| `scripts/test-live-profiles.sh`: minimum; current-stable; unknown; both matching status fixtures; mismatched status; floating image; image/server mismatch; seed mismatch; missing seed; normal Compose image; overridden image | Versioned profile/status files, isolated mutations and Compose `config` without starting containers. Assert expected version/digest and reject mismatches after JSON decoding. | Keep. Real Docker Compose configuration integration; Docker CLI/plugin required. Commands are synchronous; failure messages identify rejected categories. |
| Historical `scripts/test-release-screenshot-harness.sh` (now Rust `release_screenshots::tests`): valid fixtures; launch contract; normalized orientations; empty/unsupported orientation; invalid duration/progress/chapter/cover/duplicate filename | Checked-in fixture and separate mutated files. Validation entry points must accept valid state and reject each mutation; launch contract is source inspection only. | Keep input-validation cases. Follow up source-only launch assertions under source contracts below; they do not execute launch behavior. |
| Same migrated Rust contract suite: portrait/light+dark; landscape/light+dark; missing dark; duplicate dark; invalid dark dimensions; public manifest; sensitive manifest | Generated attachment metadata and resized fixture PNGs in a temporary directory. Assert complete/unique files and decoded dimensions; reject access-token key in manifest. | Keep. Rust validates JSON/plist contracts; the fixture task still decodes actual covers through native `sips`. Unit input checks do not claim screenshot rendering. Native lifecycle regressions retain bounded owned-child cleanup. |
| `scripts/test-paid-developer-build-modes.sh`: eight paid capability combinations; global Personal Team override; paid default; Personal Team default; native macOS default | Query actual Release Xcode build settings. Assert effective capability flags and entitlement path, including macOS/Personal Team CarPlay disablement. | Keep platform configuration coverage. Xcode/package resolution is required; no signed-device evidence. Fixed source paths are intentional manifest contracts. |
| Same script: disabled entitlement content; macOS CarPlay absence; each CarPlay-enabled and disabled entitlement; three Info.plist effective substitutions; Keychain retained; four invalid mode values | Inspect parsed plist keys and invoke capability validator with one invalid setting at a time. | Keep structural checks; follow up invalid-input subprocess checks under failure specificity below. Compiler/tool failure can otherwise masquerade as intended rejection. |
| `scripts/test-secret-scanning.sh`: safe public material; unsafe key/file types; all four required rule IDs; current-source scan | Fresh directories, public certificate/JWKS and synthetic non-secret sentinels. Require safe pass, unsafe failure and specific findings; copy current source before scanning. | Keep. Findings are redacted and specific rules are asserted. Requires gitleaks, jq and tar; preserve scanner/tool failures separately from detected secrets. |
| `scripts/test-deep-links.sh`: cold book route; warm home/library/downloads/settings; three search kinds; author; series; unavailable Now Playing; malformed search ignored | Disposable Simulator and test driver. Require a new typed receipt for each valid route; verify malformed input leaves receipt unchanged during a ten-second observation window. | Follow up cold-launch setup and retained diagnostics below. Keep real scheme-delivery coverage and per-route receipts; do not replace it with parser-only tests. |
| `scripts/test-telemetry.sh`: collector effective config; private capture network; outage queue/retry exhaustion; capture readiness; resource metadata; trace parentage; CloudKit event; prohibited data absence; non-root image | Randomized disposable project/ports, fake attestation only against local API, real PostgreSQL/Collector and redacted captures. Each assertion checks effective service output/JSON/metrics; cleanup verifies containers, volumes and raw captures are gone. | Keep real integration assertions; follow up request deadlines, shared failure artifacts and selected-test verification below. No physical App Attest claim. |

## Runner selection and result verification

The table below records the original audit findings. The
[runner verification batch](test-runner-verification.md) implements the exact
identity and outcome checks identified here; that record distinguishes automated
regression checks from full live, macOS, and device execution evidence. Other
findings in this document remain open.

| Runner/helper | Reviewed contract and decision |
| --- | --- |
| `scripts/test-host.sh`, `TestSupport/HostTests/reports.py` | Keep: selects actual built products; removes owned stale reports; compares exact identity multiplicities with the host inventory; rejects failures and unexpected skips. Only named unsigned Keychain exclusion is allowed. Signed runner verifies profile and entitlement identity. Coverage must contain executed lines in both libraries. |
| `TestSupport/SwiftTestingPrototype/run.sh`, `verify-results.py` | Keep normal XML lanes: exact seven identities, six passes and one intentional skip. Four runner/coverage combinations retain separate outputs. Trace lane relies on log patterns; follow up structured trace-result verification before treating it as equivalent evidence. |
| `scripts/test-core.sh` | Follow up exact expected identities: current checks require some passing tests, a target node, and permitted outcomes, but can accept an omitted test. Release build, host tests and app/UI boundaries remain separate. |
| `scripts/src/ci_smoke.rs` | Follow up app inventory completeness: the two named smoke cases are required, but merely finding an app target and more than two tests does not prove every app test ran. Boot worker is joined even after build failure. |
| `scripts/test-live.sh`, `scripts/test-compatibility.sh` | Follow up execution verification: filtered Swift exit status can accept zero matching tests. Compatibility correctly uses both pinned profiles, unique projects, cleanup verification and aggregates failures; it inherits that missing execution check. |
| `scripts/test-app-live.sh` | Follow up exact identities: `Info.plist` existence/lint does not prove the online/offline test ran. Keep substantive 401 range-replacement evidence and separate offline server stop. Cleanup suppresses some failures; verify disposable resources are actually removed. |
| `scripts/test-macos.sh` | Follow up retained result bundle and exact macOS identities. Signed configuration is explicit, but command success alone is not per-test evidence. |
| `scripts/xctest.sh` | Follow up skip policy and selection identity: all-skipped output currently succeeds, and observed names are not compared with the requested selection. Unknown outcomes must also fail. |
| `scripts/test-performance.sh` | Follow up exact expected case/all outcomes: current nonempty output containing one `Passed` line is weaker than a full passing inventory. Keep Release scheme and forwarded seed configuration. |
| `scripts/test-download-performance.sh` | Follow up tab handling: jq emits a tab, but `grep -Fqx "${expected_test}\tPassed"` receives a literal backslash and `t` under zsh double quotes. A synthetic passing result reproduced the failed match. Preserve the two expected identities and count when replacing text matching with decoded Rust result verification. |
| `scripts/test-dynamic-type-ui.sh` | Keep: expected three identifiers, count and successful summary checked on iPhone/iPad; no manual accessibility claim. |
| `scripts/test-accessibility-ui.sh` | Keep: exact three identifiers and expected screenshot names, fresh disposable devices per settings pass; screenshot presence does not establish visual quality. |
| `scripts/test-voiceover-ui.sh` | Keep: exact three identifiers and summary, disposable devices and settings; spoken output remains manual evidence. |
| `scripts/test-mini-player-motion.sh` | Keep: exact four names/outcomes per device/mode, reboot to apply setting, cleanup-owned devices; visual motion still needs observation. |
| `scripts/test-landscape-ui.sh` | Follow up exact three names: summary counts alone cannot identify the executed cases. Keep separate iPhone/iPad result bundles. |
| `scripts/test-release-secret-leakage.sh` | Follow up exact identity equality: one successful test whose name contains the selector can accept a similarly named case. Keep decoded result export and redacted scan evidence. |
| Rust `capture-release-screenshots` (replaces `scripts/capture-release-screenshots.sh`) | Uses the canonical verifier for exactly `BleatUITests/BleatReleaseScreenshotTests/testReleaseScreenshots`, plus one-pass/zero-skip/zero-warning native summary checks. Retains named attachments, decoded dimensions, orientation, appearance and sanitized manifests. Compact native receipts survive owned scratch cleanup. This migration does not certify unexecuted capture configurations. |
| `scripts/live-test-environment.sh` | Keep status/HTTPS readiness polling: finite attempts, request max-time, asserted final status, disposable CA trust and version checks. Poll intervals are not used as proof of readiness. Review mutation/seeding cases with the live test inventory; running the harness is distinct evidence. |
| `project.yml`, generated Bleat/BleatMac/BleatPerformance schemes | Keep platform/configuration separation and nonparallel testables. Debug/iOS compiler guards still require an explicit inventory; scheme membership alone cannot discover excluded source cases. |

## Actionable follow-ups

Owner for these items: Bleat maintainers handling
[issue #362](https://github.com/terminaloutcomes/bleat/issues/362). These findings
remain open except where an implementation and validation record is linked.

### Exact result verification

Implemented in the [runner verification batch](test-runner-verification.md):
decoded identities, multiplicity, typed outcomes, and explicit skip policies are
checked by the Rust scripts package. Results and discovery evidence are retained.
The historical LLDB prototype trace lane remains diagnostic-only and is explicitly
excluded from this completion claim.

### Failure specificity and diagnostics

For shell invalid-input cases, assert the intended validation error/exit category,
not merely any nonzero exit. Replace quiet assertion-only failures with case,
expected and observed value, while retaining privacy-safe output. For source-only
screenshot launch checks, add a runtime assertion of the effective launch mode;
text matches can survive a disconnected implementation. Risk: unrelated compiler
failures can satisfy negative tests, and source shape can be mistaken for behavior.

### Deep-link readiness and retained evidence

Replace the 0.2-second pause before terminating the initially seeded app with an
acknowledgment that the test scenario and cleared receipt were persisted. Retain
the redacted driver log and result bundle on failure instead of deleting the
only diagnostic log during cleanup; verify the driver test's exact identity.
The ten-second malformed-route observation window is intentional negative
evidence, but document its budget and limitation. Risk: cold route setup races
and failures without retained diagnostic evidence.

### Telemetry deadlines and artifact isolation

Add connection and request deadlines to telemetry health/metrics curl calls;
finite loop counts do not bound an individual stalled request. Use a run-specific
failure-artifact directory so two disposable projects cannot overwrite/delete
each other's diagnostics. Verify every filtered Swift suite's executed identities.
Risk: stalled gates, contaminated failure evidence and false coverage claims.

### Cleanup and repetition

Where cleanup suppresses removal errors, verify absence of owned resources and
preserve the original failure alongside cleanup failure. Repeat affected runners
and cases after fixes, with fresh state and supported ordering/configuration
variations. Record exact individual outcomes; current source review is not a
substitute for those executions.
