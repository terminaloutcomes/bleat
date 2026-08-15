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
}
