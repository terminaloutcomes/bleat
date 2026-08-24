import Foundation
import XCTest

@testable import BleatCore

final class TelemetryAuthenticationTransportTests: XCTestCase {
    func testConfigurationRequiresHTTPSExceptExplicitLoopbackDevelopment()
        throws
    {
        XCTAssertThrowsError(
            try URLSessionTelemetryAuthenticationTransport(
                baseURL: XCTUnwrap(URL(string: "http://auth.example")),
                allowsInsecureLoopback: true
            )
        )
        XCTAssertNoThrow(
            try URLSessionTelemetryAuthenticationTransport(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:8080")),
                allowsInsecureLoopback: true
            )
        )
        XCTAssertThrowsError(
            try URLSessionTelemetryAuthenticationTransport(
                baseURL: XCTUnwrap(URL(string: "http://127.0.0.1:8080"))
            )
        )
    }

    func testVersionedContractsPreserveConfiguredPathPrefix() async throws {
        let challengeID = try XCTUnwrap(
            UUID(uuidString: "0cc304d7-9d60-45cf-84e0-5959d433daf0")
        )
        let installationID = try XCTUnwrap(
            UUID(uuidString: "fc6f46f0-d92c-4d37-9137-851070df369d")
        )
        let recorder = TelemetryURLProtocolRecorder()
        TelemetryURLProtocolStub.setHandler { request in
            let body: String
            switch request.url?.path {
            case "/auth/v1/attestation/challenge",
                "/auth/v1/token/challenge":
                body = """
                    {"challenge_id":"\(challengeID.uuidString.lowercased())","challenge":"opaque-challenge","expires_at":"2033-05-18T03:34:00Z"}
                    """
            case "/auth/v1/attestation/enroll":
                body = """
                    {"installation_id":"\(installationID.uuidString.lowercased())"}
                    """
            case "/auth/v1/token":
                body = """
                    {"access_token":"header.payload.signature","token_type":"Bearer","expires_at":"2033-05-18T03:42:00Z"}
                    """
            default:
                throw TelemetryURLProtocolError.unexpectedRoute
            }
            recorder.append(request.materializingBody())
            let status = request.url?.path.hasSuffix("/token") == true ? 200 : 201
            return (
                HTTPURLResponse(
                    url: request.url ?? URL(fileURLWithPath: "/"),
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        defer { TelemetryURLProtocolStub.setHandler(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryURLProtocolStub.self]
        let transport = try URLSessionTelemetryAuthenticationTransport(
            baseURL: XCTUnwrap(URL(string: "https://auth.example/auth")),
            installationID: installationID,
            configuration: configuration
        )

        let attestationChallenge = try await transport.attestationChallenge()
        let enrolledID = try await transport.enroll(
            challenge: attestationChallenge,
            keyID: "opaque-key-id",
            attestationObject: Data([1, 2, 3])
        )
        let tokenChallenge = try await transport.tokenChallenge(
            installationID: enrolledID
        )
        let token = try await transport.token(
            installationID: enrolledID,
            challenge: tokenChallenge,
            assertionObject: Data([4, 5, 6])
        )

        XCTAssertEqual(enrolledID, installationID)
        XCTAssertEqual(token.value, "header.payload.signature")
        let requests = recorder.requests
        XCTAssertEqual(
            requests.compactMap(\.url?.path),
            [
                "/auth/v1/attestation/challenge",
                "/auth/v1/attestation/enroll",
                "/auth/v1/token/challenge",
                "/auth/v1/token",
            ]
        )
        XCTAssertTrue(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "baggage")
                    == "service.instance.id=\(installationID.uuidString.lowercased())"
            }
        )
        let enrollmentJSON = try XCTUnwrap(
            requests[1].httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        )
        XCTAssertEqual(enrollmentJSON["key_id"] as? String, "opaque-key-id")
        XCTAssertEqual(enrollmentJSON["attestation_object"] as? String, "AQID")
        XCTAssertEqual(
            enrollmentJSON["challenge_id"] as? String,
            challengeID.uuidString.uppercased()
        )
        let tokenJSON = try XCTUnwrap(
            requests[3].httpBody.flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
        )
        XCTAssertEqual(tokenJSON["assertion_object"] as? String, "BAUG")
        XCTAssertEqual(
            tokenJSON["installation_id"] as? String,
            installationID.uuidString.uppercased()
        )
    }

    func testAuthenticationRejectionMapsWithoutResponseBodyDisclosure()
        async throws
    {
        TelemetryURLProtocolStub.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url ?? URL(fileURLWithPath: "/"),
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                Data(
                    #"{"error":{"code":"authentication_rejected","message":"sensitive server detail"}}"#.utf8
                )
            )
        }
        defer { TelemetryURLProtocolStub.setHandler(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TelemetryURLProtocolStub.self]
        let transport = try URLSessionTelemetryAuthenticationTransport(
            baseURL: XCTUnwrap(URL(string: "https://auth.example")),
            configuration: configuration
        )

        do {
            _ = try await transport.attestationChallenge()
            XCTFail("rejected request unexpectedly succeeded")
        } catch let error {
            XCTAssertEqual(error, .authenticationRejected)
            XCTAssertFalse(String(describing: error).contains("sensitive"))
        }
    }
}

private final class TelemetryURLProtocolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { values } }
    func append(_ request: URLRequest) { lock.withLock { values.append(request) } }
}

private final class TelemetryURLProtocolStub: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: Handler?) {
        lock.withLock { self.handler = handler }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.handler }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: TelemetryURLProtocolError.missingHandler)
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum TelemetryURLProtocolError: Error {
    case missingHandler
    case unexpectedRoute
}

private extension URLRequest {
    func materializingBody() -> URLRequest {
        guard httpBody == nil, let stream = httpBodyStream else { return self }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        var copy = self
        copy.httpBodyStream = nil
        copy.httpBody = body
        return copy
    }
}
