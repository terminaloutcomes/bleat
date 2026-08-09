# Bleat Remaining Work

This file is the forward-looking backlog for Bleat. It contains only work that
still needs implementation or evidence. Delivery history and existing proof
belong in `README.md` and `docs/requirements-traceability.md`.

## 1. Version 1.0 requirement evidence

The following application requirements need additional evidence before their
traceability rows can be closed:

- `APP-HOME-001`: add deterministic application/UI coverage for shelf ordering,
  loading, empty, partial-failure, offline-download, refresh, and detail
  navigation states.
- `APP-COVER-EDIT-001`: exercise a real cover image through preprocessing,
  metadata-first saving, upload, refetch, and cache-busted presentation against
  root-hosted and path-prefixed disposable servers.
- `APP-DIAGNOSTICS-001`: prove the rolling development log's protection,
  backup exclusion, size/time bounds, and redaction, and prove that export
  controls and retained diagnostic files are absent from Release builds.
- `APP-MAC-AUTH-001`: record a signed Catalyst login/relaunch journey that
  exercises the application-host Keychain entitlement and distinguishes
  rejected credentials from unavailable secure storage.
- `APP-ICLOUD-001`: record an enabled, signed two-device journey against the
  provisioned private CloudKit container, including statistics/configuration
  merge, static-credential recovery, opt-out, cloud-copy deletion, and
  this-device/all-device account removal. A Personal Team build with
  `BLEAT_CLOUDKIT_MODE=disabled` is not CloudKit propagation evidence.
- `APP-PLAYBACK-001`: complete the physical-device media matrix for supported
  formats, background and locked playback, interruptions, route removal,
  Bluetooth, AirPlay, CarPlay transport commands, Now Playing position, speed,
  sleep timers, relaunch, and session recovery.
- `APP-CARPLAY-001`: obtain Apple's managed CarPlay Audio App entitlement and
  record CarPlay Simulator plus physical vehicle/head-unit evidence for
  browsing, search, online/offline playback, artwork, transport controls,
  background playback, disconnect/reconnect, and simultaneous phone use.

## 2. Version 1.0 release readiness

### Compatibility and integration

- Add disposable Audiobookshelf 2.26.x and current-stable profiles with
  version-specific seed state; run root-hosted and path-prefixed contract
  journeys without reusing databases across incompatible versions.
- Complete the download process/network failure matrix: suspension,
  termination, connectivity changes, token rotation, server outage/recovery,
  storage pressure, corrupt media repair, and hundreds-of-tracks behavior.
- Add measured multi-file boundary evidence required by `AC-21`.

### Quality and safety

- Exercise 10,000-book browsing/search/cache behavior without main-actor bulk
  work and record launch, memory, energy, and storage results.
- Add migration fixtures and tests for every shipped SwiftData schema, plus
  upgrade, backup/restore, account removal, and app-data reset journeys.
- Run deep secret scans over logs, diagnostics, persistence, exports, URLs,
  live-test artifacts, and Release archives for `AC-02`.
- Complete VoiceOver, largest Dynamic Type, Bold Text, Increase Contrast,
  Reduce Motion, landscape, iPad keyboard, and 44-point target audits for
  `AC-28`.

### Delivery

- Add CI workflows for strict-concurrency compilation, host tests and coverage,
  iPhone/iPad simulator tests, unsigned Release/archive checks, migration and
  security checks, the pinned live-server smoke suite, and redacted artifacts.
- Add scheduled compatibility, media/download recovery, performance, and flake
  jobs while keeping server versions sequential and disposable.
- Prove the documented validation gate from a clean checkout and complete the
  signed iPhone/iPad beta matrix, App Store privacy labels, entitlements,
  screenshots, release notes, and final compatibility baseline.

## 3. Post-1.0 product backlog

### Playback and bookmarks

- `APP-BOOKMARK-UX-001`: give Book Detail the same create, rename, delete,
  pending-sync, failure, and retry affordances as Now Playing while preserving
  the account-scoped mutation ordering rules.

### Listening statistics and portability

- Import paginated Audiobookshelf history resumably and reconcile remote and
  local sessions without double counting; represent ambiguous all-device
  results with explicit lower/upper bounds.
- Add range filtering, all-account charts, per-book and recent-session detail,
  and live overlays to the implemented lifetime summary.
- Add redacted, versioned, idempotent JSON export/import and destructive reset,
  with performance coverage for 250,000 stored slices.

### Transcription

- Complete [GitHub issue #5](https://github.com/terminaloutcomes/bleat/issues/5)
  by adding partial-result resume, current-position and result seeking,
  automatic-cache track pinning, source-specific invalidation, and independent
  transcript deletion, plus physical-device evidence that playback preempts
  active transcription. The implemented menu, explicit chapter selector,
  verified full-download input, bounded multi-file chapter transcription,
  account/book/chapter-scoped durable cache, relaunch loading, and
  case-insensitive book-wide result search remain the retained foundation.

### Other deferred enhancements

- Apple Watch remote control and offline transfer.
- Widgets and Live Activities.
- Siri and App Intents.
- Metadata provider search and matching.
- Configurable reverse-proxy/service-token headers.
- Silence skipping, voice boost, and equalizer.
- Series bulk download.
- Deliberate cross-server edition merging for statistics.

## Backlog maintenance

Every entry must map to a non-final row in
`docs/requirements-traceability.md`, an unmet release acceptance criterion, or
an explicit deferred item in `audiobookshelf-ios-app-spec.md`. Remove an entry
once its implementation and required automated, live, simulator, signed-host,
or physical-device evidence are recorded in the traceability file.
