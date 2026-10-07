import Foundation
import XCTest

actor AsyncGate {
    private(set) var entryExpectation = XCTestExpectation(
        description: "async gate entered")
    var hasEntered: Bool { entered }
    private var entered = false
    private var released = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        if !entered { entryExpectation.fulfill() }
        entered = true
        let continuations = enteredContinuations
        enteredContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }

        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func waitUntilEntered(timeout: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !entered, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
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
