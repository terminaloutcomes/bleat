# iOS 27 CarPlay and audio-session compatibility (#362, #369)

The two CarPlay failures reproduced unchanged on both base `375207ed` and
macOS-isolation head `3630c21`: two failures each, with no skips or runtime
warnings, under matching iOS 27 SDK/runtime, Debug and serial runner conditions.
The signed-in browsing case assumed three tabs while the existing iOS 27 policy
enables a fourth Search tab. The Search case stored a root in its presenter
fixture without supplying the native selected-template state used by admission.

The browsing fixture now explicitly disables optional Search. Selection belongs
to the presenter boundary: the real presenter reads native selectedTemplate,
while the fixture installs and selects only its current root's templates. The
root identity, Search identity and current selection checks remain. A Debug
completion sequence observes actual queued delegate processing. The new test
rejects changed selection, disconnect and retired roots, then accepts a current
off-actor callback. Two-second budgets and semantic push assertions remain.

Focused native iOS 27 execution passed all three selected identities, zero
failures/skips/expected failures/runtime warnings. The owning CarPlay slice
passed 53 identities with zero failures/skips but retained three audio-session
runtime warnings. This is not clean audio or physical CarPlay acceptance.
The initial new-test compilation attempt executed zero tests because four
wait calls omitted the helper's required observation diagnostic; those calls
were corrected without changing budgets or assertions.

At the initial CarPlay repair commit, audio migration was still pending. The original complete compatibility run retained
103 AVAudioSession activation/deactivation warnings and nine SessionCore warnings.
Apple supplies native async activation/deactivation from iOS 27. The maintainer
explicitly approved the unavoidable synchronous iOS 26 setActive calls and
category setup, for which Apple supplies no async setter. No audio migration is
claimed complete by this first CarPlay repair receipt. Exact final ordering,
cancellation, compatibility and warning outcomes will follow the implementation.

No physical device, installed retest build, signing material or trust setting is
changed. Security dependency remediation is separate; this branch changes no
lockfile. Normal macOS isolation remains in PR #466, with integration coordinated
after independently reviewed fixes merge.


## Audio implementation and approved compatibility boundary

Playback now awaits one process-wide audio-session owner before opening a player,
resuming Play, or recovering media services. Native actions are serialized and
awaited even after caller cancellation, because Apple's completion API offers no
cancellation that proves hardware work has retired. Activation leases prevent an
old completion's cleanup from deactivating a newer activation. Synchronous remote
commands admit one owned, coalesced async Play task; pause cancels admission and
Stop awaits retirement before cleanup. Distinct configuration, activation and
release failures preserve operation, stable failure code, stage, allowlisted
native domain and numeric code. NSError descriptions and userInfo are omitted.

On iOS 27, activation and deactivation call Apple's public native completion APIs.
A declaration-only Objective-C bridge allows supported older SDK builds to call
the same iOS 27 APIs at runtime, with a Sendable completion; it implements no
replacement selectors and uses no private API. On iOS 26 only, setActive remains
synchronous on the owning main actor because that OS has no native async API.
setCategory also remains synchronous on the owning actor because Apple supplies
no async setter; unchanged playback/spokenAudio configuration is not set again.
The maintainer explicitly approved these exact boundaries before implementation.
The iOS26 fallback can be removed when minimum deployment reaches iOS27; category
setup can change when Apple supplies an async alternative. macOS continues to let
AVPlayer manage audio without an AVAudioSession operation.

The first runnable focused audio run executed 11 tests: ten passed and one model
test failed two assertions that incorrectly expected replacement start to remain
ready and paused. Replacement start has always autoplayed; its corrected oracle
requires the current item, active playback intent and non-retired state, then an
awaited final Stop. Seven adapter cases passed, including native iOS27 activation
and release, off-actor/duplicate callbacks, FIFO cancellation drainage, rejected
release recovery and stale-lease exclusion. Compilation-only attempts before this
run executed zero tests and are not counted as coverage. The intermediate Xcode diagnostic collector reached its 600-second timeout after test execution; its failed result and logs are retained separately. Final verification follows.


## Verified repair execution

On implementation head `7871adc5215dffe7c0ae521e12543be12825974e`, the corrected
focused selection executed all 15 expected audio/CarPlay identities: 15 passed,
zero failures, skips, expected failures or runtime warnings. It includes both
original CarPlay failures, current/retired callbacks, interruption resume, native
callback and duplicate completion adapters, cancellation/FIFO, stale leases,
pause/stop/replacement races, typed release failure and real system activation.

The supported complete app and UI smoke lane independently discovered and
verified **654 passed, zero skipped** on iOS 27.0. The xcresult summary confirms
654 passes, zero failures/expected failures/runtime warnings, including both UI
smoke journeys and the three Swift Testing exporter cases. The original 103
AVAudioSession and nine SessionCore runtime warnings do not occur in this result.
No XCTest timeout or failure budget was increased. Existing interruption-resume
assertions now await actual asynchronous activation before checking its count.

Existing host diagnostic/route suites passed all 71 tests; the unsigned macOS
Release build passed. Strict Swift lint, documentation links, audit/index parity
and diff whitespace checks passed. This receipt-only update changes no tested
implementation. Exact final-head CI and its iOS26 runtime evidence are reported
in the PR, separately from local iOS27 execution. iOS26 is not installed locally;
no local iOS26 execution is claimed. Physical-route, energy, physical CarPlay,
and signed macOS authentication/relaunch acceptance remain unverified.
