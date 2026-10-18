# Tests outside core and app model

Tracked by [issue #362](https://github.com/terminaloutcomes/bleat/issues/362). Owner for these follow-ups: Bleat maintainers. `TestSupport/TestAudit/other.json` records source-specific cases and shared rule profiles; its pending count is authoritative for unreviewed bodies. No full-suite compliance or execution claim is made.

## Actionable follow-ups

1. **Runner verification implemented.** The [runner verification batch](test-runner-verification.md) adds exact Xcode and SwiftPM identity, multiplicity, outcome, summary, and skip-policy checks, with retained result artifacts. Its evidence record separates regression checks from full workflow execution; other follow-ups below remain independent.

2. **Verify bounded UI waits in Xcode.** `scrollUntilHittable` and related scroll/wait helpers in `Tests/BleatUITests` previously could exhaust their bounded polling loops without reporting a failure at the call site. The helpers now preserve their attempt bounds and call `XCTFail` with the caller's `file` and `line`; each caller still needs its semantic postcondition. An additional timing review added bounded playback-label waits before mini-player gestures and waits for the prior chapter row before tapping. These Swift changes were handed to the parent-owned Xcode validation; see the main audit record for its exact outcome.

3. **Download completion now has an explicit fixture signal.** `checkEditDuringDownload`, used by the same-book and unrelated-book edit tests, requests two real observed byte-progress updates while the actions menu remains open. The editor then explicitly releases fixture completion and waits for its completed state before checking the draft. The former 42-second inference has been removed. Both identities passed twice in `.build/timing-ui-compiled.xcresult`; owning-suite evidence is recorded in the main audit.

4. **Playback menu checks now observe real time updates.** `testPlaybackRateMenuRemainsStableAcrossTimeUpdates` and `testPlaybackActionMenusRemainStableAcrossTimeUpdates` capture the existing playback slider's accessibility value after opening each overlay, await a changed value, then assert the menu remains hittable. Both identities passed twice, including the chapter sheet, with no new clock or menu identity dependency. Owning-suite evidence is recorded in the main audit.

5. **Document the live JWT refresh threshold.** `TelemetryRecoveryLiveTests.testExistingPipelineRefreshesJWTAndDrainsQueuedSpan` configures a 1,000-second refresh window, which already makes the cached token eligible for refresh. The 1,100 ms wait crosses the issuer’s whole-second claim boundary so the refreshed signed token differs even though claims contain no random JWT ID. The follow-on batch asserts `.expiring` before waiting and documents the one-second boundary plus 100 ms margin. This is real elapsed-time token integration, not a completion wait; live execution evidence is recorded separately in the main audit.

6. **Resolved: keep protected capacity occupied through the health probe.** On explicit user request, `bleat_api::http::tests::health_remains_available_while_protected_capacity_is_exhausted` now holds the handler on an entry/release gate. It verifies zero available permits before and after the health response, releases the handler before asserting, and verifies the permit is restored after completion. Both request futures are joined within a five-second failure budget; timeout cancels them without detached work. The one-second route deadline remains and cannot silently make the test pass, because the held-capacity and successful protected-response assertions would fail. Follow-up validation is recorded in the main audit.

7. **Large-library ownership implemented (issue #379).** The shell entry point now launches `scripts/src/large_library.rs`. A locked ownership manifest and exact recorded-resource validation replace glob cleanup; unowned populated output is rejected. Disposable filesystem regressions cover shrinking, repeated generation, collisions, modified/missing ownership data, symlinks, failures, unrelated resources and wrapper forwarding. Follow-up review corrected initialization from the exact checked-in scaffold and added durable publication state; regressions reproduce both the fresh-checkout default-output failure and interrupted expansion followed by retries at the former or smaller count. See the [dataset contract](performance-baseline.md#dataset-construction) for initialization and interrupted-publication limits. This resolves only the generator cleanup defect; issue #376 retains the other fixture work.

8. **Signing-key lifecycle implemented ([#378](https://github.com/terminaloutcomes/bleat/issues/378)).** The two fixtures in `bleat-api/tests/http_api.rs` already used awaited Tokio writes/removals; the remaining defect was success-only cleanup. They now share `bleat-api/tests/support/signing_fixture.rs`: exclusive creation establishes ownership, awaited writes/flush finish before use, and operation errors or panic payloads are captured before checked removal. The helper retains cleanup failure alongside the operation result and fails otherwise successful work. The initial review P2 in `production_router_with_key` is fixed: the real operation result passes directly through the lifecycle, and combined failure retains both typed causes. A regression using the same `ProductionRouterOutcome` type verifies the exact signing-configuration cause at the final failure boundary. Cancellation is explicitly signalled; the owner aborts and joins the operation before removal and must itself be awaited to completion. This does not guarantee cleanup when the owner is dropped/aborted, the runtime is destroyed, or the process is killed. Ten focused regressions cover typed configuration/database/router failure injection, success and unexpected success, controlled cancellation, unwinding, cleanup failure alone/combined with operation failure, distinct fixtures, and an unrelated sentinel/collision. Both malformed-key assertions are preserved. Docker-backed validation and the exact execution evidence are recorded below; this work addresses only the two fixture lifecycles, not #376 or the wider audit.

## Fixed during this audit

`testBookContextMenuDownloadRunsInBackground` and `testContextDownloadAndRemovalAreMutuallyExclusive` replaced the prior guessed 8-second context-download delay with a cancellation-aware `UITestContextDownloadGate`. The debug fixture exposes a release button only while preparation is pending; each journey asserts its context-menu state, navigates to Downloads, releases the gate explicitly, and then waits for the download row. This observes the pending-to-progress transition without sleeping for an assumed duration.

`AuthenticatedOtlpSpanExporterLiveTests.testExportsWithRealJWTOverOTLPHTTP` now registers awaited exporter shutdown in XCTest teardown before exporting, so assertion failures also release pipeline resources. The three directly changed UI cases, bounded Rust admission waits, socket exchange, and App Store Connect temporary-file cases have their `fixed` decisions and exact changed postconditions recorded in `TestSupport/TestAudit/other.json`. API signing-key fixture changes are recorded in follow-up 8.

## Shared live-test support inspection

`TestSupport/ServerHarness/download_fault_proxy.py` was inspected with the application-live runner. Its `FaultState` guards arm/reset, one-shot fault claiming, sequence numbers, and event snapshots with a lock; evidence records range/status/auth scheme and whether a query exists without retaining token values. It injects exactly one `401` for the first ranged download starting above byte zero, forwards other requests, and uses a finite 120-second upstream connection timeout. `scripts/test-app-live.sh` selects a free proxy port, polls its health endpoint with a 50-by-100ms bound, arms the fault once, checks the `401`/refresh/resume event order, then terminates the proxy during cleanup. The source has no direct standalone test target; its behavior is exercised by the app-live flow, whose exact XCUITest identity/outcome verification is tracked in the runner follow-up.

The ordinary live harness uses unique Compose project names in `scripts/test-live.sh`, profile manifests with exact Audiobookshelf versions and image digests, and resets only that project’s volumes before seeding three known media fixtures. `live-profile.sh` checks the profile/image/version relationship; Caddy serves root and prefixed routes with a locally generated CA, and the app-live runner installs that CA only into its disposable Simulator. The Keycloak OIDC fixture and large-library media are separate setup paths. The large-library generator now validates ownership before replacing recorded books, as described in follow-up 7; it preserves unrecorded siblings. Audiobookshelf cleanup/fixture reset flows were reviewed from source but not run in this audit; the separate disposable PostgreSQL/telemetry gates were subsequently run as recorded below.

## Execution status

Validation on this working tree: `python3 -m unittest discover -s Tests/ScriptTests -v` ran 11 tests; `python3 -m unittest discover -s TestSupport/HostTests -v` ran 8; `python3 -m unittest discover -s TestSupport/SwiftTestingPrototype -p 'test_verify_results.py' -v` ran 7; `python3 -m unittest scripts.test-cloudkit-schema-validator -v` ran 6. All passed. `cargo test --locked --package scripts --test app_store_connect` ran 5 tests and passed twice; `cargo test --locked --package bleat-api --lib` ran 75 tests, all passed. The interim API HTTP integration target passed 12/12 and its signing-failure regression passed again 1/1; after reverting the blocking fixture change, the final-source HTTP target passed 12/12 separately; the full disposable telemetry gate also passed, including its six live cases. See the main audit for counts, prior failures and fresh-container repetition outcomes. Simulator/Xcode outcomes and the full owning-suite status are authoritative in the [main issue audit](test-reliability-audit.md#simulator-attempts-retained); this tooling subsection does not supersede its later attempts or count partial/failed selections as passes. The parent reports a focused run of 13 IDs with 26 passing executions (10 gate cases, scrubber, and two context-download cases), plus two passing repetitions each for the three mini-player/chapter fixes. The owning run reconciled 700 identities: 698 passed, one installation-interrupted app case failed, and the external-URL-driver case skipped as expected. The isolated app-suite rerun passed all 598 identities twice, including the interrupted case; the 102-case UI selection had 101 passes and that expected skip. The main audit holds the authoritative result-bundle details.


### Issue #378 fixture validation (2026-10-18)

Source base: `4bb50735a0214d2d9c3385dd4946f2412499979d` plus the issue #378 change;
the PR head records the final tested implementation. The focused command was
`mise exec -- cargo test --locked -p bleat-api --all-features --test http_api signing_fixture::tests -- --nocapture --test-threads=4`.
An initial run and a run after final formatting each passed all nine identities
below. The owning HTTP target then passed 21/21 using the configured healthy
OrbStack Docker endpoint through process-local `DOCKER_HOST`/`DOCKER_CONTEXT`;
the saved Docker context was unchanged.

All names below have prefix `signing_fixture::tests::` in the `http_api` target:

| Identity | Observed postcondition |
| --- | --- |
| `configuration_failure_cleans_fixture` | Injected typed configuration error retained; file absent |
| `database_failure_cleans_fixture` | Injected typed database error retained; file absent |
| `router_failure_cleans_fixture` | Injected typed router error retained; file absent |
| `success_and_unexpected_success_clean_before_assertion` | Both returned values survive; files absent before assertions |
| `cancellation_joins_operation_then_cleans_fixture` | Creation signal precedes cancellation; joined cancellation result and file absence |
| `unwinding_retains_original_payload_after_cleanup` | File absent before original typed panic payload resumes |
| `cleanup_failure_fails_successful_work` | Real removal failure retained and finish panics; fault directory explicitly removed |
| `cleanup_failure_preserves_operation_failure` | Helper retains both typed operation error and removal error; fault directory explicitly removed |
| `instances_and_existing_sentinel_are_isolated` | Distinct paths; inner cleanup preserves outer file/sentinel; exclusive creation collision preserves sentinel |

The stage errors are deterministic helper injections rather than actual failing
configuration/database connections. The malformed-key integration test still
checks the exact typed router failure and privacy-safe message. Creation collision
is covered; partial-write/flush failure is not deterministically injected.
Expected panic-hook output comes from the three explicit unwind/failure checks;
it is asserted and is not an unexplained runtime warning.

Retained infrastructure attempts: the first owning HTTP run passed the nine
fixture cases but failed all 12 PostgreSQL cases at container startup because
the default Docker endpoint refused connections. The first API gate passed
75 library tests and failed all nine database tests at the same boundary;
its concurrent compilation/Release tasks were interrupted. These are not
successful integration evidence. The healthy endpoint was verified before the
reruns; no test wait or assertion was weakened.

The initial independent read-only review reported no P0/P1 findings and one P2,
subsequently fixed on user request as described in follow-up 8. No
production code or dependencies changed. Owner-future abortion, process kill,
and runtime destruction remain outside the cleanup guarantee.

The healthy-endpoint `mise run api:validate` rerun passed formatting, all-target
compilation, strict Clippy (`-D warnings`), the Release binary build, and 106
tests: 75 library, nine database, 21 HTTP (including a second final-source
execution of every fixture regression), and one startup test. Empty binary and
doc-test bundles add no coverage. No unexpected warning or skip was reported.
Local logs are retained in `.build/issue-378/`: `focused-initial.log`,
`focused.log`, `http-default-docker.log`, `http.log`,
`api-validate-default-docker.log`, and `api-validate.log`.

Each of the nine new identities also passed separately with the same Cargo
command filtered to its full identity and `--exact` (one executed test per
invocation). Logs are `individual-<identity>.log` in the same artifact directory.
`mise run docs:check` passed; its log is `docs.log`. `git diff --check` passed.


### Issue #378 diagnostic-preservation follow-up

On user request, the initial P2 at `bleat-api/tests/http_api.rs` was fixed:
`production_router_with_key` now passes its real typed result directly into
`Outcome`. `finish` returns that error after successful cleanup; when cleanup
also fails it reports and preserves both typed outcomes in the panic payload.
An existing panic payload still resumes unchanged after cleanup reporting.
The new `production_router_cleanup_failure_retains_signing_configuration_cause`
regression shares the actual caller's `ProductionRouterOutcome` type and
asserts the exact `RouterBuildError::TokenIssuer(TokenIssuerError::SigningKeyConfiguration)`
cause survives the final combined-failure boundary. Existing stage and cleanup
regressions now verify `finish`, including typed combined failures.

The focused `cleanup_failure` selection passed 3/3. The new identity also passed
alone with `--exact` (1/1). The full HTTP target passed 22/22, then passed again
inside `mise run api:validate`: 107 total tests (75 library, nine database,
22 HTTP, one startup), formatting, all-target compilation, strict Clippy and
Release build passed. `mise run docs:check` and `git diff --check` passed.
The same healthy OrbStack endpoint settings were used, with no failed attempt
in this follow-up. Fault-injection panic output was expected and asserted;
no unexplained warning or skip occurred. Evidence logs are retained under
`.build/issue-378/` as `p2-focused.log`, `p2-individual.log`, `p2-http.log`,
`p2-validate.log`, and `p2-docs.log`.

A fresh independent complete-change review reported no findings and confirmed
the original P2 resolved (two independent reviews in total). Partial-write/flush
fault injection is still untested, and the documented owner-abortion/runtime/
process termination exclusions remain.
