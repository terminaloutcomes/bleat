import AVFoundation
import BleatCore
import Observation
import UIKit

enum PlaybackState: Equatable, Sendable {
    case idle
    case preparing
    case ready
    case buffering
    case playing
    case paused
    case ended
    case failed(AppFailure)
}

extension PlaybackState {
    fileprivate var diagnosticState: DiagnosticState {
        switch self {
        case .idle:
            .idle
        case .preparing:
            .preparing
        case .ready:
            .ready
        case .buffering:
            .buffering
        case .playing:
            .playing
        case .paused:
            .paused
        case .ended:
            .ended
        case .failed:
            .failed
        }
    }
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
        case .playing, .buffering:
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

enum PlaybackObservationDecision: Equatable, Sendable {
    case buffering
    case playing
    case paused

    static func decide(
        isPlaybackRequested: Bool,
        itemStatus: AVPlayerItem.Status,
        timeControlStatus: AVPlayer.TimeControlStatus,
        hasConfirmedAdvance: Bool
    ) -> Self {
        guard isPlaybackRequested else {
            return .paused
        }
        guard itemStatus == .readyToPlay,
            timeControlStatus == .playing,
            hasConfirmedAdvance
        else {
            return .buffering
        }
        return .playing
    }
}

enum PlaybackSeekContinuation: Equatable, Sendable {
    case resume
    case remainPaused

    static func decide(
        isPlaybackRequested: Bool,
        state: PlaybackState
    ) -> Self {
        if isPlaybackRequested {
            return .resume
        }
        switch state {
        case .playing, .buffering:
            // AVPlayer callbacks can lag the user's transport action. Keep
            // an active player active even if its intent flag has just reset.
            return .resume
        case .idle, .preparing, .ready, .paused, .ended, .failed:
            return .remainPaused
        }
    }
}

enum PlaybackWatchdogDecision: Equatable, Sendable {
    case none
    case showBuffering
    case recover

    static let bufferingDelay: TimeInterval = 2
    static let recoveryDelay: TimeInterval = 12

    static func decide(
        isPlaybackRequested: Bool,
        lastConfirmedAdvanceAt: TimeInterval?,
        now: TimeInterval
    ) -> Self {
        guard isPlaybackRequested, let lastConfirmedAdvanceAt else {
            return .none
        }
        let elapsed = now - lastConfirmedAdvanceAt
        if elapsed >= recoveryDelay {
            return .recover
        }
        if elapsed >= bufferingDelay {
            return .showBuffering
        }
        return .none
    }
}

enum PlaybackRecoveryFault: Equatable, Sendable {
    case decoderFailure
    case missingSession
    case stalled
    case itemFailure
    case localEndpointFailure(URL)
}

enum PlaybackRecoveryAction: Equatable, Sendable {
    case rebuildCurrentSource
    case reopenSession(PlaybackPreference)
    case fallbackFromLocal(URL)
    case fail
}

struct PlaybackRecoveryPolicy: Equatable, Sendable {
    static let sustainedPlaybackDelay: TimeInterval = 10

    private(set) var rebuiltCurrentSource = false
    private(set) var reopenedSession = false
    private(set) var forcedTranscode = false
    private(set) var attemptedEndpointFallback = false

    mutating func action(
        for fault: PlaybackRecoveryFault,
        isStreaming: Bool,
        isTranscoded: Bool
    ) -> PlaybackRecoveryAction {
        switch fault {
        case .localEndpointFailure(let url):
            guard isStreaming, !attemptedEndpointFallback else {
                return .fail
            }
            attemptedEndpointFallback = true
            reopenedSession = true
            return .fallbackFromLocal(url)
        case .decoderFailure:
            guard isStreaming, !isTranscoded, !forcedTranscode else {
                return .fail
            }
            forcedTranscode = true
            return .reopenSession(.transcode)
        case .missingSession:
            guard isStreaming, !reopenedSession else {
                return .fail
            }
            reopenedSession = true
            return .reopenSession(.automatic)
        case .stalled, .itemFailure:
            if !rebuiltCurrentSource {
                rebuiltCurrentSource = true
                return .rebuildCurrentSource
            }
            guard isStreaming, !reopenedSession else {
                return .fail
            }
            reopenedSession = true
            return .reopenSession(.automatic)
        }
    }

    mutating func sustainedPlaybackConfirmed() {
        rebuiltCurrentSource = false
    }
}

enum PlaybackItemFailureClassifier {
    static func classify(
        error: Error?,
        errorLogStatusCodes: [Int]
    ) -> PlaybackRecoveryFault {
        if errorLogStatusCodes.contains(404)
            || containsHTTPStatus(404, in: error)
        {
            return .missingSession
        }
        if containsDecoderFailure(in: error) {
            return .decoderFailure
        }
        return .itemFailure
    }

    private static func containsHTTPStatus(
        _ statusCode: Int,
        in error: Error?
    ) -> Bool {
        errorChain(startingAt: error).contains { error in
            return error.code == statusCode
                && error.domain == NSURLErrorDomain
        }
    }

    private static func containsDecoderFailure(
        in error: Error?
    ) -> Bool {
        let decoderCodes: Set<Int> = [
            AVError.Code.decodeFailed.rawValue,
            AVError.Code.decoderNotFound.rawValue,
            AVError.Code.decoderTemporarilyUnavailable.rawValue,
            AVError.Code.fileFormatNotRecognized.rawValue,
            AVError.Code.fileFailedToParse.rawValue,
            AVError.Code.undecodableMediaData.rawValue,
            AVError.Code.invalidSourceMedia.rawValue,
        ]
        return errorChain(startingAt: error).contains { error in
            error.domain == AVFoundationErrorDomain
                && decoderCodes.contains(error.code)
        }
    }

    private static func errorChain(
        startingAt error: Error?
    ) -> [NSError] {
        var errors: [NSError] = []
        var current = error as NSError?
        while let error = current, errors.count < 8 {
            errors.append(error)
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return errors
    }
}

private struct AutomaticDownloadSignal: Equatable {
    let chapterID: Int?
    let fileIndex: Int?
}

enum AutomaticDownloadBandwidthDecision: Equatable {
    case reserveForPlayback
    case allowAutomaticDownloads
}

struct AutomaticDownloadPlaybackGate {
    static let stablePlaybackDelay: TimeInterval = 10

    private var stablePlaybackStartedAt: TimeInterval?

