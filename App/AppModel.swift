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
    case switching
    case removing
    case failed(AppFailure)
}

enum AccountDownloadDisposition: Equatable, Sendable {
    case keep
    case delete
}

enum MetadataSaveState: Equatable, Sendable {
    case idle
    case saving
    case stale(LibraryBookDetail)
    case saved
    case failed(AppFailure)
}

enum BookProgressUpdateState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed(AppFailure)
}

enum LibraryPaginationState: Equatable, Sendable {
    case idle
    case loading
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
    case homeUnavailable
    case searchUnavailable
    case bookUnavailable
    case playbackDenied
    case playbackUnavailable
    case progressUnavailable
    case mediaUnavailable
    case invalidMetadata
    case metadataUnavailable
    case bookmarkUnavailable
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
        case .homeUnavailable:
            "Bleat could not load personalized shelves."
        case .searchUnavailable:
            "Bleat could not search the audiobook library."
        case .bookUnavailable:
            "Bleat could not load that audiobook."
        case .playbackDenied:
            "This account is not allowed to play that audiobook."
        case .playbackUnavailable:
            "Bleat could not start playback from the server."
        case .progressUnavailable:
            "Bleat could not update audiobook progress."
        case .mediaUnavailable:
            "This audiobook could not be prepared for playback."
        case .invalidMetadata:
            "Review the metadata fields and enter a title."
        case .metadataUnavailable:
            "Bleat could not save metadata to the server."
        case .bookmarkUnavailable:
            "Bleat could not update bookmarks."
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
        case .homeRequest:
            self = .homeUnavailable
        case .searchRequest, .searchCoordinator:
            self = .searchUnavailable
        case .bookDetail:
            self = .bookUnavailable
        case .playbackSession, .playbackSource, .playbackSync:
            self = .playbackUnavailable
        case .progress, .localPlaybackSession:
            self = .progressUnavailable
        case .metadataPatch:
            self = .invalidMetadata
        case .metadataUpdate, .coverUpdate:
            self = .metadataUnavailable
        case .bookmark:
            self = .bookmarkUnavailable
        case .downloadPlan, .downloadAuthorization:
            self = .mediaUnavailable
        case .accountRemoval, .libraryCache:
            self = .accountRemovalFailed
        }
    }
}

@MainActor
@Observable
final class AppModel {
    private let service: any AppServicing
    private let diagnostics: any DiagnosticRecording
    private var hasStarted = false
    private var libraryPageGeneration: UInt64 = 0
    private var searchGeneration: UInt64 = 0
    private var bookDetailGeneration: UInt64 = 0

    private(set) var phase: AppPhase
    private(set) var loginStatus: LoginStatus = .idle
    private(set) var accountActionStatus: AccountActionStatus = .idle
    private(set) var account: ServerAccount?
    private(set) var accounts: [ServerAccount] = []
    private(set) var libraries: ResourceState<[LibrarySummary]> = .idle
    private(set) var selectedLibrary: LibrarySummary?
    private(set) var books: ResourceState<LibraryItemsPage> = .idle
    private(set) var libraryPaginationState: LibraryPaginationState = .idle
    private(set) var librarySort: LibraryItemSort = .title
    private(set) var librarySortDescending = false
    private(set) var libraryProgressFilter: LibraryProgressFilter?
    private(set) var homeShelves: ResourceState<[LibraryBookShelf]> = .idle
    private(set) var searchQuery = ""
    private(set) var searchResults: ResourceState<[LibraryBookSummary]> = .idle
    private(set) var selectedBookID: LibraryItemID?
    private(set) var bookDetail: ResourceState<LibraryBookDetail> = .idle
    private(set) var bookBookmarks: ResourceState<[AudioBookmark]> = .idle
    private(set) var metadataSaveState: MetadataSaveState = .idle
    private(set) var bookProgressUpdateState: BookProgressUpdateState = .idle
    let playback: PlaybackModel
    let downloads: DownloadModel
    #if DEBUG
        let diagnosticLogStore: PersistentDiagnosticLogStore?
    #endif

