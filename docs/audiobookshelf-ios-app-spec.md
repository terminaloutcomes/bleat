# Audiobookshelf iOS Client — Product and Technical Specification

Status: Implementation-audited draft 1.3
Platform: iPhone, iPad, and native macOS
UI framework: SwiftUI
Minimum OS: iOS 26.0; macOS 26.0
Language mode: Swift 6 with strict concurrency checking
Backend: Audiobookshelf 2.26.0 or newer
Contract baseline: Audiobookshelf v2.36.0, commit `96d4021a3cd45f67bf374b65abafbe5d73e926b5`
Audit date: 2026-07-29

## 1. Purpose

Build a native iOS audiobook client for one or more Audiobookshelf servers. The app must:

- authenticate securely with Audiobookshelf local username/password credentials;
- retain multiple server/account connections without mixing credentials, cached data, downloads, or progress;
- browse and search book libraries;
- stream and download audiobooks;
- play multi-file and single-file books with chapters, bookmarks, background playback, system media controls, and variable speed;
- keep listening progress and sessions synchronized with Audiobookshelf, including after offline playback;
- edit book metadata and cover art when the authenticated user has permission.
- remove a book from the server library, with an explicit separate choice to
  delete its server files, when the authenticated user has permission.
- transcribe a downloaded audiobook chapter on supported devices, retain the
  completed result locally, and search cached chapters within that book.

