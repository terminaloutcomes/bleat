# Audiobookshelf compatibility

Bleat supports Audiobookshelf 2.26.0 or newer. The disposable compatibility
matrix exercises the minimum supported release and a pinned current-stable
release with the same `BleatCoreLiveTests` suite on root-hosted and
`/audiobookshelf` path-prefixed servers. Audiobookshelf 2.36.0 remains the
source-audited contract baseline in [The iOS App Spec](audiobookshelf-ios-app-spec.md).

| Role | Version | Image index digest | Root | Prefix | Verified |
| --- | --- | --- | --- | --- | --- |
| Minimum supported | 2.26.0 | `sha256:16685fbba37a21d403f5390b907d286e15b3086d26527269b4ad785f71f571e5` | Pass | Pass | 2026-09-30 |
| Audited baseline | 2.36.0 | `sha256:180acad33d69c99ed208676465d8edcb268fa46967735579a7810859885b1a8e` | Historical evidence | Historical evidence | Earlier runs |
| Current stable | 2.37.0 | `sha256:6432d1dc58951b0280b29144ffc69834a8ae02786a2126f6b7c9bd453801c78b` | Pass | Pass | 2026-09-30 |

Run `mise run test:compatibility` for the sequential matrix or
`./scripts/test-live.sh minimum` and `./scripts/test-live.sh current-stable`
for one selected profile. `mise run test:live` defaults to current-stable.
The app-live and release-secret gates also select current-stable.
On 2026-09-30, `mise run test:compatibility` passed both profiles from fresh
state: each selected 21 core live tests, executed 13, and recorded eight
expected skips for optional fixtures and OIDC research.
The 2.37.0 `test:app-live` gate passed both selected iOS Simulator journeys:
online login/playback/download and offline cached playback/local progress.
Its fault-proxy evidence recorded one injected download 401, one token refresh,
and successful range retries.
The 2.37.0 sidecar-upload probe passed an exact VTT byte round trip after an
explicit item scan.
The 2.37.0 `test:release-secrets` gate passed nine selected XCTest cases and
found zero prohibited secret values across 657 scanned files, including the
Release archive, app-owned data, server artifacts, and remote telemetry. An
initial Release UI failure was traced to an ambiguous Home button query after
download completion; the UI test now selects one matching button and the full
gate passed from fresh state.

The manifests in `TestSupport/ServerHarness/profiles/` bind a semantic role to
an exact version, image tag and digest, and seed version. The runner derives a
fresh Compose project name from the role, version, and run UUID. Its config,
metadata, and Caddy volumes are therefore separate for every run. Both
servers must report the selected version through `/status` before seeding.
The runner removes containers, orphans, and volumes even after a failure.

The shared seed flow initializes both servers, creates a disposable account,
scans the three-book media library, and applies navigation metadata. Add a
version-specific seed branch only for an observed server contract difference.
Redacted captures from fresh servers live under
`Tests/BleatCoreTests/Fixtures/<version>/`; their filenames include the version
because SwiftPM places processed resources in one bundle. They exercise
response decoding without Docker; `test:compatibility` is the evidence that
client requests and mutations work against real servers. To advance
current-stable, verify the upstream image digest, update its manifest, run
`mise run fixtures:live current-stable` to capture new fixtures, run the matrix
and Audiobookshelf-backed app gates, and record the result here. Use
`mise run fixtures:live minimum` for the minimum profile. The Rust capture
command validates the selected manifest, redacts credentials and sensitive
fields before writing, and removes its disposable Docker volumes.

Verified 2.26.0 differences:

- Expanded book and search media omit `numTracks`, `numAudioFiles`, and
  `numChapters`; the client derives these from the server's `tracks`,
  `audioFiles`, and `chapters` arrays. See the pinned
  [2.26.0 book model](https://github.com/advplyr/audiobookshelf/blob/v2.26.0/server/models/Book.js).
- The aggregate bookmark and progress GET routes added later are absent.
  A 404 on those routes selects the existing `/api/me` response, which carries
  the account's bookmark and progress arrays. Mutations retain their existing
  item routes. See the pinned
  [2.26.0 router](https://github.com/advplyr/audiobookshelf/blob/v2.26.0/server/routers/ApiRouter.js).
- The refresh endpoint can return identical opaque refresh-token text when
  calls occur within the same server timestamp second. Live assertions prove
  request recovery and logout invalidation without requiring a token byte change.

OIDC/PKCE remains research code outside the active compatibility matrix.
The suite selects the existing native-authentication and contract tests while
its OIDC test skips without a configured OIDC fixture.

Evidence for this change is measured against Bleat commit `44a49c04` and the
compatibility changes in this pull request.
