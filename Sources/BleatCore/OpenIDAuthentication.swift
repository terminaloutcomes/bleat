import AuthenticationServices
@preconcurrency import AppAuthCore
import CryptoKit
import Foundation
import Security

public enum OpenIDCallbackURLValidationError:
    Error,
    Equatable,
    Sendable
{
    case malformed
    case webSchemeNotAllowed
    case reservedScheme
    case missingCallbackTarget
    case containsCredentials
    case containsQueryOrFragment
}

public struct OpenIDCallbackURL: Hashable, Sendable {
    public let url: URL
    public let callbackScheme: String

    public init(
        _ value: String
    ) throws(OpenIDCallbackURLValidationError) {
        guard let components = URLComponents(string: value),
            let scheme = components.scheme?.lowercased(),
            let url = components.url
        else {
            throw .malformed
        }
        guard scheme != "http", scheme != "https" else {
            throw .webSchemeNotAllowed
        }
        guard scheme != "audiobookshelf" else {
            throw .reservedScheme
        }
        guard components.host?.isEmpty == false
            || !components.percentEncodedPath.isEmpty
        else {
            throw .missingCallbackTarget
        }
        guard components.user == nil, components.password == nil,
            components.port == nil
        else {
            throw .containsCredentials
        }
        guard components.query == nil, components.fragment == nil else {
            throw .containsQueryOrFragment
        }

        self.url = url
        callbackScheme = scheme
    }

    func authorizationValues(
        from callbackURL: URL,
        expectedState: String
    ) throws(OpenIDAuthenticationError) -> (
        code: String,
        state: String
    ) {
        guard
            let expected = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            let callback = URLComponents(
                url: callbackURL,
                resolvingAgainstBaseURL: false
            ),
            callback.scheme?.lowercased()
                == expected.scheme?.lowercased(),
            callback.host?.lowercased()
                == expected.host?.lowercased(),
            callback.port == expected.port,
            callback.percentEncodedPath == expected.percentEncodedPath,
            callback.user == nil,
            callback.password == nil,
            callback.fragment == nil
        else {
            throw .invalidCallbackURL
        }

        let stateValues =
            callback.queryItems?
            .filter { $0.name == "state" }
            .compactMap(\.value) ?? []
        guard stateValues.count == 1, !stateValues[0].isEmpty else {
            throw .missingState
        }
        guard stateValues[0] == expectedState else {
            throw .stateMismatch
        }

        let codeValues =
            callback.queryItems?
            .filter { $0.name == "code" }
            .compactMap(\.value) ?? []
        guard codeValues.count == 1, !codeValues[0].isEmpty else {
            throw .missingAuthorizationCode
        }
        return (codeValues[0], stateValues[0])
    }
}

public enum OpenIDBrowserError: Error, Equatable, Sendable {
    case cancelled
    case alreadyActive
    case presentationAnchorUnavailable
    case failed
}

private final class OpenIDBrowserCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claimCompletion() -> Bool {
        lock.withLock {
            guard !completed else {
                return false
            }
            completed = true
            return true
        }
    }
}

public protocol OpenIDBrowserSession: Sendable {
    @MainActor
    func authenticate(
        at authorizationURL: URL,
        callbackScheme: String
    ) async throws -> URL

    @MainActor
    func presentLogout(at logoutURL: URL)
}

public extension OpenIDBrowserSession {
    @MainActor
    func presentLogout(at logoutURL: URL) {}
}

@MainActor
protocol OpenIDWebAuthenticationSession: AnyObject {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? {
        get set
    }
    var prefersEphemeralWebBrowserSession: Bool { get set }

    func start() -> Bool
}

extension ASWebAuthenticationSession: OpenIDWebAuthenticationSession {}

protocol OpenIDWebAuthenticationSessionFactory: Sendable {
    @MainActor
    func makeSession(
        url: URL,
        callbackScheme: String,
        completion:
            @escaping @Sendable (URL?, OpenIDBrowserError?) -> Void
    ) -> any OpenIDWebAuthenticationSession
}

