import Foundation
import XCTest

@testable import BleatCore

final class AuthenticatedRequestTests: XCTestCase {
    func testTwentyUnauthorizedRequestsShareOneRotatingRefresh() async throws {
        let accountID = AccountID(rawValue: "concurrent-account")
        let server = try NormalizedServerURL("https://example.net/prefix")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let newTokens = try AuthenticationTokens(
            accessToken: "new-access",
            refreshToken: "new-refresh"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: oldTokens]
        )
        let transport = ConcurrentRefreshTransport(
            unauthorizedRequestCount: 20,
            oldTokens: oldTokens,
            newTokens: newTokens
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let request = try Self.request(for: .libraries, server: server)

        let responses = try await withThrowingTaskGroup(
            of: HTTPResponse.self
        ) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    try await coordinator.sendAuthenticated(
                        request,
                        route: .libraries,
                        accountID: accountID,
                        server: server
                    )
                }
            }

            var responses: [HTTPResponse] = []
            for try await response in group {
                responses.append(response)
            }
            return responses
        }

        XCTAssertEqual(
            responses.map(\HTTPResponse.statusCode),
            Array(repeating: 200, count: 20)
        )
        let counts = await transport.counts()
        let storedTokens = try await store.credentials(for: accountID)
        let saveCount = await store.saveCount()
        let requiresReauthentication =
            await coordinator.requiresReauthentication(for: accountID)
        let recordedRefreshRequest = await transport.refreshRequest()
        XCTAssertEqual(counts.oldAccessRequests, 20)
        XCTAssertEqual(counts.newAccessRequests, 20)
        XCTAssertEqual(counts.refreshRequests, 1)
        XCTAssertEqual(storedTokens, newTokens)
        XCTAssertEqual(saveCount, 1)
        XCTAssertFalse(requiresReauthentication)

        let refreshRequest = try XCTUnwrap(recordedRefreshRequest)
        XCTAssertEqual(refreshRequest.httpMethod, "POST")
        XCTAssertEqual(
            refreshRequest.url?.absoluteString,
            "https://example.net/prefix/auth/refresh"
        )
        XCTAssertEqual(
            refreshRequest.value(forHTTPHeaderField: "x-refresh-token"),
            "old-refresh"
        )
        XCTAssertNil(
            refreshRequest.value(forHTTPHeaderField: "Authorization")
        )
    }

    func testTwentyUnauthorizedRequestsShareOneRejectedRefresh() async throws {
        let accountID = AccountID(rawValue: "concurrent-rejection")
        let server = try NormalizedServerURL("https://example.net")
        let tokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: tokens]
        )
        let transport = ConcurrentRejectedRefreshTransport(
            unauthorizedRequestCount: 20,
            accessToken: tokens.accessToken
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let request = try Self.request(for: .libraries, server: server)

        let errors = await withTaskGroup(
            of: AuthenticatedRequestError?.self
        ) { group in
            for _ in 0 ..< 20 {
                group.addTask {
                    do {
                        _ = try await coordinator.sendAuthenticated(
                            request,
                            route: .libraries,
                            accountID: accountID,
                            server: server
                        )
                        return nil
                    } catch {
                        return error as? AuthenticatedRequestError
                    }
                }
            }

            var errors: [AuthenticatedRequestError?] = []
            for await error in group {
                errors.append(error)
            }
            return errors
        }
        let counts = await transport.counts()
        let requiresReauthentication =
            await coordinator.requiresReauthentication(for: accountID)

        XCTAssertEqual(
            errors.compactMap { $0 },
            Array(repeating: .refreshRejected, count: 20)
        )
        XCTAssertEqual(counts.ordinaryRequests, 20)
        XCTAssertEqual(counts.refreshRequests, 1)
        XCTAssertTrue(requiresReauthentication)
    }

    func testForbiddenResponseDoesNotRefresh() async throws {
        let fixture = try Fixture(
            responses: [.success(.init(data: Data(), statusCode: 403))]
        )

        let response = try await fixture.send()
        let requestCount = await fixture.transport.requestCount()
        let refreshCount = await fixture.transport.refreshCount()
        let requiresReauthentication =
            await fixture.coordinator.requiresReauthentication(
                for: fixture.accountID
            )

        XCTAssertEqual(response.statusCode, 403)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(refreshCount, 0)
        XCTAssertFalse(requiresReauthentication)
    }

    func testAuthenticationEndpointsNeverEnterRefresh() async throws {
        let fixture = try Fixture(responses: [])
        let routes: [AudiobookshelfRoute] = [
            .login,
            .beginOpenID,
            .completeOpenID,
            .refresh,
            .logout,
            .authorize,
        ]

        for route in routes {
            let request = try Self.request(
                for: route,
                server: fixture.server
            )
            await XCTAssertThrowsErrorAsync(
                try await fixture.coordinator.sendAuthenticated(
                    request,
                    route: route,
                    accountID: fixture.accountID,
                    server: fixture.server
                )
            ) { error in
                XCTAssertEqual(
                    error as? AuthenticatedRequestError,
                    .authenticationEndpoint
                )
            }
        }

        let requestCount = await fixture.transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testOrdinaryRequestRetriesOnlyOnce() async throws {
        let fixture = try Fixture(
            responses: [
                .success(.init(data: Data(), statusCode: 401)),
                .success(.json(Self.authenticationJSON(
                    accessToken: "rotated-access",
                    refreshToken: "rotated-refresh"
                ))),
                .success(.init(data: Data(), statusCode: 401)),
            ]
        )

        await XCTAssertThrowsErrorAsync(
            try await fixture.send()
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .retriedRequestUnauthorized
            )
        }

        let requestCount = await fixture.transport.requestCount()
        let refreshCount = await fixture.transport.refreshCount()
        let requiresReauthentication =
            await fixture.coordinator.requiresReauthentication(
                for: fixture.accountID
            )
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(requiresReauthentication)
    }

    func testRefreshFailuresAreTypedAndAccountScoped() async throws {
        let scenarios: [(
            Result<HTTPResponse, RequestTestError>,
            AuthenticatedRequestError
        )] = [
            (
                .failure(.transport),
                .refreshTransportFailed
            ),
            (
                .success(.init(data: Data(), statusCode: 401)),
                .refreshRejected
            ),
            (
                .success(.init(data: Data(), statusCode: 503)),
                .unexpectedRefreshStatus(503)
            ),
            (
                .success(.json(Data("not-json".utf8))),
                .malformedRefreshResponse
            ),
            (
                .success(.json(Self.authenticationJSON(
                    refreshToken: "refresh"
                ))),
                .missingAccessToken
            ),
            (
                .success(.json(Self.authenticationJSON(
                    accessToken: "access"
                ))),
                .missingRefreshToken
            ),
            (
                .success(.json(Self.authenticationJSON(
                    accessToken: "bad token",
                    refreshToken: "refresh"
                ))),
                .missingAccessToken
            ),
            (
                .success(.json(Self.authenticationJSON(
                    accessToken: "access",
                    refreshToken: "bad token"
                ))),
                .missingRefreshToken
            ),
        ]

        for (refreshResult, expectedError) in scenarios {
            let fixture = try Fixture(
                responses: [
                    .success(.init(data: Data(), statusCode: 401)),
                    refreshResult,
                ]
            )
            await XCTAssertThrowsErrorAsync(
                try await fixture.send()
            ) { error in
                XCTAssertEqual(
                    error as? AuthenticatedRequestError,
                    expectedError
                )
            }
            let requiresReauthentication =
                await fixture.coordinator.requiresReauthentication(
                    for: fixture.accountID
                )
            XCTAssertTrue(requiresReauthentication)
        }
    }

    func testCredentialFailuresAreTyped() async throws {
        let missingFixture = try Fixture(
            responses: [],
            includeCredentials: false
        )
        await XCTAssertThrowsErrorAsync(
            try await missingFixture.send()
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .missingCredentials
            )
        }
        let missingRequiresReauthentication =
            await missingFixture.coordinator.requiresReauthentication(
                for: missingFixture.accountID
            )
        XCTAssertTrue(missingRequiresReauthentication)

        let readFailureFixture = try Fixture(
            responses: [],
            credentialReadFails: true
        )
        await XCTAssertThrowsErrorAsync(
            try await readFailureFixture.send()
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .credentialsReadFailed
            )
        }
        let readFailureRequiresReauthentication =
            await readFailureFixture.coordinator.requiresReauthentication(
                for: readFailureFixture.accountID
            )
        XCTAssertFalse(readFailureRequiresReauthentication)

        let saveFailureFixture = try Fixture(
            responses: [
                .success(.init(data: Data(), statusCode: 401)),
                .success(.json(Self.authenticationJSON(
                    accessToken: "new-access",
                    refreshToken: "new-refresh"
                ))),
            ],
            credentialSaveFails: true
        )
        await XCTAssertThrowsErrorAsync(
            try await saveFailureFixture.send()
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .credentialPersistenceFailed
            )
        }
        let saveFailureRequiresReauthentication =
            await saveFailureFixture.coordinator.requiresReauthentication(
                for: saveFailureFixture.accountID
            )
        XCTAssertTrue(saveFailureRequiresReauthentication)
    }

    func testRequestValidationAndTransportFailuresAreTyped() async throws {
        let fixture = try Fixture(responses: [])
        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator.sendAuthenticated(
                try Self.request(for: .libraries, server: fixture.server),
                route: .libraries,
                accountID: AccountID(rawValue: ""),
                server: fixture.server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .invalidAccountID
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator.sendAuthenticated(
                try Self.request(for: .listeningStats, server: fixture.server),
                route: .libraries,
                accountID: fixture.accountID,
                server: fixture.server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .requestDoesNotMatchRoute
            )
        }

        var missingURLRequest = try Self.request(
            for: .libraries,
            server: fixture.server
        )
        missingURLRequest.url = nil
        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator.sendAuthenticated(
                missingURLRequest,
                route: .libraries,
                accountID: fixture.accountID,
                server: fixture.server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .requestDoesNotMatchRoute
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator.sendAuthenticated(
                try Self.request(for: .libraries, server: fixture.server),
                route: .directPlay(
                    sessionID: PlaybackSessionID(rawValue: "session"),
                    trackIndex: -1
                ),
                accountID: fixture.accountID,
                server: fixture.server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .requestDoesNotMatchRoute
            )
        }

        var tokenQueryRequest = try Self.request(
            for: .libraries,
            server: fixture.server
        )
        tokenQueryRequest.url = URL(
            string: "\(try XCTUnwrap(tokenQueryRequest.url))?token=secret"
        )
        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator.sendAuthenticated(
                tokenQueryRequest,
                route: .libraries,
                accountID: fixture.accountID,
                server: fixture.server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .authorizationFailed(.tokenBearingURL)
            )
        }

        let transportFailureFixture = try Fixture(
            responses: [.failure(.transport)]
        )
        await XCTAssertThrowsErrorAsync(
            try await transportFailureFixture.send()
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .requestTransportFailed
            )
        }
        let transportFailureRequiresReauthentication =
            await transportFailureFixture.coordinator
            .requiresReauthentication(
                for: transportFailureFixture.accountID
            )
        XCTAssertFalse(transportFailureRequiresReauthentication)
    }

    func testAlreadyRotatedCredentialsAvoidAnotherRefresh() async throws {
        let accountID = AccountID(rawValue: "externally-rotated")
        let server = try NormalizedServerURL("https://example.net")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let newTokens = try AuthenticationTokens(
            accessToken: "new-access",
            refreshToken: "new-refresh"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: oldTokens]
        )
        let transport = ExternallyRotatedTransport(
            credentialStore: store,
            accountID: accountID,
            oldTokens: oldTokens,
            newTokens: newTokens
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        let response = try await coordinator.sendAuthenticated(
            try Self.request(for: .libraries, server: server),
            route: .libraries,
            accountID: accountID,
            server: server
        )
        let counts = await transport.counts()

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(counts.oldAccessRequests, 1)
        XCTAssertEqual(counts.newAccessRequests, 1)
        XCTAssertEqual(counts.refreshRequests, 0)
    }

    func testCompletedRotationCoversAStaleCredentialRead() async throws {
        let accountID = AccountID(rawValue: "stale-read")
        let server = try NormalizedServerURL("https://example.net")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let store = StaleReadCredentialStore(credentials: oldTokens)
        let transport = ScriptedRequestTransport(responses: [
            .success(.init(data: Data(), statusCode: 401)),
            .success(.json(Self.authenticationJSON(
                accessToken: "new-access",
                refreshToken: "new-refresh"
            ))),
            .success(.init(data: Data(), statusCode: 200)),
            .success(.init(data: Data(), statusCode: 401)),
            .success(.init(data: Data(), statusCode: 200)),
        ])
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let request = try Self.request(for: .libraries, server: server)

        let firstResponse = try await coordinator.sendAuthenticated(
            request,
            route: .libraries,
            accountID: accountID,
            server: server
        )
        let secondResponse = try await coordinator.sendAuthenticated(
            request,
            route: .libraries,
            accountID: accountID,
            server: server
        )
        let refreshCount = await transport.refreshCount()
        let savedCredentials = await store.savedCredentials()

        XCTAssertEqual(firstResponse.statusCode, 200)
        XCTAssertEqual(secondResponse.statusCode, 200)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(
            savedCredentials,
            try AuthenticationTokens(
                accessToken: "new-access",
                refreshToken: "new-refresh"
            )
        )
    }

    func testRefreshFailureDoesNotAffectAnotherAccount() async throws {
        let failedAccount = AccountID(rawValue: "failed")
        let healthyAccount = AccountID(rawValue: "healthy")
        let server = try NormalizedServerURL("https://example.net")
        let store = RequestCredentialStore(credentials: [
            failedAccount: try AuthenticationTokens(
                accessToken: "failed-access",
                refreshToken: "failed-refresh"
            ),
            healthyAccount: try AuthenticationTokens(
                accessToken: "healthy-access",
                refreshToken: "healthy-refresh"
            ),
        ])
        let transport = AccountIsolationTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let request = try Self.request(for: .libraries, server: server)

        await XCTAssertThrowsErrorAsync(
            try await coordinator.sendAuthenticated(
                request,
                route: .libraries,
                accountID: failedAccount,
                server: server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .refreshRejected
            )
        }
        let healthyResponse = try await coordinator.sendAuthenticated(
            request,
            route: .libraries,
            accountID: healthyAccount,
            server: server
        )
        let failedRequiresReauthentication =
            await coordinator.requiresReauthentication(for: failedAccount)
        let healthyRequiresReauthentication =
            await coordinator.requiresReauthentication(for: healthyAccount)

        XCTAssertEqual(healthyResponse.statusCode, 200)
        XCTAssertTrue(failedRequiresReauthentication)
        XCTAssertFalse(healthyRequiresReauthentication)
    }

    private static func request(
        for route: AudiobookshelfRoute,
        server: NormalizedServerURL
    ) throws -> URLRequest {
        URLRequest(
            url: try AudiobookshelfRouteBuilder(server: server)
                .url(for: route)
        )
    }

    fileprivate static func authenticationJSON(
        accessToken: String? = nil,
        refreshToken: String? = nil
    ) -> Data {
        var tokenFields = ""
        if let accessToken {
            tokenFields += #","accessToken":"\#(accessToken)""#
        }
        if let refreshToken {
            tokenFields += #","refreshToken":"\#(refreshToken)""#
        }
        return Data(
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
                "itemTagsSelected": []
                \(tokenFields)
              }
            }
            """.utf8
        )
    }
}

private struct Fixture {
    let accountID = AccountID(rawValue: "account")
    let server: NormalizedServerURL
    let store: RequestCredentialStore
    let transport: ScriptedRequestTransport
    let coordinator: AuthCoordinator<
        ScriptedRequestTransport,
        RequestCredentialStore
    >

    init(
        responses: [Result<HTTPResponse, RequestTestError>],
        includeCredentials: Bool = true,
        credentialReadFails: Bool = false,
        credentialSaveFails: Bool = false
    ) throws {
        server = try NormalizedServerURL("https://example.net")
        let tokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        store = RequestCredentialStore(
            credentials: includeCredentials ? [accountID: tokens] : [:],
            readFails: credentialReadFails,
            saveFails: credentialSaveFails
        )
        transport = ScriptedRequestTransport(responses: responses)
        coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
    }

    func send() async throws -> HTTPResponse {
        let request = URLRequest(
            url: try AudiobookshelfRouteBuilder(server: server)
                .url(for: .libraries)
        )
        return try await coordinator.sendAuthenticated(
            request,
            route: .libraries,
            accountID: accountID,
            server: server
        )
    }
}

private actor RequestCredentialStore: AccountCredentialStore {
    private var stored: [AccountID: AuthenticationTokens]
    private var saves = 0
    private let readFails: Bool
    private let saveFails: Bool

    init(
        credentials: [AccountID: AuthenticationTokens],
        readFails: Bool = false,
        saveFails: Bool = false
    ) {
        stored = credentials
        self.readFails = readFails
        self.saveFails = saveFails
    }

    func credentials(
        for accountID: AccountID
    ) throws -> AuthenticationTokens? {
        if readFails {
            throw RequestTestError.store
        }
        return stored[accountID]
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) throws {
        if saveFails {
            throw RequestTestError.store
        }
        stored[accountID] = credentials
        saves += 1
    }

    func deleteCredentials(for accountID: AccountID) {
        stored[accountID] = nil
    }

    func saveCount() -> Int {
        saves
    }
}

private actor ScriptedRequestTransport: HTTPTransport {
    private var responses: [Result<HTTPResponse, RequestTestError>]
    private var requests: [URLRequest] = []

    init(responses: [Result<HTTPResponse, RequestTestError>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw RequestTestError.missingResponse
        }
        return try responses.removeFirst().get()
    }

    func requestCount() -> Int {
        requests.count
    }

    func refreshCount() -> Int {
        requests.filter {
            $0.url?.path.hasSuffix("/auth/refresh") == true
        }.count
    }
}

private actor StaleReadCredentialStore: AccountCredentialStore {
    private let credentialsToReturn: AuthenticationTokens
    private var lastSavedCredentials: AuthenticationTokens?

    init(credentials: AuthenticationTokens) {
        credentialsToReturn = credentials
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        credentialsToReturn
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        lastSavedCredentials = credentials
    }

    func deleteCredentials(for accountID: AccountID) {
        lastSavedCredentials = nil
    }

    func savedCredentials() -> AuthenticationTokens? {
        lastSavedCredentials
    }
}

private actor ConcurrentRefreshTransport: HTTPTransport {
    private let unauthorizedRequestCount: Int
    private let oldTokens: AuthenticationTokens
    private let newTokens: AuthenticationTokens
    private var oldAccessRequests = 0
    private var newAccessRequests = 0
    private var refreshRequests: [URLRequest] = []
    private var unauthorizedWaiters: [
        CheckedContinuation<HTTPResponse, Never>
    ] = []

    init(
        unauthorizedRequestCount: Int,
        oldTokens: AuthenticationTokens,
        newTokens: AuthenticationTokens
    ) {
        self.unauthorizedRequestCount = unauthorizedRequestCount
        self.oldTokens = oldTokens
        self.newTokens = newTokens
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            refreshRequests.append(request)
            return .json(AuthenticatedRequestTests.authenticationJSON(
                accessToken: newTokens.accessToken,
                refreshToken: newTokens.refreshToken
            ))
        }

        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer \(oldTokens.accessToken)":
            oldAccessRequests += 1
            return await withCheckedContinuation { continuation in
                unauthorizedWaiters.append(continuation)
                guard unauthorizedWaiters.count
                    == unauthorizedRequestCount
                else {
                    return
                }
                let waiters = unauthorizedWaiters
                unauthorizedWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume(
                        returning: .init(
                            data: Data(),
                            statusCode: 401
                        )
                    )
                }
            }
        case "Bearer \(newTokens.accessToken)":
            newAccessRequests += 1
            return .init(data: Data(), statusCode: 200)
        default:
            throw RequestTestError.unexpectedAuthorization
        }
    }

    func counts() -> (
        oldAccessRequests: Int,
        newAccessRequests: Int,
        refreshRequests: Int
    ) {
        (
            oldAccessRequests,
            newAccessRequests,
            refreshRequests.count
        )
    }

    func refreshRequest() -> URLRequest? {
        refreshRequests.first
    }
}

private actor ConcurrentRejectedRefreshTransport: HTTPTransport {
    private let unauthorizedRequestCount: Int
    private let accessToken: String
    private var ordinaryRequests = 0
    private var refreshRequests = 0
    private var unauthorizedWaiters: [
        CheckedContinuation<HTTPResponse, Never>
    ] = []

    init(
        unauthorizedRequestCount: Int,
        accessToken: String
    ) {
        self.unauthorizedRequestCount = unauthorizedRequestCount
        self.accessToken = accessToken
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            refreshRequests += 1
            return .init(data: Data(), statusCode: 401)
        }
        guard request.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(accessToken)"
        else {
            throw RequestTestError.unexpectedAuthorization
        }

        ordinaryRequests += 1
        return await withCheckedContinuation { continuation in
            unauthorizedWaiters.append(continuation)
            guard unauthorizedWaiters.count == unauthorizedRequestCount else {
                return
            }
            let waiters = unauthorizedWaiters
            unauthorizedWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(
                    returning: .init(data: Data(), statusCode: 401)
                )
            }
        }
    }

    func counts() -> (
        ordinaryRequests: Int,
        refreshRequests: Int
    ) {
        (ordinaryRequests, refreshRequests)
    }
}

private actor AccountIsolationTransport: HTTPTransport {
    func send(_ request: URLRequest) -> HTTPResponse {
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            return .init(data: Data(), statusCode: 401)
        }
        if request.value(forHTTPHeaderField: "Authorization")
            == "Bearer failed-access"
        {
            return .init(data: Data(), statusCode: 401)
        }
        return .init(data: Data(), statusCode: 200)
    }
}

private actor ExternallyRotatedTransport: HTTPTransport {
    private let credentialStore: RequestCredentialStore
    private let accountID: AccountID
    private let oldTokens: AuthenticationTokens
    private let newTokens: AuthenticationTokens
    private var oldAccessRequests = 0
    private var newAccessRequests = 0
    private var refreshRequests = 0

    init(
        credentialStore: RequestCredentialStore,
        accountID: AccountID,
        oldTokens: AuthenticationTokens,
        newTokens: AuthenticationTokens
    ) {
        self.credentialStore = credentialStore
        self.accountID = accountID
        self.oldTokens = oldTokens
        self.newTokens = newTokens
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            refreshRequests += 1
            throw RequestTestError.unexpectedAuthorization
        }
        if request.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(oldTokens.accessToken)"
        {
            oldAccessRequests += 1
            try await credentialStore.save(newTokens, for: accountID)
            return .init(data: Data(), statusCode: 401)
        }
        if request.value(forHTTPHeaderField: "Authorization")
            == "Bearer \(newTokens.accessToken)"
        {
            newAccessRequests += 1
            return .init(data: Data(), statusCode: 200)
        }
        throw RequestTestError.unexpectedAuthorization
    }

    func counts() -> (
        oldAccessRequests: Int,
        newAccessRequests: Int,
        refreshRequests: Int
    ) {
        (
            oldAccessRequests,
            newAccessRequests,
            refreshRequests
        )
    }
}

private enum RequestTestError: Error {
    case missingResponse
    case store
    case transport
    case unexpectedAuthorization
}

private extension HTTPResponse {
    static func json(_ data: Data) -> HTTPResponse {
        HTTPResponse(
            data: data,
            statusCode: 200,
            headers: ["Content-Type": "application/json"]
        )
    }
}
