#if DEBUG
    import Foundation
    @preconcurrency import OpenTelemetryApi
    @testable import OpenTelemetrySdk
    import XCTest

    @testable import BleatCore

    final class AuthenticatedOtlpSpanExporterLiveTests: XCTestCase {
        func testExportsWithRealJWTOverOTLPHTTP() async throws {
            let environment = ProcessInfo.processInfo.environment
            guard
                let authenticationBaseURL = environment[
                    "BLEAT_TELEMETRY_AUTH_BASE_URL"
                ].flatMap(URL.init(string:)),
                let portText = environment[
                    "BLEAT_TELEMETRY_COLLECTOR_TEST_PORT"
                ],
                let port = Int(portText)
            else {
                throw XCTSkip(
                    "Run scripts/test-telemetry.sh to provide the Collector fixture"
                )
            }

            let provider = TelemetryTokenProvider(
                attester: DevelopmentTelemetryAttester(keySeed: 8),
                transport: try URLSessionTelemetryAuthenticationTransport(
                    baseURL: authenticationBaseURL,
                    allowsInsecureLoopback: true
                ),
                store: LiveOtlpEnrollmentStore()
            )
            await provider.setEnabled(true)
            let endpoint = try XCTUnwrap(
                URL(string: "http://127.0.0.1:\(port)/v1/traces")
            )
            let exporter = AuthenticatedOtlpSpanExporter(
                tokenProvider: provider,
                client: HttpRemoteTelemetryOtlpClient(
                    endpoint: endpoint,
                    transport: URLSessionRemoteTelemetryHTTPTransport()
                ),
                timeout: 10
            )

            XCTAssertEqual(
                exporter.export(spans: [span()]),
                SpanExporterResultCode.success
            )
            exporter.shutdown()
        }

        private func span() -> SpanData {
            SpanData(
                traceId: TraceId(
                    fromHexString: "00000000000000000000000000abc123"
                ),
                spanId: SpanId(fromHexString: "0000000000def456"),
                resource: Resource(
                    attributes: ["service.name": .string("bleat")]
                ),
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
    }

    private actor LiveOtlpEnrollmentStore: TelemetryEnrollmentStoring {
        private var value: TelemetryEnrollment?

        func enrollment() -> TelemetryEnrollment? { value }
        func save(_ enrollment: TelemetryEnrollment) { value = enrollment }
        func delete() { value = nil }
    }
#endif
