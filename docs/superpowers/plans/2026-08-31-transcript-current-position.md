# Transcript Current-Position Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a prominent transcript action that navigates to and briefly highlights the segment nearest the exact account/book's active or saved playback position.

**Architecture:** Extend the existing `PlaybackModel` with a read-only typed current-or-saved position query, add a pure typed transcript target resolver beside `ChapterTranscriptionModel`, and keep selection, scrolling, highlighting, and explanatory presentation inside `ChapterTranscriptionView`. The existing unified playback-start coordinator remains unchanged and continues to own playback movement from segment menus.

**Tech Stack:** Swift 6.2, SwiftUI, Observation, XCTest, XCUITest, existing BleatCore transcript cache and playback position store.

---

### Task 1: Resolve the canonical active or saved position

**Files:**
- Modify: `Tests/BleatAppTests/AppModelTests.swift`
- Modify: `App/PlaybackModel.swift`

- [ ] **Step 1: Add failing position-source tests**

Add focused `@MainActor` XCTest cases that construct `PlaybackModel` with an isolated `PlaybackPositionStore`, save an account/item position, and assert a new `transcriptNavigationPosition(accountID:itemID:)` query returns `.saved(value)` before playback is prepared. Prepare playback for the exact account/item and assert `.active(currentTime)` takes precedence. Repeat with a different account and a different item to prove active playback never crosses identity boundaries, and assert `nil` when neither source exists.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```sh
xcodebuild test -project Bleat.xcodeproj -scheme Bleat \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO -maximum-parallel-testing-workers 1 \
  -only-testing:BleatAppTests/AppModelTests/testTranscriptNavigationPosition
```

Write an `.xcresult` bundle and inspect it with `xcresulttool`. Expected: the exact new tests execute and fail because `PlaybackTranscriptNavigationPosition` and the query do not exist.

- [ ] **Step 3: Implement the minimal typed query**

In `App/PlaybackModel.swift`, add:

```swift
enum PlaybackTranscriptNavigationPosition: Equatable, Sendable {
    case active(Double)
    case saved(Double)
}
```

Add an account/item-scoped method that returns `.active(currentTime)` only when `isPrepared(accountID:itemID:)` is true, otherwise returns `.saved` from the model's existing private `positionStore`, or `nil`. Do not start, seek, pause, resume, or mutate playback.

- [ ] **Step 4: Run the focused tests and verify GREEN**

Repeat the focused `xcodebuild` invocation with a fresh `.xcresult`. Confirm the expected test identifiers executed and passed with no warnings or skips.

- [ ] **Step 5: Commit the position-source slice**

```sh
git add App/PlaybackModel.swift Tests/BleatAppTests/AppModelTests.swift
git commit -m "feat: expose transcript navigation position"
```

### Task 2: Resolve a typed transcript navigation target

**Files:**
- Modify: `Tests/BleatAppTests/AppModelTests.swift`
- Modify: `App/ChapterTranscriptionView.swift`

- [ ] **Step 1: Add failing resolver tests**

Add tests for a pure `ChapterTranscriptPositionResolver.resolve(position:chapters:transcripts:)` API covering these exact outcomes:

```swift
enum ChapterTranscriptPositionResolution: Equatable, Sendable {
    case target(ChapterTranscriptNavigationTarget)
    case invalidPosition
    case chapterNotTranscribed(chapterID: Int)
    case noSpeechDetected(chapterID: Int)
}
```

The fixtures must prove finite/nonnegative/range validation, containment by canonical `PlaybackChapter` ranges, no jump when the containing chapter is untranscribed, no-speech handling for an empty cached transcript, global nearest-segment selection across a chapter boundary, inside-segment zero distance, and deterministic earlier-segment tie-breaking. Include transcripts for a second account/book only through a separate model book key and prove the model entry point resolves only the requested key's cached transcripts.

- [ ] **Step 2: Run the resolver tests and verify RED**

Run the exact new test identifiers through the Bleat Xcode scheme with a fresh `.xcresult`. Expected: execution fails because the typed resolver is missing.

- [ ] **Step 3: Implement the minimal pure resolver**

In `App/ChapterTranscriptionView.swift`, add a stable target containing `chapterID`, `segmentIndex`, `startMilliseconds`, and `endMilliseconds`. Validate the position and chapter ranges structurally, require the containing chapter's cached transcript, and compute distance to each segment's closed range in integer milliseconds. Sort candidates by distance, chapter start/ID, segment start/end, and segment index. Add a `ChapterTranscriptionModel` method that passes only `cachedTranscriptsByBook[bookKey]` to the resolver.

- [ ] **Step 4: Run resolver tests and verify GREEN**

Repeat the focused Xcode test with `.xcresult` inspection. Confirm every requested resolver test executed and passed.

- [ ] **Step 5: Commit the resolver slice**

```sh
git add App/ChapterTranscriptionView.swift Tests/BleatAppTests/AppModelTests.swift
git commit -m "feat: resolve transcript navigation targets"
```

