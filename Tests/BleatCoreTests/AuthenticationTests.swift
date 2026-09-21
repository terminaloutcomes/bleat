import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class AuthenticationTests {
    @Test
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

        #expect(account.user.id == UserID(rawValue: "fixture-user"))
        #expect(account.user.username == "fixture-root")
        #expect(account.user.type == .root)
        #expect(
            storedCredentials
                == (try AuthenticationTokens(
                    accessToken: "fixture-access-token",
                    refreshToken: "fixture-refresh-token"
                )))
        #expect(
            storedNativeLogin
                == (try NativeLoginCredentials(
                    userID: UserID(rawValue: "fixture-user"),
                    username: "fixture-root",
                    password: "test-password"
                )))
    }

    @Test
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

        #expect(account.id == accountID)
        #expect(account.server == server)
        #expect(account.user.id == UserID(rawValue: "user-id"))
        #expect(account.user.username == "reader")
        #expect(account.user.type == .root)
        #expect(account.user.permissions.download)
        #expect(account.user.accessibleLibraryIDs == [])
        #expect(account.user.selectedItemTags == [])

        let requests = await transport.recordedRequests()
        #expect(requests.count == 2)
        #expect(
            requests[0].url?.absoluteString
                == "https://example.com/audiobookshelf/login")
        #expect(requests[0].httpMethod == "POST")
        #expect(
            requests[0].value(forHTTPHeaderField: "Content-Type")
                == "application/json")
        #expect(
            requests[0].value(forHTTPHeaderField: "x-return-tokens") == "true")
        let loginBody = try #require(requests[0].httpBody)
        let loginObject = try #require(
            JSONSerialization.jsonObject(with: loginBody)
                as? [String: String])
        #expect(
            loginObject == [
                "username": "reader",
                "password": "test-password",
            ])

        #expect(
            requests[1].url?.absoluteString
                == "https://example.com/audiobookshelf/api/authorize")
        #expect(requests[1].httpMethod == "POST")
        #expect(
            requests[1].value(forHTTPHeaderField: "Authorization")
                == "Bearer access-token")
        #expect(requests[1].url?.query == nil)

        let storedCredentials = await store.credentials(for: accountID)
        let expectedCredentials = try AuthenticationTokens(
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
        let saveCount = await store.saveCount()
        #expect(storedCredentials == expectedCredentials)
        #expect(saveCount == 1)
    }

    @Test
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
        #expect(storedTokens == nil)
        #expect(storedLogin == nil)
        #expect(saveCount == 0)
    }

    @Test
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

        await assertThrowsErrorAsync(
            try await coordinator.validateLocalLogin(
                accountID: AccountID(rawValue: "edited-account"),
                server: NormalizedServerURL("https://local.example"),
                username: "reader",
                password: "test-password",
                expectedUserID: UserID(rawValue: "different-user")
            )
        ) { error in
            #expect(
                error as? LocalAuthenticationError
                    == .authorizedUserMismatch(
                        expected: "different-user",
                        actual: "user-id"
                    ))
        }

        let saveCount = await store.saveCount()
        #expect(saveCount == 0)
    }

    @Test
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

        #expect(authenticated.user.username == "reader")
        let storedTokens = await store.credentials(for: accountID)
        let saveCount = await store.saveCount()
        #expect(storedTokens == tokens)
        #expect(saveCount == 1)
        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        #expect(
            requests[0].url?.absoluteString
                == "https://new.example/api/authorize")
        #expect(
            requests[0].value(forHTTPHeaderField: "Authorization")
                == "Bearer stored-access")
    }

    @Test
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
        #expect(retainedTokens == storedTokens)
        #expect(retainedLogin == storedLogin)
        #expect(saveCount == 1)
    }

    @Test
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
        #expect(requests.count == 2)
        #expect(
            requests[0].url?.absoluteString
                == "https://local.example/prefix/login")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(
            requests[1].url?.absoluteString
                == "https://local.example/prefix/api/authorize")
        #expect(
            requests[1].value(forHTTPHeaderField: "Authorization")
                == "Bearer temporary-access")
        let retainedTokens = await store.credentials(for: accountID)
        let retainedLogin = await store.nativeLoginCredentials(for: accountID)
        let saveCount = await store.saveCount()
        #expect(retainedTokens == storedTokens)
        #expect(retainedLogin == storedLogin)
        #expect(saveCount == 1)
    }

    @Test
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

            await assertThrowsErrorAsync(
                try await client.login(
                    accountID: AccountID(rawValue: "account"),
                    server: NormalizedServerURL("https://example.com"),
                    username: "reader",
                    password: "incorrect"
                )
            ) { error in
                #expect(error as? LocalAuthenticationError == expectedError)
            }
            let saveCount = await store.saveCount()
            #expect(saveCount == 0)
        }
    }

    @Test
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

            await assertThrowsErrorAsync(
                try await client.login(
                    accountID: AccountID(rawValue: "account"),
                    server: NormalizedServerURL("https://example.com"),
                    username: "reader",
                    password: "test-password"
                )
            ) { error in
                #expect(error as? LocalAuthenticationError == expectedError)
            }
            let saveCount = await store.saveCount()
            #expect(saveCount == 0)
        }
    }

    @Test
    func testLocalLoginRejectsEmptyAccountAndPersistenceFailure() async throws {
        let emptyAccountTransport = AuthenticationHTTPTransport(responses: [])
        let emptyAccountStore = RecordingCredentialStore()
        let emptyAccountClient = AuthCoordinator(
            transport: emptyAccountTransport,
            credentialStore: emptyAccountStore
        )

        await assertThrowsErrorAsync(
            try await emptyAccountClient.login(
                accountID: AccountID(rawValue: ""),
                server: NormalizedServerURL("https://example.com"),
                username: "reader",
                password: "test-password"
            )
        ) { error in
            #expect(error as? LocalAuthenticationError == .invalidAccountID)
        }
        let emptyAccountRequests =
            await emptyAccountTransport.recordedRequests()
        #expect(emptyAccountRequests.count == 0)

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

        await assertThrowsErrorAsync(
            try await client.login(
                accountID: AccountID(rawValue: "account"),
                server: NormalizedServerURL("https://example.com"),
                username: "reader",
                password: "test-password"
            )
        ) { error in
            #expect(
                error as? LocalAuthenticationError
                    == .credentialPersistenceFailed)
        }
        let failedCredentials = await failingStore.credentials(
            for: AccountID(rawValue: "account")
        )
        #expect(failedCredentials == nil)
    }

    @Test
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

        await assertThrowsErrorAsync(
            try await client.login(
                accountID: AccountID(rawValue: "account"),
                server: NormalizedServerURL("https://example.com"),
                username: "reader",
                password: "test-password"
            )
        ) { error in
            #expect(
                error as? LocalAuthenticationError
                    == .credentialStorageUnavailable)
        }
        let storedCredentials = await store.credentials(
            for: AccountID(rawValue: "account")
        )
        #expect(storedCredentials == nil)
    }

    @Test
    func testBearerAuthorizerAddsHeaderWithoutChangingURL() throws {
        let url = try #require(
            URL(string: "https://example.com/api/libraries?sort=title"))
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let authorized = try BearerRequestAuthorizer().authorize(
            request,
            accessToken: "access-token"
        )

        #expect(authorized.url == url)
        #expect(
            authorized.value(forHTTPHeaderField: "Authorization")
                == "Bearer access-token")
        #expect(authorized.url?.query == "sort=title")
    }

    @Test
    func testBearerAuthorizerRejectsUnsafeRequestOrToken() throws {
        var missingURL = URLRequest(
            url: try #require(URL(string: "https://example.com"))
        )
        missingURL.url = nil

        let scenarios: [(URLRequest, String, BearerAuthorizationError)] = [
            (missingURL, "access", .missingURL),
            (
                URLRequest(
                    url: try #require(
                        URL(string: "http://example.com/api/libraries"))
                ),
                "access",
                .insecureURL
            ),
            (
                URLRequest(
                    url: try #require(
                        URL(string: "https://user@example.com/api/libraries"))
                ),
                "access",
                .embeddedCredentials
            ),
            (
                URLRequest(
                    url: try #require(
                        URL(
                            string:
                                "https://example.com/api/libraries?TOKEN=secret"
                        ))
                ),
                "access",
                .tokenBearingURL
            ),
            (
                URLRequest(
                    url: try #require(
                        URL(string: "https://example.com/api/libraries"))
                ),
                "",
                .invalidAccessToken
            ),
            (
                URLRequest(
                    url: try #require(
                        URL(string: "https://example.com/api/libraries"))
                ),
                "bad\nheader",
                .invalidAccessToken
            ),
        ]

        for (request, token, expectedError) in scenarios {
            if let error = #expect(
                throws: (any Error).self,
                performing: {
                    try BearerRequestAuthorizer().authorize(
                        request,
                        accessToken: token
                    )
                })
            {
                #expect(error as? BearerAuthorizationError == expectedError)
            }
        }
    }

    @Test
    func testAuthenticationTokensAndUnknownUserTypeValidation() throws {
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try AuthenticationTokens(
                    accessToken: "",
                    refreshToken: "refresh"
                )
            })
        {
            #expect(error as? AuthenticationTokenError == .invalidAccessToken)
        }
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try AuthenticationTokens(
                    accessToken: "access",
                    refreshToken: "bad token"
                )
            })
        {
            #expect(error as? AuthenticationTokenError == .invalidRefreshToken)
        }

        let encoded = try JSONEncoder().encode(
            AudiobookshelfUserType.unknown("future-type")
        )
        #expect(
            try JSONDecoder().decode(
                AudiobookshelfUserType.self,
                from: encoded
            ) == .unknown("future-type"))
        #expect(AudiobookshelfUserType.root.rawValue == "root")
        #expect(AudiobookshelfUserType.admin.rawValue == "admin")
        #expect(AudiobookshelfUserType.user.rawValue == "user")
        #expect(AudiobookshelfUserType.guest.rawValue == "guest")

        let decodedTypes = try JSONDecoder().decode(
            [AudiobookshelfUserType].self,
            from: Data(
                #"["root","admin","user","guest","future-type"]"#.utf8
            )
        )
        #expect(
            decodedTypes == [
                .root, .admin, .user, .guest, .unknown("future-type"),
            ])

        let tokens = try AuthenticationTokens(
            accessToken: "access",
            refreshToken: "refresh"
        )
        #expect(
            try JSONDecoder().decode(
                AuthenticationTokens.self,
                from: JSONEncoder().encode(tokens)
            ) == tokens)

        for invalidJSON in [
            #"{"accessToken":"bad token","refreshToken":"refresh"}"#,
            #"{"accessToken":"access","refreshToken":"bad token"}"#,
        ] {
            #expect(
                throws: (any Error).self,
                performing: {
                    try JSONDecoder().decode(
                        AuthenticationTokens.self,
                        from: Data(invalidJSON.utf8)
                    )
                })
        }
    }

    @Test
    func testUserPermissionsDefaultsMissingKeysToFalse() throws {
        // Older accounts may be missing newly added permissions.
        let empty = try JSONDecoder().decode(
            UserPermissions.self,
            from: Data("{}".utf8)
        )
        #expect(!(empty.download))
        #expect(!(empty.createEReader))
        #expect(!(empty.accessAllLibraries))
        #expect(!(empty.selectedTagsNotAccessible))

        // This Audiobookshelf 2.36 example predates `createEreader`.
        let legacy = try JSONDecoder().decode(
            UserPermissions.self,
            from: Data(
                """
                {
                  "download": true,
                  "update": false,
                  "delete": false,
                  "upload": false,
                  "accessAllLibraries": true,
                  "accessAllTags": true,
                  "accessExplicitContent": true,
                  "selectedTagsNotAccessible": false
                }
                """.utf8
            )
        )
        #expect(legacy.download)
        #expect(legacy.accessAllLibraries)
        #expect(legacy.accessAllTags)
        #expect(legacy.accessExplicitContent)
        #expect(!(legacy.update))
        #expect(!(legacy.createEReader))
    }

    @Test
    func testLoginSucceedsWhenPermissionKeyMissing() async throws {
        // A missing permission must not prevent login.
        let payload = Data(
            """
            {
              "user": {
                "id": "user-id",
                "username": "reader",
                "type": "user",
                "permissions": {
                  "download": true,
                  "update": false,
                  "delete": false,
                  "upload": false,
                  "accessAllLibraries": true,
                  "accessAllTags": true,
                  "accessExplicitContent": true,
                  "selectedTagsNotAccessible": false
                },
                "librariesAccessible": [],
                "itemTagsSelected": [],
                "accessToken": "access-token",
                "refreshToken": "refresh-token"
              }
            }
            """.utf8
        )
        let transport = AuthenticationHTTPTransport(
            responses: [.json(payload), .json(payload)]
        )
        let store = RecordingCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let account = try await coordinator.login(
            accountID: AccountID(rawValue: "legacy-account"),
            server: try NormalizedServerURL("https://example.com"),
            username: "reader",
            password: "test-password"
        )
        #expect(account.user.username == "reader")
        #expect(!(account.user.permissions.createEReader))
        #expect(account.user.permissions.accessAllLibraries)
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
        let url = try #require(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: nil
            )?.first {
                $0.lastPathComponent == "\(name).json"
            })
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
