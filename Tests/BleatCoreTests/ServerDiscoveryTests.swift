import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class ServerDiscoveryTests {
    @Test
    func testDecodesPinnedLiveStatusFixture() throws {
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "status-initialized",
                withExtension: "json"
            ))
        let status = try JSONDecoder().decode(
            ServerStatusResponse.self,
            from: Data(contentsOf: fixtureURL)
        )

        #expect(status.app == "audiobookshelf")
        #expect(status.serverVersion == "2.36.0")
        #expect(status.isInitialized)
        #expect(status.language == "en-us")
        #expect(status.authenticationMethods == [.local])
        #expect(status.authenticationFormData?.loginCustomMessage == "")
        #expect(status.authenticationFormData?.openIDButtonText == nil)
        #expect(status.authenticationFormData?.openIDAutoLaunch == nil)
    }

    @Test
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

        #expect(
            discovered.baseURL.url.absoluteString
                == "https://example.com/prefix")
        #expect(discovered.version.original == "2.36.0")
        #expect(discovered.language == "en-us")
        #expect(discovered.authenticationMethods == [.local, .openID])
        #expect(
            discovered.authenticationFormData?.openIDButtonText
                == "Continue with SSO")
        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
        #expect(
            requests.first?.url?.absoluteString
                == "https://example.com/prefix/status")
        #expect(requests.first?.httpMethod == "GET")
    }

    @Test
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

        #expect(status.authenticationMethods == [.unknown("future-auth")])

        let encoded = try JSONEncoder().encode(
            status.authenticationMethods
        )
        #expect(
            try JSONDecoder().decode(
                [AuthenticationMethod].self,
                from: encoded
            ) == [.unknown("future-auth")])
        #expect(AuthenticationMethod.local.rawValue == "local")
        #expect(AuthenticationMethod.openID.rawValue == "openid")
        #expect(
            AuthenticationMethod.unknown("future-auth").rawValue
                == "future-auth")
    }

    @Test
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

        #expect(
            discovered.baseURL.url.absoluteString
                == "https://example.com/audiobookshelf")
        let requests = await transport.recordedRequests()
        #expect(
            requests.map(\.url?.absoluteString) == [
                "https://example.com/status",
                "https://example.com/audiobookshelf/status",
            ])
    }

    @Test
    func testRequiresConfirmationForCrossOriginRedirect() async throws {
        let target = try #require(
            URL(string: "https://other.example/audiobookshelf/status"))
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

        await assertThrowsErrorAsync(
            try await client.discover(
                NormalizedServerURL("https://example.com")
            )
        ) { error in
            #expect(
                error as? ServerDiscoveryError
                    == .redirectRequiresConfirmation(target))
        }
        let requests = await transport.recordedRequests()
        #expect(requests.count == 1)
    }

    @Test
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
                        "Location": try #require(redirectURL).absoluteString
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

        #expect(
            discovered.baseURL.url.absoluteString
                == "https://example.com:443/audiobookshelf")
    }

    @Test
    func testRejectsInvalidRedirects() async throws {
        let scenarios: [(String?, ServerDiscoveryError)] = [
            (nil, .redirectMissingLocation),
            (
                "http://example.com/status",
                .invalidRedirect(
                    try #require(URL(string: "http://example.com/status"))
                )
            ),
            (
                "https://user@example.com/status",
                .invalidRedirect(
                    try #require(URL(string: "https://user@example.com/status"))
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

            await assertThrowsErrorAsync(
                try await client.discover(
                    NormalizedServerURL("https://example.com")
                )
            ) { error in
                #expect(error as? ServerDiscoveryError == expectedError)
            }
        }
    }

    @Test
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

        await assertThrowsErrorAsync(
            try await client.discover(
                NormalizedServerURL("https://example.com")
            )
        ) { error in
            #expect(error as? ServerDiscoveryError == .tooManyRedirects)
        }
    }

    @Test
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

            await assertThrowsErrorAsync(
                try await client.discover(
                    NormalizedServerURL("https://example.com")
                )
            ) { error in
                #expect(error as? ServerDiscoveryError == expectedError)
            }
        }
    }

    @Test
    func testServerVersionOrderingAndPrereleaseParsing() throws {
        let minimum = try #require(AudiobookshelfServerVersion("2.26.0"))
        let newer = try #require(AudiobookshelfServerVersion("2.36.0-beta.1"))

        #expect(minimum < newer)
        #expect(newer.description == "2.36.0-beta.1")
        #expect(AudiobookshelfServerVersion("2.36") == nil)
        #expect(AudiobookshelfServerVersion("2.x.0") == nil)
        #expect(AudiobookshelfServerVersion("") == nil)
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
