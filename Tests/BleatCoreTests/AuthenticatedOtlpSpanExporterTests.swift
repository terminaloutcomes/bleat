import Darwin
import Foundation
@preconcurrency import OpenTelemetryApi
import Testing

@testable import BleatCore
@testable import OpenTelemetrySdk

@Suite(.serialized)
final class AuthenticatedOtlpSpanExporterTests {
    @Test
    func testConfigurationRequiresHTTPSOriginAndPositiveTimeout() throws {
        #expect(
            throws: Never.self,
            performing: {
                try AuthenticatedOtlpSpanExporterConfiguration(
                    endpoint: #require(
                        URL(string: "https://telemetry.example:4317"))
                )
            })
        for endpoint in [
            "http://telemetry.example:4317",
            "https://user@telemetry.example:4317",
            "https://telemetry.example:4317/v1/traces",
            "https://telemetry.example:4317?token=secret",
            "https://telemetry.example:4317#fragment",
        ] {
            if let error = #expect(
                throws: (any Error).self,
                performing: {
                    try AuthenticatedOtlpSpanExporterConfiguration(
                        endpoint: #require(URL(string: endpoint))
                    )
                })
            {
                #expect(
                    error as? AuthenticatedOtlpSpanExporterConfigurationError
                        == .invalidEndpoint)
            }
        }
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try AuthenticatedOtlpSpanExporterConfiguration(
                    endpoint: #require(
                        URL(string: "https://telemetry.example")),
                    timeout: 0
                )
            })
        {
            #expect(
                error as? AuthenticatedOtlpSpanExporterConfigurationError
                    == .invalidTimeout)
        }
    }

    @Test
    func testEachExportUsesExactlyOneCurrentBearerValue() async {
        let provider = SequenceTokenProvider(tokens: ["first", "second"])
        let client = RecordingOtlpClient(results: [.success, .success])
        let exporter = exporter(provider: provider, client: client)

        let first = await exporter.export(spans: [span()])
        let second = await exporter.export(spans: [span()])
        #expect(first == .success)
        #expect(second == .success)

        #expect(
            client.recordedMetadata.map {
                $0.map { "\($0.0)=\($0.1)" }
            } == [
                ["authorization=Bearer first"],
                ["authorization=Bearer second"],
            ])
        #expect(client.asynchronousExportCount == 2)
        #expect(client.shutdownCount == 0)
    }

    @Test
    func testUnauthenticatedResponseInvalidatesMatchingTokenAndRetriesOnce()
        async
    {
        let provider = SequenceTokenProvider(tokens: ["expired", "renewed"])
        let client = RecordingOtlpClient(
            results: [.unauthenticated, .success]
        )
        let exporter = exporter(provider: provider, client: client)

        let result = await exporter.export(spans: [span()])
        #expect(result == .success)
        #expect(client.exportCount == 2)
        #expect(client.asynchronousExportCount == 2)
        let invalidatedTokens = await provider.invalidatedTokens
        #expect(invalidatedTokens == ["expired"])
        #expect(
            client.recordedMetadata.last?.map { "\($0.0)=\($0.1)" } == [
                "authorization=Bearer renewed"
            ])
    }

    @Test
    func testPersistentAuthenticationRejectionNeverLoops() async {
        let provider = SequenceTokenProvider(tokens: ["one", "two", "three"])
        let client = RecordingOtlpClient(
            results: [.unauthenticated, .unauthenticated, .success]
        )
        let exporter = exporter(provider: provider, client: client)

        let result = await exporter.export(spans: [span()])
        #expect(result == .failure)
        #expect(client.exportCount == 2)
        #expect(client.asynchronousExportCount == 2)
        let requestCount = await provider.requestCount
        let invalidatedTokens = await provider.invalidatedTokens
        #expect(requestCount == 2)
        #expect(invalidatedTokens == ["one", "two"])
    }

    @Test
    func testLogExporterRefreshesOnceAndDisableGatesQueuedRecords() async {
        let provider = SequenceTokenProvider(tokens: ["expired", "renewed"])
        let client = RecordingOtlpLogClient(
            results: [.unauthenticated, .success]
        )
        let exporter = AuthenticatedOtlpLogExporter(
            tokenProvider: provider,
            client: client,
            timeout: 2
        )

        var result = await exporter.export(logRecords: [logRecord()])
        #expect(result == .success)
        #expect(client.exportCount == 2)
        #expect(client.asynchronousExportCount == 2)
        #expect(
            client.recordedMetadata.last?.map { "\($0.0)=\($0.1)" } == [
                "authorization=Bearer renewed"
            ])
        let invalidated = await provider.invalidatedTokens
        #expect(invalidated == ["expired"])

        exporter.disable()
        result = await exporter.export(logRecords: [logRecord()])
        #expect(result == .failure)
        #expect(client.exportCount == 2)
        await exporter.shutdown()
        #expect(client.shutdownCount == 1)
    }

    private enum SuspendedTokenMode: Sendable {
        case cancelBeforeEntry, cancelWhileWaiting, retireBeforeEntry,
            retireWhileWaiting
    }

    @Test(arguments: [
        SuspendedTokenMode.cancelBeforeEntry, .cancelWhileWaiting,
        .retireBeforeEntry, .retireWhileWaiting,
    ])
    private func
        testSuspendedTokenProviderDistinguishesCancellationFromRetirement(
            mode: SuspendedTokenMode
        ) async throws
    {
        let provider = SuspendedTokenProvider()
        let start = AuthTelemetryTestSignal()
        let completed = AuthTelemetryTestCompletion<
            Result<String, TelemetryTokenProviderError>
        >()
        let caller = Task {
            guard case .signalled = await start.wait() else {
                Issue.record("Token fake contract start was not released")
                return
            }
            let result: Result<String, TelemetryTokenProviderError>
            do throws(TelemetryTokenProviderError) {
                result = .success(try await provider.currentToken())
            } catch {
                result = .failure(error)
            }
            await completed.complete(result)
        }
        try await withTestCleanup {
            caller.cancel()
            await start.signal()
            await provider.retire()
        } operation: {
            switch mode {
            case .cancelBeforeEntry:
                caller.cancel()
                await start.signal()
            case .retireBeforeEntry:
                await provider.retire()
                await start.signal()
            case .cancelWhileWaiting, .retireWhileWaiting:
                await start.signal()
                try #require(
                    await requireAuthTelemetrySignal(
                        provider.waitingSignal,
                        stage: "token fake cancellation handler installed"))
                if mode == .cancelWhileWaiting {
                    caller.cancel()
                } else {
                    await provider.retire()
                }
            }
            let result = try #require(
                await requireAuthTelemetryCompletion(
                    completed, stage: "controlled token fake caller returning"))
            #expect(result == .failure(.cancelled))
            await caller.value
            #expect(
                await provider.requestCount
                    == (mode == .retireBeforeEntry ? 0 : 1))
            let expectedCancellation =
                mode == .cancelBeforeEntry || mode == .cancelWhileWaiting
            #expect(
                await provider.cancellationCount
                    == (expectedCancellation ? 1 : 0))
        }
    }

    @Test
    func testCancellingAsyncExportCancelsTokenWaitBeforeRPC() async throws {
        // Bound observation independently of the production timeout. Capturing
        // before export establishes a lower bound on its possible deadline.
        let earliestDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [.success])
        let exporter = exporter(provider: provider, client: client, timeout: 30)
        let span = span()

        let callerReturned = AuthTelemetryTestCompletion<Bool>()
        let exportTask = Task {
            let value = await exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
            await callerReturned.complete(true)
            return value
        }
        try await withTestCleanup {
            exportTask.cancel()
            exporter.cancelActiveExports()
            await provider.retire()
        } operation: {
            #expect(
                await requireAuthTelemetrySignal(
                    provider.requestedSignal,
                    stage: "telemetry token request before span RPC"
                ))
            exportTask.cancel()

            guard
                await requireAuthTelemetryCompletion(
                    callerReturned,
                    stage: "cancelled OTLP export caller returning")
                    == true
            else {
                exportTask.cancel()
                exporter.cancelActiveExports()
                return
            }
            let result = await exportTask.value
            #expect(result == .failure)
            #expect(
                await requireAuthTelemetrySignal(
                    provider.cancelledSignal,
                    stage: "token provider observed actual task cancellation"))
            #expect(await provider.cancellationCount == 1)
            let cancellationObservedAt = try #require(
                await provider.cancellationObservedAt)
            #expect(cancellationObservedAt < earliestDeadline)
            #expect(client.exportCount == 0)
        }
    }

    @Test
    func testCancelActiveExportsCancelsAsyncTokenWaitBeforeRPC() async throws {
        // Bound observation independently of the production timeout. Capturing
        // before export establishes a lower bound on its possible deadline.
        let earliestDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [.success])
        let exporter = exporter(provider: provider, client: client, timeout: 30)
        let span = span()

        let callerReturned = AuthTelemetryTestCompletion<Bool>()
        let exportTask = Task {
            let value = await exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
            await callerReturned.complete(true)
            return value
        }
        try await withTestCleanup {
            exportTask.cancel()
            exporter.cancelActiveExports()
            await provider.retire()
        } operation: {
            #expect(
                await requireAuthTelemetrySignal(
                    provider.requestedSignal,
                    stage: "telemetry token request before span RPC"
                ))
            exporter.cancelActiveExports()

            guard
                await requireAuthTelemetryCompletion(
                    callerReturned,
                    stage: "cancelled OTLP export caller returning")
                    == true
            else {
                exportTask.cancel()
                exporter.cancelActiveExports()
                return
            }
            let result = await exportTask.value
            #expect(result == .failure)
            #expect(
                await requireAuthTelemetrySignal(
                    provider.cancelledSignal,
                    stage: "token provider observed actual task cancellation"))
            #expect(await provider.cancellationCount == 1)
            let cancellationObservedAt = try #require(
                await provider.cancellationObservedAt)
            #expect(cancellationObservedAt < earliestDeadline)
            #expect(client.exportCount == 0)
            #expect(client.cancelCount == 1)
        }
    }

    @Test
    func testAsyncTokenTimeoutDoesNotWaitForCancellationIgnoringProvider()
        async throws
    {
        let provider = CancellationIgnoringTokenProvider()
        let manualClock = ManualOtlpClock()
        let client = RecordingOtlpClient(results: [.success])
        let exporter = AuthenticatedOtlpSpanExporter(
            tokenProvider: provider, client: client, timeout: 2,
            clock: manualClock.clock)
        let span = span()
        let returned = AuthTelemetryTestCompletion<Bool>()
        let exportTask = Task {
            let result = await exporter.export(
                spans: [span], explicitTimeout: 0.05)
            await returned.complete(true)
            return result
        }
        try await withTestCleanup {
            exportTask.cancel()
            exporter.cancelActiveExports()
            await provider.retire()
            await manualClock.retire()
        } operation: {
            try #require(
                await requireAuthTelemetrySignal(
                    provider.waitingSignal,
                    stage: "uncooperative token wait installed"))
            try #require(
                await requireAuthTelemetrySignal(
                    manualClock.registeredSignal,
                    stage: "token deadline sleeper registered"))
            let budget = try #require(
                manualClock.budgets.count == 1 ? manualClock.budgets.first : nil
            )
            let expectedBudget = 0.05
            // Floating-point precision only; this is not a wall-clock tolerance.
            #expect(abs(budget - expectedBudget) <= expectedBudget.ulp * 4)
            #expect(await provider.requestCount == 1)
            #expect(await provider.exitCount == 0)
            manualClock.advance(by: expectedBudget)
            manualClock.fire()
            try #require(
                await requireAuthTelemetryCompletion(
                    returned,
                    stage: "controlled token deadline export caller returning")
                    == true)
            let result = await exportTask.value
            #expect(result == .failure)
            #expect(client.exportCount == 0)
            try #require(
                await requireAuthTelemetrySignal(
                    provider.cancellationSignal,
                    stage: "deadline token cancellation acknowledged"))
            #expect(await provider.exitCount == 0)
            #expect(manualClock.settlements == [.released])
        }
    }

    private enum UncooperativeTokenMode: Sendable {
        case cancelBeforeEntry, cancelWhileWaiting, retireBeforeEntry,
            retireWhileWaiting
    }

    @Test(arguments: [
        UncooperativeTokenMode.cancelBeforeEntry, .cancelWhileWaiting,
        .retireBeforeEntry, .retireWhileWaiting,
    ])
    private func
        testCancellationIgnoringTokenProviderRequiresExplicitRetirement(
            mode: UncooperativeTokenMode
        ) async throws
    {
        let provider = CancellationIgnoringTokenProvider()
        let start = AuthTelemetryTestSignal()
        let returned = AuthTelemetryTestCompletion<
            Result<String, TelemetryTokenProviderError>
        >()
        let caller = Task {
            guard case .signalled = await start.wait() else {
                Issue.record(
                    "Uncooperative token contract start was not released")
                return
            }
            let result: Result<String, TelemetryTokenProviderError>
            do throws(TelemetryTokenProviderError) {
                result = .success(try await provider.currentToken())
            } catch { result = .failure(error) }
            await returned.complete(result)
        }
        try await withTestCleanup {
            caller.cancel()
            await start.signal()
            await provider.retire()
        } operation: {
            switch mode {
            case .cancelBeforeEntry:
                caller.cancel()
                await start.signal()
            case .cancelWhileWaiting:
                await start.signal()
                try #require(
                    await requireAuthTelemetrySignal(
                        provider.waitingSignal,
                        stage: "uncooperative token handler installed"))
                caller.cancel()
            case .retireBeforeEntry:
                await provider.retire()
                await start.signal()
            case .retireWhileWaiting:
                await start.signal()
                try #require(
                    await requireAuthTelemetrySignal(
                        provider.waitingSignal,
                        stage: "uncooperative token handler installed"))
                await provider.retire()
            }
            if mode == .cancelBeforeEntry || mode == .cancelWhileWaiting {
                try #require(
                    await requireAuthTelemetrySignal(
                        provider.cancellationSignal,
                        stage: "uncooperative token cancellation acknowledged"))
                #expect(await provider.exitCount == 0)
                await provider.retire()
            }
            let result = try #require(
                await requireAuthTelemetryCompletion(
                    returned,
                    stage: "retired uncooperative token caller returning"))
            #expect(result == .failure(.cancelled))
            await caller.value
            #expect(
                await provider.requestCount
                    == (mode == .retireBeforeEntry ? 0 : 1))
            #expect(
                await provider.exitCount == (mode == .retireBeforeEntry ? 0 : 1)
            )
        }
    }

    private enum ManualClockMode: Equatable, Sendable {
        case cancelBeforeEntry, cancelWhileSleeping, fireBeforeEntry,
            fireWhileSleeping, retireBeforeEntry, retireWhileSleeping
    }

    private enum ManualClockOutcome: Equatable, Sendable {
        case completed, cancelled, unexpected
    }

    @Test(arguments: [
        ManualClockMode.cancelBeforeEntry, .cancelWhileSleeping,
        .fireBeforeEntry,
        .fireWhileSleeping, .retireBeforeEntry, .retireWhileSleeping,
    ])
    private func testManualOtlpClockSettlesSleepExactlyOnce(
        mode: ManualClockMode
    )
        async throws
    {
        let manualClock = ManualOtlpClock()
        let start = AuthTelemetryTestSignal()
        let returned = AuthTelemetryTestCompletion<ManualClockOutcome>()
        let caller = Task {
            guard case .signalled = await start.wait() else {
                Issue.record("Manual clock contract start was not released")
                return
            }
            let outcome: ManualClockOutcome
            do {
                try await manualClock.clock.sleep(0.05)
                outcome = .completed
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                Issue.record("Manual clock produced an unexpected error type")
                outcome = .unexpected
            }
            await returned.complete(outcome)
        }
        try await withTestCleanup {
            caller.cancel()
            await start.signal()
            await manualClock.retire()
        } operation: {
            switch mode {
            case .cancelBeforeEntry:
                caller.cancel()
                await start.signal()
            case .fireBeforeEntry:
                manualClock.advance(by: 0.05)
                manualClock.fire()
                manualClock.fire()
                await start.signal()
            case .retireBeforeEntry:
                await manualClock.retire()
                await manualClock.retire()
                await start.signal()
            case .cancelWhileSleeping, .fireWhileSleeping, .retireWhileSleeping:
                await start.signal()
                try #require(
                    await requireAuthTelemetrySignal(
                        manualClock.registeredSignal,
                        stage: "manual sleeper registered"))
                #expect(manualClock.pendingCount == 1)
                #expect(manualClock.pendingContinuationCount == 1)
                switch mode {
                case .cancelWhileSleeping: caller.cancel()
                case .fireWhileSleeping:
                    manualClock.advance(by: 0.05)
                    manualClock.fire()
                    manualClock.fire()
                case .retireWhileSleeping:
                    await manualClock.retire()
                    await manualClock.retire()
                default: Issue.record("Unexpected clock contract branch")
                }
            }
            let outcome = try #require(
                await requireAuthTelemetryCompletion(
                    returned, stage: "manual clock sleep caller returning"))
            let fired = mode == .fireBeforeEntry || mode == .fireWhileSleeping
            #expect(outcome == (fired ? .completed : .cancelled))
            await caller.value
            let expectedCount = mode == .retireBeforeEntry ? 0 : 1
            #expect(manualClock.budgets.count == expectedCount)
            #expect(manualClock.finishedCount == expectedCount)
            #expect(manualClock.pendingCount == 0)
            #expect(manualClock.pendingContinuationCount == 0)
            #expect(
                manualClock.resolutionCounts
                    == Array(repeating: 1, count: expectedCount))
            manualClock.fire()
            manualClock.fire()
            await manualClock.retire()
            await manualClock.retire()
            #expect(manualClock.finishedCount == expectedCount)
            #expect(
                manualClock.resolutionCounts
                    == Array(repeating: 1, count: expectedCount))
        }
    }

    @Test
    func testSuccessfulTokenAcquisitionCancelsManualDeadlineSleeper()
        async throws
    {
        let manualClock = ManualOtlpClock()
        let provider = SequenceTokenProvider(tokens: ["controlled"])
        let client = RecordingOtlpClient(results: [.success])
        let exporter = AuthenticatedOtlpSpanExporter(
            tokenProvider: provider, client: client, timeout: 2,
            clock: manualClock.clock)
        let span = span()
        let returned = AuthTelemetryTestCompletion<Bool>()
        let caller = Task {
            let result = await exporter.export(
                spans: [span], explicitTimeout: 0.05)
            await returned.complete(true)
            return result
        }
        try await withTestCleanup {
            caller.cancel()
            exporter.cancelActiveExports()
            await manualClock.retire()
        } operation: {
            try #require(
                await requireAuthTelemetryCompletion(
                    returned,
                    stage: "successful controlled-clock export returning")
                    == true)
            #expect(await caller.value == .success)
            try #require(
                await requireAuthTelemetrySignal(
                    manualClock.registeredSignal,
                    stage: "successful export timer registered"))
            try #require(
                await requireAuthTelemetrySignal(
                    manualClock.finishedSignal,
                    stage: "cancelled success timer exited"))
            #expect(client.exportCount == 1)
            #expect(await provider.requestCount == 1)
            #expect(manualClock.settlements == [.cancelled])
            #expect(manualClock.finishedCount == 1)
            #expect(manualClock.pendingCount == 0)
            #expect(!manualClock.hasFired)
        }
    }

    @Test
    func testExpiredControlledDeadlinePreventsRPC() async throws {
        let manualClock = ManualOtlpClock()
        let provider = SingleFlightTokenProvider(
            token: "controlled", expectedWaiters: 1)
        let client = RecordingOtlpClient(results: [.success])
        let exporter = AuthenticatedOtlpSpanExporter(
            tokenProvider: provider, client: client, timeout: 2,
            clock: manualClock.clock)
        let span = span()
        let returned = AuthTelemetryTestCompletion<Bool>()
        let caller = Task {
            let result = await exporter.export(
                spans: [span], explicitTimeout: 0.05)
            await returned.complete(true)
            return result
        }
        try await withTestCleanup {
            caller.cancel()
            exporter.cancelActiveExports()
            await provider.releaseToken()
            await manualClock.retire()
        } operation: {
            try #require(
                await requireAuthTelemetrySignal(
                    provider.allTokenWaitersArrived,
                    stage: "held token provider entered"))
            try #require(
                await requireAuthTelemetrySignal(
                    manualClock.registeredSignal,
                    stage: "held token deadline registered"))
            manualClock.advance(by: 0.05)
            await provider.releaseToken()
            try #require(
                await requireAuthTelemetryCompletion(
                    returned, stage: "expired RPC budget export returning")
                    == true)
            #expect(await caller.value == .failure)
            #expect(client.exportCount == 0)
            #expect(await provider.refreshCount == 1)
            try #require(
                await requireAuthTelemetrySignal(
                    manualClock.finishedSignal,
                    stage: "expired RPC budget timer exited"))
            #expect(manualClock.settlements == [.cancelled])
            #expect(!manualClock.hasFired)
        }
    }

    @Test
    func testAsyncLifecycleMethodsPreserveShutdownState() async {
        let provider = SequenceTokenProvider(tokens: [])
        let spanClient = RecordingOtlpClient(results: [])
        let spanExporter = exporter(
            provider: provider,
            client: spanClient
        )
        let logClient = RecordingOtlpLogClient(results: [])
        let logExporter = AuthenticatedOtlpLogExporter(
            tokenProvider: provider,
            client: logClient,
            timeout: 2
        )

        let initialReturned = AuthTelemetryTestCompletion<Bool>()
        let initialFlush = Task {
            let spanResult = await spanExporter.flush()
            let logResult = await logExporter.forceFlush()
            await initialReturned.complete(true)
            return (spanResult, logResult)
        }
        guard
            await requireAuthTelemetryCompletion(
                initialReturned,
                stage: "initial span/log flush callers returning") == true
        else {
            initialFlush.cancel()
            spanExporter.cancelActiveExports()
            logExporter.cancelActiveExports()
            return
        }
        var (spanResult, logResult) = await initialFlush.value
        #expect(spanResult == .success)
        #expect(logResult == .success)

        let shutdownReturned = AuthTelemetryTestCompletion<Bool>()
        let shutdown = Task {
            await spanExporter.shutdown()
            await logExporter.shutdown()
            await shutdownReturned.complete(true)
        }
        guard
            await requireAuthTelemetryCompletion(
                shutdownReturned, stage: "span/log shutdown callers returning")
                == true
        else {
            shutdown.cancel()
            spanExporter.cancelActiveExports()
            logExporter.cancelActiveExports()
            return
        }
        await shutdown.value

        let finalReturned = AuthTelemetryTestCompletion<Bool>()
        let finalFlush = Task {
            let spanResult = await spanExporter.flush()
            let logResult = await logExporter.forceFlush()
            await finalReturned.complete(true)
            return (spanResult, logResult)
        }
        guard
            await requireAuthTelemetryCompletion(
                finalReturned,
                stage: "post-shutdown span/log flush callers returning") == true
        else {
            finalFlush.cancel()
            spanExporter.cancelActiveExports()
            logExporter.cancelActiveExports()
            return
        }
        (spanResult, logResult) = await finalFlush.value
        #expect(spanResult == .failure)
        #expect(logResult == .failure)
        #expect(spanClient.shutdownCount == 1)
        #expect(logClient.shutdownCount == 1)
        #expect(spanClient.synchronousShutdownCount == 0)
        #expect(spanClient.asynchronousShutdownCount == 1)
        #expect(logClient.synchronousShutdownCount == 0)
        #expect(logClient.asynchronousShutdownCount == 1)
    }

    @Test
    func testPermissionAndTransportFailuresDoNotRefreshOrBlockCaller() async {
        for result in [
            RemoteTelemetryOtlpExportResult.rejected,
            .failure,
            .cancelled,
        ] {
            let provider = SequenceTokenProvider(tokens: ["private-bearer"])
            let client = RecordingOtlpClient(results: [result])
            let exporter = exporter(provider: provider, client: client)

            let exportResult = await exporter.export(spans: [span()])
            #expect(exportResult == .failure)
            #expect(client.exportCount == 1)
            let invalidatedTokens = await provider.invalidatedTokens
            #expect(invalidatedTokens.isEmpty)
        }
    }

    @Test
    func testConcurrentExportsUseProviderSafelyAndReuseOneClient() async throws
    {
        let provider = SingleFlightTokenProvider(
            token: "shared", expectedWaiters: 8)
        let client = RecordingOtlpClient(
            results: Array(repeating: .success, count: 8))
        let exporter = exporter(provider: provider, client: client)
        let span = span()
        let callers = (0..<8).map { _ in
            let returned = AuthTelemetryTestCompletion<Bool>()
            let task = Task {
                let success = await exporter.export(spans: [span]) == .success
                await returned.complete(success)
            }
            return (task, returned)
        }
        try await withTestCleanup {
            for (task, _) in callers { task.cancel() }
            exporter.cancelActiveExports()
            await provider.releaseToken()
        } operation: {
            try #require(
                await requireAuthTelemetrySignal(
                    provider.allTokenWaitersArrived,
                    stage: "eight concurrent telemetry token waiters"))
            await provider.releaseToken()
            for (index, caller) in callers.enumerated() {
                let success = try #require(
                    await requireAuthTelemetryCompletion(
                        caller.1,
                        stage:
                            "concurrent OTLP export caller \(index) returning"))
                #expect(success)
                await caller.0.value
            }
            let refreshCount = await provider.refreshCount
            #expect(refreshCount == 1)
            #expect(client.exportCount == 8)
            #expect(
                Set(client.recordedMetadata.flatMap { $0.map(\.1) }) == [
                    "Bearer shared"
                ])
        }
    }

    @Test
    func testCancellationUnblocksTokenWaitAndShutsTransportOnce() async throws {
        // Bound observation independently of the production timeout. Capturing
        // before export establishes a lower bound on its possible deadline.
        let earliestDeadline = ContinuousClock.now.advanced(by: .seconds(30))
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [])
        let exporter = exporter(provider: provider, client: client, timeout: 30)
        let span = span()

        let callerReturned = AuthTelemetryTestCompletion<Bool>()
        let exportTask = Task {
            let value = await exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
            await callerReturned.complete(true)
            return value
        }
        try await withTestCleanup {
            exportTask.cancel()
            exporter.cancelActiveExports()
            await provider.retire()
        } operation: {
            #expect(
                await requireAuthTelemetrySignal(
                    provider.requestedSignal,
                    stage: "telemetry token request before span RPC"
                ))
            exporter.cancelActiveExports()
            guard
                await requireAuthTelemetryCompletion(
                    callerReturned,
                    stage: "shutdown cancellation export returning") == true
            else { return }
            let result = await exportTask.value
            #expect(result == .failure)
            #expect(
                await requireAuthTelemetrySignal(
                    provider.cancelledSignal,
                    stage: "token provider observed actual task cancellation"))
            #expect(await provider.cancellationCount == 1)
            let cancellationObservedAt = try #require(
                await provider.cancellationObservedAt)
            #expect(cancellationObservedAt < earliestDeadline)

            let shutdownReturned = AuthTelemetryTestCompletion<Bool>()
            let shutdown = Task {
                await exporter.shutdown()
                await exporter.shutdown()
                await shutdownReturned.complete(true)
            }
            guard
                await requireAuthTelemetryCompletion(
                    shutdownReturned,
                    stage: "coalesced exporter shutdowns returning") == true
            else {
                shutdown.cancel()
                return
            }
            await shutdown.value
            #expect(client.cancelCount == 2)
            #expect(client.shutdownCount == 1)
            #expect(client.synchronousShutdownCount == 0)
            #expect(client.asynchronousShutdownCount == 1)
        }
    }

    @Test
    func testAsyncTransportShutdownWaitsForClosureCompletion() async throws {
        let gate = AsyncShutdownGate()
        let completion = AsyncCompletionState()
        let returned = AuthTelemetryTestCompletion<Bool>()
        let session = URLSession(configuration: .ephemeral)
        let transport = URLSessionRemoteTelemetryHTTPTransport(
            session: session,
            closeTransport: {
                await gate.waitForRelease()
                session.invalidateAndCancel()
            }
        )
        let shutdown = Task {
            await transport.shutdown()
            await completion.markCompleted()
            await returned.complete(true)
        }
        try await withTestCleanup {
            shutdown.cancel()
            await gate.release()
            session.invalidateAndCancel()
        } operation: {
            try #require(await gate.waitUntilEntered())
            let completedBeforeRelease = await completion.isCompleted
            #expect(!(completedBeforeRelease))
            await gate.release()
            try #require(
                await requireAuthTelemetryCompletion(
                    returned, stage: "OTLP transport shutdown caller returning")
                    == true)
            await shutdown.value
            let completedAfterRelease = await completion.isCompleted
            #expect(completedAfterRelease)
        }
    }

    @Test
    func testCancellationAfterTokenCompletionPreventsRPCAndAllowsLaterExport()
        async
    {
        let provider = SequenceTokenProvider(tokens: ["cancelled", "current"])
        let client = GatedRegistrationOtlpClient()
        let exporter = exporter(provider: provider, client: client)
        let span = span()

        let callerReturned = AuthTelemetryTestCompletion<Bool>()
        let exportTask = Task {
            let value = await exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
            await callerReturned.complete(true)
            return value
        }
        #expect(
            await requireAuthTelemetrySignal(
                client.firstRPCWillRegisterSignal,
                stage: "first OTLP RPC registration"
            ))
        exporter.cancelActiveExports()
        await client.allowFirstRPCToRegister()
        guard
            await requireAuthTelemetryCompletion(
                callerReturned, stage: "cancelled OTLP export caller returning")
                == true
        else {
            exportTask.cancel()
            exporter.cancelActiveExports()
            return
        }
        let result = await exportTask.value

        #expect(result == .failure)
        #expect(client.exportCount == 0)
        let laterReturned = AuthTelemetryTestCompletion<Bool>()
        let laterExport = Task {
            let result = await exporter.export(spans: [span])
            await laterReturned.complete(true)
            return result
        }
        guard
            await requireAuthTelemetryCompletion(
                laterReturned,
                stage: "later export after cancellation returning") == true
        else {
            laterExport.cancel()
            exporter.cancelActiveExports()
            return
        }
        let laterResult = await laterExport.value
        #expect(laterResult == .success)
        #expect(client.exportCount == 1)
        let requestCount = await provider.requestCount
        #expect(requestCount == 2)
    }

    @Test
    func testAsyncHTTPClientsUseStandardSignalPathsAndProtobufBodies()
        async throws
    {
        let spanTransport = RecordingHTTPTransport(result: .success)
        let spanClient = HttpRemoteTelemetryOtlpClient(
            endpoint: try #require(
                URL(string: "https://telemetry.example/v1/traces")),
            transport: spanTransport
        )
        let spanResult = await spanClient.export(
            spans: [span()],
            metadata: [("authorization", "Bearer span-token")],
            timeout: 2,
            isActive: { true }
        )
        #expect(spanResult == .success)
        #expect(spanTransport.asynchronousRequestCount == 1)
        let spanRequest = try #require(spanTransport.requests.first)
        #expect(spanRequest.url?.path == "/v1/traces")
        #expect(spanRequest.httpMethod == "POST")
        #expect(
            spanRequest.value(forHTTPHeaderField: "Content-Type")
                == "application/x-protobuf")
        #expect(
            spanRequest.value(forHTTPHeaderField: "Authorization")
                == "Bearer span-token")
        #expect(!(try #require(spanRequest.httpBody).isEmpty))

        let logTransport = RecordingHTTPTransport(result: .success)
        let logClient = HttpRemoteTelemetryOtlpLogClient(
            endpoint: try #require(
                URL(string: "https://telemetry.example/v1/logs")),
            transport: logTransport
        )
        let logResult = await logClient.export(
            logs: [logRecord()],
            metadata: [("authorization", "Bearer log-token")],
            timeout: 2,
            isActive: { true }
        )
        #expect(logResult == .success)
        #expect(logTransport.asynchronousRequestCount == 1)
        let logRequest = try #require(logTransport.requests.first)
        #expect(logRequest.url?.path == "/v1/logs")
        #expect(
            logRequest.value(forHTTPHeaderField: "Content-Type")
                == "application/x-protobuf")
        #expect(
            logRequest.value(forHTTPHeaderField: "Authorization")
                == "Bearer log-token")
        #expect(!(try #require(logRequest.httpBody).isEmpty))

        await spanClient.shutdown()
        await logClient.shutdown()
        #expect(spanTransport.synchronousShutdownCount == 0)
        #expect(spanTransport.asynchronousShutdownCount == 1)
        #expect(logTransport.synchronousShutdownCount == 0)
        #expect(logTransport.asynchronousShutdownCount == 1)
    }

    @Test
    func testHTTPResponseStatusPreservesAuthenticationAndTransportFailures()
        throws
    {
        let url = try #require(URL(string: "https://telemetry.example"))
        func response(_ status: Int) throws -> HTTPURLResponse {
            try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/2",
                    headerFields: nil
                ))
        }

        #expect(
            RemoteTelemetryHTTPResponse.result(
                response: try response(200), error: nil) == .success)
        #expect(
            RemoteTelemetryHTTPResponse.result(
                response: try response(401), error: nil) == .unauthenticated)
        #expect(
            RemoteTelemetryHTTPResponse.result(
                response: try response(403), error: nil) == .rejected)
        #expect(
            RemoteTelemetryHTTPResponse.result(
                response: try response(429), error: nil) == .failure)
        #expect(
            RemoteTelemetryHTTPResponse.result(
                response: nil,
                error: URLError(.cancelled)
            ) == .cancelled)
        #expect(
            RemoteTelemetryHTTPResponse.result(
                response: nil,
                error: URLError(.cannotConnectToHost)
            ) == .failure)
    }

    @Test
    func testCancellationAfterUnauthenticatedResponsePreventsRefreshAndRetry()
        async
    {
        let provider = SequenceTokenProvider(tokens: ["expired", "later"])
        let client = CancellationAfterUnauthenticatedClient()
        let exporter = exporter(provider: provider, client: client)
        client.onUnauthenticated = { [weak exporter] in
            exporter?.cancelActiveExports()
        }

        let firstReturned = AuthTelemetryTestCompletion<Bool>()
        let firstSpan = span()
        let firstExport = Task {
            let result = await exporter.export(spans: [firstSpan])
            await firstReturned.complete(true)
            return result
        }
        guard
            await requireAuthTelemetryCompletion(
                firstReturned,
                stage: "unauthenticated cancellation export caller returning")
                == true
        else {
            firstExport.cancel()
            exporter.cancelActiveExports()
            return
        }
        var exportResult = await firstExport.value
        #expect(exportResult == .failure)
        #expect(client.exportCount == 1)
        var requestCount = await provider.requestCount
        var invalidatedTokens = await provider.invalidatedTokens
        #expect(requestCount == 1)
        #expect(invalidatedTokens.isEmpty)

        let laterReturned = AuthTelemetryTestCompletion<Bool>()
        let laterSpan = span()
        let laterExport = Task {
            let result = await exporter.export(spans: [laterSpan])
            await laterReturned.complete(true)
            return result
        }
        guard
            await requireAuthTelemetryCompletion(
                laterReturned,
                stage:
                    "later export after unauthenticated cancellation returning")
                == true
        else {
            laterExport.cancel()
            exporter.cancelActiveExports()
            return
        }
        exportResult = await laterExport.value
        #expect(exportResult == .success)
        #expect(client.exportCount == 2)
        requestCount = await provider.requestCount
        invalidatedTokens = await provider.invalidatedTokens
        #expect(requestCount == 2)
        #expect(invalidatedTokens.isEmpty)
    }

    @Test
    func testBearerNeverAppearsInExporterOrFailureDescriptions() async {
        let secret = "private-bearer-material"
        let provider = SequenceTokenProvider(tokens: [secret])
        let client = RecordingOtlpClient(results: [.failure])
        let exporter = exporter(provider: provider, client: client)

        let exportedSpan = span()
        let exportReturned = AuthTelemetryTestCompletion<Bool>()
        let exportTask = Task {
            let result = await exporter.export(spans: [exportedSpan])
            await exportReturned.complete(true)
            return result
        }
        guard
            await requireAuthTelemetryCompletion(
                exportReturned,
                stage: "privacy scenario export caller returning") == true
        else {
            exportTask.cancel()
            exporter.cancelActiveExports()
            return
        }
        let exportResult = await exportTask.value
        let flushReturned = AuthTelemetryTestCompletion<Bool>()
        let flushTask = Task {
            let result = await exporter.flush()
            await flushReturned.complete(true)
            return result
        }
        guard
            await requireAuthTelemetryCompletion(
                flushReturned,
                stage: "privacy scenario flush caller returning") == true
        else {
            flushTask.cancel()
            exporter.cancelActiveExports()
            return
        }
        let flushResult = await flushTask.value
        #expect(exportResult == .failure)
        let externallyVisible = [
            String(describing: RemoteTelemetryRuntimeFailure.exportFailed),
            String(
                describing:
                    AuthenticatedOtlpSpanExporterConfigurationError
                    .invalidEndpoint
            ),
            String(describing: flushResult),
        ].joined(separator: "\n")
        #expect(!(externallyVisible.contains(secret)))
        #expect(!(String(describing: span()).contains(secret)))
    }

    @Test
    func testBearerNeverAppearsInCapturedProcessLogs() async throws {
        if let rawMode = ProcessInfo.processInfo.environment[
            BearerLogChild.environmentKey]
        {
            let mode = try #require(BearerLogChild.Mode(rawValue: rawMode))
            FileHandle.standardOutput.write(
                Data("stdout capture sentinel\n".utf8))
            FileHandle.standardError.write(
                Data("stderr capture sentinel\n".utf8))
            switch mode {
            case .incompleteReport:
                // Simulate successful process termination without runner evidence.
                Darwin._exit(0)
            case .hang:
                // Deliberately never complete: only the parent's deadline may
                // stop this injected uncooperative child.
                let never = AsyncStream<Void> { _ in }
                for await _ in never {}
            case .failure:
                Issue.record("Injected child test failure")
            case .flood:
                // Larger than a Darwin pipe: the parent must drain concurrently.
                for _ in 0..<128 {
                    FileHandle.standardOutput.write(
                        Data(repeating: 120, count: 16 * 1024))
                }
            case .leak:
                FileHandle.standardError.write(
                    Data("Bearer \(BearerLogChild.secret)\n".utf8))
            case .exporter:
                let provider = SequenceTokenProvider(tokens: [
                    BearerLogChild.secret
                ])
                let client = RecordingOtlpClient(results: [.failure])
                let exporter = exporter(provider: provider, client: client)
                let result = await exporter.export(spans: [span()])
                #expect(client.exportCount == 1)
                #expect(client.asynchronousExportCount == 1)
                #expect(await provider.requestCount == 1)
                #expect(result == .failure)
            }
            return
        }
        let result = await BearerLogChild.run()
        #expect(result.failure == nil)
        #expect(result.cleanupFailures.isEmpty)
        #expect(result.reaped)
        #expect(result.readersClosed)
        #expect(result.writersClosed)
        #expect(result.reportRemoved)
        #expect(result.privacyFailure == nil)
    }

    private func exporter(
        provider: any TelemetryTokenProviding,
        client: any RemoteTelemetryOtlpClient,
        timeout: TimeInterval = 2
    ) -> AuthenticatedOtlpSpanExporter {
        AuthenticatedOtlpSpanExporter(
            tokenProvider: provider,
            client: client,
            timeout: timeout
        )
    }

    nonisolated private func span() -> SpanData {
        SpanData(
            traceId: TraceId(),
            spanId: SpanId(),
            resource: Resource(),
            instrumentationScope: InstrumentationScopeInfo(
                name: "app.bleat.test"
            ),
            name: "bleat.app.launch",
            kind: .internal,
            startTime: Date(timeIntervalSince1970: 1),
            endTime: Date(timeIntervalSince1970: 2),
            hasEnded: true
        )
    }

    nonisolated private func logRecord() -> ReadableLogRecord {
        ReadableLogRecord(
            resource: Resource(),
            instrumentationScopeInfo: InstrumentationScopeInfo(
                name: "app.bleat.test"
            ),
            timestamp: Date(timeIntervalSince1970: 2),
            severity: .error,
            body: .string("CloudKit synchronization lifecycle"),
            attributes: [
                "bleat.cloudkit.operation": .string("synchronize")
            ],
            eventName: "bleat.cloudkit.sync.failed"
        )
    }
}