enum SystemOpenIDCompletionMapper {
    static func complete(
        callbackURL: URL?,
        error: (any Error)?,
        completion:
            @escaping @Sendable (URL?, OpenIDBrowserError?) -> Void
    ) {
        if let callbackURL {
            completion(callbackURL, nil)
        } else if let sessionError =
            error as? ASWebAuthenticationSessionError,
            sessionError.code == .canceledLogin
        {
            completion(nil, .cancelled)
        } else {
            completion(nil, .failed)
        }
    }
}

struct SystemOpenIDWebAuthenticationSessionFactory:
    OpenIDWebAuthenticationSessionFactory
{
    @MainActor
    func makeSession(
        url: URL,
        callbackScheme: String,
        completion:
            @escaping @Sendable (URL?, OpenIDBrowserError?) -> Void
    ) -> any OpenIDWebAuthenticationSession {
        ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: callbackScheme
        ) { callbackURL, error in
            SystemOpenIDCompletionMapper.complete(
                callbackURL: callbackURL,
                error: error,
                completion: completion
            )
        }
    }
}

@MainActor
public final class SystemOpenIDBrowserSession:
    NSObject,
    OpenIDBrowserSession
{
    private struct ActiveSession {
        let session: any OpenIDWebAuthenticationSession
        let presentationContext:
            any ASWebAuthenticationPresentationContextProviding
    }

    private let anchorProvider:
        @MainActor @Sendable () -> ASPresentationAnchor?
    private let sessionFactory: any OpenIDWebAuthenticationSessionFactory
    private var activeSession: ActiveSession?

    public init(
        anchorProvider:
            @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) {
        self.anchorProvider = anchorProvider
        sessionFactory = SystemOpenIDWebAuthenticationSessionFactory()
    }

    init(
        anchorProvider:
            @escaping @MainActor @Sendable () -> ASPresentationAnchor?,
        sessionFactory: any OpenIDWebAuthenticationSessionFactory
    ) {
        self.anchorProvider = anchorProvider
        self.sessionFactory = sessionFactory
    }

    public func authenticate(
        at authorizationURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        guard activeSession == nil else {
            throw OpenIDBrowserError.alreadyActive
        }
        guard let anchor = anchorProvider() else {
            throw OpenIDBrowserError.presentationAnchorUnavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let completionGate = OpenIDBrowserCompletionGate()
            let session = sessionFactory.makeSession(
                url: authorizationURL,
                callbackScheme: callbackScheme
            ) { [weak self] callbackURL, browserError in
                Task { @MainActor in
                    guard completionGate.claimCompletion() else {
                        return
                    }
                    self?.activeSession = nil
                    if let callbackURL {
                        continuation.resume(returning: callbackURL)
                    } else if browserError == .cancelled {
                        continuation.resume(
                            throwing: OpenIDBrowserError.cancelled
                        )
                    } else {
                        continuation.resume(
                            throwing: OpenIDBrowserError.failed
                        )
                    }
                }
            }
            let presentationContext = OpenIDPresentationContext(
                anchor: anchor
            )
            session.presentationContextProvider = presentationContext
            session.prefersEphemeralWebBrowserSession = false
            activeSession = ActiveSession(
                session: session,
                presentationContext: presentationContext
            )

            if !session.start(), completionGate.claimCompletion() {
                activeSession = nil
                continuation.resume(
                    throwing: OpenIDBrowserError.failed
                )
            }
        }
    }

    public func presentLogout(at logoutURL: URL) {
        guard activeSession == nil, let anchor = anchorProvider() else {
            return
        }
        let session = ASWebAuthenticationSession(
            url: logoutURL,
            callbackURLScheme: nil
        ) { [weak self] _, _ in
            Task { @MainActor in
                self?.activeSession = nil
            }
        }
        let presentationContext = OpenIDPresentationContext(anchor: anchor)
        session.presentationContextProvider = presentationContext
        session.prefersEphemeralWebBrowserSession = false
        activeSession = ActiveSession(
            session: session,
            presentationContext: presentationContext
        )
        if !session.start() {
            activeSession = nil
        }
    }
}

