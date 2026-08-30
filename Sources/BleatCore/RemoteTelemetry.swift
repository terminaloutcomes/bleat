import Foundation
@preconcurrency import OpenTelemetryApi

/// The application-facing tracing boundary. It deliberately exposes no raw
/// OpenTelemetry span names or attribute dictionaries.
public protocol RemoteTelemetryTracing: Sendable {
    func beginSpan(
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket
    ) -> RemoteTelemetrySpan

    func beginChildSpan(
        operation: RemoteTelemetryOperation,
        parent: RemoteTelemetrySpan
    ) -> RemoteTelemetrySpan
}

extension RemoteTelemetryTracing {
    public func beginSpan(
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource? = nil,
        retryBucket: RemoteTelemetryRetryBucket = .none
    ) -> RemoteTelemetrySpan {
        beginSpan(
            operation: operation,
            source: source,
            retryBucket: retryBucket
        )
    }

    public func beginChildSpan(
        operation: RemoteTelemetryOperation,
        parent: RemoteTelemetrySpan
    ) -> RemoteTelemetrySpan {
        beginSpan(operation: operation)
    }
}

/// A single reviewed operation. Ending is idempotent so cancellation and
/// replacement paths may safely race without producing duplicate spans.
public final class RemoteTelemetrySpan: @unchecked Sendable {
    @TaskLocal static var current: RemoteTelemetrySpan?

    private let lock = NSLock()
    private var endAction:
        (
            @Sendable (
                RemoteTelemetryOutcome,
                RemoteTelemetryTranscriptionInput?
            ) -> Void
        )?
    private let contextProvider: @Sendable () -> SpanContext?

    public init(
        endAction: @escaping @Sendable (RemoteTelemetryOutcome) -> Void
    ) {
        self.endAction = { outcome, _ in endAction(outcome) }
        contextProvider = { nil }
    }

    public init(
        transcriptionEndAction:
            @escaping @Sendable (
                RemoteTelemetryOutcome,
                RemoteTelemetryTranscriptionInput?
            ) -> Void
    ) {
        endAction = transcriptionEndAction
        contextProvider = { nil }
    }

    init(
        endAction: @escaping @Sendable (RemoteTelemetryOutcome) -> Void,
        contextProvider: @escaping @Sendable () -> SpanContext?
    ) {
        self.endAction = { outcome, _ in endAction(outcome) }
        self.contextProvider = contextProvider
    }

    init(
        transcriptionEndAction:
            @escaping @Sendable (
                RemoteTelemetryOutcome,
                RemoteTelemetryTranscriptionInput?
            ) -> Void,
        contextProvider: @escaping @Sendable () -> SpanContext?
    ) {
        endAction = transcriptionEndAction
        self.contextProvider = contextProvider
    }

    public func end(_ outcome: RemoteTelemetryOutcome) {
        end(outcome, transcriptionInput: nil)
    }

    public func end(
        _ outcome: RemoteTelemetryOutcome,
        transcriptionInput: RemoteTelemetryTranscriptionInput?
    ) {
        let action = lock.withLock {
            let action = endAction
            endAction = nil
            return action
        }
        action?(outcome, transcriptionInput)
    }

    var spanContext: SpanContext? { contextProvider() }

    var propagationHeaders: [String: String] {
        guard let spanContext else { return [:] }
        var headers: [String: String] = [:]
        W3CTraceContextPropagator().inject(
            spanContext: spanContext,
            carrier: &headers,
            setter: RemoteTelemetryHeaderSetter()
        )
        return headers
    }

    static let inactive = RemoteTelemetrySpan { _ in }
}

private struct RemoteTelemetryHeaderSetter: Setter {
    func set(
        carrier: inout [String: String],
        key: String,
        value: String
    ) {
        carrier[key] = value
    }
}

public struct InactiveRemoteTelemetryTracer: RemoteTelemetryTracing {
    public init() {}

    public func beginSpan(
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket
    ) -> RemoteTelemetrySpan {
        .inactive
    }
}

