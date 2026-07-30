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
    case homeRequest(LibraryHomeRequestError)
    case searchRequest(LibrarySearchRequestError)
    case searchCoordinator(LibrarySearchCoordinatorError)
    case bookDetail(LibraryRepositoryError)
    case playbackSession(PlaybackSessionError)
    case playbackSource(PlaybackSourceError)
    case playbackSync(PlaybackSyncError)
    case localPlaybackSession(LocalPlaybackSessionError)
    case metadataPatch(BookMetadataPatchError)
    case metadataUpdate(BookMetadataUpdateError)
    case coverUpdate(BookCoverUploadError)
    case bookDeletion(BookDeletionError)
    case bookmark(BookmarkError)
    case progress(BookProgressError)
    case downloadPlan(DownloadPlanRequestError)
    case downloadAuthorization(DownloadAuthorizationError)
    case accountRemoval(AccountLifecycleError)
    case libraryCache(LibraryCacheError)
    case statistics(StatisticsRepositoryError)
    case privateCloud(PrivateCloudSyncError)
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
    let sessionID: PlaybackSessionID?
    let itemID: LibraryItemID
    let title: String
    let duration: Double
    let currentTime: Double
    let chapters: [PlaybackChapter]
    let source: AppPlaybackSource
}

enum AppMetadataSaveOutcome: Equatable, Sendable {
    case saved(LibraryBookDetail)
    case stale(LibraryBookDetail)
}

enum AppBookDeletionOutcome: Equatable, Sendable {
    case deleted
    case deletedWithCacheCleanupFailure
}

protocol AppServicing: Sendable {
    func liveUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AudiobookshelfLiveUpdate>

    func accounts()
        async throws(AppServiceError) -> [ServerAccount]

    func activeAccount()
        async throws(AppServiceError) -> ServerAccount?

    func activateAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError)

    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async throws(AppServiceError) -> ServerAccount

    func reauthenticate(
        _ account: ServerAccount,
        password: String
    ) async throws(AppServiceError) -> ServerAccount

    func libraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary]

    func page(
        for account: ServerAccount,
        libraryID: LibraryID,
        page: Int,
        sort: LibraryItemSort,
        descending: Bool,
        filter: LibraryItemFilter?
    ) async throws(AppServiceError) -> LibraryItemsPage

    func homeShelves(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> [LibraryBookShelf]

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
        preference: PlaybackPreference,
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

    func syncPlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID,
        currentTime: Double,
        duration: Double,
        timeListened: Double
    ) async throws(AppServiceError)

    func syncLocalPlaybackSessions(
        for account: ServerAccount,
        sessions: [LocalPlaybackSession],
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> [LocalPlaybackSessionSyncResult]

    func saveMetadata(
        for account: ServerAccount,
        baseline: LibraryBookDetail,
        draft: BookMetadataDraft,
        overwrite: Bool
    ) async throws(AppServiceError) -> AppMetadataSaveOutcome

    func downloadPlan(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> DownloadPlan

    func authorizedDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity
    ) async throws(AppServiceError) -> URLRequest

    func replacementDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity,
        rejectedRequest: URLRequest
    ) async throws(AppServiceError) -> URLRequest

    func replaceCover(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        jpegData: Data
    ) async throws(AppServiceError) -> LibraryBookDetail

    func deleteBook(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        mode: BookDeletionMode
    ) async throws(AppServiceError) -> AppBookDeletionOutcome

    func bookmarks(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [AudioBookmark]

    func createBookmark(
        for account: ServerAccount,
        itemID: LibraryItemID,
        time: Double,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark

    func renameBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark

    func deleteBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark
    ) async throws(AppServiceError)

    func bookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookProgress?

    func updateBookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID,
        update: BookProgressUpdate
    ) async throws(AppServiceError)

    func removeAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError)

    func removeAccountFromThisDevice(
        _ account: ServerAccount,
        includeStatistics: Bool
    ) async throws(AppServiceError)

    func removeStatistics(
        accountID: AccountID
    ) async throws(AppServiceError)

    func recordStatisticsSample(
        _ sample: StatisticsPlaybackSample
    ) async throws(AppServiceError)

    func finishStatisticsSession(
        _ sessionID: PlaybackSessionID
    ) async throws(AppServiceError)

    func statisticsSummary(
        query: StatisticsQuery
    ) async throws(AppServiceError) -> StatisticsSummary

    func recordCompletion(
        _ milestone: CompletionMilestone
    ) async throws(AppServiceError)

    func pendingStatisticsRealSeconds(
        accountID: AccountID,
        sessionID: PlaybackSessionID
    ) async throws(AppServiceError) -> Double

    func confirmStatisticsSync(
        accountID: AccountID,
        sessionID: PlaybackSessionID,
        realSeconds: Double
    ) async throws(AppServiceError)

    func markStatisticsSyncUncertain(
        accountID: AccountID,
        sessionID: PlaybackSessionID,
        realSeconds: Double
    ) async throws(AppServiceError)

    func isPrivateCloudSyncEnabled() async -> Bool

    func synchronizePrivateCloud() async throws(AppServiceError)

    func setPrivateCloudSyncEnabled(
        _ enabled: Bool,
        deleteCloudData: Bool
    ) async throws(AppServiceError)

    func deletePrivateCloudAccount(
        _ accountID: AccountID,
        includeStatistics: Bool
    ) async throws(AppServiceError)
}

