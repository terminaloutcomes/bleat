import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class TelemetryAuthenticationTests {
    @Test
    func testCachedTokenAvailabilityDoesNotRefresh() async throws {
        let clock = TestClock(Date(timeIntervalSince1970: 2_000_000_000))
        let transport = FakeTelemetryTransport(clock: clock)
        let provider = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: transport,
            store: MemoryEnrollmentStore(),
            dateProvider: clock.now
        )

        let disabledAvailability = await provider.cachedTokenAvailability()
        #expect(disabledAvailability == .disabled)
        let disabledRequestCount = await transport.requestCount
        #expect(disabledRequestCount == 0)

        await provider.setEnabled(true)
        let missingAvailability = await provider.cachedTokenAvailability()
        #expect(missingAvailability == .missing)
        let missingRequestCount = await transport.requestCount
        #expect(missingRequestCount == 0)

        _ = try await provider.currentToken()
        let currentAvailability = await provider.cachedTokenAvailability()
        #expect(currentAvailability == .available)
        let currentRequestCount = await transport.requestCount
        #expect(currentRequestCount == 4)

        clock.advance(by: 481)
        let expiringAvailability = await provider.cachedTokenAvailability()
        #expect(expiringAvailability == .expiring)
        let expiringRequestCount = await transport.requestCount
        #expect(expiringRequestCount == 4)

        clock.advance(by: 120)
        let expiredAvailability = await provider.cachedTokenAvailability()
        #expect(expiredAvailability == .expired)
        let expiredRequestCount = await transport.requestCount
        #expect(expiredRequestCount == 4)
    }

    @Test
    func testCachedTokenAvailabilityPreservesFailureCause() async {
        let unsupported = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(isSupported: false),
            transport: FakeTelemetryTransport(),
            store: MemoryEnrollmentStore()
        )
        await unsupported.setEnabled(true)
        let unsupportedAvailability =
            await unsupported.cachedTokenAvailability()
        #expect(unsupportedAvailability == .failed(.attesterUnavailable))

        let rejected = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: FakeTelemetryTransport(
                enrollmentFailure: .authenticationRejected
            ),
            store: MemoryEnrollmentStore()
        )
        await rejected.setEnabled(true)
        _ = try? await rejected.currentToken()
        let rejectedAvailability = await rejected.cachedTokenAvailability()
        #expect(rejectedAvailability == .failed(.authenticationRejected))

        let invalidConfiguration = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: FakeTelemetryTransport(
                enrollmentFailure: .invalidConfiguration
            ),
            store: MemoryEnrollmentStore()
        )
        await invalidConfiguration.setEnabled(true)
        await assertThrowsTelemetryError(.invalidConfiguration) {
            try await invalidConfiguration.currentToken()
        }
        let invalidConfigurationAvailability =
            await invalidConfiguration.cachedTokenAvailability()
        #expect(
            invalidConfigurationAvailability
                == .failed(.authenticationConfigurationInvalid))

        let invalidResponse = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: FakeTelemetryTransport(
                enrollmentFailure: .malformedResponse
            ),
            store: MemoryEnrollmentStore()
        )
        await invalidResponse.setEnabled(true)
        await assertThrowsTelemetryError(.invalidResponse) {
            try await invalidResponse.currentToken()
        }
        let invalidResponseAvailability =
            await invalidResponse.cachedTokenAvailability()
        #expect(
            invalidResponseAvailability
                == .failed(.authenticationResponseInvalid))

        let rateLimited = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: FakeTelemetryTransport(
                enrollmentFailure: .rateLimited(retryAfterSeconds: nil)
            ),
            store: MemoryEnrollmentStore()
        )
        await rateLimited.setEnabled(true)
        await assertThrowsTelemetryError(.rateLimited(retryAfterSeconds: nil)) {
            try await rateLimited.currentToken()
        }
        let rateLimitedAvailability =
            await rateLimited.cachedTokenAvailability()
        #expect(rateLimitedAvailability == .failed(.rateLimited))

        let unavailableClock = TestClock(
            Date(timeIntervalSince1970: 2_000_000_000)
        )
        let unavailable = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: FakeTelemetryTransport(
                clock: unavailableClock,
                attestationChallengeFailures: 1
            ),
            store: MemoryEnrollmentStore(),
            dateProvider: unavailableClock.now,
            jitterProvider: { 1 }
        )
        await unavailable.setEnabled(true)
        _ = try? await unavailable.currentToken()
        let unavailableAvailability =
            await unavailable.cachedTokenAvailability()
        #expect(unavailableAvailability == .failed(.retryBackoff))
        unavailableClock.advance(by: 1.1)
        let retryableAvailability =
            await unavailable.cachedTokenAvailability()
        #expect(retryableAvailability == .failed(.temporarilyUnavailable))
    }

    @Test
    func testCachedTokenAvailabilityReportsActiveAcquisition() async throws {
        let responseGate = AuthTelemetryTestSignal()
        let transport = FakeTelemetryTransport(tokenResponseGate: responseGate)
        let provider = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: transport,
            store: MemoryEnrollmentStore()
        )
        await provider.setEnabled(true)
        let callerReturned = AuthTelemetryTestCompletion<Bool>()
        let acquisition = Task {
            let result = await telemetryTokenResult(from: provider)
            await callerReturned.complete(true)
            return try result.get()
        }
        try await withTestCleanup {
            acquisition.cancel()
            await provider.setEnabled(false)
            await transport.retireTokenResponse()
        } operation: {
            #expect(
                await requireAuthTelemetrySignal(
                    transport.tokenEntrySignal,
                    stage: "telemetry token transport entry"
                ))

            let availability = await provider.cachedTokenAvailability()
            #expect(availability == .acquiring)

            acquisition.cancel()
            guard
                await requireAuthTelemetryCompletion(
                    callerReturned,
                    stage: "active telemetry acquisition returning") == true
            else {
                acquisition.cancel()
                return
            }
            _ = try? await acquisition.value
        }
    }

    @Test
    func testConsentEnablementIsLazyAndFirstTokenEnrolls() async throws {
        let attester = FakeTelemetryAttester()
        let transport = FakeTelemetryTransport()
        let store = MemoryEnrollmentStore()
        let tracer = AuthenticationTelemetryTracer()
        let provider = TelemetryTokenProvider(
            attester: attester,
            transport: transport,
            store: store,
            tracer: tracer
        )

        await assertThrowsTelemetryError(.disabled) {
            try await provider.currentToken()
        }
        await provider.setEnabled(true)
        let requestsBeforeToken = await transport.requestCount
        #expect(requestsBeforeToken == 0)
        #expect(attester.callCount == 0)

        let token = try await provider.currentToken()
        let requestsAfterToken = await transport.requestCount
        let storedEnrollment = await store.value
        #expect(token == "token-1")
        #expect(requestsAfterToken == 4)
        #expect(attester.generateKeyCount == 1)
        #expect(attester.attestationCount == 1)
        #expect(attester.assertionCount == 1)
        #expect(
            tracer.startedOperations == [
                .telemetryAuthentication,
                .telemetryChallenge,
                .telemetryEnrolment,
                .telemetryChallenge,
                .telemetryToken,
            ])
        #expect(
            tracer.completedOutcomes == Array(repeating: .succeeded, count: 5))
        #expect(
            storedEnrollment
                == TelemetryEnrollment(
                    keyID: "generated-key",
                    installationID: FakeTelemetryTransport.installationID
                ))
    }

    @Test
    func testUnsupportedAttesterPerformsNoWork() async {
        let attester = FakeTelemetryAttester(isSupported: false)
        let transport = FakeTelemetryTransport()
        let provider = TelemetryTokenProvider(
            attester: attester,
            transport: transport,
            store: MemoryEnrollmentStore()
        )
        await provider.setEnabled(true)

        await assertThrowsTelemetryError(.unsupported) {
            try await provider.currentToken()
        }
        let requestCount = await transport.requestCount
        #expect(requestCount == 0)
        #expect(attester.callCount == 0)
    }

    @Test
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
        #expect(firstToken == "token-1")
        #expect(reusedToken == "token-1")
        #expect(firstRequestCount == 2)

        let relaunchedTransport = FakeTelemetryTransport()
        let relaunched = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: relaunchedTransport,
            store: store
        )
        await relaunched.setEnabled(true)
        let relaunchedToken = try await relaunched.currentToken()
        let relaunchedRequestCount = await relaunchedTransport.requestCount
        #expect(relaunchedToken == "token-1")
        #expect(relaunchedRequestCount == 2)
    }

    @Test
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
        #expect(firstToken == "token-1")
        #expect(secondToken == "token-2")
        #expect(tokenChallengeCount == 2)
        #expect(attester.generateKeyCount == 0)
    }

    @Test
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
        #expect(Set(tokens) == ["token-1"])
        #expect(tokenChallengeCount == 1)
        #expect(tokenCount == 1)
        #expect(attester.assertionCount == 1)
    }

    @Test
    func testCancellingOnlyWaiterCancelsUnderlyingRefresh() async throws {
        let responseGate = AuthTelemetryTestSignal()
        let transport = FakeTelemetryTransport(tokenResponseGate: responseGate)
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

        let callerReturned = AuthTelemetryTestCompletion<Bool>()
        let waiter = Task {
            let result = await telemetryTokenResult(from: provider)
            await callerReturned.complete(true)
            return try result.get()
        }
        try await withTestCleanup {
            waiter.cancel()
            await provider.setEnabled(false)
            await transport.retireTokenResponse()
        } operation: {
            #expect(
                await requireAuthTelemetrySignal(
                    transport.tokenEntrySignal,
                    stage: "telemetry token transport entry"
                ))
            waiter.cancel()

            guard
                await requireAuthTelemetryCompletion(
                    callerReturned,
                    stage: "cancelled sole telemetry waiter returning") == true
            else {
                waiter.cancel()
                return
            }
            await assertThrowsTelemetryError(.cancelled) {
                try await waiter.value
            }
            #expect(
                await requireAuthTelemetryCondition(
                    stage:
                        "sole telemetry waiter removed before response retirement"
                ) {
                    await provider.refreshWaiterCountForTesting == 0
                })
            await transport.retireTokenResponse()
            #expect(
                await requireAuthTelemetrySignal(
                    transport.tokenCancellationSignal,
                    stage: "telemetry token transport cancellation"
                ))
            let cancellationCount = await transport.tokenCancellationCount
            #expect(cancellationCount == 1)
        }
    }

    @Test
    func testCancellingOneWaiterPreservesRefreshForConcurrentWaiter()
        async throws
    {
        let responseGate = AuthTelemetryTestSignal()
        let transport = FakeTelemetryTransport(tokenResponseGate: responseGate)
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

        let cancelledResult = AuthTelemetryTestCompletion<
            Result<String, TelemetryTokenProviderError>
        >()
        let survivingResult = AuthTelemetryTestCompletion<
            Result<String, TelemetryTokenProviderError>
        >()
        let cancelledWaiter = Task {
            await cancelledResult.complete(
                await telemetryTokenResult(from: provider))
        }
        let survivingWaiter = Task {
            await survivingResult.complete(
                await telemetryTokenResult(from: provider))
        }
        try await withTestCleanup {
            // Keep bounded cleanup runnable even if the test task is cancelled.
            let cleanup = Task {
                cancelledWaiter.cancel()
                survivingWaiter.cancel()
                await provider.setEnabled(false)
                await transport.retireTokenResponse()
                await cancelledWaiter.value
                await survivingWaiter.value
            }
            await cleanup.value
        } operation: {
            try #require(
                await requireAuthTelemetrySignal(
                    transport.tokenEntrySignal,
                    stage: "telemetry token transport entry"
                ))
            try #require(
                await requireAuthTelemetryCondition(
                    stage: "both telemetry refresh waiters registered"
                ) {
                    await provider.refreshWaiterCountForTesting == 2
                })
            cancelledWaiter.cancel()

            let cancelled = try #require(
                await requireAuthTelemetryCompletion(
                    cancelledResult,
                    stage: "cancelled telemetry waiter completion"
                ))
            try #require(cancelled == .failure(.cancelled))
            try #require(
                await requireAuthTelemetryCondition(
                    stage: "surviving telemetry refresh waiter retained"
                ) {
                    await provider.refreshWaiterCountForTesting == 1
                })
            try Task.checkCancellation()
            await responseGate.signal()

            let surviving = try #require(
                await requireAuthTelemetryCompletion(
                    survivingResult,
                    stage: "surviving telemetry waiter completion"
                ))
            #expect(try surviving.get() == "token-1")
            #expect(await provider.refreshWaiterCountForTesting == 0)
            #expect(await transport.tokenChallengeCount == 1)
            #expect(await transport.tokenCount == 1)
            #expect(await transport.tokenCancellationCount == 0)
        }
    }

    @Test
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
        #expect(token == "token-1")
        #expect(attester.generateKeyCount == 1)
        #expect(deleteCount == 1)
        #expect(replacementKeyID == "generated-key")
    }

    @Test
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

        await assertThrowsTelemetryError(.authenticationRejected) {
            try await provider.currentToken()
        }
        await assertThrowsTelemetryError(.authenticationRejected) {
            try await provider.currentToken()
        }
        let deleteCount = await store.deleteCount
        let tokenChallengeCount = await transport.tokenChallengeCount
        #expect(deleteCount == 0)
        #expect(attester.generateKeyCount == 0)
        #expect(tokenChallengeCount == 1)
    }

    @Test
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
            await assertThrowsTelemetryError(.authenticationRejected) {
                try await provider.currentToken()
            }
        }
        var challengeCount = await transport.attestationChallengeCount
        var enrollmentCount = await transport.enrollmentCount
        #expect(challengeCount == 1)
        #expect(enrollmentCount == 1)
        #expect(attester.generateKeyCount == 1)

        await provider.setEnabled(false)
        await provider.setEnabled(true)
        await assertThrowsTelemetryError(.authenticationRejected) {
            try await provider.currentToken()
        }
        challengeCount = await transport.attestationChallengeCount
        enrollmentCount = await transport.enrollmentCount
        #expect(challengeCount == 2)
        #expect(enrollmentCount == 2)
        #expect(attester.generateKeyCount == 2)
    }

    @Test
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

        #expect(first == "token-1")
        #expect(unchanged == first)
        #expect(refreshed == "token-2")
        #expect(tokenChallengeCount == 2)
    }

    @Test
    func testDisablingCancelsRefreshAndClearsMemoryToken() async throws {
        let responseGate = AuthTelemetryTestSignal()
        let transport = FakeTelemetryTransport(tokenResponseGate: responseGate)
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
        let callerReturned = AuthTelemetryTestCompletion<Bool>()
        let refresh = Task {
            let result = await telemetryTokenResult(from: provider)
            await callerReturned.complete(true)
            return try result.get()
        }
        try await withTestCleanup {
            refresh.cancel()
            await provider.setEnabled(false)
            await transport.retireTokenResponse()
        } operation: {
            #expect(
                await requireAuthTelemetrySignal(
                    transport.tokenChallengeSignal,
                    stage: "telemetry token challenge"
                ))
            await provider.setEnabled(false)

            guard
                await requireAuthTelemetryCompletion(
                    callerReturned,
                    stage: "disabled telemetry refresh returning") == true
            else {
                refresh.cancel()
                return
            }
            do {
                _ = try await refresh.value
                Issue.record("cancelled refresh unexpectedly returned a token")
            } catch let error as TelemetryTokenProviderError {
                #expect(error == .cancelled || error == .disabled)
            }
            await assertThrowsTelemetryError(.disabled) {
                try await provider.currentToken()
            }
        }
    }

    @Test
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

        await assertThrowsTelemetryError(.temporarilyUnavailable) {
            try await provider.currentToken()
        }
        await assertThrowsTelemetryError(.backingOff) {
            try await provider.currentToken()
        }
        let challengeCount = await transport.attestationChallengeCount
        #expect(challengeCount == 1)
        clock.advance(by: 1.1)
        await assertThrowsTelemetryError(.temporarilyUnavailable) {
            try await provider.currentToken()
        }
        clock.advance(by: 1.9)
        await assertThrowsTelemetryError(.backingOff) {
            try await provider.currentToken()
        }
        clock.advance(by: 0.2)
        let token = try? await provider.currentToken()
        #expect(token == "token-1")
    }

    @Test
    func testRateLimitRetryAfterDelaysTheNextChallengeAttempt() async {
        let clock = TestClock(Date(timeIntervalSince1970: 2_000_000_000))
        let transport = FakeTelemetryTransport(
            clock: clock,
            attestationChallengeFailures: 2,
            attestationChallengeFailure: .rateLimited(retryAfterSeconds: 60)
        )
        let provider = TelemetryTokenProvider(
            attester: FakeTelemetryAttester(),
            transport: transport,
            store: MemoryEnrollmentStore(),
            dateProvider: clock.now,
            jitterProvider: { 1 }
        )
        await provider.setEnabled(true)

        await assertThrowsTelemetryError(.rateLimited(retryAfterSeconds: 60)) {
            try await provider.currentToken()
        }
        clock.advance(by: 59.9)
        await assertThrowsTelemetryError(.backingOff) {
            try await provider.currentToken()
        }
        let firstChallengeCount = await transport.attestationChallengeCount
        #expect(firstChallengeCount == 1)
        clock.advance(by: 0.2)
        await assertThrowsTelemetryError(.rateLimited(retryAfterSeconds: 60)) {
            try await provider.currentToken()
        }
        let secondChallengeCount = await transport.attestationChallengeCount
        #expect(secondChallengeCount == 2)
    }

    @Test
    func testErrorsContainNoChallengeKeyOrTokenMaterial() async {
        let values = TelemetryTokenProviderError.allTestValues
            .map(String.init(describing:))
            .joined(separator: "\n")
        for sensitive in ["challenge-value", "generated-key", "token-1"] {
            #expect(!(values.contains(sensitive)))
        }
    }
}