### Task 3: Add scrolling, highlighting, and typed explanations

**Files:**
- Modify: `App/ChapterTranscriptionView.swift`
- Modify: `App/UITestAppService.swift`
- Modify: `Tests/BleatUITests/BleatUITests.swift`

- [ ] **Step 1: Add failing UI coverage**

Extend the existing transcription-cache UI scenario with a deterministic saved position in chapter 1. Add a UI test that opens Transcription, finds `transcription.goToCurrentPosition` as the first action, taps it, and verifies the target segment becomes visible with accessibility identifier `transcription.currentPositionHighlight`. Add a second launch argument that places the saved position in an untranscribed chapter and verify `transcription.currentPositionMessage` explains that chapter has not been transcribed while no unrelated segment receives the highlight identifier.

- [ ] **Step 2: Run the focused UI tests and verify RED**

Run the two exact UI test identifiers through `xcodebuild test` with a fresh `.xcresult`. Confirm both execute and fail because the action and presentation do not exist.

- [ ] **Step 3: Implement the SwiftUI interaction**

Wrap the transcription list in `ScrollViewReader`. Insert a first `Section` containing a prominent button with accessibility identifier `transcription.goToCurrentPosition`. On activation:

1. query `appModel.playback.transcriptNavigationPosition` for the exact account/item;
2. pass its time to the model resolver;
3. for a target, clear search, select the chapter, store the target as highlighted, yield once for rendering, and animate `scrollTo(target.id, anchor: .center)`;
4. for a typed non-target outcome, store the matching explanatory presentation state;
5. clear the highlight after two seconds only if the same target is still highlighted.

Give every rendered transcript row its target-derived `.id`. Apply a visible accent background and the highlight accessibility identifier only to the current target. Keep existing playback failure and segment menu behavior unchanged.

- [ ] **Step 4: Run the focused UI tests and verify GREEN**

Repeat the two focused UI tests with `.xcresult` inspection. Confirm both exact identifiers passed and no unexpected skip, crash, warning, or hang occurred.

- [ ] **Step 5: Run focused app tests after UI integration**

Run all new `AppModelTests` identifiers again to ensure the view integration did not change typed resolver or position-source semantics.

- [ ] **Step 6: Commit the UI slice**

```sh
git add App/ChapterTranscriptionView.swift App/UITestAppService.swift \
  Tests/BleatUITests/BleatUITests.swift
git commit -m "feat: navigate transcript to current position"
```

### Task 4: Align product documentation and traceability

**Files:**
- Modify: `README.md`
- Modify: `docs/audiobookshelf-ios-app-spec.md`
- Modify: `docs/requirements-traceability.md`

- [ ] **Step 1: Update current behavior documentation**

Document the top-of-screen action, exact active-versus-saved account/book behavior, nearest segment selection, brief highlight, and explanatory untranscribed state. Add the focused resolver and UI test identifiers to `APP-TRANSCRIPTION-001` evidence without describing physical-device transcription as newly validated.

- [ ] **Step 2: Check documentation and diff hygiene**

Run:

```sh
git diff --check
rg -n '/Users/|yaleman/.codex' README.md docs App Tests
```

Expected: no whitespace errors and no newly introduced absolute local paths.

- [ ] **Step 3: Commit documentation**

```sh
git add README.md docs/audiobookshelf-ios-app-spec.md \
  docs/requirements-traceability.md
git commit -m "docs: record transcript position navigation"
```

### Task 5: Validate, review, and prepare the pull request

**Files:**
- Review: all changes from `git merge-base HEAD origin/main`

- [ ] **Step 1: Run the complete repository gate**

Run with normal host access:

```sh
./scripts/test-core.sh
```

Verify the script's host tests, Release build, app tests, and UI tests all actually execute. Investigate any warning, skip, hang, or suspicious result rather than relying on exit status.

- [ ] **Step 2: Audit recoverable failures and concurrency boundaries**

Inspect changed and adjacent production paths for `fatalError`, forced casts, force unwraps, `try!`, implicitly unwrapped optionals, string-based error branching, and callback executor assumptions. Confirm no sensitive account/item/transcript values enter diagnostics.

- [ ] **Step 3: Run the requested review-agent cycle**

Delegate a read-only review of the complete merge-base diff using the provided `review-agent` skill. Fix every P0/P1 finding test-first, rerun the relevant focused and complete validation, and ask the reviewer to inspect the refreshed complete diff. Repeat until the reviewer reports no P0/P1 findings. Preserve all P2/P3 findings verbatim for the final handoff.

- [ ] **Step 4: Verify final branch state**

Run `git status --short`, `git diff --check`, inspect `git log origin/main..HEAD`, and inspect the full merge-base diff. Confirm `.build` remains untracked and absent from every commit.

- [ ] **Step 5: Push and create the PR**

Push `yaleman/issue-49-current-position`, create a PR targeting `main` with `Closes #49`, exact validation evidence, and the requested scope. Update the Codex conversation title so it begins with both Issue #49 and the resulting PR number.
