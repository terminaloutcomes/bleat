import BleatCore
import Foundation

struct DiagnosticsEnvironment: Equatable, Sendable {
    let appVersion: String
    let operatingSystem: String

    @MainActor
    static var current: DiagnosticsEnvironment {
        let bundle = Bundle.main
        return DiagnosticsEnvironment(
            appVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "Unknown",
            operatingSystem: PlatformDevice.operatingSystem
        )
    }
}

struct DiagnosticsReport: Equatable, Sendable {
    let generatedAt: Date
    let environment: DiagnosticsEnvironment
    let appState: String
    let accountCount: Int
    let serverVersion: String?
    let connectionState: String?
    let localServerState: String?
    let lastServerConnection: String?
    let authenticationEndpoint: String?
    let apiEndpoint: String?
    let webSocketEndpoint: String?
    let webSocketState: String
    let libraryState: String
    let homeState: String
    let searchState: String
    let playbackState: String
    let playbackSyncState: String
    let privateCloudState: String
    let downloadCount: Int
    let errorCodes: [String]

    var text: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let errors =
            errorCodes.isEmpty
            ? "None"
            : errorCodes.joined(separator: ", ")
        return """
            Bleat Diagnostics
            Generated: \(formatter.string(from: generatedAt))
            App: \(environment.appVersion)
            Operating system: \(environment.operatingSystem)
            App state: \(appState)
            Saved accounts: \(accountCount)
            Server version: \(serverVersion ?? "Unavailable")
            Connection state: \(connectionState ?? "No active account")
            Local server: \(localServerState ?? "No active account")
            Last server activity: \(lastServerConnection ?? "Not recorded this launch")
            Last authentication: \(authenticationEndpoint ?? "Not recorded this launch")
            Last API connection: \(apiEndpoint ?? "Not recorded this launch")
            WebSocket endpoint: \(webSocketEndpoint ?? "No active account")
            WebSocket state: \(webSocketState)
            Libraries: \(libraryState)
            Home: \(homeState)
            Search: \(searchState)
            Playback: \(playbackState)
            Playback sync: \(playbackSyncState)
            iCloud sync: \(privateCloudState)
            Downloads: \(downloadCount)
            Active error codes: \(errors)

            Privacy: This report includes server hostnames for connection \
            diagnosis. It excludes credentials, cookies, tokens, usernames, \
            response bodies, URL paths and queries, media URLs, playback \
            session IDs, and local file paths.
            """
    }
}

extension AppModel {
    func diagnosticsReport(
        generatedAt: Date = Date(),
        environment: DiagnosticsEnvironment = .current
    ) -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: generatedAt,
            environment: environment,
            appState: phase.diagnosticsLabel,
            accountCount: accounts.count,
            serverVersion: account?.serverVersion,
            connectionState: account?.connectionState.diagnosticsLabel,
            localServerState:
                endpointDiagnostics?.localServerState.diagnosticsLabel,
            lastServerConnection:
                endpointDiagnostics?.lastConnection?.diagnosticsLabel,
            authenticationEndpoint:
                endpointDiagnostics?.authentication?.diagnosticsLabel,
            apiEndpoint: endpointDiagnostics?.api?.diagnosticsLabel,
            webSocketEndpoint:
                endpointDiagnostics?.webSocket.diagnosticsLabel,
            webSocketState: liveUpdateConnectionState.diagnosticsLabel,
            libraryState: libraries.diagnosticsLabel,
            homeState: homeShelves.diagnosticsLabel,
            searchState: searchResults.diagnosticsLabel,
            playbackState: playback.state.diagnosticsLabel,
            playbackSyncState: playback.syncState.diagnosticsLabel,
            privateCloudState: privateCloudState.diagnosticsLabel,
            downloadCount: downloads.records.count,
            errorCodes: activeDiagnosticsErrors
        )
    }

    private var activeDiagnosticsErrors: [String] {
        var errors: [AppFailure] = []
        if case .unavailable(let failure) = phase {
            errors.append(failure)
        }
        if case .failed(let failure) = loginStatus {
            errors.append(failure)
        }
        if case .failed(let failure) = accountActionStatus {
            errors.append(failure)
        }
        errors.append(
            contentsOf: [
                libraries.failure,
                homeShelves.failure,
                searchResults.failure,
                bookDetail.failure,
                playback.state.failure,
                bookmarkFailure,
                bookEditFailure,
                bookDeletionFailure,
                privateCloudState.failure,
            ].compactMap(\.self))
        return Array(Set(errors.flatMap(\.diagnosticsCodes))).sorted()
    }

    private var bookmarkFailure: AppFailure? {
        if case .failed(let failure) = playback.bookmarkState {
            return failure
        }
        return nil
    }

    private var bookEditFailure: AppFailure? {
        switch bookEditSaveState {
        case .failed(let failure),
            .metadataSavedCoverFailed(_, let failure):
            failure
        case .idle, .saving, .stale, .saved:
            nil
        }
    }

    private var bookDeletionFailure: AppFailure? {
        if case .failed(let failure) = bookDeletionState {
            return failure
        }
        return nil
    }
}

extension AudiobookshelfLiveConnectionState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .connecting:
            "Connecting"
        case .authenticated:
            "Authenticated"
        case .disconnected:
            "Disconnected"
        case .suspendedForLowDataMode:
            "Suspended — Low Data Mode"
        case .failed:
            "Failed"
        }
    }
}

