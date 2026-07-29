import BleatCore
import Foundation

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

    private let defaults: UserDefaults
    private let rateKey = "bleat.playback.defaultRate.v1"
    private let resumeRewindKey = "bleat.playback.resumeRewind.v1"

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

    private static func normalizedRate(_ rate: Float) -> Float {
        guard rate.isFinite else {
            return 1
        }
        let rounded = (rate * 20).rounded() / 20
        return min(max(rounded, 0.5), 3)
    }
}