/// The complete reviewed set of operations that Bleat may trace remotely.
///
/// Adding a case changes Bleat's remote telemetry contract and requires a
/// privacy review. Callers cannot supply arbitrary span names.
public enum RemoteTelemetryOperation: String, CaseIterable, Sendable {
    case appLaunch = "bleat.app.launch"
    case accountConnection = "bleat.account.connection"
    case liveUpdateConnection = "bleat.live_update.connection"
    case libraryRefresh = "bleat.library.refresh"
    case playbackPreparation = "bleat.playback.prepare"
    case playbackStart = "bleat.playback.start"
    case downloadTransfer = "bleat.download.transfer"
    case playbackProgressSync = "bleat.playback.progress_sync"
    case transcription = "bleat.transcription.run"
    case transcriptionChapter = "bleat.transcription.chapter"
    case privateCloudSync = "bleat.cloudkit.sync"
    case telemetryAuthentication = "bleat.telemetry.authentication"
    case telemetryChallenge = "bleat.telemetry.challenge"
    case telemetryEnrolment = "bleat.telemetry.enrolment"
    case telemetryToken = "bleat.telemetry.token"

    var subsystem: RemoteTelemetrySubsystem {
        switch self {
        case .appLaunch:
            .app
        case .accountConnection, .liveUpdateConnection:
            .authentication
        case .libraryRefresh:
            .library
        case .playbackPreparation, .playbackStart:
            .playback
        case .downloadTransfer:
            .download
        case .playbackProgressSync, .privateCloudSync:
            .synchronization
        case .transcription, .transcriptionChapter:
            .transcription
        case .telemetryAuthentication, .telemetryChallenge,
            .telemetryEnrolment, .telemetryToken:
            .authentication
        }
    }

    var spanKind: SpanKind {
        switch self {
        case .telemetryChallenge, .telemetryEnrolment, .telemetryToken:
            .client
        default:
            .internal
        }
    }
}

/// The reviewed CloudKit log boundary. It intentionally accepts the typed
/// lifecycle event rather than an arbitrary body or attributes dictionary.
public protocol RemoteTelemetryLogging: Sendable {
    func recordPrivateCloudEvent(
        _ event: PrivateCloudSyncEvent,
        span: RemoteTelemetrySpan?
    )
}

public struct InactiveRemoteTelemetryLogger: RemoteTelemetryLogging {
    public init() {}

    public func recordPrivateCloudEvent(
        _ event: PrivateCloudSyncEvent,
        span: RemoteTelemetrySpan?
    ) {}
}

public protocol RemoteTelemetryDownloadLogging: Sendable {
    func recordDownloadEvent(
        _ event: RemoteDownloadTransferEvent,
        span: RemoteTelemetrySpan?
    )
}

public struct InactiveRemoteTelemetryDownloadLogger:
    RemoteTelemetryDownloadLogging
{
    public init() {}

    public func recordDownloadEvent(
        _ event: RemoteDownloadTransferEvent,
        span: RemoteTelemetrySpan?
    ) {}
}

public enum RemoteDownloadTransferStage: String, CaseIterable, Sendable {
    case taskScheduled = "task_scheduled"
    case taskCompletion = "task_completion"
    case responseClassification = "response_classification"
    case rangeValidation = "range_validation"
    case chunkPlacement = "chunk_placement"
    case manifestCommit = "manifest_commit"
    case networkWait = "network_wait"
    case primaryFallback = "primary_fallback"
    case authenticationRefresh = "authentication_refresh"
    case retryScheduled = "retry_scheduled"
    case trackCompleted = "track_completed"
    case transferCompleted = "transfer_completed"
}

public enum RemoteDownloadTransferState: String, CaseIterable, Sendable {
    case started
    case succeeded
    case waiting
    case retrying
    case failed
    case cancelled
}

public enum RemoteDownloadRetryDelaySource: String, CaseIterable, Sendable {
    case exponentialBackoff = "exponential_backoff"
    case serverRetryAfter = "server_retry_after"
}

