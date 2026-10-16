import Foundation
import XCTest

@testable import Bleat

@MainActor
final class TestAsyncGateTests: XCTestCase {
    func testAsyncEntryTimeoutDoesNotPoisonLaterEntry() async {
        let gate = AsyncGate()
        let timedOut = await gate.waitUntilEntered(timeout: .zero)
        XCTAssertFalse(timedOut)
        let task = Task { await gate.enterAndWait() }
        await gate.waitUntilEntered()
        await gate.waitUntilEntered()
        await gate.release()
        await task.value
        let entered = await gate.hasEntered
        XCTAssertTrue(entered)
    }

    func testCancelledEntryWaitReturnsWithoutReleasingGate() async {
        let gate = AsyncGate()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await gate.waitUntilEntered(timeout: .seconds(30))
        }
        let entered = await task.value
        XCTAssertFalse(entered)
        let gateEntered = await gate.hasEntered
        XCTAssertFalse(gateEntered)
        // A cancelled observer must not consume entry or release the operation.
        let operation = Task { await gate.enterAndWait() }
        await gate.waitUntilEntered()
        await gate.release()
        await operation.value
    }

    func testAsyncEntryBeforeWaitingAndRepeatedRelease() async {
        let gate = AsyncGate()
        let finished = expectation(description: "gate released")
        let task = Task {
            await gate.enterAndWait()
            finished.fulfill()
        }
        await gate.waitUntilEntered()
        await fulfillment(of: [await gate.entryExpectation], timeout: 30)
        await gate.release()
        await gate.release()
        await fulfillment(of: [finished], timeout: 30)
        await task.value
    }

    func testAsyncEntryAfterWaiting() async {
        let gate = AsyncGate()
        let entry = await gate.entryExpectation
        let task = Task {
            await gate.enterAndWait()
        }
        await fulfillment(of: [entry], timeout: 30)
        let entered = await gate.hasEntered
        XCTAssertTrue(entered)
        await gate.release()
        await task.value
    }

    func testAsyncEntryBeyondFormerTwoSecondDeadline() async throws {
        let gate = AsyncGate()
        let task = Task {
            try await Task.sleep(for: .seconds(3))
            await gate.enterAndWait()
        }
        await fulfillment(of: [await gate.entryExpectation], timeout: 30)
        let entered = await gate.hasEntered
        XCTAssertTrue(entered)
        await gate.release()
        try await task.value
    }

    #if DEBUG && os(iOS)
        func testContextDownloadGateReleaseAndReuse() async throws {
            let gate = UITestContextDownloadGate()
            for _ in 0..<2 {
                let operation = Task { await gate.wait() }
                addTeardownBlock {
                    operation.cancel()
                    await operation.value
                }
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(30))
                while !gate.isWaiting, clock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(
                    gate.isWaiting,
                    "Preparation did not enter within 30 seconds")
                gate.release()
                gate.release()
                await operation.value
                XCTAssertFalse(gate.isWaiting)
            }
        }

        func testContextDownloadGateCancellationCleansPendingOperation() async {
            let gate = UITestContextDownloadGate()
            let operation = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await gate.wait()
            }
            await operation.value
            XCTAssertFalse(gate.isWaiting)
            gate.release()
        }

        func testPipelineEntryBeforeWaitingAndRepeatedRelease() async {
            let gate = OneShotPipelineBuildGate()
            let finished = expectation(description: "worker finished")
            DispatchQueue.global().async {
                gate.block()
                finished.fulfill()
            }
            await fulfillment(of: [gate.entryExpectation], timeout: 30)
            XCTAssertEqual(gate.state, .blocked)
            gate.release()
            gate.release()
            await fulfillment(of: [finished], timeout: 30)
            gate.block()
            XCTAssertEqual(gate.state, .released)
        }

        func testPipelineEntryAfterWaitingAndReleaseBeforeEntry() async {
            let gate = OneShotPipelineBuildGate()
            let finished = expectation(description: "worker finished")
            gate.release()
            gate.release()
            DispatchQueue.global().async {
                gate.block()
                finished.fulfill()
            }
            await fulfillment(
                of: [gate.entryExpectation, finished], timeout: 30)
            XCTAssertEqual(gate.state, .released)
        }

        func testPipelineEntryBeyondFormerFiveSecondDeadline() async {
            let gate = OneShotPipelineBuildGate()
            let finished = expectation(description: "worker finished")
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                gate.block()
                finished.fulfill()
            }
            await fulfillment(of: [gate.entryExpectation], timeout: 30)
            XCTAssertEqual(gate.state, .blocked)
            gate.release()
            await fulfillment(of: [finished], timeout: 30)
        }
    #endif
}
