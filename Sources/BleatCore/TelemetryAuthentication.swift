import CryptoKit
import Foundation

public struct TelemetryChallenge: Equatable, Sendable {
    public let id: UUID
    public let value: String
    public let expiresAt: Date

    public init(id: UUID, value: String, expiresAt: Date) {
        self.id = id
        self.value = value
        self.expiresAt = expiresAt
    }
}

public struct TelemetryEnrollment: Codable, Equatable, Sendable {
    public let keyID: String
    public let installationID: UUID?

    public init(keyID: String, installationID: UUID?) {
        self.keyID = keyID
        self.installationID = installationID
    }
}

public struct TelemetryBearerToken: Equatable, Sendable {
    public let value: String
    public let expiresAt: Date

    public init(value: String, expiresAt: Date) {
        self.value = value
        self.expiresAt = expiresAt
    }
}

public enum TelemetryAttesterError: Error, Equatable, Sendable {
    case unsupported
    case keyInvalidated
    case temporarilyUnavailable
    case rejected
}

public protocol TelemetryAttester: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws(TelemetryAttesterError) -> String
    func attest(
        keyID: String,
        clientDataHash: Data
    ) async throws(TelemetryAttesterError) -> Data
    func assertion(
        keyID: String,
        clientDataHash: Data
    ) async throws(TelemetryAttesterError) -> Data
}

public protocol TelemetryEnrollmentStoring: Sendable {
    func enrollment() async throws -> TelemetryEnrollment?
    func save(_ enrollment: TelemetryEnrollment) async throws
    func delete() async throws
}

public enum TelemetryAuthenticationTransportError:
    Error, Equatable, Sendable
{
    case invalidConfiguration
    case cancelled
    case temporarilyUnavailable
    case rateLimited
    case authenticationRejected
    case malformedResponse
}

public protocol TelemetryAuthenticationTransport: Sendable {
    func attestationChallenge() async throws(
        TelemetryAuthenticationTransportError
    ) -> TelemetryChallenge
    func enroll(
        challenge: TelemetryChallenge,
        keyID: String,
        attestationObject: Data
    ) async throws(TelemetryAuthenticationTransportError) -> UUID
    func tokenChallenge(
        installationID: UUID
    ) async throws(TelemetryAuthenticationTransportError)
        -> TelemetryChallenge
    func token(
        installationID: UUID,
        challenge: TelemetryChallenge,
        assertionObject: Data
    ) async throws(TelemetryAuthenticationTransportError)
        -> TelemetryBearerToken
}

public enum TelemetryTokenProviderError: Error, Equatable, Sendable {
    case disabled
    case unsupported
    case backingOff
    case cancelled
    case authenticationRejected
    case temporarilyUnavailable
}

public enum TelemetryClientDataPurpose: String, Sendable {
    case attestationEnroll = "attestation_enroll"
    case tokenIssue = "token_issue"
}

public enum TelemetryClientData {
    public static func hash(
        purpose: TelemetryClientDataPurpose,
        challenge: TelemetryChallenge,
        installationID: UUID?
    ) -> Data {
        let canonical = [
            "bleat-telemetry-auth/v1",
            purpose.rawValue,
            challenge.id.uuidString.lowercased(),
            challenge.value,
            installationID?.uuidString.lowercased() ?? "",
        ].joined(separator: "\n")
        return Data(SHA256.hash(data: Data(canonical.utf8)))
    }
}

