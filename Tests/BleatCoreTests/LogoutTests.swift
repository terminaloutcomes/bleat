import Foundation
import XCTest

@testable import BleatCore

final class LogoutTests: XCTestCase {
    func testOnlineLogoutUsesRefreshHeaderAndClearsCredentials() async throws {
        let accountID = AccountID(rawValue: "account")
        let server = try NormalizedServerURL("https://example.com/prefix")
        let tokens = try AuthenticationTokens(
            accessToken: "access",
            refreshToken: "refresh"
        )
        let store = LogoutCredentialStore(
            credentials: [accountID: tokens]
        )
        let transport = LogoutScriptedTransport(
            responses: [
                .success(
                    .init(
                        data: Data(#"{"redirect_url":null}"#.utf8),
                        statusCode: 200
                    ))
            ]
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        let result = try await coordinator.logout(
            accountID: accountID,
            server: server
        )
        let recordedRequest = await transport.recordedRequests().first
        let request = try XCTUnwrap(recordedRequest)
        let storedCredentials = try await store.credentials(for: accountID)
        let deleteCount = await store.deleteCount()
        let requiresReauthentication =
            await coordinator.requiresReauthentication(for: accountID)

        XCTAssertEqual(result.remoteStatus, .completed)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.com/prefix/logout"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-refresh-token"),
            "refresh"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.url?.query)
        XCTAssertNil(storedCredentials)
        XCTAssertEqual(deleteCount, 1)
        XCTAssertFalse(requiresReauthentication)

        let secondResult = try await coordinator.logout(
            accountID: accountID,
            server: server
        )
        let requestCount = await transport.requestCount()
        let secondDeleteCount = await store.deleteCount()
        XCTAssertEqual(secondResult.remoteStatus, .noCredentials)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(secondDeleteCount, 2)
    }

    func testRemoteFailuresStillDeleteLocalCredentials() async throws {
        let scenarios:
            [(
                Result<HTTPResponse, LogoutTestError>,
                RemoteLogoutStatus
            )] = [
                (.failure(.transport), .requestFailed),
                (
                    .success(.init(data: Data(), statusCode: 401)),
                    .rejected(401)
                ),
                (
                    .success(.init(data: Data(), statusCode: 503)),
                    .rejected(503)
                ),
            ]

        for (response, expectedStatus) in scenarios {
            let fixture = try LogoutFixture(responses: [response])

            let result = try await fixture.coordinator.logout(
                accountID: fixture.accountID,
                server: fixture.server
            )
            let storedCredentials = try await fixture.store.credentials(
                for: fixture.accountID
            )
            let deleteCount = await fixture.store.deleteCount()

            XCTAssertEqual(result.remoteStatus, expectedStatus)
            XCTAssertNil(storedCredentials)
            XCTAssertEqual(deleteCount, 1)
        }
    }

    func testMissingOrUnreadableCredentialsStillRunDeletion() async throws {
        let missingFixture = try LogoutFixture(
            responses: [],
            includeCredentials: false
        )
        let missingResult = try await missingFixture.coordinator.logout(
            accountID: missingFixture.accountID,
            server: missingFixture.server
        )
        let missingRequestCount =
            await missingFixture.transport.requestCount()
        let missingDeleteCount = await missingFixture.store.deleteCount()
        XCTAssertEqual(missingResult.remoteStatus, .noCredentials)
        XCTAssertEqual(missingRequestCount, 0)
        XCTAssertEqual(missingDeleteCount, 1)

        let unreadableFixture = try LogoutFixture(
            responses: [],
            readFails: true
        )
        let unreadableResult = try await unreadableFixture.coordinator.logout(
            accountID: unreadableFixture.accountID,
            server: unreadableFixture.server
        )
        let unreadableRequestCount =
            await unreadableFixture.transport.requestCount()
        let unreadableDeleteCount =
            await unreadableFixture.store.deleteCount()
        XCTAssertEqual(
            unreadableResult.remoteStatus,
            .credentialsUnavailable
        )
        XCTAssertEqual(unreadableRequestCount, 0)
        XCTAssertEqual(unreadableDeleteCount, 1)
    }