public enum RemoteDownloadFailureCause: String, CaseIterable, Sendable {
    case offline
    case connectionLost = "connection_lost"
    case timedOut = "timed_out"
    case cannotConnect = "cannot_connect"
    case dnsLookupFailed = "dns_lookup_failed"
    case transportOther = "transport_other"
    case missingResponse = "missing_response"
    case unexpectedHTTPStatus = "unexpected_http_status"
    case invalidRange = "invalid_range"
    case missingContentRange = "missing_content_range"
    case mismatchedContentRange = "mismatched_content_range"
    case mismatchedTotalByteLength = "mismatched_total_byte_length"
    case invalidPartialOffset = "invalid_partial_offset"
    case partialFileTooLarge = "partial_file_too_large"
    case byteLengthMismatch = "byte_length_mismatch"
    case persistenceFailed = "persistence_failed"
    case authenticationRefreshFailed = "authentication_refresh_failed"
    case retryExhausted = "retry_exhausted"
    case unknown
}

public struct RemoteDownloadTransferEvent: Equatable, Sendable {
    public let timestamp: Date
    public let stage: RemoteDownloadTransferStage
    public let state: RemoteDownloadTransferState
    public let failureCause: RemoteDownloadFailureCause?
    public let retryBucket: RemoteTelemetryRetryBucket
    public let isRetryable: Bool
    public let retryDelaySeconds: Int?
    public let retryDelaySource: RemoteDownloadRetryDelaySource?
    public let httpStatusCode: Int?
    public let transportErrorCode: Int?

    public init(
        timestamp: Date = Date(),
        stage: RemoteDownloadTransferStage,
        state: RemoteDownloadTransferState,
        failureCause: RemoteDownloadFailureCause? = nil,
        retryBucket: RemoteTelemetryRetryBucket = .none,
        isRetryable: Bool = false,
        retryDelaySeconds: Int? = nil,
        retryDelaySource: RemoteDownloadRetryDelaySource? = nil,
        httpStatusCode: Int? = nil,
        transportErrorCode: Int? = nil
    ) {
        self.timestamp = timestamp
        self.stage = stage
        self.state = state
        self.failureCause = failureCause
        self.retryBucket = retryBucket
        self.isRetryable = isRetryable
        self.retryDelaySeconds = retryDelaySeconds
        self.retryDelaySource = retryDelaySource
        self.httpStatusCode = httpStatusCode
        self.transportErrorCode = transportErrorCode
    }
}

public actor RemoteTelemetryPrivateCloudSyncEventRecorder:
    PrivateCloudSyncEventRecording
{
    private let tracer: any RemoteTelemetryTracing
    private let logger: any RemoteTelemetryLogging
    private var spans: [UUID: RemoteTelemetrySpan] = [:]

    public init(
        tracer: any RemoteTelemetryTracing,
        logger: any RemoteTelemetryLogging
    ) {
        self.tracer = tracer
        self.logger = logger
    }

    public func record(_ event: PrivateCloudSyncEvent) {
        switch event.phase {
        case .started:
            let span = tracer.beginSpan(
                operation: .privateCloudSync
            )
            spans[event.correlationID] = span
            logger.recordPrivateCloudEvent(event, span: span)
        case .completed:
            let span = spans.removeValue(forKey: event.correlationID)
            logger.recordPrivateCloudEvent(event, span: span)
            span?.end(.succeeded)
        case .failed(let failure):
            let span = spans.removeValue(forKey: event.correlationID)
            logger.recordPrivateCloudEvent(event, span: span)
            span?.end(
                failure.remoteTelemetryOutcome
            )
        }
    }
}

extension PrivateCloudSyncFailure {
    fileprivate var remoteTelemetryOutcome: RemoteTelemetryOutcome {
        switch cause {
        case .cancelled:
            .cancelled
        default:
            .failed(cause.remoteTelemetryFailureCategory)
        }
    }
}

