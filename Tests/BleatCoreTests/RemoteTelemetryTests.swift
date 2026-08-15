@preconcurrency import OpenTelemetrySdk
import XCTest

@testable import BleatCore

final class RemoteTelemetryTests: XCTestCase {
    func testReviewedOperationsEncodeOnlyReviewedNamesAndAttributes() {
        let allowedNames = Set(
            RemoteTelemetryOperation.allCases.map(\.rawValue))
        XCTAssertEqual(
            allowedNames,
            [
                "bleat.app.launch",
                "bleat.account.connection",
                "bleat.library.refresh",
                "bleat.playback.prepare",
                "bleat.playback.start",
                "bleat.download.transfer",
                "bleat.playback.progress_sync",
                "bleat.transcription.run",
            ]
        )

        for operation in RemoteTelemetryOperation.allCases {
            let encoded = RemoteTelemetrySpanDescriptor(
                operation: operation,
                outcome: .failed(.transport),
                source: .offline,
                retryBucket: .threeOrMore
            ).encodedSpan
            XCTAssertTrue(allowedNames.contains(encoded.name))
            XCTAssertEqual(
                Set(encoded.attributes.keys),
                [
                    "bleat.subsystem",
                    "bleat.outcome",
                    "bleat.failure.category",
                    "bleat.source",
                    "bleat.retry.bucket",
                ]
            )
            XCTAssertEqual(encoded.attributes["bleat.outcome"], "failed")
            XCTAssertEqual(
                encoded.attributes["bleat.failure.category"],
                "transport"
            )
        }
    }

    func testOutcomeEncodingNeverIncludesRawErrorText() {
        let successful = RemoteTelemetrySpanDescriptor(
            operation: .libraryRefresh,
            outcome: .succeeded
        ).encodedSpan
        XCTAssertEqual(successful.attributes["bleat.outcome"], "succeeded")
        XCTAssertNil(successful.attributes["bleat.failure.category"])

        let cancelled = RemoteTelemetrySpanDescriptor(
            operation: .transcription,
            outcome: .cancelled
        ).encodedSpan
        XCTAssertEqual(cancelled.attributes["bleat.outcome"], "cancelled")
        XCTAssertNil(cancelled.attributes["bleat.failure.category"])

        for category in RemoteTelemetryFailureCategory.allCases {
            let encoded = RemoteTelemetrySpanDescriptor(
                operation: .accountConnection,
                outcome: .failed(category)
            ).encodedSpan
            XCTAssertEqual(
                encoded.attributes["bleat.failure.category"],
                category.rawValue
            )
        }
    }

    func testRetryCountsAreBounded() {
        XCTAssertEqual(RemoteTelemetryRetryBucket(retryCount: -1), .none)
        XCTAssertEqual(RemoteTelemetryRetryBucket(retryCount: 0), .none)
        XCTAssertEqual(RemoteTelemetryRetryBucket(retryCount: 1), .one)
        XCTAssertEqual(RemoteTelemetryRetryBucket(retryCount: 2), .two)
        XCTAssertEqual(
            RemoteTelemetryRetryBucket(retryCount: 3),
            .threeOrMore
        )
        XCTAssertEqual(
            RemoteTelemetryRetryBucket(retryCount: .max),
            .threeOrMore
        )
    }

    func testResourceEncodingContainsOnlyStableTechnicalValues() throws {
        let resource = try RemoteTelemetryResource(
            applicationVersion: "0.01.1",
            applicationBuild: "00042",
            platform: .iOS,
            operatingSystemMajorVersion: 26,
            operatingSystemMinorVersion: 3,
            operatingSystemPatchVersion: 1
        )
        XCTAssertEqual(
            resource.encodedAttributes,
            [
                "service.name": "bleat",
                "service.version": "0.1.1",
                "bleat.app.build": "42",
                "os.type": "ios",
                "os.version": "26.3.1",
            ]
        )
        XCTAssertFalse(resource.encodedAttributes.keys.contains("device.model"))
        XCTAssertFalse(
            resource.encodedAttributes.keys.contains("service.instance.id")
        )
    }

