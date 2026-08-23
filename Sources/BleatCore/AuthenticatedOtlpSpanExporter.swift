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
        let session = URLSession(configuration: sessionConfiguration)
        let closer = SharedOtlpTransportCloser {
            session.invalidateAndCancel()
        }
        spans = AuthenticatedOtlpSpanExporter(
            tokenProvider: tokenProvider,
            client: HttpRemoteTelemetryOtlpClient(
                endpoint: configuration.signalEndpoint("traces"),
                transport: URLSessionRemoteTelemetryHTTPTransport(
                    session: session,
                    closeTransport: { closer.release() }
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
                    closeTransport: { closer.release() }
                )
            ),
            timeout: configuration.timeout
        )
    }
}

private final class SharedOtlpTransportCloser: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingClients = 2
    private var closeAction: (@Sendable () -> Void)?

    init(closeAction: @escaping @Sendable () -> Void) {
        self.closeAction = closeAction
    }

    func release() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            guard remainingClients > 0 else { return nil }
            remainingClients -= 1
            guard remainingClients == 0 else { return nil }
            let action = closeAction
            closeAction = nil
            return action
        }
        action?()
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
    ) -> RemoteTelemetryOtlpExportResult
    func cancelActiveExports()
    func shutdown()
}

public final class AuthenticatedOtlpSpanExporter:
    RemoteTelemetryDownstreamSpanExporter, @unchecked Sendable
{
    private let tokenProvider: any TelemetryTokenProviding
    private let client: any RemoteTelemetryOtlpClient
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var activeTokenRequests: [UInt64: BlockingTokenRequest] = [:]
    private var nextTokenRequestID: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isShutdown = false

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

    public func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        guard !spans.isEmpty else { return .success }
        let allowedDuration = min(explicitTimeout ?? timeout, timeout)
        guard allowedDuration > 0 else { return .failure }
        let deadline = Date().addingTimeInterval(allowedDuration)
        guard let generation = currentExportGeneration() else {
            return .failure
        }

        guard
            case .success(let token) = acquireToken(
                rejecting: nil,
                deadline: deadline,
                generation: generation
            )
        else {
            return .failure
        }
        let first = export(
            spans: spans,
            token: token,
            deadline: deadline,
            generation: generation
        )
        guard first == .unauthenticated else {
            return first == .success ? .success : .failure
        }

        guard
            case .success(let refreshedToken) = acquireToken(
                rejecting: token,
                deadline: deadline,
                generation: generation
            )
        else {
            return .failure
        }
        let retry = export(
            spans: spans,
            token: refreshedToken,
            deadline: deadline,
            generation: generation
        )
        if retry == .unauthenticated {
            invalidateToken(
                ifCurrent: refreshedToken,
                deadline: deadline,
                generation: generation
            )
        }
        return retry == .success ? .success : .failure
    }

    public func flush(
        explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        lock.withLock { isShutdown } ? .failure : .success
    }

    public func shutdown(explicitTimeout: TimeInterval?) {
        let shouldShutdown = lock.withLock {
            guard !isShutdown else { return false }
            isShutdown = true
            return true
        }
        guard shouldShutdown else { return }
        cancelActiveExports()
        client.shutdown()
    }

    public func cancelActiveExports() {
        let requests = lock.withLock {
            cancellationGeneration &+= 1
            let requests = Array(activeTokenRequests.values)
            activeTokenRequests.removeAll()
            return requests
        }
        for request in requests {
            request.cancel()
        }
        client.cancelActiveExports()
    }

    private func export(
        spans: [SpanData],
        token: String,
        deadline: Date,
        generation: UInt64
    ) -> RemoteTelemetryOtlpExportResult {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, isCurrent(generation: generation) else {
            return .cancelled
        }
        return client.export(
            spans: spans,
            metadata: [("authorization", "Bearer \(token)")],
            timeout: remaining,
            isActive: { [weak self] in
                self?.isCurrent(generation: generation) == true
            }
        )
    }

    private func acquireToken(
        rejecting rejectedToken: String?,
        deadline: Date,
        generation: UInt64
    ) -> BlockingTokenResult {
        let request = BlockingTokenRequest()
        let requestID: UInt64? = lock.withLock {
            guard
                !isShutdown,
                cancellationGeneration == generation
            else { return nil }
            nextTokenRequestID &+= 1
            activeTokenRequests[nextTokenRequestID] = request
            return nextTokenRequestID
        }
        guard let requestID else { return .failure }

        let task = Task { [tokenProvider] in
            if let rejectedToken {
                await tokenProvider.invalidateToken(
                    ifCurrent: rejectedToken
                )
            }
            do {
                request.complete(
                    .success(try await tokenProvider.currentToken())
                )
            } catch {
                request.complete(.failure)
            }
        }
        request.setCancellation {
            task.cancel()
        }
        let result = request.wait(until: deadline)
        lock.withLock {
            activeTokenRequests[requestID] = nil
        }
        if result == nil {
            request.cancel()
        }
        guard isCurrent(generation: generation) else { return .failure }
        return result ?? .failure
    }

    private func invalidateToken(
        ifCurrent rejectedToken: String,
        deadline: Date,
        generation: UInt64
    ) {
        let request = BlockingTokenRequest()
        let requestID: UInt64? = lock.withLock {
            guard
                !isShutdown,
                cancellationGeneration == generation
            else { return nil }
            nextTokenRequestID &+= 1
            activeTokenRequests[nextTokenRequestID] = request
            return nextTokenRequestID
        }
        guard let requestID else { return }

        let task = Task { [tokenProvider] in
            await tokenProvider.invalidateToken(ifCurrent: rejectedToken)
            request.complete(.completed)
        }
        request.setCancellation {
            task.cancel()
        }
        let result = request.wait(until: deadline)
        lock.withLock {
            activeTokenRequests[requestID] = nil
        }
        if result == nil {
            request.cancel()
        }
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
    ) -> RemoteTelemetryOtlpExportResult {
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
            return .failure
        }
        return transport.send(
            urlRequest,
            timeout: timeout,
            isActive: isActive
        )
    }

    func cancelActiveExports() { transport.cancelActiveRequests() }

    func shutdown() { transport.shutdown() }
}

