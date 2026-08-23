#if DEBUG
    import Foundation
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
                    "Run scripts/test-telemetry.sh to provide the Collector fixture"
                )
            }
            let store = CollectorEnrollmentStore()
            let provider = TelemetryTokenProvider(
                attester: DevelopmentTelemetryAttester(keySeed: 12),
                transport: try URLSessionTelemetryAuthenticationTransport(
                    baseURL: authenticationBaseURL,
                    allowsInsecureLoopback: true
                ),
                store: store
            )
            await provider.setEnabled(true)

            let client = HttpRemoteTelemetryOtlpClient(
                endpoint: try XCTUnwrap(
                    URL(string: "http://127.0.0.1:\(port)/v1/traces")
                ),
                transport: URLSessionRemoteTelemetryHTTPTransport()
            )
            let storageURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "OpenTelemetryCollectorLiveTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: storageURL) }
            let tracer = RemoteTelemetryTracer()
            let pipeline = try RemoteTelemetryPipeline(
                resource: RemoteTelemetryResource(
                    applicationVersion: "1.2.3",
                    applicationBuild: "68",
                    platform: .iOS,
                    operatingSystemMajorVersion: 26,
                    operatingSystemMinorVersion: 0,
                    operatingSystemPatchVersion: 0
                ),
                storageURL: storageURL,
                tracerFacade: tracer,
                downstreamExporter: AuthenticatedOtlpSpanExporter(
                    tokenProvider: provider,
                    client: client,
                    timeout: 10
                )
            )
            defer {
                pipeline.deactivate()
                pipeline.purge()
                pipeline.shutdown()
            }

            tracer.beginSpan(
                operation: .appLaunch,
                source: .offline,
                retryBucket: .one
            ).end(.succeeded)
            pipeline.flush(timeout: 10)

            let enrollment = await store.enrollment()
            XCTAssertNotNil(enrollment?.installationID)
            let token = try await provider.currentToken()

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

            let logClient = HttpRemoteTelemetryOtlpLogClient(
                endpoint: try XCTUnwrap(
                    URL(string: "http://127.0.0.1:\(port)/v1/logs")
                ),
                transport: URLSessionRemoteTelemetryHTTPTransport()
            )
            defer { logClient.shutdown() }
            XCTAssertEqual(
                logClient.export(
                    logs: [cloudKitLog()],
                    metadata: [("authorization", "Bearer \(token)")],
                    timeout: 10,
                    isActive: { true }
                ),
                .success
            )
            XCTAssertEqual(
                logClient.export(
                    logs: [cloudKitLog()],
                    metadata: [],
                    timeout: 10,
                    isActive: { true }
                ),
                .unauthenticated
            )

            let outageClient = HttpRemoteTelemetryOtlpClient(
                endpoint: try XCTUnwrap(
                    URL(
                        string:
                            "http://127.0.0.1:\(outagePort)/v1/traces"
                    )
                ),
                transport: URLSessionRemoteTelemetryHTTPTransport()
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
            span(
                extraAttribute: String(repeating: "x", count: 2 * 1_024 * 1_024)
            )
        }

        private func cloudKitLog() -> ReadableLogRecord {
            ReadableLogRecord(
                resource: Resource(
                    attributes: ["service.name": .string("bleat")]
                ),
                instrumentationScopeInfo: InstrumentationScopeInfo(
                    name: "app.bleat.remote-telemetry"
                ),
                timestamp: Date(timeIntervalSince1970: 2),
                severity: .error,
                body: .string("CloudKit synchronization lifecycle"),
                attributes: [
                    "bleat.subsystem": .string("synchronization"),
                    "bleat.cloudkit.operation": .string("synchronize"),
                    "bleat.cloudkit.code": .string("network_failure"),
                    "bleat.outcome": .string("failed"),
                ],
                eventName: "bleat.cloudkit.sync.failed"
            )
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
