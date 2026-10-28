# Listening records and local CloudKit storage

[Issue #355](https://github.com/terminaloutcomes/bleat/issues/355) tracks implementation and remaining device evidence. The implementation and signed-phone migration have been validated. Bidirectional synchronization was verified between an iPhone running 2026.10.14 and an iPad running Bleat 0.1.3.

## Evidence and cause

A private physical-device extract on 2026-10-14 contained 58,404 CloudKit metadata entries occupying 140,473,565 bytes. Listening slices accounted for 58,008 entries and 135,814,078 bytes. The recorder finalized every five seconds (approximately 720 records per listening hour); imported server sessions use a separate record type. Count alone does not establish duplicate history. Raw extracts contain personal data and are never repository fixtures or public attachments.

The old fetched/sent batch boundary archived every cached CloudKit record into UserDefaults. Those system fields are synchronization data, not preferences. The refactor stores individual metadata rows in the existing local SwiftData store and persists only changed rows or deletions. Account/zone/record identity and server change tags are retained; unresolved legacy ownership must not be guessed from titles or remote IDs.

## Recording and mixed versions

A continuous audible segment has one stable event identity. Five seconds is a durable save interval, not a segment-length limit. End time, position, real listening seconds, and audiobook seconds grow in the same row. Pauses, buffering, seeks, account/book/session changes, rate/chapter changes and reporting-day boundaries finalize the segment. Actual observed advancement determines listening time; wall-clock gaps and seeks add none.

Only finalized records are uploaded. Published listening records remain immutable so clients that insert by event identity continue to read them correctly. Lifecycle synchronization first finalizes local segments; subsequent playback begins another segment. Another device cannot see the active segment until finalization and synchronization. The confirmed canonical migration below replaces older records under deterministic identities before retiring their originals.

After interruption, persisted active progress becomes one finalized segment under the same identity without carrying monotonic samples across launches. Incremental summaries append only newly observed contributions from a growing row, never its whole cumulative total repeatedly. Delayed or retired samples cannot extend older finalized records.

## Migration and execution boundary

Freeze the existing schema and add a lightweight versioned upgrade. CloudKit starts only after the legacy metadata/state import finishes. Browsing and playback do not await this migration. Import batches are idempotent and verified before source preference keys are removed; failed or interrupted imports retain the source. Compare decoded structured state structurally. Intentional exact byte comparisons verify faithful storage of opaque secure archives, synchronized hash identities and retained wire payloads during migration; they do not decide semantic application or CKRecord equality.

The user explicitly approved synchronous native SwiftData fetch/save on the owning persistence actor for issue #355. ModelContext has no native asynchronous transaction API. Blocking occurs only during the actor's native ORM operations, never through a main-actor/semaphore/dispatch fallback. Replace this boundary if SwiftData gains native async transactions. Regression coverage must exercise the exceptional boundary, preservation and bounded writes.

Metadata, engine state, pending conflicts, identity mappings and deletion ledgers are data in SwiftData. Pending uploads retain their complete payload until CloudKit confirms the save, so retries and later batches can reload it after memory-cache eviction or relaunch. Confirmed statistics discard that redundant payload; their authoritative history remains in the statistics rows. The synchronization-enabled setting and the one-time upgrade-notice acknowledgment remain device-local preferences. CloudKit remains the cross-device transport; this is not automatic SwiftData-to-CloudKit synchronization.

## Upgrade notice and required evidence

Successful legacy reconciliation queues a native **Cloud storage update** notice. New finalized payloads carry an optional continuous-segment format marker; absent markers identify legacy history without proving that an outdated device is currently running. The UI observes persisted detection independently of an ongoing catch-up. Native notifications may arrive on an arbitrary executor and explicitly hop to MainActor. Consent is retained once per installation across accounts/relaunches. The minimum client version is fixed to the introducing release. The notice does not block ordinary synchronization; its explicit conversion consent gates retirement as described below.

Required evidence includes shipped-schema migration, source retention on failures, crash/retry, stable checkpoint identity and exact totals, immutable older-client payloads, duplicate delivery, alert acknowledgment, and a 200-record mutation against a synthetic 58,404-record store. Signed-device migration preserved all 58,008 local listening records, 17 completions and 376 remote-session identities/account ownership, and moved 58,404 metadata entries into SwiftData. The preferences domain fell from 140.6 MB to 4.3 KB. The host inspection of device copies emitted an older-persistence-framework warning. Mixed-version testing verified one 23.5-second finalized phone segment on the iPad and four legacy iPad slices totaling 16.8 seconds on the phone, with identities, account ownership, timestamps, positions and listening totals unchanged. The original 58,008 phone slices and 22,033 iPad slices remained unchanged. The older iPad was still catching up on other historical records; the evidence is the specifically matched bidirectional records, not a claim that its whole catch-up finished. Native UI tests cover explicit confirmation and Later across foreground transitions and relaunch; the physical phone retained its acknowledgment flag. Battery attribution is unmeasured.

The earlier reminder-only confirmation did not convert listening history. That
behavior is distinct from the new canonical migration consent and is not reused
as permission to retire originals. The historical device evidence above proves
the metadata migration only, not the canonical conversion below.

## Canonical history conversion

The proposed introducing release is **2026.10.27**; its release metadata must be
assigned and validated before distribution. No release or production migration
is evidence for this work. The revised notice offers **All devices updated —
convert history** and **Later**. It explicitly describes conversion and verified
removal, requires every device to support the introducing release, and stores a
new installation-local v4 consent. Earlier OK and v3 reminder acknowledgments do
not enable conversion. Later leaves detection pending across foreground/relaunch.

Legacy observations already contain wall timestamps, media endpoints, measured
real/audiobook totals, rate, session and chapter metadata. They can use the
existing continuous-segment model without reconstructing raw player samples.
One shared codec, continuity predicate and logical resolver serve local payloads,
CloudKit, import/export and statistics. CloudKit keeps the existing ListeningSlice
record type and opaque payload field. The optional versioned lineage extension
contains source UUIDs, measured contributions and semantic proof hashes, not
five-second timestamps or media positions. It prevents overlapping device packs
from counting sources twice. A version-2 export includes reset metadata; old
readers must reject it rather than miscount packed history.

The trial wall adjacency tolerance is 0.5 seconds. Integer microsecond comparison
ticks discard representational noise only; stored timestamps and measured totals
are unchanged. Media endpoint tolerance is independently 0.001 seconds for stored
observations. Known pause, seek, rate, account, book, session, chapter and metadata
boundaries remain hard boundaries, as do UTC reporting days. Unknown sub-half-second
pauses in historical endpoint-only data cannot be distinguished from recorder
latency; joining headers never credits that gap as listening or audiobook time.
Sub-day queries retain continuous-segment start-date semantics and cannot recover
old five-second allocation. A custom reset cutting a compacted segment is rejected
with an explicit wider-range message; no extra history is silently deleted.

Envelopes have at most 1,024 sources and a 768 KiB payload reserve. Oversized groups
split recursively, down to the existing scalar singleton path. Native conversion
persists at most 8,192 candidate observations per synchronization pass; originals
remain durable and retries exclude already represented sources. Logical readers
deduplicate original/replacement coexistence. A fetched replacement is not a save
receipt: cleanup requires a digest of the exact canonical bytes actually saved,
matched against the current local payload. Pending cleanup survives restart.

Reset actions and compact source anchors persist independently of physical
cleanup. Supplements are saved locally before a bridge is dropped, and cloud
cleanup additionally waits for their actual upload receipts. Unknown/corrupt
versions or conflicting proofs preserve records and return a typed stage/cause.
The upload provider rechecks current native ownership and existence; prepared
generation checks reject reset/rekey races, and late save callbacks enqueue
compensating cleanup. Zone creation does not flush queued saves before the remote
fetch. An uncovered canonical physical deletion repairs from authoritative local
history; a complete fetch alone is not proof of replacement coverage.

Account-wide removal first saves and verifies reset envelopes, excludes them from
ordinary deletion, and retains them through account re-add, rekey and history
export/import. Minimal suppression metadata is intentionally retained; deleting
the entire cloud zone deletes its remote copy until retained local reset metadata
is synchronized again. This implementation has only
disposable-store/fake-record evidence so far. Signed two-device recovery, actual
CloudKit storage savings and battery impact remain unverified.

Removing history on this device instead clears local observations without
creating a global reset. It first drains synchronization and installs account
suppression so an in-flight fetch cannot refill the erased history. Explicit
password/OIDC authentication on re-add clears suppression and resets fetch state
for replay, retaining remote reset anchors received while the account was
ignored. Account-scoped persisted protocol participation distinguishes transported
canonical records from unsent local roots. Callback admission occurs before the
delegate's first suspension; transitions reject new old-engine callbacks and
drain admitted callbacks and owned, coalesced cancellation tasks before changing
ownership/fetch state. Cancellation entries use unique tokens so a late waiter
cannot release a replacement task. Generation checks
reject retired state writes, and central initialization/send/provider guards
prevent an unrelated configuration action from recreating a retired engine.

## Candidate validation scope

The final canonical codec's synthetic fixture converts 58,008 observations from
18,648,945 JSON payload bytes to 58 envelopes and 5,016,115 bytes (about 73% fewer
payload bytes). This measures the candidate format, not a user's history or
CloudKit billing, indexes, disk pages, network traffic or battery. Native
conversion is bounded per pass; its eventual physical count depends on actual
sessions, boundaries and device subsets. Temporary replacement/cleanup state can
increase storage until saves and deletions are confirmed.

The isolated acceptance suites cover native receipt/restart recovery, legacy
replay, overlapping device subsets, exact local/CloudKit/local payload transport,
fractional measured quantities, corrupt/unknown versions, missing optional native
metadata, reset/upload races, account rekey, ignored-account reset protection,
local-only erasure and explicit re-add. Intentional byte comparisons bind payload
receipts and transport to exact bytes; semantic comparisons use parsed values.
The four native confirmation UI journeys and two app-model confirmation tests
passed on a task-owned iOS 27 Simulator with unsigned builds and no runtime
warnings in those result bundles. Their retained artifacts are
`.build/canonical-consent-ui.xcresult` and `.build/canonical-consent.xcresult`.

The broad unsigned app-unit/UI attempt is retained at
`.build/canonical-broad.xcresult`. Its app-unit portion encountered six
Keychain failures in its unsigned host; the separately authorized Simulator
rerun is recorded below rather than silently replacing that evidence. The
affected tests use synthetic credentials and UUID-scoped services; storage
fixtures use temporary stores with CloudKit disabled. No actual
CloudKit history operation is evidence for this candidate. Final gate results
and source scope must accompany review; the earlier metadata/device evidence
above does not establish canonical migration safety on devices.

The retained candidate is an uncommitted worktree based on
`76492149b0c8a5fd708d2ac095f8890e201541fb`; no release metadata was bumped.
Final isolated Core acceptance passed **137 tests in seven suites**, including
held runless cancellation and an intervening replacement-task ownership race
(`.build/canonical-acceptance-final.log`). The final unsigned Simulator compile,
strict Swift lint and schema consistency checks passed. The latest presentation
regression additionally preserves an account-migration segment failure through
the UI cause and exact diagnostic stage
(`.build/canonical-account-error.xcresult`, one pass, no runtime warnings).

The isolated app/UI bundle `.build/canonical-final-isolated.xcresult` contains
**679 app-unit passes and five UI passes**, no failures, skips or runtime
warnings. Its six entitlement cases were explicitly excluded pending separate
signing authorization at that time, not counted as passes. This run preceded the final
teardown-only correction and the additional typed-error regression; the former
is covered by the final Core acceptance/compile, the latter by its own bundle.

The unsuccessful broad attempt's console reported 685 app-unit cases (six
Keychain-entitlement failures) and 132 UI cases (124 passes, seven gated skips,
one failure). The UI failure was the unchanged
`testPartialTranscriptExportExplainsCoverageBeforeSharing`: its system share
sheet's **Save to Files** cell did not appear within three seconds. This remains
pre-existing on the unchanged base in a bounded comparison; a fresh candidate
build passed the same assertion without source or timeout changes. The exact
native share-service readiness mechanism remains unresolved. The comparison is
retained in `.build/transcript-diagnosis.json`; these later results do not turn
the unsuccessful broad gate into a pass. After assertions finished,
Xcode did not finalize the bundle and exceeded the supported runner's one-hour
native execution budget. Its post-test operation dump includes coverage-profile
collection/merge. Only this task's build process was interrupted and then
terminated (exit 143). Console/operation evidence remains in
`.build/canonical-broad.log`; `.build/canonical-broad.xcresult` remains staged
without `Info.plist`, so its console counts are not structured-result verification
and this broad gate is not passed.

