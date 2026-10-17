import BleatCore
import Foundation
import MediaPlayer
import Synchronization

enum PlaybackRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case toggle
    case skipBackward
    case skipForward
    case previous
    case next
    case previousChapter
    case nextChapter
    case seek(Double)
    case setRate(Float)
}

enum PlaybackRateStep: Equatable, Sendable {
    case decrease
    case increase
}

extension HeadphoneCommandAction {
    var remoteCommand: PlaybackRemoteCommand {
        switch self {
        case .skipBackward:
            .skipBackward
        case .skipForward:
            .skipForward
        case .previousChapter:
            .previousChapter
        case .nextChapter:
            .nextChapter
        }
    }
}

enum PlaybackRemoteCommandOutcome: Equatable, Sendable {
    case accepted
    case unavailable
    case invalid

    var mediaPlayerStatus: MPRemoteCommandHandlerStatus {
        switch self {
        case .accepted:
            .success
        case .unavailable:
            .noSuchContent
        case .invalid:
            .commandFailed
        }
    }
}

struct NowPlayingSnapshot: Equatable, Sendable {
    let accountID: AccountID?
    let itemID: LibraryItemID
    let title: String
    let author: String
    let narrator: String
    let coverURL: URL?
    let coverLoadPolicy: BookCoverLoadPolicy
    let currentTime: Double
    let duration: Double
    let rate: Float
    let isPlaying: Bool
    let isPlaybackRequested: Bool
    let isPlaybackAvailable: Bool
    let canPerformPreviousCommand: Bool
    let canPerformNextCommand: Bool
    let currentChapterIndex: Int?
    let currentChapterTitle: String?
    let chapterCount: Int

    func information(artwork: MPMediaItemArtwork?) -> [String: Any] {
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate:
                isPlaying ? Double(rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: Double(rate),
            MPNowPlayingInfoPropertyMediaType:
                MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyExternalContentIdentifier:
                externalContentIdentifier,
        ]
        if !author.isEmpty {
            information[MPMediaItemPropertyArtist] = author
        }
        if !narrator.isEmpty {
            information[MPMediaItemPropertyComposer] = narrator
        }
        if let currentChapterIndex {
            information[MPNowPlayingInfoPropertyChapterNumber] =
                currentChapterIndex
            information[MPNowPlayingInfoPropertyChapterCount] = chapterCount
        }
        if let currentChapterTitle, !currentChapterTitle.isEmpty {
            information[MPMediaItemPropertyAlbumTitle] = currentChapterTitle
        }
        if let artwork {
            information[MPMediaItemPropertyArtwork] = artwork
        }
        return information
    }

    var systemPlaybackState: MPNowPlayingPlaybackState {
        guard isPlaybackAvailable else {
            return .stopped
        }
        return isPlaybackRequested ? .playing : .paused
    }

    private var externalContentIdentifier: String {
        if let accountID {
            return "\(accountID.rawValue):\(itemID.rawValue)"
        }
        return itemID.rawValue
    }
}

enum NowPlayingArtwork {
    nonisolated static func make(from image: PlatformImage)
        -> MPMediaItemArtwork
    {
        #if os(iOS)
            let provider: @Sendable (CGSize) -> PlatformImage = { _ in image }
        #else
            let provider: @Sendable (CGSize) -> PlatformImage = { _ in image }
        #endif
        return MPMediaItemArtwork(
            boundsSize: image.size,
            requestHandler: provider
        )
    }
}

private struct NowPlayingArtworkIdentity: Equatable {
    let accountID: AccountID?
    let url: URL
    let policy: BookCoverLoadPolicy
}

@MainActor
protocol NowPlayingInfoPublishing: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    var playbackState: MPNowPlayingPlaybackState { get set }
}

extension MPNowPlayingInfoCenter: NowPlayingInfoPublishing {}

private struct RemoteCommandAdmission: Sendable {
    var snapshot: NowPlayingSnapshot?
    var hasHandler = false
    var hasResumableSelection = false
    var generation: UInt64 = 0

    func outcome(for command: PlaybackRemoteCommand)
        -> PlaybackRemoteCommandOutcome
    {
        switch command {
        case .seek(let position):
            guard position.isFinite, position >= 0,
                let snapshot, position <= snapshot.duration
            else { return .invalid }
        case .setRate(let rate):
            guard rate.isFinite, (0.5...3).contains(rate) else {
                return .invalid
            }
        default: break
        }
        guard hasHandler else { return .unavailable }
        if snapshot == nil, hasResumableSelection {
            switch command {
            case .play, .toggle: return .accepted
            default: return .unavailable
            }
        }
        guard let snapshot, snapshot.isPlaybackAvailable else {
            return .unavailable
        }
        switch command {
        case .play where snapshot.isPlaybackRequested: return .unavailable
        case .pause where !snapshot.isPlaybackRequested: return .unavailable
        case .previous where !snapshot.canPerformPreviousCommand:
            return .unavailable
        case .next where !snapshot.canPerformNextCommand: return .unavailable
        default: return .accepted
        }
    }
}

