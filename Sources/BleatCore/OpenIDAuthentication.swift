import AuthenticationServices
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
    case missingCallbackPath
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
        guard !components.percentEncodedPath.isEmpty else {
            throw .missingCallbackPath
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
    ASWebAuthenticationPresentationContextProviding,
    OpenIDBrowserSession
{
    private let anchorProvider: @MainActor @Sendable () -> ASPresentationAnchor
    private let sessionFactory: any OpenIDWebAuthenticationSessionFactory
    private var activeSession: (any OpenIDWebAuthenticationSession)?

    public init(
        anchorProvider:
            @escaping @MainActor @Sendable () -> ASPresentationAnchor
    ) {
        self.anchorProvider = anchorProvider
        sessionFactory = SystemOpenIDWebAuthenticationSessionFactory()
    }

    init(
        anchorProvider:
            @escaping @MainActor @Sendable () -> ASPresentationAnchor,
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
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            activeSession = session

            if !session.start(), completionGate.claimCompletion() {
                activeSession = nil
                continuation.resume(
                    throwing: OpenIDBrowserError.failed
                )
            }
        }
    }

    public func presentationAnchor(
        for session: ASWebAuthenticationSession
    ) -> ASPresentationAnchor {
        anchorProvider()
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
            generator: PKCEGenerator()
        )
    }

    func loginWithOpenID<Browser: OpenIDBrowserSession>(
        accountID: AccountID,
        server: NormalizedServerURL,
        callbackURL: OpenIDCallbackURL,
        browser: Browser,
        generator: PKCEGenerator
    ) async throws -> AuthenticatedAccount {
        guard !accountID.rawValue.isEmpty else {
            throw OpenIDAuthenticationError.invalidAccountID
        }
        guard openIDAttempt == nil else {
            throw OpenIDAuthenticationError.attemptAlreadyInProgress
        }

        let attempt: OpenIDAttempt
        do {
            attempt = try generator.makeAttempt(
                callbackURL: callbackURL
            )
        } catch let error {
            switch error {
            case .randomGenerationFailed(let status):
                throw OpenIDAuthenticationError.randomGenerationFailed(
                    status
                )
            }
        }

        openIDAttempt = attempt
        await transport.clearSession()

        do {
            let providerURL = try await beginOpenID(
                server: server,
                attempt: attempt
            )
            let callback: URL
            do {
                callback = try await browser.authenticate(
                    at: providerURL,
                    callbackScheme: callbackURL.callbackScheme
                )
            } catch let error as OpenIDBrowserError {
                switch error {
                case .cancelled:
                    throw OpenIDAuthenticationError.browserCancelled
                case .alreadyActive, .failed:
                    throw OpenIDAuthenticationError.browserFailed
                }
            } catch {
                throw OpenIDAuthenticationError.browserFailed
            }

            let account = try await completeOpenID(
                accountID: accountID,
                server: server,
                callbackURL: callback,
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
        server: NormalizedServerURL,
        attempt: OpenIDAttempt
    ) async throws -> URL {
        let url = try AudiobookshelfRouteBuilder(server: server).url(
            for: .beginOpenID,
            queryItems: [
                URLQueryItem(
                    name: "code_challenge",
                    value: attempt.challenge
                ),
                URLQueryItem(
                    name: "code_challenge_method",
                    value: "S256"
                ),
                URLQueryItem(
                    name: "redirect_uri",
                    value: attempt.callbackURL.url.absoluteString
                ),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "state", value: attempt.state),
                URLQueryItem(name: "client_id", value: "Bleat"),
            ]
        )
        var request = URLRequest(url: url)
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
        callbackURL: URL,
        attempt: OpenIDAttempt
    ) async throws -> AuthenticatedAccount {
        let values = try attempt.callbackURL.authorizationValues(
            from: callbackURL,
            expectedState: attempt.state
        )

        let routeBuilder = AudiobookshelfRouteBuilder(server: server)
        let exchangeURL = try routeBuilder.url(
            for: .completeOpenID,
            queryItems: [
                URLQueryItem(name: "state", value: values.state),
                URLQueryItem(name: "code", value: values.code),
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

        do {
            try await credentialStore.save(tokens, for: accountID)
        } catch {
            throw OpenIDAuthenticationError.credentialPersistenceFailed
        }

        return AuthenticatedAccount(
            id: accountID,
            server: server,
            user: authorizationPayload.user.authenticatedUser
        )
    }

    private func clearOpenIDAttempt() async {
        openIDAttempt = nil
        await transport.clearSession()
    }
}
