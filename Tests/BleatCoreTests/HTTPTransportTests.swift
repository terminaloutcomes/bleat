import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class HTTPTransportTests {
    @Test
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

        let requestURL = try #require(
            URL(string: "https://books.example/audiobookshelf/api/libraries"))
        let candidates = await router.candidates(for: requestURL)

        #expect(candidates.count == 2)
        #expect(
            candidates.first?.url.absoluteString
                == "https://books.home/audiobookshelf/api/libraries")
        #expect(candidates.first?.isLocal == true)
        #expect(candidates.last?.url == requestURL)
    }

    @Test
    func testEndpointRouterSkipsFailedLocalServerUntilRevalidated() async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        await router.markLocalUnavailable(for: primary)

        let requestURL = try #require(
            URL(string: "https://books.example/api/libraries"))
        let candidates = await router.candidates(for: requestURL)

        #expect(candidates.count == 1)
        #expect(!(candidates[0].isLocal))
        #expect(candidates[0].url == requestURL)
    }

    @Test(arguments: ["", "/audiobookshelf"])
    func testFailedLocalSyncStaysOnPrimaryUntilSuccessfulProbe(prefix: String)
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example\(prefix)")
        let local = try NormalizedServerURL("https://books.home/local\(prefix)")
        await router.configure(primary: primary, local: local)
        let url = try #require(
            URL(
                string:
                    "https://books.example\(prefix)/api/session/session/sync"))
        let oldLocal = await router.preferredCandidate(for: url)
        let recorder = RoutedRequestRecorder()
        URLProtocolStub.setHandler { request in
            recorder.append(request.materializingBody())
            let url = try #require(request.url)
            if url.host == "books.home" {
                throw URLError(.timedOut)
            }
            let response = try #require(
                HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: nil))
            return (response, Data())
        }
        defer { URLProtocolStub.setHandler(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let transport = URLSessionHTTPTransport(
            configuration: configuration, endpointRouter: router)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(
            #"{"currentTime":12,"duration":30,"timeListened":0}"#.utf8)
        let traced = TracedHTTPRequest(request: request, endpoint: .syncSession)

        let initialResponse = try await transport.send(traced)
        #expect(initialResponse.statusCode == 200)
        // An older in-flight local success is not a fresh reachability probe.
        await router.recordSuccessfulUse(oldLocal, endpoint: .syncSession)
        for _ in 0..<4 {
            let response = try await transport.send(traced)
            #expect(response.statusCode == 200)
        }
        let requests = recorder.requests()
        #expect(requests.count == 6)
        #expect(requests.filter { $0.url?.host == "books.home" }.count == 1)
        #expect(requests.filter { $0.url == url }.count == 5)
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization")
                    == "Bearer fixture"
            })
        for sent in requests {
            let body = try #require(sent.httpBody)
            let payload = try JSONDecoder().decode(
                [String: Double].self, from: body)
            #expect(
                payload == [
                    "currentTime": 12, "duration": 30, "timeListened": 0,
                ])
        }
        let failedAvailability = await router.localAvailability(for: primary)
        #expect(failedAvailability == .temporarilyUnavailable)

        let failedProbe = await router.networkPathDidChange()
        await router.markLocalUnavailable(
            for: primary, pathGeneration: failedProbe)
        await router.finishNetworkPathEvaluation(failedProbe)
        let afterFailedProbe = try await transport.send(traced)
        #expect(afterFailedProbe.statusCode == 200)
        #expect(
            recorder.requests().filter { $0.url?.host == "books.home" }.count
                == 1)

        let successfulProbe = await router.networkPathDidChange()
        await router.markLocalAvailable(
            for: primary, pathGeneration: successfulProbe)
        await router.finishNetworkPathEvaluation(successfulProbe)
        let recovered = await router.preferredCandidate(for: url)
        #expect(recovered.isLocal)
        #expect(
            recovered.url.path == "/local\(prefix)/api/session/session/sync")
        let recoveredAvailability = await router.localAvailability(for: primary)
        #expect(recoveredAvailability == .available)
    }

    @Test
    func testEndpointRouterUsesPrimaryUntilLocalIsRevalidatedAfterPathChange()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        await router.markLocalUnavailable(for: primary)

        let failedPreferredServer = await router.preferredServer(
            for: primary
        )
        #expect(failedPreferredServer.server == primary)

        let pathGeneration = await router.networkPathDidChange()

        let pendingPreferredServer = await router.preferredServer(
            for: primary
        )
        #expect(pendingPreferredServer.server == primary)
        let pendingAvailability = await router.localAvailability(for: primary)
        #expect(pendingAvailability == .unknown)

        await router.markLocalAvailable(
            for: primary,
            pathGeneration: pathGeneration
        )
        await router.finishNetworkPathEvaluation(pathGeneration)

        let recoveredPreferredServer = await router.preferredServer(
            for: primary)
        #expect(recoveredPreferredServer.server == local)
    }

    @Test
    func testRouteConfiguredDuringPathEvaluationRemainsPrimaryUntilValidated()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")

        let pathGeneration = await router.networkPathDidChange()
        await router.configure(primary: primary, local: local)

        var selection = await router.preferredServer(for: primary)
        #expect(selection.server == primary)

        await router.markLocalAvailable(
            for: primary,
            pathGeneration: pathGeneration
        )
        await router.finishNetworkPathEvaluation(pathGeneration)

        selection = await router.preferredServer(for: primary)
        #expect(selection.server == local)
    }

    @Test
    func testPreChangeLocalSuccessCannotCompleteCurrentPathEvaluation()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        let requestURL = try #require(
            URL(string: "https://books.example/api/libraries"))
        let candidates = await router.candidates(for: requestURL)
        let oldCandidate = try #require(candidates.first)

        _ = await router.networkPathDidChange()
        await router.recordSuccessfulUse(oldCandidate, endpoint: .libraries)

        let selection = await router.preferredServer(for: primary)
        #expect(selection.server == primary)
        let availability = await router.localAvailability(for: primary)
        #expect(availability == .unknown)
    }

    @Test
    func testURLOnlyCompletionCannotMutateCurrentPathSelection()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        let localURL = try #require(
            URL(string: "https://books.home/audio/file.m4b"))

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
        #expect(selection.server == local)
        let availability = await router.localAvailability(for: primary)
        #expect(availability == .available)
    }

    @Test
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
        #expect(selection.server == primary)
        let availability = await router.localAvailability(for: primary)
        #expect(availability == .temporarilyUnavailable)
    }

    @Test
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
        let failedURL = try #require(
            URL(string: "https://books.home/local-books/audio/file.m4b"))

        let fallback = await router.primaryFallback(
            forResolvedURL: failedURL
        )

        #expect(
            fallback?.url.absoluteString
                == "https://books.example/audiobookshelf/audio/file.m4b")
        #expect(fallback?.primary == primary)
        #expect(!(fallback?.isLocal == true))
    }

    @Test
    func testPrimaryFallbackRequestPreservesAuthenticationAndNetworkPolicy()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example/prefix")
        let local = try NormalizedServerURL("https://books.home/local")
        await router.configure(primary: primary, local: local)
        let localURL = try #require(
            URL(string: "https://books.home/local/items/book/download"))
        var request = URLRequest(url: localURL)
        request.httpMethod = "GET"
        request.setValue("Bearer opaque", forHTTPHeaderField: "Authorization")
        request.allowsConstrainedNetworkAccess = false
        request.allowsExpensiveNetworkAccess = false

        let fallback = await router.primaryFallbackRequest(for: request)

        #expect(
            fallback?.url?.absoluteString
                == "https://books.example/prefix/items/book/download")
        #expect(fallback?.httpMethod == "GET")
        #expect(
            fallback?.value(forHTTPHeaderField: "Authorization")
                == "Bearer opaque")
        #expect(!(fallback?.allowsConstrainedNetworkAccess == true))
        #expect(!(fallback?.allowsExpensiveNetworkAccess == true))
        let availability = await router.localAvailability(for: primary)
        #expect(availability == .unknown)
    }

    @Test
    func testSuccessfulProbeRestoresFailedLocalServer() async throws {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        await router.markLocalUnavailable(for: primary)

        let generation = await router.networkPathDidChange()
        await router.markLocalAvailable(
            for: primary, pathGeneration: generation)
        await router.finishNetworkPathEvaluation(generation)

        let preferredServer = await router.preferredServer(for: primary)
        #expect(preferredServer.server == local)
    }

    @Test
    func testEndpointRouterTracksAPIAndAuthenticationUsageSeparately()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        let requestURL = try #require(
            URL(string: "https://books.example/api/libraries"))
        let candidates = await router.candidates(for: requestURL)
        let localCandidate = try #require(candidates.first)
        let primaryCandidate = try #require(candidates.last)

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
        #expect(apiUsage == .local)
        #expect(authenticationUsage == .primary)
    }

    @Test
    func testEndpointRouterStreamsEveryServerConnectionPurpose()
        async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://books.example")
        let local = try NormalizedServerURL("https://books.home")
        await router.configure(primary: primary, local: local)
        let updates = await router.activityUpdates(for: primary)
        let reader = BoundedAsyncStreamReader(updates)
        guard
            let initialUpdate = await requireEndpointActivitySnapshot(
                from: reader, stage: "initial snapshot")
        else { return }
        #expect(initialUpdate == ServerEndpointActivitySnapshot())
        let requestURL = try #require(
            URL(string: "https://books.example/audio/file.mp3"))
        let candidates = await router.candidates(for: requestURL)

        await router.recordConnection(
            try #require(candidates.first),
            purpose: .playback
        )

        guard
            let playbackUpdate = await requireEndpointActivitySnapshot(
                from: reader, stage: "playback update")
        else { return }
        #expect(
            playbackUpdate.lastConnection
                == ServerConnectionActivity(
                    usage: .local,
                    purpose: .playback
                ))
        #expect(playbackUpdate.api == nil)

        await router.recordConnection(
            try #require(candidates.last),
            purpose: .webSocket
        )

        guard
            let webSocketUpdate = await requireEndpointActivitySnapshot(
                from: reader, stage: "WebSocket update")
        else { return }
        #expect(webSocketUpdate.webSocket == .primary)
        #expect(webSocketUpdate.lastConnection?.purpose == .webSocket)
    }

    @Test
    func testURLSessionTransportReturnsTypedHTTPResponse() async throws {
        URLProtocolStub.setHandler { request in
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": "application/json",
                        "X-Contract": "pinned",
                    ]
                ))
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
        let url = try #require(URL(string: "https://example.com/status"))

        let response = try await transport.send(
            TracedHTTPRequest(request: URLRequest(url: url), endpoint: .status)
        )

        #expect(response.statusCode == 200)
        #expect(response.data == Data(#"{"ok":true}"#.utf8))
        #expect(response.url == url)
        #expect(response.header(named: "x-contract") == "pinned")
        #expect(response.header(named: "CONTENT-TYPE") == "application/json")
        #expect(response.header(named: "missing") == nil)
    }

    @Test
    func testURLSessionTransportRejectsNonHTTPResponse() async throws {
        URLProtocolStub.setHandler { request in
            let response = URLResponse(
                url: try #require(request.url),
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
        let url = try #require(URL(string: "https://example.com/status"))

        await assertThrowsErrorAsync(
            try await transport.send(
                TracedHTTPRequest(
                    request: URLRequest(url: url),
                    endpoint: .status
                )
            )
        ) { error in
            #expect(error as? HTTPTransportError == .nonHTTPResponse)
        }
    }

    @Test
    func testURLSessionTransportRecordsTypedRequestOutcome() async throws {
        URLProtocolStub.setHandler { request in
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(
                    url: url,
                    statusCode: 204,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                ))
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
            url: try #require(
                URL(string: "https://secret.example/api/items/private"))
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
        #expect(events.count == 2)
        #expect(
            events.map(\.correlationID) == [
                correlationID, correlationID,
            ])
        #expect(events.map(\.endpoint) == [.metadata, .metadata])
        #expect(events.map(\.method) == [.patch, .patch])
        #expect(events.last?.statusCode == 204)
        #expect(!(events.map(\.text).joined().contains("secret")))
        #expect(!(events.map(\.text).joined().contains("private")))
    }

    @Test
    func testOpenIDTransportKeepsThenClearsSessionCookies() async throws {
        let fixture = try OpenIDCookieFixture()
        try await fixture.run { transport, recorder in
            let beginURL = try #require(
                URL(string: "https://example.com/auth/openid"))
            let callbackURL = try #require(
                URL(string: "https://example.com/auth/openid/callback"))

            let beginResponse = try await transport.send(
                TracedHTTPRequest(
                    request: URLRequest(url: beginURL),
                    endpoint: .openIDSession
                )
            )
            #expect(beginResponse.statusCode == 302)
            #expect(
                beginResponse.header(named: "Location")
                    == "https://identity.example/authorize?opaque=1")
            #expect(transport.cookieCount == 2)

            let callbackResponse = try await transport.send(
                TracedHTTPRequest(
                    request: URLRequest(url: callbackURL),
                    endpoint: .openIDSession
                )
            )
            #expect(callbackResponse.statusCode == 200)
            let callbackCookie = try #require(recorder.callbackCookie())
            #expect(callbackCookie.contains("connect.sid=fixture-session"))
            #expect(callbackCookie.contains("auth_method=openid-mobile"))

            await transport.clearSession()
            #expect(transport.cookieCount == 0)
        }
        #expect(fixture.transport.cookieCount == 0)
        #expect(!URLProtocolStub.hasHandler)
    }

    @Test
    func testOpenIDTransportUnexpectedRouteThrowsAndCleansUp() async throws {
        let fixture = try OpenIDCookieFixture()
        let beginURL = try #require(
            URL(string: "https://example.com/auth/openid"))
        let unexpectedURL = try #require(
            URL(string: "https://example.com/unexpected-openid-route"))

        do {
            try await fixture.run { transport, _ in
                let response = try await transport.send(
                    TracedHTTPRequest(
                        request: URLRequest(url: beginURL),
                        endpoint: .openIDSession))
                #expect(response.statusCode == 302)
                try #require(transport.cookieCount == 2)

                _ = try await transport.send(
                    TracedHTTPRequest(
                        request: URLRequest(url: unexpectedURL),
                        endpoint: .openIDSession))
            }
            Issue.record(
                "Expected the fixture route failure to reach its caller")
        } catch {
            // URLSession bridges handler errors to NSError, preserving domain/code/userInfo.
            let received = error as NSError
            let expected = OpenIDCookieFixtureError.unexpectedRoute(
                path: unexpectedURL.path)
            #expect(received.domain == OpenIDCookieFixtureError.errorDomain)
            #expect(received.code == expected.errorCode)
            #expect(
                received.userInfo["fixturePath"] as? String
                    == unexpectedURL.path)
        }
        // run awaits session cleanup before rethrowing; no scheduler delay is needed.
        #expect(fixture.transport.cookieCount == 0)
        #expect(!URLProtocolStub.hasHandler)
    }

    @Test
    func testOpenIDTransportDefaultConfigurationIsInitiallyEmpty()
        async throws
    {
        let transport = try URLSessionOpenIDTransport()

        #expect(transport.cookieCount == 0)
        await transport.clearSession()
        #expect(transport.cookieCount == 0)
    }
}

