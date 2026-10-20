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

## Structured result children schema (#371)

The structured Xcode verifier previously treated a present, non-array `children`
field as an absent child list. A synthetic offline CLI fixture with a passed
case and an object-valued child containing a failed repetition was accepted as
one pass. Two new regressions failed against the unchanged parser at the null
case and repetition boundaries. These are invalid-schema reproductions, not an
observed malformed Xcode run or application failure.

The parser now distinguishes absent children from present malformed values and
returns typed `InvalidResult("children must be an array")` for the latter. The
same check applies to cases, containers, nested repetitions and messages.
Borrowed child slices also avoid cloning the result subtree. Omitted fields and
empty arrays retain their existing behavior. No outcome, identity, repetition,
summary, skip or legacy-warning assertion is removed.

Three native regression functions cover 50 invalid shapes (null, Boolean,
number, string and object across structural locations), plus absent/empty
compatibility checks and the retained genuine Xcode repetitions. All five
existing integration test bodies and their original line positions are
preserved byte for byte. Three substantive audit/index entries are added; all
existing rows are preserved.

Final m2 validation verified139/139 exact owning scripts outcomes across11
nonempty targets;16 zero-test CLI targets are compilation evidence only. All
eight verifier identities passed three independent focused executions each
(24/24). Strict all-target Clippy,formatting,documentation and preservation
checks passed. The fixed binary also accepted all626 outcomes from the retained
#418 iOS CI JSON against its own discovery;this is replay evidence,not fresh
iOS execution. The original malformed CLI fixture now rejects with the exact
typed schema error. Commands,identities,exits and source hashes are retained in
`.build/i371-schema-verification.json`. Independent review and exact-head CI
remain required before reporting this bounded slice reviewable. The original
accepting CLI probe and two failing native regressions remain retained. Broader
verifier acceptance and epic configuration reconciliation remain open.
