# Bleat 1.0 Implementation Plan

This plan turns `audiobookshelf-ios-app-spec.md` draft 1.2 into an executable
delivery sequence for a native iPhone and iPad application. The specification
remains the product and protocol source of truth; this document defines work
order, deliverables, test ownership, and release gates.

## 1. Definition of done

Bleat 1.0 is done when:

1. every in-scope requirement and every release acceptance criterion in the
   specification is implemented;
2. every requirement is linked to at least one automated test or, where Apple
   system behavior cannot be automated reliably, a repeatable physical-device
   test;
3. all required unit, fixture-contract, live-server, media, download, UI,
   accessibility, security, migration, performance, and device suites pass;
4. the app passes Swift 6 strict concurrency checking with no ignored
   data-race warnings;
5. secrets, account data, cached objects, downloads, progress, and statistics
   remain account-isolated;
6. the compatibility matrix passes against Audiobookshelf 2.26.x, the audited
   2.36.0 baseline, and the current stable release selected at release time;
7. all 28 acceptance criteria in section 22 have test evidence attached to the
   release candidate;
8. the specification, implementation map, captured fixtures, privacy
   declarations, and user-facing authentication documentation match the
   shipped behavior.

“Full test coverage” means complete behavioral and requirement coverage, not a
misleading claim that simulator line coverage proves AVFoundation, Keychain,
background execution, Bluetooth, AirPlay, or CarPlay behavior. Those boundaries
receive integration and physical-device coverage in addition to unit tests.

## 2. Fixed implementation decisions

These decisions keep the implementation direct and consistent with the
specification:

- Product and target name: `Bleat`.
- Deployment target: iOS 26 and above.
- Language mode: Swift 6 with complete strict concurrency checking.
- UI: SwiftUI with Observation-based, `@MainActor` feature models.
- Persistence: versioned SwiftData schemas for structured state and opaque
  filesystem locations for media.
- Secrets: Security framework/Keychain only, using
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Networking: Foundation `URLSession`, with actors around mutable coordination.
- Playback: AVFoundation and MediaPlayer.
- Tests: XCTest/XCUITest and Apple code coverage tools.
- Third-party runtime dependencies: none for 1.0.
- Authentication scope: native Audiobookshelf username/password login and
  rotating tokens. OIDC is deferred and is not part of the active 1.0
  implementation or live-test matrix.
- Analytics: none.
- No production ATS exception, trust override, token-bearing URL, undocumented
  AVFoundation header option, or general service locator.

Before App Store work, record the final bundle identifier, callback URI, signing
team, app-group decision if any, and local-network usage copy in a short
decision record. The callback URI must be registered exactly in Audiobookshelf.

## 3. Repository and target layout
Create one Xcode project with checked-in shared schemes:

```text
Bleat.xcodeproj
Bleat/
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
BleatTests/
BleatContractTests/
BleatMediaTests/
BleatUITests/
TestSupport/
  Fixtures/
  SeedMedia/
  Doubles/
  ServerHarness/
    compose.yaml
    caddy/
    oidc/
    seed/
docs/
scripts/
```

Targets and ownership:

| Target | Purpose |
| --- | --- |
| `Bleat` | Production application. The `App` entry point contains composition only. |
| `BleatTests` | Fast deterministic unit and in-memory persistence tests. |
| `BleatContractTests` | Saved-fixture decoding and disposable-server API tests. |
| `BleatMediaTests` | AVFoundation, range, HLS, track-boundary, and interruption tests. |
| `BleatUITests` | XCUITest user journeys, accessibility identifiers, and visual state checks. |
| `TestSupport` | Test-only fixtures, clocks, URL protocol stubs, server control, and data builders. |

Use protocols only at external boundaries that need substitution: clock,
Keychain, HTTP transport, filesystem capacity/file operations, player adapter,
and system command centers. Keep domain logic concrete.

## 4. Delivery sequence

Each phase has an exit gate. Work may proceed within a phase in parallel, but a
later phase cannot depend on an unproven earlier assumption.

### Phase 0 — project, traceability, and deterministic test foundations

Deliver:

- Xcode project, shared schemes, Debug/Release configuration, iPhone and iPad
  destinations, audio background mode, and required privacy keys.
- Strict concurrency and warnings-as-errors for app-owned code.
- Minimal dependency composition in `App`; no library logic in the entry point.
- Versioned SwiftData container with an empty initial schema and in-memory test
  configuration.