@MainActor
final class NowPlayingCoordinator {
    private let infoCenter: any NowPlayingInfoPublishing
    private let commandCenter: MPRemoteCommandCenter
    private let coverLoader: BookCoverImageLoader
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var commandHandler:
        (@MainActor (PlaybackRemoteCommand) -> PlaybackRemoteCommandOutcome)?
    private nonisolated let remoteCommandAdmission = Mutex(
        RemoteCommandAdmission())
    private var latestSnapshot: NowPlayingSnapshot?
    private(set) var remoteCommandCallbackProcessingSequenceForTesting = 0
    private var artworkIdentity: NowPlayingArtworkIdentity?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var artworkGeneration: UInt64 = 0

    init(
        infoCenter: any NowPlayingInfoPublishing =
            MPNowPlayingInfoCenter.default(),
        commandCenter: MPRemoteCommandCenter = .shared(),
        coverLoader: BookCoverImageLoader = .shared,
        registersRemoteCommands: Bool = true
    ) {
        self.infoCenter = infoCenter
        self.commandCenter = commandCenter
        self.coverLoader = coverLoader
        if registersRemoteCommands {
            registerRemoteCommands()
        }
    }

    func setCommandHandler(
        _ handler:
            @escaping @MainActor (
                PlaybackRemoteCommand
            ) -> PlaybackRemoteCommandOutcome
    ) {
        commandHandler = handler
        remoteCommandAdmission.withLock {
            $0.hasHandler = true
            $0.generation &+= 1
        }
    }

