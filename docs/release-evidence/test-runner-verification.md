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

## Bounded result report commands (#371)

At runner base `706c0a5c6c74cf5d3a5a21ff87233da57ca21bdf`, the three
`xcresulttool` bundle reads still used unbounded `Command::output`: modern test
nodes, modern summary, and the legacy action-result fallback. They now use the
same invocation-owned process group and reaping boundary as the smoke runner.
Each report process has a 120-second execution budget and three-second cleanup
budget. The existing bounded Drop fallback may attempt cleanup again after an
unsuccessful retirement; failed cleanup remains an error. Native argv, fallback
selection, schema validation, exact identities,
repetition accounting and skip policy remain unchanged.

Report errors preserve the exact `TestResults`, `TestSummary` or
`LegacyTestSummary` stage, native exit or original IO cause, and separate cleanup
and capture data. Ordinary Display/Debug formatting excludes captured payloads;
raw capture remains available for programmatic inspection. Invalid UTF8 has its
own output-encoding variant, with the original byte-free validation cause and
stage rather than an ambiguous JSON error.

Structured reports have a 64 MiB per-stream **read acceptance** ceiling. The
existing smoke consumers retain their 1 MiB ceiling and unchanged budgets.
A four-MiB valid JSON positive control prevents accidental reuse of the smaller
smoke ceiling. Oversized streams fail explicitly instead of returning truncated
success. Capture uses anonymous regular files; this read ceiling bounds accepted
memory, not disk growth while a process is still running. The execution budget
retires that process group. No shared Simulator/service or daemon is killed.

Seven native regression functions cover all three report modes:

- exact argv, including a bundle path with spaces;
- nonzero native exit, stage, retained capture and diagnostic non-disclosure;
- positively admitted held processes, typed deadline and actual reaping;
- a tiny injected read ceiling and rejection of partial success;
- invalid UTF8 offsets/type/stage without payload formatting;
- valid four-MiB JSON, compared by decoded structural equality;
- missing-tool and invalid-limit causes, plus the inherited smoke ceiling.

The deadline case reuses the existing independent fixture supervisor. It
observes the exact child's admission, checks return within the separate
observation bound, and releases/joins the worker before asserting a failure.
The existing PID/release polling checks state; no readiness delay is substituted
for completion. Normal and assertion-unwind cleanup affect only recorded
invocation-owned children and private files. These synchronous CLI boundaries
introduce no async-to-sync fallback or process-global environment/output change.

The retained six-prototype baseline extracts the old output/exit/encoding
adapter. It passed the argv and valid-output controls and failed four tests:
missing capture acceptance bound, held command outliving observation, synthetic
stderr copied into diagnostics, and lost encoding stage/type. The fixture was
released and joined before the deadline assertion failed. This is controlled
native evidence, not an untouched-base run or an observed production Xcode hang
or application disclosure.

A test-only helper import was missing in the first corrected compile; no tests
ran. I then reused its log before the prior writer exited, producing interleaved
output, and the interim command's final exit was unconfirmed after its handle
expired. That raw log is preserved and excluded from acceptance. Process state
was checked before recovery. Three clean serial focused runs use independent
logs and recorded exit files: **21/21 exact function executions passed**, with
all three admitted deadline stages reaped each run.

Final Mac source validation verified **154/154** exact owning outcomes across
11 nonempty targets; 16 zero-test CLI targets are compilation checks only. All
147 existing identities are preserved and only the seven new identities are
added. Three fresh final-source focused runs verified **21/21** executions,
zero failures or ignored tests. Strict all-target Clippy, formatting and docs
checks passed. The first Clippy run rejected six test-only error-extraction
expressions; an error-only helper now avoids formatting unexpected successful
payloads. Earlier pre-style 154/21 passes are retained as a separate epoch.

The changed native report readers accepted 626 exact outcomes from the retained
actual PR #424 CI bundle with compiler-discovery agreement. Its modern warning
field is present, so this real replay exercises test-tree and modern-summary
commands;the legacy mode is exercised by controlled native fixtures and existing
pure compatibility tests. This is not fresh app or Xcode26.6 execution.

Local M2 Linux ARM64 validation on Rust 1.97.1 passed **7/7** exact new native
functions, including all three admitted deadline/reaping modes. One labelled
owned container ran the exact final-source archive without host secret mounts
or volumes and was removed afterward. Its configuration was synthetic and
container-only. The first login-shell launch replaced the Rust image PATH and
failed exit 127 before tests; that log and verified container cleanup are retained.
The successful retry preserves the image environment without toolchain overrides.
All required local gates are finished; independent review and CI remain. Artifacts use the `.build/i371-report-` prefix and the
summary is `.build/i371-report-verification.json`. A retained-result replay is
reported separately from fresh application execution. Independent review and
exact-head CI remain separate gates.

This slice adds seven substantive other-audit and source-index records while
preserving all 398 prior other records and 1,604 prior index records. It does not
claim complete audit parity: five existing inline legacy-summary unit functions
in `scripts/src/test_results.rs` are absent from both inventories at this base.
They already run as tests and need a separate bounded source-audit repair under
#369; this is an inventory gap, not five new runtime tests:

- `missing_modern_warning_field_uses_real_legacy_empty_array_shape`
- `legacy_warning_and_error_summaries_fail_closed`
- `legacy_record_requires_nonempty_actions_and_action_issues`
- `non_object_summary_is_rejected_before_legacy_fallback`
- `null_modern_warning_field_does_not_use_legacy_fallback`

Owner: Bleat maintainers / @yaleman, coordinated under #369/#362. The next action
is to reconcile current PRs/issues, review each existing body/helpers, and add
individual dispositions and current source locations with revision-bound
execution evidence. Other listing, build-settings, discovery, installation and
test-command owners still require their own bounds/review. Fresh native Xcode
26.6, broader schema/semantic, opt-in, signed macOS app/auth and physical-device
acceptance are not established by these host fixtures or retained replays.
