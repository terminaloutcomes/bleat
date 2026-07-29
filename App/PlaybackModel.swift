import AVFoundation
import BleatCore
import MediaPlayer
import Observation
import UIKit

enum PlaybackState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case playing
    case paused
    case ended
    case failed(AppFailure)
}

enum PlaybackSyncState: Equatable, Sendable {
    case idle
    case syncing
    case failed
}

enum BookmarkState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case saving
    case failed(AppFailure)
}

enum PlaybackSleepTimer: Equatable, Sendable {
    case duration(Date)
    case endOfChapter(Double)
}

enum PlaybackMediaServicesResetIntent: Equatable, Sendable {
    case play
    case pause

    static func decide(for state: PlaybackState) -> Self? {
        switch state {
        case .playing:
            .play
        case .ready, .paused:
            .pause
        case .idle, .preparing, .ended, .failed:
            nil
        }
    }
}

struct PlaybackPositionConflict: Equatable, Sendable {
    let localTime: Double
    let serverTime: Double
}

private struct AutomaticDownloadSignal: Equatable {
    let chapterID: Int?
    let fileIndex: Int?
}

@MainActor
@Observable
final class PlaybackModel {
    private let service: any AppServicing
    private let positionStore: PlaybackPositionStore
    private let localSessionStore: LocalPlaybackSessionStore
    private let bookmarkMutationStore: BookmarkMutationStore
    private let preferencesStore: PlaybackPreferencesStore
    private let audioSessionActivation: @MainActor @Sendable () throws -> Void
    private let queuePlanning:
        @MainActor @Sendable (
            AppPlaybackPreparation,
            Double
        ) throws -> AppPlaybackQueuePlan
    private var generation: UInt64 = 0
    private var player: AVQueuePlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var offsetsByItem: [ObjectIdentifier: Double] = [:]
    private var activeAccount: ServerAccount?
    private var localAccountID: AccountID?
    private var preparation: AppPlaybackPreparation?
    private var localPlaybackSession: LocalPlaybackSession?
    private var sleepTask: Task<Void, Never>?
    private var pausedAt: Date?
    private var resumeAfterInterruption = false
    private var lastAttemptedSyncTime: Double = 0
    private var lastPersistedLocalTime: Double = 0
    private var activeDownloadDetail: LibraryBookDetail?
    private var lastAutomaticDownloadSignal: AutomaticDownloadSignal?
    @ObservationIgnored
    private var automaticDownloadHandler:
        (@MainActor @Sendable (AutomaticDownloadActivity) async -> Void)?

    private(set) var state: PlaybackState = .idle
    private(set) var syncState: PlaybackSyncState = .idle
    private(set) var itemID: LibraryItemID?
    private(set) var title = ""
    private(set) var author = ""
    private(set) var narrator = ""
    private(set) var coverURL: URL?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    private(set) var sleepTimer: PlaybackSleepTimer?
    private(set) var resumeRewind: ResumeRewind
    private(set) var skipBackwardInterval: PlaybackSkipInterval
    private(set) var skipForwardInterval: PlaybackSkipInterval
    private(set) var bookmarks: [AudioBookmark] = []
    private(set) var pendingBookmarkMutations: [QueuedBookmarkMutation] = []
    private(set) var bookmarkState: BookmarkState = .idle
    private(set) var positionConflict: PlaybackPositionConflict?

    var canSyncBookmarks: Bool {
        activeAccount != nil
    }

    var accountID: AccountID? {
        localAccountID ?? activeAccount?.id
    }

    var hasActiveBook: Bool {
        state != .idle
    }

    var isPlaying: Bool {
        state == .playing
    }

    var canSetEndOfChapterSleepTimer: Bool {
        currentChapterEnd != nil
    }

    var chapters: [PlaybackChapter] {
        preparation?.chapters ?? []
    }

    var audioFiles: [AppPlaybackTrack] {
        guard case .direct(let tracks) = preparation?.source else {
            return []
        }
        return tracks
    }

    var currentAudioFileIndex: Int? {
        audioFiles.lastIndex {
            $0.startOffset <= currentTime
        }
    }

    var currentChapter: PlaybackChapter? {
        chapters.last {
            $0.start <= currentTime
                && currentTime < max($0.end, $0.start)
        }
            ?? chapters.last {
                $0.start <= currentTime
            }
    }

    var canMoveToPreviousChapter: Bool {
        !chapters.isEmpty && currentTime > 1
    }

    var canMoveToNextChapter: Bool {
        chapters.contains {
            $0.start > currentTime + 1
        }
    }

    init(
        service: any AppServicing,
        positionStore: PlaybackPositionStore = .shared,
        localSessionStore: LocalPlaybackSessionStore = .shared,
        bookmarkMutationStore: BookmarkMutationStore = .shared,
        preferencesStore: PlaybackPreferencesStore = .shared,
        audioSessionActivation:
            @escaping @MainActor @Sendable () throws -> Void = {
                try PlaybackModel.activateAudioSession()
            },
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
    ) {
        let skipBackwardInterval = preferencesStore.skipBackward()
        let skipForwardInterval = preferencesStore.skipForward()
        self.service = service
        self.positionStore = positionStore
        self.localSessionStore = localSessionStore
        self.bookmarkMutationStore = bookmarkMutationStore
        self.preferencesStore = preferencesStore
        self.audioSessionActivation = audioSessionActivation
        self.queuePlanning = queuePlanning
        rate = preferencesStore.playbackRate()
        resumeRewind = preferencesStore.resumeRewind()
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        configureRemoteCommands()
        observeAudioSession()
    }

