import BleatCore
import Foundation
import SwiftData

enum AppBootstrapError: Error, Equatable, Sendable {
    case persistenceUnavailable
}

enum AppServiceError: Error, Equatable, Sendable {
    case invalidServerURL(ServerURLValidationError)
    case discovery(ServerDiscoveryError)
    case discoveryRequestFailed
    case onboarding(AccountOnboardingError)
    case accountStore(AccountStoreError)
    case libraryRepository(LibraryRepositoryError)
    case pageRequest(LibraryPageRequestError)
    case searchRequest(LibrarySearchRequestError)
    case searchCoordinator(LibrarySearchCoordinatorError)
    case bookDetail(LibraryRepositoryError)
    case playbackSession(PlaybackSessionError)
    case playbackSource(PlaybackSourceError)
    case playbackSync(PlaybackSyncError)
    case accountRemoval(AccountLifecycleError)
    case libraryCache(LibraryCacheError)
}

struct AppPlaybackTrack: Equatable, Sendable {
    let url: URL
    let startOffset: Double
    let duration: Double
    let title: String
}

enum AppPlaybackSource: Equatable, Sendable {
    case direct([AppPlaybackTrack])
    case hls(URL)
}

struct AppPlaybackPreparation: Equatable, Sendable {
    let sessionID: PlaybackSessionID
    let itemID: LibraryItemID
    let title: String
    let duration: Double
    let currentTime: Double
    let chapters: [PlaybackChapter]
    let source: AppPlaybackSource
}

protocol AppServicing: Sendable {
    func activeAccount()
        async throws(AppServiceError) -> ServerAccount?

    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async throws(AppServiceError) -> ServerAccount

    func libraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary]

    func firstPage(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> LibraryItemsPage

    func search(
        for account: ServerAccount,
        libraryID: LibraryID,
        query: String
    ) async throws(AppServiceError) -> [LibraryBookSummary]

    func bookDetail(
        for account: ServerAccount,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookDetail

    func openPlayback(
        for account: ServerAccount,
        itemID: LibraryItemID,
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> AppPlaybackPreparation

    func closePlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID
    ) async throws(AppServiceError)

    func syncPlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID,
        currentTime: Double,
        duration: Double
    ) async throws(AppServiceError)

    func removeAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError)
}

