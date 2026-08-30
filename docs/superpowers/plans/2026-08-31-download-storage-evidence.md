# Download Storage Evidence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add repeatable Release-Simulator evidence for Issue #151's storage preflight, corruption repair, automatic-cache scope, and 300-track responsiveness requirements.

**Architecture:** Exercise the existing real `DownloadStorage`, `DownloadRepairPlanner`, and `DownloadModel` from app-hosted tests, substituting only the existing private `TestAppService`. Add the app-test target to the existing Release performance scheme and a focused runner that verifies exact test execution through `.xcresult`.

**Tech Stack:** Swift 6.2, XCTest, Swift concurrency, XcodeGen, `xcodebuild`, `xcresulttool`, zsh.

---

### Task 1: Add failing Issue #151 app tests

**Files:**
- Modify: `Tests/BleatAppTests/AppModelTests.swift`

- [ ] **Step 1: Add the insufficient-capacity regression test**

Add an async test that gives `DownloadModel` a valid single-track plan with
`expectedByteLength: Int64.max / 2`, invokes `download(detail:account:)`, and
asserts a typed `.insufficientStorage` failure, no persisted records, and no
scheduled transfer descriptors.

```swift
func testDownloadPreflightRejectsInsufficientCapacityBeforeScheduling()
    async throws
{
    let fixture = try issue151Fixture(trackCount: 1)
    defer { fixture.cleanUp() }
    let oversizedPlan = DownloadPlan(
        itemID: fixture.detail.id,
        tracks: [
            DownloadTrackPlan(
                index: 0,
                inode: "oversized",
                expectedByteLength: Int64.max / 2,
                mimeType: "audio/mpeg",
                safeExtension: .mp3,
                destinationEntry: "00000.mp3"
            )
        ]
    )
    let model = DownloadModel(
        service: TestAppService(
            activeAccount: .success(fixture.account),
            downloadPlan: .success(oversizedPlan)
        ),
        storageRootURL: fixture.root
    )

    await model.download(detail: fixture.detail, account: fixture.account)

    guard case .insufficientStorage = model.failure else {
        return XCTFail("Expected typed insufficient storage failure")
    }
    XCTAssertTrue(model.records.isEmpty)
    XCTAssertTrue(
        await model.scheduledTransferDescriptorsForTesting().isEmpty
    )
}
```

- [ ] **Step 2: Add the 300-track relaunch and responsiveness test**

Create 300 one-byte tracks, complete them through `DownloadStorage`, corrupt
track 173, reconstruct storage and `DownloadModel`, and assert:

```swift
XCTAssertEqual(reconciled.manifest.state, .partial)
XCTAssertEqual(repairTracks.map(\.index), [173])
XCTAssertEqual(model.records.first?.manifest.entries.count, 300)
XCTAssertEqual(model.controlSnapshot(for: published).phase, .repairNeeded)
XCTAssertLessThan(planningSeconds, 1.0)
XCTAssertLessThan(reconciliationSeconds, 5.0)
XCTAssertLessThan(publicationSeconds, 5.0)
XCTAssertGreaterThan(heartbeatCount, 0)
```

The same test will mutate the replacement plan's damaged track size and assert
`.repairPlanChanged`. It will create a 300-track automatic-cache record with a
five-track active window, corrupt one active entry, and assert cache-specific
`.cacheFailed` presentation and a one-track repair selection.

- [ ] **Step 3: Run through the Release performance scheme and verify red**

Run:

```sh
xcodebuild -quiet -project Bleat.xcodeproj -scheme BleatPerformance \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath .build/xcode-derived \
  -only-testing:BleatAppTests/AppModelTests/testDownloadPreflightRejectsInsufficientCapacityBeforeScheduling \
  test
```

Expected: fail because `BleatAppTests` is not part of `BleatPerformance`,
proving the Release evidence path does not exist yet.

### Task 2: Wire the focused Release evidence runner

**Files:**
- Modify: `project.yml`
- Regenerate: `Bleat.xcodeproj/project.pbxproj`
- Create: `scripts/test-download-performance.sh`

