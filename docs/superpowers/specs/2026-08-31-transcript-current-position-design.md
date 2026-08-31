# Transcript Current-Position Navigation Design

## Scope

Implement GitHub issue #49 on the existing chapter-transcription screen. Add a
prominent **Go to current position** action that navigates to the transcript
segment nearest the exact account and book's active or saved whole-book
position. Continuous follow-along remains out of scope.

Issue #57 is complete. This feature must use the playback identity and
whole-book positions already owned by `PlaybackModel`; it must not add another
playback-start or timestamp interpretation path.

## Position source

`PlaybackModel` will expose one read-only account/item-scoped position lookup.
It returns a typed source and whole-book time:

- when its prepared player owns the exact account and item, use
  `PlaybackModel.currentTime` and identify the source as active playback;
- otherwise, use the existing `PlaybackPositionStore` value for the exact
  account and item and identify the source as saved playback;
- when neither is available, return no position.

The lookup keeps the existing position store private and preserves account
identity in every decision. It does not start, seek, pause, or resume playback.

## Transcript target resolution

The transcription model will resolve a typed navigation outcome from a
whole-book position and the account/book-scoped cached transcripts already in
memory.

Resolution first identifies the canonical chapter containing the position
using the book detail's whole-book chapter ranges. Invalid or out-of-duration
positions have no position outcome. If that chapter has no cached transcript,
the outcome identifies the chapter as not transcribed. If its transcript has
no segments, the outcome explains that no speech was detected.

When the relevant chapter has transcript segments, the resolver compares
segments across all cached chapters and selects the segment whose closed time
range is nearest to the position. Distance is zero while the position is inside
a segment, otherwise it is the distance to the nearest segment boundary. Stable
chapter ordering and segment ordering break equal-distance ties. Requiring the
position's own chapter to be transcribed prevents a jump to unrelated text,
while the global nearest comparison permits correct selection across chapter
boundaries.

The target contains the chapter ID and a stable segment identity derived from
the segment's whole-book start, end, and its deterministic index within that
chapter. No transcript text is copied into navigation state or diagnostics.

## User interface

The action appears as the first row of the transcription `List`, including
while search is active. Activating it clears any previous navigation message,
resolves the current-or-saved position, and then:

- selects the target chapter;
- clears transcript search so the chapter transcript is rendered;
- scrolls the target row to the center with `ScrollViewReader`;
- applies a visible accent highlight to the target row for approximately two
  seconds, then removes it without changing selection or playback.

The action never moves playback. Existing transcript-segment actions continue
to use the unified `startPlayback(..., position: .absoluteTime(...))`
coordinator.

Typed explanatory states are shown inline below the action for:

- no active or saved position;
- an invalid/out-of-range stored position;
- a current position in a chapter that has not been transcribed;
- a transcribed chapter where no speech was detected.

The message is replaced on each attempt and does not replace cached transcript
content or existing playback failures.

## Testing

Focused app tests will prove:

- exact active account/book playback takes precedence over a saved position;
- another account or book cannot supply the active position;
- saved account/item position is used when no matching player is prepared;
- no position and invalid positions remain distinct typed outcomes;
- the containing chapter must be transcribed before navigation can succeed;
- the nearest segment is selected across chapter boundaries with deterministic
  tie-breaking;
- a transcribed chapter with no segments returns the no-speech outcome.

UI coverage will verify that the action is prominent, scrolls to and briefly
highlights the expected cached segment, and explains an untranscribed current
position without selecting unrelated transcript text. Documentation and
requirements traceability will record the implemented behavior and evidence.
