import BleatCore
import Foundation
import Observation
import SwiftUI

/// Names of app preferences stored in UserDefaults.
enum AppPreferenceKey: CaseIterable, Equatable, Sendable {
    static let colourScheme = "colourScheme"
}

@MainActor
@Observable
final class ColourSchemeStore {
    static let shared = ColourSchemeStore()

    private let defaults: UserDefaults
    var value: ColourScheme {
        didSet {
            defaults.set(value.rawValue, forKey: AppPreferenceKey.colourScheme)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value =
            defaults.string(forKey: AppPreferenceKey.colourScheme)
            .flatMap(ColourScheme.init(rawValue:)) ?? .defaultValue
    }
}

/// Provides the app-wide, persistent colour-scheme preference to SwiftUI views.
///
/// Example usage:
/// ```swift
/// @ColourSchemePreference private var colourScheme
/// ```
@propertyWrapper
@MainActor
struct ColourSchemePreference: DynamicProperty {
    private let store: ColourSchemeStore

    init(store: ColourSchemeStore = .shared) {
        self.store = store
    }

    var wrappedValue: ColourScheme {
        get { store.value }
        nonmutating set { store.value = newValue }
    }

    var projectedValue: Binding<ColourScheme> {
        Binding(
            get: { store.value },
            set: { store.value = $0 }
        )
    }
}

enum ColourScheme: String, CaseIterable, Identifiable, Equatable, Sendable {
    case purple
    case orange
    case blue
    case pink
    case red
    case white

    var id: Self { self }

    static let defaultValue: Self = .purple

    var color: Color {
        switch self {
        // #8236CB - https://easyrgb.com/en/convert.php HTML to SRGB
        case .purple: Color(red: 0.5098, green: 0.21176, blue: 0.79608)
        case .orange: .orange
        case .blue: .blue
        case .pink: .pink
        case .red: .red
        case .white: .white
        }
    }
}

enum AppPhase: Equatable, Sendable {
    case launching
    case signedOut
    case signedIn
    case unavailable(AppFailure)
}

enum PlaybackPositioningOutcome: Equatable, Sendable {
    case positioned
    case failed(AppFailure)
}

enum PlaybackPositioningRoute: Equatable, Sendable {
    case activePlayer
    case downloaded
    case streamed

    static func decide(
        playbackAccountID: AccountID?,
        playbackItemID: LibraryItemID?,
        isPlaybackPrepared: Bool,
        requestedAccountID: AccountID,
        requestedItemID: LibraryItemID,
        hasCompleteDownload: Bool
    ) -> Self {
        if isPlaybackPrepared,
            playbackAccountID == requestedAccountID,
            playbackItemID == requestedItemID
        {
            return .activePlayer
        }
        return hasCompleteDownload ? .downloaded : .streamed
    }
}

enum AppLaunchStage: Equatable, Sendable {
    case preparing
    case reticulatingSplines
    case syncingData
    case restoringAccount
    case restoringDownloads

    var message: String {
        switch self {
        case .preparing:
            "Preparing Bleat"
        case .reticulatingSplines:
            "reticulating splines…"
        case .syncingData:
            "Syncing your data"
        case .restoringAccount:
            "Restoring your account"
        case .restoringDownloads:
            "Restoring downloads"
        }
    }

    static func randomlySelectedInitialStage() -> Self {
        Int.random(in: 0..<8) == 0 ? .reticulatingSplines : .preparing
    }
}

enum AccountSubmissionStage: Equatable, Sendable {
    case checkingServer
    case checkingLocalServer
    case verifyingLocalCredentials
    case verifyingSavedCredentials
    case signingIn
    case savingAccount

    var label: String {
        switch self {
        case .checkingServer:
            "Checking server…"
        case .checkingLocalServer:
            "Checking local server…"
        case .verifyingLocalCredentials:
            "Verifying local credentials…"
        case .verifyingSavedCredentials:
            "Verifying saved credentials…"
        case .signingIn:
            "Signing in…"
        case .savingAccount:
            "Saving account…"
        }
    }
}

enum LoginStatus: Equatable, Sendable {
    case idle
    case submitting(AccountSubmissionStage)
    case failed(AppFailure)

    var isSubmitting: Bool {
        if case .submitting = self {
            return true
        }
        return false
    }

