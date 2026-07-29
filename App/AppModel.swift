import BleatCore
import Foundation
import Observation

enum AppPhase: Equatable, Sendable {
    case launching
    case signedOut
    case signedIn
    case unavailable(AppFailure)
}

enum LoginStatus: Equatable, Sendable {
    case idle
    case submitting
    case failed(AppFailure)
}

enum ResourceState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(AppFailure)
}

enum AccountActionStatus: Equatable, Sendable {
    case idle
    case removing
    case failed(AppFailure)
}

enum AppFailure: Equatable, Sendable {
    case persistenceUnavailable
    case invalidServerAddress
    case serverUnavailable
    case serverRequiresHTTPS
    case serverNotReady
    case serverUnsupported
    case localLoginUnavailable
    case invalidCredentials
    case loginFailed
    case accountUnavailable
    case libraryUnavailable
    case searchUnavailable
    case bookUnavailable
    case playbackDenied
    case playbackUnavailable
    case mediaUnavailable
    case accountRemovalFailed

    var message: String {
        switch self {
        case .persistenceUnavailable:
            "Bleat could not open its local data store."
        case .invalidServerAddress:
            "Enter a valid Audiobookshelf server address."
        case .serverUnavailable:
            "Bleat could not reach that Audiobookshelf server."
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
        case .loginFailed:
            "Bleat could not sign in to that server."
        case .accountUnavailable:
            "Bleat could not restore the saved account."
        case .libraryUnavailable:
            "Bleat could not load the audiobook library."
        case .searchUnavailable:
            "Bleat could not search the audiobook library."
        case .bookUnavailable:
            "Bleat could not load that audiobook."
        case .playbackDenied:
            "This account is not allowed to play that audiobook."
        case .playbackUnavailable:
            "Bleat could not start playback from the server."
        case .mediaUnavailable:
            "This audiobook could not be prepared for playback."
        case .accountRemovalFailed:
            "Bleat could not remove the account."
        }
    }