private actor SequenceTokenProvider: TelemetryTokenProviding {
    private var tokens: [String]
    private(set) var invalidatedTokens: [String] = []
    private(set) var requestCount = 0

    init(tokens: [String]) {
        self.tokens = tokens
    }

    func currentToken() async throws(TelemetryTokenProviderError) -> String {
        requestCount += 1
        guard !tokens.isEmpty else { throw .temporarilyUnavailable }
        return tokens.removeFirst()
    }

    func invalidateToken(ifCurrent token: String) {
        invalidatedTokens.append(token)
    }
}

private actor SingleFlightTokenProvider: TelemetryTokenProviding {
    private let token: String
    private let expectedWaiters: Int
    private var cached: String?
    private(set) var refreshCount = 0
    private var waiters: [CheckedContinuation<String, Never>] = []
    private var released = false
    nonisolated let allTokenWaitersArrived = AuthTelemetryTestSignal()

    init(token: String, expectedWaiters: Int) {
        self.token = token
        self.expectedWaiters = expectedWaiters
    }

    func currentToken() async throws(TelemetryTokenProviderError) -> String {
        if let cached { return cached }
        if refreshCount == 0 { refreshCount = 1 }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            if waiters.count == expectedWaiters {
                Task { await allTokenWaitersArrived.signal() }
            }
            if released {
                continuation.resume(returning: token)
            }
        }
    }

    func releaseToken() {
        guard !released else { return }
        released = true
        cached = token
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting {
            waiter.resume(returning: token)
        }
    }

    func invalidateToken(ifCurrent token: String) {
        if cached == token { cached = nil }
    }
}

