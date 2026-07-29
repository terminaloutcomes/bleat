import BleatCore
import SwiftUI

@main
struct BleatApp: App {
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
    func activeAccount()
        async throws(AppServiceError) -> ServerAccount?
    {
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

    func firstPage(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> LibraryItemsPage {
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

    func removeAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        throw .accountStore(.persistenceFailed)
    }
}
