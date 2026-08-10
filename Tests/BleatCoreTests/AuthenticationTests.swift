import Foundation
import XCTest

@testable import BleatCore

final class AuthenticationTests: XCTestCase {
    func testPinnedAuthenticationFixturesCompleteTransaction() async throws {
        let transport = AuthenticationHTTPTransport(
            responses: [
                .json(try Self.fixture(named: "login-tokens")),
                .json(try Self.fixture(named: "authorize")),
            ]
        )
        let store = RecordingCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let accountID = AccountID(rawValue: "fixture-account")

        let account = try await coordinator.login(
            accountID: accountID,
            server: NormalizedServerURL("https://example.com"),
            username: "fixture-root",
            password: "test-password"
        )
        let storedCredentials = await store.credentials(for: accountID)
        let storedNativeLogin = await store.nativeLoginCredentials(
            for: accountID
        )

        XCTAssertEqual(
            account.user.id,
            UserID(rawValue: "fixture-user")
        )
        XCTAssertEqual(account.user.username, "fixture-root")
        XCTAssertEqual(account.user.type, .root)
        XCTAssertEqual(
            storedCredentials,
            try AuthenticationTokens(
                accessToken: "fixture-access-token",
                refreshToken: "fixture-refresh-token"
            )
        )
        XCTAssertEqual(
            storedNativeLogin,
            try NativeLoginCredentials(
                userID: UserID(rawValue: "fixture-user"),
                username: "fixture-root",
                password: "test-password"
            )
        )
    }