private actor SuspendedTokenProvider: TelemetryTokenProviding {
    nonisolated let requestedSignal = AuthTelemetryTestSignal()
    nonisolated let waitingSignal = AuthTelemetryTestSignal()
    nonisolated let cancelledSignal = AuthTelemetryTestSignal()
    private let releaseSignal = AuthTelemetryTestSignal()
    private let exitedSignal = AuthTelemetryTestSignal()
    private var retired = false
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0
    private(set) var cancellationObservedAt: ContinuousClock.Instant?

    func currentToken() async throws(TelemetryTokenProviderError) -> String {
        guard !retired else { throw .cancelled }
        guard requestCount == 0 else {
            Issue.record("One-shot token fake was reused")
            throw .cancelled
        }
        requestCount += 1
        await requestedSignal.signal()
        let release = releaseSignal
        let waiting = waitingSignal
        let outcome = await withTaskCancellationHandler {
            await waiting.signal()
            return await release.wait()
        } onCancel: {
            Task { await release.signal() }
        }
        if case .timedOut(let elapsed) = outcome {
            Issue.record("Token fake control event missing after \(elapsed)")
        }
        if Task.isCancelled {
            cancellationObservedAt = ContinuousClock.now
            cancellationCount += 1
            await cancelledSignal.signal()
        }
        await exitedSignal.signal()
        throw .cancelled
    }

    func invalidateToken(ifCurrent token: String) async {}

    /// Retirement releases owned waiters, but never manufactures cancellation.
    func retire(sourceLocation: SourceLocation = #_sourceLocation) async {
        retired = true
        await releaseSignal.signal()
        if requestCount != 0 {
            await requireAuthTelemetrySignal(
                exitedSignal, stage: "retired one-shot token fake exit",
                sourceLocation: sourceLocation)
        }
    }
}

