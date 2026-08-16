import BleatCore
@preconcurrency import DeviceCheck
import Foundation

protocol AppAttestServicing: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data
}

private final class SystemAppAttestService:
    AppAttestServicing, @unchecked Sendable
{
    private let service = DCAppAttestService.shared

    var isSupported: Bool { service.isSupported }

    func generateKey() async throws -> String {
        try await service.generateKey()
    }

    func attestKey(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        try await service.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(
        _ keyID: String,
        clientDataHash: Data
    ) async throws -> Data {
        try await service.generateAssertion(
            keyID,
            clientDataHash: clientDataHash
        )
    }
}

final class AppAttestTelemetryAttester:
    TelemetryAttester, @unchecked Sendable
{
    private let service: any AppAttestServicing

    init(service: any AppAttestServicing = SystemAppAttestService()) {
        self.service = service
    }

    var isSupported: Bool {
        #if targetEnvironment(macCatalyst)
            false
        #else
            service.isSupported
        #endif
    }

    func generateKey() async throws(TelemetryAttesterError) -> String {
        guard isSupported else { throw .unsupported }
        do {
            return try await service.generateKey()
        } catch {
            throw Self.map(error)
        }
    }

    func attest(
        keyID: String,
        clientDataHash: Data
    ) async throws(TelemetryAttesterError) -> Data {
        guard isSupported else { throw .unsupported }
        do {
            return try await service.attestKey(
                keyID,
                clientDataHash: clientDataHash
            )
        } catch {
            throw Self.map(error)
        }
    }

    func assertion(
        keyID: String,
        clientDataHash: Data
    ) async throws(TelemetryAttesterError) -> Data {
        guard isSupported else { throw .unsupported }
        do {
            return try await service.generateAssertion(
                keyID,
                clientDataHash: clientDataHash
            )
        } catch {
            throw Self.map(error)
        }
    }

    private static func map(_ error: any Error) -> TelemetryAttesterError {
        let error = error as NSError
        guard error.domain == DCError.errorDomain,
            let code = DCError.Code(rawValue: error.code)
        else {
            return .temporarilyUnavailable
        }
        switch code {
        case .featureUnsupported:
            return .unsupported
        case .invalidKey:
            return .keyInvalidated
        case .invalidInput:
            return .rejected
        case .serverUnavailable, .unknownSystemFailure:
            return .temporarilyUnavailable
        @unknown default:
            return .temporarilyUnavailable
        }
    }
}
