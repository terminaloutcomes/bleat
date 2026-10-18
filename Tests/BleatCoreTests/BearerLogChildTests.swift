import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct BearerLogChildTests {
    @Test func successfulCaptureDrainsBeyondPipeCapacity() async {
        let streams = streamIdentities()
        let result = await BearerLogChild.run(
            mode: .flood, outputLimit: 3 * 1024 * 1024)
        expectCleanup(result)
        #expect(result.failure == nil)
        #expect(result.privacyFailure == nil)
        #expect(result.capturedByteCount >= 2 * 1024 * 1024)
        #expect(streamIdentities() == streams)
        print("Parent stdout remains usable after successful child")
        FileHandle.standardError.write(
            Data("Parent stderr remains usable\n".utf8))
    }

    @Test func childFailureIsReaped() async {
        let streams = streamIdentities()
        let result = await BearerLogChild.run(mode: .failure)
        expectCleanup(result)
        #expect(result.failure == .childFailed)
        #expect(streamIdentities() == streams)
    }

    @Test func deadlineKillsAndReapsChild() async {
        let streams = streamIdentities()
        // Deliberately short deadline tests termination, not exporter speed.
        let result = await BearerLogChild.run(
            mode: .hang, timeout: .milliseconds(300))
        expectCleanup(result)
        #expect(result.failure == .timeout)
        #expect(streamIdentities() == streams)
    }

    @Test func cancellationKillsAndReapsChild() async {
        let streams = streamIdentities()
        let launched = BoundedTestCounter()
        let task = Task {
            await BearerLogChild.run(mode: .hang, launched: launched)
        }
        let launch = await launched.wait(untilAtLeast: 1, timeout: .seconds(10))
        // Cancel and join even if launch readiness fails.
        task.cancel()
        let result = await task.value
        #expect(launch.reached)
        expectCleanup(result)
        #expect(result.failure == .cancelled)
        #expect(streamIdentities() == streams)
    }

    @Test func successfulExitWithoutCompleteReportFails() async {
        let result = await BearerLogChild.run(mode: .incompleteReport)
        expectCleanup(result)
        #expect(result.failure == .reportRejected(.malformed))
    }

    @Test func overflowFailsWithoutTruncationPass() async {
        let result = await BearerLogChild.run(
            mode: .flood, outputLimit: 32 * 1024)
        expectCleanup(result)
        #expect(result.failure == .outputOverflow)
    }

    @Test func launchFailureClosesHandles() async {
        let result = await BearerLogChild.run(
            executable: URL(fileURLWithPath: "/does-not-exist"))
        #expect(result.failure == .launch)
        #expect(!result.reaped)  // No child was created.
        #expect(result.cleanupFailures.isEmpty)
        #expect(result.readersClosed)
        #expect(result.writersClosed)
        #expect(result.reportRemoved)
    }

    @Test func secretOutputFailsWithPrivateDiagnostics() async {
        let result = await BearerLogChild.run(mode: .leak)
        expectCleanup(result)
        #expect(result.failure == nil)
        let failure = result.privacyFailure
        #expect(failure == .secretInOutput)
        // Retained diagnostics contain only a typed cause, never captured text.
        let diagnostic = String(describing: failure)
        let redacted = !diagnostic.contains(BearerLogChild.secret)
        #expect(redacted)
        print("Parent stdout remains usable after rejected capture")
        FileHandle.standardError.write(
            Data("Parent stderr remains usable\n".utf8))
    }

    @Test func reportRequiresExactlyOneSuccessfulIdentity() {
        let good = report()
        #expect(BearerLogChild.reportFailure(Data(good.utf8)) == nil)
        let invalid = [
            "", "<testsuites/>", String(good.dropLast(3)),
            report(cases: ""), report(cases: testCase() + testCase()),
            report(cases: testCase(name: "other()")),
            report(cases: testCase(suite: "UnexpectedSuite")),
            report(cases: testCase(body: "<skipped/>")),
            report(cases: testCase(body: "<failure/>")),
            report(cases: testCase(body: "<error/>")),
            report(cases: testCase(body: "<unknown/>")),
            report(cases: testCase(extra: " status=\"unknown\"")),
            report(cases: testCase(extra: " result=\"passed\"")),
            report(cases: testCase(time: "nan")),
            good.replacingOccurrences(of: "tests=\"1\"", with: "tests=\"0\""),
            good.replacingOccurrences(
                of: "failures=\"0\"", with: "failures=\"1\""),
            good.replacingOccurrences(of: " errors=\"0\"", with: ""),
        ]
        for xml in invalid {
            let failure = BearerLogChild.reportFailure(Data(xml.utf8))
            #expect(failure != nil)
        }
    }

    private func expectCleanup(
        _ result: BearerLogChild.Result,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(result.reaped, sourceLocation: sourceLocation)
        #expect(result.readersClosed, sourceLocation: sourceLocation)
        #expect(result.writersClosed, sourceLocation: sourceLocation)
        #expect(result.reportRemoved, sourceLocation: sourceLocation)
        #expect(result.cleanupFailures.isEmpty, sourceLocation: sourceLocation)
    }

    private struct StreamIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
    }

    private func streamIdentities() -> [StreamIdentity] {
        [STDOUT_FILENO, STDERR_FILENO].map { descriptor in
            var status = stat()
            let result = fstat(descriptor, &status)
            #expect(result == 0)
            return StreamIdentity(
                device: status.st_dev, inode: status.st_ino,
                mode: status.st_mode)
        }
    }

    private func report(cases: String? = nil) -> String {
        """
        <testsuites><testsuite tests="1" failures="0" errors="0" skipped="0">
        \(cases ?? testCase())
        </testsuite></testsuites>
        """
    }

    private func testCase(
        name: String = BearerLogChild.name,
        suite: String = BearerLogChild.suite,
        time: String = "0.01", body: String = "", extra: String = ""
    ) -> String {
        "<testcase classname=\"\(suite)\" name=\"\(name)\" time=\"\(time)\"\(extra)>\(body)</testcase>"
    }
}
