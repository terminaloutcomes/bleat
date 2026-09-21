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

The wrapper now defaults to a provisioned, signed copy of the toolchain's Swift
Testing helper with `--testing-library swift-testing --no-parallel`. The explicit
unsigned CI lane uses `--disable-xctest --no-parallel`. This avoids the
XCTest discovery path while preserving global serialization for shared
URLProtocol state and timing-sensitive fixtures. Individual converted suites
also have `.serialized` traits. Explicit concurrency tests still exercise their
original tasks and actors.

SwiftPM's current SwiftBuild backend produces one test product per target. A
single `--xunit-output` path can consequently be overwritten by a later empty
target. The wrapper builds once, selects each host product explicitly,
and combines reports before checking every identity against
`TestSupport/HostTests/inventory.json`. Missing, duplicate, failed, unexpectedly
skipped, and zero-test reports fail validation. Update the inventory whenever
host tests are added, renamed, or removed.

The wrapper also handles the package-wide product produced by the native
backend used by Swift 6.2. Both product layouts were exercised on Swift 6.4;
execution on a Swift 6.2 toolchain remains unverified locally. The implementation
uses Swift Testing APIs available before Swift 6.4, without the newer runtime cancellation API. SwiftPM 6.2's
[command source](https://github.com/swiftlang/swift-package-manager/blob/swift-6.2-RELEASE/Sources/Commands/SwiftTestCommand.swift)
defines the product-selection, coverage, serialization, and XCTest-disable
workflow. The signed host uses the same helper and framework search paths,
without modifying Xcode or suppressing diagnostics. The native backend experiment emitted a deprecation warning on Swift
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
| Keychain signing | Signed local host runs the synchronizable case and rejects all skips; explicitly unsigned CI excludes that named test |

There were no core setup/teardown overrides or XCTest expectation APIs, but
there were six `addTeardownBlock` registrations. They are now explicit cleanup
scopes. Keychain tests use uniquely scoped synthetic credentials and await
deletion. Four regression tests cover successful cleanup, operation
failure, cleanup failure, and simultaneous failures. The last intentionally
records one known cleanup issue while asserting the original propagated error
outside that expected-issue scope.

SwiftPM clears its coverage directory for each unsigned instrumented run. The
unsigned wrapper copies each product's fresh profile before starting the next.
The signed lane writes fresh per-product raw profiles directly. Both merge profiles
with `llvm-profdata`, and exports all test binaries through `llvm-cov`. The
normalizer keeps project-relative production sources only and rejects missing
or entirely unexecuted BleatCore or BleatTranscription coverage. Reports are:

- `.build/host-results/tests.xml`: verified combined individual outcomes.
- `.build/coverage/swift-host/lcov.info`: production LCOV for Coveralls.

CI adds a host job and the `swift-host` Coveralls flag. Existing Slather smoke
coverage (`swift-smoke`) and Rust coverage (`rust-full`) are preserved. The
parallel report is finalized after all three upload attempts. Per-product XML
is retained even when a failed test prevents combined-report generation. Fork PRs generate
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

Before the signed-host correction, the wrapper verified 478 passes and one
permitted entitlement skip,
and exports executed production coverage for both libraries. The native backend
experiment independently verified the 476 identities present before the final
upstream rebase. All 39 affected telemetry tests pass after preserving and
converting the three new upstream tests. Eight report-tool
regression tests pass. Review preserved every original assertion/unwrap check
and found no P0/P1 migration defect. A cleanup-test review finding was fixed by
moving the propagated-error assertion outside `withKnownIssue`.

The first CI host run compiled and executed all 479 tests using the native
aggregate product, but one timeout test failed. Its final manual deadline check
returned false after the background watchdog had already recorded the timeout.
The assertion now checks the exact recorded typed failure instead of which
caller first expired the callback. Review also identified that the original
timings did not distinguish a reset deadline from the original deadline; the
intermediate check now falls between those deadlines and requires both no new
expiration and no recorded failure. No production clock or timeout behavior was
changed. This failed CI attempt is retained as evidence rather than treated as
a passing run.

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
instrumentation and this assertion come from upstream. At that revision there
were no app source or app test changes relative to rebased main. The host coverage gate,
Release builds, and strict Swift lint pass. The UI stage is not reached.

The separate live XCTest target executes all 21 named cases: three local
configuration checks pass and 18 fixture-dependent cases skip. This verifies
that the target remains runnable, not disposable-server integration behavior.

The follow-up fixes address these failures separately from the runner conversion:

- Promotion publishes the persisted manual record before scheduling its new
  tracks, so transfer validation does not reject them against the old automatic
  cache target indexes.
- Chunk scheduling reserves a book across suspension points and checks for a
  surviving task before authorization. Repair and background recovery cannot
  register duplicate tasks or competing tracks for that book. A gated regression overlaps those
  operations while authorization is suspended.
- The two cached-window tests now include an uncached track. Their former
  single-track fixtures were correctly promoted to complete manual downloads,
  which do not need streaming continuation. The corrected tests also await the
  asynchronous continuation request with a bounded deadline.
- The download telemetry assertion checks download-transfer spans independently
  of HTTP spans, whose presence depends on whether cancellation follows actual
  network dispatch. The separate HTTP-metrics regression retains that contract.

The download-fix follow-up gate passed all **424 app tests**, including the five
original failures and the new gated concurrency regression; individual outcomes
were verified from the result bundle. Its host stage passes **478 tests with
one expected entitlement skip**, exports LCOV, and passes Release builds. Strict
Swift lint also passes.

Both disposable-server app journeys pass: online login/playback/download and
offline cached playback/local progress, one named test each, verified from their
result bundles. The first `scripts/test-app-live.sh` attempt exited 1 during
harness setup before creating a Simulator or running a test, with no diagnostic
explaining the exit. A repeat with a shell failure-location trap passed and
cleaned up its disposable resources; the initial setup exit remains unexplained.

Earlier superseded validation at
`c00b05b0` passed 402 app tests but failed a stale UI download-menu expectation
subsequently corrected on main; it does not validate this revision. The
simulator emitted debugger-version lookup warnings whose tooling cause remains
unresolved. No physical-device validation is claimed.

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

## Signed host correction

The earlier permitted entitlement skip was a coverage gap. Inspection found
that SwiftPM's installed helper was ad-hoc signed with only `get-task-allow` and
no application identity or Keychain access group. The app's own signing settings
do not apply to that separate process. Apple's [macOS Keychain guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)
explains why synchronizable items need provisioned data-protection access.

`TestSupport/HostTests/project.yml` now defines a dedicated, automatically
provisioned macOS application that hosts a copy of the Swift Testing helper.
The configured development team and certificate stay local. The host receives
its own application identity and Keychain access group; the installed toolchain
and the production app's Keychain group are untouched. The local gate requires
this host and rejects every skipped test. The entitlement probe was removed:
a Keychain error in the signed lane is a test failure.

The unsigned CI lane is selected explicitly and named accordingly. It excludes
only `testDeleteAllCredentialsRemovesNativeLoginAfterICloudKeychainIsDisabled`;
the report verifier requires an explicit unsigned-lane flag to accept that
omission. It must not be reported as signed-Keychain validation. Both lanes
continue to verify the same inventory and export production LCOV for Coveralls.

The formerly skipped test passed in isolation in the provisioned host. The
complete signed gate then verified **479 passed, zero skips**, with executed
production LCOV for both libraries. The explicit unsigned lane verified
**478 passed and its one declared Keychain exclusion**, with production coverage
for both libraries. Eight report-verifier tests, strict Swift lint, actionlint,
workflow/project YAML parsing, shell syntax, and whitespace checks pass.

The signed helper was also traced across all **474 core/cleanup tests**, with
zero skips and a successful inferior exit. All three breakpoints resolved with
zero hits: XCTest subclass discovery, Contacts initialization, and Core Data
XPC-store initialization. The intentional cleanup-failure fixture remains one
known issue. Signing did not reintroduce the original Contacts path.
