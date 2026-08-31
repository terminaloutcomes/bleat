# CarPlay entitlement and real-environment evidence

## Status

Apple's managed CarPlay Audio App entitlement has been requested and is
pending. `BLEAT_CARPLAY_MODE` defaults to `disabled`, and no Apple approval,
enabled provisioning-profile, or vehicle result is recorded as complete yet.
A signed disabled-build result and partial CarPlay Simulator journeys are
recorded below, but the required matrix is not complete.

Issue [#24](https://github.com/terminaloutcomes/bleat/issues/24) remains open
until every section below has dated evidence.

## Build and provisioning

- [ ] Apple grants `com.apple.developer.carplay-audio` for the application ID.
- [ ] Development and distribution profiles are regenerated after approval.
- [x] A disabled signed app omits the CarPlay audio entitlement.
- [ ] An enabled signed app contains a Boolean CarPlay audio entitlement and
  its embedded profile authorizes the same capability.
- [ ] Personal Team and macOS builds remain CarPlay-free.

Record the application version, build number, build workflow, Xcode version,
and inspection result. Do not record team IDs, device identifiers, profile
contents, or other signing material.

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
