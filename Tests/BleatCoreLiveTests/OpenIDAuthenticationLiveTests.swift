import Foundation
import Security
import XCTest

@testable import BleatCore

final class OpenIDAuthenticationLiveTests: XCTestCase {
    @MainActor
    func testKeycloakOIDCLoginCompletesForRootAndPrefixServers() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_OIDC_USERNAME"],
            let password = environment["BLEAT_LIVE_OIDC_PASSWORD"],
            let caPath = environment["BLEAT_LIVE_CA_CERT"],
            let oidcPort = Int(environment["BLEAT_LIVE_OIDC_HTTPS_PORT"] ?? "")
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live Keycloak data"
            )
        }

        let rootServerPort = Int(
            environment["BLEAT_ABS_ROOT_PORT"] ?? "13378"
        ) ?? 13378
        let prefixServerPort = Int(
            environment["BLEAT_ABS_PREFIX_PORT"] ?? "13379"
        ) ?? 13379
        let callbackURL = try OpenIDCallbackURL(
            "bleat://oauth2redirect"
        )
        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            let server = try secureLiveServerURL(for: liveURL)
            let transport = try LiveOIDCTransport(
                caCertificateURL: URL(fileURLWithPath: caPath),
                rootServerPort: rootServerPort,
                prefixServerPort: prefixServerPort
            )
            let discovered = try await ServerDiscoveryClient(
                transport: transport
            ).discover(server)

            XCTAssertTrue(discovered.authenticationMethods.contains(.local))
            XCTAssertTrue(discovered.authenticationMethods.contains(.openID))
            XCTAssertEqual(
                discovered.authenticationFormData?.openIDButtonText,
                "Sign in with Keycloak"
            )

            let credentials = LiveCredentialStore()
            let coordinator = AuthCoordinator(
                transport: transport,
                credentialStore: credentials
            )
            let browser = try LiveKeycloakBrowser(
                username: username,
                password: password,
                oidcPort: oidcPort,
                caCertificateURL: URL(fileURLWithPath: caPath)
            )
            let account = try await coordinator.loginWithOpenID(
                accountID: AccountID(rawValue: "live-oidc-\(index)"),
                server: server,
                callbackURL: callbackURL,
                browser: browser
            )
            let storedCredentials = await credentials.credentials(
                for: account.id
            )

            XCTAssertEqual(account.server, server)
            XCTAssertEqual(account.user.username, username)
            let persistedAccount = try ServerAccount(
                authenticatedAccount: account,
                discoveredServer: discovered
            )
            XCTAssertTrue(persistedAccount.supportsOpenIDAuthentication)
            XCTAssertNotNil(storedCredentials)
            XCTAssertFalse(account.user.id.rawValue.isEmpty)
        }
    }
}

private final class LiveTLSDelegate: NSObject, URLSessionDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private let certificate: SecCertificate
    private let callbackScheme: String?
    private let rewriteURL: @Sendable (URL) -> URL
    private let allowRedirects: Bool
    private let lock = NSLock()
    private var capturedCallbackURL: URL?

    init(
        certificate: SecCertificate,
        callbackScheme: String? = nil,
        rewriteURL: @escaping @Sendable (URL) -> URL = { $0 },
        allowRedirects: Bool
    ) {
        self.certificate = certificate
        self.callbackScheme = callbackScheme
        self.rewriteURL = rewriteURL
        self.allowRedirects = allowRedirects
    }

    var callbackURL: URL? {
        lock.withLock { capturedCallbackURL }
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        SecTrustSetAnchorCertificates(trust, [certificate] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        if SecTrustEvaluateWithError(trust, nil) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url else {
            completionHandler(nil)
            return
        }
        if let callbackScheme,
            url.scheme?.caseInsensitiveCompare(callbackScheme) == .orderedSame
        {
            lock.withLock {
                capturedCallbackURL = url
            }
            completionHandler(nil)
            return
        }
        guard allowRedirects else {
            completionHandler(nil)
            return
        }
        var rewrittenRequest = request
        rewrittenRequest.url = rewriteURL(url)
        completionHandler(rewrittenRequest)
    }
}

private struct LiveOIDCTransport: OpenIDSessionTransport, @unchecked Sendable {
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let rootServerPort: Int
    private let prefixServerPort: Int
    private let caddyRootPort: Int
    private let caddyPrefixPort: Int

