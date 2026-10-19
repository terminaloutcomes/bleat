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
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [.success])
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
            #expect(client.exportCount == 0)
        }
    }

    @Test
    func testCancelActiveExportsCancelsAsyncTokenWaitBeforeRPC() async throws {
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [.success])
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
            #expect(client.exportCount == 0)
            #expect(client.cancelCount == 1)
        }
    }

    @Test
    func testAsyncTokenTimeoutDoesNotWaitForCancellationIgnoringProvider()
        async
    {
        let provider = CancellationIgnoringTokenProvider()
        let client = RecordingOtlpClient(results: [.success])
        let exporter = exporter(provider: provider, client: client)
        let started = ContinuousClock.now

        let result = await exporter.export(
            spans: [span()],
            explicitTimeout: 0.05
        )

        #expect(result == .failure)
        #expect(started.duration(to: .now) < .milliseconds(500))
        #expect(client.exportCount == 0)
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

        var spanResult = await spanExporter.flush()
        var logResult = await logExporter.forceFlush()
        #expect(spanResult == .success)
        #expect(logResult == .success)

        await spanExporter.shutdown()
        await logExporter.shutdown()

        spanResult = await spanExporter.flush()
        logResult = await logExporter.forceFlush()
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
    func testConcurrentExportsUseProviderSafelyAndReuseOneClient() async {
        let provider = SingleFlightTokenProvider(
            token: "shared",
            expectedWaiters: 8
        )
        let client = RecordingOtlpClient(
            results: Array(repeating: .success, count: 8)
        )
        let exporter = exporter(provider: provider, client: client)

        let span = span()
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await exporter.export(spans: [span]) == .success
                }
            }
            #expect(
                await requireAuthTelemetrySignal(
                    provider.allTokenWaitersArrived,
                    stage: "eight concurrent telemetry token waiters"
                ))
            await provider.releaseToken()
            for await result in group {
                #expect(result)
            }
        }

        let refreshCount = await provider.refreshCount
        #expect(refreshCount == 1)
        #expect(client.exportCount == 8)
        #expect(
            Set(client.recordedMetadata.flatMap { $0.map(\.1) }) == [
                "Bearer shared"
            ])
    }

    @Test
    func testCancellationUnblocksTokenWaitAndShutsTransportOnce() async throws {
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [])
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
    func testAsyncTransportShutdownWaitsForClosureCompletion() async {
        let gate = AsyncShutdownGate()
        let completion = AsyncCompletionState()
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
        }
        #expect(await gate.waitUntilEntered())
        let completedBeforeRelease = await completion.isCompleted
        #expect(!(completedBeforeRelease))

        await gate.release()
        await shutdown.value
        let completedAfterRelease = await completion.isCompleted
        #expect(completedAfterRelease)
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

        var exportResult = await exporter.export(spans: [span()])
        #expect(exportResult == .failure)
        #expect(client.exportCount == 1)
        var requestCount = await provider.requestCount
        var invalidatedTokens = await provider.invalidatedTokens
        #expect(requestCount == 1)
        #expect(invalidatedTokens.isEmpty)

        exportResult = await exporter.export(spans: [span()])
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

        let exportResult = await exporter.export(spans: [span()])
        let flushResult = await exporter.flush()
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
        client: any RemoteTelemetryOtlpClient
    ) -> AuthenticatedOtlpSpanExporter {
        AuthenticatedOtlpSpanExporter(
            tokenProvider: provider,
            client: client,
            timeout: 2
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

private final class CancellationIgnoringTokenProvider:
    TelemetryTokenProviding, @unchecked Sendable
{
    func currentToken() async throws(TelemetryTokenProviderError) -> String {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw .cancelled
    }

    func invalidateToken(ifCurrent token: String) async {}
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
