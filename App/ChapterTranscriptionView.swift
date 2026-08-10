import AVFAudio
import BleatCore
import BleatTranscription
import Foundation
import Observation
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

struct ChapterAudioSlice: Equatable, Sendable {
    let trackIndex: Int
    let audioStartSeconds: Double
    let durationSeconds: Double
    let wholeBookStartSeconds: Double
}

struct ChapterAudioTrack: Equatable, Sendable {
    let trackIndex: Int
    let startOffsetSeconds: Double
    let durationSeconds: Double
}

enum ChapterAudioSlicePlanFailure: Error, Equatable, Sendable {
    case invalidChapter
    case invalidTrackDurations
    case incompleteChapterCoverage
}

enum ChapterAudioSlicePlanner {
    static func slices(
        for chapter: PlaybackChapter,
        trackDurations: [Double]
    ) throws(ChapterAudioSlicePlanFailure) -> [ChapterAudioSlice] {
        var nextStartOffset = 0.0
        let tracks = trackDurations.enumerated().map { index, duration in
            defer { nextStartOffset += duration }
            return ChapterAudioTrack(
                trackIndex: index,
                startOffsetSeconds: nextStartOffset,
                durationSeconds: duration
            )
        }
        return try slices(for: chapter, tracks: tracks)
    }

    static func slices(
        for chapter: PlaybackChapter,
        tracks: [ChapterAudioTrack]
    ) throws(ChapterAudioSlicePlanFailure) -> [ChapterAudioSlice] {
        guard chapter.start.isFinite,
            chapter.end.isFinite,
            chapter.start >= 0,
            chapter.end > chapter.start
        else {
            throw .invalidChapter
        }
        guard !tracks.isEmpty,
            tracks.allSatisfy({
                $0.trackIndex >= 0
                    && $0.startOffsetSeconds.isFinite
                    && $0.startOffsetSeconds >= 0
                    && $0.durationSeconds.isFinite
                    && $0.durationSeconds > 0
            })
        else {
            throw .invalidTrackDurations
        }

        var slices: [ChapterAudioSlice] = []
        for track in tracks.sorted(by: {
            ($0.startOffsetSeconds, $0.trackIndex)
                < ($1.startOffsetSeconds, $1.trackIndex)
        }) {
            let trackEnd = track.startOffsetSeconds + track.durationSeconds
            let intersectionStart = max(
                chapter.start,
                track.startOffsetSeconds
            )
            let intersectionEnd = min(chapter.end, trackEnd)
            if intersectionEnd > intersectionStart {
                slices.append(
                    ChapterAudioSlice(
                        trackIndex: track.trackIndex,
                        audioStartSeconds:
                            intersectionStart - track.startOffsetSeconds,
                        durationSeconds:
                            intersectionEnd - intersectionStart,
                        wholeBookStartSeconds: intersectionStart
                    )
                )
            }
            if trackEnd >= chapter.end {
                break
            }
        }
        guard let first = slices.first,
            let last = slices.last,
            abs(first.wholeBookStartSeconds - chapter.start) < 0.01,
            abs(
                last.wholeBookStartSeconds
                    + last.durationSeconds
                    - chapter.end
            ) < 0.01,
            abs(
                slices.reduce(0) { $0 + $1.durationSeconds }
                    - (chapter.end - chapter.start)
            ) < 0.01,
            zip(slices, slices.dropFirst()).allSatisfy({ current, next in
                abs(
                    current.wholeBookStartSeconds
                        + current.durationSeconds
                        - next.wholeBookStartSeconds
                ) < 0.01
            })
        else {
            throw .incompleteChapterCoverage
        }
        return slices
    }
}

struct ChapterTranscriptionBookKey: Hashable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
}

enum ChapterTranscriptionBatchPlanner {
    static func orderedChapters(
        selectedChapterIDs: Set<Int>,
        from chapters: [PlaybackChapter]
    ) -> [PlaybackChapter] {
        chapters
            .filter { selectedChapterIDs.contains($0.id) }
            .sorted {
                ($0.id, $0.start, $0.end)
                    < ($1.id, $1.start, $1.end)
            }
    }
}

struct ChapterTranscriptionBatchProgress: Equatable, Sendable {
    let bookKey: ChapterTranscriptionBookKey
    let chapterID: Int
    let chapterTitle: String
    let completedChapters: Int
    let totalChapters: Int
}

enum ChapterTranscriptionViewFailure: Error, Equatable, Sendable {
    case audioNotDownloaded
    case localAudioUnavailable
    case invalidChapterRange
    case cacheSaveFailed
    case transcription(ChapterTranscriptionFailure)
    case cancelled

    var message: String {
        switch self {
        case .audioNotDownloaded:
            "Download this chapter or the full audiobook before transcribing."
        case .localAudioUnavailable:
            "The downloaded audio could not be verified."
        case .invalidChapterRange:
            "This chapter could not be mapped to the downloaded audio."
        case .cacheSaveFailed:
            "The transcription was created but could not be saved."
        case .transcription(let failure):
            failure.localizedDescription
        case .cancelled:
            "Transcription was cancelled."
        }
    }

    var cachedTaskFailure: CachedChapterTranscriptionTaskFailure {
        switch self {
        case .audioNotDownloaded:
            .audioNotDownloaded
        case .localAudioUnavailable:
            .localAudioUnavailable
        case .invalidChapterRange:
            .invalidChapterRange
        case .cacheSaveFailed:
            .cacheSaveFailed
        case .cancelled:
            .cancelled
        case .transcription(let failure):
            failure.cachedTaskFailure
        }
    }
}

extension ChapterTranscriptionFailure {
    fileprivate var cachedTaskFailure: CachedChapterTranscriptionTaskFailure {
        switch self {
        case .invalidChapterStart, .invalidAudioRange:
            .invalidChapterRange
        case .operatingSystemUnsupported:
            .operatingSystemUnsupported
        case .unavailableOnDevice:
            .unavailableOnDevice
        case .unsupportedLocale:
            .unsupportedLocale
        case .languageAssetsUnavailable:
            .languageAssetsUnavailable
        case .languageAssetInstallationFailed:
            .languageAssetInstallationFailed
        case .audioFileUnreadable:
            .audioFileUnreadable
        case .chapterExtractionUnavailable:
            .chapterExtractionUnavailable
        case .chapterExtractionFailed:
            .chapterExtractionFailed
        case .analyzerInputFailed:
            .analyzerInputFailed
        case .analyzerFinalizationFailed:
            .analyzerFinalizationFailed
        case .resultStreamFailed:
            .resultStreamFailed
        }
    }
}

