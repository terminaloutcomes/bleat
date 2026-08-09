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
- `APP-ICLOUD-001`: record an enabled, signed two-device journey against the
  provisioned private CloudKit container, including statistics/configuration
  merge, static-credential recovery, opt-out, cloud-copy deletion, and
  this-device/all-device account removal. A Personal Team build with
  `BLEAT_CLOUDKIT_MODE=disabled` is not CloudKit propagation evidence.

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
  signed iPhone/iPad beta matrix, App Store privacy labels, final signing
  entitlements, 1.0 release notes, and final compatibility baseline.

## 3. Post-1.0 product backlog

### Listening statistics and portability

- Complete [GitHub issue #26](https://github.com/terminaloutcomes/bleat/issues/26),
  which tracks resumable Audiobookshelf history import and reconciliation,
  bounded ambiguous totals, richer statistics views and live overlays,
  redacted idempotent portability, destructive reset, and 250,000-slice
  performance evidence.

### Transcription

- Complete [GitHub issue #5](https://github.com/terminaloutcomes/bleat/issues/5)
  by adding partial-result resume, current-position and result seeking,
  automatic-cache track pinning, source-specific invalidation, and independent
  transcript deletion, plus physical-device evidence that playback and
  transcription remain usable concurrently.

## Backlog maintenance

Every entry must map to a non-final row in
`docs/requirements-traceability.md`, an unmet release acceptance criterion, or
an explicit deferred item in `docs/audiobookshelf-ios-app-spec.md`. Remove an entry
once its implementation and required automated, live, simulator, signed-host,
or physical-device evidence are recorded in the traceability file.
