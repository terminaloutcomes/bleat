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

    func testEachExportUsesExactlyOneCurrentBearerValue() {
        let provider = SequenceTokenProvider(tokens: ["first", "second"])
        let client = RecordingOtlpClient(results: [.success, .success])
        let exporter = exporter(provider: provider, client: client)

        XCTAssertEqual(exporter.export(spans: [span()]), .success)
        XCTAssertEqual(exporter.export(spans: [span()]), .success)

        XCTAssertEqual(
            client.recordedMetadata.map {
                $0.map { "\($0.0)=\($0.1)" }
            },
            [
                ["authorization=Bearer first"],
                ["authorization=Bearer second"],
            ]
        )
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

        XCTAssertEqual(exporter.export(spans: [span()]), .success)
        XCTAssertEqual(client.exportCount, 2)
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

        XCTAssertEqual(exporter.export(spans: [span()]), .failure)
        XCTAssertEqual(client.exportCount, 2)
        let requestCount = await provider.requestCount
        let invalidatedTokens = await provider.invalidatedTokens
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(invalidatedTokens, ["one", "two"])
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

            XCTAssertEqual(exporter.export(spans: [span()]), .failure)
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
                    exporter.export(spans: [span]) == .success
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

    func testCancellationUnblocksTokenWaitAndShutsTransportOnce() {
        let provider = SuspendedTokenProvider()
        let client = RecordingOtlpClient(results: [])
        let exporter = exporter(provider: provider, client: client)
        let finished = expectation(description: "export returned")
        let result = LockedExportResult()
        let span = span()

        DispatchQueue.global().async {
            result.value = exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
            finished.fulfill()
        }
        XCTAssertTrue(provider.waitUntilRequested(timeout: 2))
        exporter.cancelActiveExports()
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(result.value, .failure)

        exporter.shutdown()
        exporter.shutdown()
        XCTAssertEqual(client.cancelCount, 2)
        XCTAssertEqual(client.shutdownCount, 1)
    }

    func testCancellationAfterTokenCompletionPreventsRPCAndAllowsLaterExport()
        async
    {
        let provider = SequenceTokenProvider(tokens: ["cancelled", "current"])
        let client = GatedRegistrationOtlpClient()
        let exporter = exporter(provider: provider, client: client)
        let finished = expectation(description: "cancelled export returned")
        let result = LockedExportResult()
        let span = span()

        DispatchQueue.global().async {
            result.value = exporter.export(
                spans: [span],
                explicitTimeout: 30
            )
            finished.fulfill()
        }
        XCTAssertTrue(client.waitUntilFirstRPCWillRegister(timeout: 2))
        exporter.cancelActiveExports()
        client.allowFirstRPCToRegister()
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(result.value, .failure)
        XCTAssertEqual(client.exportCount, 0)
        XCTAssertEqual(exporter.export(spans: [span]), .success)
        XCTAssertEqual(client.exportCount, 1)
        let requestCount = await provider.requestCount
        XCTAssertEqual(requestCount, 2)
    }

    func testGrpcCancellationBarrierPreventsPausedStaleCallCreation() throws {
        let reachedCallBoundary = DispatchSemaphore(value: 0)
        let resumeCallAttempt = DispatchSemaphore(value: 0)
        let createdCallCount = LockedCounter()
        let result = LockedOtlpExportResult()
        let finished = expectation(description: "gRPC export returned")
        let span = span()
        let configuration = try AuthenticatedOtlpSpanExporterConfiguration(
            endpoint: XCTUnwrap(URL(string: "https://localhost:4317"))
        )
        let client = GrpcRemoteTelemetryOtlpClient(
            configuration: configuration,
            willAttemptCallCreation: {
                reachedCallBoundary.signal()
                resumeCallAttempt.wait()
            },
            didCreateCall: {
                createdCallCount.increment()
            }
        )

        DispatchQueue.global().async {
            result.value = client.export(
                spans: [span],
                metadata: [("authorization", "Bearer test")],
                timeout: 30,
                isActive: { true }
            )
            finished.fulfill()
        }
        XCTAssertEqual(
            reachedCallBoundary.wait(timeout: .now() + 2),
            .success
        )

        client.cancelActiveExports()
        resumeCallAttempt.signal()
        wait(for: [finished], timeout: 2)

        XCTAssertEqual(result.value, .cancelled)
        XCTAssertEqual(createdCallCount.value, 0)
        client.shutdown()
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

        XCTAssertEqual(exporter.export(spans: [span()]), .failure)
        XCTAssertEqual(client.exportCount, 1)
        var requestCount = await provider.requestCount
        var invalidatedTokens = await provider.invalidatedTokens
        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(invalidatedTokens.isEmpty)

        XCTAssertEqual(exporter.export(spans: [span()]), .success)
        XCTAssertEqual(client.exportCount, 2)
        requestCount = await provider.requestCount
        invalidatedTokens = await provider.invalidatedTokens
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(invalidatedTokens.isEmpty)
    }

    func testBearerNeverAppearsInExporterOrFailureDescriptions() {
        let secret = "private-bearer-material"
        let provider = SequenceTokenProvider(tokens: [secret])
        let client = RecordingOtlpClient(results: [.failure])
        let exporter = exporter(provider: provider, client: client)

        XCTAssertEqual(exporter.export(spans: [span()]), .failure)
        let externallyVisible = [
            String(describing: RemoteTelemetryRuntimeFailure.exportFailed),
            String(
                describing:
                    AuthenticatedOtlpSpanExporterConfigurationError
                    .invalidEndpoint
            ),
            String(describing: exporter.flush()),
        ].joined(separator: "\n")
        XCTAssertFalse(externallyVisible.contains(secret))
        XCTAssertFalse(String(describing: span()).contains(secret))
    }

    func testBearerNeverAppearsInCapturedProcessLogs() throws {
        let secret = "captured-private-bearer-material"
        let provider = SequenceTokenProvider(tokens: [secret])
        let client = RecordingOtlpClient(results: [.failure])
        let exporter = exporter(provider: provider, client: client)

        let captured = try captureStandardOutput {
            print("stdout capture sentinel")
            FileHandle.standardError.write(
                Data("stderr capture sentinel\n".utf8)
            )
            _ = exporter.export(spans: [span()])
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
}

private let standardOutputCaptureLock = NSLock()

private enum StandardOutputCaptureError: Error {
    case unavailable
}

private func captureStandardOutput(
    _ operation: () -> Void
) throws -> String {
    standardOutputCaptureLock.lock()
    defer { standardOutputCaptureLock.unlock() }

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

    operation()
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

private final class RecordingOtlpClient:
    RemoteTelemetryOtlpClient, @unchecked Sendable
{
    private let lock = NSLock()
    private var results: [RemoteTelemetryOtlpExportResult]
    private var metadata: [[(String, String)]] = []
    private var cancellations = 0
    private var shutdowns = 0

    init(results: [RemoteTelemetryOtlpExportResult]) {
        self.results = results
    }

    var recordedMetadata: [[(String, String)]] {
        lock.withLock { metadata }
    }

    var exportCount: Int { lock.withLock { metadata.count } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var shutdownCount: Int { lock.withLock { shutdowns } }

    func export(
        spans: [SpanData],
        metadata: [(String, String)],
        timeout: TimeInterval,
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
        lock.withLock { shutdowns += 1 }
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
}

private final class GatedRegistrationOtlpClient:
    RemoteTelemetryOtlpClient, @unchecked Sendable
{
    private let lock = NSLock()
    private let firstRPCWillRegister = DispatchSemaphore(value: 0)
    private let allowFirstRPCRegistration = DispatchSemaphore(value: 0)
    private var attempts = 0
    private var exports = 0

    var exportCount: Int { lock.withLock { exports } }

    func export(
        spans: [SpanData],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) -> RemoteTelemetryOtlpExportResult {
        let attempt = lock.withLock {
            attempts += 1
            return attempts
        }
        if attempt == 1 {
            firstRPCWillRegister.signal()
            allowFirstRPCRegistration.wait()
        }
        guard isActive() else { return .cancelled }
        lock.withLock { exports += 1 }
        return .success
    }

    func cancelActiveExports() {}

    func shutdown() {}

    func waitUntilFirstRPCWillRegister(timeout: TimeInterval) -> Bool {
        firstRPCWillRegister.wait(timeout: .now() + timeout) == .success
    }

    func allowFirstRPCToRegister() {
        allowFirstRPCRegistration.signal()
    }
}

private final class LockedExportResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: SpanExporterResultCode?

    var value: SpanExporterResultCode? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LockedOtlpExportResult: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: RemoteTelemetryOtlpExportResult?

    var value: RemoteTelemetryOtlpExportResult? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
