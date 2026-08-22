import Foundation
import XCTest

@testable import BleatCore

final class TelemetryAuthenticationTests: XCTestCase {
    func testConsentEnablementIsLazyAndFirstTokenEnrolls() async throws {
        let attester = FakeTelemetryAttester()
        let transport = FakeTelemetryTransport()
        let store = MemoryEnrollmentStore()
        let provider = TelemetryTokenProvider(
            attester: attester,
            transport: transport,
            store: store
        )

        await XCTAssertThrowsTelemetryError(.disabled) {
            try await provider.currentToken()
        }
        await provider.setEnabled(true)
        let requestsBeforeToken = await transport.requestCount
        XCTAssertEqual(requestsBeforeToken, 0)
        XCTAssertEqual(attester.callCount, 0)

        let token = try await provider.currentToken()
        let requestsAfterToken = await transport.requestCount
        let storedEnrollment = await store.value
        XCTAssertEqual(token, "token-1")
        XCTAssertEqual(requestsAfterToken, 4)
        XCTAssertEqual(attester.generateKeyCount, 1)
        XCTAssertEqual(attester.attestationCount, 1)
        XCTAssertEqual(attester.assertionCount, 1)
        XCTAssertEqual(
            storedEnrollment,
            TelemetryEnrollment(
                keyID: "generated-key",
                installationID: FakeTelemetryTransport.installationID
            )
        )
    }

    func testUnsupportedAttesterPerformsNoWork() async {
        let attester = FakeTelemetryAttester(isSupported: false)
        let transport = FakeTelemetryTransport()
        let provider = TelemetryTokenProvider(
            attester: attester,
            transport: transport,
            store: MemoryEnrollmentStore()
        )
        await provider.setEnabled(true)

        await XCTAssertThrowsTelemetryError(.unsupported) {
            try await provider.currentToken()
        }
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(attester.callCount, 0)
    }

    func testStoredEnrollmentSurvivesRelaunchWhileTokensRemainMemoryOnly()
        async throws
    {
        let enrollment = TelemetryEnrollment(
            keyID: "stored-key",
            installationID: FakeTelemetryTransport.installationID
        )
        let store = MemoryEnrollmentStore(value: enrollment)
        let firstTransport = FakeTelemetryTransport()
        let first = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: firstTransport,
            store: store
        )
        await first.setEnabled(true)
        let firstToken = try await first.currentToken()
        let reusedToken = try await first.currentToken()
        let firstRequestCount = await firstTransport.requestCount
        XCTAssertEqual(firstToken, "token-1")
        XCTAssertEqual(reusedToken, "token-1")
        XCTAssertEqual(firstRequestCount, 2)

