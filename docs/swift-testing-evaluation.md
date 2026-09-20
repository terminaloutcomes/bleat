# Host Swift Testing migration

Issue [#125](https://github.com/terminaloutcomes/bleat/issues/125), evaluated and
converted on 2026-09-20 with Xcode 27.0 (27A266a), Swift 6.4, Testing 2084, and
macOS 26.6.2 on Apple Silicon. The conversion began on `28daa1fb` and was rebased onto `8e26a7b3`,
preserving three additional upstream HTTP telemetry tests.

## Runner and scope

Run `scripts/test-host.sh`. All 37 core suites and their 470 original test
identities now use Swift Testing. Four new cleanup regression tests and the five
existing transcription tests bring the verified inventory to 479 tests across
40 suites. One transcription test retains its three parameterized cases.

The wrapper explicitly uses `--disable-xctest --no-parallel`. This avoids the
XCTest discovery path while preserving global serialization for shared
URLProtocol state and timing-sensitive fixtures. Individual converted suites
also have `.serialized` traits. Explicit concurrency tests still exercise their
original tasks and actors.

SwiftPM's current SwiftBuild backend produces one test product per target. A
single `--xunit-output` path can consequently be overwritten by a later empty
target. The wrapper builds once, selects each host product with `--test-product`,
and combines reports before checking every identity against
`TestSupport/HostTests/inventory.json`. Missing, duplicate, failed, unexpectedly
skipped, and zero-test reports fail validation. Update the inventory whenever
host tests are added, renamed, or removed.

The wrapper also handles the package-wide product produced by the native
backend used by Swift 6.2. Both product layouts were exercised on Swift 6.4;
execution on a Swift 6.2 toolchain remains unverified locally. The implementation
uses Swift Testing APIs available before Swift 6.4, including asynchronous
condition traits rather than the newer runtime cancellation API. SwiftPM 6.2's
[command source](https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/Commands/SwiftTestCommand.swift)
defines the product-selection, coverage, serialization, and XCTest-disable
workflow. No fork, private framework configuration, or diagnostic suppression
is needed. The native backend experiment emitted a deprecation warning on Swift
6.4; the final wrapper leaves backend selection to SwiftPM.

Live tests remain XCTest under `scripts/test-live.sh`. Their environment checks
and fixture-dependent skips are unchanged. The telemetry gate runs converted
host suites with XCTest disabled and keeps its live configuration checks on
XCTest. App-hosted and UI tests retain their Xcode runners and attachments.

## Assertions, lifecycle, and coverage

| Existing behavior | Converted behavior |
| --- | --- |
| Equality, nil, ordering, booleans | Native `#expect`, with structural equality and diagnostic comments |
| Floating-point tolerance | Same finite-value workloads and explicit absolute-error bounds |
| Required optional values | Throwing `#require`; nested requirements are evaluated separately |
| Typed synchronous errors | `#expect(throws:)` plus the original typed cause assertions |
| Typed asynchronous errors | Shared async assertion helper records failures through Swift Testing |
| Async methods and actor isolation | Original async/throwing signatures and actor annotations retained |
| Versioned fixtures and persistence | Original resources, stored shapes, and account-isolation checks retained |
| Manual performance bounds | Same workload, clocks, bounds, and performance summaries |
| Keychain teardown | Awaited cleanup on success and thrown failure; synchronous Security fixture cleanup uses `defer` |
| Entitlement skips | Typed asynchronous preflight enables the iCloud case or records an explicit skip; unexpected errors fail trait evaluation |

There were no core setup/teardown overrides or XCTest expectation APIs, but
there were six `addTeardownBlock` registrations. They are now explicit cleanup
scopes. The entitlement probe uses uniquely scoped synthetic credentials and
awaits deletion. Four regression tests cover successful cleanup, operation
failure, cleanup failure, and simultaneous failures. The last intentionally
records one known cleanup issue while asserting the original propagated error
outside that expected-issue scope.

SwiftPM clears its coverage directory for each instrumented run. The wrapper
copies each product's fresh profile before starting the next, merges profiles
with `llvm-profdata`, and exports all test binaries through `llvm-cov`. The
normalizer keeps project-relative production sources only and rejects missing
or entirely unexecuted BleatCore or BleatTranscription coverage. Reports are:

- `.build/host-results/tests.xml`: verified combined individual outcomes.
- `.build/coverage/swift-host/lcov.info`: production LCOV for Coveralls.

CI adds a host job and the `swift-host` Coveralls flag. Existing Slather smoke
coverage (`swift-smoke`) and Rust coverage (`rust-full`) are preserved. The
parallel report is finalized after all three upload attempts. Fork PRs generate
artifacts without uploading, and upload failures retain the existing warning
policy. Eight verifier tests cover empty/overwritten XML, identity mismatches,
duplicates, failures, unexpected skips, and absent/zero/duplicate coverage.

## Diagnostic evidence

LLDB observes `+[XCTestCase(RuntimeUtilities) _allSubclasses]`,
`+[CNContactStore initialize]`, and `-[NSXPCStoreConnection initForStore:]`,
using `TestSupport/SwiftTestingPrototype/trace.lldb`. Breakpoints continue
automatically; test outcomes, inferior exit, resolved locations, hit counts,
and loaded images are checked separately.

| Workload / runner | Instrumentation | Discovery | Contacts init | XPC-store init |
| --- | --- | ---: | ---: | ---: |
| Original core XCTest at `c00b05b0` | Ordinary and coverage | 1 | 3 | 4 |
| Isolated prototype, default SwiftPM | Ordinary and coverage | 1 | 1 | 0 |
| Isolated prototype, explicit Swift Testing helper | Ordinary and coverage | 0 | 0 | 0 |
| Converted complete core suite, explicit Swift Testing helper | Coverage | 0 | 0 | 0 |

XCTestCore still loads. Avoiding its subclass discovery is the measured benefit;
merely converting assertions while retaining default mixed-runner execution
would still initialize Contacts. The full converted trace executes 474 core
tests (473 passed, one entitlement skip), resolves all three breakpoints, and
exits successfully. Ordinary host execution and coverage execution also pass.

The original XPC-store backtrace enters ContactsPersistence through
`CNPersistentStoreBuilder addRemoteStoreWithURL:options:`. It does not indicate
a failed Bleat persistence store. Normal SwiftData messages remain visible,
including the intentionally read-only store failure exercised by
`testReadOnlyCommitFailureRollsBackTranscriptAndCheckpoint`.

A direct debugger launch of the native aggregate executable was denied by macOS
attach permissions despite normal host access. It is excluded from evidence;
the successful full-suite trace uses the same SwiftPM helper as the final
SwiftBuild runner. That debugger run also emitted a distinct
`com.apple.linkd.autoShortcut` connection warning. Its cause remains unresolved;
it is not a Contacts discovery hit or a failed test and was not suppressed.

## Validation and limitations

The final host wrapper verifies 478 passes and one permitted entitlement skip,
and exports executed production coverage for both libraries. The native backend
experiment independently verified the 476 identities present before the final
upstream rebase. All 39 affected telemetry tests pass after preserving and
converting the three new upstream tests. Eight report-tool
regression tests pass. Review preserved every original assertion/unwrap check
and found no P0/P1 migration defect. A cleanup-test review finding was fixed by
moving the propagated-error assertion outside `withKnownIssue`.

The full simulator gate already failed on unmodified `28daa1fb`: 422 app tests,
418 passed and four failed. A focused rerun passed the lookahead case and
repeated the other three failures. The first converted full gate on the same base reproduced exactly the same
418 passes and four failures (exit 65); its UI stage was not reached. These
results precede the final upstream rebase:

| AppModelTests case | Baseline full-gate assertion |
| --- | --- |
| `testAllLookaheadCreatesAndPromotesManualDownloadsThatSurviveCleanup` | Scheduled indexes `[]` instead of `[1]` |
| `testAutomaticCachedDownloadUsesPersistedAccessWhileOffline` | Playback request count 0 instead of 1 |
| `testPlaybackStartExcludesIncompleteAndUsesAutomaticCachedWindow` | Playback request count 0 instead of 1 |
| `testThreeHundredTrackDownloadRepairAndPublicationStayResponsive` | Scheduled indexes `[150, 150]` instead of `[150]` |

After rebasing onto `8e26a7b3`, the complete local gate again exits 65 at the
app stage: **423 app tests, 418 passed, five failed, no skips**. Individual
outcomes were inspected with `xcresulttool`. The four failures above recur,
and `testManualDownloadSchedulingAndCancellationEmitTaskSpans` also fails: its
whole-span-array assertion expects only a cancelled `.downloadTransfer` span,
but receives that span plus a cancelled `.httpRequest` span. Both the new HTTP
instrumentation and this assertion come from upstream; this PR changes no app
source or app tests relative to the rebased main. The host coverage gate,
Release builds, and strict Swift lint pass. The UI stage is not reached.

The separate live XCTest target executes all 21 named cases: three local
configuration checks pass and 18 fixture-dependent cases skip. This verifies
that the target remains runnable, not disposable-server integration behavior.

The two playback assertions inspect service calls before an unstructured
continuation task necessarily runs. Lookahead/background-task timing and the
repair test's manual completion need further investigation; those two causes
remain unproven. The baseline UI stage was not reached. Earlier superseded
validation at `c00b05b0` passed 402 app tests but failed a stale UI download-menu
expectation subsequently corrected on main; it does not validate this revision.
The simulator emitted debugger-version lookup warnings whose tooling cause
remains unresolved. No physical-device validation is claimed.

The isolated seven-test prototype remains available for comparing the default
and explicit runners independently of the root test graph:

```sh
python3 -m unittest discover -s TestSupport/SwiftTestingPrototype
BLEAT_PROTOTYPE_TRACE=1 TestSupport/SwiftTestingPrototype/run.sh
```

Its individual-result verifier requires six passes and one intentional skip in
each ordinary/coverage run. Earlier crashed/zero-test helper invocations and an
interrupted script-edit run are excluded; the finalized matrix was rerun and
verified. Raw debugger logs can contain local paths and should stay local.
