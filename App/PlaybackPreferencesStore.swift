import BleatCore
import Foundation

enum PlaybackSkipInterval: Int, CaseIterable, Identifiable, Sendable {
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30
    case fortyFiveSeconds = 45
    case sixtySeconds = 60

    var id: Int {
        rawValue
    }

    var label: String {
        "\(rawValue) seconds"
    }
}

extension HeadphoneCommandAction {
    var label: String {
        switch self {
        case .skipBackward:
            "Skip Back"
        case .skipForward:
            "Skip Forward"
        case .previousChapter:
            "Previous Chapter"
        case .nextChapter:
            "Next Chapter"
        }
    }

    func isAvailable(
        canMoveToPreviousChapter: Bool,
        canMoveToNextChapter: Bool
    ) -> Bool {
        switch self {
        case .skipBackward, .skipForward:
            true
        case .previousChapter:
            canMoveToPreviousChapter
        case .nextChapter:
            canMoveToNextChapter
        }
    }
}

enum ResumeRewind: Int, CaseIterable, Codable, Identifiable, Sendable {
    case off = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30

    var id: Int {
        rawValue
    }

    var label: String {
        switch self {
        case .off:
            "Off"
        default:
            "\(rawValue) seconds"
        }
    }
}

enum PlaybackResumeRewindDecision {
    static let minimumPauseDuration: TimeInterval = 5 * 60

    static func target(
        currentTime: Double,
        pausedAt: Date?,
        now: Date,
        setting: ResumeRewind
    ) -> Double? {
        guard setting != .off,
            let pausedAt,
            now.timeIntervalSince(pausedAt) >= minimumPauseDuration,
            currentTime.isFinite,
            currentTime >= 0
        else {
            return nil
        }
        return max(0, currentTime - Double(setting.rawValue))
    }
}

enum PlaybackChapterSleepDecision {
    static func target(
        chapters: [PlaybackChapter],
        currentTime: Double,
        duration: Double
    ) -> Double? {
        guard currentTime.isFinite,
            duration.isFinite,
            currentTime >= 0,
            duration >= 0
        else {
            return nil
        }
        return chapters.first {
            $0.start <= currentTime
                && currentTime < $0.end
                && $0.end <= duration
        }?.end
    }
}

@MainActor
final class PlaybackPreferencesStore {
    static let shared = PlaybackPreferencesStore(defaults: .standard)
    static let featuredRates: [Float] = [
        0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3,
    ]

    private let defaults: UserDefaults
    private let rateKey = "bleat.playback.defaultRate.v1"
    private let resumeRewindKey = "bleat.playback.resumeRewind.v1"
    private let skipBackwardKey = "bleat.playback.skipBackward.v1"
    private let skipForwardKey = "bleat.playback.skipForward.v1"
    private let previousCommandActionKey =
        "bleat.playback.previousCommandAction.v1"
    private let nextCommandActionKey =
        "bleat.playback.nextCommandAction.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func playbackRate() -> Float {
        guard defaults.object(forKey: rateKey) != nil else {
            return 1
        }
        return Self.normalizedRate(defaults.float(forKey: rateKey))
    }

    func savePlaybackRate(_ rate: Float) {
        defaults.set(Self.normalizedRate(rate), forKey: rateKey)
    }

    func resumeRewind() -> ResumeRewind {
        guard defaults.object(forKey: resumeRewindKey) != nil,
            let value = ResumeRewind(
                rawValue: defaults.integer(forKey: resumeRewindKey)
            )
        else {
            return .tenSeconds
        }
        return value
    }

    func saveResumeRewind(_ value: ResumeRewind) {
        defaults.set(value.rawValue, forKey: resumeRewindKey)
    }

    func skipBackward() -> PlaybackSkipInterval {
        skipInterval(
            forKey: skipBackwardKey,
            defaultValue: .fifteenSeconds
        )
    }

    func saveSkipBackward(_ value: PlaybackSkipInterval) {
        defaults.set(value.rawValue, forKey: skipBackwardKey)
    }

    func skipForward() -> PlaybackSkipInterval {
        skipInterval(
            forKey: skipForwardKey,
            defaultValue: .thirtySeconds
        )
    }

    func saveSkipForward(_ value: PlaybackSkipInterval) {
        defaults.set(value.rawValue, forKey: skipForwardKey)
    }

    func previousCommandAction() -> HeadphoneCommandAction {
        headphoneCommandAction(
            forKey: previousCommandActionKey,
            defaultValue: .skipBackward
        )
    }

    func savePreviousCommandAction(_ value: HeadphoneCommandAction) {
        defaults.set(value.rawValue, forKey: previousCommandActionKey)
    }

    func nextCommandAction() -> HeadphoneCommandAction {
        headphoneCommandAction(
            forKey: nextCommandActionKey,
            defaultValue: .skipForward
        )
    }

    func saveNextCommandAction(_ value: HeadphoneCommandAction) {
        defaults.set(value.rawValue, forKey: nextCommandActionKey)
    }

    private func skipInterval(
        forKey key: String,
        defaultValue: PlaybackSkipInterval
    ) -> PlaybackSkipInterval {
        guard defaults.object(forKey: key) != nil,
            let value = PlaybackSkipInterval(
                rawValue: defaults.integer(forKey: key)
            )
        else {
            return defaultValue
        }
        return value
    }

    private func headphoneCommandAction(
        forKey key: String,
        defaultValue: HeadphoneCommandAction
    ) -> HeadphoneCommandAction {
        guard let rawValue = defaults.string(forKey: key),
            let value = HeadphoneCommandAction(rawValue: rawValue)
        else {
            return defaultValue
        }
        return value
    }

    private static func normalizedRate(_ rate: Float) -> Float {
        guard rate.isFinite else {
            return 1
        }
        let rounded = (rate * 20).rounded() / 20
        return min(max(rounded, 0.5), 3)
    }
}
