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
            let authenticationBaseURL =
                try requireTelemetryAuthenticationTestBaseURL()
            guard
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
            let tracer = RemoteTelemetryTracer()
            let appInstallationID = try XCTUnwrap(
                UUID(
                    uuidString: "c12a1d3e-b1ea-44b2-955f-9b7bd5ea21aa"
                )
            )
            let store = CollectorEnrollmentStore()
            let provider = TelemetryTokenProvider(
                attester: DevelopmentTelemetryAttester(keySeed: 12),
                transport: try URLSessionTelemetryAuthenticationTransport(
                    baseURL: authenticationBaseURL,
                    allowsInsecureLoopback: true,
                    installationID: appInstallationID
                ),
                store: store,
                tracer: tracer
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
            let pipeline = try RemoteTelemetryPipeline(
                resource: RemoteTelemetryResource(
                    applicationVersion: "1.2.3",
                    applicationBuild: "68",
                    platform: .iOS,
                    operatingSystemMajorVersion: 26,
                    operatingSystemMinorVersion: 0,
                    operatingSystemPatchVersion: 0,
                    installationID: appInstallationID
                ),
                storageURL: storageURL,
                tracerFacade: tracer,
                downstreamExporter: AuthenticatedOtlpSpanExporter(
                    tokenProvider: provider,
                    client: client,
                    timeout: 10
                )
            )
            addTeardownBlock {
                pipeline.deactivate()
                pipeline.purge()
                await pipeline.shutdown()
            }

            tracer.beginSpan(
                operation: .appLaunch,
                source: .offline,
                retryBucket: .one
            ).end(.succeeded)
            await pipeline.flush(timeout: 10)

            let enrollment = await store.enrollment()
            XCTAssertNotNil(enrollment?.installationID)
            let token = try await provider.currentToken()
            await pipeline.flush(timeout: 10)

            var exportResult = await client.export(
                spans: [span()],
                metadata: [("authorization", "Bearer \(token)")],
                timeout: 10,
                isActive: { true }
            )
            XCTAssertEqual(exportResult, .success)
            exportResult = await client.export(
                spans: [span()],
                metadata: [],
                timeout: 10,
                isActive: { true }
            )
            XCTAssertEqual(exportResult, .unauthenticated)
            exportResult = await client.export(
                spans: [span()],
                metadata: [("authorization", "Bearer invalid.token.value")],
                timeout: 10,
                isActive: { true }
            )
            XCTAssertEqual(exportResult, .unauthenticated)
            let tamperedToken = try tokenWithTamperedSignature(token)
            exportResult = await client.export(
                spans: [span()],
                metadata: [
                    ("authorization", "Bearer \(tamperedToken)")
                ],
                timeout: 10,
                isActive: { true }
            )
            XCTAssertEqual(exportResult, .unauthenticated)
            exportResult = await client.export(
                spans: [oversizedSpan()],
                metadata: [("authorization", "Bearer \(token)")],
                timeout: 10,
                isActive: { true }
            )
            XCTAssertEqual(exportResult, .failure)
            exportResult = await client.export(
                spans: [oversizedSpan()],
                metadata: [],
                timeout: 10,
                isActive: { true }
            )
            XCTAssertEqual(exportResult, .unauthenticated)

            let logClient = HttpRemoteTelemetryOtlpLogClient(
                endpoint: try XCTUnwrap(
                    URL(string: "http://127.0.0.1:\(port)/v1/logs")
                ),
                transport: URLSessionRemoteTelemetryHTTPTransport()
            )
            addTeardownBlock { await logClient.shutdown() }
            var logExportResult = await logClient.export(
                logs: [cloudKitLog()],
                metadata: [("authorization", "Bearer \(token)")],
                timeout: 10,
                isActive: { true }
            )
            XCTAssertEqual(logExportResult, .success)
            logExportResult = await logClient.export(
                logs: [cloudKitLog()],
                metadata: [],
                timeout: 10,
                isActive: { true }
            )
            XCTAssertEqual(logExportResult, .unauthenticated)

            let outageClient = HttpRemoteTelemetryOtlpClient(
                endpoint: try XCTUnwrap(
                    URL(
                        string:
                            "http://127.0.0.1:\(outagePort)/v1/traces"
                    )
                ),
                transport: URLSessionRemoteTelemetryHTTPTransport()
            )
            addTeardownBlock { await outageClient.shutdown() }

            var outageResult = await outageClient.export(
                spans: [span()],
                metadata: [("authorization", "Bearer \(token)")],
                timeout: 10,
                isActive: { true }
            )
            XCTAssertEqual(outageResult, .success)
            let maximumBatch = Array(repeating: span(), count: 128)
            for _ in 0..<32 {
                outageResult = await outageClient.export(
                    spans: maximumBatch,
                    metadata: [("authorization", "Bearer \(token)")],
                    timeout: 10,
                    isActive: { true }
                )
                XCTAssertEqual(outageResult, .success)
            }
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

        private func tokenWithTamperedSignature(_ token: String) throws
            -> String
        {
            let components = token.split(
                separator: ".",
                omittingEmptySubsequences: false
            )
            XCTAssertEqual(components.count, 3)
            guard components.count == 3 else { return token }
            var signature = try XCTUnwrap(
                decodedBase64URL(String(components[2]))
            )
            XCTAssertFalse(signature.isEmpty)
            guard let firstIndex = signature.indices.first else { return token }
            signature[firstIndex] ^= 0x01
            return [
                String(components[0]),
                String(components[1]),
                signature.base64URLEncodedString(),
            ].joined(separator: ".")
        }

        private func decodedBase64URL(_ value: String) -> Data? {
            var normalized =
                value
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            normalized += String(
                repeating: "=",
                count: (4 - normalized.count % 4) % 4
            )
            return Data(base64Encoded: normalized)
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
