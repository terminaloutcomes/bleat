# Cover freshness and retained asset policy

Issue [#400](https://github.com/terminaloutcomes/bleat/issues/400) tracks the
reported old cover after restart and old-to-new Continue Listening transition.
The original device sequence and unexplained recovery have **not** been
reproduced. Source inspection confirms an independent mechanism: before this
change, an account/full-URL memory or disk hit permanently bypassed the server,
including online loads. Timestamp-only URLs could therefore retain bytes after
an external or in-app replacement with unchanged `updatedAt`. Cancellation also
lacked an ownership check before committing a completed image request.

The pinned server [cover controller](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/controllers/LibraryItemController.js)
uses `ts` to set a private 24-hour HTTP cache header, rather than select historical
image content. Its [rendered-cover cache](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/managers/CacheManager.js)
is independently keyed by item/dimensions/format; the pinned
[upload owner](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/managers/CoverManager.js)
awaits that cache’s purge. This is distinct from Bleat’s own permanent cache hit;
server-side stale rendered bytes have not been demonstrated in this report.

## Cover ownership and policy

`BookCoverURL` remains the route builder, retaining the server path prefix and
size/format/`ts` query. `BookCoverImageLoader` owns custom memory and disk caches;
HTTP requests bypass local URLCache. No bearer token is added to cover URLs.

- Resource identity is account + normalized server/prefix/item cover path.
  Variant identity additionally includes dimensions and format. Timestamp and
  transient playback revision identify requests, rather than independent
  permanent image buckets. An older downloaded metadata snapshot can therefore
  use the latest cached variant without restoring obsolete timestamp buckets.
- Online loads validate each variant once per process or refresh generation,
  before returning old disk bytes. Metadata timestamp advances retire older
  requests and publish a replacement generation to restart visible consumers.
  A forced request revision that retires pending work publishes a routine retry
  generation, retaining usable artwork. Successor work is registered before
  notification so restarted consumers can join it. Concurrent callers join one owned request. Only the current owner
  may commit; retired generations cannot return or persist bytes. A caller
  cancelling its view does not cancel another waiter’s shared valid fetch.
- Explicit library/detail refresh, live catalog catch-up and foreground catch-up
  start a revalidation generation. A catalog event for active playback outside
  the selected library also refreshes artwork without reloading the browser.
  Progress-only events keep their narrow path.
  Successful in-app cover saves and retries invalidate every variant of the
  affected account/item before notifying views and active playback. Upload retry
  keeps its operation/account/book ownership through awaited invalidation and
  rechecks it before publishing editor completion. Changing the selected book
  retires only its owned retry and releases the editor's busy state immediately;
  final cleanup checks the token so an older caller cannot clear newer work. Audio player,
  position, intent and queue are unchanged.
- A successfully fetched variant with changed bytes retires sibling variants.
  Exact encoded bytes intentionally identify the rendered variant; a changed
  encoding may cause extra revalidation. This comparison never proves why the
  original device showed stale art.
- Routine refresh retains the displayed image while requesting its replacement,
  including system artwork and CarPlay presentation cache seeds. Transient
  request revisions are excluded from presentation identity; replacement
  generations, canonical timestamps, dimensions and account identity are retained.
  A confirmed replacement, changed timestamp/URL, or account switch hides the
  obsolete presentation. Request identity includes policy and refresh generation;
  a retired view task cannot publish its completion.
- Offline/cache-only loads never fetch. Online failure falls back to a valid
  cached variant, but a known newer timestamp cannot use older bytes. Downloaded
  cards and artwork may revalidate independently of audio playback; a known
  unavailable network uses cache-only artwork. Downloaded audio preparation
  remains independent of cover completion. Network availability changes publish
  a fresh Now Playing snapshot even for paused downloaded playback in background
  or Low Data Mode, without waiting for a catalog event or chapter transition.
- New disk entries use account/resource directories, atomic encoded variant
  files with timestamps, and a timestamp watermark advanced as soon as newer
  authoritative metadata is observed, even on cache-only or failed loads. The
  watermark is published before the payload
  so interruption cannot make an older variant eligible again. A replacement tombstone prevents
  fallback to pre-policy hashed files after replacement. Legacy raw files remain
  readable offline until their resource is validated; no bulk upgrade purge is
  performed. Invalid or oversized entries are misses. Temporary files are never
  lookup targets. Cache failure does not fail playback.
- Limits remain 5 MiB per response, configured 32 MiB/256-image NSCache limits
  and a 128 MiB budget for nonhidden regular payload files, pruned by last use.
  Hidden revision/tombstone files and directory bookkeeping are outside that
  payload total. A failed deletion is reported and does not count as freed
  bytes; pruning continues through other eligible entries. If none can be
  removed, the budget cannot be guaranteed. The OS may remove cache files. Account removal
  retires requests before deleting its cache; item deletion invalidates artwork.
  Sign-out/account lifecycle cleanup retains existing account ownership rules.
- Stable OSLog events record hits, joining, revalidation start/commit/fallback,
  replacement invalidation and obsolete completion rejection, without URLs,
  account IDs, titles or image data.

Home/Continue Listening, Library, Search, Series and detail all render through
`BookCoverView`/`PlayableBookCoverView`. Downloaded Home cards use saved detail;
canonical variant lookup separates artwork freshness from that audio snapshot.
Mini/full player use `PlaybackModel.coverURL`; system artwork uses
`NowPlayingCoordinator` and the same loader. Playback edits retain the existing
random request revision for #377. The coordinator observes cover generations and
keeps its own task-generation check. CarPlay also has a presentation NSCache;
its key and observed presentation include the shared cover generation so that
it cannot bypass invalidation with an old local image. Each CarPlay image request
captures both cache keys before suspension and checks the shared identity again
before installing pixels or seeding a retained presentation.

## Reset Local Data artwork ownership (2026-10-23)

Reset Local Data now retires all cover requests and memory ownership before
removing the loader's entire owned artwork root, including account directories
and legacy orphan files. A cancellation-ignoring fetch cannot return or persist
its retired image. A missing root is already clean; an unavailable root or
failed deletion produces a typed failure with the precise safe disk cause.
This uses the existing approved actor-owned deletion boundary; #411 remains
separate.

Artwork removal follows successful store and credential reset. An earlier store
failure preserves artwork and the signed-in state. If artwork removal then fails,
the accounts and credentials are already gone: the model signs out, reports an
incomplete reset instead of completion, and presents Retry Reset on the login
screen. Login and reset exclude each other, including OpenID login.

The controlled baseline executed two native cases: the cleanup witness failed
six assertions, while the earlier-store-failure preservation control passed.
Current and orphan artwork remained cached and a held old fetch returned its
image. The preceding typed-closure compilation failure executed zero tests and
is retained separately. The five corrected focused cases passed with zero
failures, skips, expected failures or runtime warnings. They additionally cover
actual owned-directory permission failure and successful retry, and both
native/OpenID login/reset admission orders. Independent complete source review
found no remaining issues after correcting task cleanup and concurrent admission.
The first owning run stopped during test discovery with a Simulator Busy launch
error and executed zero tests. The owned Simulator was found shut down and was
booted to a verified ready state. The distinct owning run passed all 638 unique
app tests, including all five new cases, with zero failures, skips, expected
failures or runtime warnings; the supported runner and outer disk guard exited 0.
Exact tested source hashes remained unchanged. Published-head CI is separate.
No physical-device reset or real user-data reset is claimed.

## Other assets: inventory and distinct policies

| Asset / owner | Identity, authority and persistence | Freshness, integrity, limits and cleanup |
| --- | --- | --- |
| Browse metadata / `LibraryRepository`, `LibraryCache` | Account + library/query/item; remote DTOs mapped to domain snapshots in SwiftData | Remote-first with cache fallback; explicit refresh remote-only. Cached snapshots support unavailable servers. No enforced global persistent byte/count cap or universal TTL; replacement/invalidation removes superseded pages and account removal/reset deletes owned records. Cached metadata alone cannot prove image freshness. |
| Saved offline detail / download records | Account + item/download manifest; snapshot accompanies verified local tracks | Audio preparation uses the saved snapshot without requiring the server. Cover freshness is independent. Do not replace verified audio to update a picture. Older persisted shapes have their own typed reconciliation rules. |
| Explicit downloaded audio / `DownloadModel`, `DownloadStorageLayout`, manifest | Account + item/track inode/transfer identity; app-owned media and structured records | Staging, expected byte lengths, validated manifests and atomic finalization; partial/corrupt files require repair. Explicit removal/account removal, never cover TTL or automatic completion eviction. Playing/transcription-pinned files retain existing protection. |
| Automatic audio cache / same owners | Separate `automaticCache` purpose and rolling track window | Window/completion policy, durable local completion timestamp and pin-aware cleanup; default 24 hours after local completion. Valid finalized bytes remain usable offline to window end. No timestamp reset on startup. Explicit downloads are excluded. |
| Ranged-transfer partials / background download adapter and storage | Owned account/track plus expected offset, inode and transfer identity | Bounded chunks and durable byte checkpoints; retire obsolete transfers before replacement. Invalid legacy state is quarantined; late callbacks cannot mutate replacement transfers. Disposable temporary transfer data is distinct from finalized offline media. |
| Playback sessions and temporary streaming / playback engine and session controller | Account/session-scoped remote media routes | Server-session lifetime; close when owned playback ends. These bearer-like routes are never cover-cache keys or persisted diagnostic values. AVFoundation owns its buffering; no new indiscriminate media purge. |
| Transcripts / `ChapterTranscriptCache`, transcription model | Account/item/chapter and source identity; SwiftData segments and job/task state | Reconcile source identity and resumable task state; completed transcript/job/task records persist without an enforced global byte/count cap. Explicit transcript/book/account deletion cancels owned jobs before scoped removal; full reset deletes all persisted transcript/job/task record types. Presentation memory has five-minute idle expiry and inactive-book memory-pressure eviction; durable records remain. An image TTL does not apply. |
| Local positions, preferences, bookmarks, sessions and history / their stores | Account-scoped durable user state and outboxes | These are user records, not disposable asset caches. Preserve ordering, ambiguous mutation state and local position authority. Account removal follows its history-retention choice. Never clear them to refresh artwork. |
| Telemetry retry storage / `RemoteTelemetryRuntime` | Consent-owned storage generation; bounded redacted spans | Bounded retention/export, withdrawal cancels exports and purges the previous generation. Independent of server cover freshness. |

## Storage audit dispositions (2026-10-23)

The inventory records actual retention rather than introducing new limits.
Specification sections 4.4 and 4.5.1 preserve downloaded audio and completed
transcripts; artwork is cache-only offline and may fall back to a placeholder.
No numeric persistent metadata/transcript cap is specified. Adding one would be
a separate product-policy decision, not a missing value to invent for this audit.
Existing `LibraryCacheTests.testInvalidationAndAccountRemovalAreScoped` and
`ChapterTranscriptCacheTests.testRemovingAccountDeletesOnlyItsTranscripts` /
`testRemovingBookDeletesTranscriptAndTaskStateOnlyForExactScope` cover scoped
structured-record cleanup. Sign-out intentionally retains offline data.

Production cover storage uses `Library/Caches/BookCovers`; only test fixtures
override the root. Apple's [file-system guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html)
excludes the Caches directory from backup. Cover writes do not override Data
Protection; Apple's [platform-security guide](https://support.apple.com/guide/security/data-protection-classes-secb010e978a/web)
documents Protected Until First User Authentication as the default for third-party
app data without another assigned class. This supports the expected policy for
an unmodified iOS container; it does not measure actual upgraded-device file
attributes or locked-device access. Downloaded media separately sets backup
exclusion and complete-until-first-user-authentication protection in
`DownloadStorage`. No security-setting change is justified by this source review.

The residual groups in #400 remain distinct:

- **C400-R1:** A cache-only artwork miss after account-ID canonicalization is
  permitted by the offline policy; automatic cross-ID image migration is not a
  specified guarantee. The stronger device-free next check is whether canonical
  account removal also purges its trusted legacy-alias artwork while preserving
  unrelated accounts. Existing same-account raw-format fallback does not prove
  that cleanup.
- **C400-R2:** The existing account-removal/late-response regression already
  proves isolation. Generation/revision maps remain process-owned until full
  reset; no count cap or demonstrated user failure is established. Further
  lifetime measurement is a possible follow-up, not an additional proven bug.
- **C400-R3:** Failed-prune accounting has a reproduced regression and the
  correction below. Replacement invalidation and per-account deletion still
  need their own best-effort-versus-reportable failure dispositions; this is
  not a demand for an invented exhaustive fault matrix.
- **C400-R4:** Current persistent retention and visible-payload limits are now
  explicit. Automatic legacy-hash, hidden-tombstone and empty-directory
  reclamation needs an ownership/anti-resurrection policy before implementation.
- **C400-R5:** Source backup/default-protection evidence is recorded above;
  actual file attributes and any required locked-device evidence remain separate.
- **C400-R6:** Physical system-artwork evidence remains separate as below;
  #377's accepted results and the bounded original observation are preserved.

## Failed-prune accounting (2026-10-23)

The controlled native regression
`CoverCacheLifecycleTests.testFailedPruneDeletionDoesNotConsumeDiskBudget`
seeded three equal, real encoded cover payloads and denied deletion only in the
oldest payload's owned resource directory. Unchanged production code counted
that failed deletion as freed bytes and stopped at an actual 1,359 bytes against
the fixture's 906-byte budget. The exact native case failed only its removable
middle-entry, byte-budget and cold-middle-cache assertions; online pixels,
protected/newest artwork and an outside-root sentinel remained valid.

Pruning now subtracts only successful or already-absent removals, reports genuine
deletion failures through `prune_disk_entry` with the safe typed cause, and
continues the existing oldest-first scan. The corrected exact case passed with
an actual EACCES diagnostic; all 12 owning cover-lifecycle cases passed with zero
failures, skips, expected failures or runtime warnings. Source hashes remained
unchanged. Original RED and corrected native bundles remain in
`.build/cache400-prune-*`; published-head CI is separate. Capacity, hidden-marker
handling and durable offline-asset policies are unchanged. If every eligible
entry is unremovable, the cache cannot guarantee the configured budget.

## Remaining bounded work and acceptance

Diagnosing the original launch glitch would require a recording or controlled
device reproduction with exact build, edit origin, network/download state,
request revision and provenance. It remains explicitly bounded and unproven;
a new recording is useful if it recurs, not a prerequisite to crediting the
confirmed cache fixes. Physical Lock Screen/Control Center and CarPlay head-unit
acceptance at the new tested revision remain separate from simulator tests;
#377's prior user acceptance is retained.

Broader separable audits remain under #400: metadata/transcript storage budgets,
legacy hashed cover orphan reclamation and empty resource-directory and ownership-bookkeeping bounds,
explicit backup/file-protection evidence for cover files, disk I/O failure
observability and native asynchronous filesystem boundaries, and complete
sign-out/account migration/orphan evidence across every retained asset. Existing
cover filesystem I/O is synchronous actor-owned work. The maintainer explicitly
approved retaining this specific reads/writes/pruning/deletion boundary for the
scoped cover fix. Foundation lacks native async durable filesystem mutation
APIs; no queue wrapper is presented as native async I/O.
[Issue #411](https://github.com/terminaloutcomes/bleat/issues/411) owns reconsidering
the executor and awaited completion/cancellation contract, measured responsiveness,
cleanup failures and offline preservation. Its acceptance criteria determine what
would permit replacing the approved boundary; the exception does not extend to
other storage owners. Each follow-on needs
controlled interruption, cleanup-failure and account-isolation evidence for its
own owner; an image policy must not be applied to durable audio or user state.


## Editor completion ownership

Initial metadata/cover saves and cover retries share one operation identity and
target item. Every service response and awaited artwork invalidation must still
own that operation, account, selected item and saving state before publishing
editor state. Account/reset/navigation retirement releases only the retired
operation's busy state; its final cleanup cannot clear a newer save. This also
rejects a stale completion after switching away and back to the same account and
item. A save may establish its target selection after metadata success without
retiring itself.

`AppModelTests.testInitialCoverSaveCannotCompleteNewerSaveAfterInvalidation`
holds an initial save in invalidation, retires it through reset, account switch,
account round-trip or another selection, then holds a newer cover upload. The
old caller's observed return must preserve the newer saving state and exact
account/detail/selection; only the newer completion publishes success. Fresh
gates and bounded admission/return observations control all four scenarios.
The regression failed against `90e1207` with the old caller publishing `saved`
while the newer upload was held. That failed artifact is retained separately
from corrected-source validation. No physical artwork/device acceptance follows
from this app-model test.


The first owning run with the ownership fix also exposed an adjacent baseline
readiness gap in `testCoverSaveRefreshesActivePlaybackArtworkIncludingRetry`:
the item-status preservation assertion failed; the report did not retain enum
raw values or identify the loop case, so the exact runtime cause is unproven.
The test now observes a ready-to-play item and playing rate/time-control before
the playing baseline, and independently observes ready-to-play plus paused/zero
rate/time-control after its paused seek, before sampling preserved runtime state. Its five-second
budget, paused-seek checks, playing-position tolerance and continuation assertions
are unchanged. The original failed owning bundle is retained separately.


Final local source validation at `84840c1`: three independent focused executions
of the four ownership scenarios and three of the normal/retry playback-artwork
case passed, followed by **624/624** app tests and both disposable online/offline
app-live journeys. Release Simulator compilation, strict Swift lint and docs
checks passed. Structured Simulator results have zero failures/skips/runtime
warnings. Independent re-review found no actionable issues in the ownership and
readiness changes. Original red/failed attempts remain retained in
`.build/cover-initial-save-*`; final artifact/source-hash evidence is
`.build/cover-initial-save-verification.json`. CI and physical acceptance remain
separate from this local record.

## Typed persistence failure reporting (2026-10-23)

The controlled `CoverCacheLifecycleTests.testDiskPreparationFailureIsReportedWithoutLosingOnlineArtwork` fixture makes its owned cache root a regular file. Before this fix, Foundation rejected both revision- and variant-directory preparation, but neither failure was reported. The exact native case failed only on the two missing diagnostic events; fetched artwork remained usable, the synthetic obstruction remained unchanged and a fresh cache-only lookup missed.

Persistence now emits `cover_disk_failure` with the specific preparation, encoding, revision-write or payload-write stage and the underlying typed POSIX or Cocoa numeric cause. The existing observer receives the same typed values. Paths, URLs, account/item identifiers, payloads, localized descriptions and NSError userInfo are not logged. A successful in-memory revalidation does not assert disk durability. Existing fetch ownership, offline fallback, atomic watermark-before-payload ordering and approved actor-owned filesystem boundary remain unchanged.

The corrected exact native case passed with zero failures/skips/runtime warnings. It fault-injects the two directory-preparation stages and requires POSIX `ENOTDIR`; later encoding/write emissions have source review, not fault-injection coverage. The initial result and source patch remain in `.build/cache400-disk-before*`; corrected evidence is `.build/cache400-disk-after*`. Xcode's automatic failure sysdiagnose separately timed out after 600 seconds after the original test; its collector error and existing OS-build metadata diagnostics are retained, rather than counted as application runtime warnings. Owning-class and exact-head CI evidence are recorded with the delivery receipt.

This is a persistence-diagnostics fix, not a diagnosis of the original device flicker, new physical-device evidence or complete disk-I/O assurance. Read/corruption, invalidation, pruning and deletion reporting, general legacy orphan/metadata bounds and the distinct #411 execution review retain their own dispositions.

Owning `CoverCacheLifecycleTests` verification passed all 11 unique cases with zero failures, skips, expected failures or runtime warnings, including cold-start replacement, legacy offline preservation, timestamp fencing, corrupt-cache recovery, account-removal fencing and system-artwork revalidation. The outer tool wrapper disappeared while its original native driver continued; an event-based process wait observed that driver's exit 0, and the unchanged original bundle passed exact identity/outcome inspection. No replacement run was started. The owned disk guard was reattached to that driver; free space remained above the guard. Native evidence is `.build/cache400-disk-owner*`.
