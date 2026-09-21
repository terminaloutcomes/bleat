import CloudKit
@preconcurrency import OpenTelemetrySdk
import Testing

@testable import BleatCore

@Suite(.serialized)
final class RemoteTelemetryTests {
    @Test
    func testHTTPCallsExportOneRedactedSpanEventForEveryEndpointAndOutcome()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = RecordingSpanExporter()
        let tracer = RemoteTelemetryTracer()
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1.2.3", build: "45"),
            storageURL: directory,
            tracerFacade: tracer, downstreamExporter: exporter)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPTraceURLProtocol.self]
        let transport = URLSessionHTTPTransport(
            configuration: configuration, tracer: tracer)
        let outcomes: [(String, RemoteTelemetryHTTPResult)] = [
            ("200", .response(statusCode: 200)),
            ("503", .response(statusCode: 503)),
            ("transport", .urlError(.cannotConnectToHost)),
            ("cancelled", .cancelled),
            ("non-http", .nonHTTPResponse),
        ]
        for endpoint in DiagnosticEndpoint.allCases {
            for (scenario, _) in outcomes {
                var request = URLRequest(
                    url: try #require(
                        URL(
                            string:
                                "https://private.example/prefix/api/items/private-book?token=private-token"
                        )))
                request.httpMethod = "GET"
                request.setValue(
                    scenario, forHTTPHeaderField: "X-Test-Scenario")
                request.setValue(
                    "Bearer private-token", forHTTPHeaderField: "Authorization")
                _ = try? await transport.send(
                    TracedHTTPRequest(request: request, endpoint: endpoint))
            }
        }
        await pipeline.flush(timeout: 5)
        let spans = exporter.recordedSpans
        #expect(
            spans.count == DiagnosticEndpoint.allCases.count * outcomes.count)
        for endpoint in DiagnosticEndpoint.allCases {
            let matching = spans.filter {
                $0.attributes["bleat.http.endpoint"]?.description
                    == endpoint.rawValue
            }
            #expect(matching.count == outcomes.count)
            for (_, result) in outcomes {
                let expected = RemoteTelemetryHTTPCall(
                    endpoint: .audiobookshelf(endpoint), method: .get,
                    result: result)
                #expect(
                    matching.filter { span in
                        expected.attributes.allSatisfy {
                            span.attributes[$0.key]?.description == $0.value
                        }
                    }.count == 1)
            }
        }
        for span in spans {
            #expect(span.name == "bleat.http.request")
            #expect(span.kind == .client)
            #expect(span.events.count == 1)
            #expect(span.events.first?.name == "bleat.http.completed")
            #expect(
                span.events.first?.attributes["bleat.http.endpoint"]
                    == span.attributes["bleat.http.endpoint"])
            let encoded =
                String(describing: span.attributes)
                + String(describing: span.events)
            for secret in [
                "private.example", "private-book", "private-token",
                "Authorization", "prefix",
            ] {
                #expect(!(encoded.contains(secret)))
            }
        }
        pipeline.deactivate()
        pipeline.purge()
    }

    @Test

    func testHTTPFallbackRecordsBothAttemptsWithoutLosingEndpoint() async throws
    {
        let router = ServerEndpointRouter()
        let primary = try NormalizedServerURL("https://primary.example/prefix")
        await router.configure(
            primary: primary,
            local: try NormalizedServerURL("https://local.example/prefix"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPTraceURLProtocol.self]
        let recorder = HTTPTraceRecorder()
        let transport = URLSessionHTTPTransport(
            configuration: configuration, endpointRouter: router,
            tracer: recorder)
        _ = try await transport.send(
            TracedHTTPRequest(
                request: URLRequest(
                    url: try #require(
                        URL(
                            string:
                                "https://primary.example/prefix/api/me/progress/private-id"
                        ))), endpoint: .progress))
        #expect(
            recorder.recordedCalls == [
                RemoteTelemetryHTTPCall(
                    endpoint: .audiobookshelf(.progress), method: .get,
                    result: .urlError(.cannotConnectToHost)),
                RemoteTelemetryHTTPCall(
                    endpoint: .audiobookshelf(.progress), method: .get,
                    result: .response(statusCode: 200)),
            ])
    }

    @Test

    func testBufferedHTTPEventIsIdempotentAndPreservesTransactionTimes()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = RecordingSpanExporter()
        let tracer = RemoteTelemetryTracer()
        tracer.prepareForActivation()
        let call = RemoteTelemetryHTTPCall(
            endpoint: .audiobookshelf(.downloadFile), method: .get,
            result: .response(statusCode: 206))
        let start = Date().addingTimeInterval(-2)
        let end = start.addingTimeInterval(1)
        tracer.recordHTTPCall(call, startedAt: start, endedAt: end)
        let span = tracer.beginSpan(operation: .httpRequest)
        span.endHTTPCall(call)
        span.endHTTPCall(call)
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory, tracerFacade: tracer,
            downstreamExporter: exporter)
        await pipeline.flush(timeout: 2)
        let spans = exporter.recordedSpans
        #expect(spans.count == 2)
        #expect(spans.allSatisfy { $0.events.count == 1 })
        let timed = try #require(
            spans.first { abs($0.startTime.timeIntervalSince(start)) < 0.001 })
        #expect(abs((timed.endTime.timeIntervalSince(end)) - (0)) <= 0.001)
        pipeline.deactivate()
        tracer.recordHTTPCall(call, startedAt: start, endedAt: end)
        await pipeline.flush(timeout: 2)
        #expect(exporter.recordedSpans.count == 2)
        pipeline.purge()
    }

    @Test

    func testReviewedOperationsEncodeOnlyReviewedNamesAndAttributes() {
        let allowedNames = Set(
            RemoteTelemetryOperation.allCases.map(\.rawValue))
        #expect(
            allowedNames == [
                "bleat.http.request",
                "bleat.app.launch",
                "bleat.account.connection",
                "bleat.live_update.connection",
                "bleat.library.refresh",
                "bleat.playback.prepare",
                "bleat.playback.start",
                "bleat.download.transfer",
                "bleat.playback.progress_sync",
                "bleat.transcription.run",
                "bleat.transcription.chapter",
                "bleat.cloudkit.sync",
                "bleat.telemetry.authentication",
                "bleat.telemetry.challenge",
                "bleat.telemetry.enrolment",
                "bleat.telemetry.token",
            ])

        for operation in RemoteTelemetryOperation.allCases {
            let encoded = RemoteTelemetrySpanDescriptor(
                operation: operation,
                outcome: .failed(.transport),
                source: .offline,
                retryBucket: .threeOrMore
            ).encodedSpan
            #expect(allowedNames.contains(encoded.name))
            #expect(
                Set(encoded.attributes.keys) == [
                    "bleat.subsystem",
                    "bleat.outcome",
                    "bleat.failure.category",
                    "bleat.source",
                    "bleat.retry.bucket",
                ])
            #expect(encoded.attributes["bleat.outcome"] == "failed")
            #expect(encoded.attributes["bleat.failure.category"] == "transport")
        }
    }

    @Test

    func testBufferedTelemetryAuthenticationRequestSpansShareParentTrace()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = RecordingSpanExporter()
        let tracer = RemoteTelemetryTracer()
        tracer.prepareForActivation()

        let authentication = tracer.beginSpan(
            operation: .telemetryAuthentication
        )
        for operation in [
            RemoteTelemetryOperation.telemetryChallenge,
            .telemetryEnrolment,
            .telemetryToken,
        ] {
            tracer.beginChildSpan(
                operation: operation,
                parent: authentication
            ).end(.succeeded)
        }
        authentication.end(.succeeded)

        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: exporter
        )
        await pipeline.flush(timeout: 2)

        let spans = exporter.recordedSpans
        #expect(spans.count == 4)
        let parent = try #require(
            spans.first { $0.name == "bleat.telemetry.authentication" })
        #expect(parent.kind == .internal)
        for name in [
            "bleat.telemetry.challenge",
            "bleat.telemetry.enrolment",
            "bleat.telemetry.token",
        ] {
            let child = try #require(spans.first { $0.name == name })
            #expect(child.kind == .client)
            #expect(child.traceId == parent.traceId)
            #expect(child.parentSpanId == parent.spanId)
        }
        pipeline.deactivate()
        pipeline.purge()
        await pipeline.shutdown()
    }

    @Test

    func testBufferedChapterSpanExportsMeasurementsUnderBatchParent()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = RecordingSpanExporter()
        let tracer = RemoteTelemetryTracer()
        tracer.prepareForActivation()
        let input = try #require(
            RemoteTelemetryTranscriptionInput(
                durationMilliseconds: 12_345,
                byteCount: 67_890,
                sliceCount: 1,
                container: .m4a,
                codec: .aac,
                sampleRateHz: 44_100,
                channelCount: 2
            ))

        let batch = tracer.beginSpan(
            operation: .transcription,
            source: .downloaded
        )
        tracer.beginChildSpan(
            operation: .transcriptionChapter,
            parent: batch
        ).end(.succeeded, transcriptionInput: input)
        batch.end(.succeeded)

        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: exporter
        )
        await pipeline.flush(timeout: 2)

        let spans = exporter.recordedSpans
        let batchSpan = try #require(
            spans.first { $0.name == "bleat.transcription.run" })
        let chapterSpan = try #require(
            spans.first { $0.name == "bleat.transcription.chapter" })
        #expect(chapterSpan.traceId == batchSpan.traceId)
        #expect(chapterSpan.parentSpanId == batchSpan.spanId)
        #expect(
            Set(chapterSpan.attributes.keys) == [
                "bleat.subsystem",
                "bleat.outcome",
                "bleat.retry.bucket",
                "bleat.transcription.input.duration_ms",
                "bleat.transcription.input.bytes",
                "bleat.transcription.input.slice_count",
                "bleat.transcription.audio.container",
                "bleat.transcription.audio.codec",
                "bleat.transcription.audio.sample_rate_hz",
                "bleat.transcription.audio.channels",
            ])
        #expect(
            chapterSpan.attributes[
                "bleat.transcription.input.duration_ms"
            ] == .string("12345"))
        #expect(
            chapterSpan.attributes["bleat.transcription.input.bytes"]
                == .string("67890"))
        #expect(
            chapterSpan.attributes["bleat.transcription.audio.codec"]
                == .string("aac"))
        pipeline.deactivate()
        pipeline.purge()
        await pipeline.shutdown()
    }

    @Test

    func testCloudKitLifecycleProducesReviewedLogsAndSpan() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spanExporter = RecordingSpanExporter()
        let logExporter = RecordingLogExporter()
        let tracer = RemoteTelemetryTracer()
        let logger = RemoteTelemetryLogger()
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            loggerFacade: logger,
            downstreamExporter: spanExporter,
            downstreamLogExporter: logExporter
        )
        let recorder = RemoteTelemetryPrivateCloudSyncEventRecorder(
            tracer: tracer,
            logger: logger
        )
        let correlationID = UUID()
        await recorder.record(
            PrivateCloudSyncEvent(
                correlationID: correlationID,
                operation: .synchronize,
                phase: .started
            )
        )
        let cloudFailure = CloudKitFailure(
            CKError(
                .requestRateLimited,
                userInfo: [CKErrorRetryAfterKey: 1.25]
            )
        )
        let failure = PrivateCloudSyncFailure(
            operation: .synchronize,
            cause: .cloudKit(cloudFailure)
        )
        await recorder.record(
            PrivateCloudSyncEvent(
                correlationID: correlationID,
                operation: .synchronize,
                phase: .failed(failure),
                durationMilliseconds: 42,
                recordCount: 17
            )
        )
        await pipeline.flush(timeout: 2)

        let span = try #require(spanExporter.recordedSpans.first)
        #expect(span.name == RemoteTelemetryOperation.privateCloudSync.rawValue)
        let logs = logExporter.recordedLogs
        #expect(logs.count == 2)
        #expect(logExporter.synchronousExportCount == 0)
        #expect(logExporter.asynchronousExportCount == 1)
        for log in logs {
            let context = try #require(log.spanContext)
            #expect(context.traceId == span.traceId)
            #expect(context.spanId == span.spanId)
        }
        let failed = try #require(logs.last)
        #expect(failed.eventName == "bleat.cloudkit.sync.failed")
        #expect(failed.body == .string("CloudKit synchronization lifecycle"))
        #expect(
            failed.attributes["bleat.cloudkit.operation"]
                == .string("synchronize"))
        #expect(
            failed.attributes["bleat.cloudkit.code"]
                == .string("request_rate_limited"))
        #expect(failed.attributes["bleat.retryable"] == .bool(true))
        #expect(failed.attributes["bleat.retry_after_ms"] == .int(1_250))
        #expect(failed.attributes["bleat.duration_ms"] == .int(42))
        #expect(failed.attributes["bleat.cloudkit.record_count"] == .int(17))
        #expect(failed.attributes["error.description"] == nil)
        pipeline.deactivate()
        pipeline.purge()
        await pipeline.shutdown()
    }

    @Test

    func testDownloadLifecycleProducesTypedCorrelatedLogs() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spanExporter = RecordingSpanExporter()
        let logExporter = RecordingLogExporter()
        let tracer = RemoteTelemetryTracer()
        let logger = RemoteTelemetryLogger()
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            loggerFacade: logger,
            downstreamExporter: spanExporter,
            downstreamLogExporter: logExporter
        )
        let span = tracer.beginSpan(
            operation: .downloadTransfer,
            source: .remote
        )
        logger.recordDownloadEvent(
            RemoteDownloadTransferEvent(
                stage: .taskScheduled,
                state: .started
            ),
            span: span
        )
        logger.recordDownloadEvent(
            RemoteDownloadTransferEvent(
                stage: .retryScheduled,
                state: .retrying,
                retryBucket: .one,
                isRetryable: true,
                retryDelaySeconds: 120,
                retryDelaySource: .serverRetryAfter
            ),
            span: span
        )
        logger.recordDownloadEvent(
            RemoteDownloadTransferEvent(
                stage: .rangeValidation,
                state: .failed,
                failureCause: .mismatchedContentRange
            ),
            span: span
        )
        span.end(.failed(.invalidResponse))
        await pipeline.flush(timeout: 2)

        let exportedSpan = try #require(spanExporter.recordedSpans.first)
        let logs = logExporter.recordedLogs
        #expect(logs.count == 3)
        for log in logs {
            let context = try #require(log.spanContext)
            #expect(context.traceId == exportedSpan.traceId)
            #expect(context.spanId == exportedSpan.spanId)
            #expect(log.body == .string("Download transfer lifecycle"))
        }
        let retry = logs[1]
        #expect(
            retry.attributes["bleat.download.retry_delay_seconds"] == .int(120))
        #expect(
            retry.attributes["bleat.download.retry_delay_source"]
                == .string("server_retry_after"))
        #expect(retry.attributes["http.request.header.retry_after"] == nil)
        let failure = try #require(logs.last)
        #expect(failure.eventName == "bleat.download.transfer.range_validation")
        #expect(
            failure.attributes["bleat.download.stage"]
                == .string("range_validation"))
        #expect(
            failure.attributes["bleat.download.failure_code"]
                == .string("mismatched_content_range"))
        #expect(failure.attributes["bleat.outcome"] == .string("failed"))
        #expect(failure.attributes["url.full"] == nil)
        #expect(failure.attributes["file.path"] == nil)
    }

    @Test

    func testOutcomeEncodingNeverIncludesRawErrorText() {
        let successful = RemoteTelemetrySpanDescriptor(
            operation: .libraryRefresh,
            outcome: .succeeded
        ).encodedSpan
        #expect(successful.attributes["bleat.outcome"] == "succeeded")
        #expect(successful.attributes["bleat.failure.category"] == nil)

        let cancelled = RemoteTelemetrySpanDescriptor(
            operation: .transcription,
            outcome: .cancelled
        ).encodedSpan
        #expect(cancelled.attributes["bleat.outcome"] == "cancelled")
        #expect(cancelled.attributes["bleat.failure.category"] == nil)

        for category in RemoteTelemetryFailureCategory.allCases {
            let encoded = RemoteTelemetrySpanDescriptor(
                operation: .accountConnection,
                outcome: .failed(category)
            ).encodedSpan
            #expect(
                encoded.attributes["bleat.failure.category"]
                    == category.rawValue)
        }

        let liveUpdateFailure = RemoteTelemetrySpanDescriptor(
            operation: .liveUpdateConnection,
            outcome: .liveUpdateFailed(
                RemoteTelemetryLiveUpdateFailure(
                    category: .invalidResponse,
                    code: .malformedPacket,
                    stage: .protocolDecoding
                )
            ),
            source: .localServer,
            retryBucket: .one
        ).encodedSpan
        #expect(
            liveUpdateFailure.attributes == [
                "bleat.subsystem": "authentication",
                "bleat.outcome": "failed",
                "bleat.failure.category": "invalid_response",
                "bleat.source": "local_server",
                "bleat.retry.bucket": "one",
                "bleat.live_update.failure_code": "malformed_packet",
                "bleat.live_update.stage": "protocol_decoding",
            ])
    }

    @Test

    func testChapterTranscriptionSpanEncodesReviewedInputMeasurements()
        throws
    {
        let input = try #require(
            RemoteTelemetryTranscriptionInput(
                durationMilliseconds: 65_432,
                byteCount: 1_234_567,
                sliceCount: 2,
                container: .m4a,
                codec: .aac,
                sampleRateHz: 48_000,
                channelCount: 2
            ))
        let encoded = RemoteTelemetrySpanDescriptor(
            operation: .transcriptionChapter,
            outcome: .succeeded,
            transcriptionInput: input
        ).encodedSpan

        #expect(encoded.name == "bleat.transcription.chapter")
        #expect(
            encoded.attributes == [
                "bleat.subsystem": "transcription",
                "bleat.outcome": "succeeded",
                "bleat.retry.bucket": "none",
                "bleat.transcription.input.duration_ms": "65432",
                "bleat.transcription.input.bytes": "1234567",
                "bleat.transcription.input.slice_count": "2",
                "bleat.transcription.audio.container": "m4a",
                "bleat.transcription.audio.codec": "aac",
                "bleat.transcription.audio.sample_rate_hz": "48000",
                "bleat.transcription.audio.channels": "2",
            ])
    }

    @Test

    func testRetryCountsAreBounded() {
        #expect(RemoteTelemetryRetryBucket(retryCount: -1) == .none)
        #expect(RemoteTelemetryRetryBucket(retryCount: 0) == .none)
        #expect(RemoteTelemetryRetryBucket(retryCount: 1) == .one)
        #expect(RemoteTelemetryRetryBucket(retryCount: 2) == .two)
        #expect(RemoteTelemetryRetryBucket(retryCount: 3) == .threeOrMore)
        #expect(RemoteTelemetryRetryBucket(retryCount: .max) == .threeOrMore)
    }

    @Test

    func testResourceEncodingContainsOnlyStableTechnicalValues() throws {
        let resource = try RemoteTelemetryResource(
            applicationVersion: "0.01.1",
            applicationBuild: "00042",
            platform: .iOS,
            operatingSystemMajorVersion: 26,
            operatingSystemMinorVersion: 3,
            operatingSystemPatchVersion: 1,
            installationID: UUID(
                uuidString: "c12a1d3e-b1ea-44b2-955f-9b7bd5ea21aa"
            )!
        )
        #expect(
            resource.encodedAttributes == [
                "service.name": "bleat",
                "service.version": "0.1.1",
                "bleat.app.build": "42",
                "os.type": "ios",
                "os.version": "26.3.1",
                "service.instance.id":
                    "c12a1d3e-b1ea-44b2-955f-9b7bd5ea21aa",
            ])
        #expect(!(resource.encodedAttributes.keys.contains("device.model")))
    }

    @Test

    func testResourceAcceptsIntegerAndDottedNumericBuilds() throws {
        #expect(
            try resource(version: "1.2.3", build: "00042")
                .applicationBuild == "42")
        #expect(
            try resource(
                version: "1.2.3",
                build: "20260901.0033.10"
            ).applicationBuild == "20260901.33.10")
    }

    @Test

    func testResourceRejectsArbitraryOrUnboundedStrings() throws {
        if let error = #expect(
            throws: (any Error).self,
            performing: { try resource(version: "reader", build: "1") })
        {
            #expect(
                error as? RemoteTelemetryResourceError
                    == .invalidApplicationVersion)
        }
        if let error = #expect(
            throws: (any Error).self,
            performing: { try resource(version: "1.0", build: "books.example") }
        ) {
            #expect(
                error as? RemoteTelemetryResourceError
                    == .invalidApplicationBuild)
        }
        for build in ["1..2", "1.2.3.4", "1.2-beta", "4294967296"] {
            if let error = #expect(
                throws: (any Error).self,
                performing: { try resource(version: "1.0", build: build) })
            {
                #expect(
                    error as? RemoteTelemetryResourceError
                        == .invalidApplicationBuild)
            }
        }
        #expect(
            throws: (any Error).self,
            performing: { try resource(version: "1.999999", build: "1") })
        #expect(
            throws: (any Error).self,
            performing: {
                try RemoteTelemetryResource(
                    applicationVersion: "1.0",
                    applicationBuild: "1",
                    platform: .iOS,
                    operatingSystemMajorVersion: -1,
                    operatingSystemMinorVersion: 0,
                    operatingSystemPatchVersion: 0,
                    installationID: UUID()
                )
            })
    }

    @Test

    func testRepresentativeEncodingContainsNoSensitiveValues() throws {
        let resource = try resource(version: "1.2.3", build: "45")
        let span = RemoteTelemetrySpanDescriptor(
            operation: .playbackStart,
            outcome: .failed(.authentication),
            source: .streamed,
            retryBucket: .one
        ).encodedSpan
        let encoded =
            (resource.encodedAttributes.flatMap { [$0.key, $0.value] }
            + [span.name]
            + span.attributes.flatMap { [$0.key, $0.value] }).joined(
                separator: "\n")
        let prohibited = [
            "reader@example.com",
            "https://books.example/audiobookshelf",
            "Authorization",
            "Bearer eyJhbGciOiJFUzI1NiJ9",
            "refresh-token",
            "/private/var/mobile/Containers/media.m4b",
            "A Secret Audiobook Title",
            "transcript words",
            "search phrase",
            "/public/session/opaque-id",
        ]
        for value in prohibited {
            #expect(!(encoded.localizedCaseInsensitiveContains(value)))
        }
    }

    @Test

    func testDefaultCollectionPolicyMatchesReviewedBounds() {
        let policy = RemoteTelemetryCollectionPolicy.default
        #expect(policy.samplingRatio == 1)
        #expect(policy.maximumBufferedAge == 2 * 60 * 60)
        #expect(policy.maximumBufferedBytes == 128 * 1_024 * 1_024)
        #expect(policy.maximumBufferedSpanCount == nil)
        #expect(policy.overflowPolicy == .dropOldest)
    }

    @Test

    func testInactiveTracerProducesNoExportableSpan() {
        let exporter = RecordingSpanExporter()
        let tracer = InactiveRemoteTelemetryTracer()
        tracer.beginSpan(operation: .appLaunch).end(.succeeded)
        #expect(exporter.recordedSpans.isEmpty)
    }

    @Test

    func testPipelineBatchesReviewedSpansWithExactResource() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = RecordingSpanExporter()
        let tracer = RemoteTelemetryTracer()
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1.2.3", build: "45"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: exporter
        )
        tracer.beginSpan(
            operation: .libraryRefresh,
            source: .remote
        ).end(.succeeded)
        tracer.beginSpan(
            operation: .playbackStart,
            source: .downloaded,
            retryBucket: .one
        ).end(.failed(.media))

        await pipeline.flush(timeout: 2)

        let spans = exporter.recordedSpans
        #expect(spans.count == 2)
        #expect(
            Set(spans.map(\.name)) == [
                "bleat.library.refresh", "bleat.playback.start",
            ])
        for span in spans {
            #expect(
                span.resource.attributes.mapValues(\.description) == [
                    "service.name": "bleat",
                    "service.version": "1.2.3",
                    "bleat.app.build": "45",
                    "os.type": "ios",
                    "os.version": "26.0.0",
                    "service.instance.id":
                        "c12a1d3e-b1ea-44b2-955f-9b7bd5ea21aa",
                ])
            #expect(span.events.isEmpty)
            #expect(span.links.isEmpty)
        }
        #expect(exporter.batchSizes.contains(2))
        #expect(exporter.synchronousExportCount == 0)
        #expect(exporter.asynchronousExportCount == 1)
        pipeline.deactivate()
        pipeline.purge()
    }

    @Test

    func testSpansStartedDuringAsynchronousInitializationAreExported()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = RecordingSpanExporter()
        let tracer = RemoteTelemetryTracer()
        tracer.prepareForActivation()
        tracer.beginSpan(operation: .appLaunch).end(.succeeded)

        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: exporter
        )
        await pipeline.flush(timeout: 2)

        #expect(
            exporter.recordedSpans.map(\.name) == [
                RemoteTelemetryOperation.appLaunch.rawValue
            ])
        pipeline.deactivate()
        pipeline.purge()
    }

    @Test

    func testFailedExportIsRetainedAndDrainedAfterRelaunch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstTracer = RemoteTelemetryTracer()
        let first = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: firstTracer,
            downstreamExporter: RecordingSpanExporter(result: .failure)
        )
        firstTracer.beginSpan(operation: .appLaunch).end(.succeeded)
        await first.flush(timeout: 2)
        #expect(!(batchFiles(in: directory).isEmpty))
        first.deactivate()
        await first.shutdown()

        let exporter = RecordingSpanExporter()
        let second = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: RemoteTelemetryTracer(),
            downstreamExporter: exporter
        )
        await second.flush(timeout: 2)
        #expect(exporter.recordedSpans.map(\.name) == ["bleat.app.launch"])
        #expect(batchFiles(in: directory).isEmpty)
        second.deactivate()
        second.purge()
    }

    @Test

    func testPersistencePrunesExpiredAndCorruptBatches() async throws {
        let sourceDirectory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let recording = RecordingSpanExporter()
        let tracer = RemoteTelemetryTracer()
        let source = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: sourceDirectory,
            tracerFacade: tracer,
            downstreamExporter: recording
        )
        tracer.beginSpan(operation: .transcription).end(.succeeded)
        await source.flush(timeout: 2)
        let span = try #require(recording.recordedSpans.first)
        source.deactivate()
        source.purge()

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestDateBox(span.endTime)
        let failed = RecordingSpanExporter(result: .failure)
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: failed,
            policy: .default,
            now: { clock.value }
        )
        let initialExport = await exporter.export(spans: [span])
        #expect(initialExport == .success)
        #expect(!(batchFiles(in: directory).isEmpty))
        try Data("not-json".utf8).write(
            to: directory.appendingPathComponent("batch-corrupt.json")
        )
        exporter.disable()
        clock.value = span.endTime.addingTimeInterval(3 * 60 * 60)
        _ = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: failed,
            policy: .default,
            now: { clock.value }
        )
        #expect(batchFiles(in: directory).isEmpty)
    }

    @Test

    func testPersistenceNeverExceedsConfiguredByteLimit() async throws {
        let span = try await makeRecordedSpan()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = RemoteTelemetryCollectionPolicy(
            samplingRatio: 1,
            maximumBufferedAge: 60 * 60,
            maximumBufferedBytes: 4_096,
            maximumBufferedSpanCount: nil,
            overflowPolicy: .dropOldest
        )
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: RecordingSpanExporter(result: .failure),
            policy: policy
        )
        for _ in 0..<20 {
            _ = await exporter.export(spans: [span])
        }
        let bytes = batchFiles(in: directory).reduce(0) {
            $0
                + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?
                    .fileSize ?? 0)
        }
        #expect(bytes <= policy.maximumBufferedBytes)
        #expect(policy.maximumBufferedSpanCount == nil)
        exporter.disableAndPurge()
    }

    @Test

    func testByteLimitEvictsOnlyTheOldestRequiredSpans() async throws {
        let oldest = try await makeRecordedSpan(operation: .appLaunch)
        let middle = try await makeRecordedSpan(operation: .libraryRefresh)
        let newest = try await makeRecordedSpan(operation: .transcription)
        let firstBatch = try JSONEncoder().encode([oldest, middle])
        let retainedFirstBatch = try JSONEncoder().encode([middle])
        let secondBatch = try JSONEncoder().encode([newest])
        #expect(firstBatch.count > retainedFirstBatch.count)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = RemoteTelemetryCollectionPolicy(
            samplingRatio: 1,
            maximumBufferedAge: 60 * 60,
            maximumBufferedBytes: firstBatch.count + secondBatch.count - 1,
            maximumBufferedSpanCount: nil,
            overflowPolicy: .dropOldest
        )
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: RecordingSpanExporter(result: .failure),
            policy: policy
        )
        exporter.setForeground(false)

        let firstExport = await exporter.export(spans: [oldest, middle])
        let secondExport = await exporter.export(spans: [newest])
        #expect(firstExport == .success)
        #expect(secondExport == .success)

        let retained = try batchFiles(in: directory).flatMap {
            try JSONDecoder().decode(
                [SpanData].self,
                from: Data(contentsOf: $0)
            )
        }
        #expect(
            retained.sorted { $0.endTime < $1.endTime }.map(\.name) == [
                middle.name, newest.name,
            ])
        exporter.disableAndPurge()
    }

    @Test

    func testPersistenceStoresOnlySpanDataAndHasNoCountCap() async throws {
        let span = try await makeRecordedSpan()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: RecordingSpanExporter(result: .failure),
            policy: .default
        )
        exporter.setForeground(false)
        let exportResult = await exporter.export(
            spans: Array(repeating: span, count: 200)
        )
        #expect(exportResult == .success)

        let file = try #require(batchFiles(in: directory).first)
        let persisted = try JSONDecoder().decode(
            [SpanData].self,
            from: Data(contentsOf: file)
        )
        #expect(persisted.count == 200)
        #expect(
            RemoteTelemetryCollectionPolicy.default.maximumBufferedSpanCount
                == nil)
        exporter.disableAndPurge()
    }

    @Test

    func testPersistenceDrainsOldestSpanFirstAfterRelaunch() async throws {
        let oldest = try await makeRecordedSpan(operation: .appLaunch)
        let newest = try await makeRecordedSpan(operation: .transcription)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: RecordingSpanExporter(result: .failure),
            policy: .default
        )
        failed.setForeground(false)
        let newestResult = await failed.export(spans: [newest])
        let oldestResult = await failed.export(spans: [oldest])
        #expect(newestResult == .success)
        #expect(oldestResult == .success)
        failed.disable()

        let recording = RecordingSpanExporter()
        let recovered = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: recording,
            policy: .default
        )
        let flushResult = await recovered.flush(explicitTimeout: 2)
        #expect(flushResult == .success)
        #expect(
            recording.recordedSpans.map(\.name) == [oldest.name, newest.name])
        recovered.disableAndPurge()
    }

    @Test

    func testOversizedBatchDropsOldestSpansWithoutExceedingLimit()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let policy = RemoteTelemetryCollectionPolicy(
            samplingRatio: 1,
            maximumBufferedAge: 60,
            maximumBufferedBytes: 8,
            maximumBufferedSpanCount: nil,
            overflowPolicy: .dropOldest
        )
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: RecordingSpanExporter(result: .failure),
            policy: policy
        )
        exporter.setForeground(false)

        let span = try await makeRecordedSpan()
        let exportResult = await exporter.export(spans: [span])
        #expect(exportResult == .success)
        #expect(batchFiles(in: directory).isEmpty)
        exporter.disableAndPurge()
    }

    @Test

    func testSpanEndDoesNotWaitForBlockedDownstreamExport() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = RecordingSpanExporter(delay: 1)
        let tracer = RemoteTelemetryTracer()
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: exporter
        )
        let started = ContinuousClock.now
        tracer.beginSpan(operation: .appLaunch).end(.succeeded)
        let elapsed = started.duration(to: .now)
        #expect(elapsed < .milliseconds(100))
        pipeline.deactivate()
        pipeline.purge()
    }

    @Test

    func testSynchronousSpanWitnessReturnsBeforePersistenceAndAsyncFlushWaits()
        async throws
    {
        let span = try await makeRecordedSpan()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storageQueue = DispatchQueue(
            label: "app.bleat.remote-telemetry.storage.test"
        )
        let persistenceGate = DispatchSemaphore(value: 0)
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: RecordingSpanExporter(result: .failure),
            policy: .default,
            storageQueue: storageQueue
        )
        storageQueue.async { persistenceGate.wait() }
        defer {
            persistenceGate.signal()
            exporter.disableAndPurge()
        }

        let started = ContinuousClock.now
        let exportResult = synchronousExport(exporter, spans: [span])
        let elapsed = started.duration(to: .now)
        #expect(exportResult == .success)
        #expect(elapsed < .milliseconds(100))

        let completion = TestCompletionFlag()
        let flush = Task {
            let result = await exporter.flush(explicitTimeout: 2)
            completion.complete()
            return result
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!(completion.isComplete))
        #expect(batchFiles(in: directory).isEmpty)

        persistenceGate.signal()
        let flushResult = await flush.value
        #expect(flushResult == .success)
        #expect(completion.isComplete)
        #expect(!(batchFiles(in: directory).isEmpty))
    }

    @Test

    func testConcurrentLogShutdownCallersAwaitSharedCompletion() async {
        let downstream = GatedShutdownLogExporter()
        let exporter = QueuedRemoteTelemetryLogExporter(
            downstream: downstream
        )
        let firstCompletion = TestCompletionFlag()
        let secondCompletion = TestCompletionFlag()

        let first = Task {
            await exporter.shutdown(explicitTimeout: 2)
            firstCompletion.complete()
        }
        await downstream.waitUntilShutdownStarts()
        let second = Task {
            await exporter.shutdown(explicitTimeout: 2)
            secondCompletion.complete()
        }
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!(firstCompletion.isComplete))
        #expect(!(secondCompletion.isComplete))
        #expect(downstream.shutdownCount == 1)

        downstream.completeShutdown()
        await first.value
        await second.value
        #expect(firstCompletion.isComplete)
        #expect(secondCompletion.isComplete)
        #expect(downstream.shutdownCount == 1)
    }

    @Test

    func testBackgroundStyleFlushReturnsAtItsDeadline() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracer = RemoteTelemetryTracer()
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: RecordingSpanExporter(delay: 1)
        )
        tracer.beginSpan(operation: .appLaunch).end(.succeeded)

        let started = ContinuousClock.now
        await pipeline.flush(timeout: 0.05)
        let elapsed = started.duration(to: .now)

        #expect(elapsed < .milliseconds(250))
        pipeline.deactivate()
        pipeline.purge()
    }

    @Test

    func testBackgroundFlushAttemptsOneDrainWhileBackgrounded() async throws {
        let span = try await makeRecordedSpan()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = RecordingSpanExporter()
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: recording,
            policy: .default
        )
        exporter.setForeground(false)
        let exportResult = await exporter.export(spans: [span])
        #expect(exportResult == .success)

        let flushResult = await exporter.flush(
            explicitTimeout: 2,
            allowWhileBackgrounded: true
        )
        #expect(flushResult == .success)
        #expect(recording.recordedSpans.map(\.name) == [span.name])
        exporter.disableAndPurge()
    }

    @Test

    func testWithdrawalCancelsAnActiveDownstreamExport() async throws {
        let span = try await makeRecordedSpan()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downstream = CancellableBlockingSpanExporter()
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: downstream,
            policy: .default
        )

        let exportResult = await exporter.export(spans: [span])
        #expect(exportResult == .success)
        #expect(downstream.waitUntilStarted(timeout: 2) == .success)
        exporter.disable()
        #expect(downstream.waitUntilFinished(timeout: 2) == .success)

        #expect(downstream.recordedSpans.isEmpty)
        exporter.disableAndPurge()
    }

    @Test

    func testWithdrawalStopsNewSpansAndPurgesRetainedData() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracer = RemoteTelemetryTracer()
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: RecordingSpanExporter(result: .failure)
        )
        tracer.beginSpan(operation: .appLaunch).end(.succeeded)
        await pipeline.flush(timeout: 2)
        #expect(!(batchFiles(in: directory).isEmpty))

        pipeline.deactivate()
        pipeline.purge()
        tracer.beginSpan(operation: .libraryRefresh).end(.succeeded)

        #expect(batchFiles(in: directory).isEmpty)
    }

    @Test

    func testWithdrawalDuringActiveSpanCannotExportWithdrawnGeneration()
        async throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = RecordingSpanExporter()
        let tracer = RemoteTelemetryTracer()
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: recording
        )
        let active = tracer.beginSpan(operation: .appLaunch)

        pipeline.deactivate()
        pipeline.purge()
        active.end(.succeeded)
        await pipeline.shutdown()

        #expect(recording.recordedSpans.isEmpty)
        #expect(batchFiles(in: directory).isEmpty)
    }

    @Test

    func testRapidReenableExportsOnlyCleanGeneration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracer = RemoteTelemetryTracer()
        let withdrawnExporter = RecordingSpanExporter()
        let withdrawn = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: withdrawnExporter
        )
        let oldSpan = tracer.beginSpan(operation: .appLaunch)
        withdrawn.deactivate()
        withdrawn.purge()

        let currentExporter = RecordingSpanExporter()
        let current = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: currentExporter
        )
        oldSpan.end(.succeeded)
        tracer.beginSpan(operation: .libraryRefresh).end(.succeeded)
        await current.flush(timeout: 2)
        await withdrawn.shutdown()

        #expect(withdrawnExporter.recordedSpans.isEmpty)
        #expect(
            currentExporter.recordedSpans.map(\.name) == [
                RemoteTelemetryOperation.libraryRefresh.rawValue
            ])
        current.deactivate()
        current.purge()
    }

    private func resource(
        version: String,
        build: String
    ) throws -> RemoteTelemetryResource {
        try RemoteTelemetryResource(
            applicationVersion: version,
            applicationBuild: build,
            platform: .iOS,
            operatingSystemMajorVersion: 26,
            operatingSystemMinorVersion: 0,
            operatingSystemPatchVersion: 0,
            installationID: UUID(
                uuidString: "c12a1d3e-b1ea-44b2-955f-9b7bd5ea21aa"
            )!
        )
    }

    private func synchronousExport(
        _ exporter: any SpanExporter,
        spans: [SpanData]
    ) -> SpanExporterResultCode {
        exporter.export(spans: spans, explicitTimeout: 2)
    }

    private func makeRecordedSpan(
        operation: RemoteTelemetryOperation = .appLaunch
    ) async throws -> SpanData {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = RecordingSpanExporter()
        let tracer = RemoteTelemetryTracer()
        let pipeline = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: tracer,
            downstreamExporter: recording
        )
        tracer.beginSpan(operation: operation).end(.succeeded)
        await pipeline.flush(timeout: 2)
        let span = try #require(recording.recordedSpans.first)
        pipeline.deactivate()
        pipeline.purge()
        return span
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "RemoteTelemetryTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func batchFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }
    }
}