        let relaunchedTransport = FakeTelemetryTransport()
        let relaunched = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: relaunchedTransport,
            store: store
        )
        await relaunched.setEnabled(true)
        let relaunchedToken = try await relaunched.currentToken()
        let relaunchedRequestCount = await relaunchedTransport.requestCount
        XCTAssertEqual(relaunchedToken, "token-1")
        XCTAssertEqual(relaunchedRequestCount, 2)
    }

    func testTokenWithinRefreshWindowIsRenewedWithoutReenrollment()
        async throws
    {
        let clock = TestClock(Date(timeIntervalSince1970: 2_000_000_000))
        let transport = FakeTelemetryTransport(
            clock: clock,
            tokenLifetimes: [600, 1_200]
        )
        let attester = FakeTelemetryAttester()
        let provider = TelemetryTokenProvider(
            attester: attester,
            transport: transport,
            store: MemoryEnrollmentStore(
                value: TelemetryEnrollment(
                    keyID: "stored-key",
                    installationID: FakeTelemetryTransport.installationID
                )
            ),
            dateProvider: clock.now
        )
        await provider.setEnabled(true)
        let firstToken = try await provider.currentToken()
        clock.advance(by: 481)
        let secondToken = try await provider.currentToken()
        let tokenChallengeCount = await transport.tokenChallengeCount
        XCTAssertEqual(firstToken, "token-1")
        XCTAssertEqual(secondToken, "token-2")
        XCTAssertEqual(tokenChallengeCount, 2)
        XCTAssertEqual(attester.generateKeyCount, 0)
    }

    func testConcurrentRefreshIsSingleFlight() async throws {
        let transport = FakeTelemetryTransport(tokenDelay: .milliseconds(100))
        let attester = FakeTelemetryAttester()
        let provider = TelemetryTokenProvider(
            attester: attester,
            transport: transport,
            store: MemoryEnrollmentStore(
                value: TelemetryEnrollment(
                    keyID: "stored-key",
                    installationID: FakeTelemetryTransport.installationID
                )
            )
        )
        await provider.setEnabled(true)

        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask { try await provider.currentToken() }
            }
            var values: [String] = []
            for try await value in group { values.append(value) }
            return values
        }
        let tokenChallengeCount = await transport.tokenChallengeCount
        let tokenCount = await transport.tokenCount
        XCTAssertEqual(Set(tokens), ["token-1"])
        XCTAssertEqual(tokenChallengeCount, 1)
        XCTAssertEqual(tokenCount, 1)
        XCTAssertEqual(attester.assertionCount, 1)
    }

    func testCancellingOnlyWaiterCancelsUnderlyingRefresh() async {
        let transport = FakeTelemetryTransport(tokenDelay: .seconds(30))
        let provider = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: transport,
            store: MemoryEnrollmentStore(
                value: TelemetryEnrollment(
                    keyID: "stored-key",
                    installationID: FakeTelemetryTransport.installationID
                )
            )
        )
        await provider.setEnabled(true)

        let waiter = Task { try await provider.currentToken() }
        while await transport.tokenCount == 0 {
            await Task.yield()
        }
        waiter.cancel()

        await XCTAssertThrowsTelemetryError(.cancelled) {
            try await waiter.value
        }
        while await transport.tokenCancellationCount == 0 {
            await Task.yield()
        }
        let cancellationCount = await transport.tokenCancellationCount
        XCTAssertEqual(cancellationCount, 1)
    }

    func testCancellingOneWaiterPreservesRefreshForConcurrentWaiter()
        async throws
    {
        let transport = FakeTelemetryTransport(tokenDelay: .milliseconds(100))
        let provider = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: transport,
            store: MemoryEnrollmentStore(
                value: TelemetryEnrollment(
                    keyID: "stored-key",
                    installationID: FakeTelemetryTransport.installationID
                )
            )
        )
        await provider.setEnabled(true)

        let cancelledWaiter = Task { try await provider.currentToken() }
        while await transport.tokenCount == 0 {
            await Task.yield()
        }
        let survivingWaiter = Task { try await provider.currentToken() }
        for _ in 0..<100 {
            await Task.yield()
        }
        cancelledWaiter.cancel()

        await XCTAssertThrowsTelemetryError(.cancelled) {
            try await cancelledWaiter.value
        }
        let token = try await survivingWaiter.value
        let tokenCount = await transport.tokenCount
        let cancellationCount = await transport.tokenCancellationCount
        XCTAssertEqual(token, "token-1")
        XCTAssertEqual(tokenCount, 1)
        XCTAssertEqual(cancellationCount, 0)
    }

    func testInvalidStoredKeyClearsEnrollmentAndRestartsOnce() async throws {
        let attester = FakeTelemetryAttester(invalidateFirstAssertion: true)
        let store = MemoryEnrollmentStore(
            value: TelemetryEnrollment(
                keyID: "invalidated-key",
                installationID: FakeTelemetryTransport.installationID
            )
        )
        let provider = TelemetryTokenProvider(
            attester: attester,
            transport: FakeTelemetryTransport(),
            store: store
        )
        await provider.setEnabled(true)

        let token = try await provider.currentToken()
        let deleteCount = await store.deleteCount
        let replacementKeyID = await store.value?.keyID
        XCTAssertEqual(token, "token-1")
        XCTAssertEqual(attester.generateKeyCount, 1)
        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(replacementKeyID, "generated-key")
    }

    func testServerRejectionDoesNotReplaceDisabledInstallation() async {
        let attester = FakeTelemetryAttester()
        let store = MemoryEnrollmentStore(
            value: TelemetryEnrollment(
                keyID: "stored-key",
                installationID: FakeTelemetryTransport.installationID
            )
        )
        let transport = FakeTelemetryTransport(
            tokenChallengeFailure: .authenticationRejected
        )
        let provider = TelemetryTokenProvider(
            attester: attester,
            transport: transport,
            store: store
        )
        await provider.setEnabled(true)

        await XCTAssertThrowsTelemetryError(.authenticationRejected) {
            try await provider.currentToken()
        }
        await XCTAssertThrowsTelemetryError(.authenticationRejected) {
            try await provider.currentToken()
        }
        let deleteCount = await store.deleteCount
        let tokenChallengeCount = await transport.tokenChallengeCount
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(attester.generateKeyCount, 0)
        XCTAssertEqual(tokenChallengeCount, 1)
    }

    func testEnrollmentRejectionStopsRetriesUntilReenabled() async {
        let attester = FakeTelemetryAttester()
        let transport = FakeTelemetryTransport(
            enrollmentFailure: .authenticationRejected
        )
        let provider = TelemetryTokenProvider(
            attester: attester,
            transport: transport,
            store: MemoryEnrollmentStore()
        )
        await provider.setEnabled(true)

        for _ in 0..<2 {
            await XCTAssertThrowsTelemetryError(.authenticationRejected) {
                try await provider.currentToken()
            }
        }
        var challengeCount = await transport.attestationChallengeCount
        var enrollmentCount = await transport.enrollmentCount
        XCTAssertEqual(challengeCount, 1)
        XCTAssertEqual(enrollmentCount, 1)
        XCTAssertEqual(attester.generateKeyCount, 1)

        await provider.setEnabled(false)
        await provider.setEnabled(true)
        await XCTAssertThrowsTelemetryError(.authenticationRejected) {
            try await provider.currentToken()
        }
        challengeCount = await transport.attestationChallengeCount
        enrollmentCount = await transport.enrollmentCount
        XCTAssertEqual(challengeCount, 2)
        XCTAssertEqual(enrollmentCount, 2)
        XCTAssertEqual(attester.generateKeyCount, 2)
    }

    func testInvalidationOnlyClearsTheTokenThatWasRejected() async throws {
        let transport = FakeTelemetryTransport()
        let provider = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: transport,
            store: MemoryEnrollmentStore(
                value: TelemetryEnrollment(
                    keyID: "stored-key",
                    installationID: FakeTelemetryTransport.installationID
                )
            )
        )
        await provider.setEnabled(true)

        let first = try await provider.currentToken()
        await provider.invalidateToken(ifCurrent: "a-late-rejected-token")
        let unchanged = try await provider.currentToken()
        await provider.invalidateToken(ifCurrent: first)
        let refreshed = try await provider.currentToken()
        let tokenChallengeCount = await transport.tokenChallengeCount

        XCTAssertEqual(first, "token-1")
        XCTAssertEqual(unchanged, first)
        XCTAssertEqual(refreshed, "token-2")
        XCTAssertEqual(tokenChallengeCount, 2)
    }

    func testDisablingCancelsRefreshAndClearsMemoryToken() async throws {
        let transport = FakeTelemetryTransport(tokenDelay: .seconds(5))
        let provider = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: transport,
            store: MemoryEnrollmentStore(
                value: TelemetryEnrollment(
                    keyID: "stored-key",
                    installationID: FakeTelemetryTransport.installationID
                )
            )
        )
        await provider.setEnabled(true)
        let refresh = Task { try await provider.currentToken() }
        while await transport.tokenChallengeCount == 0 {
            await Task.yield()
        }
        await provider.setEnabled(false)

        do {
            _ = try await refresh.value
            XCTFail("cancelled refresh unexpectedly returned a token")
        } catch let error as TelemetryTokenProviderError {
            XCTAssertTrue(error == .cancelled || error == .disabled)
        }
        await XCTAssertThrowsTelemetryError(.disabled) {
            try await provider.currentToken()
        }
    }

    func testTransientFailureAppliesBoundedLazyBackoff() async {
        let clock = TestClock(Date(timeIntervalSince1970: 2_000_000_000))
        let transport = FakeTelemetryTransport(
            clock: clock,
            attestationChallengeFailures: 2
        )
        let provider = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: transport,
            store: MemoryEnrollmentStore(),
            dateProvider: clock.now,
            jitterProvider: { 1 }
        )
        await provider.setEnabled(true)

        await XCTAssertThrowsTelemetryError(.temporarilyUnavailable) {
            try await provider.currentToken()
        }
        await XCTAssertThrowsTelemetryError(.backingOff) {
            try await provider.currentToken()
        }
        let challengeCount = await transport.attestationChallengeCount
        XCTAssertEqual(challengeCount, 1)
        clock.advance(by: 1.1)
        await XCTAssertThrowsTelemetryError(.temporarilyUnavailable) {
            try await provider.currentToken()
        }
        clock.advance(by: 1.9)
        await XCTAssertThrowsTelemetryError(.backingOff) {
            try await provider.currentToken()
        }
        clock.advance(by: 0.2)
        let token = try? await provider.currentToken()
        XCTAssertEqual(token, "token-1")
    }

    func testErrorsContainNoChallengeKeyOrTokenMaterial() async {
        let values = TelemetryTokenProviderError.allTestValues
            .map(String.init(describing:))
            .joined(separator: "\n")
        for sensitive in ["challenge-value", "generated-key", "token-1"] {
            XCTAssertFalse(values.contains(sensitive))
        }
    }
}

