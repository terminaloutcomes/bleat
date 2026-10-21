import AVFoundation
import BleatCore
import XCTest

@testable import Bleat

#if DEBUG || BLEAT_UI_TESTING
    final class UITestPlaybackFixturesTests: XCTestCase {
        private let deviceInfo = PlaybackDeviceInfo(
            deviceID: "fixture-test", clientName: "Bleat",
            clientVersion: "test",
            manufacturer: "Apple", model: "Simulator")

        @MainActor
        func testSeparateJourneysDoNotShareDownloadStorage() async throws {
            let playback = UITestAppService(scenario: .playback)
            let browsing = UITestAppService(scenario: .signedIn)
            let playbackStorage = await playback.downloadsStorageRootURL
            let browsingStorage = await browsing.downloadsStorageRootURL
            let playbackRoot = try XCTUnwrap(playbackStorage)
            let browsingRoot = try XCTUnwrap(browsingStorage)
            XCTAssertNotEqual(playbackRoot, browsingRoot)
        }

        @MainActor
        func testBundledMediaIsPlayableAndMatchesTrackDurations() async throws {
            let fixtures = try UITestPlaybackFixtures()
            for (url, expectedDuration) in [
                (fixtures.hour, 3600.0), (fixtures.halfHour, 1800.0),
            ] {
                let asset = AVURLAsset(url: url)
                let (isPlayable, duration, tracks) = try await asset.load(
                    .isPlayable, .duration, .tracks)
                XCTAssertTrue(isPlayable)
                XCTAssertEqual(
                    duration.seconds, expectedDuration, accuracy: 0.15)
                XCTAssertEqual(tracks.count, 1)
            }
        }

        @MainActor
        func testPlaybackServiceUsesBundledMedia() async throws {
            let fixtures = try UITestPlaybackFixtures()
            for usesMultiFilePlayback in [false, true] {
                let service = UITestAppService(
                    scenario: .playback,
                    usesMultiFilePlayback: usesMultiFilePlayback)
                let accounts = try await service.accounts()
                let account = try XCTUnwrap(accounts.first)
                let preparation = try await service.openPlayback(
                    for: account, itemID: LibraryItemID(rawValue: "ui-book"),
                    preference: .directPlay, deviceInfo: deviceInfo)
                guard case .direct(let tracks) = preparation.source else {
                    XCTFail("Expected bundled direct playback")
                    return
                }
                XCTAssertEqual(tracks.count, usesMultiFilePlayback ? 2 : 1)
                XCTAssertEqual(preparation.duration, 3600)
                for (index, track) in tracks.enumerated() {
                    XCTAssertEqual(
                        track.url,
                        usesMultiFilePlayback
                            ? fixtures.halfHour : fixtures.hour)
                    XCTAssertEqual(track.startOffset, Double(index) * 1800)
                    let duration = try await AVURLAsset(url: track.url).load(
                        .duration)
                    XCTAssertEqual(
                        duration.seconds, track.duration, accuracy: 0.15)
                }
            }
        }

        @MainActor
        func testMissingBundleResourceKeepsTypedFailureThroughPlayback()
            async throws
        {
            let service = UITestAppService(
                scenario: .playback, bundle: Bundle(for: Self.self))
            let accounts = try await service.accounts()
            let account = try XCTUnwrap(accounts.first)
            do {
                _ = try await service.openPlayback(
                    for: account, itemID: LibraryItemID(rawValue: "ui-book"),
                    preference: .directPlay,
                    deviceInfo: deviceInfo
                )
                XCTFail("Missing bundled audio must reject playback")
            } catch {
                XCTAssertEqual(error, .playbackFixture(.missingResource(.hour)))
                let failure = AppFailure(
                    operation: .openPlayback, serviceError: error)
                XCTAssertEqual(
                    failure.cause, .playbackFixture(.missingResource(.hour)))
                XCTAssertEqual(
                    failure.diagnosticFailureCode, .playbackHourFixtureMissing)
                XCTAssertEqual(failure.playbackRecoveryAction, .dismiss)
                XCTAssertEqual(
                    failure.playbackPreparationDiagnosticStage,
                    .fixtureResourceLookup)
            }
        }

        func testMissingHalfHourResourceHasDistinctPresentationAndDiagnostic()
            throws
        {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "PlaybackFixtureTests-\(UUID().uuidString).bundle",
                    isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let directory = root.appendingPathComponent(
                "UIFixtures", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let fixtures = try UITestPlaybackFixtures()
            try FileManager.default.copyItem(
                at: fixtures.hour,
                to: directory.appendingPathComponent("playback-hour.m4a"))
            let bundle = try XCTUnwrap(Bundle(url: root))
            let missing: PlaybackFixtureFailure
            do {
                _ = try UITestPlaybackFixtures(bundle: bundle)
                XCTFail("Missing half-hour fixture must reject playback")
                return
            } catch {
                missing = error
            }
            XCTAssertEqual(missing, .missingResource(.halfHour))
            let failure = AppFailure(
                operation: .openPlayback,
                serviceError: .playbackFixture(missing))
            XCTAssertEqual(
                failure.cause, .playbackFixture(.missingResource(.halfHour)))
            XCTAssertEqual(
                failure.diagnosticFailureCode, .playbackHalfHourFixtureMissing)
            XCTAssertTrue(failure.message.contains("playback-half-hour.m4a"))
            XCTAssertEqual(failure.playbackRecoveryAction, .dismiss)
            XCTAssertEqual(
                failure.playbackPreparationDiagnosticStage,
                .fixtureResourceLookup)
        }
    }

#endif
