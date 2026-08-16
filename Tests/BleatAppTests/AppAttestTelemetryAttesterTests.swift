import BleatCore
import DeviceCheck
import Foundation
import XCTest

@testable import Bleat

final class AppAttestTelemetryAttesterTests: XCTestCase {
    #if !targetEnvironment(macCatalyst)
        func testAdapterHandlesServiceWorkCompletedAwayFromMainActor() async throws {
            let service = OffMainAppAttestService()
            let attester = AppAttestTelemetryAttester(service: service)

            XCTAssertTrue(attester.isSupported)
            let keyID = try await attester.generateKey()
            let attestation = try await attester.attest(
                keyID: "key-id",
                clientDataHash: Data(repeating: 1, count: 32)
            )
            let assertion = try await attester.assertion(
                keyID: "key-id",
                clientDataHash: Data(repeating: 2, count: 32)
            )
            XCTAssertEqual(keyID, "key-id")
            XCTAssertEqual(
                attestation,
                Data("attestation".utf8)
            )
            XCTAssertEqual(
                assertion,
                Data("assertion".utf8)
            )
            XCTAssertEqual(service.backgroundCompletionCount, 3)
        }

        func testInvalidAppAttestKeyMapsToTypedReenrollmentFailure() async {
            let service = FailingAppAttestService(
                error: NSError(
                    domain: DCError.errorDomain,
                    code: DCError.Code.invalidKey.rawValue
                )
            )
            let attester = AppAttestTelemetryAttester(service: service)
            do {
                _ = try await attester.assertion(
                    keyID: "invalid-key",
                    clientDataHash: Data(repeating: 3, count: 32)
                )
                XCTFail("invalid key unexpectedly produced an assertion")
            } catch let error {
                XCTAssertEqual(error, .keyInvalidated)
            }
        }
    #endif

    #if targetEnvironment(macCatalyst)
        func testMacCatalystAlwaysDegradesAsUnsupported() {
            let attester = AppAttestTelemetryAttester(
                service: OffMainAppAttestService()
            )
            XCTAssertFalse(attester.isSupported)
        }
    #endif
}

private final class OffMainAppAttestService:
    AppAttestServicing, @unchecked Sendable
{
    private let lock = NSLock()
    private let queue = DispatchQueue(
        label: "app.bleat.tests.app-attest-callback"
    )
    private let queueKey = DispatchSpecificKey<Bool>()
    private var backgroundCompletions = 0

    let isSupported = true
    var backgroundCompletionCount: Int {
        lock.withLock { backgroundCompletions }
    }

    init() { queue.setSpecific(key: queueKey, value: true) }

    func generateKey() async throws -> String {
        try await result("key-id")
    }

    func attestKey(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        try await result(Data("attestation".utf8))
    }

    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        try await result(Data("assertion".utf8))
    }

    private func result<Value: Sendable>(_ value: Value) async throws -> Value {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if DispatchQueue.getSpecific(key: queueKey) == true {
                    lock.withLock { backgroundCompletions += 1 }
                }
                continuation.resume(returning: value)
            }
        }
    }
}

private final class FailingAppAttestService:
    AppAttestServicing, @unchecked Sendable
{
    let isSupported = true
    private let error: NSError

    init(error: NSError) { self.error = error }

    func generateKey() async throws -> String { throw error }

    func attestKey(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data { throw error }

    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data { throw error }
}