extension CachedChapterTranscriptionTaskFailure {
    fileprivate var message: String {
        switch self {
        case .audioNotDownloaded:
            "Download this chapter or the full audiobook before transcribing."
        case .localAudioUnavailable:
            "The downloaded audio could not be verified."
        case .invalidChapterRange:
            "A selected chapter could not be mapped to the downloaded audio."
        case .cacheSaveFailed:
            "A transcription was created but could not be saved."
        case .cancelled:
            "Transcription was cancelled."
        case .operatingSystemUnsupported:
            "SpeechTranscriber requires iOS 26 or newer."
        case .unavailableOnDevice:
            "SpeechTranscriber is unavailable on this device."
        case .unsupportedLocale:
            "SpeechTranscriber does not support the selected locale on this device."
        case .languageAssetsUnavailable:
            "SpeechTranscriber language assets are unavailable for this locale."
        case .languageAssetInstallationFailed:
            "SpeechTranscriber language assets could not be installed."
        case .audioFileUnreadable:
            "The downloaded audio file could not be read."
        case .chapterExtractionUnavailable:
            "A selected chapter could not be extracted from the local audio file."
        case .chapterExtractionFailed:
            "A selected chapter could not be extracted for transcription."
        case .analyzerInputFailed:
            "SpeechTranscriber rejected the audio input."
        case .analyzerFinalizationFailed:
            "SpeechTranscriber could not finish analyzing the audio."
        case .resultStreamFailed:
            "SpeechTranscriber could not deliver transcription results."
        }
    }
}

enum ChapterTranscriptionViewState: Equatable, Sendable {
    case ready
    case preparingAudio(
        bookKey: ChapterTranscriptionBookKey,
        totalChapters: Int
    )
    case transcribing(
        progress: ChapterTranscriptionBatchProgress,
        completedSlices: Int,
        totalSlices: Int
    )
    case saving(ChapterTranscriptionBatchProgress)
    case cancelling(
        bookKey: ChapterTranscriptionBookKey,
        chapterID: Int?
    )
    case complete(
        bookKey: ChapterTranscriptionBookKey,
        chapterIDs: [Int]
    )
    case failed(
        bookKey: ChapterTranscriptionBookKey,
        chapterID: Int?,
        failure: ChapterTranscriptionViewFailure
    )

    var bookKey: ChapterTranscriptionBookKey? {
        switch self {
        case .ready:
            nil
        case .preparingAudio(let bookKey, _),
            .cancelling(let bookKey, _),
            .complete(let bookKey, _),
            .failed(let bookKey, _, _):
            bookKey
        case .transcribing(let progress, _, _),
            .saving(let progress):
            progress.bookKey
        }
    }

    var currentChapterID: Int? {
        switch self {
        case .transcribing(let progress, _, _), .saving(let progress):
            progress.chapterID
        case .failed(_, let chapterID, _):
            chapterID
        case .cancelling(_, let chapterID):
            chapterID
        case .ready, .preparingAudio, .complete:
            nil
        }
    }
}

enum ChapterTranscriptCacheViewFailure: Equatable, Sendable {
    case loadFailed
    case saveFailed
    case taskStateLoadFailed
    case taskStateSaveFailed

    var message: String {
        switch self {
        case .loadFailed:
            "Saved transcriptions could not be loaded."
        case .saveFailed:
            "The transcription was created but could not be saved."
        case .taskStateLoadFailed:
            "The previous transcription result could not be loaded."
        case .taskStateSaveFailed:
            "The transcription result could not be saved."
        }
    }
}

private struct ActiveChapterTranscriptionBatch {
    let taskID: UUID
    let persistenceToken: UUID
    let bookKey: ChapterTranscriptionBookKey
    let account: ServerAccount
    let selectedChapterIDs: [Int]
    let startedAt: Date
    let startedInstant: ContinuousClock.Instant
}

struct PreparedChapterTranscriptionTrack: Equatable, Sendable {
    let timeline: ChapterAudioTrack
    let url: URL
}

struct PreparedChapterTranscriptionAudio: Sendable {
    let tracks: [PreparedChapterTranscriptionTrack]
    let cachePin: AutomaticCachePin?
}

enum ChapterTranscriptionAudioLoadFailure: Error, Equatable, Sendable {
    case audioNotDownloaded
    case localAudioUnavailable
}

typealias ChapterTranscriptionAudioLoader =
    @MainActor @Sendable (
        _ detail: LibraryBookDetail,
        _ account: ServerAccount,
        _ downloads: DownloadModel,
        _ chapters: [PlaybackChapter]
    ) async throws -> PreparedChapterTranscriptionAudio

typealias ChapterTranscriberFactory = @Sendable () -> any ChapterTranscribing

@MainActor
@Observable
final class ChapterTranscriptionModel {
    private(set) var state: ChapterTranscriptionViewState = .ready
    private(set) var cachedTranscriptsByBook:
        [ChapterTranscriptionBookKey: [CachedChapterTranscript]] = [:]
    private(set) var cacheFailures:
        [ChapterTranscriptionBookKey: ChapterTranscriptCacheViewFailure] = [:]
    private(set) var terminalStatesByBook:
        [ChapterTranscriptionBookKey: CachedChapterTranscriptionTaskState] =
            [:]
    @ObservationIgnored
    private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored
    private var activeTaskID: UUID?
    @ObservationIgnored
    private var activeBatch: ActiveChapterTranscriptionBatch?
    @ObservationIgnored
    private weak var activeAppModel: AppModel?
    @ObservationIgnored
    private var activeCompletedChapterIDs: [Int] = []
    @ObservationIgnored
    private var pendingTerminalPersistence:
        [UUID: (bookKey: ChapterTranscriptionBookKey, token: UUID)] = [:]
    @ObservationIgnored
    private var bookRevisions: [ChapterTranscriptionBookKey: UInt64] = [:]
    @ObservationIgnored
    private var loadTokens: [ChapterTranscriptionBookKey: UUID] = [:]
    @ObservationIgnored
    private var viewRetentionCounts: [ChapterTranscriptionBookKey: Int] = [:]
    @ObservationIgnored
    private var cacheExpiryDeadlines:
        [ChapterTranscriptionBookKey: ContinuousClock.Instant] = [:]
    @ObservationIgnored
    private var cacheReaperTask: Task<Void, Never>?
    #if canImport(UIKit)
        @ObservationIgnored
        private var memoryWarningTask: Task<Void, Never>?
    #endif
    @ObservationIgnored
    private let transcriptCacheTTL: Duration
    @ObservationIgnored
    private let transcriptCacheReapInterval: Duration
    @ObservationIgnored
    private let audioLoader: ChapterTranscriptionAudioLoader
    @ObservationIgnored
    private let transcriberFactory: ChapterTranscriberFactory

    init(
        transcriptCacheTTL: Duration = .seconds(300),
        transcriptCacheReapInterval: Duration = .seconds(60),
        audioLoader: ChapterTranscriptionAudioLoader? = nil,
        transcriberFactory: ChapterTranscriberFactory? = nil
    ) {
        self.transcriptCacheTTL = transcriptCacheTTL
        self.transcriptCacheReapInterval = transcriptCacheReapInterval
        self.audioLoader = audioLoader ?? Self.loadAudio
        self.transcriberFactory =
            transcriberFactory ?? { SpeechChapterTranscriber() }
        startCacheMaintenance()
    }

