import Foundation
import OSLog

public enum DiagnosticCategory: String, Codable, CaseIterable, Sendable {
    case app
    case auth
    case api
    case playback
    case download
    case sync
}

public enum DiagnosticLevel: String, Codable, Sendable {
    case debug
    case info
    case notice
    case error
    case fault

    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug:
            .debug
        case .info:
            .info
        case .notice:
            .default
        case .error:
            .error
        case .fault:
            .fault
        }
    }
}

public enum DiagnosticOperation: String, Codable, Sendable {
    case appStart = "app_start"
    case restoreAccounts = "restore_accounts"
    case login
    case reauthenticate
    case switchAccount = "switch_account"
    case removeAccount = "remove_account"
    case httpRequest = "http_request"
    case loadLibraries = "load_libraries"
    case loadHome = "load_home"
    case loadLibraryPage = "load_library_page"
    case search
    case loadBook = "load_book"
    case loadBookmarks = "load_bookmarks"
    case saveMetadata = "save_metadata"
    case replaceCover = "replace_cover"
    case openPlayback = "open_playback"
    case closePlayback = "close_playback"
    case recoverPlayback = "recover_playback"
    case play
    case pause
    case seek
    case restoreDownloads = "restore_downloads"
    case resumeInterruptedDownloads = "resume_interrupted_downloads"
    case planDownload = "plan_download"
    case startDownload = "start_download"
    case pauseDownload = "pause_download"
    case resumeDownload = "resume_download"
    case cancelDownload = "cancel_download"
    case completeDownload = "complete_download"
    case repairDownload = "repair_download"
    case cleanupDownloads = "cleanup_downloads"
    case syncPlayback = "sync_playback"
    case syncLocalSessions = "sync_local_sessions"
    case syncBookmarks = "sync_bookmarks"
    case privateCloudSync = "private_cloud_sync"
    case exportRecentLogs = "export_recent_logs"
}

public enum DiagnosticState: String, Codable, Sendable {
    case launching
    case signedOut = "signed_out"
    case signedIn = "signed_in"
    case unavailable
    case idle
    case loading
    case preparing
    case ready
    case buffering
    case playing
    case paused
    case ended
    case failed
    case syncing
    case queued
    case active
    case completed
    case cancelled
}

public enum DiagnosticFailureCode: String, Codable, Sendable {
    case persistenceUnavailable = "persistence_unavailable"
    case invalidServerAddress = "invalid_server_address"
    case serverUnavailable = "server_unavailable"
    case serverRequiresHTTPS = "server_requires_https"
    case serverNotReady = "server_not_ready"
    case serverUnsupported = "server_unsupported"
    case localLoginUnavailable = "local_login_unavailable"
    case invalidCredentials = "invalid_credentials"
    case secureCredentialStorageUnavailable =
        "secure_credential_storage_unavailable"
    case loginFailed = "login_failed"
    case accountUnavailable = "account_unavailable"
    case libraryUnavailable = "library_unavailable"
    case homeUnavailable = "home_unavailable"
    case searchUnavailable = "search_unavailable"
    case bookUnavailable = "book_unavailable"
    case bookNotFound = "book_not_found"
    case bookAccessDenied = "book_access_denied"
    case bookAuthenticationRequired = "book_authentication_required"
    case bookResponseInvalid = "book_response_invalid"
    case bookStorageUnavailable = "book_storage_unavailable"
    case bookUnavailableOffline = "book_unavailable_offline"
    case bookRequestRejected = "book_request_rejected"
    case playbackDenied = "playback_denied"
    case playbackUnavailable = "playback_unavailable"
    case playbackIdentityMismatch = "playback_identity_mismatch"
    case playbackLibraryInaccessible = "playback_library_inaccessible"
    case playbackTagsInaccessible = "playback_tags_inaccessible"
    case playbackExplicitContentDenied = "playback_explicit_content_denied"
    case invalidPlaybackPosition = "invalid_playback_position"
    case unknownPlaybackChapter = "unknown_playback_chapter"
    case invalidPlaybackChapterOffset = "invalid_playback_chapter_offset"
    case playbackRecoveryExhausted = "playback_recovery_exhausted"
    case progressUnavailable = "progress_unavailable"
    case mediaUnavailable = "media_unavailable"
    case invalidMetadata = "invalid_metadata"
    case metadataUnavailable = "metadata_unavailable"
    case bookDeletionDenied = "book_deletion_denied"
    case bookDeletionUnavailable = "book_deletion_unavailable"
    case bookmarkUnavailable = "bookmark_unavailable"
    case accountRemovalFailed = "account_removal_failed"
    case requestCancelled = "request_cancelled"
    case requestTimedOut = "request_timed_out"
    case requestRateLimited = "request_rate_limited"
    case requestTransportFailed = "request_transport_failed"
    case nonHTTPResponse = "non_http_response"
    case logStorageUnavailable = "log_storage_unavailable"
    case invalidInput = "invalid_input"
    case authenticationRequired = "authentication_required"
    case permissionDenied = "permission_denied"
    case itemNotFound = "item_not_found"
    case invalidServerResponse = "invalid_server_response"
    case localStorageUnavailable = "local_storage_unavailable"
    case unavailableOffline = "unavailable_offline"
    case requestRejected = "request_rejected"
    case uncertainMutation = "uncertain_mutation"
    case authenticationCancelled = "authentication_cancelled"
    case authenticationSessionInProgress = "authentication_session_in_progress"
    case authenticationPresentationUnavailable =
        "authentication_presentation_unavailable"
    case authenticationBrowserFailed = "authentication_browser_failed"
    case authenticationBridgeFailed = "authentication_bridge_failed"
    case authenticationCallbackInvalid = "authentication_callback_invalid"
    case authenticationCredentialInvalid = "authentication_credential_invalid"
    case privateCloudDisabled = "private_cloud_disabled"
    case privateCloudCancelled = "private_cloud_cancelled"
    case privateCloudInvalidRecord = "private_cloud_invalid_record"
    case privateCloudPersistenceFailed = "private_cloud_persistence_failed"
    case privateCloudEngineUnavailable = "private_cloud_engine_unavailable"
    case privateCloudKitFailed = "private_cloudkit_failed"
    case privateCloudUnexpected = "private_cloud_unexpected"
}

