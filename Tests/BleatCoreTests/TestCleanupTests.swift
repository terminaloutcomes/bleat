import Testing

@Suite(.serialized)
struct TestCleanupTests {
    private enum Failure: Error { case operation, cleanup }

    @Test func awaitsCleanupAfterSuccess() async throws {
        var cleaned = false
        let result = try await withTestCleanup(
            {
                await Task.yield()
                cleaned = true
            }, operation: { 42 })
        #expect(result == 42)
        #expect(cleaned)
    }

    @Test func awaitsCleanupAfterOperationFailure() async {
        var cleaned = false
        await #expect(throws: Failure.operation) {
            try await withTestCleanup(
                {
                    await Task.yield()
                    cleaned = true
                }, operation: { throw Failure.operation })
        }
        #expect(cleaned)
    }

    @Test func propagatesCleanupFailure() async {
        await #expect(throws: Failure.cleanup) {
            try await withTestCleanup(
                { throw Failure.cleanup }, operation: { 42 })
        }
    }

    @Test func retainsOperationFailureWhenCleanupAlsoFails() async {
        let caller = #_sourceLocation
        var observed: Failure?
        await withKnownIssue("Cleanup failure is recorded separately") {
            do {
                try await withTestCleanup(
                    { throw Failure.cleanup },
                    sourceLocation: caller,
                    operation: {
                        throw Failure.operation
                    })
            } catch {
                observed = error as? Failure
            }
        } matching: { issue in
            issue.sourceLocation == caller
                && (issue.error as? Failure) == .cleanup
        }
        #expect(observed == .operation)
    }

    @Test func reportsDefaultCleanupFailureAtTheTestCaller() async {
        let caller = #_sourceLocation
        var observed: Failure?
        await withKnownIssue(
            "Typed cleanup diagnostic uses the calling test file"
        ) {
            do {
                try await withTestCleanup(
                    { throw Failure.cleanup },
                    operation: { throw Failure.operation })
            } catch {
                observed = error as? Failure
            }
        } matching: { issue in
            issue.sourceLocation?.fileID == caller.fileID
                && (issue.error as? Failure) == .cleanup
        }
        #expect(observed == .operation)
    }
}