    func testCredentialDeletionFailureIsTypedAndRequiresReauthentication()
        async throws
    {
        let fixture = try LogoutFixture(
            responses: [
                .success(.init(data: Data(), statusCode: 200))
            ],
            deleteFails: true
        )

        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator.logout(
                accountID: fixture.accountID,
                server: fixture.server
            )
        ) { error in
            XCTAssertEqual(
                error as? LogoutError,
                .credentialDeletionFailed
            )
        }
        let storedCredentials = try await fixture.store.credentials(
            for: fixture.accountID
        )
        let requiresReauthentication =
            await fixture.coordinator.requiresReauthentication(
                for: fixture.accountID
            )
        XCTAssertNotNil(storedCredentials)
        XCTAssertTrue(requiresReauthentication)
    }

    func testInvalidAccountDoesNotReadDeleteOrSend() async throws {
        let fixture = try LogoutFixture(responses: [])

        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator.logout(
                accountID: AccountID(rawValue: ""),
                server: fixture.server
            )
        ) { error in
            XCTAssertEqual(error as? LogoutError, .invalidAccountID)
        }

        let readCount = await fixture.store.readCount()
        let deleteCount = await fixture.store.deleteCount()
        let requestCount = await fixture.transport.requestCount()
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(deleteCount, 0)
        XCTAssertEqual(requestCount, 0)
    }

    func testConcurrentLogoutAndAuthenticatedRequestAreRejected() async throws {
        let accountID = AccountID(rawValue: "account")
        let server = try NormalizedServerURL("https://example.com")
        let store = LogoutCredentialStore(
            credentials: [
                accountID: try AuthenticationTokens(
                    accessToken: "access",
                    refreshToken: "refresh"
                )
            ]
        )
        let transport = BlockingLogoutTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let firstLogout = Task {
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilLogoutStarts()

        await XCTAssertThrowsErrorAsync(
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        ) { error in
            XCTAssertEqual(
                error as? LogoutError,
                .accountOperationInProgress
            )
        }

        let librariesRequest = URLRequest(
            url: try AudiobookshelfRouteBuilder(server: server)
                .url(for: .libraries)
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.sendAuthenticated(
                librariesRequest,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .accountOperationInProgress
            )
        }

        await transport.completeLogout()
        let result = try await firstLogout.value
        XCTAssertEqual(result.remoteStatus, .completed)
    }

    func testLogoutRejectsAnOverlappingLocalLogin() async throws {
        let accountID = AccountID(rawValue: "account")
        let server = try NormalizedServerURL("https://example.com")
        let store = LogoutCredentialStore(credentials: [:])
        let transport = BlockingLoginTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let login = Task {
            try await coordinator.login(
                accountID: accountID,
                server: server,
                username: "reader",
                password: "password"
            )
        }
        await transport.waitUntilLoginStarts()

        await XCTAssertThrowsErrorAsync(
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        ) { error in
            XCTAssertEqual(
                error as? LogoutError,
                .accountOperationInProgress
            )
        }
        await XCTAssertThrowsErrorAsync(
            try await coordinator.login(
                accountID: accountID,
                server: server,
                username: "reader",
                password: "password"
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalAuthenticationError,
                .accountOperationInProgress
            )
        }

        await transport.rejectLogin()
        await XCTAssertThrowsErrorAsync(
            try await login.value
        ) { error in
            XCTAssertEqual(
                error as? LocalAuthenticationError,
                .invalidCredentials
            )
        }
    }

    func testLogoutSettlesRefreshAndInvalidatesTheRotatedToken() async throws {
        let accountID = AccountID(rawValue: "account")
        let server = try NormalizedServerURL("https://example.com")
        let store = LogoutCredentialStore(
            credentials: [
                accountID: try AuthenticationTokens(
                    accessToken: "expired-access",
                    refreshToken: "refresh"
                )
            ]
        )
        let transport = RefreshRaceTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let librariesRequest = URLRequest(
            url: try AudiobookshelfRouteBuilder(server: server)
                .url(for: .libraries)
        )
        let authenticatedRequest = Task {
            try await coordinator.sendAuthenticated(
                librariesRequest,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilRefreshStarts()

        let logout = Task {
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        }
        for _ in 0..<1_000 {
            if await coordinator.isSigningOut(accountID: accountID) {
                break
            }
            await Task.yield()
        }
        let logoutStarted = await coordinator.isSigningOut(
            accountID: accountID
        )
        XCTAssertTrue(logoutStarted)
        await transport.completeRefresh()

        let logoutResult = try await logout.value
        await XCTAssertThrowsErrorAsync(
            try await authenticatedRequest.value
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .accountOperationInProgress
            )
        }
        let storedCredentials = try await store.credentials(for: accountID)
        let counts = await transport.counts()
        let logoutRefreshToken = await transport.logoutRefreshToken()

        XCTAssertEqual(logoutResult.remoteStatus, .completed)
        XCTAssertNil(storedCredentials)
        XCTAssertEqual(counts.refreshRequests, 1)
        XCTAssertEqual(counts.logoutRequests, 1)
        XCTAssertEqual(logoutRefreshToken, "rotated-refresh")
    }

    func testRequestCannotStartRefreshAfterLogoutBegins() async throws {
        let accountID = AccountID(rawValue: "account")
        let server = try NormalizedServerURL("https://example.com")
        let store = LogoutCredentialStore(
            credentials: [
                accountID: try AuthenticationTokens(
                    accessToken: "expired-access",
                    refreshToken: "refresh"
                )
            ]
        )
        let transport = InitialRequestRaceTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let librariesRequest = URLRequest(
            url: try AudiobookshelfRouteBuilder(server: server)
                .url(for: .libraries)
        )
        let authenticatedRequest = Task {
            try await coordinator.sendAuthenticated(
                librariesRequest,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilInitialRequestStarts()
        let logout = Task {
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilLogoutStarts()
        await transport.rejectInitialRequest()

        await XCTAssertThrowsErrorAsync(
            try await authenticatedRequest.value
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .accountOperationInProgress
            )
        }
        await transport.completeLogout()
        let logoutResult = try await logout.value
        let refreshCount = await transport.refreshCount()

        XCTAssertEqual(logoutResult.remoteStatus, .completed)
        XCTAssertEqual(refreshCount, 0)
    }

    func testSuccessfulResponseStartedBeforeCompletedLogoutIsInvalidated()
        async throws
    {
        let accountID = AccountID(rawValue: "account")
        let server = try NormalizedServerURL("https://example.com")
        let store = LogoutCredentialStore(
            credentials: [
                accountID: try AuthenticationTokens(
                    accessToken: "access",
                    refreshToken: "refresh"
                )
            ]
        )
        let transport = InitialRequestRaceTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let librariesRequest = URLRequest(
            url: try AudiobookshelfRouteBuilder(server: server)
                .url(for: .libraries)
        )
        let authenticatedRequest = Task {
            try await coordinator.sendAuthenticated(
                librariesRequest,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilInitialRequestStarts()

        let logout = Task {
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilLogoutStarts()
        await transport.completeLogout()
        let logoutResult = try await logout.value
        await transport.completeInitial(statusCode: 200)

        await XCTAssertThrowsErrorAsync(
            try await authenticatedRequest.value
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .accountOperationInProgress
            )
        }
        XCTAssertEqual(logoutResult.remoteStatus, .completed)
    }

    fileprivate static func authenticationJSON(
        accessToken: String,
        refreshToken: String
    ) -> Data {
        Data(
            """
            {
              "user": {
                "id": "user-id",
                "username": "reader",
                "type": "root",
                "permissions": {
                  "download": true,
                  "update": true,
                  "delete": true,
                  "upload": true,
                  "createEreader": true,
                  "accessAllLibraries": true,
                  "accessAllTags": true,
                  "accessExplicitContent": true,
                  "selectedTagsNotAccessible": false
                },
                "librariesAccessible": [],
                "itemTagsSelected": [],
                "accessToken": "\(accessToken)",
                "refreshToken": "\(refreshToken)"
              }
            }
            """.utf8
        )
    }
}

private struct LogoutFixture {
    let accountID = AccountID(rawValue: "account")
    let server: NormalizedServerURL
    let store: LogoutCredentialStore
    let transport: LogoutScriptedTransport
    let coordinator:
        AuthCoordinator<
            LogoutScriptedTransport,
            LogoutCredentialStore
        >

    init(
        responses: [Result<HTTPResponse, LogoutTestError>],
        includeCredentials: Bool = true,
        readFails: Bool = false,
        deleteFails: Bool = false
    ) throws {
        server = try NormalizedServerURL("https://example.com")
        let tokens = try AuthenticationTokens(
            accessToken: "access",
            refreshToken: "refresh"
        )
        store = LogoutCredentialStore(
            credentials: includeCredentials ? [accountID: tokens] : [:],
            readFails: readFails,
            deleteFails: deleteFails
        )
        transport = LogoutScriptedTransport(responses: responses)
        coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
    }
}

private actor LogoutCredentialStore: AccountCredentialStore {
    private var stored: [AccountID: AuthenticationTokens]
    private let readFails: Bool
    private let deleteFails: Bool
    private var reads = 0
    private var deletes = 0

    init(
        credentials: [AccountID: AuthenticationTokens],
        readFails: Bool = false,
        deleteFails: Bool = false
    ) {
        stored = credentials
        self.readFails = readFails
        self.deleteFails = deleteFails
    }

    func credentials(
        for accountID: AccountID
    ) throws -> AuthenticationTokens? {
        reads += 1
        if readFails {
            throw LogoutTestError.store
        }
        return stored[accountID]
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        stored[accountID] = credentials
    }

    func deleteCredentials(for accountID: AccountID) throws {
        deletes += 1
        if deleteFails {
            throw LogoutTestError.store
        }
        stored[accountID] = nil
    }

    func readCount() -> Int {
        reads
    }

    func deleteCount() -> Int {
        deletes
    }
}

private actor LogoutScriptedTransport: HTTPTransport {
    private var responses: [Result<HTTPResponse, LogoutTestError>]
    private var requests: [URLRequest] = []

    init(responses: [Result<HTTPResponse, LogoutTestError>]) {
        self.responses = responses
    }

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) throws -> HTTPResponse {
        let request = tracedRequest.request
        requests.append(request)
        guard !responses.isEmpty else {
            throw LogoutTestError.missingResponse
        }
        return try responses.removeFirst().get()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func requestCount() -> Int {
        requests.count
    }
}

private actor BlockingLogoutTransport: HTTPTransport {
    private var logoutContinuation: CheckedContinuation<HTTPResponse, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async -> HTTPResponse {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            logoutContinuation = continuation
        }
    }

    func waitUntilLogoutStarts() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func completeLogout() {
        logoutContinuation?.resume(
            returning: .init(data: Data(), statusCode: 200)
        )
        logoutContinuation = nil
    }
}

private actor BlockingLoginTransport: HTTPTransport {
    private var loginContinuation: CheckedContinuation<HTTPResponse, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async -> HTTPResponse {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            loginContinuation = continuation
        }
    }

    func waitUntilLoginStarts() async {
        if started {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func rejectLogin() {
        loginContinuation?.resume(
            returning: .init(data: Data(), statusCode: 401)
        )
        loginContinuation = nil
    }
}

private actor RefreshRaceTransport: HTTPTransport {
    private var refreshContinuation: CheckedContinuation<HTTPResponse, Never>?
    private var refreshStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshStarted = false
    private var refreshRequests = 0
    private var logoutRequests = 0
    private var recordedLogoutRefreshToken: String?

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async -> HTTPResponse {
        let request = tracedRequest.request
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            refreshRequests += 1
            refreshStarted = true
            let waiters = refreshStartWaiters
            refreshStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }

            return await withCheckedContinuation { continuation in
                refreshContinuation = continuation
            }
        }
        if request.url?.path.hasSuffix("/logout") == true {
            logoutRequests += 1
            recordedLogoutRefreshToken = request.value(
                forHTTPHeaderField: "x-refresh-token"
            )
            return .init(data: Data(), statusCode: 200)
        }
        if request.value(forHTTPHeaderField: "Authorization")
            == "Bearer rotated-access"
        {
            return .init(data: Data(), statusCode: 200)
        }
        return .init(data: Data(), statusCode: 401)
    }

    func waitUntilRefreshStarts() async {
        if refreshStarted {
            return
        }
        await withCheckedContinuation { continuation in
            refreshStartWaiters.append(continuation)
        }
    }

    func completeRefresh() {
        refreshContinuation?.resume(
            returning: .init(
                data: LogoutTests.authenticationJSON(
                    accessToken: "rotated-access",
                    refreshToken: "rotated-refresh"
                ),
                statusCode: 200
            )
        )
        refreshContinuation = nil
    }

    func counts() -> (
        refreshRequests: Int,
        logoutRequests: Int
    ) {
        (refreshRequests, logoutRequests)
    }

    func logoutRefreshToken() -> String? {
        recordedLogoutRefreshToken
    }
}

private actor InitialRequestRaceTransport: HTTPTransport {
    private var initialRequestContinuation:
        CheckedContinuation<HTTPResponse, Never>?
    private var logoutContinuation: CheckedContinuation<HTTPResponse, Never>?
    private var initialStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var logoutStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var initialStarted = false
    private var logoutStarted = false
    private var refreshRequests = 0

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async -> HTTPResponse {
        let request = tracedRequest.request
        if request.url?.path.hasSuffix("/logout") == true {
            logoutStarted = true
            let waiters = logoutStartWaiters
            logoutStartWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return await withCheckedContinuation { continuation in
                logoutContinuation = continuation
            }
        }
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            refreshRequests += 1
            return .init(data: Data(), statusCode: 500)
        }

        initialStarted = true
        let waiters = initialStartWaiters
        initialStartWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return await withCheckedContinuation { continuation in
            initialRequestContinuation = continuation
        }
    }

    func waitUntilInitialRequestStarts() async {
        if initialStarted {
            return
        }
        await withCheckedContinuation { continuation in
            initialStartWaiters.append(continuation)
        }
    }

    func waitUntilLogoutStarts() async {
        if logoutStarted {
            return
        }
        await withCheckedContinuation { continuation in
            logoutStartWaiters.append(continuation)
        }
    }

    func rejectInitialRequest() {
        completeInitial(statusCode: 401)
    }

    func completeInitial(statusCode: Int) {
        initialRequestContinuation?.resume(
            returning: .init(data: Data(), statusCode: statusCode)
        )
        initialRequestContinuation = nil
    }

    func completeLogout() {
        logoutContinuation?.resume(
            returning: .init(data: Data(), statusCode: 200)
        )
        logoutContinuation = nil
    }

    func refreshCount() -> Int {
        refreshRequests
    }
}

private enum LogoutTestError: Error {
    case missingResponse
    case store
    case transport
}
