import AuthenticationServices
import BleatCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
final class AppBootstrap {
    let model: AppModel

    init() {
        let diagnostics: any DiagnosticRecording = SystemDiagnosticRecorder.shared
        if let event = LegacyDiagnosticLogCleanup.removeLegacyDirectory()
            .failureDiagnosticEvent {
            Task {
                await diagnostics.record(event)
            }
        }
        let remoteTelemetry = RemoteTelemetryController()

        #if DEBUG || BLEAT_UI_TESTING
            if let testService = UITestAppService.current() {
                model = AppModel(
                    service: testService,
                    nearbyServerDiscovery:
                        UnavailableNearbyServerDiscovery(),
                    bootstrapError: UITestAppService.bootstrapError,
                    diagnostics: diagnostics,
                    remoteTelemetryConsentController: remoteTelemetry,
                    remoteTelemetryTracer: remoteTelemetry.tracer
                )
                if UITestAppService.opensSettingsAtLaunch {
                    AppDeepLinkInbox.shared.openSettings()
                }
                return
            }
        #endif

        do {
            model = AppModel(
                service: try LiveAppService(
                    diagnostics: diagnostics,
                    privateCloudEvents:
                        CompositePrivateCloudSyncEventRecorder([
                            DiagnosticPrivateCloudSyncEventRecorder(
                                diagnostics: diagnostics
                            ),
                            remoteTelemetry.privateCloudEvents,
                        ]),
                    openIDBrowserProvider: {
                        SystemOpenIDBrowserSession(
                            anchorProvider: {
                                #if os(iOS)
                                let activeScenes = UIApplication.shared
                                    .connectedScenes
                                    .compactMap {
                                        $0 as? UIWindowScene
                                    }
                                    .filter {
                                        $0.activationState
                                            == .foregroundActive
                                    }
                                let windows = activeScenes.flatMap(\.windows)
                                return windows
                                    .first(where: \.isKeyWindow)
                                    ?? windows.first
                                #else
                                return NSApplication.shared.keyWindow
                                    ?? NSWindow()
                                #endif
                            }
                        )
                    }
                ),
                diagnostics: diagnostics,
                remoteTelemetryConsentController: remoteTelemetry,
                remoteTelemetryTracer: remoteTelemetry.tracer
            )
        } catch let error {
            model = AppModel(
                service: UnavailableAppService(),
                bootstrapError: error,
                diagnostics: diagnostics,
                remoteTelemetryConsentController: remoteTelemetry,
                remoteTelemetryTracer: remoteTelemetry.tracer
            )
        }
    }
}

#if os(iOS)
@MainActor
final class BleatAppDelegate: NSObject, UIApplicationDelegate {
    static var backgroundDownloadCompletion: (() -> Void)?
    let bootstrap = AppBootstrap()
    var model: AppModel { bootstrap.model }
    lazy var carPlayCoordinator = CarPlayCoordinator(model: model)

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
#endif

@main
struct BleatApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(BleatAppDelegate.self)
    private var appDelegate
    #else
    @State private var bootstrap = AppBootstrap()
    #endif

    private var model: AppModel {
        #if os(iOS)
        appDelegate.model
        #else
        bootstrap.model
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
        #if os(macOS)
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        AppDeepLinkInbox.shared.openSettings()
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(model.phase != .signedIn)
                }
            }
        #endif
    }
}

struct UnavailableAppService: AppServicing {
    func discoverServer(
        serverAddress: String
    ) async throws(AppServiceError) -> DiscoveredServer {
        throw .accountStore(.persistenceFailed)
    }

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
        password: String,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        throw .accountStore(.persistenceFailed)
    }

    func loginWithOpenID(
        serverAddress: String,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        throw .accountStore(.persistenceFailed)
    }

    func reauthenticate(
        _ account: ServerAccount,
        password: String
    ) async throws(AppServiceError) -> ServerAccount {
        throw .accountStore(.persistenceFailed)
    }

    func reauthenticateWithOpenID(
        _ account: ServerAccount,
        progress: @escaping AccountSubmissionProgress
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
        request: LibraryItemsPageRequest
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
    ) async throws(AppServiceError) -> LibrarySearchResults {
        throw .accountStore(.persistenceFailed)
    }

    func bookDetail(
        for account: ServerAccount,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookDetail {
        throw .accountStore(.persistenceFailed)
    }

    func refreshedBookDetail(
        for account: ServerAccount,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookDetail {
        throw .accountStore(.persistenceFailed)
    }

    func openPlayback(
        for account: ServerAccount,
        itemID: LibraryItemID,
        preference: PlaybackPreference,
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

    func deleteBook(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        mode: BookDeletionMode
    ) async throws(AppServiceError) -> AppBookDeletionOutcome {
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

    func allBookProgress(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibraryBookProgress] {
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