@MainActor
private final class OpenIDPresentationContext:
    NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    private let anchor: ASPresentationAnchor

    init(anchor: ASPresentationAnchor) {
        self.anchor = anchor
    }

    func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        anchor
    }
}

public protocol OpenIDSessionTransport: HTTPTransport {
    func clearSession() async
}

public enum OpenIDSessionTransportConfigurationError:
    Error,
    Equatable,
    Sendable
{
    case cookieStorageUnavailable
}

public final class URLSessionOpenIDTransport:
    OpenIDSessionTransport,
    @unchecked Sendable
{
    private let cookieStorage: HTTPCookieStorage
    private let transport: URLSessionHTTPTransport

    public init() throws(OpenIDSessionTransportConfigurationError) {
        let configuration = URLSessionConfiguration.ephemeral
        guard let cookieStorage = configuration.httpCookieStorage else {
            throw .cookieStorageUnavailable
        }
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = cookieStorage
        configuration.httpCookieAcceptPolicy = .always

        self.cookieStorage = cookieStorage
        transport = URLSessionHTTPTransport(
            configuration: configuration,
            cookieStorage: cookieStorage
        )
    }

    init(
        configuration: URLSessionConfiguration,
        cookieStorage: HTTPCookieStorage
    ) {
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = cookieStorage
        configuration.httpCookieAcceptPolicy = .always

        self.cookieStorage = cookieStorage
        transport = URLSessionHTTPTransport(
            configuration: configuration,
            cookieStorage: cookieStorage
        )
    }

    public func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        var sessionRequest = tracedRequest.request
        if sessionRequest.value(forHTTPHeaderField: "Cookie") == nil,
            let url = sessionRequest.url
        {
            let cookies = cookieStorage.cookies(for: url) ?? []
            for (name, value) in HTTPCookie.requestHeaderFields(
                with: cookies
            ) {
                sessionRequest.setValue(
                    value,
                    forHTTPHeaderField: name
                )
            }
        }

        let response = try await transport.send(
            tracedRequest.replacingRequest(sessionRequest)
        )
        if let responseURL = response.url ?? sessionRequest.url {
            for cookie in HTTPCookie.cookies(
                withResponseHeaderFields: response.headers,
                for: responseURL
            ) {
                cookieStorage.setCookie(cookie)
            }
        }
        return response
    }

    public func clearSession() async {
        for cookie in cookieStorage.cookies ?? [] {
            cookieStorage.deleteCookie(cookie)
        }
    }

    var cookieCount: Int {
        cookieStorage.cookies?.count ?? 0
    }
}

public enum OpenIDAuthenticationError: Error, Equatable, Sendable {
    case invalidAccountID
    case attemptAlreadyInProgress
    case randomGenerationFailed(OSStatus)
    case unexpectedAuthorizationRedirectStatus(Int)
    case missingProviderRedirect
    case invalidProviderRedirect
    case browserCancelled
    case presentationAnchorUnavailable
    case browserFailed
    case invalidCallbackURL
    case missingState
    case stateMismatch
    case missingAuthorizationCode
    case unexpectedExchangeStatus(Int)
    case malformedExchangeResponse
    case missingAccessToken
    case missingRefreshToken
    case tokenValidationFailed
    case unexpectedAuthorizationStatus(Int)
    case malformedAuthorizationResponse
    case authorizedUserMismatch(expected: String, actual: String)
    case credentialPersistenceFailed
}

struct OpenIDAttempt: Sendable {
    let callbackURL: OpenIDCallbackURL
    let verifier: String
    let challenge: String
    let state: String
}

enum PKCEGenerationError: Error, Equatable, Sendable {
    case randomGenerationFailed(OSStatus)
}

struct PKCEGenerator: Sendable {
    typealias RandomData =
        @Sendable (Int) throws(PKCEGenerationError) -> Data

    private let randomData: RandomData

