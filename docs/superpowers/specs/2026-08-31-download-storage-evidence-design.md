# Download Storage Evidence Design

## Purpose

Close GitHub issue #151 with repeatable Release-Simulator evidence for the
existing download storage, repair, and automatic-cache behavior, plus a
download-specific responsiveness measurement using at least 300 tracks.

The current implementation already has typed insufficient-space failures,
filesystem reconciliation, repair-plan validation, healthy-track preservation,
and automatic-cache window semantics. This work must prove those paths together
without changing production behavior unless a regression test exposes a defect.

## Scope

Add a deterministic 300-track fixture to the app test target. The fixture will
use the real `DownloadStorage`, `DownloadManifest`, `DownloadRepairPlanner`, and
`DownloadModel` boundaries while substituting only the existing external
`AppServicing` boundary.

The evidence will cover:

- insufficient-space preflight rejecting work before a manifest or transfer is
  scheduled;
- relaunch-style storage reconstruction after one finalized file is removed or
  corrupted, producing a Partial download;
- repair preserving healthy finalized tracks, selecting only damaged tracks,
  and rejecting a structurally changed server plan;
- automatic-cache corruption remaining scoped to the persisted active window
  and retaining cache-specific presentation;
- planning, filesystem reconciliation, and observable-state publication for
  300 tracks under concrete elapsed-time bounds while a main-actor heartbeat
  demonstrates that asynchronous reconciliation does not monopolize UI work.

This does not claim the physical-device background-execution behavior tracked
by issue #33. It also does not add a separate service abstraction, alter the
download protocol, or introduce production-only performance instrumentation.

## Test and fixture structure

Keep the focused evidence methods in `AppModelTests.swift`, beside its private
`TestAppService` and download fixture helpers. Moving that private service into
a shared test file would create a large unrelated refactor solely to support
two tests. The new methods will construct 300 one-byte track plans and real
app-owned temporary storage, and will seed finalized and partial files through
the existing storage APIs.

The Release `BleatPerformance` scheme will include `BleatAppTests` as well as
the existing UI performance target. A repository script will run only the new
download evidence tests, write an `.xcresult`, and inspect the result so a
successful command with zero matching tests cannot count as evidence.

Elapsed measurements and heartbeat counts will be attached to the test result
and printed in a stable summary. Thresholds will be deliberately generous
enough for repeatable Simulator execution while still detecting accidental
quadratic work or main-actor serialization.

## Error and state assertions

Assertions will match typed `DownloadStorageError`, `DownloadModelFailure`,
manifest purpose/state, track identity, and scheduled transfer descriptors.
They will not branch on localized descriptions or diagnostic strings.

The insufficient-space case will use a valid plan whose required bytes exceed
the current volume capacity. It must leave no record and no scheduled transfer.
The repair cases will compare structural track identity and on-disk file state,
not serialized JSON bytes.

## Documentation and evidence

After running the Release-Simulator test, record the Simulator model, OS,
fixture size, thresholds, measured values, outcomes, command, and `.xcresult`
location in `docs/requirements-traceability.md`. Update the download evidence
row without converting issue #33's physical-device background criteria into a
verified claim.

## Validation and review

Run the new focused test first and inspect its `.xcresult`, then run the
repository's complete local validation gate when practical. Audit the changed
and adjacent production paths for process-terminating constructs and executor
assumptions if production code changes.

Finally, delegate the merge diff to the requested read-only review agent. Fix
every related P0/P1 finding and repeat review until none remain. Preserve P2/P3
findings for the PR handoff rather than silently broadening scope.