- Typed IDs: `AccountID`, `LibraryID`, `LibraryItemID`, `BookID`,
  `PlaybackSessionID`, `DownloadID`, and `ChapterID`.
- Typed error/state enums covering section 16.
- Test-only controllable monotonic clock, UTC calendar, HTTP transport,
  Keychain store, filesystem, AVPlayer adapter, and notification/event source.
- Fixture conventions keyed by server version and pinned contract source.
- `docs/requirements-traceability.md` containing stable requirement IDs.
- Scripts for build, unit tests, all simulator tests, live tests, coverage
  extraction, and fixture validation.
- CI workflows described in section 7.

Test before exit:

- Debug and Release build for iPhone and iPad simulators.
- Strict-concurrency compilation.
- Typed IDs cannot be mixed at compile time in their API use sites.
- In-memory SwiftData reset and persistence smoke tests.
- Test runner fails if duplicate requirement IDs or missing test links exist.

Exit gate: a clean clone can build and run the empty app and all empty test
schemes from documented commands.

### Phase 1 — audited contract harness and Phase 0 risk spikes

#### 1A. Contract harness

Deliver:

- A Docker Compose test stack in `TestSupport/ServerHarness/compose.yaml`.
- Disposable, seeded Audiobookshelf containers for 2.26.x, pinned 2.36.0, and a
  configurable current stable version. Pin images by immutable digest in CI
  after the version tag has been selected.
- Compose profiles for:
  - one plain Audiobookshelf instance;
  - Audiobookshelf behind an HTTPS reverse proxy at `/audiobookshelf`;
  - the full media/download matrix.
- `scripts/live-test-environment.sh` with `up`, `wait`, `seed`, `reset`,
  `artifacts`, and `down` commands. It must use a unique Compose project name,
  allocate non-conflicting ports, and always tear down its exact project and
  volumes.
- HTTPS test endpoint using a test CA installed as trusted by the test
  destination; never add an app trust bypass. Use Caddy's Go-based internal CA
  or another non-OpenSSL implementation and install its root certificate into
  the target simulator Keychain for the test run.
- Reverse-proxy deployment under `/audiobookshelf`.
- Seeded limited and full-permission users.
- Seeded single M4B, multi-file MP3, FLAC, forced-transcode, long range-seek,
  many-small-track, and metadata-editable books.
- Version-specific deterministic seed/bootstrap adapters based on verified
  server routes, or per-version database snapshots when no stable bootstrap API
  exists. Never reuse a database snapshot across incompatible server versions.
- A readiness check that validates `/status`, expected server version,
  initialization state, seeded accounts, libraries, and media before tests
  start. Container process health alone is not sufficient.
- Test-run state isolation: restore the selected version's seed state before a
  suite, use unique local account/device/session IDs, and serialize only the
  live tests that mutate shared server state.
- `scripts/test-live.sh` that starts the selected Compose profile, waits and
  seeds it, passes its base URL and test-account references to
  `BleatContractTests`/`BleatMediaTests`, captures results, and tears it down
  through a shell trap on success, failure, or cancellation.
- Redacted failure artifacts containing container health, server version,
  proxy/server logs, and the Xcode result bundle. Proxy logging must omit or
  redact authorization headers, cookies, callback queries, playback-session
  paths, and HLS paths before an artifact is retained.
- Versioned, redacted request/response fixtures for every non-trivial DTO.

The Docker harness is part of automated testing. Developers run the focused
live suite locally, contract-affecting pull requests run the pinned-server smoke
profile, and CI runs the complete version/profile matrix on a macOS runner with
Docker and iOS Simulator support. Run server versions sequentially to keep the
test destination deterministic and resource use bounded.

#### 1B. URL and route spike

Implement URL normalization, same-host HTTP-to-HTTPS upgrade handling,
cross-origin redirect confirmation state, base-relative route construction, and
returned-path construction that preserves a reverse-proxy prefix.

Prove:

- query and fragment removal, plus credentials, old server, wrong app, and
  uninitialized server rejection;
- trailing-slash normalization without dropping a path prefix;
- API, cover, direct-play, HLS, and download route construction.

#### 1C. OIDC/PKCE spike

Status: deferred by product direction. The existing isolated spike remains
available as research code, but no identity provider is required by Bleat's
active implementation or test harness.

