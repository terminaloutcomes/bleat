import AVFoundation
import BleatCore
import BleatTranscription
import Foundation
import Observation

#if canImport(UIKit)
    import UIKit
#endif

@MainActor
@Observable
final class ChapterTranscriptionModel {
    @ObservationIgnored
    private let remoteTelemetryTracer: any RemoteTelemetryTracing
    @ObservationIgnored
    private var remoteTelemetrySpan: RemoteTelemetrySpan?
    private(set) var state: ChapterTranscriptionViewState = .ready
    private(set) var cachedTranscriptsByBook:
        [ChapterTranscriptionBookKey: [CachedChapterTranscript]] = [:]
    private(set) var cacheFailures:
        [ChapterTranscriptionBookKey: ChapterTranscriptCacheViewFailure] = [:]
    private(set) var terminalStatesByBook:
        [ChapterTranscriptionBookKey: CachedChapterTranscriptionTaskState] =
            [:]
    private var localDataPresenceByBook: [ChapterTranscriptionBookKey: Bool] =
        [:]
    private var localDataPresenceFailuresByBook:
        [ChapterTranscriptionBookKey: ChapterTranscriptLocalDataFailure] = [:]
    private var deletionStatesByBook:
        [ChapterTranscriptionBookKey: ChapterTranscriptDeletionState] = [:]
    @ObservationIgnored
    private var transcriptionTask: Task<Void, Never>?
    @ObservationIgnored
    private var transcriptionTasks:
        [UUID: (bookKey: ChapterTranscriptionBookKey, task: Task<Void, Never>)] =
            [:]
    @ObservationIgnored
    private var activeTaskID: UUID?
    private(set) var jobsByBook:
        [ChapterTranscriptionBookKey: ChapterTranscriptionJob] = [:]
    private var jobLoadFinished: Set<ChapterTranscriptionBookKey> = []
    private let sourceIdentityLoader: ChapterTranscriptionSourceLoader
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
    private var presenceTokens: [ChapterTranscriptionBookKey: UUID] = [:]
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
        sourceIdentityLoader: ChapterTranscriptionSourceLoader? = nil,
        transcriberFactory: ChapterTranscriberFactory? = nil,
        remoteTelemetryTracer: any RemoteTelemetryTracing =
            InactiveRemoteTelemetryTracer()
    ) {
        self.remoteTelemetryTracer = remoteTelemetryTracer
        self.transcriptCacheTTL = transcriptCacheTTL
        self.transcriptCacheReapInterval = transcriptCacheReapInterval
        self.audioLoader = audioLoader ?? Self.loadAudio
        self.sourceIdentityLoader =
            sourceIdentityLoader ?? ChapterTranscriptionSourceValidator.load
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
        do {
            let loadedJob = try await appModel.transcriptionJob(
                for: account, itemID: detail.id)
            guard loadTokens[bookKey] == loadToken,
                revision(for: bookKey) == startingRevision
            else { return }
            jobsByBook[bookKey] = loadedJob
            jobLoadFinished.insert(bookKey)
            if case .job = cacheFailures[bookKey] {
                cacheFailures[bookKey] = nil
            }
        } catch {
            guard loadTokens[bookKey] == loadToken,
                revision(for: bookKey) == startingRevision
            else { return }
            jobLoadFinished.remove(bookKey)
            cacheFailures[bookKey] = .job(Self.jobFailure(error))
        }

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
            localDataPresenceByBook[bookKey] =
                cachedTranscriptsByBook[bookKey]?.isEmpty == false
                || terminalStatesByBook[bookKey] != nil
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
            localDataPresenceByBook[bookKey] =
                cachedTranscriptsByBook[bookKey]?.isEmpty == false
                || terminalStatesByBook[bookKey] != nil
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

    func hasLoadedTranscriptCache(
        for bookKey: ChapterTranscriptionBookKey
    ) -> Bool {
        cachedTranscriptsByBook[bookKey] != nil
            && jobLoadFinished.contains(bookKey)
    }

    func chaptersNeedingTranscription(
        _ chapters: [PlaybackChapter],
        for bookKey: ChapterTranscriptionBookKey
    ) -> [PlaybackChapter] {
        guard let cachedTranscripts = cachedTranscriptsByBook[bookKey] else {
            return chapters
        }
        let cachedChapterIDs = Set(cachedTranscripts.map(\.chapterID))
        return chapters.filter { !cachedChapterIDs.contains($0.id) }
    }

    func transcriptSegments(
        chapterID: Int,
        for bookKey: ChapterTranscriptionBookKey
    ) -> [TranscriptSegment]? {
        cachedTranscriptsByBook[bookKey]?
            .first { $0.chapterID == chapterID }?
            .segments.map(TranscriptSegment.init(cached:))
    }

    func transcriptExportSnapshot(
        for bookKey: ChapterTranscriptionBookKey,
        expectedChapterIDs: [Int]
    ) -> ChapterTranscriptExportSnapshot {
        ChapterTranscriptExportSnapshot(
            transcripts: cachedTranscriptsByBook[bookKey] ?? [],
            expectedChapterIDs: expectedChapterIDs
        )
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

    func hasLocalData(for bookKey: ChapterTranscriptionBookKey) -> Bool {
        localDataPresenceByBook[bookKey] == true || jobsByBook[bookKey] != nil
    }

    func deletionState(
        for bookKey: ChapterTranscriptionBookKey
    ) -> ChapterTranscriptDeletionState {
        deletionStatesByBook[bookKey] ?? .idle
    }

    func localDataPresenceFailure(
        for bookKey: ChapterTranscriptionBookKey
    ) -> ChapterTranscriptLocalDataFailure? {
        localDataPresenceFailuresByBook[bookKey]
    }

    func refreshLocalDataPresence(
        detail: LibraryBookDetail,
        account: ServerAccount,
        appModel: AppModel
    ) async {
        let bookKey = Self.bookKey(detail: detail, account: account)
        let token = UUID()
        let startingRevision = revision(for: bookKey)
        presenceTokens[bookKey] = token
        defer {
            if presenceTokens[bookKey] == token {
                presenceTokens[bookKey] = nil
            }
        }
        do {
            let containsData =
                try await appModel.hasCachedChapterTranscriptData(
                    for: account,
                    itemID: detail.id
                )
            guard presenceTokens[bookKey] == token,
                revision(for: bookKey) == startingRevision
            else {
                return
            }
            localDataPresenceByBook[bookKey] = containsData
            localDataPresenceFailuresByBook[bookKey] = nil
        } catch let error {
            guard presenceTokens[bookKey] == token,
                revision(for: bookKey) == startingRevision
            else {
                return
            }
            localDataPresenceFailuresByBook[bookKey] =
                ChapterTranscriptLocalDataFailure(
                    stage: .presenceInspection,
                    cause: error
                )
        }
    }

    @discardableResult
    func deleteLocalData(
        detail: LibraryBookDetail,
        account: ServerAccount,
        appModel: AppModel
    ) async -> Bool {
        let bookKey = Self.bookKey(detail: detail, account: account)
        guard deletionState(for: bookKey) != .deleting else {
            return false
        }
        deletionStatesByBook[bookKey] = .deleting
        invalidateTerminalPersistence { $0.bookKey == bookKey }
        invalidateBook(bookKey)

        let tasks = transcriptionTasks.values.compactMap {
            $0.bookKey == bookKey ? $0.task : nil
        }
        if activeBatch?.bookKey == bookKey {
            state = .cancelling(
                bookKey: bookKey,
                chapterID: state.currentChapterID
            )
            cancelWithoutPersisting()
        }
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            await task.value
        }

        do {
            try await appModel.deleteCachedChapterTranscriptData(
                for: account,
                itemID: detail.id
            )
            cachedTranscriptsByBook[bookKey] = []
            terminalStatesByBook[bookKey] = nil
            jobsByBook[bookKey] = nil
            localDataPresenceByBook[bookKey] = false
            localDataPresenceFailuresByBook[bookKey] = nil
            cacheExpiryDeadlines[bookKey] = nil
            cacheFailures[bookKey] = nil
            deletionStatesByBook[bookKey] = .idle
            if state.bookKey == bookKey {
                state = .ready
            }
            markMutated(bookKey)
            return true
        } catch let error {
            deletionStatesByBook[bookKey] = .failed(
                ChapterTranscriptLocalDataFailure(
                    stage: .deletion,
                    cause: error
                )
            )
            if state.bookKey == bookKey {
                state = .ready
            }
            return false
        }
    }

    func dismissDeletionFailure(for bookKey: ChapterTranscriptionBookKey) {
        guard case .failed = deletionState(for: bookKey) else {
            return
        }
        deletionStatesByBook[bookKey] = .idle
    }

    func dismissLocalDataPresenceFailure(
        for bookKey: ChapterTranscriptionBookKey
    ) {
        localDataPresenceFailuresByBook[bookKey] = nil
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

    func resolveTranscriptPosition(
        _ position: Double,
        detail: LibraryBookDetail,
        account: ServerAccount
    ) -> ChapterTranscriptPositionResolution {
        let bookKey = Self.bookKey(detail: detail, account: account)
        return ChapterTranscriptPositionResolver.resolve(
            position: position,
            chapters: detail.chapters,
            transcripts: cachedTranscriptsByBook[bookKey] ?? []
        )
    }

    func resumableJob(for bookKey: ChapterTranscriptionBookKey)
        -> ChapterTranscriptionJob?
    {
        guard let job = jobsByBook[bookKey], !job.unfinishedChapters.isEmpty
        else { return nil }
        return job
    }

    func start(
        chapters selectedChapters: [PlaybackChapter],
        detail: LibraryBookDetail,
        account: ServerAccount,
        downloads: DownloadModel,
        appModel: AppModel,
        resume: Bool = false,
        replacePending: Bool = false
    ) {
        let bookKey = Self.bookKey(detail: detail, account: account)
        guard activeTaskID == nil, !isWorking,
            deletionState(for: bookKey) != .deleting
        else { return }
        let savedJob = resumableJob(for: bookKey)
        if savedJob != nil && !resume && !replacePending { return }
        if resume && savedJob == nil { return }
        let chapters: [PlaybackChapter]
        if resume, let savedJob {
            do {
                chapters =
                    try ChapterTranscriptionResumePlanner.selectedChapters(
                        job: savedJob, detail: detail
                    )
                    .filter { !savedJob.completedChapterIDs.contains($0.id) }
            } catch {
                state = .failed(
                    bookKey: bookKey, chapterID: nil, failure: .job(error))
                Task { await appModel.recordTranscriptionSourceFailure(error) }
                return
            }
        } else {
            chapters = chaptersNeedingTranscription(
                ChapterTranscriptionBatchPlanner.orderedChapters(
                    selectedChapterIDs: Set(selectedChapters.map(\.id)),
                    from: detail.chapters), for: bookKey)
        }
        guard !chapters.isEmpty else { return }
        let batch = ActiveChapterTranscriptionBatch(
            taskID: UUID(),
            persistenceToken: UUID(),
            bookKey: bookKey,
            account: account,
            selectedChapterIDs: resume
                ? (savedJob?.chapters.map(\.id) ?? []) : chapters.map(\.id),
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
        activeCompletedChapterIDs =
            resume ? (savedJob?.completedChapterIDs ?? []) : []
        remoteTelemetrySpan = remoteTelemetryTracer.beginSpan(
            operation: .transcription,
            source: .downloaded
        )
        cacheExpiryDeadlines[bookKey] = nil
        state = .preparingAudio(
            bookKey: bookKey,
            totalChapters: chapters.count
        )
        let task = Task(priority: .utility) { [weak self] in
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
                appModel: appModel,
                resume: resume,
                replacePending: replacePending
            )
            self.transcriptionTaskDidFinish(taskID)
        }
        transcriptionTask = task
        transcriptionTasks[taskID] = (bookKey, task)
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
        jobsByBook = jobsByBook.filter { $0.key.accountID != accountID }
        jobLoadFinished = jobLoadFinished.filter { $0.accountID != accountID }
        terminalStatesByBook = terminalStatesByBook.filter {
            $0.key.accountID != accountID
        }
        localDataPresenceByBook = localDataPresenceByBook.filter {
            $0.key.accountID != accountID
        }
        localDataPresenceFailuresByBook =
            localDataPresenceFailuresByBook.filter {
                $0.key.accountID != accountID
            }
        deletionStatesByBook = deletionStatesByBook.filter {
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
        jobsByBook[bookKey] = nil
        jobLoadFinished.remove(bookKey)
        localDataPresenceByBook[bookKey] = nil
        localDataPresenceFailuresByBook[bookKey] = nil
        deletionStatesByBook[bookKey] = nil
    }

    func cancelAndWait(for accountID: AccountID) async {
        let tasks = transcriptionTasks.values.filter {
            $0.bookKey.accountID == accountID
        }.map(\.task)
        cancel(for: accountID)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    func cancelAndWait(for bookKey: ChapterTranscriptionBookKey) async {
        let tasks = transcriptionTasks.values.filter { $0.bookKey == bookKey }
            .map(\.task)
        cancel(for: bookKey)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
    }

    private static func jobFailure(_ error: Error)
        -> ChapterTranscriptionJobFailure
    {
        if let failure = error as? ChapterTranscriptionJobFailure {
            return failure
        }
        if case .transcriptCache(.job(let failure)) = error as? AppServiceError
        {
            return failure
        }
        return .persistenceFailed
    }

    private func checkpoint(
        _ next: ChapterTranscriptionJob,
        replacing previous: ChapterTranscriptionJob?,
        transcript: CachedChapterTranscript? = nil, taskID: UUID,
        bookKey: ChapterTranscriptionBookKey, account: ServerAccount,
        appModel: AppModel
    ) async throws {
        guard activeTaskID == taskID else { throw CancellationError() }
        try await appModel.saveTranscriptionJob(
            next, replacing: previous, transcript: transcript, for: account,
            itemID: bookKey.itemID)
        guard activeTaskID == taskID else { throw CancellationError() }
        jobsByBook[bookKey] = next
        localDataPresenceByBook[bookKey] = true
        markMutated(bookKey)
    }

    private func runBatch(
        taskID: UUID,
        chapters: [PlaybackChapter],
        bookKey: ChapterTranscriptionBookKey,
        detail: LibraryBookDetail,
        account: ServerAccount,
        downloads: DownloadModel,
        appModel: AppModel,
        resume: Bool,
        replacePending: Bool
    ) async {
        var currentChapterID: Int?
        var completedChapterIDs = activeCompletedChapterIDs
        do {
            let stored = try await appModel.transcriptionJob(
                for: account, itemID: detail.id)
            try Task.checkCancellation()
            guard activeTaskID == taskID else { return }
            var job: ChapterTranscriptionJob
            if resume {
                guard let stored, stored == jobsByBook[bookKey] else {
                    throw ChapterTranscriptionJobFailure.staleRevision
                }
                job = stored
            } else {
                guard
                    stored?.unfinishedChapters.isEmpty != false
                        || replacePending
                else { throw ChapterTranscriptionJobFailure.staleRevision }
                job = ChapterTranscriptionJob(
                    localeIdentifier: Locale.current.identifier,
                    chapters: chapters.map {
                        ChapterTranscriptionJobChapter(
                            id: $0.id, start: $0.start, end: $0.end)
                    })
                try await checkpoint(
                    job, replacing: stored, taskID: taskID, bookKey: bookKey,
                    account: account, appModel: appModel)
            }
            let selected =
                try ChapterTranscriptionResumePlanner.selectedChapters(
                    job: job, detail: detail)

            try Task.checkCancellation()
            let audio: PreparedChapterTranscriptionAudio
            do {
                audio = try await audioLoader(
                    detail,
                    account,
                    downloads,
                    selected
                )
            } catch let failure as ChapterTranscriptionAudioLoadFailure {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let cause: ChapterTranscriptionJobFailure =
                    failure == .audioNotDownloaded
                    ? .missingAudio : .insufficientSourceIdentity
                await appModel.recordTranscriptionSourceFailure(cause)
                await fail(
                    taskID: taskID,
                    bookKey: bookKey,
                    chapterID: nil,
                    failure: .job(cause)
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

            let identity: ChapterTranscriptionSourceIdentity
            do {
                identity = try await sourceIdentityLoader(
                    audio, detail, account, downloads)
            } catch {
                try Task.checkCancellation()
                let failure = Self.jobFailure(error)
                await appModel.recordTranscriptionSourceFailure(failure)
                throw failure
            }
            try Task.checkCancellation()
            if let original = job.source, original != identity {
                await appModel.recordTranscriptionSourceFailure(.sourceChanged)
                throw ChapterTranscriptionJobFailure.sourceChanged
            }
            let beforeSource = job
            job.source = identity
            for index in job.chapters.indices
            where job.chapters[index].state != .completed {
                job.chapters[index].state = .pending
            }
            job.revision += 1
            job.updatedAt = max(Date(), job.updatedAt)
            try await checkpoint(
                job, replacing: beforeSource, taskID: taskID, bookKey: bookKey,
                account: account, appModel: appModel)

            let transcriber = transcriberFactory()
            for (_, chapter) in chapters.enumerated() {
                try Task.checkCancellation()
                guard
                    let jobIndex = job.chapters.firstIndex(where: {
                        $0.id == chapter.id
                    })
                else { throw ChapterTranscriptionJobFailure.invalidCheckpoint }
                currentChapterID = chapter.id
                let beforeRunning = job
                job.chapters[jobIndex].state = .running
                job.revision += 1
                job.updatedAt = max(Date(), job.updatedAt)
                try await checkpoint(
                    job, replacing: beforeRunning, taskID: taskID,
                    bookKey: bookKey, account: account, appModel: appModel)
                let progress = ChapterTranscriptionBatchProgress(
                    bookKey: bookKey,
                    chapterID: chapter.id,
                    chapterTitle: chapter.title,
                    completedChapters: completedChapterIDs.count,
                    totalChapters: job.chapters.count
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
                let chapterSpan = remoteTelemetrySpan.map {
                    remoteTelemetryTracer.beginChildSpan(
                        operation: .transcriptionChapter,
                        parent: $0
                    )
                }
                var telemetryInput = ChapterTelemetryInputAccumulator()
                do {
                    for (sliceIndex, slice) in slices.enumerated() {
                        try Task.checkCancellation()
                        guard
                            let track = audio.tracks.first(where: {
                                $0.timeline.trackIndex == slice.trackIndex
                            })
                        else {
                            chapterSpan?.end(
                                .failed(.media),
                                transcriptionInput:
                                    telemetryInput.telemetryInput
                            )
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
                        let result = try await transcriber.transcribe(
                            ChapterTranscriptionRequest(
                                audioFileURL: track.url,
                                locale: Locale(
                                    identifier: job.localeIdentifier),
                                audioStartSeconds: slice.audioStartSeconds,
                                audioDurationSeconds: slice.durationSeconds,
                                chapterStartSeconds:
                                    slice.wholeBookStartSeconds
                            )
                        )
                        telemetryInput.append(result.input)
                        try Task.checkCancellation()
                        guard activeTaskID == taskID else {
                            chapterSpan?.end(
                                .cancelled,
                                transcriptionInput:
                                    telemetryInput.telemetryInput
                            )
                            return
                        }
                        transcript.append(contentsOf: result.segments)
                    }
                } catch is CancellationError {
                    chapterSpan?.end(
                        .cancelled,
                        transcriptionInput: telemetryInput.telemetryInput
                    )
                    throw CancellationError()
                } catch let failure as ChapterTranscriptionFailure {
                    chapterSpan?.end(
                        .failed(failure.remoteTelemetryFailureCategory),
                        transcriptionInput: telemetryInput.telemetryInput
                    )
                    throw failure
                } catch {
                    chapterSpan?.end(
                        .failed(.media),
                        transcriptionInput: telemetryInput.telemetryInput
                    )
                    throw error
                }
                chapterSpan?.end(
                    .succeeded,
                    transcriptionInput: telemetryInput.telemetryInput
                )
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
                    localeIdentifier: job.localeIdentifier,
                    segments: sortedTranscript.map(
                        CachedTranscriptSegment.init(transcript:)
                    )
                )
                do {
                    let beforeCommit = job
                    job.chapters[jobIndex].state = .completed
                    job.revision += 1
                    job.updatedAt = max(Date(), job.updatedAt)
                    try await checkpoint(
                        job, replacing: beforeCommit,
                        transcript: cachedTranscript, taskID: taskID,
                        bookKey: bookKey, account: account, appModel: appModel)
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
                completedChapterIDs.sort()
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
            localDataPresenceByBook[bookKey] = true
            markMutated(bookKey)
            remoteTelemetrySpan?.end(.succeeded)
            remoteTelemetrySpan = nil
            finishTask(taskID)
            await persist(
                terminalState,
                batch: batch,
                appModel: appModel
            )
        } catch let error as ChapterTranscriptionJobFailure {
            await fail(
                taskID: taskID, bookKey: bookKey, chapterID: currentChapterID,
                failure: .job(error))
        } catch let error as AppServiceError {
            await fail(
                taskID: taskID, bookKey: bookKey, chapterID: currentChapterID,
                failure: .job(Self.jobFailure(error)))
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
        localDataPresenceByBook[bookKey] = true
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
        if let previous = jobsByBook[bookKey], previous.source != nil,
            let index = previous.chapters.firstIndex(where: {
                $0.id == chapterID && $0.state != .completed
            })
        {
            var next = previous
            next.chapters[index].state = .failed(failure.cachedTaskFailure)
            next.revision += 1
            next.updatedAt = max(Date(), next.updatedAt)
            do {
                try await checkpoint(
                    next, replacing: previous, taskID: taskID, bookKey: bookKey,
                    account: batch.account, appModel: appModel)
            } catch {
                guard activeTaskID == taskID else { return }
                cacheFailures[bookKey] = .taskStateSaveFailed
            }
        }
        guard activeTaskID == taskID else { return }
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
        localDataPresenceByBook[bookKey] = true
        markMutated(bookKey)
        remoteTelemetrySpan?.end(failure.remoteTelemetryOutcome)
        remoteTelemetrySpan = nil
        finishTask(taskID)
        await persist(
            terminalState,
            batch: batch,
            appModel: appModel
        )
    }

    private func finishTask(_ taskID: UUID) {
        guard activeTaskID == taskID else {
            return
        }
        remoteTelemetrySpan?.end(.cancelled)
        remoteTelemetrySpan = nil
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

    private func transcriptionTaskDidFinish(_ taskID: UUID) {
        transcriptionTasks[taskID] = nil
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
        presenceTokens[bookKey] = nil
        markMutated(bookKey)
    }

    private func invalidateBooks(
        where predicate: (ChapterTranscriptionBookKey) -> Bool
    ) {
        let bookKeys = Set(bookRevisions.keys)
            .union(loadTokens.keys)
            .union(presenceTokens.keys)
            .union(cachedTranscriptsByBook.keys)
            .union(localDataPresenceFailuresByBook.keys)
            .union(deletionStatesByBook.keys)
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

        guard
            Set(record.manifest.entries.map(\.trackIndex)).count
                == record.manifest.entries.count
        else {
            throw ChapterTranscriptionAudioLoadFailure.localAudioUnavailable
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
        var durations: [Double] = []
        for url in urls {
            let duration = try await AVURLAsset(url: url).load(.duration)
                .seconds
            guard duration.isFinite, duration > 0 else {
                throw ChapterAudioSlicePlanFailure.invalidTrackDurations
            }
            durations.append(duration)
        }
        return durations
    }

    private static func milliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite,
            seconds >= 0,
            seconds <= Double(Int64.max) / 1_000
        else {
            return nil
        }
        let rounded = (seconds * 1_000).rounded()
        guard rounded < Double(Int64.max) else { return nil }
        return Int64(rounded)
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
    init(cached: CachedTranscriptSegment) {
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
