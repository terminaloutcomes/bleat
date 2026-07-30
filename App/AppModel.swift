import BleatCore
import Foundation
import Observation

enum AppPhase: Equatable, Sendable {
    case launching
    case signedOut
    case signedIn
    case unavailable(AppFailure)
}

enum LoginStatus: Equatable, Sendable {
    case idle
    case submitting
    case failed(AppFailure)
}

enum ResourceState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(AppFailure)
}

enum AccountActionStatus: Equatable, Sendable {
    case idle
    case switching
    case removing
    case failed(AppFailure)
}

enum PrivateCloudState: Equatable, Sendable {
    case disabled
    case idle
    case syncing
    case failed(AppFailure)
}

enum AccountDownloadDisposition: Equatable, Sendable {
    case keep
    case delete
}

enum AccountRemovalScope: Equatable, Sendable {
    case thisDevice
    case allDevices
}

enum AccountStatisticsDisposition: Equatable, Sendable {
    case keep
    case delete
}

enum BookEditSaveState: Equatable, Sendable {
    case idle
    case saving
    case stale(LibraryBookDetail)
    case saved
    case metadataSavedCoverFailed(LibraryBookDetail, AppFailure)
    case failed(AppFailure)
}

struct BookDeletionCleanupStatus: Equatable, Sendable {
    let cacheCleanupFailed: Bool
    let localDownloadCleanupFailed: Bool

    var hasWarning: Bool {
        cacheCleanupFailed || localDownloadCleanupFailed
    }
}

enum BookDeletionState: Equatable, Sendable {
    case idle
    case deleting
    case deleted(BookDeletionCleanupStatus)
    case failed(AppFailure)
}

enum BookProgressUpdateState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(AppFailure)
}

enum LibraryPaginationState: Equatable, Sendable {
    case idle
    case loading
    case failed(AppFailure)
}

enum AppFailureOperation: String, Equatable, Sendable {
    case appStart, login, reauthenticate, switchAccount, removeAccount
    case loadLibraries, loadLibraryPage, loadHome, search, loadBook
    case openPlayback, recoverPlayback, loadBookmarks, saveMetadata
    case replaceCover, deleteBook, updateProgress, download, localPlayback
    case loadStatistics, privateCloudSync

    var isSafeToRetry: Bool {
        switch self {
        case .loadLibraries, .loadLibraryPage, .loadHome, .search, .loadBook,
            .loadBookmarks, .loadStatistics, .privateCloudSync:
            true
        case .appStart, .login, .reauthenticate, .switchAccount, .removeAccount,
            .openPlayback, .recoverPlayback, .saveMetadata, .replaceCover,
            .deleteBook, .updateProgress, .download, .localPlayback:
            false
        }
    }
}

enum AppFailureCause: String, Equatable, Sendable {
    case persistenceUnavailable, invalidInput, serverRequiresHTTPS, serverNotReady
    case serverUnsupported, localLoginUnavailable, invalidCredentials
    case authenticationRequired, permissionDenied, itemNotFound
    case invalidServerResponse, localStorageUnavailable, unavailableOffline
    case serverUnavailable, requestRejected, mediaUnavailable, uncertainMutation

    static let notFound = Self.itemNotFound
    static let accessDenied = Self.permissionDenied
    static let reauthenticationRequired = Self.authenticationRequired
}

typealias BookDetailFailure = AppFailureCause

struct AppFailure: Equatable, Sendable {
    let operation: AppFailureOperation
    let cause: AppFailureCause

    init(_ operation: AppFailureOperation, _ cause: AppFailureCause) {
        self.operation = operation
        self.cause = cause
    }

    var title: String {
        switch cause {
        case .itemNotFound: "Audiobook not found"
        case .permissionDenied: "Access denied"
        case .authenticationRequired: "Sign in again"
        case .invalidServerResponse: "Invalid server response"
        case .localStorageUnavailable, .persistenceUnavailable: "Local storage unavailable"
        case .unavailableOffline: "Unavailable offline"
        case .serverUnavailable: "Server unavailable"
        case .serverRequiresHTTPS: "HTTPS required"
        case .serverNotReady: "Server not ready"
        case .serverUnsupported: "Server unsupported"
        case .invalidCredentials: "Sign-in rejected"
        case .invalidInput: "Check the entered information"
        case .localLoginUnavailable: "Local login unavailable"
        case .mediaUnavailable: "Playback unavailable"
        case .uncertainMutation: "Change needs attention"
        case .requestRejected: "Request rejected"
        }
    }

    var message: String {
        switch cause {
        case .persistenceUnavailable:
            "Bleat could not open its local data store."
        case .invalidInput:
            "Review the information and try again."
        case .serverRequiresHTTPS:
            "Bleat requires an HTTPS Audiobookshelf address."
        case .serverNotReady:
            "That Audiobookshelf server is not initialized."
        case .serverUnsupported:
            "That Audiobookshelf server version is not supported."
        case .localLoginUnavailable:
            "That server does not offer username and password login."
        case .invalidCredentials:
            "The username or password was not accepted."
        case .authenticationRequired:
            "Your saved sign-in is no longer accepted by the server."
        case .permissionDenied:
            "This account is not allowed to perform that action."
        case .itemNotFound:
            "This audiobook may have been removed from the server."
        case .invalidServerResponse:
            "The server returned incomplete or inconsistent data."
        case .localStorageUnavailable:
            "Bleat could not save or read the required data on this device."
        case .unavailableOffline:
            "This information has not been saved for offline access."
        case .serverUnavailable:
            "Bleat could not reach the Audiobookshelf server."
        case .requestRejected:
            "The server refused this request."
        case .mediaUnavailable:
            "This audiobook could not be prepared for playback."
        case .uncertainMutation:
            "The result of this change is uncertain; Bleat kept it for safe recovery."
        }
    }

    var systemImage: String {
        switch cause {
        case .itemNotFound: "book.closed"
        case .permissionDenied: "lock"
        case .authenticationRequired: "person.crop.circle.badge.exclamationmark"
        case .invalidServerResponse, .invalidInput, .requestRejected: "exclamationmark.triangle"
        case .localStorageUnavailable, .persistenceUnavailable: "externaldrive.badge.exclamationmark"
        case .unavailableOffline, .serverUnavailable: "wifi.exclamationmark"
        case .mediaUnavailable: "play.slash"
        case .uncertainMutation: "arrow.triangle.2.circlepath"
        case .serverRequiresHTTPS: "lock.trianglebadge.exclamationmark"
        case .serverNotReady, .serverUnsupported, .localLoginUnavailable, .invalidCredentials: "exclamationmark.circle"
        }
    }

