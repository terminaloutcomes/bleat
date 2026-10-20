# Runner verification batch

This batch implements the result-verification follow-up from
[issue #362](https://github.com/terminaloutcomes/bleat/issues/362).
It does not close the other timing, cleanup, fixture, or device-evidence findings.

## Implemented checks

`scripts/src/test_results.rs` decodes Xcode discovery and result JSON. It compares
exact target/suite/function identities, checks every requested repetition and
aggregate case outcome, and reconciles summary counts and diagnostics. Unknown
outcomes, missing or additional cases, duplicates, unapproved skips, failures,
runtime warnings, and entirely skipped selections fail validation.

Xcode 26.6 omits `runtimeWarnings` from the summary. For that schema, the
verifier reads the bundle's typed legacy action-result issue summaries and
rejects warning or error entries before accepting the summary. Missing or
malformed issue records fail validation; a present but malformed modern
`runtimeWarnings` value does not trigger this fallback. CI smoke discovery is
read from Xcode's dedicated JSON output file, separately from console output.

Core, macOS, focused Xcode, and CI smoke runners derive expectations from built
test discovery. App-live, performance, download performance, landscape,
release-secret, screenshot, and external deep-link journey runners declare the
exact intended cases. The download-performance runner no longer compares real
tabs with a literal backslash-t sequence.

`scripts/src/swift_test_results.rs` keeps XCTest and Swift Testing discovery and
results separate, applies the requested selection, and retains a selection
JSON artifact before execution. Live, compatibility (through live), and telemetry
runners use it. Optional skips are named individually in the ordinary
Audiobookshelf lane; telemetry execution requires all selected cases to pass.

Live XCTest cases use a test-only `XCTestObservation` adapter in
`Tests/BleatCoreLiveTests/SwiftPMXCTestReport.swift`. It records typed native
outcomes, including skipped cases, in owned JSON artifacts. Swift Testing retains
its XML reporting. Real toolchain experiments showed that default serial XCTest
emits no XCTest XML, while `--parallel --num-workers 1` emits XML that represents
a thrown `XCTSkip` as an ordinary passing case. Neither report is accepted as
authoritative XCTest evidence. This agrees with the upstream
[serial XCTest reporting issue](https://github.com/swiftlang/swift-package-manager/issues/9961);
the skip misclassification was reproduced locally.

## Validation

- `cargo test --locked --package scripts --all-targets`: 129 tests passed across
  12 nonempty test targets. CLI targets with zero tests were build checks only.
  The regression cases include missing, duplicate, extra, wrong-target, skipped,
  unknown, failed, inconsistent-summary, and repeated outcomes. Four tests run
  the actual download-performance, performance, and landscape shell runners
  against controlled Xcode output and the real verifier binary.
- Replayed retained `.build/issue-362-app-final-repeat.xcresult`: 598 distinct
  app cases and 1,196 passing repetitions verified. The retained
  `.build/issue-362-owning-suites.xcresult` was rejected for its recorded failure.
  These are verifier checks against previous evidence, not fresh app execution.
- `cargo clippy --locked --package scripts --all-targets -- -D warnings`,
  `cargo fmt --all -- --check`, `mise run docs:check`, changed-shell `zsh -n`,
  and `git diff --check` passed. All 17 changed live-test Swift files passed
  `swift-format` lint after formatting.
- The focused Xcode runner built, discovered, executed, and verified
  `BleatAppTests/DocumentationLinkTests/testOpenIDSetupGuideUsesStablePublicURLWithoutUserData`:
  one pass, zero skips/failures/runtime warnings on a disposable iPhone 17 Pro,
  iOS 26.5 Simulator. Evidence is
  `.build/runner-verification/focused-ready.xcresult` and its sibling discovery
  JSON. The owned Simulator was deleted after verification.

- The serial SwiftPM wrapper verified all three
  `TelemetryLiveTestConfigurationTests` from native XCTest observer JSON, with
  exact discovery identity agreement and an empty auxiliary Swift Testing report.
- The Swift Testing wrapper verified 18 of 18 `TelemetryAuthenticationTests`,
  with zero skips. Selection, native XCTest JSON, and Swift Testing XML artifacts
  are retained under `.build/swiftpm-test-results/` with the `targeted-` prefixes.
- A real fixture-disabled
  `TelemetryAuthenticationLiveTests/testSwiftDevelopmentAttesterObtainsVerifiableJWT`
  run produced a native `skipped` record. The verifier rejected that all-skipped
  selection even with an exact skip allowance. This validates the failure boundary
  that SwiftPM's parallel XML incorrectly reports as passing.

The first fresh Simulator attempt built and discovered the selection but failed
application preflight with `FBSOpenApplicationErrorDomain` code 6 (`Busy`). No
test process appeared; Xcode stalled and was interrupted, then terminated when
the interrupt did not finish. Its incomplete bundle was rejected by the verifier.
The log is retained outside the repository as `bleat-runner-xctest.log`; the
failed attempt is not counted as test evidence. The passing retry followed an
explicit `simctl bootstatus -b` readiness check and used a separate result path.

Intermediate integration builds exposed compile errors while the
parallel changes were being combined; those attempts executed no platform tests.
The OpenTelemetry dependency emitted its existing deprecated watchOS deployment
version warning during Swift builds; this is not a test runtime warning.

Independent read-only `review-agent` review of the completed batch returned no
remaining findings. Review and integration fixes included duplicate repetition
identifiers, package-resolution option forwarding, empty macOS signing settings,
and retained result paths that permit repeat runs without deleting prior evidence.

## Remaining boundaries

This change verifies what each selected test actually reported. Passing result
verification does not establish that a test's assertions satisfy its product
contract, nor does it replace signed-host, live-server, or physical-device
evidence. The other audit remediation batches remain open.
The full Docker live/telemetry/compatibility workflows, signed macOS gate,
full Simulator suites, and physical-device workflows were not rerun in this
batch; the fresh platform execution above is deliberately focused.

The historical Swift Testing prototype's LLDB trace lane remains a diagnostic
lane based on log patterns. Its ordinary XML lanes already verify their exact
seven-case inventory; the trace lane is not promoted to equivalent test evidence
by this batch.

## Smoke runner command ownership (#371)

The local runner slice demonstrates three failure boundaries before fixing
them. A minimal extraction preserved the legacy command behavior while allowing
per-invocation fixture commands. All three regressions failed: stdin writing
returned `BrokenPipe` while the started child remained alive; a ready-but-held
boot fixture prevented return through the observation window and returned
success only after release; and the production result combiner failed to retain
two completed native causes together. Fixtures were released and reaped before
failed assertions were reported. This is controlled native runner evidence, not
an observed production Simulator incident. Baseline source and logs remain in
`.build/i371-baseline-source.json` and `.build/i371-baseline-regressions.log`.

`jq` input now uses a private anonymous regular file prepared before spawning.
There is no post-spawn pipe write to fail before child retirement. Capture also
uses private regular files, so a descendant cannot hold a pipe EOF indefinitely.
The invocation owns its process group through non-reaping exit observation,
cleanup and direct-child reaping. Captured output is limited to1 MiB per stream.
New command-error formatting exposes byte counts instead of payload; output
UTF8 errors retain the byte-free validation cause. Synthetic marker regressions
check both Display and Debug while preserving typed failure data.

Build and optional boot/readiness commands are observed by one owner; there is
no production boot thread to join. Failure retires a still-running peer, while
an already-completed peer retains its native exit cause. Both failed outcomes
are retained in `PreparationFailure`. Readiness commands share a five minute
budget, compilation has 40 minutes,and JSON commands have two minutes. Cleanup has
three seconds, with one additional bounded Drop attempt after an unsuccessful
retirement. Positive historical combined build/test steps took about 20 minutes;
these policies introduce failure bounds, not performance expectations or strict
kernel interruption guarantees. Already-expired phases cannot start readiness.

Only wrapper command groups are invocation-owned. The selected Simulator and
CoreSimulator services remain shared; the change does not reset, shutdown, delete
or signal them. Other report/list/build-settings/discovery/install/test-command
boundaries are unchanged and remain separate lifecycle work. Native spawn and
local filesystem stalls, deliberate process-group escape, process destruction,
unreapable kernel states and daemon retirement are not certified. Failed cleanup
remains an explicit error rather than a successful retry.

Final m2 validation accounts for **147/147** exact native test outcomes across
11 nonempty targets;16 zero-test CLI targets are build checks only. All 11 new
lifecycle identities and three original selector identities passed three
individual focused repetitions each: **42/42** exact one-test executions. The
original selector test bodies are byte-identical to base. Strict all-target
Clippy, formatting, documentation and scope checks are recorded separately in
`.build/i371-runner-verification.json`. Compile alias/lifetime and six Clippy
conditional-style corrections are retained. Earlier 146/146 and 39/39 results
precede the test-only release/join unwind guard and its extra native regression;
they are not relabelled as final-source executions.

The three original audits previously called selection pure, although it invokes
external `jq`. Their current dependency/lifecycle descriptions are corrected
with full historical records retained. Eleven new source-reviewed audit/index
rows cover the lifecycle cases;384 unrelated audit rows remain unchanged. The
prior 725 moved navigation references are a historical navigation snapshot, not a
semantic defect count. This slice remains local: no independent reviewer was
contacted, no publication or tracker write occurred,and `fe76c69` plus draft
PR #417 remain unchanged. Linux and real Xcode/Simulator execution,independent
review and eventual integration remain separate requirements. Owner: Bleat
maintainers / @yaleman under #371/#369; broader epic acceptance stays open.