actor LiveAppService: AppServicing {
    private typealias Coordinator = AuthCoordinator<
        URLSessionHTTPTransport,
        TokenVault
    >

    private let modelContainer: ModelContainer
    private let transport: URLSessionHTTPTransport
    private let coordinator: Coordinator
    private let accountStore: AccountStore
    private let libraryCache: LibraryCache
    private let searchCoordinator = LibrarySearchCoordinator()

    init() throws(AppBootstrapError) {
        let schema = Schema([
            ServerAccountRecord.self,
            CachedLibraryCollectionRecord.self,
            CachedLibraryRecord.self,
            CachedLibraryPageRecord.self,
            CachedLibrarySearchRecord.self,
            CachedLibraryHomeRecord.self,
            CachedLibraryBookDetailRecord.self,
        ])
        do {
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        schema: schema,
                        isStoredInMemoryOnly: false
                    )
                ]
            )
        } catch {
            throw .persistenceUnavailable
        }

        transport = URLSessionHTTPTransport()
        let credentialStore = TokenVault(
            service: "com.yaleman.Bleat.credentials"
        )
        coordinator = Coordinator(
            transport: transport,
            credentialStore: credentialStore
        )
        accountStore = AccountStore(modelContainer: modelContainer)
        libraryCache = LibraryCache(modelContainer: modelContainer)
    }

    func activeAccount()
        async throws(AppServiceError) -> ServerAccount?
    {
        do {
            return try await accountStore.activeAccount()
        } catch let error {
            throw .accountStore(error)
        }
    }

    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async throws(AppServiceError) -> ServerAccount {
        let server: NormalizedServerURL
        do {
            server = try NormalizedServerURL(serverAddress)
        } catch let error {
            throw .invalidServerURL(error)
        }

        let discoveredServer: DiscoveredServer
        do {
            discoveredServer = try await ServerDiscoveryClient(
                transport: transport
            ).discover(server)
        } catch let error as ServerDiscoveryError {
            throw .discovery(error)
        } catch {
            throw .discoveryRequestFailed
        }

        do {
            return try await coordinator.loginAndPersistAccount(
                accountID: AccountID(
                    rawValue: UUID().uuidString.lowercased()
                ),
                discoveredServer: discoveredServer,
                username: username,
                password: password,
                accountStore: accountStore
            )
        } catch let error {
            throw .onboarding(error)
        }
    }

    func libraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary] {
        let repository = repository(for: account)
        do {
            return try await repository.libraries().value
        } catch let error {
            throw .libraryRepository(error)
        }
    }

    func firstPage(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> LibraryItemsPage {
        let request: LibraryItemsPageRequest
        do {
            request = try LibraryItemsPageRequest(page: 0)
        } catch let error {
            throw .pageRequest(error)
        }

        let repository = repository(for: account)
        do {
            return try await repository.libraryItems(
                in: libraryID,
                request: request
            ).value
        } catch let error {
            throw .libraryRepository(error)
        }
    }

    func search(
        for account: ServerAccount,
        libraryID: LibraryID,
        query: String
    ) async throws(AppServiceError) -> [LibraryBookSummary] {
        let request: LibrarySearchRequest
        do {
            request = try LibrarySearchRequest(query: query)
        } catch let error {
            throw .searchRequest(error)
        }

        let repository = repository(for: account)
        let operation: LibrarySearchCoordinator.Operation = {
            context,
            request in
            try await repository.search(
                in: context.libraryID,
                request: request
            )
        }
        do {
            return try await searchCoordinator.search(
                context: LibrarySearchContext(
                    accountID: account.id,
                    libraryID: libraryID
                ),
                request: request,
                operation: operation
            ).value
        } catch let error {
            throw .searchCoordinator(error)
        }
    }

    func bookDetail(
        for account: ServerAccount,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookDetail {
        let repository = repository(for: account)
        do {
            return try await repository.bookDetail(
                for: itemID,
                in: libraryID
            ).value
        } catch let error {
            throw .bookDetail(error)
        }
    }

    func openPlayback(
        for account: ServerAccount,
        itemID: LibraryItemID,
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> AppPlaybackPreparation {
        let session: PlaybackSession
        do {
            session = try await coordinator.openPlaybackSession(
                accountID: account.id,
                server: account.server,
                itemID: itemID,
                supportedMimeTypes: [
                    "audio/aac",
                    "audio/flac",
                    "audio/mp4",
                    "audio/mpeg",
                    "audio/x-m4a",
                    "audio/x-wav",
                ],
                deviceInfo: deviceInfo
            )
        } catch let error {
            throw .playbackSession(error)
        }

        let source: AppPlaybackSource
        do {
            switch try session.source(for: account.server) {
            case .direct(let tracks):
                source = .direct(
                    tracks.map { track in
                        AppPlaybackTrack(
                            url: track.url,
                            startOffset: track.track.startOffset,
                            duration: track.track.duration,
                            title: track.track.title
                        )
                    }
                )
            case .hls(let url):
                source = .hls(url)
            }
        } catch let error {
            try? await coordinator.closePlaybackSession(
                accountID: account.id,
                server: account.server,
                sessionID: session.id
            )
            throw .playbackSource(error)
        }

        return AppPlaybackPreparation(
            sessionID: session.id,
            itemID: session.libraryItemID,
            title: session.libraryItem.media.metadata.title,
            duration: session.duration,
            currentTime: session.currentTime,
            chapters: session.chapters,
            source: source
        )
    }

    func closePlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID
    ) async throws(AppServiceError) {
        do {
            try await coordinator.closePlaybackSession(
                accountID: account.id,
                server: account.server,
                sessionID: sessionID
            )
        } catch let error {
            throw .playbackSession(error)
        }
    }

    func syncPlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID,
        currentTime: Double,
        duration: Double
    ) async throws(AppServiceError) {
        do {
            try await coordinator.syncPlaybackSession(
                accountID: account.id,
                server: account.server,
                sessionID: sessionID,
                currentTime: currentTime,
                duration: duration
            )
        } catch let error {
            throw .playbackSync(error)
        }
    }

    func removeAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        do {
            try await libraryCache.removeAccount(account.id)
        } catch let error {
            throw .libraryCache(error)
        }

        do {
            _ = try await coordinator.removePersistedAccount(
                accountID: account.id,
                accountStore: accountStore
            )
        } catch let error {
            throw .accountRemoval(error)
        }
    }

    private func repository(
        for account: ServerAccount
    ) -> LibraryRepository<
        AudiobookshelfAPI<URLSessionHTTPTransport, TokenVault>
    > {
        let api = AudiobookshelfAPI(
            account: account,
            authCoordinator: coordinator
        )
        return LibraryRepository(
            accountID: account.id,
            userID: account.user.id,
            remote: api,
            cache: libraryCache
        )
    }
}
