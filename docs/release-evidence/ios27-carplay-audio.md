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

Audio migration is in progress. The original complete compatibility run retained
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