    var allowsRetry: Bool {
        operation.isSafeToRetry && (cause == .invalidServerResponse
            || cause == .localStorageUnavailable || cause == .unavailableOffline
            || cause == .serverUnavailable || cause == .requestRejected)
    }

    static let persistenceUnavailable = AppFailure(.appStart, .persistenceUnavailable)
    static let accountUnavailable = AppFailure(.appStart, .localStorageUnavailable)
    static let mediaUnavailable = AppFailure(.localPlayback, .mediaUnavailable)
    static let invalidServerAddress = AppFailure(.login, .invalidInput)
    static let serverUnavailable = AppFailure(.login, .serverUnavailable)
    static let serverRequiresHTTPS = AppFailure(.login, .serverRequiresHTTPS)
    static let serverNotReady = AppFailure(.login, .serverNotReady)
    static let serverUnsupported = AppFailure(.login, .serverUnsupported)
    static let localLoginUnavailable = AppFailure(.login, .localLoginUnavailable)
    static let invalidCredentials = AppFailure(.login, .invalidCredentials)
    static let secureCredentialStorageUnavailable = AppFailure(.login, .localStorageUnavailable)
    static let loginFailed = AppFailure(.login, .requestRejected)
    static let libraryUnavailable = AppFailure(.loadLibraries, .serverUnavailable)
    static let homeUnavailable = AppFailure(.loadHome, .serverUnavailable)
    static let searchUnavailable = AppFailure(.search, .serverUnavailable)
    static let playbackDenied = AppFailure(.openPlayback, .permissionDenied)
    static let playbackUnavailable = AppFailure(.openPlayback, .serverUnavailable)
    static let progressUnavailable = AppFailure(.updateProgress, .uncertainMutation)
    static let invalidMetadata = AppFailure(.saveMetadata, .invalidInput)
    static let metadataUnavailable = AppFailure(.saveMetadata, .uncertainMutation)
    static let bookDeletionDenied = AppFailure(.deleteBook, .permissionDenied)
    static let bookDeletionUnavailable = AppFailure(.deleteBook, .uncertainMutation)
    static let bookmarkUnavailable = AppFailure(.loadBookmarks, .serverUnavailable)
    static let accountRemovalFailed = AppFailure(.removeAccount, .uncertainMutation)

    static func bookUnavailable(_ cause: AppFailureCause) -> AppFailure {
        AppFailure(.loadBook, cause)
    }

    init(operation: AppFailureOperation, serviceError: AppServiceError) {
        self.init(operation, Self.cause(for: serviceError))
    }

    private static func cause(for error: AppServiceError) -> AppFailureCause {
        switch error {
        case .invalidServerURL(let error):
            if case .unsupportedScheme = error { return .serverRequiresHTTPS }
            return .invalidInput
        case .discovery(let error):
            switch error {
            case .uninitialized: return .serverNotReady
            case .unsupportedServerVersion, .invalidServerVersion: return .serverUnsupported
            case .malformedResponse, .wrongApplication: return .invalidServerResponse
            case .unexpectedHTTPStatus(let status): return statusCause(status)
            case .redirectMissingLocation, .redirectRequiresConfirmation,
                .tooManyRedirects, .invalidRedirect: return .requestRejected
            }
        case .discoveryRequestFailed: return .serverUnavailable
        case .onboarding(let error):
            switch error {
            case .localAuthenticationUnavailable: return .localLoginUnavailable
            case .authenticationFailed(let error):
                switch error {
                case .invalidCredentials: return .invalidCredentials
                case .credentialStorageUnavailable: return .localStorageUnavailable
                case .malformedLoginResponse, .malformedAuthorizationResponse,
                    .authorizedUserMismatch: return .invalidServerResponse
                case .unexpectedLoginStatus(let status), .unexpectedAuthorizationStatus(let status): return statusCause(status)
                case .invalidAccountID, .accountOperationInProgress,
                    .missingAccessToken, .missingRefreshToken,
                    .tokenValidationFailed, .credentialPersistenceFailed: return .authenticationRequired
                }
            case .authenticationRequestFailed: return .serverUnavailable
            case .invalidAccount: return .invalidServerResponse
            case .accountPersistenceFailed, .credentialRollbackFailed: return .localStorageUnavailable
            }
        case .accountStore, .libraryCache, .statistics:
            return .localStorageUnavailable
        case .privateCloud(let error):
            switch error {
            case .accountUnavailable:
                return .authenticationRequired
            case .disabled:
                return .requestRejected
            case .invalidRecord:
                return .invalidServerResponse
            case .persistenceFailed:
                return .localStorageUnavailable
            case .cloudUnavailable:
                return .serverUnavailable
            }
        case .libraryRepository(let error), .bookDetail(let error): return repositoryCause(error)
        case .pageRequest, .homeRequest, .searchRequest, .metadataPatch: return .invalidInput
        case .searchCoordinator(let error):
            switch error { case .cancelled, .superseded: return .serverUnavailable; case .repository(let error): return repositoryCause(error) }
        case .playbackSession(let error): return playbackSessionCause(error)
        case .playbackSource: return .mediaUnavailable
        case .playbackSync(let error): return playbackSyncCause(error)
        case .localPlaybackSession(let error): return localSessionCause(error)
        case .metadataUpdate(let error): return metadataCause(error)
        case .coverUpdate(let error): return coverCause(error)
        case .bookDeletion(let error):
            switch error { case .permissionDenied: return .permissionDenied; case .itemNotFound: return .itemNotFound; case .requestFailed: return .uncertainMutation; case .unexpectedStatus(let status): return statusCause(status); case .invalidItemID, .requestConstructionFailed, .authenticationFailed: return .requestRejected }
        case .bookmark(let error): return bookmarkCause(error)
        case .progress(let error): return progressCause(error)
        case .downloadPlan(let error):
            switch error { case .invalidItemID: return .invalidInput; case .routeConstruction: return .requestRejected; case .authenticatedRequest(let error): return authenticationCause(error); case .unexpectedStatus(let status): return statusCause(status); case .invalidPlan: return .invalidServerResponse }
        case .downloadAuthorization(let error):
            switch error { case .invalidAccountID, .accountOperationInProgress, .rejectedRequestDoesNotMatchDownload, .missingRejectedAuthorization, .malformedRejectedAuthorization: return .invalidInput; case .routeConstruction: return .requestRejected; case .authenticatedRequest(let error): return authenticationCause(error) }
        case .accountRemoval(let error):
            switch error { case .accountNotFound: return .itemNotFound; case .logoutFailed, .logoutRequestFailed: return .uncertainMutation; case .accountStoreFailed: return .localStorageUnavailable }
        }
    }