private actor CancellationIgnoringTokenProvider: TelemetryTokenProviding {
    nonisolated let waitingSignal = AuthTelemetryTestSignal()
    nonisolated let cancellationSignal = AuthTelemetryTestSignal()
    private var released = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private let exitedSignal = AuthTelemetryTestSignal()
    private var retired = false
    private(set) var requestCount = 0
    private(set) var exitCount = 0

    func currentToken() async throws(TelemetryTokenProviderError) -> String {
        guard !retired else { throw .cancelled }
        guard requestCount == 0 else {
            Issue.record("One-shot uncooperative token fake was reused")
            throw .cancelled
        }
        requestCount += 1
        let waiting = waitingSignal
        let cancellation = cancellationSignal
        await withTaskCancellationHandler {
            await waiting.signal()
            await waitForRelease()
        } onCancel: {
            // Acknowledge actual cancellation without releasing the held body.
            Task { await cancellation.signal() }
        }
        exitCount += 1
        await exitedSignal.signal()
        throw .cancelled
    }

    private func waitForRelease() async {
        guard !released else { return }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func invalidateToken(ifCurrent token: String) async {}

    func retire(sourceLocation: SourceLocation = #_sourceLocation) async {
        retired = true
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
        if requestCount != 0 {
            await requireAuthTelemetrySignal(
                exitedSignal, stage: "retired uncooperative token fake exit",
                sourceLocation: sourceLocation)
        }
    }
}

private enum ManualSleepSettlement: Equatable, Sendable {
    case released, cancelled
}

/// Fresh one-shot clock per test; all time movement and timer release is explicit.
private final class ManualOtlpClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSinceReferenceDate: 0)
    private var retired = false
    private var fired = false
    private var entries: [ManualOtlpSleep] = []
    private var recordedBudgets: [TimeInterval] = []
    private var completedSleeps = 0
    let registeredSignal = AuthTelemetryTestSignal()
    let finishedSignal = AuthTelemetryTestSignal()

    var clock: OtlpExportClock {
        OtlpExportClock(
            now: { self.lock.withLock { self.current } },
            sleep: { try await self.sleep($0) })
    }
    var budgets: [TimeInterval] { lock.withLock { recordedBudgets } }
    var finishedCount: Int { lock.withLock { completedSleeps } }
    var hasFired: Bool { lock.withLock { fired } }
    var pendingCount: Int {
        lock.withLock { entries.filter { $0.settlement == nil }.count }
    }
    var pendingContinuationCount: Int {
        lock.withLock { entries.filter(\.hasContinuation).count }
    }
    var settlements: [ManualSleepSettlement?] {
        lock.withLock { entries.map(\.settlement) }
    }
    var resolutionCounts: [Int] {
        lock.withLock { entries.map(\.resolutionCount) }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(interval) }
    }

    func fire() {
        let waiting = lock.withLock { () -> [ManualOtlpSleep] in
            guard !retired else { return [] }
            fired = true
            return entries
        }
        for waiter in waiting { waiter.resolve(.released) }
    }

    private func register(_ waiter: ManualOtlpSleep, budget: TimeInterval)
        -> Bool
    {
        let state = lock.withLock { () -> (accepted: Bool, fired: Bool) in
            guard !retired else { return (false, false) }
            entries.append(waiter)
            recordedBudgets.append(budget)
            return (true, fired)
        }
        if state.fired { waiter.resolve(.released) }
        return state.accepted
    }

    private func sleep(_ budget: TimeInterval) async throws {
        let waiter = ManualOtlpSleep(registeredSignal: registeredSignal)
        do {
            try await withTaskCancellationHandler {
                guard register(waiter, budget: budget) else {
                    throw CancellationError()
                }
                try await waiter.wait()
            } onCancel: {
                waiter.resolve(.cancelled)
            }
            await finish(waiter)
        } catch {
            await finish(waiter)
            throw error
        }
    }

    private func finish(_ waiter: ManualOtlpSleep) async {
        let owned = lock.withLock { () -> Bool in
            guard entries.contains(where: { $0 === waiter }) else {
                return false
            }
            completedSleeps += 1
            return true
        }
        if owned {
            await waiter.exitedSignal.signal()
            await finishedSignal.signal()
        }
    }

    func retire(sourceLocation: SourceLocation = #_sourceLocation) async {
        let waiting = lock.withLock {
            retired = true
            return entries
        }
        for waiter in waiting { waiter.resolve(.cancelled) }
        for waiter in waiting {
            await requireAuthTelemetrySignal(
                waiter.exitedSignal,
                stage: "retired controlled deadline sleep exit",
                sourceLocation: sourceLocation)
        }
    }
}

