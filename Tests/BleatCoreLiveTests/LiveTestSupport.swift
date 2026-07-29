import Foundation
import XCTest

@testable import BleatCore

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

    func send(_ request: URLRequest) async throws -> HTTPResponse {
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
        return try await transport.send(rewrittenRequest)
    }
}

actor LiveCredentialStore: AccountCredentialStore {
    private var stored: [AccountID: AuthenticationTokens] = [:]

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

    func deleteCredentials(for accountID: AccountID) {
        stored[accountID] = nil
    }
}

private enum LocalDockerTransportError: Error {
    case invalidRequest
}
