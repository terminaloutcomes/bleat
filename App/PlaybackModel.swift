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

@MainActor
@Observable
final class PlaybackModel {
    private let service: any AppServicing
    private var generation: UInt64 = 0
    private var player: AVQueuePlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var audioSessionObservers: [NSObjectProtocol] = []
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var offsetsByItem: [ObjectIdentifier: Double] = [:]
    private var activeAccount: ServerAccount?
    private var preparation: AppPlaybackPreparation?
    private var resumeAfterInterruption = false
    private var lastAttemptedSyncTime: Double = 0

    private(set) var state: PlaybackState = .idle
    private(set) var syncState: PlaybackSyncState = .idle
    private(set) var itemID: LibraryItemID?
    private(set) var title = ""
    private(set) var author = ""
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var rate: Float = 1

    var hasActiveBook: Bool {
        state != .idle
    }

    var isPlaying: Bool {
        state == .playing
    }

    init(service: any AppServicing) {
        self.service = service
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
        resetPlayer()
        state = .preparing
        itemID = detail.id
        title = detail.title
        author = detail.authors.map(\.name).joined(separator: ", ")
        duration = detail.duration
        currentTime = detail.progress?.currentTime ?? 0
        lastAttemptedSyncTime = currentTime
        syncState = .idle

        let deviceInfo = PlaybackDeviceInfo(
            deviceID: UIDevice.current.identifierForVendor?
                .uuidString.lowercased() ?? "bleat-ios-device",
            clientName: "Bleat",
            clientVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "0.1",
            manufacturer: "Apple",
            model: UIDevice.current.model
        )

        do {
            let prepared = try await service.openPlayback(
                for: account,
                itemID: detail.id,
                deviceInfo: deviceInfo
            )
            guard generation == operationGeneration else {
                try? await service.closePlayback(
                    for: account,
                    sessionID: prepared.sessionID
                )
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
        itemID = nil
        title = ""
        author = ""
        currentTime = 0
        duration = 0
        lastAttemptedSyncTime = 0
        state = .idle
        syncState = .idle
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
        state = .ended
        updateNowPlaying()
        Task { @MainActor [weak self] in
            await self?.syncProgress()
        }
    }

    private func syncProgress() async {
        guard syncState != .syncing,
            let activeAccount,
            let preparation
        else {
            return
        }
        let sessionID = preparation.sessionID
        let position = min(max(currentTime, 0), preparation.duration)
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
