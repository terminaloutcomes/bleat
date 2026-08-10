# Changelog

## Unreleased

### Added

- Added Select and Select All controls for ordered, one-at-a-time chapter
  transcription batches.
- Added durable account/book-scoped transcription task results with typed
  success, failure, or cancellation state, completion time, and elapsed time.

### Changed

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
