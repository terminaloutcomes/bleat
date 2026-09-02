// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//
// The OTLP request construction in this file is derived from
// opentelemetry-swift 2.4.1's OtlpTraceExporter. Bleat owns the surrounding
// token and lifecycle handling because the upstream exporter fixes metadata
// when it is initialized.

import Foundation
@preconcurrency import OpenTelemetryProtocolExporterCommon
@preconcurrency import OpenTelemetrySdk
import SwiftProtobuf

func awaitTask<Result: Sendable>(
    _ task: Task<Result, Never>,
    until deadline: Date,
    timeoutResult: Result
) async -> Result {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0, !Task.isCancelled else {
        task.cancel()
        return timeoutResult
    }
    let result = AsyncTaskResult<Result>()
    let valueTask = Task {
        await result.resolve(task.value)
    }
    let timeoutTask = Task {
        try? await Task.sleep(for: .seconds(remaining))
        guard !Task.isCancelled else { return }
        task.cancel()
        await result.resolve(timeoutResult)
    }
    return await withTaskCancellationHandler {
        let value = await result.value()
        valueTask.cancel()
        timeoutTask.cancel()
        return value
    } onCancel: {
        task.cancel()
        valueTask.cancel()
        timeoutTask.cancel()
        Task { await result.resolve(timeoutResult) }
    }
}

private actor AsyncTaskResult<Result: Sendable> {
    private var continuation: CheckedContinuation<Result, Never>?
    private var resolvedValue: Result?
    private var isResolved = false

    func value() async -> Result {
        if isResolved, let resolvedValue {
            return resolvedValue
        }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ value: Result) {
        guard !isResolved else { return }
        isResolved = true
        resolvedValue = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

public enum AuthenticatedOtlpSpanExporterConfigurationError:
    Error, Equatable, Sendable
{
    case invalidEndpoint
    case invalidTimeout
}

public struct AuthenticatedOtlpSpanExporterConfiguration:
    Equatable, Sendable
{
    public let endpoint: URL
    public let timeout: TimeInterval

    public init(
        endpoint: URL,
        timeout: TimeInterval = 10
    ) throws(AuthenticatedOtlpSpanExporterConfigurationError) {
        let resolvedPort = endpoint.port ?? 443
        guard endpoint.scheme?.lowercased() == "https",
            let host = endpoint.host,
            !host.isEmpty,
            endpoint.user == nil,
            endpoint.password == nil,
            endpoint.query == nil,
            endpoint.fragment == nil,
            endpoint.path.isEmpty || endpoint.path == "/",
            (1...65_535).contains(resolvedPort)
        else {
            throw .invalidEndpoint
        }
        guard timeout.isFinite, timeout > 0 else {
            throw .invalidTimeout
        }
        self.endpoint = endpoint
        self.timeout = timeout
    }

    func signalEndpoint(_ signal: String) -> URL {
        endpoint.appendingPathComponent("v1").appendingPathComponent(signal)
    }
}

/// Signal exporters sharing one ephemeral URL session and token provider. The
/// session closes only after both SDK processors have shut down.
public struct AuthenticatedOtlpExporters: Sendable {
    public let spans: any RemoteTelemetryDownstreamSpanExporter
    public let logs: any RemoteTelemetryDownstreamLogExporter

    public init(
        configuration: AuthenticatedOtlpSpanExporterConfiguration,
        tokenProvider: any TelemetryTokenProviding
    ) {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        let invalidationWaiter = URLSessionInvalidationWaiter()
        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: invalidationWaiter,
            delegateQueue: nil
        )
        let closer = SharedOtlpTransportCloser {
            await invalidationWaiter.invalidateAndWait(for: session)
        }
        spans = AuthenticatedOtlpSpanExporter(
            tokenProvider: tokenProvider,
            client: HttpRemoteTelemetryOtlpClient(
                endpoint: configuration.signalEndpoint("traces"),
                transport: URLSessionRemoteTelemetryHTTPTransport(
                    session: session,
                    closeTransport: { await closer.release() }
                )
            ),
            timeout: configuration.timeout
        )
        logs = AuthenticatedOtlpLogExporter(
            tokenProvider: tokenProvider,
            client: HttpRemoteTelemetryOtlpLogClient(
                endpoint: configuration.signalEndpoint("logs"),
                transport: URLSessionRemoteTelemetryHTTPTransport(
                    session: session,
                    closeTransport: { await closer.release() }
                )
            ),
            timeout: configuration.timeout
        )
    }
}

private final class SharedOtlpTransportCloser: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingClients = 2
    private var closeAction: (@Sendable () async -> Void)?

    init(closeAction: @escaping @Sendable () async -> Void) {
        self.closeAction = closeAction
    }

    func release() async {
        let action: (@Sendable () async -> Void)? = lock.withLock {
            guard remainingClients > 0 else { return nil }
            remainingClients -= 1
            guard remainingClients == 0 else { return nil }
            let action = closeAction
            closeAction = nil
            return action
        }
        if let action { await action() }
    }
}

