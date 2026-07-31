import BleatCore
import Foundation
import SwiftData

enum AppBootstrapError: Error, Equatable, Sendable {
    case persistenceUnavailable
}

enum BleatCloudKitBuildMode: String, Sendable {
    case enabled
    case disabled

    static var current: Self {
        guard
            let value = Bundle.main.object(
                forInfoDictionaryKey: "BleatCloudKitMode"
            ) as? String
        else {
            return .disabled
        }
        return Self(rawValue: value) ?? .disabled
    }
}

enum AppServiceError: Error, Equatable, Sendable {
    case invalidServerURL(ServerURLValidationError)
    case passwordRequiredForCredentialChange
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

enum LocalServerValidationPolicy: Equatable, Sendable {
    case required
    case allowUnvalidated
}

enum LocalServerValidationDecision: Equatable, Sendable {
    case skip
    case validate

    static func decide(
        account: ServerAccount,
        primary: NormalizedServerURL,
        local: NormalizedServerURL?,
        username: String
    ) -> Self {
        guard local != nil else {
            return .skip
        }
        let onlyPrimaryChanged =
            primary != account.server
            && local == account.localServer
            && username == account.user.username
        if local != account.localServer
            || (!account.localServerValidated && !onlyPrimaryChanged)
        {
            return .validate
        }
        return .skip
    }
}

enum AccountUpdateServiceOutcome: Equatable, Sendable {
    case updated(ServerAccount)
    case localServerValidationFailed(AppServiceError)
}

struct AppEndpointDescription: Equatable, Sendable {
    let usage: ServerEndpointUsage
    let host: String
    let port: Int?

    init(
        usage: ServerEndpointUsage,
        server: NormalizedServerURL
    ) {
        self.usage = usage
        host = server.url.host ?? "Unknown"
        port = server.url.port
    }

    var diagnosticsLabel: String {
        let role = usage == .local ? "Local" : "Primary"
        guard let port else {
            return "\(role) — \(host)"
        }
        return "\(role) — \(host):\(port)"
    }
}

struct AppEndpointDiagnostics: Equatable, Sendable {
    let authentication: AppEndpointDescription?
    let api: AppEndpointDescription?
    let webSocket: AppEndpointDescription
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

    func endpointDiagnostics(
        for account: ServerAccount
    ) async -> AppEndpointDiagnostics

    func accounts()
        async throws(AppServiceError) -> [ServerAccount]

    func activeAccount()
        async throws(AppServiceError) -> ServerAccount?

    func activateAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError)

    func updateAccount(
        _ account: ServerAccount,
        serverAddress: String,
        localServerAddress: String,
        username: String,
        password: String,
        localServerValidation: LocalServerValidationPolicy
    ) async throws(AppServiceError) -> AccountUpdateServiceOutcome

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

    func isPrivateCloudSyncAvailable() async -> Bool

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
    func endpointDiagnostics(
        for account: ServerAccount
    ) async -> AppEndpointDiagnostics {
        AppEndpointDiagnostics(
            authentication: nil,
            api: nil,
            webSocket: AppEndpointDescription(
                usage: .primary,
                server: account.server
            )
        )
    }

    func updateAccount(
        _ account: ServerAccount,
        serverAddress: String,
        localServerAddress: String,
        username: String,
        password: String,
        localServerValidation: LocalServerValidationPolicy
    ) async throws(AppServiceError) -> AccountUpdateServiceOutcome {
        .updated(account)
    }

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

    func isPrivateCloudSyncAvailable() async -> Bool {
        true
    }

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
    private let directTransport: URLSessionHTTPTransport
    private let endpointRouter: ServerEndpointRouter
    private let credentialStore: TokenVault
    private let coordinator: Coordinator
    private let authenticationCoordinator: Coordinator
    private let accountStore: AccountStore
    private let libraryCache: LibraryCache
    private let statisticsRepository: StatisticsRepository
    private let privateCloudSync: PrivateCloudSyncCoordinator?
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