private func requireEndpointActivitySnapshot(
    from reader: BoundedAsyncStreamReader<ServerEndpointActivitySnapshot>,
    stage: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> ServerEndpointActivitySnapshot? {
    switch await reader.next() {
    case .element(let snapshot):
        return snapshot
    case .finished:
        Issue.record(
            "Endpoint activity stream finished before the \(stage)",
            sourceLocation: sourceLocation
        )
    case .timedOut(let timeout, let elapsed):
        Issue.record(
            "Endpoint activity stream missed the \(stage); elapsed \(elapsed), limit \(timeout)",
            sourceLocation: sourceLocation
        )
    }
    return nil
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
    typealias Handler = @Sendable (URLRequest) throws -> (URLResponse, Data)

    private static let handlerLock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ newHandler: Handler?) {
        handlerLock.withLock {
            handler = newHandler
        }
    }

    static var hasHandler: Bool {
        handlerLock.withLock { handler != nil }
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

        let response: URLResponse
        let data: Data
        do {
            (response, data) = try currentHandler(request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
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

private enum OpenIDCookieFixtureError: Error, CustomNSError {
    case missingRequestURL
    case invalidResponse(path: String, statusCode: Int)
    case unexpectedRoute(path: String)

    static let errorDomain = "BleatTests.OpenIDCookieFixture"

    var errorCode: Int {
        switch self {
        case .missingRequestURL: 1
        case .invalidResponse: 2
        case .unexpectedRoute: 3
        }
    }

    var errorUserInfo: [String: Any] {
        switch self {
        case .missingRequestURL:
            [NSLocalizedDescriptionKey: "OpenID fixture request has no URL"]
        case .invalidResponse(let path, let statusCode):
            [
                NSLocalizedDescriptionKey: "Invalid OpenID fixture response",
                "fixturePath": path, "fixtureStatusCode": statusCode,
            ]
        case .unexpectedRoute(let path):
            [
                NSLocalizedDescriptionKey: "Unexpected OpenID fixture route",
                "fixturePath": path,
            ]
        }
    }
}

private struct OpenIDCookieFixture {
    let transport: URLSessionOpenIDTransport
    private let recorder = CookieFlowRecorder()

    init() throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let cookieStorage = try #require(configuration.httpCookieStorage)
        transport = URLSessionOpenIDTransport(
            configuration: configuration, cookieStorage: cookieStorage)
    }

    func run(
        _ body: (URLSessionOpenIDTransport, CookieFlowRecorder) async throws ->
            Void
    ) async throws {
        URLProtocolStub.setHandler { [recorder] request in
            guard let url = request.url else {
                throw OpenIDCookieFixtureError.missingRequestURL
            }
            let statusCode: Int
            let headers: [String: String]?
            let data: Data
            switch url.path {
            case "/auth/openid":
                statusCode = 302
                headers = [
                    "Location": "https://identity.example/authorize?opaque=1",
                    "Set-Cookie":
                        "connect.sid=fixture-session; Path=/; Secure; HttpOnly, auth_method=openid-mobile; Path=/; Secure; HttpOnly",
                ]
                data = Data()
            case "/auth/openid/callback":
                recorder.recordCallbackCookie(
                    request.value(forHTTPHeaderField: "Cookie"))
                statusCode = 200
                headers = nil
                data = Data(#"{"ok":true}"#.utf8)
            default:
                throw OpenIDCookieFixtureError.unexpectedRoute(path: url.path)
            }
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: statusCode,
                    httpVersion: "HTTP/1.1", headerFields: headers)
            else {
                throw OpenIDCookieFixtureError.invalidResponse(
                    path: url.path, statusCode: statusCode)
            }
            return (response, data)
        }
        defer { URLProtocolStub.setHandler(nil) }
        try await withTestCleanup {
            await transport.clearSession()
        } operation: {
            try await body(transport, recorder)
        }
    }
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

private final class RoutedRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { recorded.append(request) }
    }

    func requests() -> [URLRequest] {
        lock.withLock { recorded }
    }
}