    func setAutomaticDownloadHandler(
        _ handler:
            @escaping @MainActor @Sendable (
                AutomaticDownloadActivity
            ) async -> Void
    ) {
        automaticDownloadHandler = handler
    }

    func start(
        detail: LibraryBookDetail,
        account: ServerAccount
    ) async {
        let availability = BookActionAvailability(
            user: account.user,
            detail: detail
        )
        guard availability.visibleActions.contains(.play) else {
            state = .failed(.playbackDenied)
            return
        }

        generation &+= 1
        let operationGeneration = generation
        await syncProgress()
        guard generation == operationGeneration else {
            return
        }
        await closeActiveSession()
        guard generation == operationGeneration else {
            return
        }
        activeAccount = nil
        localAccountID = nil
        preparation = nil
        activeDownloadDetail = nil
        lastAutomaticDownloadSignal = nil
        localPlaybackSession = nil
        resetPlayer()
        setSleepTimer(minutes: nil)
        pausedAt = nil
        state = .preparing
        itemID = detail.id
        title = detail.title
        author = detail.authors.map(\.name).joined(separator: ", ")
        narrator = detail.narrators.joined(separator: ", ")
        coverURL = BookCoverURL.make(
            server: account.server,
            itemID: detail.id,
            updatedAtMilliseconds: detail.updatedAtMilliseconds,
            width: 600,
            height: 600
        )
        duration = detail.duration
        currentTime = detail.progress?.currentTime ?? 0
        lastAttemptedSyncTime = currentTime
        syncState = .idle
        bookmarks = []
        pendingBookmarkMutations = []
        bookmarkState = .idle
        positionConflict = nil

        do {
            let prepared = try await service.openPlayback(
                for: account,
                itemID: detail.id,
                deviceInfo: Self.deviceInfo()
            )
            guard generation == operationGeneration else {
                if let sessionID = prepared.sessionID {
                    try? await service.closePlayback(
                        for: account,
                        sessionID: sessionID
                    )
                }
                return
            }

            try configureAudioSession()
            activeAccount = account
            preparation = prepared
            activeDownloadDetail = detail
            title = prepared.title
            duration = prepared.duration
            currentTime = min(
                max(detail.progress?.currentTime ?? prepared.currentTime, 0),
                prepared.duration
            )
            try await rebuildQueue(at: currentTime)
            guard generation == operationGeneration else {
                return
            }
            state = .ready
            play()
            notifyAutomaticDownloadProgress(force: true)
            await loadBookmarks()
        } catch let error as AppServiceError {
            guard generation == operationGeneration else {
                return
            }
            activeAccount = nil
            preparation = nil
            activeDownloadDetail = nil
            resetPlayer()
            state = .failed(AppFailure(serviceError: error))
        } catch {
            guard generation == operationGeneration else {
                return
            }
            await closeActiveSession()
            activeAccount = nil
            preparation = nil
            activeDownloadDetail = nil
            resetPlayer()
            state = .failed(.mediaUnavailable)
        }
    }

    func startDownloaded(
        detail: LibraryBookDetail,
        trackURLs: [URL],
        accountID: AccountID,
        account: ServerAccount?
    ) async {
        guard !trackURLs.isEmpty else {
            state = .failed(.mediaUnavailable)
            return
        }
        generation &+= 1
        let operationGeneration = generation
        await syncProgress()
        guard generation == operationGeneration else {
            return
        }
        await closeActiveSession()
        guard generation == operationGeneration else {
            return
        }
        activeAccount = nil
        localAccountID = nil
        preparation = nil
        activeDownloadDetail = nil
        lastAutomaticDownloadSignal = nil
        localPlaybackSession = nil
        resetPlayer()
        setSleepTimer(minutes: nil)
        pausedAt = nil
        state = .preparing
        itemID = detail.id
        title = detail.title
        author = detail.authors.map(\.name).joined(separator: ", ")
        narrator = detail.narrators.joined(separator: ", ")
        coverURL = nil
        currentTime = detail.progress?.currentTime ?? 0
        syncState = .idle
        bookmarks = []
        pendingBookmarkMutations = []
        bookmarkState = .idle
        positionConflict = nil

        do {
            var offset: Double = 0
            var tracks: [AppPlaybackTrack] = []
            for (index, url) in trackURLs.enumerated() {
                let asset = AVURLAsset(url: url)
                let loadedDuration = try await asset.load(.duration)
                let seconds = loadedDuration.seconds
                guard seconds.isFinite, seconds > 0 else {
                    throw AppPlaybackBuildError.missingTracks
                }
                tracks.append(
                    AppPlaybackTrack(
                        url: url,
                        startOffset: offset,
                        duration: seconds,
                        title: "Track \(index + 1)"
                    )
                )
                offset += seconds
            }
            guard generation == operationGeneration else {
                return
            }
            let prepared = AppPlaybackPreparation(
                sessionID: nil,
                itemID: detail.id,
                title: detail.title,
                duration: offset,
                currentTime: min(
                    max(detail.progress?.currentTime ?? 0, 0),
                    offset
                ),
                chapters: detail.chapters,
                source: .direct(tracks)
            )
            try configureAudioSession()
            activeAccount = account
            localAccountID = accountID
            preparation = prepared
            duration = prepared.duration
            let savedPosition = positionStore.position(
                accountID: accountID,
                itemID: detail.id
            )
            let remoteProgress: LibraryBookProgress?
            if let account {
                remoteProgress = try? await service.bookProgress(
                    for: account,
                    itemID: detail.id
                )
            } else {
                remoteProgress = nil
            }
            currentTime = reconciledDownloadedPosition(
                savedPosition: savedPosition,
                baseline: detail.progress,
                remote: remoteProgress,
                duration: prepared.duration
            )
            lastAttemptedSyncTime = currentTime
            lastPersistedLocalTime = currentTime
            try beginLocalPlaybackSession(
                detail: detail,
                accountID: accountID
            )
            try await rebuildQueue(at: currentTime)
            guard generation == operationGeneration else {
                return
            }
            state = .ready
            if positionConflict == nil {
                play()
                await syncProgress()
            } else {
                state = .paused
            }
            await loadBookmarks()
        } catch {
            guard generation == operationGeneration else {
                return
            }
            activeAccount = nil
            localAccountID = nil
            preparation = nil
            resetPlayer()
            state = .failed(.mediaUnavailable)
        }
    }