    init(serviceError: AppServiceError) {
        switch serviceError {
        case .invalidServerURL(let error):
            switch error {
            case .unsupportedScheme:
                self = .serverRequiresHTTPS
            default:
                self = .invalidServerAddress
            }
        case .discovery(let error):
            switch error {
            case .uninitialized:
                self = .serverNotReady
            case .unsupportedServerVersion, .invalidServerVersion:
                self = .serverUnsupported
            default:
                self = .serverUnavailable
            }
        case .discoveryRequestFailed:
            self = .serverUnavailable
        case .onboarding(let error):
            switch error {
            case .localAuthenticationUnavailable:
                self = .localLoginUnavailable
            case .authenticationFailed(let authenticationError):
                self =
                    authenticationError == .invalidCredentials
                    ? .invalidCredentials
                    : .loginFailed
            default:
                self = .loginFailed
            }
        case .accountStore:
            self = .accountUnavailable
        case .libraryRepository, .pageRequest:
            self = .libraryUnavailable
        case .searchRequest, .searchCoordinator:
            self = .searchUnavailable
        case .bookDetail:
            self = .bookUnavailable
        case .playbackSession, .playbackSource, .playbackSync:
            self = .playbackUnavailable
        case .accountRemoval, .libraryCache:
            self = .accountRemovalFailed
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private let service: any AppServicing
    private var hasStarted = false
    private var searchGeneration: UInt64 = 0
    private var bookDetailGeneration: UInt64 = 0

    private(set) var phase: AppPhase
    private(set) var loginStatus: LoginStatus = .idle
    private(set) var accountActionStatus: AccountActionStatus = .idle
    private(set) var account: ServerAccount?
    private(set) var libraries: ResourceState<[LibrarySummary]> = .idle
    private(set) var selectedLibrary: LibrarySummary?
    private(set) var books: ResourceState<LibraryItemsPage> = .idle
    private(set) var searchQuery = ""
    private(set) var searchResults: ResourceState<[LibraryBookSummary]> = .idle
    private(set) var selectedBookID: LibraryItemID?
    private(set) var bookDetail: ResourceState<LibraryBookDetail> = .idle
    let playback: PlaybackModel

    init(service: any AppServicing) {
        self.service = service
        playback = PlaybackModel(service: service)
        phase = .launching
    }

    init(
        service: any AppServicing,
        bootstrapError: AppBootstrapError
    ) {
        self.service = service
        playback = PlaybackModel(service: service)
        hasStarted = true
        switch bootstrapError {
        case .persistenceUnavailable:
            phase = .unavailable(.persistenceUnavailable)
        }
    }

    func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true

        do {
            guard let restoredAccount = try await service.activeAccount()
            else {
                phase = .signedOut
                return
            }
            account = restoredAccount
            phase = .signedIn
            await loadLibraries()
        } catch let error {
            phase = .unavailable(AppFailure(serviceError: error))
        }
    }

    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async {
        guard loginStatus != .submitting else {
            return
        }
        loginStatus = .submitting

        do {
            let authenticatedAccount = try await service.login(
                serverAddress: serverAddress,
                username: username,
                password: password
            )
            account = authenticatedAccount
            phase = .signedIn
            loginStatus = .idle
            await loadLibraries()
        } catch let error {
            loginStatus = .failed(AppFailure(serviceError: error))
        }
    }

    func loadLibraries() async {
        guard let account else {
            libraries = .failed(.accountUnavailable)
            return
        }
        libraries = .loading
        selectedLibrary = nil
        books = .idle
        resetSearch()
        resetBookDetail()

        do {
            let loadedLibraries = try await service.libraries(for: account)
                .filter { library in
                    library.mediaType == .book
                }
            libraries = .loaded(loadedLibraries)
            guard let firstLibrary = loadedLibraries.first else {
                return
            }
            await selectLibrary(firstLibrary)
        } catch let error {
            libraries = .failed(AppFailure(serviceError: error))
        }
    }

    func selectLibrary(_ library: LibrarySummary) async {
        guard let account else {
            books = .failed(.accountUnavailable)
            return
        }
        if selectedLibrary?.id != library.id {
            resetSearch()
            resetBookDetail()
        }
        selectedLibrary = library
        books = .loading

        do {
            books = .loaded(
                try await service.firstPage(
                    for: account,
                    libraryID: library.id
                )
            )
        } catch let error {
            books = .failed(AppFailure(serviceError: error))
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
            searchResults = .failed(.accountUnavailable)
            return
        }
        searchResults = .loading

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
        } catch let error {
            guard searchGeneration == operationGeneration,
                !Task.isCancelled
            else {
                return
            }
            searchResults = .failed(AppFailure(serviceError: error))
        }
    }

    func loadBookDetail(_ book: LibraryBookSummary) async {
        bookDetailGeneration &+= 1
        let operationGeneration = bookDetailGeneration
        selectedBookID = book.id

        guard let account else {
            bookDetail = .failed(.accountUnavailable)
            return
        }
        bookDetail = .loading

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
        } catch let error {
            guard bookDetailGeneration == operationGeneration,
                !Task.isCancelled
            else {
                return
            }
            bookDetail = .failed(AppFailure(serviceError: error))
        }
    }

    func removeAccount() async {
        guard let account else {
            accountActionStatus = .failed(.accountUnavailable)
            return
        }
        guard accountActionStatus != .removing else {
            return
        }
        accountActionStatus = .removing
        await playback.stop()

        do {
            try await service.removeAccount(account)
            self.account = nil
            selectedLibrary = nil
            libraries = .idle
            books = .idle
            resetSearch()
            resetBookDetail()
            accountActionStatus = .idle
            loginStatus = .idle
            phase = .signedOut
        } catch let error {
            accountActionStatus = .failed(
                AppFailure(serviceError: error)
            )
        }
    }

    private func resetSearch() {
        searchGeneration &+= 1
        searchQuery = ""
        searchResults = .idle
    }

    private func resetBookDetail() {
        bookDetailGeneration &+= 1
        selectedBookID = nil
        bookDetail = .idle
    }
}
