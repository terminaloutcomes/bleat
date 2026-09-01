# CarPlay entitlement and real-environment evidence

## Status

Apple has approved the managed CarPlay Audio App entitlement. Explicitly
enabled development and distribution builds are signed with profiles that
authorize CarPlay audio. `BLEAT_CARPLAY_MODE` still defaults to `disabled`.
The signed build matrix and CarPlay Simulator journeys are complete; physical
vehicle or head-unit validation remains outstanding.

Issue [#24](https://github.com/terminaloutcomes/bleat/issues/24) remains open
until every section below has dated evidence.

## Build and provisioning

- [x] Apple grants `com.apple.developer.carplay-audio` for the application ID.
- [x] Development and distribution profiles are regenerated after approval.
- [x] A disabled signed app omits the CarPlay audio entitlement.
- [x] An enabled signed app contains a Boolean CarPlay audio entitlement and
  its embedded profile authorizes the same capability.
- [x] Personal Team and macOS builds remain CarPlay-free.

Record the application version, build number, build workflow, Xcode version,
and inspection result. Do not record team IDs, device identifiers, profile
contents, or other signing material.

### 2026-09-01 signing and TestFlight evidence

- Bleat 0.1.3 was built with Xcode 26.6 (17F113) and an explicitly enabled
  CarPlay mode.
- The development-signed app and its embedded development profile contained
  the Boolean CarPlay audio entitlement while retaining the expected Keychain,
  CloudKit, and App Attest capabilities. It installed and launched on a
  physical iPhone; this is phone deployment evidence, not a vehicle journey.
- A distribution-signed internal-only TestFlight IPA, build
  `20260901.0320.02`, contained `BleatCarPlayMode=enabled` and the Boolean
  CarPlay audio entitlement. Its distribution profile authorized the same
  capability, structural inspection passed, and App Store Connect accepted the
  upload for processing.
- An immediately preceding internal-only build, `20260901.0315.30`, exercised
  the documented default and correctly omitted CarPlay. It is retained as
  disabled-artifact evidence and is not the enabled #24 test build.

## CarPlay Simulator

- [x] Home shelves and verified downloads render in the expected order.
- [x] Library selection and bounded pagination work; the navigation-only
  `CPSearchTemplate` is not used by the audio-entitled scene.
- [x] Online and verified offline playback reach Now Playing.
- [x] Artwork remains correct across account, library, and playback changes.
- [x] Play/pause, skip, seek, chapter, and playback-rate controls work.
- [x] Disconnect and reconnect preserve deterministic state.

Record the date, application version/build, Xcode version, Simulator runtime,
and result for each journey.

### 2026-08-31 Simulator validation

- Bleat 0.1.3 (2), Xcode 26.6 (17F113), and the iOS 26.5 Simulator runtime.
- An explicitly enabled build rendered the signed-in account's Home shelves,
  tabs, artwork, audiobook metadata, and verified Downloads entries in their
  expected order after the CarPlay app was refreshed.
- Online and downloaded books both reached CarPlay Now Playing with the
  matching title, chapter, artwork, whole-book elapsed time, and remaining
  time.
- Direct CarPlay interaction passed play/pause, backward and forward skip,
  previous and next chapter, and playback-rate changes. The rate presentation
  used separate decrease and increase controls around the current system rate;
  the displayed rate remained synchronized with the phone player. Seeking also
  changed the whole-book position as expected.
- Disabling and reconnecting the Simulator's CarPlay display preserved the
  paused phone playback state. The reconnected display returned to the CarPlay
  launcher, and reopening Bleat restored the app journey deterministically.
  This is Simulator-only evidence, not a vehicle reconnect result.
- The Library chooser opened from a supported list-header control, identified
  the selected audiobook library, and returned to the refreshed Library after
  selection. The installed account contained one library; the focused
  Simulator pagination fixture loaded its explicit next page and retained
  deterministic reconnect state.
- An intermediate build exposed
  [`CPSearchTemplate`](https://developer.apple.com/documentation/carplay/cpsearchtemplate),
  but direct interaction terminated the app with an
  `NSInvalidArgumentException` because that navigation-only template is not
  allowed for an audio-entitled scene. The unsupported control and
  search-template code were removed; the final build uses only supported
  Library templates.
- Direct playback changed the visible cover and Now Playing background to the
  newly selected book. Focused Simulator tests also passed account/library
  context replacement and seeded replacement-artwork publication.

## Physical vehicle or head unit

- [ ] Online and downloaded playback work on the head unit.
- [ ] Playback continues correctly while the phone app is backgrounded.
- [ ] Wired or wireless disconnect and reconnect behave correctly as
  applicable to the tested system.
- [ ] Head-unit transport controls operate on whole-book position.
- [ ] Simultaneous phone use does not disrupt CarPlay playback or navigation.

Record the date, application version/build, iOS version, connection type, and
vehicle or head-unit model. Do not record device identifiers or private account
details.
