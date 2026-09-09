# Transcript Reduce Motion audit

Issue [#202](https://github.com/terminaloutcomes/bleat/issues/202) follows the
maintainer's completed manual Reduce Motion audit in #41.

The transcript view reads SwiftUI's system `accessibilityReduceMotion` value.
Target scrolling uses no animation when enabled and the default animation when
disabled. The existing two-second highlight clearing task is unchanged.

The focused UI regression is
`BleatUITests.testTranscriptGoToCurrentPositionHighlightsSavedSegment`. Its long
cached transcript places the destination beyond the viewport on iPhone and iPad.
It checks the expected target is hittable, its highlight clears, and returning
to the action permits another jump to the same target with the same clearing
behavior. It also retains the existing no-saved-position relaunch check.
A test-only attachment records the system setting read by the transcript view;
it does not override that setting.

## Validation

Run date: 2026-09-08. Build: Bleat 0.1.3 (2), Debug, based on `a2195685`
plus this change. Xcode 26.6 (17F113). Runtime: iOS/iPadOS 26.5 (23F77).

| Simulator | System Reduce Motion | Focused test result |
| --- | --- | --- |
| iPhone 17 Pro | Disabled | Passed (1 test) |
| iPhone 17 Pro | Enabled | Passed (1 test) |
| iPad (A16) | Disabled | Passed (1 test) |
| iPad (A16) | Enabled | Passed (1 test) |

Result bundles are retained under `.build/issue-202/`, named
`<device>-<mode>-final.xcresult`. Each completed run is checked with
`xcresulttool get test-results tests`; exported attachments confirm the setting
read inside the transcript view.

The first iPhone/disabled attempt failed because the test queried hittability
on the transient highlight after its two-second lifetime. Its recording and UI
hierarchy confirmed that scrolling reached the visible destination. The test
now checks transient existence/clearing before asserting the stable target's
hittability. The original failed bundle is retained separately.

All four runs executed exactly the requested test and passed; each attachment
matched its requested enabled/disabled mode. The disposable iPad required a
restart during its initial CoreLocation migration, then completed boot and both
runs normally. The full regression and disposable-server suites were not run
for this localized scrolling change.

The Debug build passed. One incremental rebuild emitted stale-artifact cleanup
warnings for equivalent workspace path aliases; all of its warnings matched
that category. The final test rebuild and strict Swift formatter lint passed.
Xcode also reported an LLDB version-snapshot warning during test launch; it did
not prevent the recorded test execution. No application crash was reported.

The UI regression checks navigation and highlight behavior, not animation frames.
The no-animation selection is also checked by source review. Physical iPhone
and iPad verification of scrolling in both system modes remains pending under
#202; Simulator results do not substitute for that device evidence.
