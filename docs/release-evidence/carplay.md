# CarPlay entitlement and real-environment evidence

## Status

Apple's managed CarPlay Audio App entitlement has been requested and is
pending. `BLEAT_CARPLAY_MODE` defaults to `disabled`, and no entitlement,
provisioning, CarPlay Simulator, or vehicle result is recorded as complete in
this document yet.

Issue [#24](https://github.com/terminaloutcomes/bleat/issues/24) remains open
until every section below has dated evidence.

## Build and provisioning

- [ ] Apple grants `com.apple.developer.carplay-audio` for the application ID.
- [ ] Development and distribution profiles are regenerated after approval.
- [ ] A disabled signed app omits the CarPlay audio entitlement.
- [ ] An enabled signed app contains a Boolean CarPlay audio entitlement and
  its embedded profile authorizes the same capability.
- [ ] Personal Team and macOS builds remain CarPlay-free.

Record the application version, build number, build workflow, Xcode version,
and inspection result. Do not record team IDs, device identifiers, profile
contents, or other signing material.

## CarPlay Simulator

- [ ] Home shelves and verified downloads render in the expected order.
- [ ] Library selection, bounded pagination, and search work.
- [ ] Online and verified offline playback reach Now Playing.
- [ ] Artwork remains correct across account, library, and playback changes.
- [ ] Play/pause, skip, seek, chapter, and playback-rate controls work.
- [ ] Disconnect and reconnect preserve deterministic state.

Record the date, application version/build, Xcode version, Simulator runtime,
and result for each journey.

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
