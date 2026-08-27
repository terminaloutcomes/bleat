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

/// The current in-memory availability of the exporter credential.
///
/// This deliberately reports only whether `currentToken()` could use the
/// cached token immediately. It never starts enrollment or token renewal.
public enum TelemetryTokenAvailability: Equatable, Sendable {
    case available
    case missingOrExpired
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
    private let tracer: any RemoteTelemetryTracing
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
    private var terminalFailure: TelemetryTokenProviderError?

    public init(
        attester: any TelemetryAttester,
        transport: any TelemetryAuthenticationTransport,
        store: any TelemetryEnrollmentStoring,
        tracer: any RemoteTelemetryTracing = InactiveRemoteTelemetryTracer(),
        refreshWindow: TimeInterval = 120,
        dateProvider: @escaping DateProvider = Date.init,
        jitterProvider: @escaping JitterProvider = {
            Double.random(in: 0.75...1.25)
        }
    ) {
        self.attester = attester
        self.transport = transport
        self.store = store
        self.tracer = tracer
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
        terminalFailure = nil
    }

    public func currentToken() async throws(TelemetryTokenProviderError)
        -> String
    {
        guard !Task.isCancelled else { throw .cancelled }
        guard enabled else { throw .disabled }
        guard attester.isSupported else { throw .unsupported }
        if let terminalFailure { throw terminalFailure }
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

    /// Reports whether the exporter can use its in-memory token immediately.
    ///
    /// The refresh-window comparison intentionally matches `currentToken()`:
    /// tokens inside that window are renewed before export and therefore are
    /// not reported as currently available.
    public func cachedTokenAvailability() -> TelemetryTokenAvailability {
        guard enabled,
            attester.isSupported,
            terminalFailure == nil,
            let token,
            token.expiresAt.timeIntervalSince(dateProvider()) > refreshWindow
        else {
            return .missingOrExpired
        }
        return .available
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
        refreshTask = Task { [attester, transport, store, tracer] in
            let span = tracer.beginSpan(
                operation: .telemetryAuthentication
            )
            let result: RefreshResult = await RemoteTelemetrySpan.$current
                .withValue(span) {
                    do {
                        return .success(
                            try await Self.refresh(
                                attester: attester,
                                transport: transport,
                                store: store,
                                tracer: tracer,
                                parentSpan: span
                            )
                        )
                    } catch {
                        return .failure(Self.map(error))
                    }
                }
            span.end(Self.telemetryOutcome(for: result))
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
                terminalFailure = nil
            case .failure(let failure):
                recordFailure(failure)
            }
        }
        let waiters = refreshWaiters.values
        refreshWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: completed)
        }
    }

    private func recordFailure(_ failure: TelemetryTokenProviderError) {
        if failure == .authenticationRejected {
            terminalFailure = failure
            return
        }
        guard failure == .temporarilyUnavailable else { return }
        transientFailureCount = min(transientFailureCount + 1, 6)
        let base = min(pow(2, Double(transientFailureCount - 1)), 32)
        let jitter = min(max(jitterProvider(), 0.5), 1.5)
        nextRetryAt = dateProvider().addingTimeInterval(base * jitter)
    }

    private static func refresh(
        attester: any TelemetryAttester,
        transport: any TelemetryAuthenticationTransport,
        store: any TelemetryEnrollmentStoring,
        tracer: any RemoteTelemetryTracing,
        parentSpan: RemoteTelemetrySpan
    ) async throws -> TelemetryBearerToken {
        var enrollment: TelemetryEnrollment
        do {
            if let stored = try await store.enrollment() {
                enrollment = stored
            } else {
                enrollment = try await enroll(
                    attester: attester,
                    transport: transport,
                    store: store,
                    tracer: tracer,
                    parentSpan: parentSpan
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
                    store: store,
                    tracer: tracer,
                    parentSpan: parentSpan
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
                transport: transport,
                tracer: tracer,
                parentSpan: parentSpan
            )
        } catch let error
            where error as? TelemetryAttesterError == .keyInvalidated
        {
            do {
                try await store.delete()
                let replacement = try await enroll(
                    attester: attester,
                    transport: transport,
                    store: store,
                    tracer: tracer,
                    parentSpan: parentSpan
                )
                return try await issueToken(
                    enrollment: replacement,
                    attester: attester,
                    transport: transport,
                    tracer: tracer,
                    parentSpan: parentSpan
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
        store: any TelemetryEnrollmentStoring,
        tracer: any RemoteTelemetryTracing,
        parentSpan: RemoteTelemetrySpan
    ) async throws -> TelemetryEnrollment {
        guard attester.isSupported else {
            throw TelemetryTokenProviderError.unsupported
        }
        let keyID = try await attester.generateKey()
        let pending = TelemetryEnrollment(keyID: keyID, installationID: nil)
        try await store.save(pending)
        let challenge = try await tracedRequest(
            operation: .telemetryChallenge,
            tracer: tracer,
            parentSpan: parentSpan
        ) {
            try await transport.attestationChallenge()
        }
        let hash = TelemetryClientData.hash(
            purpose: .attestationEnroll,
            challenge: challenge,
            installationID: nil
        )
        let attestation = try await attester.attest(
            keyID: keyID,
            clientDataHash: hash
        )
        let installationID = try await tracedRequest(
            operation: .telemetryEnrolment,
            tracer: tracer,
            parentSpan: parentSpan
        ) {
            try await transport.enroll(
                challenge: challenge,
                keyID: keyID,
                attestationObject: attestation
            )
        }
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
        transport: any TelemetryAuthenticationTransport,
        tracer: any RemoteTelemetryTracing,
        parentSpan: RemoteTelemetrySpan
    ) async throws -> TelemetryBearerToken {
        guard let installationID = enrollment.installationID else {
            throw TelemetryTokenProviderError.authenticationRejected
        }
        let challenge = try await tracedRequest(
            operation: .telemetryChallenge,
            tracer: tracer,
            parentSpan: parentSpan
        ) {
            try await transport.tokenChallenge(
                installationID: installationID
            )
        }
        let hash = TelemetryClientData.hash(
            purpose: .tokenIssue,
            challenge: challenge,
            installationID: installationID
        )
        let assertion = try await attester.assertion(
            keyID: enrollment.keyID,
            clientDataHash: hash
        )
        return try await tracedRequest(
            operation: .telemetryToken,
            tracer: tracer,
            parentSpan: parentSpan
        ) {
            try await transport.token(
                installationID: installationID,
                challenge: challenge,
                assertionObject: assertion
            )
        }
    }

    private static func tracedRequest<Value: Sendable>(
        operation: RemoteTelemetryOperation,
        tracer: any RemoteTelemetryTracing,
        parentSpan: RemoteTelemetrySpan,
        request: @Sendable () async throws -> Value
    ) async throws -> Value {
        let span = tracer.beginChildSpan(
            operation: operation,
            parent: parentSpan
        )
        return try await RemoteTelemetrySpan.$current.withValue(span) {
            do {
                let value = try await request()
                span.end(.succeeded)
                return value
            } catch {
                span.end(telemetryOutcome(for: error))
                throw error
            }
        }
    }

    private static func telemetryOutcome(
        for result: RefreshResult
    ) -> RemoteTelemetryOutcome {
        switch result {
        case .success:
            .succeeded
        case .failure(let failure):
            telemetryOutcome(for: failure)
        }
    }

    private static func telemetryOutcome(
        for error: any Error
    ) -> RemoteTelemetryOutcome {
        if error is CancellationError {
            return .cancelled
        }
        if let failure = error as? TelemetryAuthenticationTransportError {
            switch failure {
            case .cancelled:
                return .cancelled
            case .rateLimited:
                return .failed(.rateLimited)
            case .authenticationRejected:
                return .failed(.authentication)
            case .malformedResponse:
                return .failed(.invalidResponse)
            case .invalidConfiguration:
                return .failed(.unknown)
            case .temporarilyUnavailable:
                return .failed(.transport)
            }
        }
        if let failure = error as? TelemetryTokenProviderError {
            switch failure {
            case .cancelled, .disabled:
                return .cancelled
            case .authenticationRejected:
                return .failed(.authentication)
            case .unsupported:
                return .failed(.unsupported)
            case .backingOff, .temporarilyUnavailable:
                return .failed(.transport)
            }
        }
        if let failure = error as? TelemetryAttesterError {
            switch failure {
            case .unsupported:
                return .failed(.unsupported)
            case .keyInvalidated, .rejected:
                return .failed(.authentication)
            case .temporarilyUnavailable:
                return .failed(.transport)
            }
        }
        return .failed(.unknown)
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
