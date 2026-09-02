import Darwin
import Foundation
@preconcurrency import OpenTelemetryApi
import XCTest

@testable import BleatCore
@testable import OpenTelemetrySdk

final class AuthenticatedOtlpSpanExporterTests: XCTestCase {
    func testConfigurationRequiresHTTPSOriginAndPositiveTimeout() throws {
        XCTAssertNoThrow(
            try AuthenticatedOtlpSpanExporterConfiguration(
                endpoint: XCTUnwrap(
                    URL(string: "https://telemetry.example:4317"))
            )
        )
        for endpoint in [
            "http://telemetry.example:4317",
            "https://user@telemetry.example:4317",
            "https://telemetry.example:4317/v1/traces",
            "https://telemetry.example:4317?token=secret",
            "https://telemetry.example:4317#fragment",
        ] {
            XCTAssertThrowsError(
                try AuthenticatedOtlpSpanExporterConfiguration(
                    endpoint: XCTUnwrap(URL(string: endpoint))
                )
            ) { error in
                XCTAssertEqual(
                    error as? AuthenticatedOtlpSpanExporterConfigurationError,
                    .invalidEndpoint
                )
            }
        }
        XCTAssertThrowsError(
            try AuthenticatedOtlpSpanExporterConfiguration(
                endpoint: XCTUnwrap(URL(string: "https://telemetry.example")),
                timeout: 0
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedOtlpSpanExporterConfigurationError,
                .invalidTimeout
            )
        }
    }

    func testEachExportUsesExactlyOneCurrentBearerValue() async {
        let provider = SequenceTokenProvider(tokens: ["first", "second"])
        let client = RecordingOtlpClient(results: [.success, .success])
        let exporter = exporter(provider: provider, client: client)

        let first = await exporter.export(spans: [span()])
        let second = await exporter.export(spans: [span()])
        XCTAssertEqual(first, .success)
        XCTAssertEqual(second, .success)

        XCTAssertEqual(
            client.recordedMetadata.map {
                $0.map { "\($0.0)=\($0.1)" }
            },
            [
                ["authorization=Bearer first"],
                ["authorization=Bearer second"],
            ]
        )
        XCTAssertEqual(client.asynchronousExportCount, 2)
        XCTAssertEqual(client.shutdownCount, 0)
    }

    func testUnauthenticatedResponseInvalidatesMatchingTokenAndRetriesOnce()
        async
    {
        let provider = SequenceTokenProvider(tokens: ["expired", "renewed"])
        let client = RecordingOtlpClient(
            results: [.unauthenticated, .success]
        )
        let exporter = exporter(provider: provider, client: client)

        let result = await exporter.export(spans: [span()])
        XCTAssertEqual(result, .success)
        XCTAssertEqual(client.exportCount, 2)
        XCTAssertEqual(client.asynchronousExportCount, 2)
        let invalidatedTokens = await provider.invalidatedTokens
        XCTAssertEqual(invalidatedTokens, ["expired"])
        XCTAssertEqual(
            client.recordedMetadata.last?.map { "\($0.0)=\($0.1)" },
            ["authorization=Bearer renewed"]
        )
    }

    func testPersistentAuthenticationRejectionNeverLoops() async {
        let provider = SequenceTokenProvider(tokens: ["one", "two", "three"])
        let client = RecordingOtlpClient(
            results: [.unauthenticated, .unauthenticated, .success]
        )
        let exporter = exporter(provider: provider, client: client)

        let result = await exporter.export(spans: [span()])
        XCTAssertEqual(result, .failure)
        XCTAssertEqual(client.exportCount, 2)
        XCTAssertEqual(client.asynchronousExportCount, 2)
        let requestCount = await provider.requestCount
        let invalidatedTokens = await provider.invalidatedTokens
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(invalidatedTokens, ["one", "two"])
    }

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
        XCTAssertEqual(result, .success)
        XCTAssertEqual(client.exportCount, 2)
        XCTAssertEqual(client.asynchronousExportCount, 2)
        XCTAssertEqual(
            client.recordedMetadata.last?.map { "\($0.0)=\($0.1)" },
            ["authorization=Bearer renewed"]
        )
        let invalidated = await provider.invalidatedTokens
        XCTAssertEqual(invalidated, ["expired"])