    func setSkipIntervals(backward: Int, forward: Int) {
        commandCenter.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: backward)
        ]
        commandCenter.skipForwardCommand.preferredIntervals = [
            NSNumber(value: forward)
        ]
    }

    func publish(_ snapshot: NowPlayingSnapshot) {
        if latestSnapshot?.itemID != snapshot.itemID
            || latestSnapshot?.accountID != snapshot.accountID
            || latestSnapshot?.isPlaybackRequested
                != snapshot.isPlaybackRequested
            || latestSnapshot?.isPlaybackAvailable
                != snapshot.isPlaybackAvailable
        {
            Task {
                await SystemDiagnosticRecorder.shared.record(
                    .completed(.publishNowPlaying, category: .playback))
            }
        }
        let nextArtworkIdentity = snapshot.coverURL.map {
            NowPlayingArtworkIdentity(
                accountID: snapshot.accountID,
                url: $0,
                policy: snapshot.coverLoadPolicy
            )
        }
        latestSnapshot = snapshot
        remoteCommandAdmission.withLock { $0.snapshot = snapshot }
        updateCommandAvailability(snapshot)
        infoCenter.nowPlayingInfo = snapshot.information(artwork: artwork)
        infoCenter.playbackState = snapshot.systemPlaybackState

        guard nextArtworkIdentity != artworkIdentity else {
            return
        }
        artworkTask?.cancel()
        artworkTask = nil
        artworkIdentity = nextArtworkIdentity
        artwork = nil
        infoCenter.nowPlayingInfo = snapshot.information(artwork: nil)
        guard let nextArtworkIdentity else {
            return
        }

        artworkGeneration &+= 1
        let generation = artworkGeneration
        artworkTask = Task { @MainActor [weak self] in
            guard let self,
                let image = await coverLoader.image(
                    for: nextArtworkIdentity.url,
                    accountID: nextArtworkIdentity.accountID,
                    policy: nextArtworkIdentity.policy
                ),
                !Task.isCancelled,
                generation == artworkGeneration,
                artworkIdentity == nextArtworkIdentity
            else {
                return
            }
            artwork = NowPlayingArtwork.make(from: image)
            guard let latestSnapshot else {
                return
            }
            infoCenter.nowPlayingInfo = latestSnapshot.information(
                artwork: artwork
            )
        }
    }

    func setResumableSelectionAvailable(_ available: Bool) {
        remoteCommandAdmission.withLock {
            if !available, $0.hasResumableSelection, $0.snapshot == nil {
                $0.generation &+= 1
            }
            $0.hasResumableSelection = available
        }
        if let latestSnapshot {
            updateCommandAvailability(latestSnapshot)
        } else {
            commandCenter.playCommand.isEnabled = available
            commandCenter.togglePlayPauseCommand.isEnabled = available
        }
    }

    func clear() {
        remoteCommandAdmission.withLock {
            $0.snapshot = nil
            $0.hasResumableSelection = false
            $0.generation &+= 1
        }
        Task {
            await SystemDiagnosticRecorder.shared.record(
                .completed(.clearNowPlaying, category: .playback))
        }
        artworkGeneration &+= 1
        artworkTask?.cancel()
        artworkTask = nil
        artworkIdentity = nil
        artwork = nil
        latestSnapshot = nil
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
        updateCommandAvailability(nil)
    }

    func stepPlaybackRate(
        _ step: PlaybackRateStep
    ) -> PlaybackRemoteCommandOutcome {
        guard let snapshot = latestSnapshot,
            snapshot.isPlaybackAvailable
        else {
            return .unavailable
        }
        let nextRate: Float? =
            switch step {
            case .decrease:
                PlaybackPreferencesStore.featuredRates.last {
                    $0 < snapshot.rate - 0.001
                }
            case .increase:
                PlaybackPreferencesStore.featuredRates.first {
                    $0 > snapshot.rate + 0.001
                }
            }
        guard let nextRate else {
            return .unavailable
        }
        return commandHandler?(.setRate(nextRate)) ?? .unavailable
    }

    private func registerRemoteCommands() {
        addTarget(to: commandCenter.playCommand) { _ in .play }
        addTarget(to: commandCenter.pauseCommand) { _ in .pause }
        addTarget(to: commandCenter.togglePlayPauseCommand) { _ in .toggle }
        addTarget(to: commandCenter.skipBackwardCommand) {
            _ in .skipBackward
        }
        addTarget(to: commandCenter.skipForwardCommand) {
            _ in .skipForward
        }
        addTarget(to: commandCenter.previousTrackCommand) {
            _ in .previous
        }
        addTarget(to: commandCenter.nextTrackCommand) {
            _ in .next
        }
        addTarget(to: commandCenter.changePlaybackPositionCommand) {
            event in
            guard
                let event =
                    event as? MPChangePlaybackPositionCommandEvent
            else {
                return nil
            }
            return .seek(event.positionTime)
        }
        commandCenter.changePlaybackRateCommand.supportedPlaybackRates =
            PlaybackPreferencesStore.featuredRates.map(NSNumber.init(value:))
        addTarget(to: commandCenter.changePlaybackRateCommand) { event in
            guard
                let event = event as? MPChangePlaybackRateCommandEvent
            else {
                return nil
            }
            return .setRate(event.playbackRate)
        }
    }

    private func addTarget(
        to command: MPRemoteCommand,
        commandForEvent:
            @escaping @Sendable (MPRemoteCommandEvent)
            -> PlaybackRemoteCommand?
    ) {
        let target = command.addTarget(
            handler: makeRemoteCommandCallback(commandForEvent: commandForEvent)
        )
        commandTargets.append((command, target))
    }

    // MediaPlayer requires an immediate acknowledgement. Admit from a locked
    // snapshot, then deliver asynchronously; never wait for the main actor.
    func makeRemoteCommandCallback<Event>(
        commandForEvent:
            @escaping @Sendable (Event) -> PlaybackRemoteCommand?
    ) -> @Sendable (Event) -> MPRemoteCommandHandlerStatus {
        return { @Sendable [weak self] event in
            guard let self, let command = commandForEvent(event) else {
                return .commandFailed
            }
            let state = self.remoteCommandAdmission.withLock { $0 }
            let outcome = state.outcome(for: command)
            guard outcome == .accepted else { return outcome.mediaPlayerStatus }
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    remoteCommandCallbackProcessingSequenceForTesting += 1
                }
                guard
                    self.remoteCommandAdmission.withLock({
                        $0.generation == state.generation
                    })
                else { return }
                _ = self.commandHandler?(command)
            }
            return .success
        }
    }

    private func updateCommandAvailability(
        _ snapshot: NowPlayingSnapshot?
    ) {
        let available = snapshot?.isPlaybackAvailable == true
        commandCenter.playCommand.isEnabled =
            available && snapshot?.isPlaybackRequested == false
        commandCenter.pauseCommand.isEnabled =
            available && snapshot?.isPlaybackRequested == true
        commandCenter.togglePlayPauseCommand.isEnabled = available
        commandCenter.skipBackwardCommand.isEnabled = available
        commandCenter.skipForwardCommand.isEnabled = available
        commandCenter.changePlaybackPositionCommand.isEnabled = available
        commandCenter.changePlaybackRateCommand.isEnabled = available
        commandCenter.previousTrackCommand.isEnabled =
            available && snapshot?.canPerformPreviousCommand == true
        commandCenter.nextTrackCommand.isEnabled =
            available && snapshot?.canPerformNextCommand == true
    }
}
