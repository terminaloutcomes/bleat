#if DEBUG
    import Foundation
    @preconcurrency import OpenTelemetryApi
    @testable import OpenTelemetrySdk
    import XCTest

    @testable import BleatCore

    final class TelemetryRecoveryLiveTests: XCTestCase {
        func testAuthOutageRetainsThenRelaunchDrainsWithoutReenrollment()
            async throws
        {
            let environment = try RecoveryEnvironment.current()
            let storageURL = temporaryStorageURL()
            defer { try? FileManager.default.removeItem(at: storageURL) }
            let store = RecoveryEnrollmentStore()
            let attester = DevelopmentTelemetryAttester(keySeed: 21)
            let originalProvider = try tokenProvider(
                environment: environment,
                attester: attester,
                store: store,
                refreshWindow: 1_000
            )
            await originalProvider.setEnabled(true)
            let originalToken = try await originalProvider.currentToken()
            let storedOriginalEnrollment = await store.enrollment()
            let originalEnrollment = try XCTUnwrap(storedOriginalEnrollment)
            let originalSaveCount = await store.saveCount
            let verificationClient = environment.client()
            defer { verificationClient.shutdown() }
            XCTAssertEqual(
                verificationClient.export(
                    spans: [verificationSpan()],
                    metadata: [("authorization", "Bearer \(originalToken)")],
                    timeout: 5,
                    isActive: { true }
                ),
                .success
            )

            let originalTracer = RemoteTelemetryTracer()
            let originalPipeline = try pipeline(
                storageURL: storageURL,
                tracer: originalTracer,
                provider: originalProvider,
                environment: environment
            )
            defer {
                originalPipeline.deactivate()
                originalPipeline.shutdown()
            }

            try environment.controller.stop(.api)
            defer { try? environment.controller.start(.api) }

            let normalOutcome = completeNormalLibraryRefresh(
                using: originalTracer
            )
            XCTAssertEqual(normalOutcome, .succeeded)
            originalPipeline.flush(timeout: 4)
            XCTAssertFalse(try batchFiles(at: storageURL).isEmpty)
            originalPipeline.deactivate()
            originalPipeline.shutdown()

            try environment.controller.start(.api)
            let relaunchedProvider = try tokenProvider(
                environment: environment,
                attester: attester,
                store: store,
                refreshWindow: 0
            )
            await relaunchedProvider.setEnabled(true)
            let replacementToken = try await relaunchedProvider.currentToken()
            let relaunchedEnrollment = await store.enrollment()
            let relaunchedSaveCount = await store.saveCount
            XCTAssertNotEqual(replacementToken, originalToken)
            XCTAssertEqual(relaunchedEnrollment, originalEnrollment)
            XCTAssertEqual(relaunchedSaveCount, originalSaveCount)

            XCTAssertEqual(
                verificationClient.export(
                    spans: [verificationSpan()],
                    metadata: [("authorization", "Bearer \(replacementToken)")],
                    timeout: 5,
                    isActive: { true }
                ),
                .success
            )
            XCTAssertEqual(
                verificationClient.export(
                    spans: [verificationSpan()],
                    metadata: [("authorization", "Bearer \(originalToken)")],
                    timeout: 5,
                    isActive: { true }
                ),
                .unauthenticated
            )

            let relaunchedPipeline = try pipeline(
                storageURL: storageURL,
                tracer: RemoteTelemetryTracer(),
                provider: relaunchedProvider,
                environment: environment
            )
            defer {
                relaunchedPipeline.deactivate()
                relaunchedPipeline.purge()
                relaunchedPipeline.shutdown()
            }
            relaunchedPipeline.flush(timeout: 10)
            XCTAssertTrue(try batchFiles(at: storageURL).isEmpty)
        }

        func testCollectorOutageRetainsAndDrainsAfterReconnect()
            async throws
        {
            let environment = try RecoveryEnvironment.current()
            let storageURL = temporaryStorageURL()
            defer { try? FileManager.default.removeItem(at: storageURL) }
            let provider = try tokenProvider(
                environment: environment,
                attester: DevelopmentTelemetryAttester(keySeed: 22),
                store: RecoveryEnrollmentStore(),
                refreshWindow: 0
            )
            await provider.setEnabled(true)
            _ = try await provider.currentToken()
            let tracer = RemoteTelemetryTracer()
            let pipeline = try pipeline(
                storageURL: storageURL,
                tracer: tracer,
                provider: provider,
                environment: environment
            )
            defer {
                pipeline.deactivate()
                pipeline.purge()
                pipeline.shutdown()
            }

            try environment.controller.stop(.collector)
            defer { try? environment.controller.start(.collector) }

            let normalOutcome = completeNormalLibraryRefresh(using: tracer)
            XCTAssertEqual(normalOutcome, .succeeded)
            pipeline.flush(timeout: 4)
            XCTAssertFalse(try batchFiles(at: storageURL).isEmpty)

            try environment.controller.start(.collector)
            let drained = try await waitForAutomaticDrain(
                at: storageURL,
                timeout: 15
            )
            XCTAssertTrue(drained)
        }

        private func tokenProvider(
            environment: RecoveryEnvironment,
            attester: DevelopmentTelemetryAttester,
            store: RecoveryEnrollmentStore,
            refreshWindow: TimeInterval
        ) throws -> TelemetryTokenProvider {
            TelemetryTokenProvider(
                attester: attester,
                transport: try URLSessionTelemetryAuthenticationTransport(
                    baseURL: environment.authenticationBaseURL,
                    allowsInsecureLoopback: true
                ),
                store: store,
                refreshWindow: refreshWindow,
                jitterProvider: { 0.5 }
            )
        }

        private func pipeline(
            storageURL: URL,
            tracer: RemoteTelemetryTracer,
            provider: TelemetryTokenProvider,
            environment: RecoveryEnvironment
        ) throws -> RemoteTelemetryPipeline {
            try RemoteTelemetryPipeline(
                resource: RemoteTelemetryResource(
                    applicationVersion: "1.2.3",
                    applicationBuild: "115",
                    platform: .iOS,
                    operatingSystemMajorVersion: 26,
                    operatingSystemMinorVersion: 0,
                    operatingSystemPatchVersion: 0
                ),
                storageURL: storageURL,
                tracerFacade: tracer,
                downstreamExporter: AuthenticatedOtlpSpanExporter(
                    tokenProvider: provider,
                    client: environment.client(),
                    timeout: 2
                )
            )
        }

        private func completeNormalLibraryRefresh(
            using tracer: RemoteTelemetryTracer
        ) -> RemoteTelemetryOutcome {
            let span = tracer.beginSpan(
                operation: .libraryRefresh,
                source: .offline,
                retryBucket: .one
            )
            let outcome = RemoteTelemetryOutcome.succeeded
            span.end(outcome)
            return outcome
        }

        private func verificationSpan() -> SpanData {
            SpanData(
                traceId: TraceId(
                    fromHexString: "00000000000000000000000000115001"
                ),
                spanId: SpanId(fromHexString: "0000000011500001"),
                resource: Resource(
                    attributes: ["service.name": .string("bleat")]
                ),
                instrumentationScope: InstrumentationScopeInfo(
                    name: "app.bleat.remote-telemetry"
                ),
                name: RemoteTelemetryOperation.libraryRefresh.rawValue,
                kind: .internal,
                startTime: Date(timeIntervalSince1970: 1),
                endTime: Date(timeIntervalSince1970: 2),
                hasEnded: true
            )
        }

        private func temporaryStorageURL() -> URL {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "TelemetryRecoveryLiveTests-\(UUID().uuidString)",
                isDirectory: true
            )
        }

        private func batchFiles(at storageURL: URL) throws -> [URL] {
            try FileManager.default.contentsOfDirectory(
                at: storageURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension == "json" }
        }

        private func waitForAutomaticDrain(
            at storageURL: URL,
            timeout: TimeInterval
        ) async throws -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if try batchFiles(at: storageURL).isEmpty { return true }
                try await Task.sleep(for: .milliseconds(100))
            }
            return try batchFiles(at: storageURL).isEmpty
        }
    }

    private struct RecoveryEnvironment: Sendable {
        let authenticationBaseURL: URL
        let collectorEndpoint: URL
        let controller: TelemetryServiceController

        static func current() throws -> Self {
            let values = ProcessInfo.processInfo.environment
            guard
                let authenticationBaseURL = values[
                    "BLEAT_TELEMETRY_AUTH_BASE_URL"
                ].flatMap(URL.init(string:)),
                let collectorPort = values[
                    "BLEAT_TELEMETRY_COLLECTOR_TEST_PORT"
                ].flatMap(Int.init),
                let controlCommand = values[
                    "BLEAT_TELEMETRY_CONTROL_COMMAND"
                ].map(URL.init(fileURLWithPath:)),
                let projectName = values[
                    "BLEAT_TELEMETRY_COMPOSE_PROJECT"
                ]
            else {
                throw XCTSkip(
                    "Run scripts/test-telemetry.sh to provide recovery controls"
                )
            }
            return Self(
                authenticationBaseURL: authenticationBaseURL,
                collectorEndpoint: try XCTUnwrap(
                    URL(
                        string:
                            "http://127.0.0.1:\(collectorPort)/v1/traces"
                    )
                ),
                controller: TelemetryServiceController(
                    command: controlCommand,
                    projectName: projectName
                )
            )
        }

        func client() -> HttpRemoteTelemetryOtlpClient {
            HttpRemoteTelemetryOtlpClient(
                endpoint: collectorEndpoint,
                transport: URLSessionRemoteTelemetryHTTPTransport()
            )
        }
    }

    private enum TelemetryDisposableService: String, Sendable {
        case api
        case collector = "telemetry-collector"
    }

    private enum TelemetryServiceControlError: Error, Equatable, Sendable {
        case commandFailed(Int32)
    }

    private struct TelemetryServiceController: Sendable {
        let command: URL
        let projectName: String

        func stop(_ service: TelemetryDisposableService) throws {
            try run(action: "stop", service: service)
        }

        func start(_ service: TelemetryDisposableService) throws {
            try run(action: "start", service: service)
        }

        private func run(
            action: String,
            service: TelemetryDisposableService
        ) throws {
            let process = Process()
            process.executableURL = command
            process.arguments = [projectName, action, service.rawValue]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw TelemetryServiceControlError.commandFailed(
                    process.terminationStatus
                )
            }
        }
    }

    private actor RecoveryEnrollmentStore: TelemetryEnrollmentStoring {
        private var value: TelemetryEnrollment?
        private(set) var saveCount = 0

        func enrollment() -> TelemetryEnrollment? { value }

        func save(_ enrollment: TelemetryEnrollment) {
            value = enrollment
            saveCount += 1
        }

        func delete() {
            value = nil
        }
    }
#endif