        exporter.disable()
        result = await exporter.export(logRecords: [logRecord()])
        XCTAssertEqual(result, .failure)
        XCTAssertEqual(client.exportCount, 2)
        await exporter.shutdown()
        XCTAssertEqual(client.shutdownCount, 1)
    }

    func testCancellingAsyncExportCancelsTokenWaitBeforeRPC() async {
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [.success])
        let exporter = exporter(provider: provider, client: client)
        let span = span()

        let exportTask = Task {
            await exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
        }
        XCTAssertTrue(provider.waitUntilRequested(timeout: 2))
        exportTask.cancel()

        let result = await exportTask.value
        XCTAssertEqual(result, .failure)
        XCTAssertEqual(client.exportCount, 0)
    }

    func testCancelActiveExportsCancelsAsyncTokenWaitBeforeRPC() async {
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [.success])
        let exporter = exporter(provider: provider, client: client)
        let span = span()

        let exportTask = Task {
            await exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
        }
        XCTAssertTrue(provider.waitUntilRequested(timeout: 2))
        exporter.cancelActiveExports()

        let result = await exportTask.value
        XCTAssertEqual(result, .failure)
        XCTAssertEqual(client.exportCount, 0)
        XCTAssertEqual(client.cancelCount, 1)
    }

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

        XCTAssertEqual(result, .failure)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(500))
        XCTAssertEqual(client.exportCount, 0)
    }

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
        XCTAssertEqual(spanResult, .success)
        XCTAssertEqual(logResult, .success)

        await spanExporter.shutdown()
        await logExporter.shutdown()

        spanResult = await spanExporter.flush()
        logResult = await logExporter.forceFlush()
        XCTAssertEqual(spanResult, .failure)
        XCTAssertEqual(logResult, .failure)
        XCTAssertEqual(spanClient.shutdownCount, 1)
        XCTAssertEqual(logClient.shutdownCount, 1)
        XCTAssertEqual(spanClient.synchronousShutdownCount, 0)
        XCTAssertEqual(spanClient.asynchronousShutdownCount, 1)
        XCTAssertEqual(logClient.synchronousShutdownCount, 0)
        XCTAssertEqual(logClient.asynchronousShutdownCount, 1)
    }

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
            XCTAssertEqual(exportResult, .failure)
            XCTAssertEqual(client.exportCount, 1)
            let invalidatedTokens = await provider.invalidatedTokens
            XCTAssertTrue(invalidatedTokens.isEmpty)
        }
    }

    func testConcurrentExportsUseProviderSafelyAndReuseOneClient() async {
        let provider = SingleFlightTokenProvider(token: "shared")
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
            for await result in group {
                XCTAssertTrue(result)
            }
        }

        let refreshCount = await provider.refreshCount
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(client.exportCount, 8)
        XCTAssertEqual(
            Set(client.recordedMetadata.flatMap { $0.map(\.1) }),
            ["Bearer shared"]
        )
    }

    func testCancellationUnblocksTokenWaitAndShutsTransportOnce() async {
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [])
        let exporter = exporter(provider: provider, client: client)
        let span = span()

        let exportTask = Task {
            await exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
        }
        XCTAssertTrue(provider.waitUntilRequested(timeout: 2))
        exporter.cancelActiveExports()
        let result = await exportTask.value
        XCTAssertEqual(result, .failure)

        await exporter.shutdown()
        await exporter.shutdown()
        XCTAssertEqual(client.cancelCount, 2)
        XCTAssertEqual(client.shutdownCount, 1)
        XCTAssertEqual(client.synchronousShutdownCount, 0)
        XCTAssertEqual(client.asynchronousShutdownCount, 1)
    }

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
        await gate.waitUntilEntered()
        let completedBeforeRelease = await completion.isCompleted
        XCTAssertFalse(completedBeforeRelease)

        await gate.release()
        await shutdown.value
        let completedAfterRelease = await completion.isCompleted
        XCTAssertTrue(completedAfterRelease)
    }

    func testCancellationAfterTokenCompletionPreventsRPCAndAllowsLaterExport()
        async
    {
        let provider = SequenceTokenProvider(tokens: ["cancelled", "current"])
        let client = GatedRegistrationOtlpClient()
        let exporter = exporter(provider: provider, client: client)
        let span = span()

        let exportTask = Task {
            await exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
        }
        XCTAssertTrue(client.waitUntilFirstRPCWillRegister(timeout: 2))
        exporter.cancelActiveExports()
        await client.allowFirstRPCToRegister()
        let result = await exportTask.value

        XCTAssertEqual(result, .failure)
        XCTAssertEqual(client.exportCount, 0)
        let laterResult = await exporter.export(spans: [span])
        XCTAssertEqual(laterResult, .success)
        XCTAssertEqual(client.exportCount, 1)
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testAsyncHTTPClientsUseStandardSignalPathsAndProtobufBodies()
        async throws
    {
        let spanTransport = RecordingHTTPTransport(result: .success)
        let spanClient = HttpRemoteTelemetryOtlpClient(
            endpoint: try XCTUnwrap(
                URL(string: "https://telemetry.example/v1/traces")
            ),
            transport: spanTransport
        )
        let spanResult = await spanClient.export(
            spans: [span()],
            metadata: [("authorization", "Bearer span-token")],
            timeout: 2,
            isActive: { true }
        )
        XCTAssertEqual(spanResult, .success)
        XCTAssertEqual(spanTransport.asynchronousRequestCount, 1)
        let spanRequest = try XCTUnwrap(spanTransport.requests.first)
        XCTAssertEqual(spanRequest.url?.path, "/v1/traces")
        XCTAssertEqual(spanRequest.httpMethod, "POST")
        XCTAssertEqual(
            spanRequest.value(forHTTPHeaderField: "Content-Type"),
            "application/x-protobuf"
        )
        XCTAssertEqual(
            spanRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer span-token"
        )
        XCTAssertFalse(try XCTUnwrap(spanRequest.httpBody).isEmpty)

        let logTransport = RecordingHTTPTransport(result: .success)
        let logClient = HttpRemoteTelemetryOtlpLogClient(
            endpoint: try XCTUnwrap(
                URL(string: "https://telemetry.example/v1/logs")
            ),
            transport: logTransport
        )
        let logResult = await logClient.export(
            logs: [logRecord()],
            metadata: [("authorization", "Bearer log-token")],
            timeout: 2,
            isActive: { true }
        )
        XCTAssertEqual(logResult, .success)
        XCTAssertEqual(logTransport.asynchronousRequestCount, 1)
        let logRequest = try XCTUnwrap(logTransport.requests.first)
        XCTAssertEqual(logRequest.url?.path, "/v1/logs")
        XCTAssertEqual(
            logRequest.value(forHTTPHeaderField: "Content-Type"),
            "application/x-protobuf"
        )
        XCTAssertEqual(
            logRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer log-token"
        )
        XCTAssertFalse(try XCTUnwrap(logRequest.httpBody).isEmpty)

        await spanClient.shutdown()
        await logClient.shutdown()
        XCTAssertEqual(spanTransport.synchronousShutdownCount, 0)
        XCTAssertEqual(spanTransport.asynchronousShutdownCount, 1)
        XCTAssertEqual(logTransport.synchronousShutdownCount, 0)
        XCTAssertEqual(logTransport.asynchronousShutdownCount, 1)
    }

    func testHTTPResponseStatusPreservesAuthenticationAndTransportFailures()
        throws
    {
        let url = try XCTUnwrap(URL(string: "https://telemetry.example"))
        func response(_ status: Int) throws -> HTTPURLResponse {
            try XCTUnwrap(
                HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/2",
                    headerFields: nil
                )
            )
        }

        XCTAssertEqual(
            RemoteTelemetryHTTPResponse.result(
                response: try response(200), error: nil),
            .success
        )
        XCTAssertEqual(
            RemoteTelemetryHTTPResponse.result(
                response: try response(401), error: nil),
            .unauthenticated
        )
        XCTAssertEqual(
            RemoteTelemetryHTTPResponse.result(
                response: try response(403), error: nil),
            .rejected
        )
        XCTAssertEqual(
            RemoteTelemetryHTTPResponse.result(
                response: try response(429), error: nil),
            .failure
        )
        XCTAssertEqual(
            RemoteTelemetryHTTPResponse.result(
                response: nil,
                error: URLError(.cancelled)
            ),
            .cancelled
        )
        XCTAssertEqual(
            RemoteTelemetryHTTPResponse.result(
                response: nil,
                error: URLError(.cannotConnectToHost)
            ),
            .failure
        )
    }

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
        XCTAssertEqual(exportResult, .failure)
        XCTAssertEqual(client.exportCount, 1)
        var requestCount = await provider.requestCount
        var invalidatedTokens = await provider.invalidatedTokens
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(invalidatedTokens.isEmpty)

        exportResult = await exporter.export(spans: [span()])
        XCTAssertEqual(exportResult, .success)
        XCTAssertEqual(client.exportCount, 2)
        requestCount = await provider.requestCount
        invalidatedTokens = await provider.invalidatedTokens
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(invalidatedTokens.isEmpty)
    }

    func testBearerNeverAppearsInExporterOrFailureDescriptions() async {
        let secret = "private-bearer-material"
        let provider = SequenceTokenProvider(tokens: [secret])
        let client = RecordingOtlpClient(results: [.failure])
        let exporter = exporter(provider: provider, client: client)

        let exportResult = await exporter.export(spans: [span()])
        let flushResult = await exporter.flush()
        XCTAssertEqual(exportResult, .failure)
        let externallyVisible = [
            String(describing: RemoteTelemetryRuntimeFailure.exportFailed),
            String(
                describing:
                    AuthenticatedOtlpSpanExporterConfigurationError
                    .invalidEndpoint
            ),
            String(describing: flushResult),
        ].joined(separator: "\n")
        XCTAssertFalse(externallyVisible.contains(secret))
        XCTAssertFalse(String(describing: span()).contains(secret))
    }

    func testBearerNeverAppearsInCapturedProcessLogs() async throws {
        let secret = "captured-private-bearer-material"
        let provider = SequenceTokenProvider(tokens: [secret])
        let client = RecordingOtlpClient(results: [.failure])
        let exporter = exporter(provider: provider, client: client)

        let captured = try await captureStandardOutput {
            print("stdout capture sentinel")
            FileHandle.standardError.write(
                Data("stderr capture sentinel\n".utf8)
            )
            _ = await exporter.export(spans: [span()])
        }

        XCTAssertTrue(captured.contains("stdout capture sentinel"))
        XCTAssertTrue(captured.contains("stderr capture sentinel"))
        XCTAssertFalse(captured.contains(secret))
        XCTAssertFalse(captured.contains("Bearer \(secret)"))
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

private enum StandardOutputCaptureError: Error {
    case unavailable
}

private func captureStandardOutput(
    _ operation: () async -> Void
) async throws -> String {
    let pipe = Pipe()
    let savedStandardOutput = dup(STDOUT_FILENO)
    let savedStandardError = dup(STDERR_FILENO)
    guard savedStandardOutput >= 0, savedStandardError >= 0 else {
        if savedStandardOutput >= 0 { close(savedStandardOutput) }
        if savedStandardError >= 0 { close(savedStandardError) }
        throw StandardOutputCaptureError.unavailable
    }
    defer {
        close(savedStandardOutput)
        close(savedStandardError)
    }

    fflush(nil)
    guard
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0,
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO) >= 0
    else {
        throw StandardOutputCaptureError.unavailable
    }

    await operation()
    fflush(nil)
    guard
        dup2(savedStandardOutput, STDOUT_FILENO) >= 0,
        dup2(savedStandardError, STDERR_FILENO) >= 0
    else {
        throw StandardOutputCaptureError.unavailable
    }
    try pipe.fileHandleForWriting.close()
    let captured = pipe.fileHandleForReading.readDataToEndOfFile()
    try pipe.fileHandleForReading.close()
    return String(decoding: captured, as: UTF8.self)
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
    private var cached: String?
    private var refreshTask: Task<String, Never>?
    private(set) var refreshCount = 0

    init(token: String) {
        self.token = token
    }

    func currentToken() async throws(TelemetryTokenProviderError) -> String {
        if let cached { return cached }
        if let refreshTask { return await refreshTask.value }
        refreshCount += 1
        let token = self.token
        let task = Task {
            try? await Task.sleep(for: .milliseconds(50))
            return token
        }
        refreshTask = task
        let value = await task.value
        cached = value
        refreshTask = nil
        return value
    }

    func invalidateToken(ifCurrent token: String) {
        if cached == token { cached = nil }
    }
}

private final class SuspendedTokenProvider:
    TelemetryTokenProviding, @unchecked Sendable
{
    private let requested = DispatchSemaphore(value: 0)

    func currentToken() async throws(TelemetryTokenProviderError) -> String {
        requested.signal()
        try? await Task.sleep(for: .seconds(30))
        throw .cancelled
    }

    func invalidateToken(ifCurrent token: String) async {}

    func waitUntilRequested(timeout: TimeInterval) -> Bool {
        requested.wait(timeout: .now() + timeout) == .success
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
    private let firstRPCWillRegister = DispatchSemaphore(value: 0)
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
            firstRPCWillRegister.signal()
            await registrationGate.waitForRelease()
        }
        guard isActive() else { return .cancelled }
        lock.withLock { exports += 1 }
        return .success
    }

    func cancelActiveExports() {}

    func shutdown() {}
    func shutdown() async {}

    func waitUntilFirstRPCWillRegister(timeout: TimeInterval) -> Bool {
        firstRPCWillRegister.wait(timeout: .now() + timeout) == .success
    }

    func allowFirstRPCToRegister() async {
        await registrationGate.release()
    }
}

private actor AsyncShutdownGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
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
