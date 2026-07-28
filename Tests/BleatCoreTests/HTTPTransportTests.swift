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
            URL(string: "https://example.net/auth/openid")
        )
        let callbackURL = try XCTUnwrap(
            URL(string: "https://example.net/auth/openid/callback")
        )

        let beginResponse = try await transport.send(
            URLRequest(url: beginURL)
        )
        XCTAssertEqual(beginResponse.statusCode, 302)
        XCTAssertEqual(
            beginResponse.header(named: "Location"),
            "https://identity.example/authorize?opaque=1"
        )
        XCTAssertEqual(transport.cookieCount, 2)

        let callbackResponse = try await transport.send(
            URLRequest(url: callbackURL)
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