    func resolvePositionConflict(useLocalPosition: Bool) async {
        guard let conflict = positionConflict,
            preparation?.sessionID == nil
        else {
            return
        }
        let target =
            useLocalPosition ? conflict.localTime : conflict.serverTime
        state = .preparing
        do {
            try await rebuildQueue(at: target)
            currentTime = target
            positionConflict = nil
            persistLocalPosition()
            state = .ready
            if useLocalPosition {
                await syncProgress()
            } else {
                syncState = .idle
            }
            play()
        } catch {
            state = .failed(.mediaUnavailable)
        }
    }

    func loadBookmarks() async {
        guard let accountID = bookmarkAccountID, let itemID else {
            bookmarks = []
            pendingBookmarkMutations = []
            bookmarkState = .idle
            return
        }
        bookmarkState = .loading
        if let activeAccount {
            await syncPendingBookmarks(for: activeAccount)
        }
        do {
            let queued = try bookmarkMutationStore.mutations(
                accountID: accountID,
                itemID: itemID
            )
            pendingBookmarkMutations = queued
            let remote: [AudioBookmark]
            if let activeAccount {
                remote = try await service.bookmarks(
                    for: activeAccount,
                    itemID: itemID
                )
            } else {
                remote = []
            }
            bookmarks = bookmarkMutationStore.applying(queued, to: remote)
            bookmarkState = .ready
        } catch let error {
            if let serviceError = error as? AppServiceError {
                bookmarkState = .failed(
                    AppFailure(serviceError: serviceError)
                )
            } else {
                bookmarkState = .failed(.bookmarkUnavailable)
            }
        }
    }

