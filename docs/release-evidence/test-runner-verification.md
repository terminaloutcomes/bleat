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

## Legacy summary test audit entries (#369)

The five existing inline legacy-summary tests named in the report-reader section
were absent from both `other.json` and `source-index.json` at
`8e49600401f93dcb0379f1da86a353cf9bbe222a`. Each now has an individual source
assessment, all nine reliability rules, enablement, concrete helper/fixture and
oracle descriptions, and a current source location. All 405 prior other-audit
records and 1,611 prior index records are preserved exactly. Historical root
metadata remains revision-bound; these additions are not a broad reconciliation.

The tests cover absent modern warnings with a valid typed empty legacy Array;
five nonempty legacy warning/error collections; missing action issues and empty
actions; non-object summaries rejected before a must-not-call loader; and
present-but-null modern warnings rejected without fallback. Assessments retain
the actual strength of each assertion: `is_ok`/`is_err` and wildcard variants are
not relabelled as exact count or reason checks. The test-only panic closure is a
must-not-call oracle and introduces no production trap.

Runtime code, assertions, fixtures and dependencies are byte-identical to the
named base. All five exact native identities passed in that source's verified
154-outcome owning gate, with zero failures, ignored or filtered tests. Source
and fixture hashes bind the retained evidence; no new executions, focused
repetitions or five new coverage cases are claimed after metadata edits. The
report-reader's 21 focused executions cover different functions. This audit-only
repair does not establish fresh Xcode26.6, app, live, device or whole-epic
acceptance. Artifacts are `.build/i369-legacy-verification.json` and its linked
retained execution/scope evidence; raw logs remain private.

Review and exact-head CI remain separate requirements. Other missing or stale
records need record-by-record source review under #369; this bounded repair does
not certify name/index parity or invent an outstanding defect count.

## Remaining smoke command bounds (#371)

At base `0084df83851373294e882734bb193a91b0fffd39`, six smoke command
invocations still used unbounded native `status`/`output` calls: Xcode version,
Simulator inventory, build settings, enumeration, installation and test execution.
They now use the existing invocation-owned process-group boundary. Version and
inventory have 120-second execution policies; settings, enumeration and install
have 300 seconds; test execution has 2,400 seconds. Cleanup has its existing
three-second policy and bounded Drop fallback. Only invocation-owned commands
are retired; this does not certify completion/cancellation of operations already
submitted to shared CoreSimulator services.

Inventory and settings retain complete structured output up to the same 64 MiB
per-stream accepted-read ceiling as result reports. Anonymous capture files may
grow until the deadline; this is not a disk quota. Failed captured commands no
longer print raw stderr. Their exact stage, native cause, bounded raw capture and
cleanup outcome remain available while ordinary error formatting omits captured
bytes. The four status phases keep inherited live console output. No global
redirection, service reset or private configuration change is introduced.

Native argument vectors, environment selection, selected identities, discovery
and result paths, build/boot concurrency and all parser/verification assertions
remain unchanged. Test-result verification still runs after execution failure,
including deadline or spawn failure. A dedicated error retains execution and
verification failures separately; dual success alone establishes acceptance.

Six new native test functions review exact policy mapping, all six admitted held
commands and their retirement, native exit versus missing-tool causes, captured
synthetic marker non-disclosure, complete structured positive output beyond 1 MiB,
and all four execution/verification outcome combinations. Their individual
nine-rule assessments append to `other.json` and `source-index.json`, preserving
all 410 and 1,616 prior rows. Existing test bodies and process ownership algorithms
are unchanged. Local repetitions, owning outcomes, review and exact-head CI must
be inspected separately; a successful fixture is not fresh Xcode execution.

Remaining confirmed native command sites at this base are SwiftPM discovery and
execution plus the general Xcode runner status helper. Their distinct selection,
observation and result-audit contracts require separate review. Full record-level
schema, current source-audit dispositions, opt-in/configuration and physical-device
acceptance remain under #369/#362. Historical follow-up totals are not remaining
defect counts.

Local verification on the final runtime/test source: all six exact new native
function identities passed three serial focused runs (18 function executions).
The complete scripts owning gate passed 160 exact outcomes across 11 nonempty
targets, with zero failures, ignored or filtered tests; 16 zero-test CLI targets
are compile checks only. Strict Clippy, formatting, documentation and diff
checks passed. Independent review cleared source commit `4dc27a2`; final metadata
review and fresh exact-head CI remain separate. Evidence is retained in
`.build/i371-smoke-verification.json` and its linked native logs/manifests.

The initial six-function run preceded the additional Error::source assertions
and is retained separately. A later evidence-parser assertion saw only five
single-line outcomes because `--nocapture` interleaved one function's output;
that orchestration stopped before launching final tests. The native log still
shows all six passed. The corrected final sequence above used ordinary native
captured output and does not count that parser failure as test coverage. An
unavailable Python TOML import also stopped before setup execution; the exact
checked-in setup script subsequently ran successfully. No observed production
hang or payload disclosure is claimed.