protocol RemoteTelemetryHTTPTransport: Sendable {
    func send(
        _ request: URLRequest,
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) -> RemoteTelemetryOtlpExportResult
    func cancelActiveRequests()
    func shutdown()
}

final class URLSessionRemoteTelemetryHTTPTransport:
    RemoteTelemetryHTTPTransport, @unchecked Sendable
{
    private let session: URLSession
    private let closeTransport: @Sendable () -> Void
    private let lock = NSLock()
    private var activeTasks: [UInt64: URLSessionDataTask] = [:]
    private var nextTaskID: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isShutdown = false

    convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        self.init(
            session: session,
            closeTransport: { session.invalidateAndCancel() }
        )
    }

    init(
        session: URLSession,
        closeTransport: @escaping @Sendable () -> Void
    ) {
        self.session = session
        self.closeTransport = closeTransport
    }

    func send(
        _ request: URLRequest,
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) -> RemoteTelemetryOtlpExportResult {
        guard timeout > 0, isActive() else { return .cancelled }
        let generation: UInt64? = lock.withLock {
            isShutdown ? nil : cancellationGeneration
        }
        guard let generation else { return .cancelled }

        var timedRequest = request
        timedRequest.timeoutInterval = timeout
        let completion = HTTPRequestCompletion()
        let task = session.dataTask(with: timedRequest) {
            _, response, error in
            completion.complete(response: response, error: error)
        }
        let taskID: UInt64? = lock.withLock {
            guard !isShutdown,
                cancellationGeneration == generation,
                isActive()
            else { return nil }
            nextTaskID &+= 1
            activeTasks[nextTaskID] = task
            return nextTaskID
        }
        guard let taskID else {
            task.cancel()
            return .cancelled
        }
        task.resume()
        let result = completion.wait(timeout: timeout)
        lock.withLock { activeTasks[taskID] = nil }
        guard
            lock.withLock({
                !isShutdown && cancellationGeneration == generation
            }), isActive()
        else {
            task.cancel()
            return .cancelled
        }
        guard let result else {
            task.cancel()
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

    func shutdown() {
        let shouldClose = lock.withLock {
            guard !isShutdown else { return false }
            isShutdown = true
            return true
        }
        guard shouldClose else { return }
        cancelActiveRequests()
        closeTransport()
    }
}

private final class HTTPRequestCompletion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: RemoteTelemetryOtlpExportResult?

    func complete(response: URLResponse?, error: Error?) {
        let mapped = RemoteTelemetryHTTPResponse.result(
            response: response,
            error: error
        )
        lock.withLock { result = mapped }
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> RemoteTelemetryOtlpExportResult? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            return nil
        }
        return lock.withLock { result }
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
    ) -> RemoteTelemetryOtlpExportResult
    func cancelActiveExports()
    func shutdown()
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
    private var activeTokenRequests: [UInt64: BlockingTokenRequest] = [:]
    private var nextTokenRequestID: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isEnabled = true
    private var isShutdown = false

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

    public func export(
        logRecords: [ReadableLogRecord],
        explicitTimeout: TimeInterval?
    ) -> ExportResult {
        guard !logRecords.isEmpty else { return .success }
        let allowedDuration = min(explicitTimeout ?? timeout, timeout)
        guard allowedDuration > 0 else { return .failure }
        let deadline = Date().addingTimeInterval(allowedDuration)
        guard let generation = currentExportGeneration() else {
            return .failure
        }
        guard
            case .success(let token) = acquireToken(
                rejecting: nil,
                deadline: deadline,
                generation: generation
            )
        else {
            return .failure
        }
        let first = export(
            logs: logRecords,
            token: token,
            deadline: deadline,
            generation: generation
        )
        guard first == .unauthenticated else {
            return first == .success ? .success : .failure
        }
        guard
            case .success(let refreshedToken) = acquireToken(
                rejecting: token,
                deadline: deadline,
                generation: generation
            )
        else {
            return .failure
        }
        let retry = export(
            logs: logRecords,
            token: refreshedToken,
            deadline: deadline,
            generation: generation
        )
        if retry == .unauthenticated {
            invalidateToken(
                ifCurrent: refreshedToken,
                deadline: deadline,
                generation: generation
            )
        }
        return retry == .success ? .success : .failure
    }

    public func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        lock.withLock { isShutdown } ? .failure : .success
    }

    public func shutdown(explicitTimeout: TimeInterval?) {
        let shouldShutdown = lock.withLock {
            guard !isShutdown else { return false }
            isShutdown = true
            return true
        }
        guard shouldShutdown else { return }
        cancelActiveExports()
        client.shutdown()
    }

    public func cancelActiveExports() {
        let requests = lock.withLock {
            cancellationGeneration &+= 1
            let requests = Array(activeTokenRequests.values)
            activeTokenRequests.removeAll()
            return requests
        }
        for request in requests {
            request.cancel()
        }
        client.cancelActiveExports()
    }

    public func disable() {
        lock.withLock { isEnabled = false }
        cancelActiveExports()
    }

    private func export(
        logs: [ReadableLogRecord],
        token: String,
        deadline: Date,
        generation: UInt64
    ) -> RemoteTelemetryOtlpExportResult {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0, isCurrent(generation: generation) else {
            return .cancelled
        }
        return client.export(
            logs: logs,
            metadata: [("authorization", "Bearer \(token)")],
            timeout: remaining,
            isActive: { [weak self] in
                self?.isCurrent(generation: generation) == true
            }
        )
    }

    private func acquireToken(
        rejecting rejectedToken: String?,
        deadline: Date,
        generation: UInt64
    ) -> BlockingTokenResult {
        let request = BlockingTokenRequest()
        let requestID: UInt64? = lock.withLock {
            guard !isShutdown, cancellationGeneration == generation else {
                return nil
            }
            nextTokenRequestID &+= 1
            activeTokenRequests[nextTokenRequestID] = request
            return nextTokenRequestID
        }
        guard let requestID else { return .failure }
        let task = Task { [tokenProvider] in
            if let rejectedToken {
                await tokenProvider.invalidateToken(ifCurrent: rejectedToken)
            }
            do {
                request.complete(
                    .success(try await tokenProvider.currentToken())
                )
            } catch {
                request.complete(.failure)
            }
        }
        request.setCancellation { task.cancel() }
        let result = request.wait(until: deadline)
        lock.withLock { activeTokenRequests[requestID] = nil }
        if result == nil { request.cancel() }
        guard isCurrent(generation: generation) else { return .failure }
        return result ?? .failure
    }

    private func invalidateToken(
        ifCurrent rejectedToken: String,
        deadline: Date,
        generation: UInt64
    ) {
        let request = BlockingTokenRequest()
        let requestID: UInt64? = lock.withLock {
            guard !isShutdown, cancellationGeneration == generation else {
                return nil
            }
            nextTokenRequestID &+= 1
            activeTokenRequests[nextTokenRequestID] = request
            return nextTokenRequestID
        }
        guard let requestID else { return }
        let task = Task { [tokenProvider] in
            await tokenProvider.invalidateToken(ifCurrent: rejectedToken)
            request.complete(.completed)
        }
        request.setCancellation { task.cancel() }
        let result = request.wait(until: deadline)
        lock.withLock { activeTokenRequests[requestID] = nil }
        if result == nil { request.cancel() }
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
    ) -> RemoteTelemetryOtlpExportResult {
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
            return .failure
        }
        return transport.send(
            urlRequest,
            timeout: timeout,
            isActive: isActive
        )
    }

    func cancelActiveExports() { transport.cancelActiveRequests() }

    func shutdown() { transport.shutdown() }
}

private enum BlockingTokenResult: Equatable, Sendable {
    case success(String)
    case completed
    case failure
}

private final class BlockingTokenRequest: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: BlockingTokenResult?
    private var cancellation: (@Sendable () -> Void)?
    private var isCancelled = false

    func setCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        let shouldCancel = condition.withLock {
            if isCancelled {
                return true
            }
            self.cancellation = cancellation
            return false
        }
        if shouldCancel {
            cancellation()
        }
    }

    func complete(_ result: BlockingTokenResult) {
        condition.lock()
        guard self.result == nil else {
            condition.unlock()
            return
        }
        self.result = result
        condition.broadcast()
        condition.unlock()
    }

    func cancel() {
        let cancellation: (@Sendable () -> Void)? = condition.withLock {
            guard result == nil else { return nil }
            isCancelled = true
            result = .failure
            condition.broadcast()
            return self.cancellation
        }
        cancellation?()
    }

    func wait(until deadline: Date) -> BlockingTokenResult? {
        condition.lock()
        defer { condition.unlock() }
        while result == nil, condition.wait(until: deadline) {}
        return result
    }
}

extension NSCondition {
    fileprivate func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