extension AppServicing {
    func liveUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AudiobookshelfLiveUpdate> {
        AsyncStream { $0.finish() }
    }

    func removeAccountFromThisDevice(
        _ account: ServerAccount,
        includeStatistics: Bool
    ) async throws(AppServiceError) {
        try await removeAccount(account)
    }

    func removeStatistics(
        accountID: AccountID
    ) async throws(AppServiceError) {}

    func recordStatisticsSample(
        _ sample: StatisticsPlaybackSample
    ) async throws(AppServiceError) {}

    func finishStatisticsSession(
        _ sessionID: PlaybackSessionID
    ) async throws(AppServiceError) {}

    func statisticsSummary(
        query: StatisticsQuery
    ) async throws(AppServiceError) -> StatisticsSummary {
        .empty
    }

    func recordCompletion(
        _ milestone: CompletionMilestone
    ) async throws(AppServiceError) {}

    func syncPlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID,
        currentTime: Double,
        duration: Double,
        timeListened: Double
    ) async throws(AppServiceError) {
        try await syncPlayback(
            for: account,
            sessionID: sessionID,
            currentTime: currentTime,
            duration: duration
        )
    }

    func pendingStatisticsRealSeconds(
        accountID: AccountID,
        sessionID: PlaybackSessionID
    ) async throws(AppServiceError) -> Double {
        0
    }

    func confirmStatisticsSync(
        accountID: AccountID,
        sessionID: PlaybackSessionID,
        realSeconds: Double
    ) async throws(AppServiceError) {}

    func markStatisticsSyncUncertain(
        accountID: AccountID,
        sessionID: PlaybackSessionID,
        realSeconds: Double
    ) async throws(AppServiceError) {}

    func isPrivateCloudSyncEnabled() async -> Bool {
        true
    }

    func synchronizePrivateCloud() async throws(AppServiceError) {}

    func setPrivateCloudSyncEnabled(
        _ enabled: Bool,
        deleteCloudData: Bool
    ) async throws(AppServiceError) {}

    func deletePrivateCloudAccount(
        _ accountID: AccountID,
        includeStatistics: Bool
    ) async throws(AppServiceError) {}
}