extension AppPhase {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .launching:
            "Launching"
        case .signedOut:
            "Signed out"
        case .signedIn:
            "Signed in"
        case .unavailable:
            "Unavailable"
        }
    }
}

extension ResourceState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .idle:
            "Idle"
        case .loading:
            "Loading"
        case .loaded:
            "Loaded"
        case .failed:
            "Failed"
        }
    }

    fileprivate var failure: AppFailure? {
        if case .failed(let failure) = self {
            return failure
        }
        return nil
    }
}

extension AccountConnectionState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .connected:
            "Connected"
        case .offline:
            "Offline"
        case .reauthenticationRequired:
            "Reauthentication required"
        }
    }
}

extension PlaybackState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .idle:
            "Idle"
        case .preparing:
            "Preparing"
        case .ready:
            "Ready"
        case .buffering:
            "Buffering"
        case .playing:
            "Playing"
        case .paused:
            "Paused"
        case .ended:
            "Ended"
        case .failed:
            "Failed"
        }
    }

    fileprivate var failure: AppFailure? {
        if case .failed(let failure) = self {
            return failure
        }
        return nil
    }
}

extension PlaybackSyncState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .idle:
            "Idle"
        case .syncing:
            "Syncing"
        case .failed:
            "Failed"
        }
    }
}

extension PrivateCloudState {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .disabled: "Disabled"
        case .idle: "Idle"
        case .syncing: "Syncing"
        case .cancelling: "Cancelling"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        }
    }

    fileprivate var failure: AppFailure? {
        if case .failed(let failure) = self {
            return failure
        }
        return nil
    }
}

extension AppFailure {
    var diagnosticFailureCode: DiagnosticFailureCode {
        switch (operation, cause) {
        case (.loadBook, .itemNotFound): .bookNotFound
        case (.loadBook, .permissionDenied): .bookAccessDenied
        case (.loadBook, .authenticationRequired): .bookAuthenticationRequired
        case (.loadBook, .invalidServerResponse): .bookResponseInvalid
        case (.loadBook, .localStorageUnavailable): .bookStorageUnavailable
        case (.loadBook, .unavailableOffline): .bookUnavailableOffline
        case (.loadBook, .serverUnavailable): .bookUnavailable
        case (.loadBook, .requestRejected): .bookRequestRejected
        case (_, .persistenceUnavailable): .persistenceUnavailable
        case (_, .invalidInput): .invalidInput
        case (_, .serverRequiresHTTPS): .serverRequiresHTTPS
        case (_, .serverNotReady): .serverNotReady
        case (_, .serverUnsupported): .serverUnsupported
        case (_, .localLoginUnavailable): .localLoginUnavailable
        case (_, .invalidCredentials): .invalidCredentials
        case (_, .authenticationRequired): .authenticationRequired
        case (_, .permissionDenied): .permissionDenied
        case (_, .itemNotFound): .itemNotFound
        case (_, .invalidServerResponse): .invalidServerResponse
        case (_, .localStorageUnavailable): .localStorageUnavailable
        case (_, .unavailableOffline): .unavailableOffline
        case (_, .serverUnavailable): .serverUnavailable
        case (_, .timeout): .requestTimedOut
        case (_, .rateLimited): .requestRateLimited
        case (_, .requestCancelled): .requestCancelled
        case (_, .requestRejected): .requestRejected
        case (_, .mediaUnavailable): .mediaUnavailable
        case (_, .uncertainMutation): .uncertainMutation
        case (_, .authenticationCancelled): .authenticationCancelled
        case (_, .authenticationSessionInProgress):
            .authenticationSessionInProgress
        case (_, .authenticationPresentationUnavailable):
            .authenticationPresentationUnavailable
        case (_, .authenticationBrowserFailed): .authenticationBrowserFailed
        case (_, .authenticationBridgeFailed): .authenticationBridgeFailed
        case (_, .authenticationCallbackInvalid):
            .authenticationCallbackInvalid
        case (_, .authenticationCredentialInvalid):
            .authenticationCredentialInvalid
        case (_, .accountUnavailable): .accountUnavailable
        case (_, .playbackIdentityMismatch): .playbackIdentityMismatch
        case (_, .inaccessibleLibrary): .playbackLibraryInaccessible
        case (_, .inaccessibleTags): .playbackTagsInaccessible
        case (_, .explicitContentDenied): .playbackExplicitContentDenied
        case (_, .invalidPlaybackPosition): .invalidPlaybackPosition
        case (_, .unknownPlaybackChapter): .unknownPlaybackChapter
        case (_, .invalidPlaybackChapterOffset):
            .invalidPlaybackChapterOffset
        case (_, .privateCloud(let failure)):
            failure.cause.diagnosticFailureCode
        }
    }

    fileprivate var diagnosticsCodes: [String] {
        var codes = [diagnosticFailureCode.rawValue]
        if case .privateCloud(let failure) = cause,
            case .cloudKit(let cloudKit) = failure.cause
        {
            codes.append("cloudkit_\(cloudKit.code.diagnosticCode)")
            codes.append(
                contentsOf: cloudKit.partialFailureCodes.map {
                    "cloudkit_partial_\($0.diagnosticCode)"
                }
            )
        }
        return codes
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
