import AVFoundation
import BleatCore
import BleatTranscription
import CloudKit
import MediaPlayer
import Observation
import SwiftData
import XCTest

@testable import Bleat

extension DownloadStorageLayout {
    fileprivate func placeCompleteTestFile(
        from temporaryURL: URL,
        identity: DownloadTaskIdentity
    ) throws -> Int64 {
        _ = try appendChunk(
            from: temporaryURL,
            identity: identity,
            expectedOffset: 0,
            expectedChunkLength: identity.expectedByteLength
        )
        return try finalizePartial(identity)
    }
}

#if os(iOS)
    import UIKit
#endif

#if os(iOS) && canImport(CarPlay)
    import CarPlay
#endif

@MainActor
final class AppModelTests: XCTestCase {
    func testDownloadTransferAdmissionEnforcesAndReconcilesGlobalLimit() throws {
        for limit in [1, 5, 100] {
            var admission = DownloadTransferAdmissionController(limit: limit)
            let admitted = (0..<limit).map { _ in UUID() }
            for transferID in admitted {
                XCTAssertTrue(admission.admit(transferID))
            }
            XCTAssertFalse(admission.admit(UUID()))
            XCTAssertEqual(admission.activeTransferIDs.count, limit)
        }

        let restoredIDs = (0..<5).map { _ in UUID() }
        let restored = Set(restoredIDs)
        var admission = DownloadTransferAdmissionController(limit: 5)
        admission.reconcile(activeTransferIDs: restored)
        admission.updateLimit(1)
        XCTAssertEqual(admission.activeTransferIDs, restored)
        XCTAssertFalse(admission.admit(UUID()))
        for transferID in restoredIDs.dropLast() {
            admission.complete(transferID)
            XCTAssertFalse(admission.admit(UUID()))
        }
        admission.complete(try XCTUnwrap(restoredIDs.last))
        XCTAssertTrue(admission.admit(UUID()))

        admission.updateLimit(5)
        for _ in 0..<4 {
            XCTAssertTrue(admission.admit(UUID()))
        }
        XCTAssertEqual(admission.activeTransferIDs.count, 5)
    }

    func testSystemSettingsBundleUsesExactMaximumDownloadValues() throws {
        let settingsBundle = try XCTUnwrap(
            Bundle.main.url(
                forResource: "Settings",
                withExtension: "bundle"
            )
        )
        let root = settingsBundle.appendingPathComponent("Root.plist")
        let data = try Data(contentsOf: root)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        let specifiers = try XCTUnwrap(
            plist["PreferenceSpecifiers"] as? [[String: Any]]
        )
        let maximum = try XCTUnwrap(
            specifiers.first {
                $0["Key"] as? String
                    == MaximumConcurrentDownloadsPreference.defaultsKey
            }
        )

        XCTAssertEqual(maximum["Type"] as? String, "PSMultiValueSpecifier")
        XCTAssertEqual(maximum["DefaultValue"] as? Int, 5)
        XCTAssertEqual(
            maximum["Values"] as? [Int],
            MaximumConcurrentDownloadsPreference.permittedValues
        )
        XCTAssertEqual(
            maximum["Titles"] as? [String],
            MaximumConcurrentDownloadsPreference.permittedValues.map(String.init)
        )
    }

    func testDownloadModelQueuesAndAdmitsBooksAtConfiguredMaximum()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GlobalDownloadAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        let suite = "GlobalDownloadAdmission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlanProvider: { itemID in
                .success(
                    DownloadPlan(
                        itemID: itemID,
                        tracks: [
                            DownloadTrackPlan(
                                index: 0,
                                inode: "audio-\(itemID.rawValue)",
                                expectedByteLength: 1,
                                mimeType: "audio/mpeg",
                                safeExtension: .mp3,
                                destinationEntry: "00000.mp3"
                            )
                        ]
                    )
                )
            },
            authorizedDownloadRequest: .success(
                URLRequest(
                    url: try XCTUnwrap(
                        URL(string: "https://192.0.2.1/audio.mp3")
                    )
                )
            )
        )
        let model = DownloadModel(
            service: service,
            defaults: defaults,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.global-admission.\(UUID().uuidString)"
        )
        await model.start(account: account)
        model.setMaximumConcurrentDownloads(1)
        let details = (0..<3).map { index in
            fixtureBookDetail(
                item: fixtureBook(
                    id: "global-admission-\(index)",
                    title: "Global Admission \(index)",
                    libraryID: fixtureLibrary().id
                )
            )
        }

        for detail in details {
            await model.download(detail: detail, account: account)
        }

        XCTAssertEqual(model.records.count, 3)
        var descriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(descriptors.count, 1)

        model.setMaximumConcurrentDownloads(5)
        for _ in 0..<20 where descriptors.count != 3 {
            try await Task.sleep(for: .milliseconds(100))
            descriptors =
                await model.scheduledTransferDescriptorsForTesting()
        }
        XCTAssertEqual(descriptors.count, 3)

        model.setMaximumConcurrentDownloads(1)
        descriptors = await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(descriptors.count, 3)
        _ = await model.removeAllForLocalDataReset()
    }

    func testPlaybackSuspensionReleasesCapacityWithoutOverResuming()
        async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PlaybackSuspensionAdmission-\(UUID().uuidString)",
            isDirectory: true
        )
        let suite = "PlaybackSuspensionAdmission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let account = try fixtureAccount()
        let automaticDetail = fixtureBookDetail(
            item: fixtureBook(
                id: "automatic-admission",
                title: "Automatic Admission",
                libraryID: fixtureLibrary().id
            )
        )
        let manualDetail = fixtureBookDetail(
            item: fixtureBook(
                id: "manual-admission",
                title: "Manual Admission",
                libraryID: fixtureLibrary().id
            )
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlanProvider: { itemID in
                .success(
                    DownloadPlan(
                        itemID: itemID,
                        tracks: [
                            DownloadTrackPlan(
                                index: 0,
                                inode: "audio-\(itemID.rawValue)",
                                expectedByteLength: 1,
                                mimeType: "audio/mpeg",
                                safeExtension: .mp3,
                                destinationEntry: "00000.mp3"
                            )
                        ]
                    )
                )
            },
            authorizedDownloadRequest: .success(
                URLRequest(
                    url: try XCTUnwrap(
                        URL(string: "https://192.0.2.1/audio.mp3")
                    )
                )
            )
        )
        let model = DownloadModel(
            service: service,
            defaults: defaults,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.playback-suspension.\(UUID().uuidString)"
        )
        model.setNetworkPolicy(.allowCellular)
        model.setMaximumConcurrentDownloads(1)

        let automaticActivity = AutomaticDownloadActivity(
            kind: .progress,
            detail: automaticDetail,
            account: account,
            currentTime: 0,
            chapters: [],
            fileRanges: [
                AutomaticDownloadFileRange(
                    index: 0,
                    start: 0,
                    end: automaticDetail.duration
                )
            ]
        )
        await model.handleAutomaticPlaybackActivity(automaticActivity)
        XCTAssertEqual(model.activeTransferAdmissionCountForTesting, 1)

        await model.handleAutomaticPlaybackActivity(
            AutomaticDownloadActivity(
                kind: .playbackNeedsBandwidth,
                detail: automaticDetail,
                account: account,
                currentTime: 0,
                chapters: [],
                fileRanges: automaticActivity.fileRanges
            )
        )
        XCTAssertEqual(model.activeTransferAdmissionCountForTesting, 0)

        await model.download(detail: manualDetail, account: account)
        XCTAssertEqual(model.activeTransferAdmissionCountForTesting, 1)
        let scheduledDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(scheduledDescriptors.count, 2)

        await model.handleAutomaticPlaybackActivity(
            AutomaticDownloadActivity(
                kind: .playbackReleasedBandwidth,
                detail: automaticDetail,
                account: account,
                currentTime: 0,
                chapters: [],
                fileRanges: automaticActivity.fileRanges
            )
        )
        XCTAssertEqual(model.activeTransferAdmissionCountForTesting, 1)
        _ = await model.removeAllForLocalDataReset()
    }

    private func backgroundSessionIdentifier(_ purpose: String) -> String {
        "bleat.tests.\(purpose).\(UUID().uuidString)"
    }

    func testTransferReconciliationStopsLatePauseAndCancelCallbacks() {
        let active = DownloadTransferContext(
            isPaused: false,
            isCancelled: false,
            isDeleting: false,
            isSuperseded: false,
            isAutomatic: false
        )
        let paused = DownloadTransferContext(
            isPaused: true,
            isCancelled: false,
            isDeleting: false,
            isSuperseded: false,
            isAutomatic: false
        )
        let cancelled = DownloadTransferContext(
            isPaused: false,
            isCancelled: true,
            isDeleting: false,
            isSuperseded: false,
            isAutomatic: false
        )
        let superseded = DownloadTransferContext(
            isPaused: false,
            isCancelled: false,
            isDeleting: false,
            isSuperseded: true,
            isAutomatic: true
        )

        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .retryableFailure,
                context: active
            ),
            .retry
        )
        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .terminalFailure,
                context: active
            ),
            .fail
        )
        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .retryableFailure,
                context: paused
            ),
            .stop
        )
        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .terminalFailure,
                context: paused
            ),
            .stop
        )
        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .chunkStored(finalized: false),
                context: cancelled
            ),
            .stop
        )
        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .chunkStored(finalized: true),
                context: superseded
            ),
            .stop
        )
        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .terminalFailure,
                context: cancelled
            ),
            .stop
        )
        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .terminalFailure,
                context: superseded
            ),
            .stop
        )
    }

    func testTransferReconciliationAdvancesFinalizedAutomaticDownload() {
        let automatic = DownloadTransferContext(
            isPaused: false,
            isCancelled: false,
            isDeleting: false,
            isSuperseded: false,
            isAutomatic: true
        )

        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .chunkStored(finalized: true),
                context: automatic
            ),
            .advanceAutomaticDownload
        )
        XCTAssertEqual(
            DownloadTransferReconciler.nextAction(
                after: .chunkStored(finalized: false),
                context: automatic
            ),
            .continueChunk
        )
    }

    #if os(iOS)
        func testPlatformImagePixelSizeIncludesUIImageScale() throws {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(
                size: CGSize(width: 2, height: 3),
                format: format
            ).image { _ in }
            let cgImage = try XCTUnwrap(rendered.cgImage)
            let image = UIImage(cgImage: cgImage, scale: 3, orientation: .up)

            XCTAssertEqual(
                PlatformImageSupport.pixelSize(of: image),
                CGSize(width: 2, height: 3)
            )
        }
    #endif

    func testPlaybackPreparationAndStartEmitReviewedTelemetry() async throws {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let tracer = RecordingRemoteTelemetryTracer()
        let activation = TestAudioSessionActivation()
        let playback = PlaybackModel(
            service: TestAppService(activeAccount: .success(nil)),
            audioSessionActivation: {
                activation.activate()
            },
            remoteTelemetryTracer: tracer
        )

        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL],
            accountID: AccountID(rawValue: "private-account"),
            account: nil
        )
        playback.pause()

        XCTAssertEqual(
            tracer.spans,
            [
                RecordedRemoteTelemetrySpan(
                    operation: .playbackPreparation,
                    source: .downloaded,
                    retryBucket: .none,
                    outcome: .succeeded
                ),
                RecordedRemoteTelemetrySpan(
                    operation: .playbackStart,
                    source: .downloaded,
                    retryBucket: .none,
                    outcome: .cancelled
                ),
            ]
        )
    }

    func testPlaybackPreparationFailureEmitsTypedMediaCategory()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let tracer = RecordingRemoteTelemetryTracer()
        let playback = PlaybackModel(
            service: TestAppService(activeAccount: .success(nil)),
            remoteTelemetryTracer: tracer
        )

        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [],
            accountID: AccountID(rawValue: "private-account"),
            account: nil
        )

        XCTAssertEqual(
            tracer.spans,
            [
                RecordedRemoteTelemetrySpan(
                    operation: .playbackPreparation,
                    source: .downloaded,
                    retryBucket: .none,
                    outcome: .failed(.media)
                )
            ]
        )
    }

    func testRemotePlaybackProgressSyncEmitsOneTypedAttempt()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let account = try fixtureAccount()
        let preparation = AppPlaybackPreparation(
            sessionID: PlaybackSessionID(rawValue: "private-session"),
            itemID: fixture.detail.id,
            title: fixture.detail.title,
            duration: 1,
            currentTime: 0,
            chapters: fixture.detail.chapters,
            source: .direct([
                AppPlaybackTrack(
                    url: fixture.audioURL,
                    startOffset: 0,
                    duration: 1,
                    title: "Private track"
                )
            ])
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [.success(preparation)]
        )
        let tracer = RecordingRemoteTelemetryTracer()
        let playback = fixture.model(
            activation: TestAudioSessionActivation(),
            service: service,
            remoteTelemetryTracer: tracer
        )

        await playback.start(detail: fixture.detail, account: account)
        playback.pause()
        for _ in 0..<100
        where !tracer.spans.contains(where: {
            $0.operation == .playbackProgressSync
                && $0.outcome != nil
        }) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            tracer.spans.filter {
                $0.operation == .playbackProgressSync
            },
            [
                RecordedRemoteTelemetrySpan(
                    operation: .playbackProgressSync,
                    source: .remote,
                    retryBucket: .none,
                    outcome: .succeeded
                )
            ]
        )
        await playback.stop()
    }

    func testManualDownloadSchedulingAndCancellationEmitTaskSpans()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatTelemetryDownload-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: plan.itemID.rawValue,
                title: "Private title",
                libraryID: fixtureLibrary().id
            )
        )
        let request = URLRequest(
            url: try XCTUnwrap(
                URL(string: "https://192.0.2.1/private-audio")
            )
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .success(plan),
            authorizedDownloadRequest: .success(request)
        )
        let tracer = RecordingRemoteTelemetryTracer()
        let logger = RecordingRemoteTelemetryDownloadLogger()
        let downloads = DownloadModel(
            service: service,
            storageRootURL: root,
            remoteTelemetryTracer: tracer,
            remoteTelemetryDownloadLogger: logger,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("telemetry-download")
        )

        await downloads.download(detail: detail, account: account)
        let scheduled = await downloads.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(scheduled.count, 1)
        XCTAssertEqual(scheduled.first?.identity.trackIndex, 0)
        let record = try XCTUnwrap(downloads.records.first)
        await downloads.cancel(record)

        XCTAssertEqual(
            tracer.spans,
            [
                RecordedRemoteTelemetrySpan(
                    operation: .downloadTransfer,
                    source: .remote,
                    retryBucket: .none,
                    outcome: .cancelled
                )
            ]
        )
        XCTAssertEqual(logger.events.count, 2)
        XCTAssertEqual(logger.events.first?.stage, .taskScheduled)
        XCTAssertEqual(logger.events.first?.state, .started)
        XCTAssertEqual(logger.events.last?.stage, .taskCompletion)
        XCTAssertEqual(logger.events.last?.state, .cancelled)
    }

    func testQueuedDownloadIsPresentedAsWaitingToDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatWaitingDownload-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: plan.itemID.rawValue,
                title: "Waiting download",
                libraryID: fixtureLibrary().id
            )
        )
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        _ = try await storage.create(
            downloadID: DownloadID(rawValue: "waiting-download"),
            accountID: account.id,
            plan: plan,
            detail: detail
        )
        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(nil)),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.waiting-download.\(UUID().uuidString)"
        )

        await model.start(account: nil)

        let record = try XCTUnwrap(model.records.first)
        XCTAssertEqual(
            model.controlSnapshot(for: record),
            DownloadControlSnapshot(
                phase: .waitingToDownload,
                actions: [.pause, .cancel]
            )
        )
        await model.removeAll()
    }

    func testPlayableCoverStateUsesExactAccountAndItemIdentity() {
        let account = AccountID(rawValue: "account-1")
        let otherAccount = AccountID(rawValue: "account-2")
        let item = LibraryItemID(rawValue: "item-1")
        let otherItem = LibraryItemID(rawValue: "item-2")
        let target = PlaybackStartTarget(
            accountID: account,
            itemID: item
        )

        XCTAssertEqual(
            PlayableBookCoverState.derive(
                target: target,
                accountID: account,
                itemID: item,
                playbackAccountID: nil,
                playbackItemID: nil,
                playbackState: .idle,
                isPlaybackRequested: false
            ),
            .preparing
        )
        XCTAssertEqual(
            PlayableBookCoverState.derive(
                target: target,
                accountID: otherAccount,
                itemID: item,
                playbackAccountID: account,
                playbackItemID: item,
                playbackState: .playing,
                isPlaybackRequested: true
            ),
            .idle
        )
        XCTAssertEqual(
            PlayableBookCoverState.derive(
                target: nil,
                accountID: account,
                itemID: otherItem,
                playbackAccountID: account,
                playbackItemID: item,
                playbackState: .playing,
                isPlaybackRequested: true
            ),
            .idle
        )
    }

    func testPlayableCoverStateMapsTypedPlaybackStates() {
        let account = AccountID(rawValue: "account-1")
        let item = LibraryItemID(rawValue: "item-1")
        func state(
            _ playbackState: PlaybackState,
            requested: Bool
        ) -> PlayableBookCoverState {
            PlayableBookCoverState.derive(
                target: nil,
                accountID: account,
                itemID: item,
                playbackAccountID: account,
                playbackItemID: item,
                playbackState: playbackState,
                isPlaybackRequested: requested
            )
        }

        XCTAssertEqual(state(.preparing, requested: true), .preparing)
        XCTAssertEqual(state(.ready, requested: true), .playing)
        XCTAssertEqual(state(.buffering, requested: true), .playing)
        XCTAssertEqual(state(.playing, requested: true), .playing)
        XCTAssertEqual(state(.paused, requested: false), .paused)
        XCTAssertEqual(state(.ready, requested: false), .paused)
        XCTAssertEqual(state(.ended, requested: false), .idle)
        XCTAssertEqual(
            state(.failed(.mediaUnavailable), requested: true), .idle)
    }

    func testPlaybackStartOutcomePresentsOnlyTypedFailures() {
        XCTAssertNil(
            PlaybackStartOutcome.started(source: .streamed)
                .presentationFailure
        )
        XCTAssertNil(PlaybackStartOutcome.superseded.presentationFailure)
        XCTAssertEqual(
            PlaybackStartOutcome.failed(.mediaUnavailable)
                .presentationFailure,
            .mediaUnavailable
        )
    }

    func testBrowsingPlaybackActionPausesOnlyExactRequestedIdentity()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let account = try fixtureAccount()
        let otherAccount = try fixtureAccount(accountID: "account-2")
        let detail = fixture.detail
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [
                .success(
                    playbackPreparation(
                        detail: detail,
                        audioURL: fixture.audioURL
                    )
                )
            ]
        )
        let model = AppModel(service: service)
        await model.start()
        let initialOutcome = await model.startPlayback(
            detail: detail,
            account: account
        )
        XCTAssertEqual(initialOutcome, .started(source: .streamed))

        let mismatchedOutcome = await model.performBrowsingPlaybackAction(
            book: detail.summary,
            account: otherAccount
        )
        XCTAssertEqual(
            mismatchedOutcome,
            .start(
                .failed(
                    AppFailure(.openPlayback, .accountUnavailable)
                )
            )
        )
        XCTAssertTrue(model.playback.isPlaybackRequested)

        let matchingOutcome = await model.performBrowsingPlaybackAction(
            book: detail.summary,
            account: account
        )
        XCTAssertEqual(matchingOutcome, .paused)
        XCTAssertFalse(model.playback.isPlaybackRequested)
        await model.playback.stop()
    }

    func testDownloadByteProgressUsesOneSharedRoundedUnit() {
        XCTAssertEqual(
            DownloadByteProgressFormatter.string(
                downloadedBytes: 494_800_000,
                expectedBytes: 655_500_000
            ),
            "495/656 MB"
        )
    }

    func testDownloadByteProgressUsesExpectedSizeUnit() {
        XCTAssertEqual(
            DownloadByteProgressFormatter.string(
                downloadedBytes: 600_000_000,
                expectedBytes: 1_200_000_000
            ),
            "0.6/1.2 GB"
        )
    }

    func testChapterAudioSlicePlannerMapsChapterAcrossTracks() throws {
        let chapter = PlaybackChapter(
            id: 7,
            start: 50,
            end: 130,
            title: "Across files"
        )

        XCTAssertEqual(
            try ChapterAudioSlicePlanner.slices(
                for: chapter,
                trackDurations: [60, 50, 40]
            ),
            [
                ChapterAudioSlice(
                    trackIndex: 0,
                    audioStartSeconds: 50,
                    durationSeconds: 10,
                    wholeBookStartSeconds: 50
                ),
                ChapterAudioSlice(
                    trackIndex: 1,
                    audioStartSeconds: 0,
                    durationSeconds: 50,
                    wholeBookStartSeconds: 60
                ),
                ChapterAudioSlice(
                    trackIndex: 2,
                    audioStartSeconds: 0,
                    durationSeconds: 20,
                    wholeBookStartSeconds: 110
                ),
            ]
        )
    }

    func testChapterAudioSlicePlannerRejectsIncompleteLocalAudio() {
        XCTAssertThrowsError(
            try ChapterAudioSlicePlanner.slices(
                for: PlaybackChapter(
                    id: 1,
                    start: 50,
                    end: 130,
                    title: "Missing end"
                ),
                trackDurations: [60]
            )
        ) { error in
            XCTAssertEqual(
                error as? ChapterAudioSlicePlanFailure,
                .incompleteChapterCoverage
            )
        }
    }

    func testChapterAudioSlicePlannerUsesOneDownloadedChapterFile() throws {
        XCTAssertEqual(
            try ChapterAudioSlicePlanner.slices(
                for: PlaybackChapter(
                    id: 2,
                    start: 70,
                    end: 90,
                    title: "Downloaded chapter"
                ),
                tracks: [
                    ChapterAudioTrack(
                        trackIndex: 4,
                        startOffsetSeconds: 60,
                        durationSeconds: 60
                    )
                ]
            ),
            [
                ChapterAudioSlice(
                    trackIndex: 4,
                    audioStartSeconds: 10,
                    durationSeconds: 20,
                    wholeBookStartSeconds: 70
                )
            ]
        )
    }

    func testChapterTranscriptionBatchPlannerUsesBookChapterOrder() {
        let chapters = [
            PlaybackChapter(id: 9, start: 0, end: 10, title: "Nine"),
            PlaybackChapter(id: 2, start: 10, end: 20, title: "Two"),
            PlaybackChapter(id: 7, start: 20, end: 30, title: "Seven"),
            PlaybackChapter(id: 1, start: 30, end: 40, title: "One"),
        ]

        XCTAssertEqual(
            ChapterTranscriptionBatchPlanner.orderedChapters(
                selectedChapterIDs: [1, 9, 7],
                from: chapters
            ).map(\.id),
            [1, 7, 9]
        )
    }

    func testTranscriptPositionResolverRejectsInvalidOrUncoveredPosition() {
        let chapters = [
            PlaybackChapter(id: 1, start: 0, end: 10, title: "One")
        ]

        XCTAssertEqual(
            ChapterTranscriptPositionResolver.resolve(
                position: .nan,
                chapters: chapters,
                transcripts: []
            ),
            .invalidPosition
        )
        XCTAssertEqual(
            ChapterTranscriptPositionResolver.resolve(
                position: -1,
                chapters: chapters,
                transcripts: []
            ),
            .invalidPosition
        )
        XCTAssertEqual(
            ChapterTranscriptPositionResolver.resolve(
                position: 10,
                chapters: chapters,
                transcripts: []
            ),
            .invalidPosition
        )
    }

    func testTranscriptPositionResolverRequiresContainingChapterTranscript() {
        let chapters = [
            PlaybackChapter(id: 1, start: 0, end: 10, title: "One"),
            PlaybackChapter(id: 2, start: 10, end: 20, title: "Two"),
        ]
        let unrelatedTranscript = fixtureTranscript(
            chapter: chapters[1],
            segments: [
                CachedTranscriptSegment(
                    startMilliseconds: 10_000,
                    endMilliseconds: 11_000,
                    text: "Unrelated"
                )
            ]
        )

        XCTAssertEqual(
            ChapterTranscriptPositionResolver.resolve(
                position: 5,
                chapters: chapters,
                transcripts: [unrelatedTranscript]
            ),
            .chapterNotTranscribed(chapterID: 1)
        )
    }

    func testTranscriptPositionResolverReportsNoSpeechInContainingChapter() {
        let chapter = PlaybackChapter(
            id: 1,
            start: 0,
            end: 10,
            title: "One"
        )

        XCTAssertEqual(
            ChapterTranscriptPositionResolver.resolve(
                position: 5,
                chapters: [chapter],
                transcripts: [fixtureTranscript(chapter: chapter, segments: [])]
            ),
            .noSpeechDetected(chapterID: 1)
        )
    }

    func testTranscriptPositionResolverIncludesZeroDurationSegment() {
        let chapters = [
            PlaybackChapter(id: 1, start: 0, end: 10, title: "One"),
            PlaybackChapter(id: 2, start: 10, end: 20, title: "Two"),
        ]
        let transcripts = [
            fixtureTranscript(
                chapter: chapters[0],
                segments: [
                    CachedTranscriptSegment(
                        startMilliseconds: 5_000,
                        endMilliseconds: 5_000,
                        text: "Point in time"
                    )
                ]
            ),
            fixtureTranscript(
                chapter: chapters[1],
                segments: [
                    CachedTranscriptSegment(
                        startMilliseconds: 10_000,
                        endMilliseconds: 11_000,
                        text: "Other chapter"
                    )
                ]
            ),
        ]

        XCTAssertEqual(
            ChapterTranscriptPositionResolver.resolve(
                position: 5,
                chapters: chapters,
                transcripts: transcripts
            ),
            .target(
                ChapterTranscriptNavigationTarget(
                    chapterID: 1,
                    segmentIndex: 0,
                    startMilliseconds: 5_000,
                    endMilliseconds: 5_000
                )
            )
        )
    }

    func testTranscriptPositionResolverChoosesNearestAcrossChapterBoundary() {
        let chapters = [
            PlaybackChapter(id: 1, start: 0, end: 10, title: "One"),
            PlaybackChapter(id: 2, start: 10, end: 20, title: "Two"),
        ]
        let transcripts = [
            fixtureTranscript(
                chapter: chapters[0],
                segments: [
                    CachedTranscriptSegment(
                        startMilliseconds: 9_000,
                        endMilliseconds: 9_800,
                        text: "Before"
                    )
                ]
            ),
            fixtureTranscript(
                chapter: chapters[1],
                segments: [
                    CachedTranscriptSegment(
                        startMilliseconds: 10_000,
                        endMilliseconds: 11_000,
                        text: "After"
                    )
                ]
            ),
        ]

        XCTAssertEqual(
            ChapterTranscriptPositionResolver.resolve(
                position: 9.5,
                chapters: chapters,
                transcripts: transcripts
            ),
            .target(
                ChapterTranscriptNavigationTarget(
                    chapterID: 1,
                    segmentIndex: 0,
                    startMilliseconds: 9_000,
                    endMilliseconds: 9_800
                )
            )
        )
        XCTAssertEqual(
            ChapterTranscriptPositionResolver.resolve(
                position: 9.95,
                chapters: chapters,
                transcripts: transcripts
            ),
            .target(
                ChapterTranscriptNavigationTarget(
                    chapterID: 2,
                    segmentIndex: 0,
                    startMilliseconds: 10_000,
                    endMilliseconds: 11_000
                )
            )
        )
        XCTAssertEqual(
            ChapterTranscriptPositionResolver.resolve(
                position: 9.9,
                chapters: chapters,
                transcripts: transcripts
            ),
            .target(
                ChapterTranscriptNavigationTarget(
                    chapterID: 1,
                    segmentIndex: 0,
                    startMilliseconds: 9_000,
                    endMilliseconds: 9_800
                )
            )
        )
    }

    func testTranscriptPositionResolutionUsesOnlyRequestedBookCache()
        async throws
    {
        let account = try fixtureAccount()
        let otherAccount = try fixtureAccount(accountID: "other-account")
        let chapter = PlaybackChapter(
            id: 1,
            start: 0,
            end: 10,
            title: "One"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "scoped-transcript",
                title: "Scoped",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoad: .success([
                fixtureTranscript(chapter: chapter, text: "Scoped")
            ])
        )
        let appModel = AppModel(service: service)
        await appModel.transcription.loadCachedTranscripts(
            detail: detail,
            account: account,
            appModel: appModel
        )

        XCTAssertEqual(
            appModel.transcription.resolveTranscriptPosition(
                0.5,
                detail: detail,
                account: account
            ),
            .target(
                ChapterTranscriptNavigationTarget(
                    chapterID: 1,
                    segmentIndex: 0,
                    startMilliseconds: 0,
                    endMilliseconds: 1_000
                )
            )
        )
        XCTAssertEqual(
            appModel.transcription.resolveTranscriptPosition(
                0.5,
                detail: detail,
                account: otherAccount
            ),
            .chapterNotTranscribed(chapterID: 1)
        )
    }

    func testChapterTranscriptionViewUsesAppOwnedCoordinator() throws {
        let appModel = AppModel(
            service: TestAppService(activeAccount: .success(nil))
        )
        let item = fixtureBook(
            id: "item-1",
            title: "A Book",
            libraryID: fixtureLibrary().id
        )
        let view = ChapterTranscriptionView(
            detail: fixtureBookDetail(item: item),
            account: try fixtureAccount(),
            appModel: appModel,
            downloads: appModel.downloads
        )

        XCTAssertTrue(view.model === appModel.transcription)
    }

    func testTranscriptionBatchSkipsChaptersWithCachedTranscripts()
        async throws
    {
        let account = try fixtureAccount()
        let cachedChapter = PlaybackChapter(
            id: 1,
            start: 0,
            end: 20,
            title: "Already Transcribed"
        )
        let pendingChapter = PlaybackChapter(
            id: 2,
            start: 20,
            end: 40,
            title: "Needs Transcription"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-skip-cached",
                title: "Skip Cached",
                libraryID: fixtureLibrary().id
            ),
            chapters: [cachedChapter, pendingChapter]
        )
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoad: .success([
                fixtureTranscript(
                    chapter: cachedChapter,
                    text: "existing transcript"
                )
            ])
        )
        let recorder = ChapterTranscriptionRequestRecorder()
        let coordinator = makeTranscriptionModel(requestRecorder: recorder)
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )

        await coordinator.loadCachedTranscripts(
            detail: detail,
            account: account,
            appModel: appModel
        )
        XCTAssertTrue(coordinator.hasLoadedTranscriptCache(for: bookKey))
        XCTAssertEqual(
            coordinator.chaptersNeedingTranscription(
                detail.chapters,
                for: bookKey
            ).map(\.id),
            [pendingChapter.id]
        )

        coordinator.start(
            chapters: detail.chapters,
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )

        let loadedTerminalState = await waitForTranscriptionTerminalState(
            in: coordinator,
            bookKey: bookKey
        )
        let terminalState = try XCTUnwrap(loadedTerminalState)
        XCTAssertEqual(terminalState.selectedChapterIDs, [pendingChapter.id])
        XCTAssertEqual(terminalState.completedChapterIDs, [pendingChapter.id])
        let requests = await recorder.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.chapterStartSeconds, 20)
        XCTAssertEqual(
            coordinator.searchResults(
                query: "existing transcript",
                for: bookKey
            ).count,
            1
        )
    }

    func testTranscriptionBatchDoesNotStartWhenEveryChapterIsCached()
        async throws
    {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 1,
            start: 0,
            end: 20,
            title: "Already Transcribed"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-all-cached",
                title: "All Cached",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoad: .success([
                fixtureTranscript(chapter: chapter, text: "existing")
            ])
        )
        let recorder = ChapterTranscriptionRequestRecorder()
        let coordinator = makeTranscriptionModel(requestRecorder: recorder)
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )

        await coordinator.loadCachedTranscripts(
            detail: detail,
            account: account,
            appModel: appModel
        )
        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )

        XCTAssertFalse(coordinator.isWorking)
        let requests = await recorder.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testChapterTranscriptionFailuresMapToTypedPersistentFailures() {
        XCTAssertEqual(
            ChapterTranscriptionViewFailure.audioNotDownloaded
                .cachedTaskFailure,
            .audioNotDownloaded
        )
        XCTAssertEqual(
            ChapterTranscriptionViewFailure.transcription(
                .analyzerInputFailed(
                    ChapterTranscriptionDiagnostic(
                        domain: "SFSpeechErrorDomain",
                        code: 2
                    )
                )
            ).cachedTaskFailure,
            .analyzerInputFailed
        )
        XCTAssertEqual(
            ChapterTranscriptionViewFailure.transcription(
                .audioFileUnreadable("private filename.m4b")
            ).cachedTaskFailure,
            .audioFileUnreadable
        )
    }

    func testLateTranscriptLoadCannotReplaceNewerBatchResult() async throws {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 9,
            start: 0,
            end: 20,
            title: "Chapter Nine"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-load-race",
                title: "Load Race",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let staleTaskState = fixtureTranscriptionTaskState(
            chapterIDs: [chapter.id],
            completedChapterIDs: [],
            outcome: .failed,
            failure: .localAudioUnavailable
        )
        let loadGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoadGate: loadGate,
            transcriptLoad: .success([
                fixtureTranscript(chapter: chapter, text: "stale text")
            ]),
            transcriptionTaskStateLoad: .success(staleTaskState)
        )
        let coordinator = makeTranscriptionModel(
            segments: [
                TranscriptSegment(
                    startMilliseconds: 1_000,
                    endMilliseconds: 2_000,
                    text: "new text"
                )
            ]
        )
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )

        let load = Task { @MainActor in
            await coordinator.loadCachedTranscripts(
                detail: detail,
                account: account,
                appModel: appModel
            )
        }
        await loadGate.waitUntilEntered()
        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        let completed = await waitForTranscriptionTerminalState(
            in: coordinator,
            bookKey: bookKey
        )
        XCTAssertEqual(completed?.outcome, .succeeded)
        let completedTaskID = completed?.taskID

        await loadGate.release()
        await load.value

        XCTAssertEqual(
            coordinator.searchResults(query: "new text", for: bookKey).count,
            1
        )
        XCTAssertTrue(
            coordinator.searchResults(query: "stale text", for: bookKey)
                .isEmpty
        )
        XCTAssertEqual(
            coordinator.terminalState(for: bookKey)?.taskID,
            completedTaskID
        )
        XCTAssertEqual(
            coordinator.terminalState(for: bookKey)?.outcome,
            .succeeded
        )
    }

    func testCancellationAfterSuccessfulSaveKeepsCompletedChapter()
        async throws
    {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 3,
            start: 0,
            end: 20,
            title: "Chapter Three"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-cancel-save",
                title: "Cancel Save",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let saveGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptSaveGate: saveGate
        )
        let coordinator = makeTranscriptionModel(
            segments: [
                TranscriptSegment(
                    startMilliseconds: 500,
                    endMilliseconds: 1_500,
                    text: "saved before cancellation"
                )
            ]
        )
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )

        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        await saveGate.waitUntilEntered()
        coordinator.cancel()
        XCTAssertTrue(coordinator.isCancelling(for: bookKey))
        await saveGate.release()

        let loadedTerminalState = await waitForTranscriptionTerminalState(
            in: coordinator,
            bookKey: bookKey
        )
        let terminalState = try XCTUnwrap(loadedTerminalState)
        XCTAssertEqual(terminalState.outcome, .cancelled)
        XCTAssertEqual(terminalState.completedChapterIDs, [chapter.id])
        XCTAssertTrue(coordinator.isCached(chapterID: chapter.id, for: bookKey))
        XCTAssertEqual(
            coordinator.searchResults(
                query: "SAVED BEFORE CANCELLATION",
                for: bookKey
            ).count,
            1
        )
    }

    func testLateTranscriptLoadErrorCannotReplaceNewerBatchResult()
        async throws
    {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 11,
            start: 0,
            end: 20,
            title: "Chapter Eleven"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-load-error-race",
                title: "Load Error Race",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let loadGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoadGate: loadGate,
            transcriptLoad: .failure(
                .transcriptCache(.persistenceFailed)
            )
        )
        let coordinator = makeTranscriptionModel()
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )
        let load = Task { @MainActor in
            await coordinator.loadCachedTranscripts(
                detail: detail,
                account: account,
                appModel: appModel
            )
        }
        await loadGate.waitUntilEntered()

        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        let terminalState = await waitForTranscriptionTerminalState(
            in: coordinator,
            bookKey: bookKey
        )
        XCTAssertEqual(terminalState?.outcome, .succeeded)
        await loadGate.release()
        await load.value

        XCTAssertNil(coordinator.cacheFailure(for: bookKey))
        XCTAssertTrue(coordinator.isCached(chapterID: chapter.id, for: bookKey))
        XCTAssertEqual(
            coordinator.terminalState(for: bookKey)?.taskID,
            terminalState?.taskID
        )
    }

    func testReloadPreservesNewerTerminalStateAndItsSaveFailure()
        async throws
    {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 12,
            start: 0,
            end: 20,
            title: "Chapter Twelve"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-terminal-reload",
                title: "Terminal Reload",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoad: .success([
                fixtureTranscript(chapter: chapter, text: "durable text")
            ]),
            transcriptionTaskStateLoad: .success(nil),
            transcriptionTaskStateSaveResults: [
                .failure(.transcriptCache(.persistenceFailed))
            ]
        )
        let coordinator = makeTranscriptionModel()
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )

        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        let loadedTerminalState = await waitForTranscriptionTerminalState(
            in: coordinator,
            bookKey: bookKey
        )
        let terminalState = try XCTUnwrap(loadedTerminalState)
        await waitForTranscriptionCacheFailure(
            .taskStateSaveFailed,
            in: coordinator,
            bookKey: bookKey
        )

        await coordinator.loadCachedTranscripts(
            detail: detail,
            account: account,
            appModel: appModel
        )

        XCTAssertEqual(
            coordinator.terminalState(for: bookKey)?.taskID,
            terminalState.taskID
        )
        XCTAssertEqual(
            coordinator.cacheFailure(for: bookKey),
            .taskStateSaveFailed
        )
    }

    func testLateTerminalSaveCannotSetFailureForReplacementBatch()
        async throws
    {
        let account = try fixtureAccount()
        let firstChapter = PlaybackChapter(
            id: 13,
            start: 0,
            end: 20,
            title: "Chapter Thirteen"
        )
        let replacementChapter = PlaybackChapter(
            id: 14,
            start: 20,
            end: 40,
            title: "Chapter Fourteen"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-terminal-save-race",
                title: "Terminal Save Race",
                libraryID: fixtureLibrary().id
            ),
            chapters: [firstChapter, replacementChapter]
        )
        let firstSaveGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            firstTranscriptionTaskStateSaveGate: firstSaveGate,
            transcriptionTaskStateSaveResults: [
                .failure(.transcriptCache(.persistenceFailed)),
                .success(()),
            ]
        )
        let coordinator = makeTranscriptionModel()
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )

        coordinator.start(
            chapters: [firstChapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        await firstSaveGate.waitUntilEntered()
        let firstTaskID = try XCTUnwrap(
            coordinator.terminalState(for: bookKey)?.taskID
        )

        coordinator.start(
            chapters: [replacementChapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        let loadedReplacement =
            await waitForDifferentTranscriptionTerminalState(
                than: firstTaskID,
                in: coordinator,
                bookKey: bookKey
            )
        let replacement = try XCTUnwrap(loadedReplacement)
        await waitForTranscriptionTaskStateSaveAttempts(2, in: service)
        XCTAssertNil(coordinator.cacheFailure(for: bookKey))

        await firstSaveGate.release()
        await waitForTranscriptionTaskStateSaveCompletions(2, in: service)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(
            coordinator.terminalState(for: bookKey)?.taskID,
            replacement.taskID
        )
        XCTAssertNil(coordinator.cacheFailure(for: bookKey))
    }

    func testCancellationBeforeFailedSaveDoesNotCompleteChapter()
        async throws
    {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 5,
            start: 0,
            end: 20,
            title: "Chapter Five"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-cancel-failed-save",
                title: "Failed Save",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let saveGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptSaveGate: saveGate,
            transcriptSave: .failure(
                .transcriptCache(.persistenceFailed)
            )
        )
        let coordinator = makeTranscriptionModel()
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )

        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        await saveGate.waitUntilEntered()
        coordinator.cancel()
        await saveGate.release()

        let terminalState = await waitForTranscriptionTerminalState(
            in: coordinator,
            bookKey: bookKey
        )
        XCTAssertEqual(terminalState?.outcome, .cancelled)
        XCTAssertEqual(terminalState?.completedChapterIDs, [])
        XCTAssertFalse(
            coordinator.isCached(chapterID: chapter.id, for: bookKey))
    }

    func testTranscriptDeletionClearsLoadedTranscriptAndTaskState()
        async throws
    {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 6,
            start: 0,
            end: 20,
            title: "Chapter Six"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcript-delete",
                title: "Delete Transcript",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let taskState = fixtureTranscriptionTaskState(
            chapterIDs: [chapter.id],
            completedChapterIDs: [chapter.id],
            outcome: .succeeded,
            failure: nil
        )
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoad: .success([
                fixtureTranscript(chapter: chapter, text: "remove me")
            ]),
            transcriptDataPresence: .success(true),
            transcriptionTaskStateLoad: .success(taskState)
        )
        let coordinator = makeTranscriptionModel()
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )
        await coordinator.loadCachedTranscripts(
            detail: detail,
            account: account,
            appModel: appModel
        )
        XCTAssertTrue(coordinator.hasLocalData(for: bookKey))

        let deleted = await coordinator.deleteLocalData(
            detail: detail,
            account: account,
            appModel: appModel
        )

        let deletionRequests = await service.transcriptDeletionRequests()
        XCTAssertTrue(deleted)
        XCTAssertEqual(deletionRequests, [bookKey])
        XCTAssertFalse(coordinator.hasLocalData(for: bookKey))
        XCTAssertFalse(
            coordinator.isCached(chapterID: chapter.id, for: bookKey)
        )
        XCTAssertNil(coordinator.terminalState(for: bookKey))
        XCTAssertEqual(coordinator.deletionState(for: bookKey), .idle)
    }

    func testTranscriptDeletionWaitsForLateTranscriptSave() async throws {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 7,
            start: 0,
            end: 20,
            title: "Chapter Seven"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcript-delete-race",
                title: "Delete Race",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let saveGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptSaveGate: saveGate
        )
        let coordinator = makeTranscriptionModel()
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )
        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        await saveGate.waitUntilEntered()

        let deletion = Task { @MainActor in
            await coordinator.deleteLocalData(
                detail: detail,
                account: account,
                appModel: appModel
            )
        }
        for _ in 0..<10 {
            await Task.yield()
        }
        let requestsWhileSaveBlocked =
            await service.transcriptDeletionRequests()
        XCTAssertTrue(requestsWhileSaveBlocked.isEmpty)

        await saveGate.release()
        let deleted = await deletion.value
        let persistenceEvents =
            await service.recordedTranscriptPersistenceEvents()
        XCTAssertTrue(deleted)
        XCTAssertEqual(
            persistenceEvents,
            [.transcriptSaved(bookKey), .deleted(bookKey)]
        )
        XCTAssertFalse(coordinator.hasLocalData(for: bookKey))
        XCTAssertFalse(
            coordinator.isCached(chapterID: chapter.id, for: bookKey)
        )
    }

    func testTranscriptDeletionFailureKeepsLoadedData() async throws {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 8,
            start: 0,
            end: 20,
            title: "Chapter Eight"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcript-delete-failure",
                title: "Delete Failure",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let failure = AppServiceError.transcriptCache(.persistenceFailed)
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoad: .success([
                fixtureTranscript(chapter: chapter, text: "keep me")
            ]),
            transcriptDataPresence: .success(true),
            transcriptDeletion: .failure(failure)
        )
        let diagnostics = AppDiagnosticRecorderSpy()
        let coordinator = makeTranscriptionModel()
        let appModel = AppModel(
            service: service,
            diagnostics: diagnostics,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )
        await coordinator.loadCachedTranscripts(
            detail: detail,
            account: account,
            appModel: appModel
        )

        let deleted = await coordinator.deleteLocalData(
            detail: detail,
            account: account,
            appModel: appModel
        )

        XCTAssertFalse(deleted)
        XCTAssertTrue(coordinator.hasLocalData(for: bookKey))
        XCTAssertTrue(
            coordinator.isCached(chapterID: chapter.id, for: bookKey)
        )
        let presentationFailure = ChapterTranscriptLocalDataFailure(
            stage: .deletion,
            cause: failure
        )
        XCTAssertEqual(
            coordinator.deletionState(for: bookKey),
            .failed(presentationFailure)
        )
        XCTAssertEqual(
            presentationFailure.message,
            "Bleat could not delete the local transcript data because the local transcript store is unavailable."
        )
        let events = await diagnostics.events()
        XCTAssertTrue(
            events.contains(
                .failed(
                    .deleteTranscriptCache,
                    category: .app,
                    failureCode: .transcriptCachePersistenceFailed
                )
            )
        )
        XCTAssertEqual(
            DiagnosticOperation.deleteTranscriptCache.rawValue,
            "delete_transcript_cache"
        )
        XCTAssertEqual(
            DiagnosticFailureCode.transcriptCachePersistenceFailed.rawValue,
            "transcript_cache_persistence_failed"
        )
    }

    func testTranscriptPresenceFailurePreservesCauseAndDiagnosticStage()
        async throws
    {
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcript-presence-failure",
                title: "Presence Failure",
                libraryID: fixtureLibrary().id
            ),
            chapters: []
        )
        let failure = AppServiceError.transcriptCache(
            .invalidStoredTaskState
        )
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptDataPresence: .failure(failure)
        )
        let diagnostics = AppDiagnosticRecorderSpy()
        let coordinator = makeTranscriptionModel()
        let appModel = AppModel(
            service: service,
            diagnostics: diagnostics,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )

        await coordinator.refreshLocalDataPresence(
            detail: detail,
            account: account,
            appModel: appModel
        )

        let presentationFailure = try XCTUnwrap(
            coordinator.localDataPresenceFailure(for: bookKey)
        )
        XCTAssertEqual(presentationFailure.stage, .presenceInspection)
        XCTAssertEqual(presentationFailure.cause, failure)
        XCTAssertEqual(
            presentationFailure.message,
            "Bleat could not check the local transcript data because the saved transcription history is invalid."
        )
        XCTAssertNil(coordinator.cacheFailure(for: bookKey))
        let events = await diagnostics.events()
        XCTAssertTrue(
            events.contains(
                .failed(
                    .inspectTranscriptCache,
                    category: .app,
                    failureCode: .transcriptCacheInvalidStoredTaskState
                )
            )
        )
        XCTAssertEqual(
            DiagnosticOperation.inspectTranscriptCache.rawValue,
            "inspect_transcript_cache"
        )
        XCTAssertEqual(
            DiagnosticFailureCode.transcriptCacheInvalidStoredTaskState
                .rawValue,
            "transcript_cache_invalid_stored_task_state"
        )
    }

    func testTranscriptDeletionPreservesDownloadAndActivePlayback()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TranscriptDeletionPlayback-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 9,
            start: 0,
            end: 1,
            title: "Chapter Nine"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcript-delete-playback",
                title: "Keep Playback",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail
        )
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoad: .success([
                fixtureTranscript(chapter: chapter, text: "remove only this")
            ]),
            transcriptDataPresence: .success(true)
        )
        let coordinator = makeTranscriptionModel()
        let appModel = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("transcript-delete-playback"),
            transcription: coordinator
        )
        await appModel.start()
        let playbackOutcome = await appModel.startPlayback(
            detail: detail,
            account: account,
            position: .absoluteTime(0.5)
        )
        appModel.playback.pause()
        let playbackPositionBeforeDeletion = appModel.playback.currentTime
        let downloadBeforeDeletion = appModel.downloads.record(
            accountID: account.id,
            itemID: detail.id
        )
        await coordinator.loadCachedTranscripts(
            detail: detail,
            account: account,
            appModel: appModel
        )

        let deleted = await coordinator.deleteLocalData(
            detail: detail,
            account: account,
            appModel: appModel
        )

        XCTAssertEqual(playbackOutcome, .started(source: .downloaded))
        XCTAssertTrue(deleted)
        XCTAssertTrue(appModel.playback.hasActiveBook)
        XCTAssertEqual(appModel.playback.accountID, account.id)
        XCTAssertEqual(appModel.playback.itemID, detail.id)
        XCTAssertEqual(
            appModel.playback.currentTime,
            playbackPositionBeforeDeletion,
            accuracy: 0.01
        )
        XCTAssertEqual(
            appModel.downloads.record(
                accountID: account.id,
                itemID: detail.id
            ),
            downloadBeforeDeletion
        )
        await appModel.playback.stop()
    }

    func testTranscriptCacheExpiresOnlyAfterFiveIdleMinutes() async throws {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 1,
            start: 0,
            end: 20,
            title: "Chapter One"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-expiry",
                title: "Expiry",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let service = TestAppService(
            activeAccount: .success(account),
            transcriptLoad: .success([
                fixtureTranscript(chapter: chapter, text: "cached")
            ])
        )
        let coordinator = ChapterTranscriptionModel(
            transcriptCacheTTL: .seconds(300),
            transcriptCacheReapInterval: .seconds(3_600)
        )
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )

        await coordinator.loadCachedTranscripts(
            detail: detail,
            account: account,
            appModel: appModel
        )
        coordinator.reapExpiredTranscriptCaches(
            now: ContinuousClock().now.advanced(by: Duration.seconds(299))
        )
        XCTAssertTrue(coordinator.isCached(chapterID: chapter.id, for: bookKey))

        coordinator.reapExpiredTranscriptCaches(
            now: ContinuousClock().now.advanced(by: Duration.seconds(301))
        )
        XCTAssertFalse(
            coordinator.isCached(chapterID: chapter.id, for: bookKey))
    }

    #if os(iOS)
        func testVisibleAndActiveTranscriptCachesSurviveMemoryWarning()
            async throws
        {
            let account = try fixtureAccount()
            let chapter = PlaybackChapter(
                id: 1,
                start: 0,
                end: 20,
                title: "Chapter One"
            )
            let details = (1...3).map { index in
                fixtureBookDetail(
                    item: fixtureBook(
                        id: "memory-warning-\(index)",
                        title: "Book \(index)",
                        libraryID: fixtureLibrary().id
                    ),
                    chapters: [chapter]
                )
            }
            let transcriberGate = AsyncGate()
            let service = TestAppService(
                activeAccount: .success(account),
                transcriptLoad: .success([
                    fixtureTranscript(chapter: chapter, text: "cached")
                ])
            )
            let coordinator = makeTranscriptionModel(
                transcriberGate: transcriberGate
            )
            let appModel = AppModel(
                service: service,
                transcription: coordinator
            )
            for detail in details {
                await coordinator.loadCachedTranscripts(
                    detail: detail,
                    account: account,
                    appModel: appModel
                )
            }
            let visibleBookKey = ChapterTranscriptionBookKey(
                accountID: account.id,
                itemID: details[1].id
            )
            let activeBookKey = ChapterTranscriptionBookKey(
                accountID: account.id,
                itemID: details[2].id
            )
            coordinator.retainTranscriptCache(for: visibleBookKey)
            coordinator.start(
                chapters: [chapter],
                detail: details[2],
                account: account,
                downloads: appModel.downloads,
                appModel: appModel
            )
            await transcriberGate.waitUntilEntered()
            await Task.yield()

            NotificationCenter.default.post(
                name: UIApplication.didReceiveMemoryWarningNotification,
                object: nil
            )
            for _ in 0..<20 {
                await Task.yield()
            }

            let inactiveBookKey = ChapterTranscriptionBookKey(
                accountID: account.id,
                itemID: details[0].id
            )
            XCTAssertFalse(
                coordinator.isCached(
                    chapterID: chapter.id, for: inactiveBookKey)
            )
            XCTAssertTrue(
                coordinator.isCached(chapterID: chapter.id, for: visibleBookKey)
            )
            XCTAssertTrue(
                coordinator.isCached(chapterID: chapter.id, for: activeBookKey)
            )

            coordinator.releaseTranscriptCache(for: visibleBookKey)
            coordinator.cancel()
            await transcriberGate.release()
            _ = await waitForTranscriptionTerminalState(
                in: coordinator,
                bookKey: activeBookKey
            )
        }
    #endif

    func testPlaybackDoesNotBlockOrCancelTranscription() async throws {
        let playbackFixture = try playbackRecoveryFixture()
        defer {
            playbackFixture.cleanUp()
        }
        let playback = playbackFixture.model(
            activation: TestAudioSessionActivation()
        )
        await playback.startDownloaded(
            detail: playbackFixture.detail,
            trackURLs: [playbackFixture.audioURL],
            accountID: playbackFixture.accountID,
            account: nil
        )
        XCTAssertTrue(playback.isPlaybackRequested)

        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 7,
            start: 0,
            end: 20,
            title: "Chapter Seven"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-playback",
                title: "Playback",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let transcriberGate = AsyncGate()
        let service = TestAppService(activeAccount: .success(account))
        let coordinator = makeTranscriptionModel(
            transcriberGate: transcriberGate
        )
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )
        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        await transcriberGate.waitUntilEntered()
        XCTAssertTrue(coordinator.isWorking(for: bookKey))

        playback.pause()
        playback.play()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(playback.isPlaybackRequested)
        XCTAssertTrue(coordinator.isWorking(for: bookKey))
        XCTAssertFalse(coordinator.isCancelling(for: bookKey))

        await transcriberGate.release()
        let terminalState = await waitForTranscriptionTerminalState(
            in: coordinator,
            bookKey: bookKey
        )
        XCTAssertEqual(terminalState?.outcome, .succeeded)
        await playback.stop()
    }

    func testTranscriptionLifecycleEmitsContentFreeBatchAndChapterSpans()
        async throws
    {
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 1,
            start: 0,
            end: 20,
            title: "Private chapter title"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "private-item-id",
                title: "Private audiobook title",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
        )
        let tracer = RecordingRemoteTelemetryTracer()
        let coordinator = makeTranscriptionModel(
            remoteTelemetryTracer: tracer
        )
        let appModel = AppModel(
            service: TestAppService(activeAccount: .success(account)),
            transcription: coordinator
        )
        let bookKey = ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )

        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: appModel.downloads,
            appModel: appModel
        )
        _ = await waitForTranscriptionTerminalState(
            in: coordinator,
            bookKey: bookKey
        )

        XCTAssertEqual(
            tracer.spans,
            [
                RecordedRemoteTelemetrySpan(
                    operation: .transcription,
                    source: .downloaded,
                    retryBucket: .none,
                    outcome: .succeeded
                ),
                RecordedRemoteTelemetrySpan(
                    operation: .transcriptionChapter,
                    source: nil,
                    retryBucket: .none,
                    outcome: .succeeded,
                    transcriptionInput: RemoteTelemetryTranscriptionInput(
                        durationMilliseconds: 20_000,
                        byteCount: 4_096,
                        sliceCount: 1,
                        container: .m4a,
                        codec: .aac,
                        sampleRateHz: 44_100,
                        channelCount: 2
                    ),
                ),
            ]
        )
        XCTAssertFalse(
            String(describing: tracer.spans).contains("Private")
        )
    }

    func testChapterTelemetryAggregatesMixedSliceFormatsWithoutIdentity()
        throws
    {
        var accumulator = ChapterTelemetryInputAccumulator()
        accumulator.append(
            ChapterTranscriptionInput(
                durationMilliseconds: 10_000,
                byteCount: 1_000,
                container: .m4a,
                codec: .aac,
                sampleRateHz: 44_100,
                channelCount: 2
            )
        )
        accumulator.append(
            ChapterTranscriptionInput(
                durationMilliseconds: 20_000,
                byteCount: 2_000,
                container: .m4a,
                codec: .alac,
                sampleRateHz: 48_000,
                channelCount: 1
            )
        )

        XCTAssertEqual(
            accumulator.telemetryInput,
            RemoteTelemetryTranscriptionInput(
                durationMilliseconds: 30_000,
                byteCount: 3_000,
                sliceCount: 2,
                container: .m4a,
                codec: .mixed,
                sampleRateHz: nil,
                channelCount: nil
            )
        )
    }

    func testAutomaticChapterFileIsPinnedUntilTranscriptionCompletes()
        async throws
    {
        let audioFixture = try playbackRecoveryFixture()
        defer { audioFixture.cleanUp() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatTranscriptionPin-\(UUID().uuidString)",
                isDirectory: true
            )
        let suite = "TranscriptionPinTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let account = try fixtureAccount()
        let chapter = PlaybackChapter(
            id: 2,
            start: 1,
            end: 2,
            title: "Cached chapter"
        )
        let item = fixtureBook(
            id: "automatic-transcription",
            title: "Automatic transcription",
            libraryID: fixtureLibrary().id
        )
        let detail = fixtureBookDetail(
            item: item,
            chapters: [chapter]
        )
        let size = try XCTUnwrap(
            try FileManager.default.attributesOfItem(
                atPath: audioFixture.audioURL.path
            )[.size] as? NSNumber
        ).int64Value
        let tracks = (0..<2).map { index in
            DownloadTrackPlan(
                index: index,
                inode: "\(index)",
                expectedByteLength: size,
                mimeType: "audio/wav",
                safeExtension: .wav,
                destinationEntry: String(format: "%05d.wav", index),
                startOffset: Double(index),
                duration: 1
            )
        }
        let plan = DownloadPlan(itemID: detail.id, tracks: tracks)
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        var record = try await storage.create(
            downloadID: DownloadID(rawValue: "automatic-transcription"),
            accountID: account.id,
            plan: plan,
            detail: detail,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [1]
        )
        let identity = try DownloadTaskIdentity(
            downloadID: record.manifest.downloadID,
            accountID: account.id,
            itemID: detail.id,
            track: tracks[1]
        )
        let staged = root.appendingPathComponent("staged.wav")
        try FileManager.default.copyItem(
            at: audioFixture.audioURL,
            to: staged
        )
        let observed = try layout.placeCompleteTestFile(
            from: staged,
            identity: identity
        )
        record = try await storage.markComplete(
            identity,
            observedByteLength: observed
        )
        _ = try await storage.markBookFinished(record, at: Date())

        let gate = AsyncGate()
        let coordinator = ChapterTranscriptionModel(
            transcriptCacheReapInterval: .seconds(3_600),
            transcriberFactory: {
                TestChapterTranscriber(
                    gate: gate,
                    segments: [
                        TranscriptSegment(
                            startMilliseconds: 1_000,
                            endMilliseconds: 2_000,
                            text: "cached chapter"
                        )
                    ],
                    requestRecorder: nil
                )
            }
        )
        let service = TestAppService(activeAccount: .success(account))
        let downloads = DownloadModel(
            service: service,
            defaults: defaults,
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("transcription-pin")
        )
        let appModel = AppModel(
            service: service,
            transcription: coordinator
        )
        await downloads.start(account: account)
        coordinator.start(
            chapters: [chapter],
            detail: detail,
            account: account,
            downloads: downloads,
            appModel: appModel
        )
        await gate.waitUntilEntered()

        downloads.setAutomaticCleanupPolicy(.afterBook)
        for _ in 0..<20 {
            await Task.yield()
        }
        XCTAssertNotNil(
            downloads.record(
                accountID: account.id,
                itemID: detail.id
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.destinationURL(for: identity).path
            )
        )

        await gate.release()
        let terminalState = await waitForTranscriptionTerminalState(
            in: coordinator,
            bookKey: ChapterTranscriptionBookKey(
                accountID: account.id,
                itemID: detail.id
            )
        )
        XCTAssertEqual(terminalState?.outcome, .succeeded)
        for _ in 0..<100
        where downloads.record(
            accountID: account.id,
            itemID: detail.id
        ) != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(
            downloads.record(
                accountID: account.id,
                itemID: detail.id
            )
        )
    }

    func testCloudKitCapabilityRequiresEnabledEntitledBuild() {
        let containerIdentifier = PrivateCloudSyncCoordinator
            .containerIdentifier

        XCTAssertFalse(
            BleatCloudKitCapability.isAvailable(
                buildMode: .disabled,
                containerIdentifiers: [containerIdentifier]
            )
        )
        XCTAssertFalse(
            BleatCloudKitCapability.isAvailable(
                buildMode: .enabled,
                containerIdentifiers: nil
            )
        )
        XCTAssertTrue(
            BleatCloudKitCapability.isAvailable(
                buildMode: .enabled,
                containerIdentifiers: [containerIdentifier]
            )
        )
    }

    func testColourSchemeStorePersistsChangesAcrossViewInstances() throws {
        let suiteName = "ColourSchemeStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Could not create isolated user defaults suite")
            return
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstView = ColourSchemePreference(
            store: ColourSchemeStore(defaults: defaults)
        )
        XCTAssertEqual(firstView.wrappedValue, .defaultValue)

        firstView.wrappedValue = .orange

        let anotherView = ColourSchemePreference(
            store: ColourSchemeStore(defaults: defaults)
        )
        XCTAssertEqual(anotherView.wrappedValue, .orange)
    }

    func testBleatLocalStoreUsesApplicationSupportBleatDirectory()
        throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BleatLocalStoreTests-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let storeURL = try BleatLocalStore.storeURL(
            applicationSupportURL: root
        )

        XCTAssertEqual(
            storeURL,
            root.appendingPathComponent("Bleat/Bleat.store")
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storeURL.deletingLastPathComponent().path
            )
        )
    }

    func testBleatLocalStoreMigratesExistingDefaultStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatLocalStoreMigration-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let legacyURL = root.appendingPathComponent("default.store")
        let legacyContents = Data("legacy store".utf8)
        try legacyContents.write(to: legacyURL)
        let legacyWALURL = URL(fileURLWithPath: legacyURL.path + "-wal")
        let legacyWALContents = Data("legacy WAL".utf8)
        try legacyWALContents.write(to: legacyWALURL)

        let storeURL = try BleatLocalStore.storeURL(
            applicationSupportURL: root
        )

        XCTAssertEqual(storeURL.lastPathComponent, "Bleat.store")
        XCTAssertEqual(try Data(contentsOf: storeURL), legacyContents)
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: storeURL.path + "-wal")),
            legacyWALContents
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: legacyURL.path)
        )
    }

    func testBookDetailPlaybackActionUsesPlaybackAndProgressState() {
        let currentItemID = LibraryItemID(rawValue: "current")
        let otherItemID = LibraryItemID(rawValue: "other")

        XCTAssertEqual(
            BookDetailPlaybackAction.decide(
                itemID: currentItemID,
                currentItemID: currentItemID,
                isPlaybackRequested: true,
                progress: nil
            ),
            .pause
        )
        XCTAssertEqual(BookDetailPlaybackAction.pause.label, "Pause")
        XCTAssertEqual(
            BookDetailPlaybackAction.pause.systemImage,
            "pause.fill"
        )
        XCTAssertEqual(
            BookDetailPlaybackAction.decide(
                itemID: currentItemID,
                currentItemID: currentItemID,
                isPlaybackRequested: false,
                progress: fixtureBookProgress(
                    progress: 0.5,
                    isFinished: false
                )
            ),
            .resume
        )
        XCTAssertEqual(
            BookDetailPlaybackAction.decide(
                itemID: otherItemID,
                currentItemID: currentItemID,
                isPlaybackRequested: true,
                progress: nil
            ),
            .start
        )
        XCTAssertEqual(
            BookDetailPlaybackAction.decide(
                itemID: otherItemID,
                currentItemID: currentItemID,
                isPlaybackRequested: false,
                progress: fixtureBookProgress(
                    progress: 0.75,
                    isFinished: false
                )
            ),
            .resume
        )
        XCTAssertEqual(
            BookDetailPlaybackAction.decide(
                itemID: otherItemID,
                currentItemID: currentItemID,
                isPlaybackRequested: false,
                progress: fixtureBookProgress(
                    progress: 1,
                    isFinished: true
                )
            ),
            .playAgain
        )
        XCTAssertEqual(
            BookDetailPlaybackAction.decide(
                itemID: otherItemID,
                currentItemID: currentItemID,
                isPlaybackRequested: false,
                progress: fixtureBookProgress(
                    progress: 0,
                    isFinished: true
                )
            ),
            .start
        )
        XCTAssertEqual(BookDetailPlaybackAction.start.label, "Start")
        XCTAssertEqual(BookDetailPlaybackAction.resume.label, "Resume")
        XCTAssertEqual(BookDetailPlaybackAction.playAgain.label, "Play Again")
    }

    func testMiniPlayerSwipeDecidesDirectionalActions() {
        let height: CGFloat = 844
        XCTAssertEqual(
            MiniPlayerSwipeDecision.decide(
                translation: CGSize(width: 0, height: -50),
                predictedEndTranslation: CGSize(width: 0, height: -60),
                height: height
            ),
            .showPlayer
        )
        XCTAssertEqual(
            MiniPlayerSwipeDecision.decide(
                translation: CGSize(width: 10, height: -80),
                predictedEndTranslation: CGSize(width: 12, height: -90),
                height: height
            ),
            .showPlayer
        )
        XCTAssertEqual(
            MiniPlayerSwipeDecision.decide(
                translation: CGSize(width: 0, height: -35),
                predictedEndTranslation: CGSize(width: 0, height: -40),
                height: height
            ),
            .ignore
        )
        XCTAssertEqual(
            MiniPlayerSwipeDecision.decide(
                translation: CGSize(width: 0, height: -20),
                predictedEndTranslation: CGSize(width: 0, height: -180),
                height: height
            ),
            .showPlayer
        )
        XCTAssertEqual(
            MiniPlayerSwipeDecision.decide(
                translation: CGSize(width: 0, height: -20),
                predictedEndTranslation: CGSize(width: 300, height: -180),
                height: height
            ),
            .ignore
        )
        XCTAssertEqual(
            MiniPlayerSwipeDecision.decide(
                translation: CGSize(width: 0, height: 20),
                predictedEndTranslation: CGSize(width: 0, height: 180),
                height: height
            ),
            .stopAndDismiss
        )
        XCTAssertEqual(
            MiniPlayerSwipeDecision.decide(
                translation: CGSize(width: 0, height: -20),
                predictedEndTranslation: CGSize(width: 0, height: -180),
                height: 0
            ),
            .ignore
        )
        XCTAssertEqual(
            MiniPlayerSwipeDecision.decide(
                translation: CGSize(width: 0, height: 80),
                predictedEndTranslation: CGSize(width: 0, height: 90),
                height: height
            ),
            .stopAndDismiss
        )
        XCTAssertEqual(
            MiniPlayerSwipeDecision.decide(
                translation: CGSize(width: 80, height: -40),
                predictedEndTranslation: CGSize(width: 90, height: -50),
                height: height
            ),
            .ignore
        )
    }

    #if os(iOS)
        func testBookCoverLoaderDeduplicatesAndCachesAccountScopedImages()
            async throws
        {
            let imageData = try XCTUnwrap(
                UIGraphicsImageRenderer(
                    size: CGSize(width: 2, height: 2)
                ).image { context in
                    UIColor.systemPurple.setFill()
                    context.fill(
                        CGRect(x: 0, y: 0, width: 2, height: 2)
                    )
                }.pngData()
            )
            let fetcher = TestBookCoverFetcher(data: imageData)
            let loader = BookCoverImageLoader(
                diskCapacity: 0,
                fetch: { request in
                    try await fetcher.fetch(request)
                }
            )
            let accountID = AccountID(rawValue: "cover-account")
            let url = try XCTUnwrap(
                URL(string: "https://books.example/cover?ts=1")
            )

            async let first = loader.image(for: url, accountID: accountID)
            async let second = loader.image(for: url, accountID: accountID)
            let (firstImage, secondImage) = await (first, second)
            let third = await loader.image(for: url, accountID: accountID)
            let firstAccountRequestCount = await fetcher.requestCount

            XCTAssertNotNil(firstImage)
            XCTAssertNotNil(secondImage)
            XCTAssertNotNil(third)
            XCTAssertEqual(firstAccountRequestCount, 1)

            _ = await loader.image(
                for: url,
                accountID: AccountID(rawValue: "other-account")
            )
            let secondAccountRequestCount = await fetcher.requestCount
            XCTAssertEqual(secondAccountRequestCount, 2)
        }

        func testBookCoverLoaderReusesBoundedDiskCacheAfterMemoryEviction()
            async throws
        {
            let imageData = try XCTUnwrap(
                UIGraphicsImageRenderer(
                    size: CGSize(width: 2, height: 2)
                ).image { context in
                    UIColor.systemOrange.setFill()
                    context.fill(
                        CGRect(x: 0, y: 0, width: 2, height: 2)
                    )
                }.pngData()
            )
            let fetcher = TestBookCoverFetcher(data: imageData)
            let cacheRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "BookCoverLoaderTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer {
                try? FileManager.default.removeItem(at: cacheRoot)
            }
            let accountID = AccountID(rawValue: "persistent-cover-account")
            let url = try XCTUnwrap(
                URL(string: "https://books.example/cover?ts=2")
            )
            let loader = BookCoverImageLoader(
                diskCapacity: 1 * 1_024 * 1_024,
                cacheRoot: cacheRoot,
                fetch: { request in
                    try await fetcher.fetch(request)
                }
            )

            let first = await loader.image(
                for: url,
                accountID: accountID
            )
            await loader.clearMemoryCache()
            let second = await loader.image(
                for: url,
                accountID: accountID
            )
            let requestCount = await fetcher.requestCount

            XCTAssertNotNil(first)
            XCTAssertNotNil(second)
            XCTAssertEqual(requestCount, 1)
        }

        func testBookCoverLoaderRoutesThroughCentralEndpointAndFallsBack()
            async throws
        {
            let imageData = try XCTUnwrap(
                UIGraphicsImageRenderer(
                    size: CGSize(width: 2, height: 2)
                ).image { context in
                    UIColor.systemBlue.setFill()
                    context.fill(
                        CGRect(x: 0, y: 0, width: 2, height: 2)
                    )
                }.pngData()
            )
            let fetcher = TestBookCoverFetcher(
                data: imageData,
                failingRequestCount: 1
            )
            let router = ServerEndpointRouter()
            let primary = try NormalizedServerURL("https://books.example")
            let local = try NormalizedServerURL("https://books.home")
            await router.configure(primary: primary, local: local)
            let loader = BookCoverImageLoader(
                diskCapacity: 0,
                fetch: { request in
                    try await fetcher.fetch(request)
                }
            )
            await loader.setEndpointRouter(router)
            let url = try XCTUnwrap(
                URL(string: "https://books.example/api/items/item/cover")
            )

            let image = await loader.image(
                for: url,
                accountID: AccountID(rawValue: "cover-routing-account")
            )

            XCTAssertNotNil(image)
            let requestHosts = await fetcher.requestHosts
            XCTAssertEqual(
                requestHosts,
                ["books.home", "books.example"]
            )
            let snapshot = await router.activitySnapshot(for: primary)
            XCTAssertEqual(
                snapshot.lastConnection,
                ServerConnectionActivity(
                    usage: .primary,
                    purpose: .cover
                )
            )
        }
    #endif

    func testScrubberSeekDecisionConfirmsTenMinuteJumpsInEitherDirection() {
        // under the 300 second limit
        let initialTime: Double = 1_000.0
        // just under, seek fine
        XCTAssertEqual(
            ScrubberSeekDecision.decide(
                origin: initialTime,
                target: initialTime + ScrubberSeekDecision.confirmationThreshold
                    - 0.01),
            .seekImmediately(
                initialTime + ScrubberSeekDecision.confirmationThreshold - 0.01)
        )
        // at it, confirm
        XCTAssertEqual(
            ScrubberSeekDecision.decide(
                origin: initialTime,
                target: initialTime + ScrubberSeekDecision.confirmationThreshold
            ),
            .confirm(
                PendingScrubberSeek(
                    origin: initialTime,
                    target: initialTime
                        + ScrubberSeekDecision.confirmationThreshold)
            )
        )
        // just over, confirm
        XCTAssertEqual(
            ScrubberSeekDecision.decide(
                origin: initialTime,
                target: initialTime + ScrubberSeekDecision.confirmationThreshold
                    + 0.001),
            .confirm(
                PendingScrubberSeek(
                    origin: initialTime,
                    target: initialTime
                        + ScrubberSeekDecision.confirmationThreshold + 0.001)
            )
        )
        // going backwards but just under the threshold, seek fine
        XCTAssertEqual(
            ScrubberSeekDecision.decide(
                origin: initialTime,
                target: (initialTime
                    - ScrubberSeekDecision.confirmationThreshold) + 0.01),
            .seekImmediately(
                (initialTime - ScrubberSeekDecision.confirmationThreshold)
                    + 0.01)
        )
        // going backwards and at the threshold, confirm
        XCTAssertEqual(
            ScrubberSeekDecision.decide(
                origin: initialTime,
                target: initialTime + ScrubberSeekDecision.confirmationThreshold
            ),
            .confirm(
                PendingScrubberSeek(
                    origin: initialTime,
                    target: initialTime
                        + ScrubberSeekDecision.confirmationThreshold)
            )
        )
        // going backwards and just over the threshold, confirm
        XCTAssertEqual(
            ScrubberSeekDecision.decide(
                origin: initialTime,
                target: initialTime
                    - (ScrubberSeekDecision.confirmationThreshold + 0.001)),
            .confirm(
                PendingScrubberSeek(
                    origin: initialTime,
                    target: initialTime
                        - (ScrubberSeekDecision.confirmationThreshold + 0.001))
            )
        )
    }

    func testPlaybackScrubberChapterWindowUsesActiveChapterBounds() {
        let window = PlaybackScrubberChapterWindow.select(
            chapter: PlaybackChapter(
                id: 1,
                start: 600,
                end: 900,
                title: "Chapter Two"
            ),
            duration: 1_800
        )

        XCTAssertEqual(window.range, 600...900)
        XCTAssertEqual(window.elapsed(at: 720), 120)
        XCTAssertEqual(window.remaining(at: 720), 180)
        XCTAssertEqual(window.elapsed(at: 500), 0)
        XCTAssertEqual(window.remaining(at: 1_000), 0)
    }

    func testPlaybackScrubberChapterWindowFallsBackToBookBounds() {
        XCTAssertEqual(
            PlaybackScrubberChapterWindow.select(
                chapter: nil,
                duration: 1_800
            ).range,
            0...1_800
        )
        XCTAssertEqual(
            PlaybackScrubberChapterWindow.select(
                chapter: PlaybackChapter(
                    id: 1,
                    start: 900,
                    end: 900,
                    title: "Broken Chapter"
                ),
                duration: 1_800
            ).range,
            0...1_800
        )
    }

    func testPlaybackChapterIndexResolverUsesTimelinePositionNotChapterID() {
        let chapters = [
            PlaybackChapter(
                id: 4,
                start: 0,
                end: 10,
                title: "First"
            ),
            PlaybackChapter(
                id: 4,
                start: 10,
                end: 20,
                title: "Middle"
            ),
            PlaybackChapter(
                id: 9,
                start: 20,
                end: 30,
                title: "Final"
            ),
        ]

        XCTAssertNil(
            PlaybackChapterIndexResolver.resolve(
                chapters: chapters,
                wholeBookTime: -1
            )
        )
        XCTAssertEqual(
            PlaybackChapterIndexResolver.resolve(
                chapters: chapters,
                wholeBookTime: 0
            ),
            0
        )
        XCTAssertEqual(
            PlaybackChapterIndexResolver.resolve(
                chapters: chapters,
                wholeBookTime: 15
            ),
            1
        )
        XCTAssertEqual(
            PlaybackChapterIndexResolver.resolve(
                chapters: chapters,
                wholeBookTime: 20
            ),
            2
        )
        XCTAssertEqual(
            PlaybackChapterIndexResolver.resolve(
                chapters: chapters,
                wholeBookTime: 30
            ),
            2
        )
    }

    func
        testAutomaticDownloadWaitsForStablePlaybackAndReservesBandwidthAgainOnStall()
    {
        var gate = AutomaticDownloadPlaybackGate()

        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: false,
                timeControlStatus: .paused,
                now: 0
            ),
            .allowAutomaticDownloads
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                now: 1
            ),
            .reserveForPlayback
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .playing,
                now: 2
            ),
            .reserveForPlayback
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .playing,
                now: 11
            ),
            .reserveForPlayback
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .playing,
                now: 12
            ),
            .allowAutomaticDownloads
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                now: 13
            ),
            .reserveForPlayback
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .playing,
                now: 14
            ),
            .reserveForPlayback
        )
    }

    func testDisplayedDownloadBytesIncludeInflightTransferAndClampToExpected() {
        XCTAssertEqual(
            DownloadModel.combinedDownloadedByteLength(
                storedByteLength: 100,
                transferredByteLengths: [20, 30],
                expectedByteLength: 200
            ),
            150
        )
        XCTAssertEqual(
            DownloadModel.combinedDownloadedByteLength(
                storedByteLength: 100,
                transferredByteLengths: [Int64.max],
                expectedByteLength: 200
            ),
            200
        )
        XCTAssertEqual(
            DownloadModel.combinedDownloadedByteLength(
                storedByteLength: -1,
                transferredByteLengths: [25],
                expectedByteLength: 200
            ),
            25
        )
    }

    func testAutomaticDownloadBytesAndStateUseOnlyActiveWindow()
        throws
    {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: (0..<10).map { index in
                DownloadTrackPlan(
                    index: index,
                    inode: "\(index)",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: String(
                        format: "%05d.mp3",
                        index
                    )
                )
            }
        )
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "automatic"),
            accountID: AccountID(rawValue: "account"),
            plan: plan,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [2, 3, 4, 5, 6]
        )
        for index in 2...6 {
            try manifest.markComplete(
                trackIndex: index,
                observedByteLength: 10,
                placement: .finalized
            )
        }
        let record = DownloadedBookRecord(
            manifest: manifest,
            detail: fixtureBookDetail(
                item: fixturePage(
                    libraryID: fixtureLibrary().id
                ).items[0]
            )
        )

        XCTAssertEqual(record.manifest.automaticCacheState, .cached)
        XCTAssertEqual(
            record.manifest.automaticExpectedByteLength,
            50
        )
        XCTAssertFalse(record.manifest.isFullBookComplete)
        XCTAssertEqual(
            DownloadModel.scopedDownloadedByteLength(
                for: record,
                transferredByteLengthsByTrack: [
                    0: 10,
                    9: Int64.max,
                ]
            ),
            50
        )

        try manifest.setAutomaticWindow(
            targetTrackIndexes: [5, 6, 7, 8, 9]
        )
        try manifest.markDownloading(trackIndex: 7)
        let shifted = DownloadedBookRecord(
            manifest: manifest,
            detail: record.detail
        )
        XCTAssertEqual(
            shifted.manifest.automaticCacheState,
            .downloading
        )
        XCTAssertEqual(
            DownloadModel.scopedDownloadedByteLength(
                for: shifted,
                transferredByteLengthsByTrack: [
                    1: 10,
                    7: 5,
                ]
            ),
            25
        )
    }

    func testCoverURLRetainsPrefixAndUsesCacheDimensionsWithoutToken()
        throws
    {
        let server = try NormalizedServerURL(
            "https://books.example/audiobookshelf"
        )

        let url = try XCTUnwrap(
            BookCoverURL.make(
                server: server,
                itemID: LibraryItemID(rawValue: "item/one"),
                updatedAtMilliseconds: 123,
                width: 600,
                height: 400
            )
        )
        let components = try XCTUnwrap(
            URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        )

        XCTAssertEqual(
            components.percentEncodedPath,
            "/audiobookshelf/api/items/item%2Fone/cover"
        )
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "width", value: "600"),
                URLQueryItem(name: "height", value: "400"),
                URLQueryItem(name: "format", value: "jpeg"),
                URLQueryItem(name: "ts", value: "123"),
            ]
        )
        XCTAssertFalse(
            components.queryItems?.contains {
                ["token", "access_token"].contains($0.name.lowercased())
            } ?? true
        )
    }

    func testDownloadRepairPlannerPreservesHealthyTracksAndRejectsDrift()
        throws
    {
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8).utf8
            )
        )
        let item = fixturePage(
            libraryID: fixtureLibrary().id
        ).items[0]
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "download"),
            accountID: AccountID(rawValue: "account"),
            plan: plan
        )
        try manifest.markComplete(
            trackIndex: 0,
            observedByteLength: 4,
            placement: .finalized
        )
        try manifest.markFailed(trackIndex: 1)
        let record = DownloadedBookRecord(
            manifest: manifest,
            detail: fixtureBookDetail(item: item)
        )

        let tracks = try DownloadRepairPlanner.tracks(
            record: record,
            plan: plan
        )

        XCTAssertEqual(tracks.map(\.index), [1])
        XCTAssertThrowsError(
            try DownloadRepairPlanner.tracks(
                record: record,
                plan: DownloadPlan.decodeExpandedItem(
                    from: Data(
                        Self.downloadPlanJSON(secondSize: 9).utf8
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadModelFailure,
                .repairPlanChanged
            )
        }
    }

    func testAutomaticRepairUsesWindowWhilePromotionUsesFullBook()
        throws
    {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: (0..<3).map { index in
                DownloadTrackPlan(
                    index: index,
                    inode: "\(index)",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: String(
                        format: "%05d.mp3",
                        index
                    )
                )
            }
        )
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "automatic"),
            accountID: AccountID(rawValue: "account"),
            plan: plan,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [1]
        )
        try manifest.markComplete(
            trackIndex: 0,
            observedByteLength: 10,
            placement: .finalized
        )
        try manifest.markFailed(trackIndex: 1)
        try manifest.markFailed(trackIndex: 2)
        let record = DownloadedBookRecord(
            manifest: manifest,
            detail: fixtureBookDetail(
                item: fixturePage(
                    libraryID: fixtureLibrary().id
                ).items[0]
            )
        )

        XCTAssertEqual(
            try DownloadRepairPlanner.tracks(
                record: record,
                plan: plan
            ).map(\.index),
            [1]
        )
        XCTAssertEqual(
            try DownloadRepairPlanner.tracks(
                record: record,
                plan: plan,
                scope: .fullBook
            ).map(\.index),
            [1, 2]
        )
    }

    func testDownloadPreflightRejectsInsufficientCapacityBeforeScheduling()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatIssue151Capacity-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "issue-151-capacity",
                title: "Capacity preflight",
                libraryID: fixtureLibrary().id
            )
        )
        let plan = DownloadPlan(
            itemID: detail.id,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "oversized",
                    expectedByteLength: Int64.max / 2,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                )
            ]
        )
        let model = DownloadModel(
            service: TestAppService(
                activeAccount: .success(account),
                downloadPlan: .success(plan)
            ),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.issue-151-capacity.\(UUID().uuidString)"
        )

        await model.download(detail: detail, account: account)

        guard case .insufficientStorage(
            let requiredBytes,
            let availableBytes
        ) = model.failure else {
            XCTFail("Expected a typed insufficient-storage failure")
            return
        }
        XCTAssertGreaterThan(requiredBytes, availableBytes)
        XCTAssertTrue(model.records.isEmpty)
        let descriptors = await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        await model.removeAll()
    }

    func testThreeHundredTrackDownloadRepairAndPublicationStayResponsive()
        async throws
    {
        let trackCount = 300
        let damagedTrackIndex = 173
        let automaticDamagedTrackIndex = 150
        let planningThreshold = 1.0
        let reconciliationThreshold = 5.0
        let publicationThreshold = 5.0
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatIssue151Performance-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let libraryID = fixtureLibrary().id
        let tracks = issue151Tracks(count: trackCount)
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "issue-151-manual"),
            tracks: tracks
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: plan.itemID.rawValue,
                title: "Issue 151 manual fixture",
                libraryID: libraryID,
                trackCount: trackCount
            )
        )
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        let downloadID = DownloadID(rawValue: "issue-151-manual")
        _ = try await storage.create(
            downloadID: downloadID,
            accountID: account.id,
            plan: plan,
            detail: detail
        )
        for track in tracks {
            try await completeIssue151Track(
                track,
                downloadID: downloadID,
                accountID: account.id,
                itemID: detail.id,
                root: root,
                layout: layout,
                storage: storage
            )
        }
        let healthyIdentity = try DownloadTaskIdentity(
            downloadID: downloadID,
            accountID: account.id,
            itemID: detail.id,
            track: tracks[10]
        )
        let healthyURL = layout.destinationURL(for: healthyIdentity)
        let healthyBytes = try Data(contentsOf: healthyURL)
        let damagedIdentity = try DownloadTaskIdentity(
            downloadID: downloadID,
            accountID: account.id,
            itemID: detail.id,
            track: tracks[damagedTrackIndex]
        )
        try FileManager.default.removeItem(
            at: layout.destinationURL(for: damagedIdentity)
        )

        let automaticPlan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "issue-151-automatic"),
            tracks: tracks
        )
        let automaticDetail = fixtureBookDetail(
            item: fixtureBook(
                id: automaticPlan.itemID.rawValue,
                title: "Issue 151 automatic fixture",
                libraryID: libraryID,
                trackCount: trackCount
            )
        )
        let automaticDownloadID = DownloadID(
            rawValue: "issue-151-automatic"
        )
        let automaticWindow = Set(148...152)
        _ = try await storage.create(
            downloadID: automaticDownloadID,
            accountID: account.id,
            plan: automaticPlan,
            detail: automaticDetail,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: automaticWindow
        )
        for trackIndex in automaticWindow.sorted() {
            try await completeIssue151Track(
                tracks[trackIndex],
                downloadID: automaticDownloadID,
                accountID: account.id,
                itemID: automaticDetail.id,
                root: root,
                layout: layout,
                storage: storage
            )
        }
        let automaticDamagedIdentity = try DownloadTaskIdentity(
            downloadID: automaticDownloadID,
            accountID: account.id,
            itemID: automaticDetail.id,
            track: tracks[automaticDamagedTrackIndex]
        )
        try Data().write(
            to: layout.destinationURL(for: automaticDamagedIdentity)
        )

        let reconciliation = try await measureIssue151Stage {
            try await DownloadStorage(layout: layout).records()
        }
        let records = reconciliation.value
        let reconciled = try XCTUnwrap(
            records.first { $0.manifest.downloadID == downloadID }
        )
        let automaticReconciled = try XCTUnwrap(
            records.first {
                $0.manifest.downloadID == automaticDownloadID
            }
        )

        let planning = try await measureIssue151Stage {
            let repairTracks = try DownloadRepairPlanner.tracks(
                record: reconciled,
                plan: plan
            )
            let automaticRepairTracks = try DownloadRepairPlanner.tracks(
                record: automaticReconciled,
                plan: automaticPlan
            )
            return (repairTracks, automaticRepairTracks)
        }
        let (repairTracks, automaticRepairTracks) = planning.value

        var changedTracks = tracks
        changedTracks[damagedTrackIndex] = DownloadTrackPlan(
            index: damagedTrackIndex,
            inode: "changed-\(damagedTrackIndex)",
            expectedByteLength: 2,
            mimeType: "audio/mpeg",
            safeExtension: .mp3,
            destinationEntry: String(
                format: "%05d.mp3",
                damagedTrackIndex
            )
        )
        XCTAssertThrowsError(
            try DownloadRepairPlanner.tracks(
                record: reconciled,
                plan: DownloadPlan(
                    itemID: plan.itemID,
                    tracks: changedTracks
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadModelFailure,
                .repairPlanChanged
            )
        }

        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(
                .downloadPlan(.unexpectedStatus(503))
            ),
            authorizedDownloadRequest: .success(
                URLRequest(
                    url: try XCTUnwrap(
                        URL(string: "https://192.0.2.1/issue-151")
                    )
                )
            )
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.issue-151-performance.\(UUID().uuidString)"
        )
        XCTAssertEqual(
            model.controlSnapshot(for: reconciled).phase,
            .repairNeeded
        )
        XCTAssertEqual(
            model.controlSnapshot(for: automaticReconciled).phase,
            .cacheFailed
        )
        let publication = await measureIssue151Stage {
            await model.start(account: account)
        }

        let published = try XCTUnwrap(
            model.record(accountID: account.id, itemID: detail.id)
        )
        let automaticPublished = try XCTUnwrap(
            model.record(
                accountID: account.id,
                itemID: automaticDetail.id
            )
        )
        XCTAssertEqual(reconciled.manifest.state, .partial)
        XCTAssertEqual(repairTracks.map(\.index), [damagedTrackIndex])
        XCTAssertEqual(
            automaticReconciled.manifest.automaticCacheState,
            .failed
        )
        XCTAssertEqual(
            automaticRepairTracks.map(\.index),
            [automaticDamagedTrackIndex]
        )
        XCTAssertEqual(published.manifest.entries.count, trackCount)
        XCTAssertEqual(
            published.manifest.state,
            .partial
        )
        XCTAssertEqual(
            automaticPublished.manifest.automaticCacheState,
            .failed
        )
        XCTAssertEqual(try Data(contentsOf: healthyURL), healthyBytes)

        model.updateNetworkPathState(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: false,
                isExpensive: false
            )
        )
        await service.setDownloadPlan(.success(plan))
        await model.repair(published, account: account)
        var scheduled = await model.scheduledTransferDescriptorsForTesting()
        let manualDescriptors = scheduled.filter {
            $0.identity.itemID == detail.id
        }
        XCTAssertEqual(
            manualDescriptors.map(\.identity.trackIndex),
            [damagedTrackIndex]
        )
        try await completeIssue151RepairTransfer(
            try XCTUnwrap(manualDescriptors.first),
            model: model
        ) {
            model.record(accountID: account.id, itemID: detail.id)?
                .manifest.state == .complete
        }
        await service.setDownloadPlan(.success(automaticPlan))
        await model.repair(automaticPublished, account: account)
        scheduled = await model.scheduledTransferDescriptorsForTesting()
        let automaticDescriptors = scheduled.filter {
            $0.identity.itemID == automaticDetail.id
        }
        XCTAssertEqual(
            automaticDescriptors.map(\.identity.trackIndex),
            [automaticDamagedTrackIndex]
        )
        try await completeIssue151RepairTransfer(
            try XCTUnwrap(automaticDescriptors.first),
            model: model
        ) {
            model.record(
                accountID: account.id,
                itemID: automaticDetail.id
            )?.manifest.automaticCacheState == .cached
        }
        let repairedRecords = try await DownloadStorage(layout: layout).records()
        let repaired = try XCTUnwrap(
            repairedRecords.first { $0.manifest.downloadID == downloadID }
        )
        let automaticRepaired = try XCTUnwrap(
            repairedRecords.first {
                $0.manifest.downloadID == automaticDownloadID
            }
        )
        let repairedEntry = try XCTUnwrap(
            repaired.manifest.entries.first {
                $0.trackIndex == damagedTrackIndex
            }
        )
        let automaticRepairedEntry = try XCTUnwrap(
            automaticRepaired.manifest.entries.first {
                $0.trackIndex == automaticDamagedTrackIndex
            }
        )
        XCTAssertEqual(repaired.manifest.state, .complete)
        XCTAssertEqual(repairedEntry.state, .complete)
        XCTAssertEqual(repairedEntry.placement, .finalized)
        XCTAssertEqual(
            automaticRepaired.manifest.automaticCacheState,
            .cached
        )
        XCTAssertEqual(automaticRepairedEntry.state, .complete)
        XCTAssertEqual(automaticRepairedEntry.placement, .finalized)
        XCTAssertEqual(
            try Data(contentsOf: layout.destinationURL(for: damagedIdentity)),
            Data([0xA5])
        )
        XCTAssertEqual(
            try Data(
                contentsOf: layout.destinationURL(
                    for: automaticDamagedIdentity
                )
            ),
            Data([0xA5])
        )
        XCTAssertEqual(try Data(contentsOf: healthyURL), healthyBytes)
        XCTAssertLessThan(planning.elapsedSeconds, planningThreshold)
        XCTAssertLessThan(
            reconciliation.elapsedSeconds,
            reconciliationThreshold
        )
        XCTAssertLessThan(
            publication.elapsedSeconds,
            publicationThreshold
        )
        XCTAssertGreaterThan(planning.heartbeatCount, 0)
        XCTAssertLessThan(planning.maximumMainActorGap, 1.0)
        XCTAssertGreaterThan(reconciliation.heartbeatCount, 0)
        XCTAssertLessThan(reconciliation.maximumMainActorGap, 1.0)
        XCTAssertGreaterThan(publication.heartbeatCount, 0)
        XCTAssertLessThan(publication.maximumMainActorGap, 1.0)

        let summary = """
            Download performance evidence: Issue #151
            fixture.trackCount: \(trackCount)
            fixture.trackBytes: 1
            planning.seconds: \(String(format: "%.6f", planning.elapsedSeconds))
            planning.threshold.seconds: \(planningThreshold)
            planning.mainActor.maxGap.seconds: \(String(format: "%.6f", planning.maximumMainActorGap))
            planning.mainActor.heartbeatCount: \(planning.heartbeatCount)
            reconciliation.seconds: \(String(format: "%.6f", reconciliation.elapsedSeconds))
            reconciliation.threshold.seconds: \(reconciliationThreshold)
            reconciliation.mainActor.maxGap.seconds: \(String(format: "%.6f", reconciliation.maximumMainActorGap))
            reconciliation.mainActor.heartbeatCount: \(reconciliation.heartbeatCount)
            publication.seconds: \(String(format: "%.6f", publication.elapsedSeconds))
            publication.threshold.seconds: \(publicationThreshold)
            publication.mainActor.maxGap.seconds: \(String(format: "%.6f", publication.maximumMainActorGap))
            publication.mainActor.heartbeatCount: \(publication.heartbeatCount)
            manual.damagedTrack: \(damagedTrackIndex)
            automatic.damagedTrack: \(automaticDamagedTrackIndex)
            repair.replacementTransfersCompleted: 2
            """
        print(
            "download-perf-summary "
                + summary.replacingOccurrences(of: "\n", with: " | ")
        )
        let attachment = XCTAttachment(string: summary)
        attachment.name = "issue-151-download-performance.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        await model.removeAll()
    }

    func testManualTrackAdvancesOnlyAfterActiveTrackFinalizes() throws {
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: plan.itemID.rawValue,
                title: "Serial download",
                libraryID: fixtureLibrary().id
            )
        )
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "serial-download"),
            accountID: AccountID(rawValue: "account"),
            plan: plan
        )
        try manifest.markDownloading(trackIndex: 0)
        var record = DownloadedBookRecord(manifest: manifest, detail: detail)

        XCTAssertEqual(
            DownloadModel.nextManualDownloadIdentity(in: record)?.trackIndex,
            0
        )

        try manifest.markComplete(
            trackIndex: 0,
            observedByteLength: plan.tracks[0].expectedByteLength,
            placement: .finalized
        )
        record = DownloadedBookRecord(manifest: manifest, detail: detail)

        XCTAssertEqual(
            DownloadModel.nextManualDownloadIdentity(in: record)?.trackIndex,
            1
        )
    }

    func testAccountRemovalDeletesDownloads()
        async throws
    {
        let account = try fixtureAccount()
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8).utf8
            )
        )
        let item = fixtureBook(
            id: plan.itemID.rawValue,
            title: "Downloaded",
            libraryID: fixtureLibrary().id
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatAccountRemoval-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let storage = DownloadStorage(
            layout: try DownloadStorageLayout(rootURL: root)
        )
        _ = try await storage.create(
            downloadID: DownloadID(
                rawValue: UUID().uuidString.lowercased()
            ),
            accountID: account.id,
            plan: plan,
            detail: fixtureBookDetail(item: item)
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([])
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("account-removal")
        )
        await model.start()
        XCTAssertEqual(model.downloads.records.count, 1)

        await model.removeAccount()

        XCTAssertTrue(model.downloads.records.isEmpty)
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testStartupRemovesDownloadsForUnknownAccounts() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatOrphanedDownloads-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        let account = try fixtureAccount()
        let orphanedAccountID = AccountID(rawValue: "removed-account")
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: plan.itemID.rawValue,
                title: "Downloaded",
                libraryID: fixtureLibrary().id
            )
        )
        _ = try await storage.create(
            downloadID: DownloadID(rawValue: "current-download"),
            accountID: account.id,
            plan: plan,
            detail: detail
        )
        _ = try await storage.create(
            downloadID: DownloadID(rawValue: "orphaned-download"),
            accountID: orphanedAccountID,
            plan: plan,
            detail: detail
        )

        let model = AppModel(
            service: TestAppService(
                accounts: .success([account]),
                activeAccount: .success(account)
            ),
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("unknown-account-cleanup")
        )
        await model.start()

        XCTAssertEqual(
            model.downloads.records.map(\.manifest.accountID), [account.id])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.recordURL(
                    accountID: orphanedAccountID,
                    itemID: plan.itemID
                ).path
            )
        )
    }

    func testBulkDownloadRemovalKeepsProtectedPlaybackRecord()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatBulkRemoval-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        let account = try fixtureAccount()
        let firstPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8).utf8
            )
        )
        let secondPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8)
                    .replacingOccurrences(
                        of: "\"item-1\"",
                        with: "\"item-2\""
                    )
                    .utf8
            )
        )
        let protectedID = DownloadID(rawValue: "protected-download")
        _ = try await storage.create(
            downloadID: protectedID,
            accountID: account.id,
            plan: firstPlan,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: firstPlan.itemID.rawValue,
                    title: "Playing",
                    libraryID: fixtureLibrary().id
                )
            )
        )
        _ = try await storage.create(
            downloadID: DownloadID(rawValue: "removable-download"),
            accountID: account.id,
            plan: secondPlan,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: secondPlan.itemID.rawValue,
                    title: "Remove Me",
                    libraryID: fixtureLibrary().id
                )
            )
        )
        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(nil)),
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("protected-removal")
        )
        await model.start(account: nil)

        await model.removeAll(excluding: protectedID)

        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(
            model.records.first?.manifest.downloadID,
            protectedID
        )
    }

    func testExpiredAutomaticCacheIsRemovedWithoutDeletingManualDownload()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatAutomaticCleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        let suite = "AutomaticCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let storage = DownloadStorage(
            layout: try DownloadStorageLayout(rootURL: root)
        )
        let account = try fixtureAccount()
        let automaticPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let manualPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8)
                    .replacingOccurrences(
                        of: "\"item-1\"",
                        with: "\"item-2\""
                    )
                    .utf8
            )
        )
        var automatic = try await storage.create(
            downloadID: DownloadID(rawValue: "automatic"),
            accountID: account.id,
            plan: automaticPlan,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: automaticPlan.itemID.rawValue,
                    title: "Automatic",
                    libraryID: fixtureLibrary().id
                )
            ),
            purpose: .automaticCache,
            automaticTargetTrackIndexes: Set(
                automaticPlan.tracks.map(\.index)
            )
        )
        automatic = try await storage.markBookFinished(
            automatic,
            at: Date().addingTimeInterval(-(25 * 60 * 60))
        )
        XCTAssertNotNil(automatic.manifest.bookFinishedAt)
        _ = try await storage.create(
            downloadID: DownloadID(rawValue: "manual"),
            accountID: account.id,
            plan: manualPlan,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: manualPlan.itemID.rawValue,
                    title: "Manual",
                    libraryID: fixtureLibrary().id
                )
            )
        )
        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(nil)),
            defaults: defaults,
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("automatic-cleanup")
        )

        await model.start(account: nil)

        XCTAssertEqual(
            model.records.map(\.manifest.itemID),
            [
                manualPlan.itemID
            ])
        XCTAssertEqual(model.records.first?.manifest.purpose, .manual)
    }

    func testLegacyAutomaticCacheIsDiscardedWithoutDeletingManualDownload()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatLegacyAutomatic-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        let account = try fixtureAccount()
        let legacyPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let manualPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8)
                    .replacingOccurrences(
                        of: "\"item-1\"",
                        with: "\"item-2\""
                    )
                    .utf8
            )
        )
        let manualDetail = fixtureBookDetail(
            item: fixtureBook(
                id: manualPlan.itemID.rawValue,
                title: "Manual",
                libraryID: fixtureLibrary().id
            )
        )
        _ = try await storage.create(
            downloadID: DownloadID(rawValue: "manual"),
            accountID: account.id,
            plan: manualPlan,
            detail: manualDetail
        )

        let legacyManifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "legacy-automatic"),
            accountID: account.id,
            plan: legacyPlan,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [0]
        )
        let legacyRecord = DownloadedBookRecord(
            manifest: legacyManifest,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: legacyPlan.itemID.rawValue,
                    title: "Legacy Automatic",
                    libraryID: fixtureLibrary().id
                )
            )
        )
        let legacyURL = layout.recordURL(
            accountID: account.id,
            itemID: legacyPlan.itemID
        )
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacyRecord)
            ) as? [String: Any]
        )
        var legacyManifestObject = try XCTUnwrap(
            legacyObject["manifest"] as? [String: Any]
        )
        legacyManifestObject["automaticWindow"] = nil
        legacyObject["manifest"] = legacyManifestObject
        try JSONSerialization.data(
            withJSONObject: legacyObject
        ).write(to: legacyURL)

        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(nil)),
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("legacy-automatic-cleanup")
        )
        await model.start(account: nil)

        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(
            model.records.first?.manifest.downloadID,
            DownloadID(rawValue: "manual")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyURL.path)
        )
    }

    private func prepareInterruptedDownload(
        root: URL,
        account: ServerAccount,
        detail: LibraryBookDetail,
        downloadID: String,
        committedByteCount: Int64
    ) async throws -> (plan: DownloadPlan, storage: DownloadStorage) {
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        let identity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: downloadID),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        _ = try await storage.create(
            downloadID: identity.downloadID,
            accountID: account.id,
            plan: plan,
            detail: detail
        )
        let staged = root.appendingPathComponent("staged-\(downloadID)")
        try Data(repeating: 0xAB, count: Int(committedByteCount)).write(
            to: staged
        )
        _ = try await storage.commitChunk(
            identity,
            temporaryURL: staged,
            range: try DownloadByteRange(
                start: 0,
                endInclusive: committedByteCount - 1
            ),
            validator: nil
        )
        return (plan, storage)
    }

    func testRelaunchContinuesAfterActiveTrackCompletedWhileTerminated()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatCompletedDuringTermination-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Completed during termination",
                libraryID: fixtureLibrary().id
            )
        )
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let storage = DownloadStorage(
            layout: try DownloadStorageLayout(rootURL: root)
        )
        let downloadID = DownloadID(rawValue: "terminated-after-track")
        _ = try await storage.create(
            downloadID: downloadID,
            accountID: account.id,
            plan: plan,
            detail: detail
        )
        let completedIdentity = try DownloadTaskIdentity(
            downloadID: downloadID,
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[0]
        )
        let completedTrack = root.appendingPathComponent("completed-track")
        try Data(repeating: 0xAB, count: 4).write(to: completedTrack)
        _ = try await storage.commitChunk(
            completedIdentity,
            temporaryURL: completedTrack,
            range: try DownloadByteRange(start: 0, endInclusive: 3),
            validator: nil
        )
        let storedRecords = try await storage.records()
        let interruptedRecord = try XCTUnwrap(storedRecords.first)
        // A finalized track plus untouched queued tracks remains actionable
        // queued work. Partial is reserved for interrupted or damaged bytes.
        XCTAssertEqual(interruptedRecord.manifest.state, .queued)

        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .success(plan),
            authorizedDownloadRequest: .success(request)
        )
        let telemetry = RecordingRemoteTelemetryDownloadLogger()
        let relaunched = DownloadModel(
            service: service,
            storageRootURL: root,
            remoteTelemetryDownloadLogger: telemetry,
            backgroundSessionIdentifier:
                "bleat.tests.completed-during-termination.\(UUID().uuidString)"
        )

        await relaunched.start(account: account)

        let descriptors =
            await relaunched.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(descriptors.map { $0.identity.trackIndex }, [1])
        XCTAssertEqual(descriptors.first?.range.start, 0)
        XCTAssertEqual(relaunched.records.first?.manifest.state, .downloading)
        XCTAssertTrue(
            telemetry.events.contains(where: {
                $0.stage == .taskScheduled && $0.state == .started
            })
        )
        await relaunched.removeAll()
    }

    func
        testOfflineRelaunchRecoveryResumesInterruptedDownloadFromDurableOffset()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatOfflineRelaunch-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Interrupted",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, storage) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "interrupted",
            committedByteCount: 5
        )
        let partialIdentity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "interrupted"),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        let authorizedRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/private-audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(
                .downloadPlan(.authenticatedRequest(.requestTransportFailed))
            ),
            authorizedDownloadRequest: .success(authorizedRequest)
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.offline-relaunch.\(UUID().uuidString)"
        )

        await model.start(account: account)

        let stalledDescriptors =
            await model
            .scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(stalledDescriptors.isEmpty)
        XCTAssertEqual(
            model.pendingRecoveryDownloadIDsForTesting,
            [DownloadID(rawValue: "interrupted")]
        )
        let stalledBytes = try await storage.partialByteLength(
            partialIdentity
        )
        XCTAssertEqual(stalledBytes, 5)

        await service.setDownloadPlan(.success(plan))
        await model.recoverAfterNetworkChange(for: [account])

        let descriptors =
            await model
            .scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(descriptors.map { $0.identity.trackIndex }, [1])
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(descriptor.range.start, 5)
        XCTAssertEqual(descriptor.range.length, 3)
        XCTAssertEqual(model.pendingRecoveryDownloadIDsForTesting, [])
        let requests = await service.authorizedDownloadRequestIdentities()
        XCTAssertEqual(requests.map(\.trackIndex), [1])
        let preservedBytes = try await storage.partialByteLength(
            partialIdentity
        )
        XCTAssertEqual(preservedBytes, 5)
        await model.removeAll()
    }

    func testTransportFailureWaitsForNetworkAndDropsTransientProgress()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatActiveTransferRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Interrupted active transfer",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "active-transfer",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(.downloadPlan(.unexpectedStatus(404))),
            authorizedDownloadRequest: .success(request)
        )
        let telemetry = RecordingRemoteTelemetryDownloadLogger()
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            remoteTelemetryDownloadLogger: telemetry,
            backgroundSessionIdentifier:
                "bleat.tests.active-transfer.\(UUID().uuidString)"
        )
        await model.start(account: account)
        model.updateNetworkPathState(
            AppNetworkPathState(
                availability: .unavailable,
                isConstrained: false,
                isExpensive: false
            )
        )
        XCTAssertTrue(
            model.isWaitingForNetwork(try XCTUnwrap(model.records.first))
        )
        model.updateNetworkPathState(.unknown)
        let identity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "active-transfer"),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        let range = try XCTUnwrap(
            DownloadByteRange.next(
                committedByteLength: 5,
                expectedByteLength: identity.expectedByteLength,
                chunkByteLength: DownloadModel.rangeChunkByteLength
            )
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: request)
        task.taskDescription = try DownloadChunkTaskDescription(
            identity: identity,
            range: range,
            validator: nil
        ).encode()

        model.urlSession(
            session,
            downloadTask: task,
            didWriteData: 2,
            totalBytesWritten: 2,
            totalBytesExpectedToWrite: range.length
        )
        for _ in 0..<100 {
            guard let record = model.records.first else { break }
            if model.displayedDownloadedByteLength(for: record) == 7 {
                break
            }
            await Task.yield()
        }
        let activeRecord = try XCTUnwrap(model.records.first)
        XCTAssertEqual(
            model.displayedDownloadedByteLength(for: activeRecord),
            7
        )

        model.urlSession(
            session,
            task: task,
            didCompleteWithError: URLError(.notConnectedToInternet)
        )
        for _ in 0..<100 {
            if model.pendingRecoveryDownloadIDsForTesting.contains(
                identity.downloadID
            ) {
                break
            }
            await Task.yield()
        }

        let waitingRecord = try XCTUnwrap(model.records.first)
        XCTAssertEqual(waitingRecord.manifest.state, .downloading)
        XCTAssertTrue(model.isWaitingForNetwork(waitingRecord))
        XCTAssertNil(model.failure)
        XCTAssertEqual(
            model.displayedDownloadedByteLength(for: waitingRecord),
            5
        )
        let transportFailure = try XCTUnwrap(
            telemetry.events.first(where: {
                $0.stage == .taskCompletion && $0.state == .failed
            })
        )
        XCTAssertEqual(transportFailure.failureCause, .offline)
        XCTAssertEqual(
            transportFailure.transportErrorCode,
            URLError.notConnectedToInternet.rawValue
        )
        let descriptorsWhileWaiting =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(descriptorsWhileWaiting.isEmpty)

        await service.setDownloadPlan(.success(plan))
        await model.recoverAfterNetworkChange(for: [account])

        XCTAssertTrue(model.pendingRecoveryDownloadIDsForTesting.isEmpty)
        let resumedDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(resumedDescriptors.count, 1)
        XCTAssertEqual(resumedDescriptors.first?.identity.trackIndex, 1)
        let resumedRecord = try XCTUnwrap(model.records.first)
        XCTAssertEqual(resumedRecord.manifest.state, .downloading)
        XCTAssertEqual(
            model.displayedDownloadedByteLength(for: resumedRecord),
            5
        )
        session.invalidateAndCancel()
        await model.removeAll()
    }

    func testTransportFailureUsesChangedPrimaryFallbackExactlyOnce()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatPrimaryFallback-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Local fallback",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "primary-fallback",
            committedByteCount: 5
        )
        let localURL = try XCTUnwrap(
            URL(string: "https://192.0.2.1/audio")
        )
        let primaryURL = try XCTUnwrap(
            URL(string: "https://192.0.2.2/audio")
        )
        let failedRequests = ["bytes=0-3", "bytes=5-7"].map { range in
            var request = URLRequest(url: localURL)
            request.setValue(range, forHTTPHeaderField: "Range")
            request.setValue(
                "\"validator\"",
                forHTTPHeaderField: "If-Range"
            )
            return request
        }
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(.downloadPlan(.unexpectedStatus(404))),
            authorizedDownloadRequest: .success(failedRequests[0]),
            primaryFallbackURL: primaryURL
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.primary-fallback.\(UUID().uuidString)"
        )
        await model.start(account: account)
        let identities = try plan.tracks.map { track in
            try DownloadTaskIdentity(
                downloadID: DownloadID(rawValue: "primary-fallback"),
                accountID: account.id,
                itemID: detail.id,
                track: track
            )
        }
        let ranges = try [
            XCTUnwrap(
                DownloadByteRange.next(
                    committedByteLength: 0,
                    expectedByteLength: identities[0].expectedByteLength,
                    chunkByteLength: DownloadModel.rangeChunkByteLength
                )
            ),
            XCTUnwrap(
                DownloadByteRange.next(
                    committedByteLength: 5,
                    expectedByteLength: identities[1].expectedByteLength,
                    chunkByteLength: DownloadModel.rangeChunkByteLength
                )
            ),
        ]
        let session = URLSession(configuration: .ephemeral)
        let tasks = try zip(identities, ranges).enumerated().map {
            index, pair in
            let task = session.downloadTask(with: failedRequests[index])
            task.taskDescription = try DownloadChunkTaskDescription(
                identity: pair.0,
                range: pair.1,
                validator: nil
            ).encode()
            return task
        }
        for task in tasks {
            model.urlSession(
                session,
                task: task,
                didCompleteWithError: URLError(.cannotConnectToHost)
            )
        }
        var fallbackRequests: [URLRequest] = []
        for _ in 0..<100 {
            fallbackRequests =
                await model.scheduledTransferRequestsForTesting()
            if fallbackRequests.count == 2 {
                break
            }
            await Task.yield()
        }

        XCTAssertEqual(fallbackRequests.count, 2)
        XCTAssertTrue(fallbackRequests.allSatisfy { $0.url == primaryURL })
        XCTAssertEqual(
            Set(fallbackRequests.compactMap {
                $0.value(forHTTPHeaderField: "Range")
            }),
            ["bytes=0-3", "bytes=5-7"]
        )
        XCTAssertTrue(
            fallbackRequests.allSatisfy {
                $0.value(forHTTPHeaderField: "If-Range")
                    == "\"validator\""
            }
        )
        XCTAssertTrue(model.pendingRecoveryDownloadIDsForTesting.isEmpty)
        let descriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(descriptors.count, 2)
        XCTAssertEqual(
            descriptors.map(\.identity.trackIndex).sorted(),
            [0, 1]
        )
        session.invalidateAndCancel()
        await model.removeAll()
    }

    func testTransportRetryDoesNotScheduleAfterNetworkDropsDuringBackoff()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatRetryNetworkDrop-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Network drops during retry",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "retry-network-drop",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(.downloadPlan(.unexpectedStatus(404))),
            authorizedDownloadRequest: .success(request)
        )
        let retryGate = AsyncGate()
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.retry-network-drop.\(UUID().uuidString)",
            transferRetrySleep: { _ in
                await retryGate.enterAndWait()
            }
        )
        await model.start(account: account)
        model.updateNetworkPathState(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: false,
                isExpensive: false
            )
        )
        let identity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "retry-network-drop"),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        let range = try XCTUnwrap(
            DownloadByteRange.next(
                committedByteLength: 5,
                expectedByteLength: identity.expectedByteLength,
                chunkByteLength: DownloadModel.rangeChunkByteLength
            )
        )
        let session = URLSession(configuration: .ephemeral)
        let task = session.downloadTask(with: request)
        task.taskDescription = try DownloadChunkTaskDescription(
            identity: identity,
            range: range,
            validator: nil
        ).encode()

        model.urlSession(
            session,
            task: task,
            didCompleteWithError: URLError(.networkConnectionLost)
        )
        await retryGate.waitUntilEntered()
        XCTAssertEqual(model.transferRetryCountForTesting(identity), 1)
        model.updateNetworkPathState(
            AppNetworkPathState(
                availability: .unavailable,
                isConstrained: false,
                isExpensive: false
            )
        )
        await retryGate.release()
        for _ in 0..<100 { await Task.yield() }

        let scheduledDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(scheduledDescriptors.isEmpty)
        XCTAssertEqual(
            model.pendingRecoveryDownloadIDsForTesting,
            [identity.downloadID]
        )
        XCTAssertTrue(
            model.isWaitingForNetwork(try XCTUnwrap(model.records.first))
        )
        await model.pause(try XCTUnwrap(model.records.first))
        XCTAssertEqual(model.transferRetryCountForTesting(identity), 0)
        session.invalidateAndCancel()
        await model.removeAll()
    }

    func testRetryAfterHeaderDelaysRetryableServerReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatRetryAfter-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Server-directed retry",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "retry-after",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let primaryURL = try XCTUnwrap(
            URL(string: "https://192.0.2.2/audio")
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(.downloadPlan(.unexpectedStatus(404))),
            authorizedDownloadRequest: .success(request),
            primaryFallbackURL: primaryURL
        )
        let retryDelayGate = RetryDelayGate()
        let telemetry = RecordingRemoteTelemetryDownloadLogger()
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            remoteTelemetryDownloadLogger: telemetry,
            backgroundSessionIdentifier:
                "bleat.tests.retry-after.\(UUID().uuidString)",
            transferRetrySleep: { duration in
                await retryDelayGate.recordAndWait(duration)
            }
        )
        await model.start(account: account)
        model.updateNetworkPathState(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: false,
                isExpensive: false
            )
        )
        let identity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "retry-after"),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        let range = try XCTUnwrap(
            DownloadByteRange.next(
                committedByteLength: 5,
                expectedByteLength: identity.expectedByteLength,
                chunkByteLength: DownloadModel.rangeChunkByteLength
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryAfterDownloadURLProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: model,
            delegateQueue: nil
        )
        let task = session.downloadTask(with: request)
        task.taskDescription = try DownloadChunkTaskDescription(
            identity: identity,
            range: range,
            validator: nil
        ).encode()
        task.resume()

        await retryDelayGate.waitUntilEntered()
        let observedDelay = await retryDelayGate.observedDelay()
        XCTAssertEqual(observedDelay, .seconds(120))
        XCTAssertEqual(model.transferRetryCountForTesting(identity), 1)
        let retryEvent = try XCTUnwrap(
            telemetry.events.last(where: { $0.stage == .retryScheduled })
        )
        XCTAssertEqual(retryEvent.retryDelaySeconds, 120)
        XCTAssertEqual(retryEvent.retryDelaySource, .serverRetryAfter)

        let relaunched = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.retry-after-relaunch.\(UUID().uuidString)"
        )
        await relaunched.start(account: account)
        let relaunchedDescriptors =
            await relaunched.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(relaunchedDescriptors.isEmpty)
        XCTAssertNotNil(
            relaunched.records.first?.manifest.entries.first(where: {
                $0.trackIndex == identity.trackIndex
            })?.retryNotBefore
        )

        await service.setDownloadPlan(.success(plan))
        await model.recoverAfterNetworkChange(for: [account])
        let earlyDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(earlyDescriptors.isEmpty)

        await retryDelayGate.release()
        var replacementDescriptors: [DownloadChunkTaskDescription] = []
        for _ in 0..<100 {
            replacementDescriptors =
                await model.scheduledTransferDescriptorsForTesting()
            if replacementDescriptors.count == 1 {
                break
            }
            await Task.yield()
        }
        XCTAssertEqual(replacementDescriptors.count, 1)
        XCTAssertEqual(replacementDescriptors.first?.range.start, 5)
        let replacementRequests =
            await model.scheduledTransferRequestsForTesting()
        XCTAssertEqual(replacementRequests.first?.url, primaryURL)
        session.invalidateAndCancel()
        await relaunched.cancel(try XCTUnwrap(relaunched.records.first))
        await model.removeAll()
    }

    func testRetryAfterExpiryAndNetworkRecoveryScheduleOneTransfer()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatRetryAfterExpiry-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Concurrent server retry",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "retry-after-expiry",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(.downloadPlan(.unexpectedStatus(404))),
            authorizedDownloadRequest: .success(request)
        )
        let retryDelayGate = RetryDelayGate()
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.retry-after-expiry.\(UUID().uuidString)",
            transferRetrySleep: { duration in
                await retryDelayGate.recordAndWait(duration)
            }
        )
        await model.start(account: account)
        model.updateNetworkPathState(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: false,
                isExpensive: false
            )
        )
        let identity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "retry-after-expiry"),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        let range = try XCTUnwrap(
            DownloadByteRange.next(
                committedByteLength: 5,
                expectedByteLength: identity.expectedByteLength,
                chunkByteLength: DownloadModel.rangeChunkByteLength
            )
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            ExpiringRetryAfterDownloadURLProtocol.self
        ]
        let session = URLSession(
            configuration: configuration,
            delegate: model,
            delegateQueue: nil
        )
        let task = session.downloadTask(with: request)
        task.taskDescription = try DownloadChunkTaskDescription(
            identity: identity,
            range: range,
            validator: nil
        ).encode()
        task.resume()

        await retryDelayGate.waitUntilEntered()
        let observedDelay = await retryDelayGate.observedDelay()
        XCTAssertEqual(observedDelay, .seconds(1))
        await service.setDownloadPlan(.success(plan))
        try await Task.sleep(for: .milliseconds(1_100))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await retryDelayGate.release()
            }
            group.addTask {
                await model.recoverAfterNetworkChange(for: [account])
            }
        }
        await model.recoverAfterNetworkChange(for: [account])

        var descriptors: [DownloadChunkTaskDescription] = []
        for _ in 0..<100 {
            descriptors = await model.scheduledTransferDescriptorsForTesting()
            if descriptors.count == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(descriptors.count, 1)
        XCTAssertEqual(descriptors.first?.range.start, 5)
        session.invalidateAndCancel()
        await model.removeAll()
    }

    func testRepairDurablyResetsRetryBudgetBeforeScheduling() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatRetryReset-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "User retry reset",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "retry-reset",
            committedByteCount: 5
        )
        let identity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "retry-reset"),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        _ = try await storage.deferRetry(
            identity,
            until: Date().addingTimeInterval(120),
            retryCount: DownloadModel.maximumTransferRetries
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(.downloadPlan(.unexpectedStatus(404))),
            authorizedDownloadRequest: .success(request)
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.retry-reset.\(UUID().uuidString)"
        )
        await model.start(account: account)
        XCTAssertEqual(
            model.transferRetryCountForTesting(identity),
            DownloadModel.maximumTransferRetries
        )

        await service.setDownloadPlan(.success(plan))
        await model.repair(try XCTUnwrap(model.records.first), account: account)

        XCTAssertEqual(model.transferRetryCountForTesting(identity), 0)
        let recreated = DownloadStorage(layout: layout)
        let recreatedRecords = try await recreated.records()
        let entry = try XCTUnwrap(
            recreatedRecords.first?.manifest.entries.first(
                where: { $0.trackIndex == identity.trackIndex }
            )
        )
        XCTAssertNil(entry.retryNotBefore)
        XCTAssertNil(entry.transferRetryCount)
        await model.removeAll()
    }

    func testNetworkRecoveryLeavesUserPausedDownloadsPaused() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatPausedRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Paused",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, storage) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "paused",
            committedByteCount: 5
        )
        _ = try await storage.markPaused(
            try DownloadTaskIdentity(
                downloadID: DownloadID(rawValue: "paused"),
                accountID: account.id,
                itemID: detail.id,
                track: plan.tracks[1]
            ),
            observedByteLength: 5
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(
                .downloadPlan(.authenticatedRequest(.requestTransportFailed))
            )
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("paused-network-recovery")
        )

        await model.start(account: account)

        let pausedDescriptors =
            await model
            .scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(pausedDescriptors.isEmpty)

        await service.setDownloadPlan(.success(plan))
        await model.recoverAfterNetworkChange(for: [account])

        let resumedDescriptors =
            await model
            .scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(resumedDescriptors.isEmpty)
        XCTAssertTrue(model.pendingRecoveryDownloadIDsForTesting.isEmpty)
        let record = try XCTUnwrap(model.records.first)
        XCTAssertEqual(record.manifest.state, .paused)
    }

    func testPauseIntentPrecedesConcurrentTerminalCallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatPauseCallbackRace-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Pause callback race",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "pause-callback-race",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let gate = AsyncGate()
        let model = DownloadModel(
            service: TestAppService(
                activeAccount: .success(account),
                downloadPlan: .success(plan),
                authorizedDownloadRequest: .success(request)
            ),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.pause-callback-race.\(UUID().uuidString)",
            pauseOperationCheckpoint: {
                await gate.enterAndWait()
            }
        )
        await model.start(account: account)
        let scheduledDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        let descriptor = try XCTUnwrap(scheduledDescriptors.first)
        let record = try XCTUnwrap(model.records.first)

        let pauseTask = Task { @MainActor in
            await model.pause(record)
        }
        await gate.waitUntilEntered()

        let callbackConfiguration = URLSessionConfiguration.ephemeral
        callbackConfiguration.protocolClasses = [
            PauseTerminalFailureURLProtocol.self
        ]
        let callbackSession = URLSession(
            configuration: callbackConfiguration,
            delegate: model,
            delegateQueue: nil
        )
        let callbackTask = callbackSession.downloadTask(with: request)
        callbackTask.taskDescription = try descriptor.encode()
        callbackTask.resume()
        for _ in 0..<200 {
            if callbackTask.state == .completed,
                model.records.first?.manifest.state == .failed
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(model.pausedDownloadIDs.contains(record.manifest.downloadID))
        XCTAssertNil(model.failure)
        XCTAssertNotEqual(model.records.first?.manifest.state, .failed)

        await gate.release()
        await pauseTask.value
        callbackSession.invalidateAndCancel()

        XCTAssertEqual(model.records.first?.manifest.state, .paused)
        await model.removeAll()
    }

    func testDownloadDiagnosticsRemainOrderedWithoutBlockingStart()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatOrderedDownloadDiagnostics-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = AsyncGate()
        let diagnostics = GatedOrderedDownloadDiagnosticRecorder(gate: gate)
        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(nil)),
            storageRootURL: root,
            diagnostics: diagnostics,
            backgroundSessionIdentifier:
                "bleat.tests.ordered-download-diagnostics.\(UUID().uuidString)"
        )

        await model.start(account: nil)
        await gate.waitUntilEntered()
        await gate.release()

        var events: [DiagnosticEvent] = []
        for _ in 0..<100 {
            events = await diagnostics.events()
            if events.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            events.map(\.name),
            [.operationStarted, .operationCompleted]
        )
        XCTAssertEqual(
            events.map(\.operation),
            [.restoreDownloads, .restoreDownloads]
        )
    }

    func testPauseStorageFailureIsVisibleAndDoesNotResume() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatPauseStorageFailure-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Pause storage failure",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "pause-storage-failure",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let completedIdentity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "pause-storage-failure"),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        let finalChunk = root.appendingPathComponent(
            "pause-storage-failure-final-chunk"
        )
        try Data(repeating: 0xEF, count: 3).write(to: finalChunk)
        let model = DownloadModel(
            service: TestAppService(
                activeAccount: .success(account),
                downloadPlan: .success(plan),
                authorizedDownloadRequest: .success(request)
            ),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.pause-storage-failure.\(UUID().uuidString)",
            pauseManifestCommit: { commitStorage, _, _ in
                _ = try await commitStorage.commitChunk(
                    completedIdentity,
                    temporaryURL: finalChunk,
                    range: try DownloadByteRange(
                        start: 5,
                        endInclusive: 7
                    ),
                    validator: nil
                )
                throw DownloadStorageError.persistenceFailed
            }
        )
        await model.start(account: account)
        let record = try XCTUnwrap(model.records.first)

        await model.pause(record)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.failure, .storageUnavailable)
        XCTAssertEqual(model.records.first?.manifest.state, .failed)
        XCTAssertEqual(model.records.first?.manifest.entries[1].state, .complete)
        XCTAssertEqual(
            model.records.first?.manifest.entries[1].placement,
            .finalized
        )
        XCTAssertFalse(
            model.pausedDownloadIDs.contains(record.manifest.downloadID)
        )
        let descriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(descriptors.isEmpty)

        let relaunchedModel = DownloadModel(
            service: TestAppService(
                activeAccount: .success(account),
                downloadPlan: .success(plan),
                authorizedDownloadRequest: .success(request)
            ),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.pause-storage-relaunch.\(UUID().uuidString)"
        )
        await relaunchedModel.start(account: account)
        XCTAssertEqual(
            relaunchedModel.records.first?.manifest.state,
            .failed
        )
        let relaunchedDescriptors =
            await relaunchedModel.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(relaunchedDescriptors.isEmpty)
        await relaunchedModel.removeAll()
    }

    func testPauseDoesNotOverwriteTrackCompletedWhilePending() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatPauseCompletedTrackRace-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Pause completed track race",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, storage) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "pause-completed-track-race",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let gate = AsyncGate()
        let model = DownloadModel(
            service: TestAppService(
                activeAccount: .success(account),
                downloadPlan: .success(plan),
                authorizedDownloadRequest: .success(request)
            ),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.pause-completed-track-race.\(UUID().uuidString)",
            pauseOperationCheckpoint: {
                await gate.enterAndWait()
            }
        )
        await model.start(account: account)
        let record = try XCTUnwrap(model.records.first)
        let completedIdentity = try DownloadTaskIdentity(
            downloadID: record.manifest.downloadID,
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )

        let pauseTask = Task { @MainActor in
            await model.pause(record)
        }
        await gate.waitUntilEntered()
        let finalChunk = root.appendingPathComponent("final-pause-chunk")
        try Data(repeating: 0xCD, count: 3).write(to: finalChunk)
        _ = try await storage.commitChunk(
            completedIdentity,
            temporaryURL: finalChunk,
            range: try DownloadByteRange(start: 5, endInclusive: 7),
            validator: nil
        )
        await gate.release()
        await pauseTask.value

        let updated = try XCTUnwrap(model.records.first)
        XCTAssertEqual(updated.manifest.entries[1].state, .complete)
        XCTAssertEqual(updated.manifest.entries[1].placement, .finalized)
        let layout = try DownloadStorageLayout(rootURL: root)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.destinationURL(for: completedIdentity).path
            )
        )
        XCTAssertEqual(updated.manifest.entries[0].state, .paused)
        XCTAssertEqual(updated.manifest.state, .paused)
        await model.removeAll()
    }

    func testCancelSupersedesGatedPause() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatCancelSupersedesPause-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Cancel supersedes pause",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "cancel-supersedes-pause",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let gate = AsyncGate()
        let model = DownloadModel(
            service: TestAppService(
                activeAccount: .success(account),
                downloadPlan: .success(plan),
                authorizedDownloadRequest: .success(request)
            ),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.cancel-supersedes-pause.\(UUID().uuidString)",
            pauseOperationCheckpoint: {
                await gate.enterAndWait()
            }
        )
        await model.start(account: account)
        let record = try XCTUnwrap(model.records.first)

        let pauseTask = Task { @MainActor in
            await model.pause(record)
        }
        await gate.waitUntilEntered()
        await model.cancel(record)
        await gate.release()
        await pauseTask.value

        XCTAssertEqual(model.records.first?.manifest.state, .cancelled)
        XCTAssertFalse(
            model.pausedDownloadIDs.contains(record.manifest.downloadID)
        )
        let descriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(descriptors.isEmpty)
        await model.removeAll()
    }

    func testAccountRemovalInvalidatesGatedPauseAndDeletesDownload()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatAccountRemovalDuringPause-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Account removal during pause",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "account-removal-during-pause",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let gate = AsyncGate()
        let model = DownloadModel(
            service: TestAppService(
                activeAccount: .success(account),
                downloadPlan: .success(plan),
                authorizedDownloadRequest: .success(request)
            ),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.account-removal-pause.\(UUID().uuidString)",
            pauseOperationCheckpoint: {
                await gate.enterAndWait()
            }
        )
        await model.start(account: account)
        let record = try XCTUnwrap(model.records.first)

        let pauseTask = Task { @MainActor in
            await model.pause(record)
        }
        await gate.waitUntilEntered()
        await model.removeAll(for: account.id)
        await gate.release()
        await pauseTask.value

        XCTAssertTrue(model.records.isEmpty)
        let layout = try DownloadStorageLayout(rootURL: root)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.recordURL(
                    accountID: account.id,
                    itemID: detail.id
                ).path
            )
        )
        let descriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(descriptors.isEmpty)
    }

    func testCancelledDownloadRejectsDelayedPause() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatCancelRejectsPause-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Cancel rejects delayed pause",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "cancel-rejects-pause",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let model = DownloadModel(
            service: TestAppService(
                activeAccount: .success(account),
                downloadPlan: .success(plan),
                authorizedDownloadRequest: .success(request)
            ),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.cancel-rejects-pause.\(UUID().uuidString)"
        )
        await model.start(account: account)
        let staleRecord = try XCTUnwrap(model.records.first)

        await model.cancel(staleRecord)
        await model.pause(staleRecord)

        XCTAssertEqual(model.records.first?.manifest.state, .cancelled)
        XCTAssertFalse(
            model.pausedDownloadIDs.contains(staleRecord.manifest.downloadID)
        )
        let descriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(descriptors.isEmpty)
        await model.removeAll()
    }

    func testGatedPauseRejectsConcurrentContinue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatContinueSupersedesPause-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Continue supersedes pause",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "continue-supersedes-pause",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let gate = AsyncGate()
        let model = DownloadModel(
            service: TestAppService(
                activeAccount: .success(account),
                downloadPlan: .success(plan),
                authorizedDownloadRequest: .success(request)
            ),
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.continue-supersedes-pause.\(UUID().uuidString)",
            pauseOperationCheckpoint: {
                await gate.enterAndWait()
            }
        )
        await model.start(account: account)
        let record = try XCTUnwrap(model.records.first)

        let pauseTask = Task { @MainActor in
            await model.pause(record)
        }
        await gate.waitUntilEntered()
        await model.continueDownload(record)
        await gate.release()
        await pauseTask.value

        XCTAssertEqual(model.records.first?.manifest.state, .paused)
        XCTAssertTrue(
            model.pausedDownloadIDs.contains(record.manifest.downloadID)
        )
        let descriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertNil(model.failure)
        await model.removeAll()
    }

    func testCancelSupersedesGatedContinue() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatCancelSupersedesContinue-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Cancel supersedes continue",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "cancel-supersedes-continue",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .success(plan),
            authorizedDownloadRequest: .success(request)
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.cancel-supersedes-continue.\(UUID().uuidString)"
        )
        await model.start(account: account)
        await model.pause(try XCTUnwrap(model.records.first))
        let pausedRecord = try XCTUnwrap(model.records.first)

        let repairGate = AsyncGate()
        await service.setDownloadPlanGate(repairGate)
        let continueTask = Task { @MainActor in
            await model.continueDownload(pausedRecord)
        }
        await repairGate.waitUntilEntered()
        await model.cancel(pausedRecord)
        await repairGate.release()
        await continueTask.value

        XCTAssertEqual(model.records.first?.manifest.state, .cancelled)
        XCTAssertFalse(
            model.pausedDownloadIDs.contains(pausedRecord.manifest.downloadID)
        )
        let descriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(descriptors.isEmpty)
        XCTAssertNil(model.failure)
        await model.removeAll()
    }

    func testLateCancelledTaskCallbackDoesNotFailContinuedDownload()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatLatePausedCallback-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Late paused callback",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "late-paused-callback",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .success(plan),
            authorizedDownloadRequest: .success(request)
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.late-paused-callback.\(UUID().uuidString)"
        )
        await model.start(account: account)
        let initialDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        let oldDescriptor = try XCTUnwrap(initialDescriptors.first)

        await model.pause(try XCTUnwrap(model.records.first))
        await model.continueDownload(try XCTUnwrap(model.records.first))
        let continuedDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(
            continuedDescriptors.count,
            1,
            "continued descriptors: \(continuedDescriptors)"
        )
        XCTAssertEqual(model.records.first?.manifest.state, .downloading)
        if let continuedDescriptor = continuedDescriptors.first {
            XCTAssertNotEqual(
                continuedDescriptor.transferID,
                oldDescriptor.transferID
            )
        }

        let lateConfiguration = URLSessionConfiguration.ephemeral
        lateConfiguration.protocolClasses = [
            LateTransferDownloadURLProtocol.self
        ]
        let lateSession = URLSession(
            configuration: lateConfiguration,
            delegate: model,
            delegateQueue: nil
        )
        let lateRequest = DownloadRangeRequest.applying(
            range: oldDescriptor.range,
            validator: oldDescriptor.validator,
            to: request
        )
        let lateTask = lateSession.downloadTask(with: lateRequest)
        lateTask.taskDescription = try oldDescriptor.encode()
        lateTask.resume()
        for _ in 0..<200 {
            let descriptors =
                await model.scheduledTransferDescriptorsForTesting()
            if lateTask.state == .completed, descriptors.count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(model.failure)
        XCTAssertTrue(model.pendingRecoveryDownloadIDsForTesting.isEmpty)
        let finalDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(
            finalDescriptors.count,
            1,
            "final descriptors: \(finalDescriptors)"
        )
        XCTAssertEqual(model.records.first?.manifest.state, .downloading)
        let identity = oldDescriptor.identity
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        let partialByteLength = try await storage.partialByteLength(identity)
        XCTAssertEqual(partialByteLength, 5)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.destinationURL(for: identity).path
            )
        )
        lateSession.invalidateAndCancel()
        await model.removeAll()
    }

    func testLateCancelledTaskCallbackDoesNotRestartDownload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatLateCancelledCallback-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Late cancelled callback",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, storage) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "late-cancelled-callback",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .success(plan),
            authorizedDownloadRequest: .success(request)
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.late-cancelled-callback.\(UUID().uuidString)"
        )
        await model.start(account: account)
        let initialDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        let oldDescriptor = try XCTUnwrap(initialDescriptors.first)

        await model.cancel(try XCTUnwrap(model.records.first))
        XCTAssertEqual(model.records.first?.manifest.state, .cancelled)

        let repairGate = AsyncGate()
        await service.setDownloadPlanGate(repairGate)
        let cancelledRecord = try XCTUnwrap(model.records.first)
        let repairTask = Task { @MainActor in
            await model.repair(cancelledRecord, account: account)
        }
        await repairGate.waitUntilEntered()

        let lateConfiguration = URLSessionConfiguration.ephemeral
        lateConfiguration.protocolClasses = [
            LateTransferDownloadURLProtocol.self
        ]
        let lateSession = URLSession(
            configuration: lateConfiguration,
            delegate: model,
            delegateQueue: nil
        )
        let lateRequest = DownloadRangeRequest.applying(
            range: oldDescriptor.range,
            validator: oldDescriptor.validator,
            to: request
        )
        let lateTask = lateSession.downloadTask(with: lateRequest)
        lateTask.taskDescription = try oldDescriptor.encode()
        lateTask.resume()
        for _ in 0..<200 where lateTask.state != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }

        let cancelledDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(cancelledDescriptors.isEmpty)
        XCTAssertTrue(model.pendingRecoveryDownloadIDsForTesting.isEmpty)
        XCTAssertEqual(model.records.first?.manifest.state, .cancelled)
        let cancelledPartialByteLength = try await storage.partialByteLength(
            oldDescriptor.identity
        )
        XCTAssertEqual(cancelledPartialByteLength, 0)

        await repairGate.release()
        await repairTask.value
        let retriedDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(retriedDescriptors.count, 1)
        XCTAssertEqual(retriedDescriptors.first?.range.start, 0)
        XCTAssertEqual(model.records.first?.manifest.state, .downloading)
        XCTAssertFalse(
            model.records.first?.manifest.entries.contains(where: {
                $0.state == .cancelled
            }) ?? true
        )
        lateSession.invalidateAndCancel()
        await model.removeAll()
    }

    func testSystemResumedRangeSuffixRetriesFromDurableOffset()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatSystemResumedSuffix-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "System resumed suffix",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, storage) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "system-resumed-suffix",
            committedByteCount: 5
        )
        let request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(.downloadPlan(.unexpectedStatus(404))),
            authorizedDownloadRequest: .success(request)
        )
        let replacementGate = AsyncGate()
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.system-resumed-suffix.\(UUID().uuidString)",
            transferRetrySleep: { _ in },
            replacementTaskStartCheckpoint: {
                await replacementGate.enterAndWait()
            }
        )
        await model.start(account: account)
        model.updateNetworkPathState(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: false,
                isExpensive: false
            )
        )
        let initialDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(initialDescriptors.isEmpty)
        let identity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "system-resumed-suffix"),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        let range = try DownloadByteRange(start: 5, endInclusive: 7)
        let validator = DownloadValidator.strongETag("\"current\"")
        let descriptor = DownloadChunkTaskDescription(
            identity: identity,
            range: range,
            validator: validator
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            SystemResumedSuffixDownloadURLProtocol.self
        ]
        let resumedSession = URLSession(
            configuration: configuration,
            delegate: model,
            delegateQueue: nil
        )
        let resumedSuffixRequest = DownloadRangeRequest.applying(
            range: try DownloadByteRange(start: 6, endInclusive: 7),
            validator: .strongETag("\"stale\""),
            to: request
        )
        let resumedTask = resumedSession.downloadTask(
            with: resumedSuffixRequest
        )
        resumedTask.taskDescription = try descriptor.encode()
        resumedTask.resume()

        var scheduledDescriptors: [DownloadChunkTaskDescription] = []
        for _ in 0..<200 {
            scheduledDescriptors =
                await model.scheduledTransferDescriptorsForTesting()
            if scheduledDescriptors.count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertNil(model.failure)
        XCTAssertEqual(scheduledDescriptors.count, 1)
        XCTAssertEqual(scheduledDescriptors.first?.range, range)
        XCTAssertEqual(model.transferRetryCountForTesting(identity), 1)
        let scheduledRequests =
            await model.scheduledTransferRequestsForTesting()
        XCTAssertEqual(
            scheduledRequests.first?.value(
                forHTTPHeaderField: "Range"
            ),
            "bytes=5-7"
        )
        XCTAssertEqual(
            scheduledRequests.first?.value(
                forHTTPHeaderField: "If-Range"
            ),
            validator.headerValue
        )
        let remainingPartialBytes =
            try await storage.partialByteLength(identity)
        XCTAssertEqual(remainingPartialBytes, 5)
        let layout = try DownloadStorageLayout(rootURL: root)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: layout.destinationURL(for: identity).path
            )
        )
        resumedSession.invalidateAndCancel()
        await model.removeAll()
        await replacementGate.release()
    }

    func testOfflineRelaunchDoesNotRetryPermanentPlanFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatPermanentRecoveryFailure-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Missing",
                libraryID: fixtureLibrary().id
            )
        )
        _ = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "missing-download",
            committedByteCount: 5
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(.downloadPlan(.unexpectedStatus(404)))
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("permanent-recovery-failure")
        )

        await model.start(account: account)
        await model.recoverAfterNetworkChange(for: [account])

        XCTAssertTrue(model.pendingRecoveryDownloadIDsForTesting.isEmpty)
        let planRequests = await service.downloadPlanRequests()
        XCTAssertEqual(planRequests.count, 1)
    }

    func testNetworkRecoveryReplacesStaleBackgroundTransfer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatStaleRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Stale transfer",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "stale-transfer",
            committedByteCount: 5
        )
        let authorizedRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/private-audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(
                .downloadPlan(.authenticatedRequest(.requestTransportFailed))
            ),
            authorizedDownloadRequest: .success(authorizedRequest)
        )
        let sessionIdentifier = backgroundSessionIdentifier("stale-recovery")
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier: sessionIdentifier
        )
        await model.start(account: account)
        XCTAssertEqual(
            model.pendingRecoveryDownloadIDsForTesting,
            [DownloadID(rawValue: "stale-transfer")]
        )

        let staleIdentity = try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "stale-transfer"),
            accountID: account.id,
            itemID: detail.id,
            track: plan.tracks[1]
        )
        let staleConfiguration = URLSessionConfiguration.background(
            withIdentifier: sessionIdentifier
        )
        let staleSession = URLSession(configuration: staleConfiguration)
        let staleTask = staleSession.downloadTask(with: authorizedRequest)
        staleTask.taskDescription = try DownloadChunkTaskDescription(
            identity: staleIdentity,
            range: try DownloadByteRange(start: 0, endInclusive: 3),
            validator: nil
        ).encode()

        await service.setDownloadPlan(.success(plan))
        await model.recoverAfterNetworkChange(for: [account])

        let descriptors = await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(descriptors.map { $0.identity.trackIndex }, [1])
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(descriptor.range.start, 5)
        XCTAssertEqual(model.pendingRecoveryDownloadIDsForTesting, [])
        let requests = await service.authorizedDownloadRequestIdentities()
        XCTAssertEqual(requests.map(\.trackIndex), [1])
        staleSession.invalidateAndCancel()
        await model.removeAll()

        var remainingDescriptors =
            await model.scheduledTransferDescriptorsForTesting()
        for _ in 0..<200 where !remainingDescriptors.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            remainingDescriptors =
                await model.scheduledTransferDescriptorsForTesting()
        }
        XCTAssertTrue(remainingDescriptors.isEmpty)
    }

    func testRepeatedNetworkRecoveryDoesNotDuplicateTransfers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatRecoveryDedup-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Dedup",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "dedup",
            committedByteCount: 5
        )
        let authorizedRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/private-audio"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(
                .downloadPlan(.authenticatedRequest(.requestTransportFailed))
            ),
            authorizedDownloadRequest: .success(authorizedRequest)
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("recovery-deduplication")
        )
        await model.start(account: account)

        await service.setDownloadPlan(.success(plan))
        await model.recoverAfterNetworkChange(for: [account])
        await model.recoverAfterNetworkChange(for: [account])

        let descriptors =
            await model
            .scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(descriptors.map { $0.identity.trackIndex }, [1])
        let planRequests = await service.downloadPlanRequests()
        XCTAssertEqual(planRequests.count, 2)
        let transferRequests =
            await service
            .authorizedDownloadRequestIdentities()
        XCTAssertEqual(transferRequests.map(\.trackIndex), [1])
        await model.removeAll()
    }

    func testNetworkRecoveryIsScopedToTheRequestedAccount() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatRecoveryScope-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstAccount = try fixtureAccount(accountID: "account-1")
        let secondAccount = try fixtureAccount(accountID: "account-2")
        let firstDetail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "First",
                libraryID: fixtureLibrary().id
            )
        )
        let secondDetail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Second",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: firstAccount,
            detail: firstDetail,
            downloadID: "first-account",
            committedByteCount: 5
        )
        _ = try await prepareInterruptedDownload(
            root: root,
            account: secondAccount,
            detail: secondDetail,
            downloadID: "second-account",
            committedByteCount: 5
        )
        let authorizedRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/private-audio"))
        )
        let service = TestAppService(
            activeAccount: .success(firstAccount),
            downloadPlan: .failure(
                .downloadPlan(.authenticatedRequest(.requestTransportFailed))
            ),
            authorizedDownloadRequest: .success(authorizedRequest)
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("account-scoped-recovery")
        )
        await model.start(account: firstAccount)
        await model.start(account: secondAccount)

        await service.setDownloadPlan(.success(plan))
        await model.recoverAfterNetworkChange(for: [firstAccount])

        var descriptors =
            await model
            .scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(
            descriptors.map { $0.identity.accountID.rawValue },
            ["account-1"]
        )

        await model.recoverAfterNetworkChange(for: [secondAccount])
        descriptors = await model.scheduledTransferDescriptorsForTesting()
        XCTAssertEqual(
            descriptors.map { $0.identity.accountID.rawValue },
            [
                "account-1", "account-2",
            ]
        )
        await model.removeAll()
    }

    func testNetworkPathUpdateResumesInterruptedDownloadAfterOfflineRelaunch()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatRecoveryWiring-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Reconnect",
                libraryID: fixtureLibrary().id
            )
        )
        let (plan, _) = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "reconnect",
            committedByteCount: 5
        )
        let authorizedRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://192.0.2.1/private-audio"))
        )
        let service = TestAppService(
            accounts: .success([account]),
            activeAccount: .success(account),
            downloadPlan: .failure(
                .downloadPlan(.authenticatedRequest(.requestTransportFailed))
            ),
            authorizedDownloadRequest: .success(authorizedRequest)
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("network-path-recovery")
        )

        await model.start()
        XCTAssertEqual(model.phase, .signedIn)
        let stalledDescriptors = await model.downloads
            .scheduledTransferDescriptorsForTesting()
        XCTAssertTrue(stalledDescriptors.isEmpty)

        await service.setDownloadPlan(.success(plan))
        for _ in 0..<100 {
            if await service.networkPathObserverCount() == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await service.emitNetworkPathUpdate()

        var descriptors: [DownloadChunkTaskDescription] = []
        for _ in 0..<500 {
            descriptors = await model.downloads
                .scheduledTransferDescriptorsForTesting()
            if descriptors.count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(descriptors.map { $0.identity.trackIndex }, [1])
        let descriptor = try XCTUnwrap(descriptors.first)
        XCTAssertEqual(descriptor.range.start, 5)
        await model.downloads.removeAll()
    }

    func testDownloadFailuresHaveDistinctMessages() {
        let failures: [DownloadModelFailure] = [
            .storageUnavailable,
            .permissionDenied,
            .preparationFailed,
            .repairPlanChanged,
            .insufficientStorage(
                requiredBytes: 1_000,
                availableBytes: 500
            ),
            .transferFailed,
            .transportUnavailable,
            .requestRejected(statusCode: 503),
        ]

        XCTAssertTrue(failures.allSatisfy { !$0.message.isEmpty })
        XCTAssertEqual(Set(failures.map(\.message)).count, failures.count)
    }

    func testTransferFailureIsNotPresentedWhileManifestIsDownloading()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatFailurePresentation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-1",
                title: "Continuing download",
                libraryID: fixtureLibrary().id
            )
        )
        _ = try await prepareInterruptedDownload(
            root: root,
            account: account,
            detail: detail,
            downloadID: "continuing-download",
            committedByteCount: 5
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .failure(.downloadPlan(.unexpectedStatus(404)))
        )
        let model = DownloadModel(
            service: service,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.failure-presentation.\(UUID().uuidString)"
        )

        await model.start(account: account)

        XCTAssertEqual(model.records.first?.manifest.state, .downloading)
        XCTAssertNil(
            DownloadModel.presentedFailure(
                .transferFailed,
                downloadID: model.records.first?.manifest.downloadID,
                records: model.records
            )
        )
        XCTAssertEqual(
            DownloadModel.presentedFailure(
                .transferFailed,
                downloadID: nil,
                records: model.records
            ),
            .transferFailed
        )
        let activeRecord = try XCTUnwrap(model.records.first)
        var failedManifest = activeRecord.manifest
        try failedManifest.markFailed(trackIndex: 1)
        let failedRecord = DownloadedBookRecord(
            manifest: failedManifest,
            detail: activeRecord.detail
        )
        let otherDownloadID = DownloadID(rawValue: "other-download")
        let otherPlan = DownloadPlan(
            itemID: activeRecord.manifest.itemID,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "other-track",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                )
            ]
        )
        var otherManifest = try DownloadManifest(
            downloadID: otherDownloadID,
            accountID: activeRecord.manifest.accountID,
            plan: otherPlan
        )
        try otherManifest.markDownloading(trackIndex: 0)
        let otherActiveRecord = DownloadedBookRecord(
            manifest: otherManifest,
            detail: activeRecord.detail
        )
        XCTAssertNil(
            DownloadModel.presentedFailure(
                .transferFailed,
                downloadID: otherDownloadID,
                records: [failedRecord, otherActiveRecord]
            )
        )
        XCTAssertEqual(
            DownloadModel.presentedFailure(
                .transferFailed,
                downloadID: failedRecord.manifest.downloadID,
                records: [failedRecord]
            ),
            .transferFailed
        )
        await model.removeAll()
    }

    func testDownloadTransferStatusRetryPolicyIsBoundedToTransientResponses() {
        for status in [200, 408, 425, 429, 500, 503, 599] {
            XCTAssertTrue(DownloadModel.isRetryableTransferStatus(status))
        }
        for status in [201, 206, 400, 401, 403, 404, 409, 416] {
            XCTAssertFalse(DownloadModel.isRetryableTransferStatus(status))
        }
        XCTAssertEqual(DownloadModel.maximumTransferRetries, 2)
        XCTAssertEqual(
            DownloadModel.transferHTTPDisposition(statusCode: 206),
            .success
        )
        for status in [201, 204] {
            XCTAssertEqual(
                DownloadModel.transferHTTPDisposition(statusCode: status),
                .terminalFailure
            )
        }
    }

    func testDownloadRetryAfterParsingAndBackoffRemainBounded() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let now = try XCTUnwrap(
            calendar.date(
                from: DateComponents(
                    year: 2026,
                    month: 8,
                    day: 28,
                    hour: 0,
                    minute: 0,
                    second: 0
                )
            )
        )

        XCTAssertEqual(
            DownloadModel.retryAfterDelaySeconds(
                headerValue: "120",
                now: now
            ),
            120
        )
        XCTAssertEqual(
            DownloadModel.retryAfterDelaySeconds(
                headerValue: "Fri, 28 Aug 2026 00:02:00 GMT",
                now: now
            ),
            120
        )
        XCTAssertEqual(
            DownloadModel.retryAfterDelaySeconds(
                headerValue: "Friday, 28-Aug-26 00:02:00 GMT",
                now: now
            ),
            120
        )
        XCTAssertEqual(
            DownloadModel.retryAfterDelaySeconds(
                headerValue: "Fri Aug 28 00:02:00 2026",
                now: now
            ),
            120
        )
        XCTAssertEqual(
            DownloadModel.retryAfterDelaySeconds(
                headerValue: "999999",
                now: now
            ),
            DownloadModel.maximumServerRetryDelaySeconds
        )
        XCTAssertNil(
            DownloadModel.retryAfterDelaySeconds(
                headerValue: "later",
                now: now
            )
        )
        XCTAssertNil(
            DownloadModel.retryAfterDelaySeconds(
                headerValue: "-1",
                now: now
            )
        )
        XCTAssertEqual(
            DownloadModel.retryDelaySeconds(
                retryCount: 1,
                retryAfterSeconds: 120
            ),
            120
        )
        XCTAssertEqual(
            DownloadModel.retryDelaySeconds(
                retryCount: 2,
                retryAfterSeconds: nil
            ),
            2
        )
    }

    func testDownloadNetworkPolicyPersistsAndControlsRequests() throws {
        let suite = "DownloadNetworkPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let service = TestAppService(activeAccount: .success(nil))
        let first = DownloadModel(
            service: service,
            defaults: defaults
        )
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://books.example/file"))
        )
        request.setValue(
            "Bearer access",
            forHTTPHeaderField: "Authorization"
        )

        #if os(macOS)
            XCTAssertEqual(first.networkPolicy, .allowCellular)
            XCTAssertFalse(DownloadModel.supportsNetworkPolicySelection)
            first.setNetworkPolicy(.wifiOnly)
            XCTAssertEqual(first.networkPolicy, .allowCellular)
        #else
            XCTAssertEqual(first.networkPolicy, .wifiOnly)
            XCTAssertTrue(DownloadModel.supportsNetworkPolicySelection)
        #endif
        let wifiRequest = DownloadNetworkPolicy.wifiOnly.applying(
            to: request
        )
        XCTAssertFalse(wifiRequest.allowsExpensiveNetworkAccess)
        XCTAssertEqual(
            wifiRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer access"
        )
        first.setNetworkPolicy(.allowCellular)
        let restored = DownloadModel(
            service: service,
            defaults: defaults
        )
        XCTAssertEqual(restored.networkPolicy, .allowCellular)
        XCTAssertTrue(
            DownloadNetworkPolicy.allowCellular.applying(to: request)
                .allowsExpensiveNetworkAccess
        )
        #if os(macOS)
            XCTAssertEqual(
                DownloadNetworkDecision.decide(
                    policy: .allowCellular,
                    expectedBytes:
                        DownloadModel.largeDownloadThresholdBytes,
                    largeDownloadThresholdBytes:
                        DownloadModel.largeDownloadThresholdBytes
                ),
                .schedule
            )
        #else
            XCTAssertEqual(
                DownloadNetworkDecision.decide(
                    policy: .allowCellular,
                    expectedBytes:
                        DownloadModel.largeDownloadThresholdBytes,
                    largeDownloadThresholdBytes:
                        DownloadModel.largeDownloadThresholdBytes
                ),
                .confirmCellular(
                    expectedBytes:
                        DownloadModel.largeDownloadThresholdBytes
                )
            )
        #endif
        XCTAssertEqual(
            DownloadNetworkDecision.decide(
                policy: .wifiOnly,
                expectedBytes: Int64.max,
                largeDownloadThresholdBytes:
                    DownloadModel.largeDownloadThresholdBytes
            ),
            .schedule
        )
    }

    func testLargeCellularDownloadsPreserveEveryPendingConfirmation()
        async throws
    {
        guard DownloadModel.supportsNetworkPolicySelection else {
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatCellularConfirmationQueue-\(UUID().uuidString)",
                isDirectory: true
            )
        let suite = "CellularConfirmationQueueTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let account = try fixtureAccount()
        let first = fixtureBookDetail(
            item: fixtureBook(
                id: "cellular-first",
                title: "Cellular First",
                libraryID: fixtureLibrary().id
            )
        )
        let second = fixtureBookDetail(
            item: fixtureBook(
                id: "cellular-second",
                title: "Cellular Second",
                libraryID: fixtureLibrary().id
            )
        )
        let plan = DownloadPlan(
            itemID: first.id,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "large",
                    expectedByteLength:
                        DownloadModel.largeDownloadThresholdBytes,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                )
            ]
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .success(plan)
        )
        let model = DownloadModel(
            service: service,
            defaults: defaults,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.cellular-confirmation-queue.\(UUID().uuidString)"
        )
        model.setNetworkPolicy(.allowCellular)

        await model.download(detail: first, account: account)
        await model.download(detail: second, account: account)

        XCTAssertEqual(model.pendingCellularDownload?.detail.id, first.id)
        await model.handleAutomaticPlaybackActivity(
            AutomaticDownloadActivity(
                kind: .progress,
                detail: first,
                account: account,
                currentTime: 0,
                chapters: [],
                fileRanges: [
                    AutomaticDownloadFileRange(
                        index: 0,
                        start: 0,
                        end: first.duration
                    )
                ]
            )
        )
        XCTAssertTrue(model.records.isEmpty)
        let requestsBeforeConfirmation = await service.downloadPlanRequests()
        XCTAssertEqual(requestsBeforeConfirmation.count, 2)
        model.cancelCellularDownload()
        await Task.yield()
        XCTAssertEqual(model.pendingCellularDownload?.detail.id, second.id)

        await model.download(detail: first, account: account)
        let resetSucceeded = await model.removeAllForLocalDataReset()
        XCTAssertTrue(resetSucceeded)
        await Task.yield()
        XCTAssertNil(model.pendingCellularDownload)
        model.cancelCellularDownload()
        await Task.yield()
        XCTAssertNil(model.pendingCellularDownload)

        await model.download(detail: first, account: account)
        let confirmation = Task {
            await model.confirmCellularDownload()
        }
        await Task.yield()
        await model.download(detail: first, account: account)
        await confirmation.value
        await Task.yield()
        XCTAssertNil(model.pendingCellularDownload)
        _ = await model.removeAllForLocalDataReset()
    }

    func testConcurrentDownloadTriggersShareOneBookOperation() async throws {
        guard DownloadModel.supportsNetworkPolicySelection else {
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatDownloadSingleFlight-\(UUID().uuidString)",
                isDirectory: true
            )
        let suite = "DownloadSingleFlightTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "single-flight",
                title: "Single Flight",
                libraryID: fixtureLibrary().id
            )
        )
        let plan = DownloadPlan(
            itemID: detail.id,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "large",
                    expectedByteLength:
                        DownloadModel.largeDownloadThresholdBytes,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                )
            ]
        )
        let gate = AsyncGate()
        let authorizedRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://books.example/audio.mp3"))
        )
        let service = TestAppService(
            activeAccount: .success(account),
            downloadPlan: .success(plan),
            authorizedDownloadRequest: .success(authorizedRequest)
        )
        await service.setDownloadPlanGate(gate)
        let model = DownloadModel(
            service: service,
            defaults: defaults,
            storageRootURL: root,
            backgroundSessionIdentifier:
                "bleat.tests.download-single-flight.\(UUID().uuidString)"
        )
        model.setNetworkPolicy(.allowCellular)

        let first = Task {
            await model.download(detail: detail, account: account)
        }
        await gate.waitUntilEntered()
        await model.download(detail: detail, account: account)
        await gate.release()
        await first.value

        let requests = await service.downloadPlanRequests()
        XCTAssertEqual(requests, [detail.id])
        XCTAssertEqual(model.pendingCellularDownload?.detail.id, detail.id)
        let initialResetSucceeded = await model.removeAllForLocalDataReset()
        XCTAssertTrue(initialResetSucceeded)

        let teardownGate = AsyncGate()
        await service.setDownloadPlanGate(teardownGate)
        let inFlight = Task {
            await model.download(detail: detail, account: account)
        }
        await teardownGate.waitUntilEntered()
        let reset = Task { await model.removeAllForLocalDataReset() }
        await Task.yield()
        let otherDetail = fixtureBookDetail(
            item: fixtureBook(
                id: "blocked-during-reset",
                title: "Blocked During Reset",
                libraryID: fixtureLibrary().id
            )
        )
        await model.download(detail: otherDetail, account: account)
        await teardownGate.release()
        await inFlight.value
        let resetSucceeded = await reset.value
        XCTAssertTrue(resetSucceeded)

        let requestsAfterReset = await service.downloadPlanRequests()
        XCTAssertEqual(requestsAfterReset, [detail.id, detail.id])
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertNil(model.pendingCellularDownload)

        let automaticGate = AsyncGate()
        await service.setDownloadPlanGate(automaticGate)
        let activity = AutomaticDownloadActivity(
            kind: .progress,
            detail: detail,
            account: account,
            currentTime: 0,
            chapters: [],
            fileRanges: [
                AutomaticDownloadFileRange(
                    index: 0,
                    start: 0,
                    end: detail.duration
                )
            ]
        )
        let automatic = Task {
            await model.handleAutomaticPlaybackActivity(activity)
        }
        await automaticGate.waitUntilEntered()
        let explicit = Task {
            await model.download(detail: detail, account: account)
        }
        await Task.yield()
        await automaticGate.release()
        await automatic.value
        await explicit.value

        let automaticRecord = try XCTUnwrap(model.records.first)
        XCTAssertEqual(automaticRecord.manifest.purpose, .automaticCache)
        XCTAssertEqual(
            model.pendingCellularDownload?.kind,
            .promote(automaticRecord.manifest.downloadID)
        )
        _ = await model.removeAllForLocalDataReset()
    }

    func testAutomaticDownloadSettingsUseRequestedDefaultsAndPersist()
        throws
    {
        let suite = "AutomaticDownloadSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let service = TestAppService(activeAccount: .success(nil))
        let first = DownloadModel(service: service, defaults: defaults)

        XCTAssertEqual(first.automaticLookaheadCount, 5)
        XCTAssertEqual(first.maximumConcurrentDownloads, 5)
        XCTAssertEqual(
            first.automaticCleanupPolicy,
            .afterTwentyFourHours
        )

        first.setAutomaticLookaheadCount(9)
        first.setMaximumConcurrentDownloads(8)
        first.setAutomaticCleanupPolicy(.afterChapter)
        let restored = DownloadModel(service: service, defaults: defaults)
        XCTAssertEqual(restored.automaticLookaheadCount, 9)
        XCTAssertEqual(restored.maximumConcurrentDownloads, 10)
        XCTAssertEqual(restored.automaticCleanupPolicy, .afterChapter)

        restored.setAutomaticLookaheadCount(0)
        XCTAssertEqual(restored.automaticLookaheadCount, 1)
        restored.setAutomaticLookaheadCount(99)
        XCTAssertEqual(restored.automaticLookaheadCount, 20)

        defaults.set(
            3,
            forKey: MaximumConcurrentDownloadsPreference.defaultsKey
        )
        restored.reloadSyncedPreferences()
        XCTAssertEqual(restored.maximumConcurrentDownloads, 3)
    }

    func testAutomaticDownloadPlannerUsesWholeFilesForChapterWindow()
        throws
    {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: (0..<10).map { index in
                DownloadTrackPlan(
                    index: index,
                    inode: "\(index)",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: String(
                        format: "%05d.mp3",
                        index
                    ),
                    startOffset: Double(index * 60),
                    duration: 60
                )
            }
        )
        let chapters = (0..<20).map { index in
            PlaybackChapter(
                id: index,
                start: Double(index * 30),
                end: Double((index + 1) * 30),
                title: "Chapter \(index + 1)"
            )
        }
        let activity = AutomaticDownloadActivity(
            kind: .progress,
            detail: fixtureBookDetail(
                item: fixturePage(libraryID: fixtureLibrary().id).items[0]
            ),
            account: try fixtureAccount(),
            currentTime: 15,
            chapters: chapters,
            fileRanges: []
        )

        XCTAssertEqual(
            AutomaticDownloadPlanner.targetTrackIndexes(
                plan: plan,
                activity: activity,
                lookaheadCount: 5
            ),
            [0, 1, 2]
        )

        let laterActivity = AutomaticDownloadActivity(
            kind: .progress,
            detail: activity.detail,
            account: activity.account,
            currentTime: 125,
            chapters: chapters,
            fileRanges: []
        )
        XCTAssertEqual(
            AutomaticDownloadPlanner.completedTrackIndexes(
                plan: plan,
                activity: laterActivity
            ),
            [0, 1]
        )
    }

    func testAutomaticDownloadPlannerFallsBackToCurrentPlusFilesAhead()
        throws
    {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: (0..<10).map { index in
                DownloadTrackPlan(
                    index: index,
                    inode: "\(index)",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: String(
                        format: "%05d.mp3",
                        index
                    )
                )
            }
        )
        let ranges = (0..<10).map { index in
            AutomaticDownloadFileRange(
                index: index,
                start: Double(index * 60),
                end: Double((index + 1) * 60)
            )
        }
        let activity = AutomaticDownloadActivity(
            kind: .progress,
            detail: fixtureBookDetail(
                item: fixturePage(libraryID: fixtureLibrary().id).items[0]
            ),
            account: try fixtureAccount(),
            currentTime: 125,
            chapters: [],
            fileRanges: ranges
        )

        XCTAssertEqual(
            AutomaticDownloadPlanner.targetTrackIndexes(
                plan: plan,
                activity: activity,
                lookaheadCount: 5
            ),
            [2, 3, 4, 5, 6, 7]
        )

        let singleFile = DownloadPlan(
            itemID: plan.itemID,
            tracks: [plan.tracks[0]]
        )
        XCTAssertEqual(
            AutomaticDownloadPlanner.targetTrackIndexes(
                plan: singleFile,
                activity: activity,
                lookaheadCount: 5
            ),
            [0]
        )
    }

    func testPlaybackPreferencesPersistRateRewindAndSkipIntervals()
        throws
    {
        let suite = "PlaybackPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let first = PlaybackPreferencesStore(defaults: defaults)

        XCTAssertEqual(first.playbackRate(), 1)
        XCTAssertEqual(first.resumeRewind(), .tenSeconds)
        XCTAssertEqual(first.skipBackward(), .fifteenSeconds)
        XCTAssertEqual(first.skipForward(), .thirtySeconds)
        XCTAssertEqual(first.previousCommandAction(), .skipBackward)
        XCTAssertEqual(first.nextCommandAction(), .skipForward)
        first.savePlaybackRate(1.37)
        first.saveResumeRewind(.thirtySeconds)
        first.saveSkipBackward(.fortyFiveSeconds)
        first.saveSkipForward(.sixtySeconds)
        first.savePreviousCommandAction(.previousChapter)
        first.saveNextCommandAction(.nextChapter)

        let restored = PlaybackPreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.playbackRate(), 1.35, accuracy: 0.001)
        XCTAssertEqual(restored.resumeRewind(), .thirtySeconds)
        XCTAssertEqual(restored.skipBackward(), .fortyFiveSeconds)
        XCTAssertEqual(restored.skipForward(), .sixtySeconds)
        XCTAssertEqual(restored.previousCommandAction(), .previousChapter)
        XCTAssertEqual(restored.nextCommandAction(), .nextChapter)
        restored.savePlaybackRate(10)
        XCTAssertEqual(restored.playbackRate(), 3)
        restored.savePlaybackRate(0)
        XCTAssertEqual(restored.playbackRate(), 0.5)
        restored.savePlaybackRate(.nan)
        XCTAssertEqual(restored.playbackRate(), 1)
        defaults.set(
            "invalid",
            forKey: "bleat.playback.previousCommandAction.v1"
        )
        defaults.set(
            "invalid",
            forKey: "bleat.playback.nextCommandAction.v1"
        )
        XCTAssertEqual(restored.previousCommandAction(), .skipBackward)
        XCTAssertEqual(restored.nextCommandAction(), .skipForward)
    }

    func testHeadphoneCommandActionsMapAndRespectChapterAvailability() {
        XCTAssertEqual(
            HeadphoneCommandAction.skipBackward.remoteCommand,
            .skipBackward
        )
        XCTAssertEqual(
            HeadphoneCommandAction.skipForward.remoteCommand,
            .skipForward
        )
        XCTAssertEqual(
            HeadphoneCommandAction.previousChapter.remoteCommand,
            .previousChapter
        )
        XCTAssertEqual(
            HeadphoneCommandAction.nextChapter.remoteCommand,
            .nextChapter
        )

        for action in [
            HeadphoneCommandAction.skipBackward,
            .skipForward,
        ] {
            XCTAssertTrue(
                action.isAvailable(
                    canMoveToPreviousChapter: false,
                    canMoveToNextChapter: false
                )
            )
        }
        XCTAssertFalse(
            HeadphoneCommandAction.previousChapter.isAvailable(
                canMoveToPreviousChapter: false,
                canMoveToNextChapter: true
            )
        )
        XCTAssertTrue(
            HeadphoneCommandAction.previousChapter.isAvailable(
                canMoveToPreviousChapter: true,
                canMoveToNextChapter: false
            )
        )
        XCTAssertFalse(
            HeadphoneCommandAction.nextChapter.isAvailable(
                canMoveToPreviousChapter: true,
                canMoveToNextChapter: false
            )
        )
        XCTAssertTrue(
            HeadphoneCommandAction.nextChapter.isAvailable(
                canMoveToPreviousChapter: false,
                canMoveToNextChapter: true
            )
        )
    }

    func testBookmarkMutationStorePersistsAndAppliesOptimisticChanges()
        throws
    {
        let suite = "BookmarkMutationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let accountID = AccountID(rawValue: "account")
        let itemID = LibraryItemID(rawValue: "item")
        let bookmark = AudioBookmark(
            libraryItemID: itemID,
            time: 42,
            title: "Queued",
            createdAtMilliseconds: 1
        )
        let store = BookmarkMutationStore(defaults: defaults)
        let mutation = try store.enqueue(
            accountID: accountID,
            bookmark: bookmark,
            kind: .create,
            status: .failed
        )

        let restored = BookmarkMutationStore(defaults: defaults)
        XCTAssertEqual(
            try restored.mutations(accountID: accountID),
            [mutation]
        )
        XCTAssertEqual(
            restored.applying([mutation], to: []),
            [bookmark]
        )
        XCTAssertEqual(
            BookmarkReconciliationDecision.decide(
                mutation: mutation,
                remote: [bookmark]
            ),
            .complete
        )
        XCTAssertEqual(
            BookmarkReconciliationDecision.decide(
                mutation: mutation,
                remote: []
            ),
            .create(title: "Queued")
        )
        let renamed = try store.enqueue(
            accountID: accountID,
            bookmark: bookmark,
            kind: .rename,
            title: "Renamed",
            status: .pending
        )
        XCTAssertEqual(
            BookmarkReconciliationDecision.decide(
                mutation: renamed,
                remote: [bookmark]
            ),
            .rename(bookmark, title: "Renamed")
        )
        let deleted = try store.enqueue(
            accountID: accountID,
            bookmark: bookmark,
            kind: .delete,
            status: .pending
        )
        XCTAssertEqual(
            BookmarkReconciliationDecision.decide(
                mutation: deleted,
                remote: []
            ),
            .complete
        )

        try restored.markPending(accountID: accountID)
        XCTAssertEqual(
            try restored.mutations(accountID: accountID)[0].status,
            .pending
        )
        try restored.remove(mutation.id)
        XCTAssertEqual(
            try restored.mutations(accountID: accountID),
            [renamed, deleted]
        )
        try restored.removeAll(accountID: accountID)
        XCTAssertTrue(try restored.mutations(accountID: accountID).isEmpty)
    }

    func testResumeRewindRequiresFiveMinutePauseAndClampsAtBookStart() {
        let pausedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(
            PlaybackResumeRewindDecision.target(
                currentTime: 100,
                pausedAt: pausedAt,
                now: pausedAt.addingTimeInterval(299),
                setting: .tenSeconds
            )
        )
        XCTAssertNil(
            PlaybackResumeRewindDecision.target(
                currentTime: 100,
                pausedAt: pausedAt,
                now: pausedAt.addingTimeInterval(600),
                setting: .off
            )
        )
        XCTAssertEqual(
            PlaybackResumeRewindDecision.target(
                currentTime: 8,
                pausedAt: pausedAt,
                now: pausedAt.addingTimeInterval(300),
                setting: .tenSeconds
            ),
            0
        )
    }

    func testEndOfChapterSleepUsesWholeBookBoundary() {
        let chapters = [
            PlaybackChapter(id: 1, start: 0, end: 60, title: "One"),
            PlaybackChapter(id: 2, start: 60, end: 130, title: "Two"),
        ]

        XCTAssertEqual(
            PlaybackChapterSleepDecision.target(
                chapters: chapters,
                currentTime: 75,
                duration: 130
            ),
            130
        )
        XCTAssertNil(
            PlaybackChapterSleepDecision.target(
                chapters: chapters,
                currentTime: 130,
                duration: 130
            )
        )
    }

    func testPlaybackObservationRequiresReadyAdvancingPlayback() {
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: true,
                itemStatus: .unknown,
                timeControlStatus: .playing,
                hasConfirmedAdvance: true
            ),
            .buffering
        )
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: true,
                itemStatus: .readyToPlay,
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                hasConfirmedAdvance: true
            ),
            .buffering
        )
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: true,
                itemStatus: .readyToPlay,
                timeControlStatus: .playing,
                hasConfirmedAdvance: false
            ),
            .buffering
        )
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: true,
                itemStatus: .readyToPlay,
                timeControlStatus: .playing,
                hasConfirmedAdvance: true
            ),
            .playing
        )
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: false,
                itemStatus: .readyToPlay,
                timeControlStatus: .playing,
                hasConfirmedAdvance: true
            ),
            .paused
        )
    }

    func testSeekContinuationPreservesAnActivePlayer() {
        XCTAssertEqual(
            PlaybackSeekContinuation.decide(
                isPlaybackRequested: true,
                state: .playing
            ),
            .resume
        )
        XCTAssertEqual(
            PlaybackSeekContinuation.decide(
                isPlaybackRequested: false,
                state: .playing
            ),
            .resume
        )
        XCTAssertEqual(
            PlaybackSeekContinuation.decide(
                isPlaybackRequested: false,
                state: .buffering
            ),
            .resume
        )
        XCTAssertEqual(
            PlaybackSeekContinuation.decide(
                isPlaybackRequested: false,
                state: .paused
            ),
            .remainPaused
        )
    }

    func testPlaybackWatchdogBuffersThenRecoversAtExactDeadlines() {
        XCTAssertEqual(
            PlaybackWatchdogDecision.decide(
                isPlaybackRequested: true,
                lastConfirmedAdvanceAt: 100,
                now: 101.99
            ),
            .none
        )
        XCTAssertEqual(
            PlaybackWatchdogDecision.decide(
                isPlaybackRequested: true,
                lastConfirmedAdvanceAt: 100,
                now: 102
            ),
            .showBuffering
        )
        XCTAssertEqual(
            PlaybackWatchdogDecision.decide(
                isPlaybackRequested: true,
                lastConfirmedAdvanceAt: 100,
                now: 112
            ),
            .recover
        )
        XCTAssertEqual(
            PlaybackWatchdogDecision.decide(
                isPlaybackRequested: false,
                lastConfirmedAdvanceAt: 100,
                now: 200
            ),
            .none
        )
    }

    func testPlaybackRecoveryPolicyBoundsRebuildAndSessionReplacement()
        throws
    {
        var streamingPolicy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            streamingPolicy.action(
                for: .stalled,
                isStreaming: true,
                isTranscoded: false
            ),
            .rebuildCurrentSource
        )
        XCTAssertEqual(
            streamingPolicy.action(
                for: .itemFailure,
                isStreaming: true,
                isTranscoded: false
            ),
            .reopenSession(.automatic)
        )
        XCTAssertEqual(
            streamingPolicy.action(
                for: .missingSession,
                isStreaming: true,
                isTranscoded: false
            ),
            .fail
        )

        let localURL = try XCTUnwrap(
            URL(string: "https://local.example/audio.m4b")
        )
        var endpointPolicy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            endpointPolicy.action(
                for: .localEndpointFailure(localURL),
                isStreaming: true,
                isTranscoded: false
            ),
            .fallbackFromLocal(localURL)
        )
        XCTAssertEqual(
            endpointPolicy.action(
                for: .localEndpointFailure(localURL),
                isStreaming: true,
                isTranscoded: false
            ),
            .fail
        )

        var hlsPolicy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            hlsPolicy.action(
                for: .itemFailure,
                isStreaming: true,
                isTranscoded: true
            ),
            .rebuildCurrentSource
        )
        XCTAssertEqual(
            hlsPolicy.action(
                for: .itemFailure,
                isStreaming: true,
                isTranscoded: true
            ),
            .reopenSession(.automatic)
        )
        XCTAssertEqual(
            hlsPolicy.action(
                for: .itemFailure,
                isStreaming: true,
                isTranscoded: true
            ),
            .fail
        )

        var localPolicy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            localPolicy.action(
                for: .stalled,
                isStreaming: false,
                isTranscoded: false
            ),
            .rebuildCurrentSource
        )
        XCTAssertEqual(
            localPolicy.action(
                for: .itemFailure,
                isStreaming: false,
                isTranscoded: false
            ),
            .fail
        )
        localPolicy.sustainedPlaybackConfirmed()
        XCTAssertEqual(
            localPolicy.action(
                for: .stalled,
                isStreaming: false,
                isTranscoded: false
            ),
            .rebuildCurrentSource
        )
    }

    func testPlaybackRecoveryPolicyForcesTranscodeOnceForDecoderFailure() {
        var policy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            policy.action(
                for: .decoderFailure,
                isStreaming: true,
                isTranscoded: false
            ),
            .reopenSession(.transcode)
        )
        XCTAssertEqual(
            policy.action(
                for: .decoderFailure,
                isStreaming: true,
                isTranscoded: false
            ),
            .fail
        )
        XCTAssertEqual(
            policy.action(
                for: .missingSession,
                isStreaming: true,
                isTranscoded: true
            ),
            .reopenSession(.automatic)
        )

        var transcodedPolicy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            transcodedPolicy.action(
                for: .decoderFailure,
                isStreaming: true,
                isTranscoded: true
            ),
            .fail
        )
    }

    func testPlaybackItemFailureClassificationUsesTypedCodesOnly() {
        let decoderError = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.decoderNotFound.rawValue
        )
        XCTAssertEqual(
            PlaybackItemFailureClassifier.classify(
                error: decoderError,
                errorLogStatusCodes: []
            ),
            .decoderFailure
        )
        XCTAssertEqual(
            PlaybackItemFailureClassifier.classify(
                error: nil,
                errorLogStatusCodes: [404]
            ),
            .missingSession
        )
        XCTAssertEqual(
            PlaybackItemFailureClassifier.classify(
                error: NSError(
                    domain: "TestError",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "decoder failed after a 404"
                    ]
                ),
                errorLogStatusCodes: []
            ),
            .itemFailure
        )
    }

    func testMediaServicesResetIntentOnlyRecoversStablePlaybackStates() {
        XCTAssertEqual(
            PlaybackMediaServicesResetIntent.decide(for: .playing),
            .play
        )
        XCTAssertEqual(
            PlaybackMediaServicesResetIntent.decide(for: .buffering),
            .play
        )
        XCTAssertEqual(
            PlaybackMediaServicesResetIntent.decide(for: .paused),
            .pause
        )
        XCTAssertEqual(
            PlaybackMediaServicesResetIntent.decide(for: .ready),
            .pause
        )
        XCTAssertNil(
            PlaybackMediaServicesResetIntent.decide(for: .preparing)
        )
        XCTAssertNil(
            PlaybackMediaServicesResetIntent.decide(for: .ended)
        )
        XCTAssertNil(
            PlaybackMediaServicesResetIntent.decide(
                for: .failed(.mediaUnavailable)
            )
        )
    }

    func testQueueRecoverySelectsTrackAtWholeBookBoundary() throws {
        let tracks = [
            AppPlaybackTrack(
                url: URL(fileURLWithPath: "/one.m4b"),
                startOffset: 0,
                duration: 10,
                title: "One"
            ),
            AppPlaybackTrack(
                url: URL(fileURLWithPath: "/two.m4b"),
                startOffset: 10,
                duration: 10,
                title: "Two"
            ),
            AppPlaybackTrack(
                url: URL(fileURLWithPath: "/three.m4b"),
                startOffset: 20,
                duration: 10,
                title: "Three"
            ),
        ]
        let preparation = AppPlaybackPreparation(
            sessionID: nil,
            itemID: LibraryItemID(rawValue: "item"),
            title: "Book",
            duration: 30,
            currentTime: 0,
            chapters: [],
            source: .direct(tracks)
        )

        let beforeBoundary = try AppPlaybackQueuePlanner.make(
            preparation: preparation,
            wholeBookTime: 19.5
        )
        XCTAssertEqual(beforeBoundary.tracks, Array(tracks[1...]))
        XCTAssertEqual(beforeBoundary.localTime, 9.5)

        let atBoundary = try AppPlaybackQueuePlanner.make(
            preparation: preparation,
            wholeBookTime: 20
        )
        XCTAssertEqual(atBoundary.tracks, [tracks[2]])
        XCTAssertEqual(atBoundary.localTime, 0)
    }

    func testMediaServicesResetRestoresPlayingAndPausedIntent() async throws {
        for shouldPlay in [true, false] {
            let fixture = try playbackRecoveryFixture()
            defer {
                fixture.cleanUp()
            }
            let activation = TestAudioSessionActivation()
            let playback = fixture.model(activation: activation)

            await playback.startDownloaded(
                detail: fixture.detail,
                trackURLs: [fixture.audioURL],
                accountID: fixture.accountID,
                account: nil
            )
            XCTAssertTrue(playback.isPlaybackRequested)
            XCTAssertTrue(
                playback.state == .buffering || playback.state == .playing
            )
            playback.setRate(1.35)
            if !shouldPlay {
                playback.pause()
                XCTAssertEqual(playback.state, .paused)
            }

            await playback.handleMediaServicesReset()

            XCTAssertEqual(playback.isPlaybackRequested, shouldPlay)
            if shouldPlay {
                XCTAssertTrue(
                    playback.state == .buffering
                        || playback.state == .playing
                )
            } else {
                XCTAssertEqual(playback.state, .paused)
            }
            XCTAssertEqual(playback.rate, 1.35, accuracy: 0.001)
            XCTAssertEqual(activation.callCount, 2)
        }
    }

    func testDownloadedPlaybackCarriesCoverIntoNowPlaying() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let account = try fixtureAccount()
        let playback = fixture.model(
            activation: TestAudioSessionActivation()
        )

        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL],
            accountID: fixture.accountID,
            account: account
        )

        XCTAssertEqual(
            playback.coverURL,
            BookCoverURL.make(
                server: account.server,
                itemID: fixture.detail.id,
                updatedAtMilliseconds:
                    fixture.detail.updatedAtMilliseconds,
                width: 600,
                height: 600
            )
        )
        await playback.stop()
    }

    func testDownloadedPlaybackControlsNeverStartNetworkRequests()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let account = try fixtureAccount()
        let bookmarksGate = AsyncGate()
        let bookProgressGate = AsyncGate()
        let localSessionSyncGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            bookmarksGate: bookmarksGate,
            bookProgressGate: bookProgressGate,
            localSessionSyncGate: localSessionSyncGate
        )
        let playback = fixture.model(
            activation: TestAudioSessionActivation(),
            service: service
        )
        let prepared = expectation(
            description: "Downloaded playback prepares without network"
        )
        let start = Task { @MainActor in
            await playback.startDownloaded(
                detail: fixture.detail,
                trackURLs: [fixture.audioURL],
                accountID: fixture.accountID,
                account: account
            )
            prepared.fulfill()
        }

        await fulfillment(of: [prepared], timeout: 2)
        await start.value

        playback.pause()
        await playback.seek(to: 0.25)
        await playback.skipBackward()
        await playback.skipForward()
        await playback.previousChapter()
        await playback.nextChapter()
        playback.setRate(1.25)
        playback.play()
        await playback.stop()

        let playbackRequests = await service.playbackOpenRequests()
        let progressRequests = await service.bookProgressRequests()
        let bookmarkRequests = await service.bookmarkRequests()
        let playbackSyncRequests = await service.playbackSyncSessionIDs()
        let progressUpdateRequests = await service.progressUpdateRequests()
        let localSessionSyncRequests =
            await service.localSessionSyncRequests()
        XCTAssertTrue(playbackRequests.isEmpty)
        XCTAssertTrue(progressRequests.isEmpty)
        XCTAssertTrue(bookmarkRequests.isEmpty)
        XCTAssertTrue(playbackSyncRequests.isEmpty)
        XCTAssertTrue(progressUpdateRequests.isEmpty)
        XCTAssertTrue(localSessionSyncRequests.isEmpty)
        XCTAssertEqual(playback.coverLoadPolicy, .cacheOnly)
        XCTAssertNotNil(
            PlaybackPositionStore(defaults: fixture.defaults).position(
                accountID: fixture.accountID,
                itemID: fixture.detail.id
            )
        )
        XCTAssertFalse(
            try LocalPlaybackSessionStore(defaults: fixture.defaults)
                .pending(accountID: fixture.accountID)
                .isEmpty
        )
    }

    func testTranscriptNavigationPositionUsesSavedPositionWithoutMatchingPlayback()
        throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let positionStore = PlaybackPositionStore(defaults: fixture.defaults)
        let playback = fixture.model(
            activation: TestAudioSessionActivation()
        )
        try positionStore.save(
            42,
            accountID: fixture.accountID,
            itemID: fixture.detail.id
        )

        XCTAssertEqual(
            playback.transcriptNavigationPosition(
                accountID: fixture.accountID,
                itemID: fixture.detail.id
            ),
            .saved(42)
        )
        XCTAssertNil(
            playback.transcriptNavigationPosition(
                accountID: fixture.accountID,
                itemID: LibraryItemID(rawValue: "missing")
            )
        )
    }

    func testTranscriptNavigationPositionUsesOnlyExactActiveBookBeforeSaved()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let positionStore = PlaybackPositionStore(defaults: fixture.defaults)
        let playback = fixture.model(
            activation: TestAudioSessionActivation()
        )
        let otherAccountID = AccountID(rawValue: "other-account")
        let otherItemID = LibraryItemID(rawValue: "other-item")
        try positionStore.save(
            42,
            accountID: fixture.accountID,
            itemID: fixture.detail.id
        )
        try positionStore.save(
            84,
            accountID: otherAccountID,
            itemID: otherItemID
        )
        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL],
            accountID: fixture.accountID,
            account: nil,
            initialTime: 0.5
        )

        XCTAssertEqual(
            playback.transcriptNavigationPosition(
                accountID: fixture.accountID,
                itemID: fixture.detail.id
            ),
            .active(0.5)
        )
        XCTAssertEqual(
            playback.transcriptNavigationPosition(
                accountID: otherAccountID,
                itemID: otherItemID
            ),
            .saved(84)
        )
        await playback.stop()
    }

    func testCacheOnlyCoverLoadDoesNotFetchOnCacheMiss() async throws {
        let url = try XCTUnwrap(
            URL(string: "https://books.example/cover?ts=3")
        )
        let fetcher = TestBookCoverFetcher(data: Data())
        let loader = BookCoverImageLoader(
            diskCapacity: 0,
            fetch: { request in
                try await fetcher.fetch(request)
            }
        )

        let image = await loader.image(
            for: url,
            accountID: AccountID(rawValue: "account"),
            policy: .cacheOnly
        )

        XCTAssertNil(image)
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testMediaServicesResetRebuildsAcrossAudioFileBoundary()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let activation = TestAudioSessionActivation()
        let playback = fixture.model(activation: activation)

        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL, fixture.audioURL],
            accountID: fixture.accountID,
            account: nil
        )
        let boundary = try XCTUnwrap(
            playback.audioFiles.last?.startOffset
        )
        await playback.seek(to: boundary)
        XCTAssertEqual(playback.currentAudioFileIndex, 1)

        await playback.handleMediaServicesReset()

        XCTAssertTrue(playback.isPlaybackRequested)
        XCTAssertTrue(
            playback.state == .buffering || playback.state == .playing
        )
        XCTAssertEqual(playback.currentAudioFileIndex, 1)
        XCTAssertEqual(playback.currentTime, boundary, accuracy: 0.1)
    }

    func testSeekToAudioFileMovesToRequestedTrack() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let playback = fixture.model(
            activation: TestAudioSessionActivation()
        )
        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL, fixture.audioURL],
            accountID: fixture.accountID,
            account: nil
        )
        XCTAssertEqual(playback.currentAudioFileIndex, 0)
        let targetOffset = playback.audioFiles[1].startOffset

        await playback.seekToAudioFile(at: 1)

        XCTAssertEqual(playback.currentAudioFileIndex, 1)
        XCTAssertEqual(
            playback.currentTime,
            targetOffset,
            accuracy: 0.1
        )
        await playback.stop()
    }

    func testSeekToAudioFileIgnoresOutOfBoundsIndex() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let playback = fixture.model(
            activation: TestAudioSessionActivation()
        )
        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL, fixture.audioURL],
            accountID: fixture.accountID,
            account: nil
        )
        let originalTime = playback.currentTime

        await playback.seekToAudioFile(at: 5)

        XCTAssertEqual(playback.currentTime, originalTime)
        XCTAssertEqual(playback.currentAudioFileIndex, 0)
        await playback.stop()
    }

    func testSeekToAudioFileIsNoopWithoutActiveBook() async {
        let playback = PlaybackModel(
            service: TestAppService(
                activeAccount: .success(nil)
            )
        )

        await playback.seekToAudioFile(at: 0)

        XCTAssertEqual(playback.state, .idle)
        XCTAssertEqual(playback.currentTime, 0)
    }

    func testMediaServicesResetRebuildFailureIsTyped() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let activation = TestAudioSessionActivation()
        let planning = TestPlaybackQueuePlanning(failingCall: 2)
        let playback = fixture.model(
            activation: activation,
            queuePlanning: {
                try planning.make(
                    preparation: $0,
                    wholeBookTime: $1
                )
            }
        )

        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL],
            accountID: fixture.accountID,
            account: nil
        )
        XCTAssertTrue(playback.isPlaybackRequested)
        XCTAssertTrue(
            playback.state == .buffering || playback.state == .playing
        )

        await playback.handleMediaServicesReset()

        XCTAssertEqual(playback.state, .failed(.mediaUnavailable))
        XCTAssertEqual(activation.callCount, 2)
        XCTAssertEqual(planning.callCount, 2)
    }

    func testLocalSessionStorePersistsAndRemovesOnlyAcknowledgedIDs()
        throws
    {
        let suite = "LocalPlaybackSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let accountID = AccountID(rawValue: "account")
        let first = try localSession(
            id: "d9ef37df-6838-4dd5-9875-266ae49db169",
            itemID: "item-1"
        )
        let second = try localSession(
            id: "5eef37df-6838-4dd5-9875-266ae49db169",
            itemID: "item-2"
        )
        let store = LocalPlaybackSessionStore(defaults: defaults)
        try store.save(first, accountID: accountID)
        try store.save(second, accountID: accountID)

        let restored = LocalPlaybackSessionStore(defaults: defaults)
        XCTAssertEqual(
            try restored.pending(accountID: accountID).map(\.id),
            [first.id, second.id]
        )
        try restored.removeAcknowledged(
            accountID: accountID,
            sessionIDs: [first.id]
        )

        XCTAssertEqual(
            try restored.pending(accountID: accountID).map(\.id),
            [second.id]
        )
    }

    func testAccountIdentityMigrationRekeysPendingAppData() throws {
        let suite = "AccountIdentityAppStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let legacyID = AccountID(rawValue: "legacy-device")
        let canonicalID = AccountID(rawValue: "account-canonical")
        let itemID = LibraryItemID(rawValue: "item")
        let bookmark = AudioBookmark(
            libraryItemID: itemID,
            time: 42,
            title: "Queued",
            createdAtMilliseconds: 1
        )
        let bookmarks = BookmarkMutationStore(defaults: defaults)
        let mutation = try bookmarks.enqueue(
            accountID: legacyID,
            bookmark: bookmark,
            kind: .create,
            status: .pending
        )
        let sessions = LocalPlaybackSessionStore(defaults: defaults)
        let session = try localSession(
            id: "d9ef37df-6838-4dd5-9875-266ae49db169",
            itemID: itemID.rawValue
        )
        try sessions.save(session, accountID: legacyID)
        let positions = PlaybackPositionStore(defaults: defaults)
        try positions.save(42, accountID: legacyID, itemID: itemID)

        try bookmarks.migrateAccountIdentity(
            from: legacyID,
            to: canonicalID
        )
        try sessions.migrateAccountIdentity(
            from: legacyID,
            to: canonicalID
        )
        try positions.migrateAccountIdentity(
            from: legacyID,
            to: canonicalID
        )

        XCTAssertTrue(try bookmarks.mutations(accountID: legacyID).isEmpty)
        XCTAssertEqual(
            try bookmarks.mutations(accountID: canonicalID).map(\.id),
            [mutation.id]
        )
        XCTAssertTrue(try sessions.pending(accountID: legacyID).isEmpty)
        XCTAssertEqual(
            try sessions.pending(accountID: canonicalID).map(\.id),
            [session.id]
        )
        XCTAssertNil(positions.position(accountID: legacyID, itemID: itemID))
        XCTAssertEqual(
            positions.position(accountID: canonicalID, itemID: itemID),
            42
        )
    }

    func testPendingLocalSessionsRetryWithSameIDUntilAcknowledged()
        async throws
    {
        let suite = "LocalPlaybackSessionRetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let account = try fixtureAccount()
        let first = try localSession(
            id: "d9ef37df-6838-4dd5-9875-266ae49db169",
            itemID: "item-1"
        )
        let second = try localSession(
            id: "5eef37df-6838-4dd5-9875-266ae49db169",
            itemID: "item-2"
        )
        let store = LocalPlaybackSessionStore(defaults: defaults)
        try store.save(first, accountID: account.id)
        try store.save(second, accountID: account.id)
        let service = TestAppService(
            activeAccount: .success(account),
            localSessionSync: .success([
                LocalPlaybackSessionSyncResult(
                    id: first.id,
                    success: true,
                    progressSynced: true,
                    error: nil
                ),
                LocalPlaybackSessionSyncResult(
                    id: second.id,
                    success: false,
                    progressSynced: false,
                    error: "retry"
                ),
            ])
        )
        let playback = PlaybackModel(
            service: service,
            localSessionStore: store
        )

        await playback.syncPendingLocalSessions(for: account)

        XCTAssertEqual(
            try store.pending(accountID: account.id).map(\.id),
            [second.id]
        )
        await service.setLocalSessionSync(
            .success([
                LocalPlaybackSessionSyncResult(
                    id: second.id,
                    success: true,
                    progressSynced: true,
                    error: nil
                )
            ])
        )
        await playback.syncPendingLocalSessions(for: account)

        XCTAssertTrue(try store.pending(accountID: account.id).isEmpty)
        let requests = await service.localSessionSyncRequests()
        XCTAssertEqual(
            requests.map { $0.sessions.map(\.id) },
            [
                [first.id, second.id],
                [second.id],
            ]
        )
    }

    func testNetworkPathUpdateRetriesPendingLocalSessionsWithoutBlockingLaunch()
        async throws
    {
        let storageKey = "bleat.localPlaybackSessions.v1"
        let defaults = UserDefaults.standard
        let existing = defaults.data(forKey: storageKey)
        defaults.removeObject(forKey: storageKey)
        defer {
            if let existing {
                defaults.set(existing, forKey: storageKey)
            } else {
                defaults.removeObject(forKey: storageKey)
            }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatReconnectSync-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let account = try fixtureAccount()
        let session = try localSession(
            id: "d9ef37df-6838-4dd5-9875-266ae49db169",
            itemID: "item-reconnect"
        )
        let store = LocalPlaybackSessionStore(defaults: defaults)
        try store.save(session, accountID: account.id)
        let service = TestAppService(
            accounts: .success([account]),
            activeAccount: .success(account),
            localSessionSync: .failure(
                .localPlaybackSession(.requestFailed)
            )
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("local-session-network-retry")
        )

        await model.start()
        XCTAssertEqual(model.phase, .signedIn)
        for _ in 0..<100 {
            if await service.localSessionSyncRequests().count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let initialRequests = await service.localSessionSyncRequests()
        XCTAssertEqual(initialRequests.count, 1)

        await service.setLocalSessionSync(
            .success([
                LocalPlaybackSessionSyncResult(
                    id: session.id,
                    success: true,
                    progressSynced: true,
                    error: nil
                )
            ])
        )
        for _ in 0..<100 {
            if await service.networkPathObserverCount() == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let observerCount = await service.networkPathObserverCount()
        XCTAssertEqual(observerCount, 1)
        await service.emitNetworkPathUpdate()
        for _ in 0..<100 {
            if try store.pending(accountID: account.id).isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(try store.pending(accountID: account.id).isEmpty)
        let finalRequests = await service.localSessionSyncRequests()
        XCTAssertEqual(finalRequests.count, 2)
    }

    func testNetworkPathStateAllowsRealtimeOnlyWhenUnconstrained() {
        XCTAssertFalse(AppNetworkPathState.unknown.allowsRealtimeUpdates)
        XCTAssertFalse(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: true,
                isExpensive: false
            ).allowsRealtimeUpdates
        )
        XCTAssertTrue(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: false,
                isExpensive: true
            ).allowsRealtimeUpdates
        )
    }

    func testLiveConnectionAttemptsTraceEndpointRoleRetryAndOutcome()
        async throws
    {
        let account = try fixtureAccount()
        let tracer = RecordingRemoteTelemetryTracer()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([fixtureLibrary()])
        )
        let model = AppModel(
            service: service,
            remoteTelemetryTracer: tracer
        )
        await model.start()
        for _ in 0..<100 {
            if await service.networkPathObserverCount() == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        await service.emitNetworkPathUpdate()
        for _ in 0..<100 {
            if await service.hasLiveUpdatesSubscriber() {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let baseline = tracer.spans.count
        let localAttemptID = UUID()
        let primaryAttemptID = UUID()

        await service.emitLiveUpdate(
            .connectionAttempt(
                AudiobookshelfLiveConnectionAttempt(
                    id: localAttemptID,
                    usage: .local,
                    retryBucket: .none,
                    phase: .started
                )
            ))
        await service.emitLiveUpdate(
            .connectionAttempt(
                AudiobookshelfLiveConnectionAttempt(
                    id: localAttemptID,
                    usage: .local,
                    retryBucket: .none,
                    phase: .failed(
                        AudiobookshelfLiveConnectionFailure(
                            cause: .transportUnavailable,
                            stage: .socketReceive
                        )
                    )
                )
            ))
        await service.emitLiveUpdate(
            .connectionAttempt(
                AudiobookshelfLiveConnectionAttempt(
                    id: primaryAttemptID,
                    usage: .primary,
                    retryBucket: .one,
                    phase: .started
                )
            ))
        await service.emitLiveUpdate(
            .connectionAttempt(
                AudiobookshelfLiveConnectionAttempt(
                    id: primaryAttemptID,
                    usage: .primary,
                    retryBucket: .one,
                    phase: .authenticated
                )
            ))
        for _ in 0..<100 {
            let attempts = Array(tracer.spans.dropFirst(baseline))
            if attempts.count == 2,
                attempts.allSatisfy({ $0.outcome != nil })
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            Array(tracer.spans.dropFirst(baseline)),
            [
                RecordedRemoteTelemetrySpan(
                    operation: .liveUpdateConnection,
                    source: .localServer,
                    retryBucket: .none,
                    outcome: .liveUpdateFailed(
                        RemoteTelemetryLiveUpdateFailure(
                            category: .transport,
                            code: .transportUnavailable,
                            stage: .socketReceive
                        )
                    )
                ),
                RecordedRemoteTelemetrySpan(
                    operation: .liveUpdateConnection,
                    source: .primaryServer,
                    retryBucket: .one,
                    outcome: .succeeded
                ),
            ]
        )

        let pendingAttemptID = UUID()
        await service.emitLiveUpdate(
            .connectionAttempt(
                AudiobookshelfLiveConnectionAttempt(
                    id: pendingAttemptID,
                    usage: .local,
                    retryBucket: .two,
                    phase: .started
                )
            ))
        for _ in 0..<100 {
            if tracer.spans.count == baseline + 3 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.setLiveUpdatesActive(true)
        for _ in 0..<100 {
            if tracer.spans.last?.outcome == .cancelled {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(tracer.spans.last?.outcome, .cancelled)
    }

    func testConstrainedPathControlsLiveUpdateLifecycleWithoutBlockingREST()
        async throws
    {
        let playbackFixture = try playbackRecoveryFixture()
        defer { playbackFixture.cleanUp() }
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let service = TestAppService(
            accounts: .success([account]),
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            homeShelves: .success(fixtureShelves(libraryID: library.id))
        )
        let model = AppModel(service: service)
        await model.start()
        for _ in 0..<100 {
            if await service.networkPathObserverCount() == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        await service.emitNetworkPathUpdate(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: true,
                isExpensive: false
            )
        )
        for _ in 0..<100 {
            if model.liveUpdateConnectionState == .suspendedForLowDataMode {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.account?.id, account.id)
        XCTAssertEqual(
            model.liveUpdateConnectionState,
            .suspendedForLowDataMode
        )
        var lifecycle = await service.liveUpdatesLifecycleCounts()
        XCTAssertEqual(lifecycle.starts, 0)
        XCTAssertEqual(lifecycle.stops, 0)
        var hasSubscriber = await service.hasLiveUpdatesSubscriber()
        XCTAssertFalse(hasSubscriber)

        await service.emitNetworkPathUpdate()
        for _ in 0..<100 {
            lifecycle = await service.liveUpdatesLifecycleCounts()
            if lifecycle.starts == 1,
                await service.hasLiveUpdatesSubscriber()
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        lifecycle = await service.liveUpdatesLifecycleCounts()
        XCTAssertEqual(lifecycle.starts, 1)
        XCTAssertEqual(lifecycle.stops, 0)
        hasSubscriber = await service.hasLiveUpdatesSubscriber()
        XCTAssertTrue(hasSubscriber)

        await service.emitNetworkPathUpdate()
        await service.emitNetworkPathUpdate(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: false,
                isExpensive: true
            )
        )
        for _ in 0..<100 {
            if model.networkPathState.isExpensive {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        lifecycle = await service.liveUpdatesLifecycleCounts()
        XCTAssertEqual(lifecycle.starts, 1)
        XCTAssertEqual(lifecycle.stops, 0)
        hasSubscriber = await service.hasLiveUpdatesSubscriber()
        XCTAssertTrue(hasSubscriber)

        await model.playback.startDownloaded(
            detail: playbackFixture.detail,
            trackURLs: [playbackFixture.audioURL],
            accountID: account.id,
            account: account,
            initialTime: 0.75
        )
        model.playback.setRate(1.35)
        model.playback.pause()
        let playbackItemID = model.playback.itemID
        let playbackTime = model.playback.currentTime
        let playbackRate = model.playback.rate
        let playbackState = model.playback.state
        let playbackChapter = model.playback.currentChapterIndex

        await service.emitNetworkPathUpdate(
            AppNetworkPathState(
                availability: .satisfied,
                isConstrained: true,
                isExpensive: false
            )
        )
        for _ in 0..<100 {
            lifecycle = await service.liveUpdatesLifecycleCounts()
            if lifecycle.stops == 1,
                !(await service.hasLiveUpdatesSubscriber())
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        lifecycle = await service.liveUpdatesLifecycleCounts()
        XCTAssertEqual(lifecycle.starts, 1)
        XCTAssertEqual(lifecycle.stops, 1)
        hasSubscriber = await service.hasLiveUpdatesSubscriber()
        XCTAssertFalse(hasSubscriber)
        XCTAssertEqual(model.playback.itemID, playbackItemID)
        XCTAssertEqual(model.playback.currentTime, playbackTime, accuracy: 0.01)
        XCTAssertEqual(model.playback.rate, playbackRate, accuracy: 0.001)
        XCTAssertEqual(model.playback.state, playbackState)
        XCTAssertEqual(model.playback.currentChapterIndex, playbackChapter)
        XCTAssertFalse(model.playback.isPlaybackRequested)

        await service.emitNetworkPathUpdate(
            AppNetworkPathState(
                availability: .unavailable,
                isConstrained: false,
                isExpensive: false
            )
        )
        for _ in 0..<100 {
            if model.liveUpdateConnectionState == .disconnected {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.liveUpdateConnectionState, .disconnected)
        lifecycle = await service.liveUpdatesLifecycleCounts()
        XCTAssertEqual(lifecycle.starts, 1)
        XCTAssertEqual(lifecycle.stops, 1)

        let constrainedRESTBaseline = await service.libraryRequestCount()
        await model.refreshLibraries()
        let constrainedRESTCount = await service.libraryRequestCount()
        XCTAssertEqual(
            constrainedRESTCount,
            constrainedRESTBaseline + 1
        )

        let catchUpBaseline = await service.libraryRequestCount()
        await service.emitNetworkPathUpdate()
        for _ in 0..<100 {
            lifecycle = await service.liveUpdatesLifecycleCounts()
            if lifecycle.starts == 2,
                await service.libraryRequestCount() > catchUpBaseline
            {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        lifecycle = await service.liveUpdatesLifecycleCounts()
        XCTAssertEqual(lifecycle.starts, 2)
        XCTAssertEqual(lifecycle.stops, 1)
        hasSubscriber = await service.hasLiveUpdatesSubscriber()
        XCTAssertTrue(hasSubscriber)
        let catchUpCount = await service.libraryRequestCount()
        XCTAssertEqual(catchUpCount, catchUpBaseline + 1)
        await model.playback.stop()
    }

    func testPendingLocalSessionUploadDoesNotBlockLaunch() async throws {
        let storageKey = "bleat.localPlaybackSessions.v1"
        let defaults = UserDefaults.standard
        let existing = defaults.data(forKey: storageKey)
        defaults.removeObject(forKey: storageKey)
        defer {
            if let existing {
                defaults.set(existing, forKey: storageKey)
            } else {
                defaults.removeObject(forKey: storageKey)
            }
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatHungLocalSessionSync-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let account = try fixtureAccount()
        let session = try localSession(
            id: "8b0da0fd-889a-4d97-b8f6-c0a2efac6af5",
            itemID: "item-hanging-sync"
        )
        let store = LocalPlaybackSessionStore(defaults: defaults)
        try store.save(session, accountID: account.id)
        let syncGate = AsyncGate()
        let service = TestAppService(
            accounts: .success([account]),
            activeAccount: .success(account),
            localSessionSyncGate: syncGate
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("local-session-upload")
        )
        let launchFinished = expectation(
            description: "Launch does not await local session upload"
        )
        Task { @MainActor in
            await model.start()
            launchFinished.fulfill()
        }

        await fulfillment(of: [launchFinished], timeout: 2)
        XCTAssertEqual(model.phase, .signedIn)

        let uploadStarted = expectation(
            description: "Background local session upload starts"
        )
        Task {
            await syncGate.waitUntilEntered()
            uploadStarted.fulfill()
        }
        await fulfillment(of: [uploadStarted], timeout: 2)

        XCTAssertEqual(
            try store.pending(accountID: account.id).map(\.id),
            [session.id]
        )
        let requests = await service.localSessionSyncRequests()
        XCTAssertEqual(requests.count, 1)
        await syncGate.release()
    }

    func testStartWithoutSavedAccountShowsLogin() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.account)
        XCTAssertEqual(model.libraries, .idle)
    }

    func testAppLaunchStageUsesUserFacingMessages() {
        XCTAssertEqual(AppLaunchStage.preparing.message, "Preparing Bleat")
        XCTAssertEqual(
            AppLaunchStage.reticulatingSplines.message,
            "reticulating splines…"
        )
        XCTAssertEqual(
            AppLaunchStage.restoringAccount.message,
            "Restoring your account"
        )
        XCTAssertEqual(
            AppLaunchStage.restoringDownloads.message,
            "Restoring downloads"
        )
    }

    func testStartDoesNotWaitForPrivateCloudSync() async {
        let privateCloudGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(nil),
            privateCloudSyncGate: privateCloudGate
        )
        let model = AppModel(
            service: service,
            initialLaunchStage: .reticulatingSplines
        )

        await model.start()

        XCTAssertEqual(model.phase, .signedOut)
        await privateCloudGate.waitUntilEntered()
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.privateCloudState, .syncing)

        await privateCloudGate.release()
        let synchronizationFinished = await waitUntil(
            timeout: .seconds(1)
        ) {
            model.privateCloudState == .idle
        }
        XCTAssertTrue(synchronizationFinished)
    }

    func testCloudSyncRunsOnceWhenSceneLeavesForeground() {
        XCTAssertTrue(
            AppLifecycleCloudSyncPolicy.shouldSynchronize(
                wasActive: true,
                isActive: false
            )
        )
        XCTAssertFalse(
            AppLifecycleCloudSyncPolicy.shouldSynchronize(
                wasActive: false,
                isActive: false
            )
        )
        XCTAssertFalse(
            AppLifecycleCloudSyncPolicy.shouldSynchronize(
                wasActive: false,
                isActive: true
            )
        )
    }

    func testCloudSyncCanBeCancelledAndRetriedWithoutOverlap() async {
        let privateCloudGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(nil),
            privateCloudSyncGate: privateCloudGate
        )
        let model = AppModel(service: service)

        await model.start()
        await privateCloudGate.waitUntilEntered()

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.privateCloudState, .syncing)
        XCTAssertTrue(model.canCancelPrivateCloudSynchronization)

        await model.cancelPrivateCloudSynchronization()

        XCTAssertEqual(model.privateCloudState, .cancelled)
        XCTAssertFalse(model.canCancelPrivateCloudSynchronization)
        let cancellationCount =
            await service.privateCloudCancellationRequestCount()
        XCTAssertEqual(cancellationCount, 1)

        await privateCloudGate.reset()
        let retry = Task { @MainActor in
            await model.synchronizePrivateCloud()
        }
        await privateCloudGate.waitUntilEntered()

        XCTAssertEqual(model.privateCloudState, .syncing)
        XCTAssertTrue(model.canCancelPrivateCloudSynchronization)

        await privateCloudGate.release()
        await retry.value

        XCTAssertEqual(model.privateCloudState, .idle)
        XCTAssertFalse(model.canCancelPrivateCloudSynchronization)
    }

    func testCloudSyncCanRestartWhileStatisticsSummaryReloadContinues()
        async
    {
        let privateCloudGate = AsyncGate()
        let statisticsSummaryGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(nil),
            privateCloudSyncGate: privateCloudGate,
            statisticsSummaryGate: statisticsSummaryGate
        )
        let model = AppModel(service: service)

        await model.start()
        await privateCloudGate.waitUntilEntered()
        await privateCloudGate.release()
        await statisticsSummaryGate.waitUntilEntered()

        XCTAssertEqual(model.privateCloudState, .idle)
        XCTAssertFalse(model.canCancelPrivateCloudSynchronization)

        await privateCloudGate.reset()
        let secondSync = Task { @MainActor in
            await model.synchronizePrivateCloud()
        }
        await privateCloudGate.waitUntilEntered()

        XCTAssertEqual(model.privateCloudState, .syncing)
        XCTAssertTrue(model.canCancelPrivateCloudSynchronization)

        await statisticsSummaryGate.release()
        await privateCloudGate.release()
        await secondSync.value

        XCTAssertEqual(model.privateCloudState, .idle)
    }

    func testCloudKitFailureIsNotPresentedAsAudiobookshelfOutage() async {
        let failure = PrivateCloudSyncFailure(
            operation: .synchronize,
            cause: .cloudKit(
                CloudKitFailure(CKError(.networkFailure))
            )
        )
        let service = TestAppService(
            activeAccount: .success(nil),
            privateCloudSyncResult: .failure(.privateCloud(failure))
        )
        let model = AppModel(service: service)

        await model.start()
        let didFail = await waitUntil(timeout: .seconds(1)) {
            if case .failed = model.privateCloudState { return true }
            return false
        }

        XCTAssertTrue(didFail)
        guard case .failed(let presented) = model.privateCloudState else {
            return XCTFail("Expected a typed iCloud failure")
        }
        XCTAssertEqual(presented.title, "iCloud sync unavailable")
        XCTAssertTrue(presented.message.contains("iCloud"))
        XCTAssertFalse(presented.message.contains("Audiobookshelf"))
        XCTAssertTrue(presented.allowsRetry)
    }

    func testStartKeepsCloudSyncDisabledWhenUnavailable() async {
        let accountsGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(nil),
            accountsGate: accountsGate,
            privateCloudSyncAvailable: false
        )
        let model = AppModel(
            service: service,
            initialLaunchStage: .reticulatingSplines
        )

        let start = Task { @MainActor in
            await model.start()
        }

        await accountsGate.waitUntilEntered()
        XCTAssertEqual(model.launchStage, .restoringAccount)

        await accountsGate.release()
        await start.value
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.privateCloudState, .disabled)
    }

    func testRetryStartResetsTheInitialLaunchStage() async {
        let preparationGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .failure(.accountStore(.persistenceFailed)),
            serverEndpointRouterGate: preparationGate
        )
        let model = AppModel(
            service: service,
            initialLaunchStage: .reticulatingSplines
        )

        let firstStart = Task { @MainActor in
            await model.start()
        }
        await preparationGate.waitUntilEntered()
        XCTAssertEqual(model.launchStage, .reticulatingSplines)
        await preparationGate.release()
        await firstStart.value
        XCTAssertEqual(model.phase, .unavailable(.accountUnavailable))

        await preparationGate.reset()
        await service.setActiveAccountResult(.success(nil))
        let retry = Task { @MainActor in
            await model.retryStart()
        }
        await preparationGate.waitUntilEntered()
        XCTAssertEqual(model.phase, .launching)
        XCTAssertEqual(model.launchStage, .reticulatingSplines)
        await preparationGate.release()
        await retry.value
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testCloudKitDisabledBuildKeepsSynchronizationUnavailable() async {
        let service = TestAppService(
            activeAccount: .success(nil),
            privateCloudSyncAvailable: false
        )
        let model = AppModel(service: service)

        await model.start()
        await model.setPrivateCloudSyncEnabled(true)

        XCTAssertFalse(model.privateCloudSyncAvailable)
        XCTAssertFalse(model.privateCloudSyncEnabled)
        XCTAssertEqual(model.privateCloudState, .disabled)
    }

    func testDiagnosticsRecordLifecycleAndTypedAuthFailureWithoutInputs()
        async
    {
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .failure(
                .onboarding(
                    .authenticationFailed(.invalidCredentials)
                )
            )
        )
        let recorder = AppDiagnosticRecorderSpy()
        let model = AppModel(
            service: service,
            diagnostics: recorder
        )

        await model.start()
        _ = await model.login(
            serverAddress: "https://secret.example/private",
            username: "private-user",
            password: "private-password"
        )

        let events = await recorder.events()
        XCTAssertTrue(
            events.contains {
                $0.operation == .appStart
                    && $0.name == .operationCompleted
            }
        )
        XCTAssertTrue(
            events.contains {
                $0.fromState == .launching
                    && $0.toState == .signedOut
            }
        )
        XCTAssertTrue(
            events.contains {
                $0.operation == .login
                    && $0.failureCode == .invalidCredentials
            }
        )
        let exportedText = events.map(\.text).joined(separator: "\n")
        XCTAssertFalse(exportedText.contains("secret.example"))
        XCTAssertFalse(exportedText.contains("private-user"))
        XCTAssertFalse(exportedText.contains("private-password"))
    }

    func testStartRestoresAccountAndLoadsFirstAudiobookLibrary() async throws {
        let account = try fixtureAccount()
        let audiobookLibrary = fixtureLibrary()
        let podcastLibrary = LibrarySummary(
            id: LibraryID(rawValue: "podcasts"),
            name: "Podcasts",
            mediaType: .podcast
        )
        let page = fixturePage(libraryID: audiobookLibrary.id)
        let shelves = fixtureShelves(libraryID: audiobookLibrary.id)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([podcastLibrary, audiobookLibrary]),
            firstPage: .success(page),
            homeShelves: .success(shelves)
        )
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(model.libraries, .loaded([audiobookLibrary]))
        XCTAssertEqual(model.selectedLibrary, audiobookLibrary)
        XCTAssertEqual(model.books, .loaded(page))
        XCTAssertEqual(model.homeShelves, .loaded(shelves))
        XCTAssertFalse(model.isBookFinished(page.items[0].id))
        let pageRequests = await service.pageRequests()
        XCTAssertEqual(pageRequests, [audiobookLibrary.id])
        let homeRequests = await service.homeRequests()
        XCTAssertEqual(homeRequests, [audiobookLibrary.id])
    }

    func testStartLoadsFinishedStateAndAccountSwitchSuppressesStaleProgress()
        async throws
    {
        let first = try fixtureAccount()
        let second = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "second",
            server: "https://second.example"
        )
        let firstItemID = LibraryItemID(rawValue: "first-item")
        let secondItemID = LibraryItemID(rawValue: "second-item")
        let firstGate = AsyncGate()
        let service = TestAppService(
            accounts: .success([first, second]),
            activeAccount: .success(first),
            allBookProgress: [
                .success([
                    fixtureProgress(
                        userID: first.user.id,
                        itemID: firstItemID,
                        isFinished: true
                    )
                ]),
                .success([
                    fixtureProgress(
                        userID: second.user.id,
                        itemID: secondItemID,
                        isFinished: true
                    )
                ]),
            ],
            firstAllBookProgressGate: firstGate
        )
        let model = AppModel(service: service)
        let startTask = Task { await model.start() }
        await firstGate.waitUntilEntered()

        await model.switchAccount(to: second)

        XCTAssertFalse(model.isBookFinished(firstItemID))
        XCTAssertTrue(model.isBookFinished(secondItemID))
        await firstGate.release()
        await startTask.value
        XCTAssertFalse(model.isBookFinished(firstItemID))
        XCTAssertTrue(model.isBookFinished(secondItemID))
    }

    func testLiveProgressUpdatesFinishedStateImmediately() async throws {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let account = try fixtureAccount()
        let itemID = fixture.detail.id
        let service = TestAppService(activeAccount: .success(account))
        let model = AppModel(service: service)
        await model.start()
        for _ in 0..<100 {
            if await service.networkPathObserverCount() > 0 {
                break
            }
            await Task.yield()
        }
        await service.emitNetworkPathUpdate()
        for _ in 0..<100 where !(await service.hasLiveUpdatesSubscriber()) {
            await Task.yield()
        }
        let hasSubscriber = await service.hasLiveUpdatesSubscriber()
        XCTAssertTrue(hasSubscriber)

        await model.playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL],
            accountID: account.id,
            account: account,
            initialTime: 0.75
        )
        model.playback.setRate(1.35)
        model.playback.pause()
        let playbackItemID = model.playback.itemID
        let playbackTime = model.playback.currentTime
        let playbackRate = model.playback.rate
        let playbackState = model.playback.state
        let playbackChapter = model.playback.currentChapterIndex

        await service.emitLiveUpdate(
            .event(
                .playbackProgress(
                    AudiobookshelfLivePlaybackProgress(
                        itemID: itemID,
                        sessionID: nil,
                        deviceDescription: nil,
                        currentTime: 60,
                        duration: 60,
                        isFinished: true,
                        lastUpdateMilliseconds: 1
                    )
                )
            )
        )
        for _ in 0..<100 where !model.isBookFinished(itemID) {
            await Task.yield()
        }

        XCTAssertTrue(model.isBookFinished(itemID))
        XCTAssertEqual(model.playback.itemID, playbackItemID)
        XCTAssertEqual(model.playback.currentTime, playbackTime, accuracy: 0.01)
        XCTAssertEqual(model.playback.rate, playbackRate, accuracy: 0.001)
        XCTAssertEqual(model.playback.state, playbackState)
        XCTAssertEqual(model.playback.currentChapterIndex, playbackChapter)
        XCTAssertFalse(model.playback.isPlaybackRequested)
        await model.playback.stop()
    }

    func testStartRunsOnlyOnce() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.start()
        await model.start()

        let requestCount = await service.activeAccountRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSwitchAccountPersistsSelectionAndReloadsBrowsingContext()
        async throws
    {
        let first = try fixtureAccount()
        let second = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "second",
            server: "https://second.example"
        )
        let service = TestAppService(
            accounts: .success([first, second]),
            activeAccount: .success(first)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.switchAccount(to: second)

        XCTAssertEqual(model.account, second)
        XCTAssertEqual(model.accounts, [first, second])
        XCTAssertEqual(model.accountActionStatus, .idle)
        let activated = await service.activatedAccounts()
        XCTAssertEqual(activated, [second])
        XCTAssertFalse(model.playback.hasActiveBook)
    }

    func testStartFailureShowsUnavailableState() async {
        let service = TestAppService(
            activeAccount: .failure(.accountStore(.persistenceFailed))
        )
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .unavailable(.accountUnavailable))
    }

    func testBootstrapFailureRemainsUnavailableWhenRootStarts() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(
            service: service,
            bootstrapError: .persistenceUnavailable
        )

        await model.start()

        XCTAssertEqual(model.phase, .unavailable(.persistenceUnavailable))
        let requestCount = await service.activeAccountRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testRetryStartReattemptsBootstrapWhenUnavailable() async {
        let service = TestAppService(
            accounts: .success([]),
            activeAccount: .failure(.accountStore(.persistenceFailed))
        )
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .unavailable(.accountUnavailable))
        let afterStart = await service.activeAccountRequestCount()
        XCTAssertEqual(afterStart, 1)

        await model.retryStart()

        let afterRetry = await service.activeAccountRequestCount()
        XCTAssertEqual(afterRetry, 2)
        XCTAssertEqual(model.phase, .unavailable(.accountUnavailable))
    }

    func testRetryStartRecoversWhenServiceSucceeds() async {
        let service = TestAppService(
            activeAccount: .failure(.accountStore(.persistenceFailed))
        )
        let model = AppModel(
            service: service,
            bootstrapError: .persistenceUnavailable
        )

        await service.setActiveAccountResult(.success(nil))
        await model.retryStart()

        XCTAssertEqual(model.phase, .signedOut)
    }

    func testRetryStartIsNoOpOutsideUnavailable() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .signedOut)
        let afterStart = await service.activeAccountRequestCount()
        XCTAssertEqual(afterStart, 1)

        await model.retryStart()

        let afterRetry = await service.activeAccountRequestCount()
        XCTAssertEqual(afterRetry, 1)
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testNativeLoginForwardsUsernamePasswordAndLoadsLibrary() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .success(account),
            libraries: .success([library]),
            firstPage: .success(page)
        )
        let model = AppModel(service: service)

        await model.login(
            serverAddress: "https://books.example/audiobookshelf",
            username: "reader",
            password: "correct horse"
        )

        let loginRequests = await service.loginRequests()
        XCTAssertEqual(
            loginRequests,
            [
                LoginRequest(
                    serverAddress: "https://books.example/audiobookshelf",
                    username: "reader",
                    password: "correct horse"
                )
            ]
        )
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.loginStatus, .idle)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(model.books, .loaded(page))
    }

    func testRejectedNativeCredentialsRemainSignedOut() async {
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .failure(
                .onboarding(
                    .authenticationFailed(.invalidCredentials)
                )
            )
        )
        let model = AppModel(service: service)

        await model.start()
        await model.login(
            serverAddress: "https://books.example",
            username: "reader",
            password: "wrong"
        )

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.loginStatus, .failed(.invalidCredentials))
        XCTAssertNil(model.account)
    }

    func testOpenIDLoginForwardsServerAndLoadsLibrary() async throws {
        let account = try fixtureAccount(authenticationMethods: [.openID])
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .success(account),
            libraries: .success([library]),
            firstPage: .success(page)
        )
        let model = AppModel(service: service)

        let authenticated = await model.loginWithOpenID(
            serverAddress: "https://books.example/audiobookshelf"
        )

        XCTAssertTrue(authenticated)
        let requests = await service.openIDLoginRequests()
        XCTAssertEqual(
            requests,
            ["https://books.example/audiobookshelf"]
        )
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.loginStatus, .idle)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(model.books, .loaded(page))
    }

    func testReauthenticationUsesSavedAccountAndReloadsLibrary()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(account),
            login: .success(account),
            libraries: .success([library]),
            firstPage: .success(page)
        )
        let model = AppModel(service: service)
        await model.start()

        let authenticated = await model.reauthenticate(
            password: "new password"
        )

        XCTAssertTrue(authenticated)
        let requests = await service.reauthenticationRequests()
        XCTAssertEqual(
            requests,
            [
                ReauthenticationRequest(
                    accountID: account.id,
                    password: "new password"
                )
            ]
        )
        XCTAssertEqual(model.loginStatus, .idle)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(model.books, .loaded(page))
    }

    func testAccountEditorUpdatesPrimaryLocalAndCredentials() async throws {
        let account = try fixtureAccount()
        let updated = try ServerAccount(
            id: account.id,
            server: NormalizedServerURL("https://primary.example"),
            localServer: NormalizedServerURL("https://local.example"),
            localServerValidated: true,
            serverVersion: account.serverVersion,
            authenticationMethods: account.authenticationMethods,
            user: AuthenticatedUser(
                id: account.user.id,
                username: "updated-reader",
                type: account.user.type,
                permissions: account.user.permissions,
                accessibleLibraryIDs: account.user.accessibleLibraryIDs,
                selectedItemTags: account.user.selectedItemTags
            )
        )
        let delayedCloudAccount = try ServerAccount(
            id: account.id,
            server: NormalizedServerURL("https://old.example"),
            localServer: nil,
            localServerValidated: false,
            serverVersion: account.serverVersion,
            authenticationMethods: account.authenticationMethods,
            user: account.user
        )
        let service = TestAppService(
            activeAccount: .success(account),
            login: .success(updated),
            privateCloudSyncChanges: [
                CloudServerConfigurationChange(
                    current: account,
                    incoming: delayedCloudAccount
                )
            ]
        )
        let model = AppModel(service: service)
        await model.start()
        let cloudChangeQueued = await waitUntil(timeout: .seconds(2)) {
            !model.pendingCloudServerConfigurationChanges.isEmpty
        }
        XCTAssertTrue(cloudChangeQueued)
        XCTAssertFalse(model.pendingCloudServerConfigurationChanges.isEmpty)

        let result = await model.updateAccount(
            account,
            serverAddress: "https://primary.example",
            localServerAddress: "https://local.example",
            username: "updated-reader",
            password: "updated-password"
        )

        XCTAssertEqual(result, .saved)
        XCTAssertEqual(model.account, updated)
        XCTAssertEqual(model.accounts, [updated])
        XCTAssertTrue(model.pendingCloudServerConfigurationChanges.isEmpty)
        let forcedCloudAccounts = await service.forcedCloudAccounts()
        XCTAssertEqual(forcedCloudAccounts, [updated])
        let requests = await service.accountUpdateRequests()
        XCTAssertEqual(
            requests,
            [
                AccountUpdateRequest(
                    accountID: account.id,
                    serverAddress: "https://primary.example",
                    localServerAddress: "https://local.example",
                    username: "updated-reader",
                    password: "updated-password",
                    localServerValidation: .required
                )
            ]
        )
    }

    func testCloudServerConfigurationChangeWaitsForUserDecision()
        async throws
    {
        let current = try fixtureAccount()
        let incoming = try ServerAccount(
            id: current.id,
            server: NormalizedServerURL("https://incoming.example"),
            localServer: NormalizedServerURL("https://local.example"),
            localServerValidated: true,
            serverVersion: current.serverVersion,
            authenticationMethods: current.authenticationMethods,
            user: current.user
        )
        let change = CloudServerConfigurationChange(
            current: current,
            incoming: incoming
        )
        let service = TestAppService(
            activeAccount: .success(current),
            privateCloudSyncChanges: [change]
        )
        let model = AppModel(service: service)

        await model.start()

        let cloudChangeQueued = await waitUntil(timeout: .seconds(2)) {
            model.pendingCloudServerConfigurationChanges == [change]
        }
        XCTAssertTrue(cloudChangeQueued)
        XCTAssertEqual(
            model.pendingCloudServerConfigurationChanges,
            [change]
        )
        XCTAssertEqual(model.account, current)

        await model.resolveCloudServerConfigurationChange(
            change,
            accept: false
        )

        XCTAssertTrue(model.pendingCloudServerConfigurationChanges.isEmpty)
        let resolutions = await service.cloudResolutions()
        XCTAssertEqual(resolutions.count, 1)
        XCTAssertEqual(resolutions[0].accountID, current.id)
        XCTAssertFalse(resolutions[0].accept)
    }

    func testFreshInstallCloudRestoreShowsSingleFlightAndEmptyResult()
        async throws
    {
        let gate = AsyncGate()
        let service = TestAppService(
            accounts: .success([]),
            activeAccount: .success(nil),
            privateCloudSyncGate: gate
        )
        let model = AppModel(service: service)

        await model.start()

        let started = await waitUntil(timeout: .seconds(2)) {
            model.cloudAccountRestoreState == .synchronizing
        }
        XCTAssertTrue(started)
        async let retry: Void = model.synchronizePrivateCloud()
        await gate.release()
        _ = await retry
        let completed = await waitUntil(timeout: .seconds(2)) {
            model.cloudAccountRestoreState == .noAccounts
        }
        XCTAssertTrue(completed)
    }

    func testPendingRestoredAccountRemainsSignedOutAwaitingPassword()
        async throws
    {
        let connected = try fixtureAccount()
        let pending = try connected.updatingConnectionState(
            .reauthenticationRequired
        )
        let service = TestAppService(
            accounts: .success([pending]),
            activeAccount: .success(nil)
        )
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.pendingRestoredAccount, pending)
        XCTAssertEqual(
            model.cloudAccountRestoreState,
            .awaitingCredentials(pending.id)
        )
        let acceptedEmptyPassword =
            await model.authenticatePendingRestoredAccount(password: "")
        XCTAssertFalse(acceptedEmptyPassword)
    }

    func testCloudConfigurationConflictWaitsForExplicitResolution()
        async throws
    {
        let local = cloudConfigurationSnapshot(
            previousCommandAction: .previousChapter,
            nextCommandAction: .nextChapter
        )
        let cloud = cloudConfigurationSnapshot(
            previousCommandAction: .nextChapter,
            nextCommandAction: .previousChapter
        )
        let conflict = CloudConfigurationConflict(
            local: local,
            iCloud: cloud
        )
        let service = TestAppService(
            activeAccount: .success(nil),
            privateCloudConfigurationConflict: conflict
        )
        let model = AppModel(service: service)

        await model.start()

        let conflictQueued = await waitUntil(timeout: .seconds(2)) {
            model.pendingCloudConfigurationConflict == conflict
        }
        XCTAssertTrue(conflictQueued)

        let resolutionFailure = await model.resolveCloudConfigurationConflict(
            .keepThisDevice
        )
        let resolutions = await service.cloudConfigurationResolutions()

        XCTAssertNil(resolutionFailure)
        XCTAssertNil(model.pendingCloudConfigurationConflict)
        XCTAssertEqual(
            resolutions,
            [.keepThisDevice]
        )
        XCTAssertEqual(model.privateCloudState, .idle)
    }

    func testDisablingCloudSyncClearsPendingServerConfigurationChange()
        async throws
    {
        let current = try fixtureAccount()
        let incoming = try ServerAccount(
            id: current.id,
            server: NormalizedServerURL("https://incoming.example"),
            localServer: nil,
            localServerValidated: false,
            serverVersion: current.serverVersion,
            authenticationMethods: current.authenticationMethods,
            user: current.user
        )
        let service = TestAppService(
            activeAccount: .success(current),
            privateCloudSyncChanges: [
                CloudServerConfigurationChange(
                    current: current,
                    incoming: incoming
                )
            ]
        )
        let model = AppModel(service: service)

        await model.start()
        await model.setPrivateCloudSyncEnabled(false)

        XCTAssertFalse(model.privateCloudSyncEnabled)
        XCTAssertTrue(model.pendingCloudServerConfigurationChanges.isEmpty)
        XCTAssertEqual(model.privateCloudState, .disabled)
    }

    func testOpenIDReauthenticationUsesSavedAccount() async throws {
        let account = try fixtureAccount(authenticationMethods: [.openID])
        let service = TestAppService(
            activeAccount: .success(account),
            login: .success(account)
        )
        let model = AppModel(service: service)
        await model.start()

        let authenticated = await model.reauthenticateWithOpenID()

        XCTAssertTrue(authenticated)
        let requests = await service.openIDReauthenticationRequests()
        XCTAssertEqual(
            requests,
            [account.id]
        )
        XCTAssertEqual(model.loginStatus, .idle)
        XCTAssertEqual(model.account, account)
    }

    func testAccountEditorKeepsCredentialsWhenPasswordIsBlank() async throws {
        let account = try fixtureAccount()
        let updated = try ServerAccount(
            id: account.id,
            server: NormalizedServerURL("https://new.example"),
            serverVersion: account.serverVersion,
            authenticationMethods: account.authenticationMethods,
            user: account.user
        )
        let service = TestAppService(
            activeAccount: .success(account),
            login: .success(updated)
        )
        let model = AppModel(service: service)
        await model.start()

        let result = await model.updateAccount(
            account,
            serverAddress: "https://new.example",
            localServerAddress: "",
            username: account.user.username,
            password: ""
        )

        XCTAssertEqual(result, .saved)
        XCTAssertEqual(model.account, updated)
        let requests = await service.accountUpdateRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].password, "")
    }

    func testPrimaryOnlyAccountEditSkipsLocalValidation() throws {
        let fixture = try fixtureAccount()
        let account = try ServerAccount(
            id: fixture.id,
            server: NormalizedServerURL("https://old.example"),
            localServer: NormalizedServerURL("https://local.example"),
            localServerValidated: false,
            serverVersion: fixture.serverVersion,
            authenticationMethods: fixture.authenticationMethods,
            user: fixture.user
        )

        XCTAssertEqual(
            LocalServerValidationDecision.decide(
                account: account,
                primary: try NormalizedServerURL("https://new.example"),
                local: account.localServer,
                username: account.user.username
            ),
            .skip
        )
        XCTAssertEqual(
            LocalServerValidationDecision.decide(
                account: account,
                primary: account.server,
                local: try NormalizedServerURL(
                    "https://new-local.example"
                ),
                username: account.user.username
            ),
            .validate
        )
    }

    func testTemporaryLocalFailureNeverRevokesExistingValidation() throws {
        let fixture = try fixtureAccount()
        let local = try NormalizedServerURL("https://local.example")
        let account = try ServerAccount(
            id: fixture.id,
            server: fixture.server,
            localServer: local,
            localServerValidated: true,
            serverVersion: fixture.serverVersion,
            authenticationMethods: fixture.authenticationMethods,
            user: fixture.user
        )

        XCTAssertTrue(
            LocalServerValidationDecision.persistedValidation(
                account: account,
                local: local,
                validationSucceeded: false
            )
        )
        XCTAssertFalse(
            LocalServerValidationDecision.persistedValidation(
                account: account,
                local: try NormalizedServerURL(
                    "https://different-local.example"
                ),
                validationSucceeded: false
            )
        )
    }

    func testAccountEditorCanSaveAfterLocalValidationFailure() async throws {
        let account = try fixtureAccount()
        let updated = try ServerAccount(
            id: account.id,
            server: NormalizedServerURL("https://new.example"),
            localServer: NormalizedServerURL("https://offline.local"),
            localServerValidated: false,
            serverVersion: account.serverVersion,
            authenticationMethods: account.authenticationMethods,
            user: account.user
        )
        let service = TestAppService(
            activeAccount: .success(account),
            login: .success(updated)
        )
        await service.enqueueAccountUpdateOutcome(
            .localServerValidationFailed(.discoveryRequestFailed)
        )
        let model = AppModel(service: service)
        await model.start()

        let warning = await model.updateAccount(
            account,
            serverAddress: "https://new.example",
            localServerAddress: "https://offline.local",
            username: account.user.username,
            password: "password"
        )
        XCTAssertEqual(
            warning,
            .localServerValidationFailed(
                AppFailure(.reauthenticate, .serverUnavailable)
            )
        )
        XCTAssertEqual(model.account, account)

        let saved = await model.updateAccount(
            account,
            serverAddress: "https://new.example",
            localServerAddress: "https://offline.local",
            username: account.user.username,
            password: "password",
            allowUnvalidatedLocalServer: true
        )

        XCTAssertEqual(saved, .saved)
        XCTAssertEqual(model.account, updated)
        let requests = await service.accountUpdateRequests()
        XCTAssertEqual(
            requests.map(\.localServerValidation),
            [.required, .allowUnvalidated]
        )
    }

    func testConcurrentLoginIsIgnoredWhileSubmissionIsActive() async throws {
        let account = try fixtureAccount()
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .success(account),
            libraries: .success([]),
            loginGate: gate
        )
        let model = AppModel(service: service)

        let firstLogin = Task { @MainActor in
            await model.login(
                serverAddress: "https://books.example",
                username: "reader",
                password: "first"
            )
        }
        await gate.waitUntilEntered()

        await model.login(
            serverAddress: "https://other.example",
            username: "other",
            password: "second"
        )
        await gate.release()
        _ = await firstLogin.value

        let loginRequestCount = await service.loginRequests().count
        XCTAssertEqual(loginRequestCount, 1)
    }

    func testLoginReportsSubmissionStageWhileServiceIsRunning()
        async throws
    {
        let account = try fixtureAccount()
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .success(account),
            libraries: .success([]),
            loginGate: gate
        )
        let model = AppModel(service: service)

        let login = Task { @MainActor in
            await model.login(
                serverAddress: "https://books.example",
                username: "reader",
                password: "password"
            )
        }
        await gate.waitUntilEntered()

        XCTAssertEqual(model.loginStatus, .submitting(.signingIn))

        await gate.release()
        let signedIn = await login.value
        XCTAssertTrue(signedIn)
        XCTAssertEqual(model.loginStatus, .idle)
    }

    func testAccountUpdateReportsSubmissionStageWhileServiceIsRunning()
        async throws
    {
        let account = try fixtureAccount()
        let updated = try fixtureAccount()
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            login: .success(updated),
            accountUpdateGate: gate
        )
        let model = AppModel(service: service)
        await model.start()

        let update = Task { @MainActor in
            await model.updateAccount(
                account,
                serverAddress: "https://books.example",
                localServerAddress: "",
                username: account.user.username,
                password: "password"
            )
        }
        await gate.waitUntilEntered()

        XCTAssertEqual(model.loginStatus, .submitting(.signingIn))

        await gate.release()
        let result = await update.value
        XCTAssertEqual(result, .saved)
        XCTAssertEqual(model.loginStatus, .idle)
    }

    func testLibraryFailureAndRetry() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .failure(
                .libraryRepository(.remote(.unexpectedStatus(503)))
            )
        )
        let model = AppModel(service: service)

        await model.start()
        XCTAssertEqual(model.libraries, .failed(.libraryUnavailable))

        await service.setLibraries(.success([library]))
        await service.setFirstPage(
            .success(fixturePage(libraryID: library.id))
        )
        await model.loadLibraries()

        XCTAssertEqual(model.libraries, .loaded([library]))
        XCTAssertEqual(model.selectedLibrary, library)
    }

    func testSelectingLibraryHandlesPageFailure() async throws {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            firstPage: .failure(
                .libraryRepository(.remote(.invalidPage))
            )
        )
        let model = AppModel(service: service)

        await model.start()
        await model.selectLibrary(fixtureLibrary())

        XCTAssertEqual(
            model.books,
            .failed(AppFailure(.loadLibraryPage, .invalidServerResponse))
        )
    }

    func testLoadingNextLibraryPageAppendsBooks() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstBook = fixtureBook(
            id: "item-1",
            title: "First",
            libraryID: library.id
        )
        let secondBook = fixtureBook(
            id: "item-2",
            title: "Second",
            libraryID: library.id
        )
        let firstPage = LibraryItemsPage(
            items: [firstBook],
            total: 2,
            page: 0,
            limit: 1
        )
        let nextPage = LibraryItemsPage(
            items: [secondBook],
            total: 2,
            page: 1,
            limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(firstPage),
            nextPage: .success(nextPage)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadNextBooksPage()

        XCTAssertEqual(
            model.books,
            .loaded(
                LibraryItemsPage(
                    items: [firstBook, secondBook],
                    total: 2,
                    page: 1,
                    limit: 1
                )
            )
        )
        XCTAssertEqual(model.libraryPaginationState, .idle)
        let selections = await service.pageSelections()
        XCTAssertEqual(
            selections,
            [
                PageSelection(
                    page: 0,
                    sort: .title,
                    descending: false,
                    filter: nil
                ),
                PageSelection(
                    page: 1,
                    sort: .title,
                    descending: false,
                    filter: nil
                ),
            ]
        )
    }

    // MARK: - 10,000-book performance baseline (issue #46, spec section 19)

    /// Loading all 10,000 books (500 pages at the app default limit of 20)
    /// through `loadNextBooksPage` must preserve pagination and deduplicate
    /// every received page while `LibraryPageMerger` performs the growing
    /// collection work away from the main actor.
    func testTenKBooksLoadNextBooksPagePerformance() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let libraryID = library.id
        let totalBooks = 10_000
        let pageLimit = 20
        let pageCount = totalBooks / pageLimit

        let makeBook: @Sendable (Int) -> LibraryBookSummary =
            { index in
                let authorName = "Author \(index % 8)"
                let authorID = AuthorID(rawValue: "author-\(index % 8)")!
                let years = ["1950", "1970", "1990", "2010", "2020"]
                let baseMillis =
                    Int64(1_700_000_000_000)
                    + Int64(index) * 3_600_000
                return LibraryBookSummary(
                    id: LibraryItemID(rawValue: "book-\(index)"),
                    libraryID: libraryID,
                    title: "Book Title \(index)",
                    subtitle: nil,
                    authorName: authorName,
                    narratorName: nil,
                    seriesName: nil,
                    authors: [
                        LibraryBookContributor(id: authorID, name: authorName)
                    ],
                    series: [],
                    collapsedSeries: nil,
                    genres: ["Fiction"],
                    tags: [],
                    publisher: nil,
                    publishedYear: years[index % years.count],
                    duration: Double(45 + (index % 436)),
                    trackCount: (index % 20) + 1,
                    chapterCount: (index % 150) + 1,
                    addedAtMilliseconds: baseMillis,
                    updatedAtMilliseconds: baseMillis
                        + Int64((index % 24) * 3_600_000),
                    isExplicit: index % 10 == 0,
                    isAbridged: index % 25 == 0
                )
            }
        let provider:
            @Sendable (Int) -> Result<LibraryItemsPage, AppServiceError> =
                { pageIndex in
                    let start = pageIndex * pageLimit
                    let end = min(start + pageLimit, totalBooks)
                    var items = (start..<end).map(makeBook)
                    if start > 0 {
                        // Every subsequent page repeats the preceding page's last
                        // item so the full sweep exercises de-duplication.
                        items.append(makeBook(start - 1))
                    }
                    return .success(
                        LibraryItemsPage(
                            items: items,
                            total: totalBooks,
                            page: pageIndex,
                            limit: pageLimit
                        )
                    )
                }
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            pagedProvider: provider
        )
        let model = AppModel(service: service)

        await model.start()
        guard case .loaded(let firstPage) = model.books else {
            XCTFail("first page must load during start()")
            return
        }
        XCTAssertEqual(firstPage.items.count, pageLimit)
        XCTAssertEqual(firstPage.total, totalBooks)

        let heartbeat = Task { @MainActor in
            var ticks = 0
            while !Task.isCancelled {
                ticks &+= 1
                await Task.yield()
            }
            return ticks
        }
        defer { heartbeat.cancel() }
        let sampleIndices: Set<Int> = [1, pageCount / 2, pageCount - 1]
        var sampleTimings: [(call: Int, seconds: Double)] = []
        let sweepStart = CACurrentMediaTime()
        var callsMade = 0
        var lastItemCount = firstPage.items.count
        while case .loaded(let current) = model.books, current.hasNextPage {
            let callIndex = callsMade + 1
            let callStart = CACurrentMediaTime()
            await model.loadNextBooksPage()
            let callElapsed = CACurrentMediaTime() - callStart
            if sampleIndices.contains(callIndex) {
                sampleTimings.append((callIndex, callElapsed))
            }
            callsMade &+= 1
            // Guard against a non-advancing loop or runaway sweep.
            guard case .loaded(let after) = model.books,
                after.items.count >= lastItemCount,
                callsMade <= pageCount
            else {
                let stuckCount: Int
                if case .loaded(let stuck) = model.books {
                    stuckCount = stuck.items.count
                } else {
                    stuckCount = -1
                }
                XCTFail(
                    "loadNextBooksPage stalled at call #\(callIndex) "
                        + "with \(stuckCount) items"
                )
                return
            }
            lastItemCount = after.items.count
        }
        let sweepElapsed = CACurrentMediaTime() - sweepStart

        guard case .loaded(let final) = model.books else {
            XCTFail("books must remain loaded after sweep")
            return
        }
        heartbeat.cancel()
        let mainActorTicks = await heartbeat.value
        let finalIDs = final.items.map(\.id)
        XCTAssertEqual(
            final.items.count,
            totalBooks,
            "all 10k books must accumulate"
        )
        XCTAssertEqual(
            Set(finalIDs).count,
            totalBooks,
            "overlapping pages must not publish duplicate books"
        )
        XCTAssertEqual(final.page, pageCount - 1)
        XCTAssertEqual(final.limit, pageLimit)
        XCTAssertFalse(final.hasNextPage)
        XCTAssertEqual(model.libraryPaginationState, .idle)
        XCTAssertEqual(
            callsMade,
            pageCount - 1,
            "must advance through every page after start"
        )
        XCTAssertGreaterThan(
            mainActorTicks,
            0,
            "the main actor must advance while AppModel loads and merges pages"
        )
        XCTAssertLessThan(
            sweepElapsed,
            30.0,
            "10k-page sweep exceeded 30s"
        )

        for timing in sampleTimings {
            print(
                "perf-sample loadNextBooksPage call #\(timing.call): "
                    + "\(String(format: "%.6f", timing.seconds))s"
            )
        }
        print(
            "perf-summary loadNextBooksPage sweep: \(callsMade) calls, "
                + "\(String(format: "%.6f", sweepElapsed))s total, "
                + "\(final.items.count) books"
        )
    }

    func testIdenticalRefreshPreservesLoadedPagesWithoutPublishing()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstBook = fixtureBook(
            id: "item-1",
            title: "First",
            libraryID: library.id
        )
        let secondBook = fixtureBook(
            id: "item-2",
            title: "Second",
            libraryID: library.id
        )
        let firstPage = LibraryItemsPage(
            items: [firstBook], total: 2, page: 0, limit: 1
        )
        let nextPage = LibraryItemsPage(
            items: [secondBook], total: 2, page: 1, limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(firstPage),
            nextPage: .success(nextPage)
        )
        let model = AppModel(service: service)
        await model.start()
        await model.loadNextBooksPage()

        let browsingStateChanged = expectation(
            description: "Observable paginated state changed"
        )
        browsingStateChanged.isInverted = true
        withObservationTracking {
            _ = model.books
            _ = model.booksRefreshState
            _ = model.libraryPaginationState
            _ = model.homeShelves
            _ = model.homeShelvesRefreshState
        } onChange: {
            browsingStateChanged.fulfill()
        }

        await model.refreshSelectedLibrary()

        await fulfillment(of: [browsingStateChanged], timeout: 0.1)
        XCTAssertEqual(
            model.books,
            .loaded(
                LibraryItemsPage(
                    items: [firstBook, secondBook],
                    total: 2,
                    page: 1,
                    limit: 1
                )
            )
        )
    }

    func testChangedRefreshPublishesCompleteLoadedPageSpan() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstBook = fixtureBook(
            id: "item-1",
            title: "First",
            libraryID: library.id
        )
        let refreshedFirstBook = fixtureBook(
            id: "item-1",
            title: "Refreshed First",
            libraryID: library.id
        )
        let secondBook = fixtureBook(
            id: "item-2",
            title: "Second",
            libraryID: library.id
        )
        let firstPage = LibraryItemsPage(
            items: [firstBook], total: 2, page: 0, limit: 1
        )
        let nextPage = LibraryItemsPage(
            items: [secondBook], total: 2, page: 1, limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(firstPage),
            nextPage: .success(nextPage)
        )
        let model = AppModel(service: service)
        await model.start()
        await model.loadNextBooksPage()
        await service.setFirstPage(
            .success(
                LibraryItemsPage(
                    items: [refreshedFirstBook],
                    total: 2,
                    page: 0,
                    limit: 1
                )
            )
        )

        await model.refreshSelectedLibrary()

        XCTAssertEqual(
            model.books,
            .loaded(
                LibraryItemsPage(
                    items: [refreshedFirstBook, secondBook],
                    total: 2,
                    page: 1,
                    limit: 1
                )
            )
        )
        let selections = await service.pageSelections()
        XCTAssertEqual(selections.suffix(2).map(\.page), [0, 1])
    }

    func testLibrarySortAndProgressFilterReloadFromFirstPage()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstBook = fixturePage(libraryID: library.id).items[0]
        let firstPage = LibraryItemsPage(
            items: [firstBook],
            total: 2,
            page: 0,
            limit: 1
        )
        let nextPage = LibraryItemsPage(
            items: [
                fixtureBook(
                    id: "item-2",
                    title: "Second",
                    libraryID: library.id
                )
            ],
            total: 2,
            page: 1,
            limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(firstPage),
            nextPage: .success(nextPage)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setLibrarySort(.addedAt)
        await model.setLibrarySortDescending(true)
        await model.setLibraryProgressFilter(.inProgress)
        await model.loadNextBooksPage()

        XCTAssertEqual(model.librarySort, .addedAt)
        XCTAssertTrue(model.librarySortDescending)
        XCTAssertEqual(model.libraryBrowseFilter, .progress(.inProgress))
        let selections = await service.pageSelections()
        XCTAssertEqual(
            selections,
            [
                PageSelection(
                    page: 0,
                    sort: .title,
                    descending: false,
                    filter: nil
                ),
                PageSelection(
                    page: 0,
                    sort: .addedAt,
                    descending: false,
                    filter: nil
                ),
                PageSelection(
                    page: 0,
                    sort: .addedAt,
                    descending: true,
                    filter: nil
                ),
                PageSelection(
                    page: 0,
                    sort: .addedAt,
                    descending: true,
                    filter: LibraryItemFilter(progress: .inProgress)
                ),
                PageSelection(
                    page: 1,
                    sort: .addedAt,
                    descending: true,
                    filter: LibraryItemFilter(progress: .inProgress)
                ),
            ]
        )
    }

    func testAuthorBrowsePreservesSortAndClearsForAnotherLibrary()
        async throws
    {
        let account = try fixtureAccount()
        let firstLibrary = fixtureLibrary()
        let secondLibrary = LibrarySummary(
            id: LibraryID(rawValue: "library-2"),
            name: "Second Library",
            mediaType: .book
        )
        let authorID = try XCTUnwrap(AuthorID(rawValue: "author-1"))
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([firstLibrary, secondLibrary]),
            firstPage: .success(fixturePage(libraryID: firstLibrary.id))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setLibrarySort(.updatedAt)
        await model.setLibrarySortDescending(true)
        await model.setLibraryBrowseFilter(
            .author(id: authorID, name: "First Author")
        )

        let selections = await service.pageSelections()
        XCTAssertEqual(
            selections.last,
            PageSelection(
                page: 0,
                sort: .updatedAt,
                descending: true,
                filter: LibraryItemFilter(authorID: authorID)
            )
        )

        await model.selectLibrary(secondLibrary)
        XCTAssertEqual(model.libraryBrowseFilter, .all)
    }

    func testRefreshingLibrariesPreservesAuthorBrowseFilter()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let authorID = try XCTUnwrap(AuthorID(rawValue: "author-1"))
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id))
        )
        let model = AppModel(service: service)
        await model.start()
        await model.setLibraryBrowseFilter(
            .author(id: authorID, name: "First Author")
        )

        await model.loadLibraries()

        XCTAssertEqual(model.selectedLibrary?.id, library.id)
        XCTAssertEqual(
            model.libraryBrowseFilter,
            .author(id: authorID, name: "First Author")
        )
        let selections = await service.pageSelections()
        XCTAssertEqual(
            selections.last?.filter,
            LibraryItemFilter(authorID: authorID)
        )
    }

    func testRefreshKeepsLoadedBooksAndShelvesUntilReplacementsArrive()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let initialPage = fixturePage(libraryID: library.id)
        let initialShelves = fixtureShelves(libraryID: library.id)
        let refreshedBook = fixtureBook(
            id: "refreshed-item",
            title: "Refreshed",
            libraryID: library.id
        )
        let refreshedPage = LibraryItemsPage(
            items: [refreshedBook], total: 1, page: 0, limit: 20
        )
        let refreshedShelves = [
            LibraryBookShelf(
                id: "continue-listening",
                label: "Continue Listening",
                labelLocalizationKey: nil,
                items: [refreshedBook],
                total: 1
            )
        ]
        let pageGate = AsyncGate()
        let homeGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(initialPage),
            homeShelves: .success(initialShelves),
            refreshPageGate: pageGate,
            homeShelvesRefreshGate: homeGate
        )
        let model = AppModel(service: service)
        await model.start()
        await service.setFirstPage(.success(refreshedPage))
        await service.setHomeShelves(.success(refreshedShelves))

        let refresh = Task { @MainActor in
            await model.refreshSelectedLibrary()
        }
        await pageGate.waitUntilEntered()

        XCTAssertEqual(model.books, .loaded(initialPage))
        XCTAssertEqual(model.homeShelves, .loaded(initialShelves))
        XCTAssertEqual(model.booksRefreshState, .idle)
        XCTAssertEqual(model.homeShelvesRefreshState, .idle)

        await pageGate.release()
        await homeGate.waitUntilEntered()
        XCTAssertEqual(model.books, .loaded(refreshedPage))
        XCTAssertEqual(model.homeShelves, .loaded(initialShelves))

        await homeGate.release()
        await refresh.value
        XCTAssertEqual(model.homeShelves, .loaded(refreshedShelves))
        XCTAssertEqual(model.booksRefreshState, .idle)
        XCTAssertEqual(model.homeShelvesRefreshState, .idle)
    }

    func testRefreshFailureRetainsLoadedBooksAndShelves() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let shelves = fixtureShelves(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            homeShelves: .success(shelves)
        )
        let model = AppModel(service: service)
        await model.start()
        let failure = AppServiceError.libraryRepository(
            .remote(.unexpectedStatus(503))
        )
        await service.setFirstPage(.failure(failure))
        await service.setHomeShelves(.failure(failure))

        await model.refreshSelectedLibrary()

        XCTAssertEqual(model.books, .loaded(page))
        XCTAssertEqual(model.homeShelves, .loaded(shelves))
        guard case .failed(let booksFailure) = model.booksRefreshState,
            case .failed(let homeFailure) = model.homeShelvesRefreshState
        else {
            return XCTFail("Expected typed refresh failures")
        }
        XCTAssertEqual(booksFailure.operation, .loadLibraryPage)
        XCTAssertEqual(homeFailure.operation, .loadHome)
    }

    func testOnlyPullToRefreshEmitsOneTypedLibraryRefreshSpan()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let shelves = fixtureShelves(libraryID: library.id)
        let tracer = RecordingRemoteTelemetryTracer()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            homeShelves: .success(shelves)
        )
        let model = AppModel(service: service, remoteTelemetryTracer: tracer)
        await model.start()
        let launchSpanCount = tracer.spans.count

        await model.refreshSelectedLibrary()
        XCTAssertEqual(tracer.spans.count, launchSpanCount)

        let failure = AppServiceError.libraryRepository(
            .remote(.unexpectedStatus(503))
        )
        await service.setFirstPage(.failure(failure))
        await service.setHomeShelves(.failure(failure))
        await model.refreshSelectedLibraryForPullToRefresh()

        XCTAssertEqual(
            Array(tracer.spans.dropFirst(launchSpanCount)),
            [
                RecordedRemoteTelemetrySpan(
                    operation: .libraryRefresh,
                    source: .remote,
                    retryBucket: .none,
                    outcome: .failed(.transport)
                )
            ]
        )
    }

    func testLibraryListPullToRefreshEmitsOneSuccessfulSpanForEmptyList()
        async throws
    {
        let account = try fixtureAccount()
        let tracer = RecordingRemoteTelemetryTracer()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([])
        )
        let model = AppModel(service: service, remoteTelemetryTracer: tracer)
        await model.start()
        let launchSpanCount = tracer.spans.count

        await model.refreshLibrariesForPullToRefresh()

        XCTAssertEqual(
            Array(tracer.spans.dropFirst(launchSpanCount)),
            [
                RecordedRemoteTelemetrySpan(
                    operation: .libraryRefresh,
                    source: .remote,
                    retryBucket: .none,
                    outcome: .succeeded
                )
            ]
        )
    }

    func testIdenticalRefreshDoesNotPublishObservableContent() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let shelves = fixtureShelves(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            homeShelves: .success(shelves)
        )
        let model = AppModel(service: service)
        await model.start()
        let browsingStateChanged = expectation(
            description: "Observable browsing state changed"
        )
        browsingStateChanged.isInverted = true
        withObservationTracking {
            _ = model.libraries
            _ = model.librariesRefreshState
            _ = model.selectedLibrary
            _ = model.isNavigationReady
            _ = model.books
            _ = model.booksRefreshState
            _ = model.libraryPaginationState
            _ = model.homeShelves
            _ = model.homeShelvesRefreshState
        } onChange: {
            browsingStateChanged.fulfill()
        }

        await model.refreshLibraries()

        await fulfillment(of: [browsingStateChanged], timeout: 0.1)
        XCTAssertEqual(model.libraries, .loaded([library]))
        XCTAssertEqual(model.books, .loaded(page))
        XCTAssertEqual(model.homeShelves, .loaded(shelves))
    }

    func testIdenticalEmptyLibraryRefreshDoesNotPublishObservableContent()
        async throws
    {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([])
        )
        let model = AppModel(service: service)
        await model.start()

        await model.refreshLibraries()
        let emptyPage = LibraryItemsPage(
            items: [], total: 0, page: 0, limit: 20
        )
        XCTAssertEqual(model.books, .loaded(emptyPage))
        XCTAssertEqual(model.homeShelves, .loaded([]))

        let browsingStateChanged = expectation(
            description: "Observable empty-library state changed"
        )
        browsingStateChanged.isInverted = true
        withObservationTracking {
            _ = model.libraries
            _ = model.librariesRefreshState
            _ = model.selectedLibrary
            _ = model.books
            _ = model.booksRefreshState
            _ = model.libraryPaginationState
            _ = model.homeShelves
            _ = model.homeShelvesRefreshState
        } onChange: {
            browsingStateChanged.fulfill()
        }

        await model.refreshLibraries()

        await fulfillment(of: [browsingStateChanged], timeout: 0.1)
        XCTAssertEqual(model.books, .loaded(emptyPage))
        XCTAssertEqual(model.homeShelves, .loaded([]))
    }

    func testLatestDeepLinkDoesNotNavigateAfterNewerLinkArrives()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(fixtureBookDetail(item: page.items[0])),
            bookDetailGate: gate
        )
        let model = AppModel(service: service)
        await model.start()
        let coordinator = AppNavigationCoordinator()
        let bookURL = try XCTUnwrap(
            URL(string: "bleat://book/item-1?library=library-1")
        )
        let settingsURL = try XCTUnwrap(
            URL(string: "bleat://settings/diagnostics")
        )

        coordinator.receive(url: bookURL)
        let firstApplication = Task { @MainActor in
            await coordinator.applyPendingRoute(model: model)
        }
        await gate.waitUntilEntered()

        coordinator.receive(url: settingsURL)
        await coordinator.applyPendingRoute(model: model)
        await gate.release()
        await firstApplication.value

        XCTAssertEqual(coordinator.selectedTab, .settings)
        XCTAssertNil(coordinator.pendingRoute)
    }

    func testSupersededAccountQualifiedDeepLinkRestoresBrowsingAccount()
        async throws
    {
        let first = try fixtureAccount()
        let second = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "other-reader"
        )
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let gate = AsyncGate()
        let service = TestAppService(
            accounts: .success([first, second]),
            activeAccount: .success(first),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(fixtureBookDetail(item: page.items[0])),
            bookDetailGate: gate
        )
        let model = AppModel(service: service)
        await model.start()
        let coordinator = AppNavigationCoordinator()
        let accountQualifiedBookURL = try XCTUnwrap(
            URL(
                string:
                    "bleat://book/item-1?account=account-2&library=library-1"
            )
        )
        let settingsURL = try XCTUnwrap(
            URL(string: "bleat://settings/diagnostics")
        )

        coordinator.receive(url: accountQualifiedBookURL)
        let firstApplication = Task { @MainActor in
            await coordinator.applyPendingRoute(model: model)
        }
        await gate.waitUntilEntered()
        XCTAssertEqual(model.account?.id, second.id)

        coordinator.receive(url: settingsURL)
        await coordinator.applyPendingRoute(model: model)
        await gate.release()
        await firstApplication.value

        XCTAssertEqual(model.account?.id, first.id)
        XCTAssertEqual(model.selectedLibrary?.id, library.id)
        XCTAssertEqual(model.libraryBrowseFilter, .all)
        XCTAssertEqual(coordinator.selectedTab, .settings)
        XCTAssertNil(coordinator.pendingRoute)
    }

    func testSupersededAuthorDeepLinkRestoresBrowseFilter() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let authorID = try XCTUnwrap(AuthorID(rawValue: "author-1"))
        let book = fixtureBook(
            id: "item-1",
            title: "A Book",
            libraryID: library.id,
            authors: [
                LibraryBookContributor(id: authorID, name: "An Author")
            ]
        )
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(
                LibraryItemsPage(items: [book], total: 1, page: 0, limit: 20)
            ),
            bookDetail: .success(
                fixtureBookDetail(item: book, authors: book.authors)
            ),
            browsePageGate: gate,
            browsePageGateFilter: LibraryItemFilter(authorID: authorID)
        )
        let model = AppModel(service: service)
        await model.start()
        let coordinator = AppNavigationCoordinator()
        let authorURL = try XCTUnwrap(
            URL(string: "bleat://author/author-1?library=library-1")
        )
        let settingsURL = try XCTUnwrap(
            URL(string: "bleat://settings/diagnostics")
        )

        coordinator.receive(url: authorURL)
        let firstApplication = Task { @MainActor in
            await coordinator.applyPendingRoute(model: model)
        }
        await gate.waitUntilEntered()
        XCTAssertEqual(
            model.libraryBrowseFilter,
            .author(id: authorID, name: "An Author")
        )

        coordinator.receive(url: settingsURL)
        await coordinator.applyPendingRoute(model: model)
        await gate.release()
        await firstApplication.value

        XCTAssertEqual(model.libraryBrowseFilter, .all)
        XCTAssertEqual(coordinator.selectedTab, .settings)
        XCTAssertNil(coordinator.pendingRoute)
    }

    func testSeriesPagesAlwaysUseServerSequenceWithoutCollapsing()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let first = fixtureBook(
            id: "series-item-1",
            title: "Volume One",
            libraryID: library.id
        )
        let second = fixtureBook(
            id: "series-item-2",
            title: "Volume Two",
            libraryID: library.id
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(
                LibraryItemsPage(
                    items: [first], total: 2, page: 0, limit: 1
                )
            ),
            nextPage: .success(
                LibraryItemsPage(
                    items: [second], total: 2, page: 1, limit: 1
                )
            )
        )
        let model = AppModel(service: service)
        await model.start()
        let seriesID = try XCTUnwrap(SeriesID(rawValue: "series-1"))
        let destination = SeriesDestination(
            libraryID: library.id,
            id: seriesID,
            name: "A Series"
        )

        await model.loadSeries(destination)
        await model.loadNextSeriesPage()

        let selections = await service.pageSelections()
        XCTAssertEqual(
            Array(selections.suffix(2)),
            [
                PageSelection(
                    page: 0,
                    sort: .sequence,
                    descending: false,
                    filter: LibraryItemFilter(seriesID: seriesID),
                    collapseSeries: false
                ),
                PageSelection(
                    page: 1,
                    sort: .sequence,
                    descending: false,
                    filter: LibraryItemFilter(seriesID: seriesID),
                    collapseSeries: false
                ),
            ]
        )
    }

    func testSeriesDownloadPreparationLoadsEveryPage() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let books = (1...3).map { index in
            fixtureBook(
                id: "series-item-\(index)",
                title: "Volume \(index)",
                libraryID: library.id
            )
        }
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            pagedProvider: { page in
                guard books.indices.contains(page) else {
                    return .failure(.libraryRepository(.noCachedValue))
                }
                return .success(
                    LibraryItemsPage(
                        items: [books[page]],
                        total: books.count,
                        page: page,
                        limit: 1
                    )
                )
            }
        )
        let model = AppModel(service: service)
        await model.start()
        let destination = SeriesDestination(
            libraryID: library.id,
            id: try XCTUnwrap(SeriesID(rawValue: "series-1")),
            name: "A Series"
        )
        await model.loadSeries(destination)
        guard case .loaded(let startingPage) = model.seriesBooks else {
            return XCTFail("Expected the first series page")
        }

        let result = await model.loadAllSeriesBooks(
            destination,
            account: account,
            startingAt: startingPage
        )

        XCTAssertEqual(result, .loaded(books))
        XCTAssertEqual(
            model.seriesBooks,
            .loaded(
                LibraryItemsPage(
                    items: books,
                    total: books.count,
                    page: 2,
                    limit: 1
                )
            )
        )
        let selections = await service.pageSelections()
        XCTAssertEqual(Array(selections.suffix(3)).map(\.page), [0, 1, 2])
    }

    func testSeriesDownloadPreparationStopsBeforeConfirmationWhenPagingFails()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let first = fixtureBook(
            id: "series-item-1",
            title: "Volume One",
            libraryID: library.id
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(
                LibraryItemsPage(
                    items: [first], total: 2, page: 0, limit: 1
                )
            ),
            nextPage: .failure(
                .libraryRepository(.remote(.unexpectedStatus(503)))
            )
        )
        let model = AppModel(service: service)
        await model.start()
        let destination = SeriesDestination(
            libraryID: library.id,
            id: try XCTUnwrap(SeriesID(rawValue: "series-1")),
            name: "A Series"
        )
        await model.loadSeries(destination)
        guard case .loaded(let startingPage) = model.seriesBooks else {
            return XCTFail("Expected the first series page")
        }

        let result = await model.loadAllSeriesBooks(
            destination,
            account: account,
            startingAt: startingPage
        )

        XCTAssertEqual(
            result,
            .failed(AppFailure(.loadLibraryPage, .serverUnavailable))
        )
        XCTAssertEqual(
            model.seriesBooks,
            .loaded(
                LibraryItemsPage(
                    items: [first], total: 2, page: 0, limit: 1
                )
            )
        )
    }

    func testSeriesPaginationCoalescesAnInFlightPageWithoutBlockingMainActor()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let seriesID = try XCTUnwrap(SeriesID(rawValue: "series-1"))
        let first = fixtureBook(
            id: "series-item-1",
            title: "Volume One",
            libraryID: library.id
        )
        let second = fixtureBook(
            id: "series-item-2",
            title: "Volume Two",
            libraryID: library.id
        )
        let pageGate = AsyncGate()
        let firstPage = LibraryItemsPage(
            items: [first], total: 2, page: 0, limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            asyncPageProvider: { _, request in
                guard request.page == 1 else { return .success(firstPage) }
                await pageGate.enterAndWait()
                return .success(
                    LibraryItemsPage(
                        items: [second], total: 2, page: 1, limit: 1
                    )
                )
            }
        )
        let model = AppModel(service: service)
        await model.start()
        let destination = SeriesDestination(
            libraryID: library.id,
            id: seriesID,
            name: "A Series"
        )
        await model.loadSeries(destination)

        let loadMore = Task { await model.loadNextSeriesPage() }
        await pageGate.waitUntilEntered()
        guard case .loaded(let startingPage) = model.seriesBooks else {
            return XCTFail("Expected the first series page")
        }
        let preparation = Task {
            await model.loadAllSeriesBooks(
                destination,
                account: account,
                startingAt: startingPage
            )
        }

        await Task.yield()
        let selectionsWhilePending = await service.pageSelections()
        XCTAssertEqual(
            selectionsWhilePending.filter { $0.page == 1 }.count,
            1
        )
        await pageGate.release()
        await loadMore.value
        let result = await preparation.value
        let finalSelections = await service.pageSelections()
        XCTAssertEqual(result, .loaded([first, second]))
        XCTAssertEqual(
            finalSelections.filter { $0.page == 1 }.count,
            1
        )
    }

    func testConcurrentSeriesPreparationsQueueGlobalConfirmationsByCompletion()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstSeriesID = try XCTUnwrap(SeriesID(rawValue: "series-1"))
        let secondSeriesID = try XCTUnwrap(SeriesID(rawValue: "series-2"))
        let firstGate = AsyncGate()
        let secondGate = AsyncGate()
        let firstBooks = [
            fixtureBook(
                id: "series-1-item-1",
                title: "First One",
                libraryID: library.id
            ),
            fixtureBook(
                id: "series-1-item-2",
                title: "First Two",
                libraryID: library.id
            ),
        ]
        let secondBooks = [
            fixtureBook(
                id: "series-2-item-1",
                title: "Second One",
                libraryID: library.id
            ),
            fixtureBook(
                id: "series-2-item-2",
                title: "Second Two",
                libraryID: library.id
            ),
        ]
        let firstFilter = LibraryItemFilter(seriesID: firstSeriesID)
        let secondFilter = LibraryItemFilter(seriesID: secondSeriesID)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            asyncPageProvider: { _, request in
                if request.filter == firstFilter {
                    if request.page == 0 {
                        return .success(
                            LibraryItemsPage(
                                items: [firstBooks[0]],
                                total: 2,
                                page: 0,
                                limit: 1
                            )
                        )
                    }
                    await firstGate.enterAndWait()
                    return .success(
                        LibraryItemsPage(
                            items: [firstBooks[1]], total: 2, page: 1, limit: 1
                        )
                    )
                }
                if request.filter == secondFilter {
                    if request.page == 0 {
                        return .success(
                            LibraryItemsPage(
                                items: [secondBooks[0]],
                                total: 2,
                                page: 0,
                                limit: 1
                            )
                        )
                    }
                    await secondGate.enterAndWait()
                    return .success(
                        LibraryItemsPage(
                            items: [secondBooks[1]], total: 2, page: 1, limit: 1
                        )
                    )
                }
                return .failure(.libraryRepository(.noCachedValue))
            }
        )
        let model = AppModel(service: service)
        await model.start()
        let firstDestination = SeriesDestination(
            libraryID: library.id,
            id: firstSeriesID,
            name: "First Series"
        )
        let secondDestination = SeriesDestination(
            libraryID: library.id,
            id: secondSeriesID,
            name: "Second Series"
        )

        await model.loadSeries(firstDestination)
        XCTAssertTrue(
            model.beginSeriesDownloadPreparation(
                firstDestination,
                account: account
            )
        )
        XCTAssertFalse(
            model.beginSeriesDownloadPreparation(
                firstDestination,
                account: account
            )
        )
        await model.loadSeries(secondDestination)
        XCTAssertTrue(
            model.beginSeriesDownloadPreparation(
                secondDestination,
                account: account
            )
        )
        await firstGate.waitUntilEntered()
        await secondGate.waitUntilEntered()

        await secondGate.release()
        let secondWasPresented = await waitUntil(timeout: .seconds(1)) {
            model.pendingSeriesDownload?.destination == secondDestination
        }
        XCTAssertTrue(secondWasPresented)
        await firstGate.release()
        await Task.yield()
        XCTAssertEqual(
            model.pendingSeriesDownload?.destination,
            secondDestination
        )

        model.cancelPendingSeriesDownload()
        let firstWasPresented = await waitUntil(timeout: .seconds(1)) {
            model.pendingSeriesDownload?.destination == firstDestination
        }
        XCTAssertTrue(firstWasPresented)
        model.cancelPendingSeriesDownload()
        XCTAssertNil(model.pendingSeriesDownload)
        XCTAssertFalse(
            model.beginSeriesDownloadPreparation(
                firstDestination,
                account: account
            )
        )
    }

    func testSeriesPreparationRejectsAResponseThatDoesNotAdvanceThePage()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let book = fixtureBook(
            id: "series-item-1",
            title: "Volume One",
            libraryID: library.id
        )
        let page = LibraryItemsPage(
            items: [book], total: 2, page: 0, limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            nextPage: .success(page)
        )
        let model = AppModel(service: service)
        await model.start()
        let destination = SeriesDestination(
            libraryID: library.id,
            id: try XCTUnwrap(SeriesID(rawValue: "series-1")),
            name: "A Series"
        )

        let result = await model.loadAllSeriesBooks(
            destination,
            account: account,
            startingAt: page
        )

        XCTAssertEqual(
            result,
            .failed(AppFailure(.loadLibraryPage, .invalidServerResponse))
        )
        let selections = await service.pageSelections()
        XCTAssertEqual(
            selections.filter {
                $0.filter == LibraryItemFilter(seriesID: destination.id)
            }.map(\.page),
            [1]
        )
    }

    func testConfirmedSeriesSerializeSharedBookHandoffPerAccount()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstSeriesID = try XCTUnwrap(SeriesID(rawValue: "series-1"))
        let secondSeriesID = try XCTUnwrap(SeriesID(rawValue: "series-2"))
        let sharedBook = fixtureBook(
            id: "shared-series-item",
            title: "Shared Volume",
            libraryID: library.id
        )
        let detail = fixtureBookDetail(item: sharedBook)
        let firstDetailGate = AsyncGate()
        let secondDetailGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            asyncPageProvider: { _, request in
                guard request.filter
                    == LibraryItemFilter(seriesID: firstSeriesID)
                        || request.filter
                            == LibraryItemFilter(seriesID: secondSeriesID)
                else {
                    return .failure(.libraryRepository(.noCachedValue))
                }
                return .success(
                    LibraryItemsPage(
                        items: [sharedBook], total: 1, page: 0, limit: 50
                    )
                )
            }
        )
        await service.queueBookDetails(
            [.success(detail), .success(detail)],
            gates: [firstDetailGate, secondDetailGate]
        )
        let model = AppModel(service: service)
        await model.start()
        let firstDestination = SeriesDestination(
            libraryID: library.id,
            id: firstSeriesID,
            name: "First Series"
        )
        let secondDestination = SeriesDestination(
            libraryID: library.id,
            id: secondSeriesID,
            name: "Second Series"
        )

        await model.loadSeries(firstDestination)
        XCTAssertTrue(
            model.beginSeriesDownloadPreparation(
                firstDestination,
                account: account
            )
        )
        let firstWasPresented = await waitUntil(timeout: .seconds(1)) {
            model.pendingSeriesDownload?.destination == firstDestination
        }
        XCTAssertTrue(firstWasPresented)
        model.confirmPendingSeriesDownload()
        await firstDetailGate.waitUntilEntered()

        await model.loadSeries(secondDestination)
        XCTAssertTrue(
            model.beginSeriesDownloadPreparation(
                secondDestination,
                account: account
            )
        )
        let secondWasPresented = await waitUntil(timeout: .seconds(1)) {
            model.pendingSeriesDownload?.destination == secondDestination
        }
        XCTAssertTrue(secondWasPresented)
        model.confirmPendingSeriesDownload()
        await Task.yield()
        let requestsBeforeRelease = await service.bookDetailRequests()
        XCTAssertEqual(requestsBeforeRelease.count, 1)

        await firstDetailGate.release()
        await secondDetailGate.waitUntilEntered()
        let requestsAfterRelease = await service.bookDetailRequests()
        XCTAssertEqual(requestsAfterRelease.count, 2)
        await secondDetailGate.release()
    }

    func testLocalResetRejectsSeriesWorkStartedAfterCancellationSnapshot()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let book = fixtureBook(
            id: "reset-series-item",
            title: "Reset Volume",
            libraryID: library.id
        )
        let resetGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(
                LibraryItemsPage(
                    items: [book], total: 1, page: 0, limit: 50
                )
            ),
            localDataResetGate: resetGate
        )
        let model = AppModel(service: service)
        await model.start()
        let destination = SeriesDestination(
            libraryID: library.id,
            id: try XCTUnwrap(SeriesID(rawValue: "reset-series")),
            name: "Reset Series"
        )
        await model.loadSeries(destination)

        let reset = Task { await model.resetLocalData() }
        await resetGate.waitUntilEntered()
        XCTAssertFalse(
            model.beginSeriesDownloadPreparation(
                destination,
                account: account
            )
        )
        XCTAssertNil(model.pendingSeriesDownload)
        await resetGate.release()
        await reset.value
    }

    func testDirectEntityResolutionUsesExpandedFilteredPage() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let authorID = try XCTUnwrap(AuthorID(rawValue: "author-1"))
        let seriesID = try XCTUnwrap(SeriesID(rawValue: "series-1"))
        let book = fixtureBook(
            id: "series-item-1",
            title: "Volume One",
            libraryID: library.id,
            authors: [
                LibraryBookContributor(id: authorID, name: "First Author")
            ],
            series: [
                LibraryBookSeries(
                    id: seriesID,
                    name: "A Series",
                    sequence: "1"
                )
            ]
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(
                LibraryItemsPage(items: [book], total: 1, page: 0, limit: 1)
            ),
            bookDetail: .success(
                fixtureBookDetail(item: book, authors: book.authors)
            )
        )
        let model = AppModel(service: service)
        await model.start()

        let author = await model.resolveAuthor(authorID, in: library.id)
        let series = await model.resolveSeries(seriesID, in: library.id)

        XCTAssertEqual(
            author,
            LibrarySearchAuthorMatch(
                id: authorID,
                name: "First Author"
            ))
        XCTAssertEqual(
            series,
            LibrarySearchSeriesMatch(
                id: seriesID,
                name: "A Series"
            ))
        let selections = await service.pageSelections()
        XCTAssertEqual(
            Array(selections.suffix(2)),
            [
                PageSelection(
                    page: 0,
                    sort: .addedAt,
                    descending: false,
                    filter: LibraryItemFilter(authorID: authorID),
                    collapseSeries: false
                ),
                PageSelection(
                    page: 0,
                    sort: .sequence,
                    descending: false,
                    filter: LibraryItemFilter(seriesID: seriesID),
                    collapseSeries: false
                ),
            ]
        )
    }

    func testLoadingNextLibraryPageFailureKeepsExistingBooks()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstPage = LibraryItemsPage(
            items: [
                fixtureBook(
                    id: "item-1",
                    title: "First",
                    libraryID: library.id
                )
            ],
            total: 2,
            page: 0,
            limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(firstPage),
            nextPage: .failure(
                .libraryRepository(.remote(.unexpectedStatus(503)))
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadNextBooksPage()

        XCTAssertEqual(model.books, .loaded(firstPage))
        XCTAssertEqual(
            model.libraryPaginationState,
            .failed(AppFailure(.loadLibraryPage, .serverUnavailable))
        )
    }

    func testLoadingWithoutAccountUsesTypedFailure() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.loadLibraries()
        XCTAssertEqual(
            model.libraries,
            .failed(AppFailure(.loadLibraries, .authenticationRequired))
        )

        await model.selectLibrary(fixtureLibrary())
        XCTAssertEqual(
            model.books,
            .failed(AppFailure(.loadLibraryPage, .authenticationRequired))
        )
        XCTAssertEqual(
            model.homeShelves,
            .failed(AppFailure(.loadHome, .authenticationRequired))
        )

        await model.removeAccount()
        XCTAssertEqual(
            model.accountActionStatus,
            .failed(AppFailure(.removeAccount, .authenticationRequired))
        )

        await model.search(query: "a book")
        XCTAssertEqual(
            model.searchResults,
            .failed(AppFailure(.search, .authenticationRequired))
        )

        let book = fixturePage(libraryID: fixtureLibrary().id).items[0]
        await model.loadBookDetail(book)
        XCTAssertEqual(model.selectedBookID, book.id)
        XCTAssertEqual(
            model.bookDetail,
            .failed(AppFailure(.loadBook, .authenticationRequired))
        )
    }

    func testSearchTrimsQueryAndPublishesResults() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let result = fixturePage(libraryID: library.id).items
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            search: .success(result)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.search(query: "  A Book  ")

        XCTAssertEqual(model.searchQuery, "  A Book  ")
        XCTAssertEqual(
            model.searchResults,
            .loaded(LibrarySearchResults(books: result))
        )
        let requests = await service.searchRequests()
        XCTAssertEqual(
            requests,
            [
                SearchRequest(
                    accountID: account.id,
                    libraryID: library.id,
                    query: "A Book"
                )
            ]
        )
    }

    func testBlankSearchClearsWithoutCallingService() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.search(query: "   ")

        XCTAssertEqual(model.searchResults, .idle)
        let requests = await service.searchRequests()
        XCTAssertEqual(requests, [])
    }

    func testSearchFailureRemainsTyped() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            search: .failure(
                .searchCoordinator(
                    .repository(.remote(.unexpectedStatus(503)))
                )
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.search(query: "a book")

        XCTAssertEqual(model.searchResults, .failed(.searchUnavailable))
    }

    func testSupersededSearchCannotPublishLateResult() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let oldResult = fixturePage(libraryID: library.id).items
        let newResult = [
            LibraryBookSummary(
                id: LibraryItemID(rawValue: "item-2"),
                libraryID: library.id,
                title: "New Result",
                subtitle: nil,
                authorName: nil,
                narratorName: nil,
                seriesName: nil,
                genres: [],
                publisher: nil,
                publishedYear: nil,
                duration: 1,
                trackCount: 1,
                chapterCount: 0,
                addedAtMilliseconds: 1,
                updatedAtMilliseconds: 1,
                isExplicit: false,
                isAbridged: false
            )
        ]
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            search: .success(oldResult),
            searchGate: gate
        )
        let model = AppModel(service: service)
        await model.start()

        let oldSearch = Task { @MainActor in
            await model.search(query: "old")
        }
        await gate.waitUntilEntered()
        await service.setSearch(.success(newResult))

        await model.search(query: "new")
        await gate.release()
        await oldSearch.value

        XCTAssertEqual(model.searchQuery, "new")
        XCTAssertEqual(
            model.searchResults,
            .loaded(LibrarySearchResults(books: newResult))
        )
    }

    func testChangingLibraryResetsSearchState() async throws {
        let account = try fixtureAccount()
        let firstLibrary = fixtureLibrary()
        let secondLibrary = LibrarySummary(
            id: LibraryID(rawValue: "library-2"),
            name: "Second Library",
            mediaType: .book
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([firstLibrary, secondLibrary]),
            firstPage: .success(fixturePage(libraryID: firstLibrary.id)),
            search: .success([])
        )
        let model = AppModel(service: service)
        await model.start()
        await model.search(query: "query")

        await service.setFirstPage(
            .success(fixturePage(libraryID: secondLibrary.id))
        )
        await model.selectLibrary(secondLibrary)

        XCTAssertEqual(model.searchQuery, "")
        XCTAssertEqual(model.searchResults, .idle)
    }

    func testBookDetailLoadsForExactAccountLibraryAndItem() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let bookmark = AudioBookmark(
            libraryItemID: detail.id,
            time: 600,
            title: "A useful moment",
            createdAtMilliseconds: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            bookmarks: .success([bookmark])
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadBookDetail(page.items[0])

        XCTAssertEqual(model.selectedBookID, detail.id)
        XCTAssertEqual(model.bookDetail, .loaded(detail))
        XCTAssertEqual(model.bookBookmarks, .loaded([bookmark]))
        let requests = await service.bookDetailRequests()
        XCTAssertEqual(
            requests,
            [
                BookDetailRequest(
                    accountID: account.id,
                    libraryID: library.id,
                    itemID: detail.id
                )
            ]
        )
        let bookmarkRequests = await service.bookmarkRequests()
        XCTAssertEqual(
            bookmarkRequests,
            [
                BookmarkRequest(
                    accountID: account.id,
                    itemID: detail.id
                )
            ]
        )
    }

    func testBookDetailBookmarkFailureDoesNotHideDetail() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            bookmarks: .failure(.bookmark(.requestFailed))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadBookDetail(page.items[0])

        XCTAssertEqual(model.bookDetail, .loaded(detail))
        XCTAssertEqual(
            model.bookBookmarks,
            .failed(AppFailure(.loadBookmarks, .uncertainMutation))
        )
    }

    func testBookDetailFailureRemainsTyped() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .failure(.bookDetail(.noCachedValue))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadBookDetail(page.items[0])

        XCTAssertEqual(
            model.bookDetail,
            .failed(.bookUnavailable(.unavailableOffline))
        )
    }

    func testBookDetailRetryReloadsTheExactBook() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let book = page.items[0]
        let detail = fixtureBookDetail(item: book)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .failure(
                .bookDetail(.remote(.unexpectedStatus(503)))
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadBookDetail(book)
        XCTAssertEqual(
            model.bookDetail,
            .failed(.bookUnavailable(.serverUnavailable))
        )

        await service.setBookDetail(.success(detail))
        await model.loadBookDetail(book)

        XCTAssertEqual(model.bookDetail, .loaded(detail))
        let requests = await service.bookDetailRequests()
        XCTAssertEqual(
            requests,
            [
                BookDetailRequest(
                    accountID: account.id,
                    libraryID: library.id,
                    itemID: book.id
                ),
                BookDetailRequest(
                    accountID: account.id,
                    libraryID: library.id,
                    itemID: book.id
                ),
            ]
        )
    }

    func testMetadataSaveForwardsDraftAndPublishesSuccess() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail)
        )
        let model = AppModel(service: service)
        await model.start()
        var draft = BookMetadataDraft(detail: detail)
        draft.title = "Updated title"

        await model.saveBookEdits(
            draft: draft,
            baseline: detail,
            coverJPEGData: nil
        )

        XCTAssertEqual(model.bookEditSaveState, .saved)
        XCTAssertEqual(model.bookDetail, .loaded(detail))
        let requests = await service.metadataSaveRequests()
        XCTAssertEqual(
            requests,
            [
                MetadataSaveRequest(
                    accountID: account.id,
                    baseline: detail,
                    draft: draft,
                    overwrite: false
                )
            ]
        )
    }

    func testBookEditSavesMetadataBeforeUploadingStagedCover() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            metadataSave: .success(.saved(detail)),
            coverReplacement: .success(detail)
        )
        let model = AppModel(service: service)
        await model.start()
        var draft = BookMetadataDraft(detail: detail)
        draft.title = "Updated title"

        await model.saveBookEdits(
            draft: draft,
            baseline: detail,
            coverJPEGData: jpegData
        )

        XCTAssertEqual(model.bookEditSaveState, .saved)
        let coverRequests = await service.coverReplacementRequests()
        XCTAssertEqual(
            coverRequests,
            [
                CoverReplacementRequest(
                    accountID: account.id,
                    detail: detail,
                    jpegData: jpegData
                )
            ]
        )
    }

    func testBookEditRetainsSavedMetadataWhenCoverUploadFails()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let jpegData = Data([1])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            metadataSave: .success(.saved(detail)),
            coverReplacement: .failure(
                .coverUpdate(.uploadRejected)
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.saveBookEdits(
            draft: BookMetadataDraft(detail: detail),
            baseline: detail,
            coverJPEGData: jpegData
        )

        XCTAssertEqual(
            model.bookEditSaveState,
            .metadataSavedCoverFailed(
                account.id,
                detail,
                coverJPEGData: jpegData,
                AppFailure(.replaceCover, .invalidInput)
            )
        )
        XCTAssertEqual(model.bookDetail, .loaded(detail))
        let coverRequests = await service.coverReplacementRequests()
        XCTAssertEqual(
            coverRequests,
            [
                CoverReplacementRequest(
                    accountID: account.id,
                    detail: detail,
                    jpegData: jpegData
                )
            ]
        )

        await service.setCoverReplacement(.success(detail))
        await model.retryBookCoverUpload()

        XCTAssertEqual(model.bookEditSaveState, .coverSaved(detail))
        XCTAssertEqual(model.bookDetail, .loaded(detail))
        let retryRequests = await service.coverReplacementRequests()
        XCTAssertEqual(retryRequests.count, 2)
        XCTAssertEqual(retryRequests[0], retryRequests[1])
        let metadataRequests = await service.metadataSaveRequests()
        XCTAssertEqual(metadataRequests.count, 1)
    }

    func testCoverRetryCannotPublishAfterAccountSwitch() async throws {
        let first = try fixtureAccount()
        let second = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "second",
            server: "https://second.example"
        )
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let gate = AsyncGate()
        let service = TestAppService(
            accounts: .success([first, second]),
            activeAccount: .success(first),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            metadataSave: .success(.saved(detail)),
            coverReplacement: .failure(.coverUpdate(.uploadRejected))
        )
        let model = AppModel(service: service)
        await model.start()
        await model.saveBookEdits(
            draft: BookMetadataDraft(detail: detail),
            baseline: detail,
            coverJPEGData: Data([1])
        )
        await service.setCoverReplacement(.success(detail))
        await service.setCoverReplacementGate(gate)

        let retry = Task { await model.retryBookCoverUpload() }
        await gate.waitUntilEntered()
        await model.switchAccount(to: second)
        await gate.release()
        await retry.value

        XCTAssertEqual(model.account, second)
        XCTAssertEqual(model.bookDetail, .idle)
        XCTAssertEqual(model.bookEditSaveState, .idle)
    }

    func testBookDeletionForwardsModeAndRefreshesLibrary()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            bookDeletion: .success(
                .deletedWithCacheCleanupFailure
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.deleteBook(
            detail,
            mode: .libraryRecordAndFiles
        )

        let deletionRequests = await service.bookDeletionRequests()
        XCTAssertEqual(
            deletionRequests,
            [
                BookDeletionRequest(
                    accountID: account.id,
                    detail: detail,
                    mode: .libraryRecordAndFiles
                )
            ]
        )
        XCTAssertEqual(
            model.bookDeletionState,
            .deleted(
                BookDeletionCleanupStatus(
                    cacheCleanupFailed: true,
                    localDownloadCleanupFailed: false
                )
            )
        )
        let pageRequestCount = await service.pageRequests().count
        XCTAssertEqual(pageRequestCount, 2)
    }

    func testBookDeletionStopsFailedPreparedPlaybackAndClosesSession()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            bookDeletion: .success(.deleted),
            playback: [
                .success(
                    playbackPreparation(
                        detail: detail,
                        audioURL: fixture.audioURL,
                        sessionID: "failed-session"
                    )
                )
            ]
        )
        let model = AppModel(service: service)
        await model.start()

        let outcome = await model.startPlayback(
            detail: detail,
            account: account
        )
        XCTAssertEqual(outcome, .started(source: .streamed))
        model.playback.fail(.mediaUnavailable)
        XCTAssertTrue(model.playback.hasActiveBook)
        XCTAssertFalse(model.playback.showsMiniPlayer)

        await model.deleteBook(detail, mode: .libraryRecordOnly)

        let closedSessions = await service.playbackCloseSessionIDs()
        XCTAssertEqual(model.playback.state, .idle)
        XCTAssertFalse(model.playback.hasActiveBook)
        XCTAssertEqual(
            closedSessions,
            [PlaybackSessionID(rawValue: "failed-session")]
        )
    }

    func testSetFinishedCommitsProgressAfterCanonicalPreparation() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setFinished(true, detail: detail)

        XCTAssertEqual(model.bookProgressUpdateState, .saved)
        XCTAssertEqual(model.bookDetail, .idle)
        XCTAssertTrue(model.isBookFinished(detail.id))
        let updates = await service.progressUpdateRequests()
        XCTAssertEqual(
            updates,
            [
                ProgressUpdateRequest(
                    accountID: account.id,
                    itemID: detail.id,
                    update: BookProgressUpdate(isFinished: true)
                )
            ]
        )
        let detailRequests = await service.bookDetailRequests()
        XCTAssertEqual(
            detailRequests,
            [
                BookDetailRequest(
                    accountID: account.id,
                    libraryID: library.id,
                    itemID: detail.id
                )
            ]
        )
    }

    func testSetFinishedSynchronizesOnlyMatchingSelectedDetail() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let selectedDetail = fixtureBookDetail(item: item)
        let otherItem = fixtureBook(
            id: "item-2",
            title: "Other Book",
            libraryID: library.id
        )
        let otherDetail = fixtureBookDetail(item: otherItem)
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(selectedDetail)
        )
        let model = AppModel(service: service)
        await model.start()
        await model.loadBookDetail(item)
        await service.setBookDetail(.success(otherDetail))

        await model.setFinished(true, detail: otherDetail)

        XCTAssertEqual(model.bookDetail, .loaded(selectedDetail))
        XCTAssertTrue(model.isBookFinished(otherDetail.id))
    }

    func testBookActionPreparationReusesDetailFetchWithoutChangingSelection()
        async throws
    {
        let account = try fixtureAccount()
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail)
        )
        let model = AppModel(service: service)
        await model.start()

        let prepared = await model.prepareBookAction(for: item)
        XCTAssertEqual(prepared, .loaded(detail))
        XCTAssertEqual(model.bookDetail, .idle)
        await service.setBookDetail(
            .failure(
                .bookDetail(
                    .remote(
                        .authentication(.requestTransportFailed)
                    )
                )
            )
        )
        let failure = await model.prepareBookAction(for: item)
        XCTAssertEqual(
            failure,
            .failed(AppFailure(.loadBook, .serverUnavailable))
        )
        if case .failed(let appFailure) = failure {
            XCTAssertTrue(appFailure.allowsRetry)
        } else {
            XCTFail("Expected typed preparation failure")
        }
        XCTAssertEqual(model.bookDetail, .idle)
    }

    func testSetFinishedFailureDoesNotRefetchDetail() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail),
            progressUpdate: .failure(.progress(.unexpectedStatus(503)))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setFinished(false, detail: detail)

        XCTAssertEqual(
            model.bookProgressUpdateState,
            .failed(AppFailure(.updateProgress, .serverUnavailable))
        )
        let detailRequests = await service.bookDetailRequests()
        XCTAssertEqual(detailRequests.count, 1)
        XCTAssertFalse(model.isBookFinished(detail.id))
    }

    func testSetFinishedLeavesLocalStateUnchangedUntilPatchConfirms()
        async throws
    {
        let account = try fixtureAccount()
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let patchGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail),
            progressUpdateGate: patchGate
        )
        let model = AppModel(service: service)
        await model.start()

        let mutation = Task {
            await model.setFinished(true, detail: detail)
        }
        await patchGate.waitUntilEntered()

        XCTAssertFalse(model.isBookFinished(detail.id))
        XCTAssertTrue(model.isBookProgressMutationPending(detail.id))
        await patchGate.release()
        await mutation.value
        XCTAssertTrue(model.isBookFinished(detail.id))
    }

    func testSetFinishedSuppressesRepeatedMutationForSameItem()
        async throws
    {
        let account = try fixtureAccount()
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let patchGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail),
            progressUpdateGate: patchGate
        )
        let model = AppModel(service: service)
        await model.start()

        let first = Task { await model.setFinished(true, detail: detail) }
        await patchGate.waitUntilEntered()
        await model.setFinished(false, detail: detail)

        let repeatedRequests = await service.progressUpdateRequests()
        XCTAssertEqual(repeatedRequests.count, 1)
        await patchGate.release()
        await first.value
        XCTAssertTrue(model.isBookFinished(detail.id))
    }

    func testSetFinishedAllowsDifferentItemsToMutateConcurrently()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstItem = fixtureBook(
            id: "item-1", title: "First", libraryID: library.id
        )
        let secondItem = fixtureBook(
            id: "item-2", title: "Second", libraryID: library.id
        )
        let firstDetail = fixtureBookDetail(item: firstItem)
        let secondDetail = fixtureBookDetail(item: secondItem)
        let patchGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(firstDetail),
            progressUpdateGate: patchGate
        )
        let model = AppModel(service: service)
        await model.start()

        let first = Task {
            await model.setFinished(
                true, book: firstItem, expectedAccount: account
            )
        }
        await patchGate.waitUntilEntered()
        await service.setBookDetail(.success(secondDetail))
        let second = Task {
            await model.setFinished(
                true, book: secondItem, expectedAccount: account
            )
        }
        let secondBecamePending = await waitUntil(timeout: .seconds(1)) {
            model.isBookProgressMutationPending(secondItem.id)
        }
        XCTAssertTrue(secondBecamePending)
        let concurrentRequests = await service.progressUpdateRequests()
        XCTAssertEqual(concurrentRequests.count, 2)

        await patchGate.release()
        await first.value
        await second.value
        XCTAssertTrue(model.isBookFinished(firstItem.id))
        XCTAssertTrue(model.isBookFinished(secondItem.id))
    }

    func testSetFinishedFailureKindsPreserveTypedMutationOutcome()
        async throws
    {
        let account = try fixtureAccount()
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail),
            progressUpdate: .failure(.progress(.unexpectedStatus(403)))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setFinished(true, detail: detail)
        XCTAssertEqual(
            model.bookProgressFailure,
            AppFailure(.updateProgress, .permissionDenied)
        )
        XCTAssertFalse(model.isBookFinished(detail.id))
        model.dismissBookProgressFailure()

        await service.setProgressUpdate(
            .failure(.progress(.requestFailed))
        )
        await model.setFinished(true, detail: detail)
        XCTAssertEqual(
            model.bookProgressFailure,
            AppFailure(.updateProgress, .uncertainMutation)
        )
        XCTAssertFalse(model.isBookFinished(detail.id))
    }

    func testSetFinishedQueuesFailuresForDifferentBooks() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstItem = fixtureBook(
            id: "item-1", title: "First", libraryID: library.id
        )
        let secondItem = fixtureBook(
            id: "item-2", title: "Second", libraryID: library.id
        )
        let firstDetail = fixtureBookDetail(item: firstItem)
        let secondDetail = fixtureBookDetail(item: secondItem)
        let failure = AppFailure(.updateProgress, .permissionDenied)
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(firstDetail),
            progressUpdate: .failure(.progress(.unexpectedStatus(403)))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setFinished(true, detail: firstDetail)
        await service.setBookDetail(.success(secondDetail))
        await model.setFinished(true, detail: secondDetail)

        XCTAssertEqual(
            model.bookProgressFailures,
            [
                BookProgressFailureEntry(
                    itemID: firstItem.id,
                    failure: failure
                ),
                BookProgressFailureEntry(
                    itemID: secondItem.id,
                    failure: failure
                ),
            ]
        )
        XCTAssertEqual(model.bookProgressFailure, failure)

        model.dismissBookProgressFailure()
        XCTAssertEqual(model.bookProgressFailures.map(\.itemID), [secondItem.id])
        XCTAssertNil(model.bookProgressFailure)

        let secondWasPresented = await waitUntil(timeout: .seconds(1)) {
            model.presentedBookProgressFailure?.itemID == secondItem.id
        }
        XCTAssertTrue(secondWasPresented)
        XCTAssertEqual(model.bookProgressFailure, failure)

        model.dismissBookProgressFailure()
        XCTAssertTrue(model.bookProgressFailures.isEmpty)
        XCTAssertNil(model.bookProgressFailure)
        XCTAssertEqual(model.bookProgressUpdateState, .idle)
    }

    func testSetFinishedDeadlineDistinguishesPreparationFromSubmittedPatch()
        async throws
    {
        let account = try fixtureAccount()
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)

        let preparationGate = AsyncGate()
        let preparationDeadline = AsyncGate()
        let preparationService = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail),
            bookDetailGate: preparationGate
        )
        let preparationModel = AppModel(
            service: preparationService,
            bookProgressOperationTimeout: .seconds(30),
            bookProgressSleep: { _ in
                await preparationDeadline.enterAndWait()
            }
        )
        await preparationModel.start()
        let preparing = Task {
            await preparationModel.setFinished(true, detail: detail)
        }
        await preparationGate.waitUntilEntered()
        await preparationDeadline.release()
        await preparing.value
        XCTAssertEqual(
            preparationModel.bookProgressFailure,
            AppFailure(.updateProgress, .timeout)
        )
        await preparationGate.release()

        let patchGate = AsyncGate()
        let patchDeadline = AsyncGate()
        let patchService = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail),
            progressUpdateGate: patchGate
        )
        let patchModel = AppModel(
            service: patchService,
            bookProgressOperationTimeout: .seconds(30),
            bookProgressSleep: { _ in
                await patchDeadline.enterAndWait()
            }
        )
        await patchModel.start()
        let submitted = Task {
            await patchModel.setFinished(true, detail: detail)
        }
        await patchGate.waitUntilEntered()
        await patchDeadline.release()
        await submitted.value
        XCTAssertEqual(
            patchModel.bookProgressFailure,
            AppFailure(.updateProgress, .uncertainMutation)
        )
        XCTAssertFalse(patchModel.isBookFinished(detail.id))
        await patchGate.release()
    }

    func testSetFinishedAccountSwitchSuppressesStalePublication()
        async throws
    {
        let first = try fixtureAccount()
        let second = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "second",
            server: "https://second.example"
        )
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let patchGate = AsyncGate()
        let service = TestAppService(
            accounts: .success([first, second]),
            activeAccount: .success(first),
            bookDetail: .success(detail),
            progressUpdateGate: patchGate
        )
        let model = AppModel(service: service)
        await model.start()
        let mutation = Task {
            await model.setFinished(true, detail: detail)
        }
        await patchGate.waitUntilEntered()

        await model.switchAccount(to: second)
        await patchGate.release()
        await mutation.value

        XCTAssertEqual(model.account?.id, second.id)
        XCTAssertFalse(model.isBookFinished(detail.id))
        XCTAssertNil(model.bookProgressFailure)
    }

    func testSetFinishedStaleActionCannotPublishAfterAccountRoundTrip()
        async throws
    {
        let first = try fixtureAccount()
        let second = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "second",
            server: "https://second.example"
        )
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let service = TestAppService(
            accounts: .success([first, second]),
            activeAccount: .success(first),
            bookDetail: .success(detail),
            progressUpdate: .failure(.progress(.unexpectedStatus(403)))
        )
        let model = AppModel(service: service)
        await model.start()
        let staleGeneration = model.bookProgressActionGeneration

        await model.setFinished(true, detail: detail)
        XCTAssertNotNil(model.bookProgressFailure)
        await model.switchAccount(to: second)
        XCTAssertNil(model.bookProgressFailure)
        await model.switchAccount(to: first)

        let requestCount = await service.progressUpdateRequests().count
        await model.setFinished(
            true,
            book: item,
            expectedAccount: first,
            expectedContextGeneration: staleGeneration
        )

        let finalRequestCount = await service.progressUpdateRequests().count
        XCTAssertNil(model.bookProgressFailure)
        XCTAssertEqual(finalRequestCount, requestCount)
    }

    func testSetFinishedNewerCommitRejectsOlderDetailReconciliation()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let finishedDetail = detail.replacingProgress(
            with: fixtureProgress(
                userID: account.user.id,
                itemID: item.id,
                isFinished: true
            )
        )
        let initialGate = AsyncGate()
        let firstPreparationGate = AsyncGate()
        let oldReconciliationGate = AsyncGate()
        let secondPreparationGate = AsyncGate()
        let newReconciliationGate = AsyncGate()
        await initialGate.release()
        await firstPreparationGate.release()
        await secondPreparationGate.release()
        await newReconciliationGate.release()
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail)
        )
        await service.queueBookDetails(
            [
                .success(detail),
                .success(detail),
                .success(finishedDetail),
                .success(finishedDetail),
                .success(detail),
            ],
            gates: [
                initialGate,
                firstPreparationGate,
                oldReconciliationGate,
                secondPreparationGate,
                newReconciliationGate,
            ]
        )
        let model = AppModel(service: service)
        await model.start()
        await model.loadBookDetail(item)

        await model.setFinished(true, detail: detail)
        await oldReconciliationGate.waitUntilEntered()
        await model.setFinished(false, detail: finishedDetail)
        await oldReconciliationGate.release()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(model.isBookFinished(item.id))
        guard case .loaded(let reconciled) = model.bookDetail else {
            return XCTFail("Expected loaded detail")
        }
        XCTAssertFalse(reconciled.progress?.isFinished ?? false)
    }

    func testSetFinishedReconciliationDoesNotRestoreObsoleteSearch()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let homeRefreshGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            homeShelves: .success(fixtureShelves(libraryID: library.id)),
            search: .success([item]),
            bookDetail: .success(detail),
            homeShelvesRefreshGate: homeRefreshGate
        )
        let model = AppModel(service: service)
        await model.start()
        await model.search(query: "Old")

        await model.setFinished(true, detail: detail)
        await homeRefreshGate.waitUntilEntered()
        await model.search(query: "New")
        await homeRefreshGate.release()
        try? await Task.sleep(for: .milliseconds(100))

        let searchQueries = await service.searchRequests().map(\.query)
        XCTAssertEqual(model.searchQuery, "New")
        XCTAssertEqual(searchQueries, ["Old", "New"])
    }

    func testCompletedReconciliationDoesNotCancelLaterUserSearch()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let searchGate = AsyncGate()
        let detailGates = (0..<5).map { _ in AsyncGate() }
        for gate in detailGates.dropLast() {
            await gate.release()
        }
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            homeShelves: .success(fixtureShelves(libraryID: library.id)),
            search: .success([item]),
            bookDetail: .success(detail),
            searchGate: searchGate
        )
        await service.queueBookDetails(
            Array(repeating: .success(detail), count: 5),
            gates: detailGates
        )
        let model = AppModel(service: service)
        await model.start()
        await model.loadBookDetail(item)
        await model.setFinished(true, detail: detail)
        var firstReconciliationFinished = false
        for _ in 0..<50 {
            if await service.bookDetailRequests().count >= 3 {
                firstReconciliationFinished = true
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(firstReconciliationFinished)
        try? await Task.sleep(for: .milliseconds(20))

        let userSearch = Task { await model.search(query: "User") }
        await searchGate.waitUntilEntered()
        await model.setFinished(false, detail: detail)
        await detailGates[4].waitUntilEntered()
        await searchGate.release()
        await userSearch.value

        XCTAssertEqual(model.searchQuery, "User")
        guard case .loaded = model.searchResults else {
            await detailGates[4].release()
            return XCTFail("Expected the user search to finish")
        }
        await detailGates[4].release()
    }

    func testCancelledReconciliationSearchPreservesLoadedResults()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let initialSearchGate = AsyncGate()
        let reconciliationSearchGate = AsyncGate()
        await initialSearchGate.release()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            homeShelves: .success(fixtureShelves(libraryID: library.id)),
            search: .success([item]),
            bookDetail: .success(detail)
        )
        await service.queueSearches(
            [.success([item]), .success([item])],
            gates: [initialSearchGate, reconciliationSearchGate]
        )
        let model = AppModel(service: service)
        await model.start()
        await model.search(query: "User")
        guard case .loaded(let initialResults) = model.searchResults else {
            return XCTFail("Expected initial search results")
        }

        await model.setFinished(true, detail: detail)
        await reconciliationSearchGate.waitUntilEntered()
        await service.setProgressUpdate(
            .failure(.progress(.unexpectedStatus(403)))
        )
        await model.setFinished(false, detail: detail)
        await reconciliationSearchGate.release()
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(model.searchQuery, "User")
        XCTAssertEqual(model.searchResults, .loaded(initialResults))
        XCTAssertEqual(
            model.bookProgressFailure,
            AppFailure(.updateProgress, .permissionDenied)
        )
    }

    func testBookDetailFinishedStateFallsBackToCanonicalProgress()
        async throws
    {
        let account = try fixtureAccount()
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let finishedDetail = detail.replacingProgress(
            with: fixtureProgress(
                userID: account.user.id,
                itemID: item.id,
                isFinished: true
            )
        )
        let model = AppModel(
            service: TestAppService(
                activeAccount: .success(account),
                allBookProgress: [
                    .failure(.progress(.unexpectedStatus(503)))
                ]
            )
        )
        await model.start()

        XCTAssertTrue(
            model.isBookFinished(
                item.id,
                fallback: finishedDetail.progress?.isFinished ?? false
            )
        )
    }

    func testSetFinishedUpdatesContinueListeningOnlyForPlayedBooks()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let refreshGate = AsyncGate()
        let shelves = [
            LibraryBookShelf(
                id: "continue-listening",
                label: "Continue Listening",
                labelLocalizationKey: nil,
                items: [item],
                total: 3
            ),
            LibraryBookShelf(
                id: "recent",
                label: "Recent",
                labelLocalizationKey: nil,
                items: [item],
                total: 1
            ),
        ]
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            homeShelves: .success(shelves),
            bookDetail: .success(detail),
            homeShelvesRefreshGate: refreshGate
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setFinished(true, detail: detail)
        guard case .loaded(let playedShelves) = model.homeShelves else {
            return XCTFail("Expected loaded shelves")
        }
        XCTAssertEqual(playedShelves[0].items, [])
        XCTAssertEqual(playedShelves[0].total, 2)
        XCTAssertEqual(playedShelves[1].items, [item])

        await model.setFinished(false, detail: detail)
        guard case .loaded(let unplayedShelves) = model.homeShelves else {
            return XCTFail("Expected loaded shelves")
        }
        XCTAssertEqual(unplayedShelves[0].items, [])
        XCTAssertEqual(unplayedShelves[0].total, 2)
        await refreshGate.release()
    }

    func testSetFinishedReconciliationFailureDoesNotReverseCommitOrAlert()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let refreshGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            homeShelves: .success(fixtureShelves(libraryID: library.id)),
            bookDetail: .success(detail),
            homeShelvesRefreshGate: refreshGate
        )
        let model = AppModel(service: service)
        await model.start()
        await service.setFirstPage(
            .failure(.libraryRepository(.remote(.unexpectedStatus(503))))
        )
        await service.setHomeShelves(
            .failure(.libraryRepository(.remote(.unexpectedStatus(503))))
        )

        await model.setFinished(true, detail: detail)
        XCTAssertTrue(model.isBookFinished(detail.id))
        XCTAssertNil(model.bookProgressFailure)
        await refreshGate.release()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(model.isBookFinished(detail.id))
        XCTAssertNil(model.bookProgressFailure)
    }

    func testSetFinishedUsesRemoteOnlyDetailReconciliation() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            homeShelves: .success(fixtureShelves(libraryID: library.id)),
            bookDetail: .success(detail)
        )
        let diagnostics = AppDiagnosticRecorderSpy()
        let model = AppModel(service: service, diagnostics: diagnostics)
        await model.start()
        await model.loadBookDetail(item)
        await service.setRefreshedBookDetail(
            .failure(.bookDetail(.remote(.unexpectedStatus(503))))
        )

        await model.setFinished(true, detail: detail)

        var events = await diagnostics.events()
        for _ in 0..<100
        where !events.contains(where: {
            $0.name == .operationFailed && $0.operation == .loadBook
        }) {
            try? await Task.sleep(for: .milliseconds(10))
            events = await diagnostics.events()
        }
        let refreshRequestCount =
            await service.refreshedBookDetailRequests().count
        XCTAssertEqual(refreshRequestCount, 1)
        XCTAssertTrue(model.isBookFinished(detail.id))
        guard case .loaded(let committedDetail) = model.bookDetail else {
            return XCTFail("Expected confirmed detail to remain loaded")
        }
        XCTAssertTrue(committedDetail.progress?.isFinished ?? false)
        XCTAssertNil(model.bookProgressFailure)
        XCTAssertTrue(
            events.contains {
                $0.name == .operationFailed
                    && $0.operation == .loadBook
                    && $0.failureCode == .bookUnavailable
            }
        )
    }

    func testBookProgressReconciliationPreservesConfirmedProgressWhenRefreshOmitsIt()
        throws
    {
        let account = try fixtureAccount()
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let confirmed = fixtureProgress(
            userID: account.user.id,
            itemID: item.id,
            isFinished: true,
            lastUpdateMilliseconds: 20
        )

        let reconciled = AppModel.reconciledBookDetail(
            detail.replacingProgress(with: nil),
            preserving: confirmed,
            newerThan: 10
        )

        XCTAssertEqual(reconciled.progress, confirmed)
    }

    func testBookProgressReconciliationRejectsNonAdvancingProgressAndAcceptsNewerServerProgress()
        throws
    {
        let account = try fixtureAccount()
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let confirmed = fixtureProgress(
            userID: account.user.id,
            itemID: item.id,
            isFinished: true,
            lastUpdateMilliseconds: 2_000
        )
        let stale = fixtureProgress(
            userID: account.user.id,
            itemID: item.id,
            isFinished: false,
            lastUpdateMilliseconds: 10
        )
        let equal = fixtureProgress(
            userID: account.user.id,
            itemID: item.id,
            isFinished: false,
            lastUpdateMilliseconds: 20
        )
        let newer = fixtureProgress(
            userID: account.user.id,
            itemID: item.id,
            isFinished: false,
            lastUpdateMilliseconds: 30
        )

        let staleReconciliation = AppModel.reconciledBookDetail(
            detail.replacingProgress(with: stale),
            preserving: confirmed,
            newerThan: 20
        )
        let equalReconciliation = AppModel.reconciledBookDetail(
            detail.replacingProgress(with: equal),
            preserving: confirmed,
            newerThan: 20
        )
        let newerReconciliation = AppModel.reconciledBookDetail(
            detail.replacingProgress(with: newer),
            preserving: confirmed,
            newerThan: 20
        )

        XCTAssertEqual(staleReconciliation.progress, confirmed)
        XCTAssertEqual(equalReconciliation.progress, confirmed)
        XCTAssertEqual(newerReconciliation.progress, newer)
    }

    func testBookProgressReconciliationRejectsOlderSameStateProgress()
        throws
    {
        let account = try fixtureAccount()
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: item)
        let confirmed = fixtureProgress(
            userID: account.user.id,
            itemID: item.id,
            isFinished: false,
            lastUpdateMilliseconds: 2_000
        )
        let olderSameState = fixtureProgress(
            userID: account.user.id,
            itemID: item.id,
            isFinished: false,
            lastUpdateMilliseconds: 10
        )

        let reconciled = AppModel.reconciledBookDetail(
            detail.replacingProgress(with: olderSameState),
            preserving: confirmed,
            newerThan: 20
        )

        XCTAssertEqual(reconciled.progress, confirmed)
    }

    func testSetFinishedReconciliationFailuresRecordTypedDiagnostics()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            homeShelves: .success(fixtureShelves(libraryID: library.id)),
            search: .success([item]),
            bookDetail: .success(detail)
        )
        await service.queueBookDetails(
            [
                .success(detail),
                .success(detail),
                .failure(.bookDetail(.remote(.unexpectedStatus(503)))),
            ],
            gates: []
        )
        let diagnostics = AppDiagnosticRecorderSpy()
        let model = AppModel(service: service, diagnostics: diagnostics)
        await model.start()
        await model.loadBookDetail(item)
        await model.search(query: "Test")
        await service.setSearch(
            .failure(
                .searchCoordinator(
                    .repository(.remote(.unexpectedStatus(503)))
                )
            )
        )

        await model.setFinished(true, detail: detail)

        var events = await diagnostics.events()
        for _ in 0..<100
        where !events.contains(where: {
            $0.name == .operationFailed && $0.operation == .search
        }) {
            try? await Task.sleep(for: .milliseconds(10))
            events = await diagnostics.events()
        }
        XCTAssertTrue(
            events.contains {
                $0.name == .operationFailed
                    && $0.operation == .loadBook
                    && $0.failureCode == .bookUnavailable
            }
        )
        XCTAssertTrue(
            events.contains {
                $0.name == .operationFailed
                    && $0.operation == .search
                    && $0.failureCode == .serverUnavailable
            }
        )
        XCTAssertTrue(model.isBookFinished(detail.id))
        XCTAssertNil(model.bookProgressFailure)
        guard case .loaded(let committedDetail) = model.bookDetail else {
            return XCTFail("Expected confirmed detail to remain loaded")
        }
        XCTAssertTrue(committedDetail.progress?.isFinished ?? false)
        guard case .loaded = model.searchResults else {
            return XCTFail("Expected prior Search results to remain loaded")
        }
    }

    func testPlaybackStartRequestsAutomaticServerPreference() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let account = try fixtureAccount()
        let preparation = AppPlaybackPreparation(
            sessionID: PlaybackSessionID(rawValue: "session"),
            itemID: fixture.detail.id,
            title: fixture.detail.title,
            duration: 1,
            currentTime: 0,
            chapters: fixture.detail.chapters,
            source: .direct([
                AppPlaybackTrack(
                    url: fixture.audioURL,
                    startOffset: 0,
                    duration: 1,
                    title: "Track 1"
                )
            ])
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [.success(preparation)]
        )
        let playback = fixture.model(
            activation: TestAudioSessionActivation(),
            service: service
        )

        await playback.start(detail: fixture.detail, account: account)

        let requests = await service.playbackOpenRequests()
        XCTAssertEqual(
            requests,
            [
                PlaybackOpenRequest(
                    accountID: account.id,
                    itemID: fixture.detail.id,
                    preference: .automatic
                )
            ]
        )
        await playback.stop()
    }

    func testPlaybackStartUsesExplicitWholeBookPosition() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let account = try fixtureAccount()
        let preparation = AppPlaybackPreparation(
            sessionID: PlaybackSessionID(rawValue: "session"),
            itemID: fixture.detail.id,
            title: fixture.detail.title,
            duration: 1,
            currentTime: 0.1,
            chapters: fixture.detail.chapters,
            source: .direct([
                AppPlaybackTrack(
                    url: fixture.audioURL,
                    startOffset: 0,
                    duration: 1,
                    title: "Track 1"
                )
            ])
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [.success(preparation)]
        )
        let playback = fixture.model(
            activation: TestAudioSessionActivation(),
            service: service
        )

        await playback.start(
            detail: fixture.detail,
            account: account,
            initialTime: 0.75
        )

        XCTAssertEqual(playback.currentTime, 0.75, accuracy: 0.01)
        await playback.stop()
    }

    func testDownloadedPlaybackUsesExplicitWholeBookPosition()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let playback = fixture.model(
            activation: TestAudioSessionActivation()
        )

        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL, fixture.audioURL],
            accountID: fixture.accountID,
            account: nil,
            initialTime: 1.5
        )

        XCTAssertEqual(playback.currentTime, 1.5, accuracy: 0.01)
        XCTAssertEqual(playback.currentAudioFileIndex, 1)
        XCTAssertNil(playback.positionConflict)
        await playback.stop()
    }

    func testActivePlaybackSeekPreservesPausedIntent() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let playback = fixture.model(
            activation: TestAudioSessionActivation()
        )
        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL],
            accountID: fixture.accountID,
            account: nil
        )
        playback.pause()

        await playback.seek(to: 0.75)

        XCTAssertEqual(playback.currentTime, 0.75, accuracy: 0.01)
        XCTAssertEqual(playback.state, .paused)
        XCTAssertFalse(playback.isPlaybackRequested)
        await playback.stop()
    }

    func testActivePlaybackSeekPreservesPlayingIntent() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let playback = fixture.model(
            activation: TestAudioSessionActivation()
        )
        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL],
            accountID: fixture.accountID,
            account: nil
        )

        await playback.seek(to: 0.75)

        XCTAssertEqual(playback.currentTime, 0.75, accuracy: 0.01)
        XCTAssertTrue(playback.isPlaybackRequested)
        XCTAssertTrue(
            playback.state == .buffering || playback.state == .playing
        )
        await playback.stop()
    }

    func testPlaybackStartPositionResolverValidatesEveryTypedPosition() {
        let chapters = [
            PlaybackChapter(id: 7, start: 10, end: 20, title: "Seven"),
            PlaybackChapter(id: 8, start: 20, end: 30, title: "Eight"),
        ]

        XCTAssertEqual(
            PlaybackStartPositionResolver.resolve(
                .resume,
                duration: 30,
                chapters: chapters
            ),
            .resume
        )
        XCTAssertEqual(
            PlaybackStartPositionResolver.resolve(
                .beginning,
                duration: 30,
                chapters: chapters
            ),
            .absoluteTime(0)
        )
        XCTAssertEqual(
            PlaybackStartPositionResolver.resolve(
                .absoluteTime(12.5),
                duration: 30,
                chapters: chapters
            ),
            .absoluteTime(12.5)
        )
        for invalid in [
            -1.0, Double.nan, Double.infinity, 30.1,
        ] {
            XCTAssertEqual(
                PlaybackStartPositionResolver.resolve(
                    .absoluteTime(invalid),
                    duration: 30,
                    chapters: chapters
                ),
                .failed(
                    AppFailure(.openPlayback, .invalidPlaybackPosition)
                )
            )
        }
        XCTAssertEqual(
            PlaybackStartPositionResolver.resolve(
                .chapter(
                    PlaybackChapterPosition(chapterID: 7, offset: 2.5)
                ),
                duration: 30,
                chapters: chapters
            ),
            .absoluteTime(12.5)
        )
        XCTAssertEqual(
            PlaybackStartPositionResolver.resolve(
                .chapter(
                    PlaybackChapterPosition(chapterID: 9, offset: 0)
                ),
                duration: 30,
                chapters: chapters
            ),
            .failed(AppFailure(.openPlayback, .unknownPlaybackChapter))
        )
        for offset in [-1.0, Double.nan, Double.infinity, 10] {
            XCTAssertEqual(
                PlaybackStartPositionResolver.resolve(
                    .chapter(
                        PlaybackChapterPosition(
                            chapterID: 7,
                            offset: offset
                        )
                    ),
                    duration: 30,
                    chapters: chapters
                ),
                .failed(
                    AppFailure(
                        .openPlayback,
                        .invalidPlaybackChapterOffset
                    )
                )
            )
        }
        XCTAssertEqual(
            PlaybackStartPositionResolver.resolve(
                .chapter(
                    PlaybackChapterPosition(chapterID: 7, offset: 0)
                ),
                duration: 30,
                chapters: chapters + [chapters[0]]
            ),
            .failed(AppFailure(.openPlayback, .unknownPlaybackChapter))
        )
        let staleChapter = PlaybackChapter(
            id: 7,
            start: 1_000,
            end: 2_000,
            title: "Stale"
        )
        XCTAssertEqual(
            PlaybackStartPositionResolver.resolve(
                .chapter(staleChapter, offset: 2.5),
                duration: 30,
                chapters: chapters
            ),
            .absoluteTime(12.5)
        )
    }

    func testPlaybackStartDiscoversCompleteDownloadFromSummary()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlaybackStartDownload-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let otherAccount = try fixtureAccount(accountID: "account-2")
        let summary = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: summary)
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail
        )
        let service = TestAppService(
            accounts: .success([account, otherAccount]),
            activeAccount: .success(account)
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("complete-download-playback")
        )
        await model.start()

        let outcome = await model.startPlayback(
            book: summary,
            account: account,
            position: .absoluteTime(0.75)
        )
        let detailRequests = await service.bookDetailRequests()
        let playbackRequests = await service.playbackOpenRequests()

        XCTAssertEqual(outcome, .started(source: .downloaded))
        XCTAssertEqual(model.playback.currentTime, 0.75, accuracy: 0.01)
        XCTAssertTrue(detailRequests.isEmpty)
        XCTAssertTrue(playbackRequests.isEmpty)
        await model.playback.stop()

        let record = try XCTUnwrap(
            model.downloads.record(
                accountID: account.id,
                itemID: detail.id
            )
        )
        let mismatched = await model.startPlayback(
            download: record,
            account: otherAccount
        )
        XCTAssertEqual(
            mismatched,
            .failed(AppFailure(.openPlayback, .playbackIdentityMismatch))
        )
    }

    func testPlaybackStartUsesAutomaticCachedWindowWithoutAwaitingNetwork()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlaybackStartAutomaticCache-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let summary = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: summary)
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail,
            purpose: .automaticCache,
            includeTimelineMetadata: false
        )
        let playbackGate = AsyncGate()
        let remotePreparation = playbackPreparation(
            detail: detail,
            audioURL: root.appendingPathComponent("source.wav"),
            sessionID: "cached-continuation"
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [.success(remotePreparation)],
            playbackGate: playbackGate
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("cached-window-playback")
        )
        await model.start()
        let started = expectation(
            description: "Cached playback starts before remote preparation"
        )
        var outcome: PlaybackStartOutcome?
        let start = Task { @MainActor in
            outcome = await model.startPlayback(
                book: summary,
                account: account,
                position: .absoluteTime(0.25)
            )
            started.fulfill()
        }

        await fulfillment(of: [started], timeout: 2)

        XCTAssertEqual(outcome, .started(source: .downloaded))
        XCTAssertEqual(model.playback.currentTime, 0.25, accuracy: 0.05)
        XCTAssertEqual(model.playback.coverLoadPolicy, .cacheOnly)
        XCTAssertTrue(
            model.playback.state == .buffering
                || model.playback.state == .playing
        )
        await playbackGate.release()
        await start.value
        await model.playback.stop()
    }

    func testAutomaticCachedWindowRequiresVerifiedTimedLocalTrack()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "VerifiedAutomaticCache-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixturePage(libraryID: fixtureLibrary().id).items[0]
        )
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail,
            purpose: .automaticCache
        )
        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(account)),
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("verified-automatic-cache")
        )
        await model.start(account: account)
        let record = try XCTUnwrap(model.records.first)

        let window = await model.automaticCachedPlaybackWindow(
            for: record,
            containing: 0.25
        )
        XCTAssertEqual(window?.trackIndexes, [0])
        XCTAssertEqual(window?.startTime, 0)
        XCTAssertEqual(window?.endTime, 1)
        model.releaseAutomaticCachePin(window?.pin)

        let outside = await model.automaticCachedPlaybackWindow(
            for: record,
            containing: 1.25
        )
        XCTAssertNil(outside)

        let layout = try DownloadStorageLayout(rootURL: root)
        try FileManager.default.removeItem(
            at: layout.bookDirectory(
                accountID: account.id,
                itemID: detail.id
            ).appendingPathComponent("00000.wav")
        )
        let corrupt = await model.automaticCachedPlaybackWindow(
            for: record,
            containing: 0.25
        )
        XCTAssertNil(corrupt)
    }

    func testAutomaticCachedWindowRecoversSingleFileBookTiming()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SingleFileAutomaticCache-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixturePage(libraryID: fixtureLibrary().id).items[0]
        )
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail,
            purpose: .automaticCache,
            includeTimelineMetadata: false
        )
        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(account)),
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("single-file-cache-timing")
        )
        await model.start(account: account)
        let record = try XCTUnwrap(model.records.first)
        XCTAssertNil(record.manifest.entries[0].startOffset)
        XCTAssertNil(record.manifest.entries[0].duration)

        let requestedTime = detail.duration * 0.8
        let window = await model.automaticCachedPlaybackWindow(
            for: record,
            containing: requestedTime
        )

        XCTAssertEqual(window?.trackIndexes, [0])
        XCTAssertEqual(window?.startTime, 0)
        XCTAssertEqual(window?.endTime, detail.duration)
        model.releaseAutomaticCachePin(window?.pin)
    }

    func testAutomaticCachedWindowDoesNotInferMultiFileTiming()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "MultiFileAutomaticCache-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let singleFileDetail = fixtureBookDetail(
            item: fixturePage(libraryID: fixtureLibrary().id).items[0]
        )
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: singleFileDetail,
            purpose: .automaticCache,
            includeTimelineMetadata: false
        )
        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(account)),
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("multi-file-cache-timing")
        )
        await model.start(account: account)
        let stored = try XCTUnwrap(model.records.first)
        let multiFileDetail = fixtureBookDetail(
            item: fixtureBook(
                id: stored.detail.id.rawValue,
                title: stored.detail.title,
                libraryID: stored.detail.libraryID,
                trackCount: 2
            )
        )
        let record = DownloadedBookRecord(
            manifest: stored.manifest,
            detail: multiFileDetail
        )

        let window = await model.automaticCachedPlaybackWindow(
            for: record,
            containing: multiFileDetail.duration * 0.8
        )

        XCTAssertNil(window)
    }

    func testCachedWindowStartDoesNotAwaitPreviousRemoteSessionClose()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let root = fixture.root.appendingPathComponent(
            "CachedCloseHandoff",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let cachedSummary = fixtureBook(
            id: "cached-item",
            title: "Cached",
            libraryID: fixture.detail.libraryID
        )
        let cachedDetail = fixtureBookDetail(item: cachedSummary)
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: cachedDetail,
            purpose: .automaticCache
        )
        let closeGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [
                .success(
                    playbackPreparation(
                        detail: fixture.detail,
                        audioURL: fixture.audioURL,
                        sessionID: "previous-stream"
                    )
                ),
                .success(
                    playbackPreparation(
                        detail: cachedDetail,
                        audioURL: root.appendingPathComponent("source.wav"),
                        sessionID: "cached-continuation"
                    )
                ),
            ],
            playbackCloseGate: closeGate
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("cached-session-close")
        )
        await model.start()
        let first = await model.startPlayback(
            detail: fixture.detail,
            account: account
        )
        XCTAssertEqual(first, .started(source: .streamed))

        let started = expectation(
            description: "Cached start is independent of remote close"
        )
        var cachedOutcome: PlaybackStartOutcome?
        let cachedStart = Task { @MainActor in
            cachedOutcome = await model.startPlayback(
                book: cachedSummary,
                account: account,
                position: .absoluteTime(0.25)
            )
            started.fulfill()
        }
        await closeGate.waitUntilEntered()
        await fulfillment(of: [started], timeout: 2)

        XCTAssertEqual(cachedOutcome, .started(source: .downloaded))
        XCTAssertEqual(model.playback.itemID, cachedDetail.id)
        await closeGate.release()
        await cachedStart.value
        await model.playback.stop()
    }

    func testCachedSeekReusesPreparedStreamingSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CachedSeekPreparedSession-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let summary = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: summary)
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail,
            purpose: .automaticCache
        )
        let remote = AppPlaybackPreparation(
            sessionID: PlaybackSessionID(rawValue: "prepared-continuation"),
            itemID: detail.id,
            title: detail.title,
            duration: 2,
            currentTime: 0,
            chapters: detail.chapters,
            source: .direct([
                AppPlaybackTrack(
                    url: root.appendingPathComponent("source.wav"),
                    startOffset: 0,
                    duration: 2,
                    title: "Track 1"
                )
            ])
        )
        let preparationGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [.success(remote)],
            playbackGate: preparationGate
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("cached-seek")
        )
        await model.start()
        let outcome = await model.startPlayback(
            book: summary,
            account: account,
            position: .absoluteTime(0.25)
        )
        XCTAssertEqual(outcome, .started(source: .downloaded))
        await preparationGate.waitUntilEntered()
        await preparationGate.release()
        await Task.yield()

        await model.playback.seek(to: 1.25)

        let didContinue = await waitUntil(timeout: .seconds(2)) {
            model.playback.coverLoadPolicy == .allowNetwork
        }
        XCTAssertTrue(didContinue)
        let openRequests = await service.playbackOpenRequests()
        XCTAssertEqual(openRequests.count, 1)
        XCTAssertFalse(isFailed(model.playback.state))
        await model.playback.stop()
    }

    func testCachedBoundaryRetriesTransientStreamingPreparation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "CachedBoundaryRetry-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let summary = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: summary)
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail,
            purpose: .automaticCache
        )
        let remote = AppPlaybackPreparation(
            sessionID: PlaybackSessionID(rawValue: "retried-continuation"),
            itemID: detail.id,
            title: detail.title,
            duration: 2,
            currentTime: 0,
            chapters: detail.chapters,
            source: .direct([
                AppPlaybackTrack(
                    url: root.appendingPathComponent("source.wav"),
                    startOffset: 0,
                    duration: 2,
                    title: "Track 1"
                )
            ])
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [
                .failure(.playbackSession(.requestFailed)),
                .success(remote),
            ]
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("cached-boundary-retry")
        )
        await model.start()
        let outcome = await model.startPlayback(
            book: summary,
            account: account,
            position: .absoluteTime(0.75)
        )
        XCTAssertEqual(outcome, .started(source: .downloaded))

        let didRetry = await waitUntil(timeout: .seconds(4)) {
            model.playback.coverLoadPolicy == .allowNetwork
        }
        XCTAssertTrue(didRetry)
        let openRequests = await service.playbackOpenRequests()
        XCTAssertEqual(openRequests.count, 2)
        XCTAssertFalse(isFailed(model.playback.state))
        await model.playback.stop()
    }

    func testPausedCachedBoundaryResumesPreparedContinuation()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PausedCachedBoundary-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let summary = fixturePage(libraryID: fixtureLibrary().id).items[0]
        let detail = fixtureBookDetail(item: summary)
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail,
            purpose: .automaticCache
        )
        let remote = AppPlaybackPreparation(
            sessionID: PlaybackSessionID(rawValue: "paused-continuation"),
            itemID: detail.id,
            title: detail.title,
            duration: 2,
            currentTime: 0,
            chapters: detail.chapters,
            source: .direct([
                AppPlaybackTrack(
                    url: root.appendingPathComponent("source.wav"),
                    startOffset: 0,
                    duration: 2,
                    title: "Track 1"
                )
            ])
        )
        let preparationGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [.success(remote)],
            playbackGate: preparationGate
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("cached-boundary-resume")
        )
        await model.start()
        let outcome = await model.startPlayback(
            book: summary,
            account: account,
            position: .absoluteTime(0.75)
        )
        XCTAssertEqual(outcome, .started(source: .downloaded))
        await preparationGate.waitUntilEntered()
        let cachedBoundaryReached = expectation(
            description: "Cached boundary waits for streaming preparation"
        )
        Self.fulfill(
            cachedBoundaryReached,
            when: model.playback,
            reaches: .waitingForPreparation
        )
        await fulfillment(of: [cachedBoundaryReached], timeout: 3)
        XCTAssertEqual(
            model.playback.cachedContinuationPhase,
            .waitingForPreparation
        )
        XCTAssertGreaterThanOrEqual(model.playback.currentTime, 0.99)

        model.playback.pause()
        XCTAssertEqual(model.playback.state, .paused)
        XCTAssertEqual(
            model.playback.cachedContinuationPhase,
            .waitingForPreparation
        )
        let preparationCompleted = expectation(
            description: "Streaming continuation prepared while paused"
        )
        Self.fulfill(
            preparationCompleted,
            when: model.playback,
            reaches: .prepared
        )
        await preparationGate.release()
        await fulfillment(of: [preparationCompleted], timeout: 2)
        XCTAssertEqual(model.playback.state, .paused)
        XCTAssertEqual(
            model.playback.cachedContinuationPhase,
            .prepared
        )

        let continuationFinished = expectation(
            description: "Prepared continuation activation finished"
        )
        Self.fulfill(
            continuationFinished,
            when: model.playback,
            reaches: .inactive
        )
        model.playback.play()
        await fulfillment(of: [continuationFinished], timeout: 2)
        XCTAssertTrue(model.playback.isPlaybackRequested)
        XCTAssertTrue(
            model.playback.state == .buffering
                || model.playback.state == .playing
        )
        XCTAssertEqual(model.playback.coverLoadPolicy, .allowNetwork)
        let openRequests = await service.playbackOpenRequests()
        XCTAssertEqual(openRequests.count, 1)
        XCTAssertFalse(isFailed(model.playback.state))
        await model.playback.stop()
    }

    func testSupersededCachedStartReleasesIncomingPin() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SupersededCachedPin-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixturePage(libraryID: fixtureLibrary().id).items[0]
        )
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail,
            purpose: .automaticCache
        )
        let downloads = DownloadModel(
            service: TestAppService(activeAccount: .success(account)),
            storageRootURL: root,
            backgroundSessionIdentifier:
                backgroundSessionIdentifier("superseded-cache-pin")
        )
        await downloads.start(account: account)
        let record = try XCTUnwrap(downloads.records.first)
        let resolvedFirstWindow =
            await downloads.automaticCachedPlaybackWindow(
                for: record,
                containing: 0.25
            )
        let firstWindow = try XCTUnwrap(resolvedFirstWindow)
        let resolvedIncomingWindow =
            await downloads.automaticCachedPlaybackWindow(
                for: record,
                containing: 0.25
            )
        let incomingWindow = try XCTUnwrap(resolvedIncomingWindow)
        let statisticsFinishGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            statisticsFinishGate: statisticsFinishGate
        )
        let playback = PlaybackModel(
            service: service,
            audioSessionActivation: {}
        )
        var releasedPins: Set<AutomaticCachePin> = []
        playback.setAutomaticCachedPlaybackHandlers(
            resolve: { _, _, _ in nil },
            release: { pin in
                if let pin {
                    releasedPins.insert(pin)
                    downloads.releaseAutomaticCachePin(pin)
                }
            }
        )
        await playback.startDownloaded(
            detail: detail,
            trackURLs: [],
            accountID: account.id,
            account: nil,
            initialTime: 0.25,
            automaticCachedWindow: firstWindow
        )
        let supersededStart = Task { @MainActor in
            await playback.startDownloaded(
                detail: detail,
                trackURLs: [],
                accountID: account.id,
                account: nil,
                initialTime: 0.25,
                automaticCachedWindow: incomingWindow
            )
        }
        await statisticsFinishGate.waitUntilEntered()
        playback.pause()
        await statisticsFinishGate.release()
        await supersededStart.value

        XCTAssertTrue(releasedPins.contains(incomingWindow.pin))
        await playback.stop()
    }

    func testPlaybackStartLoadsDetailWithoutChangingNavigationState()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let account = try fixtureAccount()
        let detail = fixture.detail
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail),
            playback: [
                .success(
                    playbackPreparation(
                        detail: detail,
                        audioURL: fixture.audioURL
                    )
                )
            ]
        )
        let model = AppModel(service: service)
        await model.start()

        let outcome = await model.startPlayback(
            book: fixturePage(libraryID: detail.libraryID).items[0],
            account: account,
            position: .absoluteTime(0.75)
        )

        XCTAssertEqual(outcome, .started(source: .streamed))
        XCTAssertEqual(model.playback.currentTime, 0.75, accuracy: 0.01)
        XCTAssertNil(model.selectedBookID)
        XCTAssertEqual(model.bookDetail, .idle)
        XCTAssertEqual(model.bookBookmarks, .idle)
        let detailRequests = await service.bookDetailRequests()
        XCTAssertEqual(detailRequests.count, 1)
        await model.playback.stop()
    }

    func testPlaybackStartReusesMatchingActivePlayerAndResumes()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let account = try fixtureAccount()
        let detail = fixture.detail
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [
                .success(
                    playbackPreparation(
                        detail: detail,
                        audioURL: fixture.audioURL
                    )
                )
            ]
        )
        let model = AppModel(service: service)
        await model.start()
        let initialOutcome = await model.startPlayback(
            detail: detail,
            account: account
        )
        XCTAssertEqual(initialOutcome, .started(source: .streamed))
        model.playback.pause()

        let outcome = await model.startPlayback(
            detail: detail,
            account: account,
            position: .absoluteTime(0.5)
        )

        XCTAssertEqual(outcome, .started(source: .activePlayer))
        XCTAssertEqual(model.playback.currentTime, 0.5, accuracy: 0.01)
        XCTAssertTrue(model.playback.isPlaybackRequested)
        let playbackRequests = await service.playbackOpenRequests()
        XCTAssertEqual(playbackRequests.count, 1)
        await model.playback.stop()
    }

    func testPlaybackStartRejectsActivePlayerFromAnotherLibrary()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let account = try fixtureAccount()
        let detail = fixture.detail
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [
                .success(
                    playbackPreparation(
                        detail: detail,
                        audioURL: fixture.audioURL
                    )
                )
            ]
        )
        let model = AppModel(service: service)
        await model.start()
        let initialOutcome = await model.startPlayback(
            detail: detail,
            account: account
        )
        XCTAssertEqual(initialOutcome, .started(source: .streamed))

        let mismatched = fixtureBookDetail(
            item: fixtureBook(
                id: detail.id.rawValue,
                title: detail.title,
                libraryID: LibraryID(rawValue: "other-library")
            )
        )
        let outcome = await model.startPlayback(
            detail: mismatched,
            account: account
        )

        XCTAssertEqual(
            outcome,
            .failed(AppFailure(.openPlayback, .playbackIdentityMismatch))
        )
        let requests = await service.playbackOpenRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(model.playback.libraryID, detail.libraryID)
        await model.playback.stop()
    }

    func testPlaybackStartRejectsAnUnsavedAccount() async throws {
        let savedAccount = try fixtureAccount()
        let otherAccount = try fixtureAccount(accountID: "account-2")
        let detail = fixtureBookDetail(
            item: fixturePage(libraryID: fixtureLibrary().id).items[0]
        )
        let model = AppModel(
            service: TestAppService(activeAccount: .success(savedAccount))
        )
        await model.start()

        let outcome = await model.startPlayback(
            detail: detail,
            account: otherAccount
        )

        XCTAssertEqual(
            outcome,
            .failed(AppFailure(.openPlayback, .accountUnavailable))
        )
    }

    func testPlaybackStartMapsEveryAccessDenial() async throws {
        let libraryID = fixtureLibrary().id
        let cases:
            [(
                permissions: UserPermissions,
                accessibleLibraryIDs: [LibraryID],
                selectedItemTags: [String],
                isExplicit: Bool,
                tags: [String],
                expected: AppFailureCause
            )] = [
                (
                    permissions: UserPermissions(
                        download: false,
                        update: false,
                        delete: false,
                        upload: false,
                        createEReader: false,
                        accessAllLibraries: false,
                        accessAllTags: true,
                        accessExplicitContent: true,
                        selectedTagsNotAccessible: false
                    ),
                    accessibleLibraryIDs: [],
                    selectedItemTags: [],
                    isExplicit: false,
                    tags: [],
                    expected: .inaccessibleLibrary
                ),
                (
                    permissions: UserPermissions(
                        download: false,
                        update: false,
                        delete: false,
                        upload: false,
                        createEReader: false,
                        accessAllLibraries: true,
                        accessAllTags: false,
                        accessExplicitContent: true,
                        selectedTagsNotAccessible: false
                    ),
                    accessibleLibraryIDs: [],
                    selectedItemTags: ["allowed"],
                    isExplicit: false,
                    tags: ["restricted"],
                    expected: .inaccessibleTags
                ),
                (
                    permissions: UserPermissions(
                        download: false,
                        update: false,
                        delete: false,
                        upload: false,
                        createEReader: false,
                        accessAllLibraries: true,
                        accessAllTags: true,
                        accessExplicitContent: false,
                        selectedTagsNotAccessible: false
                    ),
                    accessibleLibraryIDs: [],
                    selectedItemTags: [],
                    isExplicit: true,
                    tags: [],
                    expected: .explicitContentDenied
                ),
            ]

        for (index, testCase) in cases.enumerated() {
            let account = try fixtureAccount(
                accountID: "account-\(index)",
                permissions: testCase.permissions,
                accessibleLibraryIDs: testCase.accessibleLibraryIDs,
                selectedItemTags: testCase.selectedItemTags
            )
            let book = fixtureBook(
                id: "restricted-\(index)",
                title: "Restricted",
                libraryID: libraryID,
                isExplicit: testCase.isExplicit
            )
            let model = AppModel(
                service: TestAppService(activeAccount: .success(account))
            )
            await model.start()

            let outcome = await model.startPlayback(
                detail: fixtureBookDetail(
                    item: book,
                    tags: testCase.tags
                ),
                account: account
            )

            XCTAssertEqual(
                outcome,
                .failed(AppFailure(.openPlayback, testCase.expected))
            )
        }
    }

    func testNewPlaybackStartSupersedesInFlightDetailLoad() async throws {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let gate = AsyncGate()
        let account = try fixtureAccount()
        let detail = fixture.detail
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail),
            playback: [
                .success(
                    playbackPreparation(
                        detail: detail,
                        audioURL: fixture.audioURL
                    )
                )
            ],
            bookDetailGate: gate
        )
        let model = AppModel(service: service)
        await model.start()
        let summary = fixturePage(libraryID: detail.libraryID).items[0]
        let first = Task {
            await model.startPlayback(book: summary, account: account)
        }
        await gate.waitUntilEntered()

        XCTAssertEqual(
            model.playbackStartTarget,
            PlaybackStartTarget(accountID: account.id, itemID: summary.id)
        )
        XCTAssertEqual(
            model.coverPlaybackState(
                accountID: account.id,
                itemID: summary.id
            ),
            .preparing
        )

        let second = await model.startPlayback(
            detail: detail,
            account: account
        )
        await gate.release()

        let firstOutcome = await first.value
        let playbackRequests = await service.playbackOpenRequests()
        XCTAssertEqual(second, .started(source: .streamed))
        XCTAssertEqual(firstOutcome, .superseded)
        XCTAssertEqual(playbackRequests.count, 1)
        XCTAssertNil(model.playbackStartTarget)
        await model.playback.stop()
    }

    func testAccountSwitchSupersedesInFlightPlaybackStart() async throws {
        let firstAccount = try fixtureAccount()
        let secondAccount = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "second",
            server: "https://second.example"
        )
        let gate = AsyncGate()
        let detail = fixtureBookDetail(
            item: fixturePage(libraryID: fixtureLibrary().id).items[0]
        )
        let service = TestAppService(
            accounts: .success([firstAccount, secondAccount]),
            activeAccount: .success(firstAccount),
            bookDetail: .success(detail),
            bookDetailGate: gate
        )
        let model = AppModel(service: service)
        await model.start()
        let start = Task {
            await model.startPlayback(
                book: fixturePage(libraryID: detail.libraryID).items[0],
                account: firstAccount
            )
        }
        await gate.waitUntilEntered()

        await model.switchAccount(to: secondAccount)
        await gate.release()

        let outcome = await start.value
        let playbackRequests = await service.playbackOpenRequests()
        XCTAssertEqual(outcome, .superseded)
        XCTAssertTrue(playbackRequests.isEmpty)
    }

    func testAccountSwitchCancelsInFlightStreamPreparation() async throws {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let playbackGate = AsyncGate()
        let firstAccount = try fixtureAccount()
        let secondAccount = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "second",
            server: "https://second.example"
        )
        let service = TestAppService(
            accounts: .success([firstAccount, secondAccount]),
            activeAccount: .success(firstAccount),
            playback: [
                .success(
                    playbackPreparation(
                        detail: fixture.detail,
                        audioURL: fixture.audioURL
                    )
                )
            ],
            playbackGate: playbackGate
        )
        let model = AppModel(service: service)
        await model.start()
        let start = Task {
            await model.startPlayback(
                detail: fixture.detail,
                account: firstAccount
            )
        }
        await playbackGate.waitUntilEntered()

        await model.switchAccount(to: secondAccount)
        await playbackGate.release()

        let outcome = await start.value
        let closedSessions = await service.playbackCloseSessionIDs()
        XCTAssertEqual(outcome, .superseded)
        XCTAssertFalse(model.playback.hasActiveBook)
        XCTAssertEqual(
            closedSessions,
            [PlaybackSessionID(rawValue: "playback-start-session")]
        )
    }

    func testNewRequestCancelsInFlightStreamPreparation() async throws {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let playbackGate = AsyncGate()
        let account = try fixtureAccount()
        let secondDetail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-2",
                title: "Second",
                libraryID: fixture.detail.libraryID
            )
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [
                .success(
                    playbackPreparation(
                        detail: fixture.detail,
                        audioURL: fixture.audioURL,
                        sessionID: "first-session"
                    )
                ),
                .success(
                    playbackPreparation(
                        detail: secondDetail,
                        audioURL: fixture.audioURL,
                        sessionID: "second-session"
                    )
                ),
            ],
            playbackGate: playbackGate
        )
        let model = AppModel(service: service)
        await model.start()
        let first = Task {
            await model.startPlayback(
                detail: fixture.detail,
                account: account
            )
        }
        await playbackGate.waitUntilEntered()

        let second = await model.startPlayback(
            detail: secondDetail,
            account: account
        )
        await playbackGate.release()

        let firstOutcome = await first.value
        let closedSessions = await service.playbackCloseSessionIDs()
        XCTAssertEqual(firstOutcome, .superseded)
        XCTAssertEqual(second, .started(source: .streamed))
        XCTAssertEqual(model.playback.itemID, secondDetail.id)
        XCTAssertTrue(
            closedSessions.contains(
                PlaybackSessionID(rawValue: "first-session")
            )
        )
        await model.playback.stop()
    }

    func testThreePlaybackStartsSerializeReentrantInvalidation()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let playbackGate = AsyncGate()
        let closeGate = AsyncGate()
        let diagnostics = GatedClosePlaybackDiagnosticRecorder(
            gate: closeGate
        )
        let account = try fixtureAccount()
        let secondDetail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-2",
                title: "Second",
                libraryID: fixture.detail.libraryID
            )
        )
        let thirdDetail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-3",
                title: "Third",
                libraryID: fixture.detail.libraryID
            )
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [
                .success(
                    playbackPreparation(
                        detail: fixture.detail,
                        audioURL: fixture.audioURL,
                        sessionID: "first-session"
                    )
                ),
                .success(
                    playbackPreparation(
                        detail: thirdDetail,
                        audioURL: fixture.audioURL,
                        sessionID: "third-session"
                    )
                ),
            ],
            playbackGate: playbackGate
        )
        let model = AppModel(service: service, diagnostics: diagnostics)
        await model.start()
        let first = Task {
            await model.startPlayback(
                detail: fixture.detail,
                account: account
            )
        }
        await playbackGate.waitUntilEntered()
        let second = Task {
            await model.startPlayback(
                detail: secondDetail,
                account: account
            )
        }
        await closeGate.waitUntilEntered()
        XCTAssertEqual(
            model.playbackStartTarget,
            PlaybackStartTarget(
                accountID: account.id,
                itemID: secondDetail.id
            )
        )
        let third = Task {
            await model.startPlayback(
                detail: thirdDetail,
                account: account
            )
        }

        await closeGate.release()
        await playbackGate.release()

        let firstOutcome = await first.value
        let secondOutcome = await second.value
        let thirdOutcome = await third.value
        XCTAssertEqual(firstOutcome, .superseded)
        XCTAssertEqual(secondOutcome, .superseded)
        XCTAssertEqual(thirdOutcome, .started(source: .streamed))
        XCTAssertEqual(model.playback.itemID, thirdDetail.id)
        let requests = await service.playbackOpenRequests()
        XCTAssertEqual(
            requests.map(\.itemID),
            [fixture.detail.id, thirdDetail.id]
        )
        await model.playback.stop()
    }

    func testSupersededFailureIsNotReturnedAfterDiagnosticRecording()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let diagnosticGate = AsyncGate()
        let diagnostics = GatedPlaybackFailureDiagnosticRecorder(
            gate: diagnosticGate
        )
        let denied = fixtureBookDetail(
            item: fixtureBook(
                id: "denied",
                title: "Denied",
                libraryID: fixture.detail.libraryID,
                isExplicit: true
            )
        )
        let restrictedAccount = try fixtureAccount(
            permissions: UserPermissions(
                download: true,
                update: false,
                delete: false,
                upload: false,
                createEReader: false,
                accessAllLibraries: true,
                accessAllTags: true,
                accessExplicitContent: false,
                selectedTagsNotAccessible: false
            )
        )
        let service = TestAppService(
            activeAccount: .success(restrictedAccount),
            playback: [
                .success(
                    playbackPreparation(
                        detail: fixture.detail,
                        audioURL: fixture.audioURL
                    )
                )
            ]
        )
        let model = AppModel(service: service, diagnostics: diagnostics)
        await model.start()
        let first = Task {
            await model.startPlayback(
                detail: denied,
                account: restrictedAccount
            )
        }
        await diagnosticGate.waitUntilEntered()

        let second = await model.startPlayback(
            detail: fixture.detail,
            account: restrictedAccount
        )
        await diagnosticGate.release()

        let firstOutcome = await first.value
        XCTAssertEqual(second, .started(source: .streamed))
        XCTAssertEqual(firstOutcome, .superseded)
        XCTAssertEqual(model.playback.itemID, fixture.detail.id)
        await model.playback.stop()
    }

    func testPlaybackStartContinuesAfterCallerCancellation() async throws {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let gate = AsyncGate()
        let account = try fixtureAccount()
        let detail = fixture.detail
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail),
            playback: [
                .success(
                    playbackPreparation(
                        detail: detail,
                        audioURL: fixture.audioURL
                    )
                )
            ],
            bookDetailGate: gate
        )
        let model = AppModel(service: service)
        await model.start()
        let start = Task {
            await model.startPlayback(
                book: fixturePage(libraryID: detail.libraryID).items[0],
                account: account
            )
        }
        await gate.waitUntilEntered()

        start.cancel()
        await gate.release()

        let outcome = await start.value
        XCTAssertEqual(outcome, .started(source: .streamed))
        XCTAssertTrue(
            model.playback.isPrepared(
                accountID: account.id,
                itemID: detail.id
            )
        )
        await model.playback.stop()
    }

    func testPlaybackStartExcludesIncompleteAndUsesAutomaticCachedWindow()
        async throws
    {
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixturePage(libraryID: fixtureLibrary().id).items[0]
        )
        let cases: [(purpose: DownloadPurpose, complete: Bool)] = [
            (.manual, false),
            (.automaticCache, true),
        ]

        for (index, testCase) in cases.enumerated() {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "PlaybackStartExcludedDownload-\(index)-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            try await prepareCompleteDownload(
                root: root,
                account: account,
                detail: detail,
                purpose: testCase.purpose,
                complete: testCase.complete
            )
            let service = TestAppService(
                activeAccount: .success(account),
                playback: [
                    .success(
                        playbackPreparation(
                            detail: detail,
                            audioURL: root.appendingPathComponent("source.wav")
                        )
                    )
                ]
            )
            let model = AppModel(
                service: service,
                downloadsStorageRootURL: root,
                downloadsBackgroundSessionIdentifier:
                    backgroundSessionIdentifier("incomplete-cached-window")
            )
            await model.start()

            let outcome = await model.startPlayback(
                detail: detail,
                account: account,
                position: .absoluteTime(0.75)
            )
            let playbackRequests = await service.playbackOpenRequests()
            let detailRequests = await service.bookDetailRequests()

            XCTAssertEqual(
                outcome,
                .started(
                    source: testCase.purpose == .automaticCache
                        ? .downloaded : .streamed
                )
            )
            XCTAssertEqual(model.playback.currentTime, 0.75, accuracy: 0.01)
            XCTAssertEqual(playbackRequests.count, 1)
            XCTAssertTrue(detailRequests.isEmpty)
            await model.playback.stop()
        }
    }

    func testAutomaticCachedDownloadUsesPersistedAccessWhileOffline()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let root = fixture.root.appendingPathComponent(
            "CanonicalDownloadFallback",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount(
            permissions: UserPermissions(
                download: true,
                update: false,
                delete: false,
                upload: false,
                createEReader: false,
                accessAllLibraries: true,
                accessAllTags: true,
                accessExplicitContent: false,
                selectedTagsNotAccessible: false
            )
        )
        let persistedDetail = fixture.detail
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: persistedDetail,
            purpose: .automaticCache
        )
        let positionStore = PlaybackPositionStore(defaults: fixture.defaults)
        try positionStore.save(
            0.25,
            accountID: account.id,
            itemID: persistedDetail.id
        )
        let canonicalDetail = fixtureBookDetail(
            item: fixtureBook(
                id: persistedDetail.id.rawValue,
                title: persistedDetail.title,
                libraryID: persistedDetail.libraryID,
                isExplicit: true
            )
        )
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(canonicalDetail)
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("offline-automatic-cache"),
            playbackPositionStore: positionStore
        )
        await model.start()
        let record = try XCTUnwrap(
            model.downloads.record(
                accountID: account.id,
                itemID: persistedDetail.id
            )
        )

        let outcome = await model.startPlayback(
            download: record,
            account: account
        )

        XCTAssertEqual(outcome, .started(source: .downloaded))
        XCTAssertEqual(model.playback.currentTime, 0.25, accuracy: 0.01)
        let detailRequests = await service.bookDetailRequests()
        XCTAssertTrue(detailRequests.isEmpty)
        let playbackRequests = await service.playbackOpenRequests()
        XCTAssertEqual(playbackRequests.count, 1)
        await model.playback.stop()
    }

    func testTranscriptPlaybackPreparationFailureRemainsTyped()
        async throws
    {
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixturePage(libraryID: fixtureLibrary().id).items[0]
        )
        let service = TestAppService(activeAccount: .success(account))
        let model = AppModel(service: service)
        await model.start()

        let outcome = await model.startPlayback(
            detail: detail,
            account: account,
            position: .absoluteTime(10)
        )

        XCTAssertEqual(outcome, .failed(.playbackUnavailable))
        XCTAssertEqual(model.playback.itemID, detail.id)
    }

    func testBrokenCompleteDownloadDoesNotFallBackToStreaming()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TranscriptPlaybackFallback-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let detail = fixtureBookDetail(
            item: fixturePage(libraryID: fixtureLibrary().id).items[0]
        )
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: detail
        )
        let preparation = AppPlaybackPreparation(
            sessionID: PlaybackSessionID(rawValue: "streamed-session"),
            itemID: detail.id,
            title: detail.title,
            duration: 1,
            currentTime: 0,
            chapters: detail.chapters,
            source: .direct([
                AppPlaybackTrack(
                    url: root.appendingPathComponent("source.wav"),
                    startOffset: 0,
                    duration: 1,
                    title: "Track 1"
                )
            ])
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [.success(preparation)]
        )
        let diagnostics = AppDiagnosticRecorderSpy()
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("broken-complete-download"),
            diagnostics: diagnostics
        )
        await model.start()
        XCTAssertTrue(
            try XCTUnwrap(model.downloads.records.first)
                .manifest.isFullBookComplete
        )
        let layout = try DownloadStorageLayout(rootURL: root)
        try FileManager.default.removeItem(
            at: layout.bookDirectory(
                accountID: account.id,
                itemID: detail.id
            ).appendingPathComponent("00000.wav")
        )

        let outcome = await model.startPlayback(
            detail: detail,
            account: account,
            position: .absoluteTime(0.75)
        )
        let playbackRequests = await service.playbackOpenRequests()

        XCTAssertEqual(outcome, .failed(.mediaUnavailable))
        XCTAssertTrue(playbackRequests.isEmpty)
        let events = await diagnostics.events()
        XCTAssertTrue(
            events.contains {
                $0.operation == .openPlayback
                    && $0.failureCode == .mediaUnavailable
            }
        )
    }

    func testBrokenDownloadFailureCannotOverwriteNewerPlayback()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer { fixture.cleanUp() }
        let root = fixture.root.appendingPathComponent(
            "BrokenDownloadSupersession",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let account = try fixtureAccount()
        let brokenDetail = fixture.detail
        try await prepareCompleteDownload(
            root: root,
            account: account,
            detail: brokenDetail
        )
        let secondDetail = fixtureBookDetail(
            item: fixtureBook(
                id: "item-2",
                title: "Second",
                libraryID: brokenDetail.libraryID
            )
        )
        let diagnosticGate = AsyncGate()
        let diagnostics = GatedPlaybackFailureDiagnosticRecorder(
            gate: diagnosticGate
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [
                .success(
                    playbackPreparation(
                        detail: secondDetail,
                        audioURL: fixture.audioURL,
                        sessionID: "second-session"
                    )
                )
            ]
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("stale-broken-download"),
            diagnostics: diagnostics
        )
        await model.start()
        let layout = try DownloadStorageLayout(rootURL: root)
        try FileManager.default.removeItem(
            at: layout.bookDirectory(
                accountID: account.id,
                itemID: brokenDetail.id
            ).appendingPathComponent("00000.wav")
        )
        let first = Task {
            await model.startPlayback(
                detail: brokenDetail,
                account: account
            )
        }
        await diagnosticGate.waitUntilEntered()

        let second = await model.startPlayback(
            detail: secondDetail,
            account: account
        )
        await diagnosticGate.release()

        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .superseded)
        XCTAssertEqual(second, .started(source: .streamed))
        XCTAssertEqual(model.playback.itemID, secondDetail.id)
        XCTAssertNotEqual(model.playback.state, .failed(.mediaUnavailable))
        await model.playback.stop()
    }

    func testPlaybackSessionFailureRemainsTyped() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.playback.start(detail: detail, account: account)

        XCTAssertEqual(
            model.playback.state,
            .failed(.playbackUnavailable)
        )
        XCTAssertEqual(model.playback.itemID, detail.id)
        XCTAssertFalse(model.playback.hasActiveBook)
    }

    func testRemoveAccountClearsSignedInState() async throws {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([])
        )
        let model = AppModel(service: service)
        await model.start()

        await model.removeAccount()

        let removedAccounts = await service.removedAccounts()
        XCTAssertEqual(removedAccounts, [account])
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.account)
        XCTAssertNil(model.selectedLibrary)
        XCTAssertEqual(model.libraries, .idle)
        XCTAssertEqual(model.books, .idle)
        XCTAssertEqual(model.homeShelves, .idle)
        XCTAssertEqual(model.accountActionStatus, .idle)
    }

    func testResetLocalDataClearsEveryAccountAndReturnsToSignedOut()
        async throws
    {
        let active = try fixtureAccount()
        let inactive = try fixtureAccount(
            accountID: "inactive-account",
            server: "https://other.example"
        )
        let service = TestAppService(
            accounts: .success([active, inactive]),
            activeAccount: .success(active),
            libraries: .success([])
        )
        let model = AppModel(service: service)
        await model.start()

        await model.resetLocalData()

        let resetRequestCount = await service.resetLocalDataRequestCount()
        XCTAssertEqual(resetRequestCount, 1)
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertTrue(model.accounts.isEmpty)
        XCTAssertNil(model.account)
        XCTAssertEqual(model.libraries, .idle)
        XCTAssertEqual(model.statistics, .idle)
        XCTAssertFalse(model.isResettingLocalData)
        XCTAssertNil(model.localDataResetFailure)
    }

    func testResetLocalDataPreservesSignedInStateWhenStoreCannotBeCleared()
        async throws
    {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([]),
            localDataReset: .failure(.localDataReset(.persistentStore))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.resetLocalData()

        let resetRequestCount = await service.resetLocalDataRequestCount()
        XCTAssertEqual(resetRequestCount, 1)
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(
            model.localDataResetFailure,
            AppFailure(
                operation: .resetAppData,
                serviceError: .localDataReset(.persistentStore)
            )
        )
    }

    func testResetLocalDataDisablesPrivateCloudBeforeItCanResynchronize()
        async throws
    {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([])
        )
        let model = AppModel(service: service)
        await model.start()

        await model.resetLocalData()
        let synchronizationRequestsAfterReset = await service
            .privateCloudSynchronizationRequestCount()
        await model.synchronizePrivateCloud()

        XCTAssertFalse(model.privateCloudSyncEnabled)
        XCTAssertEqual(model.privateCloudState, .disabled)
        let syncSettingRequests = await service.privateCloudSyncSettingRequests()
        XCTAssertEqual(syncSettingRequests.count, 1)
        XCTAssertEqual(syncSettingRequests.first?.enabled, false)
        XCTAssertEqual(syncSettingRequests.first?.deleteCloudData, false)
        let synchronizationRequestCount = await service
            .privateCloudSynchronizationRequestCount()
        XCTAssertEqual(
            synchronizationRequestCount,
            synchronizationRequestsAfterReset
        )
    }

    func testResetLocalDataPreservesDownloadsWhenPrivateCloudDisableFails()
        async throws
    {
        let account = try fixtureAccount()
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let item = fixtureBook(
            id: plan.itemID.rawValue,
            title: "Downloaded",
            libraryID: fixtureLibrary().id
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatResetCloudFailure-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let storage = DownloadStorage(
            layout: try DownloadStorageLayout(rootURL: root)
        )
        _ = try await storage.create(
            downloadID: DownloadID(
                rawValue: UUID().uuidString.lowercased()
            ),
            accountID: account.id,
            plan: plan,
            detail: fixtureBookDetail(item: item)
        )
        let disableFailure = AppServiceError.privateCloud(
            PrivateCloudSyncFailure(
                operation: .disable,
                cause: .persistenceFailed
            )
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([]),
            privateCloudSyncSetting: .failure(disableFailure)
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: root,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("failed-cloud-reset")
        )
        await model.start()
        XCTAssertEqual(model.downloads.records.count, 1)

        await model.resetLocalData()

        let restoredDownloadCount = try await storage.records().count
        let resetRequestCount = await service.resetLocalDataRequestCount()
        XCTAssertEqual(model.downloads.records.count, 1)
        XCTAssertEqual(restoredDownloadCount, 1)
        XCTAssertEqual(resetRequestCount, 0)
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(
            model.localDataResetFailure,
            AppFailure(
                operation: .resetAppData,
                serviceError: disableFailure
            )
        )
    }

    func testResetLocalDataClearsRealStorageAndSurvivesRelaunch()
        async throws
    {
        let fixture = try await makeLocalDataLifecycleFixture()
        let cleanupVault = fixture.makeCredentialStore()
        addTeardownBlock {
            try await cleanupVault.deleteAllCredentials()
        }
        let service = try makeLocalDataLifecycleService(
            modelContainer: fixture.modelContainer,
            credentialStore: fixture.makeCredentialStore()
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: fixture.downloadsURL,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("local-reset")
        )
        await model.start()
        XCTAssertEqual(model.accounts.count, 2)
        XCTAssertEqual(model.downloads.records.count, 2)

        await model.resetLocalData()

        XCTAssertNil(model.localDataResetFailure)
        XCTAssertEqual(model.phase, .signedOut)
        let relaunchedVault = fixture.makeCredentialStore()
        let relaunchedService = try makeLocalDataLifecycleService(
            modelContainer: try makeLocalDataLifecycleContainer(
                storeURL: fixture.storeURL
            ),
            credentialStore: relaunchedVault
        )
        let relaunchedModel = AppModel(
            service: relaunchedService,
            downloadsStorageRootURL: fixture.downloadsURL,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("local-reset-relaunch")
        )
        await relaunchedModel.start()

        XCTAssertEqual(relaunchedModel.phase, .signedOut)
        XCTAssertTrue(relaunchedModel.accounts.isEmpty)
        XCTAssertTrue(relaunchedModel.downloads.records.isEmpty)
        for account in fixture.accounts {
            let credentials = try await relaunchedVault.credentials(
                for: account.id
            )
            let nativeLogin = try await relaunchedVault
                .nativeLoginCredentials(
                    for: account.id
                )
            XCTAssertNil(credentials)
            XCTAssertNil(nativeLogin)
        }
    }

    func testRemovingOneOfTwoRealAccountsSurvivesRelaunch()
        async throws
    {
        let fixture = try await makeLocalDataLifecycleFixture()
        let cleanupVault = fixture.makeCredentialStore()
        addTeardownBlock {
            try await cleanupVault.deleteAllCredentials()
        }
        let service = try makeLocalDataLifecycleService(
            modelContainer: fixture.modelContainer,
            credentialStore: fixture.makeCredentialStore()
        )
        let model = AppModel(
            service: service,
            downloadsStorageRootURL: fixture.downloadsURL,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("account-removal-storage")
        )
        await model.start()
        let retainedAccount = fixture.accounts[0]
        let removedAccount = fixture.accounts[1]

        let removed = await model.removeAccount(removedAccount)

        XCTAssertTrue(removed)
        let relaunchedVault = fixture.makeCredentialStore()
        let relaunchedService = try makeLocalDataLifecycleService(
            modelContainer: try makeLocalDataLifecycleContainer(
                storeURL: fixture.storeURL
            ),
            credentialStore: relaunchedVault
        )
        let relaunchedModel = AppModel(
            service: relaunchedService,
            downloadsStorageRootURL: fixture.downloadsURL,
            downloadsBackgroundSessionIdentifier:
                backgroundSessionIdentifier("account-removal-relaunch")
        )
        await relaunchedModel.start()

        XCTAssertEqual(relaunchedModel.phase, .signedIn)
        XCTAssertEqual(relaunchedModel.accounts, [retainedAccount])
        XCTAssertEqual(relaunchedModel.account, retainedAccount)
        XCTAssertEqual(
            relaunchedModel.downloads.records.map(\.manifest.accountID),
            [retainedAccount.id]
        )
        let retainedCredentials = try await relaunchedVault.credentials(
            for: retainedAccount.id
        )
        let retainedNativeLogin = try await relaunchedVault
            .nativeLoginCredentials(
                for: retainedAccount.id
            )
        let removedCredentials = try await relaunchedVault.credentials(
            for: removedAccount.id
        )
        let removedNativeLogin = try await relaunchedVault
            .nativeLoginCredentials(
                for: removedAccount.id
            )
        XCTAssertNotNil(retainedCredentials)
        XCTAssertNotNil(retainedNativeLogin)
        XCTAssertNil(removedCredentials)
        XCTAssertNil(removedNativeLogin)
    }

    func testRemoveInactiveAccountKeepsBrowsingAccount() async throws {
        let active = try fixtureAccount()
        let inactive = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "other-reader",
            server: "https://other.example"
        )
        let service = TestAppService(
            accounts: .success([active, inactive]),
            activeAccount: .success(active),
            libraries: .success([])
        )
        let model = AppModel(service: service)
        await model.start()

        let removed = await model.removeAccount(inactive)

        XCTAssertTrue(removed)
        let removedAccounts = await service.removedAccounts()
        XCTAssertEqual(removedAccounts, [inactive])
        XCTAssertEqual(model.account, active)
        XCTAssertEqual(model.accounts, [active])
        XCTAssertEqual(model.phase, .signedIn)
    }

    func testRemoveAccountFailurePreservesSignedInState() async throws {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([]),
            removeAccount: .failure(
                .accountRemoval(.logoutRequestFailed)
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.removeAccount()

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(
            model.accountActionStatus,
            .failed(.accountRemovalFailed)
        )
    }

    func testConcurrentAccountRemovalIsIgnored() async throws {
        let account = try fixtureAccount()
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([]),
            removeGate: gate
        )
        let model = AppModel(service: service)
        await model.start()

        let firstRemoval = Task { @MainActor in
            await model.removeAccount()
        }
        await gate.waitUntilEntered()

        await model.removeAccount()
        await gate.release()
        _ = await firstRemoval.value

        let removalCount = await service.removedAccounts().count
        XCTAssertEqual(removalCount, 1)
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testServiceErrorsMapToStablePresentationFailures() {
        let cases: [(AppFailureOperation, AppServiceError, AppFailureCause)] = [
            (.login, .invalidServerURL(.empty), .invalidInput),
            (
                .login, .invalidServerURL(.unsupportedScheme("http")),
                .serverRequiresHTTPS
            ),
            (.login, .discovery(.uninitialized), .serverNotReady),
            (
                .login, .discovery(.unexpectedHTTPStatus(500)),
                .serverUnavailable
            ),
            (
                .login, .discovery(.unexpectedHTTPStatus(408)),
                .timeout
            ),
            (
                .login, .discovery(.unexpectedHTTPStatus(429)),
                .rateLimited
            ),
            (
                .login, .onboarding(.localAuthenticationUnavailable),
                .localLoginUnavailable
            ),
            (
                .login, .onboarding(.authenticationFailed(.invalidCredentials)),
                .invalidCredentials
            ),
            (
                .login,
                .onboarding(
                    .openIDAuthenticationFailed(
                        .presentationAnchorUnavailable
                    )
                ),
                .authenticationPresentationUnavailable
            ),
            (
                .appStart, .accountStore(.persistenceFailed),
                .localStorageUnavailable
            ),
            (
                .loadLibraries, .libraryRepository(.noCachedValue),
                .unavailableOffline
            ),
            (.loadLibraryPage, .pageRequest(.invalidPage), .invalidInput),
            (.loadHome, .homeRequest(.invalidLimit), .invalidInput),
            (.search, .searchRequest(.invalidQuery), .invalidInput),
            (.search, .searchCoordinator(.cancelled), .requestCancelled),
            (
                .loadBook, .bookDetail(.remote(.invalidBookDetail)),
                .invalidServerResponse
            ),
            (
                .loadBook, .bookDetail(.remote(.unexpectedStatus(404))),
                .itemNotFound
            ),
            (
                .loadBook, .bookDetail(.remote(.unexpectedStatus(403))),
                .permissionDenied
            ),
            (
                .openPlayback, .playbackSession(.requestFailed),
                .serverUnavailable
            ),
            (
                .updateProgress, .playbackSync(.unexpectedStatus(503)),
                .serverUnavailable
            ),
            (
                .updateProgress, .localPlaybackSession(.unexpectedStatus(503)),
                .serverUnavailable
            ),
            (
                .updateProgress, .progress(.unexpectedStatus(503)),
                .serverUnavailable
            ),
            (.saveMetadata, .metadataPatch(.emptyTitle), .invalidInput),
            (
                .saveMetadata, .metadataUpdate(.unexpectedStatus(503)),
                .serverUnavailable
            ),
            (
                .download, .downloadPlan(.unexpectedStatus(503)),
                .serverUnavailable
            ),
            (
                .download, .downloadAuthorization(.invalidAccountID),
                .invalidInput
            ),
            (.replaceCover, .coverUpdate(.uploadRejected), .invalidInput),
            (
                .removeAccount, .accountRemoval(.logoutRequestFailed),
                .uncertainMutation
            ),
            (
                .removeAccount, .libraryCache(.persistenceFailed),
                .localStorageUnavailable
            ),
        ]

        for (operation, error, cause) in cases {
            let expected = AppFailure(operation, cause)
            XCTAssertEqual(
                AppFailure(operation: operation, serviceError: error),
                expected,
                "Unexpected mapping for \(error)"
            )
            XCTAssertFalse(expected.diagnosticFailureCode.rawValue.isEmpty)
        }
    }

    func testPresentationFailuresHaveUserMessages() {
        let failures: [AppFailure] = [
            .persistenceUnavailable,
            .invalidServerAddress,
            .serverUnavailable,
            .invalidServerScheme,
            .serverNotReady,
            .serverUnsupported,
            .localLoginUnavailable,
            .invalidCredentials,
            .secureCredentialStorageUnavailable,
            .loginFailed,
            .accountUnavailable,
            .libraryUnavailable,
            .homeUnavailable,
            .searchUnavailable,
            .bookUnavailable(.serverUnavailable),
            .playbackDenied,
            .playbackUnavailable,
            .progressUnavailable,
            .mediaUnavailable,
            .invalidMetadata,
            .metadataUnavailable,
            .bookmarkUnavailable,
            .accountRemovalFailed,
        ]

        XCTAssertTrue(failures.allSatisfy { !$0.message.isEmpty })
        XCTAssertTrue(failures.allSatisfy { !$0.title.isEmpty })
        XCTAssertTrue(
            failures.allSatisfy { !$0.diagnosticFailureCode.rawValue.isEmpty }
        )
    }

    func testSecureCredentialStorageFailureHasRedactedDiagnosticCode() {
        let failure = AppFailure(
            operation: .login,
            serviceError: .onboarding(
                .authenticationFailed(
                    .credentialStorageUnavailable
                )
            )
        )

        XCTAssertEqual(
            failure,
            AppFailure(.login, .localStorageUnavailable)
        )
        XCTAssertEqual(
            failure.diagnosticFailureCode,
            .localStorageUnavailable
        )
        XCTAssertEqual(
            failure.diagnosticFailureCode.rawValue,
            "local_storage_unavailable"
        )
    }

    func testBookDetailFailuresHaveSpecificRedactedDiagnosticCodes() {
        let cases: [(BookDetailFailure, DiagnosticFailureCode)] = [
            (.notFound, .bookNotFound),
            (.accessDenied, .bookAccessDenied),
            (.reauthenticationRequired, .bookAuthenticationRequired),
            (.invalidServerResponse, .bookResponseInvalid),
            (.localStorageUnavailable, .bookStorageUnavailable),
            (.unavailableOffline, .bookUnavailableOffline),
            (.serverUnavailable, .bookUnavailable),
            (.requestRejected, .bookRequestRejected),
        ]

        for (detailFailure, expectedCode) in cases {
            let failure = AppFailure.bookUnavailable(detailFailure)
            XCTAssertEqual(
                failure.diagnosticFailureCode,
                expectedCode
            )
            XCTAssertFalse(failure.message.isEmpty)
            XCTAssertFalse(expectedCode.rawValue.contains("http"))
        }
    }

    func testNowPlayingSnapshotPublishesWholeBookAudiobookMetadata() {
        let snapshot = NowPlayingSnapshot(
            accountID: AccountID(rawValue: "account"),
            itemID: LibraryItemID(rawValue: "item"),
            title: "The Book",
            author: "The Author",
            narrator: "The Narrator",
            coverURL: nil,
            coverLoadPolicy: .allowNetwork,
            currentTime: 125,
            duration: 3_600,
            rate: 1.25,
            isPlaying: true,
            isPlaybackRequested: true,
            isPlaybackAvailable: true,
            canPerformPreviousCommand: true,
            canPerformNextCommand: true,
            currentChapterIndex: 1,
            currentChapterTitle: "Chapter Two",
            chapterCount: 4
        )

        let information = snapshot.information(artwork: nil)

        XCTAssertEqual(
            information[MPMediaItemPropertyTitle] as? String,
            "The Book"
        )
        XCTAssertEqual(
            information[MPMediaItemPropertyArtist] as? String,
            "The Author"
        )
        XCTAssertEqual(
            information[MPMediaItemPropertyComposer] as? String,
            "The Narrator"
        )
        XCTAssertEqual(
            information[MPMediaItemPropertyAlbumTitle] as? String,
            "Chapter Two"
        )
        XCTAssertEqual(
            information[MPNowPlayingInfoPropertyChapterNumber] as? Int,
            1
        )
        XCTAssertEqual(
            information[MPNowPlayingInfoPropertyChapterCount] as? Int,
            4
        )
        XCTAssertEqual(
            information[
                MPNowPlayingInfoPropertyElapsedPlaybackTime
            ] as? Double,
            125
        )
        XCTAssertEqual(
            information[MPNowPlayingInfoPropertyPlaybackRate] as? Double,
            1.25
        )
        XCTAssertEqual(
            information[
                MPNowPlayingInfoPropertyDefaultPlaybackRate
            ] as? Double,
            1.25
        )
        XCTAssertEqual(snapshot.systemPlaybackState, .playing)
    }

    func testNowPlayingCoordinatorPublishesSystemPlaybackStateFromIntent() {
        let infoPublisher = TestNowPlayingInfoPublisher()
        let coordinator = NowPlayingCoordinator(
            infoCenter: infoPublisher,
            registersRemoteCommands: false
        )

        coordinator.publish(
            nowPlayingSnapshot(
                accountID: nil,
                coverURL: nil,
                isPlaybackRequested: true
            )
        )
        XCTAssertEqual(infoPublisher.playbackState, .playing)

        coordinator.publish(
            nowPlayingSnapshot(
                accountID: nil,
                coverURL: nil,
                isPlaying: false,
                isPlaybackRequested: false
            )
        )
        XCTAssertEqual(infoPublisher.playbackState, .paused)

        coordinator.publish(
            nowPlayingSnapshot(
                accountID: nil,
                coverURL: nil,
                isPlaying: false,
                isPlaybackRequested: false,
                isPlaybackAvailable: false
            )
        )
        XCTAssertEqual(infoPublisher.playbackState, .stopped)

        coordinator.clear()
        XCTAssertEqual(infoPublisher.playbackState, .stopped)
    }

    #if os(iOS)
        nonisolated func testNowPlayingArtworkCanRenderOffMainActor() async {
            let image = await MainActor.run {
                UIGraphicsImageRenderer(
                    size: CGSize(width: 2, height: 2)
                ).image { context in
                    UIColor.systemBlue.setFill()
                    context.fill(
                        CGRect(x: 0, y: 0, width: 2, height: 2)
                    )
                }
            }
            let artwork = TestSendableArtwork(
                NowPlayingArtwork.make(from: image)
            )

            let renderedImage = await withCheckedContinuation { continuation in
                DispatchQueue(
                    label: "NowPlayingArtworkTests.background"
                ).async {
                    continuation.resume(
                        returning: artwork.value.image(
                            at: CGSize(width: 1, height: 1)
                        )
                    )
                }
            }

            XCTAssertNotNil(renderedImage)
        }

        func testNowPlayingRetriesCoverWhenAccountIdentityArrives() async throws
        {
            let imageData = try XCTUnwrap(
                UIGraphicsImageRenderer(
                    size: CGSize(width: 2, height: 2)
                ).image { context in
                    UIColor.systemTeal.setFill()
                    context.fill(
                        CGRect(x: 0, y: 0, width: 2, height: 2)
                    )
                }.pngData()
            )
            let fetcher = TestBookCoverFetcher(
                data: imageData,
                failingRequestCount: 1
            )
            let loader = BookCoverImageLoader(
                diskCapacity: 0,
                fetch: { request in
                    try await fetcher.fetch(request)
                }
            )
            let infoPublisher = TestNowPlayingInfoPublisher()
            let coordinator = NowPlayingCoordinator(
                infoCenter: infoPublisher,
                coverLoader: loader,
                registersRemoteCommands: false
            )
            let url = try XCTUnwrap(
                URL(string: "https://books.example/cover?ts=3")
            )

            coordinator.publish(
                nowPlayingSnapshot(accountID: nil, coverURL: url)
            )
            await waitForCoverRequests(fetcher, count: 1)
            coordinator.publish(
                nowPlayingSnapshot(
                    accountID: AccountID(rawValue: "cover-account"),
                    coverURL: url
                )
            )
            await waitForCoverRequests(fetcher, count: 2)

            let requestCount = await fetcher.requestCount
            let artwork = await waitForNowPlayingArtwork(in: infoPublisher)
            XCTAssertEqual(requestCount, 2)
            XCTAssertNotNil(artwork)
            coordinator.clear()
        }
    #endif

    func testFeaturedPlaybackRateStepsAndRemoteFailuresAreTyped() {
        let coordinator = NowPlayingCoordinator(
            registersRemoteCommands: false
        )
        var receivedCommand: PlaybackRemoteCommand?
        coordinator.setCommandHandler { command in
            receivedCommand = command
            return .accepted
        }
        coordinator.publish(
            NowPlayingSnapshot(
                accountID: nil,
                itemID: LibraryItemID(rawValue: "item"),
                title: "Book",
                author: "",
                narrator: "",
                coverURL: nil,
                coverLoadPolicy: .allowNetwork,
                currentTime: 0,
                duration: 100,
                rate: 1,
                isPlaying: false,
                isPlaybackRequested: false,
                isPlaybackAvailable: true,
                canPerformPreviousCommand: false,
                canPerformNextCommand: false,
                currentChapterIndex: nil,
                currentChapterTitle: nil,
                chapterCount: 0
            )
        )

        XCTAssertEqual(coordinator.stepPlaybackRate(.increase), .accepted)
        XCTAssertEqual(receivedCommand, .setRate(1.25))

        coordinator.publish(
            nowPlayingSnapshot(
                accountID: nil,
                coverURL: nil,
                rate: 1.35
            )
        )
        XCTAssertEqual(coordinator.stepPlaybackRate(.decrease), .accepted)
        XCTAssertEqual(receivedCommand, .setRate(1.25))
        XCTAssertEqual(coordinator.stepPlaybackRate(.increase), .accepted)
        XCTAssertEqual(receivedCommand, .setRate(1.5))

        coordinator.publish(
            nowPlayingSnapshot(
                accountID: nil,
                coverURL: nil,
                rate: 0.5
            )
        )
        XCTAssertEqual(coordinator.stepPlaybackRate(.decrease), .unavailable)

        coordinator.publish(
            nowPlayingSnapshot(
                accountID: nil,
                coverURL: nil,
                rate: 3
            )
        )
        XCTAssertEqual(coordinator.stepPlaybackRate(.increase), .unavailable)
        coordinator.clear()

        let playback = PlaybackModel(
            service: TestAppService(activeAccount: .success(nil)),
            nowPlayingCoordinator: NowPlayingCoordinator(
                registersRemoteCommands: false
            )
        )
        let unavailableCommands: [PlaybackRemoteCommand] = [
            .play,
            .pause,
            .toggle,
            .skipBackward,
            .skipForward,
            .previous,
            .next,
            .previousChapter,
            .nextChapter,
            .seek(0),
            .setRate(1),
        ]
        for command in unavailableCommands {
            XCTAssertEqual(
                playback.handleRemoteCommand(command),
                .unavailable
            )
        }
        XCTAssertEqual(
            playback.handleRemoteCommand(.seek(.nan)),
            .invalid
        )
        XCTAssertEqual(
            playback.handleRemoteCommand(.seek(-1)),
            .invalid
        )
        XCTAssertEqual(
            playback.handleRemoteCommand(.setRate(4)),
            .invalid
        )
    }

    #if canImport(CarPlay) && !os(macOS)
        func testCarPlaySceneUsesAppDelegateAdaptorBridgeUnderSwiftUIRuntime()
            throws
        {
            XCTAssertFalse(
                UIApplication.shared.delegate is BleatAppDelegate
            )
            let appDelegate = try XCTUnwrap(BleatAppDelegate.current)
            XCTAssertTrue(appDelegate.model === appDelegate.bootstrap.model)
        }

        func testCarPlayLoadingEmptyAndTypedFailureRoots() async throws {
            let loadingModel = AppModel(
                service: TestAppService(activeAccount: .success(nil))
            )
            let loadingPresenter = TestCarPlayPresenter()
            let loadingCoordinator = CarPlayCoordinator(model: loadingModel)
            loadingCoordinator.connect(loadingPresenter)
            let loadingRoot = try XCTUnwrap(
                loadingPresenter.root as? CPListTemplate
            )
            XCTAssertEqual(
                loadingRoot.emptyViewTitleVariants,
                ["Loading Bleat"]
            )
            XCTAssertTrue(loadingRoot.showsSpinnerWhileEmpty)
            loadingCoordinator.disconnect()

            let failureModel = AppModel(
                service: TestAppService(
                    activeAccount: .failure(
                        .accountStore(.persistenceFailed)
                    )
                )
            )
            await failureModel.start()
            let failurePresenter = TestCarPlayPresenter()
            let failureCoordinator = CarPlayCoordinator(model: failureModel)
            failureCoordinator.connect(failurePresenter)
            let failureRoot = try XCTUnwrap(
                failurePresenter.root as? CPListTemplate
            )
            XCTAssertEqual(
                failureRoot.emptyViewTitleVariants,
                ["Bleat unavailable"]
            )
            XCTAssertFalse(
                failureRoot.emptyViewSubtitleVariants.isEmpty
            )
            failureCoordinator.disconnect()

            let account = try fixtureAccount()
            let library = fixtureLibrary()
            let emptyModel = AppModel(
                service: TestAppService(
                    activeAccount: .success(account),
                    libraries: .success([library]),
                    firstPage: .success(
                        LibraryItemsPage(
                            items: [],
                            total: 0,
                            page: 0,
                            limit: 50
                        )
                    ),
                    homeShelves: .success([])
                )
            )
            await emptyModel.start()
            let emptyPresenter = TestCarPlayPresenter()
            let emptyCoordinator = CarPlayCoordinator(model: emptyModel)
            emptyCoordinator.connect(emptyPresenter)
            let emptyRoot = try XCTUnwrap(
                emptyPresenter.root as? CPTabBarTemplate
            )
            let home = try XCTUnwrap(
                emptyRoot.templates[0] as? CPListTemplate
            )
            let libraryTemplate = try XCTUnwrap(
                emptyRoot.templates[1] as? CPListTemplate
            )
            XCTAssertEqual(
                home.emptyViewTitleVariants,
                ["Nothing to play"]
            )
            XCTAssertEqual(
                libraryTemplate.emptyViewTitleVariants,
                ["No audiobooks"]
            )
            emptyCoordinator.disconnect()
        }

        func testCarPlaySignedOutRootDirectsUserToPhone() async {
            let model = AppModel(
                service: TestAppService(activeAccount: .success(nil))
            )
            await model.start()
            let presenter = TestCarPlayPresenter()
            let coordinator = CarPlayCoordinator(model: model)

            coordinator.connect(presenter)
            coordinator.refreshTemplates()

            let root = try? XCTUnwrap(
                presenter.root as? CPListTemplate
            )
            XCTAssertEqual(root?.title, "Downloads")
            XCTAssertEqual(
                root?.emptyViewTitleVariants,
                ["No downloads"]
            )
            XCTAssertEqual(
                root?.emptyViewSubtitleVariants,
                ["Open Bleat on iPhone to sign in."]
            )
            coordinator.disconnect()
        }

        func testCarPlaySignedInRootHasHomeLibraryAndDownloads()
            async throws
        {
            let account = try fixtureAccount()
            let library = fixtureLibrary()
            let service = TestAppService(
                activeAccount: .success(account),
                libraries: .success([library]),
                firstPage: .success(
                    fixturePage(libraryID: library.id)
                ),
                homeShelves: .success(
                    fixtureShelves(libraryID: library.id)
                )
            )
            let model = AppModel(service: service)
            await model.start()
            let presenter = TestCarPlayPresenter()
            let coordinator = CarPlayCoordinator(model: model)

            coordinator.connect(presenter)
            coordinator.refreshTemplates()

            let root = try XCTUnwrap(
                presenter.root as? CPTabBarTemplate
            )
            XCTAssertEqual(root.templates.count, 3)
            XCTAssertEqual(
                root.templates.compactMap(\.tabTitle),
                ["Home", "Library", "Downloads"]
            )
            let home = try XCTUnwrap(
                root.templates[0] as? CPListTemplate
            )
            let libraryTemplate = try XCTUnwrap(
                root.templates[1] as? CPListTemplate
            )
            XCTAssertEqual(home.sections.first?.header, "Continue Listening")
            XCTAssertEqual(home.sections.first?.items.count, 1)
            XCTAssertEqual(
                libraryTemplate.headerGridButtons?.map(\.titleVariants),
                [["Libraries"]]
            )
            XCTAssertTrue(home.trailingNavigationBarButtons.isEmpty)
            XCTAssertTrue(libraryTemplate.leadingNavigationBarButtons.isEmpty)
            XCTAssertTrue(libraryTemplate.trailingNavigationBarButtons.isEmpty)
            coordinator.disconnect()
        }

        func testCarPlayPresentationRetainsItemsAndSeedsReplacementArtwork()
            async throws
        {
            let imageData = try XCTUnwrap(
                UIGraphicsImageRenderer(
                    size: CGSize(width: 2, height: 2)
                ).image { context in
                    UIColor.systemGreen.setFill()
                    context.fill(
                        CGRect(x: 0, y: 0, width: 2, height: 2)
                    )
                }.pngData()
            )
            let fetcher = TestBookCoverFetcher(data: imageData)
            let loader = BookCoverImageLoader(
                diskCapacity: 0,
                fetch: { request in
                    try await fetcher.fetch(request)
                }
            )
            let account = try fixtureAccount()
            let library = fixtureLibrary()
            let secondLibrary = LibrarySummary(
                id: LibraryID(rawValue: "library-2"),
                name: "Second Library",
                mediaType: .book
            )
            let model = AppModel(
                service: TestAppService(
                    activeAccount: .success(account),
                    libraries: .success([library, secondLibrary]),
                    firstPage: .success(
                        fixturePage(libraryID: library.id)
                    ),
                    homeShelves: .success(
                        fixtureShelves(libraryID: library.id)
                    )
                )
            )
            await model.start()
            let presenter = TestCarPlayPresenter()
            let coordinator = CarPlayCoordinator(
                model: model,
                coverLoader: loader
            )
            coordinator.connect(presenter)

            let root = try XCTUnwrap(
                presenter.root as? CPTabBarTemplate
            )
            let home = try XCTUnwrap(
                root.templates[0] as? CPListTemplate
            )
            let item = try XCTUnwrap(
                home.sections.first?.items.first as? CPListItem
            )
            await waitForCoverRequests(fetcher, count: 1)
            for _ in 0..<100 {
                if item.image?.size == CGSize(width: 2, height: 2) {
                    break
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(
                item.image?.size,
                CGSize(width: 2, height: 2)
            )

            coordinator.refreshTemplates()

            let refreshedItem = try XCTUnwrap(
                home.sections.first?.items.first as? CPListItem
            )
            XCTAssertTrue(refreshedItem === item)
            XCTAssertEqual(
                refreshedItem.image?.size,
                CGSize(width: 2, height: 2)
            )

            await model.selectLibrary(secondLibrary)
            coordinator.refreshTemplates()

            let replacementItem = try XCTUnwrap(
                home.sections.first?.items.first as? CPListItem
            )
            XCTAssertFalse(replacementItem === item)
            XCTAssertEqual(
                replacementItem.image?.size,
                CGSize(width: 2, height: 2)
            )
            coordinator.disconnect()
        }

        func testCarPlayFailedPlaybackStartsOnceAndDoesNotPushNowPlaying()
            async throws
        {
            let account = try fixtureAccount()
            let library = fixtureLibrary()
            let book = fixturePage(libraryID: library.id).items[0]
            let service = TestAppService(
                activeAccount: .success(account),
                libraries: .success([library]),
                firstPage: .success(
                    fixturePage(libraryID: library.id)
                ),
                homeShelves: .success(
                    fixtureShelves(libraryID: library.id)
                ),
                bookDetail: .success(fixtureBookDetail(item: book)),
                playback: [
                    .failure(.playbackSession(.requestFailed))
                ]
            )
            let model = AppModel(service: service)
            await model.start()
            let presenter = TestCarPlayPresenter()
            let coordinator = CarPlayCoordinator(model: model)
            coordinator.connect(presenter)
            coordinator.refreshTemplates()
            let root = try XCTUnwrap(
                presenter.root as? CPTabBarTemplate
            )
            let home = try XCTUnwrap(
                root.templates[0] as? CPListTemplate
            )
            let item = try XCTUnwrap(
                home.sections.first?.items.first as? CPListItem
            )
            let completion = expectation(
                description: "CarPlay selection completed"
            )

            item.handler?(item) {
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)

            let playbackRequests = await service.playbackOpenRequests()
            XCTAssertEqual(playbackRequests.count, 1)
            XCTAssertFalse(
                presenter.pushed.contains {
                    $0 === CPNowPlayingTemplate.shared
                }
            )
            XCTAssertNotNil(presenter.presented as? CPAlertTemplate)
            coordinator.disconnect()
        }

        func testCarPlayLibraryPagingAndReconnectRemainDeterministic()
            async throws
        {
            let account = try fixtureAccount()
            let library = fixtureLibrary()
            let firstBook = fixtureBook(
                id: "item-1",
                title: "First",
                libraryID: library.id
            )
            let secondBook = fixtureBook(
                id: "item-2",
                title: "Second",
                libraryID: library.id
            )
            let service = TestAppService(
                activeAccount: .success(account),
                libraries: .success([library]),
                firstPage: .success(
                    LibraryItemsPage(
                        items: [firstBook],
                        total: 2,
                        page: 0,
                        limit: 1
                    )
                ),
                nextPage: .success(
                    LibraryItemsPage(
                        items: [secondBook],
                        total: 2,
                        page: 1,
                        limit: 1
                    )
                )
            )
            let model = AppModel(service: service)
            await model.start()
            let firstPresenter = TestCarPlayPresenter()
            let coordinator = CarPlayCoordinator(model: model)
            coordinator.connect(firstPresenter)
            coordinator.refreshTemplates()
            let root = try XCTUnwrap(
                firstPresenter.root as? CPTabBarTemplate
            )
            let libraryTemplate = try XCTUnwrap(
                root.templates[1] as? CPListTemplate
            )
            let loadMore = try XCTUnwrap(
                libraryTemplate.sections.first?.items.last
                    as? CPListItem
            )
            XCTAssertEqual(loadMore.text, "Load More")
            let completion = expectation(
                description: "CarPlay next page loaded"
            )
            loadMore.handler?(loadMore) {
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)
            XCTAssertEqual(
                libraryTemplate.sections.first?.items.map(\.text),
                ["First", "Second"]
            )

            coordinator.disconnect()
            let secondPresenter = TestCarPlayPresenter()
            coordinator.connect(secondPresenter)
            coordinator.refreshTemplates()
            XCTAssertNotNil(
                secondPresenter.root as? CPTabBarTemplate
            )
            XCTAssertTrue(firstPresenter.pushed.isEmpty)
            coordinator.disconnect()
        }

        func testCarPlayAccountAndLibraryChangesUseSharedBrowsingContext()
            async throws
        {
            let firstAccount = try fixtureAccount()
            let secondAccount = try fixtureAccount(
                accountID: "account-2",
                userID: "user-2",
                username: "other"
            )
            let firstLibrary = fixtureLibrary()
            let secondLibrary = LibrarySummary(
                id: LibraryID(rawValue: "library-2"),
                name: "Second Library",
                mediaType: .book
            )
            let service = TestAppService(
                accounts: .success([firstAccount, secondAccount]),
                activeAccount: .success(firstAccount),
                libraries: .success([firstLibrary, secondLibrary]),
                firstPage: .success(
                    fixturePage(libraryID: firstLibrary.id)
                )
            )
            let model = AppModel(service: service)
            await model.start()
            let presenter = TestCarPlayPresenter()
            let coordinator = CarPlayCoordinator(model: model)
            coordinator.connect(presenter)
            coordinator.refreshTemplates()
            let firstRoot = try XCTUnwrap(
                presenter.root as? CPTabBarTemplate
            )

            await model.selectLibrary(secondLibrary)
            coordinator.refreshTemplates()
            XCTAssertEqual(model.selectedLibrary, secondLibrary)
            let pageRequests = await service.pageRequests()
            XCTAssertEqual(pageRequests.last, secondLibrary.id)

            await model.switchAccount(to: secondAccount)
            coordinator.refreshTemplates()
            XCTAssertEqual(model.account, secondAccount)
            let activatedAccounts = await service.activatedAccounts()
            XCTAssertEqual(activatedAccounts, [secondAccount])
            let secondRoot = try XCTUnwrap(
                presenter.root as? CPTabBarTemplate
            )
            XCTAssertFalse(firstRoot === secondRoot)
            coordinator.disconnect()
        }

        func testCarPlayPermissionDenialDoesNotStartPlayback()
            async throws
        {
            let permissions = UserPermissions(
                download: false,
                update: false,
                delete: false,
                upload: false,
                createEReader: false,
                accessAllLibraries: true,
                accessAllTags: true,
                accessExplicitContent: false,
                selectedTagsNotAccessible: false
            )
            let account = try fixtureAccount(permissions: permissions)
            let library = fixtureLibrary()
            let book = fixtureBook(
                id: "explicit",
                title: "Restricted",
                libraryID: library.id,
                isExplicit: true
            )
            let service = TestAppService(
                activeAccount: .success(account),
                libraries: .success([library]),
                firstPage: .success(
                    LibraryItemsPage(
                        items: [book],
                        total: 1,
                        page: 0,
                        limit: 50
                    )
                ),
                homeShelves: .success([
                    LibraryBookShelf(
                        id: "restricted",
                        label: "Restricted",
                        labelLocalizationKey: nil,
                        items: [book],
                        total: 1
                    )
                ]),
                bookDetail: .success(fixtureBookDetail(item: book))
            )
            let model = AppModel(service: service)
            await model.start()
            let presenter = TestCarPlayPresenter()
            let coordinator = CarPlayCoordinator(model: model)
            coordinator.connect(presenter)
            coordinator.refreshTemplates()
            let root = try XCTUnwrap(
                presenter.root as? CPTabBarTemplate
            )
            let home = try XCTUnwrap(
                root.templates[0] as? CPListTemplate
            )
            let item = try XCTUnwrap(
                home.sections.first?.items.first as? CPListItem
            )
            let completion = expectation(
                description: "Denied selection completed"
            )
            item.handler?(item) {
                completion.fulfill()
            }
            await fulfillment(of: [completion], timeout: 2)

            let playbackRequests = await service.playbackOpenRequests()
            XCTAssertTrue(playbackRequests.isEmpty)
            XCTAssertNotNil(presenter.presented as? CPAlertTemplate)
            coordinator.disconnect()
        }

        func testCarPlayCompletedDownloadIsPreferredOnline()
            async throws
        {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "CarPlayCompleteDownload-\(UUID().uuidString)",
                    isDirectory: true
                )
            defer {
                try? FileManager.default.removeItem(at: root)
            }
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let account = try fixtureAccount()
            let library = fixtureLibrary()
            let book = fixturePage(libraryID: library.id).items[0]
            let detail = fixtureBookDetail(item: book)
            try await prepareCompleteDownload(
                root: root,
                account: account,
                detail: detail
            )

            let onlineService = TestAppService(
                activeAccount: .success(account),
                libraries: .success([library]),
                firstPage: .success(
                    fixturePage(libraryID: library.id)
                ),
                homeShelves: .success(
                    fixtureShelves(libraryID: library.id)
                ),
                bookDetail: .success(detail)
            )
            let onlineModel = AppModel(
                service: onlineService,
                downloadsStorageRootURL: root,
                downloadsBackgroundSessionIdentifier:
                    backgroundSessionIdentifier("carplay-complete-download")
            )
            await onlineModel.start()
            let onlinePresenter = TestCarPlayPresenter()
            let onlineCoordinator = CarPlayCoordinator(model: onlineModel)
            onlineCoordinator.connect(onlinePresenter)
            onlineCoordinator.refreshTemplates()
            let onlineRoot = try XCTUnwrap(
                onlinePresenter.root as? CPTabBarTemplate
            )
            let home = try XCTUnwrap(
                onlineRoot.templates[0] as? CPListTemplate
            )
            let remoteItem = try XCTUnwrap(
                home.sections.first?.items.first as? CPListItem
            )
            let onlineCompletion = expectation(
                description: "Online selection preferred download"
            )
            remoteItem.handler?(remoteItem) {
                onlineCompletion.fulfill()
            }
            await fulfillment(of: [onlineCompletion], timeout: 3)
            let onlinePlaybackRequests =
                await onlineService.playbackOpenRequests()
            XCTAssertTrue(onlinePlaybackRequests.isEmpty)
            XCTAssertTrue(
                onlinePresenter.pushed.contains {
                    $0 === CPNowPlayingTemplate.shared
                }
            )
            await onlineModel.playback.stop()
            onlineCoordinator.disconnect()
        }
    #endif

    private func fixtureAccount(
        accountID: String = "account-1",
        userID: String = "user-1",
        username: String = "reader",
        server: String = "https://books.example",
        authenticationMethods: [AuthenticationMethod] = [.local],
        permissions: UserPermissions? = nil,
        accessibleLibraryIDs: [LibraryID] = [],
        selectedItemTags: [String] = []
    ) throws -> ServerAccount {
        try ServerAccount(
            id: AccountID(rawValue: accountID),
            server: NormalizedServerURL(server),
            serverVersion: "2.36.0",
            authenticationMethods: authenticationMethods,
            user: AuthenticatedUser(
                id: UserID(rawValue: userID),
                username: username,
                type: .user,
                permissions: permissions
                    ?? UserPermissions(
                        download: true,
                        update: false,
                        delete: false,
                        upload: false,
                        createEReader: false,
                        accessAllLibraries: true,
                        accessAllTags: true,
                        accessExplicitContent: true,
                        selectedTagsNotAccessible: false
                    ),
                accessibleLibraryIDs: accessibleLibraryIDs,
                selectedItemTags: selectedItemTags
            )
        )
    }

    private func issue151Tracks(count: Int) -> [DownloadTrackPlan] {
        (0..<count).map { index in
            DownloadTrackPlan(
                index: index,
                inode: "issue-151-\(index)",
                expectedByteLength: 1,
                mimeType: "audio/mpeg",
                safeExtension: .mp3,
                destinationEntry: String(format: "%05d.mp3", index),
                startOffset: Double(index),
                duration: 1
            )
        }
    }

    private struct Issue151StageMeasurement<Value> {
        let value: Value
        let elapsedSeconds: Double
        let heartbeatCount: Int
        let maximumMainActorGap: Double
    }

    private func measureIssue151Stage<Value>(
        _ operation: @MainActor () async throws -> Value
    ) async rethrows -> Issue151StageMeasurement<Value> {
        var heartbeatCount = 0
        var maximumMainActorGap = 0.0
        var previousHeartbeat = ProcessInfo.processInfo.systemUptime
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                maximumMainActorGap = max(
                    maximumMainActorGap,
                    now - previousHeartbeat
                )
                previousHeartbeat = now
                heartbeatCount += 1
                await Task.yield()
            }
        }
        await Task.yield()
        heartbeatCount = 0
        maximumMainActorGap = 0
        previousHeartbeat = ProcessInfo.processInfo.systemUptime
        let start = previousHeartbeat
        do {
            let value = try await operation()
            let elapsedSeconds =
                ProcessInfo.processInfo.systemUptime - start
            await Task.yield()
            heartbeat.cancel()
            await heartbeat.value
            return Issue151StageMeasurement(
                value: value,
                elapsedSeconds: elapsedSeconds,
                heartbeatCount: heartbeatCount,
                maximumMainActorGap: maximumMainActorGap
            )
        } catch {
            heartbeat.cancel()
            await heartbeat.value
            throw error
        }
    }

    private func completeIssue151RepairTransfer(
        _ descriptor: DownloadChunkTaskDescription,
        model: DownloadModel,
        until completed: @MainActor () -> Bool
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue151RepairURLProtocol.self]
        let session = URLSession(
            configuration: configuration,
            delegate: model,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        let request = URLRequest(
            url: try XCTUnwrap(
                URL(string: "https://192.0.2.1/issue-151-repair")
            )
        )
        let task = session.downloadTask(with: request)
        task.taskDescription = try descriptor.encode()
        task.resume()
        for _ in 0..<500 {
            if completed(), task.state == .completed {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(completed())
        XCTAssertEqual(task.state, .completed)
    }

    private func completeIssue151Track(
        _ track: DownloadTrackPlan,
        downloadID: DownloadID,
        accountID: AccountID,
        itemID: LibraryItemID,
        root: URL,
        layout: DownloadStorageLayout,
        storage: DownloadStorage
    ) async throws {
        let identity = try DownloadTaskIdentity(
            downloadID: downloadID,
            accountID: accountID,
            itemID: itemID,
            track: track
        )
        let staged = root.appendingPathComponent(
            "staged-\(downloadID.rawValue)-\(track.index)"
        )
        try Data([UInt8(track.index % 256)]).write(to: staged)
        let observed = try layout.placeCompleteTestFile(
            from: staged,
            identity: identity
        )
        _ = try await storage.markComplete(
            identity,
            observedByteLength: observed
        )
    }

    private struct LocalDataLifecycleFixture {
        let rootURL: URL
        let storeURL: URL
        let downloadsURL: URL
        let modelContainer: ModelContainer
        let accounts: [ServerAccount]
        let tokenService: String
        let nativeLoginService: String
        let legacyService: String

        func makeCredentialStore() -> TokenVault {
            TokenVault(
                tokenService: tokenService,
                nativeLoginService: nativeLoginService,
                legacyService: legacyService,
                synchronizesNativeLogin: false
            )
        }
    }

    private struct LocalDataLifecycleOpenIDBrowser: OpenIDBrowserSession {
        func authenticate(
            at authorizationURL: URL,
            callbackScheme: String
        ) async throws -> URL {
            throw CancellationError()
        }
    }

    private func makeLocalDataLifecycleFixture()
        async throws -> LocalDataLifecycleFixture
    {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatLocalDataLifecycle-\(UUID().uuidString)",
                isDirectory: true
            )
        // ModelContainer has no explicit close operation. Keep the SQLite
        // fixture under the process-owned temporary directory so the OS can
        // reclaim it after the app-host test exits without unlinking an open
        // database.
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let storeURL = rootURL.appendingPathComponent("bleat.store")
        let downloadsURL = rootURL.appendingPathComponent(
            "Downloads",
            isDirectory: true
        )
        let modelContainer = try makeLocalDataLifecycleContainer(
            storeURL: storeURL
        )
        let first = try localDataLifecycleAccount(
            server: "https://127.0.0.1:1",
            userID: "lifecycle-user-1",
            username: "reader-a"
        )
        let second = try localDataLifecycleAccount(
            server: "https://127.0.0.1:2",
            userID: "lifecycle-user-2",
            username: "reader-b"
        )
        let accounts = [first, second]
        let accountStore = AccountStore(modelContainer: modelContainer)
        let libraryCache = LibraryCache(modelContainer: modelContainer)
        for (index, account) in accounts.enumerated() {
            try await accountStore.save(account, makeActive: index == 0)
            try await libraryCache.replaceLibraries([], for: account.id)
        }

        let serviceSuffix = UUID().uuidString.lowercased()
        let fixture = LocalDataLifecycleFixture(
            rootURL: rootURL,
            storeURL: storeURL,
            downloadsURL: downloadsURL,
            modelContainer: modelContainer,
            accounts: accounts,
            tokenService: "com.terminaloutcomes.Bleat.tests.tokens.\(serviceSuffix)",
            nativeLoginService:
                "com.terminaloutcomes.Bleat.tests.login.\(serviceSuffix)",
            legacyService:
                "com.terminaloutcomes.Bleat.tests.legacy.\(serviceSuffix)"
        )
        let credentialStore = fixture.makeCredentialStore()
        for account in accounts {
            try await credentialStore.save(
                AuthenticationTokens(
                    accessToken: "access-\(account.user.id.rawValue)",
                    refreshToken: "refresh-\(account.user.id.rawValue)"
                ),
                nativeLogin: NativeLoginCredentials(
                    userID: account.user.id,
                    username: account.user.username,
                    password: "password-\(account.user.id.rawValue)"
                ),
                for: account.id
            )
        }

        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let item = fixtureBook(
            id: plan.itemID.rawValue,
            title: "Lifecycle Download",
            libraryID: fixtureLibrary().id
        )
        let downloadStorage = DownloadStorage(
            layout: try DownloadStorageLayout(rootURL: downloadsURL)
        )
        for account in accounts {
            _ = try await downloadStorage.create(
                downloadID: DownloadID(
                    rawValue: UUID().uuidString.lowercased()
                ),
                accountID: account.id,
                plan: plan,
                detail: fixtureBookDetail(item: item)
            )
        }
        return fixture
    }

    private func makeLocalDataLifecycleContainer(
        storeURL: URL
    ) throws -> ModelContainer {
        let schema = Schema(
            versionedSchema: BleatPersistenceSchemaCurrent.self
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: BleatPersistenceSchemaMigrationPlan.self,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )
            ]
        )
    }

    private func makeLocalDataLifecycleService(
        modelContainer: ModelContainer,
        credentialStore: TokenVault
    ) throws -> LiveAppService {
        try LiveAppService(
            modelContainer: modelContainer,
            credentialStore: credentialStore,
            privateCloudAvailable: false,
            openIDBrowserProvider: {
                LocalDataLifecycleOpenIDBrowser()
            }
        )
    }

    private func localDataLifecycleAccount(
        server: String,
        userID: String,
        username: String
    ) throws -> ServerAccount {
        let normalizedServer = try NormalizedServerURL(server)
        let user = AuthenticatedUser(
            id: UserID(rawValue: userID),
            username: username,
            type: .user,
            permissions: UserPermissions(
                download: true,
                update: false,
                delete: false,
                upload: false,
                createEReader: false,
                accessAllLibraries: true,
                accessAllTags: true,
                accessExplicitContent: true,
                selectedTagsNotAccessible: false
            ),
            accessibleLibraryIDs: [],
            selectedItemTags: []
        )
        return try ServerAccount(
            id: AccountID.canonical(
                server: normalizedServer,
                userID: user.id
            ),
            server: normalizedServer,
            serverVersion: "2.36.0",
            authenticationMethods: [.local],
            user: user
        )
    }

    private func fixtureLibrary() -> LibrarySummary {
        LibrarySummary(
            id: LibraryID(rawValue: "library-1"),
            name: "Audiobooks",
            mediaType: .book
        )
    }

    private func fixtureProgress(
        userID: UserID,
        itemID: LibraryItemID,
        isFinished: Bool,
        lastUpdateMilliseconds: Int64 = 1
    ) -> LibraryBookProgress {
        LibraryBookProgress(
            id: "progress-\(itemID.rawValue)",
            userID: userID,
            libraryItemID: itemID,
            bookID: BookID(rawValue: "book-\(itemID.rawValue)"),
            duration: 60,
            progress: isFinished ? 1 : 0,
            currentTime: isFinished ? 60 : 0,
            isFinished: isFinished,
            hideFromContinueListening: false,
            lastUpdateMilliseconds: lastUpdateMilliseconds,
            startedAtMilliseconds: 1,
            finishedAtMilliseconds:
                isFinished ? lastUpdateMilliseconds : nil
        )
    }

    private func fixturePage(libraryID: LibraryID) -> LibraryItemsPage {
        LibraryItemsPage(
            items: [
                fixtureBook(
                    id: "item-1",
                    title: "A Book",
                    libraryID: libraryID
                )
            ],
            total: 1,
            page: 0,
            limit: 50
        )
    }

    private func fixtureBook(
        id: String,
        title: String,
        libraryID: LibraryID,
        isExplicit: Bool = false,
        authors: [LibraryBookContributor] = [],
        series: [LibraryBookSeries] = [],
        trackCount: Int = 1
    ) -> LibraryBookSummary {
        LibraryBookSummary(
            id: LibraryItemID(rawValue: id),
            libraryID: libraryID,
            title: title,
            subtitle: nil,
            authorName: authors.first?.name ?? "An Author",
            narratorName: "A Narrator",
            seriesName: series.first?.name,
            authors: authors,
            series: series,
            genres: ["Fiction"],
            publisher: nil,
            publishedYear: "2026",
            duration: 3_600,
            trackCount: trackCount,
            chapterCount: 2,
            addedAtMilliseconds: 1,
            updatedAtMilliseconds: 2,
            isExplicit: isExplicit,
            isAbridged: false
        )
    }

    private func fixtureBookDetail(
        item: LibraryBookSummary,
        authors: [LibraryBookContributor]? = nil,
        chapters: [PlaybackChapter] = [],
        tags: [String] = []
    ) -> LibraryBookDetail {
        LibraryBookDetail(
            id: item.id,
            libraryID: item.libraryID,
            bookID: BookID(rawValue: "book-1"),
            title: item.title,
            subtitle: "A subtitle",
            authors: authors ?? [
                LibraryBookContributor(
                    id: AuthorID(rawValue: "author-1")!,
                    name: "An Author"
                )
            ],
            narrators: ["A Narrator"],
            series: [],
            genres: item.genres,
            tags: tags,
            publishedYear: item.publishedYear,
            publishedDate: nil,
            publisher: item.publisher,
            descriptionPlain: "A detailed description.",
            isbn: nil,
            asin: nil,
            language: "English",
            duration: item.duration,
            trackCount: item.trackCount,
            audioFileCount: item.trackCount,
            chapters: chapters,
            addedAtMilliseconds: item.addedAtMilliseconds,
            updatedAtMilliseconds: item.updatedAtMilliseconds,
            isExplicit: item.isExplicit,
            isAbridged: item.isAbridged,
            progress: nil
        )
    }

    private func playbackPreparation(
        detail: LibraryBookDetail,
        audioURL: URL,
        sessionID: String = "playback-start-session"
    ) -> AppPlaybackPreparation {
        AppPlaybackPreparation(
            sessionID: PlaybackSessionID(rawValue: sessionID),
            itemID: detail.id,
            title: detail.title,
            duration: 1,
            currentTime: 0,
            chapters: detail.chapters,
            source: .direct([
                AppPlaybackTrack(
                    url: audioURL,
                    startOffset: 0,
                    duration: 1,
                    title: "Track 1"
                )
            ])
        )
    }

    private func makeTranscriptionModel(
        segments: [TranscriptSegment] = [
            TranscriptSegment(
                startMilliseconds: 0,
                endMilliseconds: 1_000,
                text: "transcribed text"
            )
        ],
        transcriberGate: AsyncGate? = nil,
        requestRecorder: ChapterTranscriptionRequestRecorder? = nil,
        remoteTelemetryTracer: any RemoteTelemetryTracing =
            InactiveRemoteTelemetryTracer()
    ) -> ChapterTranscriptionModel {
        ChapterTranscriptionModel(
            transcriptCacheReapInterval: .seconds(3_600),
            audioLoader: { _, _, _, _ in
                PreparedChapterTranscriptionAudio(
                    tracks: [
                        PreparedChapterTranscriptionTrack(
                            timeline: ChapterAudioTrack(
                                trackIndex: 0,
                                startOffsetSeconds: 0,
                                durationSeconds: 60
                            ),
                            url: FileManager.default.temporaryDirectory
                                .appendingPathComponent("test-audio.m4b")
                        )
                    ],
                    cachePin: nil
                )
            },
            transcriberFactory: {
                TestChapterTranscriber(
                    gate: transcriberGate,
                    segments: segments,
                    requestRecorder: requestRecorder
                )
            },
            remoteTelemetryTracer: remoteTelemetryTracer
        )
    }

    private func fixtureTranscript(
        chapter: PlaybackChapter,
        text: String
    ) -> CachedChapterTranscript {
        CachedChapterTranscript(
            chapterID: chapter.id,
            chapterTitle: chapter.title,
            chapterStartMilliseconds: Int64(chapter.start * 1_000),
            chapterEndMilliseconds: Int64(chapter.end * 1_000),
            localeIdentifier: "en_AU",
            segments: [
                CachedTranscriptSegment(
                    startMilliseconds: Int64(chapter.start * 1_000),
                    endMilliseconds: Int64(chapter.start * 1_000 + 1_000),
                    text: text
                )
            ]
        )
    }

    private func fixtureTranscript(
        chapter: PlaybackChapter,
        segments: [CachedTranscriptSegment]
    ) -> CachedChapterTranscript {
        CachedChapterTranscript(
            chapterID: chapter.id,
            chapterTitle: chapter.title,
            chapterStartMilliseconds: Int64(chapter.start * 1_000),
            chapterEndMilliseconds: Int64(chapter.end * 1_000),
            localeIdentifier: "en_AU",
            segments: segments
        )
    }

    private func fixtureTranscriptionTaskState(
        chapterIDs: [Int],
        completedChapterIDs: [Int],
        outcome: CachedChapterTranscriptionTaskOutcome,
        failure: CachedChapterTranscriptionTaskFailure?
    ) -> CachedChapterTranscriptionTaskState {
        let startedAt = Date(timeIntervalSince1970: 1_000)
        return CachedChapterTranscriptionTaskState(
            taskID: UUID(),
            selectedChapterIDs: chapterIDs,
            completedChapterIDs: completedChapterIDs,
            currentChapterID: chapterIDs.first,
            outcome: outcome,
            failure: failure,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(1),
            durationMilliseconds: 1_000
        )
    }

    private func waitForTranscriptionTerminalState(
        in coordinator: ChapterTranscriptionModel,
        bookKey: ChapterTranscriptionBookKey
    ) async -> CachedChapterTranscriptionTaskState? {
        for _ in 0..<100 {
            if let terminalState = coordinator.terminalState(for: bookKey) {
                return terminalState
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return coordinator.terminalState(for: bookKey)
    }

    private func waitForDifferentTranscriptionTerminalState(
        than taskID: UUID?,
        in coordinator: ChapterTranscriptionModel,
        bookKey: ChapterTranscriptionBookKey
    ) async -> CachedChapterTranscriptionTaskState? {
        for _ in 0..<100 {
            if let terminalState = coordinator.terminalState(for: bookKey),
                terminalState.taskID != taskID
            {
                return terminalState
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return coordinator.terminalState(for: bookKey)
    }

    private func waitForTranscriptionCacheFailure(
        _ failure: ChapterTranscriptCacheViewFailure,
        in coordinator: ChapterTranscriptionModel,
        bookKey: ChapterTranscriptionBookKey
    ) async {
        for _ in 0..<100 {
            if coordinator.cacheFailure(for: bookKey) == failure {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForTranscriptionTaskStateSaveAttempts(
        _ count: Int,
        in service: TestAppService
    ) async {
        for _ in 0..<100 {
            if await service.transcriptionTaskStateSaveAttemptCount() >= count {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func waitForTranscriptionTaskStateSaveCompletions(
        _ count: Int,
        in service: TestAppService
    ) async {
        for _ in 0..<100 {
            if await service.transcriptionTaskStateSaveCompletionCount()
                >= count
            {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func fixtureBookProgress(
        progress: Double,
        isFinished: Bool
    ) -> LibraryBookProgress {
        LibraryBookProgress(
            id: "progress-1",
            userID: UserID(rawValue: "user-1"),
            libraryItemID: LibraryItemID(rawValue: "item-1"),
            bookID: BookID(rawValue: "book-1"),
            duration: 100,
            progress: progress,
            currentTime: progress * 100,
            isFinished: isFinished,
            hideFromContinueListening: false,
            lastUpdateMilliseconds: 1,
            startedAtMilliseconds: 1,
            finishedAtMilliseconds: isFinished ? 1 : nil
        )
    }

    private func fixtureShelves(
        libraryID: LibraryID
    ) -> [LibraryBookShelf] {
        [
            LibraryBookShelf(
                id: "continue-listening",
                label: "Continue Listening",
                labelLocalizationKey: nil,
                items: fixturePage(libraryID: libraryID).items,
                total: 1
            )
        ]
    }

    private func prepareCompleteDownload(
        root: URL,
        account: ServerAccount,
        detail: LibraryBookDetail,
        purpose: DownloadPurpose = .manual,
        complete: Bool = true,
        includeTimelineMetadata: Bool = true
    ) async throws {
        let source = root.appendingPathComponent(
            "source.wav",
            isDirectory: false
        )
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 8_000,
                channels: 1
            )
        )
        do {
            let audioFile = try AVAudioFile(
                forWriting: source,
                settings: format.settings
            )
            let buffer = try XCTUnwrap(
                AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: 8_000
                )
            )
            buffer.frameLength = 8_000
            try audioFile.write(from: buffer)
        }
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: source.path
            )[.size] as? NSNumber
        ).int64Value
        let track = DownloadTrackPlan(
            index: 0,
            inode: "carplay-track",
            expectedByteLength: size,
            mimeType: "audio/wav",
            safeExtension: .wav,
            destinationEntry: "00000.wav",
            startOffset: includeTimelineMetadata ? 0 : nil,
            duration: includeTimelineMetadata ? 1 : nil
        )
        let plan = DownloadPlan(
            itemID: detail.id,
            tracks: [track]
        )
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        let downloadID = DownloadID(rawValue: "carplay-download")
        _ = try await storage.create(
            downloadID: downloadID,
            accountID: account.id,
            plan: plan,
            detail: detail,
            purpose: purpose,
            automaticTargetTrackIndexes:
                purpose == .automaticCache ? Set([0]) : nil
        )
        guard complete else {
            return
        }
        let identity = try DownloadTaskIdentity(
            downloadID: downloadID,
            accountID: account.id,
            itemID: detail.id,
            track: track
        )
        let staged = root.appendingPathComponent("staged.wav")
        try FileManager.default.copyItem(at: source, to: staged)
        let observed = try layout.placeCompleteTestFile(
            from: staged,
            identity: identity
        )
        _ = try await storage.markComplete(
            identity,
            observedByteLength: observed
        )
    }

    private func waitUntil(
        timeout: Duration,
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private static func fulfill(
        _ expectation: XCTestExpectation,
        when playback: PlaybackModel,
        reaches expectedPhase: CachedContinuationPhase
    ) {
        guard playback.cachedContinuationPhase != expectedPhase else {
            expectation.fulfill()
            return
        }
        withObservationTracking {
            _ = playback.cachedContinuationPhase
        } onChange: { [weak playback] in
            Task { @MainActor in
                guard let playback else { return }
                Self.fulfill(
                    expectation,
                    when: playback,
                    reaches: expectedPhase
                )
            }
        }
    }

    private func isFailed(_ state: PlaybackState) -> Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    private static func downloadPlanJSON(secondSize: Int) -> String {
        """
        {
          "id": "item-1",
          "media": {
            "audioFiles": [
              {
                "ino": "1",
                "mimeType": "audio/mpeg",
                "metadata": {"filename": "one.mp3", "size": 4}
              },
              {
                "ino": "2",
                "mimeType": "audio/mpeg",
                "metadata": {
                  "filename": "two.mp3",
                  "size": \(secondSize)
                }
              }
            ]
          }
        }
        """
    }

    private func localSession(
        id: String,
        itemID: String
    ) throws -> LocalPlaybackSession {
        try LocalPlaybackSession(
            id: PlaybackSessionID(rawValue: id),
            libraryID: LibraryID(rawValue: "library"),
            libraryItemID: LibraryItemID(rawValue: itemID),
            bookID: BookID(rawValue: "book-\(itemID)"),
            mediaMetadata: LocalPlaybackMediaMetadata(title: itemID),
            chapters: [],
            displayTitle: itemID,
            displayAuthor: "Author",
            duration: 100,
            startTime: 10,
            currentTime: 20,
            startedAtMilliseconds: 1_000,
            updatedAtMilliseconds: 2_000
        )
    }

    private func playbackRecoveryFixture() throws -> PlaybackRecoveryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatPlaybackRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let audioURL = root.appendingPathComponent("silence.caf")
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 8_000,
                channels: 1
            )
        )
        let audioFile = try AVAudioFile(
            forWriting: audioURL,
            settings: format.settings
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 8_000
            )
        )
        buffer.frameLength = 8_000
        try audioFile.write(from: buffer)

        let defaultsSuite = "PlaybackRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: defaultsSuite)
        )
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        return PlaybackRecoveryFixture(
            root: root,
            defaultsSuite: defaultsSuite,
            defaults: defaults,
            audioURL: audioURL,
            accountID: AccountID(rawValue: "recovery-account"),
            detail: fixtureBookDetail(item: item),
            service: TestAppService(activeAccount: .success(nil))
        )
    }
}

private struct TestSendableArtwork: @unchecked Sendable {
    let value: MPMediaItemArtwork

    init(_ value: MPMediaItemArtwork) {
        self.value = value
    }
}

private func nowPlayingSnapshot(
    accountID: AccountID?,
    coverURL: URL?,
    rate: Float = 1,
    isPlaying: Bool = true,
    isPlaybackRequested: Bool = true,
    isPlaybackAvailable: Bool = true
) -> NowPlayingSnapshot {
    NowPlayingSnapshot(
        accountID: accountID,
        itemID: LibraryItemID(rawValue: "item"),
        title: "Book",
        author: "",
        narrator: "",
        coverURL: coverURL,
        coverLoadPolicy: .allowNetwork,
        currentTime: 0,
        duration: 100,
        rate: rate,
        isPlaying: isPlaying,
        isPlaybackRequested: isPlaybackRequested,
        isPlaybackAvailable: isPlaybackAvailable,
        canPerformPreviousCommand: false,
        canPerformNextCommand: false,
        currentChapterIndex: nil,
        currentChapterTitle: nil,
        chapterCount: 0
    )
}

private func waitForCoverRequests(
    _ fetcher: TestBookCoverFetcher,
    count: Int
) async {
    for _ in 0..<100 {
        if await fetcher.requestCount >= count {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
private func waitForNowPlayingArtwork(
    in publisher: TestNowPlayingInfoPublisher
) async -> MPMediaItemArtwork? {
    for _ in 0..<100 {
        if let artwork =
            publisher.nowPlayingInfo?[
                MPMediaItemPropertyArtwork
            ] as? MPMediaItemArtwork
        {
            return artwork
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return nil
}

@MainActor
private final class TestNowPlayingInfoPublisher:
    NowPlayingInfoPublishing
{
    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .unknown
}

private actor TestBookCoverFetcher {
    let data: Data
    private var failingRequestCount: Int
    private(set) var requestCount = 0
    private(set) var requestHosts: [String] = []

    init(data: Data, failingRequestCount: Int = 0) {
        self.data = data
        self.failingRequestCount = max(0, failingRequestCount)
    }

    func fetch(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestCount += 1
        requestHosts.append(request.url?.host ?? "")
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: failingRequestCount > 0 ? 503 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/png"]
            )
        else {
            throw URLError(.badServerResponse)
        }
        failingRequestCount = max(0, failingRequestCount - 1)
        return (data, response)
    }
}

@MainActor
private final class TestAudioSessionActivation: @unchecked Sendable {
    private(set) var callCount = 0

    func activate() {
        callCount += 1
    }
}

@MainActor
private final class TestPlaybackQueuePlanning: @unchecked Sendable {
    private let failingCall: Int?
    private(set) var callCount = 0

    init(failingCall: Int? = nil) {
        self.failingCall = failingCall
    }

    func make(
        preparation: AppPlaybackPreparation,
        wholeBookTime: Double
    ) throws -> AppPlaybackQueuePlan {
        callCount += 1
        if callCount == failingCall {
            throw AppPlaybackBuildError.missingTracks
        }
        return try AppPlaybackQueuePlanner.make(
            preparation: preparation,
            wholeBookTime: wholeBookTime
        )
    }
}

@MainActor
private struct PlaybackRecoveryFixture {
    let root: URL
    let defaultsSuite: String
    let defaults: UserDefaults
    let audioURL: URL
    let accountID: AccountID
    let detail: LibraryBookDetail
    let service: TestAppService

    func model(
        activation: TestAudioSessionActivation,
        service: TestAppService? = nil,
        remoteTelemetryTracer: any RemoteTelemetryTracing =
            InactiveRemoteTelemetryTracer(),
        queuePlanning:
            @escaping @MainActor @Sendable (
                AppPlaybackPreparation,
                Double
            ) throws -> AppPlaybackQueuePlan = {
                try AppPlaybackQueuePlanner.make(
                    preparation: $0,
                    wholeBookTime: $1
                )
            }
    ) -> PlaybackModel {
        PlaybackModel(
            service: service ?? self.service,
            positionStore: PlaybackPositionStore(defaults: defaults),
            localSessionStore: LocalPlaybackSessionStore(defaults: defaults),
            bookmarkMutationStore: BookmarkMutationStore(
                defaults: defaults
            ),
            preferencesStore: PlaybackPreferencesStore(defaults: defaults),
            audioSessionActivation: {
                activation.activate()
            },
            queuePlanning: queuePlanning,
            remoteTelemetryTracer: remoteTelemetryTracer
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}

#if canImport(CarPlay) && !os(macOS)
    @MainActor
    private final class TestCarPlayPresenter: CarPlayPresenting {
        private(set) var root: CPTemplate?
        private(set) var pushed: [CPTemplate] = []
        private(set) var presented: CPTemplate?

        func setRoot(_ template: CPTemplate) {
            root = template
        }

        func push(_ template: CPTemplate) {
            pushed.append(template)
        }

        func pop() {
            _ = pushed.popLast()
        }

        func present(_ template: CPTemplate) {
            presented = template
        }

        func dismiss() {
            presented = nil
        }
    }
#endif

private struct LoginRequest: Equatable, Sendable {
    let serverAddress: String
    let username: String
    let password: String
}

private struct ReauthenticationRequest: Equatable, Sendable {
    let accountID: AccountID
    let password: String
}

private struct AccountUpdateRequest: Equatable, Sendable {
    let accountID: AccountID
    let serverAddress: String
    let localServerAddress: String
    let username: String
    let password: String
    let localServerValidation: LocalServerValidationPolicy
}

private struct PlaybackOpenRequest: Equatable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
    let preference: PlaybackPreference
}

private struct SearchRequest: Equatable, Sendable {
    let accountID: AccountID
    let libraryID: LibraryID
    let query: String
}

private struct PageSelection: Equatable, Sendable {
    let page: Int
    let sort: LibraryItemSort
    let descending: Bool
    let filter: LibraryItemFilter?
    let collapseSeries: Bool
    let minified: Bool

    init(
        page: Int,
        sort: LibraryItemSort,
        descending: Bool,
        filter: LibraryItemFilter?,
        collapseSeries: Bool = true,
        minified: Bool = true
    ) {
        self.page = page
        self.sort = sort
        self.descending = descending
        self.filter = filter
        self.collapseSeries = collapseSeries
        self.minified = minified
    }
}

private struct BookDetailRequest: Equatable, Sendable {
    let accountID: AccountID
    let libraryID: LibraryID
    let itemID: LibraryItemID
}

private struct BookmarkRequest: Equatable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
}

private struct MetadataSaveRequest: Equatable, Sendable {
    let accountID: AccountID
    let baseline: LibraryBookDetail
    let draft: BookMetadataDraft
    let overwrite: Bool
}

private struct CoverReplacementRequest: Equatable, Sendable {
    let accountID: AccountID
    let detail: LibraryBookDetail
    let jpegData: Data
}

private struct BookDeletionRequest: Equatable, Sendable {
    let accountID: AccountID
    let detail: LibraryBookDetail
    let mode: BookDeletionMode
}

private struct ProgressUpdateRequest: Equatable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
    let update: BookProgressUpdate
}

private struct LocalSessionSyncRequest: Equatable, Sendable {
    let accountID: AccountID
    let sessions: [LocalPlaybackSession]
    let deviceInfo: PlaybackDeviceInfo
}

private enum TranscriptPersistenceEvent: Equatable {
    case transcriptSaved(ChapterTranscriptionBookKey)
    case taskStateSaved(ChapterTranscriptionBookKey)
    case deleted(ChapterTranscriptionBookKey)
}

private actor TestAppService: AppServicing {
    private var accountsResult: Result<[ServerAccount], AppServiceError>?
    private var activeAccountResult:
        Result<
            ServerAccount?,
            AppServiceError
        >
    private var loginResult: Result<ServerAccount, AppServiceError>
    private var accountUpdateOutcomes: [AccountUpdateServiceOutcome] = []
    private var librariesResult:
        Result<
            [LibrarySummary],
            AppServiceError
        >
    private var firstPageResult:
        Result<
            LibraryItemsPage,
            AppServiceError
        >
    private var nextPageResult:
        Result<
            LibraryItemsPage,
            AppServiceError
        >
    /// Optional closure returning a synthetic page for a given zero-based
    /// page index, used by the performance suite to page through a large
    /// generated dataset without a server. When set, `page(...)` returns
    /// `pagedProvider(request.page)` for every request, including page 0.
    private let pagedProvider:
        (@Sendable (Int) -> Result<LibraryItemsPage, AppServiceError>)?
    private let asyncPageProvider:
        (@Sendable (LibraryID, LibraryItemsPageRequest) async -> Result<
            LibraryItemsPage, AppServiceError
        >)?
    private var homeShelvesResult:
        Result<
            [LibraryBookShelf],
            AppServiceError
        >
    private var searchResult:
        Result<
            LibrarySearchResults,
            AppServiceError
        >
    private var queuedSearchResults:
        [Result<LibrarySearchResults, AppServiceError>] = []
    private var searchRequestGates: [AsyncGate] = []
    private var bookDetailResult:
        Result<
            LibraryBookDetail,
            AppServiceError
        >
    private var refreshedBookDetailResult:
        Result<LibraryBookDetail, AppServiceError>?
    private var queuedBookDetailResults:
        [Result<LibraryBookDetail, AppServiceError>] = []
    private var bookDetailRequestGates: [AsyncGate] = []
    private var bookmarksResult:
        Result<
            [AudioBookmark],
            AppServiceError
        >
    private var metadataSaveResult:
        Result<AppMetadataSaveOutcome, AppServiceError>?
    private var coverReplacementResult:
        Result<LibraryBookDetail, AppServiceError>?
    private var coverReplacementGate: AsyncGate?
    private var bookDeletionResult:
        Result<AppBookDeletionOutcome, AppServiceError>
    private var progressUpdateResult: Result<Void, AppServiceError>
    private var allBookProgressResults:
        [Result<[LibraryBookProgress], AppServiceError>]
    private var localSessionSyncResult:
        Result<[LocalPlaybackSessionSyncResult], AppServiceError>
    private var playbackResults:
        [Result<AppPlaybackPreparation, AppServiceError>]
    private var downloadPlanResult: Result<DownloadPlan, AppServiceError>?
    private let downloadPlanProvider:
        (@Sendable (LibraryItemID) -> Result<DownloadPlan, AppServiceError>)?
    private var downloadPlanGate: AsyncGate?
    private let authorizedDownloadRequestResult:
        Result<URLRequest, AppServiceError>?
    private let primaryFallbackURL: URL?
    private var removeAccountResult: Result<Void, AppServiceError>
    private var localDataResetResult: Result<Void, AppServiceError>
    private var privateCloudSyncSettingResult:
        Result<Void, AppServiceError>
    private let loginGate: AsyncGate?
    private let accountUpdateGate: AsyncGate?
    private let removeGate: AsyncGate?
    private let localDataResetGate: AsyncGate?
    private let searchGate: AsyncGate?
    private let serverEndpointRouterGate: AsyncGate?
    private let privateCloudSyncGate: AsyncGate?
    private let accountsGate: AsyncGate?
    private let activeAccountGate: AsyncGate?
    private let bookmarksGate: AsyncGate?
    private let bookProgressGate: AsyncGate?
    private let firstAllBookProgressGate: AsyncGate?
    private let localSessionSyncGate: AsyncGate?
    private let bookDetailGate: AsyncGate?
    private let progressUpdateGate: AsyncGate?
    private let playbackGate: AsyncGate?
    private let playbackCloseGate: AsyncGate?
    private let statisticsFinishGate: AsyncGate?
    private let statisticsSummaryGate: AsyncGate?
    private let browsePageGate: AsyncGate?
    private let browsePageGateFilter: LibraryItemFilter?
    private let refreshPageGate: AsyncGate?
    private let homeShelvesRefreshGate: AsyncGate?
    private let transcriptLoadGate: AsyncGate?
    private let transcriptSaveGate: AsyncGate?
    private let transcriptLoadResult:
        Result<[CachedChapterTranscript], AppServiceError>
    private let transcriptSaveResult: Result<Void, AppServiceError>
    private let transcriptDataPresenceResult: Result<Bool, AppServiceError>
    private let transcriptDeletionResult: Result<Void, AppServiceError>
    private let transcriptDeletionGate: AsyncGate?
    private let transcriptionTaskStateLoadResult:
        Result<CachedChapterTranscriptionTaskState?, AppServiceError>
    private let firstTranscriptionTaskStateSaveGate: AsyncGate?
    private let transcriptionTaskStateSaveResults:
        [Result<Void, AppServiceError>]
    private let privateCloudSyncAvailable: Bool
    private var privateCloudSyncEnabled = true
    private var privateCloudSyncResult:
        Result<[CloudServerConfigurationChange], AppServiceError>
    private var privateCloudConfigurationConflict: CloudConfigurationConflict?
    private let configuredEndpointDiagnostics: AppEndpointDiagnostics?
    private var endpointDiagnosticsContinuations:
        [UUID:
            AsyncStream<AppEndpointDiagnostics>.Continuation] = [:]
    private var networkPathContinuations:
        [UUID: AsyncStream<AppNetworkPathState>.Continuation] = [:]
    private var liveUpdatesContinuation:
        AsyncStream<AudiobookshelfLiveUpdate>.Continuation?
    private var liveUpdatesToken: UUID?
    private var liveUpdatesStartCount = 0
    private var liveUpdatesStopCount = 0

    private var activeAccountRequests = 0
    private var libraryRequests = 0
    private var recordedActivatedAccounts: [ServerAccount] = []
    private var recordedLogins: [LoginRequest] = []
    private var recordedOpenIDLogins: [String] = []
    private var recordedReauthentications: [ReauthenticationRequest] = []
    private var recordedOpenIDReauthentications: [AccountID] = []
    private var recordedAccountUpdates: [AccountUpdateRequest] = []
    private var recordedPageRequests: [LibraryID] = []
    private var recordedPageSelections: [PageSelection] = []
    private var recordedHomeRequests: [LibraryID] = []
    private var recordedSearchRequests: [SearchRequest] = []
    private var recordedBookDetailRequests: [BookDetailRequest] = []
    private var recordedRefreshedBookDetailRequests: [BookDetailRequest] = []
    private var recordedPlaybackOpenRequests: [PlaybackOpenRequest] = []
    private var recordedPlaybackCloseSessionIDs: [PlaybackSessionID] = []
    private var recordedPlaybackSyncSessionIDs: [PlaybackSessionID] = []
    private var recordedBookmarkRequests: [BookmarkRequest] = []
    private var recordedBookProgressRequests: [LibraryItemID] = []
    private var recordedAllBookProgressRequests: [AccountID] = []
    private var recordedMetadataSaveRequests: [MetadataSaveRequest] = []
    private var recordedCoverReplacementRequests: [CoverReplacementRequest] = []
    private var recordedBookDeletionRequests: [BookDeletionRequest] = []
    private var recordedProgressUpdateRequests: [ProgressUpdateRequest] = []
    private var recordedLocalSessionSyncRequests: [LocalSessionSyncRequest] = []
    private var recordedDownloadPlanRequests: [LibraryItemID] = []
    private var recordedAuthorizedDownloadRequests: [DownloadTaskIdentity] = []
    private var recordedRemovedAccounts: [ServerAccount] = []
    private var localDataResetRequests = 0
    private var recordedSavedTranscripts: [CachedChapterTranscript] = []
    private var deletedTranscriptBooks: Set<ChapterTranscriptionBookKey> = []
    private var recordedTranscriptDeletionRequests:
        [ChapterTranscriptionBookKey] = []
    private var transcriptPersistenceEvents:
        [TranscriptPersistenceEvent] = []
    private var recordedForcedCloudAccounts: [ServerAccount] = []
    private var privateCloudCancellationRequests = 0
    private var recordedPrivateCloudSyncSettingRequests:
        [(enabled: Bool, deleteCloudData: Bool)] = []
    private var privateCloudSynchronizationRequests = 0
    private var recordedCloudResolutions:
        [(accountID: AccountID, accept: Bool)] = []
    private var recordedCloudConfigurationResolutions:
        [CloudConfigurationConflictResolution] = []
    private var recordedTranscriptionTaskStates:
        [CachedChapterTranscriptionTaskState] = []
    private var transcriptionTaskStateSaveAttempts = 0
    private var transcriptionTaskStateSaveCompletions = 0

    func discoverServer(
        serverAddress: String
    ) async throws(AppServiceError) -> DiscoveredServer {
        throw .discoveryRequestFailed
    }

    func liveUpdates(
        for account: ServerAccount
    ) -> AsyncStream<AudiobookshelfLiveUpdate> {
        liveUpdatesStartCount += 1
        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudiobookshelfLiveUpdate.self
        )
        liveUpdatesToken = token
        liveUpdatesContinuation = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.liveUpdatesDidTerminate(token: token)
            }
        }
        return stream
    }

    func stopLiveUpdates(for accountID: AccountID) async {
        guard let token = liveUpdatesToken else {
            return
        }
        liveUpdatesContinuation?.finish()
        liveUpdatesDidTerminate(token: token)
    }

    private func liveUpdatesDidTerminate(token: UUID) {
        guard liveUpdatesToken == token else {
            return
        }
        liveUpdatesStopCount += 1
        liveUpdatesToken = nil
        liveUpdatesContinuation = nil
    }

    func hasLiveUpdatesSubscriber() -> Bool {
        liveUpdatesContinuation != nil
    }

    func liveUpdatesLifecycleCounts() -> (starts: Int, stops: Int) {
        (liveUpdatesStartCount, liveUpdatesStopCount)
    }

    func emitLiveUpdate(_ update: AudiobookshelfLiveUpdate) {
        liveUpdatesContinuation?.yield(update)
    }

    init(
        accounts: Result<[ServerAccount], AppServiceError>? = nil,
        activeAccount: Result<ServerAccount?, AppServiceError>,
        login: Result<ServerAccount, AppServiceError> = .failure(
            .onboarding(.authenticationRequestFailed)
        ),
        libraries: Result<[LibrarySummary], AppServiceError> = .success([]),
        firstPage: Result<LibraryItemsPage, AppServiceError> = .failure(
            .libraryRepository(.noCachedValue)
        ),
        nextPage: Result<LibraryItemsPage, AppServiceError> = .failure(
            .libraryRepository(.noCachedValue)
        ),
        pagedProvider:
            (@Sendable (Int) -> Result<LibraryItemsPage, AppServiceError>)? =
            nil,
        asyncPageProvider:
            (@Sendable (LibraryID, LibraryItemsPageRequest) async -> Result<
                LibraryItemsPage, AppServiceError
            >)? = nil,
        homeShelves: Result<[LibraryBookShelf], AppServiceError> = .success(
            []
        ),
        search: Result<[LibraryBookSummary], AppServiceError> = .failure(
            .searchCoordinator(.repository(.noCachedValue))
        ),
        bookDetail: Result<LibraryBookDetail, AppServiceError> = .failure(
            .bookDetail(.noCachedValue)
        ),
        bookmarks: Result<[AudioBookmark], AppServiceError> = .success([]),
        metadataSave:
            Result<AppMetadataSaveOutcome, AppServiceError>? = nil,
        coverReplacement:
            Result<LibraryBookDetail, AppServiceError>? = nil,
        bookDeletion:
            Result<AppBookDeletionOutcome, AppServiceError> = .success(
                .deleted
            ),
        progressUpdate: Result<Void, AppServiceError> = .success(()),
        allBookProgress:
            [Result<[LibraryBookProgress], AppServiceError>] = [.success([])],
        localSessionSync:
            Result<
                [LocalPlaybackSessionSyncResult],
                AppServiceError
            > = .success([]),
        playback:
            [Result<AppPlaybackPreparation, AppServiceError>] = [],
        downloadPlan: Result<DownloadPlan, AppServiceError>? = nil,
        downloadPlanProvider:
            (@Sendable (LibraryItemID) -> Result<
                DownloadPlan, AppServiceError
            >)? = nil,
        authorizedDownloadRequest:
            Result<URLRequest, AppServiceError>? = nil,
        primaryFallbackURL: URL? = nil,
        removeAccount: Result<Void, AppServiceError> = .success(()),
        localDataReset: Result<Void, AppServiceError> = .success(()),
        privateCloudSyncSetting:
            Result<Void, AppServiceError> = .success(()),
        loginGate: AsyncGate? = nil,
        accountUpdateGate: AsyncGate? = nil,
        removeGate: AsyncGate? = nil,
        localDataResetGate: AsyncGate? = nil,
        searchGate: AsyncGate? = nil,
        serverEndpointRouterGate: AsyncGate? = nil,
        privateCloudSyncGate: AsyncGate? = nil,
        accountsGate: AsyncGate? = nil,
        activeAccountGate: AsyncGate? = nil,
        bookmarksGate: AsyncGate? = nil,
        bookProgressGate: AsyncGate? = nil,
        firstAllBookProgressGate: AsyncGate? = nil,
        localSessionSyncGate: AsyncGate? = nil,
        bookDetailGate: AsyncGate? = nil,
        progressUpdateGate: AsyncGate? = nil,
        playbackGate: AsyncGate? = nil,
        playbackCloseGate: AsyncGate? = nil,
        statisticsFinishGate: AsyncGate? = nil,
        statisticsSummaryGate: AsyncGate? = nil,
        browsePageGate: AsyncGate? = nil,
        browsePageGateFilter: LibraryItemFilter? = nil,
        refreshPageGate: AsyncGate? = nil,
        homeShelvesRefreshGate: AsyncGate? = nil,
        transcriptLoadGate: AsyncGate? = nil,
        transcriptSaveGate: AsyncGate? = nil,
        transcriptLoad:
            Result<[CachedChapterTranscript], AppServiceError> = .success([]),
        transcriptSave: Result<Void, AppServiceError> = .success(()),
        transcriptDataPresence: Result<Bool, AppServiceError> = .success(
            false
        ),
        transcriptDeletion: Result<Void, AppServiceError> = .success(()),
        transcriptDeletionGate: AsyncGate? = nil,
        transcriptionTaskStateLoad:
            Result<CachedChapterTranscriptionTaskState?, AppServiceError> =
            .success(nil),
        firstTranscriptionTaskStateSaveGate: AsyncGate? = nil,
        transcriptionTaskStateSaveResults:
            [Result<Void, AppServiceError>] = [],
        privateCloudSyncAvailable: Bool = true,
        privateCloudSyncChanges: [CloudServerConfigurationChange] = [],
        privateCloudConfigurationConflict: CloudConfigurationConflict? = nil,
        privateCloudSyncResult:
            Result<[CloudServerConfigurationChange], AppServiceError>? = nil,
        endpointDiagnostics: AppEndpointDiagnostics? = nil
    ) {
        accountsResult = accounts
        activeAccountResult = activeAccount
        loginResult = login
        librariesResult = libraries
        firstPageResult = firstPage
        nextPageResult = nextPage
        self.pagedProvider = pagedProvider
        self.asyncPageProvider = asyncPageProvider
        homeShelvesResult = homeShelves
        searchResult = search.map { LibrarySearchResults(books: $0) }
        bookDetailResult = bookDetail
        bookmarksResult = bookmarks
        metadataSaveResult = metadataSave
        coverReplacementResult = coverReplacement
        bookDeletionResult = bookDeletion
        progressUpdateResult = progressUpdate
        allBookProgressResults = allBookProgress
        localSessionSyncResult = localSessionSync
        playbackResults = playback
        downloadPlanResult = downloadPlan
        self.downloadPlanProvider = downloadPlanProvider
        authorizedDownloadRequestResult = authorizedDownloadRequest
        self.primaryFallbackURL = primaryFallbackURL
        removeAccountResult = removeAccount
        localDataResetResult = localDataReset
        privateCloudSyncSettingResult = privateCloudSyncSetting
        self.loginGate = loginGate
        self.accountUpdateGate = accountUpdateGate
        self.removeGate = removeGate
        self.localDataResetGate = localDataResetGate
        self.searchGate = searchGate
        self.serverEndpointRouterGate = serverEndpointRouterGate
        self.privateCloudSyncGate = privateCloudSyncGate
        self.accountsGate = accountsGate
        self.activeAccountGate = activeAccountGate
        self.bookmarksGate = bookmarksGate
        self.bookProgressGate = bookProgressGate
        self.firstAllBookProgressGate = firstAllBookProgressGate
        self.localSessionSyncGate = localSessionSyncGate
        self.bookDetailGate = bookDetailGate
        self.progressUpdateGate = progressUpdateGate
        self.playbackGate = playbackGate
        self.playbackCloseGate = playbackCloseGate
        self.statisticsFinishGate = statisticsFinishGate
        self.statisticsSummaryGate = statisticsSummaryGate
        self.browsePageGate = browsePageGate
        self.browsePageGateFilter = browsePageGateFilter
        self.refreshPageGate = refreshPageGate
        self.homeShelvesRefreshGate = homeShelvesRefreshGate
        self.transcriptLoadGate = transcriptLoadGate
        self.transcriptSaveGate = transcriptSaveGate
        transcriptLoadResult = transcriptLoad
        transcriptSaveResult = transcriptSave
        transcriptDataPresenceResult = transcriptDataPresence
        transcriptDeletionResult = transcriptDeletion
        self.transcriptDeletionGate = transcriptDeletionGate
        transcriptionTaskStateLoadResult = transcriptionTaskStateLoad
        self.firstTranscriptionTaskStateSaveGate =
            firstTranscriptionTaskStateSaveGate
        self.transcriptionTaskStateSaveResults =
            transcriptionTaskStateSaveResults
        self.privateCloudSyncAvailable = privateCloudSyncAvailable
        self.privateCloudSyncResult =
            privateCloudSyncResult
            ?? .success(privateCloudSyncChanges)
        self.privateCloudConfigurationConflict =
            privateCloudConfigurationConflict
        configuredEndpointDiagnostics = endpointDiagnostics
    }

    func isPrivateCloudSyncAvailable() async -> Bool {
        privateCloudSyncAvailable
    }

    func isPrivateCloudSyncEnabled() async -> Bool {
        privateCloudSyncEnabled
    }

    func cachedChapterTranscripts(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [CachedChapterTranscript] {
        let bookKey = ChapterTranscriptionBookKey(
            accountID: accountID,
            itemID: itemID
        )
        guard !deletedTranscriptBooks.contains(bookKey) else {
            return []
        }
        let result = transcriptLoadResult
        if let transcriptLoadGate {
            await transcriptLoadGate.enterAndWait()
        }
        return try value(from: result)
    }

    func saveCachedChapterTranscript(
        _ transcript: CachedChapterTranscript,
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) {
        if let transcriptSaveGate {
            await transcriptSaveGate.enterAndWait()
        }
        try value(from: transcriptSaveResult)
        recordedSavedTranscripts.append(transcript)
        transcriptPersistenceEvents.append(
            .transcriptSaved(
                ChapterTranscriptionBookKey(
                    accountID: accountID,
                    itemID: itemID
                )
            )
        )
    }

    func cachedChapterTranscriptionTaskState(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> CachedChapterTranscriptionTaskState? {
        let bookKey = ChapterTranscriptionBookKey(
            accountID: accountID,
            itemID: itemID
        )
        guard !deletedTranscriptBooks.contains(bookKey) else {
            return nil
        }
        return try value(from: transcriptionTaskStateLoadResult)
    }

    func saveCachedChapterTranscriptionTaskState(
        _ state: CachedChapterTranscriptionTaskState,
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) {
        defer {
            transcriptionTaskStateSaveCompletions += 1
        }
        let attempt = transcriptionTaskStateSaveAttempts
        transcriptionTaskStateSaveAttempts += 1
        if attempt == 0, let firstTranscriptionTaskStateSaveGate {
            await firstTranscriptionTaskStateSaveGate.enterAndWait()
        }
        if transcriptionTaskStateSaveResults.indices.contains(attempt) {
            try value(from: transcriptionTaskStateSaveResults[attempt])
        }
        recordedTranscriptionTaskStates.append(state)
        transcriptPersistenceEvents.append(
            .taskStateSaved(
                ChapterTranscriptionBookKey(
                    accountID: accountID,
                    itemID: itemID
                )
            )
        )
    }

    func hasCachedChapterTranscriptData(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> Bool {
        let bookKey = ChapterTranscriptionBookKey(
            accountID: accountID,
            itemID: itemID
        )
        guard !deletedTranscriptBooks.contains(bookKey) else {
            return false
        }
        return try value(from: transcriptDataPresenceResult)
    }

    func deleteCachedChapterTranscriptData(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) {
        if let transcriptDeletionGate {
            await transcriptDeletionGate.enterAndWait()
        }
        try value(from: transcriptDeletionResult)
        let bookKey = ChapterTranscriptionBookKey(
            accountID: accountID,
            itemID: itemID
        )
        recordedTranscriptDeletionRequests.append(bookKey)
        deletedTranscriptBooks.insert(bookKey)
        transcriptPersistenceEvents.append(.deleted(bookKey))
    }

    func transcriptDeletionRequests() -> [ChapterTranscriptionBookKey] {
        recordedTranscriptDeletionRequests
    }

    func recordedTranscriptPersistenceEvents()
        -> [TranscriptPersistenceEvent]
    {
        transcriptPersistenceEvents
    }

    func transcriptionTaskStateSaveAttemptCount() -> Int {
        transcriptionTaskStateSaveAttempts
    }

    func transcriptionTaskStateSaveCompletionCount() -> Int {
        transcriptionTaskStateSaveCompletions
    }

    func savedTranscripts() -> [CachedChapterTranscript] {
        recordedSavedTranscripts
    }

    func savedTranscriptionTaskStates()
        -> [CachedChapterTranscriptionTaskState]
    {
        recordedTranscriptionTaskStates
    }

    func serverEndpointRouter() async -> ServerEndpointRouter? {
        if let serverEndpointRouterGate {
            await serverEndpointRouterGate.enterAndWait()
        }
        return nil
    }

    func networkPathUpdates() async -> AsyncStream<AppNetworkPathState> {
        AsyncStream { continuation in
            let token = UUID()
            networkPathContinuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeNetworkPathContinuation(token)
                }
            }
        }
    }

    func primaryFallbackDownloadRequest(
        for failedRequest: URLRequest
    ) async -> URLRequest? {
        guard let primaryFallbackURL else {
            return nil
        }
        var request = failedRequest
        request.url = primaryFallbackURL
        return request
    }

    func emitNetworkPathUpdate(
        _ state: AppNetworkPathState = AppNetworkPathState(
            availability: .satisfied,
            isConstrained: false,
            isExpensive: false
        )
    ) {
        for continuation in networkPathContinuations.values {
            continuation.yield(state)
        }
    }

    func networkPathObserverCount() -> Int {
        networkPathContinuations.count
    }

    private func removeNetworkPathContinuation(_ token: UUID) {
        networkPathContinuations[token] = nil
    }

    func synchronizePrivateCloud() async throws(AppServiceError)
        -> [CloudServerConfigurationChange]
    {
        privateCloudSynchronizationRequests += 1
        if let privateCloudSyncGate {
            await privateCloudSyncGate.enterAndWait()
        }
        return try value(from: privateCloudSyncResult)
    }

    func cancelPrivateCloudSynchronization() async {
        privateCloudCancellationRequests += 1
        await privateCloudSyncGate?.release()
    }

    func setPrivateCloudSyncEnabled(
        _ enabled: Bool,
        deleteCloudData: Bool
    ) async throws(AppServiceError) {
        recordedPrivateCloudSyncSettingRequests.append(
            (enabled, deleteCloudData)
        )
        try value(from: privateCloudSyncSettingResult)
        privateCloudSyncEnabled = enabled
    }

    func privateCloudSyncSettingRequests()
        -> [(enabled: Bool, deleteCloudData: Bool)]
    {
        recordedPrivateCloudSyncSettingRequests
    }

    func privateCloudSynchronizationRequestCount() -> Int {
        privateCloudSynchronizationRequests
    }

    func pendingPrivateCloudConfigurationConflict() async
        -> CloudConfigurationConflict?
    {
        privateCloudConfigurationConflict
    }

    func resolvePrivateCloudConfigurationConflict(
        _ resolution: CloudConfigurationConflictResolution
    ) async throws(AppServiceError) {
        recordedCloudConfigurationResolutions.append(resolution)
        privateCloudConfigurationConflict = nil
    }

    func privateCloudCancellationRequestCount() -> Int {
        privateCloudCancellationRequests
    }

    func forcePushPrivateCloudServerConfiguration(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        recordedForcedCloudAccounts.append(account)
    }

    func resolvePrivateCloudServerConfigurationChange(
        accountID: AccountID,
        accept: Bool
    ) async throws(AppServiceError) {
        recordedCloudResolutions.append((accountID, accept))
        if case .success(var changes) = privateCloudSyncResult {
            changes.removeAll { $0.id == accountID }
            privateCloudSyncResult = .success(changes)
        }
    }

    func forcedCloudAccounts() -> [ServerAccount] {
        recordedForcedCloudAccounts
    }

    func cloudResolutions() -> [(accountID: AccountID, accept: Bool)] {
        recordedCloudResolutions
    }

    func cloudConfigurationResolutions()
        -> [CloudConfigurationConflictResolution]
    {
        recordedCloudConfigurationResolutions
    }

    func endpointDiagnostics(
        for account: ServerAccount
    ) async -> AppEndpointDiagnostics {
        configuredEndpointDiagnostics
            ?? AppEndpointDiagnostics(
                lastConnection: nil,
                authentication: nil,
                api: nil,
                webSocket: AppEndpointDescription(
                    usage: .primary,
                    server: account.server
                ),
                localServerState:
                    account.localServer == nil
                    ? .notConfigured
                    : account.localServerValidated
                        ? .available : .notYetValidated
            )
    }

    func endpointDiagnosticsUpdates(
        for account: ServerAccount
    ) async -> AsyncStream<AppEndpointDiagnostics> {
        let observerID = UUID()
        let (stream, continuation) =
            AsyncStream<AppEndpointDiagnostics>.makeStream()
        endpointDiagnosticsContinuations[observerID] = continuation
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeEndpointDiagnosticsContinuation(
                    observerID
                )
            }
        }
        return stream
    }

    func emitEndpointDiagnostics(
        _ diagnostics: AppEndpointDiagnostics
    ) {
        for continuation in endpointDiagnosticsContinuations.values {
            continuation.yield(diagnostics)
        }
    }

    func endpointDiagnosticsObserverCount() -> Int {
        endpointDiagnosticsContinuations.count
    }

    private func removeEndpointDiagnosticsContinuation(
        _ observerID: UUID
    ) {
        endpointDiagnosticsContinuations[observerID] = nil
    }

    func accounts()
        async throws(AppServiceError) -> [ServerAccount]
    {
        if let accountsGate {
            await accountsGate.enterAndWait()
        }
        if let accountsResult {
            return try value(from: accountsResult)
        }
        switch activeAccountResult {
        case .success(let account):
            return account.map { [$0] } ?? []
        case .failure(let error):
            throw error
        }
    }

    func activeAccount()
        async throws(AppServiceError) -> ServerAccount?
    {
        if let activeAccountGate {
            await activeAccountGate.enterAndWait()
        }
        activeAccountRequests += 1
        return try value(from: activeAccountResult)
    }

    func activateAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        recordedActivatedAccounts.append(account)
    }

    func login(
        serverAddress: String,
        username: String,
        password: String,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        recordedLogins.append(
            LoginRequest(
                serverAddress: serverAddress,
                username: username,
                password: password
            )
        )
        await progress(.signingIn)
        if let loginGate {
            await loginGate.enterAndWait()
        }
        return try value(from: loginResult)
    }

    func loginWithOpenID(
        serverAddress: String,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        recordedOpenIDLogins.append(serverAddress)
        await progress(.signingIn)
        if let loginGate {
            await loginGate.enterAndWait()
        }
        return try value(from: loginResult)
    }

    func reauthenticate(
        _ account: ServerAccount,
        password: String
    ) async throws(AppServiceError) -> ServerAccount {
        recordedReauthentications.append(
            ReauthenticationRequest(
                accountID: account.id,
                password: password
            )
        )
        return try value(from: loginResult)
    }

    func reauthenticateWithOpenID(
        _ account: ServerAccount,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> ServerAccount {
        recordedOpenIDReauthentications.append(account.id)
        await progress(.signingIn)
        return try value(from: loginResult)
    }

    func updateAccount(
        _ account: ServerAccount,
        serverAddress: String,
        localServerAddress: String,
        username: String,
        password: String,
        localServerValidation: LocalServerValidationPolicy,
        progress: @escaping AccountSubmissionProgress
    ) async throws(AppServiceError) -> AccountUpdateServiceOutcome {
        recordedAccountUpdates.append(
            AccountUpdateRequest(
                accountID: account.id,
                serverAddress: serverAddress,
                localServerAddress: localServerAddress,
                username: username,
                password: password,
                localServerValidation: localServerValidation
            ))
        await progress(
            password.isEmpty
                ? .verifyingSavedCredentials
                : .signingIn
        )
        if let accountUpdateGate {
            await accountUpdateGate.enterAndWait()
        }
        if !accountUpdateOutcomes.isEmpty {
            return accountUpdateOutcomes.removeFirst()
        }
        return .updated(try value(from: loginResult))
    }

    func libraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary] {
        libraryRequests += 1
        return try value(from: librariesResult)
    }

    func page(
        for account: ServerAccount,
        libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) async throws(AppServiceError) -> LibraryItemsPage {
        recordedPageRequests.append(libraryID)
        recordedPageSelections.append(
            PageSelection(
                page: request.page,
                sort: request.sort,
                descending: request.descending,
                filter: request.filter,
                collapseSeries: request.collapseSeries,
                minified: request.minified
            )
        )
        if request.collapseSeries,
            let browsePageGate,
            let browsePageGateFilter,
            request.filter == browsePageGateFilter
        {
            await browsePageGate.enterAndWait()
        }
        if let asyncPageProvider {
            return try value(from: await asyncPageProvider(libraryID, request))
        }
        if let pagedProvider {
            return try value(from: pagedProvider(request.page))
        }
        if request.page == 0,
            recordedPageRequests.count > 1,
            let refreshPageGate
        {
            await refreshPageGate.enterAndWait()
        }
        if request.page == 0 {
            return try value(from: firstPageResult)
        }
        return try value(from: nextPageResult)
    }

    func homeShelves(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> [LibraryBookShelf] {
        recordedHomeRequests.append(libraryID)
        if recordedHomeRequests.count > 1,
            let homeShelvesRefreshGate
        {
            await homeShelvesRefreshGate.enterAndWait()
        }
        return try value(from: homeShelvesResult)
    }

    func search(
        for account: ServerAccount,
        libraryID: LibraryID,
        query: String
    ) async throws(AppServiceError) -> LibrarySearchResults {
        recordedSearchRequests.append(
            SearchRequest(
                accountID: account.id,
                libraryID: libraryID,
                query: query
            )
        )
        let requestIndex = recordedSearchRequests.count - 1
        let result =
            queuedSearchResults.isEmpty
            ? searchResult : queuedSearchResults.removeFirst()
        if requestIndex < searchRequestGates.count {
            await searchRequestGates[requestIndex].enterAndWait()
        } else if recordedSearchRequests.count == 1,
            let searchGate
        {
            await searchGate.enterAndWait()
        }
        return try value(from: result)
    }

    func openPlayback(
        for account: ServerAccount,
        itemID: LibraryItemID,
        preference: PlaybackPreference,
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> AppPlaybackPreparation {
        recordedPlaybackOpenRequests.append(
            PlaybackOpenRequest(
                accountID: account.id,
                itemID: itemID,
                preference: preference
            )
        )
        guard !playbackResults.isEmpty else {
            throw .playbackSession(.requestFailed)
        }
        let result = playbackResults.removeFirst()
        if recordedPlaybackOpenRequests.count == 1,
            let playbackGate
        {
            await playbackGate.enterAndWait()
        }
        return try value(from: result)
    }

    func closePlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID
    ) async throws(AppServiceError) {
        recordedPlaybackCloseSessionIDs.append(sessionID)
        if let playbackCloseGate {
            await playbackCloseGate.enterAndWait()
        }
    }

    func finishStatisticsSession(
        _ sessionID: PlaybackSessionID
    ) async throws(AppServiceError) {
        if let statisticsFinishGate {
            await statisticsFinishGate.enterAndWait()
        }
    }

    func statisticsSummary(
        query: StatisticsQuery
    ) async throws(AppServiceError) -> StatisticsSummary {
        if let statisticsSummaryGate {
            await statisticsSummaryGate.enterAndWait()
        }
        return .empty
    }

    func syncPlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID,
        currentTime: Double,
        duration: Double
    ) async throws(AppServiceError) {
        recordedPlaybackSyncSessionIDs.append(sessionID)
    }

    func syncLocalPlaybackSessions(
        for account: ServerAccount,
        sessions: [LocalPlaybackSession],
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> [LocalPlaybackSessionSyncResult] {
        recordedLocalSessionSyncRequests.append(
            LocalSessionSyncRequest(
                accountID: account.id,
                sessions: sessions,
                deviceInfo: deviceInfo
            )
        )
        if let localSessionSyncGate {
            await localSessionSyncGate.enterAndWait()
        }
        return try value(from: localSessionSyncResult)
    }

    func bookDetail(
        for account: ServerAccount,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookDetail {
        recordedBookDetailRequests.append(
            BookDetailRequest(
                accountID: account.id,
                libraryID: libraryID,
                itemID: itemID
            )
        )
        let requestIndex = recordedBookDetailRequests.count - 1
        let result =
            queuedBookDetailResults.isEmpty
            ? bookDetailResult : queuedBookDetailResults.removeFirst()
        if requestIndex < bookDetailRequestGates.count {
            await bookDetailRequestGates[requestIndex].enterAndWait()
        } else if let bookDetailGate {
            await bookDetailGate.enterAndWait()
        }
        return try value(from: result)
    }

    func refreshedBookDetail(
        for account: ServerAccount,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookDetail {
        recordedRefreshedBookDetailRequests.append(
            BookDetailRequest(
                accountID: account.id,
                libraryID: libraryID,
                itemID: itemID
            )
        )
        if let refreshedBookDetailResult {
            return try value(from: refreshedBookDetailResult)
        }
        return try await bookDetail(
            for: account,
            libraryID: libraryID,
            itemID: itemID
        )
    }

    func saveMetadata(
        for account: ServerAccount,
        baseline: LibraryBookDetail,
        draft: BookMetadataDraft,
        overwrite: Bool
    ) async throws(AppServiceError) -> AppMetadataSaveOutcome {
        recordedMetadataSaveRequests.append(
            MetadataSaveRequest(
                accountID: account.id,
                baseline: baseline,
                draft: draft,
                overwrite: overwrite
            )
        )
        if let metadataSaveResult {
            return try value(from: metadataSaveResult)
        }
        return .saved(baseline)
    }

    func downloadPlan(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> DownloadPlan {
        recordedDownloadPlanRequests.append(itemID)
        if let downloadPlanGate {
            await downloadPlanGate.enterAndWait()
        }
        if let downloadPlanProvider {
            return try value(from: downloadPlanProvider(itemID))
        }
        if let downloadPlanResult {
            return try value(from: downloadPlanResult)
        }
        throw .downloadPlan(.invalidItemID)
    }

    func authorizedDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity
    ) async throws(AppServiceError) -> URLRequest {
        recordedAuthorizedDownloadRequests.append(identity)
        if let authorizedDownloadRequestResult {
            return try value(from: authorizedDownloadRequestResult)
        }
        throw .downloadAuthorization(.invalidAccountID)
    }

    func replacementDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity,
        rejectedRequest: URLRequest
    ) async throws(AppServiceError) -> URLRequest {
        throw .downloadAuthorization(.invalidAccountID)
    }

    func replaceCover(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        jpegData: Data
    ) async throws(AppServiceError) -> LibraryBookDetail {
        recordedCoverReplacementRequests.append(
            CoverReplacementRequest(
                accountID: account.id,
                detail: detail,
                jpegData: jpegData
            )
        )
        if let coverReplacementGate {
            await coverReplacementGate.enterAndWait()
        }
        if let coverReplacementResult {
            return try value(from: coverReplacementResult)
        }
        return detail
    }

    func deleteBook(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        mode: BookDeletionMode
    ) async throws(AppServiceError) -> AppBookDeletionOutcome {
        recordedBookDeletionRequests.append(
            BookDeletionRequest(
                accountID: account.id,
                detail: detail,
                mode: mode
            )
        )
        return try value(from: bookDeletionResult)
    }

    func bookmarks(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [AudioBookmark] {
        recordedBookmarkRequests.append(
            BookmarkRequest(
                accountID: account.id,
                itemID: itemID
            )
        )
        if let bookmarksGate {
            await bookmarksGate.enterAndWait()
        }
        return try value(from: bookmarksResult)
    }

    func createBookmark(
        for account: ServerAccount,
        itemID: LibraryItemID,
        time: Double,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark {
        AudioBookmark(
            libraryItemID: itemID,
            time: time,
            title: title,
            createdAtMilliseconds: 1
        )
    }

    func renameBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark {
        AudioBookmark(
            libraryItemID: bookmark.libraryItemID,
            time: bookmark.time,
            title: title,
            createdAtMilliseconds: bookmark.createdAtMilliseconds
        )
    }

    func deleteBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark
    ) async throws(AppServiceError) {}

    func bookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookProgress? {
        recordedBookProgressRequests.append(itemID)
        if let bookProgressGate {
            await bookProgressGate.enterAndWait()
        }
        return nil
    }

    func allBookProgress(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibraryBookProgress] {
        recordedAllBookProgressRequests.append(account.id)
        let result: Result<[LibraryBookProgress], AppServiceError>
        if allBookProgressResults.count > 1 {
            result = allBookProgressResults.removeFirst()
        } else {
            result = allBookProgressResults.first ?? .success([])
        }
        if recordedAllBookProgressRequests.count == 1,
            let firstAllBookProgressGate
        {
            await firstAllBookProgressGate.enterAndWait()
        }
        return try value(from: result)
    }

    func updateBookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID,
        update: BookProgressUpdate
    ) async throws(AppServiceError) {
        recordedProgressUpdateRequests.append(
            ProgressUpdateRequest(
                accountID: account.id,
                itemID: itemID,
                update: update
            )
        )
        if let progressUpdateGate {
            await progressUpdateGate.enterAndWait()
        }
        try value(from: progressUpdateResult)
    }

    func removeAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        recordedRemovedAccounts.append(account)
        if let removeGate {
            await removeGate.enterAndWait()
        }
        try value(from: removeAccountResult)
    }

    func resetLocalData() async throws(AppServiceError) {
        localDataResetRequests += 1
        if let localDataResetGate {
            await localDataResetGate.enterAndWait()
        }
        try value(from: localDataResetResult)
    }

    func resetLocalDataRequestCount() -> Int {
        localDataResetRequests
    }

    func setLibraries(
        _ result: Result<[LibrarySummary], AppServiceError>
    ) {
        librariesResult = result
    }

    func setActiveAccountResult(
        _ result: Result<ServerAccount?, AppServiceError>
    ) {
        activeAccountResult = result
    }

    func enqueueAccountUpdateOutcome(
        _ outcome: AccountUpdateServiceOutcome
    ) {
        accountUpdateOutcomes.append(outcome)
    }

    func setFirstPage(
        _ result: Result<LibraryItemsPage, AppServiceError>
    ) {
        firstPageResult = result
    }

    func setHomeShelves(
        _ result: Result<[LibraryBookShelf], AppServiceError>
    ) {
        homeShelvesResult = result
    }

    func setSearch(
        _ result: Result<[LibraryBookSummary], AppServiceError>
    ) {
        searchResult = result.map { LibrarySearchResults(books: $0) }
    }

    func queueSearches(
        _ results: [Result<[LibraryBookSummary], AppServiceError>],
        gates: [AsyncGate]
    ) {
        queuedSearchResults = results.map {
            $0.map { LibrarySearchResults(books: $0) }
        }
        searchRequestGates = gates
    }

    func setBookDetail(
        _ result: Result<LibraryBookDetail, AppServiceError>
    ) {
        bookDetailResult = result
    }

    func setRefreshedBookDetail(
        _ result: Result<LibraryBookDetail, AppServiceError>
    ) {
        refreshedBookDetailResult = result
    }

    func queueBookDetails(
        _ results: [Result<LibraryBookDetail, AppServiceError>],
        gates: [AsyncGate]
    ) {
        queuedBookDetailResults = results
        bookDetailRequestGates = gates
    }

    func setProgressUpdate(
        _ result: Result<Void, AppServiceError>
    ) {
        progressUpdateResult = result
    }

    func activeAccountRequestCount() -> Int {
        activeAccountRequests
    }

    func activatedAccounts() -> [ServerAccount] {
        recordedActivatedAccounts
    }

    func loginRequests() -> [LoginRequest] {
        recordedLogins
    }

    func openIDLoginRequests() -> [String] {
        recordedOpenIDLogins
    }

    func reauthenticationRequests() -> [ReauthenticationRequest] {
        recordedReauthentications
    }

    func openIDReauthenticationRequests() -> [AccountID] {
        recordedOpenIDReauthentications
    }

    func accountUpdateRequests() -> [AccountUpdateRequest] {
        recordedAccountUpdates
    }

    func libraryRequestCount() -> Int {
        libraryRequests
    }

    func pageRequests() -> [LibraryID] {
        recordedPageRequests
    }

    func pageSelections() -> [PageSelection] {
        recordedPageSelections
    }

    func homeRequests() -> [LibraryID] {
        recordedHomeRequests
    }

    func searchRequests() -> [SearchRequest] {
        recordedSearchRequests
    }

    func bookDetailRequests() -> [BookDetailRequest] {
        recordedBookDetailRequests
    }

    func refreshedBookDetailRequests() -> [BookDetailRequest] {
        recordedRefreshedBookDetailRequests
    }

    func playbackOpenRequests() -> [PlaybackOpenRequest] {
        recordedPlaybackOpenRequests
    }

    func playbackCloseSessionIDs() -> [PlaybackSessionID] {
        recordedPlaybackCloseSessionIDs
    }

    func playbackSyncSessionIDs() -> [PlaybackSessionID] {
        recordedPlaybackSyncSessionIDs
    }

    func bookmarkRequests() -> [BookmarkRequest] {
        recordedBookmarkRequests
    }

    func bookProgressRequests() -> [LibraryItemID] {
        recordedBookProgressRequests
    }

    func metadataSaveRequests() -> [MetadataSaveRequest] {
        recordedMetadataSaveRequests
    }

    func coverReplacementRequests() -> [CoverReplacementRequest] {
        recordedCoverReplacementRequests
    }

    func setCoverReplacement(
        _ result: Result<LibraryBookDetail, AppServiceError>
    ) {
        coverReplacementResult = result
    }

    func setCoverReplacementGate(_ gate: AsyncGate?) {
        coverReplacementGate = gate
    }

    func bookDeletionRequests() -> [BookDeletionRequest] {
        recordedBookDeletionRequests
    }

    func progressUpdateRequests() -> [ProgressUpdateRequest] {
        recordedProgressUpdateRequests
    }

    func setLocalSessionSync(
        _ result:
            Result<
                [LocalPlaybackSessionSyncResult],
                AppServiceError
            >
    ) {
        localSessionSyncResult = result
    }

    func setDownloadPlan(
        _ result: Result<DownloadPlan, AppServiceError>?
    ) {
        downloadPlanResult = result
    }

    func setDownloadPlanGate(_ gate: AsyncGate?) {
        downloadPlanGate = gate
    }

    func downloadPlanRequests() -> [LibraryItemID] {
        recordedDownloadPlanRequests
    }

    func authorizedDownloadRequestIdentities() -> [DownloadTaskIdentity] {
        recordedAuthorizedDownloadRequests
    }

    func localSessionSyncRequests() -> [LocalSessionSyncRequest] {
        recordedLocalSessionSyncRequests
    }

    func removedAccounts() -> [ServerAccount] {
        recordedRemovedAccounts
    }

    private func value<Value: Sendable>(
        from result: Result<Value, AppServiceError>
    ) throws(AppServiceError) -> Value {
        switch result {
        case .success(let value):
            value
        case .failure(let error):
            throw error
        }
    }
}

private func cloudConfigurationSnapshot(
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
        maximumConcurrentDownloads: 5,
        automaticDownloadLookahead: 2,
        automaticDownloadCleanupPolicy: "afterTwentyFourHours"
    )
}

private actor AppDiagnosticRecorderSpy: DiagnosticRecording {
    private var recordedEvents: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        recordedEvents.append(event)
    }

    func events() -> [DiagnosticEvent] {
        recordedEvents
    }
}

private actor GatedPlaybackFailureDiagnosticRecorder: DiagnosticRecording {
    private let gate: AsyncGate

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func record(_ event: DiagnosticEvent) async {
        guard event.operation == .openPlayback,
            event.name == .operationFailed
        else {
            return
        }
        await gate.enterAndWait()
    }
}

private actor GatedOrderedDownloadDiagnosticRecorder: DiagnosticRecording {
    private let gate: AsyncGate
    private var recordedEvents: [DiagnosticEvent] = []
    private var didGate = false

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func record(_ event: DiagnosticEvent) async {
        recordedEvents.append(event)
        if !didGate {
            didGate = true
            await gate.enterAndWait()
        }
    }

    func events() -> [DiagnosticEvent] {
        recordedEvents
    }
}

private actor GatedClosePlaybackDiagnosticRecorder: DiagnosticRecording {
    private let gate: AsyncGate
    private var didGate = false

    init(gate: AsyncGate) {
        self.gate = gate
    }

    func record(_ event: DiagnosticEvent) async {
        guard !didGate,
            event.operation == .closePlayback,
            event.name == .operationStarted
        else {
            return
        }
        didGate = true
        await gate.enterAndWait()
    }
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let continuations = enteredContinuations
        enteredContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }

        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    func reset() {
        entered = false
        released = false
    }
}

private actor RetryDelayGate {
    private var delay: Duration?
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []
    private var released = false

    func recordAndWait(_ duration: Duration) async {
        delay = duration
        let continuations = enteredContinuations
        enteredContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard delay == nil else { return }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func observedDelay() -> Duration? {
        delay
    }

    func release() {
        released = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

private final class Issue151RepairURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 0-0/1"]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data([0xA5]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class RetryAfterDownloadURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 503,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "120"]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ExpiringRetryAfterDownloadURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 429,
                httpVersion: "HTTP/1.1",
                headerFields: ["Retry-After": "1"]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class LateTransferDownloadURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 5-7/8"]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(repeating: 0xCD, count: 3))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class PauseTerminalFailureURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 404,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SystemResumedSuffixDownloadURLProtocol: URLProtocol,
    @unchecked Sendable
{
    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
            let response = HTTPURLResponse(
                url: url,
                statusCode: 206,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Range": "bytes 6-7/8"]
            )
        else {
            client?.urlProtocol(
                self,
                didFailWithError: URLError(.badServerResponse)
            )
            return
        }
        client?.urlProtocol(
            self,
            didReceive: response,
            cacheStoragePolicy: .notAllowed
        )
        client?.urlProtocol(self, didLoad: Data(repeating: 0xCD, count: 3))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor ChapterTranscriptionRequestRecorder {
    private var requests: [ChapterTranscriptionRequest] = []

    func record(_ request: ChapterTranscriptionRequest) {
        requests.append(request)
    }

    func recordedRequests() -> [ChapterTranscriptionRequest] {
        requests
    }
}

private struct TestChapterTranscriber: ChapterTranscribing {
    let gate: AsyncGate?
    let segments: [TranscriptSegment]
    let requestRecorder: ChapterTranscriptionRequestRecorder?
    var input = ChapterTranscriptionInput(
        durationMilliseconds: 20_000,
        byteCount: 4_096,
        container: .m4a,
        codec: .aac,
        sampleRateHz: 44_100,
        channelCount: 2
    )

    func transcribe(
        _ request: ChapterTranscriptionRequest
    ) async throws -> ChapterTranscriptionResult {
        await requestRecorder?.record(request)
        if let gate {
            await gate.enterAndWait()
        }
        return ChapterTranscriptionResult(
            segments: segments,
            input: input
        )
    }
}