    func createBookmark(title: String) async -> Bool {
        guard let accountID = bookmarkAccountID, let itemID else {
            bookmarkState = .failed(.bookmarkUnavailable)
            return false
        }
        let bookmark = AudioBookmark(
            libraryItemID: itemID,
            time: currentTime,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        bookmarkState = .saving
        if let activeAccount {
            do {
                let saved = try await service.createBookmark(
                    for: activeAccount,
                    itemID: itemID,
                    time: currentTime,
                    title: title
                )
                replaceBookmark(saved)
                bookmarkState = .ready
                return true
            } catch {
                return queueBookmarkMutation(
                    accountID: accountID,
                    bookmark: bookmark,
                    kind: .create,
                    title: title,
                    status: .failed
                )
            }
        } else {
            return queueBookmarkMutation(
                accountID: accountID,
                bookmark: bookmark,
                kind: .create,
                title: title,
                status: .pending
            )
        }
    }

    func retryPendingBookmarks() async {
        guard let accountID = activeAccount?.id else {
            bookmarkState = .failed(.bookmarkUnavailable)
            return
        }
        do {
            try bookmarkMutationStore.markPending(
                accountID: accountID
            )
        } catch {
            bookmarkState = .failed(.bookmarkUnavailable)
            return
        }
        await loadBookmarks()
    }

    func renameBookmark(
        _ bookmark: AudioBookmark,
        title: String
    ) async -> Bool {
        guard let accountID = bookmarkAccountID else {
            bookmarkState = .failed(.bookmarkUnavailable)
            return false
        }
        bookmarkState = .saving
        if let activeAccount {
            do {
                let updated = try await service.renameBookmark(
                    for: activeAccount,
                    bookmark: bookmark,
                    title: title
                )
                replaceBookmark(updated)
                bookmarkState = .ready
                return true
            } catch {
                return queueBookmarkMutation(
                    accountID: accountID,
                    bookmark: bookmark,
                    kind: .rename,
                    title: title,
                    status: .failed
                )
            }
        } else {
            return queueBookmarkMutation(
                accountID: accountID,
                bookmark: bookmark,
                kind: .rename,
                title: title,
                status: .pending
            )
        }
    }

    func deleteBookmark(_ bookmark: AudioBookmark) async {
        guard let accountID = bookmarkAccountID else {
            bookmarkState = .failed(.bookmarkUnavailable)
            return
        }
        bookmarkState = .saving
        if let activeAccount {
            do {
                try await service.deleteBookmark(
                    for: activeAccount,
                    bookmark: bookmark
                )
                bookmarks.removeAll { $0.id == bookmark.id }
                bookmarkState = .ready
                return
            } catch {
                _ = queueBookmarkMutation(
                    accountID: accountID,
                    bookmark: bookmark,
                    kind: .delete,
                    status: .failed
                )
                return
            }
        }
        _ = queueBookmarkMutation(
            accountID: accountID,
            bookmark: bookmark,
            kind: .delete,
            status: .pending
        )
    }

    private var bookmarkAccountID: AccountID? {
        accountID
    }

    private func queueBookmarkMutation(
        accountID: AccountID,
        bookmark: AudioBookmark,
        kind: QueuedBookmarkMutationKind,
        title: String? = nil,
        status: QueuedBookmarkMutationStatus
    ) -> Bool {
        do {
            _ = try bookmarkMutationStore.enqueue(
                accountID: accountID,
                bookmark: bookmark,
                kind: kind,
                title: title,
                status: status
            )
            let queued = try bookmarkMutationStore.mutations(
                accountID: accountID,
                itemID: bookmark.libraryItemID
            )
            pendingBookmarkMutations = queued
            bookmarks = bookmarkMutationStore.applying(
                queued,
                to: bookmarks
            )
            bookmarkState = .ready
            return true
        } catch {
            bookmarkState = .failed(.bookmarkUnavailable)
            return false
        }
    }

    private func replaceBookmark(_ bookmark: AudioBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        bookmarks.append(bookmark)
        bookmarks.sort { $0.time < $1.time }
    }

    func play() {
        guard let player,
            preparation != nil,
            state != .preparing
        else {
            return
        }
        if let rewindTarget = PlaybackResumeRewindDecision.target(
            currentTime: currentTime,
            pausedAt: pausedAt,
            now: Date(),
            setting: resumeRewind
        ) {
            pausedAt = nil
            state = .preparing
            Task { @MainActor [weak self] in
                await self?.resumePlayback(afterRewindingTo: rewindTarget)
            }
            return
        }
        pausedAt = nil
        player.playImmediately(atRate: rate)
        state = .playing
        updateNowPlaying()
    }

    func pause() {
        guard let player, hasActiveBook else {
            return
        }
        let wasPlaying = isPlaying
        player.pause()
        state = .paused
        if wasPlaying {
            pausedAt = Date()
        }
        updateNowPlaying()
        persistLocalPosition()
        Task { @MainActor [weak self] in
            await self?.syncProgress()
        }
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seekToAudioFile(at index: Int) async {
        let files = audioFiles
        guard files.indices.contains(index) else {
            return
        }
        await seek(to: files[index].startOffset)
    }

    func fail(_ failure: AppFailure) {
        state = .failed(failure)
    }

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        guard let minutes else {
            sleepTimer = nil
            return
        }
        let seconds = max(minutes, 1) * 60
        sleepTimer = .duration(
            Date().addingTimeInterval(
                TimeInterval(seconds)
            )
        )
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(Double(seconds))
            )
            guard !Task.isCancelled else {
                return
            }
            self?.sleepTimer = nil
            self?.pause()
            self?.sleepTask = nil
        }
    }

    func setSleepTimerToEndOfChapter() {
        guard let chapterEnd = currentChapterEnd else {
            return
        }
        sleepTask?.cancel()
        sleepTask = nil
        sleepTimer = .endOfChapter(chapterEnd)
    }

    func setRate(_ newRate: Float) {
        preferencesStore.savePlaybackRate(newRate)
        rate = preferencesStore.playbackRate()
        updateTimePitchAlgorithm()
        if isPlaying {
            player?.playImmediately(atRate: rate)
        }
        updateNowPlaying()
    }

    func setResumeRewind(_ value: ResumeRewind) {
        preferencesStore.saveResumeRewind(value)
        resumeRewind = value
    }

    func setSkipBackwardInterval(_ value: PlaybackSkipInterval) {
        preferencesStore.saveSkipBackward(value)
        skipBackwardInterval = value
        updateRemoteSkipIntervals()
    }

    func setSkipForwardInterval(_ value: PlaybackSkipInterval) {
        preferencesStore.saveSkipForward(value)
        skipForwardInterval = value
        updateRemoteSkipIntervals()
    }

    func seek(to requestedTime: Double) async {
        guard let preparation else {
            return
        }
        generation &+= 1
        let operationGeneration = generation
        await syncProgress()
        guard generation == operationGeneration else {
            return
        }
        let target = min(max(requestedTime, 0), preparation.duration)
        let shouldResume = isPlaying
        if !shouldResume {
            pausedAt = nil
        }
        state = .preparing
        do {
            try await rebuildQueue(at: target)
            guard generation == operationGeneration else {
                return
            }
            currentTime = target
            persistLocalPosition()
            state = shouldResume ? .playing : .paused
            if shouldResume {
                player?.playImmediately(atRate: rate)
            }
            updateNowPlaying()
            notifyAutomaticDownloadProgress(force: true)
            await syncProgress()
        } catch {
            guard generation == operationGeneration else {
                return
            }
            resetPlayer()
            state = .failed(.mediaUnavailable)
        }
    }

    func skipBackward() async {
        await seek(
            to: currentTime - Double(skipBackwardInterval.rawValue)
        )
    }

    func skipForward() async {
        await seek(
            to: currentTime + Double(skipForwardInterval.rawValue)
        )
    }

    func previousChapter() async {
        guard let chapters = preparation?.chapters,
            !chapters.isEmpty
        else {
            return
        }
        let previousStart =
            chapters.last(where: {
                $0.start < currentTime - 1
            })?.start ?? 0
        await seek(to: previousStart)
    }

    func nextChapter() async {
        guard let chapters = preparation?.chapters,
            let nextStart = chapters.first(where: {
                $0.start > currentTime + 1
            })?.start
        else {
            return
        }
        await seek(to: nextStart)
    }

    func stop() async {
        generation &+= 1
        let operationGeneration = generation
        await syncProgress()
        guard generation == operationGeneration else {
            return
        }
        resetPlayer()
        await closeActiveSession()
        guard generation == operationGeneration else {
            return
        }
        activeAccount = nil
        localAccountID = nil
        preparation = nil
        activeDownloadDetail = nil
        lastAutomaticDownloadSignal = nil
        localPlaybackSession = nil
        itemID = nil
        title = ""
        author = ""
        narrator = ""
        coverURL = nil
        currentTime = 0
        duration = 0
        lastAttemptedSyncTime = 0
        setSleepTimer(minutes: nil)
        pausedAt = nil
        state = .idle
        syncState = .idle
        positionConflict = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func rebuildQueue(
        at wholeBookTime: Double
    ) async throws {
        guard let preparation else {
            throw AppPlaybackBuildError.missingPreparation
        }

        removeObservers()
        player?.pause()
        offsetsByItem = [:]

        let plan = try queuePlanning(preparation, wholeBookTime)

        let items = plan.tracks.map { track in
            let item = AVPlayerItem(url: track.url)
            offsetsByItem[ObjectIdentifier(item)] = track.startOffset
            return item
        }
        guard let lastItem = items.last else {
            throw AppPlaybackBuildError.missingTracks
        }

        let queue = AVQueuePlayer(items: items)
        player = queue
        updateTimePitchAlgorithm()
        installObservers(on: queue, lastItem: lastItem)

        await seek(queue, to: plan.localTime)
    }

    private func configureAudioSession() throws {
        try audioSessionActivation()
    }

    static func activateAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .spokenAudio)
        try audioSession.setActive(true)
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        updateRemoteSkipIntervals()

        addRemoteTarget(to: commandCenter.playCommand) {
            Task { @MainActor [weak self] in
                self?.play()
            }
        }
        addRemoteTarget(to: commandCenter.pauseCommand) {
            Task { @MainActor [weak self] in
                self?.pause()
            }
        }
        addRemoteTarget(to: commandCenter.togglePlayPauseCommand) {
            Task { @MainActor [weak self] in
                self?.togglePlayback()
            }
        }
        addRemoteTarget(to: commandCenter.skipBackwardCommand) {
            Task { @MainActor [weak self] in
                await self?.skipBackward()
            }
        }
        addRemoteTarget(to: commandCenter.skipForwardCommand) {
            Task { @MainActor [weak self] in
                await self?.skipForward()
            }
        }
        addRemoteTarget(to: commandCenter.previousTrackCommand) {
            Task { @MainActor [weak self] in
                await self?.previousChapter()
            }
        }
        addRemoteTarget(to: commandCenter.nextTrackCommand) {
            Task { @MainActor [weak self] in
                await self?.nextChapter()
            }
        }
        let positionTarget =
            commandCenter.changePlaybackPositionCommand.addTarget {
                [weak self] event in
                guard
                    let positionEvent =
                        event as? MPChangePlaybackPositionCommandEvent
                else {
                    return .commandFailed
                }
                let position = positionEvent.positionTime
                Task { @MainActor [weak self] in
                    await self?.seek(to: position)
                }
                return .success
            }
        remoteCommandTargets.append(
            (commandCenter.changePlaybackPositionCommand, positionTarget)
        )
    }

    private func updateRemoteSkipIntervals() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: skipBackwardInterval.rawValue)
        ]
        commandCenter.skipForwardCommand.preferredIntervals = [
            NSNumber(value: skipForwardInterval.rawValue)
        ]
    }

    private func addRemoteTarget(
        to command: MPRemoteCommand,
        action: @escaping @Sendable () -> Void
    ) {
        let target = command.addTarget { _ in
            action()
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        audioSessionObservers.append(
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let typeValue =
                    notification.userInfo?[
                        AVAudioSessionInterruptionTypeKey
                    ] as? UInt
                let optionsValue =
                    notification.userInfo?[
                        AVAudioSessionInterruptionOptionKey
                    ] as? UInt ?? 0
                Task { @MainActor [weak self] in
                    self?.handleInterruption(
                        typeValue: typeValue,
                        optionsValue: optionsValue
                    )
                }
            }
        )
        audioSessionObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.persistLocalPosition()
                    await self?.syncProgress()
                }
            }
        )
        audioSessionObservers.append(
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let reasonValue =
                    notification.userInfo?[
                        AVAudioSessionRouteChangeReasonKey
                    ] as? UInt
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(reasonValue: reasonValue)
                }
            }
        )
        audioSessionObservers.append(
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleMediaServicesReset()
                }
            }
        )
    }

    private func installObservers(
        on player: AVQueuePlayer,
        lastItem: AVPlayerItem
    ) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCurrentTime()
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: lastItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackEnded()
            }
        }
    }

    private func removeObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }

    private func resetPlayer() {
        removeObservers()
        player?.pause()
        player?.removeAllItems()
        player = nil
        offsetsByItem = [:]
    }

    private func closeActiveSession() async {
        guard let activeAccount,
            let sessionID = preparation?.sessionID
        else {
            return
        }
        try? await service.closePlayback(
            for: activeAccount,
            sessionID: sessionID
        )
    }

    private func updateTimePitchAlgorithm() {
        let algorithm: AVAudioTimePitchAlgorithm =
            rate <= 2 ? .timeDomain : .spectral
        for item in player?.items() ?? [] {
            item.audioTimePitchAlgorithm = algorithm
        }
    }

    private func refreshCurrentTime() {
        guard let player,
            let currentItem = player.currentItem,
            let offset = offsetsByItem[ObjectIdentifier(currentItem)]
        else {
            return
        }
        let itemTime = currentItem.currentTime().seconds
        guard itemTime.isFinite else {
            return
        }
        currentTime = min(max(offset + itemTime, 0), duration)
        notifyAutomaticDownloadProgress()
        if case .endOfChapter(let chapterEnd) = sleepTimer,
            currentTime >= chapterEnd
        {
            sleepTimer = nil
            pause()
            return
        }
        if abs(currentTime - lastPersistedLocalTime) >= 5 {
            persistLocalPosition()
        }
        if isPlaying,
            currentTime - lastAttemptedSyncTime >= 15
        {
            lastAttemptedSyncTime = currentTime
            Task { @MainActor [weak self] in
                await self?.syncProgress()
            }
        }
    }

    private func notifyAutomaticDownloadProgress(force: Bool = false) {
        guard
            let automaticDownloadHandler,
            let detail = activeDownloadDetail,
            let account = activeAccount,
            let preparation
        else {
            return
        }
        let signal = AutomaticDownloadSignal(
            chapterID: currentChapter?.id,
            fileIndex: currentAudioFileIndex
        )
        guard force || signal != lastAutomaticDownloadSignal else {
            return
        }
        lastAutomaticDownloadSignal = signal
        let ranges: [AutomaticDownloadFileRange]
        switch preparation.source {
        case .direct(let tracks):
            ranges = tracks.enumerated().map { index, track in
                AutomaticDownloadFileRange(
                    index: index,
                    start: track.startOffset,
                    end: track.startOffset + track.duration
                )
            }
        case .hls:
            ranges = []
        }
        let activity = AutomaticDownloadActivity(
            kind: .progress,
            detail: detail,
            account: account,
            currentTime: currentTime,
            chapters: preparation.chapters,
            fileRanges: ranges
        )
        Task { @MainActor in
            await automaticDownloadHandler(activity)
        }
    }

    private func notifyAutomaticDownloadFinished() {
        guard
            let automaticDownloadHandler,
            let detail = activeDownloadDetail,
            let account = activeAccount,
            let preparation
        else {
            return
        }
        let activity = AutomaticDownloadActivity(
            kind: .bookFinished,
            detail: detail,
            account: account,
            currentTime: duration,
            chapters: preparation.chapters,
            fileRanges: []
        )
        Task { @MainActor in
            await automaticDownloadHandler(activity)
        }
    }

    private func playbackEnded() {
        currentTime = duration
        setSleepTimer(minutes: nil)
        persistLocalPosition()
        state = .ended
        updateNowPlaying()
        notifyAutomaticDownloadFinished()
        Task { @MainActor [weak self] in
            await self?.syncProgress()
        }
    }

    private func persistLocalPosition() {
        guard let localAccountID,
            let itemID,
            preparation?.sessionID == nil
        else {
            return
        }
        do {
            try positionStore.save(
                currentTime,
                accountID: localAccountID,
                itemID: itemID
            )
            guard let localPlaybackSession else {
                syncState = .failed
                return
            }
            let updated = try localPlaybackSession.updating(
                currentTime: min(max(currentTime, 0), duration)
            )
            try localSessionStore.save(
                updated,
                accountID: localAccountID
            )
            self.localPlaybackSession = updated
            lastPersistedLocalTime = currentTime
        } catch {
            syncState = .failed
        }
    }

    private func syncProgress() async {
        guard syncState != .syncing,
            let preparation
        else {
            return
        }
        let position = min(max(currentTime, 0), preparation.duration)
        if preparation.sessionID == nil {
            guard let localAccountID else {
                return
            }
            syncState = .syncing
            persistLocalPosition()
            guard syncState != .failed else {
                return
            }
            guard let activeAccount else {
                lastAttemptedSyncTime = position
                syncState = .idle
                return
            }
            do {
                let pending = try localSessionStore.pending(
                    accountID: localAccountID
                )
                guard !pending.isEmpty else {
                    syncState = .idle
                    return
                }
                let results = try await service.syncLocalPlaybackSessions(
                    for: activeAccount,
                    sessions: pending,
                    deviceInfo: Self.deviceInfo()
                )
                guard self.preparation?.itemID == preparation.itemID,
                    self.preparation?.sessionID == nil
                else {
                    return
                }
                let acknowledged = Set(
                    results.filter(\.success).map(\.id)
                )
                try localSessionStore.removeAcknowledged(
                    accountID: localAccountID,
                    sessionIDs: acknowledged
                )
                lastAttemptedSyncTime = position
                syncState =
                    results.allSatisfy(\.success) ? .idle : .failed
                if let localPlaybackSession,
                    let currentResult = results.first(where: {
                        $0.id == localPlaybackSession.id
                    }),
                    currentResult.success,
                    !currentResult.progressSynced
                {
                    await refreshConflictAfterRejectedLocalProgress(
                        account: activeAccount,
                        session: localPlaybackSession
                    )
                }
            } catch {
                guard self.preparation?.itemID == preparation.itemID,
                    self.preparation?.sessionID == nil
                else {
                    return
                }
                syncState = .failed
            }
            return
        }
        guard let activeAccount,
            let sessionID = preparation.sessionID
        else {
            return
        }
        syncState = .syncing
        do {
            try await service.syncPlayback(
                for: activeAccount,
                sessionID: sessionID,
                currentTime: position,
                duration: preparation.duration
            )
            guard self.preparation?.sessionID == sessionID else {
                return
            }
            lastAttemptedSyncTime = position
            syncState = .idle
        } catch {
            guard self.preparation?.sessionID == sessionID else {
                return
            }
            syncState = .failed
        }
    }

    private func reconciledDownloadedPosition(
        savedPosition: Double?,
        baseline: LibraryBookProgress?,
        remote: LibraryBookProgress?,
        duration: Double
    ) -> Double {
        switch DownloadedPositionReconciler.decide(
            savedPosition: savedPosition,
            baseline: baseline,
            remote: remote,
            duration: duration
        ) {
        case .conflict(let localTime, let serverTime):
            positionConflict = PlaybackPositionConflict(
                localTime: localTime,
                serverTime: serverTime
            )
            return localTime
        case .server(let serverTime):
            if let localAccountID, let itemID {
                try? positionStore.save(
                    serverTime,
                    accountID: localAccountID,
                    itemID: itemID
                )
            }
            return serverTime
        case .local(let localTime):
            return localTime
        }
    }

    private var currentChapterEnd: Double? {
        guard let preparation else {
            return nil
        }
        return PlaybackChapterSleepDecision.target(
            chapters: preparation.chapters,
            currentTime: currentTime,
            duration: duration
        )
    }

    private func resumePlayback(afterRewindingTo target: Double) async {
        await seek(to: target)
        guard state == .paused || state == .ready else {
            return
        }
        play()
    }

    func syncPendingLocalSessions(for account: ServerAccount) async {
        do {
            let pending = try localSessionStore.pending(
                accountID: account.id
            )
            if !pending.isEmpty {
                let results = try await service.syncLocalPlaybackSessions(
                    for: account,
                    sessions: pending,
                    deviceInfo: Self.deviceInfo()
                )
                try localSessionStore.removeAcknowledged(
                    accountID: account.id,
                    sessionIDs: Set(results.filter(\.success).map(\.id))
                )
            }
        } catch {
            // The durable outbox remains intact for the next retry.
            return
        }
        await syncPendingBookmarks(for: account)
    }

    func removeLocalData(for accountID: AccountID) {
        try? localSessionStore.removeAll(accountID: accountID)
        try? bookmarkMutationStore.removeAll(accountID: accountID)
    }

    private func syncPendingBookmarks(for account: ServerAccount) async {
        let queued: [QueuedBookmarkMutation]
        do {
            queued = try bookmarkMutationStore.mutations(
                accountID: account.id
            )
        } catch {
            return
        }
        for mutation in queued {
            guard
                await reconcileBookmarkMutation(
                    mutation,
                    account: account
                )
            else {
                try? bookmarkMutationStore.markFailed(mutation.id)
                break
            }
            try? bookmarkMutationStore.remove(mutation.id)
        }
        guard bookmarkAccountID == account.id, let itemID else {
            return
        }
        pendingBookmarkMutations =
            (try? bookmarkMutationStore.mutations(
                accountID: account.id,
                itemID: itemID
            )) ?? []
    }

    private func reconcileBookmarkMutation(
        _ mutation: QueuedBookmarkMutation,
        account: ServerAccount
    ) async -> Bool {
        do {
            let remote = try await service.bookmarks(
                for: account,
                itemID: mutation.itemID
            )
            switch BookmarkReconciliationDecision.decide(
                mutation: mutation,
                remote: remote
            ) {
            case .complete:
                return true
            case .create(let title):
                _ = try await service.createBookmark(
                    for: account,
                    itemID: mutation.itemID,
                    time: mutation.time,
                    title: title
                )
            case .rename(let existing, let title):
                _ = try await service.renameBookmark(
                    for: account,
                    bookmark: existing,
                    title: title
                )
            case .delete(let existing):
                try await service.deleteBookmark(
                    for: account,
                    bookmark: existing
                )
            case .invalid:
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private func beginLocalPlaybackSession(
        detail: LibraryBookDetail,
        accountID: AccountID
    ) throws {
        let existing = try localSessionStore.session(
            accountID: accountID,
            itemID: detail.id
        )
        let session: LocalPlaybackSession
        if let existing,
            abs(existing.duration - duration) <= 1
        {
            session = try existing.updating(currentTime: currentTime)
        } else {
            session = try LocalPlaybackSession.makeBookSession(
                libraryID: detail.libraryID,
                libraryItemID: detail.id,
                bookID: detail.bookID,
                title: detail.title,
                author: detail.authors.map(\.name).joined(separator: ", "),
                chapters: detail.chapters,
                duration: duration,
                currentTime: currentTime
            )
        }
        try localSessionStore.save(session, accountID: accountID)
        localPlaybackSession = session
    }

    private func refreshConflictAfterRejectedLocalProgress(
        account: ServerAccount,
        session: LocalPlaybackSession
    ) async {
        guard
            let remote = try? await service.bookProgress(
                for: account,
                itemID: session.libraryItemID
            ),
            remote.lastUpdateMilliseconds > session.updatedAtMilliseconds,
            abs(remote.currentTime - session.currentTime) > 1
        else {
            return
        }
        player?.pause()
        state = .paused
        positionConflict = PlaybackPositionConflict(
            localTime: session.currentTime,
            serverTime: min(max(remote.currentTime, 0), session.duration)
        )
    }

    private static func deviceInfo() -> PlaybackDeviceInfo {
        PlaybackDeviceInfo(
            deviceID: UIDevice.current.identifierForVendor?
                .uuidString.lowercased() ?? "bleat-ios-device",
            clientName: "Bleat",
            clientVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1",
            manufacturer: "Apple",
            model: UIDevice.current.model
        )
    }

    private func handleInterruption(
        typeValue: UInt?,
        optionsValue: UInt
    ) {
        guard let typeValue,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying
            pause()
        case .ended:
            let options = AVAudioSession.InterruptionOptions(
                rawValue: optionsValue
            )
            if resumeAfterInterruption,
                options.contains(.shouldResume)
            {
                play()
            }
            resumeAfterInterruption = false
        @unknown default:
            resumeAfterInterruption = false
            pause()
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard let reasonValue,
            let reason = AVAudioSession.RouteChangeReason(
                rawValue: reasonValue
            ),
            reason == .oldDeviceUnavailable
        else {
            return
        }
        pause()
    }

    func handleMediaServicesReset() async {
        guard preparation != nil,
            let intent = PlaybackMediaServicesResetIntent.decide(for: state)
        else {
            return
        }
        generation &+= 1
        let operationGeneration = generation
        let recoveryTime = currentTime
        player?.pause()
        state = .preparing
        do {
            try configureAudioSession()
            try await rebuildQueue(at: recoveryTime)
            guard generation == operationGeneration else {
                return
            }
            currentTime = recoveryTime
            switch intent {
            case .play:
                state = .playing
                player?.playImmediately(atRate: rate)
            case .pause:
                state = .paused
            }
            updateNowPlaying()
        } catch {
            guard generation == operationGeneration else {
                return
            }
            resetPlayer()
            state = .failed(.mediaUnavailable)
            updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        guard hasActiveBook else {
            return
        }
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
        ]
        if !author.isEmpty {
            information[MPMediaItemPropertyArtist] = author
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = information
    }

    private func seek(
        _ player: AVPlayer,
        to seconds: Double
    ) async {
        await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { _ in
                continuation.resume()
            }
        }
    }
}

enum AppPlaybackBuildError: Error, Equatable {
    case missingPreparation
    case missingTracks
}

struct AppPlaybackQueuePlan: Equatable, Sendable {
    let tracks: [AppPlaybackTrack]
    let localTime: Double
}

enum AppPlaybackQueuePlanner {
    static func make(
        preparation: AppPlaybackPreparation,
        wholeBookTime: Double
    ) throws(AppPlaybackBuildError) -> AppPlaybackQueuePlan {
        switch preparation.source {
        case .direct(let directTracks):
            guard !directTracks.isEmpty else {
                throw .missingTracks
            }
            let selectedIndex =
                directTracks.lastIndex(where: {
                    $0.startOffset <= wholeBookTime
                }) ?? directTracks.startIndex
            let tracks = Array(directTracks[selectedIndex...])
            return AppPlaybackQueuePlan(
                tracks: tracks,
                localTime: max(
                    0,
                    wholeBookTime - tracks[0].startOffset
                )
            )
        case .hls(let url):
            return AppPlaybackQueuePlan(
                tracks: [
                    AppPlaybackTrack(
                        url: url,
                        startOffset: 0,
                        duration: preparation.duration,
                        title: preparation.title
                    )
                ],
                localTime: max(0, wholeBookTime)
            )
        }
    }
}