After explicit test-host signing approval, the six previously failing cases
passed on the final source: three account removal/reset lifecycle tests and
three Keychain persistence/device-only policy tests. The finalized
`.build/canonical-signed-six.xcresult` contains exactly six passes, zero failures,
zero skips and no runtime warnings; individual identifiers and summary are
retained in `.build/canonical-signed-six-tests.json` and
`.build/canonical-signed-six-summary.json`. All 27 retained source fingerprints
matched before and after execution. Although the command requested the existing
Apple Development identity, Xcode selected Simulator **Sign to Run Locally**:
the inspected host has an ad-hoc signature, no team identifier and an empty
entitlement dictionary. These are passing Simulator Keychain behavior tests,
not provisioned development-certificate, synchronizable-Keychain device or
production-cloud evidence. No additional signing operation was needed or run.

Earlier incremental compile/test failures were superseded after correcting the
SwiftData optional sync predicate, a throwing-expression/type-checking issue,
cross-module lifecycle API visibility, typed catch propagation, a test that read
the pending-upload archive instead of retained history, and the model-catalog
declaration layout. The final successful checks above include those corrected
paths. The pinned OpenTelemetry manifest still emits its existing deprecated
watchOS-target warning; Xcode skips App Intents metadata extraction because that
framework is not a dependency. Read-only-store failure fixtures intentionally
emit native save errors while verifying retention/retry. None is signed-device
or production-cloud evidence.