    func testResourceRejectsArbitraryOrUnboundedStrings() throws {
        XCTAssertThrowsError(
            try resource(version: "reader", build: "1")
        ) { error in
            XCTAssertEqual(
                error as? RemoteTelemetryResourceError,
                .invalidApplicationVersion
            )
        }
        XCTAssertThrowsError(
            try resource(version: "1.0", build: "books.example")
        ) { error in
            XCTAssertEqual(
                error as? RemoteTelemetryResourceError,
                .invalidApplicationBuild
            )
        }
        XCTAssertThrowsError(
            try resource(version: "1.999999", build: "1")
        )
        XCTAssertThrowsError(
            try RemoteTelemetryResource(
                applicationVersion: "1.0",
                applicationBuild: "1",
                platform: .iOS,
                operatingSystemMajorVersion: -1,
                operatingSystemMinorVersion: 0,
                operatingSystemPatchVersion: 0
            )
        )
    }

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
            XCTAssertFalse(encoded.localizedCaseInsensitiveContains(value))
        }
    }

    func testDefaultCollectionPolicyMatchesReviewedBounds() {
        let policy = RemoteTelemetryCollectionPolicy.default
        XCTAssertEqual(policy.samplingRatio, 1)
        XCTAssertEqual(policy.maximumBufferedAge, 2 * 60 * 60)
        XCTAssertEqual(policy.maximumBufferedBytes, 128 * 1_024 * 1_024)
        XCTAssertNil(policy.maximumBufferedSpanCount)
        XCTAssertEqual(policy.overflowPolicy, .dropOldest)
    }

    func testInactiveTracerProducesNoExportableSpan() {
        let exporter = RecordingSpanExporter()
        let tracer = InactiveRemoteTelemetryTracer()
        tracer.beginSpan(operation: .appLaunch).end(.succeeded)
        XCTAssertTrue(exporter.recordedSpans.isEmpty)
    }

    func testPipelineBatchesReviewedSpansWithExactResource() throws {
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

        pipeline.flush(timeout: 2)

        let spans = exporter.recordedSpans
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(
            Set(spans.map(\.name)),
            ["bleat.library.refresh", "bleat.playback.start"]
        )
        for span in spans {
            XCTAssertEqual(
                span.resource.attributes.mapValues(\.description),
                [
                    "service.name": "bleat",
                    "service.version": "1.2.3",
                    "bleat.app.build": "45",
                    "os.type": "ios",
                    "os.version": "26.0.0",
                ]
            )
            XCTAssertTrue(span.events.isEmpty)
            XCTAssertTrue(span.links.isEmpty)
        }
        XCTAssertTrue(exporter.batchSizes.contains(2))
        pipeline.deactivate()
        pipeline.purge()
    }

    func testSpansStartedDuringAsynchronousInitializationAreExported()
        throws
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
        pipeline.flush(timeout: 2)

        XCTAssertEqual(
            exporter.recordedSpans.map(\.name),
            [RemoteTelemetryOperation.appLaunch.rawValue]
        )
        pipeline.deactivate()
        pipeline.purge()
    }

    func testFailedExportIsRetainedAndDrainedAfterRelaunch() throws {
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
        first.flush(timeout: 2)
        XCTAssertFalse(batchFiles(in: directory).isEmpty)
        first.deactivate()
        first.shutdown()

        let exporter = RecordingSpanExporter()
        let second = try RemoteTelemetryPipeline(
            resource: try resource(version: "1", build: "1"),
            storageURL: directory,
            tracerFacade: RemoteTelemetryTracer(),
            downstreamExporter: exporter
        )
        second.flush(timeout: 2)
        XCTAssertEqual(exporter.recordedSpans.map(\.name), ["bleat.app.launch"])
        XCTAssertTrue(batchFiles(in: directory).isEmpty)
        second.deactivate()
        second.purge()
    }

    func testPersistencePrunesExpiredAndCorruptBatches() throws {
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
        source.flush(timeout: 2)
        let span = try XCTUnwrap(recording.recordedSpans.first)
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
        XCTAssertEqual(exporter.export(spans: [span]), .success)
        XCTAssertFalse(batchFiles(in: directory).isEmpty)
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
        XCTAssertTrue(batchFiles(in: directory).isEmpty)
    }

    func testPersistenceNeverExceedsConfiguredByteLimit() throws {
        let span = try makeRecordedSpan()
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
            _ = exporter.export(spans: [span])
        }
        let bytes = batchFiles(in: directory).reduce(0) {
            $0
                + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?
                    .fileSize ?? 0)
        }
        XCTAssertLessThanOrEqual(bytes, policy.maximumBufferedBytes)
        XCTAssertNil(policy.maximumBufferedSpanCount)
        exporter.disableAndPurge()
    }

    func testByteLimitEvictsOnlyTheOldestRequiredSpans() throws {
        let oldest = try makeRecordedSpan(operation: .appLaunch)
        let middle = try makeRecordedSpan(operation: .libraryRefresh)
        let newest = try makeRecordedSpan(operation: .transcription)
        let firstBatch = try JSONEncoder().encode([oldest, middle])
        let retainedFirstBatch = try JSONEncoder().encode([middle])
        let secondBatch = try JSONEncoder().encode([newest])
        XCTAssertGreaterThan(firstBatch.count, retainedFirstBatch.count)
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

        XCTAssertEqual(exporter.export(spans: [oldest, middle]), .success)
        XCTAssertEqual(exporter.export(spans: [newest]), .success)

        let retained = try batchFiles(in: directory).flatMap {
            try JSONDecoder().decode(
                [SpanData].self,
                from: Data(contentsOf: $0)
            )
        }
        XCTAssertEqual(
            retained.sorted { $0.endTime < $1.endTime }.map(\.name),
            [middle.name, newest.name]
        )
        exporter.disableAndPurge()
    }

    func testPersistenceStoresOnlySpanDataAndHasNoCountCap() throws {
        let span = try makeRecordedSpan()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: RecordingSpanExporter(result: .failure),
            policy: .default
        )
        exporter.setForeground(false)
        XCTAssertEqual(
            exporter.export(spans: Array(repeating: span, count: 200)),
            .success
        )

        let file = try XCTUnwrap(batchFiles(in: directory).first)
        let persisted = try JSONDecoder().decode(
            [SpanData].self,
            from: Data(contentsOf: file)
        )
        XCTAssertEqual(persisted.count, 200)
        XCTAssertNil(
            RemoteTelemetryCollectionPolicy.default.maximumBufferedSpanCount)
        exporter.disableAndPurge()
    }

    func testPersistenceDrainsOldestSpanFirstAfterRelaunch() throws {
        let oldest = try makeRecordedSpan(operation: .appLaunch)
        let newest = try makeRecordedSpan(operation: .transcription)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let failed = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: RecordingSpanExporter(result: .failure),
            policy: .default
        )
        failed.setForeground(false)
        XCTAssertEqual(failed.export(spans: [newest]), .success)
        XCTAssertEqual(failed.export(spans: [oldest]), .success)
        failed.disable()

        let recording = RecordingSpanExporter()
        let recovered = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: recording,
            policy: .default
        )
        XCTAssertEqual(recovered.flush(explicitTimeout: 2), .success)
        XCTAssertEqual(
            recording.recordedSpans.map(\.name),
            [oldest.name, newest.name]
        )
        recovered.disableAndPurge()
    }

    func testOversizedBatchDropsOldestSpansWithoutExceedingLimit()
        throws
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

        XCTAssertEqual(
            exporter.export(spans: [try makeRecordedSpan()]),
            .success
        )
        XCTAssertTrue(batchFiles(in: directory).isEmpty)
        exporter.disableAndPurge()
    }

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
        XCTAssertLessThan(elapsed, .milliseconds(100))
        pipeline.deactivate()
        pipeline.purge()
    }

    func testBackgroundStyleFlushReturnsAtItsDeadline() throws {
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
        pipeline.flush(timeout: 0.05)
        let elapsed = started.duration(to: .now)

        XCTAssertLessThan(elapsed, .milliseconds(250))
        pipeline.deactivate()
        pipeline.purge()
    }

    func testBackgroundFlushAttemptsOneDrainWhileBackgrounded() throws {
        let span = try makeRecordedSpan()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recording = RecordingSpanExporter()
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: recording,
            policy: .default
        )
        exporter.setForeground(false)
        XCTAssertEqual(exporter.export(spans: [span]), .success)

        XCTAssertEqual(
            exporter.flush(
                explicitTimeout: 2,
                allowWhileBackgrounded: true
            ),
            .success
        )
        XCTAssertEqual(recording.recordedSpans.map(\.name), [span.name])
        exporter.disableAndPurge()
    }

    func testWithdrawalCancelsAnActiveDownstreamExport() throws {
        let span = try makeRecordedSpan()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downstream = CancellableBlockingSpanExporter()
        let exporter = try BoundedPersistentSpanExporter(
            storageURL: directory,
            downstream: downstream,
            policy: .default
        )

        XCTAssertEqual(exporter.export(spans: [span]), .success)
        XCTAssertEqual(downstream.waitUntilStarted(timeout: 2), .success)
        exporter.disable()
        XCTAssertEqual(downstream.waitUntilFinished(timeout: 2), .success)

        XCTAssertTrue(downstream.recordedSpans.isEmpty)
        exporter.disableAndPurge()
    }

    func testWithdrawalStopsNewSpansAndPurgesRetainedData() throws {
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
        pipeline.flush(timeout: 2)
        XCTAssertFalse(batchFiles(in: directory).isEmpty)

        pipeline.deactivate()
        pipeline.purge()
        tracer.beginSpan(operation: .libraryRefresh).end(.succeeded)

        XCTAssertTrue(batchFiles(in: directory).isEmpty)
    }

    func testWithdrawalDuringActiveSpanCannotExportWithdrawnGeneration()
        throws
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
        pipeline.shutdown()

        XCTAssertTrue(recording.recordedSpans.isEmpty)
        XCTAssertTrue(batchFiles(in: directory).isEmpty)
    }

    func testRapidReenableExportsOnlyCleanGeneration() throws {
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
        current.flush(timeout: 2)
        withdrawn.shutdown()

        XCTAssertTrue(withdrawnExporter.recordedSpans.isEmpty)
        XCTAssertEqual(
            currentExporter.recordedSpans.map(\.name),
            [RemoteTelemetryOperation.libraryRefresh.rawValue]
        )
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
            operatingSystemPatchVersion: 0
        )
    }

    private func makeRecordedSpan(
        operation: RemoteTelemetryOperation = .appLaunch
    ) throws -> SpanData {
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
        pipeline.flush(timeout: 2)
        let span = try XCTUnwrap(recording.recordedSpans.first)
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

private final class RecordingSpanExporter:
    RemoteTelemetryDownstreamSpanExporter, @unchecked Sendable
{
    private let lock = NSLock()
    private var spans: [SpanData] = []
    private var sizes: [Int] = []
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

    func export(
        spans: [SpanData],
        explicitTimeout: TimeInterval?
    ) -> SpanExporterResultCode {
        if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        lock.withLock {
            self.spans.append(contentsOf: spans)
            sizes.append(spans.count)
        }
        return result
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        result
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

    func cancelActiveExports() {}
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

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        .success
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

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