/// Privacy-safe CloudKit detail retained in local diagnostics. Values are
/// derived from typed failures; CloudKit descriptions and userInfo never cross
/// this boundary because they can contain record identifiers.
public struct PrivateCloudDiagnosticDetail: Codable, Equatable, Sendable {
    public let operation: PrivateCloudSyncOperation
    public let cloudKitCode: String?
    public let partialFailureCodes: [String]
    public let retryAfterMilliseconds: Int?
    public let unexpectedErrorDomain: String?
    public let unexpectedErrorCode: Int?

    public init(
        operation: PrivateCloudSyncOperation,
        failure: PrivateCloudSyncError? = nil
    ) {
        self.operation = operation
        switch failure {
        case .cloudKit(let failure):
            cloudKitCode = failure.code.diagnosticCode
            partialFailureCodes = failure.partialFailureCodes.map(
                \.diagnosticCode
            )
            retryAfterMilliseconds = failure.retryAfterSeconds.map {
                Int(($0 * 1_000).rounded())
            }
            unexpectedErrorDomain = nil
            unexpectedErrorCode = nil
        case .unexpected(let error):
            cloudKitCode = nil
            partialFailureCodes = []
            retryAfterMilliseconds = nil
            unexpectedErrorDomain = error.domain
            unexpectedErrorCode = error.code
        case .disabled, .cancelled, .invalidRecord, .persistenceFailed,
            .engineUnavailable, .none:
            cloudKitCode = nil
            partialFailureCodes = []
            retryAfterMilliseconds = nil
            unexpectedErrorDomain = nil
            unexpectedErrorCode = nil
        }
    }
}

public enum DiagnosticEndpoint: String, Codable, CaseIterable, Sendable {
    case status
    case login
    case beginOpenID = "begin_openid"
    case completeOpenID = "complete_openid"
    case refresh
    case logout
    case authorize
    case libraries
    case libraryItems = "library_items"
    case personalized
    case search
    case item
    case play
    case directPlay = "direct_play"
    case syncSession = "sync_session"
    case closeSession = "close_session"
    case syncLocalSession = "sync_local_session"
    case syncLocalSessions = "sync_local_sessions"
    case progress
    case allProgress = "all_progress"
    case listeningStats = "listening_stats"
    case listeningSessions = "listening_sessions"
    case itemListeningSessions = "item_listening_sessions"
    case yearlyStats = "yearly_stats"
    case bookmarks
    case bookmark
    case deleteBookmark = "delete_bookmark"
    case downloadFile = "download_file"
    case cover
    case metadata
    case openIDSession = "openid_session"
}

