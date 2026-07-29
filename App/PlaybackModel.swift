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

struct PlaybackPositionConflict: Equatable, Sendable {
    let localTime: Double
    let serverTime: Double
}

@MainActor
@Observable
final class PlaybackModel {
    private let service: any AppServicing
    private let positionStore: PlaybackPositionStore
    private let localSessionStore: LocalPlaybackSessionStore
    private var generation: UInt64 = 0
    private var player: AVQueuePlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var offsetsByItem: [ObjectIdentifier: Double] = [:]
    private var activeAccount: ServerAccount?
    private var preparation: AppPlaybackPreparation?
    private var localPlaybackSession: LocalPlaybackSession?
    private var sleepTask: Task<Void, Never>?
    private var resumeAfterInterruption = false
    private var lastAttemptedSyncTime: Double = 0
    private var lastPersistedLocalTime: Double = 0

    private(set) var state: PlaybackState = .idle
    private(set) var syncState: PlaybackSyncState = .idle
    private(set) var itemID: LibraryItemID?
    private(set) var title = ""
    private(set) var author = ""
    private(set) var coverURL: URL?
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1
    private(set) var sleepTimerEnd: Date?
    private(set) var bookmarks: [AudioBookmark] = []
    private(set) var bookmarkState: BookmarkState = .idle
    private(set) var positionConflict: PlaybackPositionConflict?

    var hasActiveBook: Bool {
        state != .idle
    }

    var isPlaying: Bool {
        state == .playing
    }