        let endpointRouter = ServerEndpointRouter()
        self.endpointRouter = endpointRouter
        directTransport = URLSessionHTTPTransport(diagnostics: diagnostics)
        transport = URLSessionHTTPTransport(
            diagnostics: diagnostics,
            endpointRouter: endpointRouter
        )
        let privateCloudAvailable =
            BleatCloudKitBuildMode.current == .enabled
        let privateCloudEnabled =
            privateCloudAvailable
            && (UserDefaults.standard.object(
                forKey: "bleat.cloudKit.enabled.v1"
            ) == nil
                || UserDefaults.standard.bool(
                    forKey: "bleat.cloudKit.enabled.v1"
                ))
        credentialStore = TokenVault(
            tokenService: "com.terminaloutcomes.Bleat.session-tokens",
            nativeLoginService: "com.terminaloutcomes.Bleat.native-login",
            legacyService: "com.terminaloutcomes.Bleat.credentials",
            synchronizesNativeLogin: privateCloudEnabled
        )
        coordinator = Coordinator(
            transport: transport,
            credentialStore: credentialStore
        )
        authenticationCoordinator = Coordinator(
            transport: directTransport,
            credentialStore: credentialStore
        )
        accountStore = AccountStore(modelContainer: modelContainer)
        libraryCache = LibraryCache(modelContainer: modelContainer)
        statisticsRepository = StatisticsRepository(
            modelContainer: modelContainer
        )
        if privateCloudAvailable {
            privateCloudSync = PrivateCloudSyncCoordinator(
                statistics: statisticsRepository,
                accounts: accountStore,
                credentialStore: credentialStore
            )
        } else {
            privateCloudSync = nil
        }
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

    func endpointDiagnostics(
        for account: ServerAccount
    ) async -> AppEndpointDiagnostics {
        let authenticationUsage =
            await endpointRouter.lastAuthenticationUse(for: account.server)
        let apiUsage =
            await endpointRouter.lastSuccessfulUse(for: account.server)
        return AppEndpointDiagnostics(
            authentication: authenticationUsage.map {
                endpointDescription(
                    usage: $0,
                    account: account
                )
            },
            api: apiUsage.map {
                endpointDescription(
                    usage: $0,
                    account: account
                )
            },
            webSocket: AppEndpointDescription(
                usage: .primary,
                server: account.server
            )
        )
    }