public enum DiagnosticHTTPMethod: String, Codable, Sendable {
    case delete = "DELETE"
    case get = "GET"
    case patch = "PATCH"
    case post = "POST"
    case put = "PUT"
    case other = "OTHER"

    public init(_ method: String?) {
        switch method?.uppercased() {
        case "DELETE":
            self = .delete
        case "GET":
            self = .get
        case "PATCH":
            self = .patch
        case "POST":
            self = .post
        case "PUT":
            self = .put
        default:
            self = .other
        }
    }
}

public enum DiagnosticEventName: String, Codable, Sendable {
    case operationStarted = "operation_started"
    case operationCompleted = "operation_completed"
    case operationFailed = "operation_failed"
    case stateTransition = "state_transition"
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let category: DiagnosticCategory
    public let level: DiagnosticLevel
    public let name: DiagnosticEventName
    public let operation: DiagnosticOperation?
    public let endpoint: DiagnosticEndpoint?
    public let method: DiagnosticHTTPMethod?
    public let correlationID: UUID?
    public let statusCode: Int?
    public let durationMilliseconds: Int?
    public let count: Int?
    public let fromState: DiagnosticState?
    public let toState: DiagnosticState?
    public let failureCode: DiagnosticFailureCode?
    public let privateCloud: PrivateCloudDiagnosticDetail?

    private init(
        category: DiagnosticCategory,
        level: DiagnosticLevel,
        name: DiagnosticEventName,
        operation: DiagnosticOperation? = nil,
        endpoint: DiagnosticEndpoint? = nil,
        method: DiagnosticHTTPMethod? = nil,
        correlationID: UUID? = nil,
        statusCode: Int? = nil,
        durationMilliseconds: Int? = nil,
        count: Int? = nil,
        fromState: DiagnosticState? = nil,
        toState: DiagnosticState? = nil,
        failureCode: DiagnosticFailureCode? = nil,
        privateCloud: PrivateCloudDiagnosticDetail? = nil
    ) {
        self.category = category
        self.level = level
        self.name = name
        self.operation = operation
        self.endpoint = endpoint
        self.method = method
        self.correlationID = correlationID
        self.statusCode = statusCode
        self.durationMilliseconds = durationMilliseconds
        self.count = count
        self.fromState = fromState
        self.toState = toState
        self.failureCode = failureCode
        self.privateCloud = privateCloud
    }

