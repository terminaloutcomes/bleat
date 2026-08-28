import Foundation
@preconcurrency import OpenTelemetryApi
@preconcurrency import OpenTelemetrySdk

public enum RemoteTelemetryRuntimeFailure: Error, Equatable, Sendable {
    case invalidResource
    case storageUnavailable
    case encodingFailed
    case decodingFailed
    case exportFailed
}

public protocol RemoteTelemetryDownstreamSpanExporter: SpanExporter,
    Sendable
{
    /// Stops any currently executing transport work before returning. Issue 63's
    /// authenticated exporter must implement this as a real transport cancel.
    func cancelActiveExports()
}

public protocol RemoteTelemetryDownstreamLogExporter: LogRecordExporter,
    Sendable
{
    func cancelActiveExports()
    func disable()
}

extension RemoteTelemetryDownstreamLogExporter {
    public func disable() {
        cancelActiveExports()
    }
}

/// Stable consent-gated facade for reviewed structured log schemas.
public final class RemoteTelemetryLogger: RemoteTelemetryLogging,
    RemoteTelemetryDownloadLogging, @unchecked Sendable
{
    private enum State {
        case disabled
        case initializing([BufferedRemoteTelemetryLog])
        case active(any OpenTelemetryApi.Logger)
    }

    private let lock = NSLock()
    private var state = State.disabled
    private let maximumInitializingLogs = 2_048

    public init() {}

    public func prepareForActivation() {
        lock.withLock {
            guard case .disabled = state else { return }
            state = .initializing([])
        }
    }

    func activate(_ logger: any OpenTelemetryApi.Logger) {
        let buffered = lock.withLock {
            guard case .initializing(let buffered) = state else {
                return [BufferedRemoteTelemetryLog]()
            }
            state = .active(logger)
            return buffered
        }
        for event in buffered {
            event.emit(using: logger)
        }
    }

    public func deactivate() {
        lock.withLock { state = .disabled }
    }

    public func recordPrivateCloudEvent(
        _ event: PrivateCloudSyncEvent,
        span: RemoteTelemetrySpan?
    ) {
        let logger: (any OpenTelemetryApi.Logger)? = lock.withLock {
            switch state {
            case .disabled:
                return nil
            case .active(let logger):
                return logger
            case .initializing(var buffered):
                if buffered.count < maximumInitializingLogs {
                    buffered.append(
                        .privateCloud(event: event, span: span)
                    )
                    state = .initializing(buffered)
                }
                return nil
            }
        }
        if let logger {
            Self.emit(event, span: span, using: logger)
        }
    }

    public func recordDownloadEvent(
        _ event: RemoteDownloadTransferEvent,
        span: RemoteTelemetrySpan?
    ) {
        let logger: (any OpenTelemetryApi.Logger)? = lock.withLock {
            switch state {
            case .disabled:
                return nil
            case .active(let logger):
                return logger
            case .initializing(var buffered):
                if buffered.count < maximumInitializingLogs {
                    buffered.append(.download(event: event, span: span))
                    state = .initializing(buffered)
                }
                return nil
            }
        }
        if let logger {
            Self.emit(event, span: span, using: logger)
        }
    }

    fileprivate static func emit(
        _ event: PrivateCloudSyncEvent,
        span: RemoteTelemetrySpan?,
        using logger: any OpenTelemetryApi.Logger
    ) {
        var attributes: [String: AttributeValue] = [
            "bleat.subsystem": .string(
                RemoteTelemetrySubsystem.synchronization.rawValue
            ),
            "bleat.cloudkit.operation": .string(event.operation.rawValue),
        ]
        let eventName: String
        let severity: Severity
        switch event.phase {
        case .started:
            eventName = "bleat.cloudkit.sync.started"
            severity = .debug
            attributes["bleat.outcome"] = .string("started")
        case .completed:
            eventName = "bleat.cloudkit.sync.completed"
            severity = .info
            attributes["bleat.outcome"] = .string("succeeded")
        case .failed(let failure):
            eventName = "bleat.cloudkit.sync.failed"
            severity = failure.cause == .cancelled ? .warn : .error
            attributes["bleat.outcome"] = .string(
                failure.cause == .cancelled ? "cancelled" : "failed"
            )
            attributes["bleat.failure.category"] = .string(
                failure.cause.remoteTelemetryFailureCategory.rawValue
            )
            attributes["bleat.retryable"] = .bool(
                failure.cause.isRetryable
            )
            if case .cloudKit(let cloudKit) = failure.cause {
                attributes["bleat.cloudkit.code"] = .string(
                    cloudKit.code.diagnosticCode
                )
                if !cloudKit.partialFailureCodes.isEmpty {
                    attributes["bleat.cloudkit.partial_codes"] =
                        AttributeValue(
                            cloudKit.partialFailureCodes.map(\.diagnosticCode)
                        )
                }
                if let retryAfter = cloudKit.retryAfterSeconds {
                    attributes["bleat.retry_after_ms"] = .int(
                        Int((retryAfter * 1_000).rounded())
                    )
                }
            }
        }
        if let duration = event.durationMilliseconds {
            attributes["bleat.duration_ms"] = .int(duration)
        }
        if let recordCount = event.recordCount {
            attributes["bleat.cloudkit.record_count"] = .int(recordCount)
        }
        let builder = logger.logRecordBuilder()
            .setTimestamp(event.timestamp)
            .setSeverity(severity)
            .setEventName(eventName)
            .setBody(.string("CloudKit synchronization lifecycle"))
            .setAttributes(attributes)
        if let context = span?.spanContext {
            _ = builder.setSpanContext(context)
        }
        builder.emit()
    }

    fileprivate static func emit(
        _ event: RemoteDownloadTransferEvent,
        span: RemoteTelemetrySpan?,
        using logger: any OpenTelemetryApi.Logger
    ) {
        var attributes: [String: AttributeValue] = [
            "bleat.subsystem": .string(RemoteTelemetrySubsystem.download.rawValue),
            "bleat.download.stage": .string(event.stage.rawValue),
            "bleat.outcome": .string(event.state.rawValue),
            "bleat.retry.bucket": .string(event.retryBucket.rawValue),
            "bleat.retryable": .bool(event.isRetryable),
        ]
        if let failureCause = event.failureCause {
            attributes["bleat.download.failure_code"] = .string(
                failureCause.rawValue
            )
        }
        if let retryDelaySeconds = event.retryDelaySeconds {
            attributes["bleat.download.retry_delay_seconds"] = .int(
                retryDelaySeconds
            )
        }
        if let retryDelaySource = event.retryDelaySource {
            attributes["bleat.download.retry_delay_source"] = .string(
                retryDelaySource.rawValue
            )
        }
        if let httpStatusCode = event.httpStatusCode {
            attributes["http.response.status_code"] = .int(httpStatusCode)
        }
        if let transportErrorCode = event.transportErrorCode {
            attributes["bleat.download.transport_error_code"] = .int(
                transportErrorCode
            )
        }
        let severity: Severity = switch event.state {
        case .failed:
            .error
        case .waiting, .retrying, .cancelled:
            .warn
        case .started:
            .debug
        case .succeeded:
            .info
        }
        let builder = logger.logRecordBuilder()
            .setTimestamp(event.timestamp)
            .setSeverity(severity)
            .setEventName("bleat.download.transfer.\(event.stage.rawValue)")
            .setBody(.string("Download transfer lifecycle"))
            .setAttributes(attributes)
        if let context = span?.spanContext {
            _ = builder.setSpanContext(context)
        }
        builder.emit()
    }
}

