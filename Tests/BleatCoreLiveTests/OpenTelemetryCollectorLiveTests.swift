#if DEBUG
    import Foundation
    @preconcurrency import GRPC
    @preconcurrency import NIO
    @preconcurrency import OpenTelemetryApi
    @testable import OpenTelemetrySdk
    import XCTest

    @testable import BleatCore

    final class OpenTelemetryCollectorLiveTests: XCTestCase {
        func testStockCollectorValidatesBleatTokenAndBoundsIngress()
            async throws
        {
            let environment = ProcessInfo.processInfo.environment
            guard
                let authenticationBaseURL = environment[
                    "BLEAT_TELEMETRY_AUTH_BASE_URL"
                ].flatMap(URL.init(string:)),
                let portText = environment[
                    "BLEAT_TELEMETRY_COLLECTOR_TEST_PORT"
                ],
                let port = Int(portText),
                let outagePortText = environment[
                    "BLEAT_TELEMETRY_OUTAGE_COLLECTOR_TEST_PORT"
                ],
                let outagePort = Int(outagePortText)
            else {
                throw XCTSkip(
                    "Run scripts/test-bleat-api.sh to provide the Collector fixture"
                )
            }
            let provider = TelemetryTokenProvider(
                attester: DevelopmentTelemetryAttester(keySeed: 12),
                transport: try URLSessionTelemetryAuthenticationTransport(
                    baseURL: authenticationBaseURL,
                    allowsInsecureLoopback: true
                ),
                store: CollectorEnrollmentStore()
            )
            await provider.setEnabled(true)
            let token = try await provider.currentToken()

            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let channel = ClientConnection.insecure(group: group)
                .connect(host: "127.0.0.1", port: port)
            let client = GrpcRemoteTelemetryOtlpClient(
                channel: channel,
                closeTransport: {
                    channel.close().whenComplete { _ in
                        group.shutdownGracefully { _ in }
                    }
                }
            )
            defer { client.shutdown() }

            XCTAssertEqual(
                client.export(
                    spans: [span()],
                    metadata: [("authorization", "Bearer \(token)")],
                    timeout: 10,
                    isActive: { true }
                ),
                .success
            )
            XCTAssertEqual(
                client.export(
                    spans: [span()],
                    metadata: [],
                    timeout: 10,
                    isActive: { true }
                ),
                .unauthenticated
            )
            XCTAssertEqual(
                client.export(
                    spans: [span()],
                    metadata: [("authorization", "Bearer invalid.token.value")],
                    timeout: 10,
                    isActive: { true }
                ),
                .unauthenticated
            )
            XCTAssertEqual(
                client.export(
                    spans: [oversizedSpan()],
                    metadata: [("authorization", "Bearer \(token)")],
                    timeout: 10,
                    isActive: { true }
                ),
                .failure
            )

            let outageGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let outageChannel = ClientConnection.insecure(group: outageGroup)
                .connect(host: "127.0.0.1", port: outagePort)
            let outageClient = GrpcRemoteTelemetryOtlpClient(
                channel: outageChannel,
                closeTransport: {
                    outageChannel.close().whenComplete { _ in
                        outageGroup.shutdownGracefully { _ in }
                    }
                }
            )
            defer { outageClient.shutdown() }

            XCTAssertEqual(
                outageClient.export(
                    spans: [span()],
                    metadata: [("authorization", "Bearer \(token)")],
                    timeout: 10,
                    isActive: { true }
                ),
                .success
            )
        }

        private func span(extraAttribute: String? = nil) -> SpanData {
            var attributes: [String: AttributeValue] = [
                "service.name": .string("bleat")
            ]
            if let extraAttribute {
                attributes["test.oversized"] = .string(extraAttribute)
            }
            return SpanData(
                traceId: TraceId(
                    fromHexString: "00000000000000000000000000abc999"
                ),
                spanId: SpanId(fromHexString: "0000000000def999"),
                resource: Resource(attributes: attributes),
                instrumentationScope: InstrumentationScopeInfo(
                    name: "app.bleat.remote-telemetry"
                ),
                name: RemoteTelemetryOperation.appLaunch.rawValue,
                kind: .internal,
                startTime: Date(timeIntervalSince1970: 1),
                endTime: Date(timeIntervalSince1970: 2),
                hasEnded: true
            )
        }

        private func oversizedSpan() -> SpanData {
            span(extraAttribute: String(repeating: "x", count: 2 * 1_024 * 1_024))
        }
    }

    private actor CollectorEnrollmentStore: TelemetryEnrollmentStoring {
        private var value: TelemetryEnrollment?

        func enrollment() -> TelemetryEnrollment? { value }

        func save(_ enrollment: TelemetryEnrollment) {
            value = enrollment
        }

        func delete() {
            value = nil
        }
    }
#endif
