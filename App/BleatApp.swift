import BleatCore
import SwiftUI
import UIKit

@MainActor
final class BleatAppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundDownloadCompletion: (() -> Void)?

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == bleatBackgroundDownloadSessionIdentifier else {
            completionHandler()
            return
        }
        Self.backgroundDownloadCompletion = completionHandler
    }
}

@main
struct BleatApp: App {
    @UIApplicationDelegateAdaptor(BleatAppDelegate.self)
    private var appDelegate
    @State private var model: AppModel

    init() {
        #if DEBUG
            if let testService = UITestAppService.current() {
                _model = State(initialValue: AppModel(service: testService))
                return
            }
        #endif

        do {
            _model = State(
                initialValue: AppModel(service: try LiveAppService()))
        } catch let error {
            _model = State(
                initialValue: AppModel(
                    service: UnavailableAppService(),
                    bootstrapError: error
                )
            )
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}

private struct UnavailableAppService: AppServicing {
    func accounts()
        async throws(AppServiceError) -> [ServerAccount]
    {
        throw .accountStore(.persistenceFailed)
    }

    func activeAccount()
        async throws(AppServiceError) -> ServerAccount?
    {
        throw .accountStore(.persistenceFailed)
    }

    func activateAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        throw .accountStore(.persistenceFailed)
    }

    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async throws(AppServiceError) -> ServerAccount {
        throw .accountStore(.persistenceFailed)
    }

    func libraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary] {
        throw .accountStore(.persistenceFailed)
    }

    func page(
        for account: ServerAccount,
        libraryID: LibraryID,
        page: Int,
        sort: LibraryItemSort,
        descending: Bool,
        filter: LibraryItemFilter?
    ) async throws(AppServiceError) -> LibraryItemsPage {
        throw .accountStore(.persistenceFailed)
    }

    func homeShelves(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> [LibraryBookShelf] {
        throw .accountStore(.persistenceFailed)
    }

    func search(
        for account: ServerAccount,
        libraryID: LibraryID,
        query: String
    ) async throws(AppServiceError) -> [LibraryBookSummary] {
        throw .accountStore(.persistenceFailed)
    }

    func bookDetail(
        for account: ServerAccount,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookDetail {
        throw .accountStore(.persistenceFailed)
    }

    func openPlayback(
        for account: ServerAccount,
        itemID: LibraryItemID,
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> AppPlaybackPreparation {
        throw .accountStore(.persistenceFailed)
    }

    func closePlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID
    ) async throws(AppServiceError) {
        throw .accountStore(.persistenceFailed)
    }

    func syncPlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID,
        currentTime: Double,
        duration: Double
    ) async throws(AppServiceError) {
        throw .accountStore(.persistenceFailed)
    }

    func syncLocalPlaybackSessions(
        for account: ServerAccount,
        sessions: [LocalPlaybackSession],
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> [LocalPlaybackSessionSyncResult] {
        throw .accountStore(.persistenceFailed)
    }

    func saveMetadata(
        for account: ServerAccount,
        baseline: LibraryBookDetail,
        draft: BookMetadataDraft,
        overwrite: Bool
    ) async throws(AppServiceError) -> AppMetadataSaveOutcome {
        throw .accountStore(.persistenceFailed)
    }

    func downloadPlan(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> DownloadPlan {
        throw .accountStore(.persistenceFailed)
    }

    func authorizedDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity
    ) async throws(AppServiceError) -> URLRequest {
        throw .accountStore(.persistenceFailed)
    }

    func replacementDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity,
        rejectedRequest: URLRequest
    ) async throws(AppServiceError) -> URLRequest {
        throw .accountStore(.persistenceFailed)
    }

    func replaceCover(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        jpegData: Data
    ) async throws(AppServiceError) -> LibraryBookDetail {
        throw .accountStore(.persistenceFailed)
    }

    func bookmarks(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [AudioBookmark] {
        throw .accountStore(.persistenceFailed)
    }

    func createBookmark(
        for account: ServerAccount,
        itemID: LibraryItemID,
        time: Double,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark {
        throw .accountStore(.persistenceFailed)
    }

    func renameBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark {
        throw .accountStore(.persistenceFailed)
    }

    func deleteBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark
    ) async throws(AppServiceError) {
        throw .accountStore(.persistenceFailed)
    }

    func bookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookProgress? {
        throw .accountStore(.persistenceFailed)
    }

    func updateBookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID,
        update: BookProgressUpdate
    ) async throws(AppServiceError) {
        throw .accountStore(.persistenceFailed)
    }

    func removeAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        throw .accountStore(.persistenceFailed)
    }
}
