import Foundation
import XCTest

@testable import BleatCore

final class ServerDiscoveryTests: XCTestCase {
    func testDecodesPinnedLiveStatusFixture() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "status-initialized",
                withExtension: "json"
            )
        )
        let status = try JSONDecoder().decode(
            ServerStatusResponse.self,
            from: Data(contentsOf: fixtureURL)
        )

        XCTAssertEqual(status.app, "audiobookshelf")
        XCTAssertEqual(status.serverVersion, "2.36.0")
        XCTAssertTrue(status.isInitialized)
        XCTAssertEqual(status.language, "en-us")
        XCTAssertEqual(status.authenticationMethods, [.local])
        XCTAssertEqual(
            status.authenticationFormData?.loginCustomMessage,
            ""
        )
        XCTAssertNil(status.authenticationFormData?.openIDButtonText)
        XCTAssertNil(status.authenticationFormData?.openIDAutoLaunch)
    }

    func testDiscoversInitializedSupportedServer() async throws {
        let transport = StubHTTPTransport(
            responses: [
                .json(
                    Self.validStatus,
                    url: URL(string: "https://example.com/prefix/status")
                )
            ]
        )
        let client = ServerDiscoveryClient(transport: transport)

        let discovered = try await client.discover(
            NormalizedServerURL("https://example.com/prefix")
        )

        XCTAssertEqual(
            discovered.baseURL.url.absoluteString,
            "https://example.com/prefix"
        )
        XCTAssertEqual(discovered.version.original, "2.36.0")
        XCTAssertEqual(discovered.language, "en-us")
        XCTAssertEqual(discovered.authenticationMethods, [.local, .openID])
        XCTAssertEqual(
            discovered.authenticationFormData?.openIDButtonText,
            "Continue with SSO"
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(
            requests.first?.url?.absoluteString,
            "https://example.com/prefix/status"
        )
        XCTAssertEqual(requests.first?.httpMethod, "GET")
    }

    func testUnknownAuthenticationMethodIsPreserved() throws {
        let data = Data(
            """
            {
              "app": "audiobookshelf",
              "serverVersion": "2.36.0",
              "isInit": true,
              "language": "en-us",
              "authMethods": ["future-auth"],
              "authFormData": null
            }
            """.utf8
        )

        let status = try JSONDecoder().decode(
            ServerStatusResponse.self,
            from: data
        )

        XCTAssertEqual(
            status.authenticationMethods,
            [.unknown("future-auth")]
        )

        let encoded = try JSONEncoder().encode(
            status.authenticationMethods
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                [AuthenticationMethod].self,
                from: encoded
            ),
            [.unknown("future-auth")]
        )
        XCTAssertEqual(AuthenticationMethod.local.rawValue, "local")
        XCTAssertEqual(AuthenticationMethod.openID.rawValue, "openid")
        XCTAssertEqual(
            AuthenticationMethod.unknown("future-auth").rawValue,
            "future-auth"
        )
    }

    func testFollowsOneSameOriginRedirectAndUpdatesBasePath() async throws {
        let redirectURL = URL(
            string: "https://example.com/audiobookshelf/status"
        )
        let transport = StubHTTPTransport(
            responses: [
                HTTPResponse(
                    data: Data(),
                    statusCode: 302,
                    headers: ["location": "/audiobookshelf/status"],
                    url: URL(string: "https://example.com/status")
                ),
                .json(Self.validStatus, url: redirectURL),
            ]
        )
        let client = ServerDiscoveryClient(transport: transport)

        let discovered = try await client.discover(
            NormalizedServerURL("https://example.com")
        )

        XCTAssertEqual(
            discovered.baseURL.url.absoluteString,
            "https://example.com/audiobookshelf"
        )
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.map(\.url?.absoluteString),
            [
                "https://example.com/status",
                "https://example.com/audiobookshelf/status",
            ]
        )
    }

    func testRequiresConfirmationForCrossOriginRedirect() async throws {
        let target = try XCTUnwrap(
            URL(string: "https://other.example/audiobookshelf/status")
        )
        let transport = StubHTTPTransport(
            responses: [
                HTTPResponse(
                    data: Data(),
                    statusCode: 302,
                    headers: ["Location": target.absoluteString],
                    url: URL(string: "https://example.com/status")
                )
            ]
        )
        let client = ServerDiscoveryClient(transport: transport)

        await XCTAssertThrowsErrorAsync(
            try await client.discover(
                NormalizedServerURL("https://example.com")
            )
        ) { error in
            XCTAssertEqual(
                error as? ServerDiscoveryError,
                .redirectRequiresConfirmation(target)
            )
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testTreatsExplicitDefaultHTTPSPortAsSameOrigin() async throws {
        let redirectURL = URL(
            string: "https://example.com:443/audiobookshelf/status"
        )
        let transport = StubHTTPTransport(
            responses: [
                HTTPResponse(
                    data: Data(),
                    statusCode: 302,
                    headers: [
                        "Location": try XCTUnwrap(redirectURL).absoluteString
                    ],
                    url: URL(string: "https://example.com/status")
                ),
                .json(Self.validStatus, url: redirectURL),
            ]
        )
        let client = ServerDiscoveryClient(transport: transport)

        let discovered = try await client.discover(
            NormalizedServerURL("https://example.com")
        )

        XCTAssertEqual(
            discovered.baseURL.url.absoluteString,
            "https://example.com:443/audiobookshelf"
        )
    }

    func testRejectsInvalidRedirects() async throws {
        let scenarios: [(String?, ServerDiscoveryError)] = [
            (nil, .redirectMissingLocation),
            (
                "http://example.com/status",
                .invalidRedirect(
                    try XCTUnwrap(
                        URL(string: "http://example.com/status")
                    )
                )
            ),
            (
                "https://user@example.com/status",
                .invalidRedirect(
                    try XCTUnwrap(
                        URL(string: "https://user@example.com/status")
                    )
                )
            ),
        ]

        for (location, expectedError) in scenarios {
            let headers = location.map { ["Location": $0] } ?? [:]
            let transport = StubHTTPTransport(
                responses: [
                    HTTPResponse(
                        data: Data(),
                        statusCode: 302,
                        headers: headers,
                        url: URL(string: "https://example.com/status")
                    )
                ]
            )
            let client = ServerDiscoveryClient(transport: transport)

            await XCTAssertThrowsErrorAsync(
                try await client.discover(
                    NormalizedServerURL("https://example.com")
                )
            ) { error in
                XCTAssertEqual(
                    error as? ServerDiscoveryError,
                    expectedError
                )
            }
        }
    }

    func testRejectsSecondRedirect() async throws {
        let transport = StubHTTPTransport(
            responses: [
                .redirect(
                    from: "https://example.com/status",
                    to: "/one/status"
                ),
                .redirect(
                    from: "https://example.com/one/status",
                    to: "/two/status"
                ),
            ]
        )
        let client = ServerDiscoveryClient(transport: transport)

        await XCTAssertThrowsErrorAsync(
            try await client.discover(
                NormalizedServerURL("https://example.com")
            )
        ) { error in
            XCTAssertEqual(
                error as? ServerDiscoveryError,
                .tooManyRedirects
            )
        }
    }

    func testRejectsInvalidServerResponses() async throws {
        let cases: [(Data, Int, ServerDiscoveryError)] = [
            (Data(), 503, .unexpectedHTTPStatus(503)),
            (Data("not-json".utf8), 200, .malformedResponse),
            (
                Self.statusJSON(app: "different-app"),
                200,
                .wrongApplication("different-app")
            ),
            (
                Self.statusJSON(isInitialized: false),
                200,
                .uninitialized
            ),
            (
                Self.statusJSON(version: "not-a-version"),
                200,
                .invalidServerVersion("not-a-version")
            ),
            (
                Self.statusJSON(version: "2.25.9"),
                200,
                .unsupportedServerVersion("2.25.9")
            ),
        ]

        for (data, statusCode, expectedError) in cases {
            let transport = StubHTTPTransport(
                responses: [
                    HTTPResponse(
                        data: data,
                        statusCode: statusCode,
                        url: URL(string: "https://example.com/status")
                    )
                ]
            )
            let client = ServerDiscoveryClient(transport: transport)

            await XCTAssertThrowsErrorAsync(
                try await client.discover(
                    NormalizedServerURL("https://example.com")
                )
            ) { error in
                XCTAssertEqual(
                    error as? ServerDiscoveryError,
                    expectedError
                )
            }
        }
    }

    func testServerVersionOrderingAndPrereleaseParsing() throws {
        let minimum = try XCTUnwrap(AudiobookshelfServerVersion("2.26.0"))
        let newer = try XCTUnwrap(
            AudiobookshelfServerVersion("2.36.0-beta.1")
        )

        XCTAssertLessThan(minimum, newer)
        XCTAssertEqual(newer.description, "2.36.0-beta.1")
        XCTAssertNil(AudiobookshelfServerVersion("2.36"))
        XCTAssertNil(AudiobookshelfServerVersion("2.x.0"))
        XCTAssertNil(AudiobookshelfServerVersion(""))
    }

    private static let validStatus = statusJSON()

    private static func statusJSON(
        app: String = "audiobookshelf",
        version: String = "2.36.0",
        isInitialized: Bool = true
    ) -> Data {
        Data(
            """
            {
              "app": "\(app)",
              "serverVersion": "\(version)",
              "isInit": \(isInitialized),
              "language": "en-us",
              "authMethods": ["local", "openid"],
              "authFormData": {
                "authOpenIDButtonText": "Continue with SSO",
                "authOpenIDAutoLaunch": false,
                "authLoginCustomMessage": ""
              },
              "futureField": "ignored"
            }
            """.utf8
        )
    }
}

private actor StubHTTPTransport: HTTPTransport {
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
            throw StubHTTPTransportError.noResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private enum StubHTTPTransportError: Error {
    case noResponse
}

extension HTTPResponse {
    fileprivate static func json(_ data: Data, url: URL?) -> HTTPResponse {
        HTTPResponse(
            data: data,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            url: url
        )
    }

    fileprivate static func redirect(from: String, to: String) -> HTTPResponse {
        HTTPResponse(
            data: Data(),
            statusCode: 302,
            headers: ["Location": to],
            url: URL(string: from)
        )
    }
}