### Approved test-only audit reconciliation

After explicit approval on 27 October, the overlap regression now requires its
single-group precondition before indexing. The concurrent cancellation-waiter
regression observes bounded completion before joining operation/cleanup tasks,
releases all held probes and cancels owned wrappers on exit. Independent source
review found no further concern in those two deltas. Cancellation cannot force
a deliberately broken noncooperative task to finish; the test reports bounded
failure rather than joining an unobserved completion.

The affected unsigned host run passed **81 declared tests in two suites**:
16 `ListeningContinuityPolicyTests` functions and 65 `PrivateCloudSyncTests`
functions. All four gap arguments and ten explicit-boundary arguments executed
and passed, giving 93 concrete invocations including the 79 nonparameterized
functions. The log is `.build/canonical-audit-focused.log`; no test was skipped
or failed. The existing pinned OpenTelemetry watchOS-target deprecation warning
remains. `testFailedPendingStateSavesPreserveRetryState` deliberately emits
SwiftData `NSCocoaErrorDomain` 513 save failures while asserting retained retry
state; these are controlled read-only-store fixture outcomes, not a newly
discovered environment permission failure.

The 22 new migration functions now have individual nine-rule audit records and
source-index entries, retaining the historical reviews and stating precise
limits: local CKRecord transport, actor versus disk/process recreation,
synthetic frozen-schema migration, helper versus SDK callback delivery and
error-type versus exact-cause assertions. Audit/index parity passed for 642
host functions and 47 scoped Rust functions
(`.build/canonical-audit-inventory-final.log`). This check validates inventory
parity, not semantic correctness or execution. Strict lint, documentation
references and diff checks also passed. The earlier approval rejection and
audit failure remain preserved; the single newly authorized format/test retry
was accepted and completed.