extension PrivateCloudSyncError {
    var remoteTelemetryFailureCategory: RemoteTelemetryFailureCategory {
        switch self {
        case .cloudKit(let failure):
            switch failure.code {
            case .notAuthenticated, .accountTemporarilyUnavailable:
                .authentication
            case .permissionFailure, .managedAccountRestricted:
                .authorization
            case .networkUnavailable, .networkFailure, .serverResponseLost:
                .transport
            case .requestRateLimited, .zoneBusy:
                .rateLimited
            case .badContainer, .missingEntitlement, .badDatabase,
                .incompatibleVersion:
                .unsupported
            case .partialFailure, .invalidArguments,
                .serverRecordChanged, .constraintViolation,
                .changeTokenExpired, .batchRequestFailed:
                .invalidResponse
            default:
                .serverRejected
            }
        case .persistenceFailed:
            .localStorage
        case .cancelled, .disabled, .invalidRecord, .engineUnavailable,
            .unexpected:
            .unknown
        }
    }
}

public enum RemoteTelemetrySubsystem: String, CaseIterable, Sendable {
    case app
    case authentication
    case library
    case playback
    case download
    case synchronization
    case transcription
}

public enum RemoteTelemetryFailureCategory: String, CaseIterable, Sendable {
    case authentication
    case authorization
    case offline
    case transport
    case timeout
    case rateLimited = "rate_limited"
    case serverRejected = "server_rejected"
    case invalidResponse = "invalid_response"
    case localStorage = "local_storage"
    case media
    case unsupported
    case unknown
}

public enum RemoteTelemetryOutcome: Equatable, Sendable {
    case succeeded
    case cancelled
    case failed(RemoteTelemetryFailureCategory)
    case liveUpdateFailed(RemoteTelemetryLiveUpdateFailure)
}

public struct RemoteTelemetryLiveUpdateFailure: Equatable, Sendable {
    public let category: RemoteTelemetryFailureCategory
    public let code: RemoteTelemetryLiveUpdateFailureCode
    public let stage: RemoteTelemetryLiveUpdateFailureStage

    public init(
        category: RemoteTelemetryFailureCategory,
        code: RemoteTelemetryLiveUpdateFailureCode,
        stage: RemoteTelemetryLiveUpdateFailureStage
    ) {
        self.category = category
        self.code = code
        self.stage = stage
    }
}

public enum RemoteTelemetryLiveUpdateFailureCode: String, CaseIterable,
    Sendable
{
    case invalidSocketURL = "invalid_socket_url"
    case credentialsUnavailable = "credentials_unavailable"
    case authenticationRejected = "authentication_rejected"
    case transportUnavailable = "transport_unavailable"
    case malformedPacket = "malformed_packet"
}

public enum RemoteTelemetryLiveUpdateFailureStage: String, CaseIterable,
    Sendable
{
    case requestConstruction = "request_construction"
    case credentialRetrieval = "credential_retrieval"
    case socketReceive = "socket_receive"
    case socketSend = "socket_send"
    case protocolDecoding = "protocol_decoding"
    case authentication = "authentication"
    case credentialRecovery = "credential_recovery"
}

public enum RemoteTelemetrySource: String, CaseIterable, Sendable {
    case downloaded
    case streamed
    case offline
    case remote
    case cache
    case localServer = "local_server"
    case primaryServer = "primary_server"
}

public enum RemoteTelemetryRetryBucket: String, CaseIterable, Sendable {
    case none
    case one
    case two
    case threeOrMore = "three_or_more"

    public init(retryCount: Int) {
        switch retryCount {
        case ...0:
            self = .none
        case 1:
            self = .one
        case 2:
            self = .two
        default:
            self = .threeOrMore
        }
    }
}

public enum RemoteTelemetryTranscriptionAudioContainer: String, Sendable {
    case m4a
}

public enum RemoteTelemetryTranscriptionAudioCodec: String, Sendable {
    case aac
    case alac
    case linearPCM = "linear_pcm"
    case other
    case mixed
}

/// Reviewed, content-free measurements for one chapter's analyzer input.
public struct RemoteTelemetryTranscriptionInput: Equatable, Sendable {
    public let durationMilliseconds: Int64
    public let byteCount: Int64
    public let sliceCount: Int
    public let container: RemoteTelemetryTranscriptionAudioContainer
    public let codec: RemoteTelemetryTranscriptionAudioCodec
    public let sampleRateHz: Int?
    public let channelCount: Int?