private final class ManualOtlpSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var result: ManualSleepSettlement?
    private var resolutions = 0
    private var continuation: CheckedContinuation<Void, any Error>?
    let exitedSignal = AuthTelemetryTestSignal()
    private let registeredSignal: AuthTelemetryTestSignal

    init(registeredSignal: AuthTelemetryTestSignal) {
        self.registeredSignal = registeredSignal
    }

    var settlement: ManualSleepSettlement? { lock.withLock { result } }
    var resolutionCount: Int { lock.withLock { resolutions } }
    var hasContinuation: Bool { lock.withLock { continuation != nil } }

    func wait() async throws {
        let registered = registeredSignal
        try await withCheckedThrowingContinuation { continuation in
            let settled: ManualSleepSettlement? = lock.withLock {
                if let result { return result }
                self.continuation = continuation
                return nil
            }
            if let settled { resume(continuation, with: settled) }
            // Acknowledge only after the continuation was installed or settled.
            Task { await registered.signal() }
        }
    }

    func resolve(_ settled: ManualSleepSettlement) {
        let waiting = lock.withLock {
            () -> CheckedContinuation<Void, any Error>? in
            guard result == nil else { return nil }
            result = settled
            resolutions += 1
            let waiting = continuation
            continuation = nil
            return waiting
        }
        if let waiting { resume(waiting, with: settled) }
    }

    private func resume(
        _ continuation: CheckedContinuation<Void, any Error>,
        with settled: ManualSleepSettlement
    ) {
        switch settled {
        case .released: continuation.resume()
        case .cancelled: continuation.resume(throwing: CancellationError())
        }
    }
}

