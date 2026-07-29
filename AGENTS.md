# Repository Guide

## Current state

This repository currently contains the implementation-audited product and
technical specification in `audiobookshelf-ios-app-spec.md`. Treat that document
as the source of truth until code and narrower design records exist.

The product is a native Audiobookshelf client for iPhone and iPad:

- SwiftUI
- iOS 17.0 or newer
- Swift 6 with strict concurrency checking
- SwiftData for structured local state
- Keychain references for credentials
- `AVPlayer` and system media frameworks for playback

Do not broaden the first release to podcasts, ebooks, metadata matching, full
CarPlay browsing, watchOS, widgets, Siri, SharePlay, or server administration.

## Implementation order

Start with the Phase 0 risk spikes in section 21 of the specification. Prove the
following before building broad UI:

1. Native username/password login with account-scoped Keychain credentials.
2. Per-account single-flight refresh-token rotation.
3. Session-scoped direct-file range playback.
4. Session-scoped transcoded HLS playback.
5. Restorable bearer-authenticated background downloads.

If a spike disproves an architectural assumption, update the specification and
architecture before continuing.

OIDC/PKCE, listening-time accounting, and listening-session import are
deferred. Do not implement or extend them as part of the MVP.

## Server contract

The pinned Audiobookshelf implementation is authoritative. The published API
reference is not. Follow sections 3, 15, and 24 of the specification.

- Keep endpoint construction and path-prefix handling in one route builder.
- Keep remote DTOs inside the `AudiobookshelfAPI` boundary.
- Separate remote DTOs, domain models, and SwiftData models.
- Ignore unknown JSON fields and tolerate missing nullable fields.
- Keep remote identifiers as opaque strings wrapped in domain-specific ID
  types.
- Add pinned source links to non-trivial DTOs and route adapters.
- Do not invent alternate endpoints or payloads.
- Capture fixtures from the minimum supported, audited, and current stable
  server versions.

## Architecture and concurrency

Follow the component boundaries and source layout in section 14.

- UI feature models use Observation and run on `@MainActor`.
- Token, API, repository, download, progress, and statistics coordination use
  actors.
- Playback survives SwiftUI view reconstruction and account-context switches.
- Do not add a general service locator.
- Do not expose remote DTOs to views.
- Prefer Apple platform frameworks; version 1.0 requires no third-party runtime
  dependency.

Keep account identity in every cache, persistence, download, progress, and
statistics key. Never merge records merely because remote IDs or titles match
across accounts.

## Security invariants

- Production connections require HTTPS and system trust validation.
- Never add a trust-all or self-signed-certificate bypass.
- Store credentials only through Keychain references.
- Never put access or refresh tokens in URLs.
- Treat playback session IDs as bearer-like secrets.
- Do not use undocumented AVFoundation HTTP-header options.
- Redact tokens, passwords, playback routes, and sensitive local paths from
  logs and diagnostics.

## Playback and statistics invariants

Keep these quantities distinct:

- media position;
- monotonic wall-clock time actually spent listening;
- audiobook-time heard after applying playback rate.

Pauses, buffering, interruptions, and seeks add no listening time. A seek adds
no audiobook-time. Online session sync sends only the listening-time delta
since the last confirmed sync. Ambiguous sync results must not silently resend
that delta.

Server history is authoritative for all-device real listening time. Exact
rate-aware and chapter-aware history is available only for playback observed by
this app. Preserve and display that coverage distinction.

## Persistence and downloads

- Use SwiftData for structured state and the filesystem for media bytes.
- Never persist token text in SwiftData, property lists, exports, or logs.
- Complete downloads atomically through staging files and validated manifests.
- Sanitize remote filenames and never let remote metadata choose arbitrary
  local paths.
- Downloaded books remain playable when a server is unavailable or an account
  requires reauthentication.

## Errors

Model distinct errors and state transitions with enums or dedicated structs.
Make behavior decisions by matching typed variants, never by inspecting
localized descriptions or serialized error strings.

Preserve the user-facing categories in section 16, including authentication,
permission, media, storage, conflict, uncertain-statistics, and incompatible
response errors.

## Tests and validation

Put tests in test targets, not production entry points. Keep reusable functions
in library/application modules rather than an app entry point.

Add focused unit tests with each implementation change. Use saved response
fixtures for decoding and a disposable seeded Audiobookshelf server for
contract integration tests. The complete required matrix is in section 20.

Once an Xcode project exists, use its checked-in shared schemes and run the
repository's documented formatter, build, and test commands. Until those
commands exist, do not claim the project has been compiled or tested.

For every change:

1. Run the narrowest relevant tests.
2. Run the full repository validation gate when practical.
3. Report which checks ran and distinguish static checks from live-server or
   device validation.

## Documentation

Keep `audiobookshelf-ios-app-spec.md` aligned with implemented behavior,
especially its audited baseline, route map, delivery phase, and acceptance
criteria. Use project-relative paths in documentation and comments.