private enum BufferedRemoteTelemetryLog: Sendable {
    case privateCloud(
        event: PrivateCloudSyncEvent,
        span: RemoteTelemetrySpan?
    )
    case download(
        event: RemoteDownloadTransferEvent,
        span: RemoteTelemetrySpan?
    )

    func emit(using logger: any OpenTelemetryApi.Logger) {
        switch self {
        case .privateCloud(let event, let span):
            RemoteTelemetryLogger.emit(event, span: span, using: logger)
        case .download(let event, let span):
            RemoteTelemetryLogger.emit(event, span: span, using: logger)
        }
    }
}

/// A stable application-facing tracer whose active OpenTelemetry tracer may be
/// replaced without exposing the SDK or arbitrary attributes to callers.
public final class RemoteTelemetryTracer: RemoteTelemetryTracing,
    @unchecked Sendable
{
    private enum State {
        case disabled
        case initializing([BufferedRemoteTelemetrySpan])
        case active(any Tracer)
    }

    private let lock = NSLock()
    private var state = State.disabled
    private let maximumInitializingSpans = 2_048

    public init() {}

    public func prepareForActivation() {
        lock.withLock {
            guard case .disabled = state else { return }
            state = .initializing([])
        }
    }

    func activate(_ tracer: any Tracer) {
        let buffered = lock.withLock {
            guard case .initializing(let buffered) = state else {
                return [BufferedRemoteTelemetrySpan]()
            }
            state = .active(tracer)
            return buffered
        }
        for span in buffered {
            span.materialize(using: tracer)
        }
    }

    public func deactivate() {
        let buffered = lock.withLock {
            let buffered: [BufferedRemoteTelemetrySpan]
            if case .initializing(let pending) = state {
                buffered = pending
            } else {
                buffered = []
            }
            state = .disabled
            return buffered
        }
        for span in buffered {
            span.discard()
        }
    }

    public func beginSpan(
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket
    ) -> RemoteTelemetrySpan {
        beginSpan(
            operation: operation,
            source: source,
            retryBucket: retryBucket,
            parent: nil
        )
    }

    public func beginChildSpan(
        operation: RemoteTelemetryOperation,
        parent: RemoteTelemetrySpan
    ) -> RemoteTelemetrySpan {
        beginSpan(
            operation: operation,
            source: nil,
            retryBucket: .none,
            parent: parent
        )
    }

    private func beginSpan(
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket,
        parent: RemoteTelemetrySpan?
    ) -> RemoteTelemetrySpan {
        let startedAt = Date()
        return lock.withLock {
            switch state {
            case .disabled:
                return .inactive
            case .active(let tracer):
                return Self.makeSpan(
                    tracer: tracer,
                    operation: operation,
                    source: source,
                    retryBucket: retryBucket,
                    startedAt: startedAt,
                    parent: parent
                )
            case .initializing(var buffered):
                guard buffered.count < maximumInitializingSpans else {
                    return .inactive
                }
                let pending = BufferedRemoteTelemetrySpan(
                    operation: operation,
                    source: source,
                    retryBucket: retryBucket,
                    startedAt: startedAt,
                    parent: parent
                )
                buffered.append(pending)
                state = .initializing(buffered)
                return RemoteTelemetrySpan(
                    endAction: { outcome in pending.end(outcome) },
                    contextProvider: { pending.spanContext }
                )
            }
        }
    }

    private static func makeSpan(
        tracer: any Tracer,
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket,
        startedAt: Date,
        parent: RemoteTelemetrySpan?
    ) -> RemoteTelemetrySpan {
        let builder = tracer.spanBuilder(spanName: operation.rawValue)
            .setStartTime(time: startedAt)
            .setSpanKind(spanKind: operation.spanKind)
        if let parentContext = parent?.spanContext {
            _ = builder.setParent(parentContext)
        }
        let span = builder.startSpan()
        let box = OpenTelemetrySpanBox(span: span)
        return RemoteTelemetrySpan(
            endAction: { outcome in
                let descriptor = RemoteTelemetrySpanDescriptor(
                    operation: operation,
                    outcome: outcome,
                    source: source,
                    retryBucket: retryBucket
                )
                box.end(descriptor.encodedSpan, at: Date())
            },
            contextProvider: { box.spanContext }
        )
    }
}