private final class URLSessionInvalidationWaiter: NSObject,
    URLSessionDelegate, @unchecked Sendable
{
    private let lock = NSLock()
    private var invalidationRequested = false
    private var isInvalidated = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func invalidateAndWait(for session: URLSession) async {
        await withCheckedContinuation { continuation in
            let action: Bool? = lock.withLock {
                guard !isInvalidated else { return nil }
                continuations.append(continuation)
                guard !invalidationRequested else { return false }
                invalidationRequested = true
                return true
            }
            guard let action else {
                continuation.resume()
                return
            }
            if action { session.invalidateAndCancel() }
        }
    }

    func urlSession(
        _ session: URLSession,
        didBecomeInvalidWithError error: (any Error)?
    ) {
        let continuations = lock.withLock {
            isInvalidated = true
            let continuations = self.continuations
            self.continuations.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }
}

enum RemoteTelemetryOtlpExportResult: Equatable, Sendable {
    case success
    case unauthenticated
    case rejected
    case cancelled
    case failure
}

protocol RemoteTelemetryOtlpClient: Sendable {
    func export(
        spans: [SpanData],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult
    func cancelActiveExports()
    @available(*, deprecated, message: "Use async shutdown()")
    func shutdown()
    func shutdown() async
}

public final class AuthenticatedOtlpSpanExporter:
    RemoteTelemetryDownstreamSpanExporter, @unchecked Sendable
{
    private let tokenProvider: any TelemetryTokenProviding
    private let client: any RemoteTelemetryOtlpClient
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var activeTokenRequests: [UInt64: @Sendable () -> Void] = [:]
    private var nextTokenRequestID: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isShutdown = false
    private var shutdownTask: Task<Void, Never>?

    public convenience init(
        configuration: AuthenticatedOtlpSpanExporterConfiguration,
        tokenProvider: any TelemetryTokenProviding
    ) {
        self.init(
            tokenProvider: tokenProvider,
            client: HttpRemoteTelemetryOtlpClient(
                configuration: configuration
            ),
            timeout: configuration.timeout
        )
    }

    init(
        tokenProvider: any TelemetryTokenProviding,
        client: any RemoteTelemetryOtlpClient,
        timeout: TimeInterval
    ) {
        self.tokenProvider = tokenProvider
        self.client = client
        self.timeout = timeout
    }

    @available(*, deprecated, message: "Synchronous OTLP export is prohibited")
    public func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        .failure
    }

    public func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) async -> SpanExporterResultCode {
        guard !spans.isEmpty else { return .success }
        let allowedDuration = min(explicitTimeout ?? timeout, timeout)
        guard allowedDuration > 0, !Task.isCancelled else { return .failure }
        let deadline = Date().addingTimeInterval(allowedDuration)
        guard let generation = currentExportGeneration() else {
            return .failure
        }

        guard
            case .success(let token) = await acquireTokenAsync(
                rejecting: nil,
                deadline: deadline,
                generation: generation
            )
        else {
            return .failure
        }
        let first = await exportAsync(
            spans: spans,
            token: token,
            deadline: deadline,
            generation: generation
        )
        guard first == .unauthenticated else {
            return first == .success ? .success : .failure
        }

        guard
            case .success(let refreshedToken) = await acquireTokenAsync(
                rejecting: token,
                deadline: deadline,
                generation: generation
            )
        else {
            return .failure
        }
        let retry = await exportAsync(
            spans: spans,
            token: refreshedToken,
            deadline: deadline,
            generation: generation
        )
        if retry == .unauthenticated {
            await invalidateTokenAsync(
                ifCurrent: refreshedToken,
                deadline: deadline,
                generation: generation
            )
        }
        return retry == .success ? .success : .failure
    }

    @available(*, deprecated, message: "Synchronous OTLP flush is prohibited")
    public func flush(
        explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        .failure
    }

    public func flush(
        explicitTimeout: TimeInterval?
    ) async -> SpanExporterResultCode {
        lock.withLock { isShutdown } ? .failure : .success
    }

    @available(*, deprecated, message: "Use async shutdown(explicitTimeout:)")
    public func shutdown(explicitTimeout: TimeInterval?) {
        if requestShutdown() { cancelActiveExports() }
    }

    public func shutdown(explicitTimeout: TimeInterval?) async {
        if requestShutdown() { cancelActiveExports() }
        let task = lock.withLock {
            if let shutdownTask { return shutdownTask }
            let client = self.client
            let task = Task { await client.shutdown() }
            shutdownTask = task
            return task
        }
        await task.value
    }

    private func requestShutdown() -> Bool {
        lock.withLock {
            guard !isShutdown else { return false }
            isShutdown = true
            return true
        }
    }

    public func cancelActiveExports() {
        let requests = lock.withLock {
            cancellationGeneration &+= 1
            let requests = Array(activeTokenRequests.values)
            activeTokenRequests.removeAll()
            return requests
        }
        for cancel in requests { cancel() }
        client.cancelActiveExports()
    }

    private func exportAsync(
        spans: [SpanData],
        token: String,
        deadline: Date,
        generation: UInt64
    ) async -> RemoteTelemetryOtlpExportResult {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, !Task.isCancelled,
            isCurrent(generation: generation)
        else {
            return .cancelled
        }
        return await client.export(
            spans: spans,
            metadata: [("authorization", "Bearer \(token)")],
            timeout: remaining,
            isActive: { [weak self] in
                !Task.isCancelled
                    && self?.isCurrent(generation: generation) == true
            }
        )
    }

    private func acquireTokenAsync(
        rejecting rejectedToken: String?,
        deadline: Date,
        generation: UInt64
    ) async -> BlockingTokenResult {
        guard !Task.isCancelled, isCurrent(generation: generation) else {
            return .failure
        }
        let tokenProvider = self.tokenProvider
        let task = Task<BlockingTokenResult, Never> {
            if let rejectedToken {
                await tokenProvider.invalidateToken(ifCurrent: rejectedToken)
            }
            guard !Task.isCancelled else { return .failure }
            do {
                return .success(try await tokenProvider.currentToken())
            } catch {
                return .failure
            }
        }
        guard
            let requestID = registerTokenTask(
                cancellation: { task.cancel() },
                generation: generation
            )
        else {
            task.cancel()
            return .failure
        }
        let result = await awaitTask(
            task,
            until: deadline,
            timeoutResult: .failure
        )
        removeTokenTask(requestID)
        guard !Task.isCancelled, isCurrent(generation: generation) else {
            return .failure
        }
        return result
    }

    private func invalidateTokenAsync(
        ifCurrent rejectedToken: String,
        deadline: Date,
        generation: UInt64
    ) async {
        guard !Task.isCancelled, isCurrent(generation: generation) else {
            return
        }
        let tokenProvider = self.tokenProvider
        let task = Task<Bool, Never> {
            await tokenProvider.invalidateToken(ifCurrent: rejectedToken)
            return !Task.isCancelled
        }
        guard
            let requestID = registerTokenTask(
                cancellation: { task.cancel() },
                generation: generation
            )
        else {
            task.cancel()
            return
        }
        _ = await awaitTask(task, until: deadline, timeoutResult: false)
        removeTokenTask(requestID)
    }

    private func registerTokenTask(
        cancellation: @escaping @Sendable () -> Void,
        generation: UInt64
    ) -> UInt64? {
        lock.withLock {
            guard !isShutdown, cancellationGeneration == generation else {
                return nil
            }
            nextTokenRequestID &+= 1
            activeTokenRequests[nextTokenRequestID] = cancellation
            return nextTokenRequestID
        }
    }

    private func removeTokenTask(_ requestID: UInt64) {
        lock.withLock { activeTokenRequests[requestID] = nil }
    }

    private func currentExportGeneration() -> UInt64? {
        lock.withLock {
            isShutdown ? nil : cancellationGeneration
        }
    }

    private func isCurrent(generation: UInt64) -> Bool {
        lock.withLock {
            !isShutdown && cancellationGeneration == generation
        }
    }
}

