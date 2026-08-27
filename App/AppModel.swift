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

enum PlaybackStartPosition: Equatable, Sendable {
    case resume
    case beginning
    case absoluteTime(TimeInterval)
    case chapter(PlaybackChapterPosition)

    static func chapter(
        _ chapter: PlaybackChapter,
        offset: TimeInterval = 0
    ) -> Self {
        .chapter(
            PlaybackChapterPosition(
                chapterID: chapter.id,
                offset: offset
            )
        )
    }
}

struct PlaybackChapterPosition: Equatable, Sendable {
    let chapterID: Int
    let offset: TimeInterval
}

enum PlaybackStartSource: Equatable, Sendable {
    case activePlayer
    case downloaded
    case streamed
}

enum PlaybackStartOutcome: Equatable, Sendable {
    case started(source: PlaybackStartSource)
    case superseded
    case failed(AppFailure)

    var presentationFailure: AppFailure? {
        guard case .failed(let failure) = self else { return nil }
        return failure
    }
}

enum BrowsingPlaybackActionOutcome: Equatable, Sendable {
    case paused
    case start(PlaybackStartOutcome)
}

struct PlaybackStartTarget: Equatable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
}

private enum PlaybackStartBook: Sendable {
    case summary(LibraryBookSummary)
    case detail(LibraryBookDetail)
    case download(DownloadedBookRecord)

    var itemID: LibraryItemID {
        switch self {
        case .summary(let book): book.id
        case .detail(let detail): detail.id
        case .download(let record): record.detail.id
        }
    }

    var libraryID: LibraryID {
        switch self {
        case .summary(let book): book.libraryID
        case .detail(let detail): detail.libraryID
        case .download(let record): record.detail.libraryID
        }
    }
}

private struct PlaybackStartRequest: Sendable {
    let book: PlaybackStartBook
    let account: ServerAccount
    let position: PlaybackStartPosition
}

private enum PlaybackStartPhase: Sendable {
    case resolving
    case positioningActivePlayer
    case preparingPlayback
}

enum ResolvedPlaybackStartPosition: Equatable, Sendable {
    case resume
    case absoluteTime(TimeInterval)
    case failed(AppFailure)

    var explicitTime: TimeInterval? {
        guard case .absoluteTime(let time) = self else {
            return nil
        }
        return time
    }
}

enum PlaybackStartPositionResolver {
    static func resolve(
        _ position: PlaybackStartPosition,
        duration: TimeInterval,
        chapters: [PlaybackChapter]
    ) -> ResolvedPlaybackStartPosition {
        switch position {
        case .resume:
            return .resume
        case .beginning:
            return .absoluteTime(0)
        case .absoluteTime(let value):
            guard value.isFinite, value >= 0, value <= duration else {
                return .failed(
                    AppFailure(.openPlayback, .invalidPlaybackPosition)
                )
            }
            return .absoluteTime(value)
        case .chapter(let requested):
            let matches = chapters.filter { $0.id == requested.chapterID }
            guard matches.count == 1, let chapter = matches.first else {
                return .failed(
                    AppFailure(.openPlayback, .unknownPlaybackChapter)
                )
            }
            let chapterDuration = chapter.end - chapter.start
            guard requested.offset.isFinite,
                requested.offset >= 0,
                chapterDuration.isFinite,
                chapterDuration > 0,
                requested.offset < chapterDuration
            else {
                return .failed(
                    AppFailure(
                        .openPlayback,
                        .invalidPlaybackChapterOffset
                    )
                )
            }
            let absoluteTime = chapter.start + requested.offset
            guard absoluteTime.isFinite,
                absoluteTime >= 0,
                absoluteTime <= duration
            else {
                return .failed(
                    AppFailure(.openPlayback, .invalidPlaybackPosition)
                )
            }
            return .absoluteTime(absoluteTime)
        }
    }
}

enum AppLaunchStage: Equatable, Sendable {
    case preparing
    case reticulatingSplines
    case restoringAccount
    case restoringDownloads

