import BleatCore
import Foundation
import Security
import SwiftData

enum AppBootstrapError: Error, Equatable, Sendable {
    case persistenceUnavailable
}

enum BleatLocalStore {
    private static let directoryName = "Bleat"
    private static let storeFilename = "Bleat.store"
    private static let legacyStoreFilename = "default.store"

    static func storeURL(
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let supportURL: URL
        if let applicationSupportURL {
            supportURL = applicationSupportURL
        } else if let resolvedURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            supportURL = resolvedURL
        } else {
            throw AppBootstrapError.persistenceUnavailable
        }

        let directoryURL = supportURL.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let storeURL = directoryURL.appendingPathComponent(storeFilename)
        try migrateLegacyStoreIfNeeded(
            fileManager: fileManager,
            legacyStoreURL: supportURL.appendingPathComponent(
                legacyStoreFilename
            ),
            storeURL: storeURL
        )
        return storeURL
    }

    private static func migrateLegacyStoreIfNeeded(
        fileManager: FileManager,
        legacyStoreURL: URL,
        storeURL: URL
    ) throws {
        guard !fileManager.fileExists(atPath: storeURL.path),
            fileManager.fileExists(atPath: legacyStoreURL.path)
        else {
            return
        }

        let legacyStoreSidecars = ["-wal", "-shm"].map {
            URL(fileURLWithPath: legacyStoreURL.path + $0)
        }
        let legacyURLs = ([legacyStoreURL] + legacyStoreSidecars).filter {
            fileManager.fileExists(atPath: $0.path)
        }
        var copiedURLs: [URL] = []
        do {
            for legacyURL in legacyURLs {
                let suffix = String(
                    legacyURL.path.dropFirst(
                        legacyStoreURL.path.count
                    ))
                let destinationURL = URL(
                    fileURLWithPath: storeURL.path + suffix
                )
                try fileManager.copyItem(
                    at: legacyURL,
                    to: destinationURL
                )
                copiedURLs.append(destinationURL)
            }
        } catch {
            for copiedURL in copiedURLs {
                try? fileManager.removeItem(at: copiedURL)
            }
            throw error
        }
    }
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

enum BleatCloudKitCapability {
    static var isAvailable: Bool {
        #if targetEnvironment(macCatalyst)
            isAvailable(
                buildMode: .current,
                containerIdentifiers: entitledContainerIdentifiers
            )
        #else
            BleatCloudKitBuildMode.current == .enabled
        #endif
    }

    static func isAvailable(
        buildMode: BleatCloudKitBuildMode,
        containerIdentifiers: [String]?
    ) -> Bool {
        buildMode == .enabled
            && containerIdentifiers?.contains(
                PrivateCloudSyncCoordinator.containerIdentifier
            ) == true
    }

    #if targetEnvironment(macCatalyst)
        private static var entitledContainerIdentifiers: [String]? {
            guard let task = SecTaskCreateFromSelf(nil) else {
                return nil
            }
            return SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
            ) as? [String]
        }
    #endif
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
    case transcriptCache(ChapterTranscriptCacheError)
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

    static func persistedValidation(
        account: ServerAccount,
        local: NormalizedServerURL?,
        validationSucceeded: Bool
    ) -> Bool {
        guard local != nil else {
            return false
        }
        return validationSucceeded
            || (local == account.localServer && account.localServerValidated)
    }
}

enum AccountUpdateServiceOutcome: Equatable, Sendable {
    case updated(ServerAccount)
    case localServerValidationFailed(AppServiceError)
}

typealias AccountSubmissionProgress =
    @Sendable (AccountSubmissionStage) async -> Void

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
    let lastConnection: AppEndpointActivityDescription?
    let authentication: AppEndpointDescription?
    let api: AppEndpointDescription?
    let webSocket: AppEndpointDescription
    let localServerState: AppLocalServerState
}

enum AppLocalServerState: Equatable, Sendable {
    case notConfigured
    case notYetValidated
    case probing
    case available
    case temporarilyUnavailable

