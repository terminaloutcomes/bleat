# Transcript share-action readiness

## Scope and missed boundary

The candidate changes only
`BleatUITests.testPartialTranscriptExportExplainsCoverageBeforeSharing`, its
audit reassessment and this evidence record. Production export logic is
unchanged by this correction.

The historical KEEP in `TestSupport/TestAudit/other.json` described bounded
synchronization generically. The [26 October reassessment](finished-progress-conflicts.md#native-file-picker-handoff-reassessment-26-october-2026)
corrected **Save to Files tap → intended document-picker readiness**. It did
not reassess the preceding **Export SRT → usable native share action** boundary,
which still used separate three-second existence checks. Thus a reviewed
downstream handoff was mistaken for coverage of the whole native sequence.

This missed [test reliability rules](../test-reliability.md) 1, 2, 6 and 7:
assert semantic postconditions, wait for the next action's required state,
identify real-framework prerequisites and diagnose before changing budgets.
The earlier review's broad KEEP wording was insufficient evidence for that
specific boundary. Its historical decision is preserved, with the candidate
reassessment qualified separately.

## Failure evidence and correction

The unchanged base `76492149b0c8a5fd708d2ac095f8890e201541fb` reproduced the
missing Save to Files assertion. The original hierarchy contains an empty
remote share container. Task-owned native logs place the final unsuccessful
queries around 13:06:43 UTC, before native share-client readiness at
13:06:44 UTC on 27 October. The comparison and unsuccessful attempts remain
in `.build/transcript-diagnosis.json`; this is native-service readiness
evidence, not a production exporter regression or a proven cache root cause.

The corrected test waits jointly for exactly one enabled Save to Files cell
and exactly one enabled, hittable descendant label before tapping that label.
Cell hittability is deliberately unnecessary: the system cell can extend
below the visible label. The remote container's existence is not readiness.
Private system class names/log signals are not queried by the test.

The share-action handoff uses the existing native-handoff allowance of
15 seconds, separately from the existing 15-second picker handoff. This is a
failure budget justified by retained remote-service delay, not a sleep. A
timeout attaches the screenshot, elapsed time and hierarchy, fails and returns
before attempting the dependent tap. The partial-coverage warning, SRT
confirmation, native label tap, picker navigation and intended filename remain
asserted. No retry or product fixture bypass is introduced.

Independent source review inspected the edited predicates and adjacent picker
assertions and found no defect. There is no shared readiness helper: this is
the sole Save to Files caller in the UI source. App launch/setup helpers remain
unchanged. Enforceable coverage is the actual joint predicate/guard in the
native test, focused cold/warm executions and the owning broad UI gate; review
text or a successful single repetition cannot substitute for those gates.

| Reliability rule | Scoped disposition |
| --- | --- |
| 1: semantic postconditions | Coverage warning, SRT confirmation, real native share action and intended picker filename remain asserted; actions require enabled/hittable controls. |
| 2: next-action readiness | One predicate observes unique enabled cell and unique enabled/hittable label together; the picker has its separate joint navigation/filename condition. |
| 3: playback measurement | Inapplicable: the playback fixture supplies the book, but this test makes no advancing-position, seeking or listening-duration measurement. |
| 4: async ownership | No test-owned task, callback or observer is introduced. Each predicate waiter has a finite budget and terminates before the dependent action; timeout returns. Native service lifecycle remains OS integration. |
| 5: independent setup | Each invocation launches the deterministic app scenario and partial transcription cache. Cold validation additionally resets only the task-owned Simulator; warm validation retains native service state deliberately. No personal data is a fixture. |
| 6: real integration | App transcript data is synthetic; the native share service and document picker are real Simulator integration, not a controlled fake or device evidence. |
| 7: diagnosis first | Unchanged-baseline failure, empty remote container and delayed native readiness justify the bounded state wait. No assertion removal, sleep or retry-to-green. |
| 8: failure diagnostics | Both handoffs retain elapsed time, observed accessibility hierarchy and a named screenshot; XCTest retains the failing caller. |
| 9: repetitions and owning suite | One cold and two predetermined warm executions are verified below; the broad owning gate is required separately. |

## Standalone publication scope

The standalone fix is based on `main` at
`b7c2615ddcf3caf0f94156297e2455d62e579040`. It contains no application, schema,
sync or history-migration changes. The only conflict when separating the commit
was the existing audit row's compact versus expanded JSON formatting; the
actual test correction applied unchanged.

Earlier cold/warm and owning-suite results came from a separate combined
candidate and remain historical evidence, not an exact-head claim for this
main-based PR. That original native UI bundle finalized and was independently
verified despite loss of its outer runner's exit status; no retries or forced
stops replaced its result. Those artifacts are preserved outside this PR.

Fresh main-based focused and owning-UI receipts, final source identity and CI
checks are required before this PR is merged. No full UI suite is added to CI.
The existing native picker assertions and each handoff's15-second failure
budget remain unchanged by publication.
