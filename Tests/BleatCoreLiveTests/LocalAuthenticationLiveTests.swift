import Foundation
import XCTest

@testable import BleatCore

final class LocalAuthenticationLiveTests: XCTestCase {
    func testPinnedRootAndPrefixLocalAuthenticationContracts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
              let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
              let username = environment["BLEAT_LIVE_USERNAME"],
              let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live authentication data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            let server = try secureServerURL(for: liveURL)
            let accountID = AccountID(rawValue: "live-\(index)")
            let store = LiveCredentialStore()
            let client = AuthCoordinator(
                transport: LocalDockerHTTPTransport(),
                credentialStore: store
            )

            let account = try await client.login(
                accountID: accountID,
                server: server,
                username: username,
                password: password
            )
            let storedCredentials = await store.credentials(for: accountID)

            XCTAssertEqual(account.id, accountID)
            XCTAssertEqual(account.server, server)
            XCTAssertEqual(account.user.username, username)
            XCTAssertEqual(account.user.type, .root)
            XCTAssertTrue(account.user.permissions.accessAllLibraries)
            XCTAssertNotNil(storedCredentials)

            let initialTokens = try XCTUnwrap(storedCredentials)
            let rejectedAccessTokens = try AuthenticationTokens(
                accessToken: "rejected-access-\(index)",
                refreshToken: initialTokens.refreshToken
            )
            await store.save(rejectedAccessTokens, for: accountID)
            var librariesRequest = URLRequest(
                url: try AudiobookshelfRouteBuilder(server: server)
                    .url(for: .libraries)
            )
            librariesRequest.httpMethod = "GET"

            let librariesResponse = try await client.sendAuthenticated(
                librariesRequest,
                route: .libraries,
                accountID: accountID,
                server: server
            )
            let storedRotatedTokens =
                await store.credentials(for: accountID)
            let rotatedTokens = try XCTUnwrap(storedRotatedTokens)
            let requiresReauthentication =
                await client.requiresReauthentication(for: accountID)

            XCTAssertEqual(librariesResponse.statusCode, 200)
            XCTAssertNotEqual(
                rotatedTokens.accessToken,
                rejectedAccessTokens.accessToken
            )
            XCTAssertNotEqual(
                rotatedTokens.refreshToken,
                initialTokens.refreshToken
            )
            XCTAssertFalse(requiresReauthentication)

            let rejectedStore = LiveCredentialStore()
            let rejectedCoordinator = AuthCoordinator(
                transport: LocalDockerHTTPTransport(),
                credentialStore: rejectedStore
            )
            do {
                _ = try await rejectedCoordinator.login(
                    accountID: accountID,
                    server: server,
                    username: username,
                    password: "\(password)-incorrect"
                )
                XCTFail("Expected invalid credentials to be rejected")
            } catch {
                XCTAssertEqual(
                    error as? LocalAuthenticationError,
                    .invalidCredentials
                )
            }
            let rejectedCredentials =
                await rejectedStore.credentials(for: accountID)
            XCTAssertNil(rejectedCredentials)
        }
    }

    private func secureServerURL(
        for liveURL: String
    ) throws -> NormalizedServerURL {
        var components = try XCTUnwrap(URLComponents(string: liveURL))
        components.scheme = "https"
        return try NormalizedServerURL(
            try XCTUnwrap(components.url).absoluteString
        )
    }
}

/// Rewrites only the live test's loopback requests after production has
/// enforced HTTPS and applied bearer authorization.
private struct LocalDockerHTTPTransport: HTTPTransport {
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

private actor LiveCredentialStore: AccountCredentialStore {
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