    private static func statusCause(_ status: Int) -> AppFailureCause {
        switch status { case 401: .authenticationRequired; case 403: .permissionDenied; case 404: .itemNotFound; case 408, 429, 500...599: .serverUnavailable; default: .requestRejected }
    }
    private static func repositoryCause(_ error: LibraryRepositoryError) -> AppFailureCause {
        switch error { case .remote(let error): apiCause(error); case .fallbackCache(let remote, _): apiCause(remote); case .cache: .localStorageUnavailable; case .noCachedValue: .unavailableOffline; case .cancelled: .serverUnavailable }
    }
    private static func apiCause(_ error: AudiobookshelfAPIError) -> AppFailureCause {
        switch error { case .authentication(let error): authenticationCause(error); case .unexpectedStatus(let status): statusCause(status); case .malformedResponse, .invalidLibrary, .invalidPage, .invalidLibraryItem, .invalidBookDetail, .invalidSearchResults, .invalidPersonalizedShelves: .invalidServerResponse; case .cancelled: .serverUnavailable; case .invalidAccountID, .routeConstruction: .requestRejected }
    }
    private static func authenticationCause(_ error: AuthenticatedRequestError) -> AppFailureCause {
        switch error { case .requestTransportFailed, .refreshTransportFailed, .automaticReauthenticationTransportFailed: .serverUnavailable; case .credentialsReadFailed, .missingCredentials, .refreshRejected, .missingAccessToken, .missingRefreshToken, .credentialPersistenceFailed, .savedLoginCredentialsReadFailed, .automaticReauthenticationFailed, .retriedRequestUnauthorized: .authenticationRequired; case .unexpectedRefreshStatus(let status): statusCause(status); case .invalidAccountID, .accountOperationInProgress, .authenticationEndpoint, .requestDoesNotMatchRoute, .authorizationFailed, .requestCancelled, .refreshRequestConstructionFailed, .refreshCancelled, .malformedRefreshResponse: .requestRejected }
    }
    private static func playbackSessionCause(_ error: PlaybackSessionError) -> AppFailureCause {
        switch error { case .authenticationFailed(let error): authenticationCause(error); case .unexpectedStartStatus(let status), .unexpectedCloseStatus(let status): statusCause(status); case .requestFailed: .serverUnavailable; case .malformedStartResponse, .invalidSessionResponse, .mismatchedLibraryItem: .invalidServerResponse; case .invalidLibraryItemID, .invalidDeviceInfo, .invalidSupportedMimeType, .requestConstructionFailed, .requestEncodingFailed: .invalidInput }
    }
    private static func playbackSyncCause(_ error: PlaybackSyncError) -> AppFailureCause {
        switch error { case .authenticationFailed(let error): authenticationCause(error); case .unexpectedStatus(let status): statusCause(status); case .requestFailed: .uncertainMutation; case .invalidSessionID, .invalidPosition, .invalidDuration, .invalidListeningTime, .positionExceedsDuration, .requestConstructionFailed, .requestEncodingFailed: .invalidInput }
    }
    private static func localSessionCause(_ error: LocalPlaybackSessionError) -> AppFailureCause {
        switch error { case .authenticationFailed(let error): authenticationCause(error); case .unexpectedStatus(let status): statusCause(status); case .requestFailed: .uncertainMutation; case .malformedResponse: .invalidServerResponse; case .emptyBatch, .duplicateSessionID, .invalidSessionID, .invalidMetadata, .invalidDuration, .invalidPosition, .invalidTimestamp, .invalidMVPAccounting, .invalidDeviceInfo, .requestConstructionFailed, .requestEncodingFailed: .invalidInput }
    }
    private static func metadataCause(_ error: BookMetadataUpdateError) -> AppFailureCause {
        switch error { case .authenticationFailed(let error): authenticationCause(error); case .unexpectedStatus(let status): statusCause(status); case .requestFailed: .uncertainMutation; case .malformedResponse: .invalidServerResponse; case .invalidItemID, .emptyPatch, .requestConstructionFailed, .requestEncodingFailed, .updateRejected: .invalidInput }
    }
    private static func coverCause(_ error: BookCoverUploadError) -> AppFailureCause {
        switch error { case .authenticationFailed(let error): authenticationCause(error); case .unexpectedStatus(let status): statusCause(status); case .requestFailed: .uncertainMutation; case .malformedResponse: .invalidServerResponse; case .invalidItemID, .emptyImage, .imageTooLarge, .requestConstructionFailed, .uploadRejected: .invalidInput }
    }
    private static func bookmarkCause(_ error: BookmarkError) -> AppFailureCause {
        switch error { case .authenticationFailed(let error): authenticationCause(error); case .unexpectedStatus(let status): statusCause(status); case .requestFailed: .uncertainMutation; case .malformedResponse: .invalidServerResponse; case .invalidItemID, .invalidTime, .emptyTitle, .requestConstructionFailed, .requestEncodingFailed: .invalidInput }
    }
    private static func progressCause(_ error: BookProgressError) -> AppFailureCause {
        switch error { case .authenticationFailed(let error): authenticationCause(error); case .unexpectedStatus(let status): statusCause(status); case .requestFailed: .uncertainMutation; case .malformedResponse: .invalidServerResponse; case .invalidItemID, .emptyUpdate, .invalidDuration, .invalidCurrentTime, .invalidProgress, .requestConstructionFailed, .requestEncodingFailed: .invalidInput }
    }
}

@MainActor
@Observable
final class AppModel {
    private let service: any AppServicing
    private let diagnostics: any DiagnosticRecording
    private var hasStarted = false
    private var libraryPageGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var bookDetailGeneration: UInt64 = 0
    @ObservationIgnored
    private var liveUpdatesTask: Task<Void, Never>?
    @ObservationIgnored
    private var liveRefreshTask: Task<Void, Never>?
    private var liveUpdatesAreActive = true
    private var pendingLiveLibraryRefresh = false
    private var pendingLiveItemIDs: Set<LibraryItemID> = []

