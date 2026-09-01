import Foundation
import XCTest

@testable import BleatCore

final class HTTPTransportTests: XCTestCase {
    func testEndpointRouterUsesLocalServerAndPreservesPathPrefix() async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL(
            "https://books.example/audiobookshelf"
        )
        let local = try NormalizedServerURL(
            "https://books.home/audiobookshelf"
        )
        await router.configure(primary: primary, local: local)

        let requestURL = try XCTUnwrap(
            URL(string: "https://books.example/audiobookshelf/api/libraries")
        )
        let candidates = await router.candidates(for: requestURL)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(
            candidates.first?.url.absoluteString,
            "https://books.home/audiobookshelf/api/libraries"
        )
        XCTAssertTrue(candidates.first?.isLocal == true)
        XCTAssertEqual(candidates.last?.url, requestURL)
    }

    func testEndpointRouterTemporarilySkipsFailedLocalServer() async throws {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        await router.markLocalUnavailable(for: primary, duration: 60)

        let requestURL = try XCTUnwrap(
            URL(string: "https://books.example/api/libraries")
        )
        let candidates = await router.candidates(for: requestURL)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertFalse(candidates[0].isLocal)
        XCTAssertEqual(candidates[0].url, requestURL)
    }

    func testEndpointRouterUsesPrimaryUntilLocalIsRevalidatedAfterPathChange()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        await router.markLocalUnavailable(for: primary, duration: 60)

        let failedPreferredServer = await router.preferredServer(
            for: primary
        )
        XCTAssertEqual(failedPreferredServer.server, primary)

        let pathGeneration = await router.networkPathDidChange()

        let pendingPreferredServer = await router.preferredServer(
            for: primary
        )
        XCTAssertEqual(pendingPreferredServer.server, primary)
        let pendingAvailability = await router.localAvailability(for: primary)
        XCTAssertEqual(pendingAvailability, .unknown)

        await router.markLocalAvailable(
            for: primary,
            pathGeneration: pathGeneration
        )
        await router.finishNetworkPathEvaluation(pathGeneration)

        let recoveredPreferredServer = await router.preferredServer(
            for: primary)
        XCTAssertEqual(recoveredPreferredServer.server, local)
    }

    func testRouteConfiguredDuringPathEvaluationRemainsPrimaryUntilValidated()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")

        let pathGeneration = await router.networkPathDidChange()
        await router.configure(primary: primary, local: local)

        var selection = await router.preferredServer(for: primary)
        XCTAssertEqual(selection.server, primary)

        await router.markLocalAvailable(
            for: primary,
            pathGeneration: pathGeneration
        )
        await router.finishNetworkPathEvaluation(pathGeneration)

        selection = await router.preferredServer(for: primary)
        XCTAssertEqual(selection.server, local)
    }

    func testPreChangeLocalSuccessCannotCompleteCurrentPathEvaluation()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        let requestURL = try XCTUnwrap(
            URL(string: "https://books.example/api/libraries")
        )
        let candidates = await router.candidates(for: requestURL)
        let oldCandidate = try XCTUnwrap(candidates.first)

        _ = await router.networkPathDidChange()
        await router.recordSuccessfulUse(oldCandidate, endpoint: .libraries)

        let selection = await router.preferredServer(for: primary)
        XCTAssertEqual(selection.server, primary)
        let availability = await router.localAvailability(for: primary)
        XCTAssertEqual(availability, .unknown)
    }

    func testURLOnlyCompletionCannotMutateCurrentPathSelection()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        let localURL = try XCTUnwrap(
            URL(string: "https://books.home/audio/file.m4b")
        )

        let pathGeneration = await router.networkPathDidChange()
        await router.markLocalAvailable(
            for: primary,
            pathGeneration: pathGeneration
        )
        await router.finishNetworkPathEvaluation(pathGeneration)

        let reconstructed = await router.candidate(forResolvedURL: localURL)
        await router.markLocalUnavailable(reconstructed)
        await router.recordConnection(reconstructed, purpose: .download)

        let selection = await router.preferredServer(for: primary)
        XCTAssertEqual(selection.server, local)
        let availability = await router.localAvailability(for: primary)
        XCTAssertEqual(availability, .available)
    }

    func testUnresolvedPathEvaluationLeavesLocalTemporarilyUnavailable()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)

        let pathGeneration = await router.networkPathDidChange()
        await router.finishNetworkPathEvaluation(pathGeneration)

        let selection = await router.preferredServer(for: primary)
        XCTAssertEqual(selection.server, primary)
        let availability = await router.localAvailability(for: primary)
        XCTAssertEqual(availability, .temporarilyUnavailable)
    }

    func testEndpointRouterBuildsPrimaryFallbackFromResolvedLocalURL()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL(
            "https://books.example/audiobookshelf"
        )
        let local = try NormalizedServerURL(
            "https://books.home/local-books"
        )
        await router.configure(primary: primary, local: local)
        let failedURL = try XCTUnwrap(
            URL(string: "https://books.home/local-books/audio/file.m4b")
        )

        let fallback = await router.primaryFallback(
            forResolvedURL: failedURL
        )

        XCTAssertEqual(
            fallback?.url.absoluteString,
            "https://books.example/audiobookshelf/audio/file.m4b"
        )
        XCTAssertEqual(fallback?.primary, primary)
        XCTAssertFalse(fallback?.isLocal == true)
    }

    func testPrimaryFallbackRequestPreservesAuthenticationAndNetworkPolicy()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example/prefix")
        let local = try NormalizedServerURL("https://books.home/local")
        await router.configure(primary: primary, local: local)
        let localURL = try XCTUnwrap(
            URL(string: "https://books.home/local/items/book/download")
        )
        var request = URLRequest(url: localURL)
        request.httpMethod = "GET"
        request.setValue("Bearer opaque", forHTTPHeaderField: "Authorization")
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = false

        let fallback = await router.primaryFallbackRequest(for: request)

        XCTAssertEqual(
            fallback?.url?.absoluteString,
            "https://books.example/prefix/items/book/download"
        )
        XCTAssertEqual(fallback?.httpMethod, "GET")
        XCTAssertEqual(
            fallback?.value(forHTTPHeaderField: "Authorization"),
            "Bearer opaque"
        )
        XCTAssertFalse(fallback?.allowsConstrainedNetworkAccess == true)
        XCTAssertFalse(fallback?.allowsExpensiveNetworkAccess == true)
        let availability = await router.localAvailability(for: primary)
        XCTAssertEqual(availability, .unknown)
    }

    func testSuccessfulLocalUseClearsLocalCooldown() async throws {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        await router.markLocalUnavailable(for: primary, duration: 60)

        await router.markLocalAvailable(for: primary)

        let preferredServer = await router.preferredServer(for: primary)
        XCTAssertEqual(preferredServer.server, local)
    }

    func testEndpointRouterTracksAPIAndAuthenticationUsageSeparately()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        let requestURL = try XCTUnwrap(
            URL(string: "https://books.example/api/libraries")
        )
        let candidates = await router.candidates(for: requestURL)
        let localCandidate = try XCTUnwrap(candidates.first)
        let primaryCandidate = try XCTUnwrap(candidates.last)

        await router.recordSuccessfulUse(
            localCandidate,
            endpoint: .libraries
        )
        await router.recordSuccessfulUse(
            primaryCandidate,
            endpoint: .authorize
        )

        let apiUsage = await router.lastSuccessfulUse(for: primary)
        let authenticationUsage =
            await router.lastAuthenticationUse(for: primary)
        XCTAssertEqual(apiUsage, .local)
        XCTAssertEqual(authenticationUsage, .primary)
    }

    func testEndpointRouterStreamsEveryServerConnectionPurpose()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        let updates = await router.activityUpdates(for: primary)
        var iterator = updates.makeAsyncIterator()
        let initialUpdate = await iterator.next()
        XCTAssertEqual(
            initialUpdate,
            ServerEndpointActivitySnapshot()
        )
        let requestURL = try XCTUnwrap(
            URL(string: "https://books.example/audio/file.mp3")
        )
        let candidates = await router.candidates(for: requestURL)

        await router.recordConnection(
            try XCTUnwrap(candidates.first),
            purpose: .playback
        )

        let nextPlaybackUpdate = await iterator.next()
        let playbackUpdate = try XCTUnwrap(nextPlaybackUpdate)
        XCTAssertEqual(
            playbackUpdate.lastConnection,
            ServerConnectionActivity(
                usage: .local,
                purpose: .playback
            )
        )
        XCTAssertNil(playbackUpdate.api)

        await router.recordConnection(
            try XCTUnwrap(candidates.last),
            purpose: .webSocket
        )

        let nextWebSocketUpdate = await iterator.next()
        let webSocketUpdate = try XCTUnwrap(nextWebSocketUpdate)
        XCTAssertEqual(webSocketUpdate.webSocket, .primary)
        XCTAssertEqual(
            webSocketUpdate.lastConnection?.purpose,
            .webSocket
        )
    }

    func testURLSessionTransportReturnsTypedHTTPResponse() async throws {
        URLProtocolStub.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "X-Contract": "pinned",
                ]
            )!
            return (response, Data(#"{"ok":true}"#.utf8))
        }
        defer {
            URLProtocolStub.setHandler(nil)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let transport = URLSessionHTTPTransport(
            configuration: configuration
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/status"))

        let response = try await transport.send(
            TracedHTTPRequest(request: URLRequest(url: url), endpoint: .status)
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.data, Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(response.url, url)
        XCTAssertEqual(response.header(named: "x-contract"), "pinned")
        XCTAssertEqual(
            response.header(named: "CONTENT-TYPE"),
            "application/json"
        )
        XCTAssertNil(response.header(named: "missing"))
    }

    func testURLSessionTransportRejectsNonHTTPResponse() async throws {
        URLProtocolStub.setHandler { request in
            let response = URLResponse(
                url: request.url!,
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil
            )
            return (response, Data())
        }
        defer {
            URLProtocolStub.setHandler(nil)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let transport = URLSessionHTTPTransport(
            configuration: configuration
        )
        let url = try XCTUnwrap(URL(string: "https://example.com/status"))

        await assertThrowsErrorAsync(
            try await transport.send(
                TracedHTTPRequest(
                    request: URLRequest(url: url),
                    endpoint: .status
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? HTTPTransportError,
                .nonHTTPResponse
            )
        }
    }

    func testURLSessionTransportRecordsTypedRequestOutcome() async throws {
        URLProtocolStub.setHandler { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (response, Data())
        }
        defer {
            URLProtocolStub.setHandler(nil)
        }

        let recorder = DiagnosticRecorderSpy()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let transport = URLSessionHTTPTransport(
            configuration: configuration,
            diagnostics: recorder
        )
        let correlationID = UUID()
        var request = URLRequest(
            url: try XCTUnwrap(
                URL(string: "https://secret.example/api/items/private")
            )
        )
        request.httpMethod = "PATCH"

        _ = try await transport.send(
            TracedHTTPRequest(
                request: request,
                endpoint: .metadata,
                correlationID: correlationID
            )
        )

        let events = await recorder.events()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(
            events.map(\.correlationID),
            [
                correlationID, correlationID,
            ])
        XCTAssertEqual(events.map(\.endpoint), [.metadata, .metadata])
        XCTAssertEqual(events.map(\.method), [.patch, .patch])
        XCTAssertEqual(events.last?.statusCode, 204)
        XCTAssertFalse(events.map(\.text).joined().contains("secret"))
        XCTAssertFalse(events.map(\.text).joined().contains("private"))
    }

    func testOpenIDTransportKeepsThenClearsSessionCookies() async throws {
        let recorder = CookieFlowRecorder()
        URLProtocolStub.setHandler { request in
            let url = request.url!
            switch url.path {
            case "/auth/openid":
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Location":
                            "https://identity.example/authorize?opaque=1",
                        "Set-Cookie":
                            "connect.sid=fixture-session; Path=/; Secure; HttpOnly, auth_method=openid-mobile; Path=/; Secure; HttpOnly",
                    ]
                )!
                return (response, Data())
            case "/auth/openid/callback":
                recorder.recordCallbackCookie(
                    request.value(forHTTPHeaderField: "Cookie")
                )
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!
                return (response, Data(#"{"ok":true}"#.utf8))
            default:
                preconditionFailure("Unexpected URLProtocol test route")
            }
        }
        defer {
            URLProtocolStub.setHandler(nil)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let cookieStorage = try XCTUnwrap(
            configuration.httpCookieStorage
        )
        let transport = URLSessionOpenIDTransport(
            configuration: configuration,
            cookieStorage: cookieStorage
        )
        let beginURL = try XCTUnwrap(
            URL(string: "https://example.com/auth/openid")
        )
        let callbackURL = try XCTUnwrap(
            URL(string: "https://example.com/auth/openid/callback")
        )

        let beginResponse = try await transport.send(
            TracedHTTPRequest(
                request: URLRequest(url: beginURL),
                endpoint: .openIDSession
            )
        )
        XCTAssertEqual(beginResponse.statusCode, 302)
        XCTAssertEqual(
            beginResponse.header(named: "Location"),
            "https://identity.example/authorize?opaque=1"
        )
        XCTAssertEqual(transport.cookieCount, 2)

        let callbackResponse = try await transport.send(
            TracedHTTPRequest(
                request: URLRequest(url: callbackURL),
                endpoint: .openIDSession
            )
        )
        XCTAssertEqual(callbackResponse.statusCode, 200)
        let callbackCookie = try XCTUnwrap(
            recorder.callbackCookie()
        )
        XCTAssertTrue(
            callbackCookie.contains("connect.sid=fixture-session")
        )
        XCTAssertTrue(
            callbackCookie.contains("auth_method=openid-mobile")
        )

        await transport.clearSession()
        XCTAssertEqual(transport.cookieCount, 0)
    }

    func testOpenIDTransportDefaultConfigurationIsInitiallyEmpty()
        async throws
    {
        let transport = try URLSessionOpenIDTransport()

        XCTAssertEqual(transport.cookieCount, 0)
        await transport.clearSession()
        XCTAssertEqual(transport.cookieCount, 0)
    }
}

private actor DiagnosticRecorderSpy: DiagnosticRecording {
    private var recordedEvents: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        recordedEvents.append(event)
    }

    func events() -> [DiagnosticEvent] {
        recordedEvents
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (URLResponse, Data)

    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ newHandler: Handler?) {
        handlerLock.withLock {
            handler = newHandler
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let currentHandler = Self.handlerLock.withLock {
            Self.handler
        }
        guard let currentHandler else {
            client?.urlProtocol(
                self,
                didFailWithError: URLProtocolStubError.missingHandler
            )
            return
        }

        let (response, data) = currentHandler(request)
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private enum URLProtocolStubError: Error {
    case missingHandler
}

private final class CookieFlowRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cookie: String?

    func recordCallbackCookie(_ value: String?) {
        lock.withLock {
            cookie = value
        }
    }

    func callbackCookie() -> String? {
        lock.withLock {
            cookie
        }
    }
}