These changes affect only the two host-test bodies and audit/documentation
records. The earlier combined candidate passed 686 app-unit tests and 125 UI
tests with seven approved prerequisite skips and no failures/runtime warnings.
Its original UI bundle finalized and exact discovery was independently verified
despite loss of the outer runner's exit status. That orchestration anomaly
remains unresolved; no broad suite was repeated for the test-only audit changes.

For publication, this migration is stacked on the current #480 head
`89c58cefa98d42cead73bb04be8fc24b0f67ca95`. The rebase adds only #480's
release-procedure documentation; production and host-test inputs match the
retained validation fingerprints. The standalone share-readiness fix is
intentionally excluded from this PR. Consequently, the earlier combined UI
receipt is not an exact published-head claim: reconcile the dependency with the
separate share fix and repeat the final owning UI gate before merge. Full
signed-host, actual CloudKit/multi-device and physical-device evidence remain
separate. No release or migration of actual user history was performed.

### CI portability and coexistence scaling correction

The first published head's unsigned host run on Xcode 26.6 terminated with
`NSInvalidArgumentException: keypath recordingFormat not found in entity
ListeningSliceRecord` during canonical preparation. The retained
`.build/migration-ci-host-failure.log` and original Actions run preserve that
failure. Preparation now queries only the primitive finalized-state property
and compares the materialized Codable enum in Swift. No schema or frozen-store
definition changed. The supported older runtime need not expose a Codable enum
as a SQL attribute; a Swift property declaration alone does not prove that
predicate is safe.

