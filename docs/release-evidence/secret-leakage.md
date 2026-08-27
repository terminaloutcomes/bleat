# Native-authentication secret-leakage evidence

Release evidence for [GitHub issue
#48](https://github.com/terminaloutcomes/bleat/issues/48) and AC-02. This record
covers the native Audiobookshelf username/password scope. OIDC callback values,
cookies, and playback-session routes remain outside this gate's scope.

## Evaluated source

| item | recorded value |
| --- | --- |
| source commit | `8529d306f6a8cac816b7d1691c611fdb590dfb99` |
| source tree | clean |
| evaluation date | 2026-08-27 (Australia/Brisbane) |
| application version | 0.1.3 |
| application build | 2 |
| platform | Xcode 26.6 (17F113), iOS Simulator 26.5 |
| command | `mise run test:release-secrets` |

## Journey and sentinels

The gate created a throwaway account with a high-entropy sentinel password and
privately captured the exact initial and rotated Audiobookshelf access and
refresh tokens. Nine exact Release tests passed. Together they exercised login,
forced refresh after an invalid access token, authenticated API work, download,
offline playback and local progress, diagnostics, remote telemetry, logout,
session-Keychain removal, and deletion of the private token capture.

The password reached the UI test through a one-shot private HTTPS broker instead
of XCTest environment or launch arguments. The broker returned the value once,
sent `Cache-Control: no-store`, logged no value, and stopped. Raw token manifests
and server artifacts stayed in a mode-0700 temporary directory and were deleted
after the scan. The server-artifact copy was sanitized before evidence scanning;
only its privacy-safe redaction metadata was retained. Production-relevant Bleat
surfaces were scanned without pre-redaction.

## Scanned surfaces and encodings

The gate scanned process output, the test process configuration, nine xcresult
bundles, unified Simulator logs, app-owned data captured while signed in before
and after token rotation and again after logout, remote telemetry resources and
payloads, Release test products, and the normal unsigned Release archive. It
also scanned the sanitized temporary server-artifact copy. The archive retained
the normal production capability modes and configured production telemetry
origins; only signing was disabled. The scanner covered raw UTF-8,
`Authorization: Bearer`, case-insensitive URL-percent encoding, JSON escaping
with optional escaped slashes and ASCII Unicode escapes, standard and URL-safe
Base64 with and without padding, and UTF-16 little- and big-endian forms with
and without byte order marks. It separately rejected access- or refresh-token
query parameters.

Scanner fixtures proved every supported representation is detected and that
reports contain labels, relative paths, representations, and counts without
secret values or digests.

## Result

The final clean-source run executed nine tests and scanned 5,097 files totaling
865,393,225 bytes across nine labeled surfaces. Two refresh-token occurrences in
the disposable server's raw access logs were sanitized from the temporary
server-artifact copy before scanning; only the privacy-safe redaction metadata
was retained. They are test-harness evidence inputs, not a Bleat deployment
finding. Every production-relevant Bleat surface was scanned without
pre-redaction. The final finding count was zero.

The broader `scripts/test-core.sh` run passed host tests, the optimized Release
build, paid-capability build-mode checks, package resolution, and the application
build stage. Its Simulator stage reported two unrelated unchanged test failures.
`testAutomaticCachedDownloadUsesPersistedAccessWhileOffline` passed a focused
serial rerun. `testPausedCachedBoundaryResumesPreparedContinuation` failed again
because `coverLoadPolicy` did not become `allowNetwork` within its two-second
wait. Issue #48 changes neither that playback/cache path nor its test.