    mutating func decision(
        isPlayingIntent: Bool,
        timeControlStatus: AVPlayer.TimeControlStatus,
        now: TimeInterval
    ) -> AutomaticDownloadBandwidthDecision {
        guard isPlayingIntent else {
            stablePlaybackStartedAt = nil
            return .allowAutomaticDownloads
        }
        guard timeControlStatus == .playing else {
            stablePlaybackStartedAt = nil
            return .reserveForPlayback
        }
        if stablePlaybackStartedAt == nil {
            stablePlaybackStartedAt = now
        }
        guard
            let stablePlaybackStartedAt,
            now - stablePlaybackStartedAt
                >= Self.stablePlaybackDelay
        else {
            return .reserveForPlayback
        }
        return .allowAutomaticDownloads
    }
}

@MainActor
@Observable
final class PlaybackModel {
    private let service: any AppServicing
    private let diagnostics: any DiagnosticRecording
    private let positionStore: PlaybackPositionStore
    private let localSessionStore: LocalPlaybackSessionStore
    private let bookmarkMutationStore: BookmarkMutationStore
    private let preferencesStore: PlaybackPreferencesStore
    private let nowPlayingCoordinator: NowPlayingCoordinator
    private let audioSessionActivation: @MainActor @Sendable () throws -> Void
    private let queuePlanning:
        @MainActor @Sendable (
            AppPlaybackPreparation,
            Double
        ) throws -> AppPlaybackQueuePlan
    private var generation: UInt64 = 0
    private var player: AVQueuePlayer?
    private var timeObserver: Any?
    private var timeControlStatusObserver: NSKeyValueObservation?
    private var playerStatusObserver: NSKeyValueObservation?
    private var currentItemObserver: NSKeyValueObservation?
    private var currentItemStatusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var currentItemObservers: [NSObjectProtocol] = []
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var offsetsByItem: [ObjectIdentifier: Double] = [:]
    private var activeAccount: ServerAccount?
    private var localAccountID: AccountID?
    private var preparation: AppPlaybackPreparation?
    private var localPlaybackSession: LocalPlaybackSession?
    private var sleepTask: Task<Void, Never>?
    private var playbackWatchdogTask: Task<Void, Never>?
    private var playbackRecoveryTask: Task<Void, Never>?
    private var statisticsRecordingTask: Task<Void, Never>?
    private var pausedAt: Date?
    private var resumeAfterInterruption = false
    private var lastAttemptedSyncTime: Double = 0
    private var lastPersistedLocalTime: Double = 0
    private var activeDownloadDetail: LibraryBookDetail?
    private var lastAutomaticDownloadSignal: AutomaticDownloadSignal?
    private var automaticDownloadPlaybackGate =
        AutomaticDownloadPlaybackGate()
    private var automaticDownloadBandwidthDecision:
        AutomaticDownloadBandwidthDecision?
    private var playbackRequested = false
    private var hasConfirmedPlaybackAdvance = false
    private var lastObservedWholeBookTime: Double?
    private var lastConfirmedAdvanceAt: TimeInterval?
    private var stablePlaybackStartedAt: TimeInterval?
    private var playbackRecoveryPolicy = PlaybackRecoveryPolicy()
    private let monotonicNow: @MainActor @Sendable () -> TimeInterval
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
    private(set) var previousCommandAction: HeadphoneCommandAction
    private(set) var nextCommandAction: HeadphoneCommandAction
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

    var coverLoadPolicy: BookCoverLoadPolicy {
        preparation?.sessionID == nil
            ? .cacheOnly
            : .allowNetwork
    }

    var isPlaybackRequested: Bool {
        playbackRequested
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
        nowPlayingCoordinator: NowPlayingCoordinator =
            NowPlayingCoordinator(),
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
            },
        monotonicNow:
            @escaping @MainActor @Sendable () -> TimeInterval = {
                ProcessInfo.processInfo.systemUptime
            },
        diagnostics: any DiagnosticRecording =
            SystemDiagnosticRecorder.shared
    ) {
        let skipBackwardInterval = preferencesStore.skipBackward()
        let skipForwardInterval = preferencesStore.skipForward()
        let previousCommandAction = preferencesStore.previousCommandAction()
        let nextCommandAction = preferencesStore.nextCommandAction()
        self.service = service
        self.diagnostics = diagnostics
        self.positionStore = positionStore
        self.localSessionStore = localSessionStore
        self.bookmarkMutationStore = bookmarkMutationStore
        self.preferencesStore = preferencesStore
        self.nowPlayingCoordinator = nowPlayingCoordinator
        self.audioSessionActivation = audioSessionActivation
        self.queuePlanning = queuePlanning
        self.monotonicNow = monotonicNow
        rate = preferencesStore.playbackRate()
        resumeRewind = preferencesStore.resumeRewind()
        self.skipBackwardInterval = skipBackwardInterval
        self.skipForwardInterval = skipForwardInterval
        self.previousCommandAction = previousCommandAction
        self.nextCommandAction = nextCommandAction
        nowPlayingCoordinator.setCommandHandler {
            [weak self] command in
            self?.handleRemoteCommand(command) ?? .unavailable
        }
        updateRemoteSkipIntervals()
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

    private func record(_ event: DiagnosticEvent) {
        Task {
            await diagnostics.record(event)
        }
    }

    func start(
        detail: LibraryBookDetail,
        account: ServerAccount
    ) async {
        await diagnostics.record(
            .started(.openPlayback, category: .playback)
        )
        let availability = BookActionAvailability(
            user: account.user,
            detail: detail
        )
        guard availability.visibleActions.contains(.play) else {
            state = .failed(
                AppFailure(.openPlayback, .permissionDenied)
            )
            await diagnostics.record(
                .failed(
                    .openPlayback,
                    category: .playback,
                    failureCode: .permissionDenied
                )
            )
            return
        }

        generation &+= 1
        let operationGeneration = generation
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        player?.pause()
        await syncProgress()
        guard generation == operationGeneration else {
            return
        }
        await finishStatisticsSession()
        await closeActiveSession()
        guard generation == operationGeneration else {
            return
        }
        notifyAutomaticDownloadBandwidthReleased()
        activeAccount = nil
        localAccountID = nil
        preparation = nil
        activeDownloadDetail = nil
        lastAutomaticDownloadSignal = nil
        automaticDownloadPlaybackGate =
            AutomaticDownloadPlaybackGate()
        automaticDownloadBandwidthDecision = nil
        resetPlaybackRecoveryState()
        localPlaybackSession = nil
        resetPlayer()
        setSleepTimer(minutes: nil)
        pausedAt = nil
        state = .preparing
        await diagnostics.record(
            .transition(
                category: .playback,
                from: .idle,
                to: .preparing
            )
        )
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
                preference: .automatic,
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
            await diagnostics.record(
                .transition(
                    category: .playback,
                    from: .preparing,
                    to: .ready
                )
            )
            await diagnostics.record(
                .completed(.openPlayback, category: .playback)
            )
            play()
            await loadBookmarks()
        } catch let error as AppServiceError {
            guard generation == operationGeneration else {
                return
            }
            activeAccount = nil
            preparation = nil
            activeDownloadDetail = nil
            resetPlayer()
            let failure = AppFailure(
                operation: .openPlayback, serviceError: error)
            state = .failed(failure)
            await diagnostics.record(
                .failed(
                    .openPlayback,
                    category: .playback,
                    failureCode: failure.diagnosticFailureCode
                )
            )
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
            await diagnostics.record(
                .failed(
                    .openPlayback,
                    category: .playback,
                    failureCode: .mediaUnavailable
                )
            )
        }
    }

