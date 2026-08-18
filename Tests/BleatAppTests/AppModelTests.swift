import AVFoundation
import BleatCore
import BleatTranscription
import MediaPlayer
import Observation
import UIKit
import XCTest

@testable import Bleat

#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
    import CarPlay
#endif

@MainActor
final class AppModelTests: XCTestCase {
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
        let downloads = DownloadModel(
            service: service,
            storageRootURL: root,
            remoteTelemetryTracer: tracer
        )

        await downloads.download(detail: detail, account: account)
        let record = try XCTUnwrap(downloads.records.first)
        await downloads.cancel(record)

        XCTAssertEqual(
            tracer.spans,
            plan.tracks.map { _ in
                RecordedRemoteTelemetrySpan(
                    operation: .downloadTransfer,
                    source: .remote,
                    retryBucket: .none,
                    outcome: .cancelled
                )
            }
        )
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
        let chapter = PlaybackChapter(
            id: 13,
            start: 0,
            end: 20,
            title: "Chapter Thirteen"
        )
        let detail = fixtureBookDetail(
            item: fixtureBook(
                id: "transcription-terminal-save-race",
                title: "Terminal Save Race",
                libraryID: fixtureLibrary().id
            ),
            chapters: [chapter]
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
            chapters: [chapter],
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
            chapters: [chapter],
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
            coordinator.isCached(chapterID: chapter.id, for: inactiveBookKey)
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

    func testTranscriptionLifecycleEmitsOneContentFreeSpan() async throws {
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
                )
            ]
        )
        XCTAssertFalse(
            String(describing: tracer.spans).contains("Private")
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
        let observed = try layout.placeDownloadedFile(
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
                    ]
                )
            }
        )
        let service = TestAppService(activeAccount: .success(account))
        let downloads = DownloadModel(
            service: service,
            defaults: defaults,
            storageRootURL: root
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
            downloadsStorageRootURL: root
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
            downloadsStorageRootURL: root
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
            storageRootURL: root
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
            storageRootURL: root
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
            storageRootURL: root
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
        ]

        XCTAssertTrue(failures.allSatisfy { !$0.message.isEmpty })
        XCTAssertEqual(Set(failures.map(\.message)).count, failures.count)
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

        #if targetEnvironment(macCatalyst)
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
        #if targetEnvironment(macCatalyst)
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
        XCTAssertEqual(
            first.automaticCleanupPolicy,
            .afterTwentyFourHours
        )

        first.setAutomaticLookaheadCount(9)
        first.setAutomaticCleanupPolicy(.afterChapter)
        let restored = DownloadModel(service: service, defaults: defaults)
        XCTAssertEqual(restored.automaticLookaheadCount, 9)
        XCTAssertEqual(restored.automaticCleanupPolicy, .afterChapter)

        restored.setAutomaticLookaheadCount(0)
        XCTAssertEqual(restored.automaticLookaheadCount, 1)
        restored.setAutomaticLookaheadCount(99)
        XCTAssertEqual(restored.automaticLookaheadCount, 20)
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
            downloadsStorageRootURL: root
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

    func testConstrainedPathSuspendsLiveUpdatesWithoutSigningOut()
        async throws
    {
        let account = try fixtureAccount()
        let service = TestAppService(
            accounts: .success([account]),
            activeAccount: .success(account)
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
            downloadsStorageRootURL: root
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
            AppLaunchStage.syncingData.message,
            "Syncing your data"
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

    func testStartPublishesStagesAsStartupWorkBegins() async {
        let privateCloudGate = AsyncGate()
        let accountsGate = AsyncGate()
        let activeAccountGate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(nil),
            privateCloudSyncGate: privateCloudGate,
            accountsGate: accountsGate,
            activeAccountGate: activeAccountGate
        )
        let model = AppModel(
            service: service,
            initialLaunchStage: .reticulatingSplines
        )

        let start = Task { @MainActor in
            await model.start()
        }

        await privateCloudGate.waitUntilEntered()
        XCTAssertEqual(model.phase, .launching)
        XCTAssertEqual(model.launchStage, .syncingData)

        await privateCloudGate.release()
        await accountsGate.waitUntilEntered()
        XCTAssertEqual(model.launchStage, .restoringAccount)

        await accountsGate.release()
        await activeAccountGate.waitUntilEntered()
        XCTAssertEqual(model.launchStage, .restoringAccount)

        await activeAccountGate.release()
        await start.value
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testStartSkipsSyncingStageWhenPrivateCloudIsUnavailable() async {
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
        XCTAssertNotEqual(model.launchStage, .syncingData)

        await accountsGate.release()
        await start.value
        XCTAssertEqual(model.phase, .signedOut)
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
        let account = try fixtureAccount()
        let itemID = LibraryItemID(rawValue: "live-item")
        let service = TestAppService(activeAccount: .success(account))
        let model = AppModel(service: service)
        await model.start()
        for _ in 0 ..< 100 {
            if await service.networkPathObserverCount() > 0 {
                break
            }
            await Task.yield()
        }
        await service.emitNetworkPathUpdate()
        for _ in 0 ..< 100 where !(await service.hasLiveUpdatesSubscriber()) {
            await Task.yield()
        }
        let hasSubscriber = await service.hasLiveUpdatesSubscriber()
        XCTAssertTrue(hasSubscriber)

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
        for _ in 0 ..< 100 where !model.isBookFinished(itemID) {
            await Task.yield()
        }

        XCTAssertTrue(model.isBookFinished(itemID))
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

    func testDiagnosticsReportContainsStateWithoutAccountSecrets()
        async throws
    {
        let account = try fixtureAccount(
            accountID: "private-account-id",
            userID: "private-user-id",
            username: "private-username",
            server: "https://private.example/library"
        )
        let library = fixtureLibrary()
        let endpointDiagnostics = AppEndpointDiagnostics(
            lastConnection: AppEndpointActivityDescription(
                purpose: .api,
                endpoint: AppEndpointDescription(
                    usage: .local,
                    server: try NormalizedServerURL(
                        "https://books.home:8443/library"
                    )
                )
            ),
            authentication: AppEndpointDescription(
                usage: .primary,
                server: try NormalizedServerURL(
                    "https://private.example/library"
                )
            ),
            api: AppEndpointDescription(
                usage: .local,
                server: try NormalizedServerURL(
                    "https://books.home:8443/library"
                )
            ),
            webSocket: AppEndpointDescription(
                usage: .primary,
                server: try NormalizedServerURL(
                    "https://private.example/library"
                )
            ),
            localServerState: .available
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            endpointDiagnostics: endpointDiagnostics
        )
        let model = AppModel(service: service)
        await model.start()
        await model.refreshEndpointDiagnostics()

        let report = model.diagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 1_721_865_600),
            environment: DiagnosticsEnvironment(
                appVersion: "0.1.0",
                appBuild: "7",
                operatingSystem: "iOS 26.0"
            )
        )

        XCTAssertEqual(report.serverVersion, "2.36.0")
        XCTAssertEqual(report.connectionState, "Connected")
        XCTAssertEqual(report.accountCount, 1)
        XCTAssertEqual(report.libraryState, "Loaded")
        XCTAssertEqual(report.playbackState, "Idle")
        XCTAssertEqual(
            report.lastServerConnection,
            "API — Local — books.home:8443"
        )
        XCTAssertEqual(
            report.authenticationEndpoint,
            "Primary — private.example"
        )
        XCTAssertEqual(report.apiEndpoint, "Local — books.home:8443")
        XCTAssertEqual(report.webSocketEndpoint, "Primary — private.example")
        XCTAssertEqual(report.webSocketState, "Disconnected")
        XCTAssertEqual(report.localServerState, "Validated — available")
        XCTAssertTrue(report.errorCodes.isEmpty)
        XCTAssertTrue(report.text.contains("App: 0.1.0 (7)"))
        XCTAssertTrue(report.text.contains("Server version: 2.36.0"))
        XCTAssertTrue(
            report.text.contains(
                "Last API connection: Local — books.home:8443"
            )
        )
        XCTAssertFalse(report.text.contains("private-account-id"))
        XCTAssertFalse(report.text.contains("private-user-id"))
        XCTAssertFalse(report.text.contains("private-username"))
        XCTAssertTrue(report.text.contains("private.example"))
        XCTAssertFalse(report.text.contains("/library"))

        let playbackDiagnostics = AppEndpointDiagnostics(
            lastConnection: AppEndpointActivityDescription(
                purpose: .playback,
                endpoint: AppEndpointDescription(
                    usage: .primary,
                    server: account.server
                )
            ),
            authentication: endpointDiagnostics.authentication,
            api: endpointDiagnostics.api,
            webSocket: endpointDiagnostics.webSocket,
            localServerState: .temporarilyUnavailable
        )
        for _ in 0..<100 {
            if await service.endpointDiagnosticsObserverCount() > 0 {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await service.emitEndpointDiagnostics(playbackDiagnostics)
        for _ in 0..<100 {
            if model.endpointDiagnostics == playbackDiagnostics {
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            model.diagnosticsReport().lastServerConnection,
            "Playback — Primary — private.example"
        )
    }

    func testDiagnosticsReportUsesTypedErrorCodes() async throws {
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

        _ = await model.login(
            serverAddress: "https://private.example",
            username: "private-username",
            password: "private-password"
        )
        let report = model.diagnosticsReport(
            environment: DiagnosticsEnvironment(
                appVersion: "0.1.0",
                appBuild: "7",
                operatingSystem: "iOS 26.0"
            )
        )

        XCTAssertEqual(report.errorCodes, ["invalid_credentials"])
        XCTAssertTrue(
            report.text.contains(
                "Active error codes: invalid_credentials"
            )
        )
        XCTAssertFalse(report.text.contains("private-password"))
        XCTAssertFalse(report.text.contains("private-username"))
        XCTAssertFalse(report.text.contains("private.example"))
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
            coverJPEGData: Data([1])
        )

        XCTAssertEqual(
            model.bookEditSaveState,
            .metadataSavedCoverFailed(
                detail,
                AppFailure(.replaceCover, .invalidInput)
            )
        )
        XCTAssertEqual(model.bookDetail, .loaded(detail))
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

    func testSetFinishedUpdatesProgressAndRefetchesDetail() async throws {
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
        XCTAssertTrue(detailRequests.isEmpty)
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
            downloadsStorageRootURL: root
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
            downloadsStorageRootURL: root
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
            storageRootURL: root
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
            storageRootURL: root
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
            storageRootURL: root
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
            downloadsStorageRootURL: root
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
            downloadsStorageRootURL: root
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
            downloadsStorageRootURL: root
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
            downloadsStorageRootURL: root
        )
        await model.start()
        let outcome = await model.startPlayback(
            book: summary,
            account: account,
            position: .absoluteTime(0.75)
        )
        XCTAssertEqual(outcome, .started(source: .downloaded))
        await preparationGate.waitUntilEntered()
        let didReachBoundary = await waitUntil(timeout: .seconds(3)) {
            model.playback.currentTime >= 0.99
        }
        XCTAssertTrue(didReachBoundary)

        model.playback.pause()
        await preparationGate.release()
        let didPause = await waitUntil(timeout: .seconds(2)) {
            model.playback.state == .paused
        }
        XCTAssertTrue(didPause)
        model.playback.play()

        let didResumeContinuation = await waitUntil(timeout: .seconds(2)) {
            model.playback.coverLoadPolicy == .allowNetwork
        }
        XCTAssertTrue(didResumeContinuation)
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
            storageRootURL: root
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
                downloadsStorageRootURL: root
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
            downloadsStorageRootURL: root
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
            information[MPNowPlayingInfoPropertyPlaybackRate] as? Float,
            1.25
        )
    }

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

    func testNowPlayingRetriesCoverWhenAccountIdentityArrives() async throws {
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

    func testFeaturedPlaybackRateCyclesAndRemoteFailuresAreTyped() {
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

        XCTAssertEqual(
            coordinator.cyclePlaybackRate(),
            .accepted
        )
        XCTAssertEqual(receivedCommand, .setRate(1.25))
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

    #if canImport(CarPlay) && !targetEnvironment(macCatalyst)
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
            XCTAssertEqual(home.sections.first?.header, "Continue Listening")
            XCTAssertEqual(home.sections.first?.items.count, 1)
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

        func testCarPlaySearchSuppressesSupersededResult() async throws {
            let account = try fixtureAccount()
            let library = fixtureLibrary()
            let result = fixtureBook(
                id: "search-item",
                title: "Current Result",
                libraryID: library.id
            )
            let gate = AsyncGate()
            let service = TestAppService(
                activeAccount: .success(account),
                libraries: .success([library]),
                firstPage: .success(
                    fixturePage(libraryID: library.id)
                ),
                search: .success([result]),
                searchGate: gate
            )
            let model = AppModel(service: service)
            await model.start()
            let coordinator = CarPlayCoordinator(model: model)
            let presenter = TestCarPlayPresenter()
            coordinator.connect(presenter)
            var firstResult: [CPListItem]?
            var secondResult: [CPListItem]?
            let first = expectation(description: "Old search completed")
            let second = expectation(description: "New search completed")

            coordinator.searchTemplate(
                CPSearchTemplate(),
                updatedSearchText: "old"
            ) {
                firstResult = $0
                first.fulfill()
            }
            try await Task.sleep(for: .milliseconds(350))
            await gate.waitUntilEntered()
            coordinator.searchTemplate(
                CPSearchTemplate(),
                updatedSearchText: "new"
            ) {
                secondResult = $0
                second.fulfill()
            }
            try await Task.sleep(for: .milliseconds(350))
            await gate.release()
            await fulfillment(of: [first, second], timeout: 2)

            XCTAssertEqual(firstResult?.count, 0)
            XCTAssertEqual(secondResult?.map(\.text), ["Current Result"])
            let requests = await service.searchRequests()
            XCTAssertEqual(requests.map(\.query), ["old", "new"])
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
                downloadsStorageRootURL: root
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
        isFinished: Bool
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
            lastUpdateMilliseconds: 1,
            startedAtMilliseconds: 1,
            finishedAtMilliseconds: isFinished ? 1 : nil
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
                    segments: segments
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
        let observed = try layout.placeDownloadedFile(
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
    coverURL: URL?
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
        rate: 1,
        isPlaying: true,
        isPlaybackRequested: true,
        isPlaybackAvailable: true,
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

#if canImport(CarPlay) && !targetEnvironment(macCatalyst)
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
    private var bookDetailResult:
        Result<
            LibraryBookDetail,
            AppServiceError
        >
    private var bookmarksResult:
        Result<
            [AudioBookmark],
            AppServiceError
        >
    private var metadataSaveResult:
        Result<AppMetadataSaveOutcome, AppServiceError>?
    private var coverReplacementResult:
        Result<LibraryBookDetail, AppServiceError>?
    private var bookDeletionResult:
        Result<AppBookDeletionOutcome, AppServiceError>
    private var progressUpdateResult: Result<Void, AppServiceError>
    private var allBookProgressResults:
        [Result<[LibraryBookProgress], AppServiceError>]
    private var localSessionSyncResult:
        Result<[LocalPlaybackSessionSyncResult], AppServiceError>
    private var playbackResults:
        [Result<AppPlaybackPreparation, AppServiceError>]
    private let downloadPlanResult: Result<DownloadPlan, AppServiceError>?
    private let authorizedDownloadRequestResult:
        Result<URLRequest, AppServiceError>?
    private var removeAccountResult: Result<Void, AppServiceError>
    private let loginGate: AsyncGate?
    private let accountUpdateGate: AsyncGate?
    private let removeGate: AsyncGate?
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
    private let playbackGate: AsyncGate?
    private let playbackCloseGate: AsyncGate?
    private let statisticsFinishGate: AsyncGate?
    private let browsePageGate: AsyncGate?
    private let browsePageGateFilter: LibraryItemFilter?
    private let refreshPageGate: AsyncGate?
    private let homeShelvesRefreshGate: AsyncGate?
    private let transcriptLoadGate: AsyncGate?
    private let transcriptSaveGate: AsyncGate?
    private let transcriptLoadResult:
        Result<[CachedChapterTranscript], AppServiceError>
    private let transcriptSaveResult: Result<Void, AppServiceError>
    private let transcriptionTaskStateLoadResult:
        Result<CachedChapterTranscriptionTaskState?, AppServiceError>
    private let firstTranscriptionTaskStateSaveGate: AsyncGate?
    private let transcriptionTaskStateSaveResults:
        [Result<Void, AppServiceError>]
    private let privateCloudSyncAvailable: Bool
    private var privateCloudSyncChanges: [CloudServerConfigurationChange]
    private let configuredEndpointDiagnostics: AppEndpointDiagnostics?
    private var endpointDiagnosticsContinuations:
        [UUID:
            AsyncStream<AppEndpointDiagnostics>.Continuation] = [:]
    private var networkPathContinuations:
        [UUID: AsyncStream<AppNetworkPathState>.Continuation] = [:]
    private var liveUpdatesContinuation:
        AsyncStream<AudiobookshelfLiveUpdate>.Continuation?

    private var activeAccountRequests = 0
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
    private var recordedRemovedAccounts: [ServerAccount] = []
    private var recordedSavedTranscripts: [CachedChapterTranscript] = []
    private var recordedForcedCloudAccounts: [ServerAccount] = []
    private var recordedCloudResolutions:
        [(accountID: AccountID, accept: Bool)] = []
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
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudiobookshelfLiveUpdate.self
        )
        liveUpdatesContinuation = continuation
        return stream
    }

    func hasLiveUpdatesSubscriber() -> Bool {
        liveUpdatesContinuation != nil
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
        authorizedDownloadRequest:
            Result<URLRequest, AppServiceError>? = nil,
        removeAccount: Result<Void, AppServiceError> = .success(()),
        loginGate: AsyncGate? = nil,
        accountUpdateGate: AsyncGate? = nil,
        removeGate: AsyncGate? = nil,
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
        playbackGate: AsyncGate? = nil,
        playbackCloseGate: AsyncGate? = nil,
        statisticsFinishGate: AsyncGate? = nil,
        browsePageGate: AsyncGate? = nil,
        browsePageGateFilter: LibraryItemFilter? = nil,
        refreshPageGate: AsyncGate? = nil,
        homeShelvesRefreshGate: AsyncGate? = nil,
        transcriptLoadGate: AsyncGate? = nil,
        transcriptSaveGate: AsyncGate? = nil,
        transcriptLoad:
            Result<[CachedChapterTranscript], AppServiceError> = .success([]),
        transcriptSave: Result<Void, AppServiceError> = .success(()),
        transcriptionTaskStateLoad:
            Result<CachedChapterTranscriptionTaskState?, AppServiceError> =
            .success(nil),
        firstTranscriptionTaskStateSaveGate: AsyncGate? = nil,
        transcriptionTaskStateSaveResults:
            [Result<Void, AppServiceError>] = [],
        privateCloudSyncAvailable: Bool = true,
        privateCloudSyncChanges: [CloudServerConfigurationChange] = [],
        endpointDiagnostics: AppEndpointDiagnostics? = nil
    ) {
        accountsResult = accounts
        activeAccountResult = activeAccount
        loginResult = login
        librariesResult = libraries
        firstPageResult = firstPage
        nextPageResult = nextPage
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
        authorizedDownloadRequestResult = authorizedDownloadRequest
        removeAccountResult = removeAccount
        self.loginGate = loginGate
        self.accountUpdateGate = accountUpdateGate
        self.removeGate = removeGate
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
        self.playbackGate = playbackGate
        self.playbackCloseGate = playbackCloseGate
        self.statisticsFinishGate = statisticsFinishGate
        self.browsePageGate = browsePageGate
        self.browsePageGateFilter = browsePageGateFilter
        self.refreshPageGate = refreshPageGate
        self.homeShelvesRefreshGate = homeShelvesRefreshGate
        self.transcriptLoadGate = transcriptLoadGate
        self.transcriptSaveGate = transcriptSaveGate
        transcriptLoadResult = transcriptLoad
        transcriptSaveResult = transcriptSave
        transcriptionTaskStateLoadResult = transcriptionTaskStateLoad
        self.firstTranscriptionTaskStateSaveGate =
            firstTranscriptionTaskStateSaveGate
        self.transcriptionTaskStateSaveResults =
            transcriptionTaskStateSaveResults
        self.privateCloudSyncAvailable = privateCloudSyncAvailable
        self.privateCloudSyncChanges = privateCloudSyncChanges
        configuredEndpointDiagnostics = endpointDiagnostics
    }

    func isPrivateCloudSyncAvailable() async -> Bool {
        privateCloudSyncAvailable
    }

    func cachedChapterTranscripts(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [CachedChapterTranscript] {
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
    }

    func cachedChapterTranscriptionTaskState(
        accountID: AccountID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> CachedChapterTranscriptionTaskState? {
        try value(from: transcriptionTaskStateLoadResult)
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
        if let privateCloudSyncGate {
            await privateCloudSyncGate.enterAndWait()
        }
        return privateCloudSyncChanges
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
        privateCloudSyncChanges.removeAll { $0.id == accountID }
    }

    func forcedCloudAccounts() -> [ServerAccount] {
        recordedForcedCloudAccounts
    }

    func cloudResolutions() -> [(accountID: AccountID, accept: Bool)] {
        recordedCloudResolutions
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
        try value(from: librariesResult)
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
        let result = searchResult
        if recordedSearchRequests.count == 1,
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
        if let bookDetailGate {
            await bookDetailGate.enterAndWait()
        }
        return try value(from: bookDetailResult)
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
        if let downloadPlanResult {
            return try value(from: downloadPlanResult)
        }
        throw .downloadPlan(.invalidItemID)
    }

    func authorizedDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity
    ) async throws(AppServiceError) -> URLRequest {
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

    func setBookDetail(
        _ result: Result<LibraryBookDetail, AppServiceError>
    ) {
        bookDetailResult = result
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

private struct TestChapterTranscriber: ChapterTranscribing {
    let gate: AsyncGate?
    let segments: [TranscriptSegment]

    func transcribe(
        _ request: ChapterTranscriptionRequest
    ) async throws -> [TranscriptSegment] {
        if let gate {
            await gate.enterAndWait()
        }
        return segments
    }
}
