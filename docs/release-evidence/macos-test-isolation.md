# macOS app-hosted test isolation (#362, #369, #374)

The maintainer resumed the five previously deferred macOS groups on 24 October
2026. This work addresses the documented reachable boundary: the former
`BleatMac` scheme used the normal app bootstrap, identity, preferences and
default download location. Compilation alone did not make launching it safe.
The completed 312 historical review dispositions remain unchanged.

| Group | Implementation |
| --- | --- |
| MAC-1 | `MacTesting` configuration and `BleatMac` scheme use a dedicated host/test identity, disabled CloudKit/App Attest/CarPlay, and existing development signing without provisioning updates. Package testability is explicit. The generated project comes from `project.yml`. |
| MAC-2 | The Rust driver validates the single built `.xctestrun`, exact host executable/test bundle/target, bundle identities, runner admission marker, development signature/team and absence of production capabilities (only the exact standard Xcode unit-test loader entitlements are admitted) before enumeration. Enumeration and execution consume that same manifest. Existing exact-discovery/result verification rejects zero tests, missing identities, failures and unexpected skips. |
| MAC-3 | The test configuration never constructs `AppBootstrap` or `RootView`; its scene admits only the dedicated identity and runner marker. A rejected launch remains inert and presents its typed rejection. Normal app compilation keeps its existing bootstrap. |
| MAC-4 | AppModel initialization, its playback/download construction and standalone PlaybackModel initialization receive fresh constructor-owned preference stores and download paths in this configuration. Explicit restoration-test stores retain their identity. Normal configurations retain shared stores. Automatic remote-command registration is disabled for test defaults. The shared cover loader uses the run-owned cache root, and five direct download-test constructors also receive owned roots. Unique preference domains are removed when their owner retires; the driver owns the temporary download root through native test completion. |
| MAC-5 | Both NetworkPathTests LiveAppService constructors supply a unique device-only synthetic credential namespace instead of production credential services. |

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

Current validation: the dedicated development-signed macOS build-for-testing
and supported unsigned macOS Release compilation passed. Fourteen Rust runner
regressions, 39 build-helper tests, eight audit-parity regressions, strict Swift
lint and documentation checking passed. Native application-test execution and
final-head checks remain in progress.

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
metadata assumption, and package modules compiled without testability. These
attempts executed zero native tests and establish no runtime acceptance.

Signed normal-application authentication/relaunch acceptance remains separate.
No iPad retest, physical iPhone energy work, other host access, credential setup,
trust change or permission change is part of this implementation.
