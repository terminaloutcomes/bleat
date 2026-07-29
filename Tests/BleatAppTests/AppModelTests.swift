import BleatCore
import XCTest

@testable import Bleat

@MainActor
final class AppModelTests: XCTestCase {
    func testStartWithoutSavedAccountShowsLogin() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.account)
        XCTAssertEqual(model.libraries, .idle)
    }

    func testStartRestoresAccountAndLoadsFirstAudiobookLibrary() async throws {
        let account = try fixtureAccount()
        let audiobookLibrary = fixtureLibrary()
        let podcastLibrary = LibrarySummary(
            id: LibraryID(rawValue: "podcasts"),
            name: "Podcasts",
            mediaType: .podcast
        )
        let page = fixturePage(libraryID: audiobookLibrary.id)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([podcastLibrary, audiobookLibrary]),
            firstPage: .success(page)
        )
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(model.libraries, .loaded([audiobookLibrary]))
        XCTAssertEqual(model.selectedLibrary, audiobookLibrary)
        XCTAssertEqual(model.books, .loaded(page))
        let pageRequests = await service.pageRequests()
        XCTAssertEqual(pageRequests, [audiobookLibrary.id])
    }

    func testStartRunsOnlyOnce() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.start()
        await model.start()

        let requestCount = await service.activeAccountRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testStartFailureShowsUnavailableState() async {
        let service = TestAppService(
            activeAccount: .failure(.accountStore(.persistenceFailed))
        )
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .unavailable(.accountUnavailable))
    }

    func testBootstrapFailureRemainsUnavailableWhenRootStarts() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(
            service: service,
            bootstrapError: .persistenceUnavailable
        )

        await model.start()

        XCTAssertEqual(model.phase, .unavailable(.persistenceUnavailable))
        let requestCount = await service.activeAccountRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testNativeLoginForwardsUsernamePasswordAndLoadsLibrary() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .success(account),
            libraries: .success([library]),
            firstPage: .success(page)
        )
        let model = AppModel(service: service)

        await model.login(
            serverAddress: "https://books.example/audiobookshelf",
            username: "reader",
            password: "correct horse"
        )

        let loginRequests = await service.loginRequests()
        XCTAssertEqual(
            loginRequests,
            [
                LoginRequest(
                    serverAddress: "https://books.example/audiobookshelf",
                    username: "reader",
                    password: "correct horse"
                )
            ]
        )
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.loginStatus, .idle)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(model.books, .loaded(page))
    }

    func testRejectedNativeCredentialsRemainSignedOut() async {
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .failure(
                .onboarding(
                    .authenticationFailed(.invalidCredentials)
                )
            )
        )
        let model = AppModel(service: service)

        await model.start()
        await model.login(
            serverAddress: "https://books.example",
            username: "reader",
            password: "wrong"
        )

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.loginStatus, .failed(.invalidCredentials))
        XCTAssertNil(model.account)
    }

    func testConcurrentLoginIsIgnoredWhileSubmissionIsActive() async throws {
        let account = try fixtureAccount()
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .success(account),
            libraries: .success([]),
            loginGate: gate
        )
        let model = AppModel(service: service)

        let firstLogin = Task { @MainActor in
            await model.login(
                serverAddress: "https://books.example",
                username: "reader",
                password: "first"
            )
        }
        await gate.waitUntilEntered()

        await model.login(
            serverAddress: "https://other.example",
            username: "other",
            password: "second"
        )
        await gate.release()
        await firstLogin.value

        let loginRequestCount = await service.loginRequests().count
        XCTAssertEqual(loginRequestCount, 1)
    }

    func testLibraryFailureAndRetry() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .failure(
                .libraryRepository(.remote(.unexpectedStatus(503)))
            )
        )
        let model = AppModel(service: service)

        await model.start()
        XCTAssertEqual(model.libraries, .failed(.libraryUnavailable))

        await service.setLibraries(.success([library]))
        await service.setFirstPage(
            .success(fixturePage(libraryID: library.id))
        )
        await model.loadLibraries()

        XCTAssertEqual(model.libraries, .loaded([library]))
        XCTAssertEqual(model.selectedLibrary, library)
    }

    func testSelectingLibraryHandlesPageFailure() async throws {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            firstPage: .failure(
                .libraryRepository(.remote(.invalidPage))
            )
        )
        let model = AppModel(service: service)

        await model.start()
        await model.selectLibrary(fixtureLibrary())

        XCTAssertEqual(model.books, .failed(.libraryUnavailable))
    }

    func testLoadingWithoutAccountUsesTypedFailure() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.loadLibraries()
        XCTAssertEqual(model.libraries, .failed(.accountUnavailable))

        await model.selectLibrary(fixtureLibrary())
        XCTAssertEqual(model.books, .failed(.accountUnavailable))

        await model.removeAccount()
        XCTAssertEqual(
            model.accountActionStatus,
            .failed(.accountUnavailable)
        )
    }

    func testRemoveAccountClearsSignedInState() async throws {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([])
        )
        let model = AppModel(service: service)
        await model.start()

        await model.removeAccount()

        let removedAccounts = await service.removedAccounts()
        XCTAssertEqual(removedAccounts, [account])
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.account)
        XCTAssertNil(model.selectedLibrary)
        XCTAssertEqual(model.libraries, .idle)
        XCTAssertEqual(model.books, .idle)
        XCTAssertEqual(model.accountActionStatus, .idle)
    }

    func testRemoveAccountFailurePreservesSignedInState() async throws {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([]),
            removeAccount: .failure(
                .accountRemoval(.logoutRequestFailed)
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.removeAccount()

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(
            model.accountActionStatus,
            .failed(.accountRemovalFailed)
        )
    }

    func testConcurrentAccountRemovalIsIgnored() async throws {
        let account = try fixtureAccount()
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([]),
            removeGate: gate
        )
        let model = AppModel(service: service)
        await model.start()

        let firstRemoval = Task { @MainActor in
            await model.removeAccount()
        }
        await gate.waitUntilEntered()

        await model.removeAccount()
        await gate.release()
        await firstRemoval.value

        let removalCount = await service.removedAccounts().count
        XCTAssertEqual(removalCount, 1)
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testServiceErrorsMapToStablePresentationFailures() {
        let cases: [(AppServiceError, AppFailure)] = [
            (.invalidServerURL(.empty), .invalidServerAddress),
            (
                .invalidServerURL(.unsupportedScheme("http")),
                .serverRequiresHTTPS
            ),
            (.discovery(.uninitialized), .serverNotReady),
            (
                .discovery(.unsupportedServerVersion("2.25.0")),
                .serverUnsupported
            ),
            (
                .discovery(.invalidServerVersion("not-a-version")),
                .serverUnsupported
            ),
            (
                .discovery(.unexpectedHTTPStatus(500)),
                .serverUnavailable
            ),
            (.discoveryRequestFailed, .serverUnavailable),
            (
                .onboarding(.localAuthenticationUnavailable),
                .localLoginUnavailable
            ),
            (
                .onboarding(
                    .authenticationFailed(.invalidCredentials)
                ),
                .invalidCredentials
            ),
            (
                .onboarding(
                    .authenticationFailed(.malformedLoginResponse)
                ),
                .loginFailed
            ),
            (
                .onboarding(.authenticationRequestFailed),
                .loginFailed
            ),
            (.accountStore(.persistenceFailed), .accountUnavailable),
            (
                .libraryRepository(.noCachedValue),
                .libraryUnavailable
            ),
            (.pageRequest(.invalidPage), .libraryUnavailable),
            (
                .accountRemoval(.logoutRequestFailed),
                .accountRemovalFailed
            ),
            (
                .libraryCache(.persistenceFailed),
                .accountRemovalFailed
            ),
        ]

        for (error, expected) in cases {
            XCTAssertEqual(
                AppFailure(serviceError: error),
                expected,
                "Unexpected mapping for \(error)"
            )
        }
    }

    func testPresentationFailuresHaveUserMessages() {
        let failures: [AppFailure] = [
            .persistenceUnavailable,
            .invalidServerAddress,
            .serverUnavailable,
            .serverRequiresHTTPS,
            .serverNotReady,
            .serverUnsupported,
            .localLoginUnavailable,
            .invalidCredentials,
            .loginFailed,
            .accountUnavailable,
            .libraryUnavailable,
            .accountRemovalFailed,
        ]

        XCTAssertTrue(failures.allSatisfy { !$0.message.isEmpty })
        XCTAssertEqual(Set(failures.map(\.message)).count, failures.count)
    }

    private func fixtureAccount() throws -> ServerAccount {
        try ServerAccount(
            id: AccountID(rawValue: "account-1"),
            server: NormalizedServerURL("https://books.example"),
            serverVersion: "2.36.0",
            authenticationMethods: [.local],
            user: AuthenticatedUser(
                id: UserID(rawValue: "user-1"),
                username: "reader",
                type: .user,
                permissions: UserPermissions(
                    download: true,
                    update: false,
                    delete: false,
                    upload: false,
                    createEReader: false,
                    accessAllLibraries: true,
                    accessAllTags: true,
                    accessExplicitContent: true,
                    selectedTagsNotAccessible: false
                ),
                accessibleLibraryIDs: [],
                selectedItemTags: []
            )
        )
    }

    private func fixtureLibrary() -> LibrarySummary {
        LibrarySummary(
            id: LibraryID(rawValue: "library-1"),
            name: "Audiobooks",
            mediaType: .book
        )
    }

    private func fixturePage(libraryID: LibraryID) -> LibraryItemsPage {
        LibraryItemsPage(
            items: [
                LibraryBookSummary(
                    id: LibraryItemID(rawValue: "item-1"),
                    libraryID: libraryID,
                    title: "A Book",
                    subtitle: nil,
                    authorName: "An Author",
                    narratorName: "A Narrator",
                    seriesName: nil,
                    genres: ["Fiction"],
                    publisher: nil,
                    publishedYear: "2026",
                    duration: 3_600,
                    trackCount: 1,
                    chapterCount: 2,
                    addedAtMilliseconds: 1,
                    updatedAtMilliseconds: 2,
                    isExplicit: false,
                    isAbridged: false
                )
            ],
            total: 1,
            page: 0,
            limit: 50
        )
    }
}

