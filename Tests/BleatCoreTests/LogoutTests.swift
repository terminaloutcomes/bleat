import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class LogoutTests {
    @Test
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
                        data: Data(
                            #"{"redirect_url":"https://id.example/logout"}"#
                                .utf8
                        ),
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
        let request = try #require(recordedRequest)
        let storedCredentials = try await store.credentials(for: accountID)
        let deleteCount = await store.deleteCount()
        let requiresReauthentication =
            await coordinator.requiresReauthentication(for: accountID)

        #expect(result.remoteStatus == .completed)
        #expect(
            result.providerLogoutURL?.absoluteString
                == "https://id.example/logout")
        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString == "https://example.com/prefix/logout")
        #expect(
            request.value(forHTTPHeaderField: "x-refresh-token") == "refresh")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.query == nil)
        #expect(storedCredentials == nil)
        #expect(deleteCount == 1)
        #expect(!(requiresReauthentication))

        let secondResult = try await coordinator.logout(
            accountID: accountID,
            server: server
        )
        let requestCount = await transport.requestCount()
        let secondDeleteCount = await store.deleteCount()
        #expect(secondResult.remoteStatus == .noCredentials)
        #expect(secondResult.providerLogoutURL == nil)
        #expect(requestCount == 1)
        #expect(secondDeleteCount == 2)
    }

    @Test
    func testLogoutRejectsUnsafeProviderRedirectWithoutBlockingCleanup()
        async throws
    {
        let fixture = try LogoutFixture(
            responses: [
                .success(
                    .init(
                        data: Data(
                            #"{"redirect_url":"http://id.example/logout"}"#.utf8
                        ),
                        statusCode: 200
                    )
                )
            ]
        )

        let result = try await fixture.coordinator.logout(
            accountID: fixture.accountID,
            server: fixture.server
        )

        #expect(result.remoteStatus == .completed)
        #expect(result.providerLogoutURL == nil)
        let credentials = try await fixture.store.credentials(
            for: fixture.accountID
        )
        #expect(credentials == nil)
    }

    @Test
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

            #expect(result.remoteStatus == expectedStatus)
            #expect(storedCredentials == nil)
            #expect(deleteCount == 1)
        }
    }

    @Test
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
        #expect(missingResult.remoteStatus == .noCredentials)
        #expect(missingRequestCount == 0)
        #expect(missingDeleteCount == 1)

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
        #expect(unreadableResult.remoteStatus == .credentialsUnavailable)
        #expect(unreadableRequestCount == 0)
        #expect(unreadableDeleteCount == 1)
    }

    @Test
    func testCredentialDeletionFailureIsTypedAndRequiresReauthentication()
        async throws
    {
        let fixture = try LogoutFixture(
            responses: [
                .success(.init(data: Data(), statusCode: 200))
            ],
            deleteFails: true
        )

        await assertThrowsErrorAsync(
            try await fixture.coordinator.logout(
                accountID: fixture.accountID,
                server: fixture.server
            )
        ) { error in
            #expect(error as? LogoutError == .credentialDeletionFailed)
        }
        let storedCredentials = try await fixture.store.credentials(
            for: fixture.accountID
        )
        let requiresReauthentication =
            await fixture.coordinator.requiresReauthentication(
                for: fixture.accountID
            )
        #expect(storedCredentials != nil)
        #expect(requiresReauthentication)
    }

    @Test
    func testInvalidAccountDoesNotReadDeleteOrSend() async throws {
        let fixture = try LogoutFixture(responses: [])

        await assertThrowsErrorAsync(
            try await fixture.coordinator.logout(
                accountID: AccountID(rawValue: ""),
                server: fixture.server
            )
        ) { error in
            #expect(error as? LogoutError == .invalidAccountID)
        }

        let readCount = await fixture.store.readCount()
        let deleteCount = await fixture.store.deleteCount()
        let requestCount = await fixture.transport.requestCount()
        #expect(readCount == 0)
        #expect(deleteCount == 0)
        #expect(requestCount == 0)
    }

    @Test
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
        #expect(await transport.waitUntilLogoutStarts())

        await assertThrowsErrorAsync(
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        ) { error in
            #expect(error as? LogoutError == .accountOperationInProgress)
        }

        let librariesRequest = URLRequest(
            url: try AudiobookshelfRouteBuilder(server: server)
                .url(for: .libraries)
        )
        await assertThrowsErrorAsync(
            try await coordinator.sendAuthenticated(
                librariesRequest,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        ) { error in
            #expect(
                error as? AuthenticatedRequestError
                    == .accountOperationInProgress)
        }

        await transport.completeLogout()
        let result = try await firstLogout.value
        #expect(result.remoteStatus == .completed)
    }

    @Test
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
        #expect(await transport.waitUntilLoginStarts())

        await assertThrowsErrorAsync(
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        ) { error in
            #expect(error as? LogoutError == .accountOperationInProgress)
        }
        await assertThrowsErrorAsync(
            try await coordinator.login(
                accountID: accountID,
                server: server,
                username: "reader",
                password: "password"
            )
        ) { error in
            #expect(
                error as? LocalAuthenticationError
                    == .accountOperationInProgress)
        }

        await transport.rejectLogin()
        await assertThrowsErrorAsync(
            try await login.value
        ) { error in
            #expect(error as? LocalAuthenticationError == .invalidCredentials)
        }
    }

    @Test
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
        let authenticatedRequestCompletion =
            AuthTelemetryTestCompletion<
                Result<HTTPResponse, AuthenticatedRequestError>
            >()
        let authenticatedRequestTask = Task {
            let outcome: Result<HTTPResponse, AuthenticatedRequestError>
            do {
                outcome = .success(
                    try await coordinator.sendAuthenticated(
                        librariesRequest,
                        route: .libraries,
                        accountID: accountID,
                        server: server
                    )
                )
            } catch let error as AuthenticatedRequestError {
                outcome = .failure(error)
            } catch {
                Issue.record(
                    "Authenticated request returned an unexpected error")
                outcome = .failure(.requestTransportFailed)
            }
            await authenticatedRequestCompletion.complete(outcome)
        }
        #expect(await transport.waitUntilRefreshStarts())

        let logoutCompletion = AuthTelemetryTestCompletion<
            Result<LogoutResult, LogoutError>
        >()
        let logoutTask = Task {
            let outcome: Result<LogoutResult, LogoutError>
            do {
                outcome = .success(
                    try await coordinator.logout(
                        accountID: accountID,
                        server: server
                    )
                )
            } catch let error as LogoutError {
                outcome = .failure(error)
            } catch {
                Issue.record("Logout returned an unexpected error")
                outcome = .failure(.credentialDeletionFailed)
            }
            await logoutCompletion.complete(outcome)
        }
        let signingOutReached = await requireAuthTelemetryCondition(
            stage: "logout signing-out state",
            timeout: .seconds(30)
        ) {
            await coordinator.isSigningOut(accountID: accountID)
        }
        #expect(signingOutReached)
        await transport.completeRefresh()

        let logoutOutcome = await requireAuthTelemetryCompletion(
            logoutCompletion,
            stage: "logout completion after refresh release",
            timeout: .seconds(30)
        )
        let requestOutcome = await requireAuthTelemetryCompletion(
            authenticatedRequestCompletion,
            stage: "authenticated request completion after logout",
            timeout: .seconds(30)
        )
        guard let logoutOutcome, let requestOutcome else {
            authenticatedRequestTask.cancel()
            logoutTask.cancel()
            await transport.completeRefresh()
            let requestCleanup = await requireAuthTelemetryCompletion(
                authenticatedRequestCompletion,
                stage: "authenticated request cancellation cleanup",
                timeout: .seconds(5)
            )
            let logoutCleanup = await requireAuthTelemetryCompletion(
                logoutCompletion,
                stage: "logout cancellation cleanup",
                timeout: .seconds(5)
            )
            if requestCleanup != nil {
                await authenticatedRequestTask.value
            }
            if logoutCleanup != nil {
                await logoutTask.value
            }
            return
        }
        await authenticatedRequestTask.value
        await logoutTask.value
        let logoutResult = try logoutOutcome.get()
        switch requestOutcome {
        case .success:
            Issue.record(
                "Authenticated request should be rejected during logout")
        case .failure(let error):
            #expect(error == .accountOperationInProgress)
        }
        let storedCredentials = try await store.credentials(for: accountID)
        let counts = await transport.counts()
        let logoutRefreshToken = await transport.logoutRefreshToken()

        #expect(logoutResult.remoteStatus == .completed)
        #expect(storedCredentials == nil)
        #expect(counts.refreshRequests == 1)
        #expect(counts.logoutRequests == 1)
        #expect(logoutRefreshToken == "rotated-refresh")
    }

    @Test
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
        #expect(await transport.waitUntilInitialRequestStarts())
        let logout = Task {
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        }
        #expect(await transport.waitUntilLogoutStarts())
        await transport.rejectInitialRequest()

        await assertThrowsErrorAsync(
            try await authenticatedRequest.value
        ) { error in
            #expect(
                error as? AuthenticatedRequestError
                    == .accountOperationInProgress)
        }
        await transport.completeLogout()
        let logoutResult = try await logout.value
        let refreshCount = await transport.refreshCount()

        #expect(logoutResult.remoteStatus == .completed)
        #expect(refreshCount == 0)
    }

    @Test
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
        #expect(await transport.waitUntilInitialRequestStarts())

        let logout = Task {
            try await coordinator.logout(
                accountID: accountID,
                server: server
            )
        }
        #expect(await transport.waitUntilLogoutStarts())
        await transport.completeLogout()
        let logoutResult = try await logout.value
        await transport.completeInitial(statusCode: 200)

        await assertThrowsErrorAsync(
            try await authenticatedRequest.value
        ) { error in
            #expect(
                error as? AuthenticatedRequestError
                    == .accountOperationInProgress)
        }
        #expect(logoutResult.remoteStatus == .completed)
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
    nonisolated let logoutStartedSignal = AuthTelemetryTestSignal()
    private var started = false
    private var completionReleased = false

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async -> HTTPResponse {
        started = true
        await logoutStartedSignal.signal()
        return await withCheckedContinuation { continuation in
            if completionReleased {
                continuation.resume(
                    returning: .init(data: Data(), statusCode: 200)
                )
            } else {
                logoutContinuation = continuation
            }
        }
    }

    func waitUntilLogoutStarts(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if started { return true }
        return await requireAuthTelemetrySignal(
            logoutStartedSignal,
            stage: "logout transport entry",
            sourceLocation: sourceLocation
        )
    }

    func completeLogout() {
        completionReleased = true
        logoutContinuation?.resume(
            returning: .init(data: Data(), statusCode: 200)
        )
        logoutContinuation = nil
    }
}

