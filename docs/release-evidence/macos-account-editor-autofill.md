# macOS account-editor AutoFill cleanup failure

A normal signed native macOS application on macOS 27.0.1 saved and validated an
edited local endpoint, but its account-editor sheet remained visibly attached.
A read-only check confirmed that the saved endpoint matched the edit. The main
thread was idle in AppKit's event loop; keyboard focus reached the dimmed parent
content rather than the stale editor. No account, credentials or history were
reset, and the application was not force-terminated.

Private system logs captured repeated `NSRangeException` failures in
`SPSafariPlatformSupport._removeVisibleObserverFromWindow`, reached through
`credentialSelected`, AutoFill cleanup, text-field end editing and key-window
resignation. One stack included `NSWindowEndWindowModalSession` and SwiftUI's
sheet teardown. Private logs and process/concurrency samples are not repository
fixtures or public attachments.

## Scoped mitigation

On macOS 27 and later, only the account editor's username/password controls opt
out of semantic Password AutoFill registration using the public optional
`textContentType` API. The password remains a native secure field. Manual entry
and paste still work, and blank-password editing retains saved credentials. A
visible footer explains the temporary editor-only limitation. Native login,
iOS credential AutoFill, earlier macOS versions, and system password-manager
settings retain their existing behavior. No security/trust settings are changed.

This avoids the observed framework integration; it does not catch Objective-C
exceptions or bypass native sheet dismissal. Remove the mitigation after the
same focus/AutoFill/dismissal path is verified on a fixed macOS version.

## Verification boundaries

The native field regression inspects the real SwiftUI-backed `NSTextField` and
`NSSecureTextField` content types, transitions first responder, and executes
ordinary parent/sheet begin/end presentation with completion and detach checks.
A control proves that the old semantic registrations reach the native controls.
That synthetic control is not a reproduction of the user's OS-managed AutoFill
session; the original framework exception is established by the captured live
stack. Final normal-app account editing after a safe user-authorized relaunch
remains a distinct runtime check. Never clear credentials, seed a password
manager or change machine security settings to manufacture that reproduction.

The first extended sheet/control run passed both assertions but was correctly
rejected by the runtime-warning gate. Symbolication identified a synchronous
AppKit `NSSpellChecker` / data-detector initialization wait when the synthetic
username immediately resigned focus. Disabling SwiftUI autocorrection alone did
not remove it; that second unsuccessful gate is also retained. A fixture-only attempt to disable prose/data-detection services also did not
produce a clean gate. Both unsuccessful adjustments have been removed. The old
registrations and mitigation now run the same native sheet fixture, values,
focus sequence and normal dismissal in separate fresh processes, to establish
matched warning evidence before any further change. A clean gate remains required.

Matched fresh-process control and mitigation runs each passed their native
assertions but reproduced the same priority-inversion warning. This establishes
that the forced-focus fixture triggers that warning with both old and new
registration behavior. The corrected fixture awaits AppKit's documented native
background text-checking request before presenting the sheet, retaining normal
text services and runtime checking. Both corrected fresh-process runs passed
**1/1**, with zero failures, skips or runtime warnings. The ordinary native
responder transitions, sheet completion and detached-parent assertions execute
in both runs. Unsuccessful production autocorrection and fixture service-disable
adjustments were removed; no warning was waived. Full-suite and affected-account
runtime verification remain distinct gates.