    var diagnosticsLabel: String {
        switch self {
        case .notConfigured:
            "Not configured"
        case .notYetValidated:
            "Not yet validated"
        case .probing:
            "Validated — checking this network"
        case .available:
            "Validated — available"
        case .temporarilyUnavailable:
            "Validated — unavailable on this network"
        }
    }
}

struct AppEndpointActivityDescription: Equatable, Sendable {
    let purpose: ServerConnectionPurpose
    let endpoint: AppEndpointDescription

    var diagnosticsLabel: String {
        "\(purpose.diagnosticsLabel) — \(endpoint.diagnosticsLabel)"
    }
}

extension ServerConnectionPurpose {
    fileprivate var diagnosticsLabel: String {
        switch self {
        case .authentication:
            "Authentication"
        case .api:
            "API"
        case .webSocket:
            "WebSocket"
        case .cover:
            "Cover"
        case .playback:
            "Playback"
        case .download:
            "Download"
        }
    }
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
    func discoverServer(
        serverAddress: String
    ) async throws(AppServiceError) -> DiscoveredServer

    func liveUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AudiobookshelfLiveUpdate>

    func endpointDiagnostics(
        for account: ServerAccount
    ) async -> AppEndpointDiagnostics

    func endpointDiagnosticsUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AppEndpointDiagnostics>

    func serverEndpointRouter() async -> ServerEndpointRouter?

    func networkPathUpdates() async -> AsyncStream<AppNetworkPathState>

    func recordServerActivity(
        url: URL,
        purpose: ServerConnectionPurpose
    ) async

    func reportServerTransportFailure(url: URL) async -> Bool

    func primaryFallbackDownloadRequest(
        for failedRequest: URLRequest
    ) async -> URLRequest?

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
        localServerValidation: LocalServerValidationPolicy,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> AccountUpdateServiceOutcome

