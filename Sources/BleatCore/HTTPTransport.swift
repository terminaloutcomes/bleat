import Foundation

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]
    public let url: URL?

    public init(
        data: Data,
        statusCode: Int,
        headers: [String: String] = [:],
        url: URL? = nil
    ) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
        self.url = url
    }

    public func header(named name: String) -> String? {
        headers.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

public struct TracedHTTPRequest: Sendable {
    public let request: URLRequest
    public let endpoint: DiagnosticEndpoint
    public let correlationID: UUID

    public init(
        request: URLRequest,
        endpoint: DiagnosticEndpoint,
        correlationID: UUID = UUID()
    ) {
        self.request = request
        self.endpoint = endpoint
        self.correlationID = correlationID
    }

    public func replacingRequest(_ request: URLRequest) -> TracedHTTPRequest {
        TracedHTTPRequest(
            request: request,
            endpoint: endpoint,
            correlationID: correlationID
        )
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: TracedHTTPRequest) async throws -> HTTPResponse
}

public struct ServerEndpointCandidate: Sendable {
    public let url: URL
    public let primary: NormalizedServerURL?
    public let isLocal: Bool
    public let pathGeneration: ServerEndpointPathGeneration?

    public init(
        url: URL,
        primary: NormalizedServerURL?,
        isLocal: Bool,
        pathGeneration: ServerEndpointPathGeneration? = nil
    ) {
        self.url = url
        self.primary = primary
        self.isLocal = isLocal
        self.pathGeneration = pathGeneration
    }
}

public struct ServerEndpointPathGeneration: Equatable, Sendable {
    fileprivate let value: UInt64
}

public struct ServerEndpointServerSelection: Equatable, Sendable {
    public let server: NormalizedServerURL
    public let usage: ServerEndpointUsage
    public let pathGeneration: ServerEndpointPathGeneration
}

public enum ServerEndpointUsage: String, Codable, Equatable, Sendable {
    case primary
    case local
}

public enum ServerEndpointLocalAvailability: Equatable, Sendable {
    case notConfigured
    case unknown
    case available
    case temporarilyUnavailable
}

public enum ServerConnectionPurpose: String, Codable, Equatable, Sendable {
    case authentication
    case api
    case webSocket
    case cover
    case playback
    case download
}

public struct ServerConnectionActivity: Equatable, Sendable {
    public let usage: ServerEndpointUsage
    public let purpose: ServerConnectionPurpose

    public init(
        usage: ServerEndpointUsage,
        purpose: ServerConnectionPurpose
    ) {
        self.usage = usage
        self.purpose = purpose
    }
}

public struct ServerEndpointActivitySnapshot: Equatable, Sendable {
    public let lastConnection: ServerConnectionActivity?
    public let authentication: ServerEndpointUsage?
    public let api: ServerEndpointUsage?
    public let webSocket: ServerEndpointUsage?

    public init(
        lastConnection: ServerConnectionActivity? = nil,
        authentication: ServerEndpointUsage? = nil,
        api: ServerEndpointUsage? = nil,
        webSocket: ServerEndpointUsage? = nil
    ) {
        self.lastConnection = lastConnection
        self.authentication = authentication
        self.api = api
        self.webSocket = webSocket
    }
}

public actor ServerEndpointRouter {
    private struct Route: Sendable {
        let primary: NormalizedServerURL
        let local: NormalizedServerURL?
    }

    private var routes: [NormalizedServerURL: Route] = [:]
    private var localFailures: [NormalizedServerURL: Date] = [:]
    private var currentPathGeneration = ServerEndpointPathGeneration(value: 0)
    private var activePathEvaluation: ServerEndpointPathGeneration?
    private var pendingLocalPathEvaluations:
        [NormalizedServerURL: ServerEndpointPathGeneration] = [:]
    private var localAvailabilityStates:
        [NormalizedServerURL: ServerEndpointLocalAvailability] = [:]
    private var activity:
        [NormalizedServerURL: ServerEndpointActivitySnapshot] = [:]
    private var activityObservers:
        [
            NormalizedServerURL:
                [
                    UUID:
                        AsyncStream<
                            ServerEndpointActivitySnapshot
                        >.Continuation
                ]
        ] = [:]

    public init() {}

    public func configure(
        primary: NormalizedServerURL,
        local: NormalizedServerURL?
    ) {
        let route = Route(
            primary: primary,
            local: local == primary ? nil : local
        )
        let unchanged = routes[primary]?.local == route.local
        routes[primary] = route
        guard !unchanged else {
            return
        }
        localFailures[primary] = nil
        if let generation = activePathEvaluation, route.local != nil {
            pendingLocalPathEvaluations[primary] = generation
        } else {
            pendingLocalPathEvaluations[primary] = nil
        }
        localAvailabilityStates[primary] = route.local == nil
            ? .notConfigured : .unknown
    }

    public func candidates(for url: URL) -> [ServerEndpointCandidate] {
        for route in routes.values {
            guard let local = route.local else {
                if isURL(url, under: route.primary) {
                    return [ServerEndpointCandidate(
                        url: url,
                        primary: route.primary,
                        isLocal: false,
                        pathGeneration: currentPathGeneration
                    )]
                }
                continue
            }
            guard let localURL = replacingBase(
                in: url,
                from: route.primary,
                with: local
            ) else {
                continue
            }
            if pendingLocalPathEvaluations[route.primary] != nil
                || localFailureIsActive(for: route.primary)
            {
                return [ServerEndpointCandidate(
                    url: url,
                    primary: route.primary,
                    isLocal: false,
                    pathGeneration: currentPathGeneration
                )]
            }
            return [
                ServerEndpointCandidate(
                    url: localURL,
                    primary: route.primary,
                    isLocal: true,
                    pathGeneration: currentPathGeneration
                ),
                ServerEndpointCandidate(
                    url: url,
                    primary: route.primary,
                    isLocal: false,
                    pathGeneration: currentPathGeneration
                ),
            ]
        }
        return [ServerEndpointCandidate(
            url: url,
            primary: nil,
            isLocal: false,
            pathGeneration: currentPathGeneration
        )]
    }

    public func candidate(
        forResolvedURL url: URL
    ) -> ServerEndpointCandidate {
        for route in routes.values {
            if isURL(url, under: route.primary) {
                return ServerEndpointCandidate(
                    url: url,
                    primary: route.primary,
                    isLocal: false
                )
            }
            if let local = route.local, isURL(url, under: local) {
                return ServerEndpointCandidate(
                    url: url,
                    primary: route.primary,
                    isLocal: true
                )
            }
        }
        return ServerEndpointCandidate(
            url: url,
            primary: nil,
            isLocal: false
        )
    }

    public func preferredCandidate(
        for url: URL
    ) -> ServerEndpointCandidate {
        candidates(for: url).first
            ?? ServerEndpointCandidate(
                url: url,
                primary: nil,
                isLocal: false
            )
    }

    public func preferredURL(for url: URL) -> URL {
        preferredCandidate(for: url).url
    }

    public func primaryFallback(
        forResolvedURL url: URL
    ) -> ServerEndpointCandidate? {
        for route in routes.values {
            guard let local = route.local,
                let primaryURL = replacingBase(
                    in: url,
                    from: local,
                    with: route.primary
                )
            else {
                continue
            }
            return ServerEndpointCandidate(
                url: primaryURL,
                primary: route.primary,
                isLocal: false
            )
        }
        return nil
    }

    public func primaryFallbackRequest(
        for failedRequest: URLRequest
    ) -> URLRequest? {
        guard let failedURL = failedRequest.url,
            candidate(forResolvedURL: failedURL).isLocal,
            let fallback = primaryFallback(forResolvedURL: failedURL)
        else {
            return nil
        }
        var request = failedRequest
        request.url = fallback.url
        return request
    }

    public func preferredServer(
        for primary: NormalizedServerURL
    ) -> ServerEndpointServerSelection {
        guard let route = routes[primary], let local = route.local else {
            return ServerEndpointServerSelection(
                server: primary,
                usage: .primary,
                pathGeneration: currentPathGeneration
            )
        }
        if pendingLocalPathEvaluations[primary] != nil
            || localFailureIsActive(for: primary)
        {
            return ServerEndpointServerSelection(
                server: primary,
                usage: .primary,
                pathGeneration: currentPathGeneration
            )
        }
        return ServerEndpointServerSelection(
            server: local,
            usage: .local,
            pathGeneration: currentPathGeneration
        )
    }

    public func networkPathDidChange() -> ServerEndpointPathGeneration {
        currentPathGeneration = ServerEndpointPathGeneration(
            value: currentPathGeneration.value &+ 1
        )
        activePathEvaluation = currentPathGeneration
        for primary in routes.keys {
            localFailures[primary] = nil
            if routes[primary]?.local == nil {
                pendingLocalPathEvaluations[primary] = nil
                localAvailabilityStates[primary] = .notConfigured
            } else {
                pendingLocalPathEvaluations[primary] = currentPathGeneration
                localAvailabilityStates[primary] = .unknown
            }
            publishCurrentActivity(for: primary)
        }
        return currentPathGeneration
    }

    public func markLocalAvailable(
        for primary: NormalizedServerURL
    ) {
        guard pendingLocalPathEvaluations[primary] == nil else {
            return
        }
        localFailures[primary] = nil
        localAvailabilityStates[primary] = .available
        publishCurrentActivity(for: primary)
    }

    public func markLocalAvailable(
        for primary: NormalizedServerURL,
        pathGeneration: ServerEndpointPathGeneration
    ) {
        guard pathGeneration == currentPathGeneration,
            pendingLocalPathEvaluations[primary] == pathGeneration
        else {
            return
        }
        pendingLocalPathEvaluations[primary] = nil
        localFailures[primary] = nil
        localAvailabilityStates[primary] = .available
        publishCurrentActivity(for: primary)
    }

    public func markLocalUnavailable(
        for primary: NormalizedServerURL,
        duration: TimeInterval = 30
    ) {
        guard pendingLocalPathEvaluations[primary] == nil else {
            return
        }
        localFailures[primary] = Date().addingTimeInterval(duration)
        localAvailabilityStates[primary] = .temporarilyUnavailable
        publishCurrentActivity(for: primary)
    }

    public func markLocalUnavailable(
        for primary: NormalizedServerURL,
        pathGeneration: ServerEndpointPathGeneration,
        duration: TimeInterval = 30
    ) {
        guard pathGeneration == currentPathGeneration,
            pendingLocalPathEvaluations[primary] == pathGeneration
        else {
            return
        }
        pendingLocalPathEvaluations[primary] = nil
        localFailures[primary] = Date().addingTimeInterval(duration)
        localAvailabilityStates[primary] = .temporarilyUnavailable
        publishCurrentActivity(for: primary)
    }

    public func markLocalUnavailable(
        _ candidate: ServerEndpointCandidate,
        duration: TimeInterval = 30
    ) {
        guard candidate.isLocal,
            let primary = candidate.primary,
            candidate.pathGeneration == currentPathGeneration,
            pendingLocalPathEvaluations[primary] == nil
        else {
            return
        }
        markLocalUnavailable(for: primary, duration: duration)
    }

    public func finishNetworkPathEvaluation(
        _ pathGeneration: ServerEndpointPathGeneration
    ) {
        guard activePathEvaluation == pathGeneration else {
            return
        }
        activePathEvaluation = nil
        let unresolved = pendingLocalPathEvaluations.compactMap {
            primary, generation in
            generation == pathGeneration ? primary : nil
        }
        for primary in unresolved {
            pendingLocalPathEvaluations[primary] = nil
            localFailures[primary] = Date().addingTimeInterval(30)
            localAvailabilityStates[primary] = .temporarilyUnavailable
            publishCurrentActivity(for: primary)
        }
    }

    public func localAvailability(
        for primary: NormalizedServerURL
    ) -> ServerEndpointLocalAvailability {
        guard routes[primary]?.local != nil else {
            return .notConfigured
        }
        return localAvailabilityStates[primary] ?? .unknown
    }

    public func recordSuccessfulUse(
        _ candidate: ServerEndpointCandidate,
        endpoint: DiagnosticEndpoint
    ) {
        switch endpoint {
        case .login, .authorize, .refresh, .logout:
            recordConnection(candidate, purpose: .authentication)
        default:
            recordConnection(candidate, purpose: .api)
        }
    }

    public func recordConnection(
        _ candidate: ServerEndpointCandidate,
        purpose: ServerConnectionPurpose
    ) {
        if candidate.isLocal, let primary = candidate.primary {
            if candidate.pathGeneration == currentPathGeneration,
                pendingLocalPathEvaluations[primary] == nil
            {
                localFailures[primary] = nil
                localAvailabilityStates[primary] = .available
            }
        }
        guard let primary = candidate.primary else {
            return
        }
        recordConnection(
            primary: primary,
            usage: candidate.isLocal ? .local : .primary,
            purpose: purpose
        )
    }

    private func localFailureIsActive(
        for primary: NormalizedServerURL
    ) -> Bool {
        guard let failedUntil = localFailures[primary] else {
            return false
        }
        return failedUntil > Date()
    }

    public func recordConnection(
        primary: NormalizedServerURL,
        usage: ServerEndpointUsage,
        purpose: ServerConnectionPurpose
    ) {
        let previous = activity[primary]
            ?? ServerEndpointActivitySnapshot()
        let updated = ServerEndpointActivitySnapshot(
            lastConnection: ServerConnectionActivity(
                usage: usage,
                purpose: purpose
            ),
            authentication:
                purpose == .authentication
                ? usage : previous.authentication,
            api: purpose == .api ? usage : previous.api,
            webSocket:
                purpose == .webSocket
                ? usage : previous.webSocket
        )
        activity[primary] = updated
        if let observers = activityObservers[primary] {
            for continuation in observers.values {
                continuation.yield(updated)
            }
        }
    }

    public func recordAuthenticationUse(
        primary: NormalizedServerURL,
        usage: ServerEndpointUsage
    ) {
        recordConnection(
            primary: primary,
            usage: usage,
            purpose: .authentication
        )
    }

    public func lastSuccessfulUse(
        for primary: NormalizedServerURL
    ) -> ServerEndpointUsage? {
        activity[primary]?.api
    }

    public func lastAuthenticationUse(
        for primary: NormalizedServerURL
    ) -> ServerEndpointUsage? {
        activity[primary]?.authentication
    }

    public func activitySnapshot(
        for primary: NormalizedServerURL
    ) -> ServerEndpointActivitySnapshot {
        activity[primary] ?? ServerEndpointActivitySnapshot()
    }

    public func activityUpdates(
        for primary: NormalizedServerURL
    ) -> AsyncStream<ServerEndpointActivitySnapshot> {
        let observerID = UUID()
        let initial = activitySnapshot(for: primary)
        return AsyncStream { continuation in
            activityObservers[primary, default: [:]][observerID] =
                continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeActivityObserver(
                        observerID,
                        primary: primary
                    )
                }
            }
        }
    }

    private func replacingBase(
        in url: URL,
        from primary: NormalizedServerURL,
        with local: NormalizedServerURL
    ) -> URL? {
        guard
            let request = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            let primaryComponents = URLComponents(
                url: primary.url,
                resolvingAgainstBaseURL: false
            ),
            let localComponents = URLComponents(
                url: local.url,
                resolvingAgainstBaseURL: false
            ),
            request.scheme == primaryComponents.scheme,
            request.host == primaryComponents.host,
            request.port == primaryComponents.port,
            request.path.hasPrefix(primaryComponents.path)
        else {
            return nil
        }
        var updated = request
        let suffix = String(
            request.path.dropFirst(primaryComponents.path.count)
        )
        updated.scheme = localComponents.scheme
        updated.host = localComponents.host
        updated.port = localComponents.port
        updated.path = localComponents.path + suffix
        return updated.url
    }

    private func isURL(
        _ url: URL,
        under server: NormalizedServerURL
    ) -> Bool {
        replacingBase(in: url, from: server, with: server) != nil
    }

    private func removeActivityObserver(
        _ observerID: UUID,
        primary: NormalizedServerURL
    ) {
        activityObservers[primary]?[observerID] = nil
        if activityObservers[primary]?.isEmpty == true {
            activityObservers[primary] = nil
        }
    }

    private func publishCurrentActivity(for primary: NormalizedServerURL) {
        guard let observers = activityObservers[primary] else {
            return
        }
        let snapshot = activitySnapshot(for: primary)
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }
}

