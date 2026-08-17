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

public protocol TelemetryTokenProviding: Sendable {
    func currentToken() async throws(TelemetryTokenProviderError) -> String
    func invalidateToken(ifCurrent token: String) async
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

public actor TelemetryTokenProvider: TelemetryTokenProviding {
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
    private typealias RefreshResult = Result<
        TelemetryBearerToken,
        TelemetryTokenProviderError
    >

    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private var refreshWaiters:
        [UUID: CheckedContinuation<RefreshResult, Never>] = [:]
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
        refreshID = nil
        let waiters = refreshWaiters.values
        refreshWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: .failure(.disabled))
        }
        token = nil
        transientFailureCount = 0
        nextRetryAt = nil
    }

    public func currentToken() async throws(TelemetryTokenProviderError)
        -> String
    {
        guard !Task.isCancelled else { throw .cancelled }
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
        let waiterID = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                registerRefreshWaiter(
                    id: waiterID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelRefreshWaiter(id: waiterID) }
        }
        switch result {
        case .success(let refreshed):
            return refreshed.value
        case .failure(let failure):
            throw failure
        }
    }

    public func invalidateToken(ifCurrent rejectedToken: String) {
        guard token?.value == rejectedToken else { return }
        token = nil
        transientFailureCount = 0
        nextRetryAt = nil
    }

    private func registerRefreshWaiter(
        id: UUID,
        continuation: CheckedContinuation<RefreshResult, Never>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(returning: .failure(.cancelled))
            return
        }
        refreshWaiters[id] = continuation
        guard refreshTask == nil else { return }

        let id = UUID()
        refreshID = id
        refreshTask = Task { [attester, transport, store] in
            let result: RefreshResult
            do {
                result = .success(
                    try await Self.refresh(
                        attester: attester,
                        transport: transport,
                        store: store
                    )
                )
            } catch {
                result = .failure(Self.map(error))
            }
            self.completeRefresh(id: id, result: result)
        }
    }

    private func cancelRefreshWaiter(id: UUID) {
        guard let waiter = refreshWaiters.removeValue(forKey: id) else {
            return
        }
        waiter.resume(returning: .failure(.cancelled))
        guard refreshWaiters.isEmpty else { return }
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
    }

    private func completeRefresh(id: UUID, result: RefreshResult) {
        guard refreshID == id else { return }
        refreshTask = nil
        refreshID = nil

        let completed: RefreshResult
        if !enabled {
            completed = .failure(.disabled)
        } else {
            completed = result
            switch result {
            case .success(let refreshed):
                token = refreshed
                transientFailureCount = 0
                nextRetryAt = nil
            case .failure(let failure):
                recordBackoffIfNeeded(for: failure)
            }
        }
        let waiters = refreshWaiters.values
        refreshWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: completed)
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