    deinit {
        cacheReaperTask?.cancel()
        #if canImport(UIKit)
            memoryWarningTask?.cancel()
        #endif
    }

    var isWorking: Bool {
        switch state {
        case .preparingAudio, .transcribing, .saving, .cancelling:
            true
        case .ready, .complete, .failed:
            false
        }
    }

    func loadCachedTranscripts(
        detail: LibraryBookDetail,
        account: ServerAccount,
        appModel: AppModel
    ) async {
        let bookKey = Self.bookKey(detail: detail, account: account)
        let loadToken = UUID()
        let startingRevision = revision(for: bookKey)
        loadTokens[bookKey] = loadToken
        defer {
            if loadTokens[bookKey] == loadToken {
                loadTokens[bookKey] = nil
            }
        }
        do {
            let loaded = try await appModel.cachedChapterTranscripts(
                for: account,
                itemID: detail.id
            )
            guard !Task.isCancelled else {
                return
            }
            guard loadTokens[bookKey] == loadToken else {
                return
            }
            if revision(for: bookKey) == startingRevision {
                cachedTranscriptsByBook[bookKey] = Self.sorted(loaded)
            } else {
                cachedTranscriptsByBook[bookKey] = Self.merge(
                    loaded: loaded,
                    current: cachedTranscriptsByBook[bookKey] ?? []
                )
            }
            scheduleExpiryIfInactive(for: bookKey)
            if cacheFailures[bookKey] == .loadFailed {
                cacheFailures[bookKey] = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard loadTokens[bookKey] == loadToken,
                revision(for: bookKey) == startingRevision
            else {
                return
            }
            cacheFailures[bookKey] = .loadFailed
        }
        do {
            let loaded =
                try await appModel.cachedChapterTranscriptionTaskState(
                    for: account,
                    itemID: detail.id
                )
            guard !Task.isCancelled else {
                return
            }
            guard loadTokens[bookKey] == loadToken else {
                return
            }
            guard revision(for: bookKey) == startingRevision else {
                return
            }
            terminalStatesByBook[bookKey] =
                terminalStatesByBook[bookKey] ?? loaded
            if cacheFailures[bookKey] == .taskStateLoadFailed {
                cacheFailures[bookKey] = nil
            }
        } catch is CancellationError {
            return
        } catch {
            guard loadTokens[bookKey] == loadToken,
                revision(for: bookKey) == startingRevision
            else {
                return
            }
            if cacheFailures[bookKey] == nil {
                cacheFailures[bookKey] = .taskStateLoadFailed
            }
        }
    }

    func retainTranscriptCache(for bookKey: ChapterTranscriptionBookKey) {
        viewRetentionCounts[bookKey, default: 0] += 1
        cacheExpiryDeadlines[bookKey] = nil
    }

    func releaseTranscriptCache(for bookKey: ChapterTranscriptionBookKey) {
        let remaining = max((viewRetentionCounts[bookKey] ?? 1) - 1, 0)
        if remaining == 0 {
            viewRetentionCounts[bookKey] = nil
            scheduleExpiryIfInactive(for: bookKey)
        } else {
            viewRetentionCounts[bookKey] = remaining
        }
    }

    func reapExpiredTranscriptCaches(
        now: ContinuousClock.Instant = .now
    ) {
        let expired = cacheExpiryDeadlines.compactMap { bookKey, deadline in
            deadline <= now && !isCacheProtected(bookKey) ? bookKey : nil
        }
        for bookKey in expired {
            evictTranscriptCache(for: bookKey)
        }
    }

    func evictInactiveTranscriptCachesForMemoryPressure() {
        let inactiveBookKeys = Set(cachedTranscriptsByBook.keys)
            .union(loadTokens.keys)
            .filter { !isCacheProtected($0) }
        for bookKey in inactiveBookKeys {
            evictTranscriptCache(for: bookKey)
        }
    }

    func state(
        for bookKey: ChapterTranscriptionBookKey
    ) -> ChapterTranscriptionViewState? {
        state.bookKey == bookKey ? state : nil
    }

    func isWorking(for bookKey: ChapterTranscriptionBookKey) -> Bool {
        isWorking && state.bookKey == bookKey
    }

    func isCancelling(for bookKey: ChapterTranscriptionBookKey) -> Bool {
        guard case .cancelling(let stateBookKey, _) = state else {
            return false
        }
        return stateBookKey == bookKey
    }

    func isCached(
        chapterID: Int,
        for bookKey: ChapterTranscriptionBookKey
    ) -> Bool {
        cachedTranscriptsByBook[bookKey]?.contains {
            $0.chapterID == chapterID
        } == true
    }

    func transcriptSegments(
        chapterID: Int,
        for bookKey: ChapterTranscriptionBookKey
    ) -> [TranscriptSegment]? {
        cachedTranscriptsByBook[bookKey]?
            .first { $0.chapterID == chapterID }?
            .segments.map(TranscriptSegment.init(cached:))
    }

    func cacheFailure(
        for bookKey: ChapterTranscriptionBookKey
    ) -> ChapterTranscriptCacheViewFailure? {
        cacheFailures[bookKey]
    }

    func terminalState(
        for bookKey: ChapterTranscriptionBookKey
    ) -> CachedChapterTranscriptionTaskState? {
        terminalStatesByBook[bookKey]
    }

    func searchResults(
        query: String,
        for bookKey: ChapterTranscriptionBookKey
    ) -> [CachedChapterTranscriptMatch] {
        CachedChapterTranscriptSearch.matches(
            query: query,
            in: cachedTranscriptsByBook[bookKey] ?? []
        )
    }

    func start(
        chapters selectedChapters: [PlaybackChapter],
        detail: LibraryBookDetail,
        account: ServerAccount,
        downloads: DownloadModel,
        appModel: AppModel
    ) {
        guard !isWorking else {
            return
        }
        let selectedChapterIDs = Set(selectedChapters.map(\.id))
        let chapters = ChapterTranscriptionBatchPlanner.orderedChapters(
            selectedChapterIDs: selectedChapterIDs,
            from: detail.chapters
        )
        guard !chapters.isEmpty else {
            return
        }
        let bookKey = Self.bookKey(detail: detail, account: account)
        let batch = ActiveChapterTranscriptionBatch(
            taskID: UUID(),
            persistenceToken: UUID(),
            bookKey: bookKey,
            account: account,
            selectedChapterIDs: chapters.map(\.id),
            startedAt: Date(),
            startedInstant: .now
        )
        markMutated(bookKey)
        terminalStatesByBook[bookKey] = nil
        let taskID = batch.taskID
        activeTaskID = taskID
        activeBatch = batch
        pendingTerminalPersistence[taskID] = (
            bookKey: bookKey,
            token: batch.persistenceToken
        )
        activeAppModel = appModel
        activeCompletedChapterIDs = []
        cacheExpiryDeadlines[bookKey] = nil
        state = .preparingAudio(
            bookKey: bookKey,
            totalChapters: chapters.count
        )
        transcriptionTask = Task(priority: .utility) { [weak self] in
            guard let self else {
                return
            }
            await self.runBatch(
                taskID: taskID,
                chapters: chapters,
                bookKey: bookKey,
                detail: detail,
                account: account,
                downloads: downloads,
                appModel: appModel
            )
        }
    }

    func cancel() {
        guard isWorking,
            let bookKey = state.bookKey,
            activeBatch != nil,
            !isCancelling(for: bookKey)
        else {
            return
        }
        let chapterID = state.currentChapterID
        markMutated(bookKey)
        state = .cancelling(
            bookKey: bookKey,
            chapterID: chapterID
        )
        transcriptionTask?.cancel()
    }

    func cancel(for accountID: AccountID) {
        invalidateTerminalPersistence {
            $0.bookKey.accountID == accountID
        }
        if state.bookKey?.accountID == accountID {
            if isWorking {
                cancelWithoutPersisting()
            }
            state = .ready
        }
        invalidateBooks { $0.accountID == accountID }
        cachedTranscriptsByBook = cachedTranscriptsByBook.filter {
            $0.key.accountID != accountID
        }
        viewRetentionCounts = viewRetentionCounts.filter {
            $0.key.accountID != accountID
        }
        cacheExpiryDeadlines = cacheExpiryDeadlines.filter {
            $0.key.accountID != accountID
        }
        cacheFailures = cacheFailures.filter {
            $0.key.accountID != accountID
        }
        terminalStatesByBook = terminalStatesByBook.filter {
            $0.key.accountID != accountID
        }
    }

    func cancel(for bookKey: ChapterTranscriptionBookKey) {
        invalidateTerminalPersistence { $0.bookKey == bookKey }
        if state.bookKey == bookKey {
            if isWorking {
                cancelWithoutPersisting()
            }
            state = .ready
        }
        cachedTranscriptsByBook[bookKey] = nil
        invalidateBook(bookKey)
        viewRetentionCounts[bookKey] = nil
        cacheExpiryDeadlines[bookKey] = nil
        cacheFailures[bookKey] = nil
        terminalStatesByBook[bookKey] = nil
    }

    private func runBatch(
        taskID: UUID,
        chapters: [PlaybackChapter],
        bookKey: ChapterTranscriptionBookKey,
        detail: LibraryBookDetail,
        account: ServerAccount,
        downloads: DownloadModel,
        appModel: AppModel
    ) async {
        var currentChapterID: Int?
        var completedChapterIDs: [Int] = []
        do {
            try Task.checkCancellation()
            let audio: PreparedChapterTranscriptionAudio
            do {
                audio = try await audioLoader(
                    detail,
                    account,
                    downloads,
                    chapters
                )
            } catch let failure as ChapterTranscriptionAudioLoadFailure {
                if Task.isCancelled {
                    throw CancellationError()
                }
                await fail(
                    taskID: taskID,
                    bookKey: bookKey,
                    chapterID: nil,
                    failure: failure.viewFailure
                )
                return
            }
            defer {
                downloads.releaseAutomaticCachePin(audio.cachePin)
            }
            try Task.checkCancellation()
            guard activeTaskID == taskID else {
                return
            }

            let transcriber = transcriberFactory()
            for (chapterIndex, chapter) in chapters.enumerated() {
                currentChapterID = chapter.id
                let progress = ChapterTranscriptionBatchProgress(
                    bookKey: bookKey,
                    chapterID: chapter.id,
                    chapterTitle: chapter.title,
                    completedChapters: chapterIndex,
                    totalChapters: chapters.count
                )
                let slices: [ChapterAudioSlice]
                do {
                    slices = try ChapterAudioSlicePlanner.slices(
                        for: chapter,
                        tracks: audio.tracks.map(\.timeline)
                    )
                } catch {
                    await fail(
                        taskID: taskID,
                        bookKey: bookKey,
                        chapterID: chapter.id,
                        failure: .invalidChapterRange
                    )
                    return
                }

                var transcript: [TranscriptSegment] = []
                for (sliceIndex, slice) in slices.enumerated() {
                    try Task.checkCancellation()
                    guard
                        let track = audio.tracks.first(where: {
                            $0.timeline.trackIndex == slice.trackIndex
                        })
                    else {
                        await fail(
                            taskID: taskID,
                            bookKey: bookKey,
                            chapterID: chapter.id,
                            failure: .localAudioUnavailable
                        )
                        return
                    }
                    state = .transcribing(
                        progress: progress,
                        completedSlices: sliceIndex,
                        totalSlices: slices.count
                    )
                    let segments = try await transcriber.transcribe(
                        ChapterTranscriptionRequest(
                            audioFileURL: track.url,
                            locale: .current,
                            audioStartSeconds: slice.audioStartSeconds,
                            audioDurationSeconds: slice.durationSeconds,
                            chapterStartSeconds:
                                slice.wholeBookStartSeconds
                        )
                    )
                    try Task.checkCancellation()
                    guard activeTaskID == taskID else {
                        return
                    }
                    transcript.append(contentsOf: segments)
                }
                let sortedTranscript = transcript.sorted {
                    ($0.startMilliseconds, $0.endMilliseconds)
                        < ($1.startMilliseconds, $1.endMilliseconds)
                }
                guard
                    let chapterStartMilliseconds = Self.milliseconds(
                        chapter.start
                    ),
                    let chapterEndMilliseconds = Self.milliseconds(
                        chapter.end
                    )
                else {
                    await fail(
                        taskID: taskID,
                        bookKey: bookKey,
                        chapterID: chapter.id,
                        failure: .invalidChapterRange
                    )
                    return
                }
                state = .saving(progress)
                let cachedTranscript = CachedChapterTranscript(
                    chapterID: chapter.id,
                    chapterTitle: chapter.title,
                    chapterStartMilliseconds: chapterStartMilliseconds,
                    chapterEndMilliseconds: chapterEndMilliseconds,
                    localeIdentifier: Locale.current.identifier,
                    segments: sortedTranscript.map(
                        CachedTranscriptSegment.init(transcript:)
                    )
                )
                do {
                    try await appModel.saveCachedChapterTranscript(
                        cachedTranscript,
                        for: account,
                        itemID: detail.id
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if Task.isCancelled {
                        throw CancellationError()
                    }
                    cacheFailures[bookKey] = .saveFailed
                    await fail(
                        taskID: taskID,
                        bookKey: bookKey,
                        chapterID: chapter.id,
                        failure: .cacheSaveFailed
                    )
                    return
                }
                guard activeTaskID == taskID else {
                    return
                }
                updateCache(
                    cachedTranscript,
                    for: bookKey
                )
                completedChapterIDs.append(chapter.id)
                activeCompletedChapterIDs = completedChapterIDs
                try Task.checkCancellation()
            }

            guard activeTaskID == taskID else {
                return
            }
            state = .complete(
                bookKey: bookKey,
                chapterIDs: completedChapterIDs
            )
            guard let batch = activeBatch else {
                finishTask(taskID)
                return
            }
            let terminalState = Self.terminalState(
                batch: batch,
                completedChapterIDs: completedChapterIDs,
                currentChapterID: nil,
                outcome: .succeeded,
                failure: nil
            )
            terminalStatesByBook[bookKey] = terminalState
            markMutated(bookKey)
            finishTask(taskID)
            await persist(
                terminalState,
                batch: batch,
                appModel: appModel
            )
        } catch is CancellationError {
            await fail(
                taskID: taskID,
                bookKey: bookKey,
                chapterID: currentChapterID,
                failure: .cancelled
            )
        } catch let failure as ChapterTranscriptionFailure {
            if Task.isCancelled {
                await fail(
                    taskID: taskID,
                    bookKey: bookKey,
                    chapterID: currentChapterID,
                    failure: .cancelled
                )
                return
            }
            await fail(
                taskID: taskID,
                bookKey: bookKey,
                chapterID: currentChapterID,
                failure: .transcription(failure)
            )
        } catch {
            if Task.isCancelled {
                await fail(
                    taskID: taskID,
                    bookKey: bookKey,
                    chapterID: currentChapterID,
                    failure: .cancelled
                )
                return
            }
            await fail(
                taskID: taskID,
                bookKey: bookKey,
                chapterID: currentChapterID,
                failure: .localAudioUnavailable
            )
        }
    }

    private func updateCache(
        _ transcript: CachedChapterTranscript,
        for bookKey: ChapterTranscriptionBookKey
    ) {
        var transcripts = cachedTranscriptsByBook[bookKey] ?? []
        transcripts.removeAll { $0.chapterID == transcript.chapterID }
        transcripts.append(transcript)
        transcripts.sort {
            ($0.chapterStartMilliseconds, $0.chapterID)
                < ($1.chapterStartMilliseconds, $1.chapterID)
        }
        cachedTranscriptsByBook[bookKey] = transcripts
        cacheFailures[bookKey] = nil
        markMutated(bookKey)
        scheduleExpiryIfInactive(for: bookKey)
    }

    private func fail(
        taskID: UUID,
        bookKey: ChapterTranscriptionBookKey,
        chapterID: Int?,
        failure: ChapterTranscriptionViewFailure
    ) async {
        guard activeTaskID == taskID,
            let batch = activeBatch,
            let appModel = activeAppModel
        else {
            return
        }
        let completedChapterIDs = activeCompletedChapterIDs
        state = .failed(
            bookKey: bookKey,
            chapterID: chapterID,
            failure: failure
        )
        let outcome: CachedChapterTranscriptionTaskOutcome =
            failure == .cancelled ? .cancelled : .failed
        let terminalState = Self.terminalState(
            batch: batch,
            completedChapterIDs: completedChapterIDs,
            currentChapterID: chapterID,
            outcome: outcome,
            failure: failure.cachedTaskFailure
        )
        terminalStatesByBook[bookKey] = terminalState
        markMutated(bookKey)
        finishTask(taskID)
        if outcome == .cancelled {
            Task { [weak self, weak appModel] in
                guard let self, let appModel else {
                    return
                }
                await self.persist(
                    terminalState,
                    batch: batch,
                    appModel: appModel
                )
            }
        } else {
            await persist(
                terminalState,
                batch: batch,
                appModel: appModel
            )
        }
    }

    private func finishTask(_ taskID: UUID) {
        guard activeTaskID == taskID else {
            return
        }
        transcriptionTask = nil
        let bookKey = activeBatch?.bookKey
        activeTaskID = nil
        activeBatch = nil
        activeAppModel = nil
        activeCompletedChapterIDs = []
        if let bookKey {
            scheduleExpiryIfInactive(for: bookKey)
        }
    }

    private func cancelWithoutPersisting() {
        transcriptionTask?.cancel()
        guard let taskID = activeTaskID else {
            return
        }
        finishTask(taskID)
    }

    private func startCacheMaintenance() {
        let reapInterval = transcriptCacheReapInterval
        cacheReaperTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: reapInterval)
                } catch {
                    return
                }
                self?.reapExpiredTranscriptCaches()
            }
        }
        #if canImport(UIKit)
            memoryWarningTask = Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: UIApplication.didReceiveMemoryWarningNotification
                ) {
                    guard !Task.isCancelled else {
                        return
                    }
                    self?.evictInactiveTranscriptCachesForMemoryPressure()
                }
            }
        #endif
    }

    private func revision(
        for bookKey: ChapterTranscriptionBookKey
    ) -> UInt64 {
        bookRevisions[bookKey] ?? 0
    }

    private func markMutated(_ bookKey: ChapterTranscriptionBookKey) {
        bookRevisions[bookKey, default: 0] &+= 1
    }

    private func invalidateBook(_ bookKey: ChapterTranscriptionBookKey) {
        loadTokens[bookKey] = nil
        markMutated(bookKey)
    }

    private func invalidateBooks(
        where predicate: (ChapterTranscriptionBookKey) -> Bool
    ) {
        let bookKeys = Set(bookRevisions.keys)
            .union(loadTokens.keys)
            .union(cachedTranscriptsByBook.keys)
            .union(viewRetentionCounts.keys)
            .union(cacheExpiryDeadlines.keys)
            .filter(predicate)
        for bookKey in bookKeys {
            invalidateBook(bookKey)
        }
    }

    private func isCacheProtected(
        _ bookKey: ChapterTranscriptionBookKey
    ) -> Bool {
        (viewRetentionCounts[bookKey] ?? 0) > 0
            || activeBatch?.bookKey == bookKey
    }

    private func scheduleExpiryIfInactive(
        for bookKey: ChapterTranscriptionBookKey
    ) {
        guard cachedTranscriptsByBook[bookKey] != nil,
            !isCacheProtected(bookKey)
        else {
            cacheExpiryDeadlines[bookKey] = nil
            return
        }
        cacheExpiryDeadlines[bookKey] = .now.advanced(
            by: transcriptCacheTTL
        )
    }

    private func evictTranscriptCache(
        for bookKey: ChapterTranscriptionBookKey
    ) {
        cachedTranscriptsByBook[bookKey] = nil
        cacheExpiryDeadlines[bookKey] = nil
        invalidateBook(bookKey)
    }

    private func persist(
        _ terminalState: CachedChapterTranscriptionTaskState,
        batch: ActiveChapterTranscriptionBatch,
        appModel: AppModel
    ) async {
        guard isTerminalPersistenceValid(for: batch) else {
            return
        }
        defer {
            if isTerminalPersistenceValid(for: batch) {
                pendingTerminalPersistence[batch.taskID] = nil
            }
        }
        do {
            try await appModel.saveCachedChapterTranscriptionTaskState(
                terminalState,
                for: batch.account,
                itemID: batch.bookKey.itemID
            )
            guard isTerminalPersistenceValid(for: batch),
                terminalStatesByBook[batch.bookKey]?.taskID
                    == terminalState.taskID
            else {
                return
            }
            if cacheFailures[batch.bookKey] == .taskStateLoadFailed
                || cacheFailures[batch.bookKey] == .taskStateSaveFailed
            {
                cacheFailures[batch.bookKey] = nil
            }
        } catch is CancellationError {
            guard isTerminalPersistenceValid(for: batch),
                terminalStatesByBook[batch.bookKey]?.taskID
                    == terminalState.taskID
            else {
                return
            }
            cacheFailures[batch.bookKey] = .taskStateSaveFailed
        } catch {
            guard isTerminalPersistenceValid(for: batch),
                terminalStatesByBook[batch.bookKey]?.taskID
                    == terminalState.taskID
            else {
                return
            }
            cacheFailures[batch.bookKey] = .taskStateSaveFailed
        }
    }

    private func isTerminalPersistenceValid(
        for batch: ActiveChapterTranscriptionBatch
    ) -> Bool {
        pendingTerminalPersistence[batch.taskID]?.token
            == batch.persistenceToken
    }

    private func invalidateTerminalPersistence(
        where predicate: (
            (bookKey: ChapterTranscriptionBookKey, token: UUID)
        ) -> Bool
    ) {
        pendingTerminalPersistence = pendingTerminalPersistence.filter {
            !predicate($0.value)
        }
    }

    private static func terminalState(
        batch: ActiveChapterTranscriptionBatch,
        completedChapterIDs: [Int],
        currentChapterID: Int?,
        outcome: CachedChapterTranscriptionTaskOutcome,
        failure: CachedChapterTranscriptionTaskFailure?
    ) -> CachedChapterTranscriptionTaskState {
        let finishedAt = max(Date(), batch.startedAt)
        return CachedChapterTranscriptionTaskState(
            taskID: batch.taskID,
            selectedChapterIDs: batch.selectedChapterIDs,
            completedChapterIDs: completedChapterIDs,
            currentChapterID: currentChapterID,
            outcome: outcome,
            failure: failure,
            startedAt: batch.startedAt,
            finishedAt: finishedAt,
            durationMilliseconds: elapsedMilliseconds(
                since: batch.startedInstant
            )
        )
    }

    private static func elapsedMilliseconds(
        since start: ContinuousClock.Instant
    ) -> Int64 {
        let components = start.duration(to: .now).components
        guard components.seconds >= 0,
            components.attoseconds >= 0
        else {
            return 0
        }
        let (milliseconds, overflow) =
            components.seconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else {
            return Int64.max
        }
        let fractionalMilliseconds =
            components.attoseconds / 1_000_000_000_000_000
        let (result, additionOverflow) =
            milliseconds
            .addingReportingOverflow(fractionalMilliseconds)
        return additionOverflow ? Int64.max : result
    }

    private static func bookKey(
        detail: LibraryBookDetail,
        account: ServerAccount
    ) -> ChapterTranscriptionBookKey {
        ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )
    }

    private static func loadAudio(
        detail: LibraryBookDetail,
        account: ServerAccount,
        downloads: DownloadModel,
        chapters: [PlaybackChapter]
    ) async throws -> PreparedChapterTranscriptionAudio {
        guard
            let record = downloads.record(
                accountID: account.id,
                itemID: detail.id
            )
        else {
            throw ChapterTranscriptionAudioLoadFailure.audioNotDownloaded
        }

        let entries = record.manifest.entries.sorted {
            $0.trackIndex < $1.trackIndex
        }
        let timelineTracks: [ChapterAudioTrack] = entries.compactMap {
            entry in
            guard let startOffset = entry.startOffset,
                let duration = entry.duration
            else {
                return nil
            }
            return ChapterAudioTrack(
                trackIndex: entry.trackIndex,
                startOffsetSeconds: startOffset,
                durationSeconds: duration
            )
        }
        if timelineTracks.count == entries.count {
            var requiredTrackIndexes: Set<Int> = []
            do {
                for chapter in chapters {
                    requiredTrackIndexes.formUnion(
                        try ChapterAudioSlicePlanner.slices(
                            for: chapter,
                            tracks: timelineTracks
                        ).map(\.trackIndex)
                    )
                }
            } catch {
                throw ChapterTranscriptionAudioLoadFailure
                    .localAudioUnavailable
            }
            let entriesByIndex = Dictionary(
                uniqueKeysWithValues: entries.map { ($0.trackIndex, $0) }
            )
            guard
                requiredTrackIndexes.allSatisfy({ trackIndex in
                    guard let entry = entriesByIndex[trackIndex] else {
                        return false
                    }
                    return entry.state == .complete
                        && entry.placement == .finalized
                        && entry.observedByteLength == entry.expectedByteLength
                })
            else {
                throw ChapterTranscriptionAudioLoadFailure.audioNotDownloaded
            }
            let pin = downloads.pinAutomaticCacheTracks(
                for: record,
                trackIndexes: requiredTrackIndexes
            )
            let urlsByIndex: [Int: URL]
            do {
                urlsByIndex = try await downloads.localTrackURLs(
                    for: record,
                    trackIndexes: requiredTrackIndexes
                )
            } catch {
                downloads.releaseAutomaticCachePin(pin)
                throw ChapterTranscriptionAudioLoadFailure
                    .localAudioUnavailable
            }
            let tracks = timelineTracks.compactMap { timeline in
                urlsByIndex[timeline.trackIndex].map {
                    PreparedChapterTranscriptionTrack(
                        timeline: timeline,
                        url: $0
                    )
                }
            }
            guard tracks.count == requiredTrackIndexes.count else {
                downloads.releaseAutomaticCachePin(pin)
                throw ChapterTranscriptionAudioLoadFailure
                    .localAudioUnavailable
            }
            return PreparedChapterTranscriptionAudio(
                tracks: tracks,
                cachePin: pin
            )
        }

        guard downloads.isFullBookAvailable(record) else {
            throw ChapterTranscriptionAudioLoadFailure.localAudioUnavailable
        }
        let allTrackIndexes = Set(entries.map(\.trackIndex))
        let pin = downloads.pinAutomaticCacheTracks(
            for: record,
            trackIndexes: allTrackIndexes
        )
        do {
            let urls = try await downloads.localTrackURLs(for: record)
            let durations = try await audioDurations(for: urls)
            guard urls.count == durations.count, !urls.isEmpty else {
                throw ChapterTranscriptionAudioLoadFailure
                    .localAudioUnavailable
            }
            var nextStartOffset = 0.0
            let tracks = zip(entries, zip(urls, durations)).map {
                entry, urlAndDuration in
                let (url, duration) = urlAndDuration
                defer { nextStartOffset += duration }
                return PreparedChapterTranscriptionTrack(
                    timeline: ChapterAudioTrack(
                        trackIndex: entry.trackIndex,
                        startOffsetSeconds: nextStartOffset,
                        durationSeconds: duration
                    ),
                    url: url
                )
            }
            return PreparedChapterTranscriptionAudio(
                tracks: tracks,
                cachePin: pin
            )
        } catch is CancellationError {
            downloads.releaseAutomaticCachePin(pin)
            throw CancellationError()
        } catch {
            downloads.releaseAutomaticCachePin(pin)
            throw ChapterTranscriptionAudioLoadFailure.localAudioUnavailable
        }
    }

    private static func merge(
        loaded: [CachedChapterTranscript],
        current: [CachedChapterTranscript]
    ) -> [CachedChapterTranscript] {
        var transcriptsByChapterID: [Int: CachedChapterTranscript] = [:]
        for transcript in loaded {
            transcriptsByChapterID[transcript.chapterID] = transcript
        }
        for transcript in current {
            transcriptsByChapterID[transcript.chapterID] = transcript
        }
        return sorted(Array(transcriptsByChapterID.values))
    }

    private static func sorted(
        _ transcripts: [CachedChapterTranscript]
    ) -> [CachedChapterTranscript] {
        transcripts.sorted {
            ($0.chapterStartMilliseconds, $0.chapterID)
                < ($1.chapterStartMilliseconds, $1.chapterID)
        }
    }

    private static func audioDurations(
        for urls: [URL]
    ) async throws -> [Double] {
        try await Task.detached(priority: .utility) {
            try urls.map { url in
                let file = try AVAudioFile(forReading: url)
                let sampleRate = file.processingFormat.sampleRate
                guard sampleRate.isFinite, sampleRate > 0 else {
                    throw ChapterAudioSlicePlanFailure
                        .invalidTrackDurations
                }
                return Double(file.length) / sampleRate
            }
        }.value
    }

    private static func milliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite,
            seconds >= 0,
            seconds <= Double(Int64.max) / 1_000
        else {
            return nil
        }
        return Int64((seconds * 1_000).rounded())
    }
}