private extension TelemetryTokenProviderError {
    static let allTestValues: [Self] = [
        .disabled, .unsupported, .backingOff, .cancelled,
        .authenticationRejected, .temporarilyUnavailable,
    ]
}

private func XCTAssertThrowsTelemetryError(
    _ expected: TelemetryTokenProviderError,
    operation: () async throws -> some Any
) async {
    do {
        _ = try await operation()
        XCTFail("operation unexpectedly succeeded")
    } catch let error as TelemetryTokenProviderError {
        XCTAssertEqual(error, expected)
    } catch {
        XCTFail("unexpected error type: \(type(of: error))")
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value = value.addingTimeInterval(interval) }
    }
}

private final class FakeTelemetryAttester:
    TelemetryAttester, @unchecked Sendable
{
    let isSupported: Bool
    private let lock = NSLock()
    private var counts = (generate: 0, attest: 0, assertion: 0)
    private var shouldInvalidateFirstAssertion: Bool

    init(
        isSupported: Bool = true,
        invalidateFirstAssertion: Bool = false
    ) {
        self.isSupported = isSupported
        shouldInvalidateFirstAssertion = invalidateFirstAssertion
    }

    var generateKeyCount: Int { lock.withLock { counts.generate } }
    var attestationCount: Int { lock.withLock { counts.attest } }
    var assertionCount: Int { lock.withLock { counts.assertion } }
    var callCount: Int {
        lock.withLock { counts.generate + counts.attest + counts.assertion }
    }

    func generateKey() async throws(TelemetryAttesterError) -> String {
        lock.withLock { counts.generate += 1 }
        return "generated-key"
    }

    func attest(
        keyID: String,
        clientDataHash: Data
    ) async throws(TelemetryAttesterError) -> Data {
        lock.withLock { counts.attest += 1 }
        return Data("attestation".utf8)
    }

    func assertion(
        keyID: String,
        clientDataHash: Data
    ) async throws(TelemetryAttesterError) -> Data {
        let invalidate = lock.withLock {
            counts.assertion += 1
            if shouldInvalidateFirstAssertion {
                shouldInvalidateFirstAssertion = false
                return true
            }
            return false
        }
        if invalidate { throw .keyInvalidated }
        return Data("assertion".utf8)
    }
}