private struct LoginRequest: Equatable, Sendable {
    let serverAddress: String
    let username: String
    let password: String
}

private actor TestAppService: AppServicing {
    private var activeAccountResult:
        Result<
            ServerAccount?,
            AppServiceError
        >
    private var loginResult: Result<ServerAccount, AppServiceError>
    private var librariesResult:
        Result<
            [LibrarySummary],
            AppServiceError
        >
    private var firstPageResult:
        Result<
            LibraryItemsPage,
            AppServiceError
        >
    private var removeAccountResult: Result<Void, AppServiceError>
    private let loginGate: AsyncGate?
    private let removeGate: AsyncGate?

    private var activeAccountRequests = 0
    private var recordedLogins: [LoginRequest] = []
    private var recordedPageRequests: [LibraryID] = []
    private var recordedRemovedAccounts: [ServerAccount] = []

    init(
        activeAccount: Result<ServerAccount?, AppServiceError>,
        login: Result<ServerAccount, AppServiceError> = .failure(
            .onboarding(.authenticationRequestFailed)
        ),
        libraries: Result<[LibrarySummary], AppServiceError> = .success([]),
        firstPage: Result<LibraryItemsPage, AppServiceError> = .failure(
            .libraryRepository(.noCachedValue)
        ),
        removeAccount: Result<Void, AppServiceError> = .success(()),
        loginGate: AsyncGate? = nil,
        removeGate: AsyncGate? = nil
    ) {
        activeAccountResult = activeAccount
        loginResult = login
        librariesResult = libraries
        firstPageResult = firstPage
        removeAccountResult = removeAccount
        self.loginGate = loginGate
        self.removeGate = removeGate
    }

    func activeAccount()
        async throws(AppServiceError) -> ServerAccount?
    {
        activeAccountRequests += 1
        return try value(from: activeAccountResult)
    }

    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async throws(AppServiceError) -> ServerAccount {
        recordedLogins.append(
            LoginRequest(
                serverAddress: serverAddress,
                username: username,
                password: password
            )
        )
        if let loginGate {
            await loginGate.enterAndWait()
        }
        return try value(from: loginResult)
    }

    func libraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary] {
        try value(from: librariesResult)
    }

    func firstPage(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> LibraryItemsPage {
        recordedPageRequests.append(libraryID)
        return try value(from: firstPageResult)
    }

    func removeAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        recordedRemovedAccounts.append(account)
        if let removeGate {
            await removeGate.enterAndWait()
        }
        try value(from: removeAccountResult)
    }

    func setLibraries(
        _ result: Result<[LibrarySummary], AppServiceError>
    ) {
        librariesResult = result
    }

    func setFirstPage(
        _ result: Result<LibraryItemsPage, AppServiceError>
    ) {
        firstPageResult = result
    }

    func activeAccountRequestCount() -> Int {
        activeAccountRequests
    }

    func loginRequests() -> [LoginRequest] {
        recordedLogins
    }

    func pageRequests() -> [LibraryID] {
        recordedPageRequests
    }

    func removedAccounts() -> [ServerAccount] {
        recordedRemovedAccounts
    }

    private func value<Value: Sendable>(
        from result: Result<Value, AppServiceError>
    ) throws(AppServiceError) -> Value {
        switch result {
        case .success(let value):
            value
        case .failure(let error):
            throw error
        }
    }
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let continuations = enteredContinuations
        enteredContinuations.removeAll()
        continuations.forEach { $0.resume() }

        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }
}