    private(set) var phase: AppPhase
    private(set) var loginStatus: LoginStatus = .idle
    private(set) var accountActionStatus: AccountActionStatus = .idle
    private(set) var account: ServerAccount?
    private(set) var accounts: [ServerAccount] = []
    private(set) var libraries: ResourceState<[LibrarySummary]> = .idle
    private(set) var selectedLibrary: LibrarySummary?
    private(set) var books: ResourceState<LibraryItemsPage> = .idle
    private(set) var libraryPaginationState: LibraryPaginationState = .idle
    private(set) var librarySort: LibraryItemSort = .title
    private(set) var librarySortDescending = false
    private(set) var libraryProgressFilter: LibraryProgressFilter?
    private(set) var homeShelves: ResourceState<[LibraryBookShelf]> = .idle
    private(set) var searchQuery = ""
    private(set) var searchResults: ResourceState<[LibraryBookSummary]> = .idle
    private(set) var selectedBookID: LibraryItemID?
    private(set) var bookDetail: ResourceState<LibraryBookDetail> = .idle
    private(set) var bookBookmarks: ResourceState<[AudioBookmark]> = .idle
    private(set) var bookEditSaveState: BookEditSaveState = .idle
    private(set) var bookDeletionState: BookDeletionState = .idle
    private(set) var bookProgressUpdateState: BookProgressUpdateState = .idle
    private(set) var statistics: ResourceState<StatisticsSummary> = .idle
    private(set) var privateCloudState: PrivateCloudState = .idle
    private(set) var privateCloudSyncEnabled = true
    let playback: PlaybackModel
    let downloads: DownloadModel
    #if DEBUG
        let diagnosticLogStore: PersistentDiagnosticLogStore?
    #endif

    init(
        service: any AppServicing,
        downloadsStorageRootURL: URL? = nil,
        diagnostics: any DiagnosticRecording =
            SystemDiagnosticRecorder.shared,
        diagnosticLogStore: (any DiagnosticRecording)? = nil
    ) {
        self.service = service
        self.diagnostics = diagnostics
        let playback = PlaybackModel(
            service: service,
            diagnostics: diagnostics
        )
        let downloads = DownloadModel(
            service: service,
            storageRootURL: downloadsStorageRootURL,
            diagnostics: diagnostics
        )
        self.playback = playback
        self.downloads = downloads
        #if DEBUG
            self.diagnosticLogStore =
                diagnosticLogStore as? PersistentDiagnosticLogStore
        #endif
        playback.setAutomaticDownloadHandler { [weak downloads] activity in
            await downloads?.handleAutomaticPlaybackActivity(activity)
        }
        phase = .launching
    }

    init(
        service: any AppServicing,
        bootstrapError: AppBootstrapError,
        diagnostics: any DiagnosticRecording =
            SystemDiagnosticRecorder.shared,
        diagnosticLogStore: (any DiagnosticRecording)? = nil
    ) {
        self.service = service
        self.diagnostics = diagnostics
        let playback = PlaybackModel(
            service: service,
            diagnostics: diagnostics
        )
        let downloads = DownloadModel(
            service: service,
            diagnostics: diagnostics
        )
        self.playback = playback
        self.downloads = downloads
        #if DEBUG
            self.diagnosticLogStore =
                diagnosticLogStore as? PersistentDiagnosticLogStore
        #endif
        playback.setAutomaticDownloadHandler { [weak downloads] activity in
            await downloads?.handleAutomaticPlaybackActivity(activity)
        }
        hasStarted = true
        switch bootstrapError {
        case .persistenceUnavailable:
            phase = .unavailable(.persistenceUnavailable)
        }
    }

    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        await diagnostics.record(
            .started(.appStart, category: .app)
        )