    init(
        service: any AppServicing,
        downloadsStorageRootURL: URL? = nil,
        diagnostics: any DiagnosticRecording =
            SystemDiagnosticRecorder.shared,
        diagnosticLogStore: (any DiagnosticRecording)? = nil
    ) {
        self.service = service
        self.diagnostics = diagnostics
        let playback = PlaybackModel(
            service: service,
            diagnostics: diagnostics
        )
        let downloads = DownloadModel(
            service: service,
            storageRootURL: downloadsStorageRootURL,
            diagnostics: diagnostics
        )
        self.playback = playback
        self.downloads = downloads
        #if DEBUG
            self.diagnosticLogStore =
                diagnosticLogStore as? PersistentDiagnosticLogStore
        #endif
        playback.setAutomaticDownloadHandler { [weak downloads] activity in
            await downloads?.handleAutomaticPlaybackActivity(activity)
        }
        phase = .launching
    }

    init(
        service: any AppServicing,
        bootstrapError: AppBootstrapError,
        diagnostics: any DiagnosticRecording =
            SystemDiagnosticRecorder.shared,
        diagnosticLogStore: (any DiagnosticRecording)? = nil
    ) {
        self.service = service
        self.diagnostics = diagnostics
        let playback = PlaybackModel(
            service: service,
            diagnostics: diagnostics
        )
        let downloads = DownloadModel(
            service: service,
            diagnostics: diagnostics
        )
        self.playback = playback
        self.downloads = downloads
        #if DEBUG
            self.diagnosticLogStore =
                diagnosticLogStore as? PersistentDiagnosticLogStore
        #endif
        playback.setAutomaticDownloadHandler { [weak downloads] activity in
            await downloads?.handleAutomaticPlaybackActivity(activity)
        }
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
        await diagnostics.record(
            .started(.appStart, category: .app)
        )

        do {
            await diagnostics.record(
                .started(.restoreAccounts, category: .auth)
            )
            accounts = try await service.accounts()
            await diagnostics.record(
                .completed(
                    .restoreAccounts,
                    category: .auth,
                    count: accounts.count
                )
            )
            await downloads.start(account: nil)
            for storedAccount in accounts {
                await downloads.start(account: storedAccount)
                await playback.syncPendingLocalSessions(
                    for: storedAccount
                )
            }
            guard let restoredAccount = try await service.activeAccount()
            else {
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
            await diagnostics.record(
                .completed(.appStart, category: .app)
            )
        } catch let error {
            let failure = AppFailure(serviceError: error)
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

    @discardableResult
    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async -> Bool {
        guard loginStatus != .submitting else {
            return false
        }
        loginStatus = .submitting
        await diagnostics.record(
            .started(.login, category: .auth)
        )

        do {
            let authenticatedAccount = try await service.login(
                serverAddress: serverAddress,
                username: username,
                password: password
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
            await playback.syncPendingLocalSessions(
                for: authenticatedAccount
            )
            await loadLibraries()
            return true
        } catch let error {
            let failure = AppFailure(serviceError: error)
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
    }

    @discardableResult
    func reauthenticate(password: String) async -> Bool {
        guard let account else {
            loginStatus = .failed(.accountUnavailable)
            return false
        }
        guard loginStatus != .submitting else {
            return false
        }
        loginStatus = .submitting
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
            await playback.syncPendingLocalSessions(
                for: authenticatedAccount
            )
            await loadLibraries()
            return true
        } catch let error {
            let failure = AppFailure(serviceError: error)
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
        accountActionStatus = .switching
        await diagnostics.record(
            .started(.switchAccount, category: .auth)
        )
        do {
            try await service.activateAccount(selectedAccount)
            account = selectedAccount
            await downloads.start(account: selectedAccount)
            await playback.syncPendingLocalSessions(for: selectedAccount)
            await loadLibraries()
            accountActionStatus = .idle
            await diagnostics.record(
                .completed(.switchAccount, category: .auth)
            )
        } catch let error {
            let failure = AppFailure(serviceError: error)
            accountActionStatus = .failed(
                failure
            )
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
        guard let account else {
            libraries = .failed(.accountUnavailable)
            return
        }
        await diagnostics.record(
            .started(.loadLibraries, category: .api)
        )
        libraries = .loading
        selectedLibrary = nil
        libraryPageGeneration &+= 1
        books = .idle
        libraryPaginationState = .idle
        homeShelves = .idle
        resetSearch()
        resetBookDetail()

        do {
            let loadedLibraries = try await service.libraries(for: account)
                .filter { library in
                    library.mediaType == .book
                }
            libraries = .loaded(loadedLibraries)
            await diagnostics.record(
                .completed(
                    .loadLibraries,
                    category: .api,
                    count: loadedLibraries.count
                )
            )
            guard let firstLibrary = loadedLibraries.first else {
                return
            }
            await selectLibrary(firstLibrary)
        } catch let error {
            let failure = AppFailure(serviceError: error)
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

    func selectLibrary(_ library: LibrarySummary) async {
        guard let account else {
            books = .failed(.accountUnavailable)
            homeShelves = .failed(.accountUnavailable)
            return
        }
        if selectedLibrary?.id != library.id {
            resetSearch()
            resetBookDetail()
        }
        selectedLibrary = library
        homeShelves = .loading
        await diagnostics.record(
            .started(.loadHome, category: .api)
        )

        await reloadBooks()
        guard self.account?.id == account.id,
            selectedLibrary?.id == library.id
        else {
            return
        }
        do {
            homeShelves = .loaded(
                try await service.homeShelves(
                    for: account,
                    libraryID: library.id
                )
            )
            let count: Int
            if case .loaded(let shelves) = homeShelves {
                count = shelves.count
            } else {
                count = 0
            }
            await diagnostics.record(
                .completed(
                    .loadHome,
                    category: .api,
                    count: count
                )
            )
        } catch {
            homeShelves = .failed(.homeUnavailable)
            await diagnostics.record(
                .failed(
                    .loadHome,
                    category: .api,
                    failureCode: .homeUnavailable
                )
            )
        }
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
        guard libraryProgressFilter != filter else {
            return
        }
        libraryProgressFilter = filter
        await reloadBooks()
    }

    func reloadBooks() async {
        libraryPageGeneration &+= 1
        let operationGeneration = libraryPageGeneration
        guard let account, let library = selectedLibrary else {
            books = .failed(.accountUnavailable)
            return
        }
        books = .loading
        libraryPaginationState = .idle
        await diagnostics.record(
            .started(.loadLibraryPage, category: .api)
        )

        do {
            let page = try await service.page(
                for: account,
                libraryID: library.id,
                page: 0,
                sort: librarySort,
                descending: librarySortDescending,
                filter: libraryProgressFilter.map(
                    LibraryItemFilter.init(progress:)
                )
            )
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id
            else {
                return
            }
            books = .loaded(page)
            await diagnostics.record(
                .completed(
                    .loadLibraryPage,
                    category: .api,
                    count: page.items.count
                )
            )
        } catch let error {
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id
            else {
                return
            }
            let failure = AppFailure(serviceError: error)
            books = .failed(failure)
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

        do {
            let nextPage = try await service.page(
                for: account,
                libraryID: library.id,
                page: nextPageNumber,
                sort: librarySort,
                descending: librarySortDescending,
                filter: libraryProgressFilter.map(
                    LibraryItemFilter.init(progress:)
                )
            )
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id,
                case .loaded(let latestPage) = books,
                latestPage.page == currentPage.page
            else {
                return
            }
            let existingIDs = Set(latestPage.items.map(\.id))
            let newItems = nextPage.items.filter {
                !existingIDs.contains($0.id)
            }
            books = .loaded(
                LibraryItemsPage(
                    items: latestPage.items + newItems,
                    total: nextPage.total,
                    page: nextPage.page,
                    limit: nextPage.limit
                )
            )
            libraryPaginationState = .idle
        } catch let error {
            guard operationGeneration == libraryPageGeneration,
                self.account?.id == account.id,
                selectedLibrary?.id == library.id
            else {
                return
            }
            libraryPaginationState = .failed(
                AppFailure(serviceError: error)
            )
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
        await diagnostics.record(
            .started(.search, category: .api)
        )

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
            await diagnostics.record(
                .completed(
                    .search,
                    category: .api,
                    count: results.count
                )
            )
        } catch let error {
            guard searchGeneration == operationGeneration,
                !Task.isCancelled
            else {
                return
            }
            let failure = AppFailure(serviceError: error)
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
            bookDetail = .failed(.accountUnavailable)
            return
        }
        bookDetail = .loading
        await diagnostics.record(
            .started(.loadBook, category: .api)
        )

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
            let failure = AppFailure(serviceError: error)
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

    func loadBookBookmarks() async {
        let operationGeneration = bookDetailGeneration
        guard let account, let itemID = selectedBookID else {
            bookBookmarks = .failed(.accountUnavailable)
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
            bookBookmarks = .failed(AppFailure(serviceError: error))
        }
    }

    func saveMetadata(
        draft: BookMetadataDraft,
        baseline: LibraryBookDetail,
        overwrite: Bool = false
    ) async {
        guard let account else {
            metadataSaveState = .failed(.accountUnavailable)
            return
        }
        guard metadataSaveState != .saving else {
            return
        }
        metadataSaveState = .saving
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
                metadataSaveState = .saved
            case .stale(let latest):
                metadataSaveState = .stale(latest)
            }
        } catch let error {
            metadataSaveState = .failed(
                AppFailure(serviceError: error)
            )
        }
    }

    func resetMetadataSaveState() {
        metadataSaveState = .idle
    }

    func replaceCover(
        jpegData: Data,
        detail: LibraryBookDetail
    ) async -> Bool {
        guard let account else {
            return false
        }
        do {
            let updated = try await service.replaceCover(
                for: account,
                detail: detail,
                jpegData: jpegData
            )
            selectedBookID = updated.id
            bookDetail = .loaded(updated)
            return true
        } catch {
            return false
        }
    }

    func setFinished(
        _ isFinished: Bool,
        detail: LibraryBookDetail
    ) async {
        guard let account else {
            bookProgressUpdateState = .failed(.accountUnavailable)
            return
        }
        guard bookProgressUpdateState != .saving else {
            return
        }
        bookProgressUpdateState = .saving
        do {
            try await service.updateBookProgress(
                for: account,
                itemID: detail.id,
                update: BookProgressUpdate(isFinished: isFinished)
            )
            let updated = try await service.bookDetail(
                for: account,
                libraryID: detail.libraryID,
                itemID: detail.id
            )
            selectedBookID = updated.id
            bookDetail = .loaded(updated)
            bookProgressUpdateState = .saved
        } catch let error {
            bookProgressUpdateState = .failed(
                AppFailure(serviceError: error)
            )
        }
    }

    func playDownloaded(_ record: DownloadedBookRecord) async {
        let recordAccount = accounts.first {
            $0.id == record.manifest.accountID
        }
        do {
            let urls = try await downloads.localTrackURLs(
                for: record
            )
            await playback.startDownloaded(
                detail: record.detail,
                trackURLs: urls,
                accountID: record.manifest.accountID,
                account: recordAccount
            )
        } catch {
            playback.fail(.mediaUnavailable)
        }
    }

    func removeAccount(
        downloads disposition: AccountDownloadDisposition = .delete
    ) async {
        guard let account else {
            accountActionStatus = .failed(.accountUnavailable)
            return
        }
        guard accountActionStatus != .removing else {
            return
        }
        accountActionStatus = .removing
        await diagnostics.record(
            .started(.removeAccount, category: .auth)
        )
        await playback.stop()

        do {
            try await service.removeAccount(account)
            switch disposition {
            case .keep:
                await downloads.retainDownloadsAndDetachAccount(
                    account.id
                )
            case .delete:
                await downloads.removeAll(for: account.id)
                playback.removeLocalData(for: account.id)
            }
            accounts.removeAll { $0.id == account.id }
            self.account = accounts.first
            selectedLibrary = nil
            libraryPageGeneration &+= 1
            libraries = .idle
            books = .idle
            libraryPaginationState = .idle
            homeShelves = .idle
            resetSearch()
            resetBookDetail()
            accountActionStatus = .idle
            loginStatus = .idle
            if let replacement = self.account {
                try await service.activateAccount(replacement)
                phase = .signedIn
                await downloads.start(account: replacement)
                await loadLibraries()
            } else {
                phase = .signedOut
            }
            await diagnostics.record(
                .completed(
                    .removeAccount,
                    category: .auth,
                    count: accounts.count
                )
            )
        } catch let error {
            let failure = AppFailure(serviceError: error)
            accountActionStatus = .failed(
                failure
            )
            await diagnostics.record(
                .failed(
                    .removeAccount,
                    category: .auth,
                    failureCode: failure.diagnosticFailureCode
                )
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
        bookBookmarks = .idle
        metadataSaveState = .idle
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