    public init?(
        durationMilliseconds: Int64,
        byteCount: Int64,
        sliceCount: Int,
        container: RemoteTelemetryTranscriptionAudioContainer,
        codec: RemoteTelemetryTranscriptionAudioCodec,
        sampleRateHz: Int?,
        channelCount: Int?
    ) {
        guard durationMilliseconds > 0, byteCount >= 0, sliceCount > 0,
            sampleRateHz.map({ $0 > 0 }) != false,
            channelCount.map({ $0 > 0 }) != false
        else {
            return nil
        }
        self.durationMilliseconds = durationMilliseconds
        self.byteCount = byteCount
        self.sliceCount = sliceCount
        self.container = container
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
    }
}

/// A reviewed remote span description with no arbitrary name or attribute API.
public struct RemoteTelemetrySpanDescriptor: Equatable, Sendable {
    public let operation: RemoteTelemetryOperation
    public let outcome: RemoteTelemetryOutcome
    public let source: RemoteTelemetrySource?
    public let retryBucket: RemoteTelemetryRetryBucket
    public let transcriptionInput: RemoteTelemetryTranscriptionInput?

    public init(
        operation: RemoteTelemetryOperation,
        outcome: RemoteTelemetryOutcome,
        source: RemoteTelemetrySource? = nil,
        retryBucket: RemoteTelemetryRetryBucket = .none,
        transcriptionInput: RemoteTelemetryTranscriptionInput? = nil
    ) {
        self.operation = operation
        self.outcome = outcome
        self.source = source
        self.retryBucket = retryBucket
        self.transcriptionInput = transcriptionInput
    }

    /// OpenTelemetry records elapsed time from the span clock. Duration is not
    /// accepted as an application attribute.
    var encodedSpan: RemoteTelemetryEncodedSpan {
        var attributes: [String: String] = [
            "bleat.subsystem": operation.subsystem.rawValue,
            "bleat.outcome": outcome.encodedOutcome,
            "bleat.retry.bucket": retryBucket.rawValue,
        ]
        if let source {
            attributes["bleat.source"] = source.rawValue
        }
        switch outcome {
        case .failed(let category):
            attributes["bleat.failure.category"] = category.rawValue
        case .liveUpdateFailed(let failure):
            attributes["bleat.failure.category"] = failure.category.rawValue
            attributes["bleat.live_update.failure_code"] =
                failure.code.rawValue
            attributes["bleat.live_update.stage"] = failure.stage.rawValue
        case .succeeded, .cancelled:
            break
        }
        if operation == .transcriptionChapter, let transcriptionInput {
            attributes["bleat.transcription.input.duration_ms"] =
                String(transcriptionInput.durationMilliseconds)
            attributes["bleat.transcription.input.bytes"] =
                String(transcriptionInput.byteCount)
            attributes["bleat.transcription.input.slice_count"] =
                String(transcriptionInput.sliceCount)
            attributes["bleat.transcription.audio.container"] =
                transcriptionInput.container.rawValue
            attributes["bleat.transcription.audio.codec"] =
                transcriptionInput.codec.rawValue
            if let sampleRateHz = transcriptionInput.sampleRateHz {
                attributes["bleat.transcription.audio.sample_rate_hz"] =
                    String(sampleRateHz)
            }
            if let channelCount = transcriptionInput.channelCount {
                attributes["bleat.transcription.audio.channels"] =
                    String(channelCount)
            }
        }
        return RemoteTelemetryEncodedSpan(
            name: operation.rawValue,
            attributes: attributes
        )
    }
}

extension RemoteTelemetryOutcome {
    fileprivate var encodedOutcome: String {
        switch self {
        case .succeeded:
            "succeeded"
        case .cancelled:
            "cancelled"
        case .failed, .liveUpdateFailed:
            "failed"
        }
    }
}

