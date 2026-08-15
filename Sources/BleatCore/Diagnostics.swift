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
    case authenticationBrowserFailed = "authentication_browser_failed"
    case authenticationBridgeFailed = "authentication_bridge_failed"
    case authenticationCallbackInvalid = "authentication_callback_invalid"
    case authenticationCredentialInvalid = "authentication_credential_invalid"
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
    case historyTruncated = "history_truncated"
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
        failureCode: DiagnosticFailureCode? = nil
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

    public static var historyTruncated: DiagnosticEvent {
        DiagnosticEvent(
            category: .app,
            level: .notice,
            name: .historyTruncated
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
        return fields.joined(separator: " ")
    }
}

public struct DiagnosticRecord: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let event: DiagnosticEvent

    public init(timestamp: Date, event: DiagnosticEvent) {
        self.timestamp = timestamp
        self.event = event
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

public actor CompositeDiagnosticRecorder: DiagnosticRecording {
    private let recorders: [any DiagnosticRecording]

    public init(_ recorders: [any DiagnosticRecording]) {
        self.recorders = recorders
    }

    public func record(_ event: DiagnosticEvent) async {
        for recorder in recorders {
            await recorder.record(event)
        }
    }
}

public struct DisabledDiagnosticRecorder: DiagnosticRecording {
    public init() {}

    public func record(_ event: DiagnosticEvent) async {}
}