        do {
            privateCloudSyncEnabled =
                await service.isPrivateCloudSyncEnabled()
            if privateCloudSyncEnabled {
                privateCloudState = .syncing
                do {
                    try await service.synchronizePrivateCloud()
                    privateCloudState = .idle
                } catch let error {
                    privateCloudState = .failed(
                        AppFailure(
                            operation: .privateCloudSync,
                            serviceError: error
                        )
                    )
                }
            } else {
                privateCloudState = .disabled
            }
            await diagnostics.record(
                .started(.restoreAccounts, category: .auth)
            )
            accounts = try await service.accounts()
            await diagnostics.record(
                .completed(
                    .restoreAccounts,
                    category: .auth,
                    count: accounts.count
                )
            )
            await downloads.start(account: nil)
            for storedAccount in accounts {
                await downloads.start(account: storedAccount)
                await playback.syncPendingLocalSessions(
                    for: storedAccount
                )
            }
            guard let restoredAccount = try await service.activeAccount()
            else {
                phase = .signedOut
                await diagnostics.record(
                    .transition(
                        category: .app,
                        from: .launching,
                        to: .signedOut
                    )
                )
                await diagnostics.record(
                    .completed(.appStart, category: .app)
                )
                return
            }
            account = restoredAccount
            phase = .signedIn
            await diagnostics.record(
                .transition(
                    category: .app,
                    from: .launching,
                    to: .signedIn
                )
            )
            await loadLibraries()
            await loadStatistics()
            startLiveUpdates(for: restoredAccount)
            await diagnostics.record(
                .completed(.appStart, category: .app)
            )
        } catch let error {
            let failure = AppFailure(operation: .appStart, serviceError: error)
            phase = .unavailable(failure)
            await diagnostics.record(
                .failed(
                    .appStart,
                    category: .app,
                    failureCode: failure.diagnosticFailureCode
                )
            )
            await diagnostics.record(
                .transition(
                    category: .app,
                    from: .launching,
                    to: .unavailable
                )
            )
        }
    }

    @discardableResult
    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async -> Bool {
        guard loginStatus != .submitting else {
            return false
        }
        loginStatus = .submitting
        await diagnostics.record(
            .started(.login, category: .auth)
        )

        do {
            let authenticatedAccount = try await service.login(
                serverAddress: serverAddress,
                username: username,
                password: password
            )
            account = authenticatedAccount
            accounts.removeAll { $0.id == authenticatedAccount.id }
            accounts.append(authenticatedAccount)
            accounts.sort(by: Self.sortAccounts)
            phase = .signedIn
            loginStatus = .idle
            await diagnostics.record(
                .completed(.login, category: .auth)
            )
            await diagnostics.record(
                .transition(
                    category: .app,
                    from: .signedOut,
                    to: .signedIn
                )
            )
            await downloads.start(account: authenticatedAccount)
            await playback.syncPendingLocalSessions(
                for: authenticatedAccount
            )
            await loadLibraries()
            await loadStatistics()
            await synchronizePrivateCloud()
            startLiveUpdates(for: authenticatedAccount)
            return true
        } catch let error {
            let failure = AppFailure(operation: .login, serviceError: error)
            loginStatus = .failed(failure)
            await diagnostics.record(
                .failed(
                    .login,
                    category: .auth,
                    failureCode: failure.diagnosticFailureCode
                )
            )
            return false
        }
    }

    func prepareAccountLogin() {
        loginStatus = .idle
    }

    @discardableResult
    func reauthenticate(password: String) async -> Bool {
        guard let account else {
            loginStatus = .failed(
                AppFailure(.reauthenticate, .authenticationRequired)
            )
            return false
        }
        guard loginStatus != .submitting else {
            return false
        }
        loginStatus = .submitting
        await diagnostics.record(
            .started(.reauthenticate, category: .auth)
        )

        do {
            let authenticatedAccount = try await service.reauthenticate(
                account,
                password: password
            )
            self.account = authenticatedAccount
            accounts.removeAll { $0.id == authenticatedAccount.id }
            accounts.append(authenticatedAccount)
            accounts.sort(by: Self.sortAccounts)
            loginStatus = .idle
            await diagnostics.record(
                .completed(.reauthenticate, category: .auth)
            )
            await downloads.start(account: authenticatedAccount)
            await playback.syncPendingLocalSessions(
                for: authenticatedAccount
            )
            await loadLibraries()
            startLiveUpdates(for: authenticatedAccount)
            return true
        } catch let error {
            let failure = AppFailure(operation: .reauthenticate, serviceError: error)
            loginStatus = .failed(failure)
            await diagnostics.record(
                .failed(
                    .reauthenticate,
                    category: .auth,
                    failureCode: failure.diagnosticFailureCode
                )
            )
            return false
        }
    }

    func switchAccount(to selectedAccount: ServerAccount) async {
        guard selectedAccount.id != account?.id else {
            return
        }
        guard accountActionStatus == .idle else {
            return
        }
        accountActionStatus = .switching
        stopLiveUpdates()
        await diagnostics.record(
            .started(.switchAccount, category: .auth)
        )
        do {
            try await service.activateAccount(selectedAccount)
            account = selectedAccount
            await downloads.start(account: selectedAccount)
            await playback.syncPendingLocalSessions(for: selectedAccount)
            await loadLibraries()
            startLiveUpdates(for: selectedAccount)
            accountActionStatus = .idle
            await diagnostics.record(
                .completed(.switchAccount, category: .auth)
            )
        } catch let error {
            let failure = AppFailure(operation: .switchAccount, serviceError: error)
            accountActionStatus = .failed(
                failure
            )
            if let account {
                startLiveUpdates(for: account)
            }
            await diagnostics.record(
                .failed(
                    .switchAccount,
                    category: .auth,
                    failureCode: failure.diagnosticFailureCode
                )
            )
        }
    }

    func loadLibraries() async {
        guard let account else {
            libraries = .failed(
                AppFailure(.loadLibraries, .authenticationRequired)
            )
            return
        }
        await diagnostics.record(
            .started(.loadLibraries, category: .api)
        )
        libraries = .loading
        selectedLibrary = nil
        libraryPageGeneration &+= 1
        books = .idle
        libraryPaginationState = .idle
        homeShelves = .idle
        resetSearch()
        resetBookDetail()

        do {
            let loadedLibraries = try await service.libraries(for: account)
                .filter { library in
                    library.mediaType == .book
                }
            libraries = .loaded(loadedLibraries)
            await diagnostics.record(
                .completed(
                    .loadLibraries,
                    category: .api,
                    count: loadedLibraries.count
                )
            )
            guard let firstLibrary = loadedLibraries.first else {
                return
            }
            await selectLibrary(firstLibrary)
        } catch let error {
            let failure = AppFailure(operation: .loadLibraries, serviceError: error)
            libraries = .failed(failure)
            await diagnostics.record(
                .failed(
                    .loadLibraries,
                    category: .api,
                    failureCode: failure.diagnosticFailureCode
                )
            )
        }
    }

    func selectLibrary(_ library: LibrarySummary) async {
        guard let account else {
            books = .failed(
                AppFailure(.loadLibraryPage, .authenticationRequired)
            )
            homeShelves = .failed(
                AppFailure(.loadHome, .authenticationRequired)
            )
            return
        }
        if selectedLibrary?.id != library.id {
            resetSearch()
            resetBookDetail()
        }
        selectedLibrary = library
        homeShelves = .loading
        await diagnostics.record(
            .started(.loadHome, category: .api)
        )

        await reloadBooks()
        guard self.account?.id == account.id,
            selectedLibrary?.id == library.id
        else {
            return
        }
        do {
            homeShelves = .loaded(
                try await service.homeShelves(
                    for: account,
                    libraryID: library.id
                )
            )
            let count: Int
            if case .loaded(let shelves) = homeShelves {
                count = shelves.count
            } else {
                count = 0
            }
            await diagnostics.record(
                .completed(
                    .loadHome,
                    category: .api,
                    count: count
                )
            )
        } catch {
            let failure = AppFailure(.loadHome, .serverUnavailable)
            homeShelves = .failed(failure)
            await diagnostics.record(
                .failed(
                    .loadHome,
                    category: .api,
                    failureCode: failure.diagnosticFailureCode
                )
            )
        }
    }

    func setLibrarySort(_ sort: LibraryItemSort) async {
        guard librarySort != sort else {
            return
        }
        librarySort = sort
        await reloadBooks()
    }

    func setLibrarySortDescending(_ descending: Bool) async {
        guard librarySortDescending != descending else {
            return
        }
        librarySortDescending = descending
        await reloadBooks()
    }

    func setLibraryProgressFilter(
        _ filter: LibraryProgressFilter?
    ) async {
        guard libraryProgressFilter != filter else {
            return
        }
        libraryProgressFilter = filter
        await reloadBooks()
    }

    func reloadBooks() async {
        libraryPageGeneration &+= 1
        let operationGeneration = libraryPageGeneration
        guard let account, let library = selectedLibrary else {
            books = .failed(
                AppFailure(.loadLibraryPage, .authenticationRequired)
            )
            return
        }
        books = .loading
        libraryPaginationState = .idle
        await diagnostics.record(
            .started(.loadLibraryPage, category: .api)
        )

        do {
            let page = try await service.page(
                for: account,
                libraryID: library.id,
                page: 0,
                sort: librarySort,
                descending: librarySortDescending,
                filter: libraryProgressFilter.map(
                    LibraryItemFilter.init(progress:)
                )
            )
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id
            else {
                return
            }
            books = .loaded(page)
            await diagnostics.record(
                .completed(
                    .loadLibraryPage,
                    category: .api,
                    count: page.items.count
                )
            )
        } catch let error {
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id
            else {
                return
            }
            let failure = AppFailure(operation: .loadLibraryPage, serviceError: error)
            books = .failed(failure)
            await diagnostics.record(
                .failed(
                    .loadLibraryPage,
                    category: .api,
                    failureCode: failure.diagnosticFailureCode
                )
            )
        }
    }

    func loadNextBooksPage() async {
        guard libraryPaginationState != .loading,
            let account,
            let library = selectedLibrary,
            case .loaded(let currentPage) = books,
            currentPage.hasNextPage
        else {
            return
        }
        libraryPaginationState = .loading
        let operationGeneration = libraryPageGeneration
        let nextPageNumber = currentPage.page + 1

        do {
            let nextPage = try await service.page(
                for: account,
                libraryID: library.id,
                page: nextPageNumber,
                sort: librarySort,
                descending: librarySortDescending,
                filter: libraryProgressFilter.map(
                    LibraryItemFilter.init(progress:)
                )
            )
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                case .loaded(let latestPage) = books,
                latestPage.page == currentPage.page
            else {
                return
            }
            let existingIDs = Set(latestPage.items.map(\.id))
            let newItems = nextPage.items.filter {
                !existingIDs.contains($0.id)
            }
            books = .loaded(
                LibraryItemsPage(
                    items: latestPage.items + newItems,
                    total: nextPage.total,
                    page: nextPage.page,
                    limit: nextPage.limit
                )
            )
            libraryPaginationState = .idle
        } catch let error {
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id
            else {
                return
            }
            libraryPaginationState = .failed(
                AppFailure(operation: .loadLibraryPage, serviceError: error)
            )
        }
    }

    func search(query: String) async {
        searchGeneration &+= 1
        let operationGeneration = searchGeneration
        searchQuery = query

        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty else {
            searchResults = .idle
            return
        }
        guard let account, let selectedLibrary else {
            searchResults = .failed(
                AppFailure(.search, .authenticationRequired)
            )
            return
        }
        searchResults = .loading
        await diagnostics.record(
            .started(.search, category: .api)
        )

        do {
            let results = try await service.search(
                for: account,
                libraryID: selectedLibrary.id,
                query: normalizedQuery
            )
            guard searchGeneration == operationGeneration else {
                return
            }
            searchResults = .loaded(results)
            await diagnostics.record(
                .completed(
                    .search,
                    category: .api,
                    count: results.count
                )
            )
        } catch let error {
            guard searchGeneration == operationGeneration,
                !Task.isCancelled
            else {
                return
            }
            let failure = AppFailure(operation: .search, serviceError: error)
            searchResults = .failed(failure)
            await diagnostics.record(
                .failed(
                    .search,
                    category: .api,
                    failureCode: failure.diagnosticFailureCode
                )
            )
        }
    }

    func loadBookDetail(_ book: LibraryBookSummary) async {
        bookProgressUpdateState = .idle
        bookDetailGeneration &+= 1
        let operationGeneration = bookDetailGeneration
        selectedBookID = book.id
        bookBookmarks = .idle

        guard let account else {
            bookDetail = .failed(
                AppFailure(.loadBook, .authenticationRequired)
            )
            return
        }
        bookDetail = .loading
        await diagnostics.record(
            .started(.loadBook, category: .api)
        )

        do {
            let detail = try await service.bookDetail(
                for: account,
                libraryID: book.libraryID,
                itemID: book.id
            )
            guard bookDetailGeneration == operationGeneration else {
                return
            }
            bookDetail = .loaded(detail)
            await diagnostics.record(
                .completed(.loadBook, category: .api)
            )
            await loadBookBookmarks()
        } catch let error {
            guard bookDetailGeneration == operationGeneration,
                !Task.isCancelled
            else {
                return
            }
            let failure = AppFailure(operation: .loadBook, serviceError: error)
            bookDetail = .failed(failure)
            await diagnostics.record(
                .failed(
                    .loadBook,
                    category: .api,
                    failureCode: failure.diagnosticFailureCode
                )
            )
        }
    }

    func loadBookBookmarks() async {
        let operationGeneration = bookDetailGeneration
        guard let account, let itemID = selectedBookID else {
            bookBookmarks = .failed(
                AppFailure(.loadBookmarks, .authenticationRequired)
            )
            return
        }
        bookBookmarks = .loading
        do {
            let bookmarks = try await service.bookmarks(
                for: account,
                itemID: itemID
            )
            guard bookDetailGeneration == operationGeneration,
                selectedBookID == itemID
            else {
                return
            }
            bookBookmarks = .loaded(bookmarks)
        } catch let error {
            guard bookDetailGeneration == operationGeneration,
                selectedBookID == itemID,
                !Task.isCancelled
            else {
                return
            }
            bookBookmarks = .failed(
                AppFailure(operation: .loadBookmarks, serviceError: error)
            )
        }
    }

    func saveBookEdits(
        draft: BookMetadataDraft,
        baseline: LibraryBookDetail,
        coverJPEGData: Data?,
        overwrite: Bool = false
    ) async {
        guard let account else {
            bookEditSaveState = .failed(
                AppFailure(.saveMetadata, .authenticationRequired)
            )
            return
        }
        guard bookEditSaveState != .saving else {
            return
        }
        bookEditSaveState = .saving
        do {
            switch try await service.saveMetadata(
                for: account,
                baseline: baseline,
                draft: draft,
                overwrite: overwrite
            ) {
            case .saved(let detail):
                selectedBookID = detail.id
                bookDetail = .loaded(detail)
                guard let coverJPEGData else {
                    bookEditSaveState = .saved
                    return
                }
                do {
                    let updated = try await service.replaceCover(
                        for: account,
                        detail: detail,
                        jpegData: coverJPEGData
                    )
                    selectedBookID = updated.id
                    bookDetail = .loaded(updated)
                    bookEditSaveState = .saved
                } catch let error {
                    bookEditSaveState = .metadataSavedCoverFailed(
                        detail,
                        AppFailure(operation: .replaceCover, serviceError: error)
                    )
                }
            case .stale(let latest):
                bookEditSaveState = .stale(latest)
            }
        } catch let error {
            bookEditSaveState = .failed(
                AppFailure(operation: .saveMetadata, serviceError: error)
            )
        }
    }

    func resetBookEditSaveState() {
        bookEditSaveState = .idle
    }

    func deleteBook(
        _ detail: LibraryBookDetail,
        mode: BookDeletionMode
    ) async {
        guard let account else {
            bookDeletionState = .failed(
                AppFailure(.deleteBook, .authenticationRequired)
            )
            return
        }
        guard bookDeletionState != .deleting else {
            return
        }
        bookDeletionState = .deleting

        let isActiveBook =
            playback.hasActiveBook
            && playback.accountID == account.id
            && playback.itemID == detail.id
        let localRecord =
            isActiveBook
            ? downloads.record(
                accountID: account.id,
                itemID: detail.id
            )
            : nil
        if isActiveBook {
            await playback.stop()
        }

        do {
            let serviceOutcome = try await service.deleteBook(
                for: account,
                detail: detail,
                mode: mode
            )
            let localDownloadCleanupFailed: Bool
            if let localRecord {
                localDownloadCleanupFailed =
                    !(await downloads.remove(localRecord))
            } else {
                localDownloadCleanupFailed = false
            }
            let cacheCleanupFailed =
                serviceOutcome == .deletedWithCacheCleanupFailure
            bookDeletionState = .deleted(
                BookDeletionCleanupStatus(
                    cacheCleanupFailed: cacheCleanupFailed,
                    localDownloadCleanupFailed:
                        localDownloadCleanupFailed
                )
            )
            if selectedLibrary?.id == detail.libraryID {
                await reloadAfterBookDeletion()
            }
        } catch let error {
            bookDeletionState = .failed(
                AppFailure(operation: .deleteBook, serviceError: error)
            )
        }
    }

    func resetBookDeletionState() {
        bookDeletionState = .idle
    }

    func completeBookDeletion() {
        bookDetailGeneration &+= 1
        selectedBookID = nil
        bookDetail = .idle
        bookBookmarks = .idle
        bookEditSaveState = .idle
        bookDeletionState = .idle
    }

    private func reloadAfterBookDeletion() async {
        guard let library = selectedLibrary else {
            return
        }
        let activeQuery = searchQuery
        await selectLibrary(library)
        if !activeQuery.isEmpty {
            await search(query: activeQuery)
        }
    }

    func setFinished(
        _ isFinished: Bool,
        detail: LibraryBookDetail
    ) async {
        guard let account else {
            bookProgressUpdateState = .failed(
                AppFailure(.updateProgress, .authenticationRequired)
            )
            return
        }
        guard bookProgressUpdateState != .saving else {
            return
        }
        bookProgressUpdateState = .saving
        do {
            try await service.updateBookProgress(
                for: account,
                itemID: detail.id,
                update: BookProgressUpdate(isFinished: isFinished)
            )
            if isFinished {
                try? await service.recordCompletion(
                    CompletionMilestone(
                        accountID: account.id,
                        itemID: detail.id,
                        completedAt: Date(),
                        duration: detail.duration,
                        title: detail.title,
                        author: detail.authors.map(\.name).joined(
                            separator: ", "
                        ),
                        evidence: .explicitMarkFinished
                    )
                )
            }
            let updated = try await service.bookDetail(
                for: account,
                libraryID: detail.libraryID,
                itemID: detail.id
            )
            selectedBookID = updated.id
            bookDetail = .loaded(updated)
            bookProgressUpdateState = .saved
        } catch let error {
            bookProgressUpdateState = .failed(
                AppFailure(operation: .updateProgress, serviceError: error)
            )
        }
    }

    func playDownloaded(_ record: DownloadedBookRecord) async {
        let recordAccount = accounts.first {
            $0.id == record.manifest.accountID
        }
        do {
            let urls = try await downloads.localTrackURLs(
                for: record
            )
            await playback.startDownloaded(
                detail: record.detail,
                trackURLs: urls,
                accountID: record.manifest.accountID,
                account: recordAccount
            )
        } catch {
            playback.fail(.mediaUnavailable)
        }
    }

    func loadStatistics() async {
        statistics = .loading
        do {
            statistics = .loaded(
                try await service.statisticsSummary(
                    query: StatisticsQuery(accountID: account?.id)
                )
            )
        } catch let error {
            statistics = .failed(
                AppFailure(
                    operation: .loadStatistics,
                    serviceError: error
                )
            )
        }
    }

    func synchronizePrivateCloud() async {
        guard privateCloudSyncEnabled,
            privateCloudState != .syncing
        else {
            return
        }
        privateCloudState = .syncing
        do {
            try await service.synchronizePrivateCloud()
            accounts = try await service.accounts()
            if let active = try await service.activeAccount() {
                account = active
            }
            playback.reloadSyncedPreferences()
            downloads.reloadSyncedPreferences()
            privateCloudState = .idle
            await loadStatistics()
        } catch let error {
            privateCloudState = .failed(
                AppFailure(
                    operation: .privateCloudSync,
                    serviceError: error
                )
            )
        }
    }

    func setPrivateCloudSyncEnabled(
        _ enabled: Bool,
        deleteCloudData: Bool = false
    ) async {
        privateCloudState = .syncing
        do {
            try await service.setPrivateCloudSyncEnabled(
                enabled,
                deleteCloudData: deleteCloudData
            )
            privateCloudSyncEnabled = enabled
            privateCloudState = enabled ? .idle : .disabled
        } catch let error {
            privateCloudState = .failed(
                AppFailure(
                    operation: .privateCloudSync,
                    serviceError: error
                )
            )
        }
    }

    func removeAccount(
        downloads disposition: AccountDownloadDisposition = .delete,
        scope: AccountRemovalScope = .thisDevice,
        statistics statisticsDisposition:
            AccountStatisticsDisposition = .keep
    ) async {
        guard let account else {
            accountActionStatus = .failed(
                AppFailure(.removeAccount, .authenticationRequired)
            )
            return
        }
        guard accountActionStatus != .removing else {
            return
        }
        accountActionStatus = .removing
        stopLiveUpdates()
        await diagnostics.record(
            .started(.removeAccount, category: .auth)
        )
        await playback.stop()

        do {
            let deleteStatistics = statisticsDisposition == .delete
            if scope == .allDevices {
                try await service.deletePrivateCloudAccount(
                    account.id,
                    includeStatistics: deleteStatistics
                )
            }
            if deleteStatistics {
                try await service.removeStatistics(accountID: account.id)
            }
            switch scope {
            case .thisDevice:
                try await service.removeAccountFromThisDevice(
                    account,
                    includeStatistics: deleteStatistics
                )
            case .allDevices:
                try await service.removeAccount(account)
            }
            switch disposition {
            case .keep:
                await downloads.retainDownloadsAndDetachAccount(
                    account.id
                )
            case .delete:
                await downloads.removeAll(for: account.id)
                playback.removeLocalData(for: account.id)
            }
            accounts.removeAll { $0.id == account.id }
            self.account = accounts.first
            selectedLibrary = nil
            libraryPageGeneration &+= 1
            libraries = .idle
            books = .idle
            libraryPaginationState = .idle
            homeShelves = .idle
            resetSearch()
            resetBookDetail()
            accountActionStatus = .idle
            loginStatus = .idle
            if let replacement = self.account {
                try await service.activateAccount(replacement)
                phase = .signedIn
                await downloads.start(account: replacement)
                await loadLibraries()
                startLiveUpdates(for: replacement)
            } else {
                phase = .signedOut
            }
            await diagnostics.record(
                .completed(
                    .removeAccount,
                    category: .auth,
                    count: accounts.count
                )
            )
        } catch let error {
            let failure = AppFailure(operation: .removeAccount, serviceError: error)
            accountActionStatus = .failed(
                failure
            )
            if let account = self.account {
                startLiveUpdates(for: account)
            }
            await diagnostics.record(
                .failed(
                    .removeAccount,
                    category: .auth,
                    failureCode: failure.diagnosticFailureCode
                )
            )
        }
    }

    private func resetSearch() {
        searchGeneration &+= 1
        searchQuery = ""
        searchResults = .idle
    }

    func setLiveUpdatesActive(_ active: Bool) {
        liveUpdatesAreActive = active
        if active, let account {
            startLiveUpdates(for: account)
            scheduleLiveRefresh(libraryChanged: true, itemIDs: [])
        } else {
            stopLiveUpdates()
        }
    }

    private func startLiveUpdates(for account: ServerAccount) {
        guard liveUpdatesAreActive else {
            return
        }
        liveUpdatesTask?.cancel()
        let accountID = account.id
        liveUpdatesTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let updates = await service.liveUpdates(for: account)
            for await update in updates {
                guard !Task.isCancelled, self.account?.id == accountID else {
                    return
                }
                guard case .event(let event) = update else {
                    continue
                }
                switch event {
                case .libraryChanged:
                    scheduleLiveRefresh(libraryChanged: true, itemIDs: [])
                case .itemsChanged(let change):
                    guard let selectedLibrary,
                        change.libraryIDs.contains(selectedLibrary.id)
                    else {
                        continue
                    }
                    scheduleLiveRefresh(
                        libraryChanged: false,
                        itemIDs: change.itemIDs
                    )
                case .playbackProgress(let progress):
                    await playback.handleLiveProgress(progress)
                    scheduleLiveRefresh(
                        libraryChanged: false,
                        itemIDs: [progress.itemID]
                    )
                }
            }
        }
    }

    private func stopLiveUpdates() {
        liveUpdatesTask?.cancel()
        liveUpdatesTask = nil
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    private func scheduleLiveRefresh(
        libraryChanged: Bool,
        itemIDs: Set<LibraryItemID>
    ) {
        pendingLiveLibraryRefresh =
            pendingLiveLibraryRefresh || libraryChanged
        pendingLiveItemIDs.formUnion(itemIDs)
        liveRefreshTask?.cancel()
        liveRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.performLiveRefresh()
        }
    }

    private func performLiveRefresh() async {
        guard let account else { return }
        let refreshLibraries = pendingLiveLibraryRefresh
        let itemIDs = pendingLiveItemIDs
        pendingLiveLibraryRefresh = false
        pendingLiveItemIDs = []

        if refreshLibraries {
            guard let loaded = try? await service.libraries(for: account)
                .filter({ $0.mediaType == .book })
            else { return }
            libraries = .loaded(loaded)
            let retained = selectedLibrary.flatMap { selected in
                loaded.first { $0.id == selected.id }
            }
            guard let library = retained ?? loaded.first else {
                selectedLibrary = nil
                books = .loaded(
                    LibraryItemsPage(
                        items: [], total: 0, page: 0, limit: 20
                    )
                )
                homeShelves = .loaded([])
                return
            }
            await selectLibrary(library)
        } else if let library = selectedLibrary {
            await selectLibrary(library)
        }

        if let selectedBookID,
            refreshLibraries || itemIDs.contains(selectedBookID),
            let selectedLibrary,
            let detail = try? await service.bookDetail(
                for: account,
                libraryID: selectedLibrary.id,
                itemID: selectedBookID
            )
        {
            bookDetail = .loaded(detail)
        }
        if !searchQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            await search(query: searchQuery)
        }
    }

    private func resetBookDetail() {
        bookDetailGeneration &+= 1
        selectedBookID = nil
        bookDetail = .idle
        bookBookmarks = .idle
        bookEditSaveState = .idle
        bookDeletionState = .idle
    }

    private static func sortAccounts(
        _ lhs: ServerAccount,
        _ rhs: ServerAccount
    ) -> Bool {
        let usernameOrder = lhs.user.username.localizedStandardCompare(
            rhs.user.username
        )
        if usernameOrder == .orderedSame {
            return lhs.server.url.absoluteString
                < rhs.server.url.absoluteString
        }
        return usernameOrder == .orderedAscending
    }
}