## SwiftPM command bounds (#371)

At base `6ec96a59e6bad297f2860f45c83bee3ac2543765`, SwiftPM discovery and
execution still used unbounded native calls. They now use the same
invocation-owned process boundary with distinct XCTest discovery, Swift Testing
discovery and execution stages. Discovery has a 1,200-second execution policy;
execution has 3,600 seconds. Cleanup retains its existing three-second policy
and bounded Drop fallback. Native descendants in the owned process group are
retired; independently managed services are a separate boundary.
These noninteractive batch commands use the shared owner's null stdin. Discovery
already used null stdin; execution now receives EOF rather than inheriting
interactive parent input.

Discovery captures complete stdout up to a 64 MiB accepted-read ceiling and
preserves inherited live compiler stderr. Compiler stderr is never buffered or
replayed to the parent's console. Existing capture-both and inherited-output
callers keep their policies. Anonymous files may grow until the deadline; the
ceiling is not a disk quota. Encoding failures retain the runner and original
UTF8 error without embedding captured bytes in diagnostics.

Selection, observer environment, report preparation and identity interpretation
remain unchanged. Every execution outcome now audits existing result artifacts,
including spawn/deadline failures. Native and report failures remain separate
typed causes rather than a status/audit string. The exact accepted verification
summary is returned only after native success and a successful audit.

Seven controlled native/pure regressions cover arguments and budgets, actual
admitted child deadlines/reaping, missing tools versus native exits, selective
stdout transport/encoding, capture rejection, child-only observer environment,
and the four native/audit outcome combinations. Seven individual nine-rule audit
records append while preserving all 416 prior other records and 1,622 index
records. Actual focused, owning, representative SwiftPM, review and CI acceptance
remain separate gates; no fixture is fresh SwiftPM, app, signed-Keychain, live or
device execution. The general Xcode runner and broader #369/#362 reconciliation
remain open.

Local final-source verification passed all seven exact new native function
identities in three serial runs (21 executions), and 167 exact owning outcomes
across 11 nonempty targets. There were zero failures, ignored or filtered tests
in the owning gate; 16 empty CLI targets are compilation only. Strict Clippy,
formatting, documentation and diff checks passed. Independent source review
cleared `9809a3c`; final metadata review and exact-head CI remain separate.

Fresh actual SwiftPM selections through the changed binary verified three
`TelemetryLiveTestConfigurationTests` XCTest identities using authoritative
native observer records, plus two controlled-clock `PrivateCloudSyncTests`
identities repeated three times (six Swift Testing passes). Exact selections,
individual outcomes and XML/observer artifacts reconcile with zero skips. The
existing configured package cache at `f8237ee` was reused for these fresh
executions; selected tests, helpers, observer, production sources and manifest
were hash-equal to this checkout. No cache relocation, compiler/SDK override,
server, actual CloudKit device or signed-Keychain result is claimed. This also
supplies the previously unclear focused controlled-clock evidence under #373;
its broader audit disposition remains separate.

The native XCTest invocation emitted two upstream OpenTelemetry manifest
warnings about deprecated watchOS4 (four matching diagnostic lines); the three
clock logs had no warnings. The older unrelated Package.swift sysroot diagnostic
remains retained and unresolved; its absence here does not establish its cause.

The first native fixture run had six passes and one failure: an assertion
expected an unboxed Failure from Error::source. The final assertion instead
verifies the exact originating typed deadline cause and duration fields through
the error chain, retaining direct stage and paired-error assertions. Its earlier
failure is preserved, separate from the clean 21-execution sequence. An actual
SwiftPM attempt also rejected unsupported `--skip-build` before discovery or
execution (zero tests); the supported invocation above ran subsequently without
changing the implementation. Neither attempt is counted as acceptance coverage.
Artifacts are `.build/i371-swiftpm-verification.json`, its native selections and
linked logs/manifests. No observed production hang or disclosure is claimed.

## Direct Xcode runner command bounds (#371)

At base `1f59c442d5066cabc9b5a5e08fd4c6f62a5da313`, the general Xcode runner
had six direct native call sites plus an aggregate-script caller sharing an
unbounded status helper. The six direct sites now use seven typed roles: Swift
Release build, Cargo release-version tests, package resolution, Release Simulator
build, build-for-testing, enumeration and test execution. Version tests and
resolution have 1,200-second policies; builds 2,400; enumeration 300; execution
3,600. Cleanup retains the existing three-second policy and bounded fallback.
These batch commands inherit live console output and receive null stdin.

The adapter preserves status() semantics for observed nonzero exits only after
the existing owner confirms retirement. Other native failures retain exact role,
stage, original cause and context label. Unconfirmed cleanup is never converted
to an accepted status. Result verification remains unconditional after attempted
test execution; both native and verification failures survive. The combined
message describes native failure accurately for spawn and deadline cases.