    init(
        randomData: @escaping RandomData = Self.secureRandomData
    ) {
        self.randomData = randomData
    }

    func makeAttempt(
        callbackURL: OpenIDCallbackURL
    ) throws(PKCEGenerationError) -> OpenIDAttempt {
        let verifier = Self.base64URLEncoded(
            try randomData(32)
        )
        let state = Self.base64URLEncoded(
            try randomData(32)
        )
        return OpenIDAttempt(
            callbackURL: callbackURL,
            verifier: verifier,
            challenge: Self.challenge(for: verifier),
            state: state
        )
    }

    static func challenge(for verifier: String) -> String {
        base64URLEncoded(
            Data(SHA256.hash(data: Data(verifier.utf8)))
        )
    }

    private static func secureRandomData(
        count: Int
    ) throws(PKCEGenerationError) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(
            kSecRandomDefault,
            bytes.count,
            &bytes
        )
        guard status == errSecSuccess else {
            throw .randomGenerationFailed(status)
        }
        return Data(bytes)
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension AuthCoordinator where Transport: OpenIDSessionTransport {
    public func loginWithOpenID<Browser: OpenIDBrowserSession>(
        accountID: AccountID,
        server: NormalizedServerURL,
        callbackURL: OpenIDCallbackURL,
        browser: Browser
    ) async throws -> AuthenticatedAccount {
        try await loginWithOpenID(
            accountID: accountID,
            server: server,
            callbackURL: callbackURL,
            browser: browser,
            suppliedAttempt: nil
        )
    }

    func loginWithOpenID<Browser: OpenIDBrowserSession>(
        accountID: AccountID,
        server: NormalizedServerURL,
        callbackURL: OpenIDCallbackURL,
        browser: Browser,
        generator: PKCEGenerator
    ) async throws -> AuthenticatedAccount {
        let attempt: OpenIDAttempt
        do {
            attempt = try generator.makeAttempt(callbackURL: callbackURL)
        } catch let error {
            switch error {
            case .randomGenerationFailed(let status):
                throw OpenIDAuthenticationError.randomGenerationFailed(status)
            }
        }
        return try await loginWithOpenID(
            accountID: accountID,
            server: server,
            callbackURL: callbackURL,
            browser: browser,
            suppliedAttempt: attempt
        )
    }

    private func loginWithOpenID<Browser: OpenIDBrowserSession>(
        accountID: AccountID,
        server: NormalizedServerURL,
        callbackURL: OpenIDCallbackURL,
        browser: Browser,
        suppliedAttempt: OpenIDAttempt?
    ) async throws -> AuthenticatedAccount {
        guard !accountID.rawValue.isEmpty else {
            throw OpenIDAuthenticationError.invalidAccountID
        }
        guard openIDAttempt == nil else {
            throw OpenIDAuthenticationError.attemptAlreadyInProgress
        }

        let routeBuilder = AudiobookshelfRouteBuilder(server: server)
        let authorizationEndpoint = try routeBuilder.url(for: .beginOpenID)
        let completionEndpoint = try routeBuilder.url(for: .completeOpenID)
        let configuration = OIDServiceConfiguration(
            authorizationEndpoint: authorizationEndpoint,
            tokenEndpoint: completionEndpoint
        )
        let authorizationRequest: OIDAuthorizationRequest
        if let suppliedAttempt {
            authorizationRequest = OIDAuthorizationRequest(
                configuration: configuration,
                clientId: "Bleat",
                clientSecret: nil,
                scope: nil,
                redirectURL: callbackURL.url,
                responseType: OIDResponseTypeCode,
                state: suppliedAttempt.state,
                nonce: nil,
                codeVerifier: suppliedAttempt.verifier,
                codeChallenge: suppliedAttempt.challenge,
                codeChallengeMethod:
                    OIDOAuthorizationRequestCodeChallengeMethodS256,
                additionalParameters: nil
            )
        } else {
            authorizationRequest = OIDAuthorizationRequest(
                configuration: configuration,
                clientId: "Bleat",
                scopes: nil,
                redirectURL: callbackURL.url,
                responseType: OIDResponseTypeCode,
                additionalParameters: nil
            )
        }
        guard let state = authorizationRequest.state,
            let verifier = authorizationRequest.codeVerifier,
            let challenge = authorizationRequest.codeChallenge
        else {
            throw OpenIDAuthenticationError.randomGenerationFailed(
                errSecAllocate
            )
        }
        let attempt = OpenIDAttempt(
            callbackURL: callbackURL,
            verifier: verifier,
            challenge: challenge,
            state: state
        )

        openIDAttempt = attempt
        await transport.clearSession()

        do {
            let providerURL = try await beginOpenID(
                authorizationRequest.authorizationRequestURL()
            )
            let grant = try await AppAuthAuthorizationFlow.authorize(
                request: authorizationRequest,
                providerURL: providerURL,
                callbackURL: callbackURL,
                browser: browser
            )
            let account = try await completeOpenID(
                accountID: accountID,
                server: server,
                grant: grant,
                attempt: attempt
            )
            await clearOpenIDAttempt()
            return account
        } catch {
            await clearOpenIDAttempt()
            throw error
        }
    }

    private func beginOpenID(
        _ authorizationURL: URL
    ) async throws -> URL {
        var request = URLRequest(url: authorizationURL)
        request.httpMethod = "GET"

        let response = try await transport.send(
            TracedHTTPRequest(
                request: request,
                endpoint: .beginOpenID
            )
        )
        guard (300..<400).contains(response.statusCode) else {
            throw
                OpenIDAuthenticationError
                .unexpectedAuthorizationRedirectStatus(
                    response.statusCode
                )
        }
        guard let location = response.header(named: "Location"),
            let providerURL = URL(string: location)
        else {
            throw OpenIDAuthenticationError.missingProviderRedirect
        }
        guard providerURL.scheme?.lowercased() == "https",
            providerURL.host != nil,
            providerURL.user == nil,
            providerURL.password == nil
        else {
            throw OpenIDAuthenticationError.invalidProviderRedirect
        }
        return providerURL
    }

    private func completeOpenID(
        accountID: AccountID,
        server: NormalizedServerURL,
        grant: OpenIDAuthorizationGrant,
        attempt: OpenIDAttempt
    ) async throws -> AuthenticatedAccount {
        let routeBuilder = AudiobookshelfRouteBuilder(server: server)
        let exchangeURL = try routeBuilder.url(
            for: .completeOpenID,
            queryItems: [
                URLQueryItem(name: "state", value: grant.state),
                URLQueryItem(name: "code", value: grant.code),
                URLQueryItem(
                    name: "code_verifier",
                    value: attempt.verifier
                ),
            ]
        )
        var exchangeRequest = URLRequest(url: exchangeURL)
        exchangeRequest.httpMethod = "GET"

        let exchangeResponse = try await transport.send(
            TracedHTTPRequest(
                request: exchangeRequest,
                endpoint: .completeOpenID
            )
        )
        guard exchangeResponse.statusCode == 200 else {
            throw OpenIDAuthenticationError.unexpectedExchangeStatus(
                exchangeResponse.statusCode
            )
        }

        let exchangePayload: AuthenticationResponse
        do {
            exchangePayload = try decoder.decode(
                AuthenticationResponse.self,
                from: exchangeResponse.data
            )
        } catch {
            throw OpenIDAuthenticationError.malformedExchangeResponse
        }

        guard let accessToken = exchangePayload.user.accessToken,
            !accessToken.isEmpty
        else {
            throw OpenIDAuthenticationError.missingAccessToken
        }
        guard let refreshToken = exchangePayload.user.refreshToken,
            !refreshToken.isEmpty
        else {
            throw OpenIDAuthenticationError.missingRefreshToken
        }

        let tokens: AuthenticationTokens
        do {
            tokens = try AuthenticationTokens(
                accessToken: accessToken,
                refreshToken: refreshToken
            )
        } catch let error {
            switch error {
            case .invalidAccessToken:
                throw OpenIDAuthenticationError.missingAccessToken
            case .invalidRefreshToken:
                throw OpenIDAuthenticationError.missingRefreshToken
            }
        }

        let authorizeURL = try routeBuilder.url(for: .authorize)
        var authorizeRequest = URLRequest(url: authorizeURL)
        authorizeRequest.httpMethod = "POST"
        authorizeRequest = try requestAuthorizer.authorize(
            authorizeRequest,
            accessToken: tokens.accessToken
        )

        let authorizeResponse = try await transport.send(
            TracedHTTPRequest(
                request: authorizeRequest,
                endpoint: .authorize
            )
        )
        switch authorizeResponse.statusCode {
        case 200:
            break
        case 401:
            throw OpenIDAuthenticationError.tokenValidationFailed
        default:
            throw
                OpenIDAuthenticationError
                .unexpectedAuthorizationStatus(
                    authorizeResponse.statusCode
                )
        }

        let authorizationPayload: AuthenticationResponse
        do {
            authorizationPayload = try decoder.decode(
                AuthenticationResponse.self,
                from: authorizeResponse.data
            )
        } catch {
            throw OpenIDAuthenticationError
                .malformedAuthorizationResponse
        }
        guard authorizationPayload.user.id == exchangePayload.user.id else {
            throw OpenIDAuthenticationError.authorizedUserMismatch(
                expected: exchangePayload.user.id.rawValue,
                actual: authorizationPayload.user.id.rawValue
            )
        }

        let canonicalID = AccountID.canonical(
            server: server,
            userID: authorizationPayload.user.id
        )
        do {
            try await credentialStore.save(tokens, for: canonicalID)
        } catch {
            throw OpenIDAuthenticationError.credentialPersistenceFailed
        }

        return AuthenticatedAccount(
            id: canonicalID,
            server: server,
            user: authorizationPayload.user.authenticatedUser
        )
    }

    private func clearOpenIDAttempt() async {
        openIDAttempt = nil
        await transport.clearSession()
    }

    public func loginWithOpenIDAndPersistAccount<Browser: OpenIDBrowserSession>(
        accountID: AccountID,
        discoveredServer: DiscoveredServer,
        callbackURL: OpenIDCallbackURL,
        browser: Browser,
        accountStore: AccountStore,
        expectedUserID: UserID? = nil,
        makeActive: Bool = true,
        onAuthenticationCompleted: @escaping @Sendable () async -> Void = {}
    ) async throws(AccountOnboardingError) -> ServerAccount {
        guard discoveredServer.authenticationMethods.contains(.openID) else {
            throw .openIDAuthenticationUnavailable
        }

        let authenticated: AuthenticatedAccount
        do {
            authenticated = try await loginWithOpenID(
                accountID: accountID,
                server: discoveredServer.baseURL,
                callbackURL: callbackURL,
                browser: browser
            )
        } catch let error as OpenIDAuthenticationError {
            throw .openIDAuthenticationFailed(error)
        } catch {
            throw .authenticationRequestFailed
        }

        if let expectedUserID, authenticated.user.id != expectedUserID {
            try await rollbackOnboardingCredentials(
                accountID: authenticated.id,
                originalError: .openIDAuthenticationFailed(
                    .authorizedUserMismatch(
                        expected: expectedUserID.rawValue,
                        actual: authenticated.user.id.rawValue
                    )
                )
            )
        }

        await onAuthenticationCompleted()

        let account: ServerAccount
        do {
            account = try ServerAccount(
                authenticatedAccount: authenticated,
                discoveredServer: discoveredServer
            )
        } catch let error {
            try await rollbackOnboardingCredentials(
                accountID: authenticated.id,
                originalError: .invalidAccount(error)
            )
        }

        do {
            try await accountStore.save(account, makeActive: makeActive)
        } catch let error {
            try await rollbackOnboardingCredentials(
                accountID: authenticated.id,
                originalError: .accountPersistenceFailed(error)
            )
        }
        return account
    }
}

public struct OpenIDAuthorizationGrant: Equatable, Sendable {
    public let code: String
    public let state: String

