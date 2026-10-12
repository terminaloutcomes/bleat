# CarPlay entitlement and real-environment evidence

## Status

Apple has approved the managed CarPlay Audio App entitlement. Development and
distribution builds default to `BLEAT_CARPLAY_MODE=enabled` and are signed with
profiles that authorize CarPlay audio.
The signed build matrix and CarPlay Simulator journeys are complete. The
maintainer reports that the physical wireless CarPlay journeys also passed.
The public GitHub release workflow also pins CarPlay to enabled. Personal Team
and macOS builds still force it off, and paid-team profiles without the managed
entitlement can opt out explicitly.

Issue [#24](https://github.com/terminaloutcomes/bleat/issues/24) was closed on
2026-09-14 after the maintainer checked every physical journey.

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

### 2026-09-14 release archive validation

- A local `BLEAT_CARPLAY_MODE=enabled` Release archive of Bleat 0.1.3 (2),
  built with Xcode 26.6 (17F113), passed `scripts/archive-beta.sh` and its
  archive inspector. The built `Info.plist` reported `BleatCarPlayMode=enabled`;
  the signed app and embedded profile passed the CarPlay entitlement checks.
  This validates the selected build mode locally, not a GitHub Actions run or
  a new public release.

## CarPlay Simulator

- [x] Home shelves and verified downloads render in the expected order.
- [x] Library selection and bounded pagination work; the iOS 26 audio-unsupported
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
  `NSInvalidArgumentException` because that template is not supported for iOS 26 audio scenes and is not
  allowed for an audio-entitled scene. The unsupported control and
  search-template code were removed; the final build uses only supported
  Library templates.
- Direct playback changed the visible cover and Now Playing background to the
  newly selected book. Focused Simulator tests also passed account/library
  context replacement and seeded replacement-artwork publication.

## Physical vehicle or head unit

- [x] Online and downloaded playback work on the head unit.
- [x] Playback continues correctly while the phone app is backgrounded.
- [x] Wired or wireless disconnect and reconnect behave correctly as
  applicable to the tested system.
- [x] Head-unit transport controls operate on whole-book position.
- [x] Simultaneous phone use does not disrupt CarPlay playback or navigation.

Record the date, application version/build, iOS version, connection type, and
vehicle or head-unit model. Do not record device identifiers or private account
details.

### Maintainer-reported physical validation, reported 2026-09-14

- iPhone running iOS 26.6.2, connected wirelessly to a Pioneer head unit via
  CarPlay. The exact head-unit model and app version/build were not supplied.
- The maintainer used CarPlay during approximately the preceding one to two
  weeks. They reported that every physical journey above worked, including
  online and downloaded playback with the phone foregrounded and backgrounded,
  wireless reconnect, whole-book head-unit controls, and simultaneous phone use.
- This is maintainer-reported vehicle evidence; it is separate from the
  2026-08-31 Simulator and 2026-09-01 signed-artifact checks above.

## Alphabet index and bounded Library windows — issue #331

The older Simulator and maintainer-reported vehicle journeys above predate this
change and do not validate the new index or paging behavior. Implementation adds
an uncollapsed, bounded server-page feed, current-window letter sections,
Next/Previous navigation, runtime limit adaptation, explicit cached portions,
and generation-safe loading/retry.

Automated validation on 2026-10-10:

- The final focused `xcodebuild` CarPlay selection ran all 20 requested app-hosted
  tests on iPhone 17 Pro / iOS 26.5: 20 passed, zero skipped, zero runtime warnings.
  Native list and bar callback regressions enter off the main actor and verify
  the explicit UI hop. The final complete app bundle passed all 505 tests, including these 20
  CarPlay tests, without skips or runtime warnings.
- `BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh` passed: three Rust release-version
  checks, 520 signed host tests with zero skips, host Release build, and the paid
  capability/build-mode matrix. The first attempt rejected the new decoder test
  until `TestSupport/HostTests/inventory.json` was updated. The host suite's one
  intentional cleanup known issue and injected SwiftData save failures are
  test-fixture evidence; the existing dependency watchOS deprecation warning is
  unrelated to this change.
- The focused title-key/legacy-cache decoder test ran and passed (1/1). An initial
  selection before the test existed executed zero tests and provided no coverage.
- `./scripts/test-live.sh` passed against current-stable Audiobookshelf 2.37.0:
  13 passed, eight unrelated OIDC/telemetry tests skipped by this harness lane.
- `./scripts/test-app-live.sh` passed online and offline journeys (1/1 each) with
  zero result-bundle runtime warnings. The first attempt collided with the core
  harness's ports; a retry used the supported isolated root/prefix/OIDC port
  overrides. Both runners removed their disposable resources. Xcode's debugger
  metadata lookup messages did not produce test or runtime-warning failures.
- `mise run swift-lint` and `git diff --check` passed. Initial compilation issues
  (project generation, typed catch, test enum, Objective-C completion transfer)
  and the mutable-capture fixture warnings were corrected before final validation.

Follow-up review fixes on 2026-10-10:

- Failed adjacent-page requests retain their navigation direction. Next/Previous
  traverse retained windows before retrying the corresponding page boundary.
  Terminal authentication and permission failures disable retry at either
  boundary. Accounts without audiobook libraries show an empty state, and a
  library-discovery failure retries discovery.
- Independent page loads emit started/completed/failed events under
  `load_carplay_library_page`. Failures include typed context-validation,
  request-construction, page-request, or page-validation stages and privacy-safe
  failure codes. Validation remains inside the asynchronous page loader.
- All six focused app-hosted regressions passed with zero skips or runtime
  warnings. The final
  complete app bundle passed 511 tests, including all 26 CarPlay tests, with
  zero skips or runtime warnings; the intermediate bundle passed 509 tests. The host gate again passed all
  520 tests, Release build, capability matrix, and three Rust checks. Swift lint
  and diff checks passed. The existing live-suite results above remain prior
  validation and were not rerun for this UI/diagnostic follow-up.
- Two fresh independent complete-change review cycles covered this follow-up.
  The first found two additional P2s (Previous-request direction and discovery
  retry), which were fixed and regression-tested. The second reported no findings.
  All four original P2s and both follow-up P2s are resolved.

The 10,000-book
fixture exercises reachability under changing row limits, including one large
letter group. Locale fixtures cover accents, case, numbers, punctuation, emoji,
CJK, right-to-left titles, duplicate titles/IDs, and server article keys. These
are app-hosted/model tests, not evidence that a head unit displays an index.

Library presentation simplification on 2026-10-10 removes the range/index
explanations, per-section headings, Library page title, and Libraries grid
image/title control. The native letter index, tab label, and Next/Previous
navigation remain. Library selection follows the phone. Cached pages retain
their books and typed adjacent-page failure behavior without a cached-range
banner. This supersedes the range/cached-banner and chooser descriptions above.
All 26 CarPlay app-hosted tests passed on iOS 26.5 with zero skips or runtime
warnings; the two directly affected presentation/cache tests also passed as a
focused selection. An initial test-only protocol/concrete-item compile error was
corrected before these runs. Swift lint and diff checks passed. A fresh
independent complete-change review reported no findings. These checks do not
confirm recovered screen space on a physical head unit.

The approved list/folder design supersedes the window/paging implementation above.
Library automatically loads all uncollapsed server pages, then presents one
scrollable list if it fits the runtime limit, or alphabetic/title-range folders.
There are no Next/Previous controls. Three folder pushes leave room for Now
Playing within five navigation levels. Restrictive limits produce distinct typed
item/section/depth failures rather than silently truncating the catalog. Later
page failures retain fetched books and resume only the failed page on retry.
Changed catalog totals/page sizes produce a distinct typed failure and restart
from page zero on retry.
List/folder validation on 2026-10-10:

- The final iOS 26.5 app unit bundle passed 512 tests, including all 27 CarPlay
  tests, with zero failures, skips, or runtime warnings. Exact test identifiers
  and outcomes were verified from the result bundle. Coverage includes 10,000
  books, Unicode/duplicate titles, changing vehicle limits, folder selection
  off the main actor, stale callbacks, partial cache, retry/resume, and changed
  catalog restart.
- `BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh` passed 520 host tests with
  zero skips, Release compilation, and the paid-capability build matrix.
- `mise run swift-lint` and `git diff --check` passed.
- `./scripts/test-app-live.sh` passed the disposable Audiobookshelf 2.37.0
  online login/playback/download and offline cached-download/local-progress
  journeys: one test each, zero skips or runtime warnings. These phone-app
  journeys do not establish CarPlay head-unit presentation.
- Two initial focused attempts failed compilation because the coordinator
  accessed a file-private resource-state helper. This was corrected; the next
  focused run passed six tests, followed by the final complete app bundle above.
- Two independent complete-change review cycles: the first found one P2 for
  inconsistent totals across catalog pages/retries. Stable snapshot validation,
  typed changed-catalog diagnostics, and restart regression coverage resolve it;
  the second review reported no findings.
- The revised `mise run iphone` attempt failed at device build with status 70:
  Xcode could not find the requested physical-device destination. This version
  was not installed by that attempt.

Account-switch regression follow-up on 2026-10-11:

- A physical-head-unit report found a completely blank CarPlay Library after
  switching accounts, despite the phone showing books. The user subsequently
  confirmed all manual testing passed after installing the fix.
- The strengthened account-switch test caught all three native child list
  templates being reused across replacement tab bars. Catalog context now
  includes account ID, selected library ID and browse generation. Every new
  signed-in root creates fresh native child lists, including catalog-restart
  retries; ordinary content refreshes retain the current hierarchy.
- The regression verifies both fresh child-template identity and the new
  account's catalog. Artwork, discovery-retry and phone-browse tests inspect the
  active replacement hierarchy rather than detached old templates.
- The complete app unit bundle passed 512 tests after the initial hierarchy
  fix. After consolidating root construction, all 27 CarPlay tests passed.
  Result bundles verified exact test identities and zero skips/runtime warnings.
  Strict Swift lint and diff checks passed. Three read-only complete-change
  review passes reported no findings; reviewer test-quality notes were addressed.
- `mise run iphone` built, installed and launched this fix on the physical
  iPhone successfully. This confirms deployment, not CarPlay rendering.
- These app-hosted checks establish model/template behavior, not actual native
  head-unit attachment or rendering. The user supplied the separate manual
  confirmation recorded below.

Manual acceptance on 2026-10-11:

- After installing the account-switch fix, the user confirmed: "yeah all my
  manual testing looks good now" and requested that issue #331 be marked done
  and PR #335 set for auto-merge. This records user-reported completion of the
  manual plan in #331, including the account-switch retest.
- No head-unit model, exact app build/iOS version, photos, or separate iOS 27
  CarPlay Simulator run were supplied. Those details are not inferred from the
  manual confirmation or app-hosted tests. The user approved closure with the
  available automated and manual evidence.

[Issue #331](https://github.com/terminaloutcomes/bleat/issues/331) is complete
per the user's manual acceptance. Existing CarPlay approval is unaffected.

## Native audio search — issue #333

Apple's CarPlay Developer Guide dated 2026-06-08 (printed pages 14 and 24)
permits the Search template for Audio/video on iOS 27 and later. The earlier
search-template exception above was observed on iOS 26; it does not establish
an all-version navigation-only restriction.

Implementation adds an icon-only Search tab only for enabled
iOS 27+ audio scenes. It keeps Library and Downloads available when vehicle
keyboard restrictions change. CarPlay owns its own debounced session, repository
cache provenance, title/author destinations, typed failure/retry and exact-once
completion lifecycle. Search data and author lists are bounded and explicitly
partial when necessary; saved queries never imply a complete offline index.

Automated validation on 2026-10-11:

- `swift test --filter LibrarySearchCoordinatorTests`: all 8 intended tests passed.
- `BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh`: 526 signed-host tests
  passed with no skips, 3 Rust release tests passed, and the Release package
  build and paid-capability build-mode matrix passed. The existing cleanup
  known-issue fixture reported its expected issue; read-only persistence
  fixtures emitted expected Core Data errors. An external dependency manifest
  reports its watchOS-version deprecation.
- App-hosted focused cancellation checks: all 4 intended tests passed with no
  skips or runtime warnings, covering ordinary phone caller cancellation,
  delayed CarPlay detail/stream preparation, newer phone playback, and a
  diagnostic suspension resumed after cancellation.
- `./scripts/test-app-live.sh`: the final online login/playback/download and
  offline cached-download/local-progress journeys each passed (1 test each),
  with exact identifiers, no skips and no runtime warnings verified in the
  result bundles. This validates the shared app flows against disposable
  Audiobookshelf, not native CarPlay rendering. Xcode printed its debugger
  version lookup warning; the test runtime-warning arrays were empty.
- `BLEAT_SKIP_HOST=1 ./scripts/test-core.sh` on a fresh iOS 26.5 Simulator:
  Release simulator build passed and all 525 app tests passed, including the
  40 CarPlay/cancellation identifiers, with no skips or runtime warnings.
  The broader UI gate failed its rotation/playback label assertion, and was
  interrupted for focused base-revision classification. It is not a passed
  complete local gate. Its finalized bundle contains 6 passes, the rotation
  assertion failure, 6 supported opt-in skips, and one cancelled unrelated
  author/series test. Runtime-warning arrays are empty. The invocation exited
  75 after interruption and diagnostic cleanup. The isolated unchanged base
  revision `dd490f1` passed the focused rotation test (1 pass, no skips/runtime warnings). The final-source focused run failed
  the unchanged orientation helper's geometry timeout before reaching the
  original playback assertion (1 failure, no skips/runtime warnings). The
  failed broad run recorded `playback_recovery_exhausted` before its assertion;
  its unchanged UI fixture uses a missing media file. Review found no introduced
  mechanism, but these execution results do not establish that the original
  failure is pre-existing. Both UI failures remain unresolved. No further
  reruns are used to erase them. Completed focused
  outcomes were preserved before stopping its stalled diagnostic collector.
- `mise run swift-lint` and `git diff --check` passed.

Earlier attempts are retained as superseded evidence: initial integration builds
needed protocol-witness, typed-throw, and fixture corrections. A preliminary app
run passed 522 tests but printed an unexplained Xcode compiler message with exit
code zero; mutable-capture warnings were corrected. The subsequent full app run
passed 524 tests and failed the existing ordinary caller-cancellation test;
the cancellation policy is now scoped to CarPlay. Xcode's diagnostic collector
stalled after that run and was stopped after preserving the completed test
outcomes. That reused Simulator also logged an unknown persisted model version;
the final gate uses a fresh disposable Simulator and that migration warning
did not recur in its app diagnostics. One focused diagnostic test
then failed to enter its gate and timed out because its summary request lacked
its detail fixture; the corrected fixture passed the complete four-test rerun.
None of these unsuccessful attempts is counted as coverage.

The installed SDK is iOS 27, but the available Simulator runtime is iOS 26.5.
No iOS 27 CarPlay Simulator or physical-head-unit search evidence is claimed.

Outstanding manual acceptance for #333:

- iOS 26 audio scene has no Search control and never pushes `CPSearchTemplate`;
  iOS 27 enabled scene presents native Search without an entitlement exception.
- Title playback and author navigation select the active account/library,
  including phone searches in progress, account/library switching, and reconnect.
- Rapid/duplicate input, clearing, retry, query caps, cached/missing offline
  queries, native back navigation, and delayed responses remain accurate.
- Disabling the keyboard during a session leaves Library folders and verified
  Downloads usable; restricted lists retain accurate limited-result labels.
- Native labels, touch and rotary input, larger/bold text, and Voice Control.
- Record exact build, OS, head-unit model, restriction transitions, and outcomes
  separately from app-hosted and ordinary Simulator tests.

Issue #333 remains open until these evidence requirements are satisfied.

Independent review ran four complete-change cycles. The blocking stale-playback
finding was repaired with an explicit CarPlay cancellation policy in the shared
playback start lifecycle, checks after preparation suspensions, and rejection of
obsolete Now Playing publication. Ordinary phone playback retains its existing
behavior of continuing after caller cancellation. The latest review reports no P0/P1 findings.

The four P2 findings from that review were resolved in the requested follow-up:

- Native keyboard result rows retain their identities and actions when capacity
  changes (`App/CarPlaySearchController.swift`, `render`).
- Author-page removal cancels only owned author loads, discharges their
  completions once, and rejects late responses and stale retry handlers
  (`templateRemoved`, `register`, `perform`, `loadAuthor`).
- Opening or closing an author page clears retained author results, so a capacity
  update cannot populate a new loading page with the previous author's books
  (`templateRemoved`, `perform`).
- Author status and failure rows, and pushed search results, produce no sections
  at effective zero capacity (`renderAuthor`, `updateLimits`, `publish`,
  `showResults`, `loadAuthor`). The pushed-search empty-section issue was found
  and resolved during the follow-up review.

Six focused regressions cover these fixes, including uncooperative responses,
retained native rows, stale retry handlers after reopening, cached and limited
status rows, failure-row capacity changes, and zero-section pushed results. An additional
review found that pending/failed search pages also needed limit reapplication;
`updateLimits` now republishes retained status rows when capacity changes.
The first follow-up test build failed because three fixture arguments were out
of declaration order; no tests executed. The corrected five-test run passed with zero skips or runtime warnings; its
exact identifiers were verified in the result bundle. A subsequent broader run
failed before executing any selected test because the Simulator rejected the
runner launch as Busy during preflight. This was an environment failure, and the
owned disposable Simulator was booted and its boot completion verified before
rerunning. The final app-hosted `xcodebuild test` selection passed all 46 CarPlay
and adjacent playback-cancellation tests on iOS 26.5, including all six new
regressions. The result bundle verified every requested identifier as passed,
with zero failures, skips, or runtime warnings. Targeted `swift-format lint
--strict` and `git diff --check` also passed. The complete local/UI and live
gates were not repeated for this template-lifecycle follow-up; their previous
evidence and unresolved UI outcomes remain above.

Three independent complete-change follow-up reviews ran. The latest reports no
findings: all original and follow-up P2s are resolved, with no P0/P1 findings.

The manual evidence gaps still prevent claiming that every #333 acceptance
criterion is complete.

### Icon-only Search tab follow-up

Search moved from Library's header to a magnifying-glass-only fourth tab on
supported iOS 27+ scenes, provided the runtime permits four tabs. The tab has an
image and an empty title. Apple's guide (printed page 25) permits Grid,
Information, List, and Point of Interest tab roots, so a grid launcher opens the
native Search template on tab selection and lets people reopen it after Back.
Keyboard restrictions disable the launcher and prevent keyboard presentation.
Delayed selection callbacks validate the selected root tab; switching tabs keeps
the retained Search navigation stack alive.

The capability regression checks that older/disabled scenes retain the three
browsing tabs without a Library header Search button. The iOS 27 branch checks
the image-only fourth tab and native keyboard selection. Positive iOS 27 tab
selection, Back/reopen, keyboard restrictions, and physical head-unit
accessibility remain manual evidence gaps on the available iOS 26.5 runtime.

The tab follow-up's second review found a P2 where Back followed by a tab switch
could skip queued removal cleanup. Search now reconciles its native keyboard,
author page, and result page against the visible stack when its tab is selected
again. A removed keyboard invalidates its controller so it can reopen; removed
author/result pages discharge their existing lifecycles. Regressions cover a
removed keyboard and an uncooperative author load reconciled after removal.
An intermediate final run failed before executing tests because the Simulator
rejected runner launch as Busy during preflight. Boot completion was verified
before the final retry; this was not a failed test assertion.

The third tab review found a second P2 in the grid reopen callback: switching tabs
before the callback's main-actor task ran could push Search on the other tab.
Both tab selection and the grid launcher now use `openSelectedSearchTab`, which
verifies the selected Search root and reconciles navigation before opening the
keyboard. Both review findings are resolved.

Final tab-follow-up validation: `xcodebuild test` passed all 47 selected CarPlay
and adjacent playback-cancellation app tests on iOS 26.5. Every requested
identifier was verified in the result bundle, with zero failures, skips, or
runtime warnings. Targeted `swift-format lint --strict` and `git diff --check`
passed. Four independent complete-change tab reviews ran; the latest reports
no findings and no P0/P1s. Both tab-review P2s are resolved. The complete local/UI
and live gates were not repeated; their previously recorded outcomes remain.

### Internal TestFlight delivery

The requested internal deployment uploaded `2026.10.11 (20261011.2129.21)`
from clean commit `059f803`. Source marketing version, timestamp fallback,
changelog, and regenerated Xcode configurations were aligned first;
`mise run release:check -- --repository-root <deployment-checkout>` passed
using the repository release checker. One independent release-metadata review
reported no findings.

`mise run testflight:internal` passed six CloudKit validator tests, three
release-version tests, export-options validation, production CloudKit schema
validation, signed Release archive inspection, and distribution IPA inspection.
The internal-only export completed with Apple's explicit upload confirmation.
App Store Connect subsequently reported `valid`, `IN_BETA_TESTING`, and membership
in the existing internal `Testers` group. `testflight-release` saved `en-AU`
testing notes and verified that same membership. External state is
`NOT_APPLICABLE`; no external group or beta review was requested.

Local signed artifacts, checksum, redacted upload logs, and delivery report are
retained under `.build/testflight-internal/2026.10.11-20261011.2129.21/`.
This is verified internal delivery and does not complete the outstanding native
iOS 27 or physical head-unit acceptance evidence above.

### Rebase and phone metadata correction

Rebased on main `c281391`; all 47 selected CarPlay and adjacent playback tests
passed on iOS 26.5, with exact identifiers verified and zero skips or runtime
warnings. The first attempt executed no tests because required telemetry build
settings were absent; the successful run supplied the configured settings.
Independent complete-change rebase and metadata reviews reported no findings.

The UTC date advanced while the source still declared `2026.10.11`, causing
`mise run iphone` to reject its fresh build number. Updated source version,
fallback timestamp, changelog and regenerated Xcode settings to `2026.10.12`;
`mise run release:check` passed. `mise run iphone` then built, installed and
launched successfully. Device metadata confirmed `2026.10.12 (20261012.0814.16)`.
The earlier phone install had retained `2026.10.08 (2)` metadata.

The user will perform manual testing and requested review-ready status. The
unresolved UI failures and native iOS 27/head-unit acceptance gaps above remain
open. The previously delivered internal TestFlight build remains unchanged.

## Issue 342: shared cellular confirmation

The phone and CarPlay resolve one account/item request by its UUID. Native
Download/Cancel actions cannot resolve a later queued request. The coordinator
uses `CPAlertTemplate` when its action limit permits both choices and
`CPActionSheetTemplate` when the alert limit is one. Only the owned confirmation
is dismissed; modal contention and failed presentation/dismissal are retried.
Queued confirmations advance when a decision is claimed, preserving FIFO even
while an accepted transfer prepares.

The final integrated branch is based on main `6ec9976`. Strict Swift lint and
`git diff --check` passed. `BLEAT_SKIP_SIMULATOR=1 ./scripts/test-core.sh`
passed 536 signed host tests, the host Release build, and paid-capability checks.
The cleanup test intentionally records its expected known issue; the upstream
OpenTelemetry package emits an existing watchOS deployment deprecation warning.
`./scripts/test-app-live.sh` passed both named online and offline journeys with
zero skips or runtime warnings.

The first simulator attempt failed before
tests because a Rust helper dependency was compiled with Xcode's simulator SDK;
building repository helpers with the host SDK resolved it. A subsequent test
assumed the disconnected framework retained two alert actions and indexed a
truncated action list. XCTest crashed with a task-allocation error. Tests now
exercise the actual native alert/action-sheet actions. The clean focused run
passed ten tests with no runtime warnings. A later final-source attempt was
rejected by SpringBoard as busy before test execution; it is not passing evidence.
After restarting the owned simulator, the three final queue regressions passed
with zero skips or runtime warnings.

`BLEAT_SKIP_HOST=1 BLEAT_SIMULATOR_DESTINATION=<owned-simulator-destination>
./scripts/test-core.sh` passed the Simulator Release build and executed all 572
app tests: 571 passed, including all seven new CarPlay confirmation regressions,
and one failed. `testLastPlayingRejectsDiscardedSelectionInNativeCallbacks`
expected `.unavailable` but observed `.accepted`. There were no runtime warnings.
The unchanged main baseline passed all 565 app tests, and the isolated failing
test passed once and then all 20 verified repetitions. This failure remains
unclassified at initial publication; it was not claimed as a confirmed pre-existing
failure. The complete
gate stopped before its UI suite. Review identified a possible scheduling race
in unchanged selection-resume startup code, but no demonstrated connection to
the cellular confirmation changes. The focused phone UI test
`testSignedInAlertsPresentInSequence` passed with zero skips or runtime warnings.

Five independent complete-change review cycles ran. The first P1 (a global claim
blocking another decision) was fixed with per-request claims. The fourth review
raised a P2 for an outdated remaining-queue expectation in the new overlap test;
it was corrected as part of the P1 regression coverage and subsequently passed.
The latest review, after integration with main, reported no findings and no P0/P1.

The maintainer subsequently reported successful Download/Cancel on both screens
using their CarPlay test device on iOS 27.0.1 with this current build, explicitly
confirmed by the maintainer. Queued prompts appeared to work but were not
confidently confirmed. Reconnect/foreground behavior remains unconfirmed.

Manual verification checklist:

1. On an expensive network path, select an uncached large item from CarPlay.
   Confirm both screens show the correct item/size and Download/Cancel choices.
2. Accept on CarPlay, then cancel another item there. Confirm exactly one transfer
   for acceptance, none for cancellation, and matching phone prompt dismissal.
3. Queue at least two items. Resolve one on the phone and the next on CarPlay.
   Repeated taps or delayed actions must not resolve a later request.
4. While a prompt is pending, disconnect/reconnect CarPlay and background/foreground
   the phone. Confirm the same decision remains available.
5. Switch to Wi-Fi, remove the owning account, or reset local work. Confirm stale
   prompts disappear. With an unrelated CarPlay modal open, leave it intact and
   verify confirmation becomes available after that modal closes.

Record app/build, iOS version, Simulator/head-unit context, and outcomes here.
The physical outcome above is maintainer-reported, rather than an automated
device or head-unit validation.

### Bootstrap resume race follow-up

The existing last-playing rejection test now gates the app-start completion
diagnostic. This holds bootstrap open after its invalid selection has been
discarded while the already-claimed resume task is still suspended. Before the
fix, the gated test reproduced `.accepted` instead of `.unavailable` with both
mismatched-account and signed-out startup. Retiring bootstrap resume admission
now also cancels the pending selection-resume task and invalidates its generation.
It does not cancel shared bootstrap work.

The gated regression and four adjacent bootstrap/cancellation tests passed with
zero skips or runtime warnings. Strict Swift lint passed after correcting one
test-initializer line wrap. A sixth independent review of the complete merge
change reported no findings. The Simulator Release build and all 572 app tests
passed, including the gated resume regression and all seven CarPlay tests, with
zero skips or runtime warnings. Both named live-application journeys passed
again with zero skips or runtime warnings.

The broad UI attempt ran for approximately twelve minutes before it was stopped
to finish focused validation. Its finalized result contains 21 passed tests,
six expected live/screenshot skips, one assertion failure and one canceled test
(`testBookDetailPlacesChapterProgressBelowPlayback`); Xcode exited 75 after
SIGINT and emitted interruption diagnostics. No runtime warnings were recorded.
`testPlaybackRemainsUsableAtLargestDynamicType` could not hit `player.sleepTimer`
below the screen. The layout, scrolling helper and fixture are unchanged, and
review found no demonstrated causal connection to this PR. The failure remains
unclassified and the full UI gate remains incomplete. Focused
`testColdResumeFailureOffersRetryAndKeepsSelectedBookAfterDismissal`,
`testColdResumeAuthenticationOffersAccountEditor`, and
`testSignedInAlertsPresentInSequence` all passed with zero skips or runtime
warnings; their exact result identifiers were verified.