This is an audiobook app, not a general Audiobookshelf administration client;
item deletion is limited to the current book editor.
The same application target supports native macOS 26. Signed launch, native
login, split Keychain credential
persistence, and account restoration are implemented; their signed runtime
journey is tracked in
[GitHub issue #25](https://github.com/terminaloutcomes/bleat/issues/25) as
post-1.0 evidence and is not a version 1.0 acceptance requirement. Notarization,
distribution, Mac-specific interface adaptation, and otherwise unlisted Mac
media or background behavior are also not version 1.0 acceptance requirements.

## 2. Product defaults

These decisions keep the first release bounded:

| Topic | Decision |
| --- | --- |
| Minimum Audiobookshelf version | 2.26.0, because this introduced access/refresh tokens and managed sessions |
| Audited server contract | Audiobookshelf v2.36.0 at commit `96d4021a3cd45f67bf374b65abafbe5d73e926b5` |
| Client interoperability reference | Official mobile client at commit `185cba16eb122b40e8537a7bf475632680d6fb94`; copy its server contract, not its implementation bugs or legacy token-in-URL workarounds |
| Server selection | One active browsing context at a time; playback and downloads continue when the user browses another account |
| Multiple users on one server | Supported; an account is identified by normalized server URL plus remote user ID |
| Podcasts and ebooks | Out of scope for 1.0 |
| Metadata matching providers | Out of scope for 1.0; manual editing is in scope |
| CarPlay | The implemented audio-app scene browses the active account's Home shelves, audiobook libraries, search, and verified complete downloads; account and download management remain phone-only. Managed entitlement enablement and real-environment validation are deferred until after 1.0 |
| watchOS, widgets, Siri/App Intents, SharePlay | Out of scope for 1.0 |
| Server WebSocket events | Authenticated Socket.IO updates refresh visible library and progress state while foregrounded; reconnect performs a catch-up refresh |
| Statistics and time tracking | Deferred until after the MVP. Section 12 retains the intended design, and [GitHub issue #26](https://github.com/terminaloutcomes/bleat/issues/26) tracks the remaining implementation; it is not an MVP or 1.0 release requirement |
| Cleartext HTTP | Not supported in production builds |
| Untrusted/self-signed TLS bypass | Never supported; system-trusted private CAs are supported |
| Third-party analytics | None by default |

## 3. Important constraints

### 3.1 The server implementation is the contract

Audiobookshelf's public API reference explicitly says it is out of date. For this specification, authority is:

1. the pinned server router, controllers, models, and playback manager;
2. observed responses from disposable supported servers;
3. the official mobile client as interoperability evidence;
4. the published API reference only as a non-authoritative clue.

The implementation must isolate all remote DTOs and endpoint construction behind an `AudiobookshelfAPI` layer. It must be tested against:

- the minimum supported server, 2.26.x;
- the audited v2.36.0 baseline;
- the current stable server at development time;
- saved request/response fixtures for each.

Unknown JSON fields must be ignored. Missing nullable fields must not make otherwise valid responses fail to decode. Remote IDs remain opaque `String` values even when current servers return UUIDs.

Any endpoint or payload change discovered in a newer server must be implemented behind a server-version capability or a verified shape decoder. Do not guess alternate routes.

### 3.2 Current playback is session-scoped

The v2.36.0 server and current official iOS client use an authenticated API call to open a playback session, followed by session-scoped media URLs:

- direct play: `GET /public/session/<session-id>/track/<track-index>`;
- transcode: the returned `audioTracks[].contentUrl`, currently `/hls/<session-id>/output.m3u8`.

These media routes work only while the in-memory playback session or stream exists. The session ID is therefore a bearer-like capability and must be redacted from logs and diagnostics.

Do not put access or refresh tokens in media URLs. Although the server still accepts `?token=` for compatibility, this client uses bearer headers only on authenticated API and download requests. Do not use undocumented `AVURLAssetHTTPHeaderFieldsKey`.

### 3.3 Listening time is not media time — post-MVP

At 2× speed, 30 seconds of real listening advances the book by roughly 60
seconds. A future time-tracking implementation therefore needs two independent
values:

- `currentTime`: position in the book's media timeline;
- `timeListened`: the monotonic wall-clock listening-time **delta since the previous successful online session sync**.

Buffering, paused time, interruption time, and time spent seeking must not be counted as listening time.

The MVP does not measure this value and sends `timeListened: 0` during session
position synchronization.

### 3.4 The server does not provide every requested statistic — post-MVP

The pinned v2.36.0 implementation exposes persisted listening sessions and two aggregate views, but it does not persist playback rate, media-timeline distance heard, or chapter-completion events. Its historical session model also returns `chapters: null`.

Consequently:

- Audiobookshelf `timeListening` is the source for all-device real listening time;
- exact audiobook-time and chapter metrics can only be guaranteed for playback observed by this app after statistics tracking begins;
- book/file duration comes from the expanded item's canonical `media.duration`, snapshotted so later metadata edits do not rewrite history;
- seek distance must never be treated as listened media;
- the UI must label the source and coverage of each metric and must not manufacture historical precision the server does not contain.

In statistics copy, **file length** means duration, not byte size. Downloaded byte totals remain a storage metric.

## 4. Core user stories

### 4.1 Accounts and instances

- As a user, I can enter an Audiobookshelf server URL, including a path prefix such as `https://example.com/audiobookshelf`.
- I can sign in using a local Audiobookshelf username and password.
- I can add multiple users from the same server and users from different servers.
- I can switch accounts without stopping current playback or unrelated background downloads.
- I can see when an account requires reauthentication.
- I can sign out or remove an account, with clear confirmation that removes its downloaded books.
- I can tap a saved account to edit its primary URL, optional local-network URL,
  username, and password, or remove that specific account.
- Leaving the password blank while editing preserves the existing device
  credentials; entering a password replaces them after successful
  authentication.
- The normalized primary URL and remote Audiobookshelf user ID form a
  deterministic account identity shared by every device; the local URL does
  not affect identity. Matching requests prefer the local URL and fall back to
  the primary URL when the local endpoint is unavailable.

### 4.2 Library

- I can browse accessible book libraries using paginated lists or grids.
- I can see Continue Listening, Recently Added, Downloaded, and library contents.
- I can search by title, author, narrator, and series using server-side search.
- I can sort and filter without loading the entire library into memory.
- Collapsed server series open an uncollapsed, server-sequenced series detail;
  author and series navigation always uses the server's opaque identifiers.
- Book details show title, subtitle, authors, narrators, series and sequence, cover, description, duration, chapters, file/download state, and listening progress.
- Cached summaries and downloaded-book details remain available offline.
- A long press on any single-book Home, Library, Search, or Series card exposes
  one native menu backed by the existing Book Detail actions: exactly one of
  Mark Played or Mark Unplayed, permitted Download and Edit actions, and the
  platform's transcription availability. Played-state changes dismiss the menu
  normally and run through an account- and item-scoped asynchronous coordinator
  with a 30-second logical deadline. The coordinator loads canonical detail,
  re-checks item access, leaves local state unchanged until the progress PATCH
  returns HTTP 200, commits locally, and schedules detail, Home, Library, and
  Search reconciliation separately. Preparation or mutation failure presents
  one typed dismissible alert; confirmed success has no pending or success
  presentation. Download, Edit, and Transcribe retain their modal preparation
  path. No context action navigates or activates the separate cover playback
  control. Collapsed-series entries remain navigation-only.
- In CarPlay I can browse Home shelves, choose an audiobook library, page and
  search its books, and play verified whole-book downloads.

### 4.3 Playback

- I can play or resume a streamed or downloaded book.
- Every application playback entry point supplies a saved account, audiobook,
  and typed resume, beginning, whole-book-time, or chapter-relative position to
  one coordinator. The coordinator alone reuses an active player, discovers
  and validates complete manual downloads, loads canonical detail, enforces
  access policy, or opens streamed playback.
- Chapter-relative positions resolve a unique canonical chapter ID and a
  non-negative in-chapter offset before becoming one whole-book timestamp.
  Invalid, non-finite, ambiguous, or out-of-range positions fail distinctly.
- A newer playback request or invalidating account transition supersedes late
  preparation without presenting an error or starting the stale audiobook.
- Quick playback detail loading does not change Book Detail, bookmarks,
  selection, or navigation state.
- Context-menu action preparation uses that same detail-loading boundary and
  likewise does not change Book Detail, bookmarks, selection, or navigation.
- Every Home, Library, Search, and Series cover that identifies one audiobook
  exposes the same account/item-scoped Play, Preparing, and Pause control.
  Playback and Book Detail navigation remain separate hit and accessibility
  targets; starting playback never navigates and navigation never starts
  playback.
- Cover controls submit only the saved account, book summary, and resume
  position to the shared playback-start coordinator. They never inspect or
  select active, cached, downloaded, or streamed media. A superseded start is
  silent and typed failures use one privacy-safe browsing presentation.
- Collapsed-series covers and artwork on Book Detail, metadata editing,
  mini-player, and Now Playing do not receive redundant playback overlays.
- Deterministic Simulator coverage is provided by
  `BleatUITests.testPlayableHomeCoverSeparatesPlaybackFromNavigation`,
  `testPlayableCoverPreparationDisablesOnlyMatchingAction`,
  `testPlayableCoverPresentsTypedPlaybackFailure`,
  `testPlayableCoverPresentsTypedPermissionDenial`,
  `testPlayableCoversAppearOnEverySingleBookBrowseSurface`,
  `testBookEditorOwnsCoverAndServerDeletionControls`,
  `testCoreJourneyAtLargestDynamicType`, and
  `testSeriesCoverBrowserDisablesDepthMotionWhenRequested`.
- `BleatLiveUITests.testLiveOnlineLoginPlaybackAndDownload` quick-plays the
  remote Home cover before Book Detail, completes a full download, and
  quick-plays its Downloaded cover. With every test server stopped,
  `testLiveOfflineCachedDownloadAndLocalProgress` starts that completed book
  from `home.downloaded.<id>.play` and verifies local transport and progress.
- Component-specific manual checks on iPad and Mac confirm independent
  VoiceOver and keyboard navigation/playback targets, changing Play/Pause
  labels, reduced carousel motion, legible increased-contrast presentation,
  and usable largest-Dynamic-Type layout. These results do not close the
  whole-application accessibility audits or claim physical-device audio-route
  validation.
- Xcode 26.3 (17C529) reports an internal priority-inversion warning during
  each final live UI journey on iOS Simulator 26.3.1 (23D8133):
  `Thread running at User-initiated quality-of-service class waiting on a lower
  QoS thread running at Utility quality-of-service class`. Exported diagnostics
  contain only `BleatUITests-Runner`/XCTest `XCTWaiter` screen-identifier and
  remote-query work, with no application source location or Bleat application
  frame. The warning is recorded as an Xcode test-infrastructure limitation;
  the final app-test result bundle contains no QoS warning.
- I can pause, seek, scrub across the whole book, skip backward and forward, and jump between chapters.
- A multi-file book behaves as one continuous timeline.
- Playback continues with the screen locked and while the app is in the background.
- Lock Screen, Control Center, Bluetooth, AirPlay, and CarPlay transport controls work.
- I can choose a playback speed between 0.5× and 3.0×.
- My selected speed survives pause/resume, track changes, app relaunch, and switching between local and streamed media.
- I can set a sleep timer by duration or end of chapter.
- I can create, rename, and delete bookmarks.

### 4.4 Downloads and offline use

- I can download a book for offline playback.
- I can see per-book and per-file progress, pause/cancel/retry downloads, and understand failures.
- Downloads resume after app suspension, process termination, connectivity loss, or access-token refresh.
- I can restrict downloads to Wi-Fi/non-expensive networks.
- Starting playback automatically caches complete source files for the current
  position and a configurable lookahead, defaulting to five files/chapters
  ahead; a single-file book caches that complete file.
- Automatic cache progress, target bytes, and `queued`, `downloading`,
  `cached`, or `failed` state describe only the active window. A cached window
  does not make a multi-file book an offline download.
- I can choose whether automatic cache files are deleted after each completed
  chapter, when the book finishes, or 24 hours after the book finishes.
- I can promote an automatic cache to a full-book download without downloading
  its verified files again.
- The app checks available storage before starting and never leaves a completed book pointing at partial files.
- I can play downloaded books while the server is unavailable or the account needs reauthentication.
- A whole-book-complete download prepares from its persisted detail, verified local files, and account/item-scoped local position. Play, pause, seek, skip, chapter navigation, rate changes, resume, stop, backgrounding, and bookmark edits persist local state without opening a playback session, fetching progress, bookmarks, authentication, or artwork, or uploading progress.
- Missing, partial, or invalid local media fails immediately as media unavailable and never falls back to streamed playback.
- Downloaded artwork is cache-only; a cache miss uses the normal placeholder rather than fetching from the server.
- Offline listening sessions and progress synchronize in a coalesced background retry after a later app lifecycle event or network-path update; a failed or timed-out retry retains the durable records and never blocks launch or playback.

### 4.5 Book editing and deletion

- If my server account has update permission, I can edit supported book metadata and cover art.
- Cover changes are staged in the book editor and upload only after metadata
  saves successfully; cancelling the editor discards the staged cover.
- If my server account has delete permission, I can remove the book from the
  library or explicitly delete its files from the server.
- If I lack permission, editing controls are absent rather than merely failing later.
- Metadata edits are never silently queued while offline.
- If the server item changed since I began editing, the app warns me and lets me reload or deliberately overwrite.

### 4.5.1 Chapter transcription

- On a supported iOS device, I can explicitly transcribe one chapter or select
  multiple chapters, including Select All, when the verified local download or
  automatic cache contains every audio file intersecting those chapters.
- Automatic-cache files are pinned while transcription uses them, preventing
  ordinary cache cleanup from removing the input until the batch finishes,
  fails, or is cancelled.
- Playback and transcription can run concurrently; starting or resuming
  playback does not cancel active transcription.
- A selected batch transcribes one chapter at a time in ascending chapter-index
  order, not selection order, and continues when I dismiss the transcription
  screen or navigate elsewhere in the running app.
- Completed transcripts persist locally under the exact account, library item,
  and chapter identity and replace only that chapter when run again.
- The latest batch's typed success, failure, or cancellation result persists
  under the account and library item with start and finish timestamps plus
  monotonic elapsed time. The transcription screen reloads that terminal state
  after relaunch without retaining private filenames or framework diagnostics.
- I can search transcript text case-insensitively across every previously
  transcribed chapter of the current book. Query terms may appear in any order,
  but every term must occur within the same transcript segment.
- Tapping a transcript segment or search result opens actions to copy only its
  text or move playback to its whole-book start timestamp. A matching active
  player seeks without changing its playing or paused intent; otherwise the
  existing downloaded-first preparation flow starts the exact account and book
  at that timestamp. Typed playback failures remain visible without replacing
  the transcript.
- In-memory transcript text is retained while its screen is visible or its
  batch is active, then evicted after five idle minutes or immediately for
  inactive books when iOS reports memory pressure. Durable records remain.
- Removing an account or deleting the book removes its cached transcripts and
  terminal transcription task state.
- Explicit cancellation, account removal, or book deletion stops the relevant
  active transcription task.

### 4.6 Listening statistics — post-MVP

This user story is intentionally deferred until after the MVP. Its remaining
implementation is tracked in
[GitHub issue #26](https://github.com/terminaloutcomes/bleat/issues/26).

- I can see lifetime totals across all configured Audiobookshelf accounts or filter to one account.
- I can see real listening time separately from audiobook time heard at the active playback rate.
- I can see distinct books started, distinct books completed, chapters started, chapters completed, and the combined canonical duration of completed books.
- I can open a per-book breakdown showing sessions, real time, audiobook time, chapter progress, and completion history.
- The current listening session updates the statistics screen live without waiting for server synchronization.
- I can understand when a value covers all devices versus only playback observed by this app.
- I can export and idempotently re-import my listening history.

## 5. Navigation and screens

Use a `TabView` with:

1. **Home**
   - Continue Listening
   - Recently Added
   - Downloaded
   - current account/server indicator
   - separate navigation and quick-play targets on each single-book card
2. **Library**
   - library selector
   - paginated grid/list
   - sort and filter controls
   - quick-play controls on individual-book rows
3. **Search**
   - debounced server-side search
   - grouped results by books, authors, and series where supported
   - quick-play controls on book results
4. **Downloads**
   - queued, active, completed, and failed items
   - aggregate storage usage
5. **Settings**
   - accounts and server management
   - playback defaults
   - skip intervals
   - Previous and Next headphone-command actions
   - download/network policy
   - storage management
   - diagnostics

A persistent mini-player appears in a rounded material bar above the signed-in
tab bar when a book is loaded, leaving every tab unobstructed. Tapping it or
swiping upward opens the full player. Swiping it downward stops playback and
dismisses it, whether it is playing or paused.

### 5.4 Scene-local deep links

Use `bleat://` as the sole canonical custom URL scheme for every Bleat-owned
URL, including navigation and OIDC callbacks. Do not introduce a separate
bundle-derived callback scheme. Parse only canonical Home, Library,
Downloads, Now Playing, Settings, Search, Book, Author, and Series routes.
Routes may qualify Search and entity destinations with an account and library.
Keep navigation state scene-local, queue only the latest valid incoming route
until the signed-in browse context is ready, and leave the current UI unchanged
for malformed routes. Resolve book, author, and series routes only in their
qualified or selected account/library; never probe another account. Resolve a
book's detail and validate its returned library before navigation. A missing
player or unavailable entity produces a typed, safe presentation failure.

### 5.1 Full player

The full player contains:

- cover art, title, author, narrator, and current chapter;
- active-chapter elapsed and remaining time;
- accessible scrubber limited to the active chapter;
- play/pause;
- configurable skip back and forward controls, defaulting to 15 and 30 seconds;
- previous/next chapter;
- speed picker;
- chapter list that opens with the active chapter visible and uniquely
  selected, plus direct file navigation;
- sleep timer;
- bookmarks;
- AirPlay route picker;
- sync/error indicator that explains pending offline state when tapped.

Seeking must require an intentional drag or explicit tap target. Chapter
scrubber moves of at least 10 minutes from the position where the drag began
require explicit confirmation in either direction. Skip, chapter, audio-file,
and system position commands remain direct. Tiny accidental touches must not
move a user hours into a book.

### 5.2 Book detail

The detail screen contains:

- Resume/Play;
- Download, pause, retry, or remove download;
- progress and finished state;
- metadata in a collapsible Details section;
- separate 44-point-or-larger author and series controls that retain their
  position-based accessibility identifiers; authors select a clearable Library
  filter and series push a series detail above the book;
- a collapsible Chapters section whose header shows the chapter count, with
  duration-bearing rows that confirm before starting or repositioning playback
  through the unified playback-start coordinator;
- bookmarks after chapters;
- Edit item in the top-right actions menu, gated by server permission;
- a single Edit destination for metadata, cover, and server deletion;
- server/account attribution when it could be ambiguous.
- a typed failure reason that distinguishes missing or forbidden items,
  reauthentication, invalid server responses, local-storage failures, offline
  cache misses, and temporary server failures;
- an explicit retry action only when repeating the detail request can succeed
  without a permission or account change.

### 5.3 Statistics — post-MVP

This screen is not part of the MVP. Its remaining implementation is tracked in
[GitHub issue #26](https://github.com/terminaloutcomes/bleat/issues/26). When
implemented, Statistics is a Home destination rather than a sixth tab. Its
default range is **Lifetime** and its default account filter is **All Accounts**.

Top-level cards show:

- Real time listened;
- Audiobook time heard;
- Finished runtime;
- Books started and completed;
- Chapters started and completed;
- effective average speed, calculated as audiobook time divided by real time.

The screen also provides year, month, and custom-range filters; per-account and per-book breakdowns; a daily listening chart; recent sessions; and an explanation of metric coverage. Values update while playback is active. A metric that is local-only or awaiting ambiguous synchronization displays a concise coverage or approximation badge rather than a false exact total.

## 6. Server connection and URL handling

### 6.1 Add-server flow

The server field remains directly editable. When the add-server form appears,
it automatically browses `_audiobookshelf._tcp` in the local Bonjour domain,
resolves the advertised SRV hostname and port, and accepts an optional TXT
`path` value beginning with `/`.
Values containing a query, fragment, credentials, or invalid encoding are
rejected. Every candidate is converted to HTTPS using the SRV hostname,
normalized by the rules below, and verified through `GET <base>/status`.
Duplicate normalized bases collapse to one selectable result, and the first
verified result fills an empty server field automatically. Discovery does not
permit HTTP, construct IP-based server URLs, or weaken system trust.
The Diagnostics screen on iPhone, iPad, and Mac exposes a Bonjour troubleshooter
that runs this same production pipeline and reports the service instance, SRV
host and port, TXT path, resolved and final URLs, and `/status` verification.

1. Normalize the user-entered URL:
   - require `https`;
   - remove query and fragment;
   - preserve any path prefix;
   - remove only the final trailing slash;
   - reject embedded username/password.
2. Request `GET <base>/status`.
3. Require `app == "audiobookshelf"` and `isInit == true`.
4. Record:
   - resolved base URL;
   - server version;
   - `authMethods`;
   - relevant `authFormData`, including `authOpenIDButtonText`, `authOpenIDAutoLaunch`, and the sanitized custom login message.
5. Reject versions older than 2.26.0 with a useful explanation.
6. Present only authentication methods returned by the server.

An account may additionally store a normalized local-network base URL. This is
an endpoint alias for the same server, not another account. API requests and
session-scoped media/download URLs may use the local base first and must fall
back to the primary base after a local transport failure. Account identity,
credentials, caches, downloads, and playback state remain keyed to the primary
account. A changed local base must be authenticated directly with supplied or
saved native credentials and identify the existing remote user before it is
enabled.
Changing only the primary base must not require the unchanged local base to be
reachable. If changed local validation fails or identifies a different user,
the user may save the primary and local details with the local base disabled.
An unvalidated local base must never receive an existing bearer credential.
Every app launch and platform network-path change retries each configured local
base without blocking primary-server work. Successful authenticated identity
validation is durable for that exact normalized URL. Probe and transport
failures update only current-lifecycle availability and must never clear a
previously successful validation; only explicit URL replacement/removal or
account removal clears it.

The app monitors changes to the available network path using the platform
Network framework on iOS and native macOS. A path change clears the temporary
local-endpoint failure state and performs a non-mutating `GET <local>/status`
probe for each validated local alias and an authenticated native-credential
probe for an unvalidated alias. The app does not infer home-network
identity from Wi-Fi, DNS search domains, or interface names. A successful probe
restores local-first routing; a failed probe keeps the bounded primary fallback.
Live WebSocket connections use the same endpoint selection and fallback policy.
They are optional foreground refresh channels: when `NWPath.isConstrained` is
true the app closes the current socket, suppresses reconnects, and also sets
`URLRequest.allowsConstrainedNetworkAccess` to false. Becoming unconstrained
starts one connection and one catch-up browse refresh. REST, cover, playback,
download, and offline behavior do not depend on the socket.

Endpoint URLs must be built relative to the normalized base URL. Never construct API URLs from an origin alone, because that drops an Audiobookshelf path prefix.

Cross-origin redirects during status discovery must not be followed silently. An HTTP-to-HTTPS upgrade on the same host may be accepted; any other origin change requires the user to confirm the resulting server URL.

### 6.2 Local authentication

When `authMethods` contains `local`:

1. Send `POST <base>/login`.
2. Include `x-return-tokens: true`.
3. Send username/password as JSON over HTTPS.
4. Require `user.accessToken` and `user.refreshToken` for server 2.26.0 or newer.
5. Call `POST <base>/api/authorize` using the access token to validate it and load user/server data.
6. Persist tokens only after validation succeeds.
7. Clear the password from view state immediately after submission. After
   validation succeeds, store the username, remote user ID, and password only in
   the same non-synchronizing, device-only Keychain credential item as the
   rotating token pair. Never store it elsewhere or log it.

### 6.3 OpenID Connect authentication

OpenID Connect is an optional authentication method selected from the server's
advertised `authMethods`. Native username/password remains available when the
server advertises `local`; OIDC-only servers are valid account targets.

Audiobookshelf acts as a bridge between the native client and its configured OpenID provider. Use Authorization Code with PKCE; do not embed a web view.

#### Callback URI

Use the exact callback URI `bleat://oauth2redirect`. The `bleat://` scheme is
the sole canonical custom scheme for Bleat-owned URLs and is intentionally
shared with scene-local navigation. Do not introduce a separate callback
scheme derived from the bundle identifier. Do not reuse
`audiobookshelf://oauth`, which belongs to the official client. Document the
exact callback URI for users to add to Audiobookshelf's Allowed Mobile Redirect
URIs list.

The public administrator guide at
`https://bleat.terminaloutcomes.com/help/oidc-setup/` documents the complete
Audiobookshelf and provider setup. Keep an external-system-browser link to that
stable URL on the add-server surface without adding account, server, or
authentication data to it.

#### Flow

1. Create an in-memory `OAuthAttempt` scoped to the draft account:
   - cryptographically random PKCE verifier of 43–128 base64url characters;
   - `S256` challenge;
   - random client state;
   - callback URI;
   - a dedicated, non-shared `HTTPCookieStorage`;
   - an ephemeral `URLSession` configured to use that cookie store while still allowing normal browser SSO in `ASWebAuthenticationSession`.
2. Request:
   - `GET <base>/auth/openid`
   - `code_challenge=<challenge>`
   - `code_challenge_method=S256`
   - `redirect_uri=<exact callback URI>`
   - `response_type=code`
   - `state=<client state>`
   - optionally `client_id=<stable app name>` for parity with the official client; the current server ignores this native-client value and uses Audiobookshelf's configured OIDC client ID when talking to the provider.
3. Disable automatic redirect following for this request and retain all cookies set by Audiobookshelf. The current server stores the Passport/Express authorization session and `auth_method=openid-mobile` across this boundary.
4. Require a 3xx response with an HTTPS `Location` from the server. The provider may be on another host. Open this URL exactly as returned; do not reconstruct its query parameters as the Capacitor client does for a platform-specific workaround.
5. Open the provider URL from `Location` with `ASWebAuthenticationSession`.
   - Do not use `WKWebView`.
   - Default to a non-ephemeral browser session so existing SSO can work.
   - Cancellation returns cleanly to the account form.
6. The provider redirects to Audiobookshelf's `/auth/openid/mobile-redirect`, not directly to the app. Audiobookshelf checks the state held in its in-memory mobile-auth map, then redirects to the registered app callback as:

   `<callback-uri>?code=<authorization-code>&state=<client-state>`

7. On the app callback:
   - require the exact registered scheme/host/path;
   - reject missing or mismatched state against the originally generated client state;
   - handle a missing code as a failed/cancelled provider flow; the current bridge does not reliably forward every provider error field;
   - require an authorization code.
8. Exchange the code using the same Audiobookshelf cookie store:
   - `GET <base>/auth/openid/callback`
   - include `state`, `code`, and `code_verifier`.
   - do not expect this to behave like a generic OAuth token endpoint: the current server requires the original Express session cookie and uses the earlier `auth_method=openid-mobile` cookie to return JSON containing both tokens.
9. Require access and refresh tokens, then validate with `/api/authorize`.
10. Atomically store the account and tokens.
11. Clear the verifier, state, authorization code, Express session cookie, and temporary response data on success, failure, or cancellation.
12. On logout, accept only Audiobookshelf's returned HTTPS provider logout URL and open it in a separate non-ephemeral `ASWebAuthenticationSession` after local credentials and account state have been cleared. Do not retain provider cookies in account state, and never allow provider logout cancellation or failure to block local cleanup.

Do not log provider URLs, callback URLs, authorization codes, tokens, cookies, or the PKCE verifier.

### 6.4 Credential storage and refresh

- Store the native username/password credential and access/refresh tokens in
  separate Keychain items, not SwiftData or `UserDefaults`.
- Treat an existing token-only Keychain item as a legacy account. It remains
  readable, but requires one explicit native login before automatic recovery is
  available because a previously discarded password cannot be reconstructed.
- Access and refresh tokens use
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and never synchronize.
  The stable native username/password uses
  `kSecAttrAccessibleAfterFirstUnlock` with iCloud Keychain while private
  iCloud synchronization is enabled, and migrates back to a device-only item
  when the user opts out. A build with the CloudKit capability disabled also
  keeps this credential device-only.
- Use a distinct Keychain service/account key for every canonical `AccountID`.
  Migrate legacy device-generated account keys locally without placing access
  or refresh tokens in synchronizing Keychain storage.
- Use the access token only in `Authorization: Bearer` headers.
- The current server also extracts an access token from `?token=`, but this client never uses or stores token-bearing URLs.
- Use the refresh token only in `x-refresh-token` for:
  - `POST <base>/auth/refresh`;
  - `POST <base>/logout`.
- Refresh tokens rotate. Replace the old access/refresh pair atomically before retrying requests.
- A per-account `AuthCoordinator` actor must collapse concurrent refresh attempts into one request.
- If a reachable refresh endpoint rejects the token, returns an unexpected
  status or malformed response, omits or returns invalid rotated tokens, or the
  rotated pair cannot be persisted, perform one native login using the saved
  Keychain credential. Require the same remote user ID, atomically replace the
  token pair, and retry the original request without prompting.
- Refresh request-construction, transport, and cancellation failures do not use
  the saved login. They remain retryable and must not be memoized against the
  rejected access token.
- Memoize successful recovery and conclusive authentication failure only.
  Transient saved-login transport, server-contract, credential-read, and
  persistence failures remain retryable. Late waiters from an older recovery
  attempt must not overwrite a newer attempt's state.
- Retry an ordinary request at most once after refresh.
- Authentication endpoints must never recursively trigger refresh.
- Missing saved credentials, a rejected saved password, a rejected replacement
  token, a changed remote user ID, or the retried request's second `401` marks
  only that account as `reauthenticationRequired`; other accounts continue
  normally.
- It is acceptable to decode the access-token `exp` claim only as an untrusted scheduling hint. The server remains authoritative.

### 6.5 Logout and account removal

Logout calls `/logout` with the refresh-token header, then clears local
credentials even if the server is unreachable. If Audiobookshelf returns an
HTTPS OIDC provider logout URL, the app opens it in a separate system
authentication session after local cleanup. Provider cancellation or failure
does not undo local cleanup, and no provider cookie or redirect is retained in
account state.

Removing an account distinguishes this device from all devices and asks
separately whether to retain listening history. It must:

- stop and delete its active downloads;
- close its active playback session if possible;
- delete device session tokens; an all-device removal also deletes the
  synchronized native credential;
- remove its cached data and pending sync operations;
- delete its downloaded audio. Startup also deletes any downloaded record whose
  owning account is no longer stored.

## 7. Account and permission isolation

Every persisted or cached remote object uses a composite identity:

`AccountID + RemoteObjectID`

This includes libraries, items, authors, series, cover cache entries, progress, bookmarks, sessions, and downloads. A remote ID alone is never a valid local primary key.

The app must honor server permissions returned for the current user:

| Current response field | Behaviour |
| --- | --- |
| `user.permissions.download` | Show download controls only when true |
| `user.permissions.update` | Show metadata editing only when true |
| `user.permissions.update` and `user.permissions.upload` | Both are required for cover upload because the router and controller perform separate checks |
| `user.permissions.delete` | Show server deletion only when true |
| `user.permissions.accessAllLibraries` plus top-level `user.librariesAccessible` | Restrict queries and UI to accessible libraries |
| `user.permissions.accessAllTags`, `user.permissions.selectedTagsNotAccessible`, plus top-level `user.itemTagsSelected` | Mirror the server's tag allow/deny semantics and do not reveal stale inaccessible items |
| `user.permissions.accessExplicitContent` | Respect server filtering and do not reveal cached inaccessible items |

Treat `403` as an authorization result, not an authentication failure. Do not refresh tokens in a loop for permission errors.

## 8. Library and metadata requirements

### 8.1 Library loading

- List libraries with `GET /api/libraries`.
- Load a page with `GET /api/libraries/<id>/items` using the current query names: `limit`, zero-based `page`, `sort`, `desc=1`, `filter`, `minified=1`, `collapseseries=1`, and comma-separated `include` where needed.
- Use padded standard-Base64 `authors.<id>` and `series.<id>` filters for typed
  author and series IDs. A normal Library request asks the server to collapse
  series; a series detail omits `collapseseries`, filters by its series ID, and
  uses server sequence order without inheriting a Library progress filter.
- Load home shelves from `GET /api/libraries/<id>/personalized?limit=<n>&include=progress`.
- Search with `GET /api/libraries/<id>/search?q=<query>&limit=<n>`.
- Load book detail with `GET /api/items/<id>?expanded=1&include=progress`.
- Use server pagination with an initial page size of 40–60 items.
- Cancel superseded searches and requests when account/library changes.
- Debounce text search by approximately 300 ms.
- Cache summaries for offline browsing, but show their last-refresh state.
- Refresh on app launch, foregrounding, explicit pull-to-refresh, and after a successful mutation.
- Keep loaded libraries, pages, and Home shelves mounted during refresh. Publish
  a complete normalized replacement only when its domain value changed; a
  refresh failure retains usable content and presents a compact typed retry.
- Normalize Continue Listening by progress `lastUpdate` descending, then opaque
  library-item ID ascending when timestamps are equal. Preserve server order
  for other personalized shelves.
- Do not preload expanded details for every item.
- Cache cover thumbnails separately from original cover images.

### 8.2 Metadata editor

The editor supports, when returned/supported by the server:

- title;
- subtitle;
- authors;
- narrators;
- series and sequence;
- genres;
- tags;
- publisher;
- published year/date;
- description;
- language;
- ISBN;
- ASIN;
- explicit flag;
- abridged flag.

Save with `PATCH /api/items/<item-id>/media` using the current old-model payload shape:

```json
{
  "metadata": {
    "title": "Example",
    "subtitle": null,
    "authors": [{ "name": "Author Name" }],
    "narrators": ["Narrator Name"],
    "series": [{ "name": "Series Name", "sequence": "2" }],
    "genres": ["Science Fiction"],
    "publishedYear": "2026",
    "publishedDate": "2026-07-28",
    "publisher": "Publisher",
    "description": "<p>Server-sanitized HTML</p>",
    "isbn": "…",
    "asin": "…",
    "language": "en",
    "explicit": false,
    "abridged": false
  },
  "tags": ["tag"]
}
```

Send only changed scalar fields, but when authors, series, narrators, genres, or tags change, send the complete resulting array: the server treats those arrays as replacements. `tags` is top-level; the other editable fields are under `metadata`. Authors are name objects and series are `{name, sequence}` objects. Do not serialize display-only flattened fields such as `authorName`, `seriesName`, `narratorName`, or `descriptionPlain`.

The current success response is `{ "updated": Bool, "libraryItem": <old library item> }`.

Before saving:

1. Fetch the latest expanded item.
2. Compare its `updatedAt` with the version used to create the draft.
3. If unchanged, submit the patch.
4. If changed, show:
   - Reload server version;
   - Review my draft;
   - Overwrite anyway.

Metadata edits require a live connection. A draft may be retained locally, but it must not auto-submit after reconnection.

The current endpoint has no `ETag`, `If-Match`, or other atomic precondition. This stale-draft check is best effort and must be described honestly; a race remains between the final fetch and patch.

Descriptions received from the server are untrusted rich text. Render a sanitized attributed string or plain text; do not execute HTML or JavaScript in a web view.

### 8.3 Cover art

- Select a local image using `PhotosPicker`.
- Remove unnecessary metadata, orient correctly, and resize to a documented maximum before upload.
- Upload as `multipart/form-data` with the file field named `cover` to `POST /api/items/<item-id>/cover`.
- Require both `permissions.update` and `permissions.upload`.
- Treat `{ "success": true, "cover": <server cover path> }` as success.
- Refetch the item after success because the cover response does not include the new item `updatedAt` used for cache busting.
- Keep the previous cached cover until the server confirms success.
- Fetch with `GET /api/items/<item-id>/cover`, optionally using `width`, `height`, `format`, and `ts=<updatedAt>`; the current server intentionally permits unauthenticated cover GETs.
- Cache-bust with `ts=<updatedAt>` rather than appending bearer tokens to URLs.
- Chapter editing, track reordering, provider matching, and writing embedded audio tags are deferred.

### 8.4 Server item deletion

- Present one destructive `Delete from Server` action at the bottom of the book
  editor and identify the affected account and server in its confirmation.
- `DELETE /api/items/<item-id>` removes the library record while leaving its
  media files on the server.
- `DELETE /api/items/<item-id>?hard=1` removes the library record and requests
  permanent deletion of its server media path.
- If the same account and book are active in playback, warn that playback will
  stop. Stop and close playback before sending the deletion. After confirmed
  server success, remove that active book's local download; inactive local
  downloads remain untouched.
- Invalidate account- and library-scoped detail, page, search, and Home cache
  records after server success. Report cache or local-download cleanup failures
  as partial success rather than encouraging a second server delete.

## 9. Playback

### 9.1 Playback engine

Use Apple media frameworks:

- `AVQueuePlayer` for ordered multi-track playback;
- `AVPlayerItem` per audio track;
- `AVAudioSession` with category `.playback` and mode `.spokenAudio`;
- MediaPlayer for Now Playing and remote commands.

There is one process-wide `PlaybackEngine`, because iOS should have one active audiobook at a time. It owns a `PlaybackContext` containing account, library item, remote session, source tracks, chapters, desired speed, and global position.

The engine maps between:

- whole-book time;
- track index and track-local time;
- chapter index and chapter-local time.

All three mappings require unit tests for exact boundaries, zero-duration/missing tracks, and floating-point tolerance.

### 9.2 Starting playback

For streamed playback:

1. Ensure a usable access token.
2. Call `POST /api/items/<item-id>/play` with:
   - `forceDirectPlay: Bool`;
   - `forceTranscode: Bool`;
   - `mediaPlayer: "AVPlayer"`;
   - `supportedMimeTypes: [String]`;
   - `deviceInfo` containing a stable `deviceId`, `clientName`, `clientVersion`, `manufacturer`, and `model`. The current server derives `deviceName`; the client does not need to send it.
3. Normally send both force flags as false and allow the server to direct-play only when every included file MIME type occurs in `supportedMimeTypes`. Reserve `forceTranscode` for one automatic retry after a typed direct-play decoder failure.
4. Decode the returned `PlaybackSession`, including `id`, `playMethod`, `startTime`, `currentTime`, `duration`, `chapters`, expanded `libraryItem`, and ordered `audioTracks`.
5. Build session-scoped AVPlayer assets as described in section 9.3.
6. Seek to the selected whole-book position.
7. Start playback only when the intended item is ready.

For downloaded playback:

1. Load the local manifest and validate required files exist.
2. Build local file player items.
3. Create a local playback-session record with UUIDv4 and play method `Local`.
4. Queue it for later `/api/session/local` or `/api/session/local-all` synchronization.

If the requested position is inside a finalized, byte-verified automatic cache
window, build and start that local queue before awaiting any server
playback-session work. Complete per-file timing metadata defines the window for
multi-file books. For an unambiguously single-file book, an older persisted
manifest that omitted optional timing metadata may instead use offset zero and
the authoritative cached book duration; never infer missing timing across
multiple files. Pin the files while the player owns them, extend from newly
verified adjacent files when possible, and prepare a streaming continuation in
the background. If later tracks are not local, switch to streaming at the exact
whole-book position when online. It must not silently stall or report
whole-book completion at the cached boundary.

### 9.3 Playback URL construction

Use a `PlaybackRouteAdapter` selected by the validated server version. For every supported version from 2.26.0 onward, the current implementation contract is:

#### Direct play (`playMethod == 0`)

- Ignore the bearer-protected `audioTracks[].contentUrl` for AVPlayer playback.
- Build each asset URL as:

  `<base>/public/session/<session-id>/track/<audio-track-index>`

- This is the route used by the official iOS client for servers 2.22.0 and newer.
- The route resolves the track from the open in-memory session and supports normal HTTP range handling through Express `sendFile`.
- Do not attach an access token and do not append `?token=`.

#### Transcode (`playMethod == 2`)

- Append the returned `audioTracks[0].contentUrl` under the normalized server base URL. The current value is `/hls/<session-id>/output.m3u8`.
- Treat the leading slash as server-base-relative, not origin-relative. Standard URL resolution would otherwise drop a reverse-proxy path prefix such as `/audiobookshelf`; use the shared route builder's `base + returnedPath` operation.
- Pass the HTTPS URL directly to `AVURLAsset`.
- HLS segment URLs are relative to the manifest and are served by the current `HlsRouter` while the stream is open.
- Do not add bearer headers using undocumented AVFoundation options and do not rewrite the manifest unless a future, separately verified server contract requires it.

The playback session must remain open while either route is in use. Do not close it on ordinary backgrounding, route changes, or account-tab changes. Close it when replacing the book, explicitly stopping playback, or after the final sync at completion.

Treat session IDs and the resulting public/HLS URLs as short-lived secrets: never log them, persist them beyond recovery metadata, share them, or include them in diagnostics.

If a playback URL returns `404` after a server restart or lost in-memory session, open a new playback session once, rebuild the queue, and seek to the latest confirmed whole-book position. Do not loop session creation.

An implementation spike must prove direct-play range seeking, multi-file track transitions, HLS startup/seeking, and immediate failure after the corresponding session is closed.

### 9.4 Speed control

- Supported UI range: 0.5×–3.0×.
- Store as `Float`, with 0.05 precision; present common presets plus fine adjustment.
- Set `AVPlayerItem.audioTimePitchAlgorithm`:
  - `.timeDomain` for 0.5×–2.0× because Apple describes it as suitable for voice;
  - `.spectral` above 2.0× where the time-domain algorithm's supported range ends.
- Apply speed with `AVPlayer.rate`/`playImmediately(atRate:)`.
- Reapply the desired rate after:
  - play following pause;
  - item replacement;
  - track transition;
  - route/interruption recovery;
  - local/stream source transition.
- Persist a global default and an optional per-book override.
- The Now Playing playback rate must match the actual player rate, not merely the desired setting.

### 9.5 Playback state and progress

Use explicit states:

`idle → preparing → ready/paused → playing ↔ buffering → paused → ended`

Any state can transition to `failed`. Loading a different book cancels the previous preparation and closes or persists its session.

Treat play and pause requests as intent, not proof of audible playback. Publish
`playing` only after the current item is ready, AVPlayer reports that it is
playing, and the whole-book position advances. Show `buffering` while waiting
or stalled, keep Pause available, and report a zero Now Playing rate. If no
advance occurs for 12 monotonic seconds, rebuild once at the last confirmed
position. Ten continuous seconds of advancing playback starts a new transient
stall incident; lost-session and forced-transcode recovery remain one-time for
the started book.

Use AVPlayer periodic and boundary observers:

- approximately 0.5 seconds for visible UI updates;
- chapter/track boundaries for transitions;
- a slower persistence cadence for durable progress.

Remove every observer deterministically when replacing the context. Do not let SwiftUI view lifetime own core playback observers.

### 9.6 System integration

Enable the Audio background mode.

Populate `MPNowPlayingInfoCenter` manually with whole-book values:

- title;
- author/narrator;
- current chapter;
- cover;
- total book duration;
- whole-book elapsed time;
- actual playback rate;
- default playback rate.

Update Now Playing after play/pause, seek, speed change, chapter/track change, book change, and material artwork/metadata change. It does not need per-second elapsed updates.

Register `MPRemoteCommandCenter` handlers for:

- play;
- pause;
- toggle;
- skip backward;
- skip forward;
- absolute position change;
- previous/next commands independently configurable as skip backward, skip
  forward, previous chapter, or next chapter;
- playback-rate changes using the featured 0.5×, 0.75×, 1×, 1.25×, 1.5×, 2×,
  2.5×, and 3× values.

Remote commands and Bluetooth/headset actions call the same engine methods as SwiftUI controls.
The app receives semantic Previous and Next commands and cannot identify the
originating AirPod, ear, or raw tap count. Previous defaults to the configured
skip-back action and Next defaults to the configured skip-forward action.

Provide a `CPTemplateApplicationScene` for the CarPlay Audio App category. Its
signed-in root is a three-tab interface:

- Home presents personalized shelves in server order followed by verified
  completed downloads;
- Library presents the active audiobook library, explicit bounded pagination,
  search, and a chooser for that account's audiobook libraries;
- Downloads presents verified whole-book-complete records only.

CarPlay uses the phone's active account and shared library selection. Account
switching, authentication, bookmark editing, sleep timers, Stop, and download
management stay on the phone. When signed out, retained verified downloads
remain playable and the interface instructs the user to sign in on the phone
for server content. Remote selection must load typed detail and permissions,
prefer verified local media, prepare exactly one local or streaming operation,
and present Now Playing only after preparation succeeds.

CarPlay list and Now Playing artwork use bounded token-free cover routes,
placeholders, an account-scoped bounded memory/disk cache shared with phone
cover views, and account/item generation checks. Concurrent requests for the
same account and cache-busted URL are deduplicated. Late results must not
replace artwork or templates for a newer account, library, search, or playback
item.
The CarPlay entitlement requires Apple's approval and matching provisioning;
the repository intentionally omits it until approval. See Apple's
[CarPlay entitlement process](https://developer.apple.com/documentation/carplay/requesting-carplay-entitlements)
and [scene guidance](https://developer.apple.com/documentation/carplay/displaying-content-in-carplay).
Entitlement enablement and CarPlay Simulator/vehicle validation are tracked in
[GitHub issue #24](https://github.com/terminaloutcomes/bleat/issues/24) as
post-1.0 work and are not a 1.0 release acceptance gate.

Handle:

- phone/Siri/system interruptions;
- route changes;
- headphone or Bluetooth disconnection;
- AirPlay handoff;
- media services reset.

Headphone/output removal pauses playback. Resume after an interruption only when the system indicates resumption is appropriate and the user had been playing before the interruption.

### 9.7 Sleep timer and resume rewind

Sleep timer options:

- 5, 10, 15, 30, 45, 60, 90, and 120 minutes;
- end of current chapter;
- cancel/reset.

Duration timers use monotonic wall time, not book time, so speed changes do not alter their duration. End-of-chapter derives the boundary from the whole-book timeline and continues to work across track boundaries. Optionally fade audio over the final 10 seconds.

Resume rewind is configurable: off, 5, 10, 15, or 30 seconds after a pause longer than five minutes. It must never cross before the start of the book.

## 10. Downloads and storage

### 10.1 Background download manager

Use `URLSessionConfiguration.background(withIdentifier:)` and bounded download
tasks. Maintain one stable session identifier, but make Bleat-owned partial
files the durable checkpoint. Transfer each track in 16 MiB HTTP range chunks,
persist every validated completed chunk, and calculate continuation from the
actual partial-file length after relaunch.

Build the download plan from `GET /api/items/<id>?expanded=1&include=progress`. For every included `media.audioFiles[]` entry, use its `ino`, `metadata.filename`, `metadata.size`, and MIME information. Download each file with:

`GET /api/items/<item-id>/file/<ino>/download`

Create the background task from a `URLRequest` carrying `Authorization: Bearer <access-token>`. Never use the server's supported `?token=` compatibility path. `GET /api/items/<id>/download` is not the per-track API: for directory-backed books it streams a ZIP and is unsuitable for the atomic multi-track manifest described here.

Each task description or persisted mapping identifies:

- `AccountID`;
- library item ID;
- track ID/index;
- expected byte length;
- destination manifest entry.

Requirements:

- at most three concurrent audio-file downloads by default;
- per-book queueing;
- playback-driven automatic caching of whole files: use source-file timing to
  cover the current and configured following chapter window, otherwise retain
  the current file plus the configured number of following files;
- default automatic lookahead of five, with a single-file book downloading the
  complete file once;
- automatic cache transfers wait for stable streamed playback, use background
  network priority, and suspend whenever the player needs bandwidth;
- distinguish automatic cache records from explicit downloads so automatic
  cleanup never applies to an explicit download;
- persist the current automatic target track set and aggregate progress only
  from target files and target transfers;
- cancel superseded automatic transfers after a seek without treating that
  cancellation as a failed cache;
- promote an automatic cache in place when the user explicitly downloads the
  full book, retaining verified files and preflighting only the remainder;
- Wi-Fi/non-expensive network option;
- cellular warning for large books;
- user Pause persists a paused manifest state, cancels only the current chunk,
  and retains committed partial bytes; Continue resumes from the durable byte
  offset, while Cancel discards unfinished partial bytes and retains completed
  tracks;
- validate `206 Partial Content`, the complete `Content-Range`, and the expected
  total before appending; retain a strong `ETag` or `Last-Modified` validator
  and send it as `If-Range` on later chunks;
- never append a `200 OK` response to a ranged transfer;
- keep playback-driven suspension separate from persisted user Pause;
- retry;
- stalled/failure detection with bounded exponential retry;
- 401 refresh and rescheduling with a newly constructed `URLRequest`, because an existing background task's authorization header cannot be rotated in place;
- background completion-handler support;
- progress aggregation by known bytes, with an indeterminate fallback;
- no heavy import or indexing work on the main actor.

Do not use server filenames as filesystem paths. Store media under opaque local directories such as:

`Application Support/Media/<AccountID>/<LibraryItemID>/<track-index>.<safe-extension>`

Derive a safe extension from a whitelist of known media types. Reject path traversal and unexpected file types.

### 10.2 Atomic completion

A downloaded book has a manifest with `queued`, `downloading`, `partial`, `complete`, `failed`, or `deleting` state.

An automatic cache additionally has a window-scoped `queued`, `downloading`,
`cached`, or `failed` state. It becomes `cached` when every target track is
finalized at its expected byte length. Whole-book `complete` remains the only
state that guarantees uninterrupted whole-book offline playback. A completed
automatic window may start from its verified local files and remains usable
offline only to the end of that window.

A book becomes `complete` only after:

- every required track exists;
- each known byte length matches;
- the manifest and offline metadata snapshot are durably written;
- temporary files have been atomically moved to final locations.

Partial books remain inspectable and retryable. Completed files are never silently replaced by a failed retry.

### 10.3 Storage policy

- Preflight free space against expected bytes plus a safety margin.
- Exclude downloaded media and regenerable covers from iCloud/iTunes backup.
- Apply file protection compatible with playback while locked after first unlock, such as complete-until-first-user-authentication.
- Show storage by account and book.
- Support explicit deletion.
- For automatic cache records, support deletion after each completed chapter,
  immediately after book completion, or 24 hours after book completion; default
  to 24 hours. If the app is suspended at the deadline, perform overdue cleanup
  at the next launch or app activity.
- Never apply automatic cleanup to an explicit full-book download.
- Completed automatic files outside the current window continue to count
  toward actual storage while being excluded from window progress.
- Incomplete download records without current ranged-transfer metadata are
  invalid and are deleted. Byte-valid finalized books remain available.
- Never evict the currently playing track.
- If iOS removes or corrupts a local file, mark the download partial and offer repair instead of crashing.

Offline download of a server-transcoded replacement format is deferred unless Audiobookshelf exposes a stable downloadable transcode. Original supported files remain downloadable.

## 11. Progress, sessions, bookmarks, and conflicts

### 11.1 Durable local progress

Persist local playback position:

- at least every five seconds while playing;
- on pause;
- before and after seek;
- on chapter/track change;
- on app backgrounding;
- before replacing the current book;
- when a sleep timer ends;
- after an interruption.

Do not rely on an app-termination callback.

### 11.2 Online session sync

For an open streamed session:

- sync with `POST /api/session/<session-id>/sync`;
- send `{ "currentTime": <whole-book-seconds>, "timeListened": <new-real-seconds>, "duration": <whole-book-seconds> }`;
- sync approximately every 15 seconds while connected and after significant events;
- close with `POST /api/session/<session-id>/close`, optionally carrying the same final sync body, when the book changes or playback is deliberately ended.

`timeListened` is an acknowledged delta measured from monotonic, audible
forward playback. An ambiguous response marks that delta uncertain rather than
silently sending it again.

### 11.3 Offline session sync

Downloaded playback creates UUIDv4 local sessions. Persist them until acknowledged by:

- `POST /api/session/local`, or
- `POST /api/session/local-all`.

The persisted local position and session are authoritative while the download is
active. Do not look up remote progress or open a server playback session before
local playback starts. Control actions write local state first and do not await
network work. A single coalesced worker retries pending sessions after account
restoration, login or reauthentication, foreground restoration, or a new
network-path event. It uses normal request timeouts and leaves records intact
unless their exact IDs are acknowledged; conflict detection occurs only after a
successful local-session synchronization.

Prefer the batch endpoint with:

```json
{
  "sessions": [
    {
      "id": "6f0d7dd3-9b2d-4e32-819f-392d994ef334",
      "libraryId": "server-library-id",
      "libraryItemId": "server-library-item-id",
      "bookId": "server-book-id",
      "episodeId": null,
      "mediaType": "book",
      "mediaMetadata": { "title": "Example" },
      "chapters": [],
      "displayTitle": "Example",
      "displayAuthor": "Author Name",
      "coverPath": "/server/cover/path",
      "duration": 36000,
      "playMethod": 3,
      "mediaPlayer": "AVPlayer",
      "timeListening": 120,
      "startTime": 600,
      "currentTime": 720,
      "startedAt": 1785240000000,
      "updatedAt": 1785240120000
    }
  ],
  "deviceInfo": {
    "deviceId": "…",
    "clientName": "…",
    "clientVersion": "…",
    "manufacturer": "Apple",
    "model": "…"
  }
}
```

Each local playback-session object uses UUIDv4 `id`, numeric `playMethod: 3`, cumulative `timeListening`, whole-book `currentTime`, millisecond `updatedAt`, and the current library/item/book identifiers. The batch response is `{ "results": [{ "id": String, "success": Bool, "progressSynced": Bool, "error": String? }] }`.

Delete a pending session only when its matching result has `success == true`. `progressSynced == false` can legitimately mean that server progress was newer; refresh progress before deciding what to show. The single `/api/session/local` endpoint returns only an HTTP success status and is less useful for a durable queue. Do not use the obsolete `/api/me/sync-local-progress` workflow.

Bookmarks created offline are queued and reconciled after session/progress sync. The current bookmark API has no idempotency key, so before retrying an ambiguous create, refetch the item's bookmarks and compare item ID, time, and title. A failed mutation remains visible with a retry indicator.

### 11.4 Position conflict rules

The current server exposes progress `lastUpdate` in Unix milliseconds but no revision token or conditional mutation. Local-session import compares server `updatedAt` with the incoming session `updatedAt`; direct progress PATCH does not perform a conflict check.

Direct progress changes use `PATCH /api/me/progress/<library-item-id>` with the relevant subset of `duration`, `currentTime`, `progress`, `isFinished`, and `hideFromContinueListening`. The endpoint returns an empty 200 response.

Track a local `lastCommonServerUpdate` and position for each item.

- Socket.IO playback-progress events refresh browsing data only. A foreground
  player never lets those events move playback or present a conflict alert.
  Session progress is echoed over the user's subscription, including late
  events from stale sessions, so the active player owns its timeline through
  pausing, rewinding, seeking, and resuming.
- If only the local position changed since the last common update, upload it.
- If only the server position changed, adopt it while idle.
- If both changed, show a non-destructive conflict prompt with:
  - Continue from this device at `<time>`;
  - Continue from server at `<time>`.
- Choosing one creates a new common checkpoint and syncs deliberately.
- Before uploading queued local progress, fetch `GET /api/me/progress/<library-item-id>`. Use `lastUpdate` to determine whether the server moved after the common checkpoint.
- Timestamps are the only concurrency signal the current server provides. Account for clock skew and never claim this is atomic conflict prevention.

Marking a book finished or unfinished is an explicit progress mutation. It
currently performs a canonical detail and access recheck before submission but
does not yet compare the server timestamp with a persisted common checkpoint.
[GitHub issue #146](https://github.com/terminaloutcomes/bleat/issues/146)
tracks that pre-submission conflict check. Until it is complete, explicit
finished-state changes must not be described as implementing these conflict
rules.

## 12. Lifetime listening statistics

The app implements the local ledger, completion milestones, lifetime summary,
and private CloudKit merge. Paginated server-history import, user-facing
archive import/export, range charts, and large-ledger performance work remain
deferred in
[GitHub issue #26](https://github.com/terminaloutcomes/bleat/issues/26).

### 12.1 Metric definitions

Statistics use seconds internally as `Double` values and format only at the UI boundary. Every book key is `(AccountID, LibraryItemID)`; identical editions on different servers are distinct unless a future explicit merge feature says otherwise.

| Metric | Normative definition | Coverage |
| --- | --- | --- |
| Real time listened | Monotonic wall-clock seconds during confirmed forward, audible playback. Excludes pause, buffering, interruption, route loss, and seek handling | All devices from imported Audiobookshelf `timeListening`, with unsynchronized local time overlaid; exact local value is also retained |
| Audiobook time heard | Sum of forward media-timeline distance actually traversed while playing. A replay counts again; a seek does not | This app, from the point tracking begins |
| Effective average speed | `audiobookTimeHeard / realTimeListened` for slices that contain both values | This app |
| Books started | Distinct book keys with at least 30 accumulated seconds of real listening | All devices where session history remains available |
| Books completed | Distinct book keys for which a first-finish milestone has been observed. Marking a book unfinished later does not erase the lifetime milestone | Current server progress can seed the value; exact thereafter in this app |
| Chapters started | Distinct chapter keys with at least 10 seconds of audible forward traversal, or the whole chapter if shorter | This app |
| Chapters completed | Distinct chapter keys for which at least 90% of the chapter's timeline has been audibly traversed and the end boundary has been crossed without a seek | This app |
| Finished runtime | Sum of the canonical duration snapshot for each distinct completed book | Same coverage as Books completed |
| Listening sessions | Distinct playback-session IDs | All devices where server history remains available |

The primary count cards show distinct books and chapters. Per-book detail may additionally show total completion events, including rereads, but must not mix that value into the distinct lifetime total.

`media.duration` from the expanded item is the canonical finished-runtime snapshot. If it is absent, the app may sum valid `audioFiles[].duration` values and mark the result estimated. File byte length is not part of listening statistics.

### 12.2 Local measurement algorithm

The `PlaybackEngine` emits a statistics sample approximately every 0.5 seconds and immediately on state, rate, track, chapter, app-lifecycle, and seek transitions. Measurement uses `ContinuousClock`; persisted UTC timestamps are for reporting, never for measuring elapsed time.

For two consecutive samples in the same uninterrupted playback generation:

1. Require `AVPlayer.timeControlStatus == .playing`, an active audio session, a ready item, and no seek, interruption, route-loss, or buffering transition.
2. Compute positive whole-book position advancement. Discard negative advancement.
3. Record real time only when the position is advancing; this avoids counting a player that claims to be playing while stalled.
4. Record audiobook time as the observed positive advancement, capped at `realDelta × actualPlayerRate + 0.5 seconds` to reject an unmarked jump.
5. Split the resulting slice at chapter boundaries, local-midnight boundaries, and rate changes.

Every explicit or automatic seek increments a playback-generation counter and discards the interval spanning the seek. A seamless track transition keeps the generation because the whole-book timeline remains continuous. Replay through an already heard range creates new audiobook time but does not create another distinct chapter or book.

Persist accumulated slices with the same five-second durability target as playback position. The live Statistics screen combines durable slices with the uncommitted in-memory slice so its counters move without waiting for a server sync.

### 12.3 Server history and implementation limits

Use the current implementation as follows:

- `GET /api/me/listening-stats` returns `{totalTime, items, days, dayOfWeek, today, recentSessions}`. `totalTime` and the item/day buckets sum persisted session `timeListening`.
- `GET /api/me/listening-sessions?itemsPerPage=<n>&page=<n>` returns `{total, numPages, page, itemsPerPage, sessions}` in descending `updatedAt` order.
- `GET /api/me/stats/year/<year>` returns yearly listening totals, top authors/genres/narrator/month, `numBooksFinished`, `numBooksListened`, and cover samples.
- `GET /api/me/progress` supplies current progress records that can seed first-known finished-book milestones.

Do not treat those endpoints as richer than they are:

- session `timeListening` is real time supplied by clients;
- persisted session reads do not contain chapters or playback rate;
- a server session's entire time is assigned to its stored date rather than split across midnight;
- yearly sessions are selected by `createdAt`, and `numBooksListened` is currently deduplicated by `displayTitle`, not by item ID;
- a book that was finished and later reset may no longer be recoverable as a historical completion;
- there is no incremental history cursor or immutable statistics revision.

The pinned official iOS client likewise accumulates elapsed wall seconds into `timeListening`, sends that delta to the online session endpoint, and resets the local accumulator only after success. Its current Statistics screen shows server `totalTime`, distinct server day buckets, and the present `mediaProgress.isFinished` count. Those implementation choices confirm the contract but do not supply rate-aware or chapter-aware history. This specification uses a monotonic clock and a separate ledger to add that missing precision.

The app may use `/api/me/listening-stats` for a fast summary, but canonical per-session import uses paginated `/api/me/listening-sessions` and deduplicates by `(AccountID, sessionID)`. The current controller loads all of a user's sessions before slicing a page, so do not poll it. Perform a full import when an account is added, on explicit refresh, and no more than once per day automatically. Use pages of 500 by default to reduce repeated server-wide scans, adapt downward after memory-pressure or response-size failures, and show progress for large histories.

### 12.4 Reconciliation and multi-instance aggregation

Maintain two related sources:

- local `ListeningSlice` rows for exact playback observed by this app;
- `RemoteSessionSnapshot` rows for history imported from each Audiobookshelf account.

For all-device real time, aggregate remote snapshots plus local session time not yet known to be represented remotely. Associate every local slice with its online or offline UUIDv4 playback-session ID. After a confirmed online 2xx sync, advance the local expected remote total immediately. After a successful offline-session import, remove that session's pending overlay. When the corresponding remote session is later fetched, replace the expected snapshot rather than adding a second copy.

An ambiguous online sync leaves the local this-app statistic exact but creates a lower/upper bound for the all-device figure. Display `≈` and expose the uncertain range until a later session import resolves it. Never resolve uncertainty by blindly resending `timeListened`.

Remote snapshots are upserted when the same session ID has a newer `updatedAt`. A session disappearing from the server does not silently reduce a lifetime total already observed; deleting or rebuilding imported history is an explicit user action.

The All Accounts view aggregates account-scoped results only after each account has produced a valid result. An unavailable or reauthentication-required account appears as stale with its last successful import time. One server failure must not blank totals from other servers.

### 12.5 Chapter and completion identity

Chapter metadata is mutable and current server history does not retain it. Create a `ChapterKey` from the book key plus a stable local chapter UUID. On first encounter, map server chapters by ordered index, normalized title, and start/end times. On later metadata refresh:

- preserve the local UUID when boundaries and title still match within tolerance;
- create a new chapter identity when one chapter is split or materially replaced;
- never retroactively award completion merely because edited boundaries now cover previously heard time.

Book completion is recorded when either:

- server progress first reports `isFinished == true`; or
- this app reaches the natural end through forward playback without seeking across it; or
- an explicit Mark Finished mutation succeeds.

Store the completion time, duration snapshot, title/author snapshot, and evidence source. A later metadata edit updates current display data but not the historical duration snapshot without an explicit “Recalculate durations” action.

### 12.6 Retention, reset, and portability

Listening history contains personal behavioral data. It receives the same file protection as other structured app data and is never written to logs or analytics.

- Ordinary sign-out retains statistics.
- Removing an account presents separate choices for credentials/cache/downloads and listening history.
- “Reset listening statistics” identifies the affected account/range and is destructive only after confirmation.
- Export produces a versioned JSON document with no tokens, cookies, server-session URLs, or local media paths. The share sheet warns that titles and listening times are personal.
- Import validates schema and account mapping, then upserts by stable event/session ID so importing the same file twice changes nothing.
- Structured statistics remain eligible for encrypted device backup; downloaded audio and regenerable covers remain excluded.

Private CloudKit synchronization is opt-out and uses
`iCloud.com.terminaloutcomes.Bleat`. Mergeable ledger records, completion
milestones, non-secret account descriptors, and playback/download preferences
use the private database. Access and refresh tokens never enter CloudKit or
iCloud Keychain. Launch restores authoritative local state before scheduling
CloudKit synchronization as non-blocking background maintenance; a slow or
failed CloudKit operation never delays the signed-in or signed-out transition,
and an active operation can be cancelled and retried from Settings without
overlapping the abandoned operation. Disabling synchronization keeps all local
data and offers to retain or delete the private CloudKit zone. Saving primary
or local server settings immediately pushes the updated non-secret account
descriptor. A
different account descriptor fetched from CloudKit remains pending until the
user explicitly selects one complete structural configuration from a single
aggregate choice; cancelling preserves the candidates and pauses account sync;
keeping the device values pushes them back to CloudKit. A cloud-only account
likewise requires confirmation before it is added locally. On a fresh install,
the signed-out form exposes the same single-flight automatic/manual restore as
**Sync from iCloud**, including progress, empty-zone, and typed failure states.
The chosen descriptor remains inactive with `reauthenticationRequired` until a
mandatory native password authenticates the expected remote user and canonical
identity; rotating tokens remain device-only. Account descriptors
carry a generation ID and predecessor identity; a delayed predecessor is stale
and must be ignored and replaced without prompting or changing local settings.
Legacy device-generated account IDs are canonicalized from the normalized
primary server URL and remote user ID. Account descriptors retain legacy ID
aliases long enough to rekey account-scoped statistics fetched later. Save each
canonical CloudKit replacement before deleting its obsolete account or remote
session record; interrupted migration must converge on a later sync without
re-presenting the legacy configuration. This is a private-zone data migration,
not a CloudKit record-type or field deployment, and requires no CloudKit
Dashboard schema deployment.
`BLEAT_CLOUDKIT_MODE=disabled`
selects CloudKit-free entitlements for development teams that do not support
the capability; those builds do not initialize or present CloudKit
synchronization. `enabled` is the default and the only other supported value.
Every CloudKit operation and CKSyncEngine persistence/apply callback emits a
typed local diagnostic lifecycle. Failures preserve their originating
operation, exact `CKError.Code`, privacy-safe partial-failure codes, and retry
delay through service, presentation, and diagnostics boundaries; UI copy must
identify iCloud and must never translate a CloudKit failure into an
Audiobookshelf outage. Local diagnostics exclude localized descriptions,
CloudKit record identifiers, and CloudKit `userInfo`. On native macOS, remote
OpenTelemetry export is out of scope and the same typed lifecycle remains
on-device only. The iOS build retains the reviewed remote telemetry behavior.
Successful record system fields, including server change tags, must survive
process relaunch. Mutable records retain the last successfully synchronized
payload digest, and statistics rows retain explicit synchronized state plus
durable account-scoped deletion tombstones. Local preparation must fetch and
enqueue only new, changed, or deleted records, while interrupted or failed
sends remain pending for retry. Missing synchronization state on older rows is
reconciled rather than treated as success. A pending local deletion takes
precedence over a racing fetched modification, and deleting the CloudKit zone
marks retained local statistics for upload if synchronization is enabled again. Fetched
statistics changes are decoded as a batch and imported with one bounded
repository transaction per CloudKit callback rather than one full-ID scan and
save per record; one invalid fetched record does not discard valid records in
the same callback. Zone setup, fetch, fetched-record application, local
preparation, upload, and sent-change reconciliation emit privacy-safe duration
and available record-count diagnostics for successful and failed stages.
Presentation summary refresh follows a completed
CloudKit result and does not keep the iCloud state active. A
`serverRecordChanged` save failure is resolved against the
returned server record: matching payloads adopt its current system fields,
unambiguous newer local configuration is rebased and retried once, and an
ambiguous preference merge remains pending without overwriting either value.
The app shows the fields that differ and requires the user to choose the
complete current device snapshot or complete iCloud snapshot. The pending
choice survives relaunch, suppresses automatic configuration uploads, and each
typed resolution operation emits the same local and consent-gated remote
diagnostic lifecycle as other CloudKit operations.
`BLEAT_APP_ATTEST_MODE` likewise accepts only `enabled` or `disabled` and
defaults to `enabled`. `BUILD_WITHOUT_PAID_DEVELOPER` accepts only `YES` or
`NO`, defaults to `NO`, and when `YES` overrides both effective capability
modes to `disabled`. Xcode selects one of four iOS entitlement files from the
effective CloudKit/App Attest matrix; the fully disabled file retains only the
Personal-Team-compatible Keychain entitlement. Unsupported build values fail
the build. The effective modes are embedded in the app's information property
list so signing capabilities and runtime behavior use the same values; a
missing or unknown runtime value fails closed as disabled.

## 13. Local data model

Use SwiftData for structured local state and the filesystem for audio bytes.

Every shipped SwiftData schema requires a versioned migration fixture and
coverage for upgrade, backup/restore, account removal, and app-data reset
journeys ([GitHub issue #47](https://github.com/terminaloutcomes/bleat/issues/47)).

Suggested models:

- `ServerAccount`
  - local account ID
  - normalized base URL
  - display name
  - remote user ID and username
  - server version
  - auth capabilities
  - connection/reauth state
- `LibraryCache`
- `BookSummaryCache`
- `BookDetailCache`
- `ProgressCheckpoint`
- `PendingPlaybackSession`
- `PendingBookmarkOperation`
- `DownloadManifest`
- `DownloadTrack`
- `MetadataDraft`
- `PlaybackPreference`

Credentials are represented only by a Keychain reference, never token text.

Use strongly typed wrappers such as `AccountID`, `LibraryID`, `LibraryItemID`, and `PlaybackSessionID` to prevent accidental identifier mixing. Remote DTOs, domain models, and SwiftData models are separate types.

## 14. Architecture

### 14.1 Components

| Component | Responsibility |
| --- | --- |
| `AccountStore` | Account lifecycle and current browsing account |
| `TokenVault` actor | Keychain reads/writes and atomic token replacement |
| `AuthCoordinator` actor | Login state and single-flight token refresh per account |
| `AudiobookshelfAPI` actor | Typed endpoint operations and DTO mapping |
| `LibraryRepository` actor | Server/cache merge, pagination, search, invalidation |
| `MetadataRepository` actor | Draft creation, best-effort `updatedAt` stale checks, and mutation |
| `PlaybackEngine` | AVPlayer/AVAudioSession lifecycle and global playback state |
| `AppModel` playback-start coordinator | Account/item validation, active/downloaded/streamed routing, typed positioning and failure outcomes, and stale-request suppression |
| `ProgressCoordinator` actor | Durable checkpoints, session accounting, conflict resolution |
| `StatisticsRepository` actor | Local slice recording, remote-session import, deduplication, metric aggregation, coverage labels, and export/import |
| `PlaybackRouteAdapter` | Builds version-verified public-session or HLS media URLs from a playback session |
| `DownloadModel` | Main-actor download intent and transfer reconciliation |
| `DownloadStorage` actor | Validated manifests, ranged partial bytes, and finalized media |
| `NowPlayingCoordinator` | MediaPlayer metadata and remote commands |
| `CarPlayCoordinator` | Active-account CarPlay templates, generation-safe browsing, selection, artwork, and Now Playing presentation |

UI feature models use Observation and are `@MainActor`. Network, persistence coordination, token refresh, and sync use actors. Avoid a general service locator and avoid exposing raw DTOs to views.

### 14.2 Suggested source layout

```text
App/
Core/
  Accounts/
  Auth/
  Networking/
  Persistence/
  Diagnostics/
Audiobookshelf/
  API/
  DTO/
  Mapping/
Playback/
  Engine/
  Routes/
  NowPlaying/
  Progress/
Statistics/
  Ledger/
  Import/
  Aggregation/
  Export/
Downloads/
Features/
  Home/
  Library/
  Search/
  BookDetail/
  MetadataEditor/
  Player/
  Statistics/
  Downloads/
  Settings/
```

AppAuth-iOS `2.0.0` is the sole third-party runtime dependency. It is pinned to
revision `145104f5ea9d58ae21b60add007c33c1cc0c948e`, published by the OpenID
Foundation under Apache-2.0, and isolated behind Bleat's internal OIDC adapter.
The upstream release signature and published security-advisory list were
checked when accepted; dependency updates require the same review.

## 15. Current implementation integration map

These routes and shapes are audited against the pinned v2.36.0 implementation. DTOs still require saved fixtures because the server deliberately emits its compatibility “old JSON” model to clients.

| Capability | Current operation and important shape |
| --- | --- |
| Discover server/auth | `GET /status` → `app`, `serverVersion`, `isInit`, `language`, `authMethods`, `authFormData` |
| Local login | `POST /login`, JSON username/password, `x-return-tokens: true` |
| Begin mobile OIDC/PKCE | `GET /auth/openid` with challenge, S256, callback URI, `response_type=code`, client state; retain cookies and the 3xx `Location` |
| Provider-to-app bridge | Provider returns to server `GET /auth/openid/mobile-redirect`; server redirects to the allow-listed app callback |
| Complete mobile OIDC/PKCE | `GET /auth/openid/callback?state=…&code=…&code_verifier=…` using the initial cookie jar |
| Refresh | `POST /auth/refresh` with `x-refresh-token`; response user contains the rotated access and refresh tokens |
| Logout | `POST /logout` with `x-refresh-token` → `{redirect_url}` |
| Validate token/get user | `POST /api/authorize` with bearer token |
| List libraries | `GET /api/libraries` |
| List library items | `GET /api/libraries/<id>/items?limit=&page=&sort=&desc=&filter=&minified=&collapseseries=&include=` |
| Personalized shelves | `GET /api/libraries/<id>/personalized?limit=&include=progress` |
| Search library | `GET /api/libraries/<id>/search?q=&limit=` |
| Get expanded item/progress | `GET /api/items/<id>?expanded=1&include=progress` |
| Start playback | `POST /api/items/<id>/play` with force flags, MIME list, media player, and device info |
| Direct-play bytes | `GET /public/session/<session-id>/track/<track-index>` while the session is open |
| Transcoded HLS | Returned `audioTracks[0].contentUrl`, currently `/hls/<session-id>/output.m3u8` |
| Sync/close open session | `POST /api/session/<id>/sync`, `POST /api/session/<id>/close` |
| Sync offline sessions | Prefer `POST /api/session/local-all` with `{sessions, deviceInfo}`; single-session fallback is `/api/session/local` |
| Read/update progress | `GET` or `PATCH /api/me/progress/<library-item-id>` |
| Read current user's progress list | `GET /api/me/progress` → `{mediaProgress}` |
| Read lifetime listening summary | `GET /api/me/listening-stats` → `totalTime`, item/day/day-of-week buckets, `today`, and up to 10 recent sessions |
| Page current user's listening sessions | `GET /api/me/listening-sessions?itemsPerPage=&page=` → `total`, `numPages`, and compatibility playback-session objects |
| Page sessions for one item | `GET /api/me/item/listening-sessions/<library-item-id>`; the optional episode segment is out of scope for books |
| Read yearly server statistics | `GET /api/me/stats/year/<year>`; use for presentation/cross-checking, not canonical distinct-book identity |
| Read bookmarks | `GET /api/me/bookmarks/<library-item-id>` |
| Create bookmark | `POST /api/me/item/<item-id>/bookmark` with `{time, title}` |
| Rename bookmark | `PATCH /api/me/item/<item-id>/bookmark` with `{time, title}` |
| Delete bookmark | `DELETE /api/me/item/<item-id>/bookmark/<time>` |
| Download one source file | `GET /api/items/<item-id>/file/<ino>/download` with bearer header |
| Read cover | `GET /api/items/<id>/cover?width=&height=&format=&ts=` |
| Update metadata | `PATCH /api/items/<id>/media` with `{metadata, tags}` |
| Upload cover | Multipart `POST /api/items/<id>/cover`, field `cover` |
| Delete item | `DELETE /api/items/<id>`; add `hard=1` only for confirmed permanent server-file deletion |

All request construction, including path-prefix handling, belongs in one route builder. Endpoint strings must not be scattered through views.

### 15.1 Contract-source policy

Every route adapter and non-trivial DTO must carry a source comment linking to a pinned implementation file listed in section 24. When updating the audited baseline:

1. compare the relevant server router/controller/model files;
2. regenerate captured fixtures from a disposable server;
3. run the minimum/current compatibility matrix;
4. update this table and the baseline commit together.

Do not update a DTO merely because the published API reference says something different.

## 16. Error handling and diagnostics

Preserve the failed operation together with a typed, user-safe failure cause.
Do not collapse distinct failures into a generic unavailable state. The UI may
group causes only when the resulting message, retry policy, and diagnostics
code remain unambiguous. Define user-facing causes including:

- server unreachable;
- TLS trust failure;
- unsupported/old server;
- authentication required;
- permission denied;
- item removed or unavailable;
- media format/playback failure;
- download/storage failure;
- progress conflict;
- partial, stale, or uncertain statistics coverage;
- malformed/incompatible server response.

Use `OSLog` categories for auth, API, playback, download, and sync. Logs must redact:

- bearer and refresh tokens;
- cookies;
- passwords;
- PKCE verifier;
- authorization codes;
- callback query strings;
- playback session IDs and `/public/session/` or `/hls/` URLs;
- custom secret headers;
- local file paths containing user metadata.

Diagnostics should show the privacy-safe hostname and port, without URL paths
or queries, for the primary or local endpoint last used for authentication and
API traffic. It should also show the configured WebSocket endpoint and current
WebSocket connection state. A central account-aware endpoint activity boundary
must publish live changes from routed and direct API/authentication requests,
WebSockets, cover requests, streamed playback sources, and foreground or
restored background downloads; Diagnostics must not rely on a one-time copied
snapshot or create a shareable report.

Every diagnostic failure event carries its operation and a stable typed cause.
Do not derive either from localized text, serialized errors, or raw server
payloads.

The Diagnostics status screen remains available in every build and presents
live operational state, the Bonjour troubleshooter, and telemetry consent. It
does not export a diagnostic snapshot, retain app-owned diagnostic history, or
create a temporary diagnostic sharing file. Typed, redacted diagnostic events
continue to emit through the applicable `OSLog` categories in every build.

Remote diagnostic telemetry is a separate, optional channel. Its purpose is to
diagnose bounded technical application operations without collecting user,
server, account, or audiobook content. It defaults off and may be enabled only
through the device-local **Share diagnostic telemetry** control on the
Diagnostics screen. The consent preference is not synchronized through iCloud.
Remote export is out of scope on native macOS: that build must not create App
Attest keys, request telemetry tokens, retain export batches, or send OTLP.
On iOS, disabling it persists withdrawal before synchronously notifying the
remote telemetry runtime; that runtime must stop export and token renewal before
returning, then clear memory-only telemetry credentials and purge buffered
remote telemetry. The Diagnostics screen remains available while signed out and
through the unavailable-startup screen. Telemetry initialization or runtime
failure must never affect launch, browsing, authentication, downloads, playback,
transcription, synchronization, or local Diagnostics.

The reviewed resource allowlist is `service.name=bleat`, an opaque random
`service.instance.id` scoped to the app installation, normalized numeric app
version and build, typed Apple platform, and numeric operating-system version.
The hardware model is excluded. The reviewed span
names are app launch, account connection, library refresh, playback preparation,
playback start, download transfer, playback progress synchronization, and
transcription, plus private CloudKit synchronization. Telemetry authentication
is one parent span, with challenge, enrolment, and token HTTP client spans as
children. Each client span propagates W3C trace context so the matching
`bleat-api` server span is part of the same trace. Span attributes are limited to a subsystem derived from the span
name, typed success/cancellation/failure outcome, privacy-safe failure category,
optional downloaded/streamed/offline/remote/cache source, and a retry bucket of
none, one, two, or three-or-more. Duration comes from span timing and is not an
application-supplied attribute. Application code must not receive an arbitrary
span-name or attribute-dictionary API.

The reviewed log schema is initially limited to private CloudKit lifecycle
events. Its event names and static body are closed; attributes may contain only
the typed CloudKit operation or stage, outcome, privacy-safe failure category,
exact CloudKit code, partial codes, retryability, retry delay, duration, and
bounded record count. Raw
errors, descriptions, `userInfo`, records, accounts, servers, and correlation
identifiers are excluded. Logs use the same consent generation, resource,
authenticated OTLP origin, foreground/background lifecycle, and synchronous
withdrawal gate as spans. Their SDK queue is memory-only, bounded to 2,048
records, and is not replayed after relaunch; the two-hour/128 MiB persistent
policy remains specific to completed span batches.

When enabled, the reviewed collection policy samples every eligible trace.
Temporary retained telemetry is limited to two hours and 128 MiB, has no
separate span-count cap, and evicts the oldest spans first at the byte limit.
The application owns a private OpenTelemetry provider with the SDK batch span
processor and a persistence-first exporter decorator. Completed batches are
atomically written to a protected, backup-excluded Application Support
directory before downstream delivery, drained oldest-first, and deleted only
after downstream success. Failed delivery retries with bounded foreground
backoff and resumes after relaunch or foreground activation. Backgrounding
requests a best-effort non-main-actor flush with a two-second caller-visible
deadline and adds no telemetry background mode. Withdrawal synchronously gates
new spans and downstream attempts and invalidates the current storage
generation before asynchronous shutdown and purge, so rapid re-enablement
cannot export withdrawn data. The downstream exporter remains injectable;
when authentication and OTLP origins are configured, production creates one
ephemeral `URLSession` using the platform-best Darwin TLS transport and system
trust. Every export resolves the current memory-only token immediately before
the OTLP/HTTP protobuf request and attaches exactly one bearer authorization
header. OTLP/HTTP is required for the production route because Cloudflare
Tunnel [does not support gRPC through a public
hostname](https://developers.cloudflare.com/network/grpc-connections/); HTTPS
and platform TLS validation remain mandatory. A typed HTTP 401 unauthenticated
result compare-invalidates the rejected token and permits one
refresh/retry; permission rejection and transport failures do not retry inside
the exporter and leave the persisted batch available to the existing bounded
drain policy. Token renewal does not recreate the tracer provider, batch
processor, persistence exporter, or URL session. Missing or invalid transport
configuration retains the unavailable sink.

Telemetry authentication is fully lazy. Enabling consent creates no App Attest
key, network request, challenge, enrollment, assertion, or token. The first
`currentToken()` request starts enrollment or token issuance, and concurrent
requests share that operation. A token with more than two minutes remaining is
reused in memory; there are no refresh timers. Transient failures establish a
bounded jittered backoff observed only by later token requests. Disabling
consent cancels the active operation and clears the memory-only token while
retaining enrollment for later re-enablement.

The client gates App Attest on `DCAppAttestService.isSupported`, treats macOS as unsupported, and retains only the App Attest key identifier plus an
opaque backend installation identifier in one non-synchronizing, device-only
Keychain record. Invalidated keys clear that record and restart enrollment.
When App Attest is enabled, Debug iOS builds use its development entitlement
and Release iOS builds use its production entitlement. Debug may select the
deterministic fake attester; Release cannot. System App Attest is unavailable unless
the effective `BLEAT_APP_ATTEST_MODE` is exactly `enabled`; the Debug fake
attester remains available independently for disposable development tests. The
backend base URL comes only from
`BLEAT_TELEMETRY_AUTH_BASE_URL`; missing configuration leaves authentication
unavailable, Release requires HTTPS, and Debug permits HTTP only for loopback.
The OTLP origin comes only from `BLEAT_TELEMETRY_OTLP_ENDPOINT` and must be an
HTTPS origin without credentials, path, query, or fragment. Traces and logs use
OTLP/HTTP protobuf at `/v1/traces` and `/v1/logs` through one ephemeral
`URLSession`, retaining platform TLS validation without a custom trust root or
verification bypass. Background deadlines and withdrawal cancel active
requests, while exporter shutdown invalidates the shared session after both
signal processors release it.

The telemetry authentication backend persists installation identity and
challenge state in PostgreSQL through typed ORM statements. Installations use
opaque UUIDs and retain the App Attest key identifier, 65-byte P-256 public key,
typed App Attest environment, active or disabled status, monotonic assertion
counter, and timestamps. Challenge responses contain 32 random bytes encoded as
unpadded base64url, while persistence retains only the SHA-256 digest, typed
purpose, optional installation binding, expiry, and consumption timestamp.
Consumption and assertion-counter advancement are conditional atomic updates.
In development mode the backend verifies the fake attester's P-256
proof-of-possession, enrolls through the same persisted installation boundary,
and atomically advances assertion counters before issuing a ten-minute ES256
JWT. Development signing remains ephemeral per process. Production loads one
SEC1 DER P-256 private key from a mounted deployment secret and fails before
binding if the key is missing or invalid. Both modes issue only `iss`, opaque
installation `sub`, `aud=bleat-telemetry`, `scope=telemetry:write`, `iat`, and
`exp`; there is no refresh token or additional identity claim. Discovery is
exposed at `/.well-known/openid-configuration` and JWKS at
`/.well-known/jwks.json`, with bounded public caching, deterministic ETags, and
conditional responses. A public-only scheduled key set supports rotation: a
new key is prepublished before activation and the prior public key remains
available for at least the maximum token lifetime plus clock skew. Private keys
never enter that set, the container image, normal logs, or repository fixtures.

Production mode uses a structurally separate verifier that validates Apple's
certificate path and pinned App Attest root, attestation nonce, App ID hash,
AAGUID environment, credential and certificate/COSE public key consistency,
and, when supplied by iOS 27 or later, configured bundle-version and
validation-category policy. Earlier supported Apple operating systems omit
these recently introduced authenticator-data extensions; their evidence still
requires the complete certificate, nonce, application, credential, signature,
and counter checks. It verifies assertions with the stored key and environment
before atomically advancing the monotonic counter; replay and concurrent
counter conflicts are rejected. Only that authenticated installation principal
can reach signing. Disabling an installation prevents future issuance, while
an already-issued token expires naturally within ten minutes.

Production ClickHouse tables retain traces for seven days and logs for 90
days. The Collector has no separate durable store. Production query access is
restricted to the deployment operator through authenticated HyperDX access,
with direct database access limited to cluster workloads and deployment
administrators. PostgreSQL authentication records currently have no automatic
expiry and remain until operator deletion or service decommissioning;
withdrawing application consent stops authentication and export and purges
local telemetry, but does not delete the existing server enrollment. The
service's server spans can retain a client network address and bounded
user-agent for operational diagnostics, so App Store disclosure treats this
other diagnostic data as linked. Client-originated spans and logs contain the
disclosed opaque installation identifier for correlation.

The repository validates a pinned stock OpenTelemetry Collector Contrib ingress
configuration against the development token service through
`mise run test:telemetry`. The disposable gate drives the reviewed Swift
pipeline and fake attester through enrollment, JWT issuance, authenticated
OTLP/HTTP protobuf export, and a private capture Collector. It checks exact issuer and audience
authentication, rejects missing or malformed credentials and messages larger
than 1 MiB, bounds memory, batching, retry, and the in-memory exporter queue,
forwards accepted traces only over a private internal route, and remains healthy
when that exporter is unavailable. Captured wire data must contain the exact
reviewed resource and span fields and none of the prohibited values in this
section. The token's `telemetry:write` scope remains part of the single-purpose
token. Stock Collector processors can inspect verified claims and silently drop
telemetry, but the stock OIDC authenticator cannot hard-reject an OTLP RPC based
on a custom claim. Hard scope rejection is not required while the issuer
produces only this narrow telemetry token with exact issuer and audience
semantics. A separate gateway and per-installation telemetry accounting are not
required.

`docs/architecture-logging.md` defines the production deployment topology. One
stock Collector process owns distinct OIDC-authenticated device and private API
OTLP/HTTP receivers and exports both signal identities directly to ClickHouse.

The backend's server-generated HTTP request spans follow the stable
OpenTelemetry HTTP server conventions. They distinguish the immediate socket
peer from an originating `client.address` resolved only through explicitly
trusted proxy CIDRs and bounded Cloudflare, RFC 7239 `Forwarded`, or
`X-Forwarded-For` parsing. Forwarding headers from untrusted peers, malformed or
conflicting families, and excessive input fall back to the socket peer. These
originating addresses are server-side observability data subject to the
backend's access and retention controls; raw forwarding chains are not exported
or normally logged. Temporary local forwarding diagnostics require explicit
configuration and remain excluded from OTLP logs.

Client-originated remote telemetry must never contain credentials, tokens,
cookies, authorization headers, playback session routes, App Attest evidence,
backend
JWTs, usernames, account identifiers, server URLs or network
discovery data, IP addresses, audiobook/author/series/library names, filenames,
filesystem paths, cover or media URLs, metadata, transcript/subtitle content,
search or other entered text, HTTP bodies, or unreviewed URLs and query strings.
The shipped pipeline is expected to require App Store disclosure as diagnostic
data; its final categories, linkage declaration, privacy manifest, and actual
wire schema must be re-audited before release as part of GitHub issue 68.

## 17. Security and privacy requirements

- HTTPS and system trust validation are mandatory in production.
- Do not implement “accept any certificate.”
- Do not pin a public certificate; self-hosted servers legitimately rotate certificates and may use private CAs.
- Store no secrets in SwiftData, plist files, logs, crash annotations, or URLs.
- Before the first release, scan logs, diagnostics, persistence, exports, URLs,
  live-test artifacts, and Release archives for seeded secrets and bearer-like
  values ([GitHub issue #48](https://github.com/terminaloutcomes/bleat/issues/48)).
- Diagnostics must emit typed events through `OSLog` without creating or
  sharing an app-owned diagnostic snapshot, history, or export file.
- Treat playback session IDs as transient bearer-like capabilities even though they are not JWTs.
- Use secure random generation from Security/CryptoKit for OAuth material.
- Enforce exact OAuth callback matching.
- Apply server/account scoping to every cache and file lookup.
- Sanitize all remote filenames and rich text.
- Do not allow remote metadata to select arbitrary local paths.
- Treat downloaded media as private user data.
- Treat listening slices, completion milestones, titles in exports, and daily activity as private behavioral data.
- Provide an in-app “Delete all local data for this account” action.
- Support local-network privacy usage text if connecting to LAN addresses triggers iOS permission.
- Document collected data accurately in App Store privacy declarations; by default, data remains between the device and the user's configured servers.

## 18. Accessibility and usability

- Full Dynamic Type support without clipping essential controls
  ([GitHub issue #38](https://github.com/terminaloutcomes/bleat/issues/38)).
- VoiceOver labels include action, title, current state, and time where relevant
  ([GitHub issue #39](https://github.com/terminaloutcomes/bleat/issues/39)).
- Player actions remain usable without relying on artwork or colour.
- Minimum 44-point interaction targets
  ([GitHub issue #45](https://github.com/terminaloutcomes/bleat/issues/45)).
- Support Bold Text ([GitHub issue #44](https://github.com/terminaloutcomes/bleat/issues/44)),
  Increase Contrast ([GitHub issue #43](https://github.com/terminaloutcomes/bleat/issues/43)),
  and Reduce Motion ([GitHub issue #41](https://github.com/terminaloutcomes/bleat/issues/41)).
- Keep primary navigation, login, browsing, and playback layouts usable in
  portrait and landscape on iPhone and iPad.
- Provide keyboard shortcuts on iPad for play/pause, skip, speed, and search
  ([GitHub issue #40](https://github.com/terminaloutcomes/bleat/issues/40)).
- Format times and numbers with locale-aware APIs.
- VoiceOver labels for statistics state the metric, value, selected range, account scope, and whether coverage is all-device, this-app-only, stale, or approximate.
- All destructive actions require clear confirmation and identify the affected server/account.

## 19. Performance and reliability targets

- Library browsing remains responsive with at least 10,000 cached books, with
  launch, memory, energy, storage, and main-actor evidence recorded in
  [GitHub issue #46](https://github.com/terminaloutcomes/bleat/issues/46).
- No full-library expanded fetch.
- No audio file or complete HTTP response is held in memory.
- UI work remains off the main thread except observable state publication.
- Playback must survive SwiftUI view reconstruction and account-tab changes.
- An app crash/relaunch loses no more than five seconds of local position.
- A failed token refresh affects one account, not global app state.
- Valid ranged download tasks are restored deterministically after relaunch;
  invalid or obsolete background tasks are cancelled.
- Repeated play taps cannot create multiple simultaneous server sessions.

The following targets apply to the deferred post-MVP statistics work tracked in
[GitHub issue #26](https://github.com/terminaloutcomes/bleat/issues/26):

- Statistics sampling adds no more than 1% sustained CPU overhead during local playback on the oldest supported device.
- Aggregation over 250,000 listening slices completes off the main actor and publishes a cached Lifetime summary within 500 ms after launch.
- Statistics imports are resumable, deduplicated, and rate-limited so opening the Statistics screen does not repeatedly make the server scan all session history.

## 20. Testing strategy

### 20.1 Unit tests

- URL normalization and path-prefix preservation;
- typed ID isolation;
- JSON decoding fixtures from minimum/current server versions;
- rotating-token atomic replacement;
- 20 concurrent 401s produce one refresh request;
- whole-book/track/chapter time mapping;
- speed persistence and pitch-algorithm selection;

The following advanced statistics tests remain post-MVP under
[GitHub issue #26](https://github.com/terminaloutcomes/bleat/issues/26):

- wall-clock `timeListened` accounting at 0.5×, 1×, 2×, and during buffering;
- audiobook-time integration at 0.5×, 1×, 2×, and 3×;
- pause, stall, seek, backward replay, rate change, chapter boundary, track boundary, and midnight slice splitting;
- one real hour at 2× produces one real hour and approximately two audiobook hours;
- seeks add neither real time nor audiobook time, while replayed forward audio adds audiobook time again;
- chapter-start and chapter-completion thresholds, including metadata edits and chapter splits;
- distinct book/chapter counts across accounts with colliding remote IDs and identical titles;
- finished-runtime snapshots remain stable after a later metadata duration edit;
- remote-session plus pending-local aggregation never counts the same session twice;
- ambiguous online sync produces an uncertainty bound without altering exact this-app time;
- repeated statistics import and repeated JSON import are idempotent;
- online `timeListened` reports contain deltas rather than cumulative session totals;
- an ambiguous `/sync` response cannot silently resend the same listening delta;

MVP unit coverage continues with:

- progress conflict detection;
- metadata patch generation and stale-draft detection;
- download manifest state transitions and path sanitization.
- automatic whole-file lookahead selection, playback-bandwidth gating,
  cache/manual ownership, live byte aggregation, chapter-boundary eviction,
  and delayed book-completion cleanup.

### 20.2 Network integration tests

Use a disposable Audiobookshelf container with a seeded library:

- local login and refresh rotation;
- subdirectory deployment;
- limited user permissions;
- multi-file MP3 book;
- single M4B book;
- FLAC book;
- a format that requires transcode;
- metadata and cover updates;
- library-record-only and permanent-file item deletion;
- stream session sync/close;
- offline local-session synchronization;
- `/api/me/listening-stats`, paginated `/api/me/listening-sessions`, `/api/me/progress`, and `/api/me/stats/year/<year>` fixtures from the pinned implementation;
- large session history import, concurrent new sessions during paging, and a deleted server session;

### 20.3 Media tests

- range seeks through `/public/session/<id>/track/<index>` near the beginning, middle, and end of a long file;
- repeated seeking;
- track transitions with negligible missing/duplicate audio;
- HLS playback from the returned `/hls/<session-id>/output.m3u8` with relative segments and no undocumented header injection;
- public direct-play and HLS URLs fail after their session is closed;
- local/remote source transition;
- interruption and Bluetooth removal;
- background and locked-screen playback;
- AirPlay transport commands, metadata, whole-book seeking, chapter controls,
  and featured playback-rate changes;
- speed changes across track boundaries;
- end-of-chapter sleep timer at non-1× speeds.

### 20.4 Download tests

- app killed and relaunched mid-download;
- network changes from Wi-Fi to cellular under each policy;
- access token expires mid-queue;
- every source-file download uses `/api/items/<item-id>/file/<ino>/download` with a bearer header and never `?token=`;
- server unavailable and later restored;
- insufficient disk space;
- bad byte length/truncated file;
- hundreds of small tracks without main-thread stalls;
- deleted local file repaired cleanly.

### 20.5 UI tests

- add two servers and two users on one server;
- switch accounts without cache bleed;
- reauthenticate one account while another remains usable;
- VoiceOver and largest Dynamic Type;
- permission-gated metadata/download controls;
- offline playback and pending-sync indicators;
- metadata conflict choice;
- accidental scrub protection.
- multiple author and series controls, clearable author browsing, grouped
  search selection, series navigation with Reduce Motion and large Dynamic
  Type, and valid/malformed cold and warm `bleat` links.

## 21. Delivery phases

### Phase 0 — risk spikes

Prove before building broad UI:

1. Single-flight refresh rotation.
2. Session-scoped direct-file range playback through `/public/session/<id>/track/<index>`.
3. Transcoded HLS playback through the returned `/hls/<session-id>/output.m3u8`.
4. Bearer-authenticated background download restoration and 401 rescheduling.

If one of these fails, revise the architecture before proceeding.

### Phase 1 — accounts and library

- account store and Keychain;
- local username/password login;
- refresh/logout;
- server/library discovery;
- paginated browsing, search, cache;
- book detail.

### Phase 2 — playback and sync

- single/multi-file playback;
- global timeline and chapters;
- speed control;
- background audio;
- Now Playing and remote commands;
- streamed session sync;
- sleep timer and bookmarks.

### Phase 3 — offline

- background download manager;
- manifests and storage UI;
- local playback;
- local-session sync and conflict UI;
- network/storage policies.

### Phase 4 — metadata and release polish

- metadata and cover editing;
- permission/error states;
- accessibility;
- diagnostics;
- first-release CI, migration, security, live-smoke, and redacted-artifact
  coverage ([GitHub issue #35](https://github.com/terminaloutcomes/bleat/issues/35));
- scheduled compatibility, recovery, performance, and flake jobs
  ([GitHub issue #34](https://github.com/terminaloutcomes/bleat/issues/34));
- clean-checkout validation, signed beta coverage, App Store privacy and
  entitlement review, release notes, and the final compatibility baseline
  ([GitHub issue #36](https://github.com/terminaloutcomes/bleat/issues/36)).

## 22. Release acceptance criteria

The 1.0 release is acceptable only when:

- [ ] **AC-01:** Two different Audiobookshelf accounts can remain signed in concurrently.
- [x] **AC-02:** No token, cookie, password, verifier, or OAuth code appears in
  logs or media URLs. `mise run test:release-secrets` verifies the native-auth
  Release boundary recorded in `docs/release-evidence/secret-leakage.md`.
- [ ] **AC-03:** Native username/password login, rotating refresh tokens, and logout work without an identity provider.
- [ ] **AC-04:** Twenty concurrent expired-token requests cause one refresh and at most one retry each.
- [ ] **AC-05:** Server path prefixes work for API, covers, playback, and downloads.
- [ ] **AC-06:** A limited user cannot see edit/download actions they lack permission to use.
- [ ] **AC-07:** MP3, M4B/AAC, FLAC, and one transcoded format pass streaming tests.
- [ ] **AC-08:** Seeking a long remote file uses range requests and does not download the whole file first.
- [ ] **AC-09:** Streaming uses the current session-scoped `/public/session/` and `/hls/` routes without token query parameters or undocumented AVFoundation header options.
- [ ] **AC-10:** Speed remains correct through pause, track change, lock, interruption, and relaunch.
- [ ] **AC-11:** Lock Screen/Control Center/Bluetooth/AirPlay controls report the whole-book position correctly.
- [ ] **AC-21:** Multi-file track boundaries neither skip nor repeat material beyond a documented tolerance.
- [ ] **AC-22:** Downloads continue or recover after suspension, termination, token refresh, and connectivity loss.
- [ ] **AC-23:** Downloaded media plays while the server is offline.
- [ ] **AC-24:** Offline sessions synchronize once and are not duplicated.
- [ ] **AC-25:** Concurrent local/server progress never silently overwrites both changed positions.
- [ ] **AC-26:** Metadata editing performs the documented best-effort `updatedAt` stale-draft check and does not claim atomic conflict prevention.
- [ ] **AC-29:** Server item deletion is permission-gated, distinguishes library removal
  from permanent file deletion, and stops active playback before deletion.
- [ ] **AC-27:** Removing an account cannot leave credentials, transcripts, or cross-account cache records behind.
- [ ] **AC-28:** The app remains usable with VoiceOver and the largest Dynamic Type size.

## 23. Deferred enhancements

- [listening statistics and portability](https://github.com/terminaloutcomes/bleat/issues/26),
  including paginated history import, archive import/export, advanced views,
  and the performance work described in section 12;
- [managed CarPlay entitlement and real-environment validation](https://github.com/terminaloutcomes/bleat/issues/24);
- [signed native macOS authentication and Keychain persistence validation](https://github.com/terminaloutcomes/bleat/issues/25);
- Apple Watch remote and offline transfer;
- widgets and Live Activities;
- Siri/App Intents;
- podcasts and ebooks;
- metadata provider search/matching;
- chapter editor and audio-track reordering;
- configurable reverse-proxy/service-token headers;
- Bonjour discovery;
- silence skipping, voice boost, and equalizer;
- series bulk download;
- offline transcoding format selection;
- deliberate cross-server edition merging for statistics.

## 24. References

Audiobookshelf implementation baseline:

- [Server v2.36.0 baseline commit](https://github.com/advplyr/audiobookshelf/commit/96d4021a3cd45f67bf374b65abafbe5d73e926b5)
- [Server route mounting and `/status`](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/Server.js)
- [Authentication routes and token return rules](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/Auth.js)
- [OIDC mobile bridge and PKCE handling](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/auth/OidcAuthStrategy.js)
- [Current API router](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/routers/ApiRouter.js)
- [Library queries and search](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/controllers/LibraryController.js)
- [Item detail, metadata, cover, playback, and download controllers](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/controllers/LibraryItemController.js)
- [Playback-session manager and synchronization semantics](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/managers/PlaybackSessionManager.js)
- [Playback-session response model](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/objects/PlaybackSession.js)
- [Direct-play track model and content URLs](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/objects/files/AudioTrack.js)
- [Public session-track router](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/routers/PublicRouter.js)
- [Public session-track implementation](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/controllers/SessionController.js)
- [HLS router](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/routers/HlsRouter.js)
- [Book metadata request/response model](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/models/Book.js)
- [User response and permission model](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/models/User.js)
- [Progress update semantics](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/models/MediaProgress.js)
- [Current-user session and listening-summary implementation](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/controllers/MeController.js)
- [Yearly user-statistics query and its aggregation keys](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/utils/queries/userStats.js)
- [Persisted playback-session schema and compatibility mapping](https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/models/PlaybackSession.js)

Official mobile client interoperability reference:

- [Current mobile-client baseline commit](https://github.com/advplyr/audiobookshelf-app/commit/185cba16eb122b40e8537a7bf475632680d6fb94)
- [Mobile OIDC connection flow](https://github.com/advplyr/audiobookshelf-app/blob/185cba16eb122b40e8537a7bf475632680d6fb94/components/connection/ServerConnectForm.vue)
- [Current iOS API client and refresh handling](https://github.com/advplyr/audiobookshelf-app/blob/185cba16eb122b40e8537a7bf475632680d6fb94/ios/App/Shared/util/ApiClient.swift)
- [Current iOS playback URL selection](https://github.com/advplyr/audiobookshelf-app/blob/185cba16eb122b40e8537a7bf475632680d6fb94/ios/App/Shared/player/AudioPlayer.swift)
- [Current iOS session accounting](https://github.com/advplyr/audiobookshelf-app/blob/185cba16eb122b40e8537a7bf475632680d6fb94/ios/App/Shared/player/PlayerProgress.swift)
- [Current mobile statistics screen](https://github.com/advplyr/audiobookshelf-app/blob/185cba16eb122b40e8537a7bf475632680d6fb94/pages/stats.vue)
- [Current iOS per-file background download behaviour](https://github.com/advplyr/audiobookshelf-app/blob/185cba16eb122b40e8537a7bf475632680d6fb94/ios/App/App/plugins/AbsDownloader.swift)

Supplementary Audiobookshelf material:

- [New JWT authentication discussion](https://github.com/advplyr/audiobookshelf/discussions/4460)
- [Server releases](https://github.com/advplyr/audiobookshelf/releases)
- [Published API reference](https://api.audiobookshelf.org/) — explicitly out of date and not normative for this specification

OAuth:

- [RFC 7636 — Proof Key for Code Exchange](https://www.rfc-editor.org/rfc/rfc7636)
- [RFC 8252 — OAuth 2.0 for Native Apps](https://www.rfc-editor.org/rfc/rfc8252)

Apple:

- [ASWebAuthenticationSession](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession)
- [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)
- [AVAudioTimePitchAlgorithm](https://developer.apple.com/documentation/avfoundation/avaudiotimepitchalgorithm)
- [AVAudioSession](https://developer.apple.com/documentation/avfaudio/avaudiosession)
- [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
- [Responding to audio route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes)
- [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
- [MPRemoteCommandCenter](https://developer.apple.com/documentation/mediaplayer/mpremotecommandcenter)
- [Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
