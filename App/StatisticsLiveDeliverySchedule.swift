import Foundation

/// Only changed live data schedules a wakeup. Deadlines stay anchored to the
/// previous delivery rather than moving with every playback sample.
struct StatisticsLiveDeliverySchedule {
    private var lastDelivery: ContinuousClock.Instant?

    func deadline(at now: ContinuousClock.Instant) -> ContinuousClock.Instant? {
        guard let lastDelivery else { return nil }
        let deadline = lastDelivery.advanced(by: .seconds(1))
        return now < deadline ? deadline : nil
    }

    mutating func didDeliver(at now: ContinuousClock.Instant) {
        lastDelivery = now
    }
}
