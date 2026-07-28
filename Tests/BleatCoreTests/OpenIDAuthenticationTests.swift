import AuthenticationServices
import Foundation
import XCTest

@testable import BleatCore

final class OpenIDAuthenticationTests: XCTestCase {
    @MainActor
    func testSystemBrowserFactoryMapsProviderCompletions() throws {
        let authorizationURL = try XCTUnwrap(
            URL(string: "https://identity.example/authorize")
        )
        let callbackURL = try XCTUnwrap(
            URL(string: "com.example.bleat:/oauth/callback")
        )
        let cases:
            [(
                URL?,
                (any Error)?,
                URL?,
                OpenIDBrowserError?
            )] = [
                (callbackURL, nil, callbackURL, nil),
                (
                    nil,
                    ASWebAuthenticationSessionError(.canceledLogin),
                    nil,
                    .cancelled
                ),
                (
                    nil,
                    OpenIDTestError.invalidBrowserRequest,
                    nil,
                    .failed
                ),
            ]

        for (providerURL, providerError, expectedURL, expectedError)
            in cases
        {
            let recorder = OpenIDCompletionRecorder()
            SystemOpenIDCompletionMapper.complete(
                callbackURL: providerURL,
                error: providerError
            ) { callbackURL, error in
                recorder.record(
                    callbackURL: callbackURL,
                    error: error
                )
            }
            let result = recorder.result()
            XCTAssertEqual(result.callbackURL, expectedURL)
            XCTAssertEqual(result.error, expectedError)
        }

        let systemFactory =
            SystemOpenIDWebAuthenticationSessionFactory()
        let session = systemFactory.makeSession(
            url: authorizationURL,
            callbackScheme: "com.example.bleat"
        ) { _, _ in }
        XCTAssertTrue(
            session is ASWebAuthenticationSession
        )

        let anchor = ASPresentationAnchor()
        let defaultBrowser = SystemOpenIDBrowserSession(
            anchorProvider: { anchor }
        )
        let presentationSession = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: "com.example.bleat"
        ) { _, _ in }
        XCTAssertTrue(
            defaultBrowser.presentationAnchor(
                for: presentationSession
            ) === anchor
        )
    }

    @MainActor
    func testSystemBrowserSessionCompletesAndConfiguresSession()
        async throws
    {
        let authorizationURL = try XCTUnwrap(
            URL(string: "https://identity.example/authorize?opaque=1")
        )
        let callbackURL = try XCTUnwrap(
            URL(
                string:
                    "com.example.bleat:/oauth/callback?code=code&state=state"
            )
        )
        let anchor = ASPresentationAnchor()
        let factory = OpenIDWebSessionFactory(
            behavior: .complete(callbackURL, nil)
        )
        let browser = SystemOpenIDBrowserSession(
            anchorProvider: { anchor },
            sessionFactory: factory
        )

        let result = try await browser.authenticate(
            at: authorizationURL,
            callbackScheme: "com.example.bleat"
        )

        XCTAssertEqual(result, callbackURL)
        let session = try XCTUnwrap(factory.sessions.first)
        XCTAssertEqual(session.authorizationURL, authorizationURL)
        XCTAssertEqual(
            session.callbackScheme,
            "com.example.bleat"
        )
        XCTAssertTrue(session.didStart)
        XCTAssertFalse(session.prefersEphemeralWebBrowserSession)
        XCTAssertTrue(session.presentationContextProvider === browser)

        let presentationSession = ASWebAuthenticationSession(
            url: authorizationURL,
            callbackURLScheme: "com.example.bleat"
        ) { _, _ in }
        XCTAssertTrue(
            browser.presentationAnchor(for: presentationSession) === anchor
        )
    }

    @MainActor
    func testSystemBrowserSessionMapsCancellationAndFailure()
        async throws
    {
        let authorizationURL = try XCTUnwrap(
            URL(string: "https://identity.example/authorize")
        )
        let cases: [(OpenIDWebSessionBehavior, OpenIDBrowserError)] = [
            (.complete(nil, .cancelled), .cancelled),
            (.complete(nil, .failed), .failed),
            (.refuseStart, .failed),
            (.completeThenRefuseStart(nil, .failed), .failed),
        ]

        for (behavior, expectedError) in cases {
            let factory = OpenIDWebSessionFactory(
                behavior: behavior
            )
            let browser = SystemOpenIDBrowserSession(
                anchorProvider: { ASPresentationAnchor() },
                sessionFactory: factory
            )

            do {
                _ = try await browser.authenticate(
                    at: authorizationURL,
                    callbackScheme: "com.example.bleat"
                )
                XCTFail("Expected system browser failure")
            } catch {
                XCTAssertEqual(
                    error as? OpenIDBrowserError,
                    expectedError
                )
            }
        }
    }

    @MainActor
    func testSystemBrowserSessionRejectsASecondActiveSession()
        async throws
    {
        let authorizationURL = try XCTUnwrap(
            URL(string: "https://identity.example/authorize")
        )
        let factory = OpenIDWebSessionFactory(behavior: .wait)
        let browser = SystemOpenIDBrowserSession(
            anchorProvider: { ASPresentationAnchor() },
            sessionFactory: factory
        )

        async let firstCallback = browser.authenticate(
            at: authorizationURL,
            callbackScheme: "com.example.bleat"
        )
        await factory.waitUntilSessionStarts()

        do {
            _ = try await browser.authenticate(
                at: authorizationURL,
                callbackScheme: "com.example.bleat"
            )
            XCTFail("Expected active-session rejection")
        } catch {
            XCTAssertEqual(
                error as? OpenIDBrowserError,
                .alreadyActive
            )
        }

        factory.sessions[0].finish(
            callbackURL: nil,
            error: .cancelled
        )
        do {
            _ = try await firstCallback
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(
                error as? OpenIDBrowserError,
                .cancelled
            )
        }
    }

    func testPKCEUsesRFC7636ChallengeAndSecureShapes() throws {
        XCTAssertEqual(
            PKCEGenerator.challenge(
                for:
                    "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
            ),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )

        let attempt = try PKCEGenerator().makeAttempt(
            callbackURL: Self.callbackURL
        )
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )

        XCTAssertEqual(attempt.verifier.count, 43)
        XCTAssertEqual(attempt.state.count, 43)
        XCTAssertEqual(attempt.challenge.count, 43)
        XCTAssertNotEqual(attempt.verifier, attempt.state)
        XCTAssertNil(
            attempt.verifier.rangeOfCharacter(
                from: allowed.inverted
            )
        )
        XCTAssertNil(
            attempt.state.rangeOfCharacter(
                from: allowed.inverted
            )
        )
        XCTAssertEqual(
            attempt.challenge,
            PKCEGenerator.challenge(for: attempt.verifier)
        )
    }

    func testPKCERandomFailureRemainsTyped() async throws {
        let transport = OpenIDTestTransport()
        let store = OpenIDCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let generator = PKCEGenerator { _ throws(PKCEGenerationError) in
            throw PKCEGenerationError.randomGenerationFailed(-50)
        }

        await XCTAssertThrowsErrorAsync(
            try await coordinator.loginWithOpenID(
                accountID: AccountID(rawValue: "account"),
                server: NormalizedServerURL("https://example.net"),
                callbackURL: Self.callbackURL,
                browser: OpenIDTestBrowser.success(
                    callbackURL: Self.callbackURL
                ),
                generator: generator
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenIDAuthenticationError,
                .randomGenerationFailed(-50)
            )
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    func testCallbackURLValidation() throws {
        XCTAssertEqual(
            Self.callbackURL.url.absoluteString,
            "com.example.bleat:/oauth/callback"
        )
        XCTAssertEqual(
            Self.callbackURL.callbackScheme,
            "com.example.bleat"
        )

        let cases: [(String, OpenIDCallbackURLValidationError)] = [
            ("not a url", .malformed),
            ("https://example.net/oauth/callback", .webSchemeNotAllowed),
            ("http://example.net/oauth/callback", .webSchemeNotAllowed),
            ("audiobookshelf:/oauth", .reservedScheme),
            ("com.example.bleat:", .missingCallbackPath),
            (
                "com.example.bleat://user@example.net/oauth/callback",
                .containsCredentials
            ),
            (
                "com.example.bleat:/oauth/callback?state=secret",
                .containsQueryOrFragment
            ),
            (
                "com.example.bleat:/oauth/callback#fragment",
                .containsQueryOrFragment
            ),
        ]

        for (value, expectedError) in cases {
            XCTAssertThrowsError(
                try OpenIDCallbackURL(value)
            ) { error in
                XCTAssertEqual(
                    error as? OpenIDCallbackURLValidationError,
                    expectedError
                )
            }
        }
    }

    func testCallbackRequiresExactURLStateAndCode() throws {
        let expectedState = "expected-state"
        let valid = try XCTUnwrap(
            URL(
                string:
                    "com.example.bleat:/oauth/callback?code=code&state=expected-state"
            )
        )
        let values = try Self.callbackURL.authorizationValues(
            from: valid,
            expectedState: expectedState
        )
        XCTAssertEqual(values.code, "code")
        XCTAssertEqual(values.state, expectedState)

        let invalidURLs: [(String, OpenIDAuthenticationError)] = [
            (
                "other.scheme:/oauth/callback?code=code&state=expected-state",
                .invalidCallbackURL
            ),
            (
                "com.example.bleat:/different?code=code&state=expected-state",
                .invalidCallbackURL
            ),
            (
                "com.example.bleat:/oauth/callback?code=code&state=expected-state#fragment",
                .invalidCallbackURL
            ),
            (
                "com.example.bleat:/oauth/callback?code=code",
                .missingState
            ),
            (
                "com.example.bleat:/oauth/callback?code=code&state=",
                .missingState
            ),
            (
                "com.example.bleat:/oauth/callback?code=code&state=one&state=two",
                .missingState
            ),
            (
                "com.example.bleat:/oauth/callback?code=code&state=wrong",
                .stateMismatch
            ),
            (
                "com.example.bleat:/oauth/callback?state=expected-state",
                .missingAuthorizationCode
            ),
            (
                "com.example.bleat:/oauth/callback?code=&state=expected-state",
                .missingAuthorizationCode
            ),
            (
                "com.example.bleat:/oauth/callback?code=one&code=two&state=expected-state",
                .missingAuthorizationCode
            ),
        ]

        for (value, expectedError) in invalidURLs {
            let callback = try XCTUnwrap(URL(string: value))
            XCTAssertThrowsError(
                try Self.callbackURL.authorizationValues(
                    from: callback,
                    expectedState: expectedState
                )
            ) { error in
                XCTAssertEqual(
                    error as? OpenIDAuthenticationError,
                    expectedError
                )
            }
        }
    }

    func testCompleteCookieBoundFlowValidatesThenPersists() async throws {
        let random = DeterministicRandomData()
        let transport = OpenIDTestTransport(
            exchangeData: try Self.fixture(named: "login-tokens"),
            authorizationData: try Self.fixture(named: "authorize")
        )
        let store = OpenIDCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let accountID = AccountID(rawValue: "oidc-account")
        let server = try NormalizedServerURL(
            "https://example.net/audiobookshelf"
        )

        let account = try await coordinator.loginWithOpenID(
            accountID: accountID,
            server: server,
            callbackURL: Self.callbackURL,
            browser: OpenIDTestBrowser.success(
                callbackURL: Self.callbackURL
            ),
            generator: PKCEGenerator(randomData: random.data)
        )

        XCTAssertEqual(account.id, accountID)
        XCTAssertEqual(account.server, server)
        XCTAssertEqual(account.user.username, "fixture-root")
        XCTAssertEqual(
            account.user.id,
            UserID(rawValue: "fixture-user")
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(
            requests.map(\.url?.path),
            [
                "/audiobookshelf/auth/openid",
                "/audiobookshelf/auth/openid/callback",
                "/audiobookshelf/api/authorize",
            ]
        )

        let beginItems = try Self.queryItems(from: requests[0])
        let verifier = Self.base64URL(
            Data((0..<32).map { UInt8($0) })
        )
        let state = Self.base64URL(
            Data((32..<64).map(UInt8.init))
        )
        XCTAssertEqual(
            beginItems,
            [
                "code_challenge": PKCEGenerator.challenge(
                    for: verifier
                ),
                "code_challenge_method": "S256",
                "redirect_uri":
                    Self.callbackURL.url.absoluteString,
                "response_type": "code",
                "state": state,
                "client_id": "Bleat",
            ]
        )
        XCTAssertEqual(requests[0].httpMethod, "GET")

        let exchangeItems = try Self.queryItems(from: requests[1])
        XCTAssertEqual(
            exchangeItems,
            [
                "state": state,
                "code": "authorization-code",
                "code_verifier": verifier,
            ]
        )
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertEqual(
            requests[2].value(forHTTPHeaderField: "Authorization"),
            "Bearer fixture-access-token"
        )
        XCTAssertNil(requests[2].url?.query)

        let stored = await store.credentials(for: accountID)
        XCTAssertEqual(
            stored,
            try AuthenticationTokens(
                accessToken: "fixture-access-token",
                refreshToken: "fixture-refresh-token"
            )
        )
        let clearCount = await transport.clearCount()
        let hasCookieSession = await transport.hasCookieSession()
        let openIDAttempt = await coordinator.openIDAttempt
        XCTAssertEqual(clearCount, 2)
        XCTAssertFalse(hasCookieSession)
        XCTAssertNil(openIDAttempt)
    }

    func testBeginRejectsInvalidResponsesAndCleansUp() async throws {
        let cases:
            [(
                OpenIDTestTransport.Configuration,
                OpenIDAuthenticationError
            )] = [
                (
                    .init(beginStatus: 200),
                    .unexpectedAuthorizationRedirectStatus(200)
                ),
                (
                    .init(providerLocation: nil),
                    .missingProviderRedirect
                ),
                (
                    .init(providerLocation: "http://idp.example/authorize"),
                    .invalidProviderRedirect
                ),
                (
                    .init(
                        providerLocation:
                            "https://user@idp.example/authorize"
                    ),
                    .invalidProviderRedirect
                ),
            ]

        for (configuration, expectedError) in cases {
            let transport = OpenIDTestTransport(
                configuration: configuration
            )
            let store = OpenIDCredentialStore()
            let coordinator = AuthCoordinator(
                transport: transport,
                credentialStore: store
            )

            await XCTAssertThrowsErrorAsync(
                try await coordinator.loginWithOpenID(
                    accountID: AccountID(rawValue: "account"),
                    server: NormalizedServerURL("https://example.net"),
                    callbackURL: Self.callbackURL,
                    browser: OpenIDTestBrowser.success(
                        callbackURL: Self.callbackURL
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? OpenIDAuthenticationError,
                    expectedError
                )
            }
            let clearCount = await transport.clearCount()
            let openIDAttempt = await coordinator.openIDAttempt
            let saveCount = await store.saveCount()
            XCTAssertEqual(clearCount, 2)
            XCTAssertNil(openIDAttempt)
            XCTAssertEqual(saveCount, 0)
        }
    }

    func testBrowserCancellationAndFailureCleanUp() async throws {
        let cases: [(OpenIDBrowserError, OpenIDAuthenticationError)] = [
            (.cancelled, .browserCancelled),
            (.alreadyActive, .browserFailed),
            (.failed, .browserFailed),
        ]

        for (browserError, expectedError) in cases {
            let transport = OpenIDTestTransport()
            let store = OpenIDCredentialStore()
            let coordinator = AuthCoordinator(
                transport: transport,
                credentialStore: store
            )

            await XCTAssertThrowsErrorAsync(
                try await coordinator.loginWithOpenID(
                    accountID: AccountID(rawValue: "account"),
                    server: NormalizedServerURL("https://example.net"),
                    callbackURL: Self.callbackURL,
                    browser: OpenIDTestBrowser(
                        result: .failure(browserError)
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? OpenIDAuthenticationError,
                    expectedError
                )
            }
            let clearCount = await transport.clearCount()
            let hasCookieSession = await transport.hasCookieSession()
            let saveCount = await store.saveCount()
            XCTAssertEqual(clearCount, 2)
            XCTAssertFalse(hasCookieSession)
            XCTAssertEqual(saveCount, 0)
        }

        let transport = OpenIDTestTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: OpenIDCredentialStore()
        )
        await XCTAssertThrowsErrorAsync(
            try await coordinator.loginWithOpenID(
                accountID: AccountID(rawValue: "account"),
                server: NormalizedServerURL("https://example.net"),
                callbackURL: Self.callbackURL,
                browser: OpenIDTestBrowser(result: .unexpectedFailure)
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenIDAuthenticationError,
                .browserFailed
            )
        }
    }

    func testInvalidBrowserCallbacksNeverReachExchange() async throws {
        let callbacks: [(URL, OpenIDAuthenticationError)] = [
            (
                try XCTUnwrap(
                    URL(
                        string:
                            "other.scheme:/oauth/callback?code=code&state=state"
                    )
                ),
                .invalidCallbackURL
            ),
            (
                try XCTUnwrap(
                    URL(
                        string:
                            "com.example.bleat:/oauth/callback?code=code"
                    )
                ),
                .missingState
            ),
            (
                try XCTUnwrap(
                    URL(
                        string:
                            "com.example.bleat:/oauth/callback?code=code&state=wrong"
                    )
                ),
                .stateMismatch
            ),
        ]

        for (callback, expectedError) in callbacks {
            let transport = OpenIDTestTransport()
            let store = OpenIDCredentialStore()
            let coordinator = AuthCoordinator(
                transport: transport,
                credentialStore: store
            )

            await XCTAssertThrowsErrorAsync(
                try await coordinator.loginWithOpenID(
                    accountID: AccountID(rawValue: "account"),
                    server: NormalizedServerURL("https://example.net"),
                    callbackURL: Self.callbackURL,
                    browser: OpenIDTestBrowser(
                        result: .callback(callback)
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? OpenIDAuthenticationError,
                    expectedError
                )
            }

            let requests = await transport.recordedRequests()
            let clearCount = await transport.clearCount()
            let saveCount = await store.saveCount()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(clearCount, 2)
            XCTAssertEqual(saveCount, 0)
        }
    }

    func testCallbackWithoutCodeNeverReachesExchange() async throws {
        let transport = OpenIDTestTransport()
        let store = OpenIDCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.loginWithOpenID(
                accountID: AccountID(rawValue: "account"),
                server: NormalizedServerURL("https://example.net"),
                callbackURL: Self.callbackURL,
                browser: OpenIDTestBrowser(
                    result: .missingCode(Self.callbackURL)
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenIDAuthenticationError,
                .missingAuthorizationCode
            )
        }

        let requests = await transport.recordedRequests()
        let clearCount = await transport.clearCount()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(clearCount, 2)
    }

    func testConcurrentAttemptIsRejectedWithoutDisturbingActiveFlow()
        async throws
    {
        let transport = OpenIDTestTransport()
        let store = OpenIDCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let gate = OpenIDBrowserGate()
        let browser = SuspendingOpenIDBrowser(gate: gate)
        let accountID = AccountID(rawValue: "account")
        let server = try NormalizedServerURL("https://example.net")

        async let firstAttempt = coordinator.loginWithOpenID(
            accountID: accountID,
            server: server,
            callbackURL: Self.callbackURL,
            browser: browser
        )
        await gate.waitUntilEntered()

        await XCTAssertThrowsErrorAsync(
            try await coordinator.loginWithOpenID(
                accountID: AccountID(rawValue: "second-account"),
                server: server,
                callbackURL: Self.callbackURL,
                browser: OpenIDTestBrowser.success(
                    callbackURL: Self.callbackURL
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenIDAuthenticationError,
                .attemptAlreadyInProgress
            )
        }

        await gate.fail(with: .cancelled)
        var firstError: OpenIDAuthenticationError?
        do {
            _ = try await firstAttempt
        } catch let error as OpenIDAuthenticationError {
            firstError = error
        }
        let clearCount = await transport.clearCount()
        let requests = await transport.recordedRequests()
        let openIDAttempt = await coordinator.openIDAttempt
        XCTAssertEqual(firstError, .browserCancelled)
        XCTAssertEqual(clearCount, 2)
        XCTAssertEqual(requests.count, 1)
        XCTAssertNil(openIDAttempt)
    }

    func testExchangeFailuresNeverPersistAndAlwaysCleanUp() async throws {
        let loginData = try Self.fixture(named: "login-tokens")
        let cases:
            [(
                OpenIDTestTransport.Configuration,
                Data?,
                OpenIDAuthenticationError
            )] = [
                (
                    .init(exchangeStatus: 401),
                    nil,
                    .unexpectedExchangeStatus(401)
                ),
                (
                    .init(),
                    Data("not-json".utf8),
                    .malformedExchangeResponse
                ),
                (
                    .init(),
                    Self.authenticationJSON(refreshToken: "refresh"),
                    .missingAccessToken
                ),
                (
                    .init(),
                    Self.authenticationJSON(accessToken: "access"),
                    .missingRefreshToken
                ),
                (
                    .init(),
                    Self.authenticationJSON(
                        accessToken: "bad token",
                        refreshToken: "refresh"
                    ),
                    .missingAccessToken
                ),
                (
                    .init(),
                    Self.authenticationJSON(
                        accessToken: "access",
                        refreshToken: "bad token"
                    ),
                    .missingRefreshToken
                ),
            ]

        for (configuration, customData, expectedError) in cases {
            let transport = OpenIDTestTransport(
                configuration: configuration,
                exchangeData: customData ?? loginData
            )
            let store = OpenIDCredentialStore()
            let coordinator = AuthCoordinator(
                transport: transport,
                credentialStore: store
            )

            await XCTAssertThrowsErrorAsync(
                try await coordinator.loginWithOpenID(
                    accountID: AccountID(rawValue: "account"),
                    server: NormalizedServerURL("https://example.net"),
                    callbackURL: Self.callbackURL,
                    browser: OpenIDTestBrowser.success(
                        callbackURL: Self.callbackURL
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? OpenIDAuthenticationError,
                    expectedError
                )
            }
            let clearCount = await transport.clearCount()
            let saveCount = await store.saveCount()
            XCTAssertEqual(clearCount, 2)
            XCTAssertEqual(saveCount, 0)
        }
    }

    func testAuthorizationAndPersistenceFailuresRemainTyped() async throws {
        let loginData = try Self.fixture(named: "login-tokens")
        let authorizationData = try Self.fixture(named: "authorize")
        let cases:
            [(
                OpenIDTestTransport.Configuration,
                Data?,
                Bool,
                OpenIDAuthenticationError
            )] = [
                (
                    .init(authorizationStatus: 401),
                    nil,
                    false,
                    .tokenValidationFailed
                ),
                (
                    .init(authorizationStatus: 403),
                    nil,
                    false,
                    .unexpectedAuthorizationStatus(403)
                ),
                (
                    .init(),
                    Data("not-json".utf8),
                    false,
                    .malformedAuthorizationResponse
                ),
                (
                    .init(),
                    Self.authenticationJSON(userID: "different-user"),
                    false,
                    .authorizedUserMismatch(
                        expected: "fixture-user",
                        actual: "different-user"
                    )
                ),
                (
                    .init(),
                    authorizationData,
                    true,
                    .credentialPersistenceFailed
                ),
            ]

        for (configuration, customData, failStore, expectedError) in cases {
            let transport = OpenIDTestTransport(
                configuration: configuration,
                exchangeData: loginData,
                authorizationData: customData ?? authorizationData
            )
            let store = OpenIDCredentialStore(
                shouldFailSave: failStore
            )
            let coordinator = AuthCoordinator(
                transport: transport,
                credentialStore: store
            )

            await XCTAssertThrowsErrorAsync(
                try await coordinator.loginWithOpenID(
                    accountID: AccountID(rawValue: "account"),
                    server: NormalizedServerURL("https://example.net"),
                    callbackURL: Self.callbackURL,
                    browser: OpenIDTestBrowser.success(
                        callbackURL: Self.callbackURL
                    )
                )
            ) { error in
                XCTAssertEqual(
                    error as? OpenIDAuthenticationError,
                    expectedError
                )
            }
            let clearCount = await transport.clearCount()
            XCTAssertEqual(clearCount, 2)
            let stored = await store.credentials(
                for: AccountID(rawValue: "account")
            )
            XCTAssertNil(stored)
        }
    }

    func testInvalidAccountDoesNotTouchAttemptOrCookies() async throws {
        let transport = OpenIDTestTransport()
        let store = OpenIDCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )

        await XCTAssertThrowsErrorAsync(
            try await coordinator.loginWithOpenID(
                accountID: AccountID(rawValue: ""),
                server: NormalizedServerURL("https://example.net"),
                callbackURL: Self.callbackURL,
                browser: OpenIDTestBrowser.success(
                    callbackURL: Self.callbackURL
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? OpenIDAuthenticationError,
                .invalidAccountID
            )
        }
        let clearCount = await transport.clearCount()
        let openIDAttempt = await coordinator.openIDAttempt
        XCTAssertEqual(clearCount, 0)
        XCTAssertNil(openIDAttempt)
    }

    private static let callbackURL = try! OpenIDCallbackURL(
        "com.example.bleat:/oauth/callback"
    )

    private static func queryItems(
        from request: URLRequest
    ) throws -> [String: String] {
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(
            URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        )
        return Dictionary(
            uniqueKeysWithValues: try XCTUnwrap(components.queryItems)
                .map { ($0.name, $0.value ?? "") }
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

    fileprivate static func authenticationJSON(
        userID: String = "fixture-user",
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
                "username": "fixture-root",
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

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private final class DeterministicRandomData: @unchecked Sendable {
    private let lock = NSLock()
    private var nextByte: UInt8 = 0

    func data(
        count: Int
    ) throws(PKCEGenerationError) -> Data {
        lock.withLock {
            let bytes = (0..<count).map { _ -> UInt8 in
                defer {
                    nextByte &+= 1
                }
                return nextByte
            }
            return Data(bytes)
        }
    }
}

private final class OpenIDCompletionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callbackURL: URL?
    private var error: OpenIDBrowserError?

    func record(
        callbackURL: URL?,
        error: OpenIDBrowserError?
    ) {
        lock.withLock {
            self.callbackURL = callbackURL
            self.error = error
        }
    }

    func result() -> (
        callbackURL: URL?,
        error: OpenIDBrowserError?
    ) {
        lock.withLock {
            (callbackURL, error)
        }
    }
}

private enum OpenIDWebSessionBehavior: Sendable {
    case complete(URL?, OpenIDBrowserError?)
    case refuseStart
    case completeThenRefuseStart(URL?, OpenIDBrowserError?)
    case wait
}

@MainActor
private final class OpenIDWebSessionFactory:
    OpenIDWebAuthenticationSessionFactory
{
    let behavior: OpenIDWebSessionBehavior
    private(set) var sessions: [OpenIDWebSession] = []

    init(behavior: OpenIDWebSessionBehavior) {
        self.behavior = behavior
    }

    func makeSession(
        url: URL,
        callbackScheme: String,
        completion:
            @escaping @Sendable (URL?, OpenIDBrowserError?) -> Void
    ) -> any OpenIDWebAuthenticationSession {
        let session = OpenIDWebSession(
            authorizationURL: url,
            callbackScheme: callbackScheme,
            behavior: behavior,
            completion: completion
        )
        sessions.append(session)
        return session
    }

    func waitUntilSessionStarts() async {
        while sessions.first?.didStart != true {
            await Task.yield()
        }
    }
}

@MainActor
private final class OpenIDWebSession: OpenIDWebAuthenticationSession {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    var prefersEphemeralWebBrowserSession = true

    let authorizationURL: URL
    let callbackScheme: String
    private let behavior: OpenIDWebSessionBehavior
    private let completion: @Sendable (URL?, OpenIDBrowserError?) -> Void
    private(set) var didStart = false

    init(
        authorizationURL: URL,
        callbackScheme: String,
        behavior: OpenIDWebSessionBehavior,
        completion:
            @escaping @Sendable (URL?, OpenIDBrowserError?) -> Void
    ) {
        self.authorizationURL = authorizationURL
        self.callbackScheme = callbackScheme
        self.behavior = behavior
        self.completion = completion
    }

    func start() -> Bool {
        didStart = true
        switch behavior {
        case .complete(let callbackURL, let error):
            completion(callbackURL, error)
            return true
        case .refuseStart:
            return false
        case .completeThenRefuseStart(let callbackURL, let error):
            completion(callbackURL, error)
            return false
        case .wait:
            return true
        }
    }

    func finish(
        callbackURL: URL?,
        error: OpenIDBrowserError?
    ) {
        completion(callbackURL, error)
    }
}

private struct OpenIDTestBrowser: OpenIDBrowserSession {
    enum Result: Sendable {
        case success(OpenIDCallbackURL)
        case callback(URL)
        case missingCode(OpenIDCallbackURL)
        case failure(OpenIDBrowserError)
        case unexpectedFailure
    }

    let result: Result

    static func success(
        callbackURL: OpenIDCallbackURL
    ) -> OpenIDTestBrowser {
        OpenIDTestBrowser(result: .success(callbackURL))
    }

    @MainActor
    func authenticate(
        at authorizationURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        switch result {
        case .success(let callbackURL):
            guard authorizationURL.scheme == "https",
                authorizationURL.host == "idp.example",
                callbackScheme == callbackURL.callbackScheme,
                let components = URLComponents(
                    url: authorizationURL,
                    resolvingAgainstBaseURL: false
                ),
                let state = components.queryItems?
                    .first(where: { $0.name == "state" })?.value,
                var callback = URLComponents(
                    url: callbackURL.url,
                    resolvingAgainstBaseURL: false
                )
            else {
                throw OpenIDTestError.invalidBrowserRequest
            }
            callback.queryItems = [
                URLQueryItem(
                    name: "code",
                    value: "authorization-code"
                ),
                URLQueryItem(name: "state", value: state),
            ]
            guard let callbackURL = callback.url else {
                throw OpenIDTestError.invalidBrowserRequest
            }
            return callbackURL
        case .callback(let url):
            return url
        case .missingCode(let callbackURL):
            guard
                let components = URLComponents(
                    url: authorizationURL,
                    resolvingAgainstBaseURL: false
                ),
                let state = components.queryItems?
                    .first(where: { $0.name == "state" })?.value,
                var callback = URLComponents(
                    url: callbackURL.url,
                    resolvingAgainstBaseURL: false
                )
            else {
                throw OpenIDTestError.invalidBrowserRequest
            }
            callback.queryItems = [
                URLQueryItem(name: "state", value: state)
            ]
            guard let callbackURL = callback.url else {
                throw OpenIDTestError.invalidBrowserRequest
            }
            return callbackURL
        case .failure(let error):
            throw error
        case .unexpectedFailure:
            throw OpenIDTestError.invalidBrowserRequest
        }
    }
}

private struct SuspendingOpenIDBrowser: OpenIDBrowserSession {
    let gate: OpenIDBrowserGate

    @MainActor
    func authenticate(
        at authorizationURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        await gate.enter()
        return try await gate.waitForResolution()
    }
}

private actor OpenIDBrowserGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var resolution: Result<URL, OpenIDBrowserError>?
    private var resolutionWaiter: CheckedContinuation<URL, any Error>?

    func enter() {
        entered = true
        for waiter in entryWaiters {
            waiter.resume()
        }
        entryWaiters.removeAll()
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func waitForResolution() async throws -> URL {
        if let resolution {
            return try resolution.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            resolutionWaiter = continuation
        }
    }

    func fail(with error: OpenIDBrowserError) {
        if let resolutionWaiter {
            self.resolutionWaiter = nil
            resolutionWaiter.resume(throwing: error)
        } else {
            resolution = .failure(error)
        }
    }
}

private actor OpenIDTestTransport: OpenIDSessionTransport {
    struct Configuration: Sendable {
        var beginStatus = 302
        var providerLocation: String? =
            "https://idp.example/authorize"
        var exchangeStatus = 200
        var authorizationStatus = 200
    }

    private let configuration: Configuration
    private let exchangeData: Data
    private let authorizationData: Data
    private var requests: [URLRequest] = []
    private var cookieSession = false
    private var clears = 0

    init(
        configuration: Configuration = .init(),
        exchangeData: Data =
            OpenIDAuthenticationTests
            .authenticationJSON(
                accessToken: "fixture-access-token",
                refreshToken: "fixture-refresh-token"
            ),
        authorizationData: Data =
            OpenIDAuthenticationTests
            .authenticationJSON()
    ) {
        self.configuration = configuration
        self.exchangeData = exchangeData
        self.authorizationData = authorizationData
    }

    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard let path = request.url?.path else {
            throw OpenIDTestError.invalidRequest
        }

        if path.hasSuffix("/auth/openid") {
            cookieSession = true
            var location = configuration.providerLocation
            if let baseLocation = location,
                let requestURL = request.url,
                let components = URLComponents(
                    url: requestURL,
                    resolvingAgainstBaseURL: false
                ),
                let state = components.queryItems?
                    .first(where: { $0.name == "state" })?.value
            {
                location = "\(baseLocation)?state=\(state)"
            }
            return HTTPResponse(
                data: Data(),
                statusCode: configuration.beginStatus,
                headers: location.map { ["Location": $0] } ?? [:],
                url: request.url
            )
        }
        if path.hasSuffix("/auth/openid/callback") {
            guard cookieSession else {
                return HTTPResponse(
                    data: Data(),
                    statusCode: 400,
                    url: request.url
                )
            }
            return HTTPResponse(
                data: exchangeData,
                statusCode: configuration.exchangeStatus,
                headers: ["Content-Type": "application/json"],
                url: request.url
            )
        }
        if path.hasSuffix("/api/authorize") {
            return HTTPResponse(
                data: authorizationData,
                statusCode: configuration.authorizationStatus,
                headers: ["Content-Type": "application/json"],
                url: request.url
            )
        }
        throw OpenIDTestError.invalidRequest
    }

    func clearSession() {
        cookieSession = false
        clears += 1
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func clearCount() -> Int {
        clears
    }

    func hasCookieSession() -> Bool {
        cookieSession
    }
}

private actor OpenIDCredentialStore: AccountCredentialStore {
    private var stored: [AccountID: AuthenticationTokens] = [:]
    private var saves = 0
    private let shouldFailSave: Bool

    init(shouldFailSave: Bool = false) {
        self.shouldFailSave = shouldFailSave
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
        if shouldFailSave {
            throw OpenIDTestError.storeFailure
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

private enum OpenIDTestError: Error {
    case invalidBrowserRequest
    case invalidRequest
    case storeFailure
}
