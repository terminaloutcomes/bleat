import BleatCore
import Foundation
import MediaPlayer
import UIKit

enum PlaybackRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case toggle
    case skipBackward
    case skipForward
    case previousChapter
    case nextChapter
    case seek(Double)
    case setRate(Float)
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
    let canMoveToPreviousChapter: Bool
    let canMoveToNextChapter: Bool
    let currentChapterIndex: Int?
    let currentChapterTitle: String?
    let chapterCount: Int

    func information(artwork: MPMediaItemArtwork?) -> [String: Any] {
        var information: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyMediaType: MPMediaType.audioBook.rawValue,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate,
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

    private var externalContentIdentifier: String {
        if let accountID {
            return "\(accountID.rawValue):\(itemID.rawValue)"
        }
        return itemID.rawValue
    }
}

enum NowPlayingArtwork {
    nonisolated static func make(from image: UIImage) -> MPMediaItemArtwork {
        let provider: @Sendable (CGSize) -> UIImage = { _ in image }
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
}

extension MPNowPlayingInfoCenter: NowPlayingInfoPublishing {}

@MainActor
final class NowPlayingCoordinator {
    private let infoCenter: any NowPlayingInfoPublishing
    private let commandCenter: MPRemoteCommandCenter
    private let coverLoader: BookCoverImageLoader
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    private var commandHandler:
        (@MainActor (PlaybackRemoteCommand) -> PlaybackRemoteCommandOutcome)?
    private var latestSnapshot: NowPlayingSnapshot?
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
        let nextArtworkIdentity = snapshot.coverURL.map {
            NowPlayingArtworkIdentity(
                accountID: snapshot.accountID,
                url: $0,
                policy: snapshot.coverLoadPolicy
            )
        }
        latestSnapshot = snapshot
        updateCommandAvailability(snapshot)
        infoCenter.nowPlayingInfo = snapshot.information(artwork: artwork)

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

    func clear() {
        artworkGeneration &+= 1
        artworkTask?.cancel()
        artworkTask = nil
        artworkIdentity = nil
        artwork = nil
        latestSnapshot = nil
        infoCenter.nowPlayingInfo = nil
        updateCommandAvailability(nil)
    }

    func cyclePlaybackRate() -> PlaybackRemoteCommandOutcome {
        guard let snapshot = latestSnapshot,
            snapshot.isPlaybackAvailable
        else {
            return .unavailable
        }
        let nextRate =
            PlaybackPreferencesStore.featuredRates.first {
                $0 > snapshot.rate + 0.001
            }
            ?? PlaybackPreferencesStore.featuredRates[0]
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
            _ in .previousChapter
        }
        addTarget(to: commandCenter.nextTrackCommand) {
            _ in .nextChapter
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
        let target = command.addTarget { [weak self] event in
            guard let self,
                let remoteCommand = commandForEvent(event)
            else {
                return .commandFailed
            }
            let outcome =
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self.commandHandler?(remoteCommand)
                            ?? .unavailable
                    }
                } else {
                    DispatchQueue.main.sync {
                        MainActor.assumeIsolated {
                            self.commandHandler?(remoteCommand)
                                ?? .unavailable
                        }
                    }
                }
            return outcome.mediaPlayerStatus
        }
        commandTargets.append((command, target))
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
            available && snapshot?.canMoveToPreviousChapter == true
        commandCenter.nextTrackCommand.isEnabled =
            available && snapshot?.canMoveToNextChapter == true
    }
}
