import Foundation
import XCTest

@testable import BleatCore

final class AuthenticatedRequestTests: XCTestCase {
    func testTwentyUnauthorizedRequestsShareOneRotatingRefresh() async throws {
        let accountID = AccountID(rawValue: "concurrent-account")
        let server = try NormalizedServerURL("https://example.com/prefix")
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
            for _ in 0..<20 {
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
        let correlations = await transport.requestCorrelations()
        XCTAssertEqual(Set(correlations).count, 20)
        XCTAssertTrue(
            Dictionary(grouping: correlations, by: { $0 })
                .values.allSatisfy { $0.count == 2 }
        )
        XCTAssertEqual(storedTokens, newTokens)
        XCTAssertEqual(saveCount, 1)
        XCTAssertFalse(requiresReauthentication)

        let refreshRequest = try XCTUnwrap(recordedRefreshRequest)
        XCTAssertEqual(refreshRequest.httpMethod, "POST")
        XCTAssertEqual(
            refreshRequest.url?.absoluteString,
            "https://example.com/prefix/auth/refresh"
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
        let server = try NormalizedServerURL("https://example.com")
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
            for _ in 0..<20 {
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

    func testConcurrentRejectionJoinsInFlightRefreshInsteadOfStaleStoreRead()
        async throws
    {
        let accountID = AccountID(rawValue: "join-in-flight")
        let server = try NormalizedServerURL("https://example.com")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let midTokens = try AuthenticationTokens(
            accessToken: "mid-access",
            refreshToken: "mid-refresh"
        )
        let finalTokens = try AuthenticationTokens(
            accessToken: "final-access",
            refreshToken: "final-refresh"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: oldTokens]
        )
        let transport = GatedMidFlightRefreshTransport(
            store: store,
            accountID: accountID,
            midTokens: midTokens,
            finalTokens: finalTokens,
            refreshSucceeds: true
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let request = try Self.request(for: .libraries, server: server)

        let taskA = Task { () -> HTTPResponse in
            try await coordinator.sendAuthenticated(
                request,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilRefreshStarted()

        let taskB = Task { () -> HTTPResponse in
            try await coordinator.sendAuthenticated(
                request,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilInitialSendBlocked()

        await transport.releaseRefresh()
        await transport.waitUntilMidSaved()
        await transport.releaseInitialSend()
        await transport.releaseMidSave()

        let responseA = try await taskA.value
        let responseB = try await taskB.value
        let counts = await transport.counts()
        let storedTokens = try await store.credentials(for: accountID)

        XCTAssertEqual(responseA.statusCode, 200)
        XCTAssertEqual(responseB.statusCode, 200)
        XCTAssertEqual(counts.refreshRequests, 1)
        XCTAssertEqual(counts.midAccessRequests, 0)
        XCTAssertEqual(counts.finalAccessRequests, 2)
        XCTAssertEqual(storedTokens, finalTokens)
    }

    func testJoinerRecordsOriginatorRejectedTokenInCompletedRefresh()
        async throws
    {
        let accountID = AccountID(rawValue: "originator-token")
        let server = try NormalizedServerURL("https://example.com")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let midTokens = try AuthenticationTokens(
            accessToken: "mid-access",
            refreshToken: "mid-refresh"
        )
        let finalTokens = try AuthenticationTokens(
            accessToken: "final-access",
            refreshToken: "final-refresh"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: oldTokens]
        )
        let transport = GatedMidFlightRefreshTransport(
            store: store,
            accountID: accountID,
            midTokens: midTokens,
            finalTokens: finalTokens,
            refreshSucceeds: false
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let request = try Self.request(for: .libraries, server: server)

        let taskA = Task { () -> HTTPResponse in
            try await coordinator.sendAuthenticated(
                request,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilRefreshStarted()

        let taskB = Task { () -> String in
            try await coordinator.recoverAccessToken(
                for: accountID,
                server: server,
                rejectedAccessToken: "other-token"
            )
        }
        await transport.releaseRefresh()
        await transport.waitUntilMidSaved()
        await transport.releaseMidSave()

        await assertThrowsErrorAsync(try await taskA.value) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .refreshRejected
            )
        }
        await assertThrowsErrorAsync(try await taskB.value) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .refreshRejected
            )
        }

        let recordedToken = await coordinator.completedRefreshes[
            accountID
        ]?.rejectedAccessToken
        XCTAssertEqual(recordedToken, "old-access")

        await assertThrowsErrorAsync(
            try await coordinator.recoverAccessToken(
                for: accountID,
                server: server,
                rejectedAccessToken: "old-access"
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .refreshRejected
            )
        }
        let counts = await transport.counts()
        XCTAssertEqual(counts.refreshRequests, 1)
    }

    func testConcurrentRejectionJoinsFailingInFlightRefresh() async throws {
        let accountID = AccountID(rawValue: "join-failing-refresh")
        let server = try NormalizedServerURL("https://example.com")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let midTokens = try AuthenticationTokens(
            accessToken: "mid-access",
            refreshToken: "mid-refresh"
        )
        let finalTokens = try AuthenticationTokens(
            accessToken: "final-access",
            refreshToken: "final-refresh"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: oldTokens]
        )
        let transport = GatedMidFlightRefreshTransport(
            store: store,
            accountID: accountID,
            midTokens: midTokens,
            finalTokens: finalTokens,
            refreshSucceeds: false
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let request = try Self.request(for: .libraries, server: server)

        let taskA = Task { () -> HTTPResponse in
            try await coordinator.sendAuthenticated(
                request,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilRefreshStarted()

        let taskB = Task { () -> HTTPResponse in
            try await coordinator.sendAuthenticated(
                request,
                route: .libraries,
                accountID: accountID,
                server: server
            )
        }
        await transport.waitUntilInitialSendBlocked()

        await transport.releaseRefresh()
        await transport.waitUntilMidSaved()
        await transport.releaseInitialSend()
        await transport.releaseMidSave()

        await assertThrowsErrorAsync(try await taskA.value) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .refreshRejected
            )
        }
        await assertThrowsErrorAsync(try await taskB.value) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .refreshRejected
            )
        }
        let counts = await transport.counts()
        let requiresReauthentication =
            await coordinator.requiresReauthentication(for: accountID)

        XCTAssertEqual(counts.refreshRequests, 1)
        XCTAssertEqual(counts.midAccessRequests, 0)
        XCTAssertTrue(requiresReauthentication)
    }

    func testTwentyUnauthorizedRequestsShareOneSavedPasswordRecovery()
        async throws
    {
        let accountID = AccountID(rawValue: "concurrent-saved-login")
        let server = try NormalizedServerURL("https://example.com")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let newTokens = try AuthenticationTokens(
            accessToken: "new-access",
            refreshToken: "new-refresh"
        )
        let nativeLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "user-id"),
            username: "reader",
            password: "saved-password"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: oldTokens],
            nativeLogins: [accountID: nativeLogin]
        )
        let transport = ConcurrentSavedLoginRecoveryTransport(
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
            for _ in 0..<20 {
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
        let counts = await transport.counts()
        let storedTokens = try await store.credentials(for: accountID)

        XCTAssertEqual(
            responses.map(\.statusCode),
            Array(repeating: 200, count: 20)
        )
        XCTAssertEqual(counts.oldAccessRequests, 20)
        XCTAssertEqual(counts.refreshRequests, 1)
        XCTAssertEqual(counts.loginRequests, 1)
        XCTAssertEqual(counts.authorizationRequests, 1)
        XCTAssertEqual(counts.newAccessRequests, 20)
        XCTAssertEqual(storedTokens, newTokens)
    }

    func testRejectedRefreshUsesSavedPasswordAndRetriesRequest() async throws {
        let accountID = AccountID(rawValue: "saved-login")
        let server = try NormalizedServerURL("https://example.com/prefix")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let newTokens = try AuthenticationTokens(
            accessToken: "new-access",
            refreshToken: "new-refresh"
        )
        let nativeLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "user-id"),
            username: "reader",
            password: "saved-password"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: oldTokens],
            nativeLogins: [accountID: nativeLogin]
        )
        let transport = ScriptedRequestTransport(responses: [
            .success(.init(data: Data(), statusCode: 401)),
            .success(.init(data: Data(), statusCode: 401)),
            .success(
                .json(
                    Self.authenticationJSON(
                        accessToken: newTokens.accessToken,
                        refreshToken: newTokens.refreshToken
                    ))),
            .success(.json(Self.authenticationJSON())),
            .success(.init(data: Data(), statusCode: 200)),
        ])
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
        let requests = await transport.recordedRequests()
        let savedTokens = try await store.credentials(for: accountID)
        let savedNativeLogin = try await store.nativeLoginCredentials(
            for: accountID
        )
        let requiresReauthentication =
            await coordinator.requiresReauthentication(for: accountID)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            requests.map(\.url?.path),
            [
                "/prefix/api/libraries",
                "/prefix/auth/refresh",
                "/prefix/login",
                "/prefix/api/authorize",
                "/prefix/api/libraries",
            ]
        )
        let loginBody = try XCTUnwrap(requests[2].httpBody)
        let loginObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: loginBody)
                as? [String: String]
        )
        XCTAssertEqual(
            loginObject,
            [
                "username": "reader",
                "password": "saved-password",
            ]
        )
        XCTAssertEqual(
            requests[3].value(forHTTPHeaderField: "Authorization"),
            "Bearer new-access"
        )
        XCTAssertEqual(
            requests[4].value(forHTTPHeaderField: "Authorization"),
            "Bearer new-access"
        )
        XCTAssertEqual(savedTokens, newTokens)
        XCTAssertEqual(savedNativeLogin, nativeLogin)
        XCTAssertFalse(requiresReauthentication)
    }

    func testRefreshContractFailuresUseSavedPasswordAndRetryRequest()
        async throws
    {
        let scenarios:
            [(
                name: String,
                refreshResult: Result<HTTPResponse, RequestTestError>,
                saveFailures: Int
            )] = [
                ("rejected", Self.response(statusCode: 401), 0),
                ("not found", Self.response(statusCode: 404), 0),
                ("server error", Self.response(statusCode: 503), 0),
                (
                    "malformed response",
                    .success(.json(Data("not-json".utf8))),
                    0
                ),
                (
                    "missing access token",
                    Self.authenticationResponse(
                        refreshToken: "rotated-refresh"
                    ),
                    0
                ),
                (
                    "missing refresh token",
                    Self.authenticationResponse(
                        accessToken: "rotated-access"
                    ),
                    0
                ),
                (
                    "invalid access token",
                    Self.authenticationResponse(
                        accessToken: "bad token",
                        refreshToken: "rotated-refresh"
                    ),
                    0
                ),
                (
                    "invalid refresh token",
                    Self.authenticationResponse(
                        accessToken: "rotated-access",
                        refreshToken: "bad token"
                    ),
                    0
                ),
                (
                    "rotated token persistence",
                    Self.authenticationResponse(
                        accessToken: "discarded-access",
                        refreshToken: "discarded-refresh"
                    ),
                    1
                ),
            ]

        for scenario in scenarios {
            let fixture = try SavedLoginRecoveryFixture(
                name: "contract-\(scenario.name)",
                responsesBeforeSuccessfulRecovery: [
                    .success(.init(data: Data(), statusCode: 401)),
                    scenario.refreshResult,
                ],
                saveFailuresRemaining: scenario.saveFailures
            )

            let response = try await fixture.send()
            let requests = await fixture.transport.recordedRequests()
            let storedTokens = try await fixture.store.credentials(
                for: fixture.accountID
            )
            let storedNativeLogin =
                try await fixture.store.nativeLoginCredentials(
                    for: fixture.accountID
                )
            let requiresReauthentication =
                await fixture.coordinator.requiresReauthentication(
                    for: fixture.accountID
                )

            XCTAssertEqual(response.statusCode, 200, scenario.name)
            XCTAssertEqual(
                requests.map(\.url?.path),
                SavedLoginRecoveryFixture.successfulRequestPaths,
                scenario.name
            )
            XCTAssertEqual(
                storedTokens,
                fixture.recoveredTokens,
                scenario.name
            )
            XCTAssertEqual(
                storedNativeLogin,
                fixture.nativeLogin,
                scenario.name
            )
            XCTAssertFalse(requiresReauthentication, scenario.name)
        }
    }

    func testSavedPasswordRejectionRemainsTyped() async throws {
        let accountID = AccountID(rawValue: "rejected-saved-login")
        let server = try NormalizedServerURL("https://example.com")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let nativeLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "user-id"),
            username: "reader",
            password: "old-password"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: oldTokens],
            nativeLogins: [accountID: nativeLogin]
        )
        let transport = ScriptedRequestTransport(responses: [
            .success(.init(data: Data(), statusCode: 401)),
            .success(.init(data: Data(), statusCode: 401)),
            .success(.init(data: Data(), statusCode: 401)),
            .success(.init(data: Data(), statusCode: 401)),
        ])
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        await assertThrowsErrorAsync(
            try await coordinator.sendAuthenticated(
                try Self.request(for: .libraries, server: server),
                route: .libraries,
                accountID: accountID,
                server: server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .automaticReauthenticationFailed(.invalidCredentials)
            )
        }
        await assertThrowsErrorAsync(
            try await coordinator.sendAuthenticated(
                try Self.request(for: .libraries, server: server),
                route: .libraries,
                accountID: accountID,
                server: server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .automaticReauthenticationFailed(.invalidCredentials)
            )
        }
        let savedTokens = try await store.credentials(for: accountID)
        let savedNativeLogin = try await store.nativeLoginCredentials(
            for: accountID
        )
        let requiresReauthentication =
            await coordinator.requiresReauthentication(for: accountID)
        let refreshCount = await transport.refreshCount()
        let requests = await transport.recordedRequests()
        XCTAssertEqual(savedTokens, oldTokens)
        XCTAssertEqual(savedNativeLogin, nativeLogin)
        XCTAssertTrue(requiresReauthentication)
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(
            requests.filter {
                $0.url?.path == "/login"
            }.count,
            1
        )
    }

    func testSavedLoginCannotChangeRemoteUserIdentity() async throws {
        let accountID = AccountID(rawValue: "identity-change")
        let server = try NormalizedServerURL("https://example.com")
        let tokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let nativeLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "user-id"),
            username: "reader",
            password: "saved-password"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: tokens],
            nativeLogins: [accountID: nativeLogin]
        )
        let transport = ScriptedRequestTransport(responses: [
            .success(.init(data: Data(), statusCode: 401)),
            .success(.init(data: Data(), statusCode: 401)),
            .success(
                .json(
                    Self.authenticationJSON(
                        userID: "other-user",
                        accessToken: "new-access",
                        refreshToken: "new-refresh"
                    ))),
            .success(.json(Self.authenticationJSON(userID: "other-user"))),
        ])
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        await assertThrowsErrorAsync(
            try await coordinator.sendAuthenticated(
                try Self.request(for: .libraries, server: server),
                route: .libraries,
                accountID: accountID,
                server: server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .automaticReauthenticationFailed(
                    .authorizedUserMismatch(
                        expected: "user-id",
                        actual: "other-user"
                    )
                )
            )
        }
        let retainedTokens = try await store.credentials(for: accountID)
        let requiresReauthentication =
            await coordinator.requiresReauthentication(for: accountID)
        XCTAssertEqual(retainedTokens, tokens)
        XCTAssertTrue(requiresReauthentication)
    }

    func testSavedLoginAuthorizationRejectionRequiresReauthentication()
        async throws
    {
        let accountID = AccountID(rawValue: "authorization-rejection")
        let server = try NormalizedServerURL("https://example.com")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let nativeLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "user-id"),
            username: "reader",
            password: "saved-password"
        )
        let store = RequestCredentialStore(
            credentials: [accountID: oldTokens],
            nativeLogins: [accountID: nativeLogin]
        )
        let transport = ScriptedRequestTransport(responses: [
            .success(.init(data: Data(), statusCode: 401)),
            .success(.init(data: Data(), statusCode: 401)),
            .success(
                .json(
                    Self.authenticationJSON(
                        accessToken: "new-access",
                        refreshToken: "new-refresh"
                    )
                )
            ),
            .success(.init(data: Data(), statusCode: 401)),
        ])
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        await assertThrowsErrorAsync(
            try await coordinator.sendAuthenticated(
                try Self.request(for: .libraries, server: server),
                route: .libraries,
                accountID: accountID,
                server: server
            )
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .automaticReauthenticationFailed(.tokenValidationFailed)
            )
        }
        let retainedTokens = try await store.credentials(for: accountID)
        let requiresReauthentication =
            await coordinator.requiresReauthentication(for: accountID)

        XCTAssertEqual(retainedTokens, oldTokens)
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
            await assertThrowsErrorAsync(
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
                .success(
                    .json(
                        Self.authenticationJSON(
                            accessToken: "rotated-access",
                            refreshToken: "rotated-refresh"
                        ))),
                .success(.init(data: Data(), statusCode: 401)),
            ]
        )

        await assertThrowsErrorAsync(
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
        let scenarios:
            [(
                Result<HTTPResponse, RequestTestError>,
                AuthenticatedRequestError,
                Bool
            )] = [
                (
                    .failure(.transport),
                    .refreshTransportFailed,
                    false
                ),
                (
                    .success(.init(data: Data(), statusCode: 401)),
                    .refreshRejected,
                    true
                ),
                (
                    .success(.init(data: Data(), statusCode: 503)),
                    .unexpectedRefreshStatus(503),
                    true
                ),
                (
                    .success(.json(Data("not-json".utf8))),
                    .malformedRefreshResponse,
                    true
                ),
                (
                    .success(
                        .json(
                            Self.authenticationJSON(
                                refreshToken: "refresh"
                            ))),
                    .missingAccessToken,
                    true
                ),
                (
                    .success(
                        .json(
                            Self.authenticationJSON(
                                accessToken: "access"
                            ))),
                    .missingRefreshToken,
                    true
                ),
                (
                    .success(
                        .json(
                            Self.authenticationJSON(
                                accessToken: "bad token",
                                refreshToken: "refresh"
                            ))),
                    .missingAccessToken,
                    true
                ),
                (
                    .success(
                        .json(
                            Self.authenticationJSON(
                                accessToken: "access",
                                refreshToken: "bad token"
                            ))),
                    .missingRefreshToken,
                    true
                ),
            ]

        for (
            refreshResult,
            expectedError,
            expectedReauthentication
        ) in scenarios {
            let fixture = try Fixture(
                responses: [
                    .success(.init(data: Data(), statusCode: 401)),
                    refreshResult,
                ]
            )
            await assertThrowsErrorAsync(
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
            XCTAssertEqual(
                requiresReauthentication,
                expectedReauthentication
            )
        }
    }

    func testRefreshTransportFailureIsNotCachedAndRetries() async throws {
        let fixture = try Fixture(
            responses: [
                .success(.init(data: Data(), statusCode: 401)),
                .failure(.transport),
                .success(.init(data: Data(), statusCode: 401)),
                .success(
                    .json(
                        Self.authenticationJSON(
                            accessToken: "new-access",
                            refreshToken: "new-refresh"
                        )
                    )
                ),
                .success(.init(data: Data(), statusCode: 200)),
            ]
        )

        await assertThrowsErrorAsync(
            try await fixture.send()
        ) { error in
            XCTAssertEqual(
                error as? AuthenticatedRequestError,
                .refreshTransportFailed
            )
        }
        let requiresReauthenticationAfterFailure =
            await fixture.coordinator.requiresReauthentication(
                for: fixture.accountID
            )
        let response = try await fixture.send()
        let requests = await fixture.transport.recordedRequests()
        let requiresReauthenticationAfterRetry =
            await fixture.coordinator.requiresReauthentication(
                for: fixture.accountID
            )

        XCTAssertFalse(requiresReauthenticationAfterFailure)
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            requests.map(\.url?.path),
            [
                "/api/libraries",
                "/auth/refresh",
                "/api/libraries",
                "/auth/refresh",
                "/api/libraries",
            ]
        )
        XCTAssertFalse(requiresReauthenticationAfterRetry)
    }

    func testMissingSavedCredentialsMemoizesConclusiveFailure() async throws {
        let fixture = try Fixture(
            responses: [
                .success(.init(data: Data(), statusCode: 401)),
                .success(.init(data: Data(), statusCode: 503)),
                .success(.init(data: Data(), statusCode: 401)),
            ]
        )

        for _ in 0..<2 {
            await assertThrowsErrorAsync(
                try await fixture.send()
            ) { error in
                XCTAssertEqual(
                    error as? AuthenticatedRequestError,
                    .unexpectedRefreshStatus(503)
                )
            }
        }
        let requests = await fixture.transport.recordedRequests()
        let requiresReauthentication =
            await fixture.coordinator.requiresReauthentication(
                for: fixture.accountID
            )

        XCTAssertEqual(
            requests.map(\.url?.path),
            [
                "/api/libraries",
                "/auth/refresh",
                "/api/libraries",
            ]
        )
        XCTAssertTrue(requiresReauthentication)
    }

    func testTransientSavedLoginFailuresAreNotCachedAndRetry()
        async throws
    {
        let scenarios:
            [(
                name: String,
                firstRecoveryResponses:
                    [Result<HTTPResponse, RequestTestError>],
                expectedError: AuthenticatedRequestError,
                saveFailures: Int
            )] = [
                (
                    "transport",
                    [.failure(.transport)],
                    .automaticReauthenticationTransportFailed,
                    0
                ),
                (
                    "contract",
                    [Self.response(statusCode: 503)],
                    .automaticReauthenticationFailed(
                        .unexpectedLoginStatus(503)
                    ),
                    0
                ),
                (
                    "persistence",
                    [
                        Self.authenticationResponse(
                            accessToken: "first-access",
                            refreshToken: "first-refresh"
                        ),
                        Self.authenticationResponse(),
                    ],
                    .automaticReauthenticationFailed(
                        .credentialPersistenceFailed
                    ),
                    1
                ),
            ]

        for scenario in scenarios {
            let fixture = try SavedLoginRecoveryFixture(
                name: "retryable-\(scenario.name)",
                responsesBeforeSuccessfulRecovery: [
                    .success(.init(data: Data(), statusCode: 401)),
                    .success(.init(data: Data(), statusCode: 503)),
                ]
                    + scenario.firstRecoveryResponses
                    + [
                        .success(.init(data: Data(), statusCode: 401)),
                        .success(.init(data: Data(), statusCode: 503)),
                    ],
                saveFailuresRemaining: scenario.saveFailures
            )

            await assertThrowsErrorAsync(
                try await fixture.send()
            ) { error in
                XCTAssertEqual(
                    error as? AuthenticatedRequestError,
                    scenario.expectedError,
                    scenario.name
                )
            }
            let requiresReauthenticationAfterFailure =
                await fixture.coordinator.requiresReauthentication(
                    for: fixture.accountID
                )
            let response = try await fixture.send()
            let requests = await fixture.transport.recordedRequests()
            let storedTokens = try await fixture.store.credentials(
                for: fixture.accountID
            )
            let requiresReauthenticationAfterRetry =
                await fixture.coordinator.requiresReauthentication(
                    for: fixture.accountID
                )

            XCTAssertFalse(
                requiresReauthenticationAfterFailure,
                scenario.name
            )
            XCTAssertEqual(response.statusCode, 200, scenario.name)
            XCTAssertEqual(
                requests.filter {
                    $0.url?.path == "/auth/refresh"
                }.count,
                2,
                scenario.name
            )
            XCTAssertEqual(
                storedTokens,
                fixture.recoveredTokens,
                scenario.name
            )
            XCTAssertFalse(
                requiresReauthenticationAfterRetry,
                scenario.name
            )
        }
    }

    func testMissingSessionTokensUseSynchronizedNativeLogin() async throws {
        let accountID = AccountID(rawValue: "cloud-account")
        let server = try NormalizedServerURL("https://example.com")
        let nativeLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "user-id"),
            username: "reader",
            password: "saved-password"
        )
        let recoveredTokens = try AuthenticationTokens(
            accessToken: "device-access",
            refreshToken: "device-refresh"
        )
        let store = RequestCredentialStore(
            credentials: [:],
            nativeLogins: [accountID: nativeLogin]
        )
        let transport = ScriptedRequestTransport(responses: [
            .success(
                .json(
                    Self.authenticationJSON(
                        accessToken: recoveredTokens.accessToken,
                        refreshToken: recoveredTokens.refreshToken
                    )
                )
            ),
            .success(.json(Self.authenticationJSON())),
            .success(.init(data: Data(), statusCode: 200)),
        ])
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
        let requestPaths = await transport.recordedRequests().map(\.url?.path)
        let storedTokens = try await store.credentials(for: accountID)
        let storedNativeLogin = try await store.nativeLoginCredentials(
            for: accountID
        )
        let requiresReauthentication =
            await coordinator
            .requiresReauthentication(for: accountID)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(
            requestPaths,
            ["/login", "/api/authorize", "/api/libraries"]
        )
        XCTAssertEqual(storedTokens, recoveredTokens)
        XCTAssertEqual(storedNativeLogin, nativeLogin)
        XCTAssertFalse(requiresReauthentication)
    }

    func testCredentialFailuresAreTyped() async throws {
        let missingFixture = try Fixture(
            responses: [],
            includeCredentials: false
        )
        await assertThrowsErrorAsync(
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
        await assertThrowsErrorAsync(
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
                .success(
                    .json(
                        Self.authenticationJSON(
                            accessToken: "new-access",
                            refreshToken: "new-refresh"
                        ))),
            ],
            credentialSaveFails: true
        )
        await assertThrowsErrorAsync(
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
        await assertThrowsErrorAsync(
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

        await assertThrowsErrorAsync(
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
        await assertThrowsErrorAsync(
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

        await assertThrowsErrorAsync(
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
        await assertThrowsErrorAsync(
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
        await assertThrowsErrorAsync(
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
        let server = try NormalizedServerURL("https://example.com")
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
        let server = try NormalizedServerURL("https://example.com")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let store = StaleReadCredentialStore(credentials: oldTokens)
        let transport = ScriptedRequestTransport(responses: [
            .success(.init(data: Data(), statusCode: 401)),
            .success(
                .json(
                    Self.authenticationJSON(
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
        let server = try NormalizedServerURL("https://example.com")
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

        await assertThrowsErrorAsync(
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

    private static func response(
        statusCode: Int
    ) -> Result<HTTPResponse, RequestTestError> {
        .success(.init(data: Data(), statusCode: statusCode))
    }

    private static func authenticationResponse(
        accessToken: String? = nil,
        refreshToken: String? = nil
    ) -> Result<HTTPResponse, RequestTestError> {
        .success(
            .json(
                authenticationJSON(
                    accessToken: accessToken,
                    refreshToken: refreshToken
                )
            )
        )
    }

    fileprivate static func authenticationJSON(
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
              }
            }
            """.utf8
        )
    }
}

private struct SavedLoginRecoveryFixture {
    static let successfulRequestPaths = [
        "/api/libraries",
        "/auth/refresh",
        "/login",
        "/api/authorize",
        "/api/libraries",
    ]

    let accountID: AccountID
    let server: NormalizedServerURL
    let recoveredTokens: AuthenticationTokens
    let nativeLogin: NativeLoginCredentials
    let store: RequestCredentialStore
    let transport: ScriptedRequestTransport
    let coordinator:
        AuthCoordinator<
            ScriptedRequestTransport,
            RequestCredentialStore
        >

    init(
        name: String,
        responsesBeforeSuccessfulRecovery:
            [Result<HTTPResponse, RequestTestError>],
        saveFailuresRemaining: Int
    ) throws {
        accountID = AccountID(rawValue: name)
        server = try NormalizedServerURL("https://example.com")
        recoveredTokens = try AuthenticationTokens(
            accessToken: "recovered-access",
            refreshToken: "recovered-refresh"
        )
        nativeLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "user-id"),
            username: "reader",
            password: "saved-password"
        )
        store = RequestCredentialStore(
            credentials: [
                accountID: try AuthenticationTokens(
                    accessToken: "old-access",
                    refreshToken: "old-refresh"
                )
            ],
            nativeLogins: [accountID: nativeLogin],
            saveFailuresRemaining: saveFailuresRemaining
        )
        transport = ScriptedRequestTransport(
            responses:
                responsesBeforeSuccessfulRecovery
                + [
                    .success(
                        .json(
                            AuthenticatedRequestTests.authenticationJSON(
                                accessToken: recoveredTokens.accessToken,
                                refreshToken: recoveredTokens.refreshToken
                            )
                        )
                    ),
                    .success(
                        .json(
                            AuthenticatedRequestTests.authenticationJSON()
                        )
                    ),
                    .success(.init(data: Data(), statusCode: 200)),
                ]
        )
        coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
    }

    func send() async throws -> HTTPResponse {
        try await coordinator.sendAuthenticated(
            URLRequest(
                url: try AudiobookshelfRouteBuilder(server: server)
                    .url(for: .libraries)
            ),
            route: .libraries,
            accountID: accountID,
            server: server
        )
    }
}

private struct Fixture {
    let accountID = AccountID(rawValue: "account")
    let server: NormalizedServerURL
    let store: RequestCredentialStore
    let transport: ScriptedRequestTransport
    let coordinator:
        AuthCoordinator<
            ScriptedRequestTransport,
            RequestCredentialStore
        >

    init(
        responses: [Result<HTTPResponse, RequestTestError>],
        includeCredentials: Bool = true,
        credentialReadFails: Bool = false,
        credentialSaveFails: Bool = false
    ) throws {
        server = try NormalizedServerURL("https://example.com")
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
    private var nativeLogins: [AccountID: NativeLoginCredentials]
    private var saves = 0
    private let readFails: Bool
    private let saveFails: Bool
    private var saveFailuresRemaining: Int

    init(
        credentials: [AccountID: AuthenticationTokens],
        nativeLogins: [AccountID: NativeLoginCredentials] = [:],
        readFails: Bool = false,
        saveFails: Bool = false,
        saveFailuresRemaining: Int = 0
    ) {
        stored = credentials
        self.nativeLogins = nativeLogins
        self.readFails = readFails
        self.saveFails = saveFails
        self.saveFailuresRemaining = saveFailuresRemaining
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
        if saveFails || saveFailuresRemaining > 0 {
            saveFailuresRemaining = max(0, saveFailuresRemaining - 1)
            throw RequestTestError.store
        }
        stored[accountID] = credentials
        saves += 1
    }

    func save(
        _ credentials: AuthenticationTokens,
        nativeLogin: NativeLoginCredentials,
        for accountID: AccountID
    ) async throws {
        if saveFails || saveFailuresRemaining > 0 {
            saveFailuresRemaining = max(0, saveFailuresRemaining - 1)
            throw RequestTestError.store
        }
        stored[accountID] = credentials
        nativeLogins[accountID] = nativeLogin
        saves += 1
    }

    func nativeLoginCredentials(
        for accountID: AccountID
    ) async throws -> NativeLoginCredentials? {
        if readFails {
            throw RequestTestError.store
        }
        return nativeLogins[accountID]
    }

    func deleteCredentials(for accountID: AccountID) {
        stored[accountID] = nil
        nativeLogins[accountID] = nil
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

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) throws -> HTTPResponse {
        let request = tracedRequest.request
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

    func recordedRequests() -> [URLRequest] {
        requests
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
    private var correlations: [UUID] = []
    private var unauthorizedWaiters:
        [CheckedContinuation<HTTPResponse, Never>] = []

    init(
        unauthorizedRequestCount: Int,
        oldTokens: AuthenticationTokens,
        newTokens: AuthenticationTokens
    ) {
        self.unauthorizedRequestCount = unauthorizedRequestCount
        self.oldTokens = oldTokens
        self.newTokens = newTokens
    }

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            refreshRequests.append(request)
            return .json(
                AuthenticatedRequestTests.authenticationJSON(
                    accessToken: newTokens.accessToken,
                    refreshToken: newTokens.refreshToken
                ))
        }
        correlations.append(tracedRequest.correlationID)

        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer \(oldTokens.accessToken)":
            oldAccessRequests += 1
            return await withCheckedContinuation { continuation in
                unauthorizedWaiters.append(continuation)
                guard
                    unauthorizedWaiters.count
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

    func requestCorrelations() -> [UUID] {
        correlations
    }
}

private actor ConcurrentRejectedRefreshTransport: HTTPTransport {
    private let unauthorizedRequestCount: Int
    private let accessToken: String
    private var ordinaryRequests = 0
    private var refreshRequests = 0
    private var unauthorizedWaiters:
        [CheckedContinuation<HTTPResponse, Never>] = []

    init(
        unauthorizedRequestCount: Int,
        accessToken: String
    ) {
        self.unauthorizedRequestCount = unauthorizedRequestCount
        self.accessToken = accessToken
    }

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            refreshRequests += 1
            return .init(data: Data(), statusCode: 401)
        }
        guard
            request.value(forHTTPHeaderField: "Authorization")
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

private actor GatedMidFlightRefreshTransport: HTTPTransport {
    private let store: RequestCredentialStore
    private let accountID: AccountID
    private let midTokens: AuthenticationTokens
    private let finalTokens: AuthenticationTokens
    private let refreshSucceeds: Bool
    private var refreshRequests = 0
    private var midAccessRequests = 0
    private var finalAccessRequests = 0
    private var oldAccessSends = 0
    private var refreshStarted = false
    private var midSaved = false
    private var refreshStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var midSavedWaiters: [CheckedContinuation<Void, Never>] = []
    private var initialSendWaiters: [CheckedContinuation<Void, Never>] = []
    private var refreshGate: CheckedContinuation<Void, Never>?
    private var midSaveGate: CheckedContinuation<HTTPResponse, Never>?
    private var initialSendGate: CheckedContinuation<Void, Never>?

    init(
        store: RequestCredentialStore,
        accountID: AccountID,
        midTokens: AuthenticationTokens,
        finalTokens: AuthenticationTokens,
        refreshSucceeds: Bool
    ) {
        self.store = store
        self.accountID = accountID
        self.midTokens = midTokens
        self.finalTokens = finalTokens
        self.refreshSucceeds = refreshSucceeds
    }

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
        if request.url?.path.hasSuffix("/auth/refresh") == true {
            refreshRequests += 1
            refreshStarted = true
            let startedWaiters = refreshStartedWaiters
            refreshStartedWaiters.removeAll()
            for waiter in startedWaiters {
                waiter.resume()
            }
            await withCheckedContinuation { continuation in
                refreshGate = continuation
            }
            try await store.save(midTokens, for: accountID)
            midSaved = true
            let savedWaiters = midSavedWaiters
            midSavedWaiters.removeAll()
            for waiter in savedWaiters {
                waiter.resume()
            }
            return await withCheckedContinuation { continuation in
                midSaveGate = continuation
            }
        }
        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer old-access":
            oldAccessSends += 1
            if oldAccessSends == 1 {
                return .init(data: Data(), statusCode: 401)
            }
            await withCheckedContinuation { continuation in
                let waiters = initialSendWaiters
                initialSendWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                initialSendGate = continuation
            }
            return .init(data: Data(), statusCode: 401)
        case "Bearer \(midTokens.accessToken)":
            midAccessRequests += 1
            return .init(data: Data(), statusCode: 401)
        case "Bearer \(finalTokens.accessToken)":
            finalAccessRequests += 1
            return .init(data: Data(), statusCode: 200)
        default:
            throw RequestTestError.unexpectedAuthorization
        }
    }

    func waitUntilRefreshStarted() async {
        if refreshStarted {
            return
        }
        await withCheckedContinuation { continuation in
            refreshStartedWaiters.append(continuation)
        }
    }

    func waitUntilMidSaved() async {
        if midSaved {
            return
        }
        await withCheckedContinuation { continuation in
            midSavedWaiters.append(continuation)
        }
    }

    func waitUntilInitialSendBlocked() async {
        if initialSendGate != nil {
            return
        }
        await withCheckedContinuation { continuation in
            initialSendWaiters.append(continuation)
        }
    }

    func releaseRefresh() {
        refreshGate?.resume()
        refreshGate = nil
    }

    func releaseMidSave() {
        let response: HTTPResponse
        if refreshSucceeds {
            response = .json(
                AuthenticatedRequestTests.authenticationJSON(
                    accessToken: finalTokens.accessToken,
                    refreshToken: finalTokens.refreshToken
                )
            )
        } else {
            response = .init(data: Data(), statusCode: 401)
        }
        midSaveGate?.resume(returning: response)
        midSaveGate = nil
    }

    func releaseInitialSend() {
        initialSendGate?.resume()
        initialSendGate = nil
    }

    func counts() -> (
        refreshRequests: Int,
        midAccessRequests: Int,
        finalAccessRequests: Int
    ) {
        (refreshRequests, midAccessRequests, finalAccessRequests)
    }
}

private actor ConcurrentSavedLoginRecoveryTransport: HTTPTransport {
    private let unauthorizedRequestCount: Int
    private let oldTokens: AuthenticationTokens
    private let newTokens: AuthenticationTokens
    private var oldAccessRequests = 0
    private var refreshRequests = 0
    private var loginRequests = 0
    private var authorizationRequests = 0
    private var newAccessRequests = 0
    private var unauthorizedWaiters:
        [CheckedContinuation<HTTPResponse, Never>] = []

    init(
        unauthorizedRequestCount: Int,
        oldTokens: AuthenticationTokens,
        newTokens: AuthenticationTokens
    ) {
        self.unauthorizedRequestCount = unauthorizedRequestCount
        self.oldTokens = oldTokens
        self.newTokens = newTokens
    }

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
        switch request.url?.path {
        case "/auth/refresh":
            refreshRequests += 1
            return .init(data: Data(), statusCode: 401)
        case "/login":
            loginRequests += 1
            return .json(
                AuthenticatedRequestTests.authenticationJSON(
                    accessToken: newTokens.accessToken,
                    refreshToken: newTokens.refreshToken
                ))
        case "/api/authorize":
            guard
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer \(newTokens.accessToken)"
            else {
                throw RequestTestError.unexpectedAuthorization
            }
            authorizationRequests += 1
            return .json(
                AuthenticatedRequestTests.authenticationJSON()
            )
        default:
            break
        }

        switch request.value(forHTTPHeaderField: "Authorization") {
        case "Bearer \(oldTokens.accessToken)":
            oldAccessRequests += 1
            return await withCheckedContinuation { continuation in
                unauthorizedWaiters.append(continuation)
                guard
                    unauthorizedWaiters.count
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
        refreshRequests: Int,
        loginRequests: Int,
        authorizationRequests: Int,
        newAccessRequests: Int
    ) {
        (
            oldAccessRequests,
            refreshRequests,
            loginRequests,
            authorizationRequests,
            newAccessRequests
        )
    }
}

private actor AccountIsolationTransport: HTTPTransport {
    func send(
        _ tracedRequest: TracedHTTPRequest
    ) -> HTTPResponse {
        let request = tracedRequest.request
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

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
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

extension HTTPResponse {
    fileprivate static func json(_ data: Data) -> HTTPResponse {
        HTTPResponse(
            data: data,
            statusCode: 200,
            headers: ["Content-Type": "application/json"]
        )
    }
}