The retained research spike records:

- PKCE verifier length/entropy and S256 challenge;
- initial cookies survive the browser boundary and are required at exchange;
- exact callback and state validation;
- provider cancellation and missing-code behavior;
- token validation before persistence;
- cleanup of verifier, code, state, cookies, and temporary responses on every
  terminal path;
- no sensitive URL or value is logged.

#### 1D. Single-flight refresh spike

Implement `TokenVault` and a per-account `AuthCoordinator`.

Status: verified against deterministic actor tests and fresh pinned 2.36.0
root and path-prefixed Docker instances.

Prove:

- atomic rotating token replacement;
- 20 concurrent 401 responses cause one refresh;
- each ordinary request retries at most once;
- auth endpoints never recurse into refresh;
- a 403 never refreshes;
- one account's refresh failure does not affect another.

#### 1E. Playback-route spike

Status: verified against deterministic DTO and route tests plus fresh pinned
2.36.0 root and path-prefixed Docker instances.

Open real server sessions and prove:

- byte-range seeking near the start, middle, and end of a long direct-play
  track;
- ordered multi-file transition;
- HLS startup and seeking with relative segments;
- path-prefix preservation;
- both routes fail after closing their session;
- no access token is present in a media URL or undocumented asset option.

#### 1F. Background-download spike

Prove:

- bearer header on every file request;
- background task restoration after process termination;
- a 401 creates a newly authorized replacement request;
- task-to-account/book/track mapping survives relaunch;
- no completed manifest points at a partial file.

#### 1G. Time and history spike

Implement the smallest clock-driven slice recorder and remote-session importer.

Prove:

- real time versus audiobook time at 0.5×, 1×, 2×, and 3×;
- pause, buffering, seek, interruption, route loss, rate change, track
  transition, chapter transition, and midnight splitting;
- one hour at 2× yields about one real hour and two audiobook hours;
- repeated import is idempotent;
- a local session represented remotely is counted once;
- ambiguous online sync produces a bounded approximate all-device result.

Exit gate: all seven risk spikes pass against the pinned live server. Record
evidence and revise the specification before continuing if any contract
assumption fails.

### Phase 2 — accounts, authentication, and API foundation

Deliver:

- `ServerAccount` persistence and account-scoped Keychain references.
- Add-server discovery and authentication-method presentation.
- Production native username/password login coordinator.
- `/api/authorize`, refresh, logout, reauthentication, and account-removal
  flows.
- `AudiobookshelfAPI` actor, typed requests/responses, route builder, status
  validation, retry policy, cancellation, and correlation IDs.
- Permission model mirroring download, update, upload, library, tag, and
  explicit-content constraints.
- Account store supporting two users on one server and multiple servers.
- Redacted `OSLog` categories and diagnostics event model.

Test before exit:

- every add-server, local-login, token, logout, and account-removal branch;
- malformed and forward-compatible fixtures;
- cross-account concurrency and storage isolation;
- credentials remain available after first unlock but do not synchronize;
- server-unreachable logout still removes local credentials;
- retained statistics contain no server URL, credential, cookie, pending
  operation, or local media path;
- permission-denied remains distinct from authentication failure.

Exit gate: two users on one server and users on separate servers can remain
signed in, switch active browsing context, and fail/re-authenticate
independently with no secret in logs or persistence.

### Phase 3 — library, cache, navigation, and book detail

Deliver:

- SwiftData models and mappers for accessible libraries, book summaries,
  expanded details, progress summaries, and cover-cache metadata.
- `LibraryRepository` actor with server/cache merge, account/library
  invalidation, pagination, home shelves, last-refresh state, and offline reads.
- Paginated Library UI with 40–60 item pages, sort/filter, list/grid selection,
  and no full-library expanded fetch.
- Debounced Search UI with cancellation on query/account/library change.
- Home shelves, Downloads summary placeholder, lifetime-statistics placeholder,
  and current account indicator.
- Book detail with account attribution, metadata, chapters, bookmarks,
  progress, and permission-gated actions.
- Thumbnail and original-cover cache separation.
- Root `TabView` and persistent mini-player shell.

Test before exit:

- pagination boundary, duplicate-page, empty-page, refresh, cancellation, stale
  cache, inaccessible item removal, and 10,000-book data-set behavior;