private final class BufferedRemoteTelemetrySpan: @unchecked Sendable {
    private struct Completion {
        let outcome: RemoteTelemetryOutcome
        let endedAt: Date
    }

    private let lock = NSLock()
    private let operation: RemoteTelemetryOperation
    private let source: RemoteTelemetrySource?
    private let retryBucket: RemoteTelemetryRetryBucket
    private let startedAt: Date
    private let parent: RemoteTelemetrySpan?
    private var completion: Completion?
    private var materialized: OpenTelemetrySpanBox?
    private var discarded = false

    init(
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket,
        startedAt: Date,
        parent: RemoteTelemetrySpan?
    ) {
        self.operation = operation
        self.source = source
        self.retryBucket = retryBucket
        self.startedAt = startedAt
        self.parent = parent
    }

    func end(_ outcome: RemoteTelemetryOutcome) {
        let action: (OpenTelemetrySpanBox, Completion)? = lock.withLock {
            guard completion == nil, !discarded else { return nil }
            let completion = Completion(outcome: outcome, endedAt: Date())
            self.completion = completion
            return materialized.map { ($0, completion) }
        }
        if let action {
            finish(action.0, completion: action.1)
        }
    }

    func materialize(using tracer: any Tracer) {
        let result: (OpenTelemetrySpanBox, Completion?)? = lock.withLock {
            guard !discarded else { return nil }
            let builder = tracer.spanBuilder(spanName: operation.rawValue)
                .setStartTime(time: startedAt)
                .setSpanKind(spanKind: operation.spanKind)
            if let parentContext = parent?.spanContext {
                _ = builder.setParent(parentContext)
            }
            let span = builder.startSpan()
            let box = OpenTelemetrySpanBox(span: span)
            materialized = box
            return (box, completion)
        }
        if let result, let completion = result.1 {
            finish(result.0, completion: completion)
        }
    }