private actor BlockingLoginTransport: HTTPTransport {
    private var loginContinuation: CheckedContinuation<HTTPResponse, Never>?
    nonisolated let loginStartedSignal = AuthTelemetryTestSignal()
    private var started = false
    private var completionReleased = false

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async -> HTTPResponse {
        started = true
        await loginStartedSignal.signal()
        return await withCheckedContinuation { continuation in
            if completionReleased {
                continuation.resume(
                    returning: .init(data: Data(), statusCode: 401)
                )
            } else {
                loginContinuation = continuation
            }
        }
    }

    func waitUntilLoginStarts(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if started { return true }
        return await requireAuthTelemetrySignal(
            loginStartedSignal,
            stage: "login transport entry",
            sourceLocation: sourceLocation
        )
    }

    func rejectLogin() {
        completionReleased = true
        loginContinuation?.resume(
            returning: .init(data: Data(), statusCode: 401)
        )
        loginContinuation = nil
    }
}

private actor RefreshRaceTransport: HTTPTransport {
    private var refreshContinuation: CheckedContinuation<HTTPResponse, Never>?
    nonisolated let refreshStartedSignal = AuthTelemetryTestSignal()
    private var refreshStarted = false
    private var refreshReleased = false
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
            await refreshStartedSignal.signal()

            return await withCheckedContinuation { continuation in
                if refreshReleased {
                    continuation.resume(
                        returning: .init(
                            data: LogoutTests.authenticationJSON(
                                accessToken: "rotated-access",
                                refreshToken: "rotated-refresh"
                            ),
                            statusCode: 200
                        )
                    )
                } else {
                    refreshContinuation = continuation
                }
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

    func waitUntilRefreshStarts(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if refreshStarted { return true }
        return await requireAuthTelemetrySignal(
            refreshStartedSignal,
            stage: "refresh transport entry",
            sourceLocation: sourceLocation
        )
    }

    func completeRefresh() {
        refreshReleased = true
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
    nonisolated let initialStartedSignal = AuthTelemetryTestSignal()
    nonisolated let logoutStartedSignal = AuthTelemetryTestSignal()
    private var initialStarted = false
    private var logoutStarted = false
    private var initialRequestReleased = false
    private var logoutReleased = false
    private var refreshRequests = 0

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async -> HTTPResponse {
        let request = tracedRequest.request
        if request.url?.path.hasSuffix("/logout") == true {
            logoutStarted = true
            await logoutStartedSignal.signal()
            return await withCheckedContinuation { continuation in
                if logoutReleased {
                    continuation.resume(
                        returning: .init(data: Data(), statusCode: 200)
                    )
                } else {
                    logoutContinuation = continuation
                }
            }
        }
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            refreshRequests += 1
            return .init(data: Data(), statusCode: 500)
        }

        initialStarted = true
        await initialStartedSignal.signal()
        return await withCheckedContinuation { continuation in
            if initialRequestReleased {
                continuation.resume(
                    returning: .init(data: Data(), statusCode: 401)
                )
            } else {
                initialRequestContinuation = continuation
            }
        }
    }

    func waitUntilInitialRequestStarts(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if initialStarted { return true }
        return await requireAuthTelemetrySignal(
            initialStartedSignal,
            stage: "initial request transport entry",
            sourceLocation: sourceLocation
        )
    }

    func waitUntilLogoutStarts(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if logoutStarted { return true }
        return await requireAuthTelemetrySignal(
            logoutStartedSignal,
            stage: "logout transport entry",
            sourceLocation: sourceLocation
        )
    }

    func rejectInitialRequest() {
        completeInitial(statusCode: 401)
    }

    func completeInitial(statusCode: Int) {
        initialRequestReleased = true
        initialRequestContinuation?.resume(
            returning: .init(data: Data(), statusCode: statusCode)
        )
        initialRequestContinuation = nil
    }

    func completeLogout() {
        logoutReleased = true
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
