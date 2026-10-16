# Application behavior reference

This reference records implemented behavior and internal recovery details.
For user instructions, see the [user guide](https://bleat.terminaloutcomes.com/help/using-bleat/).
The [specification](audiobookshelf-ios-app-spec.md) remains authoritative for contracts.

## Sign in

Launch Bleat, then enter:

- the complete HTTPS address of the Audiobookshelf server, including any path
  prefix;
- an Audiobookshelf username;
- that user's password.

Bleat discovers the server, requires Audiobookshelf 2.26.0 or newer, and uses
the server's native username/password login. The password is cleared from the
screen before the request starts. Rotating access/refresh tokens stay in a
non-synchronizing, device-only Keychain item. When iCloud sync is enabled, the
stable username/password credential uses iCloud Keychain so another device can
obtain its own token pair; tokens are never synchronized. If a reachable
refresh endpoint rejects the session or returns
an unusable response, Bleat silently performs one native login, verifies that
the same server user was returned, and retries the request. Network, malformed
recovery, and storage failures remain retryable; only a missing or conclusively
invalid saved login requires explicit sign-in. OIDC uses the configured
Audiobookshelf identity-provider bridge and does not expose provider
configuration in the app.

## iCloud synchronization

Private iCloud synchronization is enabled by default and can be turned off in
Settings. It merges account descriptors, playback and download preferences,
listening slices, completion milestones, and imported server sessions in
`iCloud.com.terminaloutcomes.Bleat`. Turning synchronization off always keeps
local data and moves stable native credentials back to device-only Keychain
storage; the confirmation also offers to retain or delete the private CloudKit
copy.

Account identity is deterministic from the normalized primary server URL and
Audiobookshelf user ID, so the same server user is one account on every device;
an optional local-network URL does not change that identity. On upgrade, Bleat
rekeys legacy device-generated account IDs across local persistence, pending
mutations, downloads, caches, Keychain credentials, and private CloudKit data.
Canonical CloudKit replacements are saved before obsolete legacy records are
deleted. This migration changes record data only and requires no CloudKit
Dashboard schema deployment.

Launch restores local accounts and downloads before starting private iCloud
synchronization as background maintenance. A slow CloudKit operation never
holds the app on its launch screen. Settings exposes active synchronization,
allows it to be cancelled, and offers an explicit retry after cancellation or
failure. CloudKit failures remain distinct from Audiobookshelf failures:
Settings names iCloud as the failing service, chooses retry behavior from the
typed CloudKit code, and local diagnostics retain the operation, exact code,
partial-failure codes, and retry delay without recording record identifiers or
localized error descriptions. Stage diagnostics also report privacy-safe
durations and available record counts, including failed stages, for zone setup,
fetch, fetched-record application, local preparation, and upload.
Foreground fetched-record application has a 60-second no-progress deadline.
If it expires, Settings reports the specific timeout and keeps the sync in a
stopping state until the old callback drains; retry starts only afterward.
Fetched callback failures make the overall sync fail even when CloudKit's fetch
operation returns successfully.

Bleat retains each successful record's CloudKit system fields, mutable-record
payload digests, per-row statistics sync state,
and account-scoped deletion tombstones across launches, so an unchanged sync
does not scan or re-enqueue the complete statistics archive and interrupted
deletions retry.
Legacy rows without synchronization state are reconciled, pending local
deletions win over racing fetched records, and deleting the iCloud zone marks
retained local statistics for upload if synchronization is enabled again.
Fetched statistics are decoded and
written in one batch instead of opening a persistence transaction per record,
and the iCloud status stops spinning before the independent statistics-summary
refresh completes. A stale-change-tag response is reconciled from
the returned server record: identical data adopts the current server version,
a newer unambiguous local edit is rebased and retried once, and an ambiguous
preference conflict pauses synchronization. Bleat shows only the settings that
differ and asks whether to upload this device's complete current settings or
apply the complete iCloud settings. The pending choice survives relaunch and
blocks automatic configuration uploads until it is resolved.

On a fresh installation, the signed-out form shows **Sync from iCloud** while
CloudKit is enabled. Automatic and manual restore share one synchronization
task and visibly report progress, an empty private zone, or the typed iCloud
failure. Restored account alternatives appear together as selectable cards
showing only the main server, optional local server, and username. A restored
descriptor remains inactive until this device authenticates the expected
Audiobookshelf user; if no synchronized native password is available, Bleat
prefills a dedicated password-required continuation. Rotating tokens remain
device-only.

Saving an account's primary or local server settings immediately pushes that
account descriptor to CloudKit. A different account descriptor fetched from
CloudKit is never applied silently: Bleat aggregates the structurally distinct
choices and requires one complete server configuration to be selected.
Each pushed descriptor carries a generation ID and its predecessor identity, so
a delayed predecessor is ignored instead of prompting or reverting the device.
Keeping the device settings pushes them back to CloudKit.

Builds whose effective CloudKit mode is `disabled`, whether selected directly
or forced by `BUILD_WITHOUT_PAID_DEVELOPER=YES`, omit the CloudKit entitlement
entirely. They do not initialize CloudKit or show its Settings controls, and
their stable native credentials remain device-only.

Account removal distinguishes this device from all devices and asks separately
whether listening history should be retained. Downloaded audio is always
removed with its account, and launch cleanup removes any record whose account
is no longer saved.

Accounts created by an older Bleat build contain only tokens because those
builds discarded the password. Enter the password once with **Sign In Again**
to migrate that account; subsequent refresh-session failures recover silently.

## Browse the library

Home identifies the active username, server host, and audiobook library above
the server's personalized shelves. Completed books for that account appear in
a local **Downloaded** shelf after **Continue Listening** and
**Recently Added**, before the remaining personalized shelves, and start
offline playback directly. That shelf remains usable while personalized
shelves are loading or unavailable.
Shelf cards are compact enough to scan several books without losing title and
author context. Pull down on Home to refresh the current library page and its
personalized shelves. Refresh keeps the loaded shelves visible and replaces
them only when the normalized content changes. **Continue Listening** is
ordered by the most recently updated listening progress, with stable book-ID
ordering when progress timestamps are equal. Ordering reuses the loaded account
progress snapshot; shelf loads never fetch progress separately for each book.
Books with known progress sort ahead of books absent from the snapshot; those
unknown books retain their server order.

The Library tab loads 50 books at a time. Its controls sort server-side by
title, author, recently added, recently updated, or duration in either
direction. The progress filter shows all, finished, in-progress, not-started,
or not-finished books without downloading the entire library first. Pull down
to reload accessible libraries and the selected library's content without
clearing the loaded page; unchanged results are not republished. **Load More**
fetches the next page using the active sort and filter. Collapsed server series
are shown as series entries; opening one uses the server's uncollapsed sequence
order, supports cached pages and pagination, and provides a swipeable cover
browser. A book's authors and series use compact, comma-delimited lists that
wrap for larger text while keeping every entry a separate accessible control.
An author opens a named Library filter that can be cleared, while a series
opens its ordered series detail. **Download Series** loads every remaining series
page, asks for confirmation even if you navigate elsewhere, and hands each book
to the normal download flow. Another series can be prepared at the same time;
completed confirmations are shown in order. Existing downloads are retained,
and Wi-Fi-only downloads remain queued until an allowed network is available.
Search presents separate Books, Authors, and Series groups, with the same
destinations.

## Open a Bleat link

Bleat uses `bleat://` as its sole canonical custom URL scheme for every
app-owned URL, including scene-local navigation and OIDC callbacks. It accepts
Home, Library, Downloads, Now Playing, Settings (including Diagnostics,
Listening Stats, and About), Search, and account/library-qualified Book,
Author, and Series routes. Entity routes resolve their display labels using the
selected account and library; they never search other accounts. Malformed links
leave the current screen unchanged, and a link received while the app is
starting opens once its account and library context is ready.

## Play an audiobook

Single-book covers on Home, Library, Search, and Series provide a separate
Play/Pause control without changing the current screen; tapping the rest of a
card opens Book Detail. The same control discovers a verified complete download
or opens streamed playback without making the browsing screen choose the media
source. While preparation is in progress, only that book's control is disabled.
Collapsed-series covers remain navigation-only because they do not identify one
book. Book Detail retains its larger primary playback action.

Long-press a single-book card or row on Home, Library, Search, or Series to use
the same actions as Book Detail without navigating first. The menu offers one
of **Mark Played** or **Mark Unplayed**, plus permitted Download and Edit
actions; on iPhone and iPad it also reports whether on-device transcription is
available. Played-state changes dismiss the menu and run without a preparation
sheet: Bleat loads canonical detail, re-checks account access, and changes local
state only after the server confirms the mutation. Preparation and mutation
failures use a dismissible alert, while successful server reconciliation runs
separately. Download, Edit, and Transcribe retain their existing preparation
presentation. Collapsed series remain navigation-only, and long-pressing never
starts playback.

Bleat opens native Audiobookshelf playback sessions and uses session-scoped
direct-play or HLS URLs without putting access tokens in media URLs. The
mini-player floats in a
rounded material bar above the signed-in tab bar so tab navigation stays
unobstructed; tap its title or swipe upward to open Now Playing for
current-chapter seeking, configurable rewind and forward controls,
previous/next chapter controls, and speed control from 0.5× to 3×. Swipe the
mini-player downward to stop playback and dismiss it, whether playback is active
or paused. Rewind defaults to 15 seconds and forward defaults to 30 seconds.
Settings offers 5, 10, 15, 30, 45, and 60-second choices for either direction.
Current-chapter scrubber moves of 10 minutes or more in either direction require
confirmation; skip, chapter, audio-file, and system commands remain immediate.
Now Playing identifies the narrator and current chapter, offers a chapter list
for direct navigation, and shows an Audio Files menu for multi-file direct or
downloaded books. The chapter list opens with the current chapter visible and
as its only selected row. Selecting a chapter or file seeks directly to its
whole-book start position. The player also includes the native AirPlay route
picker. Player content and secondary controls scroll when the screen or text
size is too small to show them at once.
Bleat reports playback as active only after AVPlayer has a ready item and the
whole-book playhead is advancing. Initial loading and later stalls show as
buffering while Pause remains available. A stream that makes no progress for
12 seconds is rebuilt at its last confirmed position. Bleat can replace one
lost server session automatically, and a typed direct-play decoder failure
opens one forced-transcode session instead; exhausted recovery becomes a
visible playback failure rather than continuing to appear active.
The selected global speed persists across relaunches and can be adjusted in
0.05× steps.

Playable-cover verification is provided by
`BleatUITests.testPlayableHomeCoverSeparatesPlaybackFromNavigation`,
`testPlayableCoverPreparationDisablesOnlyMatchingAction`,
`testPlayableCoverPresentsTypedPlaybackFailure`,
`testPlayableCoverPresentsTypedPermissionDenial`,
`testPlayableCoversAppearOnEverySingleBookBrowseSurface`,
`testBookEditorOwnsCoverAndServerDeletionControls`,
`BleatDynamicTypeUITests`, and
`testSeriesCoverBrowserDisablesDepthMotionWhenRequested`. The disposable live
journeys `BleatLiveUITests.testLiveOnlineLoginPlaybackAndDownload` and
`testLiveOfflineCachedDownloadAndLocalProgress` cover remote and completed
download quick-play, including offline local transport with every server
stopped. Component-specific manual checks confirm separate VoiceOver and
keyboard targets on iPad and Mac, legible increased-contrast presentation,
reduced carousel motion without playback-state changes, and no overlap at the
largest Dynamic Type size. These checks do not replace the broader application
accessibility audits or physical-device audio-route validation.

Audio continues in the background. Lock-screen, Control Center, headset, and
Bluetooth controls can play, pause, seek, and skip. Settings independently maps
the system Previous and Next commands to skip back, skip forward, previous
chapter, or next chapter; they default to the configured back and forward
intervals. AirPods report only Previous or Next to Bleat, not the originating
ear or tap count.
Removing headphones pauses playback. Removing the signed-in account stops
playback and closes its server session before credentials are deleted.
Switching accounts first stops playback and clears the mini-player and system
Now Playing state, then activates the selected account. If activation fails,
the current account remains selected while playback stays stopped.
The CarPlay audio scene shares the phone's active account, selected audiobook
library, downloads, and process-wide player. Its Home, Library, and Downloads
tabs provide personalized shelves, a library chooser, explicit pagination,
and verified whole-book offline playback. Selecting a book prefers a verified
complete download, otherwise prepares one streaming
session, then opens the system Now Playing template. Play/pause, configured
skip intervals, whole-book seeking, chapter navigation, and a featured-speed
decrease/current/increase control are available in-car. Sign-in, account
switching, bookmark editing, sleep timers, Stop, and download management remain
on the phone. Signed-out users can play retained verified downloads.
The full player includes 5, 10, 15, 30, 45, 60, 90, and 120-minute sleep
timers plus an end-of-current-chapter option. Settings also configures an
optional 5, 10, 15, or 30-second rewind when resuming after a pause longer than
five minutes.
Its Bookmarks menu loads the current book's server bookmarks, creates a
bookmark at the current whole-book position, and supports rename and delete.
The same controls remain available during local-file playback. Changes appear
immediately, survive relaunch, and reconcile in order when the playback
account can reach the server. Ambiguous create retries refetch first and do not
duplicate an already-created bookmark. Failed synchronization remains visible
in Now Playing with an explicit retry action.
While streaming, Bleat sends the whole-book position to Audiobookshelf every
15 seconds and after pause, seek, backgrounding, interruption, and completion.
Only forward audible playback contributes listening time; pauses, buffering,
interruptions, and seeks do not.

Home shelves, library/search rows, book detail, and Now Playing request bounded
cover images with `updatedAt` cache busting. SwiftUI, system Now Playing, and
CarPlay share an account-scoped memory and bounded disk cache, including
in-flight request deduplication. Cover URLs retain server path prefixes and
never contain access tokens.

## Edit book metadata

Accounts with Audiobookshelf's update permission see **Edit** in the top-right
book actions menu on book detail.
The editor supports title, subtitle, authors, narrators, series and sequence,
genres, tags, publishing fields, description, explicit status, and abridged
status. Saving sends only changed scalar fields and complete replacement arrays
through the native account's bearer-authenticated metadata endpoint.

Bleat refetches the item immediately before saving. If the server's `updatedAt`
value changed since the editor opened, Bleat offers to load the server version,
review the current draft, or overwrite it. This is a best-effort conflict check
because Audiobookshelf does not expose an atomic metadata precondition.

Accounts with both update and upload permissions also see **Cover** on book
detail. Bleat uses the system photo picker, applies orientation, strips source
metadata by redrawing the image, limits the longest edge to 1600 pixels, encodes
JPEG, uploads it as the server's `cover` multipart field, and refetches the book
before replacing the displayed cached cover.

## Download an audiobook

Accounts with Audiobookshelf's download permission see **Download** on book
detail. Bleat schedules every original audio file through a stable background
URL session with bearer headers, admits audio transfers through one process-wide
scheduler,
persists an offline metadata snapshot and byte-exact manifest, and restores
system-owned tasks after relaunch. An interrupted non-paused transfer that could
not be restored because Bleat launched offline resumes automatically from its
durable partial bytes when connectivity returns; user-paused downloads stay
paused. Unavailable paths show **Waiting for network**, and satisfied-path
recovery shows **Retrying download**. Bleat does not infer failure from gaps in
progress callbacks; delegate-reported failures enter its bounded replacement
flow. HTTP 429 and 503 responses honor valid `Retry-After` delta-seconds or
HTTP-date values, bounded to one hour, while retaining exponential backoff as
the minimum delay. Multi-file books transfer one track at a time, resume an
existing partial track before starting another, and report durable bytes plus
only the active request's in-flight bytes. If the system resumes within an
active range but reports only the resumed suffix, Bleat discards the ambiguous
temporary file and retries the bounded chunk from its durable offset. A failed
track does not label the
whole book failed
while another retained transfer is still active; the failure becomes visible
only when no track is continuing. The Downloads tab shows durable state and
supports book-scoped deletion. Its storage section shows the total number of
books, device storage used, and books ready offline. Confirmed bulk removal
cancels matching transfers but preserves the currently playing download;
Settings links to the same management screen and storage total.
Home and Library book context menus also expose **Remove Download** for a
matching manual download or automatic cache and disable it while that account
and book are playing. Removal affects only local state and media files.
Before scheduling, Bleat requires the expected audio bytes plus the larger of
10% or 256 MB to be available. Downloads are grouped by saved account and show stored
versus expected bytes for each book and the stored total for that account.
Startup removes local records that have no saved owning account. A 401 transfer
response is replaced using the native account's rotating refresh token without
placing tokens in URLs.
Downloads default to **Wi-Fi Only** in Settings. Turning that off permits
expensive networks on newly created and replacement requests; books of 100 MB
or more still require explicit confirmation before Bleat schedules them.
The process-wide maximum defaults to five concurrent books and is configurable
under **Settings → Downloads** on every platform. iPhone and iPad also expose
the same exact permitted values under Bleat in the system Settings app. Values
from one through five advance by one, then advance by five through 100.

Starting streamed playback also creates an automatic whole-file cache. Bleat
keeps the current file plus enough following files to cover the next configured
chapter window when file timing is available, and otherwise keeps the
configured number of files ahead. Settings offers 1, 3, 5, 10, or **All**;
the default is five files ahead. **All** starts a full-book download during
playback, promoting any existing automatic cache and retaining its verified
files. These full-book downloads follow the normal download network policy
and cellular confirmation rules and are excluded from automatic cleanup.
A single M4B is downloaded once in full. Automatic transfers wait for stable
playback, run at background priority, and suspend whenever the player needs
bandwidth.
Their status and displayed byte count cover only the active file window, so a
fully cached window reads **Downloaded** at 100% and offers no further per-book
Download action, without changing the whole-book offline guarantee. Play starts
immediately from a finalized, byte-verified
cached window when it covers the requested position. Bleat keeps filling the
window and prepares any later streaming continuation in the background; a
full-book download remains the only guarantee that playback can reach the end
without a connection. Completed files outside the active window still count
toward device storage until cleanup removes them. Settings can delete
automatic cache files after each completed chapter, when the book finishes,
or—by default—24 hours after the book finishes. Cleanup never applies to an
explicit download. Natural playback completion and a successful **Mark Finished**
action start cleanup from the local completion time. Launch applies the selected
policy to persisted local timestamps and schedules future 24-hour deadlines.
Starting a reread clears the deadline; new caches and older caches without a
local timestamp remain until a new local completion or explicit deletion.
Historical server completion never starts cleanup for the current copy, and
playback or transcription pins defer deletion until their files are released.
**Download Full Book** promotes an automatic cache in place,
keeps its verified files, and downloads only the remaining files when requested
before the current automatic window completes or through Download Series.

Book detail keeps Play and available Download actions above long description
and metadata content; completed local downloads do not show another Download
button. Chapter and completion progress sits directly below Play or Resume.
Its Details and Chapters sections are
collapsible; the Chapters header shows the count, and each chapter shows its
duration and asks for confirmation before moving playback there. Bookmarks
follow Chapters. When multiple accounts are configured, the source account is
the final row in Details. When detail loading fails,
the screen distinguishes missing or forbidden items, expired authentication,
invalid server responses, local-storage failures, offline cache misses, and
temporary server failures. Retryable failures include a **Try Again** action;
diagnostics retain only the corresponding non-sensitive failure code. Existing
downloads show status plus stored and expected bytes. Their single trailing
control matches the mini player: active work shows a Stop pictograph, while
stopped or failed work shows a Download pictograph that resumes from retained
bytes or retries from the beginning. Stop discards unfinished partial bytes
while retaining already completed tracks, persists **Stopped**, and never
restarts through recovery without an explicit user action. Late cleanup from
the stopped transfer cannot overwrite or delete that action, and restarting
queues every unfinished track before starting the next one. Queued work is shown as **Waiting to download**,
separately from **Waiting for network** and **Retrying download**. Download
diagnostics are emitted outside these transfer-control transactions and cannot
delay their state changes.
Automatic cache failures retry only the active window and never appear as a
full-book repair. Explicit full-book downloads play directly from local files
without opening a server playback session. Automatic cached windows can also
begin locally while later streaming continuation is prepared without blocking
local controls. Bleat audits completed files when restoring downloads and
before playback; a missing or byte-corrupt track in an explicit download
changes the book to Partial and exposes Repair. Repair preserves verified
tracks, downloads only damaged
entries, and refuses to mix files when the server's plan changed.
Local-file playback saves an account-scoped
position every five seconds and on pause, seek, backgrounding, completion, and
stop, then resumes from that durable position after relaunch. Position updates
are queued as Audiobookshelf local sessions and retried with the same UUID until
the server acknowledges them, including after app or account restoration. When
both the
saved device position and server position changed after the download snapshot,
Now Playing asks which position to keep before syncing. Book detail also
supports explicit **Mark Finished** and **Mark Unfinished** actions through the
same account- and item-scoped non-modal mutation coordinator used by browsing
menus.

## Use multiple accounts

Settings lists every saved username/server pair and marks the active browsing
account. Tap a saved account to edit its primary server URL, optional local
server URL, username, and password, remove it, or make it the active account.
Leave password blank while editing to preserve the existing Keychain
credentials, including when verifying a local server. Use **Add Account** for
another standard Audiobookshelf username/password login.
Switching the browsing account stops current playback and clears Now Playing;
unrelated background downloads continue.

Each account can also have an optional **Local Network** server URL. Bleat uses
the primary URL together with the remote user ID as the account identity and
tries the local URL first for matching
requests, and falls back to the primary URL when the local endpoint cannot be
reached. Every launch and network-path change clears the current local failure
state and tries any configured local endpoint. An endpoint that has not yet
been validated uses the saved native username and password for direct identity
validation without sending its existing bearer token. A successful validation
is retained; a temporary failure affects only the current network lifecycle and
never revokes an earlier validation. This applies to
all supported iOS and native macOS network interfaces; it does not assume that
the current path is Wi-Fi. A changed local URL is verified directly as the same saved
Audiobookshelf user. Changing only the primary URL does not require the local
server to be reachable. If changed local details cannot be verified, the edit
can still be saved with that local URL disabled. The local URL is not treated
as another account and does not split caches, credentials, downloads, or
playback state.

Settings also provides **Diagnostics**, which shows the app, operating-system,
server, connection, resource, playback, sync, and download state. It identifies
the primary or local hostname and port last used for authentication and API
traffic, plus the configured WebSocket endpoint and its connection state.
Endpoint activity updates live and is collected through the same account-aware
boundary for API and authentication requests, WebSockets, covers, streamed
playback, and foreground or restored background downloads. **Last Server
Activity** identifies which of those paths most recently reached a server.
Diagnostics also distinguishes a local endpoint that is not yet validated,
being checked, available, or temporarily unavailable.

The Diagnostics **Privacy** section also records device-local, default-off
consent for **Share diagnostic telemetry** and whether a current OpenTelemetry
export token is available. The token status reads the exporter's in-memory
state without requesting a refresh and never exposes credential material. It
distinguishes disabled, acquiring, missing, expiring, expired, available,
invalid authentication configuration, invalid authentication response, invalid
export configuration, unavailable App Attest, authentication rejection, rate
limiting, temporary unavailability, retry backoff, unsupported platform, and
inactive-controller states. The reviewed schema permits only
bounded technical operation, outcome, timing, app-version, and operating-system data;
it excludes audiobook content, credentials, accounts, servers, searches,
transcripts, paths, and hardware or advertising identifiers. A random
installation identifier authenticates uploads and is included as the standard
OpenTelemetry `service.instance.id` resource attribute so related spans and logs
can be correlated. Turning the setting off does not affect local Diagnostics. The
Diagnostics screen remains available while signed out and when application
startup is unavailable. On iOS, the
opted-in runtime batches completed OpenTelemetry spans and reviewed CloudKit
and download lifecycle log records away from the main actor, retaining failed span batches
under the bounded persistence policy before authenticated OTLP export. Remote
telemetry authentication is traced end to end, with challenge, enrolment, and
token client spans correlated to the matching `bleat-api` server spans through
W3C trace context. Remote OpenTelemetry export is out of scope on native macOS:
that build does not create
App Attest keys, request telemetry tokens, retain export batches, or send OTLP.
Transcription batches include content-free child spans for each chapter. Their
span duration measures processing time, while reviewed attributes report the
analyzer input duration, byte count, slice count, M4A container, bounded codec
category, sample rate, and channel count without including book or chapter
identity, filenames, paths, or transcript text.

Foreground Socket.IO updates are suspended while the current path is marked
constrained by Low Data Mode and resume with a catch-up refresh when the path
becomes unconstrained. REST requests, downloads, covers, and playback remain
independent of that optional realtime connection, and socket progress never
changes the foreground player's timeline. Progress events reconcile only the
affected book's progress and Continue Listening membership/order. The locally prepared
book (streamed or downloaded, playing or paused) never triggers a progress
refetch. Other books request just their progress and, if their summary is not
loaded, that single item's detail. Progress-filtered browse pages refresh only
when the changed progress alters membership; libraries, personalized shelves,
all-progress, and searches are not reloaded for progress events. Inactive scenes
cancel queued live refreshes and stop follow-up requests from an in-flight
refresh; foreground return performs a catch-up refresh.
**About** shows the app icon, version, build timestamp, developer,
and bundle identifier.
Opted-in HTTP tracing identifies endpoints with a closed, identifier-free enum
and emits one completion event per app-controlled HTTP attempt, including API
requests, cover fetches, nearby-server verification, authentication, and download
transactions. Cache hits do not count. OTLP uploads are excluded to prevent
recursive reporting; AVFoundation and Apple-service internal traffic is outside
this HTTP boundary.

Diagnostics shows live, privacy-safe operational status and keeps the
**Share diagnostic telemetry** control and Bonjour troubleshooter available.
Bleat emits typed diagnostic events through the system log; it does not create
or share an app-owned diagnostic snapshot or rolling log file.

Each visible failure retains both the operation and a specific safe cause—for
example authentication, permission, missing content, invalid server data,
offline cache state, local storage, or transient connectivity—rather than a
generic unavailable message. Read-only operations offer retry only when safely
repeatable; mutation recovery continues through its existing durable state.

**Remove Account** always asks for confirmation and removes the account's
local books, metadata, and device progress. It separately asks whether to keep
or delete listening history.

Listening Statistics uses pull-to-refresh for an explicit server-history
import. Automatic imports run at most daily per account. Interrupted imports restart
from the first page and reuse already saved session identities. Charts and book
details include imported sessions, with explicit uncertainty bounds. Daily
charts and date-range boundaries use UTC Gregorian days; playback
rate and chapter coverage remain specific to this app. Summaries and live slices
are read together so persisted playback does not disappear from the counters.
A local derived cache makes repeated Lifetime reads independent of ledger size;
playback and session updates maintain compact aggregates transactionally.
While the statistics screen is open, repository changes update its prepared
snapshot and import progress without periodic database polling. Changes to
uncommitted listening time are coalesced to a one-second cadence; saved totals
and range changes update promptly and take precedence over pending updates.
Bulk archive imports and resets invalidate the cache and reload the visible
query, or rebuild it on the next explicit load when the screen is closed.
JSON archives contain
book titles and listening times, which are personal behavioral data; choose a
safe destination when exporting them.

The app requires HTTPS. The live app harness below supplies a trusted,
disposable local CA to its temporary simulator; production builds continue to
use normal system trust validation and contain no trust bypass.