public actor TelemetryTokenProvider {
    public typealias DateProvider = @Sendable () -> Date
    public typealias JitterProvider = @Sendable () -> Double

    private let attester: any TelemetryAttester
    private let transport: any TelemetryAuthenticationTransport
    private let store: any TelemetryEnrollmentStoring
    private let dateProvider: DateProvider
    private let jitterProvider: JitterProvider
    private let refreshWindow: TimeInterval

    private var enabled = false
    private var token: TelemetryBearerToken?
    private var refreshTask: Task<TelemetryBearerToken, Error>?
    private var transientFailureCount = 0
    private var nextRetryAt: Date?

    public init(
        attester: any TelemetryAttester,
        transport: any TelemetryAuthenticationTransport,
        store: any TelemetryEnrollmentStoring,
        refreshWindow: TimeInterval = 120,
        dateProvider: @escaping DateProvider = Date.init,
        jitterProvider: @escaping JitterProvider = {
            Double.random(in: 0.75...1.25)
        }
    ) {
        self.attester = attester
        self.transport = transport
        self.store = store
        self.refreshWindow = refreshWindow
        self.dateProvider = dateProvider
        self.jitterProvider = jitterProvider
    }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        guard !enabled else { return }
        refreshTask?.cancel()
        refreshTask = nil
        token = nil
        transientFailureCount = 0
        nextRetryAt = nil
    }

    public func currentToken() async throws(TelemetryTokenProviderError)
        -> String
    {
        guard enabled else { throw .disabled }
        guard attester.isSupported else { throw .unsupported }
        let now = dateProvider()
        if let token,
            token.expiresAt.timeIntervalSince(now) > refreshWindow
        {
            return token.value
        }
        if let nextRetryAt, nextRetryAt > now {
            throw .backingOff
        }
        if let refreshTask {
            let refreshed = try await value(from: refreshTask)
            guard enabled else { throw .disabled }
            return refreshed.value
        }

        let task = Task { [attester, transport, store] in
            try await Self.refresh(
                attester: attester,
                transport: transport,
                store: store
            )
        }
        refreshTask = task
        do {
            let refreshed = try await value(from: task)
            guard enabled else { throw TelemetryTokenProviderError.disabled }
            token = refreshed
            transientFailureCount = 0
            nextRetryAt = nil
            refreshTask = nil
            return refreshed.value
        } catch let failure as TelemetryTokenProviderError {
            refreshTask = nil
            recordBackoffIfNeeded(for: failure)
            throw failure
        } catch {
            refreshTask = nil
            recordBackoffIfNeeded(for: .temporarilyUnavailable)
            throw .temporarilyUnavailable
        }
    }

    private func value(
        from task: Task<TelemetryBearerToken, Error>
    ) async throws(TelemetryTokenProviderError) -> TelemetryBearerToken {
        do {
            return try await task.value
        } catch is CancellationError {
            throw .cancelled
        } catch let failure as TelemetryTokenProviderError {
            throw failure
        } catch {
            throw .temporarilyUnavailable
        }
    }

    private func recordBackoffIfNeeded(
        for failure: TelemetryTokenProviderError
    ) {
        guard failure == .temporarilyUnavailable else { return }
        transientFailureCount = min(transientFailureCount + 1, 6)
        let base = min(pow(2, Double(transientFailureCount - 1)), 32)
        let jitter = min(max(jitterProvider(), 0.5), 1.5)
        nextRetryAt = dateProvider().addingTimeInterval(base * jitter)
    }

    private static func refresh(
        attester: any TelemetryAttester,
        transport: any TelemetryAuthenticationTransport,
        store: any TelemetryEnrollmentStoring
    ) async throws -> TelemetryBearerToken {
        var enrollment: TelemetryEnrollment
        do {
            if let stored = try await store.enrollment() {
                enrollment = stored
            } else {
                enrollment = try await enroll(
                    attester: attester,
                    transport: transport,
                    store: store
                )
            }
        } catch {
            throw map(error)
        }

        if enrollment.installationID == nil {
            do {
                try await store.delete()
                enrollment = try await enroll(
                    attester: attester,
                    transport: transport,
                    store: store
                )
            } catch {
                throw map(error)
            }
            guard enrollment.installationID != nil else {
                throw TelemetryTokenProviderError.authenticationRejected
            }
        }

        do {
            return try await issueToken(
                enrollment: enrollment,
                attester: attester,
                transport: transport
            )
        } catch let error
            where error as? TelemetryAttesterError == .keyInvalidated
        {
            do {
                try await store.delete()
                let replacement = try await enroll(
                    attester: attester,
                    transport: transport,
                    store: store
                )
                return try await issueToken(
                    enrollment: replacement,
                    attester: attester,
                    transport: transport
                )
            } catch {
                throw map(error)
            }
        } catch {
            throw map(error)
        }
    }

    private static func enroll(
        attester: any TelemetryAttester,
        transport: any TelemetryAuthenticationTransport,
        store: any TelemetryEnrollmentStoring
    ) async throws -> TelemetryEnrollment {
        guard attester.isSupported else {
            throw TelemetryTokenProviderError.unsupported
        }
        let keyID = try await attester.generateKey()
        let pending = TelemetryEnrollment(keyID: keyID, installationID: nil)
        try await store.save(pending)
        let challenge = try await transport.attestationChallenge()
        let hash = TelemetryClientData.hash(
            purpose: .attestationEnroll,
            challenge: challenge,
            installationID: nil
        )
        let attestation = try await attester.attest(
            keyID: keyID,
            clientDataHash: hash
        )
        let installationID = try await transport.enroll(
            challenge: challenge,
            keyID: keyID,
            attestationObject: attestation
        )
        let enrollment = TelemetryEnrollment(
            keyID: keyID,
            installationID: installationID
        )
        try await store.save(enrollment)
        return enrollment
    }

    private static func issueToken(
        enrollment: TelemetryEnrollment,
        attester: any TelemetryAttester,
        transport: any TelemetryAuthenticationTransport
    ) async throws -> TelemetryBearerToken {
        guard let installationID = enrollment.installationID else {
            throw TelemetryTokenProviderError.authenticationRejected
        }
        let challenge = try await transport.tokenChallenge(
            installationID: installationID
        )
        let hash = TelemetryClientData.hash(
            purpose: .tokenIssue,
            challenge: challenge,
            installationID: installationID
        )
        let assertion = try await attester.assertion(
            keyID: enrollment.keyID,
            clientDataHash: hash
        )
        return try await transport.token(
            installationID: installationID,
            challenge: challenge,
            assertionObject: assertion
        )
    }

    private static func map(_ error: any Error) -> TelemetryTokenProviderError {
        if error is CancellationError { return .cancelled }
        if let failure = error as? TelemetryTokenProviderError {
            return failure
        }
        if let failure = error as? TelemetryAttesterError {
            switch failure {
            case .unsupported: return .unsupported
            case .keyInvalidated, .rejected: return .authenticationRejected
            case .temporarilyUnavailable: return .temporarilyUnavailable
            }
        }
        if let failure = error as? TelemetryAuthenticationTransportError {
            switch failure {
            case .cancelled: return .cancelled
            case .authenticationRejected: return .authenticationRejected
            case .invalidConfiguration, .malformedResponse:
                return .authenticationRejected
            case .temporarilyUnavailable, .rateLimited:
                return .temporarilyUnavailable
            }
        }
        return .temporarilyUnavailable
    }
}