private final class RecordingOtlpClient:
    RemoteTelemetryOtlpClient, @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [RemoteTelemetryOtlpExportResult]
    private var metadata: [[(String, String)]] = []
    private var cancellations = 0
    private var shutdowns = 0
    private var synchronousShutdowns = 0
    private var asynchronousShutdowns = 0
    private var asynchronousExports = 0

    init(results: [RemoteTelemetryOtlpExportResult]) {
        self.results = results
    }

    var recordedMetadata: [[(String, String)]] {
        lock.withLock { metadata }
    }

    var exportCount: Int { lock.withLock { metadata.count } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    var synchronousShutdownCount: Int {
        lock.withLock { synchronousShutdowns }
    }
    var asynchronousShutdownCount: Int {
        lock.withLock { asynchronousShutdowns }
    }
    var asynchronousExportCount: Int {
        lock.withLock { asynchronousExports }
    }

    func export(
        spans: [SpanData],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult {
        lock.withLock { asynchronousExports += 1 }
        return recordExport(metadata: metadata, isActive: isActive)
    }

    private func recordExport(
        metadata: [(String, String)],
        isActive: @escaping @Sendable () -> Bool
    ) -> RemoteTelemetryOtlpExportResult {
        guard isActive() else { return .cancelled }
        return lock.withLock {
            self.metadata.append(metadata)
            guard !results.isEmpty else { return .failure }
            return results.removeFirst()
        }
    }

    func cancelActiveExports() {
        lock.withLock { cancellations += 1 }
    }

    func shutdown() {
        lock.withLock {
            shutdowns += 1
            synchronousShutdowns += 1
        }
    }

    func shutdown() async {
        lock.withLock {
            shutdowns += 1
            asynchronousShutdowns += 1
        }
    }
}

private final class RecordingHTTPTransport:
    RemoteTelemetryHTTPTransport, @unchecked Sendable
{
    private let lock = NSLock()
    private let result: RemoteTelemetryOtlpExportResult
    private var recordedRequests: [URLRequest] = []
    private var asynchronousRequests = 0
    private var synchronousShutdowns = 0
    private var asynchronousShutdowns = 0

    init(result: RemoteTelemetryOtlpExportResult) {
        self.result = result
    }

    var requests: [URLRequest] { lock.withLock { recordedRequests } }
    var asynchronousRequestCount: Int {
        lock.withLock { asynchronousRequests }
    }
    var synchronousShutdownCount: Int {
        lock.withLock { synchronousShutdowns }
    }
    var asynchronousShutdownCount: Int {
        lock.withLock { asynchronousShutdowns }
    }

    func send(
        _ request: URLRequest,
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult {
        lock.withLock { asynchronousRequests += 1 }
        return record(request, isActive: isActive)
    }

    private func record(
        _ request: URLRequest,
        isActive: @escaping @Sendable () -> Bool
    ) -> RemoteTelemetryOtlpExportResult {
        guard isActive() else { return .cancelled }
        lock.withLock { recordedRequests.append(request) }
        return result
    }

    func cancelActiveRequests() {}
    func shutdown() { lock.withLock { synchronousShutdowns += 1 } }
    func shutdown() async { lock.withLock { asynchronousShutdowns += 1 } }
}

private final class RecordingOtlpLogClient:
    RemoteTelemetryOtlpLogClient, @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [RemoteTelemetryOtlpExportResult]
    private var metadata: [[(String, String)]] = []
    private var shutdowns = 0
    private var synchronousShutdowns = 0
    private var asynchronousShutdowns = 0
    private var asynchronousExports = 0

    init(results: [RemoteTelemetryOtlpExportResult]) {
        self.results = results
    }

    var recordedMetadata: [[(String, String)]] {
        lock.withLock { metadata }
    }

    var exportCount: Int { lock.withLock { metadata.count } }
    var shutdownCount: Int { lock.withLock { shutdowns } }
    var synchronousShutdownCount: Int {
        lock.withLock { synchronousShutdowns }
    }
    var asynchronousShutdownCount: Int {
        lock.withLock { asynchronousShutdowns }
    }
    var asynchronousExportCount: Int {
        lock.withLock { asynchronousExports }
    }

    func export(
        logs: [ReadableLogRecord],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult {
        lock.withLock { asynchronousExports += 1 }
        return recordExport(metadata: metadata, isActive: isActive)
    }

    private func recordExport(
        metadata: [(String, String)],
        isActive: @escaping @Sendable () -> Bool
    ) -> RemoteTelemetryOtlpExportResult {
        guard isActive() else { return .cancelled }
        return lock.withLock {
            self.metadata.append(metadata)
            guard !results.isEmpty else { return .failure }
            return results.removeFirst()
        }
    }

    func cancelActiveExports() {}

    func shutdown() {
        lock.withLock {
            shutdowns += 1
            synchronousShutdowns += 1
        }
    }

    func shutdown() async {
        lock.withLock {
            shutdowns += 1
            asynchronousShutdowns += 1
        }
    }
}

private final class CancellationAfterUnauthenticatedClient:
    RemoteTelemetryOtlpClient, @unchecked Sendable
{
    private let lock = NSLock()
    private var exports = 0
    var onUnauthenticated: (@Sendable () -> Void)?

    var exportCount: Int { lock.withLock { exports } }

    func export(
        spans: [SpanData],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult {
        exportResult(isActive: isActive)
    }

    private func exportResult(
        isActive: @escaping @Sendable () -> Bool
    ) -> RemoteTelemetryOtlpExportResult {
        guard isActive() else { return .cancelled }
        let export = lock.withLock {
            exports += 1
            return exports
        }
        guard export == 1 else { return .success }
        onUnauthenticated?()
        return .unauthenticated
    }

    func cancelActiveExports() {}

    func shutdown() {}
    func shutdown() async {}
}

private final class GatedRegistrationOtlpClient:
    RemoteTelemetryOtlpClient, @unchecked Sendable
{
    private let lock = NSLock()
    nonisolated let firstRPCWillRegisterSignal = AuthTelemetryTestSignal()
    private let registrationGate = AsyncShutdownGate()
    private var attempts = 0
    private var exports = 0

    var exportCount: Int { lock.withLock { exports } }

    func export(
        spans: [SpanData],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt == 1 {
            await firstRPCWillRegisterSignal.signal()
            await registrationGate.waitForRelease()
        }
        guard isActive() else { return .cancelled }
        lock.withLock { exports += 1 }
        return .success
    }

    func cancelActiveExports() {}

    func shutdown() {}
    func shutdown() async {}

    func allowFirstRPCToRegister() async {
        await registrationGate.release()
    }
}

private actor AsyncShutdownGate {
    private var released = false
    nonisolated let entrySignal = AuthTelemetryTestSignal()
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        await entrySignal.signal()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if released { return true }
        return await requireAuthTelemetrySignal(
            entrySignal,
            stage: "async shutdown closure entry",
            sourceLocation: sourceLocation
        )
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters.removeAll()
    }
}

private actor AsyncCompletionState {
    private(set) var isCompleted = false

    func markCompleted() {
        isCompleted = true
    }
}