extension ChapterTranscriptionAudioLoadFailure {
    fileprivate var viewFailure: ChapterTranscriptionViewFailure {
        switch self {
        case .audioNotDownloaded:
            .audioNotDownloaded
        case .localAudioUnavailable:
            .localAudioUnavailable
        }
    }
}

extension TranscriptSegment {
    fileprivate init(cached: CachedTranscriptSegment) {
        self.init(
            startMilliseconds: cached.startMilliseconds,
            endMilliseconds: cached.endMilliseconds,
            text: cached.text
        )
    }
}

extension CachedTranscriptSegment {
    fileprivate init(transcript: TranscriptSegment) {
        self.init(
            startMilliseconds: transcript.startMilliseconds,
            endMilliseconds: transcript.endMilliseconds,
            text: transcript.text
        )
    }
}

struct ChapterTranscriptionView: View {
    let detail: LibraryBookDetail
    let account: ServerAccount
    let appModel: AppModel
    @Bindable var downloads: DownloadModel
    let model: ChapterTranscriptionModel
    @State private var selectedChapterID: Int?
    @State private var selectedChapterIDs: Set<Int> = []
    @State private var isSelectingChapters = false
    @State private var searchQuery = ""
    @State private var showDownloadConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(
        detail: LibraryBookDetail,
        account: ServerAccount,
        appModel: AppModel,
        downloads: DownloadModel
    ) {
        self.detail = detail
        self.account = account
        self.appModel = appModel
        self.downloads = downloads
        model = appModel.transcription
        _selectedChapterID = State(initialValue: detail.chapters.first?.id)
    }

