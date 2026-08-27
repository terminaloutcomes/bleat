import BleatCore

extension AppModel {
    var activeDiagnosticErrorCodes: [String] {
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
    var diagnosticsLabel: String {
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
    var diagnosticsLabel: String {
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
    var diagnosticsLabel: String {
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
    var diagnosticsLabel: String {
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
    var diagnosticsLabel: String {
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
    var diagnosticsLabel: String {
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
    var diagnosticsLabel: String {
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
        case (_, .localDataReset(.downloads)):
            .localDataResetDownloadsFailed
        case (_, .localDataReset(.credentials)):
            .localDataResetCredentialsFailed
        case (_, .localDataReset(.persistentStore)):
            .localDataResetStoreFailed
        case (_, .persistenceUnavailable): .persistenceUnavailable
        case (_, .storedDataMigrationFailed): .storedDataMigrationFailed
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
