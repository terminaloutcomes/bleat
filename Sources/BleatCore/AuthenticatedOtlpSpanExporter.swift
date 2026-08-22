// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
//
// The OTLP request construction in this file is derived from
// opentelemetry-swift 2.4.1's OtlpTraceExporter. Bleat owns the surrounding
// token and lifecycle handling because the upstream exporter fixes metadata
// when it is initialized.

import Foundation
@preconcurrency import GRPC
@preconcurrency import OpenTelemetryProtocolExporterCommon
@preconcurrency import OpenTelemetryProtocolExporterGrpc
@preconcurrency import OpenTelemetrySdk

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

    let host: String
    let port: Int

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
        self.host = host
        self.port = resolvedPort
    }
}

/// Signal exporters sharing one TLS/gRPC channel and token provider. The
/// channel closes only after both SDK processors have shut down.
public struct AuthenticatedOtlpExporters: Sendable {
    public let spans: any RemoteTelemetryDownstreamSpanExporter
    public let logs: any RemoteTelemetryDownstreamLogExporter

    public init(
        configuration: AuthenticatedOtlpSpanExporterConfiguration,
        tokenProvider: any TelemetryTokenProviding
    ) {
        let group = PlatformSupport.makeEventLoopGroup(
            loopCount: 1,
            networkPreference: .best
        )
        let channel = ClientConnection.usingPlatformAppropriateTLS(
            for: group
        ).connect(host: configuration.host, port: configuration.port)
        let closer = SharedOtlpTransportCloser {
            channel.close().whenComplete { _ in
                group.shutdownGracefully { _ in }
            }
        }
        spans = AuthenticatedOtlpSpanExporter(
            tokenProvider: tokenProvider,
            client: GrpcRemoteTelemetryOtlpClient(
                channel: channel,
                closeTransport: { closer.release() }
            ),
            timeout: configuration.timeout
        )
        logs = AuthenticatedOtlpLogExporter(
            tokenProvider: tokenProvider,
            client: GrpcRemoteTelemetryOtlpLogClient(
                channel: channel,
                closeTransport: { closer.release() }
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
            client: GrpcRemoteTelemetryOtlpClient(
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

final class GrpcRemoteTelemetryOtlpClient:
    RemoteTelemetryOtlpClient, @unchecked Sendable
{
    private typealias TraceCall = UnaryCall<
        Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest,
        Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse
    >

    private let channel: ClientConnection
    private let traceClient:
        Opentelemetry_Proto_Collector_Trace_V1_TraceServiceNIOClient
    private let closeTransport: @Sendable () -> Void
    private let willAttemptCallCreation: @Sendable () -> Void
    private let didCreateCall: @Sendable () -> Void
    private let lock = NSLock()
    private var activeCalls: [UInt64: TraceCall] = [:]
    private var nextCallID: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isShutdown = false

    init(
        configuration: AuthenticatedOtlpSpanExporterConfiguration,
        willAttemptCallCreation: @escaping @Sendable () -> Void = {},
        didCreateCall: @escaping @Sendable () -> Void = {}
    ) {
        let group = PlatformSupport.makeEventLoopGroup(
            loopCount: 1,
            networkPreference: .best
        )
        let channel = ClientConnection.usingPlatformAppropriateTLS(
            for: group
        ).connect(
            host: configuration.host,
            port: configuration.port
        )
        self.channel = channel
        traceClient = .init(channel: channel)
        closeTransport = {
            channel.close().whenComplete { _ in
                group.shutdownGracefully { _ in }
            }
        }
        self.willAttemptCallCreation = willAttemptCallCreation
        self.didCreateCall = didCreateCall
    }

    init(
        channel: ClientConnection,
        closeTransport: @escaping @Sendable () -> Void,
        willAttemptCallCreation: @escaping @Sendable () -> Void = {},
        didCreateCall: @escaping @Sendable () -> Void = {}
    ) {
        self.channel = channel
        traceClient = .init(channel: channel)
        self.closeTransport = closeTransport
        self.willAttemptCallCreation = willAttemptCallCreation
        self.didCreateCall = didCreateCall
    }

    func export(
        spans: [SpanData],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) -> RemoteTelemetryOtlpExportResult {
        guard timeout > 0, isActive() else { return .cancelled }
        let generation: UInt64? = lock.withLock {
            isShutdown ? nil : cancellationGeneration
        }
        guard let generation else { return .cancelled }
        let request =
            Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest
            .with {
                $0.resourceSpans = SpanAdapter.toProtoResourceSpans(
                    spanDataList: spans
                )
            }
        var options = CallOptions()
        for (name, value) in metadata {
            options.customMetadata.add(name: name, value: value)
        }
        let nanoseconds = min(
            timeout * 1_000_000_000,
            Double(Int64.max)
        )
        options.timeLimit = .timeout(.nanoseconds(Int64(nanoseconds)))
        willAttemptCallCreation()
        let registeredCall: (TraceCall, UInt64)? = lock.withLock {
            guard
                !isShutdown,
                cancellationGeneration == generation,
                isActive()
            else { return nil }
            nextCallID &+= 1
            let call = traceClient.export(request, callOptions: options)
            didCreateCall()
            activeCalls[nextCallID] = call
            return (call, nextCallID)
        }
        guard let (call, callID) = registeredCall else { return .cancelled }
        defer {
            lock.withLock {
                activeCalls[callID] = nil
            }
        }

        do {
            let status = try call.status.wait()
            switch status.code {
            case .ok:
                return .success
            case .unauthenticated:
                return .unauthenticated
            case .permissionDenied:
                return .rejected
            case .cancelled, .deadlineExceeded:
                return .cancelled
            default:
                return .failure
            }
        } catch {
            return .failure
        }
    }

    func cancelActiveExports() {
        let calls = lock.withLock {
            cancellationGeneration &+= 1
            return Array(activeCalls.values)
        }
        for call in calls {
            call.cancel(promise: nil)
        }
    }

    func shutdown() {
        let shouldClose = lock.withLock {
            guard !isShutdown else { return false }
            isShutdown = true
            return true
        }
        guard shouldClose else { return }
        cancelActiveExports()
        closeTransport()
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
            client: GrpcRemoteTelemetryOtlpLogClient(
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

final class GrpcRemoteTelemetryOtlpLogClient:
    RemoteTelemetryOtlpLogClient, @unchecked Sendable
{
    private typealias LogCall = UnaryCall<
        Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest,
        Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceResponse
    >

    private let logClient:
        Opentelemetry_Proto_Collector_Logs_V1_LogsServiceNIOClient
    private let closeTransport: @Sendable () -> Void
    private let lock = NSLock()
    private var activeCalls: [UInt64: LogCall] = [:]
    private var nextCallID: UInt64 = 0
    private var cancellationGeneration: UInt64 = 0
    private var isShutdown = false

    init(configuration: AuthenticatedOtlpSpanExporterConfiguration) {
        let group = PlatformSupport.makeEventLoopGroup(
            loopCount: 1,
            networkPreference: .best
        )
        let channel = ClientConnection.usingPlatformAppropriateTLS(
            for: group
        ).connect(host: configuration.host, port: configuration.port)
        logClient = .init(channel: channel)
        closeTransport = {
            channel.close().whenComplete { _ in
                group.shutdownGracefully { _ in }
            }
        }
    }

    init(
        channel: ClientConnection,
        closeTransport: @escaping @Sendable () -> Void
    ) {
        logClient = .init(channel: channel)
        self.closeTransport = closeTransport
    }

    func export(
        logs: [ReadableLogRecord],
        metadata: [(String, String)],
        timeout: TimeInterval,
        isActive: @escaping @Sendable () -> Bool
    ) -> RemoteTelemetryOtlpExportResult {
        guard timeout > 0, isActive() else { return .cancelled }
        let generation: UInt64? = lock.withLock {
            isShutdown ? nil : cancellationGeneration
        }
        guard let generation else { return .cancelled }
        let request =
            Opentelemetry_Proto_Collector_Logs_V1_ExportLogsServiceRequest
            .with {
                $0.resourceLogs = LogRecordAdapter
                    .toProtoResourceRecordLog(logRecordList: logs)
            }
        var options = CallOptions()
        for (name, value) in metadata {
            options.customMetadata.add(name: name, value: value)
        }
        let nanoseconds = min(
            timeout * 1_000_000_000,
            Double(Int64.max)
        )
        options.timeLimit = .timeout(.nanoseconds(Int64(nanoseconds)))
        let registeredCall: (LogCall, UInt64)? = lock.withLock {
            guard !isShutdown,
                cancellationGeneration == generation,
                isActive()
            else { return nil }
            nextCallID &+= 1
            let call = logClient.export(request, callOptions: options)
            activeCalls[nextCallID] = call
            return (call, nextCallID)
        }
        guard let (call, callID) = registeredCall else { return .cancelled }
        defer { lock.withLock { activeCalls[callID] = nil } }
        do {
            let status = try call.status.wait()
            switch status.code {
            case .ok: return .success
            case .unauthenticated: return .unauthenticated
            case .permissionDenied: return .rejected
            case .cancelled, .deadlineExceeded: return .cancelled
            default: return .failure
            }
        } catch {
            return .failure
        }
    }

    func cancelActiveExports() {
        let calls = lock.withLock {
            cancellationGeneration &+= 1
            return Array(activeCalls.values)
        }
        for call in calls { call.cancel(promise: nil) }
    }

    func shutdown() {
        let shouldClose = lock.withLock {
            guard !isShutdown else { return false }
            isShutdown = true
            return true
        }
        guard shouldClose else { return }
        cancelActiveExports()
        closeTransport()
    }
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