    var body: some View {
        NavigationStack {
            List {
                if hasSearchQuery {
                    searchContent
                } else {
                    chapterSelector
                    cacheFailureContent
                    transcriptionStatusContent
                    selectedTranscriptContent
                }
            }
            .navigationTitle("Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchQuery,
                prompt: "Search Transcriptions"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isSelectingChapters ? "Cancel" : "Select") {
                        if isSelectingChapters {
                            selectedChapterIDs.removeAll()
                        }
                        isSelectingChapters.toggle()
                    }
                    .disabled(model.isWorking || hasSearchQuery)
                    .accessibilityIdentifier("transcription.select")
                }
            }
            .safeAreaInset(edge: .bottom) {
                actionBar
            }
            .confirmationDialog(
                "Download Audiobook?",
                isPresented: $showDownloadConfirmation,
                titleVisibility: .visible
            ) {
                Button("Download Audiobook") {
                    Task {
                        await downloads.download(
                            detail: detail,
                            account: account
                        )
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "Transcription uses verified audio stored on this device."
                )
            }
        }
        .accessibilityIdentifier("transcription.view")
        .onAppear {
            model.retainTranscriptCache(for: bookKey)
        }
        .onDisappear {
            model.releaseTranscriptCache(for: bookKey)
        }
        .task(id: "\(account.id.rawValue):\(detail.id.rawValue)") {
            await model.loadCachedTranscripts(
                detail: detail,
                account: account,
                appModel: appModel
            )
        }
    }

    @ViewBuilder
    private var chapterSelector: some View {
        Section {
            ForEach(detail.chapters, id: \.id) { chapter in
                Button {
                    if isSelectingChapters {
                        if selectedChapterIDs.contains(chapter.id) {
                            selectedChapterIDs.remove(chapter.id)
                        } else {
                            selectedChapterIDs.insert(chapter.id)
                        }
                    } else {
                        selectedChapterID = chapter.id
                    }
                } label: {
                    HStack {
                        Text(chapter.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if model.isCached(
                            chapterID: chapter.id,
                            for: bookKey
                        ) {
                            Image(systemName: "text.badge.checkmark")
                                .accessibilityLabel("Transcribed")
                        }
                        if model.state.currentChapterID == chapter.id,
                            model.isWorking(for: bookKey)
                        {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Transcribing")
                        }
                        if isSelectingChapters {
                            Image(
                                systemName: selectedChapterIDs.contains(
                                    chapter.id
                                )
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(
                                selectedChapterIDs.contains(chapter.id)
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                        } else if selectedChapterID == chapter.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityIdentifier(
                    "transcription.chapter.\(chapter.id)"
                )
            }
        } header: {
            HStack {
                Text("Chapters")
                Spacer()
                if isSelectingChapters {
                    Button("Select All") {
                        selectedChapterIDs = Set(
                            detail.chapters.map(\.id)
                        )
                    }
                    .disabled(
                        selectedChapterIDs.count == detail.chapters.count
                    )
                    .accessibilityIdentifier("transcription.selectAll")
                }
            }
        }
    }

    @ViewBuilder
    private var cacheFailureContent: some View {
        if let failure = model.cacheFailure(for: bookKey) {
            Section {
                Label(
                    failure.message,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let matches = model.searchResults(
            query: searchQuery,
            for: bookKey
        )
        Section("Search Results") {
            if matches.isEmpty {
                Text("No cached transcription matches this search.")
            } else {
                ForEach(Array(matches.enumerated()), id: \.offset) {
                    _, match in
                    Button {
                        selectedChapterID = match.chapterID
                        searchQuery = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                "\(match.chapterTitle) - \(timestamp(match.segment.startMilliseconds))"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            Text(match.segment.text)
                                .foregroundStyle(.primary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "transcription.searchResult.\(match.chapterID)"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptionStatusContent: some View {
        if model.isWorking, !model.isWorking(for: bookKey) {
            Section {
                Label(
                    "Another audiobook is being transcribed.",
                    systemImage: "waveform.badge.mic"
                )
            }
        } else if let state = model.state(for: bookKey) {
            switch state {
            case .ready:
                EmptyView()
            case .preparingAudio(_, let totalChapters):
                Section {
                    ProgressView("Preparing \(chapterCountText(totalChapters))")
                }
            case .transcribing(
                let progress,
                let completedSlices,
                let totalSlices
            ):
                Section {
                    ProgressView(
                        value: Double(progress.completedChapters),
                        total: Double(max(progress.totalChapters, 1))
                    )
                    Text(
                        "Transcribing \(progress.chapterTitle) (\(progress.completedChapters + 1) of \(progress.totalChapters))"
                    )
                    if totalSlices > 1 {
                        Text(
                            "Audio file \(completedSlices + 1) of \(totalSlices)"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            case .saving(let progress):
                Section {
                    ProgressView(
                        "Saving \(progress.chapterTitle) (\(progress.completedChapters + 1) of \(progress.totalChapters))"
                    )
                }
            case .cancelling:
                Section {
                    ProgressView("Cancelling transcription")
                }
            case .complete(_, let chapterIDs):
                if let terminalState = model.terminalState(for: bookKey) {
                    terminalStateContent(terminalState)
                } else {
                    Section {
                        Label(
                            "Transcribed \(chapterCountText(chapterIDs.count)).",
                            systemImage: "checkmark.circle"
                        )
                    }
                }
            case .failed(_, _, let failure):
                if let terminalState = model.terminalState(for: bookKey) {
                    terminalStateContent(terminalState)
                } else {
                    Section {
                        Label(
                            failure.message,
                            systemImage: "exclamationmark.triangle"
                        )
                        if failure == .audioNotDownloaded {
                            Button("Download Audiobook") {
                                showDownloadConfirmation = true
                            }
                        }
                    }
                }
            }
        } else if let terminalState = model.terminalState(for: bookKey) {
            terminalStateContent(terminalState)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func terminalStateContent(
        _ terminalState: CachedChapterTranscriptionTaskState
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                switch terminalState.outcome {
                case .succeeded:
                    Label(
                        "Transcribed \(chapterCountText(terminalState.completedChapterIDs.count)) in \(elapsedTime(terminalState.durationMilliseconds)).",
                        systemImage: "checkmark.circle"
                    )
                case .failed:
                    Label(
                        terminalState.failure?.message
                            ?? "Transcription failed.",
                        systemImage: "exclamationmark.triangle"
                    )
                    Text(
                        "Failed after \(elapsedTime(terminalState.durationMilliseconds))."
                    )
                    .foregroundStyle(.secondary)
                case .cancelled:
                    Label(
                        "Transcription was cancelled.",
                        systemImage: "xmark.circle"
                    )
                    Text(
                        "Cancelled after \(elapsedTime(terminalState.durationMilliseconds))."
                    )
                    .foregroundStyle(.secondary)
                }
                if terminalState.completedChapterIDs.count
                    < terminalState.selectedChapterIDs.count
                {
                    Text(
                        "\(terminalState.completedChapterIDs.count) of \(terminalState.selectedChapterIDs.count) chapters completed."
                    )
                    .foregroundStyle(.secondary)
                }
                Text(
                    "Finished \(terminalState.finishedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("transcription.terminalState")
            if terminalState.failure == .audioNotDownloaded {
                Button("Download Audiobook") {
                    showDownloadConfirmation = true
                }
            }
        }
    }

    @ViewBuilder
    private var selectedTranscriptContent: some View {
        if let selectedChapterID,
            let segments = model.transcriptSegments(
                chapterID: selectedChapterID,
                for: bookKey
            )
        {
            Section("Transcript") {
                if segments.isEmpty {
                    Text("No speech was detected in this chapter.")
                } else {
                    ForEach(
                        Array(segments.enumerated()),
                        id: \.offset
                    ) { _, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(timestamp(segment.startMilliseconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(segment.text)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if hasSearchQuery {
            EmptyView()
        } else if model.isCancelling(for: bookKey) {
            Button("Cancelling…") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
        } else if model.isWorking(for: bookKey) {
            Button("Cancel", role: .cancel) {
                model.cancel()
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        } else if model.isWorking {
            Button("Transcription in Progress") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
        } else if isSelectingChapters {
            Button(
                "Transcribe \(chapterCountText(selectedChapterIDs.count))",
                systemImage: "waveform.badge.mic"
            ) {
                let chapters =
                    ChapterTranscriptionBatchPlanner
                    .orderedChapters(
                        selectedChapterIDs: selectedChapterIDs,
                        from: detail.chapters
                    )
                selectedChapterID = chapters.first?.id
                model.start(
                    chapters: chapters,
                    detail: detail,
                    account: account,
                    downloads: downloads,
                    appModel: appModel
                )
                isSelectingChapters = false
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedChapterIDs.isEmpty)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("transcription.startBatch")
        } else {
            Button(
                model.isCached(
                    chapterID: selectedChapterID ?? Int.min,
                    for: bookKey
                )
                    ? "Transcribe Again"
                    : "Start Transcription",
                systemImage: "waveform.badge.mic"
            ) {
                guard let chapter = selectedChapter else {
                    return
                }
                model.start(
                    chapters: [chapter],
                    detail: detail,
                    account: account,
                    downloads: downloads,
                    appModel: appModel
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedChapter == nil)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("transcription.start")
        }
    }

    private var selectedChapter: PlaybackChapter? {
        detail.chapters.first { $0.id == selectedChapterID }
    }

    private var bookKey: ChapterTranscriptionBookKey {
        ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )
    }

    private var hasSearchQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func chapterCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "chapter" : "chapters")"
    }

    private func elapsedTime(_ milliseconds: Int64) -> String {
        let roundedSeconds = max(
            1,
            milliseconds / 1_000 + (milliseconds % 1_000 == 0 ? 0 : 1)
        )
        let hours = roundedSeconds / 3_600
        let minutes = (roundedSeconds / 60) % 60
        let seconds = roundedSeconds % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append("\(hours)h")
        }
        if minutes > 0 {
            parts.append("\(minutes)m")
        }
        if seconds > 0 || parts.isEmpty {
            parts.append("\(seconds)s")
        }
        return parts.joined(separator: " ")
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1_000
        return String(
            format: "%02lld:%02lld:%02lld",
            totalSeconds / 3_600,
            (totalSeconds / 60) % 60,
            totalSeconds % 60
        )
    }
}
