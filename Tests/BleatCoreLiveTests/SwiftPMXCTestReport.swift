import Foundation
import XCTest

/// Base class for XCTest cases whose runner outcomes must be retained by SwiftPM.
/// SwiftPM's parallel XCTest reporter currently omits thrown XCTSkip outcomes.
class SwiftPMObservedLiveTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = SwiftPMXCTestObservation.installation
    }
}

private enum SwiftPMXCTestObservation {
    static let installation: Void = {
        guard
            ProcessInfo.processInfo.environment["BLEAT_XCTEST_OBSERVATION_PATH"]
                != nil
        else {
            return
        }
        XCTestObservationCenter.shared.addTestObserver(
            SwiftPMXCTestResultObserver.shared)
    }()
}

// XCTest callbacks can arrive outside an actor context; the lock protects the shared run records.
private final class SwiftPMXCTestResultObserver: NSObject, XCTestObservation,
    @unchecked Sendable
{
    static let shared = SwiftPMXCTestResultObserver()

    private let lock = NSLock()
    private var records: [SwiftPMXCTestResultRecord] = []

    func testCaseDidFinish(_ testCase: XCTestCase) {
        guard let testRun = testCase.testRun as? XCTestCaseRun else { return }
        let testName = testCase.name
        let methodName: String
        if testName.hasPrefix("-["), testName.hasSuffix("]"),
            let separator = testName.lastIndex(of: " ")
        {
            methodName = String(
                testName[
                    testName.index(
                        after: separator)..<testName.index(
                            before: testName.endIndex)])
        } else {
            methodName = testName
        }
        let outcome: SwiftPMXCTestResultRecord.Outcome
        if testRun.totalFailureCount > 0 {
            outcome = .failed
        } else if testRun.hasBeenSkipped {
            outcome = .skipped
        } else if testRun.hasSucceeded {
            outcome = .passed
        } else {
            outcome = .failed
        }
        let record = SwiftPMXCTestResultRecord(
            identity: "\(String(reflecting: type(of: testCase)))/\(methodName)",
            outcome: outcome
        )
        lock.lock()
        records.append(record)
        lock.unlock()
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        guard
            let prefix = ProcessInfo.processInfo.environment[
                "BLEAT_XCTEST_OBSERVATION_PATH"]
        else {
            return
        }
        lock.lock()
        let snapshot = records
        lock.unlock()
        let processID = ProcessInfo.processInfo.processIdentifier
        let destination = URL(fileURLWithPath: "\(prefix).\(processID).json")
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: destination, options: .atomic)
        } catch {
            fputs(
                "SwiftPM XCTest observer could not write its structured results.\n",
                stderr)
        }
    }
}

private struct SwiftPMXCTestResultRecord: Encodable {
    enum Outcome: String, Encodable {
        case passed
        case skipped
        case failed
    }

    let identity: String
    let outcome: Outcome
}