    func discard() {
        lock.withLock {
            discarded = true
            materialized = nil
        }
    }

    var spanContext: SpanContext? {
        lock.withLock { materialized?.spanContext }
    }

    private func finish(
        _ box: OpenTelemetrySpanBox,
        completion: Completion
    ) {
        box.end(
            RemoteTelemetrySpanDescriptor(
                operation: operation,
                outcome: completion.outcome,
                source: source,
                retryBucket: retryBucket
            ).encodedSpan,
            at: completion.endedAt
        )
    }
}

private final class OpenTelemetrySpanBox: @unchecked Sendable {
    private let span: any Span

    init(span: any Span) {
        self.span = span
    }

    var spanContext: SpanContext { span.context }

    func end(_ encoded: RemoteTelemetryEncodedSpan, at endTime: Date) {
        for (key, value) in encoded.attributes {
            span.setAttribute(key: key, value: value)
        }
        span.end(time: endTime)
    }
}

final class UnavailableRemoteTelemetrySpanExporter:
    RemoteTelemetryDownstreamSpanExporter, @unchecked Sendable
{
    func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        .failure
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        .failure
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

    func cancelActiveExports() {}

    func disable() {}
}

final class UnavailableRemoteTelemetryLogExporter:
    RemoteTelemetryDownstreamLogExporter, @unchecked Sendable
{
    func export(
        logRecords: [ReadableLogRecord],
        explicitTimeout: TimeInterval?
    ) -> ExportResult {
        .failure
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        .failure
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

    func cancelActiveExports() {}
}

/// Persists completed OpenTelemetry batches before attempting downstream
/// export. The batch processor calls this exporter from its worker thread, so
/// serialization and filesystem work never execute on the originating caller.
final class BoundedPersistentSpanExporter: SpanExporter, @unchecked Sendable {
    private let storageURL: URL
    private let downstream: any RemoteTelemetryDownstreamSpanExporter
    private let policy: RemoteTelemetryCollectionPolicy
    private let now: @Sendable () -> Date
    private let storageQueue = DispatchQueue(
        label: "app.bleat.remote-telemetry.storage",
        // SpanExporter.export must wait for durable persistence. Match the
        // OpenTelemetry batch worker's QoS to avoid priority inversion while
        // keeping all serialization and filesystem work off the main actor.
        qos: .userInitiated
    )
    private let drainQueue = DispatchQueue(
        label: "app.bleat.remote-telemetry.export",
        qos: .utility
    )
    private let stateLock = NSLock()
    private var enabled = true
    private var foreground = true
    private var drainRunning = false
    private var drainRequested = false
    private var retryScheduled = false
    private var retryAttempt = 0
    private var backgroundFlushCount = 0

    init(
        storageURL: URL,
        downstream: any RemoteTelemetryDownstreamSpanExporter,
        policy: RemoteTelemetryCollectionPolicy,
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        self.storageURL = storageURL
        self.downstream = downstream
        self.policy = policy
        self.now = now
        try prepareStorage()
        storageQueue.sync {
            pruneAndEnforceBounds()
        }
        requestDrain()
    }

    func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        guard isEnabled, !spans.isEmpty else {
            return .failure
        }
        let stored = storageQueue.sync {
            persist(spans)
        }
        guard stored else {
            return .failure
        }
        requestDrain()
        return .success
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        flush(
            explicitTimeout: explicitTimeout,
            allowWhileBackgrounded: false
        )
    }

    func flush(
        explicitTimeout: TimeInterval?,
        allowWhileBackgrounded: Bool
    ) -> SpanExporterResultCode {
        if allowWhileBackgrounded {
            stateLock.withLock {
                backgroundFlushCount += 1
                // A lifecycle flush is a fresh bounded best-effort attempt,
                // even when a foreground retry backoff was pending.
                retryScheduled = false
            }
        }
        defer {
            if allowWhileBackgrounded {
                stateLock.withLock { backgroundFlushCount -= 1 }
            }
        }
        requestDrain()
        let group = DispatchGroup()
        group.enter()
        drainQueue.async {
            group.leave()
        }
        let timeout = max(explicitTimeout ?? 30, 0)
        let result = group.wait(timeout: .now() + timeout)
        if result != .success,
            stateLock.withLock({ !foreground })
        {
            downstream.cancelActiveExports()
        }
        return result == .success ? .success : .failure
    }

    func shutdown(explicitTimeout: TimeInterval?) {
        setEnabled(false)
        downstream.shutdown(explicitTimeout: explicitTimeout)
    }

    func setForeground(_ foreground: Bool) {
        stateLock.withLock {
            self.foreground = foreground
        }
        if foreground {
            requestDrain()
        }
    }

    func disableAndPurge() {
        setEnabled(false)
        storageQueue.sync {
            try? FileManager.default.removeItem(at: storageURL)
        }
    }

    func disable() {
        setEnabled(false)
    }

    private var isEnabled: Bool {
        stateLock.withLock { enabled }
    }

    private var mayDrain: Bool {
        stateLock.withLock {
            enabled && (foreground || backgroundFlushCount > 0)
        }
    }

    private func setEnabled(_ enabled: Bool) {
        stateLock.withLock {
            self.enabled = enabled
            if !enabled {
                retryScheduled = false
                drainRequested = false
            }
        }
        if !enabled {
            downstream.cancelActiveExports()
        }
    }

    private func prepareStorage() throws {
        do {
            try FileManager.default.createDirectory(
                at: storageURL,
                withIntermediateDirectories: true
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = storageURL
            try mutableURL.setResourceValues(values)
        } catch {
            throw RemoteTelemetryRuntimeFailure.storageUnavailable
        }
    }

    private func persist(_ spans: [SpanData]) -> Bool {
        guard isEnabled else { return false }
        do {
            try prepareStorage()
            let encoder = JSONEncoder()
            var retained = spans.sorted { $0.endTime < $1.endTime }
            var data = try encoder.encode(retained)
            while data.count > policy.maximumBufferedBytes,
                !retained.isEmpty
            {
                retained.removeFirst()
                data = try encoder.encode(retained)
            }
            guard !retained.isEmpty else { return true }
            let fileURL = storageURL.appendingPathComponent(
                "batch-\(UUID().uuidString.lowercased()).json",
                isDirectory: false
            )
            try writeBatch(data, spans: retained, to: fileURL)
            pruneAndEnforceBounds()
            return true
        } catch {
            return false
        }
    }

    private func pruneAndEnforceBounds() {
        let cutoff = now().addingTimeInterval(-policy.maximumBufferedAge)
        let encoder = JSONEncoder()
        for fileURL in batchFiles() {
            do {
                let data = try Data(contentsOf: fileURL)
                let spans = try JSONDecoder().decode(
                    [SpanData].self,
                    from: data
                )
                let retained = spans.filter { $0.endTime >= cutoff }
                if retained.isEmpty {
                    try? FileManager.default.removeItem(at: fileURL)
                } else if retained.count != spans.count {
                    let updated = try encoder.encode(retained)
                    try writeBatch(updated, spans: retained, to: fileURL)
                }
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        var files = batchFilesWithMetadata()
        var total = files.reduce(0) { $0 + $1.byteCount }
        while total > policy.maximumBufferedBytes, let oldest = files.first {
            let removed = trimOldestSpans(
                in: oldest.url,
                removingAtLeast: total - policy.maximumBufferedBytes
            )
            guard removed > 0 else {
                try? FileManager.default.removeItem(at: oldest.url)
                total -= oldest.byteCount
                files.removeFirst()
                continue
            }
            total -= removed
            files = batchFilesWithMetadata()
        }
    }

    private func trimOldestSpans(
        in fileURL: URL,
        removingAtLeast targetBytes: Int
    ) -> Int {
        do {
            let original = try Data(contentsOf: fileURL)
            var spans = try JSONDecoder().decode(
                [SpanData].self, from: original
            )
            .sorted { $0.endTime < $1.endTime }
            let encoder = JSONEncoder()
            var updated = original
            repeat {
                guard !spans.isEmpty else { break }
                spans.removeFirst()
                updated = try encoder.encode(spans)
            } while original.count - updated.count < targetBytes
            if spans.isEmpty {
                try FileManager.default.removeItem(at: fileURL)
                return original.count
            }
            try writeBatch(updated, spans: spans, to: fileURL)
            return max(original.count - updated.count, 0)
        } catch {
            let oldSize =
                (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize ?? 0
            try? FileManager.default.removeItem(at: fileURL)
            return oldSize
        }
    }

    private func requestDrain() {
        let shouldStart = stateLock.withLock {
            guard enabled, foreground || backgroundFlushCount > 0 else {
                return false
            }
            drainRequested = true
            guard !drainRunning, !retryScheduled else { return false }
            drainRequested = false
            drainRunning = true
            return true
        }
        guard shouldStart else { return }
        drainQueue.async { [weak self] in
            self?.drain()
        }
    }

    private func drain() {
        defer {
            let shouldRestart = stateLock.withLock {
                drainRunning = false
                guard enabled,
                    foreground || backgroundFlushCount > 0,
                    drainRequested,
                    !retryScheduled
                else { return false }
                drainRequested = false
                drainRunning = true
                return true
            }
            if shouldRestart {
                drainQueue.async { [weak self] in self?.drain() }
            }
        }
        while mayDrain {
            stateLock.withLock { drainRequested = false }
            guard let next = storageQueue.sync(execute: nextBatch) else {
                stateLock.withLock {
                    retryAttempt = 0
                }
                return
            }
            guard isEnabled else { return }
            let result = downstream.export(
                spans: next.spans,
                explicitTimeout: 30
            )
            switch result {
            case .success:
                guard isEnabled else { return }
                storageQueue.sync {
                    try? FileManager.default.removeItem(at: next.url)
                }
                stateLock.withLock {
                    retryAttempt = 0
                }
            case .failure:
                scheduleRetry()
                return
            }
        }
    }

    private func scheduleRetry() {
        let delay: TimeInterval? = stateLock.withLock {
            guard enabled, foreground, !retryScheduled else { return nil }
            retryScheduled = true
            retryAttempt = min(retryAttempt + 1, 5)
            return min(pow(2, Double(retryAttempt - 1)) * 5, 60)
        }
        guard let delay else { return }
        drainQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            stateLock.withLock {
                retryScheduled = false
            }
            requestDrain()
        }
    }

    private func nextBatch() -> (
        url: URL,
        spans: [SpanData]
    )? {
        pruneAndEnforceBounds()
        for fileURL in batchFiles() {
            guard let data = try? Data(contentsOf: fileURL),
                let spans = try? JSONDecoder().decode(
                    [SpanData].self,
                    from: data
                )
            else {
                try? FileManager.default.removeItem(at: fileURL)
                continue
            }
            return (fileURL, spans)
        }
        return nil
    }

    private func batchFiles() -> [URL] {
        batchFilesWithMetadata().map(\.url)
    }

    private func batchFilesWithMetadata() -> [(
        url: URL, oldestSpanDate: Date, byteCount: Int
    )] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .fileSizeKey, .isRegularFileKey,
        ]
        let urls =
            (try? FileManager.default.contentsOfDirectory(
                at: storageURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )) ?? []
        return urls.compactMap { url in
            guard url.pathExtension == "json",
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true
            else {
                return nil
            }
            return (
                url,
                values.contentModificationDate ?? .distantPast,
                values.fileSize ?? 0
            )
        }
        .sorted {
            ($0.oldestSpanDate, $0.url.lastPathComponent)
                < ($1.oldestSpanDate, $1.url.lastPathComponent)
        }
    }

    private func writeBatch(
        _ data: Data,
        spans: [SpanData],
        to fileURL: URL
    ) throws {
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: spans[0].endTime],
            ofItemAtPath: fileURL.path
        )
        #if os(iOS)
            try FileManager.default.setAttributes(
                [
                    .protectionKey: FileProtectionType
                        .completeUntilFirstUserAuthentication
                ],
                ofItemAtPath: fileURL.path
            )
        #endif
    }
}

