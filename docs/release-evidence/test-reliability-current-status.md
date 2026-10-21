# Test reliability: current delivery and acceptance

Issue [#362](https://github.com/terminaloutcomes/bleat/issues/362) remains open.
This checkpoint reconciles landed implementation with evidence and the
maintainer's 21 October priority: finish important demonstrated problems and
acceptance work; defer macOS application changes and optional hardening.
An unchecked historical bullet is not itself an unfixed bug.

## Revision and counting

Source checkpoint: `c71298edfb918678145cdd97bf5fb62f8422f19e` (merged #440).
It contains the reviewed #437 integration, #438 fallback-test completion repair,
and #439 host-driver cancellation repair. Subsequent #430 updated the mise
action, and #440 repaired two demonstrated Release gate build failures.
[Exact-head Validate Bleat39632228095](https://github.com/terminaloutcomes/bleat/actions/runs/39632228095)
passed at #440's reviewed `cdd7a38`. Historical executions below retain their
actual revisions; the owning local Simulator run remains tied to `adc7ac4`.

Count different units separately:

| Category | Count / current disposition |
| --- | --- |
| Proven unresolved implementation bugs | 0 currently confirmed after #438/#439/#440. Two demonstrated Release gate build blockers are repaired, and the full gate passed with the documented explicit-version setting. This is not a claim the app is bug-free. |
| Unresolved observed validation failures | 1: iPad Increase Contrast mini-player geometry; see below. |
| Important implementation remainder | 0 confirmed code fixes after #440. This receipt reconciles the delivered work; full Release archive/surface-scan acceptance passed with the documented explicit release version. |
| Missing structured audit/index records | 87 source-confirmed declarations: 25 app, 8 UI, 54 Rust. These are record omissions, not reproduced defects. |
| Existing-record review queue | 71 app semantic rechecks and 241 core helper-context rechecks retained from the bounded prior reconciliation. These overlap source concerns and are not implementation-task counts. |
| Deferred macOS implementation groups | 5, explicitly not completed, in #369. |
| Optional/unproven hardening groups | 22, listed below; no implementation is authorized merely by a source concern. |
| Broader configuration/device acceptance | 8 tracked groups: G4 completed; 7 remain separate configuration/device dispositions, not seven new code defects. |

The previous 19-PR backlog (#417–#429, #432–#437) is merged, as are #438/#439/#440.
Do not report those PRs, the old 140 follow-up labels, or navigation line drift as
remaining code work. Full audit compliance still requires the record review
and configuration dispositions; this checkpoint does not certify it.

## Child acceptance reconciliation

Four children are closed: #370, #371, #373 and #376. Four remain open: #369,
#372, #374 and #375, for the explicit formal/configuration dispositions below.
These are issue counts, not four newly discovered bugs.

| Issue | Landed source/evidence | Current disposition |
| --- | --- | --- |
| #369 | #417 adds the five host and nine build-helper records, moved-path history and parity checker. #418 and #437 reconcile reviewed command-owner records. The eight checker regressions and preservation checks are retained in [the audit](test-reliability-audit.md#missing-audit-entry-repair-369). | The old 14-record repair is delivered. Keep comprehensive inventory/semantic reconciliation open; retain the 87 omissions and existing-record queue explicitly. |
| #370 | The small `build-scripts` package, caller-environment/dependency/sandbox regressions and workflow consumers are present. #418 bounds the three build-helper regression commands. Actual Xcode build-for-testing without compiler/SDK overrides is retained in [build-helper evidence](test-reliability-audit.md#build-helper-dependency-isolation-2026-10-16); current app CI continues to build using it. | Closed after reconciliation: all four bounded extraction acceptance items have implementation/execution evidence. Later independent subprocess hardening is a separate optional concern. |
| #371 | Exact native identities, multiplicities and skip policy are verified by the current runners. #419/#425/#427–#429 own runner/report commands, #420 rejects malformed children, #426 supplies legacy-summary audit records, #432 preserves repository-root results, #435 preserves typed paid-build failures, and #439 handles driver cancellation. See [runner evidence](test-runner-verification.md). | Closed after reconciliation: all four selection/parser/execution acceptance items are delivered. Retained JSON/schema replay is distinct from fresh native execution. Further aggregate/nested-owner hardening is not a demonstrated selection defect. |
| #372 | Account/transport/telemetry/callback/observer fixes through #434 are merged. Specific original semantics, focused repetitions and signed owners are retained in [core follow-ups](test-reliability-core-followups.md), #437 and #439. | Delivered changed fixtures are credited; broad per-record/helper audit remains in #369. Keep formal acceptance open rather than certify every host helper from one passing suite. |
| #373 | Controlled-clock progress reset, foreground/background expiry and callback-drain tests remain; production defaults use `ContinuousClock`. Cache tests retain parent-supervised startup/cancellation/timeout/success boundaries. | Closed after reconciliation: all four bounded clock/cache criteria have evidence: original focused repetitions at `39fd45a`, clock-specific native selections retained in #428, plus all named clock/drain and five cache cases in the retained 609-pass signed report at `e9835ae`. This does not establish live CloudKit/device behavior. |
| #374 | #386 and later app fixes, #393, #438 and the current 627-test app owner cover changed iOS semantics. #438's controlled ordering witness reproduced the actual premature completion assertion; [exact-head CI39581982755](https://github.com/terminaloutcomes/bleat/actions/runs/39581982755) verified 629 iOS outcomes. | No confirmed open app defect from the focused investigation. Formal source audit and deferred macOS configuration remain explicit; do not count source-only candidates as bugs. |
| #375 | #436 supplies post-registration gate cancellation/repeated release/reuse; #437 fixes the edit-download fixture menu. Three native app fixture regressions and 629 iOS CI outcomes are retained at #437. | Current owning standard UI validation passed 119 tests with six explicitly allowed skips; 627 application tests also passed. Playback-menu semantic assertions remain. Optional caller-diagnostic edits are preserved unpublished, not silently counted as delivered. |
| #376 | Already closed: #380/#381 cleanup, two Audiobookshelf profiles, two app-live journeys and specific artwork phone acceptance have revision-specific evidence. | Preserve its closed state. The remaining configuration/device gates below are not certified by that closure. |

The signed evidence above is 609 distinct identities (604 core and five
transcription), zero failures/skips, executed at `e9835ae`. Its 215 tracked host
inputs remained identical through #439 and `adc7ac4`. At this checkpoint 214
remain identical; #440 changed the paid-build validator's iOS branch, retaining
its macOS branch. The signed result is retained execution at `e9835ae`, not a new
signed run of #440 or this documentation checkpoint. #439's exact-head
[CI39585563313](https://github.com/terminaloutcomes/bleat/actions/runs/39585563313)
verified 608 host passes plus the named unsigned Keychain skip, 629 iOS passes
with zero failures/skips/expected failures/runtime warnings, and 329 Rust passes
across 22 nonempty targets. The 26 other Cargo targets were compile-only.

## Important local acceptance

Current owning Simulator/UI gate: **passed**, command
`BLEAT_SKIP_HOST=1 mise run test:local`, at `adc7ac4`. The Release Simulator
build passed; all 627 application identities passed with no skips, and the UI
selection contained 125 identities: 119 passed and six explicitly allowed skips.
Canonical result/discovery checks found no failures, expected failures or runtime
warnings. Allowed skips were external-URL confirmation, the two opt-in live
journeys, Release screenshots, and Release-secret refresh/logout. Configured
accessibility tests remain a separate gate. Private result bundles, exact
identities and receipt are retained in `.build/i362-important-ui-verified.json`.
The owning run did not change source or configuration. Existing signed host
evidence is reused rather than relabelled as a new run.

The first real Release secret-leakage gate then failed at build-for-testing,
after seven scanner Python regressions passed and before any native App/UI
selection. Its original activity log identified rejected HTTPS loopback telemetry
in the instrumented Release Simulator. A bounded validator regression reproduced
that failure. After admission was repaired, a second compile exposed a fixture
test class compiled without its guarded subject types. The class now matches
the subject's `DEBUG || BLEAT_UI_TESTING` condition. All five Debug fixture
identities and the Release compile pass; the validator's three new functions
pass individually and all 38 owning package tests pass. Both failures remain
retained. No TLS trust policy or ordinary Release/device origin rule changed.

The full repaired secret gate at clean candidate `cdd7a38` passed seven scanner
Python regressions and all nine exact native cases, including online login,
refresh, offline restoration, logout and credential/capture removal. It then
failed before archive building at the release-version preflight: generated
`2026.10.21` differs from checked-in `2026.10.14`. No release metadata was changed
and no version override, upload or deployment was requested. The archive and
final surface scan did not execute in that attempt; these passing journeys are
not a complete secret-nondisclosure result. The existing documented
`BLEAT_MARKETING_VERSION=2026.10.14` setting supports a later-day rebuild with a
fresh UTC build number. Its resolver/metadata preflight passed without source
changes. The separate full gate using that setting passed at clean `4542700`:
seven Python regressions and nine native cases, inspected Release archive
(version `2026.10.14`, fresh build `20261021.1653.50`), and all nine scan surfaces
covering 667 files / 1,677,234,199 bytes with zero prohibited findings. Two expected
refresh-token redactions occurred only in disposable server logs. The final
report contains no secret values/digests. Cleanup again verified no owned
resources remain. This corrects the earlier overly strong conclusion that a
version bump was necessarily required; no project metadata changed. All three attempts and their individual outcomes remain
retained. Independent checks after each attempt found no owned Simulator,
container, volume or private secret-broker process.

[PR #440](https://github.com/terminaloutcomes/bleat/pull/440) delivers the two
bounded build repairs; full source review found no actionable findings. Its exact reviewed head `cdd7a38` passed all registered CI checks and merged
through normal auto-merge as `c71298e` on 21 October at 16:30 UTC. Artifact
verification established 608 host passes plus the one named unsigned-Keychain
skip, 629 iOS passes with zero skips/expected failures/runtime warnings, and
332 Rust passes across 22 nonempty targets; 26 targets were compile-only.
All five guarded fixture cases were present and passed in CI. Existing
coverage-threshold, Xcode destination/AppIntents metadata and uploader deprecation
warnings remain retained; they are not runtime test warnings. The failed-gate receipt remains `.build/i362-release-scan-fixed-verified.json`;
the passing complete gate is `.build/i362-release-scan-explicit-version-verified.json`.
The [native-authentication revalidation](secret-leakage.md#revalidation-2026-10-21-362)
retains the complete exact identity list and gate scope.
The gate's `4542700` differs from reviewed #440 only in evidence documentation;
all build/test inputs are unchanged. No deployment or physical-device validation
is inferred.

## Configuration and device groups

| Gate | Existing evidence / remaining prerequisite |
| --- | --- |
| G1 Configured accessibility/layout/VoiceOver | Standard UI is distinct from configured matrices. Retain the partial Bold Text/Increase Contrast result and unresolved observation below. Dynamic Type, VoiceOver, landscape and spoken/gesture manual evidence must retain their actual configurations. |
| G2 Opt-in performance/large library | App 10k and local cache workloads have revision-specific evidence. The opt-in 250k statistics benchmark has historical Release measurements in [Statistics Validation](../statistics-validation.md); default host/CI does not execute it. Disposable-server large-library acceptance still needs its owned dataset and exact selection. |
| G3 Signed macOS app/authentication | Explicitly deferred by the maintainer; host tests and compilation do not substitute for app/authentication/relaunch execution. Five preserved implementation groups remain in #369. |
| G4 Release-secret/archive | Completed at clean `4542700` using the documented checked-in marketing version and fresh UTC build: seven Python/nine native passes, inspected archive, nine surfaces / 667 files / 1,677,234,199 bytes, zero prohibited findings and two expected server redactions. Cleanup verified. Original failures retained; no source metadata bump, validation bypass or deployment. |
| G5 Release screenshots | Release fixture/configuration prerequisite and screenshot review; a normal UI pass is not screenshot acceptance. |
| G6 Physical CarPlay | Applicable connected hardware and scenario observations required. #377's artwork acceptance does not establish this gate. |
| G7 Physical audio routes | Applicable Bluetooth/AirPlay/headphone/interruption hardware and scenario observations required. Simulator playback does not establish routing. |
| G8 Physical background transfer | Physical OS/background/termination scenarios and actual transfer outcomes required. Simulator recovery does not establish execution in the background. |

### Preserved iPad observation

At source `58223214`, the accessibility matrix recorded eight passes and one
failure: Increase Contrast playback reported `player.mini.open` width 0.0
against the unchanged 43.5-point minimum. Xcode separately timed out after
600 seconds collecting failure diagnostics. iPad Bold Text did not execute.
One matching focused run passed; no failure-time geometry snapshot established
cause. Relevant app/test code matched main; unpublished exhaustion diagnostics
were not reached. The exact original result, recording, focused pass and restored
Simulator settings are retained under #375.

Disposition: **observed failure, not reproduced once, cause unresolved**.
Do not call it fixed or infer a persistent layout defect. No blind retry,
threshold relaxation or speculative app patch is part of this reconciliation.

## Optional/unproven source concerns

Owner: Bleat maintainers under #369 and the corresponding child issue. Preserve
existing unpublished work and original reviews; require a reachable trigger and
observed impact before turning a source concern into a code fix.

| Stable group | Count | Disposition |
| --- | --- | --- |
| UI-1–UI-7 | 7 | Caller/exhaustion diagnostics across six suites and download-status wrappers; preserved unpublished; no demonstrated product failure caused by these paths. |
| HOST deadlines plus HOST-2–HOST-4 | 4 | Additional execution deadlines and nested bearer/migration/cache ownership concerns. #439 closes the demonstrated driver-SIGTERM boundary only; do not re-open that completed fix as a deadline redesign. |
| REL-1–REL-5 | 5 | Broader release broker/Simulator/server/telemetry retirement and evidence preservation; no current observed failure established. |
| APP-CURRENT-01–APP-CURRENT-05 | 5 | Consumption/admission/cleanup/player-diagnostic source candidates from the earlier audit. No reproduced defect is inferred from sleeps, yields or a possible failure path alone. |
| RUST-1 | 1 | Broader HTTP-fixture retirement concern; not a demonstrated current failure. |

The five MAC groups are deferred separately, not included in these 22 concerns.
No optional source concern is a required per-slice merge gate. Missing records,
source review and unrun configurations remain explicit rather than being
papered over with generic keep labels or an unsupported epic-complete claim.
