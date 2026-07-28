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

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
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

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15

        session = URLSession(
            configuration: configuration,
            delegate: RedirectBlockingDelegate(),
            delegateQueue: nil
        )
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
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

        return HTTPResponse(
            data: data,
            statusCode: response.statusCode,
            headers: headers,
            url: response.url
        )
    }
}
