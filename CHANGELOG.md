# Changelog

## 0.1.3 - 2026-08-24

### Added

- Added optional privacy-preserving diagnostic telemetry with explicit user opt-in, App Attest authentication, short-lived credentials, and bounded collection.
- Added CloudKit synchronization improvements including typed sync failures and safer conflict handling.
- Added improved diagnostics and troubleshooting visibility for connection, sync, and application state.
- Added OIDC setup guidance and privacy documentation updates.

### Improved

- Improved download handling with durable pause/resume support and safer interrupted transfer recovery.
- Improved playback, search, transcription, and account lifecycle reliability.
- Improved release security validation, dependency checks, and telemetry operational controls.

### Fixed

- Fixed corrupted CloudKit conflict states preventing synchronization recovery.
- Fixed durable download pause/continue behavior.
- Fixed UI test reliability around restored accounts and diagnostics visibility.
- Fixed various edge cases around authentication, synchronization, and app state restoration.

## 0.1.2 - 2026-08-18

### Added

- Added Select and Select All controls for ordered, one-at-a-time chapter
  transcription batches.
- Added durable account/book-scoped transcription task results with typed
  success, failure, or cancellation state, completion time, and elapsed time.
- Added transcript-segment menus for copying text or moving playback to the
  segment's whole-book timestamp.
- Transcript search now matches all query terms within a segment regardless of
  term order or letter case.

### Changed

- Adopted the registered TerminalOutcomes app identity and paid CloudKit and
  App Attest capabilities for signed device and distribution builds.
- Made server-configuration edits push immediately to CloudKit, require
  confirmation on receiving devices, and ignore delayed predecessor
  generations.
- Made devices without local session tokens establish their own session from
  the synchronized native login before making the original API request.
- Made configured local servers retry automatically on launch and network
  changes, retain successful validation across temporary failures, and fall
  back from local playback and downloads to the primary server.
- Suspended Audiobookshelf WebSocket updates while Low Data Mode is active
  without changing REST access or local playback state.
- Moved active transcription ownership out of the sheet so work continues when
  navigating elsewhere; playback and transcription can now run concurrently.
- Made transcription cancellation cooperative so chapters saved during a
  cancellation race remain cached and included in the final cancelled result.
- Limited inactive in-memory transcript retention to five minutes and evicted
  inactive transcript text immediately when iOS reports memory pressure.
- Reloaded the latest transcription task result after relaunch and displayed
  its privacy-safe error and elapsed time on the transcription screen.
- Allowed transcription from verified downloaded files covering the selected
  chapters without requiring a complete-book download, and pinned automatic
  cache files against cleanup until transcription releases them.

## 0.1.1 - 2026-08-09

### Added

- Added chapter-level on-device transcription from the book actions menu, with
  an explicit chapter selector, verified downloaded-audio input, and
  whole-book timestamps.
- Added account-, book-, and chapter-scoped transcript caching with relaunch
  loading and case-insensitive search across previously transcribed chapters
  in the current book.
- Added the `bleat-transcribe` developer CLI for testing Apple's
  `SpeechTranscriber` against local chapter audio.
- Added independent settings for mapping system Previous and Next headphone
  commands to skip-back, skip-forward, previous-chapter, or next-chapter
  actions.
- Added main-branch release automation that validates the versioned archive and
  publishes the matching changelog section as a GitHub Release.

### Changed

- Changed book playback actions to distinguish Start, Resume, Play Again, and
  Pause from the current playback and saved-progress state.
- Made privacy-safe diagnostic snapshot export available in release builds;
  recent-log export remains development-only.
- Made download progress use a compact downloaded/expected display with one
  shared unit.
- Restyled transcription search matches as a compact chapter-and-timestamp
  header followed by adaptive primary-colour transcript text.