final class HttpRemoteTelemetryOtlpClient:
    RemoteTelemetryOtlpClient, @unchecked Sendable
{
    private let endpoint: URL
    private let transport: any RemoteTelemetryHTTPTransport

    init(configuration: AuthenticatedOtlpSpanExporterConfiguration) {
        endpoint = configuration.signalEndpoint("traces")
        transport = URLSessionRemoteTelemetryHTTPTransport()
    }

    init(
        endpoint: URL,
        transport: any RemoteTelemetryHTTPTransport
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func export(
        spans: [SpanData],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult {
        guard let urlRequest = request(spans: spans, metadata: metadata) else {
            return .failure
        }
        return await transport.send(
            urlRequest,
            timeout: timeout,
            isActive: isActive
        )
    }

    private func request(
        spans: [SpanData],
        metadata: [(String, String)]
    ) -> URLRequest? {
        let request =
            Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest
            .with {
                $0.resourceSpans = SpanAdapter.toProtoResourceSpans(
                    spanDataList: spans
                )
            }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "application/x-protobuf",
            forHTTPHeaderField: "Content-Type"
        )
        for (name, value) in metadata {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            urlRequest.httpBody = try request.serializedData()
        } catch {
            return nil
        }
        return urlRequest
    }

    func cancelActiveExports() { transport.cancelActiveRequests() }

    @available(*, deprecated, message: "Use async shutdown()")
    func shutdown() { transport.cancelActiveRequests() }

    func shutdown() async { await transport.shutdown() }
}

protocol RemoteTelemetryHTTPTransport: Sendable {
    func send(
        _ request: URLRequest,
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult
    func cancelActiveRequests()
    @available(*, deprecated, message: "Use async shutdown()")
    func shutdown()
    func shutdown() async
}

private struct ActiveHTTPRequest: Sendable {
    let cancel: @Sendable () -> Void
}

final class URLSessionRemoteTelemetryHTTPTransport:
    RemoteTelemetryHTTPTransport, @unchecked Sendable
{
    private let session: URLSession
    private let closeTransport: @Sendable () async -> Void
    private let lock = NSLock()
    private var activeTasks: [UInt64: ActiveHTTPRequest] = [:]
    private var nextTaskID: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isShutdown = false
    private var closeTask: Task<Void, Never>?

    convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let invalidationWaiter = URLSessionInvalidationWaiter()
        let session = URLSession(
            configuration: configuration,
            delegate: invalidationWaiter,
            delegateQueue: nil
        )
        self.init(
            session: session,
            closeTransport: {
                await invalidationWaiter.invalidateAndWait(for: session)
            }
        )
    }

    init(
        session: URLSession,
        closeTransport: @escaping @Sendable () async -> Void
    ) {
        self.session = session
        self.closeTransport = closeTransport
    }

    func send(
        _ request: URLRequest,
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult {
        guard timeout > 0, !Task.isCancelled, isActive() else {
            return .cancelled
        }
        let generation: UInt64? = lock.withLock {
            isShutdown ? nil : cancellationGeneration
        }
        guard let generation else { return .cancelled }

        var timedRequest = request
        timedRequest.timeoutInterval = timeout
        let session = self.session
        let requestTask = Task<RemoteTelemetryOtlpExportResult, Never> {
            do {
                let (_, response) = try await session.data(for: timedRequest)
                return RemoteTelemetryHTTPResponse.result(
                    response: response,
                    error: nil
                )
            } catch {
                return RemoteTelemetryHTTPResponse.result(
                    response: nil,
                    error: error
                )
            }
        }
        let taskID: UInt64? = lock.withLock {
            guard !isShutdown,
                cancellationGeneration == generation,
                isActive()
            else { return nil }
            nextTaskID &+= 1
            activeTasks[nextTaskID] = ActiveHTTPRequest {
                requestTask.cancel()
            }
            return nextTaskID
        }
        guard let taskID else {
            requestTask.cancel()
            return .cancelled
        }
        let result = await withTaskCancellationHandler {
            await requestTask.value
        } onCancel: {
            requestTask.cancel()
        }
        lock.withLock { activeTasks[taskID] = nil }
        guard !Task.isCancelled,
            lock.withLock({
                !isShutdown && cancellationGeneration == generation
            }), isActive()
        else {
            requestTask.cancel()
            return .cancelled
        }
        return result
    }

    func cancelActiveRequests() {
        let tasks = lock.withLock {
            cancellationGeneration &+= 1
            return Array(activeTasks.values)
        }
        for task in tasks { task.cancel() }
    }

    @available(*, deprecated, message: "Use async shutdown()")
    func shutdown() {
        if requestShutdown() { cancelActiveRequests() }
    }

    func shutdown() async {
        if requestShutdown() { cancelActiveRequests() }
        let task = lock.withLock {
            if let closeTask { return closeTask }
            let closeTransport = self.closeTransport
            let task = Task { await closeTransport() }
            closeTask = task
            return task
        }
        await task.value
    }

    private func requestShutdown() -> Bool {
        lock.withLock {
            guard !isShutdown else { return false }
            isShutdown = true
            return true
        }
    }
}

enum RemoteTelemetryHTTPResponse {
    static func result(
        response: URLResponse?,
        error: Error?
    ) -> RemoteTelemetryOtlpExportResult {
        if let urlError = error as? URLError,
            urlError.code == .cancelled || urlError.code == .timedOut
        {
            return .cancelled
        } else if error != nil {
            return .failure
        } else if let response = response as? HTTPURLResponse {
            switch response.statusCode {
            case 200..<300: return .success
            case 401: return .unauthenticated
            case 403: return .rejected
            default: return .failure
            }
        } else {
            return .failure
        }
    }
}

protocol RemoteTelemetryOtlpLogClient: Sendable {
    func export(
        logs: [ReadableLogRecord],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult
    func cancelActiveExports()
    @available(*, deprecated, message: "Use async shutdown()")
    func shutdown()
    func shutdown() async
}

/// Authenticated OTLP log transport with the same rotating-token and consent
/// cancellation behavior as the trace exporter.
public final class AuthenticatedOtlpLogExporter:
    RemoteTelemetryDownstreamLogExporter, @unchecked Sendable
{
    private let tokenProvider: any TelemetryTokenProviding
    private let client: any RemoteTelemetryOtlpLogClient
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var activeTokenRequests: [UInt64: @Sendable () -> Void] = [:]
    private var nextTokenRequestID: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isEnabled = true
    private var isShutdown = false
    private var shutdownTask: Task<Void, Never>?

    public convenience init(
        configuration: AuthenticatedOtlpSpanExporterConfiguration,
        tokenProvider: any TelemetryTokenProviding
    ) {
        self.init(
            tokenProvider: tokenProvider,
            client: HttpRemoteTelemetryOtlpLogClient(
                configuration: configuration
            ),
            timeout: configuration.timeout
        )
    }

    init(
        tokenProvider: any TelemetryTokenProviding,
        client: any RemoteTelemetryOtlpLogClient,
        timeout: TimeInterval
    ) {
        self.tokenProvider = tokenProvider
        self.client = client
        self.timeout = timeout
    }

    @available(*, deprecated, message: "Synchronous OTLP export is prohibited")
    public func export(
        logRecords: [ReadableLogRecord],
        explicitTimeout: TimeInterval?
    ) -> ExportResult {
        .failure
    }

    public func export(
        logRecords: [ReadableLogRecord],
        explicitTimeout: TimeInterval?
    ) async -> ExportResult {
        guard !logRecords.isEmpty else { return .success }
        let allowedDuration = min(explicitTimeout ?? timeout, timeout)
        guard allowedDuration > 0, !Task.isCancelled else { return .failure }
        let deadline = Date().addingTimeInterval(allowedDuration)
        guard let generation = currentExportGeneration() else {
            return .failure
        }
        guard
            case .success(let token) = await acquireTokenAsync(
                rejecting: nil,
                deadline: deadline,
                generation: generation
            )
        else {
            return .failure
        }
        let first = await exportAsync(
            logs: logRecords,
            token: token,
            deadline: deadline,
            generation: generation
        )
        guard first == .unauthenticated else {
            return first == .success ? .success : .failure
        }
        guard
            case .success(let refreshedToken) = await acquireTokenAsync(
                rejecting: token,
                deadline: deadline,
                generation: generation
            )
        else {
            return .failure
        }
        let retry = await exportAsync(
            logs: logRecords,
            token: refreshedToken,
            deadline: deadline,
            generation: generation
        )
        if retry == .unauthenticated {
            await invalidateTokenAsync(
                ifCurrent: refreshedToken,
                deadline: deadline,
                generation: generation
            )
        }
        return retry == .success ? .success : .failure
    }

    @available(*, deprecated, message: "Synchronous OTLP flush is prohibited")
    public func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        .failure
    }

    public func forceFlush(
        explicitTimeout: TimeInterval?
    ) async -> ExportResult {
        lock.withLock { isShutdown } ? .failure : .success
    }

    @available(*, deprecated, message: "Use async shutdown(explicitTimeout:)")
    public func shutdown(explicitTimeout: TimeInterval?) {
        if requestShutdown() { cancelActiveExports() }
    }

    public func shutdown(explicitTimeout: TimeInterval?) async {
        if requestShutdown() { cancelActiveExports() }
        let task = lock.withLock {
            if let shutdownTask { return shutdownTask }
            let client = self.client
            let task = Task { await client.shutdown() }
            shutdownTask = task
            return task
        }
        await task.value
    }

    private func requestShutdown() -> Bool {
        lock.withLock {
            guard !isShutdown else { return false }
            isShutdown = true
            return true
        }
    }

    public func cancelActiveExports() {
        let requests = lock.withLock {
            cancellationGeneration &+= 1
            let requests = Array(activeTokenRequests.values)
            activeTokenRequests.removeAll()
            return requests
        }
        for cancel in requests { cancel() }
        client.cancelActiveExports()
    }

    public func disable() {
        lock.withLock { isEnabled = false }
        cancelActiveExports()
    }

    private func exportAsync(
        logs: [ReadableLogRecord],
        token: String,
        deadline: Date,
        generation: UInt64
    ) async -> RemoteTelemetryOtlpExportResult {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, !Task.isCancelled,
            isCurrent(generation: generation)
        else {
            return .cancelled
        }
        return await client.export(
            logs: logs,
            metadata: [("authorization", "Bearer \(token)")],
            timeout: remaining,
            isActive: { [weak self] in
                !Task.isCancelled
                    && self?.isCurrent(generation: generation) == true
            }
        )
    }

    private func acquireTokenAsync(
        rejecting rejectedToken: String?,
        deadline: Date,
        generation: UInt64
    ) async -> BlockingTokenResult {
        guard !Task.isCancelled, isCurrent(generation: generation) else {
            return .failure
        }
        let tokenProvider = self.tokenProvider
        let task = Task<BlockingTokenResult, Never> {
            if let rejectedToken {
                await tokenProvider.invalidateToken(ifCurrent: rejectedToken)
            }
            guard !Task.isCancelled else { return .failure }
            do {
                return .success(try await tokenProvider.currentToken())
            } catch {
                return .failure
            }
        }
        guard
            let requestID = registerTokenTask(
                cancellation: { task.cancel() },
                generation: generation
            )
        else {
            task.cancel()
            return .failure
        }
        let result = await awaitTask(
            task,
            until: deadline,
            timeoutResult: .failure
        )
        removeTokenTask(requestID)
        guard !Task.isCancelled, isCurrent(generation: generation) else {
            return .failure
        }
        return result
    }

    private func invalidateTokenAsync(
        ifCurrent rejectedToken: String,
        deadline: Date,
        generation: UInt64
    ) async {
        guard !Task.isCancelled, isCurrent(generation: generation) else {
            return
        }
        let tokenProvider = self.tokenProvider
        let task = Task<Bool, Never> {
            await tokenProvider.invalidateToken(ifCurrent: rejectedToken)
            return !Task.isCancelled
        }
        guard
            let requestID = registerTokenTask(
                cancellation: { task.cancel() },
                generation: generation
            )
        else {
            task.cancel()
            return
        }
        _ = await awaitTask(task, until: deadline, timeoutResult: false)
        removeTokenTask(requestID)
    }

    private func registerTokenTask(
        cancellation: @escaping @Sendable () -> Void,
        generation: UInt64
    ) -> UInt64? {
        lock.withLock {
            guard !isShutdown, isEnabled,
                cancellationGeneration == generation
            else {
                return nil
            }
            nextTokenRequestID &+= 1
            activeTokenRequests[nextTokenRequestID] = cancellation
            return nextTokenRequestID
        }
    }

    private func removeTokenTask(_ requestID: UInt64) {
        lock.withLock { activeTokenRequests[requestID] = nil }
    }

    private func currentExportGeneration() -> UInt64? {
        lock.withLock {
            isShutdown || !isEnabled ? nil : cancellationGeneration
        }
    }

    private func isCurrent(generation: UInt64) -> Bool {
        lock.withLock {
            !isShutdown && isEnabled && cancellationGeneration == generation
        }
    }
}

final class HttpRemoteTelemetryOtlpLogClient:
    RemoteTelemetryOtlpLogClient, @unchecked Sendable
{
    private let endpoint: URL
    private let transport: any RemoteTelemetryHTTPTransport

    init(configuration: AuthenticatedOtlpSpanExporterConfiguration) {
        endpoint = configuration.signalEndpoint("logs")
        transport = URLSessionRemoteTelemetryHTTPTransport()
    }

    init(
        endpoint: URL,
        transport: any RemoteTelemetryHTTPTransport
    ) {
        self.endpoint = endpoint
        self.transport = transport
    }

    func export(
        logs: [ReadableLogRecord],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) async -> RemoteTelemetryOtlpExportResult {
        guard let urlRequest = request(logs: logs, metadata: metadata) else {
            return .failure
        }
        return await transport.send(
            urlRequest,
            timeout: timeout,
            isActive: isActive
        )
    }

    private func request(
        logs: [ReadableLogRecord],
        metadata: [(String, String)]
    ) -> URLRequest? {
        let request =
            Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest
            .with {
                $0.resourceLogs =
                    LogRecordAdapter
                    .toProtoResourceRecordLog(logRecordList: logs)
            }
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(
            "application/x-protobuf",
            forHTTPHeaderField: "Content-Type"
        )
        for (name, value) in metadata {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            urlRequest.httpBody = try request.serializedData()
        } catch {
            return nil
        }
        return urlRequest
    }

    func cancelActiveExports() { transport.cancelActiveRequests() }

    @available(*, deprecated, message: "Use async shutdown()")
    func shutdown() { transport.cancelActiveRequests() }

    func shutdown() async { await transport.shutdown() }
}

private enum BlockingTokenResult: Equatable, Sendable {
    case success(String)
    case failure
}
