# Architecture and feature ownership

This is a map of the current codebase. The [specification](audiobookshelf-ios-app-spec.md)
defines contracts; the [behavior reference](app-behavior.md) explains implemented
flows; [traceability](requirements-traceability.md) records evidence.

## Modules and entry points

| Area | Implementation and ownership | Tests |
| --- | --- | --- |
| Application composition/UI | `App/BleatApp.swift` composes services; `App/RootView.swift` owns the shell; `App/AppModel.swift` coordinates intent through `App/AppService.swift` | `Tests/BleatAppTests/`, `Tests/BleatUITests/` |
| Authentication/network | Core `AccountStore`, `TokenVault`, authenticated requests, `AudiobookshelfAPI`, `AudiobookshelfRoute`, OIDC adapters | Authentication, route, transport, and versioned contract suites |
| Browsing | `LibraryRepository`, library cache, app browse models and page merger | Repository/core suites and app browsing tests |
| Playback/system integration | `App/PlaybackModel.swift`, platform playback engine, `App/CarPlayCoordinator.swift`; core sessions/progress | Playback/session suites, `FrameworkCallbackTests`, live app journeys |
| Downloads/offline | `App/DownloadModel.swift`, core storage/manifests, app background adapters | Storage/manifest/core suites, app recovery and live journeys |
| Statistics/bookmarks | Core repositories, import/export, durable account-scoped mutation state | Statistics/bookmark suites, performance evidence and app tests |
| Persistence/private cloud | Core schema history/catalog, local stores and `PrivateCloudSync` | Migration/catalog/cloud suites; schema validator; separate device evidence |
| Transcription | `Sources/BleatTranscription/`, core job/cache state, app transcript UI; `Sources/BleatTranscribeCLI/` developer harness | Transcription package and app tests |
| Diagnostics/telemetry | Core diagnostic types, authentication/export runtime; app consent and platform attester | Telemetry host/live suites, privacy checks; iOS remote export only |
| Authentication backend | `bleat-api/` Rust service, SeaORM persistence, App Attest, JWT/JWKS, Collector configuration | Rust unit/container tests and telemetry gate |
| Tooling and website | Rust `scripts` workspace package; `site/` Zola content | Rust tooling tests, documentation checks, Zola checks |

UI models use Observation on the main actor; mutable core coordination uses
actors. External-boundary protocols permit test substitution. Views consume
domain/presentation models, not remote DTOs. Keep reusable logic outside entry
points and avoid service locators or speculative abstractions.

## Account and launch lifecycle

Launch restores local account/download state before asynchronous private-cloud
maintenance. Account identity scopes cache keys, tokens, manifests, progress,
bookmarks, statistics, and requests. Deterministic identity/rekeying must retain
legacy local state and pending work. Explicit browsing-account switches stop playback and clear Now Playing.
Unrelated downloads retain their account ownership and continue.

Rotating tokens stay device-only. Stable native credentials synchronize only
when the effective CloudKit mode and user preference allow it. Removal closes
owned playback and removes account-owned state and credentials in the defined
order. See specification sections 6–7 and the persistence procedure.

## Playback, downloads, and synchronization

App playback-start coordination validates account/item and selects active,
downloaded, or streamed playback. Online playback owns a server session and its
bearer-like routes. Downloaded media is finalized through validated manifests
and staging files; unavailable network/authentication must not destroy valid
local playback. Positions are whole-book coordinates.

Real listening time, audiobook time, and position are separate quantities.
Progress, bookmarks, and offline sessions use durable account-scoped outboxes.
Ordering, uncertain confirmation, and retries remain typed states; ambiguous
creates/deltas must not be resent as though unsubmitted. Statistics reconciles
confirmed remote snapshots with local session overlays without double counting.

## Callback and private-cloud ownership

Framework callbacks can arrive off actor. Actual adapters must admit work using
explicit sendable boundaries, hop to the owning actor, and reject callbacks or
queued commands from retired operations. Cancellation and replacement must not
overlap abandoned work. A `Task` hop inherits task-local context and does not
alone make callback-triggered teardown safe: own/coalesce teardown outside the
unsafe callback context and await completion before retrying.

CloudKit background maintenance preserves local launch and downloaded playback.
Fetched-record application, cancellation, and timeout failures retain distinct
causes and stages; incoming account/preference conflicts await explicit user
resolution. See the [callback audit](release-evidence/callback-cancellation-audit.md)
the [current local CloudKit storage design](design/cloud-sync-storage.md),
and [CloudKit workflow](development.md#cloudkit-schema-management).

## Telemetry and operational boundaries

Remote diagnostics are default-off and reconciled from iOS system Settings at
launch/foreground. Withdrawal retires export work and purges the previous
storage generation. iOS attestation obtains narrow memory-only telemetry tokens;
the Rust backend verifies evidence and the Collector authenticates ingestion.
Native macOS does not initialize remote telemetry. Local diagnostics and remote
export have separate privacy boundaries.

Use the [logging architecture](architecture-logging.md),
[telemetry authentication guide](telemetry-authentication.md), and
[API guide](https://github.com/terminaloutcomes/bleat/blob/main/bleat-api/README.md). Bleat logs are in ClickStack/HyperDX, not
Splunk. Use the repository log helper; never retain sensitive paths, routes,
credentials, callback queries, or raw evidence in artifacts.