- account and library switches cannot publish superseded results;
- search debounce is clock-controlled and deterministic;
- no raw DTO reaches a feature model;
- offline summaries/details and refresh timestamps render correctly;
- permissions hide actions before a request is attempted;
- VoiceOver labels and largest Dynamic Type on all completed screens.

Exit gate: accounts can browse, search, and inspect accessible books online and
from cache without cross-account bleed or main-thread bulk work.

### Phase 4 — playback engine and system media integration

Deliver:

- Process-wide `PlaybackEngine` and explicit typed playback state machine.
- `PlaybackContext`, global/track/chapter timeline maps, preparation
  cancellation, and observer ownership.
- Stream session creation, direct-play and HLS route adapters, one-time
  lost-session recovery, and deliberate session closure.
- Local-manifest playback and explicit local-to-stream transition behavior.
- Speed selection, persistence, per-book override, pitch algorithm, and
  reapplication across transitions.
- Full Player and mini-player behavior.
- Whole-book scrubber with accidental-seek protection and chapter navigation.
- `AVAudioSession` interruption, route, AirPlay, and media-services-reset
  handling.
- `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`.
- Sleep timer and resume rewind.

Test before exit:

- all exact/zero/missing/floating-point timeline boundaries;
- all allowed and rejected state transitions;
- repeated play cannot create concurrent server sessions;
- stale preparations cannot start the wrong item;
- observer installation/removal has no duplicates or retain cycles;
- MP3, M4B/AAC, FLAC, and transcode paths;
- range seeking does not fetch a whole long file first;
- rate/pitch/Now Playing consistency through every transition;
- interruptions, output removal, background, lock screen, remote commands,
  Bluetooth, AirPlay, and CarPlay;
- sleep timers use wall time and chapter boundaries across tracks;
- crash/relaunch recovery loses no more than five seconds of durable position.

Exit gate: streaming and downloaded media pass the media matrix on simulator
where supported and on a physical iPhone, including background and system
controls.

### Phase 5 — progress, sessions, bookmarks, and conflict handling

Deliver:

- `ProgressCoordinator` actor and durable five-second checkpoints.
- Online sync/close with separate whole-book position and unsent
  monotonic-listening delta.
- Explicit uncertain-delta state for transport-ambiguous sync failures.
- Offline UUIDv4 session queue and batch `/api/session/local-all` import.
- Direct progress read/patch and local/server/common-checkpoint model.
- Non-destructive two-position conflict UI.
- Online bookmark CRUD and visible offline operation queue with
  refetch-before-ambiguous-retry behavior.
- Finished/unfinished mutations using the same conflict rules.

Test before exit:

- every persistence trigger in section 11.1;
- online sync cadence, final close, retry limit, confirmed reset, ambiguous
  preservation, and no cumulative resend;
- partial batch results remove only acknowledged sessions;
- `progressSynced == false` refreshes server progress;
- obsolete local-progress endpoint is never used;
- local-only, server-only, both-changed, active-playback, clock-skew, and user
  choice conflict branches;
- ambiguous bookmark create is deduplicated by item/time/title;
- pending mutations survive relaunch and remain visible.

Exit gate: online and offline sessions synchronize once, progress conflicts are
never resolved silently, and the server receives only confirmed deltas.

### Phase 6 — statistics ledger, import, aggregation, and portability

Deliver:

- Versioned models for listening slices, remote snapshots, completion
  milestones, chapter identity/coverage, import state, and uncertainty bounds.
- Clock-driven live slice recording tied to playback generations.
- Durable five-second slice persistence and live in-memory overlay.
- Paginated server-history import, adaptive page sizing, once-daily automatic
  limit, explicit refresh, resumability, upsert, and non-destructive deletion
  semantics.
- Remote/local reconciliation with expected remote totals and ambiguous
  lower/upper bounds.
- All Accounts and per-account aggregation with stale-account results.
- Chapter identity remapping across metadata edits.
- Natural, server-seeded, and explicit completion milestones with immutable
  duration snapshots.
- Statistics UI: Lifetime default, account/range filters, cards, charts,
  per-book breakdown, recent sessions, live updates, and coverage badges.
- Versioned, redacted, idempotent JSON export/import and destructive reset.

Test before exit:

