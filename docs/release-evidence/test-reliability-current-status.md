# Test reliability: current delivery and acceptance

Issue [#362](https://github.com/terminaloutcomes/bleat/issues/362) remains open.
This 25 October 2026 reconciliation describes delivery through merged
[#473](https://github.com/terminaloutcomes/bleat/pull/473), main
`9808cb1e5f9063c3c20526bbc86626c3a6448006`. It supersedes earlier current-status
claims that the macOS work, child acceptance, or the fixed review cohort remain
undelivered. The [#476 reassessment](#sign-offs-revisited-after-476-26-october-2026)
qualifies affected test sign-offs with unmerged candidate evidence. Dated receipts and failed attempts below keep their tested-source
boundaries. An unchecked historical bullet is not itself an unfixed bug.

## Delivered implementation and current remainder

- The fixed historical cohort has **312 completed scoped reviews: 241 core and
  71 app, zero pending identities**. Merged
  [#450](https://github.com/terminaloutcomes/bleat/pull/450) repaired all **85**
  omissions in its bounded audit/index list. Neither count certifies a new
  repository-wide audit or a fresh execution of every configuration.
- **MAC-1–MAC-5 are delivered** in
  [#466](https://github.com/terminaloutcomes/bleat/pull/466): dedicated test
  configuration/identity, exact artifact preflight, inert admission, owned model
  state, and isolated credential fixtures. See [the isolation receipt](macos-test-isolation.md).
- [#467](https://github.com/terminaloutcomes/bleat/pull/467) delivered the
  cryptography, zip and Tokio advisory remediation and both-lockfile audit;
  [#468](https://github.com/terminaloutcomes/bleat/pull/468) delivered the CarPlay
  selection fixtures and audio-session lifecycle fixes. Historical advisory and
  failed-run limits remain preserved, with current remediation recorded separately.
- [#469](https://github.com/terminaloutcomes/bleat/pull/469) delivered foreign-store
  preservation and visible native Diagnostics;
  [#473](https://github.com/terminaloutcomes/bleat/pull/473) delivered the scoped
  account-editor AutoFill mitigation. Its final native lane passed **564/564**,
  with zero failures, skips, expected failures or runtime warnings, and exact-head
  CI/review passed. These are source-specific results, not new tests run by this
  documentation update.
- Signed macOS acceptance is **partially complete**: provisioned core host
  **609/609** and the separate provisioned app-host Keychain contract **1/1**
  passed. Native login, historical normal termination/relaunch, candidate account
  restoration without a password prompt, and the user's original Save flow are
  credited in [#25](https://github.com/terminaloutcomes/bleat/issues/25).
  Only its broad credential/privacy evidence and completion of
  `APP-MAC-AUTH-001` remain unchecked; accepted login/relaunch is not reopened.

The remaining physical checklist is **11 grouped items**, not 11 bugs: **K1–K3**
keyboard, **E1** energy, **C1–C5** CarPlay Search/input, and **R1–R2** audio routes.
Execution is assigned to the separate physical-device work; this update performs
none. Use the [accepted checklist](https://github.com/terminaloutcomes/bleat/issues/369#issuecomment-6341177157)
for exact completion criteria and retain its accepted waivers. The old comment's
macOS deferral and runtime-availability snapshot are historical, superseded by the
macOS evidence above; do not use them as current prerequisites.

Deferred [#457](https://github.com/terminaloutcomes/bleat/pull/457) retest/integration
and the inconclusive iPad presentation observation remain separate. Preserve that
branch and installed retest build. Closed #333 and #342 are not reopened by
retained manual-evidence limits. Original background-download #33, VoiceOver #39,
CarPlay #24/#331, AirPods-only #341, Release privacy #48/screenshots #445 and
performance #46/#446 acceptance remains credited. The notice work
[#470](https://github.com/terminaloutcomes/bleat/pull/470)/[#471](https://github.com/terminaloutcomes/bleat/issues/471)
and modal layout [#472](https://github.com/terminaloutcomes/bleat/issues/472) stay
separate from this epic reconciliation.

## Sign-offs revisited after #476 (26 October 2026)

This source review qualifies the historical keep/fixed labels below; it does
not erase the original reviews, counts or failed attempts. Main at this review
is `0ed12585dc6726fce2aca2336e99272014810f5d`. PR
[#476](https://github.com/terminaloutcomes/bleat/pull/476) is **unmerged** at
`851d51a14a2675c6dc97a60c43b9ba70cc4ea653`; its corrections are candidate
implementation, not delivered main behavior. The audit JSON rows link here as
reassessments while preserving their historical decisions and source extracts.

| Affected sign-off / source | Reassessment of main and candidate correction |
| --- | --- |
| `other.json`: `testDiagnosticTelemetryConsentLivesInSystemSettings`, `testSystemSettingsLinkAvailableWhenStartupUnavailable`; `Tests/BleatUITests/BleatUITests.swift` | Historical keep does not establish native selector correctness on iOS 27: main queries Buttons for the SwiftUI Settings Link. Candidate uses the identifier across native element types, retaining the actual Settings journey and interaction checks. Fix pending merge; no platform-wide selector guarantee. |
| `other.json`: `testViewOnServerOpensSystemBrowserWithoutEditPermission`; same UI source | Historical keep missed separately sampled foreground states. Candidate bounds Safari foreground and Bleat departure in one predicate; the dispatch test does not prove remote page availability. Fix pending merge. |
| `other.json`: `testMiniPlayerRestoresWhenStopIsSuperseded`; same UI source; `App/UITestAppService.swift` and `App/RootView.swift` | Historical fixed label covers earlier label waits, not valid replacement admission or gate lifetime. Main's idle retained player is incorrectly reusable and delayed-sync release rearms. Candidate observes replacement generation before releasing serialized sync, then verifies paused restoration and resume; its one-shot gate retains the first waiter and later waits pass. Fix pending merge. |
| `app.json`: `AppModelTests/testLastPlayingFailureSurvivesRelaunchAndRetriesLocalCheckpoint`; `Tests/BleatAppTests/AppModelTests.swift` | Historical keep/rule 3 overstates the stable boundary. Retry already starts native playback before returning; Pause afterward cannot undo advancing time. Candidate observes actual completed seek before Play through the existing recorder, retains `0.5 ± 0.15`, verifies native Play/Pause and persisted failure/Stop cleanup. Fix pending merge. |
| `app.json`: `AppModelTests/testPlaybackStartReusesMatchingActivePlayerAndResumes`, `AppModelTests/testStopCompletionDoesNotRetireNewerSelection`; `App/PlaybackModel.swift` | Keep these bounded scenarios: matching paused reuse and replacement across the diagnostic suspension. They do not establish idle reuse eligibility or ownership after every later await. Main checks generation after diagnostics but not after the later statistics finish. Candidate excludes idle reuse, rechecks ownership after statistics, and adds two separately held progress/statistics replacement regressions checking native player identity, exact old-session closure and resumed reuse. No new regression is credited to main. |

Review inspected the
[pinned candidate diff](https://github.com/terminaloutcomes/bleat/compare/0ed12585dc6726fce2aca2336e99272014810f5d...851d51a14a2675c6dc97a60c43b9ba70cc4ea653)
and [source-grounded receipt](https://github.com/terminaloutcomes/bleat/blob/851d51a14a2675c6dc97a60c43b9ba70cc4ea653/docs/release-evidence/broader-ui-regressions.md),
including test bodies, fixture state and Stop/reuse continuations. Statistics
completion flushes local listening accounting; the required correction is stale
continuation ownership, not removing accounting or weakening serialization.
The earlier diagnostic-boundary Stop evidence remains valid within that scope.

The [authoritative execution receipt](https://github.com/terminaloutcomes/bleat/pull/476#issuecomment-6397997492)
records four unchanged-main UI failures, followed by clean candidate repetitions
(eight UI executions), 15 focused regressions, and a completed production
aggregate: signed host 609 passed, app 664 passed, broad UI 119 passed with seven
existing approved opt-in skips, core live 13 passed with eight configuration
skips, and both app-live journeys passed. The final checkpoint-only correction
has three clean repetitions, all 664 owning app tests and exact-final-head CI;
unchanged host/UI/live inputs retain their earlier aggregate evidence. These
are reported #476 results, **not executions by this documentation change**.
The failed signing preflight and earlier checkpoint CI failure remain in that
receipt. Neither inventory totals nor the historical 312-review cohort certifies
execution or full semantic compliance. #475, #470 and deferred #457 are unchanged;
physical-device acceptance remains separate.

## Revision and counting

Historical application/test execution checkpoint: `f59a7629cd3156ca8086690f2bbc4a4169e01608`
(merged #442). Its tree matches reviewed/tested
`fd40daca480a0ef1be6aeb817c95a361c8bfaf7f`. #431's SwiftProtobuf update,
#440/#441's Release repairs/receipt, and #442's original #375 caller diagnostics
are landed. [Exact-head Validate Bleat39700230098](https://github.com/terminaloutcomes/bleat/actions/runs/39700230098)
verified 608 host passes plus the expected unsigned-Keychain skip, 629 iOS
passes with zero skips/runtime warnings, and 332 Rust passes. Current results
and earlier unsuccessful attempts remain revision-specific; none is erased or
relabeled as a new execution by this documentation refresh.

Count different units separately:

| Category | Count / current disposition |
| --- | --- |
| Proven unresolved implementation bugs | 0 in this completed review/remediation cohort. Separate #471/#472 follow-ups remain; this is not an app-wide bug-free claim. |
| Retained inconclusive observation | The transient frame-query defect was corrected in #444. The later iPad tap/presentation observation remains inconclusive, with no confirmed app bug or speculative fix. See the preserved receipts below. |
| Deferred retest/integration | #457 awaits its deferred installed-build retest/integration. This is separate from the inconclusive presentation observation and from delivered macOS implementation. |
| Known missing structured audit/index entries | 0 remaining in the bounded 85-entry list: merged #450 added 25 app, 6 UI and 54 Rust primary records plus 85 navigation rows at source `82e3fdf`. Source concerns and historical execution limits remain explicit. The separate 312-review cohort is also complete in its identity ledger; neither count certifies global coverage. |
| Existing-record review queue | The fixed historical 241 core + 71 app identities now have **312 completed scoped reviews and zero pending identities** in the [identity ledger](../../TestSupport/TestAudit/review-queue-reconciliation.json). The final app batch records 58 bounded KEEP conclusions and 13 corrected test gaps. This finite review completion is separate from configuration-specific execution, whole native drainage, physical acceptance and the overall epic. Historical findings/receipts and per-record limits remain preserved. |
| Delivered macOS implementation groups | All five MAC-1–MAC-5 groups merged in #466. Signed evidence is credited separately; only the broad #25 privacy criterion and traceability completion remain open. |
| Optional/unproven source concerns | 20 residual groups after #442 delivered UI-1/UI-7 and the required caller attribution. These are backlogged concerns, not confirmed defects or an implementation queue. |
| Configuration/device acceptance | G4 and G5 are complete. Four groups remain active (G1/G2/G6/G7); G8's original background-download acceptance was already user-accepted under closed #33, with explicit evidence waivers. G3 has accepted signed evidence with only broad credential/privacy verification and traceability completion remaining. These are validation groups, not code-defect counts. |

The previous 19-PR backlog (#417–#429, #432–#437) is merged, as are #438–#442.
Do not report those PRs, the old 140 follow-up labels, or navigation line drift as
remaining code work. The fixed scoped record review is complete. This checkpoint does not certify
repository-wide compliance or complete the remaining configuration acceptance.

## What the merged #450 85-entry repair establishes

This is a known documentation-coverage list, not 85 missing tests, 85 failing
tests, or 85 demonstrated implementation fixes. The preserved source-declaration
comparison at `58223214` found 87 `(source path, function name)` pairs absent
from `TestSupport/TestAudit/source-index.json`'s `declarations` list. Rechecking
that exact list at `f59a762` finds 85 absent: 25 app, 6 UI and 54 Rust. All 85
functions still exist uniquely in source. #442 added the two existing
download-status entries, so the known list fell from 87 to 85. This bounded
recheck is not a new repository-wide discovery or semantic audit.

Before this repair, those 85 pairs also lacked primary per-test rows in
`app.json`'s `methods` or `other.json`'s `tests`, as applicable. They are not merely
rows with a stale line number. Some have review or execution evidence elsewhere:
for example, the cover-save/artwork case is mentioned in another app-review
section. Missing a structured row does not establish that a test was never run
or reviewed; that existing evidence must be credited rather than recreated.

Concrete existing tests in the known list include:

- [Cold-start cover revalidation](https://github.com/terminaloutcomes/bleat/blob/f59a7629cd3156ca8086690f2bbc4a4169e01608/Tests/BleatAppTests/CoverCacheLifecycleTests.swift#L44):
  `testColdStartRevalidatesBeforeReturningAndPersistsUnchangedTimestampReplacement`.
- [Typed sign-in failure UI](https://github.com/terminaloutcomes/bleat/blob/f59a7629cd3156ca8086690f2bbc4a4169e01608/Tests/BleatUITests/BleatUITests.swift#L1484):
  `testTypedHomeFailureWithoutDownloads`.
- [Exact download-runner results](https://github.com/terminaloutcomes/bleat/blob/f59a7629cd3156ca8086690f2bbc4a4169e01608/scripts/tests/fixed_runner_verification.rs#L87):
  `download_runner_accepts_exact_results_without_literal_tab_matching`.

The index stores location/name/language for navigation and inventory comparison;
the audit row records purpose, setup, action/postcondition, waits/budgets,
cleanup, compiler/skip conditions, applicable rules and a reasoned keep/fix/
follow-up disposition. Filling the gap means inspecting the relevant body and
helpers, linking valid existing review/execution, and adding or linking an honest
record plus index row. A template or name match cannot certify the nine rules;
the original #443 status refresh performed no 85-row repair or semantic review. The [current reconciliation](test-reliability-audit.md#known-85-entry-reconciliation-369) now supplies source-specific records after inspecting those bodies and relevant helpers; it does not execute the underlying tests or certify complete compliance.

The original [#362 scope](https://github.com/terminaloutcomes/bleat/issues/362)
requested a per-test audit across targets. The JSON/index format was the chosen
tracking mechanism, not 85 additional product requirements. Missing rows do not
stop the tests building/running or invalidate independently verified passes.
They limit a claim of complete per-test audit reconciliation from this ledger.
The separate historical 71-app/241-core cohorts concern existing records; the
current pending partition is in the identity ledger above. This review queue is not the same omission list and must not be added to it as a bug
count. Stale prose references are a third, separate tracking problem.

## Child acceptance reconciliation

All seven direct delivery children #370–#376 and grandchildren #378, #379,
#382 and #384 are closed. #369 remains open for acceptance reconciliation under
#362. Historical per-slice open-status statements in the linked receipts do not
reopen those closed children or the completed 312-review cohort.

| Issue | Landed source/evidence | Current disposition |
| --- | --- | --- |
| #369 | #417 adds the five host and nine build-helper records, moved-path history and parity checker. #418 and #437 reconcile reviewed command-owner records. The eight checker regressions and preservation checks are retained in [the audit](test-reliability-audit.md#missing-audit-entry-repair-369). | The old 14-record repair, merged #450 85-record/index repair and 312 scoped reviews are delivered. Remaining privacy/device acceptance and tracking stay explicit; no new semantic-review queue or repository-wide compliance claim is inferred. |
| #370 | The small `build-scripts` package, caller-environment/dependency/sandbox regressions and workflow consumers are present. #418 bounds the three build-helper regression commands. Actual Xcode build-for-testing without compiler/SDK overrides is retained in [build-helper evidence](test-reliability-audit.md#build-helper-dependency-isolation-2026-10-16); current app CI continues to build using it. | Closed after reconciliation: all four bounded extraction acceptance items have implementation/execution evidence. Later independent subprocess hardening is a separate optional concern. |
| #371 | Exact native identities, multiplicities and skip policy are verified by the current runners. #419/#425/#427–#429 own runner/report commands, #420 rejects malformed children, #426 supplies legacy-summary audit records, #432 preserves repository-root results, #435 preserves typed paid-build failures, and #439 handles driver cancellation. See [runner evidence](test-runner-verification.md). | Closed after reconciliation: all four selection/parser/execution acceptance items are delivered. Retained JSON/schema replay is distinct from fresh native execution. Further aggregate/nested-owner hardening is not a demonstrated selection defect. |
| #372 | Account/transport/telemetry/callback/observer fixes through #434 are merged. Specific original semantics, focused repetitions and signed owners are retained in [core follow-ups](test-reliability-core-followups.md), #437 and #439. | Closed after scoped reconciliation. The 241-core cohort is complete; its bounded source/cleanup limits remain preserved without implying global framework drainage. |
| #373 | Controlled-clock progress reset, foreground/background expiry and callback-drain tests remain; production defaults use `ContinuousClock`. Cache tests retain parent-supervised startup/cancellation/timeout/success boundaries. | Closed after reconciliation: all four bounded clock/cache criteria have evidence: original focused repetitions at `39fd45a`, clock-specific native selections retained in #428, plus all named clock/drain and five cache cases in the retained 609-pass signed report at `e9835ae`. This does not establish live CloudKit/device behavior. |
| #374 | #386 and later app fixes, #393, #438 and the current 627-test app owner cover changed iOS semantics. #438's controlled ordering witness reproduced the actual premature completion assertion; [exact-head CI39581982755](https://github.com/terminaloutcomes/bleat/actions/runs/39581982755) verified 629 iOS outcomes. | Closed after scoped reconciliation. The 71-app cohort and MAC-1–MAC-5 delivery are complete; retained manual evidence and the inconclusive iPad observation remain separate. |
| #375 | #436 supplies gate cancellation/repeated release/reuse; #437 fixes the edit-download fixture menu. #442 delivers nine helper caller/exhaustion diagnostics and the two existing download-status audit/index rows, preserving loops, waits and semantic assertions. | Closed: all four original criteria are satisfied. Four affected journeys passed individually twice; the implementing owner passed 627 app and 119 UI cases with six named opt-in skips. Exact-head CI and normal merge are verified. The larger gesture-loop patch stays separate; the iPad observation is not declared fixed. |
| #376 | Already closed: #380/#381 cleanup, two Audiobookshelf profiles, two app-live journeys and specific artwork phone acceptance have revision-specific evidence. | Preserve its closed state. The remaining configuration/device gates below are not certified by that closure. |

The signed evidence above is 609 distinct identities (604 core and five
transcription), zero failures/skips, executed at `e9835ae`. Its 215 tracked host
inputs remained identical through #439 and `adc7ac4`. At the historical #440
checkpoint `c71298e`, 214 remained identical; the paid-build validator changed
its iOS branch while retaining its macOS branch. #431 later changed the package
manifest/resolutions. No current all-input equivalence claim is made here. The
signed result remains execution at `e9835ae`, not a new signed run of this
checkpoint; current unsigned CI retains its explicit Keychain exclusion. #439's exact-head
[CI39585563313](https://github.com/terminaloutcomes/bleat/actions/runs/39585563313)
verified 608 host passes plus the named unsigned Keychain skip, 629 iOS passes
with zero failures/skips/expected failures/runtime warnings, and 329 Rust passes
across 22 nonempty targets. The 26 other Cargo targets were compile-only.

## Historical local acceptance receipts

Retained owning Simulator/UI evidence at the earlier checkpoint: **passed native owner and verified bundles**,
command `BLEAT_SKIP_HOST=1 mise run test:local`, at clean `65a889c8d978a4701ce0b40fb89f5306b7a2b2c3`.
All 627 app identities passed; UI selected 125 identities: 119 passed and six
explicitly allowed opt-in skips. All ten original fixture UI and four app
lifecycle identities passed. There were no failures, expected failures or runtime
warnings. The interrupted outer execution wrapper has no final exit receipt;
the unchanged original native core owner continued without restart and its
exit 0 was observed through the host process-exit mechanism. Both original
bundles independently passed canonical discovery/result verification.
The earlier successful `adc7ac4` gate remains historical evidence, not a rerun.

The six owning-lane skips remain external-URL confirmation, two live journeys,
Release screenshots and Release-secret refresh/logout. Separately executing some
of those configurations later does not change this run's skip count. Dedicated
accessibility cases were excluded. Four affected download-status/edit-progress
cases also passed individually twice at `65a889c`; only audit/evidence metadata
and main ancestry changed before reviewed #442 head `fd40daca`.
See [#375's delivered criteria and receipts](https://github.com/terminaloutcomes/bleat/issues/375).

### Historical Release repair attempts (21 October 2026)

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

G4 is now freshly complete at clean `fd40daca`: seven scanner regressions and
all nine exact native cases passed, the normal unsigned Release archive was
inspected (version `2026.10.14`, build `20261022.0143.03`), and all nine surfaces
passed final scanning: 667 files / 1,684,100,832 bytes, zero prohibited findings
and two expected server-artifact redactions. Owned runtime resources were
verified retired. The [approved public receipt](https://github.com/terminaloutcomes/bleat/issues/369)
retains the earlier signing, Homebrew LLVM/Z3 and disk-guard interruptions.
The successful run selected an already-installed consistent rustup toolchain
through caller PATH only; no package installation, persistent environment,
signing/security change or release metadata bump was made. The earlier
`4542700` acceptance above remains historical, not overwritten.

G3 now credits the signed evidence in [#25](https://github.com/terminaloutcomes/bleat/issues/25):
[historical login and normal termination/relaunch](https://github.com/terminaloutcomes/bleat/issues/25#issuecomment-5475241195),
[609-pass provisioned core host](https://github.com/terminaloutcomes/bleat/issues/25#issuecomment-6392332809),
[separate 1/1 provisioned app-host contract](https://github.com/terminaloutcomes/bleat/issues/25#issuecomment-6392383064),
[candidate account restoration](https://github.com/terminaloutcomes/bleat/issues/25#issuecomment-6393002506),
and [user-confirmed Save](https://github.com/terminaloutcomes/bleat/issues/25#issuecomment-6393668067).
Broad credential/privacy evidence and `APP-MAC-AUTH-001` completion remain open.
The dated G4 receipt above and failed macOS attempts in linked receipts remain
unchanged historical evidence; compilation alone is not runtime acceptance.

Four groups remain active after G5's screenshot matrix and reconciliation of the already accepted #33/G8 evidence. The [accepted remaining checklist](https://github.com/terminaloutcomes/bleat/issues/369#issuecomment-6341177157) preserves the physical-evidence boundaries and waivers; this record repair adds no physical validation. Available tools are not
passing evidence; unrun configurations are not reported as blocked merely
because they are unrun. The earlier 22 October no-build preflight established
local prerequisites. Subsequent native screenshot execution and the lossless
export correction are recorded in the G5 receipt below; they do not close other
acceptance groups.

| Group | Already evidenced | Executable here / remaining prerequisite |
| --- | --- | --- |
| G1 Accessibility/layout/VoiceOver | Partial Bold Text/Increase Contrast matrix and historical Dynamic Type/landscape/VoiceOver selections. One configured iPhone primary journey passed at `fd40daca`; one diagnostic iPad playback case passed at private `137fae4`. The single-frame width-query correction merged in #444; the later Increase Contrast tap/presentation observation remains inconclusive (diagnostics below). | K1–K3 are the three remaining keyboard acceptance items in the accepted checklist. Closed [#39](https://github.com/terminaloutcomes/bleat/issues/39) retains manual VoiceOver sign-off. Earlier matrix/probe limits below do not add new required groups. Deferred #457 retest/integration and the inconclusive iPad presentation observation stay separate. |
| G2 Opt-in performance/large library | App 10k/cache and the 250k-slice Release benchmark retain revision-specific [measurements](../statistics-validation.md); they are not new runs. The [current-stable 2.37.0 live unit](performance-baseline.md#current-stable-setup-readiness-correction-2026-10-22) now passed one exact native identity, zero skips: root/prefix each loaded and cached all 10,000 books under unchanged limits. The original setup failure and bounded correction remain separately recorded. | The selected executable live unit is complete, with independently verified owned cleanup. Historical host, AppModel, Release UI and 250k measurements retain their original sources. Physical-device energy remains separately tracked in [#95](https://github.com/terminaloutcomes/bleat/issues/95); this run cannot establish energy or broader device behavior. |
| G5 Release screenshots — complete | The [Rust migration receipt](release-screenshots-rust.md#full-matrix-and-orientation-correction) records eight exact native passes and 80 visually reviewed PNGs across both devices, appearances and orientations. Original files are retained. The observed EXIF/XMP orientation defect is corrected losslessly with separate capture/export provenance. | Default matrix, file/manifest validation and independently verified owned cleanup are evidenced. Optional video was not run. This does not substitute for G1 manual accessibility or physical-device groups. |
| G6 Physical CarPlay | Original [#24](https://github.com/terminaloutcomes/bleat/issues/24) and [#331](https://github.com/terminaloutcomes/bleat/issues/331) head-unit acceptance remains credited, alongside #377's specific artwork phone evidence. | Only the later C1–C5 native Search/input gaps in the accepted checklist remain; original acceptance is not reopened. This record repair performed no head-unit session. |
| G7 Physical audio routes | [#341](https://github.com/terminaloutcomes/bleat/issues/341) retains the user-reported 12 October Play → Pause → force-quit → AirPods Play pass. Simulator readiness/rate/position evidence remains separate. | R1–R2 cross-app handoff/reconnect/interruption checks remain in the accepted checklist. Optional tracing is not a prerequisite for crediting the accepted pass. This repair performed no route session. |
| G8 Physical background transfer — accepted original scope | The original four background-download scenarios were user-accepted in closed [#33](https://github.com/terminaloutcomes/bleat/issues/33); explicit evidence waivers remain in the [accepted checklist](https://github.com/terminaloutcomes/bleat/issues/369#issuecomment-6341177157). | Preserve that acceptance. This audit-record repair performed no physical session and does not upgrade Simulator results to physical evidence or broaden the accepted scenarios. |

### Latest bounded iPad acceptance unit

The three previously unexecuted iPad Bold Text cases ran at `dd63da4`: login
and primary journeys passed; playback reported a zero-width `player.mini.open`.
One instrumented reproduction preserved the failure and captured valid/null/valid
successive frames (852 × 44, `CGRect.null`, 852 × 44), one query match, and a wide
visible control. The underlying reason for the transient null accessibility
frame remains unknown; this is not evidence of a visibly collapsed app layout.

The minimum-target helper now uses one sampled rectangle for bounds and both
unchanged 43.5-point dimensions, without waits or retries. At code head
`72226c1`, all three Bold Text cases passed in the original order, with zero
skips/runtime warnings and all 12 named screenshots retained and reviewed.
The additional Increase Contrast playback selection passed mini-player geometry
but failed later waiting for `player.screen` after a correct-centre tap. Its tree
remained on Book Detail. That later failure is retained without retry; full G1
acceptance remains open. See [traceability](../requirements-traceability.md#22-october-geometry-query-correction-and-remaining-ipad-failure).

### Preserved iPad observation

At source `58223214`, the accessibility matrix recorded eight passes and one
failure: Increase Contrast playback reported `player.mini.open` width 0.0
against the unchanged 43.5-point minimum. Xcode separately timed out after
600 seconds collecting failure diagnostics. iPad Bold Text did not execute.
One matching focused run passed; no failure-time geometry snapshot established
cause. Relevant app/test code matched main; unpublished exhaustion diagnostics
were not reached. The exact original result, recording, focused pass and restored
Simulator settings are retained under #375.

A later single diagnostic run at private `137fae4971a8ed98eb4b899023b6894d8d600c9b`
matched the iPad/runtime/Increase Contrast configuration. It passed its exact
identity with no skips/failures/runtime warnings and captured the frame used by
the width assertion: **852 × 44 points**, equal to the immediate bounds and
subsequent reads; one accessibility node was present and hittable, and the tree
and screenshot agreed. The three relevant app files match the original failure
source. Extra diagnostic observations can perturb subsequent timing, so this is
a negative reproduction, not an explanation of the historical zero frame.
The private probe/attachments are preserved; the published source was restored,
no workaround shipped, and no retry loop was used.

Disposition: **original observed failure, cause still unresolved; no fix claimed**.
Do not call it fixed or infer a persistent layout defect. No blind retry,
threshold relaxation or speculative app patch is part of this reconciliation.

## Optional/unproven source concerns

Owner: Bleat maintainers under #369 and the corresponding child issue. Preserve
existing unpublished work and original reviews; require a reachable trigger and
observed impact before turning a source concern into a code fix.

| Stable group | Count | Disposition |
| --- | --- | --- |
| UI-2–UI-6 residual loop proposals | 5 | #442 delivered the required caller attribution and the UI-1 live-exhaustion/UI-7 wrapper goals. Only the larger proposed gesture-loop changes remain preserved unpublished; unchanged loops are not demonstrated product defects. |
| HOST deadlines plus HOST-2–HOST-4 | 4 | Additional execution deadlines and nested bearer/migration/cache ownership concerns. #439 closes the demonstrated driver-SIGTERM boundary only; do not re-open that completed fix as a deadline redesign. |
| REL-1–REL-5 | 5 | Broader release broker/Simulator/server/telemetry retirement and evidence preservation; no current observed failure established. |
| APP-CURRENT-01–APP-CURRENT-05 | 5 | Consumption/admission/cleanup/player-diagnostic source candidates from the earlier audit. No reproduced defect is inferred from sleeps, yields or a possible failure path alone. |
| RUST-1 | 1 | Broader HTTP-fixture retirement concern; not a demonstrated current failure. |

The five MAC implementation groups are delivered in #466, separately from these
20 residual concerns. The remaining G3 privacy evidence is acceptance work, not
a deferred macOS implementation queue.
No optional source concern is a required per-slice merge gate. Missing records,
source review and unrun configurations remain explicit rather than being
papered over with generic keep labels or an unsupported epic-complete claim.