private actor MemoryEnrollmentStore: TelemetryEnrollmentStoring {
    private(set) var value: TelemetryEnrollment?
    private(set) var deleteCount = 0

    init(value: TelemetryEnrollment? = nil) { self.value = value }

    func enrollment() async throws -> TelemetryEnrollment? { value }
    func save(_ enrollment: TelemetryEnrollment) async throws { value = enrollment }
    func delete() async throws {
        value = nil
        deleteCount += 1
    }
}

private actor FakeTelemetryTransport: TelemetryAuthenticationTransport {
    static let installationID = UUID(
        uuidString: "6e723e48-ad19-4c18-aabf-f2b79cc375d1"
    )!

    private let clock: TestClock
    private let tokenLifetimes: [TimeInterval]
    private let tokenDelay: Duration?
    private let enrollmentFailure: TelemetryAuthenticationTransportError?
    private let tokenChallengeFailure: TelemetryAuthenticationTransportError?
    private var remainingAttestationChallengeFailures: Int
    private(set) var attestationChallengeCount = 0
    private(set) var enrollmentCount = 0
    private(set) var tokenChallengeCount = 0
    private(set) var tokenCount = 0
    private(set) var tokenCancellationCount = 0

    init(
        clock: TestClock = TestClock(Date(timeIntervalSince1970: 2_000_000_000)),
        tokenLifetimes: [TimeInterval] = [600],
        tokenDelay: Duration? = nil,
        attestationChallengeFailures: Int = 0,
        enrollmentFailure: TelemetryAuthenticationTransportError? = nil,
        tokenChallengeFailure: TelemetryAuthenticationTransportError? = nil
    ) {
        self.clock = clock
        self.tokenLifetimes = tokenLifetimes
        self.tokenDelay = tokenDelay
        self.enrollmentFailure = enrollmentFailure
        self.tokenChallengeFailure = tokenChallengeFailure
        remainingAttestationChallengeFailures = attestationChallengeFailures
    }

    var requestCount: Int {
        attestationChallengeCount + enrollmentCount
            + tokenChallengeCount + tokenCount
    }

    func attestationChallenge() async throws(
        TelemetryAuthenticationTransportError
    ) -> TelemetryChallenge {
        attestationChallengeCount += 1
        if remainingAttestationChallengeFailures > 0 {
            remainingAttestationChallengeFailures -= 1
            throw .temporarilyUnavailable
        }
        return challenge(value: "attestation-challenge")
    }

    func enroll(
        challenge: TelemetryChallenge,
        keyID: String,
        attestationObject: Data
    ) async throws(TelemetryAuthenticationTransportError) -> UUID {
        enrollmentCount += 1
        if let enrollmentFailure { throw enrollmentFailure }
        return Self.installationID
    }

    func tokenChallenge(
        installationID: UUID
    ) async throws(TelemetryAuthenticationTransportError)
        -> TelemetryChallenge
    {
        tokenChallengeCount += 1
        if let tokenChallengeFailure { throw tokenChallengeFailure }
        return challenge(value: "token-challenge")
    }

    func token(
        installationID: UUID,
        challenge: TelemetryChallenge,
        assertionObject: Data
    ) async throws(TelemetryAuthenticationTransportError)
        -> TelemetryBearerToken
    {
        tokenCount += 1
        if let tokenDelay {
            do {
                try await Task.sleep(for: tokenDelay)
            } catch {
                tokenCancellationCount += 1
                throw .cancelled
            }
        }
        let index = min(tokenCount - 1, tokenLifetimes.count - 1)
        return TelemetryBearerToken(
            value: "token-\(tokenCount)",
            expiresAt: clock.now().addingTimeInterval(tokenLifetimes[index])
        )
    }

    private func challenge(value: String) -> TelemetryChallenge {
        TelemetryChallenge(
            id: UUID(),
            value: value,
            expiresAt: clock.now().addingTimeInterval(120)
        )
    }
}
