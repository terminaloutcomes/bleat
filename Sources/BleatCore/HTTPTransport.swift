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

    public convenience init(
        configuration: URLSessionConfiguration = .ephemeral,
        diagnostics: any DiagnosticRecording = SystemDiagnosticRecorder.shared
    ) {
        self.init(
            configuration: configuration,
            cookieStorage: nil,
            diagnostics: diagnostics
        )
    }

    init(
        configuration: URLSessionConfiguration,
        cookieStorage: HTTPCookieStorage?,
        diagnostics: any DiagnosticRecording = SystemDiagnosticRecorder.shared
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
    }

    public func send(
        _ tracedRequest: TracedHTTPRequest
    ) async throws -> HTTPResponse {
        let request = tracedRequest.request
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