actor LiveAppService: AppServicing {
    private typealias Coordinator = AuthCoordinator<
        URLSessionHTTPTransport,
        TokenVault
    >

    private let modelContainer: ModelContainer
    private let transport: URLSessionHTTPTransport
    private let credentialStore: TokenVault
    private let coordinator: Coordinator
    private let accountStore: AccountStore
    private let libraryCache: LibraryCache
    private let statisticsRepository: StatisticsRepository
    private let privateCloudSync: PrivateCloudSyncCoordinator
    private let searchCoordinator = LibrarySearchCoordinator()

    init(
        diagnostics: any DiagnosticRecording =
            SystemDiagnosticRecorder.shared
    ) throws(AppBootstrapError) {
        let schema = Schema([
            ServerAccountRecord.self,
            CachedLibraryCollectionRecord.self,
            CachedLibraryRecord.self,
            CachedLibraryPageRecord.self,
            CachedLibrarySearchRecord.self,
            CachedLibraryHomeRecord.self,
            CachedLibraryBookDetailRecord.self,
            ListeningSliceRecord.self,
            CompletionMilestoneRecord.self,
            RemoteListeningSessionRecord.self,
            StatisticsSessionAccountingRecord.self,
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

        transport = URLSessionHTTPTransport(diagnostics: diagnostics)
        let privateCloudEnabled =
            UserDefaults.standard.object(
                forKey: "bleat.cloudKit.enabled.v1"
            ) == nil
            || UserDefaults.standard.bool(
                forKey: "bleat.cloudKit.enabled.v1"
            )
        credentialStore = TokenVault(
            tokenService: "com.yaleman.Bleat.session-tokens",
            nativeLoginService: "com.yaleman.Bleat.native-login",
            legacyService: "com.yaleman.Bleat.credentials",
            synchronizesNativeLogin: privateCloudEnabled
        )
        coordinator = Coordinator(
            transport: transport,
            credentialStore: credentialStore
        )
        accountStore = AccountStore(modelContainer: modelContainer)
        libraryCache = LibraryCache(modelContainer: modelContainer)
        statisticsRepository = StatisticsRepository(
            modelContainer: modelContainer
        )
        privateCloudSync = PrivateCloudSyncCoordinator(
            statistics: statisticsRepository,
            accounts: accountStore,
            credentialStore: credentialStore
        )
    }

    func liveUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AudiobookshelfLiveUpdate> {
        let coordinator = coordinator
        let client = AudiobookshelfLiveEventClient(
            server: account.server,
            tokenProvider: {
                try await coordinator.accessToken(for: account.id)
            },
            tokenRecovery: { rejectedToken in
                try await coordinator.recoverAccessToken(
                    for: account.id,
                    server: account.server,
                    rejectedAccessToken: rejectedToken
                )
            }
        )
        return await client.updates()
    }

    func accounts()
        async throws(AppServiceError) -> [ServerAccount]
    {
        do {
            return try await accountStore.accounts()
        } catch let error {
            throw .accountStore(error)
        }
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

    func activateAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        do {
            try await accountStore.setActiveAccount(id: account.id)
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

        let discoveredServer = try await discover(server)

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

    func reauthenticate(
        _ account: ServerAccount,
        password: String
    ) async throws(AppServiceError) -> ServerAccount {
        let discoveredServer = try await discover(account.server)
        do {
            return try await coordinator.loginAndPersistAccount(
                accountID: account.id,
                discoveredServer: discoveredServer,
                username: account.user.username,
                password: password,
                accountStore: accountStore,
                makeActive: false
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

    func page(
        for account: ServerAccount,
        libraryID: LibraryID,
        page: Int,
        sort: LibraryItemSort,
        descending: Bool,
        filter: LibraryItemFilter?
    ) async throws(AppServiceError) -> LibraryItemsPage {
        let request: LibraryItemsPageRequest
        do {
            request = try LibraryItemsPageRequest(
                page: page,
                sort: sort,
                descending: descending,
                filter: filter
            )
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

    func homeShelves(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> [LibraryBookShelf] {
        let request: LibraryHomeRequest
        do {
            request = try LibraryHomeRequest()
        } catch let error {
            throw .homeRequest(error)
        }
        let repository = repository(for: account)
        do {
            return try await repository.personalizedShelves(
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
        preference: PlaybackPreference,
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> AppPlaybackPreparation {
        let session: PlaybackSession
        do {
            session = try await coordinator.openPlaybackSession(
                accountID: account.id,
                server: account.server,
                itemID: itemID,
                preference: preference,
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

    func syncPlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID,
        currentTime: Double,
        duration: Double,
        timeListened: Double
    ) async throws(AppServiceError) {
        do {
            try await coordinator.syncPlaybackSession(
                accountID: account.id,
                server: account.server,
                sessionID: sessionID,
                currentTime: currentTime,
                duration: duration,
                timeListened: timeListened
            )
        } catch let error {
            throw .playbackSync(error)
        }
    }

    func syncLocalPlaybackSessions(
        for account: ServerAccount,
        sessions: [LocalPlaybackSession],
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> [LocalPlaybackSessionSyncResult] {
        do {
            return try await coordinator.syncLocalPlaybackSessions(
                accountID: account.id,
                server: account.server,
                sessions: sessions,
                deviceInfo: deviceInfo
            )
        } catch let error {
            throw .localPlaybackSession(error)
        }
    }

    func saveMetadata(
        for account: ServerAccount,
        baseline: LibraryBookDetail,
        draft: BookMetadataDraft,
        overwrite: Bool
    ) async throws(AppServiceError) -> AppMetadataSaveOutcome {
        let patch: BookMetadataPatch
        do {
            patch = try BookMetadataPatch(
                baseline: baseline,
                draft: draft
            )
        } catch let error {
            throw .metadataPatch(error)
        }
        if patch.isEmpty {
            return .saved(baseline)
        }

        let repository = repository(for: account)
        let latest: LibraryBookDetail
        do {
            latest = try await repository.bookDetail(
                for: baseline.id,
                in: baseline.libraryID,
                policy: .remoteOnly
            ).value
        } catch let error {
            throw .bookDetail(error)
        }
        if patch.isStale(comparedTo: latest), !overwrite {
            return .stale(latest)
        }

        do {
            try await coordinator.updateBookMetadata(
                accountID: account.id,
                server: account.server,
                itemID: baseline.id,
                patch: patch
            )
        } catch let error {
            throw .metadataUpdate(error)
        }

        do {
            return .saved(
                try await repository.bookDetail(
                    for: baseline.id,
                    in: baseline.libraryID,
                    policy: .remoteOnly
                ).value
            )
        } catch let error {
            throw .bookDetail(error)
        }
    }

    func downloadPlan(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> DownloadPlan {
        do {
            return try await coordinator.downloadPlan(
                accountID: account.id,
                server: account.server,
                itemID: itemID
            )
        } catch let error {
            throw .downloadPlan(error)
        }
    }

    func authorizedDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity
    ) async throws(AppServiceError) -> URLRequest {
        do {
            return try await coordinator.makeAuthorizedDownloadRequest(
                identity: identity,
                server: account.server
            )
        } catch let error as DownloadAuthorizationError {
            throw .downloadAuthorization(error)
        } catch {
            throw .downloadAuthorization(
                .authenticatedRequest(.requestTransportFailed)
            )
        }
    }

    func replacementDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity,
        rejectedRequest: URLRequest
    ) async throws(AppServiceError) -> URLRequest {
        do {
            return try await coordinator.makeReplacementDownloadRequest(
                identity: identity,
                server: account.server,
                rejectedRequest: rejectedRequest
            )
        } catch let error as DownloadAuthorizationError {
            throw .downloadAuthorization(error)
        } catch {
            throw .downloadAuthorization(
                .authenticatedRequest(.requestTransportFailed)
            )
        }
    }

    func replaceCover(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        jpegData: Data
    ) async throws(AppServiceError) -> LibraryBookDetail {
        do {
            try await coordinator.updateBookCover(
                accountID: account.id,
                server: account.server,
                itemID: detail.id,
                jpegData: jpegData
            )
        } catch let error {
            throw .coverUpdate(error)
        }
        do {
            return try await repository(for: account).bookDetail(
                for: detail.id,
                in: detail.libraryID,
                policy: .remoteOnly
            ).value
        } catch let error {
            throw .bookDetail(error)
        }
    }

    func deleteBook(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        mode: BookDeletionMode
    ) async throws(AppServiceError) -> AppBookDeletionOutcome {
        do {
            try await coordinator.deleteBook(
                accountID: account.id,
                server: account.server,
                itemID: detail.id,
                mode: mode
            )
        } catch let error {
            throw .bookDeletion(error)
        }

        do {
            try await libraryCache.invalidateLibrary(
                detail.libraryID,
                for: account.id
            )
            return .deleted
        } catch {
            return .deletedWithCacheCleanupFailure
        }
    }

    func bookmarks(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [AudioBookmark] {
        do {
            return try await coordinator.bookmarks(
                accountID: account.id,
                server: account.server,
                itemID: itemID
            )
        } catch let error {
            throw .bookmark(error)
        }
    }

    func createBookmark(
        for account: ServerAccount,
        itemID: LibraryItemID,
        time: Double,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark {
        do {
            return try await coordinator.mutateBookmark(
                accountID: account.id,
                server: account.server,
                itemID: itemID,
                time: time,
                title: title,
                mutation: .create
            )
        } catch let error {
            throw .bookmark(error)
        }
    }

    func renameBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark {
        do {
            return try await coordinator.mutateBookmark(
                accountID: account.id,
                server: account.server,
                itemID: bookmark.libraryItemID,
                time: bookmark.time,
                title: title,
                mutation: .rename
            )
        } catch let error {
            throw .bookmark(error)
        }
    }

    func deleteBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark
    ) async throws(AppServiceError) {
        do {
            try await coordinator.deleteBookmark(
                accountID: account.id,
                server: account.server,
                itemID: bookmark.libraryItemID,
                time: bookmark.time
            )
        } catch let error {
            throw .bookmark(error)
        }
    }

    func bookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookProgress? {
        do {
            return try await coordinator.bookProgress(
                accountID: account.id,
                server: account.server,
                itemID: itemID
            )
        } catch let error {
            throw .progress(error)
        }
    }

    func updateBookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID,
        update: BookProgressUpdate
    ) async throws(AppServiceError) {
        do {
            try await coordinator.updateBookProgress(
                accountID: account.id,
                server: account.server,
                itemID: itemID,
                update: update
            )
        } catch let error {
            throw .progress(error)
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

    func removeAccountFromThisDevice(
        _ account: ServerAccount,
        includeStatistics: Bool
    ) async throws(AppServiceError) {
        do {
            try await libraryCache.removeAccount(account.id)
        } catch let error {
            throw .libraryCache(error)
        }
        await privateCloudSync.ignoreAccountOnThisDevice(
            account.id,
            includeStatistics: includeStatistics
        )
        do {
            _ = try await coordinator.removePersistedAccountFromDevice(
                accountID: account.id,
                accountStore: accountStore
            )
        } catch let error {
            throw .accountRemoval(error)
        }
    }

    func removeStatistics(
        accountID: AccountID
    ) async throws(AppServiceError) {
        do {
            try await statisticsRepository.reset(
                query: StatisticsQuery(accountID: accountID)
            )
        } catch let error {
            throw .statistics(error)
        }
    }

    func recordStatisticsSample(
        _ sample: StatisticsPlaybackSample
    ) async throws(AppServiceError) {
        do {
            try await statisticsRepository.record(sample)
        } catch let error {
            throw .statistics(error)
        }
    }

    func finishStatisticsSession(
        _ sessionID: PlaybackSessionID
    ) async throws(AppServiceError) {
        do {
            try await statisticsRepository.finish(sessionID: sessionID)
        } catch let error {
            throw .statistics(error)
        }
    }

    func statisticsSummary(
        query: StatisticsQuery
    ) async throws(AppServiceError) -> StatisticsSummary {
        do {
            return try await statisticsRepository.summary(query: query)
        } catch let error {
            throw .statistics(error)
        }
    }

    func recordCompletion(
        _ milestone: CompletionMilestone
    ) async throws(AppServiceError) {
        do {
            try await statisticsRepository.recordCompletion(milestone)
        } catch let error {
            throw .statistics(error)
        }
    }

    func pendingStatisticsRealSeconds(
        accountID: AccountID,
        sessionID: PlaybackSessionID
    ) async throws(AppServiceError) -> Double {
        do {
            return try await statisticsRepository.pendingRealSeconds(
                accountID: accountID,
                sessionID: sessionID
            )
        } catch let error {
            throw .statistics(error)
        }
    }

    func confirmStatisticsSync(
        accountID: AccountID,
        sessionID: PlaybackSessionID,
        realSeconds: Double
    ) async throws(AppServiceError) {
        do {
            try await statisticsRepository.confirmSync(
                accountID: accountID,
                sessionID: sessionID,
                realSeconds: realSeconds
            )
        } catch let error {
            throw .statistics(error)
        }
    }

    func markStatisticsSyncUncertain(
        accountID: AccountID,
        sessionID: PlaybackSessionID,
        realSeconds: Double
    ) async throws(AppServiceError) {
        do {
            try await statisticsRepository.markSyncUncertain(
                accountID: accountID,
                sessionID: sessionID,
                realSeconds: realSeconds
            )
        } catch let error {
            throw .statistics(error)
        }
    }

    func isPrivateCloudSyncEnabled() async -> Bool {
        privateCloudSync.isEnabled
    }

    func synchronizePrivateCloud() async throws(AppServiceError) {
        do {
            try await privateCloudSync.synchronize()
        } catch let error {
            throw .privateCloud(error)
        }
    }

    func setPrivateCloudSyncEnabled(
        _ enabled: Bool,
        deleteCloudData: Bool
    ) async throws(AppServiceError) {
        let accountIDs: [AccountID]
        do {
            accountIDs = try await accountStore.accounts().map(\.id)
        } catch let error {
            throw .accountStore(error)
        }
        do {
            try await credentialStore.setSynchronizesNativeLogin(
                enabled,
                accountIDs: accountIDs
            )
            do {
                try await privateCloudSync.setEnabled(
                    enabled,
                    deleteCloudData: deleteCloudData
                )
            } catch {
                try? await credentialStore.setSynchronizesNativeLogin(
                    !enabled,
                    accountIDs: accountIDs
                )
                throw error
            }
        } catch let error as PrivateCloudSyncError {
            throw .privateCloud(error)
        } catch {
            throw .privateCloud(.persistenceFailed)
        }
    }

    func deletePrivateCloudAccount(
        _ accountID: AccountID,
        includeStatistics: Bool
    ) async throws(AppServiceError) {
        do {
            try await privateCloudSync.deleteAccountEverywhere(
                accountID,
                includeStatistics: includeStatistics
            )
        } catch let error {
            throw .privateCloud(error)
        }
    }

    private func discover(
        _ server: NormalizedServerURL
    ) async throws(AppServiceError) -> DiscoveredServer {
        do {
            return try await ServerDiscoveryClient(
                transport: transport
            ).discover(server)
        } catch let error as ServerDiscoveryError {
            throw .discovery(error)
        } catch {
            throw .discoveryRequestFailed
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