- every metric definition and threshold in section 12.1;
- every sample eligibility and split rule in section 12.2;
- 0.5×/1×/2×/3×, replay, forward/backward seek, stall, interruption, rate
  changes, track/chapter boundaries, and local midnight;
- 250,000-slice aggregation within the 500 ms publication target off the main
  actor;
- remote session update/upsert, disappearance, concurrent paging inserts,
  deleted sessions, retry/resume, memory-pressure page reduction, and stale
  accounts;
- book identity collisions across accounts and identical titles;
- chapter unchanged/split/materially-replaced mappings;
- metadata duration edits do not rewrite completion history;
- current server progress seeds but cannot fabricate lost historical
  completions;
- export contains no secret, session URL, or local path;
- repeated file import and repeated server import change nothing;
- live UI includes uncommitted time and loses no more than five seconds after
  relaunch.

Exit gate: all statistics definitions produce exact or explicitly qualified
results, with no remote/local double count and no manufactured historical
precision.

### Phase 7 — background downloads, storage, and offline recovery

Deliver:

- `DownloadCoordinator`, `BackgroundDownloadDelegate`, stable session
  identifier, task restoration, and app completion-handler plumbing.
- Expanded-item download plans using per-file `ino` endpoints.
- Three-file default concurrency, per-book queueing, pause/cancel/retry,
  bounded exponential retry, stalled-task detection, and 401 rescheduling.
- Network policy and large-cellular confirmation.
- Opaque account/item filesystem layout, MIME extension allow-list, path
  sanitization, temporary staging, and atomic completion.
- Manifest states, per-file/book progress, storage preflight, repair, deletion,
  backup exclusion, file protection, storage summaries, and optional
  completion-age cleanup.
- Offline playback integration and reconnect-triggered session/progress/bookmark
  synchronization.

Test before exit:

- kill/relaunch restoration with stable task mapping;
- Wi-Fi/cellular/expensive/constrained transitions under every policy;
- token expiration mid-queue with new request and no token query;
- unavailable/restored server, bounded retries, cancellation, and pause/resume;
- insufficient space and safety margin;
- wrong length, truncated file, corrupt/deleted local file, unsafe filename,
  unexpected MIME, and partial repair;
- hundreds of tracks without main-actor stalls;
- completed files survive a failed retry;
- backup and protection attributes;
- auto-delete never evicts the playing track;
- offline playback while the server is down or reauthentication is required.

Exit gate: a downloaded book remains atomically valid, private, recoverable,
and playable offline across process and network failure.

### Phase 8 — metadata and cover editing

Deliver:

- `MetadataDraft` and `MetadataRepository`.
- Permission-gated editor for all fields in section 8.2.
- Changed-scalar and complete-array replacement patch generation using the
  audited old-model payload.
- Final expanded-item fetch and best-effort `updatedAt` stale-draft UI.
- Online-only explicit save; drafts never auto-submit.
- Sanitized description rendering.
- `PhotosPicker`, metadata removal, orientation, documented resize limit,
  multipart `cover` upload, confirmed cache swap, refetch, and `ts` cache bust.

Test before exit:

- field-by-field patch generation and null/removal behavior;
- complete array replacement and top-level tags;
- display-only fields never serialize;
- unchanged, stale/reload, stale/review, overwrite, and race-disclosure paths;
- offline save prevention and retained draft;
- rich-text script/unsafe-link sanitization;
- update/upload permission combinations;
- image orientation, metadata stripping, resizing, multipart field name,
  failure preserving old cover, success refetch, and token-free cache busting.

Exit gate: authorized users can deliberately edit metadata and cover art
without claiming atomic conflict prevention; unauthorized controls are absent.

### Phase 9 — release polish and complete-system validation

Deliver:

- Final Home, Library, Search, Downloads, Settings, Player, Book Detail,
  Metadata, and Statistics states.
- Consistent empty/loading/offline/stale/reauth/permission/error/conflict states.
- Diagnostics export with endpoint names, status, correlation IDs, versions,
  state transitions, and redacted errors.
- Complete VoiceOver, Dynamic Type, Bold Text, Increase Contrast, Reduce
  Motion, landscape, and iPad keyboard support.
- Account/data deletion flows and privacy copy.
- SwiftData migration tests from every shipped schema fixture.
- App Store privacy labels, entitlements, screenshots, and release notes.
- Updated audited server/current-client baselines and compatibility fixtures.

Test before exit:

