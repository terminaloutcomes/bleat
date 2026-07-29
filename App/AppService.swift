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
    case accountRemoval(AccountLifecycleError)
    case libraryCache(LibraryCacheError)
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
