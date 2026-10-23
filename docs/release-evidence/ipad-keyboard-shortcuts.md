# iPad keyboard shortcut candidate (#40)

Status: **unmerged; native modified-key delivery is an acceptance blocker**.
This candidate does not close #40 or the keyboard/focus acceptance group in #369.
No physical keyboard pass is claimed.

## Scope

The candidate adds iPad-only Command-P (play/pause), Command-Left/Right Arrow
(configured skip intervals), Command-Minus/Plus (featured speed steps), and
Command-F (Search, retained query and text focus). Actions reuse the existing
playback command handlers and scene navigation coordinator. A cold restored
selection can toggle through its existing resume handler; unprepared seek/rate
commands remain unavailable.

Admission checks the signed-in account phase, actual key window/foreground
scene, current text responder and presented controller ancestry again when an
action is delivered. Other sheets/confirmations block commands; the player is
permitted explicitly through its passive scene anchor. Search focus waits for
player dismissal. Bare Space/arrows and native editing priority are preserved.
There is no custom first-responder takeover, presentation delegate replacement,
arbitrary sleep, or production diagnostic/readiness overlay.

## Retained evidence (2026-10-23)

Environment: Xcode 27.1 (27A9275), iPad Pro 13-inch (M5) Simulator,
iOS 26.5 (23F77). Only this iOS runtime is installed; no runtime download,
new worktree, global toolchain selection or personal-device operation occurred.
The version difference is context, not an established failure cause.

| Check | Observed outcome and limit |
| --- | --- |
| Initial deterministic policy/navigation/cold-resume tests | Seven exact app-test identities passed; no failures/skips/expected failures/runtime warnings. Final owning execution is recorded below. |
| Hosted production-scope registration and guarded Search | `testHostedScopeExposesPublicShortcutRegistrationAndGuardedSearch` passed in `ipad-keyboard-held-modifier-and-registration.xcresult`. UIKit exposes the eligible Command-F binding and an NSObject action target that responds to its selector. The real scene guard allows Search, retains the query, clears the search path and increments the focus-request counter exactly once. No selector or key event is invoked. This proves registration/admission, not hardware delivery. |
| Original registration probe | First compile failed before tests because the SDK imports the command selector as optional. The next execution incorrectly expected disabled media commands in public metadata and assumed targets are UIResponder objects; it also reported already-removed fixture storage as cleanup failure. These receipts are retained. The corrected probe checks the eligible Search binding, public NSObject target capability and checked owned-resource absence. No delivery assertion was relaxed. |
| Native modified-key calibration, feature enabled | In a genuinely focused native Search field, public XCTest Command-A followed by plain `x` produced `testx`, rather than `x`. Plain key delivery worked; the standard selection shortcut did not. |
| Same calibration, all new keyboard UI wiring removed | Identical focused-field `testx` failure in `ipad-keyboard-native-modifier-baseline.xcresult`. This excludes the new shortcut wiring as the cause of this calibration failure; it does not prove the feature works. |
| Documented held-modifier XCTest alternative | Same strict calibration failed in the combined registration result above. That bundle is **one passed identity and one failed identity**, not a green run. No further modifier-injection attempts are planned on this setup. |
| Strict native shortcut journeys | Transport/rate, fresh Search, retained-query/editing and bookmark-modal journeys retain their original failed attempts. The final candidate has no successful modified-key end-to-end acceptance. Assertions remain strict; failures are not converted to expected failures or accepted passes. |
| Mini-player setup comparisons | The existing swipe regression passed with all new UI wiring removed, including two fixed baseline iterations. Early wiring comparisons failed before keys; a zero-size/noninteractive anchor run passed that existing regression. This does not resolve the separate historical intermittent iPad tap observation in #374. |

Temporary boolean logging, visible-button comparisons and readiness markers were
removed. One diagnostic build was stopped when its preparatory edit failed; it
executed no tests and is retained as interrupted, not a test result. Source,
result bundles, activity/hierarchy attachments and execution receipts remain in
the reused task build directory. Sanitized summaries are retained in the task's
`ipad-keyboard-evidence` directory; raw setup/configuration traces are not published.

## Owning validation

The supported `scripts/xctest.sh -t BleatAppTests -d id=<owned-iPad> -r <result>`
run completed with **649 unique exact identities passed**, including all eight
new app cases: zero failures, skips, expected failures or runtime warnings.
The runner and disk guard both exited 0. All 426 recorded build/test input
fingerprints remained unchanged through execution. The result is
`ipad-keyboard-owner.xcresult`; it does not include a native modified-key pass.
Strict Swift formatting, Rust formatting and diff checks passed. The single
owning run used 15.33 GiB free before and 14.79 GiB afterward, above the 3 GiB
active floor. Existing SDK/build-number diagnostics remain in the raw log;
zero runtime warnings is not a claim that build tools emitted no diagnostics.

## Independent review and delivery boundary

Independent review found no additional demonstrated production-source defect or
owned-resource cleanup issue. Its readiness decision is to **preserve this
candidate unmerged** until a modified-key path succeeds on a working input
setup. Public registration and direct guarded action coverage cannot replace
that boundary. No PR, merge, auto-merge or deployment is represented as completed.

The five new UI cases require an iPad destination. Their phone-only skips are
explicitly enumerated by the ordinary UI runner; that disposition cannot count
as iPad acceptance. Configured iPad delivery assertions remain strict.

## Smallest remaining acceptance procedure

Use an agreed test iPad with a real keyboard, or a working Simulator input setup:

1. Calibrate a focused native Search field: type `test`, press Command-A and
   then `x`; require exactly `x`.
2. From browsing, Command-F must reveal Search and focus it without a tap;
   typing must update the retained query. Repeat from the player and require
   dismissal followed by focus.
3. With the synthetic silent playback fixture, verify Command-P, both configured
   skips while paused, and both speed directions as separate observations.
4. Verify native caret movement and text entry consume editing shortcuts without
   playback changes. A bookmark editor must block transport/Search, and commands
   must recover after cancellation. Check recovery after a root text-entry sheet
   as well; that path remains unverified.

Record candidate commit/build, iPad model/OS, keyboard/input method and exact
observed states. No device installation, playback interruption or settings
change has been performed on the user's devices. Retain original failures even
if a different supported input setup passes.

After this delivery blocker, a separate finite #372 bookkeeping slice can
clarify the current dispositions of two already-delivered HTTPTransport
findings (bounded endpoint snapshots and the OpenID cookie fixture). Those are
not two new bugs and are not deductions from the distinct 241-record historical
helper-context review queue. No such reconciliation is included in this patch.
