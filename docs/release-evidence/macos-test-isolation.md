# macOS app-hosted test isolation (#362, #369, #374)

The maintainer resumed the five previously deferred macOS groups on 24 October
2026. This work addresses the documented reachable boundary: the former
`BleatMac` scheme used the normal app bootstrap, identity, preferences and
default download location. Compilation alone did not make launching it safe.
The completed 312 historical review dispositions remain unchanged.

| Group | Implementation |
| --- | --- |
| MAC-1 | `MacTesting` configuration and `BleatMac` scheme use a dedicated host/test identity, disabled CloudKit/App Attest/CarPlay, and existing development signing without provisioning updates. Package testability is explicit. The generated project comes from `project.yml`. |
| MAC-2 | The Rust driver validates the single built `.xctestrun`, exact host executable/test bundle/target, bundle identities, runner admission marker, development signature/team and absence of production capabilities (only the exact standard Xcode unit-test loader entitlements are admitted) before enumeration. Enumeration and execution consume that same manifest. Existing exact-discovery/result verification rejects zero tests, missing identities, failures and unexpected skips. The one provisioned synchronizable-Keychain identity is explicitly excluded from this reduced-entitlement lane; it remains separate acceptance. |
| MAC-3 | The test configuration never constructs `AppBootstrap` or `RootView`; its scene admits only the dedicated identity and runner marker. A rejected launch remains inert and presents its typed rejection. Normal app compilation keeps its existing bootstrap. |
| MAC-4 | AppModel initialization, its playback/download construction and standalone PlaybackModel initialization receive fresh constructor-owned preference stores and download paths in this configuration. Explicit restoration-test stores retain their identity. Normal configurations retain shared stores. Automatic remote-command registration is disabled for test defaults. The shared cover loader uses the run-owned cache root, and five direct download-test constructors also receive owned roots. Unique preference domains are removed when their owner retires; the driver owns the temporary download root through native test completion. |
| MAC-5 | Both NetworkPathTests LiveAppService constructors supply a unique device-only synthetic credential namespace instead of production credential services. |

## Current acceptance disposition — 25 October 2026