Existing builders, selectors, discovery/result paths, verification flow and all
four existing runner assertions are preserved. The package-resolution test's
single action argument becomes a typed enum. Test-only fixture visibility allows
reuse of the existing lifecycle guards; their bodies and existing tests are
unchanged. The existing cleanup predicate is visible within the crate so status
translation uses the same retirement contract; its behavior is unchanged.

Four new functions cover all seven policies and native status/spawn cases,
positively admitted held commands with observed cleanup, rejection of fabricated
unconfirmed retirement, and the six full-gate exit/spawn/deadline-versus-result
combinations. Four individual nine-rule assessments append while preserving all
423 prior other records and 1,629 index records. These native fixtures do not
constitute actual Xcode/app execution or full verifier-schema acceptance.

The two aggregate scripts (`test-host.sh` and paid-developer build modes) remain
explicitly separate. Killing an outer shell would bypass EXIT cleanup and does
not prove nested Foundation/SwiftPM or tool-created process groups drained.
Likewise, native group retirement does not own shared CoreSimulator, Xcode build
or signing services, nor Simulator-hosted application processes. Those remaining
ownership and configuration boundaries stay open; this slice does not certify
all runners or the broader #362/#369 audit.

Final-source local verification passed the four exact new functions in three
serial focused runs (12 executions), then 171 exact owning outcomes across
11 nonempty targets, with zero failures, ignored or filtered tests. Sixteen empty
CLI targets are compilation only. Strict Clippy, formatting, documentation and
diff checks passed. Independent review cleared source commit `656c3a3`; final
metadata review and exact-head CI remain separate.

A fresh actual app-hosted Xcode selection through the changed runner passed
`BleatAppTests/FrameworkCallbackTests/testActualPlayerKVOCallbackRunsOffMainActor`.
Its compiler discovery and one individual result reconcile, with zero failures,
skips, expected failures and runtime warnings. A new disposable Simulator was
created for this invocation, then shut down/deleted with its absence verified;
no shared device or service was reset. This is Simulator/framework evidence,
not physical playback, signed-Keychain, release or whole-epic acceptance.

The native build retained one `Package.swift: BleatTranscriptiondynamic-product`
compiler warning about a macOS 27.0 sysroot targeting an iOS 26 Simulator triple.
The app, generated transcription framework and app-test bundle were inspected
with vtool: all three are IOSSIMULATOR with minimum OS 26.0. No explicit SDKROOT,
DEVELOPER_DIR or deployment-target override appeared in the mise child, and no
compiler/SDK settings were changed. The diagnostic's underlying cause remains
unresolved; successful execution and correct product platforms do not erase it.
Native artifacts and warning/platform checks are linked from
`.build/i371-xcode-verification.json`.

Adjacent audit found a separate existing result-preservation guard defect:
`result_bundle.exists()` checks process cwd instead of the repository root.
A private synthetic probe rejected an existing bundle from root cwd but invoked
the stub native tool from nested cwd; both retained sentinels stayed unchanged.
Independent review corroborated the guard bypass. No real overwrite is claimed.
The guard is unchanged in this ownership slice and requires its own bounded
#371 correction; it is not hidden by the fresh successful result path.

## Repository-root result preservation guard (#371)

The general Xcode gate resolved discovery/result paths against its repository
root, but checked an existing relative bundle against process cwd. A private
synthetic CLI probe at `1f59c44` rejected the retained bundle from root cwd and
invoked the stub from nested cwd. The guard clause is identical at parent
`7f05e2b`. Both sentinels stayed unchanged; this demonstrates guard bypass,
not a real result overwrite. The finding was reported before implementation.

The one production condition now checks `root.join(result_bundle)`, matching the
root already used by native arguments and the typed ExistingResultBundle path.
Absolute paths retain their behavior. All other production bytes and previous
native test bodies are unchanged. No SDK, configuration, cleanup policy or
credential behavior changes.

One regression covers absolute and relative paths from an explicit isolated root
without changing process cwd. It requires exact typed rejection, no native tool
or verifier invocation and unchanged opaque artifact bytes. One nine-rule audit
and declaration append while preserving all 427 prior other rows and 1,633
index rows. Focused repetitions, owning outcomes, the post-fix CLI probe, review
and exact-head CI must be inspected separately; no actual Xcode/Simulator run
is claimed by these synthetic guard cases. Broader #362/#369 acceptance and
aggregate-script ownership remain open.

Local final-source verification passed the exact new native identity in three
serial focused runs (two path modes per execution), plus 172 exact owning
outcomes across 11 nonempty targets with zero failures, ignored or filtered
tests. Sixteen empty CLI targets count only as compilation. Strict Clippy,
formatting, documentation and diff checks passed. The fixed public CLI probe
now rejects both root and nested invocations before the stub, preserving both
sentinels. These two synthetic CLI cases are not actual Xcode/test executions.
The original failing guard observation remains separate and unmodified.

Artifacts are `.build/i371-result-guard-verification.json`, its exact native
outcomes and before/after probe references. Parent native Xcode evidence remains
revision-bound; no expensive real Xcode run was duplicated for this guard-only
change. Independent review and exact-head CI remain separate gates.