private final class TestDateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Date

    init(_ value: Date) {
        storedValue = value
    }

    var value: Date {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class TestCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isComplete: Bool {
        lock.withLock { completed }
    }

    func complete() {
        lock.withLock { completed = true }
    }
}

private final class TestAsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var completed = false

    func wait() async {
        if lock.withLock({ completed }) { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if completed { return true }
                self.continuation = continuation
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func complete() {
        let continuation = lock.withLock {
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}

private final class GatedShutdownLogExporter:
    RemoteTelemetryDownstreamLogExporter, @unchecked Sendable
{
    private let lock = NSLock()
    private let shutdownStarted = TestAsyncSignal()
    private let shutdownCompletion = TestAsyncSignal()
    private var shutdowns = 0

    var shutdownCount: Int {
        lock.withLock { shutdowns }
    }

    func export(
        logRecords: [ReadableLogRecord],
        explicitTimeout: TimeInterval?
    ) -> ExportResult { .failure }

    func export(
        logRecords: [ReadableLogRecord],
        explicitTimeout: TimeInterval?
    ) async -> ExportResult { .failure }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult { .failure }

    func forceFlush(
        explicitTimeout: TimeInterval?
    ) async -> ExportResult { .failure }

    func shutdown(explicitTimeout: TimeInterval?) {}

    func shutdown(explicitTimeout: TimeInterval?) async {
        lock.withLock { shutdowns += 1 }
        shutdownStarted.complete()
        await shutdownCompletion.wait()
    }

    func cancelActiveExports() {}

    func disable() {}

    func waitUntilShutdownStarts() async {
        await shutdownStarted.wait()
    }

    func completeShutdown() {
        shutdownCompletion.complete()
    }
}

private final class RecordingSpanExporter:
    RemoteTelemetryDownstreamSpanExporter, @unchecked Sendable
{
    private let lock = NSLock()
    private var spans: [SpanData] = []
    private var sizes: [Int] = []
    private var synchronousExports = 0
    private var asynchronousExports = 0
    private let result: SpanExporterResultCode
    private let delay: TimeInterval

    init(
        result: SpanExporterResultCode = .success,
        delay: TimeInterval = 0
    ) {
        self.result = result
        self.delay = delay
    }

    var recordedSpans: [SpanData] {
        lock.withLock { spans }
    }

    var batchSizes: [Int] {
        lock.withLock { sizes }
    }

    var synchronousExportCount: Int {
        lock.withLock { synchronousExports }
    }

    var asynchronousExportCount: Int {
        lock.withLock { asynchronousExports }
    }

    func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        lock.withLock { synchronousExports += 1 }
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        record(spans)
        return result
    }

    func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) async -> SpanExporterResultCode {
        lock.withLock { asynchronousExports += 1 }
        if delay > 0 {
            try? await Task.sleep(for: .seconds(delay))
        }
        record(spans)
        return result
    }

    private func record(_ spans: [SpanData]) {
        lock.withLock {
            self.spans.append(contentsOf: spans)
            sizes.append(spans.count)
        }
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        result
    }

    func flush(
        explicitTimeout: TimeInterval?
    ) async -> SpanExporterResultCode {
        result
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

    func shutdown(explicitTimeout: TimeInterval?) async {}

    func cancelActiveExports() {}
}

private final class RecordingLogExporter:
    RemoteTelemetryDownstreamLogExporter, @unchecked Sendable
{
    private let lock = NSLock()
    private var logs: [ReadableLogRecord] = []
    private var synchronousExports = 0
    private var asynchronousExports = 0

    var recordedLogs: [ReadableLogRecord] {
        lock.withLock { logs }
    }

    var synchronousExportCount: Int {
        lock.withLock { synchronousExports }
    }

    var asynchronousExportCount: Int {
        lock.withLock { asynchronousExports }
    }

    func export(
        logRecords: [ReadableLogRecord],
        explicitTimeout: TimeInterval?
    ) -> ExportResult {
        lock.withLock {
            synchronousExports += 1
            logs.append(contentsOf: logRecords)
        }
        return .success
    }

    func export(
        logRecords: [ReadableLogRecord],
        explicitTimeout: TimeInterval?
    ) async -> ExportResult {
        lock.withLock {
            asynchronousExports += 1
            logs.append(contentsOf: logRecords)
        }
        return .success
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        .success
    }

    func forceFlush(explicitTimeout: TimeInterval?) async -> ExportResult {
        .success
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

    func shutdown(explicitTimeout: TimeInterval?) async {}

    func cancelActiveExports() {}

    func disable() {}
}

private final class CancellableBlockingSpanExporter:
    RemoteTelemetryDownstreamSpanExporter, @unchecked Sendable
{
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private var cancelled = false
    private var spans: [SpanData] = []

    var recordedSpans: [SpanData] {
        lock.withLock { spans }
    }

    func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        started.signal()
        _ = release.wait(timeout: .now() + (explicitTimeout ?? 30))
        let result: SpanExporterResultCode = lock.withLock {
            guard !cancelled else { return .failure }
            self.spans.append(contentsOf: spans)
            return .success
        }
        finished.signal()
        return result
    }

    func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) async -> SpanExporterResultCode {
        started.signal()
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(explicitTimeout ?? 30)
        )
        while !Task.isCancelled,
            !lock.withLock({ cancelled }),
            ContinuousClock.now < deadline
        {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let result: SpanExporterResultCode = lock.withLock {
            guard !cancelled, !Task.isCancelled else { return .failure }
            self.spans.append(contentsOf: spans)
            return .success
        }
        finished.signal()
        return result
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        .success
    }

    func flush(
        explicitTimeout: TimeInterval?
    ) async -> SpanExporterResultCode {
        .success
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

    func shutdown(explicitTimeout: TimeInterval?) async {}

    func cancelActiveExports() {
        lock.withLock { cancelled = true }
        release.signal()
    }

    func waitUntilStarted(timeout: TimeInterval) -> DispatchTimeoutResult {
        started.wait(timeout: .now() + timeout)
    }

    func waitUntilFinished(timeout: TimeInterval) -> DispatchTimeoutResult {
        finished.wait(timeout: .now() + timeout)
    }
}
