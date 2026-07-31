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

    init(
        url: URL,
        primary: NormalizedServerURL?,
        isLocal: Bool
    ) {
        self.url = url
        self.primary = primary
        self.isLocal = isLocal
    }
}

public actor ServerEndpointRouter {
    private struct Route: Sendable {
        let primary: NormalizedServerURL
        let local: NormalizedServerURL
    }

    private var routes: [NormalizedServerURL: Route] = [:]
    private var localFailures: [NormalizedServerURL: Date] = [:]

    public init() {}

    public func configure(
        primary: NormalizedServerURL,
        local: NormalizedServerURL?
    ) {
        guard let local, local != primary else {
            routes[primary] = nil
            localFailures[primary] = nil
            return
        }
        routes[primary] = Route(primary: primary, local: local)
        localFailures[primary] = nil
    }

    public func candidates(for url: URL) -> [ServerEndpointCandidate] {
        for route in routes.values {
            guard let localURL = replacingBase(
                in: url,
                from: route.primary,
                with: route.local
            ) else {
                continue
            }
            if let failedUntil = localFailures[route.primary],
               failedUntil > Date()
            {
                return [ServerEndpointCandidate(
                    url: url,
                    primary: route.primary,
                    isLocal: false
                )]
            }
            return [
                ServerEndpointCandidate(
                    url: localURL,
                    primary: route.primary,
                    isLocal: true
                ),
                ServerEndpointCandidate(
                    url: url,
                    primary: route.primary,
                    isLocal: false
                ),
            ]
        }
        return [ServerEndpointCandidate(
            url: url,
            primary: nil,
            isLocal: false
        )]
    }

    public func preferredURL(for url: URL) -> URL {
        candidates(for: url).first?.url ?? url
    }

    public func markLocalUnavailable(
        for primary: NormalizedServerURL,
        duration: TimeInterval = 30
    ) {
        localFailures[primary] = Date().addingTimeInterval(duration)
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

    public convenience init(
        configuration: URLSessionConfiguration = .ephemeral,
        diagnostics: any DiagnosticRecording = SystemDiagnosticRecorder.shared,
        endpointRouter: ServerEndpointRouter? = nil
    ) {
        self.init(
            configuration: configuration,
            cookieStorage: nil,
            diagnostics: diagnostics,
            endpointRouter: endpointRouter
        )
    }

    init(
        configuration: URLSessionConfiguration,
        cookieStorage: HTTPCookieStorage?,
        diagnostics: any DiagnosticRecording = SystemDiagnosticRecorder.shared,
        endpointRouter: ServerEndpointRouter? = nil
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
    }

    public func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
        let candidates: [ServerEndpointCandidate]
        if let endpointRouter, let url = request.url {
            candidates = await endpointRouter.candidates(for: url)
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
                return try await send(
                    tracedRequest,
                    requestURL: candidate.url
                )
            } catch {
                if Task.isCancelled {
                    throw error
                }
                lastError = error
                if candidate.isLocal, let primary = candidate.primary {
                    await endpointRouter?.markLocalUnavailable(for: primary)
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
