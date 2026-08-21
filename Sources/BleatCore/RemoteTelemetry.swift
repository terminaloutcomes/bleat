import Foundation

/// The application-facing tracing boundary. It deliberately exposes no raw
/// OpenTelemetry span names or attribute dictionaries.
public protocol RemoteTelemetryTracing: Sendable {
    func beginSpan(
        operation: RemoteTelemetryOperation,
        source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket
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
}

/// A single reviewed operation. Ending is idempotent so cancellation and
/// replacement paths may safely race without producing duplicate spans.
public final class RemoteTelemetrySpan: @unchecked Sendable {
    private let lock = NSLock()
    private var endAction: (@Sendable (RemoteTelemetryOutcome) -> Void)?

    public init(
        endAction: @escaping @Sendable (RemoteTelemetryOutcome) -> Void
    ) {
        self.endAction = endAction
    }

    public func end(_ outcome: RemoteTelemetryOutcome) {
        let action = lock.withLock {
            let action = endAction
            endAction = nil
            return action
        }
        action?(outcome)
    }

    static let inactive = RemoteTelemetrySpan { _ in }
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
    case libraryRefresh = "bleat.library.refresh"
    case playbackPreparation = "bleat.playback.prepare"
    case playbackStart = "bleat.playback.start"
    case downloadTransfer = "bleat.download.transfer"
    case playbackProgressSync = "bleat.playback.progress_sync"
    case transcription = "bleat.transcription.run"
    case privateCloudSync = "bleat.cloudkit.sync"

    var subsystem: RemoteTelemetrySubsystem {
        switch self {
        case .appLaunch:
            .app
        case .accountConnection:
            .authentication
        case .libraryRefresh:
            .library
        case .playbackPreparation, .playbackStart:
            .playback
        case .downloadTransfer:
            .download
        case .playbackProgressSync, .privateCloudSync:
            .synchronization
        case .transcription:
            .transcription
        }
    }
}

/// The reviewed CloudKit log boundary. It intentionally accepts the typed
/// lifecycle event rather than an arbitrary body or attributes dictionary.
public protocol RemoteTelemetryLogging: Sendable {
    func recordPrivateCloudEvent(_ event: PrivateCloudSyncEvent)
}

public struct InactiveRemoteTelemetryLogger: RemoteTelemetryLogging {
    public init() {}

    public func recordPrivateCloudEvent(_ event: PrivateCloudSyncEvent) {}
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
        logger.recordPrivateCloudEvent(event)
        switch event.phase {
        case .started:
            spans[event.correlationID] = tracer.beginSpan(
                operation: .privateCloudSync
            )
        case .completed:
            spans.removeValue(forKey: event.correlationID)?.end(.succeeded)
        case .failed(let failure):
            spans.removeValue(forKey: event.correlationID)?.end(
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
}

public enum RemoteTelemetrySource: String, CaseIterable, Sendable {
    case downloaded
    case streamed
    case offline
    case remote
    case cache
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

/// A reviewed remote span description with no arbitrary name or attribute API.
public struct RemoteTelemetrySpanDescriptor: Equatable, Sendable {
    public let operation: RemoteTelemetryOperation
    public let outcome: RemoteTelemetryOutcome
    public let source: RemoteTelemetrySource?
    public let retryBucket: RemoteTelemetryRetryBucket

    public init(
        operation: RemoteTelemetryOperation,
        outcome: RemoteTelemetryOutcome,
        source: RemoteTelemetrySource? = nil,
        retryBucket: RemoteTelemetryRetryBucket = .none
    ) {
        self.operation = operation
        self.outcome = outcome
        self.source = source
        self.retryBucket = retryBucket
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
        if case .failed(let category) = outcome {
            attributes["bleat.failure.category"] = category.rawValue
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
        case .failed:
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

/// Stable resource data permitted on every remote span.
///
/// Versions are normalized from bounded numeric components so account names,
/// server addresses, tokens, and other arbitrary strings cannot be smuggled
/// through resource construction.
public struct RemoteTelemetryResource: Equatable, Sendable {
    public static let serviceName = "bleat"

    public let applicationVersion: String
    public let applicationBuild: String
    public let platform: RemoteTelemetryPlatform
    public let operatingSystemVersion: String

    public init(
        applicationVersion: String,
        applicationBuild: String,
        platform: RemoteTelemetryPlatform,
        operatingSystemMajorVersion: Int,
        operatingSystemMinorVersion: Int,
        operatingSystemPatchVersion: Int
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
