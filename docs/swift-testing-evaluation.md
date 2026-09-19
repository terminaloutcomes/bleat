# Host Swift Testing evaluation

Issue [#125](https://github.com/terminaloutcomes/bleat/issues/125), evaluated
on 2026-09-20 with Xcode 27.0 (27A266a), Swift 6.4, Testing 2084, and
macOS 26.6.2 on Apple Silicon. Initial diagnostic evidence uses `c00b05b0`;
the changes were subsequently rebased onto main at `28daa1fb`.

## Decision

Use SwiftPM's explicit Swift Testing-only runner for migrated host unit tests:

```sh
swift test --disable-xctest --enable-code-coverage
```

The prototype supports a phased host migration with this runner choice. In both
ordinary and coverage runs, it executes the runnable tests without calling
XCTest subclass discovery, initializing Contacts, or entering the XPC-store
initializer. XCTestCore still loads; avoiding its discovery path is the measured
benefit. No SwiftPM fork, private framework setting, or diagnostic suppression
is needed.

The initial recommendation to retain XCTest gave too much weight to default
execution. **Default SwiftPM still initializes Contacts, but the supported
`--disable-xctest` option avoids the observed path in the prototype.** Choose
that option deliberately rather than treating the default as a migration blocker.

The host migration is not implemented by this prototype. Keep the existing root
gate during conversion; switching it immediately would silently omit the current
467 core XCTest tests. Once every host test has been converted and equivalent
individual outcomes verified, switch the host coverage command to the explicit
runner above. Keep live XCTest execution in `scripts/test-live.sh`, which already
uses `swift test --filter BleatCoreLiveTests`, and keep app/UI execution in Xcode.
The final migration must also verify the complete converted workload's diagnostic
behavior and preserve the live target's existing checks in that separate workflow.

## Current source and prototype

The original issue's counts and coverage-only symptom are historical. The tested
revision contains 37 core XCTestCase suites / 464 methods, 16 live XCTestCase
suites / 21 methods, and two Swift Testing transcription suites. The app and UI
targets remain separate Xcode test targets. Host tests do not override XCTest
setup/teardown, use XCTest expectations, `measure`, or attachments. Their
performance tests use explicit elapsed-time bounds and `perf-summary` output.

A pre-publication source check of main at `28daa1fb` found 37 core XCTestCase
suites / 467 methods and the same two Swift Testing transcription suites. The
root package manifest, dependency pins, `scripts/test-core.sh`, transcription
tests, and `ChapterTranscriptCache` implementation are unchanged from the tested
revision. The runner finding remains current. Initial and rebased validation
results are distinguished below.

The isolated package imports the real BleatCore product without linking any of
the root package's test targets. Its runner copies the root package's generated
`Package.resolved` and uses `--force-resolved-versions`, so transitive dependency
drift does not confound the comparison. It contains seven independently named
tests:

| Test | Behavior exercised |
| --- | --- |
| `synchronousIdentity` | Synchronous domain equality |
| `typedThrowingValidation` | Exact typed URL-validation failure |
| `bundledFixture` | Resource lookup, throwing fixture decode, normalized URLs |
| `concurrentActorCalls` | 100 task-group calls to an isolated actor |
| `intentionalSkip` | Disabled trait, with a body that fails if incorrectly run |
| `swiftDataAccountIsolation` | Real cache write/read across actors; another account remains empty |
| `timedTranscriptRoundTrip` | 10,000 segments through the real SwiftData cache with structural equality and elapsed-time bounds |

The SwiftData fixture is in-memory with CloudKit explicitly disabled. No Contacts
APIs are called by the prototype. No permissions, private defaults, message
filters, or framework hooks are used. The timing case demonstrates portable
timing assertions, not equivalence to the existing 10,000-book benchmark or an
XCTest performance baseline. No existing tests were converted or removed.

## Diagnostic evidence

LLDB observes entry to `+[XCTestCase(RuntimeUtilities) _allSubclasses]`,
`+[CNContactStore initialize]`, and `-[NSXPCStoreConnection initForStore:]`.
Breakpoints automatically continue; backtraces and final hit counts are retained.
`image list -b` records loaded frameworks without publishing local paths.

| Process | Instrumentation | XCTestCore loaded | Discovery hits | Contacts initializer hits | XPC-store initializer hits |
| --- | --- | --- | ---: | ---: | ---: |
| Existing BleatCoreTests at `c00b05b0`, XCTest runner | Ordinary | Yes | 1 | 3 | 4 |
| Existing BleatCoreTests at `c00b05b0`, XCTest runner | Coverage | Yes | 1 | 3 | 4 |
| Isolated prototype, default XCTest runner | Ordinary | Yes | 1 | 1 | 0 |
| Isolated prototype, default XCTest runner | Coverage | Yes | 1 | 1 | 0 |
| Isolated prototype, Swift Testing helper | Ordinary | Yes | 0 | 0 | 0 |
| Isolated prototype, Swift Testing helper | Coverage | Yes | 0 | 0 | 0 |

The prototype's default runner executes zero XCTest cases **and then all seven
Swift Testing tests**. Zero XCTest cases do not mean discovery was avoided.
The Contacts backtrace goes through ContactsUICore, Swift metadata realization,
`objc_copyClassList`, and XCTest's subclass discovery. The existing suite's
XPC-store backtrace goes through ContactsPersistence's
`CNPersistentStoreBuilder addRemoteStoreWithURL:options:`. These are framework
side effects, not evidence of a failed Bleat store.

Ordinary and coverage host logs both reproduce `Failed to create NSXPCConnection`
on this host. The shorter prototype records no XPC-store initializer hits; that
does **not** prove it eliminates asynchronous Contacts retries. The positive
discovery/Contacts hits already disprove the proposed automatic benefit. Tests
were not shortened, sharded, or kept alive artificially to alter warning timing.
Normal CoreData maintenance messages remain visible.

Direct helper-launch troubleshooting initially used a bundle directory instead
of its executable, then omitted runtime library search paths and the
`--testing-library swift-testing` argument. Those crashed or zero-test launches
are excluded from evidence. The supplied runner uses the corrected invocation
and rejects debugger runs without a successful inferior exit and seven tests.

## Migration feature map and possible batches

Apple's [migration guide](https://developer.apple.com/documentation/testing/migratingfromxctest)
documents assertions, traits, lifecycle, and concurrency differences. Its
[XCTest guidance](https://developer.apple.com/documentation/xctest) retains
XCTest for UI automation and performance APIs.

| Repository usage | Migration treatment |
| --- | --- |
| Equality, nil, ordering, booleans | `#expect`; retain structural comparisons and diagnostic context |
| Floating-point `accuracy:` | Explicit absolute-error bound; preserve the existing tolerance |
| `XCTUnwrap`, `XCTFail`, typed throw assertions | `try #require`, `Issue.record`, `#expect(throws:)`; retain typed causes |
| Throwing and async test methods | Throwing/async `@Test`; preserve actor isolation and explicit concurrency tests |
| Private fixture helpers and Bundle.module | Keep local fixtures and versioned resources; demonstrated by prototype |
| `XCTSkip` after entitlement or live-environment checks | Do not replace with successful early returns. Use preflight condition traits where possible; runtime cancellation needs separate toolchain and reporting verification |
| XCTest setup/teardown and expectations | No core-host usages to convert. App/UI usages stay on XCTest; future conversions require per-test initialization/cleanup and async confirmations with verified completion semantics |
| Manual performance bounds | Preserve workloads, clocks, thresholds, and summaries; serialize performance suites to prevent default parallelism from changing meaning |
| XCTest measurement APIs / attachments | No core-host usage. App/UI attachments and XCUITest behavior remain in their Xcode targets |

Proceed in five reviewable batches: (1) identifiers/URLs/routes/policies;
(2) API/authentication/transport tests and fixtures; (3) actor-based playback,
progress, bookmarks, downloads and telemetry; (4) SwiftData, migration and
performance suites; (5) entitlement-dependent Keychain cases and the final
host-runner switch, retaining the separate live XCTest workflow. Subdivide large
files such as API and private-cloud-sync tests rather than converting hundreds of assertions in one
review. Default parallelism, shared process state, timing bounds, and runtime
skips require behavioral review, not search-and-replace.

Each batch must retain every test identity/outcome and assertion, pass the
complete `scripts/test-core.sh` gate, and run disposable live suites if their
contracts change. Default mixed-runner execution cannot establish discovery
removal; verify the explicit runner on the complete converted host workload.

Transitional retention: core XCTest suites remain until their conversion and
execution verification are complete. Live XCTest suites retain environment-dependent
skips and the disposable-server workflow; simulator app tests retain their hosted Apple
API coverage and attachments; XCUITest retains required UI automation APIs.
No app-hosted test is claimed inherently impossible to migrate merely because
it runs in an app process.

## Reproduction and validation

From the repository root, run:

```sh
python3 -m unittest discover -s TestSupport/SwiftTestingPrototype -p test_verify_results.py -v
BLEAT_PROTOTYPE_TRACE=1 TestSupport/SwiftTestingPrototype/run.sh
./scripts/test-core.sh
```

Omit `BLEAT_PROTOTYPE_TRACE=1` for just the four ordinary/coverage ×
default/Swift-Testing-only runs. Results stay under
`TestSupport/SwiftTestingPrototype/.build/evidence`. Review raw logs locally;
they can include local paths. Do not publish them without redaction. The XML
verifier requires all seven distinct identifiers, six passes, and exactly the
intentional skip; missing, duplicate, failed, and unexpectedly skipped cases
fail validation. Aggregate XML counts are not trusted: this Testing version
reports `tests="6"` despite listing seven cases including the skip.

The same `trace.lldb` can inspect the root core bundle with
`xcrun lldb --batch -s TestSupport/SwiftTestingPrototype/trace.lldb -- "$(xcrun --find xctest)" .build/debug/BleatCoreTests.xctest`
after ordinary and coverage host builds. This runs the complete core suite.

Initial validation at `c00b05b0`: ordinary and coverage root runs each execute 464 core
tests (463 passed; the iCloud-Keychain entitlement case skipped), 21 live-target
tests (3 local checks passed, 18 fixture-dependent cases skipped), and five
transcription tests. These host runs are not disposable-server integration or
device evidence. Seven verifier regression tests pass. The reproducible matrix
and its four debugger runs each confirm all six runnable prototype tests pass
and the intentional test is skipped. The initial simulator app result bundle
confirms 402 tests passed with no failures or skips.

The initial full gate did not pass: UI test
`testContextDownloadAndRemovalAreMutuallyExclusive` failed at
`Tests/BleatUITests/BleatUITests.swift:1053` because it expected a Download action
for an already-downloaded book. Main already corrected that stale expectation
by removing the download first. The superseded UI run was interrupted after
retaining its failure evidence (gate exit 75). No product or existing test fix
was added to this change; the branch was rebased onto `28daa1fb` for a fresh
ordinary host run, prototype matrix, and full gate.

Rebased validation at `28daa1fb`: ordinary and coverage host runs each execute
467 core tests (466 passed, one entitlement-related skip), the same 21
live-target tests (three passed, 18 fixture-dependent skips), and five passing
transcription tests. The Release build passes. All four prototype runs verify
six passes and one intentional skip, and all four debugger runs retain the hit
counts in the table.

The rebased full gate exits 65 at the app stage. The result bundle contains 422
individual app tests: 418 passed, four failed, no skips. A single focused rerun
of all four also exits 65, with one pass and three failures:

| AppModelTests case | Full gate assertion | Focused rerun |
| --- | --- | --- |
| `testAllLookaheadCreatesAndPromotesManualDownloadsThatSurviveCleanup` | Scheduled indexes `[]` instead of `[1]` | Passed |
| `testAutomaticCachedDownloadUsesPersistedAccessWhileOffline` | Playback request count 0 instead of 1 | Failed |
| `testPlaybackStartExcludesIncompleteAndUsesAutomaticCachedWindow` | Playback request count 0 instead of 1 | Failed |
| `testThreeHundredTrackDownloadRepairAndPublicationStayResponsive` | Scheduled indexes `[150, 150]` instead of `[150]` | Failed |

Both bundles were inspected for exact identifiers and individual outcomes. The
rebased UI stage was not reached. Neither full-gate attempt is represented as
a pass, and the earlier 402 passing app tests do not validate the newer main
revision. No disposable live-server suite or physical-device validation ran.

Read-only review found a concrete scheduling race in the two playback-count
assertions: `PlaybackModel.prepareStreamingContinuation` launches an unstructured
task, while the tests inspect service calls immediately after playback starts.
The lookahead test samples running/suspended background URLSession tasks after
resuming a request, so task-state timing is a plausible explanation for its
intermittent result. The repair test mixes manual completion with a real
background task and asynchronous reconciliation; distinguishing an observation
race from duplicate scheduling requires further task/callback evidence. These
last two causes remain unproven. The prototype is not in the root test graph,
and this change modifies no app source, existing test, root manifest, or gate.
The baseline failures remain follow-up validation issues rather than evidence
of a Swift Testing regression.

An earlier matrix invocation was superseded after editing the running shell
script caused a parse error at its end; the finalized script was rerun from
start to finish successfully, including after the review fix. Review identified
one P3 fixture-bounds failure path: a throwing `#require` assertion now prevents
indexing an undersized decoded fixture. Re-review found no outstanding P0–P3.

The UI runner also emitted Xcode `IDELaunchParametersSnapshot` debugger-version
lookup / `noURL` warnings. Their tooling cause remains unresolved in this
evaluation; they are recorded separately from test outcomes and were not
suppressed or worked around.
