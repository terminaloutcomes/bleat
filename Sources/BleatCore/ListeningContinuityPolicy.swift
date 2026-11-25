import Foundation

public enum ListeningBoundary: String, Codable, Sendable {
    case inaudibleSample, explicitStop, playbackGenerationChanged
    case accountChanged, bookChanged, sessionChanged, rateChanged,
        chapterChanged
    case positionDiscontinuity, observationDiscontinuity, metadataChanged,
        processInterrupted
    case synchronizationCheckpoint

    var permitsContinuation: Bool { self == .synchronizationCheckpoint }
}

/// One continuity predicate for recording and historical coalescing. A wall gap
/// is classification evidence only; it never contributes listening quantities.
enum ListeningContinuityPolicy {
    enum Evidence { case liveSamples, storedEndpoints }
    static let wallGapTolerance: TimeInterval = 0.5
    static let storedMediaGapTolerance: TimeInterval = 0.001

    static func canJoin(
        _ lhs: ListeningSlice, _ rhs: ListeningSlice,
        evidence: Evidence
    ) -> Bool {
        if let boundary = lhs.boundaryAfter, !boundary.permitsContinuation {
            return false
        }
        guard sameContext(lhs, rhs),
            sameReportingDay(lhs.startedAt, rhs.startedAt),
            sameReportingDay(lhs.startedAt, lhs.endedAt),
            rhs.endedAt
                <= StatisticsQuery.reportingCalendar.startOfDay(
                    for: lhs.startedAt
                ).addingTimeInterval(86_400),
            wallAdjacent(end: lhs.endedAt, start: rhs.startedAt)
        else { return false }
        return mediaAdjacent(
            end: lhs.endPosition, start: rhs.startPosition,
            tolerance: evidence == .liveSamples ? 0.5 : storedMediaGapTolerance)
    }

    static func sameContext(_ lhs: ListeningSlice, _ rhs: ListeningSlice)
        -> Bool
    {
        Set(lhs.acknowledgedResetIDs ?? [])
            == Set(rhs.acknowledgedResetIDs ?? [])
            && lhs.accountID == rhs.accountID && lhs.itemID == rhs.itemID
            && lhs.sessionID == rhs.sessionID
            && lhs.playbackRate == rhs.playbackRate
            && lhs.chapterID == rhs.chapterID
            && lhs.chapterTitle == rhs.chapterTitle
            && lhs.chapterStart == rhs.chapterStart
            && lhs.chapterEnd == rhs.chapterEnd
            && lhs.title == rhs.title && lhs.author == rhs.author
            && lhs.duration == rhs.duration
    }

    static func wallAdjacent(end: Date, start: Date) -> Bool {
        // Integer microsecond comparison ticks discard sub-microsecond Date
        // representation noise. Stored timestamps and quantities stay untouched.
        guard let gap = comparisonTicks(start.timeIntervalSince(end)) else {
            return false
        }
        return gap >= 0 && gap <= 500_000
    }

    static func mediaAdjacent(end: Double, start: Double, tolerance: Double)
        -> Bool
    {
        guard let gap = comparisonTicks(start - end),
            let limit = comparisonTicks(tolerance)
        else { return false }
        return abs(gap) <= limit
    }

    private static func comparisonTicks(_ seconds: Double) -> Int64? {
        // This loose bound is solely to make conversion total and recoverable;
        // values this far apart can never be adjacent under either policy.
        guard seconds.isFinite, abs(seconds) <= 86_400 else { return nil }
        return Int64((seconds * 1_000_000).rounded(.toNearestOrEven))
    }

    static func sameReportingDay(_ lhs: Date, _ rhs: Date) -> Bool {
        StatisticsQuery.reportingCalendar.isDate(lhs, inSameDayAs: rhs)
    }
}