private final class AuthenticationTelemetryTracer: RemoteTelemetryTracing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var starts: [RemoteTelemetryOperation] = []
    private var completions: [RemoteTelemetryOutcome] = []

    var startedOperations: [RemoteTelemetryOperation] {
        lock.withLock { starts }
    }

    var completedOutcomes: [RemoteTelemetryOutcome] {
        lock.withLock { completions }
    }

    func beginSpan(
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket
    ) -> RemoteTelemetrySpan {
        record(operation)
    }

    func beginChildSpan(
        operation: RemoteTelemetryOperation,
        parent: RemoteTelemetrySpan
    ) -> RemoteTelemetrySpan {
        record(operation)
    }

    private func record(
        _ operation: RemoteTelemetryOperation
    ) -> RemoteTelemetrySpan {
        lock.withLock { starts.append(operation) }
        return RemoteTelemetrySpan { [weak self] outcome in
            self?.lock.withLock { self?.completions.append(outcome) }
        }
    }
}

extension TelemetryTokenProviderError {
    fileprivate static let allTestValues: [Self] = [
        .disabled, .unsupported, .backingOff, .cancelled,
        .invalidConfiguration, .invalidResponse, .authenticationRejected,
        .rateLimited(retryAfterSeconds: nil), .temporarilyUnavailable,
    ]
}