    var submissionStage: AccountSubmissionStage? {
        guard case .submitting(let stage) = self else {
            return nil
        }
        return stage
    }
}

enum AccountUpdateResult: Equatable, Sendable {
    case saved
    case localServerValidationFailed(AppFailure)
    case failed
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
    case persistenceUnavailable, invalidInput, serverRequiresHTTPS,
        serverNotReady
    case serverUnsupported, localLoginUnavailable, invalidCredentials
    case authenticationRequired, permissionDenied, itemNotFound
    case invalidServerResponse, localStorageUnavailable, unavailableOffline
    case serverUnavailable, requestRejected, mediaUnavailable, uncertainMutation
    case authenticationCancelled, authenticationSessionInProgress
    case authenticationBrowserFailed, authenticationBridgeFailed
    case authenticationCallbackInvalid, authenticationCredentialInvalid

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
        case .localStorageUnavailable, .persistenceUnavailable:
            "Local storage unavailable"
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
        case .authenticationCancelled: "Sign-in cancelled"
        case .authenticationSessionInProgress: "Sign-in already in progress"
        case .authenticationBrowserFailed: "Browser sign-in unavailable"
        case .authenticationBridgeFailed: "Sign-in bridge unavailable"
        case .authenticationCallbackInvalid: "Invalid sign-in callback"
        case .authenticationCredentialInvalid: "Invalid sign-in response"
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
        case .authenticationCancelled:
            "The system browser sign-in was cancelled."
        case .authenticationSessionInProgress:
            "Finish or cancel the current sign-in attempt before starting another."
        case .authenticationBrowserFailed:
            "Bleat could not start or complete the system browser sign-in session."
        case .authenticationBridgeFailed:
            "Audiobookshelf could not complete its OpenID sign-in bridge."
        case .authenticationCallbackInvalid:
            "The OpenID callback did not match the sign-in request."
        case .authenticationCredentialInvalid:
            "Audiobookshelf returned incomplete or mismatched account credentials."
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
        case .invalidServerResponse, .invalidInput, .requestRejected,
            .authenticationBridgeFailed, .authenticationCallbackInvalid,
            .authenticationCredentialInvalid:
            "exclamationmark.triangle"
        case .localStorageUnavailable, .persistenceUnavailable:
            "externaldrive.badge.exclamationmark"
        case .unavailableOffline, .serverUnavailable: "wifi.exclamationmark"
        case .mediaUnavailable: "play.slash"
        case .uncertainMutation: "arrow.triangle.2.circlepath"
        case .serverRequiresHTTPS: "lock.trianglebadge.exclamationmark"
        case .serverNotReady, .serverUnsupported, .localLoginUnavailable,
            .invalidCredentials, .authenticationCancelled,
            .authenticationSessionInProgress, .authenticationBrowserFailed:
            "exclamationmark.circle"
        }
    }

    var allowsRetry: Bool {
        operation.isSafeToRetry
            && (cause == .invalidServerResponse
                || cause == .localStorageUnavailable
                || cause == .unavailableOffline
                || cause == .serverUnavailable || cause == .requestRejected)
    }

    static let persistenceUnavailable = AppFailure(
        .appStart, .persistenceUnavailable)
    static let accountUnavailable = AppFailure(
        .appStart, .localStorageUnavailable)
    static let mediaUnavailable = AppFailure(.localPlayback, .mediaUnavailable)
    static let invalidServerAddress = AppFailure(.login, .invalidInput)
    static let serverUnavailable = AppFailure(.login, .serverUnavailable)
    static let invalidServerScheme = AppFailure(.login, .serverRequiresHTTPS)
    static let serverNotReady = AppFailure(.login, .serverNotReady)
    static let serverUnsupported = AppFailure(.login, .serverUnsupported)
    static let localLoginUnavailable = AppFailure(
        .login, .localLoginUnavailable)
    static let invalidCredentials = AppFailure(.login, .invalidCredentials)
    static let secureCredentialStorageUnavailable = AppFailure(
        .login, .localStorageUnavailable)
    static let loginFailed = AppFailure(.login, .requestRejected)
    static let libraryUnavailable = AppFailure(
        .loadLibraries, .serverUnavailable)
    static let homeUnavailable = AppFailure(.loadHome, .serverUnavailable)
    static let searchUnavailable = AppFailure(.search, .serverUnavailable)
    static let playbackDenied = AppFailure(.openPlayback, .permissionDenied)
    static let playbackUnavailable = AppFailure(
        .openPlayback, .serverUnavailable)
    static let progressUnavailable = AppFailure(
        .updateProgress, .uncertainMutation)
    static let invalidMetadata = AppFailure(.saveMetadata, .invalidInput)
    static let metadataUnavailable = AppFailure(
        .saveMetadata, .uncertainMutation)
    static let bookDeletionDenied = AppFailure(.deleteBook, .permissionDenied)
    static let bookDeletionUnavailable = AppFailure(
        .deleteBook, .uncertainMutation)
    static let bookmarkUnavailable = AppFailure(
        .loadBookmarks, .serverUnavailable)
    static let accountRemovalFailed = AppFailure(
        .removeAccount, .uncertainMutation)

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
        case .passwordRequiredForCredentialChange:
            return .invalidInput
        case .discovery(let error):
            switch error {
            case .uninitialized: return .serverNotReady
            case .unsupportedServerVersion, .invalidServerVersion:
                return .serverUnsupported
            case .malformedResponse, .wrongApplication:
                return .invalidServerResponse
            case .unexpectedHTTPStatus(let status): return statusCause(status)
            case .redirectMissingLocation, .redirectRequiresConfirmation,
                .tooManyRedirects, .invalidRedirect:
                return .requestRejected
            }
        case .discoveryRequestFailed: return .serverUnavailable
        case .onboarding(let error):
            switch error {
            case .localAuthenticationUnavailable: return .localLoginUnavailable
            case .openIDAuthenticationUnavailable:
                return .authenticationBridgeFailed
            case .openIDAuthenticationFailed(let error):
                return openIDCause(error)
            case .authenticationFailed(let error):
                switch error {
                case .invalidCredentials: return .invalidCredentials
                case .credentialStorageUnavailable:
                    return .localStorageUnavailable
                case .malformedLoginResponse, .malformedAuthorizationResponse,
                    .authorizedUserMismatch:
                    return .invalidServerResponse
                case .unexpectedLoginStatus(let status),
                    .unexpectedAuthorizationStatus(let status):
                    return statusCause(status)
                case .invalidAccountID, .accountOperationInProgress,
                    .missingAccessToken, .missingRefreshToken,
                    .tokenValidationFailed, .credentialPersistenceFailed:
                    return .authenticationRequired
                }
            case .authenticationRequestFailed: return .serverUnavailable
            case .invalidAccount: return .invalidServerResponse
            case .accountPersistenceFailed, .credentialRollbackFailed:
                return .localStorageUnavailable
            }
        case .accountStore, .libraryCache, .transcriptCache, .statistics:
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
        case .libraryRepository(let error), .bookDetail(let error):
            return repositoryCause(error)
        case .pageRequest, .homeRequest, .searchRequest, .metadataPatch:
            return .invalidInput
        case .searchCoordinator(let error):
            switch error {
            case .cancelled, .superseded: return .serverUnavailable
            case .repository(let error): return repositoryCause(error)
            }
        case .playbackSession(let error): return playbackSessionCause(error)
        case .playbackSource: return .mediaUnavailable
        case .playbackSync(let error): return playbackSyncCause(error)
        case .localPlaybackSession(let error): return localSessionCause(error)
        case .metadataUpdate(let error): return metadataCause(error)
        case .coverUpdate(let error): return coverCause(error)
        case .bookDeletion(let error):
            switch error {
            case .permissionDenied: return .permissionDenied
            case .itemNotFound: return .itemNotFound
            case .requestFailed: return .uncertainMutation
            case .unexpectedStatus(let status): return statusCause(status)
            case .invalidItemID, .requestConstructionFailed,
                .authenticationFailed:
                return .requestRejected
            }
        case .bookmark(let error): return bookmarkCause(error)
        case .progress(let error): return progressCause(error)
        case .downloadPlan(let error):
            switch error {
            case .invalidItemID: return .invalidInput
            case .routeConstruction: return .requestRejected
            case .authenticatedRequest(let error):
                return authenticationCause(error)
            case .unexpectedStatus(let status): return statusCause(status)
            case .invalidPlan: return .invalidServerResponse
            }
        case .downloadAuthorization(let error):
            switch error {
            case .invalidAccountID, .accountOperationInProgress,
                .rejectedRequestDoesNotMatchDownload,
                .missingRejectedAuthorization, .malformedRejectedAuthorization:
                return .invalidInput
            case .routeConstruction: return .requestRejected
            case .authenticatedRequest(let error):
                return authenticationCause(error)
            }
        case .accountRemoval(let error):
            switch error {
            case .accountNotFound: return .itemNotFound
            case .logoutFailed, .logoutRequestFailed: return .uncertainMutation
            case .accountStoreFailed: return .localStorageUnavailable
            }
        }
    }

    private static func openIDCause(
        _ error: OpenIDAuthenticationError
    ) -> AppFailureCause {
        switch error {
        case .invalidAccountID:
            .invalidInput
        case .attemptAlreadyInProgress:
            .authenticationSessionInProgress
        case .randomGenerationFailed, .browserFailed:
            .authenticationBrowserFailed
        case .browserCancelled:
            .authenticationCancelled
        case .unexpectedAuthorizationRedirectStatus,
            .missingProviderRedirect, .invalidProviderRedirect,
            .unexpectedExchangeStatus:
            .authenticationBridgeFailed
        case .invalidCallbackURL, .missingState, .stateMismatch,
            .missingAuthorizationCode:
            .authenticationCallbackInvalid
        case .malformedExchangeResponse, .missingAccessToken,
            .missingRefreshToken, .tokenValidationFailed,
            .unexpectedAuthorizationStatus, .malformedAuthorizationResponse,
            .authorizedUserMismatch:
            .authenticationCredentialInvalid
        case .credentialPersistenceFailed:
            .localStorageUnavailable
        }
    }

    private static func statusCause(_ status: Int) -> AppFailureCause {
        switch status {
        case 401: .authenticationRequired
        case 403: .permissionDenied
        case 404: .itemNotFound
        case 408, 429, 500...599: .serverUnavailable
        default: .requestRejected
        }
    }
    private static func repositoryCause(_ error: LibraryRepositoryError)
        -> AppFailureCause
    {
        switch error {
        case .remote(let error): apiCause(error)
        case .fallbackCache(let remote, _): apiCause(remote)
        case .cache: .localStorageUnavailable
        case .noCachedValue: .unavailableOffline
        case .cancelled: .serverUnavailable
        }
    }
    private static func apiCause(_ error: AudiobookshelfAPIError)
        -> AppFailureCause
    {
        switch error {
        case .authentication(let error): authenticationCause(error)
        case .unexpectedStatus(let status): statusCause(status)
        case .malformedResponse, .invalidLibrary, .invalidPage,
            .invalidLibraryItem, .invalidBookDetail, .invalidSearchResults,
            .invalidPersonalizedShelves:
            .invalidServerResponse
        case .cancelled: .serverUnavailable
        case .invalidAccountID, .routeConstruction: .requestRejected
        }
    }
    private static func authenticationCause(_ error: AuthenticatedRequestError)
        -> AppFailureCause
    {
        switch error {
        case .requestTransportFailed, .refreshTransportFailed,
            .automaticReauthenticationTransportFailed:
            .serverUnavailable
        case .credentialsReadFailed, .missingCredentials, .refreshRejected,
            .missingAccessToken, .missingRefreshToken,
            .credentialPersistenceFailed, .savedLoginCredentialsReadFailed,
            .automaticReauthenticationFailed, .retriedRequestUnauthorized:
            .authenticationRequired
        case .unexpectedRefreshStatus(let status): statusCause(status)
        case .invalidAccountID, .accountOperationInProgress,
            .authenticationEndpoint, .requestDoesNotMatchRoute,
            .authorizationFailed, .requestCancelled,
            .refreshRequestConstructionFailed, .refreshCancelled,
            .malformedRefreshResponse:
            .requestRejected
        }
    }
    private static func playbackSessionCause(_ error: PlaybackSessionError)
        -> AppFailureCause
    {
        switch error {
        case .authenticationFailed(let error): authenticationCause(error)
        case .unexpectedStartStatus(let status),
            .unexpectedCloseStatus(let status):
            statusCause(status)
        case .requestFailed: .serverUnavailable
        case .malformedStartResponse, .invalidSessionResponse,
            .mismatchedLibraryItem:
            .invalidServerResponse
        case .invalidLibraryItemID, .invalidDeviceInfo,
            .invalidSupportedMimeType, .requestConstructionFailed,
            .requestEncodingFailed:
            .invalidInput
        }
    }
    private static func playbackSyncCause(_ error: PlaybackSyncError)
        -> AppFailureCause
    {
        switch error {
        case .authenticationFailed(let error): authenticationCause(error)
        case .unexpectedStatus(let status): statusCause(status)
        case .requestFailed: .uncertainMutation
        case .invalidSessionID, .invalidPosition, .invalidDuration,
            .invalidListeningTime, .positionExceedsDuration,
            .requestConstructionFailed, .requestEncodingFailed:
            .invalidInput
        }
    }
    private static func localSessionCause(_ error: LocalPlaybackSessionError)
        -> AppFailureCause
    {
        switch error {
        case .authenticationFailed(let error): authenticationCause(error)
        case .unexpectedStatus(let status): statusCause(status)
        case .requestFailed: .uncertainMutation
        case .malformedResponse: .invalidServerResponse
        case .emptyBatch, .duplicateSessionID, .invalidSessionID,
            .invalidMetadata, .invalidDuration, .invalidPosition,
            .invalidTimestamp, .invalidMVPAccounting, .invalidDeviceInfo,
            .requestConstructionFailed, .requestEncodingFailed:
            .invalidInput
        }
    }
    private static func metadataCause(_ error: BookMetadataUpdateError)
        -> AppFailureCause
    {
        switch error {
        case .authenticationFailed(let error): authenticationCause(error)
        case .unexpectedStatus(let status): statusCause(status)
        case .requestFailed: .uncertainMutation
        case .malformedResponse: .invalidServerResponse
        case .invalidItemID, .emptyPatch, .requestConstructionFailed,
            .requestEncodingFailed, .updateRejected:
            .invalidInput
        }
    }
    private static func coverCause(_ error: BookCoverUploadError)
        -> AppFailureCause
    {
        switch error {
        case .authenticationFailed(let error): authenticationCause(error)
        case .unexpectedStatus(let status): statusCause(status)
        case .requestFailed: .uncertainMutation
        case .malformedResponse: .invalidServerResponse
        case .invalidItemID, .emptyImage, .imageTooLarge,
            .requestConstructionFailed, .uploadRejected:
            .invalidInput
        }
    }
    private static func bookmarkCause(_ error: BookmarkError) -> AppFailureCause
    {
        switch error {
        case .authenticationFailed(let error): authenticationCause(error)
        case .unexpectedStatus(let status): statusCause(status)
        case .requestFailed: .uncertainMutation
        case .malformedResponse: .invalidServerResponse
        case .invalidItemID, .invalidTime, .emptyTitle,
            .requestConstructionFailed, .requestEncodingFailed:
            .invalidInput
        }
    }
    private static func progressCause(_ error: BookProgressError)
        -> AppFailureCause
    {
        switch error {
        case .authenticationFailed(let error): authenticationCause(error)
        case .unexpectedStatus(let status): statusCause(status)
        case .requestFailed: .uncertainMutation
        case .malformedResponse: .invalidServerResponse
        case .invalidItemID, .emptyUpdate, .invalidDuration,
            .invalidCurrentTime, .invalidProgress, .requestConstructionFailed,
            .requestEncodingFailed:
            .invalidInput
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private let service: any AppServicing
    private var nearbyServerDiscovery: (any NearbyServerDiscovering)?
    private let diagnostics: any DiagnosticRecording
    private let initialLaunchStage: AppLaunchStage
    private var hasStarted = false
    private var libraryPageGeneration: UInt64 = 0
    private var seriesPageGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var bookDetailGeneration: UInt64 = 0
    @ObservationIgnored
    private var liveUpdatesTask: Task<Void, Never>?
    @ObservationIgnored
    private var endpointDiagnosticsTask: Task<Void, Never>?
    @ObservationIgnored
    private var liveRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var localSessionSyncTask: Task<Void, Never>?
    @ObservationIgnored
    private var networkPathUpdatesTask: Task<Void, Never>?
    private var liveUpdatesAreActive = true
    private var pendingLiveLibraryRefresh = false
    private var pendingLiveItemIDs: Set<LibraryItemID> = []
    private var pendingLocalSessionSyncAccounts: [AccountID: ServerAccount] =
        [:]

    private(set) var phase: AppPhase
    private(set) var launchStage: AppLaunchStage
    private(set) var loginStatus: LoginStatus = .idle
    private(set) var loginDiscovery: ResourceState<DiscoveredServer> = .idle
    private(set) var nearbyServerDiscoveryState: NearbyServerDiscoveryState =
        .idle
    private(set) var accountActionStatus: AccountActionStatus = .idle
    private(set) var endpointDiagnostics: AppEndpointDiagnostics?
    private(set) var liveUpdateConnectionState:
        AudiobookshelfLiveConnectionState = .disconnected
    private(set) var networkPathState: AppNetworkPathState = .unknown
    private(set) var account: ServerAccount?
    private(set) var accounts: [ServerAccount] = []
    private(set) var libraries: ResourceState<[LibrarySummary]> = .idle
    private(set) var selectedLibrary: LibrarySummary?
    private(set) var isNavigationReady = false
    private(set) var books: ResourceState<LibraryItemsPage> = .idle
    private(set) var libraryPaginationState: LibraryPaginationState = .idle
    private(set) var librarySort: LibraryItemSort = .title
    private(set) var librarySortDescending = false
    private(set) var libraryBrowseFilter: LibraryBrowseFilter = .all
    private(set) var seriesBooks: ResourceState<LibraryItemsPage> = .idle
    private(set) var seriesPaginationState: LibraryPaginationState = .idle
    private(set) var selectedSeries: SeriesDestination?
    private(set) var homeShelves: ResourceState<[LibraryBookShelf]> = .idle
    private(set) var searchQuery = ""
    private(set) var searchResults: ResourceState<LibrarySearchResults> = .idle
    private(set) var selectedBookID: LibraryItemID?
    private(set) var bookDetail: ResourceState<LibraryBookDetail> = .idle
    private(set) var bookBookmarks: ResourceState<[AudioBookmark]> = .idle
    private(set) var bookEditSaveState: BookEditSaveState = .idle
    private(set) var bookDeletionState: BookDeletionState = .idle
    private(set) var bookProgressUpdateState: BookProgressUpdateState = .idle
    private(set) var statistics: ResourceState<StatisticsSummary> = .idle
    private(set) var privateCloudState: PrivateCloudState = .idle
    private(set) var privateCloudSyncAvailable = true
    private(set) var privateCloudSyncEnabled = true
    let playback: PlaybackModel
    let downloads: DownloadModel
    let transcription: ChapterTranscriptionModel
    #if DEBUG
        let diagnosticLogStore: PersistentDiagnosticLogStore?
    #endif

    func cachedChapterTranscripts(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws -> [CachedChapterTranscript] {
        try await service.cachedChapterTranscripts(
            accountID: account.id,
            itemID: itemID
        )
    }

    func saveCachedChapterTranscript(
        _ transcript: CachedChapterTranscript,
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws {
        try await service.saveCachedChapterTranscript(
            transcript,
            accountID: account.id,
            itemID: itemID
        )
    }

    func cachedChapterTranscriptionTaskState(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws -> CachedChapterTranscriptionTaskState? {
        try await service.cachedChapterTranscriptionTaskState(
            accountID: account.id,
            itemID: itemID
        )
    }

    func saveCachedChapterTranscriptionTaskState(
        _ state: CachedChapterTranscriptionTaskState,
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws {
        try await service.saveCachedChapterTranscriptionTaskState(
            state,
            accountID: account.id,
            itemID: itemID
        )
    }

    init(
        service: any AppServicing,
        nearbyServerDiscovery: (any NearbyServerDiscovering)? = nil,
        bootstrapError: AppBootstrapError? = nil,
        downloadsStorageRootURL: URL? = nil,
        diagnostics: any DiagnosticRecording =
            SystemDiagnosticRecorder.shared,
        diagnosticLogStore: (any DiagnosticRecording)? = nil,
        initialLaunchStage: AppLaunchStage? = nil,
        transcription: ChapterTranscriptionModel? = nil
    ) {
        self.service = service
        self.nearbyServerDiscovery = nearbyServerDiscovery
        self.diagnostics = diagnostics
        let launchStage =
            initialLaunchStage
            ?? AppLaunchStage.randomlySelectedInitialStage()
        self.initialLaunchStage = launchStage
        self.launchStage = launchStage
        let subsystems = Self.makePlaybackAndDownloads(
            service: service,
            downloadsStorageRootURL: downloadsStorageRootURL,
            diagnostics: diagnostics
        )
        self.playback = subsystems.playback
        self.downloads = subsystems.downloads
        self.transcription = transcription ?? ChapterTranscriptionModel()
        #if DEBUG
            self.diagnosticLogStore =
                diagnosticLogStore as? PersistentDiagnosticLogStore
        #endif
        if let bootstrapError {
            hasStarted = true
            switch bootstrapError {
            case .persistenceUnavailable:
                phase = .unavailable(.persistenceUnavailable)
            }
        } else {
            phase = .launching
        }
    }

    func startNearbyServerDiscovery() {
        let discovery =
            nearbyServerDiscovery
            ?? BonjourNearbyServerDiscovery()
        nearbyServerDiscovery = discovery
        discovery.start { [weak self] state in
            self?.nearbyServerDiscoveryState = state
        }
    }

    func cancelNearbyServerDiscovery() {
        nearbyServerDiscovery?.cancel()
        nearbyServerDiscoveryState = .idle
    }

    func discoverLoginServer(_ serverAddress: String) async {
        let trimmed = serverAddress.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            loginDiscovery = .idle
            return
        }
        loginDiscovery = .loading
        do {
            loginDiscovery = .loaded(
                try await service.discoverServer(serverAddress: trimmed)
            )
        } catch let error {
            loginDiscovery = .failed(
                AppFailure(operation: .login, serviceError: error)
            )
        }
    }

    private static func makePlaybackAndDownloads(
        service: any AppServicing,
        downloadsStorageRootURL: URL?,
        diagnostics: any DiagnosticRecording
    ) -> (playback: PlaybackModel, downloads: DownloadModel) {
        let playback = PlaybackModel(
            service: service,
            diagnostics: diagnostics
        )
        let downloads = DownloadModel(
            service: service,
            storageRootURL: downloadsStorageRootURL,
            diagnostics: diagnostics
        )
        playback.setAutomaticDownloadHandler { [weak downloads] activity in
            await downloads?.handleAutomaticPlaybackActivity(activity)
        }
        return (playback, downloads)
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
            if let endpointRouter = await service.serverEndpointRouter() {
                await BookCoverImageLoader.shared.setEndpointRouter(
                    endpointRouter
                )
            }
            privateCloudSyncAvailable =
                await service.isPrivateCloudSyncAvailable()
            if privateCloudSyncAvailable {
                privateCloudSyncEnabled =
                    await service.isPrivateCloudSyncEnabled()
            } else {
                privateCloudSyncEnabled = false
            }
            if privateCloudSyncEnabled {
                launchStage = .syncingData
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
            launchStage = .restoringAccount
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
            let restoredAccount = try await service.activeAccount()
            if let restoredAccount,
                !accounts.contains(where: { $0.id == restoredAccount.id })
            {
                accounts.append(restoredAccount)
            }
            launchStage = .restoringDownloads
            await downloads.start(account: nil)
            for storedAccount in accounts {
                await downloads.start(account: storedAccount)
            }
            await downloads.removeOrphanedDownloads(
                retaining: Set(accounts.map(\.id))
            )
            startNetworkPathUpdates()
            schedulePendingLocalSessionSync(for: accounts)
            guard let restoredAccount else {
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

    func retryStart() async {
        guard case .unavailable = phase else {
            return
        }
        hasStarted = false
        phase = .launching
        launchStage = initialLaunchStage
        await start()
    }

    @discardableResult
    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async -> Bool {
        guard !loginStatus.isSubmitting else {
            return false
        }
        loginStatus = .submitting(.checkingServer)
        await diagnostics.record(
            .started(.login, category: .auth)
        )

        do {
            let authenticatedAccount = try await service.login(
                serverAddress: serverAddress,
                username: username,
                password: password,
                progress: { [weak self] stage in
                    await self?.updateSubmissionStage(stage)
                }
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
            schedulePendingLocalSessionSync(for: authenticatedAccount)
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

    @discardableResult
    func loginWithOpenID(serverAddress: String) async -> Bool {
        guard !loginStatus.isSubmitting else {
            return false
        }
        loginStatus = .submitting(.checkingServer)
        await diagnostics.record(.started(.login, category: .auth))
        do {
            let authenticatedAccount = try await service.loginWithOpenID(
                serverAddress: serverAddress,
                progress: { [weak self] stage in
                    await self?.updateSubmissionStage(stage)
                }
            )
            account = authenticatedAccount
            accounts.removeAll { $0.id == authenticatedAccount.id }
            accounts.append(authenticatedAccount)
            accounts.sort(by: Self.sortAccounts)
            phase = .signedIn
            loginStatus = .idle
            await downloads.start(account: authenticatedAccount)
            await loadLibraries()
            await loadStatistics()
            startLiveUpdates(for: authenticatedAccount)
            await diagnostics.record(.completed(.login, category: .auth))
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
        loginDiscovery = .idle
    }

    private func updateSubmissionStage(_ stage: AccountSubmissionStage) {
        guard loginStatus.isSubmitting else {
            return
        }
        loginStatus = .submitting(stage)
    }

    @discardableResult
    func reauthenticateWithOpenID() async -> Bool {
        guard let account else {
            loginStatus = .failed(
                AppFailure(.reauthenticate, .authenticationRequired)
            )
            return false
        }
        guard !loginStatus.isSubmitting else {
            return false
        }
        loginStatus = .submitting(.checkingServer)
        do {
            let authenticated = try await service.reauthenticateWithOpenID(
                account,
                progress: { [weak self] stage in
                    await self?.updateSubmissionStage(stage)
                }
            )
            self.account = authenticated
            accounts.removeAll { $0.id == authenticated.id }
            accounts.append(authenticated)
            accounts.sort(by: Self.sortAccounts)
            loginStatus = .idle
            await loadLibraries()
            await loadStatistics()
            startLiveUpdates(for: authenticated)
            return true
        } catch let error {
            loginStatus = .failed(
                AppFailure(operation: .reauthenticate, serviceError: error)
            )
            return false
        }
    }

    func updateAccount(
        _ account: ServerAccount,
        serverAddress: String,
        localServerAddress: String,
        username: String,
        password: String,
        allowUnvalidatedLocalServer: Bool = false
    ) async -> AccountUpdateResult {
        guard !loginStatus.isSubmitting else {
            return .failed
        }
        loginStatus = .submitting(.checkingServer)
        do {
            let outcome = try await service.updateAccount(
                account,
                serverAddress: serverAddress,
                localServerAddress: localServerAddress,
                username: username,
                password: password,
                localServerValidation:
                    allowUnvalidatedLocalServer
                    ? .allowUnvalidated
                    : .required,
                progress: { [weak self] stage in
                    await self?.updateSubmissionStage(stage)
                }
            )
            let updated: ServerAccount
            switch outcome {
            case .updated(let account):
                updated = account
            case .localServerValidationFailed(let error):
                let failure = AppFailure(
                    operation: .reauthenticate,
                    serviceError: error
                )
                loginStatus = .idle
                return .localServerValidationFailed(failure)
            }
            accounts.removeAll { $0.id == updated.id }
            accounts.append(updated)
            accounts.sort(by: Self.sortAccounts)
            if self.account?.id == updated.id {
                await stopLiveUpdatesAndWait()
                self.account = updated
                await downloads.start(account: updated)
                await loadLibraries()
                startLiveUpdates(for: updated)
            }
            loginStatus = .idle
            return .saved
        } catch let error {
            loginStatus = .failed(
                AppFailure(
                    operation: .reauthenticate,
                    serviceError: error
                )
            )
            return .failed
        }
    }

    @discardableResult
    func reauthenticate(password: String) async -> Bool {
        guard let account else {
            loginStatus = .failed(
                AppFailure(.reauthenticate, .authenticationRequired)
            )
            return false
        }
        guard !loginStatus.isSubmitting else {
            return false
        }
        loginStatus = .submitting(.signingIn)
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
            schedulePendingLocalSessionSync(for: authenticatedAccount)
            await loadLibraries()
            startLiveUpdates(for: authenticatedAccount)
            return true
        } catch let error {
            let failure = AppFailure(
                operation: .reauthenticate, serviceError: error)
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
        await stopLiveUpdatesAndWait()
        await diagnostics.record(
            .started(.switchAccount, category: .auth)
        )
        do {
            try await service.activateAccount(selectedAccount)
            account = selectedAccount
            selectedLibrary = nil
            clearEntityBrowseFilter()
            await downloads.start(account: selectedAccount)
            schedulePendingLocalSessionSync(for: selectedAccount)
            await loadLibraries()
            startLiveUpdates(for: selectedAccount)
            accountActionStatus = .idle
            await diagnostics.record(
                .completed(.switchAccount, category: .auth)
            )
        } catch let error {
            let failure = AppFailure(
                operation: .switchAccount, serviceError: error)
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
        isNavigationReady = false
        let previouslySelectedLibraryID = selectedLibrary?.id
        libraryPageGeneration &+= 1
        books = .idle
        libraryPaginationState = .idle
        homeShelves = .idle
        resetSearch()
        resetBookDetail()
        resetSeriesBrowse()

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
            guard
                let library = previouslySelectedLibraryID.flatMap({ id in
                    loadedLibraries.first(where: { $0.id == id })
                }) ?? loadedLibraries.first
            else {
                selectedLibrary = nil
                if previouslySelectedLibraryID != nil {
                    clearEntityBrowseFilter()
                }
                return
            }
            if previouslySelectedLibraryID != nil,
                library.id != previouslySelectedLibraryID
            {
                selectedLibrary = nil
            }
            await selectLibrary(library)
        } catch let error {
            let failure = AppFailure(
                operation: .loadLibraries, serviceError: error)
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
            clearEntityBrowseFilter()
            resetSearch()
            resetBookDetail()
            resetSeriesBrowse()
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
        isNavigationReady = true
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
        await setLibraryBrowseFilter(
            filter.map(LibraryBrowseFilter.progress) ?? .all)
    }

    func setLibraryBrowseFilter(_ filter: LibraryBrowseFilter) async {
        guard libraryBrowseFilter != filter else {
            return
        }
        libraryBrowseFilter = filter
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
        let filter = libraryBrowseFilter
        await diagnostics.record(
            .started(.loadLibraryPage, category: .api)
        )

        do {
            let request = try makeLibraryItemsPageRequest(
                page: 0,
                sort: librarySort,
                descending: librarySortDescending,
                filter: filter.itemFilter
            )
            let page = try await service.page(
                for: account,
                libraryID: library.id,
                request: request
            )
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                libraryBrowseFilter == filter
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
            let failure = AppFailure(
                operation: .loadLibraryPage, serviceError: error)
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
        let filter = libraryBrowseFilter

        do {
            let request = try makeLibraryItemsPageRequest(
                page: nextPageNumber,
                sort: librarySort,
                descending: librarySortDescending,
                filter: filter.itemFilter
            )
            let nextPage = try await service.page(
                for: account,
                libraryID: library.id,
                request: request
            )
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                libraryBrowseFilter == filter,
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

    func loadSeries(_ destination: SeriesDestination) async {
        seriesPageGeneration &+= 1
        let generation = seriesPageGeneration
        selectedSeries = destination
        seriesBooks = .loading
        seriesPaginationState = .idle
        guard let account else {
            seriesBooks = .failed(
                AppFailure(.loadLibraryPage, .authenticationRequired)
            )
            return
        }
        do {
            let request = try makeLibraryItemsPageRequest(
                page: 0,
                sort: .sequence,
                filter: LibraryItemFilter(seriesID: destination.id),
                collapseSeries: false
            )
            let page = try await service.page(
                for: account,
                libraryID: destination.libraryID,
                request: request
            )
            guard generation == seriesPageGeneration,
                self.account?.id == account.id,
                selectedSeries == destination
            else {
                return
            }
            seriesBooks = .loaded(page)
        } catch let error {
            guard generation == seriesPageGeneration,
                selectedSeries == destination
            else {
                return
            }
            seriesBooks = .failed(
                AppFailure(operation: .loadLibraryPage, serviceError: error)
            )
        }
    }

    func resolveAuthor(
        _ id: AuthorID,
        in libraryID: LibraryID
    ) async -> LibrarySearchAuthorMatch? {
        guard let account else { return nil }
        do {
            let request = try makeLibraryItemsPageRequest(
                page: 0,
                limit: 1,
                filter: LibraryItemFilter(authorID: id),
                collapseSeries: false
            )
            let page = try await service.page(
                for: account,
                libraryID: libraryID,
                request: request
            )
            guard self.account?.id == account.id,
                let item = page.items.first
            else {
                return nil
            }
            let detail = try await service.bookDetail(
                for: account,
                libraryID: libraryID,
                itemID: item.id
            )
            guard self.account?.id == account.id,
                detail.libraryID == libraryID,
                detail.id == item.id
            else {
                return nil
            }
            return detail.authors
                .first(where: { $0.id == id })
                .map { LibrarySearchAuthorMatch(id: $0.id, name: $0.name) }
        } catch {
            return nil
        }
    }

    func resolveSeries(
        _ id: SeriesID,
        in libraryID: LibraryID
    ) async -> LibrarySearchSeriesMatch? {
        guard let account else { return nil }
        do {
            let request = try LibraryItemsPageRequest(
                page: 0,
                limit: 1,
                sort: .sequence,
                filter: LibraryItemFilter(seriesID: id),
                collapseSeries: false
            )
            let page = try await service.page(
                for: account,
                libraryID: libraryID,
                request: request
            )
            guard self.account?.id == account.id else { return nil }
            return page.items.lazy
                .flatMap(\.series)
                .first(where: { $0.id == id })
                .map { LibrarySearchSeriesMatch(id: $0.id, name: $0.name) }
        } catch {
            return nil
        }
    }

    func resolveBook(
        _ id: LibraryItemID,
        in libraryID: LibraryID
    ) async -> LibraryBookSummary? {
        guard let account else { return nil }
        do {
            let detail = try await service.bookDetail(
                for: account,
                libraryID: libraryID,
                itemID: id
            )
            guard self.account?.id == account.id,
                detail.id == id,
                detail.libraryID == libraryID
            else {
                return nil
            }
            return LibraryBookSummary(
                id: detail.id,
                libraryID: detail.libraryID,
                title: detail.title,
                subtitle: detail.subtitle,
                authorName: detail.authors.first?.name,
                narratorName: detail.narrators.first,
                seriesName: detail.series.first?.name,
                authors: detail.authors,
                series: detail.series,
                genres: detail.genres,
                publisher: detail.publisher,
                publishedYear: detail.publishedYear,
                duration: detail.duration,
                trackCount: detail.trackCount,
                chapterCount: detail.chapters.count,
                addedAtMilliseconds: detail.addedAtMilliseconds,
                updatedAtMilliseconds: detail.updatedAtMilliseconds,
                isExplicit: detail.isExplicit,
                isAbridged: detail.isAbridged
            )
        } catch {
            return nil
        }
    }

    func loadNextSeriesPage() async {
        guard let destination = selectedSeries,
            let account,
            case .loaded(let currentPage) = seriesBooks,
            currentPage.hasNextPage,
            seriesPaginationState != .loading
        else {
            return
        }
        seriesPaginationState = .loading
        let generation = seriesPageGeneration
        do {
            let request = try makeLibraryItemsPageRequest(
                page: currentPage.page + 1,
                sort: .sequence,
                filter: LibraryItemFilter(seriesID: destination.id),
                collapseSeries: false
            )
            let nextPage = try await service.page(
                for: account,
                libraryID: destination.libraryID,
                request: request
            )
            guard generation == seriesPageGeneration,
                selectedSeries == destination,
                case .loaded(let latest) = seriesBooks,
                latest.page == currentPage.page
            else {
                return
            }
            let existingIDs = Set(latest.items.map(\.id))
            let additions = nextPage.items.filter {
                !existingIDs.contains($0.id)
            }
            seriesBooks = .loaded(
                LibraryItemsPage(
                    items: latest.items + additions,
                    total: nextPage.total,
                    page: nextPage.page,
                    limit: nextPage.limit
                )
            )
            seriesPaginationState = .idle
        } catch let error {
            guard generation == seriesPageGeneration,
                selectedSeries == destination
            else {
                return
            }
            seriesPaginationState = .failed(
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
                    count: results.books.count + results.authors.count
                        + results.series.count
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
                        AppFailure(
                            operation: .replaceCover, serviceError: error)
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

        transcription.cancel(
            for: ChapterTranscriptionBookKey(
                accountID: account.id,
                itemID: detail.id
            )
        )

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

    func playDownloaded(
        _ record: DownloadedBookRecord,
        initialTime: Double? = nil
    ) async {
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
                account: recordAccount,
                initialTime: initialTime
            )
        } catch {
            playback.fail(.mediaUnavailable)
        }
    }

    func positionPlayback(
        for detail: LibraryBookDetail,
        account: ServerAccount,
        at requestedTime: Double
    ) async -> PlaybackPositioningOutcome {
        let downloaded = downloads.record(
            accountID: account.id,
            itemID: detail.id
        )
        let hasCompleteDownload =
            downloaded.map {
                downloads.isFullBookAvailable($0)
            } ?? false
        let route = PlaybackPositioningRoute.decide(
            playbackAccountID: playback.accountID,
            playbackItemID: playback.itemID,
            isPlaybackPrepared: playback.isPrepared(
                accountID: account.id,
                itemID: detail.id
            ),
            requestedAccountID: account.id,
            requestedItemID: detail.id,
            hasCompleteDownload: hasCompleteDownload
        )

        switch route {
        case .activePlayer:
            await playback.seek(to: requestedTime)
        case .downloaded:
            guard let downloaded else {
                return .failed(.mediaUnavailable)
            }
            await playDownloaded(
                downloaded,
                initialTime: requestedTime
            )
        case .streamed:
            await playback.start(
                detail: detail,
                account: account,
                initialTime: requestedTime
            )
        }

        if case .failed(let failure) = playback.state {
            return .failed(failure)
        }
        return .positioned
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
        guard privateCloudSyncAvailable,
            privateCloudSyncEnabled,
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
        guard privateCloudSyncAvailable else {
            privateCloudSyncEnabled = false
            privateCloudState = .disabled
            return
        }
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

    @discardableResult
    func removeAccount(
        _ accountToRemove: ServerAccount? = nil,
        scope: AccountRemovalScope = .thisDevice,
        statistics statisticsDisposition:
            AccountStatisticsDisposition = .keep
    ) async -> Bool {
        guard let account = accountToRemove ?? self.account else {
            accountActionStatus = .failed(
                AppFailure(.removeAccount, .authenticationRequired)
            )
            return false
        }
        guard accountActionStatus != .removing else {
            return false
        }
        let removingBrowsingAccount = account.id == self.account?.id
        accountActionStatus = .removing
        if removingBrowsingAccount {
            await stopLiveUpdatesAndWait()
        } else {
            await service.stopLiveUpdates(for: account.id)
        }
        await diagnostics.record(
            .started(.removeAccount, category: .auth)
        )
        transcription.cancel(for: account.id)
        if playback.accountID == account.id {
            await playback.stop()
        }

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
            await downloads.removeAll(for: account.id)
            playback.removeLocalData(for: account.id)
            await BookCoverImageLoader.shared.removeAll(for: account.id)
            accounts.removeAll { $0.id == account.id }
            pendingLocalSessionSyncAccounts[account.id] = nil
            if removingBrowsingAccount {
                self.account = accounts.first
                selectedLibrary = nil
                libraryPageGeneration &+= 1
                libraries = .idle
                books = .idle
                libraryPaginationState = .idle
                homeShelves = .idle
                resetSearch()
                resetBookDetail()
            }
            accountActionStatus = .idle
            loginStatus = .idle
            if removingBrowsingAccount {
                if let replacement = self.account {
                    try await service.activateAccount(replacement)
                    phase = .signedIn
                    await downloads.start(account: replacement)
                    await loadLibraries()
                    startLiveUpdates(for: replacement)
                } else {
                    phase = .signedOut
                }
            }
            await diagnostics.record(
                .completed(
                    .removeAccount,
                    category: .auth,
                    count: accounts.count
                )
            )
            return true
        } catch let error {
            let failure = AppFailure(
                operation: .removeAccount, serviceError: error)
            accountActionStatus = .failed(
                failure
            )
            if removingBrowsingAccount, let account = self.account {
                startLiveUpdates(for: account)
            }
            await diagnostics.record(
                .failed(
                    .removeAccount,
                    category: .auth,
                    failureCode: failure.diagnosticFailureCode
                )
            )
            return false
        }
    }

    private func startNetworkPathUpdates() {
        guard networkPathUpdatesTask == nil else {
            return
        }
        networkPathUpdatesTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let updates = await service.networkPathUpdates()
            for await state in updates {
                guard !Task.isCancelled else {
                    return
                }
                networkPathState = state
                schedulePendingLocalSessionSync(for: accounts)
                await refreshAccountsAfterNetworkChange()
                guard let account else {
                    continue
                }
                if state.allowsRealtimeUpdates {
                    startLiveUpdates(for: account)
                    scheduleLiveRefresh(
                        libraryChanged: true,
                        itemIDs: []
                    )
                } else {
                    await stopLiveUpdatesAndWait()
                    if state.isConstrained {
                        liveUpdateConnectionState =
                            .suspendedForLowDataMode
                    }
                }
            }
        }
    }

    private func refreshAccountsAfterNetworkChange() async {
        guard let refreshed = try? await service.accounts() else {
            return
        }
        accounts = refreshed.sorted(by: Self.sortAccounts)
        guard let account,
            let replacement = refreshed.first(where: { $0.id == account.id })
        else {
            return
        }
        self.account = replacement
    }

    private func schedulePendingLocalSessionSync(
        for accounts: [ServerAccount]
    ) {
        for account in accounts {
            pendingLocalSessionSyncAccounts[account.id] = account
        }
        schedulePendingLocalSessionSyncWork()
    }

    private func schedulePendingLocalSessionSync(
        for account: ServerAccount
    ) {
        pendingLocalSessionSyncAccounts[account.id] = account
        schedulePendingLocalSessionSyncWork()
    }

    private func schedulePendingLocalSessionSyncWork() {
        guard localSessionSyncTask == nil else {
            return
        }
        localSessionSyncTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            while let next = pendingLocalSessionSyncAccounts.values.first {
                pendingLocalSessionSyncAccounts[next.id] = nil
                await playback.syncPendingLocalSessions(for: next)
            }
            localSessionSyncTask = nil
            if !pendingLocalSessionSyncAccounts.isEmpty {
                schedulePendingLocalSessionSyncWork()
            }
        }
    }

    private func resetSearch() {
        searchGeneration &+= 1
        searchQuery = ""
        searchResults = .idle
    }

    private func clearEntityBrowseFilter() {
        guard libraryBrowseFilter.isEntityScoped else {
            return
        }
        libraryBrowseFilter = .all
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

    func refreshEndpointDiagnostics() async {
        guard let account else {
            endpointDiagnostics = nil
            return
        }
        endpointDiagnostics = await service.endpointDiagnostics(for: account)
    }

    private func startLiveUpdates(for account: ServerAccount) {
        startEndpointDiagnostics(for: account)
        guard liveUpdatesAreActive,
            networkPathState.allowsRealtimeUpdates
        else {
            if networkPathState.isConstrained {
                liveUpdateConnectionState = .suspendedForLowDataMode
            }
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
                    if case .connection(let state) = update {
                        liveUpdateConnectionState = state
                    }
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
        endpointDiagnosticsTask?.cancel()
        endpointDiagnosticsTask = nil
        liveUpdateConnectionState = .disconnected
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    private func stopLiveUpdatesAndWait() async {
        let accountID = account?.id
        stopLiveUpdates()
        if let accountID {
            await service.stopLiveUpdates(for: accountID)
        }
    }

    private func startEndpointDiagnostics(for account: ServerAccount) {
        endpointDiagnosticsTask?.cancel()
        let accountID = account.id
        endpointDiagnosticsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            endpointDiagnostics =
                await service.endpointDiagnostics(for: account)
            let updates =
                await service.endpointDiagnosticsUpdates(for: account)
            for await update in updates {
                guard !Task.isCancelled,
                    self.account?.id == accountID
                else {
                    return
                }
                endpointDiagnostics = update
            }
        }
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
            guard
                let loaded = try? await service.libraries(for: account)
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

    private func makeLibraryItemsPageRequest(
        page: Int,
        limit: Int = 20,
        sort: LibraryItemSort = .addedAt,
        descending: Bool = false,
        filter: LibraryItemFilter? = nil,
        collapseSeries: Bool = true,
        minified: Bool = true
    ) throws(AppServiceError) -> LibraryItemsPageRequest {
        do {
            return try LibraryItemsPageRequest(
                page: page,
                limit: limit,
                sort: sort,
                descending: descending,
                filter: filter,
                collapseSeries: collapseSeries,
                minified: minified
            )
        } catch let error {
            throw .pageRequest(error)
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

    private func resetSeriesBrowse() {
        seriesPageGeneration &+= 1
        selectedSeries = nil
        seriesBooks = .idle
        seriesPaginationState = .idle
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