    init(
        caCertificateURL: URL,
        rootServerPort: Int,
        prefixServerPort: Int
    ) throws {
        guard let certificate = LiveOIDCTransport.certificate(
            at: caCertificateURL
        ) else {
            throw LiveOIDCTransportError.invalidCertificate
        }
        let configuration = URLSessionConfiguration.ephemeral
        guard let cookieStorage = configuration.httpCookieStorage else {
            throw LiveOIDCTransportError.cookieStorageUnavailable
        }
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = cookieStorage
        let delegate = LiveTLSDelegate(
            certificate: certificate,
            allowRedirects: false
        )
        session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        self.cookieStorage = cookieStorage
        self.rootServerPort = rootServerPort
        self.prefixServerPort = prefixServerPort
        caddyRootPort = Int(
            ProcessInfo.processInfo.environment["BLEAT_HTTPS_ROOT_PORT"]
                ?? "13478"
        ) ?? 13478
        caddyPrefixPort = Int(
            ProcessInfo.processInfo.environment["BLEAT_HTTPS_PREFIX_PORT"]
                ?? "13479"
        ) ?? 13479
    }

    func send(_ tracedRequest: TracedHTTPRequest) async throws -> HTTPResponse {
        var request = tracedRequest.request
        guard let url = request.url else {
            throw LiveOIDCTransportError.missingURL
        }
        request.url = caddyURL(for: url)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LiveOIDCTransportError.nonHTTPResponse
        }
        return HTTPResponse(
            data: data,
            statusCode: httpResponse.statusCode,
            headers: httpResponse.allHeaderFields.reduce(into: [:]) { result, item in
                if let key = item.key as? String,
                    let value = item.value as? String
                {
                    result[key] = value
                }
            },
            url: url
        )
    }

    func clearSession() async {
        for cookie in cookieStorage.cookies ?? [] {
            cookieStorage.deleteCookie(cookie)
        }
    }

    private func caddyURL(for url: URL) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.host == "127.0.0.1" else {
            return url
        }
        components.host = "localhost"
        if components.port == rootServerPort {
            components.port = caddyRootPort
        } else if components.port == prefixServerPort {
            components.port = caddyPrefixPort
        }
        return components.url ?? url
    }

    fileprivate static func certificate(at url: URL) -> SecCertificate? {
        guard let pem = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter {
                !$0.hasPrefix("---") && !$0.isEmpty
            }
            .joined()
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        return SecCertificateCreateWithData(nil, data as CFData)
    }
}

@MainActor
private final class LiveKeycloakBrowser: OpenIDBrowserSession, @unchecked Sendable {
    let username: String
    let password: String
    let oidcPort: Int
    let certificate: SecCertificate

    init(
        username: String,
        password: String,
        oidcPort: Int,
        caCertificateURL: URL
    ) throws {
        guard let certificate = LiveOIDCTransport.certificate(
            at: caCertificateURL
        ) else {
            throw LiveOIDCTransportError.invalidCertificate
        }
        self.username = username
        self.password = password
        self.oidcPort = oidcPort
        self.certificate = certificate
    }

    func authenticate(
        at authorizationURL: URL,
        callbackScheme: String
    ) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        let delegate = LiveTLSDelegate(
            certificate: certificate,
            callbackScheme: callbackScheme,
            rewriteURL: { [oidcPort] url in
                Self.rewriteProviderURL(url, oidcPort: oidcPort)
            },
            allowRedirects: true
        )
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        let initialURL = Self.rewriteProviderURL(
            authorizationURL,
            oidcPort: oidcPort
        )
        let (pageData, _) = try await session.data(from: initialURL)
        let page = String(decoding: pageData, as: UTF8.self)
        let action = try Self.loginAction(from: page)
        var loginRequest = URLRequest(
            url: Self.rewriteProviderURL(action, oidcPort: oidcPort)
        )
        loginRequest.httpMethod = "POST"
        loginRequest.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        loginRequest.httpBody = form.percentEncodedQuery?.data(
            using: .utf8
        )

        do {
            _ = try await session.data(for: loginRequest)
        } catch let error as URLError where error.code == .cancelled {
            // The redirect delegate cancels the request when the private
            // callback URL is reached.
        }
        guard let callbackURL = delegate.callbackURL else {
            throw OpenIDBrowserError.failed
        }
        return callbackURL
    }

    nonisolated private static func rewriteProviderURL(
        _ url: URL,
        oidcPort: Int
    ) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.host == "caddy", components.port == 8445 else {
            return url
        }
        components.host = "localhost"
        components.port = oidcPort
        return components.url ?? url
    }

    private static func loginAction(from page: String) throws -> URL {
        let expression = try NSRegularExpression(
            pattern: "<form[^>]*action=\\\"([^\\\"]+)\\\"[^>]*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        let range = NSRange(page.startIndex..<page.endIndex, in: page)
        guard let match = expression.firstMatch(in: page, range: range),
            let actionRange = Range(match.range(at: 1), in: page),
            let actionURL = URL(string: String(page[actionRange]).replacingOccurrences(of: "&amp;", with: "&"))
        else {
            throw OpenIDBrowserError.failed
        }
        return actionURL
    }
}

private enum LiveOIDCTransportError: Error {
    case invalidCertificate
    case cookieStorageUnavailable
    case missingURL
    case nonHTTPResponse
}
