# Release screenshot workflow migration — 22 October 2026

This records the bounded #369 migration from the capture/check shell entrypoints
into the Rust `capture-release-screenshots` command. It is screenshot workflow
evidence, not whole-epic or physical-device acceptance.

## Reviewed implementation

Implementation `5e4c9f9cd293a16143d6d6e6ff770527cc80e5c8` is based on
`c9a142bc28a5864d3f7bd718d2aebc5ca9555fdf`. Independent review inspected the
complete migration and found one interrupted-Simulator-creation ownership gap.
The correction records the exact run-specific name before creation and discovers
that name during cleanup even if creation returned no UDID. The correction and
its regression received a second review with no actionable findings.

The Rust workflow retains the five-book fixture, ordered ten PNG names,
device/orientation directory layout, dark suffixes and public manifest fields.
It reads the pinned profile directly. Docker, Xcode/Simulator and `sips` remain
native prerequisites. Shared shell helpers used by other workflows remain;
the screenshot entrypoint no longer executes them. Existing output destinations
are rejected. Exported images remain on later failure, alongside native failure
evidence. Console wording is not a compatibility contract.

## Automated checks

- `cargo test --quiet --locked --package scripts --lib release_screenshots`:
  **25 passed, zero failed/ignored, 108 filtered** at the reviewed implementation.
- Strict scripts `cargo clippy --all-targets -- -D warnings`: passed.
- The earlier complete scripts library execution passed **132 tests**, before
  the final exact-name cleanup regression was added. It is retained as earlier
  shared-owner evidence, not relabelled as a 133-test final-head execution.
- `mise run screenshots:check` passed the earlier 24-case contract set and
  decoded all five actual fixture covers. The final focused run includes the
  additional cleanup regression.
- `mise run docs:check` and the mdBook HTML build passed.

## Native iPhone portrait/light slice

One clean-source invocation at the reviewed implementation used the installed
rustup toolchain through command-local PATH and the existing supported
`BLEAT_MARKETING_VERSION=2026.10.14` setting. No release metadata, host trust,
signing policy, package installation or persistent environment was changed.

Selection: iPhone 17 Pro Max, iOS Simulator 26.5, portrait, light, `en_AU`.
Xcode: 27.1 build 27A9275. The Release app reports version **2026.10.14**, build
**20261014.0835.34**. The pinned current-stable Audiobookshelf is 2.37.0;
the public manifest records both exact container image digests.

The exact native identity
`BleatUITests/BleatReleaseScreenshotTests/testReleaseScreenshots` passed once:
**one total/pass, zero failures, skips, expected failures or runtime warnings**.
The native test tree and summary were retained separately from public output.
All ten required PNGs decoded at **1320×2868** and the public manifest passed
schema/content validation. Visual contact-sheet review covered login, Home,
Library, book details/chapters, mini-player, Now Playing, Downloads, Search and
Settings; no new visible defect was identified in this slice.

Local artifacts are retained in `.build/release-screenshots-20261022-iphone/`
(ten PNGs plus `manifest.json`), with compact native identity/summary and cleanup
receipts in `.build/release-screenshot-receipts/`. PNGs were not recompressed or
modified for contact-sheet review. SHA-256 hashes of all eleven public files
were retained in the local delivery checkpoint.

Cleanup reported no failures and private-workspace removal. Independent checks
confirmed absence of the exact owned Simulator ID/name, Compose project
containers/volumes and run-labelled media containers. Free space was **18.49
GiB** afterward; the 3 GiB active guard did not trigger. Successful large result
bundles and invocation-owned build/media scratch were removed; public outputs
and earlier evidence were preserved.

This verifies one of eight default device/orientation/appearance combinations.
The other seven, any optional video capture and the separate #369 acceptance
groups are not certified by this result. macOS application work stays deferred;
the earlier inconclusive iPad interaction observation is not resolved here.

## Full matrix and orientation correction

The subsequent clean-source run at
`3af98f7334e48ef841153c15dff6d62de9176992` completed the default matrix:

| Device | Portrait light/dark | Landscape-left light/dark | PNG dimensions |
| --- | --- | --- | --- |
| iPhone 17 Pro Max | 2 passed | 2 passed | 1320×2868 / 2868×1320 |
| 13-inch iPad Pro M5 | 2 passed | 2 passed | 2064×2752 / 2752×2064 |

All **eight exact native journeys passed**, with zero failures, skips, expected
failures or runtime warnings, and all **80 PNGs** exported. The iPad Release
build completed within its 40-minute budget. Independent checks verified
absence of both owned Simulators and every owned Compose/media resource and
private workspace; free space afterward was **19.31 GiB**. Native summaries,
test trees and cleanup receipts remain under
`.build/release-screenshot-receipts/c28f5f28cef0a9a80e78eb0fa57ee2d3/`.

File QA then found a real export defect missed by dimensions-only checks:
landscape pixels were correctly rotated, but retained generated EXIF and Adobe
XMP orientation 8 and portrait dimension metadata. A metadata-aware viewer
therefore displayed a sideways image. The port had retained the previous shell
workflow's `sips` rotation behavior. This was a file-export defect; no app or
layout change was made.

Correction `756431d1daa94d893aa96af4c8497368b7382c6b` removes only generated
EXIF and Adobe XMP chunks after landscape pixel rotation. All pixel, color/profile
and unrelated text chunks remain byte-identical. Independent review approved
the correction and its validation boundary. The final **28 focused Rust cases**
and strict all-target Clippy passed; the initial module-declaration-order compile
error is retained separately from the successful corrected run.

A private validation driver imported that exact committed production helper and
created a separate corrected artifact set. Every PNG passed native decoding and
expected dimensions; all **40 landscape PNGs** report canonical viewer
orientation. Independent chunk comparison verified pixel/profile byte identity
for all 80 files; a decoded representative comparison reported zero pixel
differences. Contact-sheet review covered all eight contexts, and the corrected
representative displayed correctly in the metadata-aware viewer. This verifies
scene/theme/orientation and file integrity, not that all scrollable content must
fit a single viewport or that G1 accessibility/manual acceptance is complete.

Corrected files are in
`.build/release-screenshots-20261022-matrix-canonical/` (80 PNGs plus the public
manifest). Original matrix files remain unchanged in
`.build/release-screenshots-20261022-matrix/`; the earlier ten-screen slice is
also retained. The public schema, filenames and layout are unchanged. Its git
revision identifies the export correction; `canonical-export.json` beside the
native receipts separately records the native capture revision, exporter source
hash and per-file source/output hashes. The corrected manifest SHA-256 is
`e69f75a90acad5dc7937105f0720ab75daf3dc882e7fc5d83e426aa2517f1fe7`.

The native capture is not relabelled as execution at the correction revision.
The app, native test journey, fixtures, service setup and build/selection inputs
are unchanged between the two revisions; only post-capture metadata processing,
its Rust regressions and audit entries changed. This input equivalence and direct
production-helper replay avoid repeating the long native builds.

G5's agreed default screenshot matrix is now evidenced. Optional video capture
was not run. G1/G2/G6/G7/G8 remain separate active acceptance groups, signed macOS
remains deferred, and the inconclusive iPad interaction observation is unchanged.
#369 and #362 remain open. The earlier `3af98f7` CI completed successfully,
including 608 host passes plus the named unsigned-Keychain skip and 629 iOS
passes with no skips/runtime warnings; final correction-head CI is a separate
publication gate.