    func startDownloaded(
        detail: LibraryBookDetail,
        trackURLs: [URL],
        accountID: AccountID,
        account: ServerAccount?
    ) async {
        await diagnostics.record(
            .started(
                .openPlayback,
                category: .playback,
                count: trackURLs.count
            )
        )
        guard !trackURLs.isEmpty else {
            state = .failed(.mediaUnavailable)
            await diagnostics.record(
                .failed(
                    .openPlayback,
                    category: .playback,
                    failureCode: .mediaUnavailable
                )
            )
            return
        }
        generation &+= 1
        let operationGeneration = generation
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        player?.pause()
        persistLocalPosition()
        guard generation == operationGeneration else {
            return
        }
        await finishStatisticsSession()
        await closeActiveSession()
        guard generation == operationGeneration else {
            return
        }
        notifyAutomaticDownloadBandwidthReleased()
        activeAccount = nil
        localAccountID = nil
        preparation = nil
        activeDownloadDetail = nil
        lastAutomaticDownloadSignal = nil
        automaticDownloadPlaybackGate =
            AutomaticDownloadPlaybackGate()
        automaticDownloadBandwidthDecision = nil
        resetPlaybackRecoveryState()
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
            server: account?.server,
            itemID: detail.id,
            updatedAtMilliseconds: detail.updatedAtMilliseconds,
            width: 600,
            height: 600
        )
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
            currentTime = reconciledDownloadedPosition(
                savedPosition: savedPosition,
                baseline: detail.progress,
                remote: nil,
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
            await diagnostics.record(
                .completed(.openPlayback, category: .playback)
            )
            if positionConflict == nil {
                play()
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
            await diagnostics.record(
                .failed(
                    .openPlayback,
                    category: .playback,
                    failureCode: .mediaUnavailable
                )
            )
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
            if !useLocalPosition {
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
        let isDownloadedPlayback = preparation?.sessionID == nil
        if let activeAccount {
            if !isDownloadedPlayback {
                await syncPendingBookmarks(for: activeAccount)
            }
        }
        do {
            let queued = try bookmarkMutationStore.mutations(
                accountID: accountID,
                itemID: itemID
            )
            pendingBookmarkMutations = queued
            guard !isDownloadedPlayback else {
                bookmarks = bookmarkMutationStore.applying(
                    queued,
                    to: []
                )
                bookmarkState = .ready
                return
            }
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
                    AppFailure(
                        operation: .loadBookmarks, serviceError: serviceError)
                )
            } else {
                bookmarkState = .failed(
                    AppFailure(.loadBookmarks, .localStorageUnavailable)
                )
            }
        }
    }

    func createBookmark(title: String) async -> Bool {
        guard let accountID = bookmarkAccountID, let itemID else {
            bookmarkState = .failed(
                AppFailure(.loadBookmarks, .authenticationRequired)
            )
            return false
        }
        let bookmark = AudioBookmark(
            libraryItemID: itemID,
            time: currentTime,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            createdAtMilliseconds: Int64(Date().timeIntervalSince1970 * 1_000)
        )
        bookmarkState = .saving
        guard preparation?.sessionID != nil else {
            return queueBookmarkMutation(
                accountID: accountID,
                bookmark: bookmark,
                kind: .create,
                title: title,
                status: .pending
            )
        }
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
            bookmarkState = .failed(
                AppFailure(.loadBookmarks, .authenticationRequired)
            )
            return
        }
        do {
            try bookmarkMutationStore.markPending(
                accountID: accountID
            )
        } catch {
            bookmarkState = .failed(
                AppFailure(.loadBookmarks, .localStorageUnavailable)
            )
            return
        }
        await loadBookmarks()
    }

