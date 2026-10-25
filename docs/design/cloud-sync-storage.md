# Listening records and local CloudKit storage

[Issue #355](https://github.com/terminaloutcomes/bleat/issues/355) tracks implementation and remaining device evidence. The implementation and signed-phone migration have been validated. Bidirectional synchronization was verified between an iPhone running 2026.10.14 and an iPad running Bleat 0.1.3.

## Evidence and cause

A private physical-device extract on 2026-10-14 contained 58,404 CloudKit metadata entries occupying 140,473,565 bytes. Listening slices accounted for 58,008 entries and 135,814,078 bytes. The recorder finalized every five seconds (approximately 720 records per listening hour); imported server sessions use a separate record type. Count alone does not establish duplicate history. Raw extracts contain personal data and are never repository fixtures or public attachments.

The old fetched/sent batch boundary archived every cached CloudKit record into UserDefaults. Those system fields are synchronization data, not preferences. The refactor stores individual metadata rows in the existing local SwiftData store and persists only changed rows or deletions. Account/zone/record identity and server change tags are retained; unresolved legacy ownership must not be guessed from titles or remote IDs.

## Recording and mixed versions

A continuous audible segment has one stable event identity. Five seconds is a durable save interval, not a segment-length limit. End time, position, real listening seconds, and audiobook seconds grow in the same row. Pauses, buffering, seeks, account/book/session changes, rate/chapter changes and reporting-day boundaries finalize the segment. Actual observed advancement determines listening time; wall-clock gaps and seeks add none.

Only finalized records are uploaded. Published listening records remain immutable so clients that insert by event identity continue to read them correctly. Lifecycle synchronization first finalizes local segments; subsequent playback begins another segment. Another device cannot see the active segment until finalization and synchronization. Previously published slices remain unchanged.

After interruption, persisted active progress becomes one finalized segment under the same identity without carrying monotonic samples across launches. Incremental summaries append only newly observed contributions from a growing row, never its whole cumulative total repeatedly. Delayed or retired samples cannot extend older finalized records.

## Migration and execution boundary

Freeze the existing schema and add a lightweight versioned upgrade. CloudKit starts only after the legacy metadata/state import finishes. Browsing and playback do not await this migration. Import batches are idempotent and verified before source preference keys are removed; failed or interrupted imports retain the source. Compare decoded structured state structurally. Intentional exact byte comparisons verify faithful storage of opaque secure archives, synchronized hash identities and retained wire payloads during migration; they do not decide semantic application or CKRecord equality.

The user explicitly approved synchronous native SwiftData fetch/save on the owning persistence actor for issue #355. ModelContext has no native asynchronous transaction API. Blocking occurs only during the actor's native ORM operations, never through a main-actor/semaphore/dispatch fallback. Replace this boundary if SwiftData gains native async transactions. Regression coverage must exercise the exceptional boundary, preservation and bounded writes.

Metadata, engine state, pending conflicts, identity mappings and deletion ledgers are data in SwiftData. Pending uploads retain their complete payload until CloudKit confirms the save, so retries and later batches can reload it after memory-cache eviction or relaunch. Confirmed statistics discard that redundant payload; their authoritative history remains in the statistics rows. The synchronization-enabled setting and the one-time upgrade-notice acknowledgment remain device-local preferences. CloudKit remains the cross-device transport; this is not automatic SwiftData-to-CloudKit synchronization.

## Upgrade notice and required evidence

Successful legacy reconciliation queues a native **Cloud storage update** notice. New finalized payloads carry an optional continuous-segment format marker; absent markers identify legacy history without proving that an outdated device is currently running. The UI observes the persisted detection flag independently of the ongoing CloudKit sync, so a long cloud catch-up cannot delay the notice. Native notifications may arrive on an arbitrary executor and explicitly hop to MainActor. Acknowledgment is retained once per installation across accounts/relaunches. The minimum client version is fixed to the introducing marketing release, not the current version of a later update. The notice never blocks synchronization or deletes history.

Required evidence includes shipped-schema migration, source retention on failures, crash/retry, stable checkpoint identity and exact totals, immutable older-client payloads, duplicate delivery, alert acknowledgment, and a 200-record mutation against a synthetic 58,404-record store. Signed-device migration preserved all 58,008 local listening records, 17 completions and 376 remote-session identities/account ownership, and moved 58,404 metadata entries into SwiftData. The preferences domain fell from 140.6 MB to 4.3 KB. The host inspection of device copies emitted an older-persistence-framework warning. Mixed-version testing verified one 23.5-second finalized phone segment on the iPad and four legacy iPad slices totaling 16.8 seconds on the phone, with identities, account ownership, timestamps, positions and listening totals unchanged. The original 58,008 phone slices and 22,033 iPad slices remained unchanged. The older iPad was still catching up on other historical records; the evidence is the specifically matched bidirectional records, not a claim that its whole catch-up finished. Native UI tests cover explicit confirmation and Later across foreground transitions and relaunch; the physical phone retained its acknowledgment flag. Battery attribution is unmeasured.

The upgrade notice offers **All my devices are updated** and **Later**. Confirmation
records only this installation's acknowledgment; Bleat does not infer remote
device versions or start a new cloud-history rewrite. Local sync-metadata
migration is already automatic, verified, and restartable. Legacy listening
slices remain immutable: their original playback samples are unavailable, so
relabeling them as continuous segments would misrepresent how they were recorded.
Later preserves the pending notice for a subsequent foreground or relaunch.
Neither choice changes existing history or older-client compatibility.