- [ ] **Step 1: Add `BleatAppTests` to `BleatPerformance`**

```yaml
  BleatPerformance:
    build:
      targets:
        BleatApp: all
        BleatAppTests:
          - test
        BleatUITests:
          - test
    test:
      config: Release
      gatherCoverageData: false
      targets:
        - BleatAppTests
        - BleatUITests
```

- [ ] **Step 2: Regenerate the checked-in project**

Run: `xcodegen generate`

Expected: `Bleat.xcodeproj/project.pbxproj` changes only to include
`BleatAppTests` in the `BleatPerformance` scheme's generated metadata.

- [ ] **Step 3: Add a focused result-verifying script**

Create `scripts/test-download-performance.sh` by following
`scripts/test-performance.sh`, using result bundle
`.build/download-performance.xcresult` and selector:

```sh
-only-testing:BleatAppTests/AppModelTests/testDownloadPreflightRejectsInsufficientCapacityBeforeScheduling \
-only-testing:BleatAppTests/AppModelTests/testThreeHundredTrackDownloadRepairAndPublicationStayResponsive
```

Parse test nodes with `xcresulttool`, require exactly those two test names,
and require both results to equal `Passed`; an empty or partial selection exits
nonzero.

- [ ] **Step 4: Run the focused script**

Run: `./scripts/test-download-performance.sh`

Expected: two named tests execute and pass in Release on the configured iPhone
Simulator, with a `download-perf-summary` containing fixture size, timings,
thresholds, and heartbeat count.

### Task 3: Record evidence and validate

**Files:**
- Modify: `docs/requirements-traceability.md`

- [ ] **Step 1: Record measured Release-Simulator evidence**

Add the two new test identifiers and the observed simulator model, OS,
300-track fixture size, typed outcomes, timings, thresholds, heartbeat count,
command, and `.xcresult` path to `APP-DOWNLOAD-001`. Keep issue #33's physical
background evidence separate.

- [ ] **Step 2: Run focused evidence again after documentation edits**

Run: `./scripts/test-download-performance.sh`

Expected: exactly two tests pass and the new measured values match the
documentation.

- [ ] **Step 3: Run repository validation**

Run: `./scripts/test-core.sh`

Expected: host tests, Release build, app tests, and UI tests all execute with no
failures; inspect the generated `.xcresult` evidence as required by repository
instructions.

- [ ] **Step 4: Check the complete merge diff**

Run:

```sh
git diff --check
git diff "$(git merge-base HEAD origin/main)" --stat
git status --short
```

Expected: no whitespace errors; only Issue #151 files plus the pre-existing
untracked `.build` directory are present.

### Task 4: Independent review and publication

**Files:**
- Review: complete merge diff from `origin/main`

- [ ] **Step 1: Delegate a read-only review-agent pass**

Ask the named review agent to inspect the merge-base diff, relevant call sites,
and tests and return all P0-P3 findings.

- [ ] **Step 2: Fix and re-review P0/P1 findings**

For each related P0/P1, add a failing regression test, implement the minimal
fix, rerun focused and full validation, and request another fresh review. Stop
only when no related P0/P1 remains. Preserve P2/P3 findings for handoff.

- [ ] **Step 3: Commit and push the scoped branch**

```sh
git add project.yml Bleat.xcodeproj/project.pbxproj \
  Tests/BleatAppTests/AppModelTests.swift \
  scripts/test-download-performance.sh \
  docs/requirements-traceability.md \
  docs/superpowers/specs/2026-08-31-download-storage-evidence-design.md \
  docs/superpowers/plans/2026-08-31-download-storage-evidence.md
git commit -m "test: verify download storage resilience at scale"
git push -u origin yaleman/issue-151-download-evidence
```

- [ ] **Step 4: Create the pull request**

Create a non-draft PR targeting `main`, include the exact validation commands
and results, and use `Closes #151` only if every issue criterion is evidenced.
Otherwise use `Refs #151` and state the remaining evidence explicitly.
