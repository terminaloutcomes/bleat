import Foundation
import XCTest

@testable import Bleat

@MainActor
func assertEventually(
    _ description: String,
    timeout: Duration,
    observed: @MainActor () async -> String,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @MainActor () async -> Bool
) async {
    let clock = ContinuousClock()
    let startedAt = clock.now
    let deadline = startedAt.advanced(by: timeout)
    while clock.now < deadline, !Task.isCancelled {
        if await condition() {
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(20))
        } catch {
            break
        }
    }
    if await condition() {
        return
    }
    let elapsed = startedAt.duration(to: clock.now)
    XCTFail(
        "Timed out waiting for \(description) after \(elapsed); "
            + "budget was \(timeout); observed: \(await observed())",
        file: file,
        line: line
    )
}

actor AsyncGate {
    private(set) var entryExpectation = XCTestExpectation(
        description: "async gate entered")
    var hasEntered: Bool { entered }
    private var entered = false
    private var released = false
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        if !entered { entryExpectation.fulfill() }
        entered = true
        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilEntered(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // This is a failure budget, not a delay used to establish completion.
        // The state remains observable for multiple callers after entry.
        let entered = await waitUntilEntered(timeout: .seconds(30))
        XCTAssertTrue(
            entered,
            "Async gate did not enter within 30 seconds (or wait was cancelled)",
            file: file, line: line)
    }

    func waitUntilEntered(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline, !Task.isCancelled {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return false
            }
        }
        return entered
    }

    func release() {
        released = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func reset() {
        entryExpectation = XCTestExpectation(description: "async gate entered")
        entered = false
        released = false
    }
}

#if DEBUG && os(iOS)
    final class OneShotPipelineBuildGate: @unchecked Sendable {
        enum State { case waiting, blocked, released }
        let entryExpectation = XCTestExpectation(
            description: "pipeline build gate entered")
        var state: State {
            lock.withLock {
                didRelease ? .released : (didBlock ? .blocked : .waiting)
            }
        }
        private let lock = NSLock()
        private let continueBuild = DispatchSemaphore(value: 0)

        private var didBlock = false
        private var didRelease = false

        func block() {
            let shouldWait = lock.withLock {
                guard !didBlock else { return false }

                didBlock = true
                entryExpectation.fulfill()
                return !didRelease
            }

            if shouldWait {
                continueBuild.wait()
            }
        }

        func release() {
            let shouldSignal = lock.withLock {
                guard !didRelease else { return false }

                didRelease = true
                return didBlock
            }

            if shouldSignal {
                continueBuild.signal()
            }
        }
    }
#endif

@MainActor
final class AppModelOperationEventProbe {
    private var pending: [(AppModelOperationEvent, XCTestExpectation)] = []
    private(set) var recordedEvents: [AppModelOperationEvent] = []

    func expectation(
        for event: AppModelOperationEvent
    ) -> XCTestExpectation {
        let expectation = XCTestExpectation(
            description: "AppModel operation event: \(event)"
        )
        pending.append((event, expectation))
        return expectation
    }

    func record(_ event: AppModelOperationEvent) {
        recordedEvents.append(event)
        guard let index = pending.firstIndex(where: { $0.0 == event }) else {
            return
        }
        let (_, expectation) = pending.remove(at: index)
        expectation.fulfill()
    }

    func count(of event: AppModelOperationEvent) -> Int {
        recordedEvents.filter { $0 == event }.count
    }
}
