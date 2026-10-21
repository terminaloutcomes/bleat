# Native-authentication secret-leakage evidence

Release evidence for [GitHub issue `#48`](https://github.com/terminaloutcomes/bleat/issues/48) and AC-02. This record
covers the native Audiobookshelf username/password scope. OIDC callback values,
cookies, and playback-session routes remain outside this gate's scope.

## Evaluated source

| item | recorded value |
| --- | --- |
| source commit | `014eec32aa74d7db6feb37aeacc76064b5bfe286` |
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
bundles, unified Simulator messages decoded from the collected `.logarchive`,
app-owned data captured while signed in before and after token rotation and
again after logout, remote telemetry resources and payloads, Release test
products, and the normal unsigned Release archive. It also scanned the sanitized
temporary server-artifact copy. The archive retained the normal production
capability modes and configured production telemetry origins; only signing was
disabled. The scanner covered raw UTF-8,
`Authorization: Bearer`, case-insensitive URL-percent encoding, JSON escaping
with optional escaped slashes and ASCII Unicode escapes, standard and URL-safe
Base64 with and without padding, and UTF-16 little- and big-endian forms with
and without byte order marks. It separately rejected access- or refresh-token
query parameters.

Scanner fixtures proved every supported representation is detected and that
reports contain labels, relative paths, representations, and counts without
secret values or digests.

## Result

The final clean-source run executed nine tests and scanned 5,910 files totaling
1,787,872,690 bytes across nine labeled surfaces. Two refresh-token occurrences
in the disposable server's raw access logs were sanitized from the temporary
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

## Revalidation 2026-10-21 (#362)

The native-authentication gate passed at clean source
`4542700bc9c9f6e84017403630aa18afbcb904b7` using the existing supported
`BLEAT_MARKETING_VERSION=2026.10.14 mise run test:release-secrets` configuration.
All build/test inputs match reviewed and merged #440; only evidence documents
differ. The inspected normal Release archive reports version `2026.10.14` and
fresh UTC build `20261021.1653.50`, using configured signing. Project metadata,
TLS trust and capability policy were unchanged; nothing was uploaded or deployed.
Toolchain: Xcode 27.1 (27A9275), iOS Simulator 26.5.

All seven scanner Python regressions and these nine exact native identities
passed, with no failed or skipped native cases:

- `BleatUITests/BleatLiveUITests/testLiveOnlineLoginPlaybackAndDownload`
- `BleatAppTests/ReleaseSecretLeakageTests/testCaptureInitialTokensAndForceRefresh`
- `BleatUITests/BleatLiveUITests/testReleaseSecretScanRefreshAfterTokenInvalidation`
- `BleatAppTests/ReleaseSecretLeakageTests/testCaptureRotatedTokens`
- `BleatAppTests/ReleaseSecretLeakageTests/testRemovePrivateCapture`
- `BleatUITests/BleatLiveUITests/testLiveOfflineCachedDownloadAndLocalProgress`
- `BleatUITests/BleatLiveUITests/testReleaseSecretScanLogout`
- `BleatAppTests/ReleaseSecretLeakageTests/testLogoutRemovedSessionCredentials`
- `BleatAppTests/ReleaseSecretLeakageTests/testPrivateCaptureRemainsRemovedAfterLogout`

The final scan covered all nine surfaces listed above: 667 files totaling
1,677,234,199 bytes, with zero prohibited findings. Two refresh-token occurrences
were redacted only in the disposable server's `compose.log` copy, as in the
original gate; production-relevant Bleat surfaces were not pre-redacted. The
retained report contains no secret values or secret digests. This gate still
does not cover the OIDC/cookie/playback-route scope excluded above.

Independent after-run checks found no owned Simulator, container, volume or
private secret-broker process. The non-secret `report.json`, `scan.json` and
`tests.json` are retained under
`.build/i362-release-scan-explicit-version-retained-report/`, with exact identity
and cleanup verification in `.build/i362-release-scan-explicit-version-verified.json`.

The original Release build failure and the subsequent default-version archive
preflight failure remain retained separately. #440 repaired the two demonstrated
build blockers. The latter version mismatch needed the documented explicit
checked-in marketing version, not a source-version bump or validation bypass.
The supported rebuild keeps a fresh UTC build number and validates project,
generated settings and changelog consistency. This result is local disposable
server/Simulator/archive evidence, not physical-device acceptance.