private func telemetryTokenResult(
    from provider: TelemetryTokenProvider
) async -> Result<String, TelemetryTokenProviderError> {
    do {
        return .success(try await provider.currentToken())
    } catch {
        return .failure(error)
    }
}

private func assertThrowsTelemetryError(
    _ expected: TelemetryTokenProviderError,
    operation: () async throws -> some Any
) async {
    do {
        _ = try await operation()
        Issue.record("operation unexpectedly succeeded")
    } catch let error as TelemetryTokenProviderError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected error type: \(type(of: error))")
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
    func save(_ enrollment: TelemetryEnrollment) async throws {
        value = enrollment
    }
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
    nonisolated let tokenEntrySignal = AuthTelemetryTestSignal()
    nonisolated let tokenChallengeSignal = AuthTelemetryTestSignal()
    nonisolated let tokenCancellationSignal = AuthTelemetryTestSignal()
    private let tokenLifetimes: [TimeInterval]
    private let tokenDelay: Duration?
    private let tokenResponseGate: AuthTelemetryTestSignal?
    private enum TokenResponseState {
        case idle, waiting, finished, retired, retiredFinished
    }
    private var tokenResponseState = TokenResponseState.idle
    private let enrollmentFailure: TelemetryAuthenticationTransportError?
    private let tokenChallengeFailure: TelemetryAuthenticationTransportError?
    private let attestationChallengeFailure:
        TelemetryAuthenticationTransportError
    private var remainingAttestationChallengeFailures: Int
    private(set) var attestationChallengeCount = 0
    private(set) var enrollmentCount = 0
    private(set) var tokenChallengeCount = 0
    private(set) var tokenCount = 0
    private(set) var tokenCancellationCount = 0

    init(
        clock: TestClock = TestClock(
            Date(timeIntervalSince1970: 2_000_000_000)),
        tokenLifetimes: [TimeInterval] = [600],
        tokenDelay: Duration? = nil,
        tokenResponseGate: AuthTelemetryTestSignal? = nil,
        attestationChallengeFailures: Int = 0,
        attestationChallengeFailure: TelemetryAuthenticationTransportError =
            .temporarilyUnavailable,
        enrollmentFailure: TelemetryAuthenticationTransportError? = nil,
        tokenChallengeFailure: TelemetryAuthenticationTransportError? = nil
    ) {
        self.clock = clock
        self.tokenLifetimes = tokenLifetimes
        self.tokenDelay = tokenDelay
        self.tokenResponseGate = tokenResponseGate
        self.attestationChallengeFailure = attestationChallengeFailure
        self.enrollmentFailure = enrollmentFailure
        self.tokenChallengeFailure = tokenChallengeFailure
        remainingAttestationChallengeFailures = attestationChallengeFailures
    }

    var requestCount: Int {
        attestationChallengeCount + enrollmentCount
            + tokenChallengeCount + tokenCount
    }

    func attestationChallenge()
        async throws(TelemetryAuthenticationTransportError)
        -> TelemetryChallenge
    {
        attestationChallengeCount += 1
        if remainingAttestationChallengeFailures > 0 {
            remainingAttestationChallengeFailures -= 1
            throw attestationChallengeFailure
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
        await tokenChallengeSignal.signal()
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
        if tokenResponseGate != nil {
            switch tokenResponseState {
            case .retired, .retiredFinished:
                throw .cancelled
            case .idle, .waiting, .finished:
                tokenResponseState = .waiting
            }
        }
        defer {
            if tokenResponseGate != nil {
                tokenResponseState =
                    tokenResponseState == .retired
                    ? .retiredFinished : .finished
            }
        }
        tokenCount += 1
        await tokenEntrySignal.signal()
        if let tokenResponseGate {
            switch await tokenResponseGate.wait() {
            case .signalled:
                break
            case .timedOut(let elapsed):
                Issue.record(
                    "Timed out waiting for telemetry token response release after \(elapsed)."
                )
                throw .temporarilyUnavailable
            }
            if Task.isCancelled {
                tokenCancellationCount += 1
                await tokenCancellationSignal.signal()
                throw .cancelled
            }
        }
        if let tokenDelay {
            do {
                try await Task.sleep(for: tokenDelay)
            } catch {
                tokenCancellationCount += 1
                await tokenCancellationSignal.signal()
                throw .cancelled
            }
        }
        let index = min(tokenCount - 1, tokenLifetimes.count - 1)
        return TelemetryBearerToken(
            value: "token-\(tokenCount)",
            expiresAt: clock.now().addingTimeInterval(tokenLifetimes[index])
        )
    }

    func retireTokenResponse() async {
        let previousState = tokenResponseState
        tokenResponseState = .retired
        await tokenResponseGate?.signal()
        if previousState == .waiting {
            await requireAuthTelemetryCondition(
                stage: "retired telemetry token response exit"
            ) {
                await self.tokenResponseState == .retiredFinished
            }
        }
    }

    private func challenge(value: String) -> TelemetryChallenge {
        TelemetryChallenge(
            id: UUID(),
            value: value,
            expiresAt: clock.now().addingTimeInterval(120)
        )
    }
}
