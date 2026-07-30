# Repository Guide

## Project state and sources of truth

Bleat is an implemented native Audiobookshelf client for iPhone and iPad. The
repository contains a runnable SwiftUI application, the `BleatCore` Swift
package, unit and UI tests, and a disposable Audiobookshelf integration-test
harness.

Use these documents for their specific purposes:

- `audiobookshelf-ios-app-spec.md` defines product scope, protocol behavior,
  security invariants, and acceptance criteria.
- `README.md` documents current user-visible behavior and supported developer
  workflows.
- `IMPLEMENTATION_PLAN.md` records delivery sequencing and remaining release
  work. Verify status claims against the current code and tests before relying
  on them.
- `docs/requirements-traceability.md` maps requirements to implementation and
  test evidence.

Keep all four aligned when a change affects their subject matter. Do not
describe a proposed or partially implemented behavior as complete.

## Platform and scope

The current targets are:

- SwiftUI on iPhone and iPad;
- iOS 26.0 or newer for the application;
- Swift 6.2 or newer with complete strict-concurrency checking;
- SwiftData for structured local state;
- Security framework and Keychain references for secrets;
- AVFoundation and MediaPlayer for playback;
- Foundation `URLSession` for networking;
- no third-party runtime dependencies in version 1.0.

The Swift package also supports macOS 15 so its host-side tests can run without
an iOS Simulator.

Native Audiobookshelf username/password login with rotating access and refresh
tokens is the active authentication scope. `OpenIDAuthentication.swift` is
retained research code only: do not connect OIDC/PKCE to the application or
live-test matrix unless product scope changes explicitly.

The MVP reports playback position while sending zero additional listening
time. Local listening-time accounting, lifetime statistics, and
listening-history import/export remain deferred.

Do not broaden version 1.0 to podcasts, ebooks, metadata matching, full CarPlay
browsing, watchOS, widgets, Siri, SharePlay, or server administration.

## Repository layout

- `App/` contains SwiftUI views, app-level models, platform adapters, and the
  composition root.
- `Sources/BleatCore/` contains reusable domain, API, authentication,
  persistence, playback-session, progress, bookmark, metadata, and download
  logic. It must not depend on app UI.
- `Tests/BleatCoreTests/` contains deterministic host tests and versioned
  response fixtures.
- `Tests/BleatCoreLiveTests/` contains tests against the disposable
  Audiobookshelf server.
- `Tests/BleatAppTests/` and `Tests/BleatUITests/` contain simulator application
  and UI tests.
- `TestSupport/ServerHarness/` contains Docker Compose, Caddy, seed media, and
  live-test support.
- `project.yml` is the editable XcodeGen project definition.
- `Bleat.xcodeproj/` is generated from `project.yml` and is checked in.
- `scripts/` contains the supported validation, live-test, and archive entry
  points.

Do not hand-edit `Bleat.xcodeproj/project.pbxproj`. Change `project.yml`, run
`xcodegen generate`, and review the generated project diff.

## Architecture and concurrency

- Keep the application entry point limited to composition.
- Keep reusable functions in `BleatCore` or an appropriate app module, never in
  the app entry point.
- UI feature models use Observation and run on `@MainActor`.
- Token, API, repository, download, progress, and related mutable coordination
  use actors.
- Preserve playback across SwiftUI view reconstruction and account-context
  changes.
- Use protocols only at external boundaries that need test substitution.
- Do not add a general service locator.
- Do not expose remote DTOs to views.
- Separate remote DTOs, domain models, and SwiftData models.
- Prefer direct implementations using Apple platform frameworks over new
  abstractions or dependencies.

Model distinct errors, result states, and transitions with enums or dedicated
structs. Make decisions by matching typed variants. Never branch on localized
descriptions, serialized error messages, or other string contents.
Preserve both the originating operation and typed failure cause through service,
model, UI, and diagnostics boundaries. Do not collapse distinct failures into a
generic unavailable/failed state: translate them only into a typed,
privacy-safe presentation cause, with retry behavior decided from that type.

## UI

- Use native pull-to-refresh for refreshable primary browsing surfaces. Do not
  add toolbar reload buttons when pull-to-refresh is available.

## Audiobookshelf contract

The pinned Audiobookshelf implementation is authoritative; the published API
reference is not. Follow sections 3, 15, and 24 of
`audiobookshelf-ios-app-spec.md`.