- complete XCUITest journeys on iPhone and iPad sizes;
- security scans of logs, persistence, exports, URLs, and diagnostics;
- performance, memory, energy, launch, and large-data targets;
- physical-device media/background matrix;
- upgrade, backup/restore, account removal, statistics retention/deletion, and
  app-data reset;
- clean install and release archive validation.

Exit gate: the release candidate meets all section 22 criteria and every row in
`docs/requirements-traceability.md` has passing evidence.

## 5. Full test coverage model

### 5.1 Coverage policy

Enforce all of the following:

- 100% of specification requirements and acceptance criteria have a stable ID
  and at least one test/evidence link.
- 100% reachable line coverage for deterministic security, URL/route, typed
  state-machine, timeline, time-accounting, conflict, reconciliation,
  aggregation, import/export, and manifest-transition logic.
- At least 95% line coverage for repositories, API mapping, persistence
  coordination, and download coordination.
- At least 90% line coverage across all app-owned non-UI production code.
- SwiftUI view declarations, generated code, the application entry point, and
  direct Apple-framework callbacks may be excluded from the numeric threshold
  only when the exclusion is documented and covered through UI, integration,
  or device tests.
- Changed-code coverage must not decrease, and new deterministic domain logic
  must be fully covered before merge.

Collect coverage with `xcodebuild test -enableCodeCoverage YES` and `xccov`.
Keep numeric coverage and requirement traceability as separate gates.

### 5.2 Test layers

| Layer | Runs | Owns |
| --- | --- | --- |
| Compile/static | Every change | Swift 6 concurrency, warnings, format, forbidden API/string scans, source-boundary checks. |
| Unit | Every change | Pure transformations, actors with doubles, state machines, persistence, timing, reconciliation, serialization. |
| Fixture contract | Every change | DTO decoding/mapping and recorded request construction for all supported baselines. |
| UI simulator | Every change for affected journeys; full suite before merge | Navigation, visible states, conflict choices, permission gating, account isolation, accessibility identifiers. |
| Docker live server | Pinned smoke profile for contract changes; full matrix nightly and before release | Real authentication, routes, permissions, session sync, history, metadata, cover, and downloads against an automatically provisioned instance. |
| Media/download | Nightly and before release | Range/HLS, codecs, transitions, restoration, storage and network failures. |
| Physical device | Before each beta and release | lock/background, audio routes, Bluetooth, AirPlay, CarPlay, file protection, first-unlock behavior, energy. |
| Performance | Nightly and release | 10,000 cached books, 250,000 slices, hundreds of tracks, launch/aggregation/main-thread targets. |
| Migration/recovery | Every schema change and release | SwiftData migrations, corrupted/missing media repair, kill/relaunch, backup/restore. |
| Security/privacy | Every change plus release deep scan | Secret leakage, TLS policy, path traversal, rich text, exports, deletion, account separation. |

### 5.3 Deterministic test design

- Inject `ContinuousClock`-compatible and UTC calendar boundaries rather than
  sleeping.
- Drive networking through a custom test `URLProtocol` or transport double;
  reserve real `URLSession` for contract tests.
- Use ephemeral Keychain service names and delete only those exact test items.
- Use temporary directories and in-memory SwiftData stores for unit tests.
- Use generated media only when the bytes themselves are under test; otherwise
  use small checked-in deterministic seed files.
- Record every asynchronous state transition and await typed states, never
  arbitrary delays.
- Seed random generators in tests except when testing cryptographic entropy
  properties.
- Run actor and cancellation tests repeatedly under Thread Sanitizer in a
  dedicated CI job.

### 5.4 Required behavioral suites

#### URL, contract, and API

- Normalization: HTTPS, trailing slash, path prefix, query, fragment, embedded
  credentials, malformed URL, wrong app, uninitialized server, and old version.
- Redirects: same-host upgrade, same-origin redirect, cross-origin
  confirmation, and rejected downgrade.
- Route builder: every section 15 endpoint, percent encoding, opaque IDs,
  path-prefix preservation, returned HLS path, and no token query.
- DTOs: minimum/audited/current fixtures, unknown fields, missing nullable
  fields, malformed required fields, compatibility old JSON, and opaque IDs.
- HTTP: success, empty success, structured error, malformed response,
  cancellation, timeout, offline, TLS failure, 401 retry, 403 no retry, and
  correlation/redaction behavior.