    func accounts()
        async throws(AppServiceError) -> [ServerAccount]
    {
        do {
            let accounts = try await accountStore.accounts()
            for account in accounts {
                await endpointRouter.configure(
                    primary: account.server,
                    local:
                        account.localServerValidated
                        ? account.localServer
                        : nil
                )
            }
            return accounts
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

    func updateAccount(
        _ account: ServerAccount,
        serverAddress: String,
        localServerAddress: String,
        username: String,
        password: String,
        localServerValidation: LocalServerValidationPolicy
    ) async throws(AppServiceError) -> AccountUpdateServiceOutcome {
        let primary: NormalizedServerURL
        let requestedLocal: NormalizedServerURL?
        do {
            primary = try NormalizedServerURL(serverAddress)
            if localServerAddress.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                requestedLocal = nil
            } else {
                requestedLocal = try NormalizedServerURL(localServerAddress)
            }
        } catch let error {
            throw .invalidServerURL(error)
        }
        let local = requestedLocal == primary ? nil : requestedLocal
        guard !password.isEmpty || username == account.user.username else {
            throw .passwordRequiredForCredentialChange
        }
        let localValidationDecision = LocalServerValidationDecision.decide(
            account: account,
            primary: primary,
            local: local,
            username: username
        )
        let discoveredPrimary = try await discoverDirect(primary)
        guard discoveredPrimary.authenticationMethods.contains(.local) else {
            throw .onboarding(.localAuthenticationUnavailable)
        }

        var localWasValidated = false
        if let local,
            localValidationDecision == .validate,
            localServerValidation == .required
        {
            guard !password.isEmpty else {
                return .localServerValidationFailed(
                    .passwordRequiredForCredentialChange
                )
            }
            do {
                let discoveredLocal = try await discoverDirect(local)
                guard discoveredLocal.authenticationMethods.contains(.local)
                else {
                    throw AccountOnboardingError.localAuthenticationUnavailable
                }
                _ = try await authenticationCoordinator.validateLocalLogin(
                    accountID: account.id,
                    server: local,
                    username: username,
                    password: password,
                    expectedUserID: account.user.id
                )
                localWasValidated = true
            } catch let error as AccountOnboardingError {
                return .localServerValidationFailed(.onboarding(error))
            } catch let error as LocalAuthenticationError {
                return .localServerValidationFailed(
                    .onboarding(.authenticationFailed(error))
                )
            } catch let error as AppServiceError {
                return .localServerValidationFailed(error)
            } catch {
                return .localServerValidationFailed(
                    .onboarding(.authenticationRequestFailed)
                )
            }
        }
        let localValidated =
            local != nil
            && (localWasValidated
                || (localValidationDecision == .skip
                    && account.localServerValidated))

        let persisted: ServerAccount
        do {
            if password.isEmpty {
                let authenticated = try await authenticationCoordinator
                    .validateStoredAuthentication(
                        accountID: account.id,
                        server: primary,
                        expectedUserID: account.user.id
                    )
                persisted = try ServerAccount(
                    id: account.id,
                    server: primary,
                    serverVersion: discoveredPrimary.version.original,
                    authenticationMethods:
                        discoveredPrimary.authenticationMethods,
                    user: authenticated.user,
                    connectionState: account.connectionState
                )
                try await accountStore.save(persisted)
            } else {
                persisted = try await authenticationCoordinator
                    .loginAndPersistAccount(
                        accountID: account.id,
                        discoveredServer: discoveredPrimary,
                        username: username,
                        password: password,
                        expectedUserID: account.user.id,
                        accountStore: accountStore,
                        makeActive: false
                    )
            }
            try await accountStore.setLocalServer(
                local,
                validated: localValidated,
                for: account.id
            )
            let updated = try persisted.updatingLocalServer(
                local,
                validated: localValidated
            )
            await endpointRouter.configure(
                primary: account.server,
                local: nil
            )
            await endpointRouter.configure(
                primary: updated.server,
                local:
                    updated.localServerValidated
                    ? updated.localServer
                    : nil
            )
            await endpointRouter.recordAuthenticationUse(
                primary: updated.server,
                usage: .primary
            )
            return .updated(updated)
        } catch let error as AccountOnboardingError {
            throw .onboarding(error)
        } catch let error as ServerAccountValidationError {
            throw .onboarding(.invalidAccount(error))
        } catch let error as AccountStoreError {
            throw .accountStore(error)
        } catch {
            throw .accountStore(.profileEncodingFailed)
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

        let discoveredServer = try await discoverDirect(server)

        do {
            let account =
                try await authenticationCoordinator.loginAndPersistAccount(
                accountID: AccountID(
                    rawValue: UUID().uuidString.lowercased()
                ),
                discoveredServer: discoveredServer,
                username: username,
                password: password,
                accountStore: accountStore
            )
            await endpointRouter.recordAuthenticationUse(
                primary: account.server,
                usage: .primary
            )
            return account
        } catch let error {
            throw .onboarding(error)
        }
    }

    func reauthenticate(
        _ account: ServerAccount,
        password: String
    ) async throws(AppServiceError) -> ServerAccount {
        let discoveredServer = try await discoverDirect(account.server)
        do {
            let authenticated =
                try await authenticationCoordinator.loginAndPersistAccount(
                accountID: account.id,
                discoveredServer: discoveredServer,
                username: account.user.username,
                password: password,
                expectedUserID: account.user.id,
                accountStore: accountStore,
                makeActive: false
            )
            await endpointRouter.recordAuthenticationUse(
                primary: authenticated.server,
                usage: .primary
            )
            return authenticated
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
                var appTracks: [AppPlaybackTrack] = []
                appTracks.reserveCapacity(tracks.count)
                for track in tracks {
                    appTracks.append(AppPlaybackTrack(
                        url: await endpointRouter.preferredURL(for: track.url),
                        startOffset: track.track.startOffset,
                        duration: track.track.duration,
                        title: track.track.title
                    ))
                }
                source = .direct(appTracks)
            case .hls(let url):
                source = .hls(await endpointRouter.preferredURL(for: url))
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
            let request = try await coordinator.makeAuthorizedDownloadRequest(
                identity: identity,
                server: account.server
            )
            guard let url = request.url else {
                return request
            }
            var updated = request
            updated.url = await endpointRouter.preferredURL(for: url)
            return updated
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
            let request = try await coordinator.makeReplacementDownloadRequest(
                identity: identity,
                server: account.server,
                rejectedRequest: rejectedRequest
            )
            guard let url = request.url else {
                return request
            }
            var updated = request
            updated.url = await endpointRouter.preferredURL(for: url)
            return updated
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
        await privateCloudSync?.ignoreAccountOnThisDevice(
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

    func isPrivateCloudSyncAvailable() async -> Bool {
        privateCloudSync != nil
    }

    func isPrivateCloudSyncEnabled() async -> Bool {
        privateCloudSync?.isEnabled ?? false
    }

    func synchronizePrivateCloud() async throws(AppServiceError) {
        guard let privateCloudSync else {
            throw .privateCloud(.disabled)
        }
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
        guard let privateCloudSync else {
            throw .privateCloud(.disabled)
        }
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
        guard let privateCloudSync else {
            throw .privateCloud(.disabled)
        }
        do {
            try await privateCloudSync.deleteAccountEverywhere(
                accountID,
                includeStatistics: includeStatistics
            )
        } catch let error {
            throw .privateCloud(error)
        }
    }

    private func endpointDescription(
        usage: ServerEndpointUsage,
        account: ServerAccount
    ) -> AppEndpointDescription {
        switch usage {
        case .primary:
            AppEndpointDescription(
                usage: .primary,
                server: account.server
            )
        case .local:
            AppEndpointDescription(
                usage: .local,
                server: account.localServer ?? account.server
            )
        }
    }

    private func discoverDirect(
        _ server: NormalizedServerURL
    ) async throws(AppServiceError) -> DiscoveredServer {
        do {
            return try await ServerDiscoveryClient(
                transport: directTransport
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