- Keep endpoint construction and path-prefix handling in
  `AudiobookshelfRoute`.
- Keep remote DTOs inside the `AudiobookshelfAPI` boundary.
- Ignore unknown JSON fields and tolerate absent nullable fields.
- Keep remote identifiers as opaque strings wrapped in domain-specific ID
  types.
- Add pinned source links to non-trivial DTOs and route adapters.
- Do not invent alternate endpoints, payloads, or fallback semantics.
- Add redacted fixtures under the matching server-version directory when a
  contract changes.
- Test both root-hosted and path-prefixed server configurations where routing
  is relevant.

## Account and security invariants

Account identity belongs in every cache, persistence, download, progress,
bookmark, and request-coordination key. Never merge records merely because
remote IDs or titles match across accounts.

- Production connections require HTTPS and system trust validation.
- Never add a trust-all or self-signed-certificate bypass. Live tests install
  their disposable Caddy CA into their disposable Simulator.
- Store credentials and tokens only through the account-scoped,
  non-synchronizing, device-only Keychain item.
- Never persist token text in SwiftData, property lists, fixtures, exports, or
  logs.
- Never put access or refresh tokens in URLs.
- Treat playback session IDs and playback routes as bearer-like secrets.
- Do not use undocumented AVFoundation HTTP-header options.
- Redact passwords, tokens, authorization headers, cookies, playback routes,
  callback queries, and sensitive local paths from diagnostics and retained
  artifacts.
- Account removal must close active playback and remove account-owned local
  state and credentials in the defined lifecycle order.

## Playback, progress, bookmarks, and downloads

Keep these quantities distinct:

- whole-book media position;
- monotonic wall-clock time actually spent listening;
- audiobook-time heard after applying playback rate.

Pauses, buffering, interruptions, and seeks add no listening time. Seeks add no
audiobook-time. Do not silently resend an ambiguous progress or statistics
delta.

Playback URLs are session-scoped. Preserve server path prefixes for direct
files, HLS playlists and segments, covers, and downloads. Close online playback
sessions when their owning playback stops or their account is removed.

Offline progress and bookmark mutations use durable account-scoped outboxes.
Preserve ordering and explicit uncertain/failure states; do not convert
ambiguous creates into duplicate mutations.

Use SwiftData for structured download state and the filesystem for media bytes.
Complete downloads through staging files and validated manifests. Sanitize
remote filenames, keep filesystem destinations app-owned, and preserve
downloaded playback when the server is unavailable or the account requires
reauthentication.

## Tests and validation

Put tests in test targets, not production entry points. Add focused tests with
each implementation change and use versioned saved fixtures for response
decoding.

Run the narrowest relevant check first. Typical host-side examples are:

```sh
swift test --filter BleatCoreTests
swift test --filter TokenVaultTests
```

Run the complete local validation gate when practical:

```sh
./scripts/test-core.sh
```

That gate runs host tests with coverage, a Release build, and application unit
and UI tests on an iOS Simulator. For a host-only check:

```sh
BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh
```

Contract or server-behavior changes require the disposable live suite:

```sh
./scripts/test-live.sh
```

Changes spanning the app, HTTPS trust, playback, downloads, offline state, or
pending synchronization require the live application journeys when practical:

```sh
./scripts/test-app-live.sh
```

The live scripts create and tear down Docker state; the app-live script also
creates and deletes its own Simulator. Use their supported environment
variables rather than modifying the scripts for a local machine.

For release packaging changes, run:

```sh
./scripts/archive-beta.sh
```

Always report exactly which checks ran. Distinguish host tests, static or
simulator validation, disposable-server integration tests, and physical-device
validation. Never claim live-server, background-execution, AirPlay, Bluetooth,
CarPlay, or physical-device behavior was validated by a host or ordinary
Simulator test.

## Documentation and change discipline

- Use project-relative paths in documentation, comments, diagnostics, and test
  output. Never write full local filesystem paths into repository files.
- Keep `README.md` focused on behavior that exists now.
- Update `audiobookshelf-ios-app-spec.md` when implementation evidence changes
  a product or architectural assumption.
- Update `docs/requirements-traceability.md` with implementation and test
  evidence for affected requirements.
- Preserve unrelated worktree changes.
- Prefer small, direct changes that reduce duplication and code sprawl.