    func login(
        serverAddress: String,
        username: String,
        password: String,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount

    func loginWithOpenID(
        serverAddress: String,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount

    func reauthenticate(
        _ account: ServerAccount,
        password: String
    ) async throws(AppServiceError) -> ServerAccount

    func reauthenticateWithOpenID(
        _ account: ServerAccount,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount

    func libraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary]

    func page(
        for account: ServerAccount,
        libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) async throws(AppServiceError) -> LibraryItemsPage

    func homeShelves(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> [LibraryBookShelf]

    func refreshedLibraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary]

    func refreshedPage(
        for account: ServerAccount,
        libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) async throws(AppServiceError) -> LibraryItemsPage

    func refreshedHomeShelves(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> [LibraryBookShelf]

    func search(
        for account: ServerAccount,
        libraryID: LibraryID,
        query: String
    ) async throws(AppServiceError) -> LibrarySearchResults

    func bookDetail(
        for account: ServerAccount,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookDetail

    func cachedChapterTranscripts(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [CachedChapterTranscript]

    func saveCachedChapterTranscript(
        _ transcript: CachedChapterTranscript,
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError)

    func cachedChapterTranscriptionTaskState(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> CachedChapterTranscriptionTaskState?

    func saveCachedChapterTranscriptionTaskState(
        _ state: CachedChapterTranscriptionTaskState,
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError)

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
    func refreshedLibraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary] {
        try await libraries(for: account)
    }

    func refreshedPage(
        for account: ServerAccount,
        libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) async throws(AppServiceError) -> LibraryItemsPage {
        try await page(
            for: account,
            libraryID: libraryID,
            request: request
        )
    }

    func refreshedHomeShelves(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> [LibraryBookShelf] {
        try await homeShelves(for: account, libraryID: libraryID)
    }

    func loginWithOpenID(
        serverAddress: String,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        throw .onboarding(.openIDAuthenticationUnavailable)
    }

    func reauthenticateWithOpenID(
        _ account: ServerAccount,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        throw .onboarding(.openIDAuthenticationUnavailable)
    }

    func stopLiveUpdates(for accountID: AccountID) async {}

    func endpointDiagnostics(
        for account: ServerAccount
    ) async -> AppEndpointDiagnostics {
        AppEndpointDiagnostics(
            lastConnection: nil,
            authentication: nil,
            api: nil,
            webSocket: AppEndpointDescription(
                usage: .primary,
                server: account.server
            ),
            localServerState:
                account.localServer == nil
                ? .notConfigured
                : account.localServerValidated
                    ? .available : .notYetValidated
        )
    }

    func endpointDiagnosticsUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AppEndpointDiagnostics> {
        AsyncStream { $0.finish() }
    }

    func serverEndpointRouter() async -> ServerEndpointRouter? {
        nil
    }

    func networkPathUpdates() async -> AsyncStream<AppNetworkPathState> {
        AsyncStream { $0.finish() }
    }

    func recordServerActivity(
        url: URL,
        purpose: ServerConnectionPurpose
    ) async {}

    func reportServerTransportFailure(url: URL) async -> Bool {
        false
    }

    func primaryFallbackDownloadRequest(
        for failedRequest: URLRequest
    ) async -> URLRequest? {
        nil
    }

    func updateAccount(
        _ account: ServerAccount,
        serverAddress: String,
        localServerAddress: String,
        username: String,
        password: String,
        localServerValidation: LocalServerValidationPolicy,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> AccountUpdateServiceOutcome {
        .updated(account)
    }

    func liveUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AudiobookshelfLiveUpdate> {
        AsyncStream { $0.finish() }
    }

    func cachedChapterTranscripts(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [CachedChapterTranscript] {
        []
    }

    func saveCachedChapterTranscript(
        _ transcript: CachedChapterTranscript,
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) {}

    func cachedChapterTranscriptionTaskState(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> CachedChapterTranscriptionTaskState? {
        nil
    }

    func saveCachedChapterTranscriptionTaskState(
        _ state: CachedChapterTranscriptionTaskState,
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) {}

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
    private let openIDAuthenticationCoordinator: AuthCoordinator<
        URLSessionOpenIDTransport,
        TokenVault
    >
    private let openIDBrowserProvider:
        @MainActor @Sendable () -> any OpenIDBrowserSession
    private let accountStore: AccountStore
    private let libraryCache: LibraryCache
    private let transcriptCache: ChapterTranscriptCache
    private let statisticsRepository: StatisticsRepository
    private let privateCloudSync: PrivateCloudSyncCoordinator?
    private var networkPathMonitor: AppNetworkPathMonitor?
    private struct LiveClientRegistration: Sendable {
        let token: UUID
        let client: AudiobookshelfLiveEventClient
    }

    private var liveClients: [AccountID: LiveClientRegistration] = [:]
    private var networkProbeGeneration = 0
    private var networkProbeTask: Task<Void, Never>?
    private var networkPathState: AppNetworkPathState = .unknown
    private var networkPathContinuations:
        [UUID: AsyncStream<AppNetworkPathState>.Continuation] = [:]
    private let searchCoordinator = LibrarySearchCoordinator()

    init(
        diagnostics: any DiagnosticRecording =
            SystemDiagnosticRecorder.shared,
        openIDBrowserProvider: @escaping @MainActor @Sendable ()
            -> any OpenIDBrowserSession
    ) throws(AppBootstrapError) {
        let schema = Schema(BleatPersistenceModelCatalog.allModelTypes)
        do {
            let storeURL = try BleatLocalStore.storeURL()
            modelContainer = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        schema: schema,
                        url: storeURL,
                        cloudKitDatabase: .none
                    )
                ]
            )
        } catch {
            throw .persistenceUnavailable
        }

        let endpointRouter = ServerEndpointRouter()
        self.endpointRouter = endpointRouter
        directTransport = URLSessionHTTPTransport(
            diagnostics: diagnostics,
            endpointRouter: endpointRouter,
            routesRequests: false
        )
        transport = URLSessionHTTPTransport(
            diagnostics: diagnostics,
            endpointRouter: endpointRouter
        )
        let privateCloudAvailable = BleatCloudKitCapability.isAvailable
        let privateCloudEnabled =
            privateCloudAvailable
            && (UserDefaults.standard.object(
                forKey: "bleat.cloudKit.enabled.v1"
            ) == nil
                || UserDefaults.standard.bool(
                    forKey: "bleat.cloudKit.enabled.v1"
                ))
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
        authenticationCoordinator = Coordinator(
            transport: directTransport,
            credentialStore: credentialStore
        )
        guard let openIDTransport = try? URLSessionOpenIDTransport() else {
            throw .persistenceUnavailable
        }
        openIDAuthenticationCoordinator = AuthCoordinator(
            transport: openIDTransport,
            credentialStore: credentialStore
        )
        self.openIDBrowserProvider = openIDBrowserProvider
        accountStore = AccountStore(modelContainer: modelContainer)
        libraryCache = LibraryCache(modelContainer: modelContainer)
        transcriptCache = ChapterTranscriptCache(
            modelContainer: modelContainer
        )
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

    func loginWithOpenID(
        serverAddress: String,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        let server: NormalizedServerURL
        do {
            server = try NormalizedServerURL(serverAddress)
        } catch let error {
            throw .invalidServerURL(error)
        }

        await progress(.checkingServer)
        let discoveredServer = try await discoverDirect(server)
        guard discoveredServer.authenticationMethods.contains(.openID) else {
            throw .onboarding(.openIDAuthenticationUnavailable)
        }
        let callbackURL: OpenIDCallbackURL
        do {
            callbackURL = try OpenIDCallbackURL(
                "com.yaleman.bleat:/oauth2redirect"
            )
        } catch {
            throw .onboarding(.openIDAuthenticationUnavailable)
        }

        await progress(.signingIn)
        let browser = await openIDBrowserProvider()
        do {
            let account = try await openIDAuthenticationCoordinator
                .loginWithOpenIDAndPersistAccount(
                    accountID: AccountID(
                        rawValue: UUID().uuidString.lowercased()
                    ),
                    discoveredServer: discoveredServer,
                    callbackURL: callbackURL,
                    browser: browser,
                    accountStore: accountStore,
                    onAuthenticationCompleted: {
                        await progress(.savingAccount)
                    }
                )
            await endpointRouter.recordAuthenticationUse(
                primary: account.server,
                usage: .primary
            )
            return account
        } catch let error as AccountOnboardingError {
            throw .onboarding(error)
        } catch {
            throw .onboarding(.authenticationRequestFailed)
        }
    }

    func liveUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AudiobookshelfLiveUpdate> {
        guard networkPathState.allowsRealtimeUpdates else {
            let state: AudiobookshelfLiveConnectionState =
                networkPathState.isConstrained
                ? .suspendedForLowDataMode : .disconnected
            return AsyncStream { continuation in
                continuation.yield(.connection(state))
                continuation.finish()
            }
        }
        let coordinator = coordinator
        let endpointRouter = self.endpointRouter
        if let existing = liveClients.removeValue(forKey: account.id) {
            await existing.client.stop()
        }
        let clientToken = UUID()
        let client = AudiobookshelfLiveEventClient(
            serverProvider: {
                await endpointRouter.preferredServer(for: account.server)
            },
            tokenProvider: {
                try await coordinator.accessToken(for: account.id)
            },
            tokenRecovery: { rejectedToken in
                try await coordinator.recoverAccessToken(
                    for: account.id,
                    server: account.server,
                    rejectedAccessToken: rejectedToken
                )
            },
            onTransportFailure: { server in
                guard let localServer = account.localServer,
                    server == localServer
                else {
                    return
                }
                await endpointRouter.markLocalUnavailable(
                    for: account.server
                )
            },
            onAuthenticated: { server in
                let isLocal =
                    account.localServer.map {
                        server == $0
                    } ?? false
                let usage: ServerEndpointUsage =
                    isLocal ? .local : .primary
                await endpointRouter.recordConnection(
                    primary: account.server,
                    usage: usage,
                    purpose: .webSocket
                )
            }
        )
        liveClients[account.id] = LiveClientRegistration(
            token: clientToken,
            client: client
        )
        let source = await client.updates()
        return AsyncStream { continuation in
            let forwardingTask = Task {
                for await update in source {
                    guard !Task.isCancelled else {
                        break
                    }
                    continuation.yield(update)
                }
                continuation.finish()
                self.removeLiveClient(
                    accountID: account.id,
                    token: clientToken
                )
            }
            continuation.onTermination = { _ in
                forwardingTask.cancel()
                Task {
                    await client.stop()
                    await self.removeLiveClient(
                        accountID: account.id,
                        token: clientToken
                    )
                }
            }
        }
    }

    func stopLiveUpdates(for accountID: AccountID) async {
        guard let registration = liveClients.removeValue(forKey: accountID)
        else {
            return
        }
        await registration.client.stop()
    }

    private func removeLiveClient(
        accountID: AccountID,
        token: UUID
    ) {
        guard liveClients[accountID]?.token == token else {
            return
        }
        liveClients.removeValue(forKey: accountID)
    }

    private func networkPathChanged(_ state: AppNetworkPathState) async {
        networkPathState = state
        networkProbeGeneration &+= 1
        let generation = networkProbeGeneration
        for continuation in networkPathContinuations.values {
            continuation.yield(state)
        }
        if !state.allowsRealtimeUpdates {
            let clients = liveClients.values.map(\.client)
            liveClients.removeAll()
            for client in clients {
                await client.stop()
            }
        }
        networkProbeTask?.cancel()
        networkProbeTask = Task { [weak self] in
            await self?.probeNetworkEndpoints(generation: generation)
        }
    }

    private func probeNetworkEndpoints(generation: Int) async {
        guard generation == networkProbeGeneration else {
            return
        }
        await endpointRouter.networkPathDidChange()
        do {
            let accounts = try await accountStore.accounts()
            for account in accounts {
                guard generation == networkProbeGeneration,
                    !Task.isCancelled
                else {
                    return
                }
                guard let localServer = account.localServer
                else {
                    continue
                }
                do {
                    _ = try await ServerDiscoveryClient(
                        transport: directTransport
                    ).discover(localServer)
                    guard generation == networkProbeGeneration,
                        !Task.isCancelled
                    else {
                        return
                    }
                    let promotedValidation = !account.localServerValidated
                    if promotedValidation {
                        _ = try await authenticationCoordinator
                            .validateSavedNativeLogin(
                                accountID: account.id,
                                server: localServer,
                                expectedUserID: account.user.id
                            )
                        try await accountStore.setLocalServer(
                            localServer,
                            validated: true,
                            for: account.id
                        )
                    }
                    await endpointRouter.configure(
                        primary: account.server,
                        local: localServer
                    )
                    await endpointRouter.markLocalAvailable(
                        for: account.server
                    )
                    if promotedValidation {
                        await endpointRouter.recordAuthenticationUse(
                            primary: account.server,
                            usage: .local
                        )
                        for continuation in networkPathContinuations.values {
                            continuation.yield(networkPathState)
                        }
                    }
                } catch {
                    guard generation == networkProbeGeneration,
                        !Task.isCancelled
                    else {
                        return
                    }
                    await endpointRouter.markLocalUnavailable(
                        for: account.server
                    )
                }
            }
        } catch {
            // The next routed request will still perform normal local-first
            // selection if the account list cannot be read here.
        }
        guard generation == networkProbeGeneration,
            !Task.isCancelled
        else {
            return
        }
        if networkPathState.allowsRealtimeUpdates {
            let clients = liveClients.values.map(\.client)
            for client in clients {
                guard generation == networkProbeGeneration,
                    !Task.isCancelled
                else {
                    return
                }
                await client.reconnect()
            }
        }
        if generation == networkProbeGeneration {
            networkProbeTask = nil
        }
    }

    func endpointDiagnostics(
        for account: ServerAccount
    ) async -> AppEndpointDiagnostics {
        let snapshot =
            await endpointRouter.activitySnapshot(for: account.server)
        let localAvailability = await endpointRouter.localAvailability(
            for: account.server
        )
        return endpointDiagnostics(
            snapshot: snapshot,
            account: account,
            localAvailability: localAvailability
        )
    }

    func endpointDiagnosticsUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AppEndpointDiagnostics> {
        let updates =
            await endpointRouter.activityUpdates(for: account.server)
        return AsyncStream { continuation in
            let task = Task {
                for await snapshot in updates {
                    let localAvailability =
                        await endpointRouter.localAvailability(
                            for: account.server
                        )
                    continuation.yield(
                        self.endpointDiagnostics(
                            snapshot: snapshot,
                            account: account,
                            localAvailability: localAvailability
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func serverEndpointRouter() async -> ServerEndpointRouter? {
        endpointRouter
    }

    func networkPathUpdates() async -> AsyncStream<AppNetworkPathState> {
        startNetworkPathMonitoring()
        return AsyncStream { continuation in
            let token = UUID()
            networkPathContinuations[token] = continuation
            continuation.yield(networkPathState)
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeNetworkPathContinuation(token)
                }
            }
        }
    }

    private func removeNetworkPathContinuation(_ token: UUID) {
        networkPathContinuations[token] = nil
    }

    func recordServerActivity(
        url: URL,
        purpose: ServerConnectionPurpose
    ) async {
        let candidate =
            await endpointRouter.candidate(forResolvedURL: url)
        await endpointRouter.recordConnection(
            candidate,
            purpose: purpose
        )
    }

    func reportServerTransportFailure(url: URL) async -> Bool {
        let candidate = await endpointRouter.candidate(forResolvedURL: url)
        guard candidate.isLocal, let primary = candidate.primary else {
            return false
        }
        await endpointRouter.markLocalUnavailable(for: primary)
        return true
    }

    func primaryFallbackDownloadRequest(
        for failedRequest: URLRequest
    ) async -> URLRequest? {
        await endpointRouter.primaryFallbackRequest(for: failedRequest)
    }

    nonisolated private func endpointDiagnostics(
        snapshot: ServerEndpointActivitySnapshot,
        account: ServerAccount,
        localAvailability: ServerEndpointLocalAvailability
    ) -> AppEndpointDiagnostics {
        return AppEndpointDiagnostics(
            lastConnection: snapshot.lastConnection.map {
                AppEndpointActivityDescription(
                    purpose: $0.purpose,
                    endpoint: endpointDescription(
                        usage: $0.usage,
                        account: account
                    )
                )
            },
            authentication: snapshot.authentication.map {
                endpointDescription(
                    usage: $0,
                    account: account
                )
            },
            api: snapshot.api.map {
                endpointDescription(
                    usage: $0,
                    account: account
                )
            },
            webSocket: endpointDescription(
                usage: snapshot.webSocket ?? .primary,
                account: account
            ),
            localServerState: localServerState(
                account: account,
                availability: localAvailability
            )
        )
    }

    nonisolated private func localServerState(
        account: ServerAccount,
        availability: ServerEndpointLocalAvailability
    ) -> AppLocalServerState {
        guard account.localServer != nil else {
            return .notConfigured
        }
        guard account.localServerValidated else {
            return .notYetValidated
        }
        switch availability {
        case .notConfigured, .temporarilyUnavailable:
            return .temporarilyUnavailable
        case .unknown:
            return .probing
        case .available:
            return .available
        }
    }

    func accounts()
        async throws(AppServiceError) -> [ServerAccount]
    {
        startNetworkPathMonitoring()
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

    private func startNetworkPathMonitoring() {
        guard networkPathMonitor == nil else {
            return
        }
        networkPathMonitor = AppNetworkPathMonitor { [weak self] state in
            Task {
                await self?.networkPathChanged(state)
            }
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
        localServerValidation: LocalServerValidationPolicy,
        progress: @escaping AccountSubmissionProgress
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
        await progress(.checkingServer)
        let discoveredPrimary = try await discoverDirect(primary)
        guard discoveredPrimary.authenticationMethods.contains(.local) else {
            throw .onboarding(.localAuthenticationUnavailable)
        }

        var localWasValidated = false
        if let local,
            localValidationDecision == .validate,
            localServerValidation == .required
        {
            do {
                await progress(.checkingLocalServer)
                let discoveredLocal = try await discoverDirect(local)
                guard discoveredLocal.authenticationMethods.contains(.local)
                else {
                    throw AccountOnboardingError.localAuthenticationUnavailable
                }
                await progress(.verifyingLocalCredentials)
                if password.isEmpty {
                    _ = try await authenticationCoordinator
                        .validateSavedNativeLogin(
                            accountID: account.id,
                            server: local,
                            expectedUserID: account.user.id
                        )
                } else {
                    _ = try await authenticationCoordinator
                        .validateLocalLogin(
                            accountID: account.id,
                            server: local,
                            username: username,
                            password: password,
                            expectedUserID: account.user.id
                        )
                }
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
            LocalServerValidationDecision.persistedValidation(
                account: account,
                local: local,
                validationSucceeded: localWasValidated
            )

        let persisted: ServerAccount
        do {
            if password.isEmpty {
                await progress(.verifyingSavedCredentials)
                let authenticated =
                    try await authenticationCoordinator
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
                await progress(.savingAccount)
                try await accountStore.save(persisted)
            } else {
                await progress(.signingIn)
                persisted =
                    try await authenticationCoordinator
                    .loginAndPersistAccount(
                        accountID: account.id,
                        discoveredServer: discoveredPrimary,
                        username: username,
                        password: password,
                        expectedUserID: account.user.id,
                        accountStore: accountStore,
                        makeActive: false,
                        onAuthenticationCompleted: {
                            await progress(.savingAccount)
                        }
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
        password: String,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        let server: NormalizedServerURL
        do {
            server = try NormalizedServerURL(serverAddress)
        } catch let error {
            throw .invalidServerURL(error)
        }

        await progress(.checkingServer)
        let discoveredServer = try await discoverDirect(server)

        do {
            await progress(.signingIn)
            let account =
                try await authenticationCoordinator.loginAndPersistAccount(
                    accountID: AccountID(
                        rawValue: UUID().uuidString.lowercased()
                    ),
                    discoveredServer: discoveredServer,
                    username: username,
                    password: password,
                    accountStore: accountStore,
                    onAuthenticationCompleted: {
                        await progress(.savingAccount)
                    }
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

    func reauthenticateWithOpenID(
        _ account: ServerAccount,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        let discoveredServer = try await discoverDirect(account.server)
        guard discoveredServer.authenticationMethods.contains(.openID) else {
            throw .onboarding(.openIDAuthenticationUnavailable)
        }
        let callbackURL: OpenIDCallbackURL
        do {
            callbackURL = try OpenIDCallbackURL(
                "com.yaleman.bleat:/oauth2redirect"
            )
        } catch {
            throw .onboarding(.openIDAuthenticationUnavailable)
        }

        await progress(.checkingServer)
        await progress(.signingIn)
        let browser = await openIDBrowserProvider()
        do {
            let authenticated = try await openIDAuthenticationCoordinator
                .loginWithOpenIDAndPersistAccount(
                    accountID: account.id,
                    discoveredServer: discoveredServer,
                    callbackURL: callbackURL,
                    browser: browser,
                    accountStore: accountStore,
                    expectedUserID: account.user.id,
                    makeActive: false
                )
            await endpointRouter.recordAuthenticationUse(
                primary: authenticated.server,
                usage: .primary
            )
            return authenticated
        } catch let error as AccountOnboardingError {
            throw .onboarding(error)
        } catch {
            throw .onboarding(.authenticationRequestFailed)
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
        request: LibraryItemsPageRequest
    ) async throws(AppServiceError) -> LibraryItemsPage {
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

    func refreshedLibraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary] {
        let repository = repository(for: account)
        do {
            return try await repository.libraries(policy: .remoteOnly).value
        } catch let error {
            throw .libraryRepository(error)
        }
    }

    func refreshedPage(
        for account: ServerAccount,
        libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) async throws(AppServiceError) -> LibraryItemsPage {
        let repository = repository(for: account)
        do {
            return try await repository.libraryItems(
                in: libraryID,
                request: request,
                policy: .remoteOnly
            ).value
        } catch let error {
            throw .libraryRepository(error)
        }
    }

    func refreshedHomeShelves(
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
                request: request,
                policy: .remoteOnly
            ).value
        } catch let error {
            throw .libraryRepository(error)
        }
    }

    func search(
        for account: ServerAccount,
        libraryID: LibraryID,
        query: String
    ) async throws(AppServiceError) -> LibrarySearchResults {
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
                    appTracks.append(
                        AppPlaybackTrack(
                            url: await routedServerURL(track.url),
                            startOffset: track.track.startOffset,
                            duration: track.track.duration,
                            title: track.track.title
                        ))
                }
                source = .direct(appTracks)
            case .hls(let url):
                source = .hls(
                    await routedServerURL(url)
                )
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
            updated.url = await routedServerURL(url)
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
            updated.url = await routedServerURL(url)
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

        var cacheCleanupFailed = false
        do {
            try await libraryCache.invalidateLibrary(
                detail.libraryID,
                for: account.id
            )
        } catch {
            cacheCleanupFailed = true
        }
        do {
            try await transcriptCache.removeBook(
                accountID: account.id,
                itemID: detail.id
            )
        } catch {
            cacheCleanupFailed = true
        }
        return cacheCleanupFailed
            ? .deletedWithCacheCleanupFailure
            : .deleted
    }

    func cachedChapterTranscripts(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [CachedChapterTranscript] {
        do {
            return try await transcriptCache.transcripts(
                accountID: accountID,
                itemID: itemID
            )
        } catch let error {
            throw .transcriptCache(error)
        }
    }

    func saveCachedChapterTranscript(
        _ transcript: CachedChapterTranscript,
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) {
        do {
            try await transcriptCache.save(
                transcript,
                accountID: accountID,
                itemID: itemID
            )
        } catch let error {
            throw .transcriptCache(error)
        }
    }

    func cachedChapterTranscriptionTaskState(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> CachedChapterTranscriptionTaskState? {
        do {
            return try await transcriptCache.taskState(
                accountID: accountID,
                itemID: itemID
            )
        } catch let error {
            throw .transcriptCache(error)
        }
    }

    func saveCachedChapterTranscriptionTaskState(
        _ state: CachedChapterTranscriptionTaskState,
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) {
        do {
            try await transcriptCache.saveTaskState(
                state,
                accountID: accountID,
                itemID: itemID
            )
        } catch let error {
            throw .transcriptCache(error)
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
        await stopLiveUpdates(for: account.id)
        do {
            try await libraryCache.removeAccount(account.id)
        } catch let error {
            throw .libraryCache(error)
        }
        do {
            try await transcriptCache.removeAccount(account.id)
        } catch let error {
            throw .transcriptCache(error)
        }

        let logoutResult: LogoutResult
        do {
            logoutResult = try await coordinator.removePersistedAccount(
                accountID: account.id,
                accountStore: accountStore
            )
        } catch let error {
            throw .accountRemoval(error)
        }
        await presentProviderLogout(logoutResult.providerLogoutURL)
    }

    func removeAccountFromThisDevice(
        _ account: ServerAccount,
        includeStatistics: Bool
    ) async throws(AppServiceError) {
        await stopLiveUpdates(for: account.id)
        do {
            try await libraryCache.removeAccount(account.id)
        } catch let error {
            throw .libraryCache(error)
        }
        do {
            try await transcriptCache.removeAccount(account.id)
        } catch let error {
            throw .transcriptCache(error)
        }
        await privateCloudSync?.ignoreAccountOnThisDevice(
            account.id,
            includeStatistics: includeStatistics
        )
        let logoutResult: LogoutResult
        do {
            logoutResult = try await coordinator.removePersistedAccountFromDevice(
                accountID: account.id,
                accountStore: accountStore
            )
        } catch let error {
            throw .accountRemoval(error)
        }
        await presentProviderLogout(logoutResult.providerLogoutURL)
    }

    private func presentProviderLogout(_ url: URL?) async {
        guard let url else {
            return
        }
        let browser = await openIDBrowserProvider()
        await browser.presentLogout(at: url)
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

    nonisolated private func endpointDescription(
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

    private func routedServerURL(_ url: URL) async -> URL {
        return await endpointRouter.preferredCandidate(for: url).url
    }

    func discoverServer(
        serverAddress: String
    ) async throws(AppServiceError) -> DiscoveredServer {
        let server: NormalizedServerURL
        do {
            server = try NormalizedServerURL(serverAddress)
        } catch let error {
            throw .invalidServerURL(error)
        }
        return try await discoverDirect(server)
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