MAC-1–MAC-5 merged in [#466](https://github.com/terminaloutcomes/bleat/pull/466).
Later [#469](https://github.com/terminaloutcomes/bleat/pull/469) and
[#473](https://github.com/terminaloutcomes/bleat/pull/473) delivered normal-app
storage/Diagnostics and account-editor fixes; #473's native lane passed 564/564
with zero failures, skips, expected failures or runtime warnings. The historical
failed attempts and reduced-entitlement lane receipts below remain unchanged.

Separate provisioned evidence now credits the
[609/609 core-host gate](https://github.com/terminaloutcomes/bleat/issues/25#issuecomment-6392332809)
and [1/1 app-host Keychain contract](https://github.com/terminaloutcomes/bleat/issues/25#issuecomment-6392383064).
That separate contract pass does not remove the reduced-entitlement lane's named
exclusion or turn its earlier failure into a pass. [#25](https://github.com/terminaloutcomes/bleat/issues/25)
retains accepted signed native login and historical normal termination/relaunch,
plus later password-free candidate restoration and user-confirmed Save. Only its
broad credential/privacy evidence and `APP-MAC-AUTH-001` completion remain open.
See [current delivery and acceptance](test-reliability-current-status.md); these
are linked receipts, not new executions performed by this tracking update.

## Supported validation

Use the configured `.envrc` and an existing Apple Development signing identity:

```sh
mise run macos:test
```

For focused admission/state coverage, the same driver accepts exact selectors:

```sh
mise exec -- cargo run --quiet --locked --package scripts --bin xcode-test-runner -- macos --test-id BleatAppTests/MacTestIsolationTests
```

The runner never requests provisioning updates. It requires the configured
signing team, but no production bundle identifier. The test host intentionally
carries no production Keychain-group or CloudKit entitlement. This is separate
from the provisioned signed core-host workflow and its synchronizable-Keychain
coverage. Do not replace either lane with unsigned results.

Native evidence is retained under `.build/macos-signed/`: build logs, exact test
discovery, `.xcresult` bundles and verifier receipts. Download fixtures live in a
fresh driver-owned temporary root and are retired after the native command.
The unit-test host is intentionally inert; it cannot establish real login,
Keychain restoration, normal-window navigation or application relaunch acceptance.
The repository's UI automation target supports iOS, so it is not a macOS UI
acceptance suite.

## Validation receipt

Original validation before serial integration: the dedicated development-signed macOS build-for-testing
and supported unsigned macOS Release compilation passed. Seventeen Rust runner
regressions, 39 build-helper tests, eight audit-parity regressions, strict Swift
lint and documentation checking passed. Focused native admission/state execution
passed three identities; the real legacy entry point independently passed the
same three. The complete isolated lane passed 545 identities with zero failures,
skips, expected failures or runtime warnings. The one explicitly excluded
provisioned synchronizable-Keychain contract remains unmet acceptance, rather
than a passed or skipped identity in that lane. Final-head CI and local Simulator
compatibility checks are recorded in the PR before handoff.

The provisioned signed core-host lane stopped before tests because its existing
profile/registration prerequisites were unavailable; no registration or profile
was created. The unsigned host gate subsequently verified 608 passes and one
named synchronizable-Keychain skip. Its first run had 590 passes, 13 failures and
one skip among 604 core identities: removed preferences domains were represented
as empty dictionaries rather than nil. Two test-only checks now accept an absent
or empty domain, still reject surviving entries, and preserve unrelated-domain
sentinels. The corrected complete host gate passed, including five transcription
identities. Four intentional known-issue reports and expected read-only-store
negative-case diagnostics remain separate from failures. The native owner also
retained a permission diagnostic during process-group signaling after retirement;
its final receipt proved the child exited and the group was gone.

The original native preflight attempts rejected the unhandled version-1 manifest
and Xcode-injected test-loader entitlements before enumeration or execution.
Their corrected structural regressions retain those rejection boundaries. Original unsuccessful build attempts remain local:
missing provisioning profile for the new identity, the old two-configuration
metadata assumption, package modules compiled without testability, and mismatched package Debug
conditions. These attempts executed zero native tests and establish no runtime acceptance.

Signed normal-application authentication/relaunch acceptance remains separate.
No iPad retest, physical iPhone energy work, other host access, credential setup,
trust change or permission change is part of this implementation.


The initial full native macOS attempt executed 546 identities: 545 passed and
`KeychainEntitlementTests/testApplicationHostKeepsRotatingTokensDeviceOnly`
failed with typed `missingEntitlement`; there were zero skips, expected failures
or runtime warnings. Its result is retained, not reclassified as a pass. The
isolated lane explicitly excludes only that provisioned-host contract; the four
other Keychain identities remain selected. It establishes no synchronizable
Keychain or signed normal-application authentication/relaunch acceptance.

Legacy `scripts/xctest.sh -s BleatMac -d platform=macOS` uses the same signing,
manifest, admission and owned-root preparation, preserving selection, result
path and safe forwarded environment. Debug requests map to the isolated test
configuration. Release/other-platform requests and overrides of the owned
admission/root markers are rejected with distinct typed causes.


Normal Xcode Run remains Debug and retains the real application bootstrap;
MacTesting is confined to TestAction. The generated-scheme regression verifies
both actions. Native Xcode logs retain ambiguous-destination warnings; inspected
result bundles identify native macOS execution and contain no runtime warnings.
One intermediate version-1 parser regression failed before its complete parser
repair; the final 17-test runner receipt passes all identities.

CI at reviewed head `40a5c12` reported newly published `RUSTSEC-2026-0387` for
`crypto-bigint 0.5.5` in the unchanged backend lockfile. The macOS PR does not
change either Rust lockfile or waive the advisory. Exact final-head status is
reported separately; passing local implementation checks do not clear that
repository-security gate or authorize merge.


## Serial integration with CarPlay/audio repair (#468)

PR #468 merged as `64fa56676cd88d3b1a87159754d91bc233f121e2` after two clean
final reviews and successful exact-head checks. Its iOS26.5 CI and local iOS27
lanes each verified 660 passes with zero failures, skips or runtime warnings.
Its retained initial Rust image-pull setup failure recovered with one failed-job
rerun on the unchanged reviewed head, without source or assertion changes.

The macOS branch is rebased onto that merge. Conflict resolution retains both
constructor-owned defaults/stores/download state and the asynchronous paired
audio-session dependency, including the test-only remote-command policy. The
first-activation and AppModel outcome/persistence retirement guards remain intact.
Both audit inventories and traceability sections are retained, without reopening
historical cohorts. XcodeGen regeneration adds the inherited bridging header to
MacTesting; normal Run remains Debug and isolation stays confined to TestAction.

The combined isolated macOS lane discovered and verified **558 passes**, zero
failures/skips/expected failures/runtime warnings. This includes the thirteen
additional cross-platform audio/lifecycle identities from #468. The real legacy
entry point separately verified all three admission/state identities, also with
zero runtime warnings. Seventeen Rust runner regressions, all 39 build-helper
tests and eight audit-parity regressions passed. The full unsigned host gate
verified 608 passes plus the one explicitly expected unsigned Keychain skip.
Strict Swift lint, documentation references, audit parity and whitespace checks
passed. Final combined Release/iOS and exact published-head CI results are
reported in the PR rather than inferred from either pre-integration branch.

The isolated lane still explicitly excludes the single provisioned-host
Keychain contract. Its results do not establish normal signed authentication,
relaunch or synchronizable-Keychain acceptance. No signing credentials, profiles,
trust settings, physical devices or unrelated data were changed.