    func testLocalLoginValidatesBeforePersistingCredentials() async throws {
        let transport = AuthenticationHTTPTransport(
            responses: [
                .json(
                    Self.authenticationJSON(
                        accessToken: "access-token",
                        refreshToken: "refresh-token"
                    )
                ),
                .json(Self.authenticationJSON()),
            ]
        )
        let store = RecordingCredentialStore()
        let client = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let accountID = AccountID(rawValue: "local-account")
        let server = try NormalizedServerURL(
            "https://example.com/audiobookshelf"
        )

        let account = try await client.login(
            accountID: accountID,
            server: server,
            username: "reader",
            password: "test-password"
        )

        XCTAssertEqual(account.id, accountID)
        XCTAssertEqual(account.server, server)
        XCTAssertEqual(
            account.user.id,
            UserID(rawValue: "user-id")
        )
        XCTAssertEqual(account.user.username, "reader")
        XCTAssertEqual(account.user.type, .root)
        XCTAssertTrue(account.user.permissions.download)
        XCTAssertEqual(account.user.accessibleLibraryIDs, [])
        XCTAssertEqual(account.user.selectedItemTags, [])

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://example.com/audiobookshelf/login"
        )
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "x-return-tokens"),
            "true"
        )
        let loginBody = try XCTUnwrap(requests[0].httpBody)
        let loginObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: loginBody)
                as? [String: String]
        )
        XCTAssertEqual(
            loginObject,
            [
                "username": "reader",
                "password": "test-password",
            ]
        )

        XCTAssertEqual(
            requests[1].url?.absoluteString,
            "https://example.com/audiobookshelf/api/authorize"
        )
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertNil(requests[1].url?.query)

        let storedCredentials = await store.credentials(for: accountID)
        let expectedCredentials = try AuthenticationTokens(
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
        let saveCount = await store.saveCount()
        XCTAssertEqual(storedCredentials, expectedCredentials)
        XCTAssertEqual(saveCount, 1)
    }

    func testCredentialValidationRequiresSameUserWithoutPersisting()
        async throws
    {
        let transport = AuthenticationHTTPTransport(
            responses: [
                .json(
                    Self.authenticationJSON(
                        accessToken: "access-token",
                        refreshToken: "refresh-token"
                    )
                ),
                .json(Self.authenticationJSON()),
            ]
        )
        let store = RecordingCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let accountID = AccountID(rawValue: "edited-account")

        _ = try await coordinator.validateLocalLogin(
            accountID: accountID,
            server: NormalizedServerURL("https://local.example"),
            username: "reader",
            password: "test-password",
            expectedUserID: UserID(rawValue: "user-id")
        )

        let storedTokens = await store.credentials(for: accountID)
        let storedLogin = await store.nativeLoginCredentials(for: accountID)
        let saveCount = await store.saveCount()
        XCTAssertNil(storedTokens)
        XCTAssertNil(storedLogin)
        XCTAssertEqual(saveCount, 0)
    }

    func testCredentialValidationRejectsADifferentSavedUser() async throws {
        let transport = AuthenticationHTTPTransport(
            responses: [
                .json(
                    Self.authenticationJSON(
                        accessToken: "access-token",
                        refreshToken: "refresh-token"
                    )
                ),
                .json(Self.authenticationJSON()),
            ]
        )
        let store = RecordingCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.validateLocalLogin(
                accountID: AccountID(rawValue: "edited-account"),
                server: NormalizedServerURL("https://local.example"),
                username: "reader",
                password: "test-password",
                expectedUserID: UserID(rawValue: "different-user")
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalAuthenticationError,
                .authorizedUserMismatch(
                    expected: "different-user",
                    actual: "user-id"
                )
            )
        }

        let saveCount = await store.saveCount()
        XCTAssertEqual(saveCount, 0)
    }

    func testStoredSessionValidationDoesNotReplaceCredentials() async throws {
        let transport = AuthenticationHTTPTransport(
            responses: [.json(Self.authenticationJSON())]
        )
        let store = RecordingCredentialStore()
        let accountID = AccountID(rawValue: "edited-account")
        let tokens = try AuthenticationTokens(
            accessToken: "stored-access",
            refreshToken: "stored-refresh"
        )
        try await store.save(tokens, for: accountID)
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        let authenticated = try await coordinator.validateStoredSession(
            accountID: accountID,
            server: NormalizedServerURL("https://new.example"),
            expectedUserID: UserID(rawValue: "user-id")
        )

        XCTAssertEqual(authenticated.user.username, "reader")
        let storedTokens = await store.credentials(for: accountID)
        let saveCount = await store.saveCount()
        XCTAssertEqual(storedTokens, tokens)
        XCTAssertEqual(saveCount, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://new.example/api/authorize"
        )
        XCTAssertEqual(
            requests[0].value(forHTTPHeaderField: "Authorization"),
            "Bearer stored-access"
        )
    }

    func testStoredAuthenticationFallsBackWithoutReplacingPassword()
        async throws
    {
        let transport = AuthenticationHTTPTransport(
            responses: [
                .init(data: Data(), statusCode: 401),
                .json(
                    Self.authenticationJSON(
                        accessToken: "temporary-access",
                        refreshToken: "temporary-refresh"
                    )
                ),
                .json(Self.authenticationJSON()),
            ]
        )
        let store = RecordingCredentialStore()
        let accountID = AccountID(rawValue: "edited-account")
        let storedTokens = try AuthenticationTokens(
            accessToken: "expired-access",
            refreshToken: "stored-refresh"
        )
        let storedLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "user-id"),
            username: "reader",
            password: "stored-password"
        )
        try await store.save(
            storedTokens,
            nativeLogin: storedLogin,
            for: accountID
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        _ = try await coordinator.validateStoredAuthentication(
            accountID: accountID,
            server: NormalizedServerURL("https://new.example"),
            expectedUserID: UserID(rawValue: "user-id")
        )

        let retainedTokens = await store.credentials(for: accountID)
        let retainedLogin = await store.nativeLoginCredentials(for: accountID)
        let saveCount = await store.saveCount()
        XCTAssertEqual(retainedTokens, storedTokens)
        XCTAssertEqual(retainedLogin, storedLogin)
        XCTAssertEqual(saveCount, 1)
    }

    func testSavedNativeLoginValidatesAnUntrustedEndpointWithoutBearerToken()
        async throws
    {
        let transport = AuthenticationHTTPTransport(
            responses: [
                .json(
                    Self.authenticationJSON(
                        accessToken: "temporary-access",
                        refreshToken: "temporary-refresh"
                    )
                ),
                .json(Self.authenticationJSON()),
            ]
        )
        let store = RecordingCredentialStore()
        let accountID = AccountID(rawValue: "edited-account")
        let storedTokens = try AuthenticationTokens(
            accessToken: "primary-access",
            refreshToken: "primary-refresh"
        )
        let storedLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "user-id"),
            username: "reader",
            password: "stored-password"
        )
        try await store.save(
            storedTokens,
            nativeLogin: storedLogin,
            for: accountID
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        _ = try await coordinator.validateSavedNativeLogin(
            accountID: accountID,
            server: NormalizedServerURL("https://local.example/prefix"),
            expectedUserID: UserID(rawValue: "user-id")
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(
            requests[0].url?.absoluteString,
            "https://local.example/prefix/login"
        )
        XCTAssertNil(
            requests[0].value(forHTTPHeaderField: "Authorization")
        )
        XCTAssertEqual(
            requests[1].url?.absoluteString,
            "https://local.example/prefix/api/authorize"
        )
        XCTAssertEqual(
            requests[1].value(forHTTPHeaderField: "Authorization"),
            "Bearer temporary-access"
        )
        let retainedTokens = await store.credentials(for: accountID)
        let retainedLogin = await store.nativeLoginCredentials(for: accountID)
        let saveCount = await store.saveCount()
        XCTAssertEqual(retainedTokens, storedTokens)
        XCTAssertEqual(retainedLogin, storedLogin)
        XCTAssertEqual(saveCount, 1)
    }

    func testLocalLoginRejectsInvalidLoginResultsWithoutPersisting()
        async throws
    {
        let scenarios:
            [(
                HTTPResponse,
                LocalAuthenticationError
            )] = [
                (.init(data: Data(), statusCode: 401), .invalidCredentials),
                (
                    .init(data: Data(), statusCode: 429),
                    .unexpectedLoginStatus(429)
                ),
                (.json(Data("not-json".utf8)), .malformedLoginResponse),
                (
                    .json(Self.authenticationJSON(refreshToken: "refresh")),
                    .missingAccessToken
                ),
                (
                    .json(Self.authenticationJSON(accessToken: "access")),
                    .missingRefreshToken
                ),
                (
                    .json(
                        Self.authenticationJSON(
                            accessToken: "bad token",
                            refreshToken: "refresh"
                        )
                    ),
                    .missingAccessToken
                ),
                (
                    .json(
                        Self.authenticationJSON(
                            accessToken: "access",
                            refreshToken: "bad token"
                        )
                    ),
                    .missingRefreshToken
                ),
            ]

        for (response, expectedError) in scenarios {
            let transport = AuthenticationHTTPTransport(
                responses: [response]
            )
            let store = RecordingCredentialStore()
            let client = AuthCoordinator(
                transport: transport,
                credentialStore: store
            )

            await XCTAssertThrowsErrorAsync(
                try await client.login(
                    accountID: AccountID(rawValue: "account"),
                    server: NormalizedServerURL("https://example.com"),
                    username: "reader",
                    password: "incorrect"
                )
            ) { error in
                XCTAssertEqual(
                    error as? LocalAuthenticationError,
                    expectedError
                )
            }
            let saveCount = await store.saveCount()
            XCTAssertEqual(saveCount, 0)
        }
    }

    func testLocalLoginRejectsInvalidAuthorizationWithoutPersisting()
        async throws
    {
        let loginResponse = HTTPResponse.json(
            Self.authenticationJSON(
                accessToken: "access",
                refreshToken: "refresh"
            )
        )
        let scenarios:
            [(
                HTTPResponse,
                LocalAuthenticationError
            )] = [
                (
                    .init(data: Data(), statusCode: 401),
                    .tokenValidationFailed
                ),
                (
                    .init(data: Data(), statusCode: 403),
                    .unexpectedAuthorizationStatus(403)
                ),
                (
                    .json(Data("not-json".utf8)),
                    .malformedAuthorizationResponse
                ),
                (
                    .json(Self.authenticationJSON(userID: "other-user")),
                    .authorizedUserMismatch(
                        expected: "user-id",
                        actual: "other-user"
                    )
                ),
            ]

        for (response, expectedError) in scenarios {
            let transport = AuthenticationHTTPTransport(
                responses: [loginResponse, response]
            )
            let store = RecordingCredentialStore()
            let client = AuthCoordinator(
                transport: transport,
                credentialStore: store
            )

            await XCTAssertThrowsErrorAsync(
                try await client.login(
                    accountID: AccountID(rawValue: "account"),
                    server: NormalizedServerURL("https://example.com"),
                    username: "reader",
                    password: "test-password"
                )
            ) { error in
                XCTAssertEqual(
                    error as? LocalAuthenticationError,
                    expectedError
                )
            }
            let saveCount = await store.saveCount()
            XCTAssertEqual(saveCount, 0)
        }
    }

    func testLocalLoginRejectsEmptyAccountAndPersistenceFailure() async throws {
        let emptyAccountTransport = AuthenticationHTTPTransport(responses: [])
        let emptyAccountStore = RecordingCredentialStore()
        let emptyAccountClient = AuthCoordinator(
            transport: emptyAccountTransport,
            credentialStore: emptyAccountStore
        )

        await XCTAssertThrowsErrorAsync(
            try await emptyAccountClient.login(
                accountID: AccountID(rawValue: ""),
                server: NormalizedServerURL("https://example.com"),
                username: "reader",
                password: "test-password"
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalAuthenticationError,
                .invalidAccountID
            )
        }
        let emptyAccountRequests =
            await emptyAccountTransport.recordedRequests()
        XCTAssertEqual(emptyAccountRequests.count, 0)

        let transport = AuthenticationHTTPTransport(
            responses: [
                .json(
                    Self.authenticationJSON(
                        accessToken: "access",
                        refreshToken: "refresh"
                    )
                ),
                .json(Self.authenticationJSON()),
            ]
        )
        let failingStore = RecordingCredentialStore(
            saveFailure: .generic
        )
        let client = AuthCoordinator(
            transport: transport,
            credentialStore: failingStore
        )

        await XCTAssertThrowsErrorAsync(
            try await client.login(
                accountID: AccountID(rawValue: "account"),
                server: NormalizedServerURL("https://example.com"),
                username: "reader",
                password: "test-password"
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalAuthenticationError,
                .credentialPersistenceFailed
            )
        }
        let failedCredentials = await failingStore.credentials(
            for: AccountID(rawValue: "account")
        )
        XCTAssertNil(failedCredentials)
    }

    func testMissingKeychainEntitlementHasDistinctAuthenticationError()
        async throws
    {
        let transport = AuthenticationHTTPTransport(
            responses: [
                .json(
                    Self.authenticationJSON(
                        accessToken: "access",
                        refreshToken: "refresh"
                    )
                ),
                .json(Self.authenticationJSON()),
            ]
        )
        let store = RecordingCredentialStore(
            saveFailure: .missingEntitlement
        )
        let client = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        await XCTAssertThrowsErrorAsync(
            try await client.login(
                accountID: AccountID(rawValue: "account"),
                server: NormalizedServerURL("https://example.com"),
                username: "reader",
                password: "test-password"
            )
        ) { error in
            XCTAssertEqual(
                error as? LocalAuthenticationError,
                .credentialStorageUnavailable
            )
        }
        let storedCredentials = await store.credentials(
            for: AccountID(rawValue: "account")
        )
        XCTAssertNil(storedCredentials)
    }

    func testBearerAuthorizerAddsHeaderWithoutChangingURL() throws {
        let url = try XCTUnwrap(
            URL(string: "https://example.com/api/libraries?sort=title")
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let authorized = try BearerRequestAuthorizer().authorize(
            request,
            accessToken: "access-token"
        )

        XCTAssertEqual(authorized.url, url)
        XCTAssertEqual(
            authorized.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertEqual(
            authorized.url?.query,
            "sort=title"
        )
    }

    func testBearerAuthorizerRejectsUnsafeRequestOrToken() throws {
        var missingURL = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com"))
        )
        missingURL.url = nil

        let scenarios: [(URLRequest, String, BearerAuthorizationError)] = [
            (missingURL, "access", .missingURL),
            (
                URLRequest(
                    url: try XCTUnwrap(
                        URL(string: "http://example.com/api/libraries")
                    )
                ),
                "access",
                .insecureURL
            ),
            (
                URLRequest(
                    url: try XCTUnwrap(
                        URL(string: "https://user@example.com/api/libraries")
                    )
                ),
                "access",
                .embeddedCredentials
            ),
            (
                URLRequest(
                    url: try XCTUnwrap(
                        URL(
                            string:
                                "https://example.com/api/libraries?TOKEN=secret"
                        )
                    )
                ),
                "access",
                .tokenBearingURL
            ),
            (
                URLRequest(
                    url: try XCTUnwrap(
                        URL(string: "https://example.com/api/libraries")
                    )
                ),
                "",
                .invalidAccessToken
            ),
            (
                URLRequest(
                    url: try XCTUnwrap(
                        URL(string: "https://example.com/api/libraries")
                    )
                ),
                "bad\nheader",
                .invalidAccessToken
            ),
        ]

        for (request, token, expectedError) in scenarios {
            XCTAssertThrowsError(
                try BearerRequestAuthorizer().authorize(
                    request,
                    accessToken: token
                )
            ) { error in
                XCTAssertEqual(
                    error as? BearerAuthorizationError,
                    expectedError
                )
            }
        }
    }

    func testAuthenticationTokensAndUnknownUserTypeValidation() throws {
        XCTAssertThrowsError(
            try AuthenticationTokens(
                accessToken: "",
                refreshToken: "refresh"
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticationTokenError,
                .invalidAccessToken
            )
        }
        XCTAssertThrowsError(
            try AuthenticationTokens(
                accessToken: "access",
                refreshToken: "bad token"
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticationTokenError,
                .invalidRefreshToken
            )
        }

        let encoded = try JSONEncoder().encode(
            AudiobookshelfUserType.unknown("future-type")
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AudiobookshelfUserType.self,
                from: encoded
            ),
            .unknown("future-type")
        )
        XCTAssertEqual(AudiobookshelfUserType.root.rawValue, "root")
        XCTAssertEqual(AudiobookshelfUserType.admin.rawValue, "admin")
        XCTAssertEqual(AudiobookshelfUserType.user.rawValue, "user")
        XCTAssertEqual(AudiobookshelfUserType.guest.rawValue, "guest")

        let decodedTypes = try JSONDecoder().decode(
            [AudiobookshelfUserType].self,
            from: Data(
                #"["root","admin","user","guest","future-type"]"#.utf8
            )
        )
        XCTAssertEqual(
            decodedTypes,
            [.root, .admin, .user, .guest, .unknown("future-type")]
        )

        let tokens = try AuthenticationTokens(
            accessToken: "access",
            refreshToken: "refresh"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                AuthenticationTokens.self,
                from: JSONEncoder().encode(tokens)
            ),
            tokens
        )

        for invalidJSON in [
            #"{"accessToken":"bad token","refreshToken":"refresh"}"#,
            #"{"accessToken":"access","refreshToken":"bad token"}"#,
        ] {
            XCTAssertThrowsError(
                try JSONDecoder().decode(
                    AuthenticationTokens.self,
                    from: Data(invalidJSON.utf8)
                )
            )
        }
    }

    private static func authenticationJSON(
        userID: String = "user-id",
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
                "id": "\(userID)",
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
              },
              "futureField": "ignored"
            }
            """.utf8
        )
    }

    private static func fixture(named name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: nil
            )?.first {
                $0.lastPathComponent == "\(name).json"
            }
        )
        return try Data(contentsOf: url)
    }
}

private actor AuthenticationHTTPTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) throws -> HTTPResponse {
        let request = tracedRequest.request
        requests.append(request)
        guard !responses.isEmpty else {
            throw AuthenticationTestError.noResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private actor RecordingCredentialStore: AccountCredentialStore {
    enum SaveFailure: Sendable {
        case generic
        case missingEntitlement
    }

    private var stored: [AccountID: AuthenticationTokens] = [:]
    private var nativeLogins: [AccountID: NativeLoginCredentials] = [:]
    private var saves = 0
    private let saveFailure: SaveFailure?

    init(saveFailure: SaveFailure? = nil) {
        self.saveFailure = saveFailure
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        stored[accountID]
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) throws {
        try failSaveIfRequested()
        stored[accountID] = credentials
        saves += 1
    }

    func save(
        _ credentials: AuthenticationTokens,
        nativeLogin: NativeLoginCredentials,
        for accountID: AccountID
    ) async throws {
        try failSaveIfRequested()
        stored[accountID] = credentials
        nativeLogins[accountID] = nativeLogin
        saves += 1
    }

    func nativeLoginCredentials(
        for accountID: AccountID
    ) async -> NativeLoginCredentials? {
        nativeLogins[accountID]
    }

    func deleteCredentials(for accountID: AccountID) {
        stored[accountID] = nil
        nativeLogins[accountID] = nil
    }

    func saveCount() -> Int {
        saves
    }

    private func failSaveIfRequested() throws {
        switch saveFailure {
        case .generic:
            throw AuthenticationTestError.storeFailure
        case .missingEntitlement:
            throw TokenVaultError.missingEntitlement
        case nil:
            return
        }
    }
}

private enum AuthenticationTestError: Error {
    case noResponse
    case storeFailure
}

extension HTTPResponse {
    fileprivate static func json(_ data: Data) -> HTTPResponse {
        HTTPResponse(
            data: data,
            statusCode: 200,
            headers: ["Content-Type": "application/json"]
        )
    }
}