A representative native fixture also exposed repeated aggregate reconstruction
in overlap resolution. Its first diagnostic run was interrupted (exit 130),
still in the second of three preparation passes after about nine minutes of
full-CPU execution. It contained 8,194 pending observations, two represented
legacy observations, a replacement, and current/active rows. The one-second
owned-process sample is `.build/canonical-enum-stall-sample.txt`; this was not
a completed measurement or an extrapolation to 58,000 observations. Independent
review also caught a new helper's changed default; the legacy recording state
is again optional `nil`, with explicit finalized state only for current-format
fixtures. The interrupted attempt is not counted as passing coverage.

The shared resolver now indexes account/source identities, joins overlapping
components and materializes each final component once. It caches portable
session normalization and retains the prior header order through an iterative
merge tree. A shared bounds-summary check still rejects each invalid
intermediate merge before a later bridge could conceal it. Metadata conflicts
precede contribution conflicts for an input with multiple invalid shared
sources. Exact source proofs, deterministic quantity summation, identity
hashing, canonical encoding and reset resolution remain the same.

Final local unsigned acceptance passed **139 declared tests in seven suites**
in 45.797 seconds (`.build/canonical-resolver-final-acceptance.log`). The native
8,194-pending fixture completed all three passes and preservation assertions in
14.724 seconds. Actual resolution of 58,008 sources with original rows and
duplicate replacements took 6.746 seconds, preserving 290,040 real seconds,
435,060 audiobook seconds and exact unique-source cardinality. The encoded
fixture remains 58 envelopes / 5,016,115 bytes. These are measured observations,
not low-CPU or short-duration pass requirements. Whole-command profiling
reported 66.13 seconds elapsed and 857,653,248 bytes maximum resident size,
including build/test infrastructure; this is not an app-memory measurement.

The new regressions retain account separation, exact typed metadata/proof/bounds
rejection, malformed intermediate bounds despite a later spanning bridge, and
context-before-proof priority under reordered delivery. Native mutation remains
limited to 8,192 eligible observations per pass after represented-source
filtering; total history reads are not bounded. The fixture was not shrunk and
no duration threshold was inflated. Actual app responsiveness during migration,
signed-device behavior and live multi-device CloudKit remain separate evidence;
the concurrent standalone share-sheet UI run is not proof of migration UI
responsiveness.