    func renameBookmark(
        _ bookmark: AudioBookmark,
        title: String
    ) async -> Bool {
        guard let accountID = bookmarkAccountID else {
            bookmarkState = .failed(
                AppFailure(.loadBookmarks, .authenticationRequired)
            )
            return false
        }
        bookmarkState = .saving
        guard preparation?.sessionID != nil else {
            return queueBookmarkMutation(
                accountID: accountID,
                bookmark: bookmark,
                kind: .rename,
                title: title,
                status: .pending
            )
        }
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
            bookmarkState = .failed(
                AppFailure(.loadBookmarks, .authenticationRequired)
            )
            return
        }
        bookmarkState = .saving
        guard preparation?.sessionID != nil else {
            _ = queueBookmarkMutation(
                accountID: accountID,
                bookmark: bookmark,
                kind: .delete,
                status: .pending
            )
            return
        }
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
            bookmarkState = .failed(
                AppFailure(.loadBookmarks, .localStorageUnavailable)
            )
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
            state != .preparing,
            state != .ended
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
        playbackRequested = true
        hasConfirmedPlaybackAdvance = false
        stablePlaybackStartedAt = nil
        lastObservedWholeBookTime = currentTime
        lastConfirmedAdvanceAt = monotonicNow()
        startPlaybackWatchdog()
        if player.status == .failed {
            handleItemFailure(
                error: player.error,
                item: player.currentItem
            )
            return
        }
        if let currentItem = player.currentItem,
            currentItem.status == .failed
        {
            handleItemFailure(
                error: currentItem.error,
                item: currentItem
            )
            return
        }
        player.playImmediately(atRate: rate)
        recordStatisticsSample(isAudibleAndAdvancing: true)
        let previousState = state.diagnosticState
        state = .buffering
        record(
            .transition(
                category: .playback,
                from: previousState,
                to: .buffering
            )
        )
        record(.completed(.play, category: .playback))
        updateAutomaticDownloadBandwidth()
        updateNowPlaying()
    }

    func pause() {
        guard let player, hasActiveBook else {
            return
        }
        let wasPlaying = isPlaybackRequested
        recordStatisticsSample(isAudibleAndAdvancing: false)
        generation &+= 1
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        player.pause()
        let previousState = state.diagnosticState
        state = .paused
        record(
            .transition(
                category: .playback,
                from: previousState,
                to: .paused
            )
        )
        record(.completed(.pause, category: .playback))
        updateAutomaticDownloadBandwidth()
        if wasPlaying {
            pausedAt = Date()
        }
        updateNowPlaying()
        persistLocalPosition()
        if preparation?.sessionID != nil {
            Task { @MainActor [weak self] in
                await self?.syncProgress()
            }
        }
    }

    func togglePlayback() {
        if isPlaybackRequested {
            pause()
        } else {
            play()
        }
    }

    func seekToAudioFile(at index: Int) async {
        guard let preparation = preparation,
            case .direct(let tracks) = preparation.source,
            tracks.indices.contains(index)
        else {
            return
        }
        await seek(to: tracks[index].startOffset)
    }

    func fail(_ failure: AppFailure) {
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        player?.pause()
        state = .failed(failure)
        updateNowPlaying()
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
        recordStatisticsSample(isAudibleAndAdvancing: false)
        preferencesStore.savePlaybackRate(newRate)
        rate = preferencesStore.playbackRate()
        updateTimePitchAlgorithm()
        if isPlaybackRequested {
            player?.playImmediately(atRate: rate)
        }
        updateNowPlaying()
    }

    func cycleFeaturedPlaybackRate() -> PlaybackRemoteCommandOutcome {
        nowPlayingCoordinator.cyclePlaybackRate()
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

    func setPreviousCommandAction(_ value: HeadphoneCommandAction) {
        preferencesStore.savePreviousCommandAction(value)
        previousCommandAction = value
        updateNowPlaying()
    }

    func setNextCommandAction(_ value: HeadphoneCommandAction) {
        preferencesStore.saveNextCommandAction(value)
        nextCommandAction = value
        updateNowPlaying()
    }

    func reloadSyncedPreferences() {
        rate = preferencesStore.playbackRate()
        resumeRewind = preferencesStore.resumeRewind()
        skipBackwardInterval = preferencesStore.skipBackward()
        skipForwardInterval = preferencesStore.skipForward()
        previousCommandAction = preferencesStore.previousCommandAction()
        nextCommandAction = preferencesStore.nextCommandAction()
        updateTimePitchAlgorithm()
        if isPlaybackRequested {
            player?.playImmediately(atRate: rate)
        }
        updateRemoteSkipIntervals()
        updateNowPlaying()
    }

    func seek(to requestedTime: Double) async {
        await performSeek(to: requestedTime)
    }

    private func performSeek(to requestedTime: Double) async {
        guard let preparation else {
            return
        }
        await diagnostics.record(
            .started(.seek, category: .playback)
        )
        let continuation = PlaybackSeekContinuation.decide(
            isPlaybackRequested: isPlaybackRequested,
            state: state
        )
        recordStatisticsSample(isAudibleAndAdvancing: false)
        generation &+= 1
        let operationGeneration = generation
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        player?.pause()
        if preparation.sessionID != nil {
            await syncProgress()
        } else {
            persistLocalPosition()
        }
        guard generation == operationGeneration else {
            return
        }
        let target = min(max(requestedTime, 0), preparation.duration)
        if continuation == .remainPaused {
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
            if continuation == .resume {
                state = .ready
                play()
            } else {
                state = .paused
            }
            updateNowPlaying()
            updateAutomaticDownloadBandwidth()
            if preparation.sessionID != nil {
                await syncProgress()
            }
            await diagnostics.record(
                .completed(.seek, category: .playback)
            )
        } catch {
            guard generation == operationGeneration else {
                return
            }
            resetPlayer()
            state = .failed(.mediaUnavailable)
            await diagnostics.record(
                .failed(
                    .seek,
                    category: .playback,
                    failureCode: .mediaUnavailable
                )
            )
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
        await diagnostics.record(
            .started(.closePlayback, category: .playback)
        )
        generation &+= 1
        let operationGeneration = generation
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        player?.pause()
        if preparation?.sessionID != nil {
            await syncProgress()
        } else {
            persistLocalPosition()
        }
        guard generation == operationGeneration else {
            return
        }
        await finishStatisticsSession()
        notifyAutomaticDownloadBandwidthReleased()
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
        automaticDownloadPlaybackGate =
            AutomaticDownloadPlaybackGate()
        automaticDownloadBandwidthDecision = nil
        resetPlaybackRecoveryState()
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
        nowPlayingCoordinator.clear()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        await diagnostics.record(
            .completed(.closePlayback, category: .playback)
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
        installObservers(
            on: queue,
            lastItem: lastItem
        )

        await seek(queue, to: plan.localTime)
        lastObservedWholeBookTime = wholeBookTime
    }

    private func configureAudioSession() throws {
        try audioSessionActivation()
    }

    static func activateAudioSession() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .spokenAudio)
        try audioSession.setActive(true)
    }

    private func updateRemoteSkipIntervals() {
        nowPlayingCoordinator.setSkipIntervals(
            backward: skipBackwardInterval.rawValue,
            forward: skipForwardInterval.rawValue
        )
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
                    if self?.preparation?.sessionID != nil {
                        await self?.syncProgress()
                    }
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
        timeControlStatusObserver = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.handleTimeControlStatusChange()
            }
        }
        playerStatusObserver = player.observe(
            \.status,
            options: [.new]
        ) { [weak self] player, _ in
            guard player.status == .failed else {
                return
            }
            Task { @MainActor [weak self] in
                self?.handleItemFailure(
                    error: player.error,
                    item: player.currentItem
                )
            }
        }
        currentItemObserver = player.observe(
            \.currentItem,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                self?.observeCurrentItem(player.currentItem)
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
        timeControlStatusObserver?.invalidate()
        timeControlStatusObserver = nil
        playerStatusObserver?.invalidate()
        playerStatusObserver = nil
        currentItemObserver?.invalidate()
        currentItemObserver = nil
        removeCurrentItemObservers()
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
        lastObservedWholeBookTime = nil
        hasConfirmedPlaybackAdvance = false
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
        updateAutomaticDownloadBandwidth()
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
        let refreshedTime = min(max(offset + itemTime, 0), duration)
        let previousChapterID = currentChapter?.id
        let previousObservedTime = lastObservedWholeBookTime
        currentTime = refreshedTime
        lastObservedWholeBookTime = refreshedTime
        if currentChapter?.id != previousChapterID {
            updateNowPlaying()
        }
        if let previousObservedTime,
            refreshedTime - previousObservedTime > 0.01,
            isPlaybackRequested
        {
            confirmPlaybackAdvance(at: monotonicNow())
        }
        recordStatisticsSample(
            isAudibleAndAdvancing:
                isPlaybackRequested
                && player.timeControlStatus == .playing
                && currentItem.status == .readyToPlay
                && (previousObservedTime.map {
                    refreshedTime - $0 > 0.01
                } ?? false)
        )
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
        if preparation?.sessionID != nil,
            isPlaying,
            currentTime - lastAttemptedSyncTime >= 15
        {
            lastAttemptedSyncTime = currentTime
            Task { @MainActor [weak self] in
                await self?.syncProgress()
            }
        }
    }

    private func observeCurrentItem(_ item: AVPlayerItem?) {
        removeCurrentItemObservers()
        guard let item else {
            if isPlaybackRequested, state != .ended {
                transitionPlaybackState(to: .buffering)
            }
            return
        }
        currentItemStatusObserver = item.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                self?.handleCurrentItemStatus(item)
            }
        }
        let center = NotificationCenter.default
        currentItemObservers.append(
            center.addObserver(
                forName: AVPlayerItem.playbackStalledNotification,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handlePlaybackStall()
                }
            }
        )
        currentItemObservers.append(
            center.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { [weak self] notification in
                let error =
                    notification.userInfo?[
                        AVPlayerItemFailedToPlayToEndTimeErrorKey
                    ] as? Error
                Task { @MainActor [weak self] in
                    self?.handleItemFailure(error: error, item: item)
                }
            }
        )
        hasConfirmedPlaybackAdvance = false
        stablePlaybackStartedAt = nil
        lastObservedWholeBookTime = currentTime
        if isPlaybackRequested {
            lastConfirmedAdvanceAt = monotonicNow()
            player?.playImmediately(atRate: rate)
        }
        applyObservedPlaybackState()
    }

    private func removeCurrentItemObservers() {
        currentItemStatusObserver?.invalidate()
        currentItemStatusObserver = nil
        for observer in currentItemObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        currentItemObservers = []
    }

    private func handleCurrentItemStatus(_ item: AVPlayerItem) {
        guard item === player?.currentItem else {
            return
        }
        switch item.status {
        case .unknown:
            applyObservedPlaybackState()
        case .readyToPlay:
            if let asset = item.asset as? AVURLAsset {
                Task {
                    await service.recordServerActivity(
                        url: asset.url,
                        purpose: .playback
                    )
                }
            }
            applyObservedPlaybackState()
        case .failed:
            handleItemFailure(error: item.error, item: item)
        @unknown default:
            handleItemFailure(error: item.error, item: item)
        }
    }

    private func handleTimeControlStatusChange() {
        updateAutomaticDownloadBandwidth()
        if player?.timeControlStatus != .playing {
            recordStatisticsSample(isAudibleAndAdvancing: false)
            hasConfirmedPlaybackAdvance = false
            stablePlaybackStartedAt = nil
        }
        applyObservedPlaybackState()
    }

    private func handlePlaybackStall() {
        guard isPlaybackRequested else {
            return
        }
        hasConfirmedPlaybackAdvance = false
        stablePlaybackStartedAt = nil
        transitionPlaybackState(to: .buffering)
        updateNowPlaying()
    }

    private func handleItemFailure(
        error: Error?,
        item: AVPlayerItem?
    ) {
        guard isPlaybackRequested else {
            return
        }
        let statusCodes =
            item?.errorLog()?.events.map(\.errorStatusCode) ?? []
        let fault = PlaybackItemFailureClassifier.classify(
            error: error ?? item?.error,
            errorLogStatusCodes: statusCodes
        )
        beginPlaybackRecovery(for: fault)
    }

    private func applyObservedPlaybackState() {
        guard let player,
            let item = player.currentItem,
            state != .idle,
            state != .ended,
            !isPlaybackFailed
        else {
            return
        }
        let decision = PlaybackObservationDecision.decide(
            isPlaybackRequested: isPlaybackRequested,
            itemStatus: item.status,
            timeControlStatus: player.timeControlStatus,
            hasConfirmedAdvance: hasConfirmedPlaybackAdvance
        )
        switch decision {
        case .buffering:
            transitionPlaybackState(to: .buffering)
        case .playing:
            transitionPlaybackState(to: .playing)
        case .paused:
            transitionPlaybackState(to: .paused)
        }
        updateNowPlaying()
    }

    private var isPlaybackFailed: Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    private func transitionPlaybackState(to newState: PlaybackState) {
        guard state != newState else {
            return
        }
        let previousState = state.diagnosticState
        state = newState
        record(
            .transition(
                category: .playback,
                from: previousState,
                to: newState.diagnosticState
            )
        )
    }

    private func confirmPlaybackAdvance(at now: TimeInterval) {
        hasConfirmedPlaybackAdvance = true
        lastConfirmedAdvanceAt = now
        if stablePlaybackStartedAt == nil {
            stablePlaybackStartedAt = now
        }
        if let stablePlaybackStartedAt,
            now - stablePlaybackStartedAt
                >= PlaybackRecoveryPolicy.sustainedPlaybackDelay
        {
            playbackRecoveryPolicy.sustainedPlaybackConfirmed()
        }
        applyObservedPlaybackState()
    }

    private func resetPlaybackRecoveryState() {
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        hasConfirmedPlaybackAdvance = false
        lastObservedWholeBookTime = nil
        lastConfirmedAdvanceAt = nil
        stablePlaybackStartedAt = nil
        playbackRecoveryPolicy = PlaybackRecoveryPolicy()
    }

    private func startPlaybackWatchdog() {
        guard playbackWatchdogTask == nil else {
            return
        }
        playbackWatchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else {
                    return
                }
                self.evaluatePlaybackWatchdog()
            }
        }
    }

    private func cancelPlaybackWatchdog() {
        playbackWatchdogTask?.cancel()
        playbackWatchdogTask = nil
    }

    private func evaluatePlaybackWatchdog() {
        guard playbackRecoveryTask == nil else {
            return
        }
        switch PlaybackWatchdogDecision.decide(
            isPlaybackRequested: isPlaybackRequested,
            lastConfirmedAdvanceAt: lastConfirmedAdvanceAt,
            now: monotonicNow()
        ) {
        case .none:
            return
        case .showBuffering:
            hasConfirmedPlaybackAdvance = false
            stablePlaybackStartedAt = nil
            transitionPlaybackState(to: .buffering)
            updateNowPlaying()
        case .recover:
            beginPlaybackRecovery(for: .stalled)
        }
    }

    private func beginPlaybackRecovery(
        for fault: PlaybackRecoveryFault
    ) {
        guard isPlaybackRequested,
            playbackRecoveryTask == nil,
            let preparation
        else {
            return
        }
        let isStreaming =
            preparation.sessionID != nil && activeAccount != nil
        let isTranscoded: Bool
        switch preparation.source {
        case .direct:
            isTranscoded = false
        case .hls:
            isTranscoded = true
        }
        let effectiveFault: PlaybackRecoveryFault
        if (fault == .stalled || fault == .itemFailure),
            let localURL = currentLocalPlaybackURL()
        {
            effectiveFault = .localEndpointFailure(localURL)
        } else {
            effectiveFault = fault
        }
        let action = playbackRecoveryPolicy.action(
            for: effectiveFault,
            isStreaming: isStreaming,
            isTranscoded: isTranscoded
        )
        guard action != .fail else {
            failPlaybackRecovery()
            return
        }

        transitionPlaybackState(to: .buffering)
        updateNowPlaying()
        record(.started(.recoverPlayback, category: .playback))
        let operationGeneration = generation
        playbackRecoveryTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            await self.performPlaybackRecovery(
                action,
                operationGeneration: operationGeneration
            )
            guard self.generation == operationGeneration else {
                return
            }
            self.playbackRecoveryTask = nil
        }
    }

    private func performPlaybackRecovery(
        _ action: PlaybackRecoveryAction,
        operationGeneration: UInt64
    ) async {
        let recoveryTime = currentTime
        switch action {
        case .rebuildCurrentSource:
            do {
                try await rebuildQueue(at: recoveryTime)
                guard generation == operationGeneration,
                    !Task.isCancelled,
                    isPlaybackRequested
                else {
                    return
                }
                currentTime = recoveryTime
                resumeAfterPlaybackRecovery()
                record(.completed(.recoverPlayback, category: .playback))
            } catch {
                guard generation == operationGeneration,
                    !Task.isCancelled
                else {
                    return
                }
                let isStreaming =
                    preparation?.sessionID != nil && activeAccount != nil
                let isTranscoded: Bool
                switch preparation?.source {
                case .hls:
                    isTranscoded = true
                case .direct, .none:
                    isTranscoded = false
                }
                let fallback = playbackRecoveryPolicy.action(
                    for: .itemFailure,
                    isStreaming: isStreaming,
                    isTranscoded: isTranscoded
                )
                await performPlaybackRecovery(
                    fallback,
                    operationGeneration: operationGeneration
                )
            }
        case .reopenSession(let preference):
            await reopenPlaybackSession(
                preference: preference,
                recoveryTime: recoveryTime,
                operationGeneration: operationGeneration
            )
        case .fallbackFromLocal(let failedURL):
            guard await service.reportServerTransportFailure(
                url: failedURL
            ) else {
                failPlaybackRecovery()
                return
            }
            await reopenPlaybackSession(
                preference: .automatic,
                recoveryTime: recoveryTime,
                operationGeneration: operationGeneration
            )
        case .fail:
            failPlaybackRecovery()
        }
    }

    private func currentLocalPlaybackURL() -> URL? {
        guard let account = activeAccount,
            let local = account.localServer,
            let asset = player?.currentItem?.asset as? AVURLAsset,
            Self.isURL(asset.url, under: local.url)
        else {
            return nil
        }
        return asset.url
    }

    private static func isURL(_ url: URL, under serverURL: URL) -> Bool {
        guard let value = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
            let server = URLComponents(
                url: serverURL,
                resolvingAgainstBaseURL: false
            )
        else {
            return false
        }
        return value.scheme == server.scheme
            && value.host == server.host
            && value.port == server.port
            && value.path.hasPrefix(server.path)
    }

    private func reopenPlaybackSession(
        preference: PlaybackPreference,
        recoveryTime: Double,
        operationGeneration: UInt64
    ) async {
        guard let account = activeAccount,
            let itemID,
            let previousPreparation = preparation,
            let previousSessionID = previousPreparation.sessionID
        else {
            failPlaybackRecovery()
            return
        }

        do {
            let replacement = try await service.openPlayback(
                for: account,
                itemID: itemID,
                preference: preference,
                deviceInfo: Self.deviceInfo()
            )
            guard generation == operationGeneration,
                !Task.isCancelled,
                isPlaybackRequested
            else {
                if let replacementSessionID = replacement.sessionID {
                    try? await service.closePlayback(
                        for: account,
                        sessionID: replacementSessionID
                    )
                }
                return
            }

            preparation = replacement
            title = replacement.title
            duration = replacement.duration
            let clampedRecoveryTime = min(
                max(recoveryTime, 0),
                replacement.duration
            )
            currentTime = clampedRecoveryTime
            do {
                try await rebuildQueue(at: clampedRecoveryTime)
            } catch {
                if let replacementSessionID = replacement.sessionID {
                    try? await service.closePlayback(
                        for: account,
                        sessionID: replacementSessionID
                    )
                }
                preparation = previousPreparation
                throw error
            }
            guard generation == operationGeneration,
                !Task.isCancelled,
                isPlaybackRequested
            else {
                if let replacementSessionID = replacement.sessionID {
                    try? await service.closePlayback(
                        for: account,
                        sessionID: replacementSessionID
                    )
                }
                return
            }
            if replacement.sessionID != previousSessionID {
                try? await service.closePlayback(
                    for: account,
                    sessionID: previousSessionID
                )
            }
            resumeAfterPlaybackRecovery()
            record(.completed(.recoverPlayback, category: .playback))
        } catch let error as AppServiceError {
            guard generation == operationGeneration,
                !Task.isCancelled
            else {
                return
            }
            failPlaybackRecovery(
                AppFailure(operation: .recoverPlayback, serviceError: error)
            )
        } catch {
            guard generation == operationGeneration,
                !Task.isCancelled
            else {
                return
            }
            failPlaybackRecovery()
        }
    }

    private func resumeAfterPlaybackRecovery() {
        hasConfirmedPlaybackAdvance = false
        stablePlaybackStartedAt = nil
        lastObservedWholeBookTime = currentTime
        lastConfirmedAdvanceAt = monotonicNow()
        transitionPlaybackState(to: .buffering)
        player?.playImmediately(atRate: rate)
        updateAutomaticDownloadBandwidth()
        updateNowPlaying()
    }

    private func failPlaybackRecovery(
        _ failure: AppFailure = .mediaUnavailable
    ) {
        playbackRequested = false
        cancelPlaybackWatchdog()
        player?.pause()
        transitionPlaybackState(to: .failed(failure))
        updateAutomaticDownloadBandwidth()
        updateNowPlaying()
        record(
            .failed(
                .recoverPlayback,
                category: .playback,
                failureCode: .playbackRecoveryExhausted
            )
        )
    }

    private func notifyAutomaticDownloadProgress(force: Bool = false) {
        guard
            automaticDownloadBandwidthDecision
                == .allowAutomaticDownloads,
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

    private func updateAutomaticDownloadBandwidth(
        now: TimeInterval = Date().timeIntervalSinceReferenceDate
    ) {
        guard let player,
            activeAccount != nil,
            activeDownloadDetail != nil,
            preparation != nil
        else {
            return
        }
        let decision = automaticDownloadPlaybackGate.decision(
            isPlayingIntent: isPlaybackRequested,
            timeControlStatus: player.timeControlStatus,
            now: now
        )
        guard decision != automaticDownloadBandwidthDecision else {
            return
        }
        automaticDownloadBandwidthDecision = decision
        switch decision {
        case .reserveForPlayback:
            notifyAutomaticDownloadActivity(
                kind: .playbackNeedsBandwidth
            )
        case .allowAutomaticDownloads:
            if isPlaybackRequested {
                notifyAutomaticDownloadProgress(force: true)
            } else {
                notifyAutomaticDownloadBandwidthReleased()
            }
        }
    }

    private func notifyAutomaticDownloadBandwidthReleased() {
        notifyAutomaticDownloadActivity(
            kind: .playbackReleasedBandwidth
        )
    }

    private func notifyAutomaticDownloadActivity(
        kind: AutomaticDownloadActivityKind
    ) {
        guard
            let automaticDownloadHandler,
            let detail = activeDownloadDetail,
            let account = activeAccount,
            let preparation
        else {
            return
        }
        let activity = AutomaticDownloadActivity(
            kind: kind,
            detail: detail,
            account: account,
            currentTime: currentTime,
            chapters: preparation.chapters,
            fileRanges: []
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
        recordStatisticsSample(isAudibleAndAdvancing: false)
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
        currentTime = duration
        setSleepTimer(minutes: nil)
        persistLocalPosition()
        state = .ended
        updateNowPlaying()
        notifyAutomaticDownloadFinished()
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            if self.preparation?.sessionID != nil {
                await self.syncProgress()
            }
            await self.recordNaturalCompletion()
            await self.finishStatisticsSession()
        }
    }

    private var statisticsSessionID: PlaybackSessionID? {
        preparation?.sessionID ?? localPlaybackSession?.id
    }

    private func recordStatisticsSample(
        isAudibleAndAdvancing: Bool
    ) {
        guard let accountID,
            let itemID,
            let sessionID = statisticsSessionID,
            duration.isFinite,
            duration > 0
        else {
            return
        }
        let sample = StatisticsPlaybackSample(
            accountID: accountID,
            itemID: itemID,
            sessionID: sessionID,
            observedAt: Date(),
            monotonicTime: monotonicNow(),
            wholeBookPosition: currentTime,
            playbackRate: Double(rate),
            playbackGeneration: generation,
            isAudibleAndAdvancing: isAudibleAndAdvancing,
            chapter: currentChapter,
            title: title,
            author: author,
            duration: duration
        )
        let previousTask = statisticsRecordingTask
        statisticsRecordingTask = Task { [service] in
            _ = await previousTask?.result
            try? await service.recordStatisticsSample(sample)
        }
    }

    private func finishStatisticsSession() async {
        guard let sessionID = statisticsSessionID else {
            return
        }
        recordStatisticsSample(isAudibleAndAdvancing: false)
        _ = await statisticsRecordingTask?.result
        statisticsRecordingTask = nil
        try? await service.finishStatisticsSession(sessionID)
    }

    private func recordNaturalCompletion() async {
        guard let accountID,
            let itemID,
            duration.isFinite,
            duration > 0
        else {
            return
        }
        try? await service.recordCompletion(
            CompletionMilestone(
                accountID: accountID,
                itemID: itemID,
                completedAt: Date(),
                duration: duration,
                title: title,
                author: author,
                evidence: .naturalEnd
            )
        )
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
        guard preparation.sessionID != nil else {
            persistLocalPosition()
            return
        }
        await diagnostics.record(
            .started(.syncPlayback, category: .sync)
        )
        let position = min(max(currentTime, 0), preparation.duration)
        guard let activeAccount,
            let sessionID = preparation.sessionID
        else {
            return
        }
        await finishStatisticsSession()
        let listeningDelta =
            (try? await service.pendingStatisticsRealSeconds(
                accountID: activeAccount.id,
                sessionID: sessionID
            )) ?? 0
        syncState = .syncing
        do {
            try await service.syncPlayback(
                for: activeAccount,
                sessionID: sessionID,
                currentTime: position,
                duration: preparation.duration,
                timeListened: listeningDelta
            )
            guard self.preparation?.sessionID == sessionID else {
                return
            }
            try await service.confirmStatisticsSync(
                accountID: activeAccount.id,
                sessionID: sessionID,
                realSeconds: listeningDelta
            )
            lastAttemptedSyncTime = position
            syncState = .idle
            await diagnostics.record(
                .completed(.syncPlayback, category: .sync)
            )
        } catch let error {
            guard self.preparation?.sessionID == sessionID else {
                return
            }
            if listeningDelta > 0,
                Self.isAmbiguousStatisticsSyncFailure(error)
            {
                try? await service.markStatisticsSyncUncertain(
                    accountID: activeAccount.id,
                    sessionID: sessionID,
                    realSeconds: listeningDelta
                )
            }
            syncState = .failed
            await diagnostics.record(
                .failed(
                    .syncPlayback,
                    category: .sync,
                    failureCode: .progressUnavailable
                )
            )
        }
    }

    private static func isAmbiguousStatisticsSyncFailure(
        _ error: AppServiceError
    ) -> Bool {
        switch error {
        case .playbackSync(.requestFailed):
            true
        case .playbackSync(
            .authenticationFailed(.requestTransportFailed)
        ):
            true
        default:
            false
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
        await diagnostics.record(
            .started(.syncLocalSessions, category: .sync)
        )
        do {
            let pending = try localSessionStore.pending(
                accountID: account.id
            )
            if !pending.isEmpty {
                let measured = try await localSessionsWithListeningTime(
                    pending,
                    accountID: account.id
                )
                let results = try await service.syncLocalPlaybackSessions(
                    for: account,
                    sessions: measured.sessions,
                    deviceInfo: Self.deviceInfo()
                )
                let acknowledged = Set(
                    results.filter(\.success).map(\.id)
                )
                for sessionID in acknowledged {
                    try await service.confirmStatisticsSync(
                        accountID: account.id,
                        sessionID: sessionID,
                        realSeconds: measured.deltas[sessionID] ?? 0
                    )
                }
                try localSessionStore.removeAcknowledged(
                    accountID: account.id,
                    sessionIDs: acknowledged
                )
                await diagnostics.record(
                    .completed(
                        .syncLocalSessions,
                        category: .sync,
                        count: results.count
                    )
                )
            } else {
                await diagnostics.record(
                    .completed(
                        .syncLocalSessions,
                        category: .sync,
                        count: 0
                    )
                )
            }
        } catch {
            // The durable outbox remains intact for the next retry.
            await diagnostics.record(
                .failed(
                    .syncLocalSessions,
                    category: .sync,
                    failureCode: .progressUnavailable
                )
            )
            return
        }
        await syncPendingBookmarks(for: account)
    }

    private func localSessionsWithListeningTime(
        _ sessions: [LocalPlaybackSession],
        accountID: AccountID
    ) async throws -> (
        sessions: [LocalPlaybackSession],
        deltas: [PlaybackSessionID: Double]
    ) {
        var measured: [LocalPlaybackSession] = []
        var deltas: [PlaybackSessionID: Double] = [:]
        measured.reserveCapacity(sessions.count)
        for session in sessions {
            let delta = try await service.pendingStatisticsRealSeconds(
                accountID: accountID,
                sessionID: session.id
            )
            measured.append(
                try session.updating(
                    currentTime: session.currentTime,
                    timeListening: session.timeListening + delta
                )
            )
            deltas[session.id] = delta
        }
        return (measured, deltas)
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
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
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
            resumeAfterInterruption = isPlaybackRequested
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
        playbackRequested = false
        cancelPlaybackWatchdog()
        playbackRecoveryTask?.cancel()
        playbackRecoveryTask = nil
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
                state = .ready
                playbackRequested = true
                startPlaybackWatchdog()
                resumeAfterPlaybackRecovery()
            case .pause:
                state = .paused
            }
            updateAutomaticDownloadBandwidth()
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
        guard let itemID, hasActiveBook else {
            return
        }
        let currentChapterIndex = currentChapter.flatMap { chapter in
            chapters.firstIndex { $0.id == chapter.id }
        }
        nowPlayingCoordinator.publish(
            NowPlayingSnapshot(
                accountID: accountID,
                itemID: itemID,
                title: title,
                author: author,
                narrator: narrator,
                coverURL: coverURL,
                coverLoadPolicy: coverLoadPolicy,
                currentTime: currentTime,
                duration: duration,
                rate: rate,
                isPlaying: isPlaying,
                isPlaybackRequested: isPlaybackRequested,
                isPlaybackAvailable: isPlaybackControlAvailable,
                canPerformPreviousCommand: canPerformHeadphoneCommand(
                    previousCommandAction
                ),
                canPerformNextCommand: canPerformHeadphoneCommand(
                    nextCommandAction
                ),
                currentChapterIndex: currentChapterIndex,
                currentChapterTitle: currentChapter?.title,
                chapterCount: chapters.count
            )
        )
    }

    private var isPlaybackControlAvailable: Bool {
        guard preparation != nil else {
            return false
        }
        switch state {
        case .ready, .buffering, .playing, .paused:
            return true
        case .idle, .preparing, .ended, .failed:
            return false
        }
    }

    func handleRemoteCommand(
        _ command: PlaybackRemoteCommand
    ) -> PlaybackRemoteCommandOutcome {
        switch command {
        case .play:
            guard isPlaybackControlAvailable, !isPlaybackRequested else {
                return .unavailable
            }
            play()
        case .pause:
            guard isPlaybackControlAvailable, isPlaybackRequested else {
                return .unavailable
            }
            pause()
        case .toggle:
            guard isPlaybackControlAvailable else {
                return .unavailable
            }
            togglePlayback()
        case .skipBackward:
            guard isPlaybackControlAvailable else {
                return .unavailable
            }
            Task { @MainActor [weak self] in
                await self?.skipBackward()
            }
        case .skipForward:
            guard isPlaybackControlAvailable else {
                return .unavailable
            }
            Task { @MainActor [weak self] in
                await self?.skipForward()
            }
        case .previous:
            return handleHeadphoneCommand(previousCommandAction)
        case .next:
            return handleHeadphoneCommand(nextCommandAction)
        case .previousChapter:
            guard isPlaybackControlAvailable,
                canMoveToPreviousChapter
            else {
                return .unavailable
            }
            Task { @MainActor [weak self] in
                await self?.previousChapter()
            }
        case .nextChapter:
            guard isPlaybackControlAvailable, canMoveToNextChapter else {
                return .unavailable
            }
            Task { @MainActor [weak self] in
                await self?.nextChapter()
            }
        case .seek(let position):
            guard position.isFinite,
                (0...duration).contains(position)
            else {
                return .invalid
            }
            guard isPlaybackControlAvailable else {
                return .unavailable
            }
            Task { @MainActor [weak self] in
                await self?.seek(to: position)
            }
        case .setRate(let requestedRate):
            guard requestedRate.isFinite,
                (0.5...3).contains(requestedRate)
            else {
                return .invalid
            }
            guard isPlaybackControlAvailable else {
                return .unavailable
            }
            setRate(requestedRate)
        }
        return .accepted
    }

    private func handleHeadphoneCommand(
        _ action: HeadphoneCommandAction
    ) -> PlaybackRemoteCommandOutcome {
        handleRemoteCommand(action.remoteCommand)
    }

    private func canPerformHeadphoneCommand(
        _ action: HeadphoneCommandAction
    ) -> Bool {
        action.isAvailable(
            canMoveToPreviousChapter: canMoveToPreviousChapter,
            canMoveToNextChapter: canMoveToNextChapter
        )
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
