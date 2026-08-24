import Foundation
import XCTest

@testable import BleatCore

enum TelemetryLiveTestConfigurationError: Error, Equatable {
    case invalidAuthenticationBaseURL
}

/// Reads only the disposable fixture URL. Do not fall back to
/// `BLEAT_TELEMETRY_AUTH_BASE_URL`: `.envrc` uses that setting for production,
/// where the fake development attester is intentionally rejected.
func telemetryAuthenticationTestBaseURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
) throws -> URL? {
    guard let value = environment["BLEAT_TELEMETRY_TEST_AUTH_BASE_URL"] else {
        return nil
    }
    guard let components = URLComponents(string: value),
        components.scheme == "http",
        let host = components.host?.lowercased(),
        ["localhost", "127.0.0.1", "::1"].contains(host),
        components.port != nil,
        components.user == nil,
        components.password == nil,
        components.path.isEmpty || components.path == "/",
        components.query == nil,
        components.fragment == nil,
        let url = components.url
    else {
        throw TelemetryLiveTestConfigurationError
            .invalidAuthenticationBaseURL
    }
    return url
}

/// A missing fixture skips fixture-dependent tests, while an explicitly unsafe
/// fixture URL fails so a typo cannot silently redirect test traffic elsewhere.
func requireTelemetryAuthenticationTestBaseURL() throws -> URL {
    guard let url = try telemetryAuthenticationTestBaseURL() else {
        throw XCTSkip(
            "Run scripts/test-telemetry.sh to provide the telemetry auth fixture"
        )
    }
    return url
}

func secureLiveServerURL(for liveURL: String) throws -> NormalizedServerURL {
    var components = try XCTUnwrap(URLComponents(string: liveURL))
    components.scheme = "https"
    return try NormalizedServerURL(
        try XCTUnwrap(components.url).absoluteString
    )
}

/// Rewrites only loopback live-test requests after production has enforced
/// HTTPS and applied bearer authorization where required.
struct LocalDockerHTTPTransport: HTTPTransport {
    private let transport = URLSessionHTTPTransport()

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
        guard let requestURL = request.url,
            var components = URLComponents(
                url: requestURL,
                resolvingAgainstBaseURL: false
            ),
            components.host == "127.0.0.1",
            components.scheme == "https"
        else {
            throw LocalDockerTransportError.invalidRequest
        }

        components.scheme = "http"
        var rewrittenRequest = request
        rewrittenRequest.url = try XCTUnwrap(components.url)
        let response = try await transport.send(
            tracedRequest.replacingRequest(rewrittenRequest)
        )
        let restoredURL = try response.url.map {
            try Self.restoringSecureLoopbackURL($0)
        }
        var restoredHeaders = response.headers
        if let location = response.header(named: "Location"),
            let locationURL = URL(string: location),
            locationURL.host == "127.0.0.1",
            locationURL.scheme == "http"
        {
            let headerName =
                restoredHeaders.keys.first {
                    $0.caseInsensitiveCompare("Location") == .orderedSame
                } ?? "Location"
            restoredHeaders[headerName] =
                try Self
                .restoringSecureLoopbackURL(locationURL)
                .absoluteString
        }
        return HTTPResponse(
            data: response.data,
            statusCode: response.statusCode,
            headers: restoredHeaders,
            url: restoredURL
        )
    }

    private static func restoringSecureLoopbackURL(
        _ url: URL
    ) throws -> URL {
        guard
            var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ), components.host == "127.0.0.1"
        else {
            return url
        }
        components.scheme = "https"
        return try XCTUnwrap(components.url)
    }
}

actor LiveCredentialStore: AccountCredentialStore {
    private var stored: [AccountID: AuthenticationTokens] = [:]
    private var nativeLogins: [AccountID: NativeLoginCredentials] = [:]

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        stored[accountID]
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        stored[accountID] = credentials
    }

    func save(
        _ credentials: AuthenticationTokens,
        nativeLogin: NativeLoginCredentials,
        for accountID: AccountID
    ) async {
        stored[accountID] = credentials
        nativeLogins[accountID] = nativeLogin
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
}

private enum LocalDockerTransportError: Error {
    case invalidRequest
}
