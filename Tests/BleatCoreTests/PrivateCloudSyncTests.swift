import Foundation
import XCTest
@testable import BleatCore

final class PrivateCloudSyncTests: XCTestCase {
    func testConfigurationSnapshotDefaultsHeadphoneCommands() async throws {
        let suite = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let store = try makeStore(suite: suite)

        let snapshot = await store.snapshot()

        XCTAssertEqual(snapshot.previousCommandAction, .skipBackward)
        XCTAssertEqual(snapshot.nextCommandAction, .skipForward)
    }

    func testConfigurationSnapshotRoundTripsHeadphoneCommands() async throws {
        let sourceSuite = makeSuite()
        let targetSuite = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: sourceSuite)
            UserDefaults.standard.removePersistentDomain(forName: targetSuite)
        }
        let source = try makeStore(suite: sourceSuite)
        let target = try makeStore(suite: targetSuite)
        try await source.apply(
            makeSnapshot(
                previousCommandAction: .previousChapter,
                nextCommandAction: .nextChapter
            )
        )

        let snapshot = await source.snapshot()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            CloudConfigurationSnapshot.self,
            from: encoded
        )
        try await target.apply(decoded)
        let restored = await target.snapshot()

        XCTAssertEqual(restored.previousCommandAction, .previousChapter)
        XCTAssertEqual(restored.nextCommandAction, .nextChapter)
    }

    func testLegacyConfigurationDefaultsMissingHeadphoneCommands() throws {
        let legacy = LegacyCloudConfigurationSnapshot(
            defaultPlaybackRate: 1.25,
            resumeRewindSeconds: 10,
            skipBackwardSeconds: 15,
            skipForwardSeconds: 30,
            downloadNetworkPolicy: "wifiOnly",
            automaticDownloadLookahead: 5,
            automaticDownloadCleanupPolicy: "afterTwentyFourHours"
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(
            CloudConfigurationSnapshot.self,
            from: data
        )

        XCTAssertEqual(decoded.previousCommandAction, .skipBackward)
        XCTAssertEqual(decoded.nextCommandAction, .skipForward)
    }

    func testConfigurationRejectsInvalidHeadphoneCommand() throws {
        let invalid = InvalidCloudConfigurationSnapshot(
            defaultPlaybackRate: 1,
            resumeRewindSeconds: 10,
            skipBackwardSeconds: 15,
            skipForwardSeconds: 30,
            previousCommandAction: "invalid",
            nextCommandAction: "skipForward",
            downloadNetworkPolicy: "wifiOnly",
            automaticDownloadLookahead: 5,
            automaticDownloadCleanupPolicy: "afterTwentyFourHours"
        )
        let data = try JSONEncoder().encode(invalid)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: data
            )
        )
    }

    private func makeSuite() -> String {
        "PrivateCloudSyncTests.\(UUID().uuidString)"
    }

    private func makeStore(
        suite: String
    ) throws -> CloudConfigurationStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return CloudConfigurationStore(defaults: defaults)
    }

    private func makeSnapshot(
        previousCommandAction: HeadphoneCommandAction,
        nextCommandAction: HeadphoneCommandAction
    ) -> CloudConfigurationSnapshot {
        CloudConfigurationSnapshot(
            defaultPlaybackRate: 1,
            resumeRewindSeconds: 10,
            skipBackwardSeconds: 15,
            skipForwardSeconds: 30,
            previousCommandAction: previousCommandAction,
            nextCommandAction: nextCommandAction,
            downloadNetworkPolicy: "wifiOnly",
            automaticDownloadLookahead: 5,
            automaticDownloadCleanupPolicy: "afterTwentyFourHours"
        )
    }
}

private struct LegacyCloudConfigurationSnapshot: Encodable {
    let defaultPlaybackRate: Double
    let resumeRewindSeconds: Int
    let skipBackwardSeconds: Int
    let skipForwardSeconds: Int
    let downloadNetworkPolicy: String
    let automaticDownloadLookahead: Int
    let automaticDownloadCleanupPolicy: String
}

private struct InvalidCloudConfigurationSnapshot: Encodable {
    let defaultPlaybackRate: Double
    let resumeRewindSeconds: Int
    let skipBackwardSeconds: Int
    let skipForwardSeconds: Int
    let previousCommandAction: String
    let nextCommandAction: String
    let downloadNetworkPolicy: String
    let automaticDownloadLookahead: Int
    let automaticDownloadCleanupPolicy: String
}
