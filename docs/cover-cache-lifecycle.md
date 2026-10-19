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
  requests. Concurrent callers join one owned request. Only the current owner
  may commit; retired generations cannot return or persist bytes. A caller
  cancelling its view does not cancel another waiter’s shared valid fetch.
- Explicit library/detail refresh, live catalog catch-up and foreground catch-up
  start a revalidation generation. A catalog event for active playback outside
  the selected library also refreshes artwork without reloading the browser.
  Progress-only events keep their narrow path.
  Successful in-app cover saves and retries invalidate every variant of the
  affected account/item before notifying views and active playback. Audio player,
  position, intent and queue are unchanged.
- A successfully fetched variant with changed bytes retires sibling variants.
  Exact encoded bytes intentionally identify the rendered variant; a changed
  encoding may cause extra revalidation. This comparison never proves why the
  original device showed stale art.
- Routine refresh retains the displayed image while requesting its replacement.
  A confirmed replacement, changed timestamp/URL, or account switch hides the
  obsolete presentation. Request identity includes policy and refresh generation;
  a retired view task cannot publish its completion.
- Offline/cache-only loads never fetch. Online failure falls back to a valid
  cached variant, but a known newer timestamp cannot use older bytes. Downloaded
  cards and artwork may revalidate independently of audio playback; a known
  unavailable network uses cache-only artwork. Downloaded audio preparation
  remains independent of cover completion.
- New disk entries use account/resource directories, atomic encoded variant
  files with timestamps, and a timestamp watermark published before the payload
  so interruption cannot make an older variant eligible again. A replacement tombstone prevents
  fallback to pre-policy hashed files after replacement. Legacy raw files remain
  readable offline until their resource is validated; no bulk upgrade purge is
  performed. Invalid or oversized entries are misses. Temporary files are never
  lookup targets. Cache failure does not fail playback.
- Limits remain 5 MiB per response, 32 MiB/256 images in NSCache and 128 MiB of
  disk files, pruned by last use. The OS may remove cache files. Account removal
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
it cannot bypass invalidation with an old local image.

## Other assets: inventory and distinct policies

| Asset / owner | Identity, authority and persistence | Freshness, integrity, limits and cleanup |
| --- | --- | --- |
| Browse metadata / `LibraryRepository`, `LibraryCache` | Account + library/query/item; remote DTOs mapped to domain snapshots in SwiftData | Remote-first with cache fallback; explicit refresh remote-only. Cached snapshots support unavailable servers. No universal TTL or image eviction policy; account lifecycle deletes owned records. Cached metadata alone cannot prove image freshness. |
| Saved offline detail / download records | Account + item/download manifest; snapshot accompanies verified local tracks | Audio preparation uses the saved snapshot without requiring the server. Cover freshness is independent. Do not replace verified audio to update a picture. Older persisted shapes have their own typed reconciliation rules. |
| Explicit downloaded audio / `DownloadModel`, `DownloadStorageLayout`, manifest | Account + item/track inode/transfer identity; app-owned media and structured records | Staging, expected byte lengths, validated manifests and atomic finalization; partial/corrupt files require repair. Explicit removal/account removal, never cover TTL or automatic completion eviction. Playing/transcription-pinned files retain existing protection. |
| Automatic audio cache / same owners | Separate `automaticCache` purpose and rolling track window | Window/completion policy, durable local completion timestamp and pin-aware cleanup; default 24 hours after local completion. Valid finalized bytes remain usable offline to window end. No timestamp reset on startup. Explicit downloads are excluded. |
| Ranged-transfer partials / background download adapter and storage | Owned account/track plus expected offset, inode and transfer identity | Bounded chunks and durable byte checkpoints; retire obsolete transfers before replacement. Invalid legacy state is quarantined; late callbacks cannot mutate replacement transfers. Disposable temporary transfer data is distinct from finalized offline media. |
| Playback sessions and temporary streaming / playback engine and session controller | Account/session-scoped remote media routes | Server-session lifetime; close when owned playback ends. These bearer-like routes are never cover-cache keys or persisted diagnostic values. AVFoundation owns its buffering; no new indiscriminate media purge. |
| Transcripts / `ChapterTranscriptCache`, transcription model | Account/item/chapter and source identity; SwiftData segments and job/task state | Reconcile source identity and resumable task state; derived transcript data supports local search/offline presentation. Cancel jobs before owned account/book deletion. No image TTL; retention/storage-budget work is separable. |
| Local positions, preferences, bookmarks, sessions and history / their stores | Account-scoped durable user state and outboxes | These are user records, not disposable asset caches. Preserve ordering, ambiguous mutation state and local position authority. Account removal follows its history-retention choice. Never clear them to refresh artwork. |
| Telemetry retry storage / `RemoteTelemetryRuntime` | Consent-owned storage generation; bounded redacted spans | Bounded retention/export, withdrawal cancels exports and purges the previous generation. Independent of server cover freshness. |

## Remaining bounded work and acceptance

The original launch glitch needs a recording or controlled device reproduction
with exact build, edit origin, network/download state, request revision and
provenance. Do not describe the confirmed cache mechanism as that device's
proven root cause. Physical Lock Screen/Control Center and CarPlay head-unit
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