public enum HTTPTransportError: Error, Equatable, Sendable {
    case nonHTTPResponse
}

private final class RedirectBlockingDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let diagnostics: any DiagnosticRecording
    private let endpointRouter: ServerEndpointRouter?
    private let routesRequests: Bool

    public convenience init(
        configuration: URLSessionConfiguration = .ephemeral,
        diagnostics: any DiagnosticRecording = SystemDiagnosticRecorder.shared,
        endpointRouter: ServerEndpointRouter? = nil,
        routesRequests: Bool = true
    ) {
        self.init(
            configuration: configuration,
            cookieStorage: nil,
            diagnostics: diagnostics,
            endpointRouter: endpointRouter,
            routesRequests: routesRequests
        )
    }

    init(
        configuration: URLSessionConfiguration,
        cookieStorage: HTTPCookieStorage?,
        diagnostics: any DiagnosticRecording = SystemDiagnosticRecorder.shared,
        endpointRouter: ServerEndpointRouter? = nil,
        routesRequests: Bool = true
    ) {
        configuration.httpShouldSetCookies = cookieStorage != nil
        configuration.httpCookieStorage = cookieStorage
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15

        session = URLSession(
            configuration: configuration,
            delegate: RedirectBlockingDelegate(),
            delegateQueue: nil
        )
        self.diagnostics = diagnostics
        self.endpointRouter = endpointRouter
        self.routesRequests = routesRequests
    }

    public func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
        let candidates: [ServerEndpointCandidate]
        if let endpointRouter, let url = request.url, routesRequests {
            candidates = await endpointRouter.candidates(for: url)
        } else if let endpointRouter, let url = request.url {
            candidates = [
                await endpointRouter.candidate(forResolvedURL: url)
            ]
        } else if let url = request.url {
            candidates = [ServerEndpointCandidate(
                url: url,
                primary: nil,
                isLocal: false
            )]
        } else {
            candidates = []
        }
        var lastError: Error?
        for candidate in candidates {
            do {
                let response = try await send(
                    tracedRequest,
                    requestURL: candidate.url
                )
                await endpointRouter?.recordSuccessfulUse(
                    candidate,
                    endpoint: tracedRequest.endpoint
                )
                return response
            } catch {
                if Task.isCancelled {
                    throw error
                }
                lastError = error
                if candidate.isLocal {
                    await endpointRouter?.markLocalUnavailable(candidate)
                    continue
                }
                throw error
            }
        }
        if let lastError {
            throw lastError
        }
        throw HTTPTransportError.nonHTTPResponse
    }

    private func send(
        _ tracedRequest: TracedHTTPRequest,
        requestURL: URL
    ) async throws -> HTTPResponse {
        var request = tracedRequest.request
        request.url = requestURL
        let method = DiagnosticHTTPMethod(request.httpMethod)
        await diagnostics.record(
            .started(
                .httpRequest,
                category: .api,
                endpoint: tracedRequest.endpoint,
                method: method,
                correlationID: tracedRequest.correlationID
            )
        )
        let clock = ContinuousClock()
        let start = clock.now
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            await diagnostics.record(
                .failed(
                    .httpRequest,
                    category: .api,
                    failureCode:
                        error is CancellationError
                        ? .requestCancelled
                        : .requestTransportFailed,
                    endpoint: tracedRequest.endpoint,
                    method: method,
                    correlationID: tracedRequest.correlationID,
                    durationMilliseconds: Self.milliseconds(
                        clock.now - start
                    )
                )
            )
            throw error
        }
        guard let response = response as? HTTPURLResponse else {
            await diagnostics.record(
                .failed(
                    .httpRequest,
                    category: .api,
                    failureCode: .nonHTTPResponse,
                    endpoint: tracedRequest.endpoint,
                    method: method,
                    correlationID: tracedRequest.correlationID,
                    durationMilliseconds: Self.milliseconds(
                        clock.now - start
                    )
                )
            )
            throw HTTPTransportError.nonHTTPResponse
        }

        let headers = response.allHeaderFields.reduce(
            into: [String: String]()
        ) { result, header in
            guard let name = header.key as? String else {
                return
            }
            result[name] = String(describing: header.value)
        }

        let result = HTTPResponse(
            data: data,
            statusCode: response.statusCode,
            headers: headers,
            url: response.url
        )
        await diagnostics.record(
            .completed(
                .httpRequest,
                category: .api,
                endpoint: tracedRequest.endpoint,
                method: method,
                correlationID: tracedRequest.correlationID,
                statusCode: response.statusCode,
                durationMilliseconds: Self.milliseconds(clock.now - start)
            )
        )
        return result
    }

    private static func milliseconds(
        _ duration: ContinuousClock.Duration
    ) -> Int {
        let components = duration.components
        let seconds = components.seconds * 1_000
        let attoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: seconds + attoseconds)
    }
}