    init(
        service: any AppServicing,
        positionStore: PlaybackPositionStore = .shared,
        localSessionStore: LocalPlaybackSessionStore = .shared
    ) {
        self.service = service
        self.positionStore = positionStore
        self.localSessionStore = localSessionStore
        configureRemoteCommands()
        observeAudioSession()
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
        preparation = nil
        localPlaybackSession = nil
        resetPlayer()
        state = .preparing
        itemID = detail.id
        title = detail.title
        author = detail.authors.map(\.name).joined(separator: ", ")
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
            await loadBookmarks()
        } catch let error as AppServiceError {
            guard generation == operationGeneration else {
                return
            }
            activeAccount = nil
            preparation = nil
            resetPlayer()
            state = .failed(AppFailure(serviceError: error))
        } catch {
            guard generation == operationGeneration else {
                return
            }
            await closeActiveSession()
            activeAccount = nil
            preparation = nil
            resetPlayer()
            state = .failed(.mediaUnavailable)
        }
    }

    func startDownloaded(
        detail: LibraryBookDetail,
        trackURLs: [URL],
        account: ServerAccount
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
        preparation = nil
        localPlaybackSession = nil
        resetPlayer()
        state = .preparing
        itemID = detail.id
        title = detail.title
        author = detail.authors.map(\.name).joined(separator: ", ")
        coverURL = nil
        currentTime = detail.progress?.currentTime ?? 0
        syncState = .idle
        bookmarks = []
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
            preparation = prepared
            duration = prepared.duration
            let savedPosition = positionStore.position(
                accountID: account.id,
                itemID: detail.id
            )
            let remoteProgress = try? await service.bookProgress(
                for: account,
                itemID: detail.id
            )
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
                account: account
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
        guard let activeAccount, let itemID else {
            bookmarks = []
            bookmarkState = .idle
            return
        }
        bookmarkState = .loading
        do {
            bookmarks = try await service.bookmarks(
                for: activeAccount,
                itemID: itemID
            )
            bookmarkState = .ready
        } catch let error {
            bookmarkState = .failed(AppFailure(serviceError: error))
        }
    }

    func createBookmark(title: String) async -> Bool {
        guard let activeAccount, let itemID else {
            bookmarkState = .failed(.bookmarkUnavailable)
            return false
        }
        bookmarkState = .saving
        do {
            let bookmark = try await service.createBookmark(
                for: activeAccount,
                itemID: itemID,
                time: currentTime,
                title: title
            )
            replaceBookmark(bookmark)
            bookmarkState = .ready
            return true
        } catch let error {
            bookmarkState = .failed(AppFailure(serviceError: error))
            return false
        }
    }

    func renameBookmark(
        _ bookmark: AudioBookmark,
        title: String
    ) async -> Bool {
        guard let activeAccount else {
            bookmarkState = .failed(.bookmarkUnavailable)
            return false
        }
        bookmarkState = .saving
        do {
            let updated = try await service.renameBookmark(
                for: activeAccount,
                bookmark: bookmark,
                title: title
            )
            replaceBookmark(updated)
            bookmarkState = .ready
            return true
        } catch let error {
            bookmarkState = .failed(AppFailure(serviceError: error))
            return false
        }
    }

    func deleteBookmark(_ bookmark: AudioBookmark) async {
        guard let activeAccount else {
            bookmarkState = .failed(.bookmarkUnavailable)
            return
        }
        bookmarkState = .saving
        do {
            try await service.deleteBookmark(
                for: activeAccount,
                bookmark: bookmark
            )
            bookmarks.removeAll { $0.id == bookmark.id }
            bookmarkState = .ready
        } catch let error {
            bookmarkState = .failed(AppFailure(serviceError: error))
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
        player.playImmediately(atRate: rate)
        state = .playing
        updateNowPlaying()
    }

    func pause() {
        guard let player, hasActiveBook else {
            return
        }
        player.pause()
        state = .paused
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

    func fail(_ failure: AppFailure) {
        state = .failed(failure)
    }

    func setSleepTimer(minutes: Int?) {
        sleepTask?.cancel()
        sleepTask = nil
        guard let minutes else {
            sleepTimerEnd = nil
            return
        }
        let seconds = max(minutes, 1) * 60
        sleepTimerEnd = Date().addingTimeInterval(
            TimeInterval(seconds)
        )
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .seconds(Double(seconds))
            )
            guard !Task.isCancelled else {
                return
            }
            self?.pause()
            self?.sleepTimerEnd = nil
            self?.sleepTask = nil
        }
    }

    func setRate(_ newRate: Float) {
        let rounded = (newRate * 20).rounded() / 20
        rate = min(max(rounded, 0.5), 3)
        updateTimePitchAlgorithm()
        if isPlaying {
            player?.playImmediately(atRate: rate)
        }
        updateNowPlaying()
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
        await seek(to: currentTime - 15)
    }

    func skipForward() async {
        await seek(to: currentTime + 30)
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
        preparation = nil
        localPlaybackSession = nil
        itemID = nil
        title = ""
        author = ""
        coverURL = nil
        currentTime = 0
        duration = 0
        lastAttemptedSyncTime = 0
        setSleepTimer(minutes: nil)
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

        let tracks: [AppPlaybackTrack]
        switch preparation.source {
        case .direct(let directTracks):
            guard !directTracks.isEmpty else {
                throw AppPlaybackBuildError.missingTracks
            }
            let selectedIndex =
                directTracks.lastIndex(where: {
                    $0.startOffset <= wholeBookTime
                }) ?? directTracks.startIndex
            tracks = Array(directTracks[selectedIndex...])
        case .hls(let url):
            tracks = [
                AppPlaybackTrack(
                    url: url,
                    startOffset: 0,
                    duration: preparation.duration,
                    title: preparation.title
                )
            ]
        }

        let items = tracks.map { track in
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

        let firstOffset = tracks[0].startOffset
        let localTime = max(0, wholeBookTime - firstOffset)
        await seek(queue, to: localTime)
    }

    private func configureAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .spokenAudio)
        try audioSession.setActive(true)
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.preferredIntervals = [30]

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
        player?.items().forEach {
            $0.audioTimePitchAlgorithm = algorithm
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

    private func playbackEnded() {
        currentTime = duration
        persistLocalPosition()
        state = .ended
        updateNowPlaying()
        Task { @MainActor [weak self] in
            await self?.syncProgress()
        }
    }

    private func persistLocalPosition() {
        guard let activeAccount,
            let itemID,
            preparation?.sessionID == nil
        else {
            return
        }
        do {
            try positionStore.save(
                currentTime,
                accountID: activeAccount.id,
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
                accountID: activeAccount.id
            )
            self.localPlaybackSession = updated
            lastPersistedLocalTime = currentTime
        } catch {
            syncState = .failed
        }
    }

    private func syncProgress() async {
        guard syncState != .syncing,
            let activeAccount,
            let preparation
        else {
            return
        }
        let position = min(max(currentTime, 0), preparation.duration)
        syncState = .syncing
        if preparation.sessionID == nil {
            persistLocalPosition()
            guard syncState != .failed else {
                return
            }
            do {
                let pending = try localSessionStore.pending(
                    accountID: activeAccount.id
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
                    accountID: activeAccount.id,
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
        guard let sessionID = preparation.sessionID else {
            return
        }
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
            if let activeAccount, let itemID {
                try? positionStore.save(
                    serverTime,
                    accountID: activeAccount.id,
                    itemID: itemID
                )
            }
            return serverTime
        case .local(let localTime):
            return localTime
        }
    }

    func syncPendingLocalSessions(for account: ServerAccount) async {
        do {
            let pending = try localSessionStore.pending(
                accountID: account.id
            )
            guard !pending.isEmpty else {
                return
            }
            let results = try await service.syncLocalPlaybackSessions(
                for: account,
                sessions: pending,
                deviceInfo: Self.deviceInfo()
            )
            try localSessionStore.removeAcknowledged(
                accountID: account.id,
                sessionIDs: Set(results.filter(\.success).map(\.id))
            )
        } catch {
            // The durable outbox remains intact for the next retry.
        }
    }

    func removeLocalSessions(for accountID: AccountID) {
        try? localSessionStore.removeAll(accountID: accountID)
    }

    private func beginLocalPlaybackSession(
        detail: LibraryBookDetail,
        account: ServerAccount
    ) throws {
        let existing = try localSessionStore.session(
            accountID: account.id,
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
        try localSessionStore.save(session, accountID: account.id)
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

private enum AppPlaybackBuildError: Error {
    case missingPreparation
    case missingTracks
}