    var message: String {
        switch self {
        case .preparing:
            "Preparing Bleat"
        case .reticulatingSplines:
            "reticulating splines…"
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

enum ResourceRefreshState: Equatable, Sendable {
    case idle
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
    case cancelling
    case cancelled
    case failed(AppFailure)
}

enum CloudAccountRestoreState: Equatable, Sendable {
    case idle
    case synchronizing
    case noAccounts
    case awaitingSelection
    case awaitingCredentials(AccountID)
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

struct BookProgressFailureEntry: Equatable, Sendable {
    let itemID: LibraryItemID
    let failure: AppFailure
}

private struct BookProgressMutationKey: Hashable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
}

private enum BookProgressMutationStage: Sendable {
    case preparing
    case submitted
}

private enum BookProgressMutationResult: Sendable {
    case confirmed(LibraryBookDetail)
    case failed(AppFailure)
    case cancelled
}

private enum TimedBookProgressMutationResult: Sendable {
    case operation(BookProgressMutationResult)
    case deadline
}

enum BookActionPreparationResult: Equatable, Sendable {
    case loaded(LibraryBookDetail)
    case failed(AppFailure)
}

enum LibraryPaginationState: Equatable, Sendable {
    case idle
    case loading
    case failed(AppFailure)
}

enum AppFailureOperation: String, Equatable, Sendable {
    case appStart, login, reauthenticate, switchAccount, removeAccount,
        resetAppData
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
            .resetAppData,
            .openPlayback, .recoverPlayback, .saveMetadata, .replaceCover,
            .deleteBook, .updateProgress, .download, .localPlayback:
            false
        }
    }
}

enum AppFailureCause: Equatable, Sendable {
    case persistenceUnavailable, storedDataMigrationFailed, invalidInput, serverRequiresHTTPS,
        serverNotReady
    case serverUnsupported, localLoginUnavailable, invalidCredentials
    case authenticationRequired, permissionDenied, itemNotFound
    case invalidServerResponse, localStorageUnavailable, unavailableOffline
    case serverUnavailable, requestRejected, mediaUnavailable, uncertainMutation
    case requestCancelled, timeout, rateLimited
    case authenticationCancelled, authenticationSessionInProgress
    case authenticationPresentationUnavailable, authenticationBrowserFailed
    case authenticationBridgeFailed
    case authenticationCallbackInvalid, authenticationCredentialInvalid
    case accountUnavailable, playbackIdentityMismatch
    case inaccessibleLibrary, inaccessibleTags, explicitContentDenied
    case invalidPlaybackPosition, unknownPlaybackChapter
    case invalidPlaybackChapterOffset
    case localDataReset(LocalDataResetFailure)
    case privateCloud(PrivateCloudSyncFailure)

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
        case .privateCloud(let failure): failure.presentationTitle
        case .localDataReset: "Local data reset incomplete"
        case .accountUnavailable: "Account unavailable"
        case .playbackIdentityMismatch: "Audiobook mismatch"
        case .inaccessibleLibrary, .inaccessibleTags,
            .explicitContentDenied:
            "Access denied"
        case .invalidPlaybackPosition: "Invalid playback position"
        case .unknownPlaybackChapter: "Chapter unavailable"
        case .invalidPlaybackChapterOffset: "Invalid chapter position"
        case .itemNotFound: "Audiobook not found"
        case .permissionDenied: "Access denied"
        case .authenticationRequired: "Sign in again"
        case .invalidServerResponse: "Invalid server response"
        case .localStorageUnavailable, .persistenceUnavailable,
            .storedDataMigrationFailed:
            "Local storage unavailable"
        case .unavailableOffline: "Unavailable offline"
        case .serverUnavailable: "Server unavailable"
        case .timeout: "Request timed out"
        case .rateLimited: "Too many requests"
        case .requestCancelled: "Request cancelled"
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
        case .authenticationPresentationUnavailable:
            "Sign-in window unavailable"
        case .authenticationBrowserFailed: "Browser sign-in unavailable"
        case .authenticationBridgeFailed: "Sign-in bridge unavailable"
        case .authenticationCallbackInvalid: "Invalid sign-in callback"
        case .authenticationCredentialInvalid: "Invalid sign-in response"
        }
    }

    var message: String {
        switch cause {
        case .privateCloud(let failure): failure.presentationMessage
        case .localDataReset(let failure):
            switch failure {
            case .downloads:
                "Bleat could not remove every downloaded file. Your accounts and saved credentials were left unchanged."
            case .credentials:
                "Bleat removed its local store but could not confirm deletion of every saved credential."
            case .persistentStore:
                "Bleat could not clear its local store. Your accounts and saved credentials were left unchanged."
            }
        case .accountUnavailable:
            "That saved account is no longer available."
        case .playbackIdentityMismatch:
            "The audiobook does not belong to the selected account or library."
        case .inaccessibleLibrary:
            "This account cannot access the audiobook's library."
        case .inaccessibleTags:
            "This account cannot access the audiobook's tags."
        case .explicitContentDenied:
            "This account cannot access explicit audiobooks."
        case .invalidPlaybackPosition:
            "That playback position is outside this audiobook."
        case .unknownPlaybackChapter:
            "That chapter is not available in this audiobook."
        case .invalidPlaybackChapterOffset:
            "That position is outside the selected chapter."
        case .persistenceUnavailable:
            "Bleat could not open its local data store."
        case .storedDataMigrationFailed:
            "Bleat could not upgrade its existing local data store. Your saved data was left in place."
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
        case .timeout:
            "The Audiobookshelf server did not respond in time."
        case .rateLimited:
            "The Audiobookshelf server asked Bleat to try again later."
        case .requestCancelled:
            "The request was cancelled."
        case .requestRejected:
            "The server refused this request."
        case .authenticationCancelled:
            "The system browser sign-in was cancelled."
        case .authenticationSessionInProgress:
            "Finish or cancel the current sign-in attempt before starting another."
        case .authenticationPresentationUnavailable:
            "Bleat could not find an active app window for system browser sign-in."
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
        case .privateCloud(let failure): failure.systemImage
        case .localDataReset: "externaldrive.badge.exclamationmark"
        case .accountUnavailable, .authenticationRequired:
            "person.crop.circle.badge.exclamationmark"
        case .playbackIdentityMismatch, .invalidPlaybackPosition,
            .unknownPlaybackChapter, .invalidPlaybackChapterOffset:
            "exclamationmark.triangle"
        case .inaccessibleLibrary, .inaccessibleTags,
            .explicitContentDenied:
            "lock"
        case .itemNotFound: "book.closed"
        case .permissionDenied: "lock"
        case .invalidServerResponse, .invalidInput, .requestRejected,
            .authenticationBridgeFailed, .authenticationCallbackInvalid,
            .authenticationCredentialInvalid:
            "exclamationmark.triangle"
        case .localStorageUnavailable, .persistenceUnavailable,
            .storedDataMigrationFailed:
            "externaldrive.badge.exclamationmark"
        case .unavailableOffline, .serverUnavailable, .timeout, .rateLimited:
            "wifi.exclamationmark"
        case .requestCancelled: "xmark.circle"
        case .mediaUnavailable: "play.slash"
        case .uncertainMutation: "arrow.triangle.2.circlepath"
        case .serverRequiresHTTPS: "lock.trianglebadge.exclamationmark"
        case .serverNotReady, .serverUnsupported, .localLoginUnavailable,
            .invalidCredentials, .authenticationCancelled,
            .authenticationSessionInProgress,
            .authenticationPresentationUnavailable,
            .authenticationBrowserFailed:
            "exclamationmark.circle"
        }
    }

    var allowsRetry: Bool {
        if case .privateCloud(let failure) = cause {
            return operation.isSafeToRetry && failure.isRetryable
        }
        return operation.isSafeToRetry
            && (cause == .invalidServerResponse
                || cause == .localStorageUnavailable
                || cause == .unavailableOffline
                || cause == .serverUnavailable || cause == .requestRejected
                || cause == .timeout || cause == .rateLimited)
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
        case .accountStore, .credentialStore, .accountIdentityMigration,
            .libraryCache,
            .transcriptCache, .statistics:
            return .localStorageUnavailable
        case .localDataReset(let error):
            return .localDataReset(error)
        case .privateCloud(let error):
            return .privateCloud(error)
        case .libraryRepository(let error), .bookDetail(let error):
            return repositoryCause(error)
        case .pageRequest, .homeRequest, .searchRequest, .metadataPatch:
            return .invalidInput
        case .searchCoordinator(let error):
            switch error {
            case .cancelled, .superseded: return .requestCancelled
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
        case .presentationAnchorUnavailable:
            .authenticationPresentationUnavailable
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
        case 408: .timeout
        case 429: .rateLimited
        case 500...599: .serverUnavailable
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
        case .cancelled: .requestCancelled
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
        case .cancelled: .requestCancelled
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
            .authorizationFailed,
            .refreshRequestConstructionFailed,
            .malformedRefreshResponse:
            .requestRejected
        case .requestCancelled, .refreshCancelled:
            .requestCancelled
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

extension AppFailure {
    var remoteTelemetryOutcome: RemoteTelemetryOutcome {
        if cause == .authenticationCancelled || cause == .requestCancelled {
            return .cancelled
        }
        return .failed(cause.remoteTelemetryFailureCategory)
    }
}

extension AppFailureCause {
    var remoteTelemetryFailureCategory: RemoteTelemetryFailureCategory {
        switch self {
        case .privateCloud(let failure):
            failure.remoteTelemetryFailureCategory
        case .invalidCredentials, .authenticationRequired,
            .authenticationCallbackInvalid,
            .authenticationCredentialInvalid:
            .authentication
        case .permissionDenied, .inaccessibleLibrary, .inaccessibleTags,
            .explicitContentDenied:
            .authorization
        case .unavailableOffline:
            .offline
        case .serverUnavailable, .uncertainMutation,
            .authenticationBrowserFailed:
            .transport
        case .timeout:
            .timeout
        case .rateLimited:
            .rateLimited
        case .serverNotReady, .requestRejected, .itemNotFound,
            .authenticationBridgeFailed:
            .serverRejected
        case .invalidServerResponse, .playbackIdentityMismatch:
            .invalidResponse
        case .persistenceUnavailable, .storedDataMigrationFailed,
            .localStorageUnavailable, .localDataReset:
            .localStorage
        case .mediaUnavailable:
            .media
        case .serverUnsupported, .localLoginUnavailable:
            .unsupported
        case .invalidInput, .serverRequiresHTTPS,
            .authenticationSessionInProgress, .accountUnavailable,
            .invalidPlaybackPosition, .unknownPlaybackChapter,
            .invalidPlaybackChapterOffset,
            .authenticationPresentationUnavailable,
            .authenticationCancelled,
            .requestCancelled:
            .unknown
        }
    }
}

extension PrivateCloudSyncFailure {
    fileprivate var presentationTitle: String {
        switch cause {
        case .cancelled: "iCloud sync cancelled"
        case .cloudKit(let failure):
            switch failure.code {
            case .notAuthenticated: "Sign in to iCloud"
            case .accountTemporarilyUnavailable: "iCloud account unavailable"
            case .quotaExceeded: "iCloud storage full"
            case .permissionFailure, .managedAccountRestricted:
                "iCloud access denied"
            case .requestRateLimited: "iCloud sync delayed"
            default: "iCloud sync unavailable"
            }
        case .disabled: "iCloud sync is off"
        case .invalidRecord: "Invalid iCloud data"
        case .persistenceFailed: "Local storage unavailable"
        case .engineUnavailable: "iCloud sync unavailable"
        case .unexpected: "iCloud sync failed"
        }
    }

    fileprivate var presentationMessage: String {
        switch cause {
        case .disabled:
            "Turn on iCloud synchronization before syncing."
        case .cancelled:
            "iCloud synchronization was cancelled."
        case .invalidRecord:
            "Bleat received incomplete or inconsistent data from iCloud."
        case .persistenceFailed:
            "Bleat could not save or read the iCloud data on this device."
        case .engineUnavailable:
            "Bleat could not initialize iCloud synchronization."
        case .unexpected:
            "Bleat encountered an unexpected iCloud synchronization error."
        case .cloudKit(let failure):
            cloudKitMessage(failure)
        }
    }

    fileprivate var systemImage: String {
        switch cause {
        case .cloudKit(let failure):
            switch failure.code {
            case .networkUnavailable, .networkFailure,
                .serviceUnavailable, .serverResponseLost:
                "icloud.slash"
            case .notAuthenticated, .accountTemporarilyUnavailable:
                "person.crop.circle.badge.exclamationmark"
            case .quotaExceeded:
                "externaldrive.badge.exclamationmark"
            case .permissionFailure, .managedAccountRestricted:
                "lock.trianglebadge.exclamationmark"
            default:
                "exclamationmark.triangle"
            }
        case .persistenceFailed:
            "externaldrive.badge.exclamationmark"
        case .cancelled:
            "xmark.circle"
        case .disabled:
            "icloud.slash"
        case .invalidRecord, .engineUnavailable, .unexpected:
            "exclamationmark.triangle"
        }
    }

    fileprivate var isRetryable: Bool {
        switch cause {
        case .cloudKit(let failure): failure.isRetryable
        case .cancelled, .persistenceFailed, .engineUnavailable: true
        case .disabled, .invalidRecord, .unexpected: false
        }
    }

    fileprivate var remoteTelemetryFailureCategory:
        RemoteTelemetryFailureCategory
    {
        switch cause {
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

    private func cloudKitMessage(_ failure: CloudKitFailure) -> String {
        switch failure.code {
        case .notAuthenticated:
            "Sign in to iCloud in Settings to synchronize Bleat."
        case .accountTemporarilyUnavailable:
            "Your iCloud account is temporarily unavailable. Try again when iCloud is ready."
        case .networkUnavailable, .networkFailure, .serverResponseLost:
            "Bleat could not reach iCloud. Check this device's connection and try again."
        case .serviceUnavailable, .zoneBusy:
            "iCloud is temporarily unavailable. Try again later."
        case .requestRateLimited:
            if let retryAfter = failure.retryAfterSeconds {
                "iCloud asked Bleat to wait before synchronizing again. Try again in \(max(1, Int(retryAfter.rounded(.up)))) seconds."
            } else {
                "iCloud asked Bleat to wait before synchronizing again."
            }
        case .quotaExceeded:
            "There is not enough iCloud storage to synchronize Bleat."
        case .permissionFailure, .managedAccountRestricted:
            "This iCloud account is not permitted to synchronize Bleat."
        case .badContainer, .missingEntitlement, .badDatabase,
            .incompatibleVersion:
            "Bleat's iCloud configuration is unavailable in this build."
        case .partialFailure, .serverRecordChanged, .batchRequestFailed,
            .changeTokenExpired, .constraintViolation:
            "Bleat could not merge the iCloud data safely. Try again before changing local data."
        case .operationCancelled:
            "iCloud synchronization was cancelled."
        default:
            "Bleat could not complete iCloud synchronization."
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private let service: any AppServicing
    private var nearbyServerDiscovery: (any NearbyServerDiscovering)?
    private let diagnostics: any DiagnosticRecording
    private let remoteTelemetryConsentStore: RemoteTelemetryConsentStore
    private let remoteTelemetryConsentController:
        any RemoteTelemetryConsentApplying
    private let remoteTelemetryTracer: any RemoteTelemetryTracing
    private let initialLaunchStage: AppLaunchStage
    private var hasStarted = false
    private var librariesGeneration: UInt64 = 0
    private var libraryPageGeneration: UInt64 = 0
    private var homeShelvesGeneration: UInt64 = 0
    private var bookProgressGeneration: UInt64 = 0
    private var seriesPageGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var bookDetailGeneration: UInt64 = 0
    private var playbackStartGeneration: UInt64 = 0
    @ObservationIgnored
    private var playbackStartTask: Task<PlaybackStartOutcome, Never>?
    @ObservationIgnored
    private var playbackStartPhase: PlaybackStartPhase?
    @ObservationIgnored
    private var playbackStartInvalidationTask: Task<Void, Never>?
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
    @ObservationIgnored
    private var privateCloudSyncTask: Task<Void, Never>?
    @ObservationIgnored
    private var privateCloudSyncGeneration: UInt64 = 0
    private var liveUpdatesAreActive = true
    private var pendingLiveLibraryRefresh = false
    private var pendingLiveItemIDs: Set<LibraryItemID> = []
    private var pendingLocalSessionSyncAccounts: [AccountID: ServerAccount] =
        [:]
    @ObservationIgnored
    private var pendingBookProgressMutations:
        [BookProgressMutationKey: UUID] = [:]
    @ObservationIgnored
    private var bookProgressMutationStages:
        [BookProgressMutationKey: BookProgressMutationStage] = [:]
    @ObservationIgnored
    private var bookProgressMutationRevisions:
        [BookProgressMutationKey: UInt64] = [:]
    @ObservationIgnored
    private var bookProgressReconciliationTasks:
        [BookProgressMutationKey: Task<Void, Never>] = [:]
    @ObservationIgnored
    private var bookProgressRevision: UInt64 = 0
    @ObservationIgnored
    private(set) var bookProgressActionGeneration: UInt64 = 0
    private let bookProgressOperationTimeout: Duration
    private let bookProgressSleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored
    private var downloadRecoveryTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingDownloadRecoveryAccounts: [AccountID: ServerAccount] =
        [:]

    private(set) var phase: AppPhase
    private(set) var launchStage: AppLaunchStage
    private(set) var loginStatus: LoginStatus = .idle
    private(set) var loginDiscovery: ResourceState<DiscoveredServer> = .idle
    private(set) var nearbyServerDiscoveryState: NearbyServerDiscoveryState =
        .idle
    private(set) var accountActionStatus: AccountActionStatus = .idle
    private(set) var isResettingLocalData = false
    private(set) var localDataResetFailure: AppFailure?
    private(set) var endpointDiagnostics: AppEndpointDiagnostics?
    private(set) var liveUpdateConnectionState:
        AudiobookshelfLiveConnectionState = .disconnected
    private(set) var networkPathState: AppNetworkPathState = .unknown
    private(set) var playbackStartTarget: PlaybackStartTarget?
    private(set) var account: ServerAccount?
    private(set) var accounts: [ServerAccount] = []
    private(set) var libraries: ResourceState<[LibrarySummary]> = .idle
    private(set) var librariesRefreshState: ResourceRefreshState = .idle
    private(set) var selectedLibrary: LibrarySummary?
    private(set) var isNavigationReady = false
    private(set) var books: ResourceState<LibraryItemsPage> = .idle
    private(set) var booksRefreshState: ResourceRefreshState = .idle
    private(set) var libraryPaginationState: LibraryPaginationState = .idle
    private let libraryPageMerger = LibraryPageMerger()

    #if DEBUG || BLEAT_UI_TESTING
        /// Resident memory snapshot exposed via accessibility label
        /// `perf.memory` for the performance UI test. Only updated when the
        /// `--ui-testing-large-library` launch argument is present.
        private(set) var perfMemoryLabel: String = ""

        private var isPerformanceTestMode: Bool {
            ProcessInfo.processInfo.arguments.contains(
                "--ui-testing-large-library"
            )
        }

        private func captureMemorySnapshotIfNeeded() {
            guard isPerformanceTestMode else { return }
            perfMemoryLabel = "\(ProcessMemory.residentBytes)"
        }
    #endif
    private(set) var librarySort: LibraryItemSort = .title
    private(set) var librarySortDescending = false
    private(set) var libraryBrowseFilter: LibraryBrowseFilter = .all
    private(set) var seriesBooks: ResourceState<LibraryItemsPage> = .idle
    private(set) var seriesPaginationState: LibraryPaginationState = .idle
    private(set) var selectedSeries: SeriesDestination?
    private(set) var homeShelves: ResourceState<[LibraryBookShelf]> = .idle
    private(set) var homeShelvesRefreshState: ResourceRefreshState = .idle
    private(set) var searchQuery = ""
    private(set) var searchResults: ResourceState<LibrarySearchResults> = .idle
    private(set) var selectedBookID: LibraryItemID?
    private(set) var bookDetail: ResourceState<LibraryBookDetail> = .idle
    private(set) var bookBookmarks: ResourceState<[AudioBookmark]> = .idle
    private(set) var bookEditSaveState: BookEditSaveState = .idle
    private(set) var bookDeletionState: BookDeletionState = .idle
    private(set) var bookProgressUpdateState: BookProgressUpdateState = .idle
    private(set) var bookProgressFailures: [BookProgressFailureEntry] = []
    private(set) var presentedBookProgressFailure: BookProgressFailureEntry?
    var bookProgressFailure: AppFailure? {
        presentedBookProgressFailure?.failure
    }
    private(set) var bookFinishedStates: [LibraryItemID: Bool] = [:]
    private(set) var statistics: ResourceState<StatisticsSummary> = .idle
    private(set) var privateCloudState: PrivateCloudState = .idle
    private(set) var cloudAccountRestoreState: CloudAccountRestoreState = .idle
    private(set) var privateCloudSyncAvailable = true
    private(set) var privateCloudSyncEnabled = true
    private(set) var canCancelPrivateCloudSynchronization = false
    private(set) var pendingCloudServerConfigurationChanges:
        [CloudServerConfigurationChange] = []
    private(set) var pendingCloudConfigurationConflict:
        CloudConfigurationConflict?
    private(set) var remoteTelemetryEnabled: Bool
    private(set) var remoteTelemetryTokenAvailability:
        TelemetryTokenAvailability = .disabled
    @ObservationIgnored
    private var remoteTelemetryTokenAvailabilityGeneration: UInt64 = 0
    let playback: PlaybackModel
    let downloads: DownloadModel
    let transcription: ChapterTranscriptionModel

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
        initialLaunchStage: AppLaunchStage? = nil,
        transcription: ChapterTranscriptionModel? = nil,
        remoteTelemetryConsentStore: RemoteTelemetryConsentStore? = nil,
        remoteTelemetryConsentController:
            any RemoteTelemetryConsentApplying =
            InactiveRemoteTelemetryConsentController(),
        remoteTelemetryTracer: any RemoteTelemetryTracing =
            InactiveRemoteTelemetryTracer(),
        remoteTelemetryDownloadLogger: any RemoteTelemetryDownloadLogging =
            InactiveRemoteTelemetryDownloadLogger(),
        bookProgressOperationTimeout: Duration = .seconds(30),
        bookProgressSleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.service = service
        self.nearbyServerDiscovery = nearbyServerDiscovery
        self.diagnostics = diagnostics
        let consentStore =
            remoteTelemetryConsentStore ?? RemoteTelemetryConsentStore()
        self.remoteTelemetryConsentStore = consentStore
        self.remoteTelemetryConsentController =
            remoteTelemetryConsentController
        self.remoteTelemetryTracer = remoteTelemetryTracer
        self.bookProgressOperationTimeout = bookProgressOperationTimeout
        self.bookProgressSleep = bookProgressSleep
        remoteTelemetryEnabled = consentStore.isEnabled
        let launchStage =
            initialLaunchStage
            ?? AppLaunchStage.randomlySelectedInitialStage()
        self.initialLaunchStage = launchStage
        self.launchStage = launchStage
        let subsystems = Self.makePlaybackAndDownloads(
            service: service,
            downloadsStorageRootURL: downloadsStorageRootURL,
            diagnostics: diagnostics,
            remoteTelemetryTracer: remoteTelemetryTracer,
            remoteTelemetryDownloadLogger: remoteTelemetryDownloadLogger
        )
        self.playback = subsystems.playback
        self.downloads = subsystems.downloads
        self.transcription =
            transcription
            ?? ChapterTranscriptionModel(
                remoteTelemetryTracer: remoteTelemetryTracer
            )
        if let bootstrapError {
            hasStarted = true
            switch bootstrapError {
            case .persistenceUnavailable:
                phase = .unavailable(.persistenceUnavailable)
            case .storedDataMigrationFailed:
                phase = .unavailable(
                    AppFailure(.appStart, .storedDataMigrationFailed)
                )
            }
        } else {
            phase = .launching
        }
        if remoteTelemetryEnabled {
            let storageGeneration =
                consentStore
                .ensureEnabledStorageGeneration()
            remoteTelemetryConsentController
                .applyRemoteTelemetryConsent(
                    true,
                    storageGeneration: storageGeneration
                )
        } else {
            remoteTelemetryConsentController
                .applyRemoteTelemetryConsent(
                    false,
                    storageGeneration: nil
                )
        }
    }

    func setRemoteTelemetryEnabled(_ enabled: Bool) {
        guard remoteTelemetryEnabled != enabled else { return }

        // Persist withdrawal before crossing the asynchronous runtime
        // boundary. A later exporter must independently consult this setting
        // before export or token renewal.
        let storageGeneration = remoteTelemetryConsentStore.setEnabled(enabled)
        remoteTelemetryEnabled = enabled
        remoteTelemetryTokenAvailabilityGeneration &+= 1
        if !enabled {
            remoteTelemetryTokenAvailability = .disabled
        }
        remoteTelemetryConsentController
            .applyRemoteTelemetryConsent(
                enabled,
                storageGeneration: storageGeneration
            )
    }

    func setRemoteTelemetryForeground(_ foreground: Bool) {
        remoteTelemetryConsentController
            .setRemoteTelemetryForeground(foreground)
    }

    func refreshRemoteTelemetryTokenAvailability() async {
        let generation = remoteTelemetryTokenAvailabilityGeneration
        let availability =
            await remoteTelemetryConsentController.telemetryTokenAvailability()
        guard generation == remoteTelemetryTokenAvailabilityGeneration else {
            return
        }
        remoteTelemetryTokenAvailability = availability
    }

    func monitorRemoteTelemetryTokenAvailability(
        interval: Duration = .seconds(1)
    ) async {
        while !Task.isCancelled {
            await refreshRemoteTelemetryTokenAvailability()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
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
        diagnostics: any DiagnosticRecording,
        remoteTelemetryTracer: any RemoteTelemetryTracing,
        remoteTelemetryDownloadLogger: any RemoteTelemetryDownloadLogging
    ) -> (playback: PlaybackModel, downloads: DownloadModel) {
        let playback = PlaybackModel(
            service: service,
            diagnostics: diagnostics,
            remoteTelemetryTracer: remoteTelemetryTracer
        )
        let downloads = DownloadModel(
            service: service,
            storageRootURL: downloadsStorageRootURL,
            diagnostics: diagnostics,
            remoteTelemetryTracer: remoteTelemetryTracer,
            remoteTelemetryDownloadLogger: remoteTelemetryDownloadLogger
        )
        playback.setAutomaticDownloadHandler { [weak downloads] activity in
            await downloads?.handleAutomaticPlaybackActivity(activity)
        }
        playback.setAutomaticCachedPlaybackHandlers(
            resolve: { [weak downloads] accountID, itemID, time in
                guard let downloads,
                    let record = downloads.record(
                        accountID: accountID,
                        itemID: itemID
                    )
                else {
                    return nil
                }
                return await downloads.automaticCachedPlaybackWindow(
                    for: record,
                    containing: time
                )
            },
            release: { [weak downloads] pin in
                downloads?.releaseAutomaticCachePin(pin)
            }
        )
        return (playback, downloads)
    }

    func start() async {
        guard !hasStarted else {
            return
        }
        let telemetrySpan = remoteTelemetryTracer.beginSpan(
            operation: .appLaunch
        )
        var telemetryOutcome = RemoteTelemetryOutcome.cancelled
        defer { telemetrySpan.end(telemetryOutcome) }
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
                privateCloudState = .idle
            } else {
                privateCloudState = .disabled
            }
            launchStage = .restoringAccount
            await diagnostics.record(
                .started(.restoreAccounts, category: .auth)
            )
            accounts = try await service.accounts()
            if let pending = accounts.first(where: {
                $0.connectionState == .reauthenticationRequired
            }) {
                cloudAccountRestoreState = .awaitingCredentials(pending.id)
            }
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
                telemetryOutcome = .succeeded
                schedulePrivateCloudSyncAfterLaunch()
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
            telemetryOutcome = .succeeded
            schedulePrivateCloudSyncAfterLaunch()
            #if DEBUG || BLEAT_UI_TESTING
                captureMemorySnapshotIfNeeded()
            #endif
        } catch let error {
            let failure = AppFailure(operation: .appStart, serviceError: error)
            telemetryOutcome = failure.remoteTelemetryOutcome
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
        let telemetrySpan = remoteTelemetryTracer.beginSpan(
            operation: .accountConnection,
            source: .remote
        )
        var telemetryOutcome = RemoteTelemetryOutcome.cancelled
        defer { telemetrySpan.end(telemetryOutcome) }
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
            telemetryOutcome = .succeeded
            return true
        } catch let error {
            let failure = AppFailure(operation: .login, serviceError: error)
            telemetryOutcome = failure.remoteTelemetryOutcome
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
        if self.account?.id == account.id {
            await invalidatePlaybackStarts()
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
                resetBrowsingResourcesForAccountChange()
                await downloads.start(account: updated)
                await loadLibraries()
                startLiveUpdates(for: updated)
            }
            if privateCloudSyncEnabled {
                privateCloudState = .syncing
                do {
                    try await service
                        .forcePushPrivateCloudServerConfiguration(updated)
                    pendingCloudServerConfigurationChanges.removeAll {
                        $0.id == updated.id
                    }
                    privateCloudState = .idle
                } catch let error {
                    privateCloudState = .failed(
                        AppFailure(
                            operation: .privateCloudSync,
                            serviceError: error
                        )
                    )
                }
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
        let telemetrySpan = remoteTelemetryTracer.beginSpan(
            operation: .accountConnection,
            source: .remote
        )
        var telemetryOutcome = RemoteTelemetryOutcome.cancelled
        defer { telemetrySpan.end(telemetryOutcome) }
        guard let account else {
            let failure = AppFailure(
                .reauthenticate,
                .authenticationRequired
            )
            loginStatus = .failed(failure)
            telemetryOutcome = failure.remoteTelemetryOutcome
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
            telemetryOutcome = .succeeded
            return true
        } catch let error {
            let failure = AppFailure(
                operation: .reauthenticate, serviceError: error)
            telemetryOutcome = failure.remoteTelemetryOutcome
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
        await invalidatePlaybackStarts()
        accountActionStatus = .switching
        await stopLiveUpdatesAndWait()
        await diagnostics.record(
            .started(.switchAccount, category: .auth)
        )
        do {
            try await service.activateAccount(selectedAccount)
            account = selectedAccount
            resetBrowsingResourcesForAccountChange()
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
        if case .loaded = libraries {
            await refreshLibraries()
            return
        }
        guard let account else {
            libraries = .failed(
                AppFailure(.loadLibraries, .authenticationRequired)
            )
            return
        }
        await refreshBookProgress(for: account)
        librariesGeneration &+= 1
        let operationGeneration = librariesGeneration
        await diagnostics.record(
            .started(.loadLibraries, category: .api)
        )
        libraries = .loading
        librariesRefreshState = .idle
        isNavigationReady = false
        let previouslySelectedLibraryID = selectedLibrary?.id
        libraryPageGeneration &+= 1
        books = .idle
        booksRefreshState = .idle
        libraryPaginationState = .idle
        homeShelves = .idle
        homeShelvesRefreshState = .idle
        resetSearch()
        resetBookDetail()
        resetSeriesBrowse()

        do {
            let loadedLibraries = try await service.libraries(for: account)
                .filter { library in
                    library.mediaType == .book
                }
            guard operationGeneration == librariesGeneration,
                self.account?.id == account.id
            else {
                return
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
            guard operationGeneration == librariesGeneration,
                self.account?.id == account.id
            else {
                return
            }
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

    func refreshLibraries() async {
        if let account {
            await refreshBookProgress(for: account)
        }
        await refreshLibrariesContent()
    }

    func refreshLibrariesForPullToRefresh() async {
        let telemetrySpan = remoteTelemetryTracer.beginSpan(
            operation: .libraryRefresh,
            source: .remote
        )
        let startingGeneration = librariesGeneration
        if let account {
            await refreshBookProgress(for: account)
        }
        await refreshLibrariesContent()
        let expectedGeneration = startingGeneration &+ 1
        let outcome =
            librariesGeneration == expectedGeneration
            ? currentLibraryRefreshOutcome(includeLibraries: true)
            : .cancelled
        telemetrySpan.end(outcome)
    }

    private func refreshLibrariesContent() async {
        librariesGeneration &+= 1
        let operationGeneration = librariesGeneration
        guard let account else {
            let appFailure = AppFailure(
                .loadLibraries,
                .authenticationRequired
            )
            let failure = ResourceRefreshState.failed(appFailure)
            if librariesRefreshState != failure {
                librariesRefreshState = failure
            }
            return
        }
        await diagnostics.record(
            .started(.loadLibraries, category: .api)
        )
        do {
            let loadedLibraries = try await service.refreshedLibraries(
                for: account
            )
            .filter { $0.mediaType == .book }
            guard operationGeneration == librariesGeneration,
                self.account?.id == account.id
            else {
                return
            }
            let loadedState = ResourceState.loaded(loadedLibraries)
            if libraries != loadedState {
                libraries = loadedState
            }
            if librariesRefreshState != .idle {
                librariesRefreshState = .idle
            }
            await diagnostics.record(
                .completed(
                    .loadLibraries,
                    category: .api,
                    count: loadedLibraries.count
                )
            )
            guard let currentLibrary = selectedLibrary else {
                guard let firstLibrary = loadedLibraries.first else {
                    setEmptyLibraryContentIfChanged()
                    return
                }
                await selectLibrary(firstLibrary)
                return
            }
            guard
                let retainedLibrary = loadedLibraries.first(where: {
                    $0.id == currentLibrary.id
                })
            else {
                selectedLibrary = nil
                clearEntityBrowseFilter()
                resetSearch()
                resetBookDetail()
                resetSeriesBrowse()
                guard let firstLibrary = loadedLibraries.first else {
                    libraryPageGeneration &+= 1
                    setEmptyLibraryContentIfChanged()
                    booksRefreshState = .idle
                    homeShelvesRefreshState = .idle
                    return
                }
                await selectLibrary(firstLibrary)
                return
            }
            if selectedLibrary != retainedLibrary {
                selectedLibrary = retainedLibrary
            }
            await refreshSelectedLibraryContent()
        } catch let error {
            guard operationGeneration == librariesGeneration,
                self.account?.id == account.id
            else {
                return
            }
            let failure = AppFailure(
                operation: .loadLibraries, serviceError: error)
            let failedState = ResourceRefreshState.failed(failure)
            if librariesRefreshState != failedState {
                librariesRefreshState = failedState
            }
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
        if selectedLibrary?.id == library.id {
            if selectedLibrary != library {
                selectedLibrary = library
            }
            await refreshSelectedLibrary()
            return
        }
        if selectedLibrary?.id != library.id {
            clearEntityBrowseFilter()
            resetSearch()
            resetBookDetail()
            resetSeriesBrowse()
        }
        selectedLibrary = library
        homeShelvesGeneration &+= 1
        let homeOperationGeneration = homeShelvesGeneration
        homeShelves = .loading
        homeShelvesRefreshState = .idle
        await diagnostics.record(
            .started(.loadHome, category: .api)
        )

        await reloadBooks(preservingLoadedContent: false)
        guard self.account?.id == account.id,
            selectedLibrary?.id == library.id,
            homeOperationGeneration == homeShelvesGeneration
        else {
            return
        }
        isNavigationReady = true
        do {
            let shelves = try await service.homeShelves(
                for: account,
                libraryID: library.id
            )
            guard self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                homeOperationGeneration == homeShelvesGeneration
            else {
                return
            }
            let loadedState = ResourceState.loaded(shelves)
            if homeShelves != loadedState {
                homeShelves = loadedState
            }
            await diagnostics.record(
                .completed(
                    .loadHome,
                    category: .api,
                    count: shelves.count
                )
            )
        } catch let error {
            guard self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                homeOperationGeneration == homeShelvesGeneration
            else {
                return
            }
            let failure = AppFailure(
                operation: .loadHome, serviceError: error)
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

    func refreshSelectedLibrary() async {
        if let account {
            await refreshBookProgress(for: account)
        }
        await refreshSelectedLibraryContent()
    }

    func refreshSelectedLibraryForPullToRefresh() async {
        let telemetrySpan = remoteTelemetryTracer.beginSpan(
            operation: .libraryRefresh,
            source: .remote
        )
        let startingGeneration = homeShelvesGeneration
        if let account {
            await refreshBookProgress(for: account)
        }
        await refreshSelectedLibraryContent()
        let expectedGeneration = startingGeneration &+ 1
        let outcome =
            homeShelvesGeneration == expectedGeneration
            ? currentLibraryRefreshOutcome(includeLibraries: false)
            : .cancelled
        telemetrySpan.end(outcome)
    }

    private func refreshSelectedLibraryContent() async {
        homeShelvesGeneration &+= 1
        let operationGeneration = homeShelvesGeneration
        guard let account, let library = selectedLibrary else {
            return
        }
        await diagnostics.record(
            .started(.loadHome, category: .api)
        )

        await reloadBooks(preservingLoadedContent: true)
        guard !Task.isCancelled,
            self.account?.id == account.id,
            selectedLibrary?.id == library.id,
            operationGeneration == homeShelvesGeneration
        else {
            return
        }
        if !isNavigationReady {
            isNavigationReady = true
        }
        do {
            let shelves = try await service.refreshedHomeShelves(
                for: account,
                libraryID: library.id
            )
            guard !Task.isCancelled,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                operationGeneration == homeShelvesGeneration
            else {
                return
            }
            let loadedState = ResourceState.loaded(shelves)
            if homeShelves != loadedState {
                homeShelves = loadedState
            }
            if homeShelvesRefreshState != .idle {
                homeShelvesRefreshState = .idle
            }
            await diagnostics.record(
                .completed(
                    .loadHome,
                    category: .api,
                    count: shelves.count
                )
            )
        } catch let error {
            guard !Task.isCancelled,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                operationGeneration == homeShelvesGeneration
            else {
                return
            }
            let failure = AppFailure(
                operation: .loadHome, serviceError: error)
            if case .loaded = homeShelves {
                let failedState = ResourceRefreshState.failed(failure)
                if homeShelvesRefreshState != failedState {
                    homeShelvesRefreshState = failedState
                }
            } else {
                homeShelves = .failed(failure)
                homeShelvesRefreshState = .idle
            }
            await diagnostics.record(
                .failed(
                    .loadHome,
                    category: .api,
                    failureCode: failure.diagnosticFailureCode
                )
            )
        }
    }

    private func currentLibraryRefreshOutcome(
        includeLibraries: Bool
    ) -> RemoteTelemetryOutcome {
        if includeLibraries {
            if case .failed(let failure) = librariesRefreshState {
                return failure.remoteTelemetryOutcome
            }
            if case .failed(let failure) = libraries {
                return failure.remoteTelemetryOutcome
            }
        }
        if case .failed(let failure) = booksRefreshState {
            return failure.remoteTelemetryOutcome
        }
        if case .failed(let failure) = books {
            return failure.remoteTelemetryOutcome
        }
        if case .failed(let failure) = homeShelvesRefreshState {
            return failure.remoteTelemetryOutcome
        }
        if case .failed(let failure) = homeShelves {
            return failure.remoteTelemetryOutcome
        }
        guard account != nil else {
            return .failed(.authentication)
        }
        guard includeLibraries || selectedLibrary != nil else {
            return .failed(.unknown)
        }
        return Task.isCancelled ? .cancelled : .succeeded
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

    func reloadBooks(
        preservingLoadedContent: Bool = false
    ) async {
        libraryPageGeneration &+= 1
        let operationGeneration = libraryPageGeneration
        guard let account, let library = selectedLibrary else {
            books = .failed(
                AppFailure(.loadLibraryPage, .authenticationRequired)
            )
            return
        }
        let retainsLoadedContent: Bool
        let retainedPage: LibraryItemsPage?
        if preservingLoadedContent, case .loaded(let page) = books {
            retainsLoadedContent = true
            retainedPage = page
        } else {
            retainsLoadedContent = false
            retainedPage = nil
        }
        if !retainsLoadedContent {
            books = .loading
            booksRefreshState = .idle
        }
        if libraryPaginationState != .idle {
            libraryPaginationState = .idle
        }
        let filter = libraryBrowseFilter
        await diagnostics.record(
            .started(.loadLibraryPage, category: .api)
        )

        do {
            let page: LibraryItemsPage
            if let retainedPage {
                page = try await refreshedLibraryItemsPage(
                    for: account,
                    library: library,
                    filter: filter,
                    retaining: retainedPage
                )
            } else {
                let request = try makeLibraryItemsPageRequest(
                    page: 0,
                    sort: librarySort,
                    descending: librarySortDescending,
                    filter: filter.itemFilter
                )
                if preservingLoadedContent {
                    page = try await service.refreshedPage(
                        for: account,
                        libraryID: library.id,
                        request: request
                    )
                } else {
                    page = try await service.page(
                        for: account,
                        libraryID: library.id,
                        request: request
                    )
                }
            }
            guard !Task.isCancelled,
                operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                libraryBrowseFilter == filter
            else {
                return
            }
            let loadedState = ResourceState.loaded(page)
            if books != loadedState {
                books = loadedState
            }
            if booksRefreshState != .idle {
                booksRefreshState = .idle
            }
            await diagnostics.record(
                .completed(
                    .loadLibraryPage,
                    category: .api,
                    count: page.items.count
                )
            )
        } catch let error {
            guard !Task.isCancelled,
                operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id
            else {
                return
            }
            let failure = AppFailure(
                operation: .loadLibraryPage, serviceError: error)
            if preservingLoadedContent, case .loaded = books {
                let failedState = ResourceRefreshState.failed(failure)
                if booksRefreshState != failedState {
                    booksRefreshState = failedState
                }
            } else {
                books = .failed(failure)
                booksRefreshState = .idle
            }
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
            let mergedPage = await libraryPageMerger.merge(
                current: latestPage,
                next: nextPage
            )
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                libraryBrowseFilter == filter,
                case .loaded(let currentPage) = books,
                currentPage.page == latestPage.page
            else {
                return
            }
            books = .loaded(mergedPage)
            libraryPaginationState = .idle
            #if DEBUG || BLEAT_UI_TESTING
                captureMemorySnapshotIfNeeded()
            #endif
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
            return detail.summary
        } catch {
            return nil
        }
    }

    func refreshSeries(_ destination: SeriesDestination) async {
        if let account {
            await refreshBookProgress(for: account)
        }
        await loadSeries(destination)
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
        await search(query: query, preservingLoadedContent: false)
    }

    private func search(
        query: String,
        preservingLoadedContent: Bool
    ) async {
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
        if !preservingLoadedContent {
            searchResults = .loading
        }
        await diagnostics.record(
            .started(.search, category: .api)
        )

        do {
            let results = try await service.search(
                for: account,
                libraryID: selectedLibrary.id,
                query: normalizedQuery
            )
            guard !Task.isCancelled,
                searchGeneration == operationGeneration
            else {
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
            if preservingLoadedContent {
                await diagnostics.record(
                    .failed(
                        .search,
                        category: .api,
                        failureCode: failure.diagnosticFailureCode
                    )
                )
                return
            }
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
            let detail = try await fetchBookDetail(book, account: account)
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

    func prepareBookAction(
        for book: LibraryBookSummary,
        account expectedAccount: ServerAccount? = nil
    ) async -> BookActionPreparationResult {
        guard let account else {
            return .failed(AppFailure(.loadBook, .authenticationRequired))
        }
        if let expectedAccount, expectedAccount.id != account.id {
            return .failed(AppFailure(.loadBook, .authenticationRequired))
        }
        do {
            let detail = try await fetchBookDetail(book, account: account)
            guard self.account?.id == account.id else {
                return .failed(AppFailure(.loadBook, .authenticationRequired))
            }
            return .loaded(detail)
        } catch let error {
            guard self.account?.id == account.id else {
                return .failed(AppFailure(.loadBook, .authenticationRequired))
            }
            return .failed(
                AppFailure(operation: .loadBook, serviceError: error)
            )
        }
    }

    private func fetchBookDetail(
        _ book: LibraryBookSummary,
        account: ServerAccount
    ) async throws(AppServiceError) -> LibraryBookDetail {
        try await service.bookDetail(
            for: account,
            libraryID: book.libraryID,
            itemID: book.id
        )
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
            publishBookProgressFailure(
                AppFailure(.updateProgress, .authenticationRequired),
                itemID: detail.id
            )
            return
        }
        await setFinished(
            isFinished,
            book: detail.summary,
            expectedAccount: account,
            expectedContextGeneration: bookProgressActionGeneration
        )
    }

    func setFinished(
        _ isFinished: Bool,
        book: LibraryBookSummary,
        expectedAccount: ServerAccount
    ) async {
        await setFinished(
            isFinished,
            book: book,
            expectedAccount: expectedAccount,
            expectedContextGeneration: bookProgressActionGeneration
        )
    }

    func setFinished(
        _ isFinished: Bool,
        book: LibraryBookSummary,
        expectedAccount: ServerAccount,
        expectedContextGeneration: UInt64
    ) async {
        guard account?.id == expectedAccount.id,
            bookProgressActionGeneration == expectedContextGeneration
        else { return }
        let key = BookProgressMutationKey(
            accountID: expectedAccount.id,
            itemID: book.id
        )
        guard pendingBookProgressMutations[key] == nil else {
            return
        }

        let token = UUID()
        bookProgressRevision &+= 1
        let revision = bookProgressRevision
        invalidateBookProgressReconciliation(for: key)
        pendingBookProgressMutations[key] = token
        bookProgressMutationStages[key] = .preparing
        bookProgressMutationRevisions[key] = revision
        bookProgressUpdateState = .saving

        let timedResult = await timedBookProgressMutation(
            isFinished: isFinished,
            book: book,
            account: expectedAccount,
            key: key,
            token: token,
            contextGeneration: expectedContextGeneration,
            revision: revision
        )
        guard pendingBookProgressMutations[key] == token else {
            return
        }
        let stage = bookProgressMutationStages.removeValue(forKey: key)
        pendingBookProgressMutations.removeValue(forKey: key)

        guard account?.id == expectedAccount.id,
            bookProgressActionGeneration == expectedContextGeneration,
            bookProgressMutationRevisions[key] == revision
        else {
            return
        }
        switch timedResult {
        case .deadline:
            let cause: AppFailureCause =
                stage == .submitted ? .uncertainMutation : .timeout
            publishBookProgressFailure(
                AppFailure(.updateProgress, cause),
                itemID: book.id
            )
        case .operation(.failed(let failure)):
            publishBookProgressFailure(failure, itemID: book.id)
        case .operation(.cancelled):
            break
        case .operation(.confirmed(let preparedDetail)):
            let confirmedProgress = commitFinishedState(
                isFinished,
                detail: preparedDetail,
                account: expectedAccount
            )
            bookProgressUpdateState = .saved
            scheduleBookProgressReconciliation(
                for: expectedAccount,
                detail: preparedDetail,
                key: key,
                contextGeneration: expectedContextGeneration,
                revision: revision,
                confirmedProgress: confirmedProgress
            )
        }
    }

    func isBookProgressMutationPending(_ itemID: LibraryItemID) -> Bool {
        guard let account else { return false }
        return pendingBookProgressMutations[
            BookProgressMutationKey(accountID: account.id, itemID: itemID)
        ] != nil
    }

    func dismissBookProgressFailure() {
        guard presentedBookProgressFailure != nil else { return }
        presentedBookProgressFailure = nil
        guard !bookProgressFailures.isEmpty else { return }
        bookProgressFailures.removeFirst()
        if let next = bookProgressFailures.first {
            bookProgressUpdateState = .failed(next.failure)
        } else if case .failed = bookProgressUpdateState {
            bookProgressUpdateState = .idle
        }
        guard !bookProgressFailures.isEmpty else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            guard
                let self,
                self.presentedBookProgressFailure == nil,
                let next = self.bookProgressFailures.first
            else {
                return
            }
            self.presentedBookProgressFailure = next
        }
    }

    private func timedBookProgressMutation(
        isFinished: Bool,
        book: LibraryBookSummary,
        account: ServerAccount,
        key: BookProgressMutationKey,
        token: UUID,
        contextGeneration: UInt64,
        revision: UInt64
    ) async -> TimedBookProgressMutationResult {
        let (stream, continuation) =
            AsyncStream<TimedBookProgressMutationResult>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
        let operationTask = Task { @MainActor [weak self] in
            guard let self else {
                continuation.yield(.operation(.cancelled))
                continuation.finish()
                return
            }
            let result = await performBookProgressMutation(
                isFinished: isFinished,
                book: book,
                account: account,
                key: key,
                token: token,
                contextGeneration: contextGeneration,
                revision: revision
            )
            continuation.yield(.operation(result))
            continuation.finish()
        }
        let sleep = bookProgressSleep
        let timeout = bookProgressOperationTimeout
        let deadlineTask = Task {
            do {
                try await sleep(timeout)
                guard !Task.isCancelled else { return }
                continuation.yield(.deadline)
                continuation.finish()
            } catch {
                // Cancellation means the operation won the race.
            }
        }
        var iterator = stream.makeAsyncIterator()
        let result = await iterator.next() ?? .deadline
        operationTask.cancel()
        deadlineTask.cancel()
        return result
    }

    private func performBookProgressMutation(
        isFinished: Bool,
        book: LibraryBookSummary,
        account: ServerAccount,
        key: BookProgressMutationKey,
        token: UUID,
        contextGeneration: UInt64,
        revision: UInt64
    ) async -> BookProgressMutationResult {
        let detail: LibraryBookDetail
        do {
            detail = try await fetchBookDetail(book, account: account)
        } catch let error {
            return .failed(
                AppFailure(operation: .updateProgress, serviceError: error)
            )
        }
        guard !Task.isCancelled,
            pendingBookProgressMutations[key] == token,
            bookProgressMutationRevisions[key] == revision,
            bookProgressActionGeneration == contextGeneration,
            self.account?.id == account.id
        else {
            return .cancelled
        }
        let availability = BookActionAvailability(
            user: account.user,
            detail: detail
        )
        guard availability.access == .allowed else {
            return .failed(
                AppFailure(
                    .updateProgress,
                    Self.failureCause(for: availability.access)
                )
            )
        }

        bookProgressMutationStages[key] = .submitted
        do {
            try await service.updateBookProgress(
                for: account,
                itemID: detail.id,
                update: BookProgressUpdate(isFinished: isFinished)
            )
        } catch let error {
            let failure =
                Self.isUncertainProgressMutation(error)
                ? AppFailure(.updateProgress, .uncertainMutation)
                : AppFailure(operation: .updateProgress, serviceError: error)
            return .failed(failure)
        }
        guard !Task.isCancelled,
            pendingBookProgressMutations[key] == token,
            bookProgressMutationRevisions[key] == revision,
            bookProgressActionGeneration == contextGeneration,
            self.account?.id == account.id
        else {
            return .cancelled
        }
        return .confirmed(detail)
    }

    private func commitFinishedState(
        _ isFinished: Bool,
        detail: LibraryBookDetail,
        account: ServerAccount
    ) -> LibraryBookProgress? {
        guard self.account?.id == account.id else { return nil }
        let nowMilliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        let previous = detail.progress
        let progress = LibraryBookProgress(
            id: previous?.id ?? "local-\(detail.id.rawValue)",
            userID: account.user.id,
            libraryItemID: detail.id,
            bookID: detail.bookID,
            duration: previous?.duration ?? detail.duration,
            progress: isFinished ? 1 : (previous?.progress ?? 0),
            currentTime: isFinished
                ? detail.duration : (previous?.currentTime ?? 0),
            isFinished: isFinished,
            hideFromContinueListening:
                previous?.hideFromContinueListening ?? false,
            lastUpdateMilliseconds: nowMilliseconds,
            startedAtMilliseconds:
                previous?.startedAtMilliseconds ?? nowMilliseconds,
            finishedAtMilliseconds: isFinished ? nowMilliseconds : nil
        )
        let updatedDetail = detail.replacingProgress(with: progress)
        bookFinishedStates[detail.id] = isFinished
        if selectedBookID == detail.id {
            bookDetail = .loaded(updatedDetail)
        }
        if isFinished {
            removeFromContinueListening(detail.id)
            Task { [service] in
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
        }
        return progress
    }

    private func removeFromContinueListening(_ itemID: LibraryItemID) {
        guard case .loaded(let shelves) = homeShelves else { return }
        homeShelves = .loaded(
            shelves.map { shelf in
                guard shelf.id == "continue-listening" else { return shelf }
                let remaining = shelf.items.filter { $0.id != itemID }
                guard remaining.count != shelf.items.count else { return shelf }
                return LibraryBookShelf(
                    id: shelf.id,
                    label: shelf.label,
                    labelLocalizationKey: shelf.labelLocalizationKey,
                    items: remaining,
                    total: max(remaining.count, shelf.total - 1)
                )
            }
        )
    }

    private func scheduleBookProgressReconciliation(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        key: BookProgressMutationKey,
        contextGeneration: UInt64,
        revision: UInt64,
        confirmedProgress: LibraryBookProgress?
    ) {
        let query = searchQuery
        let task = Task { @MainActor [weak self] in
            guard let self,
                isCurrentBookProgressMutation(
                    key: key,
                    contextGeneration: contextGeneration,
                    revision: revision
                )
            else { return }
            defer {
                finishBookProgressReconciliation(
                    key: key,
                    revision: revision
                )
            }
            if selectedBookID == detail.id {
                do {
                    let reconciled = try await service.refreshedBookDetail(
                        for: account,
                        libraryID: detail.libraryID,
                        itemID: detail.id
                    )
                    guard isCurrentBookProgressMutation(
                        key: key,
                        contextGeneration: contextGeneration,
                        revision: revision
                    ), selectedBookID == detail.id else { return }
                    let merged = Self.reconciledBookDetail(
                        reconciled,
                        preserving: confirmedProgress,
                        newerThan: detail.progress?.lastUpdateMilliseconds
                    )
                    bookDetail = .loaded(merged)
                    bookFinishedStates[detail.id] =
                        merged.progress?.isFinished
                        ?? bookFinishedStates[detail.id]
                        ?? false
                } catch let error {
                    guard isCurrentBookProgressMutation(
                        key: key,
                        contextGeneration: contextGeneration,
                        revision: revision
                    ), selectedBookID == detail.id else { return }
                    let failure =
                        if let serviceError = error as? AppServiceError {
                            AppFailure(
                                operation: .loadBook,
                                serviceError: serviceError
                            )
                        } else {
                            AppFailure(.loadBook, .invalidServerResponse)
                        }
                    await diagnostics.record(
                        .failed(
                            .loadBook,
                            category: .api,
                            failureCode: failure.diagnosticFailureCode
                        )
                    )
                }
            }
            guard isCurrentBookProgressMutation(
                key: key,
                contextGeneration: contextGeneration,
                revision: revision
            ) else { return }
            await refreshSelectedLibraryContent()
            guard isCurrentBookProgressMutation(
                key: key,
                contextGeneration: contextGeneration,
                revision: revision
            ),
                searchQuery == query,
                !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            await search(query: query, preservingLoadedContent: true)
        }
        bookProgressReconciliationTasks[key] = task
    }

    static func reconciledBookDetail(
        _ refreshed: LibraryBookDetail,
        preserving confirmedProgress: LibraryBookProgress?,
        newerThan canonicalLastUpdateMilliseconds: Int64?
    ) -> LibraryBookDetail {
        guard let confirmedProgress else { return refreshed }
        guard let refreshedProgress = refreshed.progress else {
            return refreshed.replacingProgress(with: confirmedProgress)
        }
        guard let canonicalLastUpdateMilliseconds else {
            return refreshed
        }
        guard
            refreshedProgress.lastUpdateMilliseconds
                > canonicalLastUpdateMilliseconds
        else {
            return refreshed.replacingProgress(with: confirmedProgress)
        }
        return refreshed
    }

    private func invalidateBookProgressReconciliation(
        for key: BookProgressMutationKey
    ) {
        guard let task = bookProgressReconciliationTasks.removeValue(
            forKey: key
        ) else { return }
        task.cancel()
    }

    private func finishBookProgressReconciliation(
        key: BookProgressMutationKey,
        revision: UInt64
    ) {
        guard bookProgressMutationRevisions[key] == revision else { return }
        bookProgressReconciliationTasks[key] = nil
    }

    private func isCurrentBookProgressMutation(
        key: BookProgressMutationKey,
        contextGeneration: UInt64,
        revision: UInt64
    ) -> Bool {
        !Task.isCancelled
            && account?.id == key.accountID
            && bookProgressActionGeneration == contextGeneration
            && bookProgressMutationRevisions[key] == revision
    }

    private func publishBookProgressFailure(
        _ failure: AppFailure,
        itemID: LibraryItemID
    ) {
        let entry = BookProgressFailureEntry(itemID: itemID, failure: failure)
        bookProgressFailures.append(entry)
        if presentedBookProgressFailure == nil,
            bookProgressFailures.count == 1
        {
            presentedBookProgressFailure = entry
        }
        bookProgressUpdateState = .failed(failure)
    }

    private static func failureCause(
        for access: LibraryItemAccessDecision
    ) -> AppFailureCause {
        switch access {
        case .allowed: .permissionDenied
        case .inaccessibleLibrary: .inaccessibleLibrary
        case .inaccessibleTags: .inaccessibleTags
        case .explicitContentDenied: .explicitContentDenied
        }
    }

    private static func isUncertainProgressMutation(
        _ error: AppServiceError
    ) -> Bool {
        guard case .progress(let progressError) = error else { return false }
        switch progressError {
        case .requestFailed:
            return true
        case .authenticationFailed(let authenticationError):
            switch authenticationError {
            case .requestCancelled, .requestTransportFailed,
                .refreshTransportFailed, .refreshCancelled,
                .automaticReauthenticationTransportFailed:
                return true
            case .invalidAccountID, .accountOperationInProgress,
                .authenticationEndpoint, .requestDoesNotMatchRoute,
                .credentialsReadFailed, .missingCredentials,
                .authorizationFailed, .refreshRequestConstructionFailed,
                .refreshRejected, .unexpectedRefreshStatus,
                .malformedRefreshResponse, .missingAccessToken,
                .missingRefreshToken, .credentialPersistenceFailed,
                .savedLoginCredentialsReadFailed,
                .automaticReauthenticationFailed,
                .retriedRequestUnauthorized:
                return false
            }
        case .invalidItemID, .emptyUpdate, .invalidDuration,
            .invalidCurrentTime, .invalidProgress,
            .requestConstructionFailed, .requestEncodingFailed,
            .unexpectedStatus, .malformedResponse:
            return false
        }
    }

    func startPlayback(
        book: LibraryBookSummary,
        account: ServerAccount,
        position: PlaybackStartPosition = .resume
    ) async -> PlaybackStartOutcome {
        await startPlayback(
            PlaybackStartRequest(
                book: .summary(book),
                account: account,
                position: position
            )
        )
    }

    func performBrowsingPlaybackAction(
        book: LibraryBookSummary,
        account: ServerAccount
    ) async -> BrowsingPlaybackActionOutcome {
        if playback.accountID == account.id,
            playback.itemID == book.id,
            playback.isPlaybackRequested
        {
            playback.pause()
            return .paused
        }
        return .start(
            await startPlayback(book: book, account: account)
        )
    }

    func startPlayback(
        detail: LibraryBookDetail,
        account: ServerAccount,
        position: PlaybackStartPosition = .resume
    ) async -> PlaybackStartOutcome {
        await startPlayback(
            PlaybackStartRequest(
                book: .detail(detail),
                account: account,
                position: position
            )
        )
    }

    func startPlayback(
        download: DownloadedBookRecord,
        account: ServerAccount,
        position: PlaybackStartPosition = .resume
    ) async -> PlaybackStartOutcome {
        await startPlayback(
            PlaybackStartRequest(
                book: .download(download),
                account: account,
                position: position
            )
        )
    }

    private func startPlayback(
        _ request: PlaybackStartRequest
    ) async -> PlaybackStartOutcome {
        let target = PlaybackStartTarget(
            accountID: request.account.id,
            itemID: request.book.itemID
        )
        let generation = await invalidatePlaybackStarts(
            replacementTarget: target
        )
        guard playbackStartGeneration == generation else {
            return .superseded
        }
        playbackStartPhase = .resolving
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return PlaybackStartOutcome.failed(
                    AppFailure(.openPlayback, .accountUnavailable)
                )
            }
            return await performPlaybackStart(
                request,
                generation: generation
            )
        }
        playbackStartTask = task
        let outcome = await task.value
        if playbackStartGeneration == generation {
            playbackStartTask = nil
            playbackStartPhase = nil
            playbackStartTarget = nil
        }
        return outcome
    }

    func coverPlaybackState(
        accountID: AccountID,
        itemID: LibraryItemID
    ) -> PlayableBookCoverState {
        PlayableBookCoverState.derive(
            target: playbackStartTarget,
            accountID: accountID,
            itemID: itemID,
            playbackAccountID: playback.accountID,
            playbackItemID: playback.itemID,
            playbackState: playback.state,
            isPlaybackRequested: playback.isPlaybackRequested
        )
    }

    private func performPlaybackStart(
        _ request: PlaybackStartRequest,
        generation: UInt64
    ) async -> PlaybackStartOutcome {
        guard
            let savedAccount = accounts.first(where: {
                $0.id == request.account.id
            })
        else {
            return await playbackStartFailure(
                AppFailureCause.accountUnavailable,
                generation: generation
            )
        }
        guard
            validateSuppliedPlaybackIdentity(
                request.book,
                accountID: savedAccount.id
            )
        else {
            return await playbackStartFailure(
                .playbackIdentityMismatch,
                generation: generation
            )
        }
        guard playbackStartGeneration == generation else {
            return .superseded
        }

        let itemID = request.book.itemID
        let libraryID = request.book.libraryID
        if playback.isPrepared(
            accountID: savedAccount.id,
            itemID: itemID
        ) {
            guard playback.libraryID == libraryID else {
                return await playbackStartFailure(
                    .playbackIdentityMismatch,
                    generation: generation
                )
            }
            let resolved = PlaybackStartPositionResolver.resolve(
                request.position,
                duration: playback.duration,
                chapters: playback.chapters
            )
            if case .failed(let failure) = resolved {
                return await playbackStartFailure(
                    failure.cause,
                    generation: generation
                )
            }
            if case .absoluteTime(let time) = resolved {
                playbackStartPhase = .positioningActivePlayer
                await playback.seek(to: time)
            }
            guard playbackStartGeneration == generation else {
                return .superseded
            }
            playbackStartPhase = .resolving
            playback.play()
            return playbackStartOutcome(
                source: .activePlayer,
                accountID: savedAccount.id,
                itemID: itemID
            )
        }

        let downloaded = downloads.record(
            accountID: savedAccount.id,
            itemID: itemID
        )
        if let downloaded,
            downloaded.manifest.purpose == .manual,
            downloads.isFullBookAvailable(downloaded)
        {
            guard downloaded.detail.id == itemID,
                downloaded.detail.libraryID == libraryID,
                downloaded.manifest.itemID == itemID
            else {
                return await playbackStartFailure(
                    .playbackIdentityMismatch,
                    generation: generation
                )
            }
            let resolved = PlaybackStartPositionResolver.resolve(
                request.position,
                duration: downloaded.detail.duration,
                chapters: downloaded.detail.chapters
            )
            if case .failed(let failure) = resolved {
                return await playbackStartFailure(
                    failure.cause,
                    generation: generation
                )
            }
            do {
                let urls = try await downloads.localTrackURLs(
                    for: downloaded
                )
                guard playbackStartGeneration == generation else {
                    return .superseded
                }
                playbackStartPhase = .preparingPlayback
                await playback.startDownloaded(
                    detail: downloaded.detail,
                    trackURLs: urls,
                    accountID: savedAccount.id,
                    account: savedAccount,
                    initialTime: resolved.explicitTime
                )
            } catch {
                let failure = AppFailure.mediaUnavailable
                let outcome = await playbackStartFailure(
                    failure,
                    generation: generation
                )
                guard case .failed = outcome else {
                    return outcome
                }
                playback.fail(failure)
                return outcome
            }
            guard playbackStartGeneration == generation else {
                return .superseded
            }
            playbackStartPhase = .resolving
            return playbackStartOutcome(
                source: .downloaded,
                accountID: savedAccount.id,
                itemID: itemID
            )
        }

        if let downloaded,
            downloaded.manifest.purpose == .automaticCache
        {
            guard downloaded.detail.id == itemID,
                downloaded.detail.libraryID == libraryID,
                downloaded.manifest.itemID == itemID
            else {
                return await playbackStartFailure(
                    .playbackIdentityMismatch,
                    generation: generation
                )
            }
            let resolved = PlaybackStartPositionResolver.resolve(
                request.position,
                duration: downloaded.detail.duration,
                chapters: downloaded.detail.chapters
            )
            if case .failed(let failure) = resolved {
                return await playbackStartFailure(
                    failure.cause,
                    generation: generation
                )
            }
            let preferredTime = playback.preferredDownloadedStartTime(
                detail: downloaded.detail,
                accountID: savedAccount.id,
                initialTime: resolved.explicitTime
            )
            if let window = await downloads.automaticCachedPlaybackWindow(
                for: downloaded,
                containing: preferredTime
            ) {
                guard playbackStartGeneration == generation else {
                    downloads.releaseAutomaticCachePin(window.pin)
                    return .superseded
                }
                playbackStartPhase = .preparingPlayback
                await playback.startDownloaded(
                    detail: downloaded.detail,
                    trackURLs: [],
                    accountID: savedAccount.id,
                    account: savedAccount,
                    initialTime: resolved.explicitTime,
                    automaticCachedWindow: window
                )
                guard playbackStartGeneration == generation else {
                    return .superseded
                }
                playbackStartPhase = .resolving
                return playbackStartOutcome(
                    source: .downloaded,
                    accountID: savedAccount.id,
                    itemID: itemID
                )
            }
        }

        let detail: LibraryBookDetail
        switch request.book {
        case .detail(let suppliedDetail):
            detail = suppliedDetail
        case .summary, .download:
            do {
                detail = try await service.bookDetail(
                    for: savedAccount,
                    libraryID: libraryID,
                    itemID: itemID
                )
            } catch let error {
                guard playbackStartGeneration == generation else {
                    return .superseded
                }
                let failure = AppFailure(
                    operation: .openPlayback,
                    serviceError: error
                )
                return await playbackStartFailure(
                    failure,
                    generation: generation
                )
            }
        }
        guard playbackStartGeneration == generation else {
            return .superseded
        }
        guard detail.id == itemID, detail.libraryID == libraryID else {
            return await playbackStartFailure(
                .playbackIdentityMismatch,
                generation: generation
            )
        }

        let availability = BookActionAvailability(
            user: savedAccount.user,
            detail: detail
        )
        if availability.access != .allowed {
            return await playbackStartFailure(
                Self.playbackFailureCause(for: availability.access),
                generation: generation
            )
        }
        let resolved = PlaybackStartPositionResolver.resolve(
            request.position,
            duration: detail.duration,
            chapters: detail.chapters
        )
        if case .failed(let failure) = resolved {
            return await playbackStartFailure(
                failure.cause,
                generation: generation
            )
        }
        playbackStartPhase = .preparingPlayback
        await playback.start(
            detail: detail,
            account: savedAccount,
            initialTime: resolved.explicitTime
        )
        guard playbackStartGeneration == generation else {
            return .superseded
        }
        playbackStartPhase = .resolving
        return playbackStartOutcome(
            source: .streamed,
            accountID: savedAccount.id,
            itemID: itemID
        )
    }

    private func validateSuppliedPlaybackIdentity(
        _ book: PlaybackStartBook,
        accountID: AccountID
    ) -> Bool {
        guard case .download(let supplied) = book else {
            return true
        }
        guard supplied.manifest.accountID == accountID,
            supplied.manifest.itemID == supplied.detail.id,
            let current = downloads.record(
                accountID: supplied.manifest.accountID,
                itemID: supplied.manifest.itemID
            )
        else {
            return false
        }
        return current.manifest.downloadID == supplied.manifest.downloadID
            && current.detail.id == supplied.detail.id
            && current.detail.libraryID == supplied.detail.libraryID
    }

    private func playbackStartOutcome(
        source: PlaybackStartSource,
        accountID: AccountID,
        itemID: LibraryItemID
    ) -> PlaybackStartOutcome {
        if case .failed(let failure) = playback.state {
            return .failed(failure)
        }
        guard playback.accountID == accountID,
            playback.itemID == itemID,
            playback.isPrepared(accountID: accountID, itemID: itemID)
        else {
            return .failed(.mediaUnavailable)
        }
        return .started(source: source)
    }

    private func playbackStartFailure(
        _ cause: AppFailureCause,
        generation: UInt64
    ) async -> PlaybackStartOutcome {
        await playbackStartFailure(
            AppFailure(.openPlayback, cause),
            generation: generation
        )
    }

    private func playbackStartFailure(
        _ failure: AppFailure,
        generation: UInt64
    ) async -> PlaybackStartOutcome {
        guard playbackStartGeneration == generation else {
            return .superseded
        }
        await recordPlaybackStartFailure(failure)
        guard playbackStartGeneration == generation else {
            return .superseded
        }
        return .failed(failure)
    }

    private func recordPlaybackStartFailure(
        _ failure: AppFailure
    ) async {
        await diagnostics.record(
            .failed(
                .openPlayback,
                category: .playback,
                failureCode: failure.diagnosticFailureCode
            )
        )
    }

    private static func playbackFailureCause(
        for access: LibraryItemAccessDecision
    ) -> AppFailureCause {
        switch access {
        case .allowed: .permissionDenied
        case .inaccessibleLibrary: .inaccessibleLibrary
        case .inaccessibleTags: .inaccessibleTags
        case .explicitContentDenied: .explicitContentDenied
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
        guard privateCloudSyncAvailable,
            privateCloudSyncEnabled,
            privateCloudSyncTask == nil
        else {
            return
        }
        guard let task = beginPrivateCloudSynchronization() else {
            return
        }
        await task.value
    }

    func cancelPrivateCloudSynchronization() async {
        guard let task = privateCloudSyncTask,
            canCancelPrivateCloudSynchronization
        else {
            return
        }
        privateCloudSyncGeneration &+= 1
        canCancelPrivateCloudSynchronization = false
        privateCloudState = .cancelling
        task.cancel()
        await service.cancelPrivateCloudSynchronization()
        await task.value
        privateCloudSyncTask = nil
        privateCloudState = privateCloudSyncEnabled ? .cancelled : .disabled
    }

    private func schedulePrivateCloudSyncAfterLaunch() {
        guard privateCloudSyncAvailable,
            privateCloudSyncEnabled,
            privateCloudSyncTask == nil
        else {
            return
        }
        _ = beginPrivateCloudSynchronization()
    }

    private func beginPrivateCloudSynchronization() -> Task<Void, Never>? {
        guard privateCloudSyncTask == nil else {
            return nil
        }
        privateCloudSyncGeneration &+= 1
        let generation = privateCloudSyncGeneration
        privateCloudState = .syncing
        if case .signedOut = phase, accounts.isEmpty {
            cloudAccountRestoreState = .synchronizing
        }
        canCancelPrivateCloudSynchronization = true
        let task = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            let shouldReloadStatistics =
                await performPrivateCloudSynchronization(
                    generation: generation
                )
            guard privateCloudSyncGeneration == generation else {
                return
            }
            privateCloudSyncTask = nil
            canCancelPrivateCloudSynchronization = false
            if shouldReloadStatistics {
                await loadStatistics()
            }
        }
        privateCloudSyncTask = task
        return task
    }

    private func performPrivateCloudSynchronization(
        generation: UInt64
    ) async -> Bool {
        do {
            let changes = try await service.synchronizePrivateCloud()
            let configurationConflict =
                await service.pendingPrivateCloudConfigurationConflict()
            guard privateCloudSyncGeneration == generation,
                !Task.isCancelled
            else {
                return false
            }
            let synchronizedAccounts = try await service.accounts()
            let active = try await service.activeAccount()
            guard privateCloudSyncGeneration == generation,
                !Task.isCancelled
            else {
                return false
            }
            queueCloudServerConfigurationChanges(changes)
            pendingCloudConfigurationConflict = configurationConflict
            accounts = synchronizedAccounts
            if !changes.isEmpty {
                cloudAccountRestoreState = .awaitingSelection
            } else if let pending = synchronizedAccounts.first(where: {
                $0.connectionState == .reauthenticationRequired
            }) {
                cloudAccountRestoreState = .awaitingCredentials(pending.id)
            } else if case .signedOut = phase, synchronizedAccounts.isEmpty {
                cloudAccountRestoreState = .noAccounts
            } else {
                cloudAccountRestoreState = .idle
            }
            if let active {
                account = active
            }
            playback.reloadSyncedPreferences()
            downloads.reloadSyncedPreferences()
            privateCloudState = .idle
            canCancelPrivateCloudSynchronization = false
            return true
        } catch let error {
            guard privateCloudSyncGeneration == generation,
                !Task.isCancelled
            else {
                return false
            }
            if case .privateCloud(let failure) = error,
                failure.cause == .cancelled
            {
                privateCloudState = .cancelled
                return false
            }
            privateCloudState = .failed(
                AppFailure(
                    operation: .privateCloudSync,
                    serviceError: error
                )
            )
            if case .signedOut = phase, accounts.isEmpty {
                cloudAccountRestoreState = .failed(
                    AppFailure(
                        operation: .privateCloudSync,
                        serviceError: error
                    )
                )
            }
            return false
        }
    }

    var pendingRestoredAccount: ServerAccount? {
        accounts.first {
            $0.connectionState == .reauthenticationRequired
        }
    }

    @discardableResult
    func authenticatePendingRestoredAccount(password: String) async -> Bool {
        guard !password.isEmpty, let pending = pendingRestoredAccount,
            !loginStatus.isSubmitting
        else { return false }
        loginStatus = .submitting(.signingIn)
        do {
            let authenticated = try await service.authenticateRestoredAccount(
                pending,
                password: password
            )
            account = authenticated
            accounts.removeAll { $0.id == authenticated.id }
            accounts.append(authenticated)
            accounts.sort(by: Self.sortAccounts)
            phase = .signedIn
            cloudAccountRestoreState = .idle
            loginStatus = .idle
            await downloads.start(account: authenticated)
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

    func resolveCloudServerConfigurationChange(
        _ change: CloudServerConfigurationChange,
        accept: Bool
    ) async {
        privateCloudState = .syncing
        do {
            try await service.resolvePrivateCloudServerConfigurationChange(
                accountID: change.id,
                accept: accept
            )
            pendingCloudServerConfigurationChanges.removeAll {
                $0.id == change.id
            }
            privateCloudState = .idle
            guard accept else {
                return
            }
            await stopLiveUpdatesAndWait()
            hasStarted = false
            phase = .launching
            launchStage = initialLaunchStage
            await start()
        } catch let error {
            privateCloudState = .failed(
                AppFailure(
                    operation: .privateCloudSync,
                    serviceError: error
                )
            )
        }
    }

    func resolveCloudServerConfigurationSelection(
        _ selected: CloudServerConfigurationChange
    ) async {
        let candidates = pendingCloudServerConfigurationChanges
        privateCloudState = .syncing
        do {
            for accountID in Set(candidates.map(\.id))
            where accountID != selected.id {
                try await service.resolvePrivateCloudServerConfigurationChange(
                    accountID: accountID,
                    accept: false
                )
            }
            try await service.resolvePrivateCloudServerConfigurationSelection(
                selected.incoming
            )
            pendingCloudServerConfigurationChanges.removeAll()
            let restored = try await service
                .authenticateRestoredAccountUsingSynchronizedCredential(
                    selected.incoming
                )
            cloudAccountRestoreState = restored == nil
                ? .awaitingCredentials(selected.id) : .idle
            privateCloudState = .idle
            await stopLiveUpdatesAndWait()
            hasStarted = false
            phase = .launching
            launchStage = initialLaunchStage
            await start()
        } catch let error {
            privateCloudState = .failed(
                AppFailure(
                    operation: .privateCloudSync,
                    serviceError: error
                )
            )
        }
    }

    func resolveCloudConfigurationConflict(
        _ resolution: CloudConfigurationConflictResolution
    ) async -> AppFailure? {
        privateCloudState = .syncing
        do {
            try await service.resolvePrivateCloudConfigurationConflict(
                resolution
            )
            pendingCloudConfigurationConflict = nil
            playback.reloadSyncedPreferences()
            downloads.reloadSyncedPreferences()
            privateCloudState = .idle
            return nil
        } catch let error {
            let failure = AppFailure(
                operation: .privateCloudSync,
                serviceError: error
            )
            privateCloudState = .failed(failure)
            return failure
        }
    }

    private func queueCloudServerConfigurationChanges(
        _ changes: [CloudServerConfigurationChange]
    ) {
        for change in changes {
            pendingCloudServerConfigurationChanges.removeAll {
                $0.id == change.id
            }
            pendingCloudServerConfigurationChanges.append(change)
        }
    }

    func setPrivateCloudSyncEnabled(
        _ enabled: Bool,
        deleteCloudData: Bool = false
    ) async {
        guard privateCloudSyncAvailable else {
            privateCloudSyncEnabled = false
            pendingCloudServerConfigurationChanges.removeAll()
            pendingCloudConfigurationConflict = nil
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
            if !enabled {
                pendingCloudServerConfigurationChanges.removeAll()
                pendingCloudConfigurationConflict = nil
            }
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

    func resetLocalData() async {
        guard !isResettingLocalData else {
            return
        }
        isResettingLocalData = true
        localDataResetFailure = nil
        await diagnostics.record(
            .started(.resetAppData, category: .app)
        )

        await cancelPrivateCloudSynchronization()
        do {
            if privateCloudSyncAvailable, privateCloudSyncEnabled {
                try await service.setPrivateCloudSyncEnabled(
                    false,
                    deleteCloudData: false
                )
                privateCloudSyncEnabled = false
                privateCloudState = .disabled
            }
            await invalidatePlaybackStarts()
            await stopLiveUpdatesAndWait()
            await playback.stop()
            for account in accounts {
                transcription.cancel(for: account.id)
            }
            guard await downloads.removeAllForLocalDataReset() else {
                let failure = AppFailure(
                    operation: .resetAppData,
                    serviceError: .localDataReset(.downloads)
                )
                localDataResetFailure = failure
                await diagnostics.record(
                    .failed(
                        .resetAppData,
                        category: .app,
                        failureCode: failure.diagnosticFailureCode
                    )
                )
                isResettingLocalData = false
                return
            }
            try await service.resetLocalData()
            clearLocalPreferences()
            accounts.removeAll()
            account = nil
            resetBrowsingResourcesForAccountChange()
            statistics = .idle
            accountActionStatus = .idle
            loginStatus = .idle
            privateCloudSyncEnabled = false
            privateCloudState = .disabled
            cloudAccountRestoreState = .idle
            pendingCloudServerConfigurationChanges.removeAll()
            pendingCloudConfigurationConflict = nil
            phase = .signedOut
            await diagnostics.record(
                .completed(.resetAppData, category: .app)
            )
        } catch let error {
            let failure = AppFailure(
                operation: .resetAppData,
                serviceError: error
            )
            localDataResetFailure = failure
            await diagnostics.record(
                .failed(
                    .resetAppData,
                    category: .app,
                    failureCode: failure.diagnosticFailureCode
                )
            )
        }
        isResettingLocalData = false
    }

    private func clearLocalPreferences() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("bleat.") || key == AppPreferenceKey.colourScheme {
            defaults.removeObject(forKey: key)
        }
        // The cloud database is deliberately retained. Keep synchronization
        // off after reset so it cannot immediately restore the erased local
        // state; the user can explicitly re-enable it in Settings later.
        defaults.set(false, forKey: "bleat.cloudKit.enabled.v1")
        ColourSchemeStore.shared.value = .defaultValue
        setRemoteTelemetryEnabled(false)
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
        await invalidatePlaybackStarts()
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
                resetBrowsingResourcesForAccountChange()
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
                downloads.updateNetworkPathState(state)
                schedulePendingLocalSessionSync(for: accounts)
                scheduleDownloadRecovery(for: accounts)
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

    private func scheduleDownloadRecovery(for accounts: [ServerAccount]) {
        for account in accounts {
            pendingDownloadRecoveryAccounts[account.id] = account
        }
        scheduleDownloadRecoveryWork()
    }

    private func scheduleDownloadRecoveryWork() {
        guard downloadRecoveryTask == nil else {
            return
        }
        downloadRecoveryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            while let next = pendingDownloadRecoveryAccounts.values.first {
                pendingDownloadRecoveryAccounts[next.id] = nil
                await downloads.recoverAfterNetworkChange(for: [next])
            }
            downloadRecoveryTask = nil
            if !pendingDownloadRecoveryAccounts.isEmpty {
                scheduleDownloadRecoveryWork()
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
                    bookFinishedStates[progress.itemID] = progress.isFinished
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
        let librariesChanged = pendingLiveLibraryRefresh
        let itemIDs = pendingLiveItemIDs
        pendingLiveLibraryRefresh = false
        pendingLiveItemIDs = []

        if librariesChanged {
            await refreshLibraries()
        } else {
            await refreshSelectedLibrary()
        }

        if let selectedBookID,
            librariesChanged || itemIDs.contains(selectedBookID),
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

    private func refreshedLibraryItemsPage(
        for account: ServerAccount,
        library: LibrarySummary,
        filter: LibraryBrowseFilter,
        retaining currentPage: LibraryItemsPage
    ) async throws(AppServiceError) -> LibraryItemsPage {
        let firstRequest = try makeLibraryItemsPageRequest(
            page: 0,
            limit: currentPage.limit,
            sort: librarySort,
            descending: librarySortDescending,
            filter: filter.itemFilter
        )
        let firstPage = try await service.refreshedPage(
            for: account,
            libraryID: library.id,
            request: firstRequest
        )
        guard firstPage.limit > 0 else {
            throw .libraryRepository(.remote(.invalidPage))
        }
        let lastAvailablePage =
            firstPage.total > 0
            ? (firstPage.total - 1) / firstPage.limit
            : 0
        let lastPageToRefresh = min(currentPage.page, lastAvailablePage)
        guard lastPageToRefresh > 0 else {
            return firstPage
        }

        var items = firstPage.items
        var itemIDs = Set(items.map(\.id))
        for pageNumber in 1...lastPageToRefresh {
            let request = try makeLibraryItemsPageRequest(
                page: pageNumber,
                limit: firstPage.limit,
                sort: librarySort,
                descending: librarySortDescending,
                filter: filter.itemFilter
            )
            let nextPage = try await service.refreshedPage(
                for: account,
                libraryID: library.id,
                request: request
            )
            guard nextPage.page == pageNumber,
                nextPage.limit == firstPage.limit,
                nextPage.total == firstPage.total
            else {
                throw .libraryRepository(.remote(.invalidPage))
            }
            for item in nextPage.items where itemIDs.insert(item.id).inserted {
                items.append(item)
            }
        }
        return LibraryItemsPage(
            items: items,
            total: firstPage.total,
            page: lastPageToRefresh,
            limit: firstPage.limit
        )
    }

    private func resetBookDetail() {
        bookDetailGeneration &+= 1
        selectedBookID = nil
        bookDetail = .idle
        bookBookmarks = .idle
        bookEditSaveState = .idle
        bookDeletionState = .idle
    }

    @discardableResult
    private func invalidatePlaybackStarts(
        replacementTarget: PlaybackStartTarget? = nil
    ) async -> UInt64 {
        playbackStartGeneration &+= 1
        let generation = playbackStartGeneration
        playbackStartTask?.cancel()
        playbackStartTask = nil
        let phase = playbackStartPhase
        playbackStartPhase = nil
        playbackStartTarget = replacementTarget
        let previousInvalidation = playbackStartInvalidationTask
        let invalidation = Task { @MainActor [weak self] in
            await previousInvalidation?.value
            guard let self else {
                return
            }
            switch phase {
            case .positioningActivePlayer:
                playback.pause()
            case .preparingPlayback:
                await playback.stop()
            case .resolving, nil:
                break
            }
        }
        playbackStartInvalidationTask = invalidation
        await invalidation.value
        if playbackStartGeneration == generation {
            playbackStartInvalidationTask = nil
        }
        return generation
    }

    private func resetSeriesBrowse() {
        seriesPageGeneration &+= 1
        selectedSeries = nil
        seriesBooks = .idle
        seriesPaginationState = .idle
    }

    private func setEmptyLibraryContentIfChanged() {
        let emptyBooks = ResourceState.loaded(
            LibraryItemsPage(items: [], total: 0, page: 0, limit: 20)
        )
        if books != emptyBooks {
            books = emptyBooks
        }
        let emptyShelves = ResourceState<[LibraryBookShelf]>.loaded([])
        if homeShelves != emptyShelves {
            homeShelves = emptyShelves
        }
    }

    private func resetBrowsingResourcesForAccountChange() {
        bookProgressActionGeneration &+= 1
        for task in bookProgressReconciliationTasks.values {
            task.cancel()
        }
        bookProgressReconciliationTasks = [:]
        pendingBookProgressMutations = [:]
        bookProgressMutationStages = [:]
        bookProgressMutationRevisions = [:]
        bookProgressFailures = []
        presentedBookProgressFailure = nil
        bookProgressUpdateState = .idle
        librariesGeneration &+= 1
        libraryPageGeneration &+= 1
        homeShelvesGeneration &+= 1
        selectedLibrary = nil
        libraries = .idle
        librariesRefreshState = .idle
        books = .idle
        booksRefreshState = .idle
        libraryPaginationState = .idle
        homeShelves = .idle
        homeShelvesRefreshState = .idle
        bookProgressGeneration &+= 1
        bookFinishedStates = [:]
        clearEntityBrowseFilter()
        resetSearch()
        resetBookDetail()
        resetSeriesBrowse()
    }

    func isBookFinished(_ itemID: LibraryItemID) -> Bool {
        bookFinishedStates[itemID] ?? false
    }

    func isBookFinished(_ itemID: LibraryItemID, fallback: Bool) -> Bool {
        bookFinishedStates[itemID] ?? fallback
    }

    private func refreshBookProgress(for account: ServerAccount) async {
        bookProgressGeneration &+= 1
        let generation = bookProgressGeneration
        do {
            let progress = try await service.allBookProgress(for: account)
            guard generation == bookProgressGeneration,
                self.account?.id == account.id
            else {
                return
            }
            bookFinishedStates = Dictionary(
                uniqueKeysWithValues: progress.map {
                    ($0.libraryItemID, $0.isFinished)
                }
            )
        } catch {
            // Browsing remains available with the last known progress snapshot.
        }
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