public enum RemoteTelemetryPlatform: String, CaseIterable, Sendable {
    case iOS = "ios"
    case iPadOS = "ipados"
    case macOS = "macos"
}

public enum RemoteTelemetryResourceError: Error, Equatable, Sendable {
    case invalidApplicationVersion
    case invalidApplicationBuild
    case invalidOperatingSystemVersion
}

/// Stable resource data permitted on every remote span and log record.
///
/// Versions are normalized from bounded numeric components so account names,
/// server addresses, tokens, and other arbitrary strings cannot be smuggled
/// through resource construction. The opaque installation identifier enables
/// correlation of technical events from one app installation.
public struct RemoteTelemetryResource: Equatable, Sendable {
    public static let serviceName = "bleat"

    public let applicationVersion: String
    public let applicationBuild: String
    public let platform: RemoteTelemetryPlatform
    public let operatingSystemVersion: String
    public let installationID: UUID

    public init(
        applicationVersion: String,
        applicationBuild: String,
        platform: RemoteTelemetryPlatform,
        operatingSystemMajorVersion: Int,
        operatingSystemMinorVersion: Int,
        operatingSystemPatchVersion: Int,
        installationID: UUID
    ) throws {
        guard
            let normalizedVersion = Self.normalizedApplicationVersion(
                applicationVersion
            )
        else {
            throw RemoteTelemetryResourceError.invalidApplicationVersion
        }
        guard let normalizedBuild = Self.normalizedBuild(applicationBuild)
        else {
            throw RemoteTelemetryResourceError.invalidApplicationBuild
        }
        let osComponents = [
            operatingSystemMajorVersion,
            operatingSystemMinorVersion,
            operatingSystemPatchVersion,
        ]
        guard osComponents.allSatisfy({ (0...65_535).contains($0) }) else {
            throw RemoteTelemetryResourceError.invalidOperatingSystemVersion
        }

        self.applicationVersion = normalizedVersion
        self.applicationBuild = normalizedBuild
        self.platform = platform
        self.installationID = installationID
        operatingSystemVersion = osComponents.map(String.init).joined(
            separator: "."
        )
    }

    var encodedAttributes: [String: String] {
        [
            "service.name": Self.serviceName,
            "service.version": applicationVersion,
            "bleat.app.build": applicationBuild,
            "os.type": platform.rawValue,
            "os.version": operatingSystemVersion,
            "service.instance.id": installationID.uuidString.lowercased(),
        ]
    }

    private static func normalizedApplicationVersion(
        _ value: String
    ) -> String? {
        let parts = value.split(
            separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var normalized: [String] = []
        for part in parts {
            guard !part.isEmpty,
                part.allSatisfy(\.isNumber),
                let component = UInt16(part)
            else {
                return nil
            }
            normalized.append(String(component))
        }
        return normalized.joined(separator: ".")
    }

    private static func normalizedBuild(_ value: String) -> String? {
        guard !value.isEmpty,
            value.allSatisfy(\.isNumber),
            let build = UInt32(value)
        else {
            return nil
        }
        return String(build)
    }
}

struct RemoteTelemetryEncodedSpan: Equatable, Sendable {
    let name: String
    let attributes: [String: String]
}

public enum RemoteTelemetryBufferOverflowPolicy: Equatable, Sendable {
    case dropOldest
}

/// Reviewed collection limits for the exporter introduced by issue 61.
public struct RemoteTelemetryCollectionPolicy: Equatable, Sendable {
    public let samplingRatio: Double
    public let maximumBufferedAge: TimeInterval
    public let maximumBufferedBytes: Int
    public let maximumBufferedSpanCount: Int?
    public let overflowPolicy: RemoteTelemetryBufferOverflowPolicy

    public static let `default` = RemoteTelemetryCollectionPolicy(
        samplingRatio: 1,
        maximumBufferedAge: 2 * 60 * 60,
        maximumBufferedBytes: 128 * 1_024 * 1_024,
        maximumBufferedSpanCount: nil,
        overflowPolicy: .dropOldest
    )
}