    public init(code: String, state: String) {
        self.code = code
        self.state = state
    }
}

@MainActor
private enum AppAuthAuthorizationFlow {
    static func authorize<Browser: OpenIDBrowserSession>(
        request: OIDAuthorizationRequest,
        providerURL: URL,
        callbackURL: OpenIDCallbackURL,
        browser: Browser
    ) async throws -> OpenIDAuthorizationGrant {
        let externalUserAgent = AppAuthOpenIDExternalUserAgent(
            providerURL: providerURL,
            callbackScheme: callbackURL.callbackScheme,
            browser: browser
        )
        return try await withCheckedThrowingContinuation { continuation in
            let session = OIDAuthorizationService.present(
                request,
                externalUserAgent: externalUserAgent
            ) { response, _ in
                Task { @MainActor in
                    externalUserAgent.releaseSession()
                    if let response,
                        let code = response.authorizationCode,
                        let state = response.request.state
                    {
                        continuation.resume(
                            returning: OpenIDAuthorizationGrant(
                                code: code,
                                state: state
                            )
                        )
                        return
                    }
                    if let browserError = externalUserAgent.browserError {
                        switch browserError {
                        case .cancelled:
                            continuation.resume(
                                throwing:
                                    OpenIDAuthenticationError.browserCancelled
                            )
                        case .presentationAnchorUnavailable:
                            continuation.resume(
                                throwing:
                                    OpenIDAuthenticationError
                                    .presentationAnchorUnavailable
                            )
                        case .alreadyActive, .failed:
                            continuation.resume(
                                throwing:
                                    OpenIDAuthenticationError.browserFailed
                            )
                        }
                        return
                    }
                    if let returnedURL = externalUserAgent.callbackURL {
                        do {
                            _ = try callbackURL.authorizationValues(
                                from: returnedURL,
                                expectedState: request.state ?? ""
                            )
                        } catch let error as OpenIDAuthenticationError {
                            continuation.resume(throwing: error)
                            return
                        } catch {}
                    }
                    continuation.resume(
                        throwing: OpenIDAuthenticationError.invalidCallbackURL
                    )
                }
            }
            externalUserAgent.retain(session: session)
        }
    }
}

@MainActor
private final class AppAuthOpenIDExternalUserAgent<
    Browser: OpenIDBrowserSession
>: NSObject, @preconcurrency OIDExternalUserAgent {
    private let providerURL: URL
    private let callbackScheme: String
    private let browser: Browser
    private var task: Task<Void, Never>?
    private var authorizationSession: (any OIDExternalUserAgentSession)?
    private(set) var callbackURL: URL?
    private(set) var browserError: OpenIDBrowserError?

    init(
        providerURL: URL,
        callbackScheme: String,
        browser: Browser
    ) {
        self.providerURL = providerURL
        self.callbackScheme = callbackScheme
        self.browser = browser
    }

    func present(
        _ request: any OIDExternalUserAgentRequest,
        session: any OIDExternalUserAgentSession
    ) -> Bool {
        guard task == nil else {
            return false
        }
        task = Task { @MainActor in
            do {
                let callbackURL = try await browser.authenticate(
                    at: providerURL,
                    callbackScheme: callbackScheme
                )
                self.callbackURL = callbackURL
                if !session.resumeExternalUserAgentFlow(with: callbackURL) {
                    await session.cancel()
                }
            } catch let error as OpenIDBrowserError {
                browserError = error
                await session.cancel()
            } catch {
                browserError = .failed
                await session.cancel()
            }
        }
        return true
    }

    func dismiss(
        animated: Bool,
        completion: @escaping @Sendable () -> Void
    ) {
        task = nil
        completion()
    }

    func retain(session: any OIDExternalUserAgentSession) {
        authorizationSession = session
    }

    func releaseSession() {
        authorizationSession = nil
        task = nil
    }
}