#### Authentication and accounts

- Local login success and every missing/invalid-token path.
- Atomic Keychain pair write, rollback/failure, accessibility, and isolation.
- One refresh for 20 callers, rotation, retry-once, recursion prevention,
  account-local failure, and app relaunch.
- Sign out while online/offline, account removal during playback/download, all
  history/download retention choices, and two users on one server.

#### Library and metadata

- Pagination, shelves, sort/filter, debounce/cancellation, offline cache,
  refresh triggers, stale state, cover variants, and permission filtering.
- No expanded full-library fetch and bounded memory for 10,000 summaries.
- Every editable field, array replacement, stale-draft choice, online-only
  mutation, sanitization, cover preprocessing/upload/refetch, and failure
  rollback.

#### Playback and system integration

- Whole-book/track/chapter maps at starts, ends, exact boundaries, gaps,
  zero/missing durations, and tolerance limits.
- Preparation cancellation, repeated play, direct/HLS/local/mixed sources,
  lost-session recovery once, close behavior, and decoder retry as transcode.
- State transitions through ready, playing, buffering, paused, ended, failed,
  interruption, route loss, and reset.
- 0.5×–3.0× selection, pitch algorithm boundary at 2.0×, persistence, actual
  rate reporting, and transition reapplication.
- Seek/scrub/skip/chapter commands, accidental-scrub protection, remote
  commands, Now Playing global time, artwork, rate, and chapter.
- Sleep timer presets/end-of-chapter and resume rewind limits.

#### Progress, sessions, bookmarks, and statistics

- Every durability event and five-second crash-loss limit.
- Fifteen-second online sync, final close, delta-only accounting, ambiguous
  result, later reconciliation, and no duplicate resend.
- UUIDv4 offline sessions, batch partial results, fallback behavior, progress
  refresh, and durable retry.
- Four progress-conflict cases plus active playback, finished state, explicit
  resolution, and clock skew.
- Bookmark create/rename/delete, offline queue, ambiguous create refetch, and
  visible failure.
- Every section 12 metric, threshold, source, coverage label, range/account
  filter, live overlay, import, reconciliation, chapter identity, milestone,
  reset, export, and idempotent import behavior.

#### Downloads and storage

- Queue/concurrency, task restoration, pause/cancel/retry, bounded backoff,
  network policy, cellular warning, 401 replacement, and aggregate progress.
- Safe opaque paths, MIME extensions, traversal rejection, free-space margin,
  staging, length validation, atomic move, manifest state transitions, repair,
  protection, backup exclusion, deletion, and auto-delete.
- Process kill, app suspension, connectivity loss, reauthentication, server
  outage, corrupt file, hundreds of tracks, and offline playback.

#### UI, accessibility, diagnostics, and privacy

- Every screen's loading, empty, content, partial, stale, offline, error,
  permission, reauthentication, and destructive-confirmation states.
- VoiceOver labels include action/state/time/coverage; largest Dynamic Type has
  no essential clipping; 44-point targets; non-color cues; contrast; reduced
  motion; landscape; and iPad shortcuts.
- Diagnostics and export redaction, rich-text safety, cache/data cleanup,
  account isolation, private file protection, and no third-party analytics.

## 6. Acceptance-criterion traceability

Create these entries in `docs/requirements-traceability.md` and link each to
concrete test names and release evidence:

| ID | Acceptance behavior | Primary evidence |
| --- | --- | --- |
| AC-01 | Multiple concurrent accounts, including two users on one server | Account integration and XCUITest journey |
| AC-02 | No secret in logs or media URLs | Security scan and live media test |
| AC-03 | Native login, rotating tokens, and logout work without an identity provider | Live local-authentication suite |
| AC-04 | Twenty 401s cause one refresh and one retry each | Deterministic actor concurrency test |
| AC-05 | Server path prefixes work everywhere | Route unit tests and proxied live suite |
| AC-06 | Limited users do not see forbidden actions | Permission unit and UI tests |
| AC-07 | MP3, M4B/AAC, FLAC, and transcode stream | Media matrix |
| AC-08 | Long-file seek uses ranges | HTTP trace media test |
| AC-09 | Session routes contain no token/header workaround | Route/security tests |
| AC-10 | Speed survives all transitions | Engine, relaunch, and device tests |
| AC-11 | System controls report whole-book position | Device MediaPlayer suite |
| AC-12 | Listening wall time differs from media position | Clock-driven recorder suite |
| AC-13 | One hour at 2× gives 1h real/2h audiobook and seek gives neither | Deterministic long-duration test |
| AC-14 | Multi-account statistics do not merge collisions | Aggregation identity suite |
| AC-15 | All required counts and finished runtime display correctly | Statistics definition/UI suite |
| AC-16 | Remote/local sources deduplicate with coverage labels | Reconciliation and UI suite |
| AC-17 | Live statistics and five-second relaunch durability | Recorder/recovery/UI suite |
| AC-18 | Statistics export/import is redacted and idempotent | Serialization/security suite |
| AC-19 | Ambiguous sync shows bounds without altering exact local ledger | Uncertainty suite |
| AC-20 | Online sync sends only the new listening delta | Request-capture suite |
| AC-21 | Multi-file boundaries stay within measured tolerance | Seed-media waveform test |
| AC-22 | Downloads recover after every interruption class | Background download suite |
| AC-23 | Downloaded media plays with server offline | Offline physical-device test |
| AC-24 | Offline sessions synchronize exactly once | Batch import/relaunch suite |
| AC-25 | Concurrent progress never silently overwrites both positions | Conflict suite and UI journey |
| AC-26 | Metadata uses honest best-effort stale-draft handling | Live mutation and UI suite |
| AC-27 | Account removal leaves no credential or cross-account cache | Persistence/Keychain/filesystem audit |
| AC-28 | VoiceOver and largest Dynamic Type remain usable | Accessibility audit and UI suite |

## 7. CI and validation gates

### Per change

1. Format and static policy checks.
2. Debug build with complete concurrency checking.
3. Unit and fixture-contract tests with coverage.
4. Affected XCUITest journeys.
5. Requirement-link and changed-code coverage checks.
6. For auth, API, DTO, route, playback-session, progress, statistics-import,
   metadata, or download changes: Dockerized pinned-server smoke tests.

### Main branch

1. Full iPhone and iPad simulator matrix.
2. Release build and archive-without-signing validation.
3. Thread Sanitizer actor/cancellation suite.
4. SwiftData migration and kill/relaunch recovery suites.
5. Security and secret scans.

### Nightly

1. Start a clean Docker Compose stack and run the full pinned Audiobookshelf
   2.36.0 contract suite.
2. Recreate the stack from its version-specific seed and run the minimum
   2.26.x fixture/live compatibility suite.
3. Recreate it again and run the current-stable compatibility observation
   suite.
4. Media, download restoration, large-history import, and performance suites.
5. Flake detection by repeating concurrency, timing, and UI tests.
6. Upload only redacted Xcode and container artifacts, then verify the Compose
   project and its test volumes were removed.

### Beta and release

1. All CI suites green from a clean checkout.
2. Physical iPhone and iPad device matrix.
3. Bluetooth/headset removal, AirPlay, CarPlay, lock/background, first-unlock,
   network-transition, and storage-pressure tests.
4. Full accessibility audit.
5. Every AC-01 through AC-28 evidence link populated.
6. No unresolved critical/high security finding or known data-loss issue.
7. Specification baseline, fixtures, privacy declaration, and native
   authentication documentation updated.

## 8. Per-work-item completion checklist

Every implementation change is complete only when:

- the requirement IDs are identified;
- typed success, failure, and transitional states are implemented;
- unit tests cover every deterministic branch;
- contract fixtures are added or updated when a remote shape changes;
- an integration/UI/device test is added where a framework boundary is
  involved;
- account scoping, cancellation, relaunch, offline, and redaction behavior are
  considered explicitly;
- focused tests and the practical repository gate pass;
- coverage and requirement traceability do not regress;
- documentation uses project-relative paths and matches actual behavior.

## 9. Release sequencing summary

The critical path is:

```text
Project/test foundation
  → audited contract and seven risk spikes
  → accounts/auth/API
  → library/cache
  → playback
  → progress/session sync
  → statistics and offline downloads
  → metadata
  → accessibility/security/performance/release validation
```

Statistics and download implementation can proceed in parallel after playback
and progress contracts are stable. Metadata editing can proceed after the API,
permission, and book-detail layers are stable. Broad UI polish waits until the
underlying typed states and failure behavior are proven.