/// Owns one enabled OpenTelemetry provider. Callers retain the stable facade,
/// while consent changes replace or deactivate this pipeline.
public final class RemoteTelemetryPipeline: @unchecked Sendable {
    private let provider: TracerProviderSdk
    private let loggerProvider: LoggerProviderSdk
    private let exporter: BoundedPersistentSpanExporter
    private let logExporter: any RemoteTelemetryDownstreamLogExporter
    private let tracerFacade: RemoteTelemetryTracer
    private let loggerFacade: RemoteTelemetryLogger
    private var processor: BatchSpanProcessor
    private var logProcessor: BatchLogRecordProcessor

    public init(
        resource: RemoteTelemetryResource,
        storageURL: URL,
        tracerFacade: RemoteTelemetryTracer,
        loggerFacade: RemoteTelemetryLogger = RemoteTelemetryLogger(),
        policy: RemoteTelemetryCollectionPolicy = .default,
        downstreamExporter: (any RemoteTelemetryDownstreamSpanExporter)? = nil,
        downstreamLogExporter: (
            any RemoteTelemetryDownstreamLogExporter
        )? = nil
    ) throws {
        tracerFacade.prepareForActivation()
        loggerFacade.prepareForActivation()
        let attributes = resource.encodedAttributes.mapValues {
            AttributeValue.string($0)
        }
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: storageURL,
            downstream: downstreamExporter
                ?? UnavailableRemoteTelemetrySpanExporter(),
            policy: policy
        )
        let processor = BatchSpanProcessor(spanExporter: exporter)
        let logExporter = downstreamLogExporter
            ?? UnavailableRemoteTelemetryLogExporter()
        let logProcessor = BatchLogRecordProcessor(
            logRecordExporter: logExporter
        )
        let limits = SpanLimits()
            .settingAttributeCountLimit(8)
            .settingEventCountLimit(0)
            .settingLinkCountLimit(0)
        provider = TracerProviderSdk(
            resource: Resource(attributes: attributes),
            spanLimits: limits,
            sampler: Samplers.alwaysOn,
            spanProcessors: [processor]
        )
        loggerProvider = LoggerProviderBuilder()
            .with(resource: Resource(attributes: attributes))
            .with(processors: [logProcessor])
            .build()
        self.exporter = exporter
        self.logExporter = logExporter
        self.tracerFacade = tracerFacade
        self.loggerFacade = loggerFacade
        self.processor = processor
        self.logProcessor = logProcessor
        tracerFacade.activate(
            provider.get(
                instrumentationName: "app.bleat.remote-telemetry",
                instrumentationVersion: resource.applicationVersion
            )
        )
        loggerFacade.activate(
            loggerProvider.get(
                instrumentationScopeName: "app.bleat.remote-telemetry"
            )
        )
    }

    public func setForeground(_ foreground: Bool) {
        exporter.setForeground(foreground)
    }

    public func flush(timeout: TimeInterval) {
        provider.forceFlush(timeout: timeout)
        _ = logProcessor.forceFlush(explicitTimeout: timeout)
        _ = exporter.flush(explicitTimeout: timeout)
    }

    public func flushForBackground(timeout: TimeInterval) {
        provider.forceFlush(timeout: timeout)
        _ = logProcessor.forceFlush(explicitTimeout: timeout)
        _ = exporter.flush(
            explicitTimeout: timeout,
            allowWhileBackgrounded: true
        )
    }

    public func deactivate() {
        tracerFacade.deactivate()
        loggerFacade.deactivate()
        provider.resetSpanProcessors()
        exporter.disable()
        logExporter.disable()
    }

    public func purge() {
        exporter.disableAndPurge()
    }

    public func shutdown() {
        processor.shutdown(explicitTimeout: 2)
        _ = logProcessor.shutdown(explicitTimeout: 2)
    }
}
