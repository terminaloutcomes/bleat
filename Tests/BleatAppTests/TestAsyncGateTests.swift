import Foundation
import XCTest

@MainActor
final class TestAsyncGateTests: XCTestCase {
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
        func testPipelineEntryBeforeWaitingAndRepeatedRelease() async {
            let gate = OneShotPipelineBuildGate()
            let entered = expectation(description: "worker reached gate")
            let finished = expectation(description: "worker finished")
            DispatchQueue.global().async {
                entered.fulfill()
                gate.block()
                finished.fulfill()
            }
            await fulfillment(of: [entered], timeout: 30)
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while gate.state == .waiting, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
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
