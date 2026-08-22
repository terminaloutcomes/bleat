#if DEBUG
    import Foundation
    @preconcurrency import GRPC
    @preconcurrency import NIO
    @preconcurrency import NIOSSL
    @preconcurrency import OpenTelemetryApi
    @preconcurrency import OpenTelemetryProtocolExporterCommon
    @preconcurrency import OpenTelemetryProtocolExporterGrpc
    @testable import OpenTelemetrySdk
    import XCTest

    @testable import BleatCore

    final class AuthenticatedOtlpSpanExporterLiveTests: XCTestCase {
        func testRefreshesRealJWTAgainstTLSGrpcEndpointOnOneChannel()
            async throws
        {
            let environment = ProcessInfo.processInfo.environment
            guard
                let authenticationBaseURL = environment[
                    "BLEAT_TELEMETRY_AUTH_BASE_URL"
                ].flatMap(URL.init(string:)),
                let caPath = environment["BLEAT_TELEMETRY_TLS_CA_CERT"],
                let certificatePath = environment[
                    "BLEAT_TELEMETRY_TLS_CERT"
                ],
                let intermediateCertificatePath = environment[
                    "BLEAT_TELEMETRY_TLS_INTERMEDIATE_CERT"
                ],
                let keyPath = environment["BLEAT_TELEMETRY_TLS_KEY"]
            else {
                throw XCTSkip(
                    "Run scripts/test-bleat-api.sh to provide TLS and token fixtures"
                )
            }

            let collector = RecordingTLSCollector()
            let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let certificateChain =
                try NIOSSLCertificate.fromPEMFile(certificatePath)
                + NIOSSLCertificate.fromPEMFile(
                    intermediateCertificatePath
                )
            let privateKey = try NIOSSLPrivateKey(
                file: keyPath,
                format: .pem
            )
            let server = try await Server.usingTLSBackedByNIOSSL(
                on: serverGroup,
                certificateChain: certificateChain,
                privateKey: privateKey
            )
            .withDebugChannelInitializer { channel in
                collector.recordConnection()
                return channel.eventLoop.makeSucceededFuture(())
            }
            .withServiceProviders([collector])
            .bind(host: "127.0.0.1", port: 0)
            .get()
            defer {
                server.close().whenComplete { _ in
                    serverGroup.shutdownGracefully { _ in }
                }
            }
            let port = try XCTUnwrap(server.channel.localAddress?.port)

            let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let trustRoots = try NIOSSLCertificate.fromPEMFile(caPath)
            let channel = ClientConnection.usingTLSBackedByNIOSSL(
                on: clientGroup
            )
            .withTLS(trustRoots: .certificates(trustRoots))
            .withTLS(serverHostnameOverride: "localhost")
            .connect(host: "127.0.0.1", port: port)
            let client = GrpcRemoteTelemetryOtlpClient(
                channel: channel,
                closeTransport: {
                    channel.close().whenComplete { _ in
                        clientGroup.shutdownGracefully { _ in }
                    }
                }
            )

            let provider = TelemetryTokenProvider(
                attester: DevelopmentTelemetryAttester(keySeed: 8),
                transport: try URLSessionTelemetryAuthenticationTransport(
                    baseURL: authenticationBaseURL,
                    allowsInsecureLoopback: true
                ),
                store: LiveOtlpEnrollmentStore()
            )
            await provider.setEnabled(true)
            _ = try await provider.currentToken()
            let exporter = AuthenticatedOtlpSpanExporter(
                tokenProvider: provider,
                client: client,
                timeout: 10
            )

            XCTAssertEqual(
                exporter.export(spans: [span()]),
                SpanExporterResultCode.success
            )
            exporter.shutdown()

            let snapshot = collector.snapshot
            XCTAssertEqual(snapshot.requestCount, 2)
            XCTAssertEqual(snapshot.connectionCount, 1)
            XCTAssertEqual(snapshot.authorizationCounts, [1, 1])
            XCTAssertTrue(snapshot.everyAuthorizationIsBearerJWT)
            XCTAssertGreaterThan(snapshot.resourceSpanCount, 0)
        }

        private func span() -> SpanData {
            SpanData(
                traceId: TraceId(
                    fromHexString:
                        "00000000000000000000000000abc123"
                ),
                spanId: SpanId(fromHexString: "0000000000def456"),
                resource: Resource(
                    attributes: [
                        "service.name": .string("bleat")
                    ]
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

        func save(_ enrollment: TelemetryEnrollment) {
            value = enrollment
        }

        func delete() {
            value = nil
        }
    }

    private final class RecordingTLSCollector:
        Opentelemetry_Proto_Collector_Trace_V1_TraceServiceProvider,
        @unchecked Sendable
    {
        typealias ExportRequest =
            Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest
        typealias ExportResponse =
            Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceResponse

        struct Snapshot {
            let requestCount: Int
            let connectionCount: Int
            let authorizationCounts: [Int]
            let everyAuthorizationIsBearerJWT: Bool
            let resourceSpanCount: Int
        }

        private let lock = NSLock()
        private var authorizations: [[String]] = []
        private var connections = 0
        private var resourceSpans = 0
        var interceptors:
            Opentelemetry_Proto_Collector_Trace_V1_TraceServiceServerInterceptorFactoryProtocol?

        var snapshot: Snapshot {
            lock.withLock {
                let flattened = authorizations.flatMap { $0 }
                return Snapshot(
                    requestCount: authorizations.count,
                    connectionCount: connections,
                    authorizationCounts: authorizations.map(\.count),
                    everyAuthorizationIsBearerJWT: flattened.allSatisfy {
                        value in
                        guard value.hasPrefix("Bearer ") else { return false }
                        return value.dropFirst("Bearer ".count)
                            .split(separator: ".").count == 3
                    },
                    resourceSpanCount: resourceSpans
                )
            }
        }

        func recordConnection() {
            lock.withLock { connections += 1 }
        }

        func export(
            request: ExportRequest,
            context: StatusOnlyCallContext
        ) -> EventLoopFuture<ExportResponse> {
            let values = Array(
                context.headers.values(forHeader: "authorization")
            ).map(String.init)
            let shouldReject = lock.withLock {
                authorizations.append(values)
                resourceSpans += request.resourceSpans.count
                return authorizations.count == 1
            }
            if shouldReject {
                return context.eventLoop.makeFailedFuture(
                    GRPCStatus(code: .unauthenticated)
                )
            }
            return context.eventLoop.makeSucceededFuture(.init())
        }
    }
#endif
