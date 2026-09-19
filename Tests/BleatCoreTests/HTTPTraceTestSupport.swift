import Foundation

@testable import BleatCore

final class HTTPTraceRecorder: RemoteTelemetryTracing, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [RemoteTelemetryHTTPCall] = []
    var recordedCalls: [RemoteTelemetryHTTPCall] { lock.withLock { calls } }
    func beginSpan(
        operation: RemoteTelemetryOperation, source: RemoteTelemetrySource?,
        retryBucket: RemoteTelemetryRetryBucket
    ) -> RemoteTelemetrySpan {
        RemoteTelemetrySpan(
            completionAction: { [weak self] _, _, call in
                guard let self, let call else { return }
                lock.withLock { calls.append(call) }
            }, contextProvider: { nil })
    }
}

final class HTTPTraceURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest
    { request }
    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-Test-Scenario")
        if scenario == "cancelled" || scenario == "transport"
            || request.url?.host == "local.example"
        {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(
                    scenario == "cancelled" ? .cancelled : .cannotConnectToHost)
            )
            return
        }
        guard let url = request.url else { return }
        let response: URLResponse
        if scenario == "non-http" {
            response = URLResponse(
                url: url, mimeType: nil, expectedContentLength: 0,
                textEncodingName: nil)
        } else if let http = HTTPURLResponse(
            url: url, statusCode: scenario == "503" ? 503 : 200,
            httpVersion: "HTTP/1.1", headerFields: nil)
        {
            response = http
        } else {
            return
        }
        client?.urlProtocol(
            self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
