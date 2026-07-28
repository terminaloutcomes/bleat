import Foundation
import XCTest

@testable import BleatCore

final class HTTPTransportTests: XCTestCase {
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
        let url = try XCTUnwrap(URL(string: "https://example.net/status"))

        let response = try await transport.send(URLRequest(url: url))

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
        let url = try XCTUnwrap(URL(string: "https://example.net/status"))

        await XCTAssertThrowsErrorAsync(
            try await transport.send(URLRequest(url: url))
        ) { error in
            XCTAssertEqual(
                error as? HTTPTransportError,
                .nonHTTPResponse
            )
        }
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