    public static func started(
        _ operation: DiagnosticOperation,
        category: DiagnosticCategory,
        endpoint: DiagnosticEndpoint? = nil,
        method: DiagnosticHTTPMethod? = nil,
        correlationID: UUID? = nil,
        count: Int? = nil
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: category,
            level: .debug,
            name: .operationStarted,
            operation: operation,
            endpoint: endpoint,
            method: method,
            correlationID: correlationID,
            count: count
        )
    }

    public static func completed(
        _ operation: DiagnosticOperation,
        category: DiagnosticCategory,
        endpoint: DiagnosticEndpoint? = nil,
        method: DiagnosticHTTPMethod? = nil,
        correlationID: UUID? = nil,
        statusCode: Int? = nil,
        durationMilliseconds: Int? = nil,
        count: Int? = nil
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: category,
            level: .info,
            name: .operationCompleted,
            operation: operation,
            endpoint: endpoint,
            method: method,
            correlationID: correlationID,
            statusCode: statusCode,
            durationMilliseconds: durationMilliseconds,
            count: count
        )
    }

    public static func failed(
        _ operation: DiagnosticOperation,
        category: DiagnosticCategory,
        failureCode: DiagnosticFailureCode,
        endpoint: DiagnosticEndpoint? = nil,
        method: DiagnosticHTTPMethod? = nil,
        correlationID: UUID? = nil,
        durationMilliseconds: Int? = nil
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: category,
            level: .error,
            name: .operationFailed,
            operation: operation,
            endpoint: endpoint,
            method: method,
            correlationID: correlationID,
            durationMilliseconds: durationMilliseconds,
            failureCode: failureCode
        )
    }

    public static func transition(
        category: DiagnosticCategory,
        from: DiagnosticState,
        to: DiagnosticState
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: category,
            level: .debug,
            name: .stateTransition,
            fromState: from,
            toState: to
        )
    }

    public static func privateCloudStarted(
        operation: PrivateCloudSyncOperation,
        correlationID: UUID
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .sync,
            level: .debug,
            name: .operationStarted,
            operation: .privateCloudSync,
            correlationID: correlationID,
            privateCloud: PrivateCloudDiagnosticDetail(operation: operation)
        )
    }

    public static func privateCloudCompleted(
        operation: PrivateCloudSyncOperation,
        correlationID: UUID,
        durationMilliseconds: Int,
        recordCount: Int? = nil
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .sync,
            level: .info,
            name: .operationCompleted,
            operation: .privateCloudSync,
            correlationID: correlationID,
            durationMilliseconds: durationMilliseconds,
            count: recordCount,
            privateCloud: PrivateCloudDiagnosticDetail(operation: operation)
        )
    }

    public static func privateCloudFailed(
        failure: PrivateCloudSyncFailure,
        correlationID: UUID,
        durationMilliseconds: Int,
        recordCount: Int? = nil
    ) -> DiagnosticEvent {
        DiagnosticEvent(
            category: .sync,
            level: failure.cause == .cancelled ? .notice : .error,
            name: .operationFailed,
            operation: .privateCloudSync,
            correlationID: correlationID,
            durationMilliseconds: durationMilliseconds,
            count: recordCount,
            failureCode: failure.cause.diagnosticFailureCode,
            privateCloud: PrivateCloudDiagnosticDetail(
                operation: failure.operation,
                failure: failure.cause
            )
        )
    }

    public var text: String {
        var fields = [
            "level=\(level.rawValue)",
            "category=\(category.rawValue)",
            "event=\(name.rawValue)",
        ]
        if let operation {
            fields.append("operation=\(operation.rawValue)")
        }
        if let endpoint {
            fields.append("endpoint=\(endpoint.rawValue)")
        }
        if let method {
            fields.append("method=\(method.rawValue)")
        }
        if let correlationID {
            fields.append(
                "correlation=\(correlationID.uuidString.lowercased())"
            )
        }
        if let statusCode {
            fields.append("status=\(statusCode)")
        }
        if let durationMilliseconds {
            fields.append("duration_ms=\(durationMilliseconds)")
        }
        if let count {
            fields.append("count=\(count)")
        }
        if let fromState {
            fields.append("from=\(fromState.rawValue)")
        }
        if let toState {
            fields.append("to=\(toState.rawValue)")
        }
        if let failureCode {
            fields.append("failure=\(failureCode.rawValue)")
        }
        if let privateCloud {
            fields.append("cloud_operation=\(privateCloud.operation.rawValue)")
            if let cloudKitCode = privateCloud.cloudKitCode {
                fields.append("cloudkit_code=\(cloudKitCode)")
            }
            if !privateCloud.partialFailureCodes.isEmpty {
                fields.append(
                    "cloudkit_partial_codes=\(privateCloud.partialFailureCodes.joined(separator: ","))"
                )
            }
            if let retryAfterMilliseconds =
                privateCloud.retryAfterMilliseconds
            {
                fields.append("retry_after_ms=\(retryAfterMilliseconds)")
            }
            if let unexpectedErrorDomain =
                privateCloud.unexpectedErrorDomain
            {
                fields.append("error_domain=\(unexpectedErrorDomain)")
            }
            if let unexpectedErrorCode = privateCloud.unexpectedErrorCode {
                fields.append("error_code=\(unexpectedErrorCode)")
            }
        }
        return fields.joined(separator: " ")
    }
}

extension PrivateCloudSyncError {
    fileprivate var diagnosticFailureCode: DiagnosticFailureCode {
        switch self {
        case .disabled: .privateCloudDisabled
        case .cancelled: .privateCloudCancelled
        case .invalidRecord: .privateCloudInvalidRecord
        case .persistenceFailed: .privateCloudPersistenceFailed
        case .engineUnavailable: .privateCloudEngineUnavailable
        case .cloudKit: .privateCloudKitFailed
        case .unexpected: .privateCloudUnexpected
        }
    }
}

public protocol DiagnosticRecording: Sendable {
    func record(_ event: DiagnosticEvent) async
}

public actor SystemDiagnosticRecorder: DiagnosticRecording {
    public static let shared = SystemDiagnosticRecorder()

    public init() {}

    public func record(_ event: DiagnosticEvent) {
        let logger = Logger(
            subsystem: AppIdentifier,
            category: event.category.rawValue
        )
        logger.log(
            level: event.level.osLogType,
            "\(event.text, privacy: .public)"
        )
    }
}
