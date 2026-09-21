import CryptoKit
import Foundation
import SwiftData

public struct StatisticsPlaybackSample: Equatable, Sendable {
    public let accountID: AccountID
    public let itemID: LibraryItemID
    public let sessionID: PlaybackSessionID
    public let observedAt: Date
    public let monotonicTime: TimeInterval
    public let wholeBookPosition: Double
    public let playbackRate: Double
    public let playbackGeneration: UInt64
    public let isAudibleAndAdvancing: Bool
    public let chapter: PlaybackChapter?
    public let title: String
    public let author: String
    public let duration: Double

    public init(
        accountID: AccountID,
        itemID: LibraryItemID,
        sessionID: PlaybackSessionID,
        observedAt: Date,
        monotonicTime: TimeInterval,
        wholeBookPosition: Double,
        playbackRate: Double,
        playbackGeneration: UInt64,
        isAudibleAndAdvancing: Bool,
        chapter: PlaybackChapter?,
        title: String,
        author: String,
        duration: Double
    ) {
        self.accountID = accountID
        self.itemID = itemID
        self.sessionID = sessionID
        self.observedAt = observedAt
        self.monotonicTime = monotonicTime
        self.wholeBookPosition = wholeBookPosition
        self.playbackRate = playbackRate
        self.playbackGeneration = playbackGeneration
        self.isAudibleAndAdvancing = isAudibleAndAdvancing
        self.chapter = chapter
        self.title = title
        self.author = author
        self.duration = duration
    }
}

public struct ListeningSlice: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let accountID: AccountID
    public let itemID: LibraryItemID
    public let sessionID: PlaybackSessionID
    public let startedAt: Date
    public let endedAt: Date
    public let startPosition: Double
    public let endPosition: Double
    public let realSeconds: Double
    public let audiobookSeconds: Double
    public let playbackRate: Double
    public let chapterID: Int?
    public let chapterTitle: String?
    public let chapterStart: Double?
    public let chapterEnd: Double?
    public let title: String
    public let author: String
    public let duration: Double

    public init(
        id: UUID = UUID(),
        accountID: AccountID,
        itemID: LibraryItemID,
        sessionID: PlaybackSessionID,
        startedAt: Date,
        endedAt: Date,
        startPosition: Double,
        endPosition: Double,
        realSeconds: Double,
        audiobookSeconds: Double,
        playbackRate: Double,
        chapterID: Int?,
        chapterTitle: String?,
        chapterStart: Double?,
        chapterEnd: Double?,
        title: String,
        author: String,
        duration: Double
    ) {
        self.id = id
        self.accountID = accountID
        self.itemID = itemID
        self.sessionID = sessionID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.realSeconds = realSeconds
        self.audiobookSeconds = audiobookSeconds
        self.playbackRate = playbackRate
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.chapterStart = chapterStart
        self.chapterEnd = chapterEnd
        self.title = title
        self.author = author
        self.duration = duration
    }

    func reidentified(as accountID: AccountID) -> ListeningSlice {
        ListeningSlice(
            id: id,
            accountID: accountID,
            itemID: itemID,
            sessionID: sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            startPosition: startPosition,
            endPosition: endPosition,
            realSeconds: realSeconds,
            audiobookSeconds: audiobookSeconds,
            playbackRate: playbackRate,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            chapterStart: chapterStart,
            chapterEnd: chapterEnd,
            title: title,
            author: author,
            duration: duration
        )
    }

    func replacingSessionID(_ sessionID: PlaybackSessionID) -> ListeningSlice {
        ListeningSlice(
            id: id, accountID: accountID, itemID: itemID,
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt,
            startPosition: startPosition, endPosition: endPosition,
            realSeconds: realSeconds, audiobookSeconds: audiobookSeconds,
            playbackRate: playbackRate, chapterID: chapterID,
            chapterTitle: chapterTitle, chapterStart: chapterStart,
            chapterEnd: chapterEnd, title: title, author: author,
            duration: duration
        )
    }
}

public enum CompletionEvidence: String, Codable, Sendable {
    case naturalEnd
    case serverProgress
    case explicitMarkFinished
}

public struct CompletionMilestone:
    Codable, Equatable, Identifiable, Sendable
{
    public let id: UUID
    public let accountID: AccountID
    public let itemID: LibraryItemID
    public let completedAt: Date
    public let duration: Double
    public let title: String
    public let author: String
    public let evidence: CompletionEvidence

    public init(
        id: UUID = UUID(),
        accountID: AccountID,
        itemID: LibraryItemID,
        completedAt: Date,
        duration: Double,
        title: String,
        author: String,
        evidence: CompletionEvidence
    ) {
        self.id = id
        self.accountID = accountID
        self.itemID = itemID
        self.completedAt = completedAt
        self.duration = duration
        self.title = title
        self.author = author
        self.evidence = evidence
    }

    func reidentified(as accountID: AccountID) -> CompletionMilestone {
        CompletionMilestone(
            id: id,
            accountID: accountID,
            itemID: itemID,
            completedAt: completedAt,
            duration: duration,
            title: title,
            author: author,
            evidence: evidence
        )
    }
}

public struct RemoteListeningSession:
    Codable, Equatable, Identifiable, Sendable
{
    public let id: PlaybackSessionID
    public let accountID: AccountID
    public let itemID: LibraryItemID
    public let startedAt: Date
    public let updatedAt: Date
    public let realSeconds: Double
    public let currentTime: Double
    public let duration: Double
    public let title: String
    public let author: String

    public init(
        id: PlaybackSessionID,
        accountID: AccountID,
        itemID: LibraryItemID,
        startedAt: Date,
        updatedAt: Date,
        realSeconds: Double,
        currentTime: Double,
        duration: Double,
        title: String,
        author: String
    ) {
        self.id = id
        self.accountID = accountID
        self.itemID = itemID
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.realSeconds = realSeconds
        self.currentTime = currentTime
        self.duration = duration
        self.title = title
        self.author = author
    }

    func reidentified(as accountID: AccountID) -> RemoteListeningSession {
        RemoteListeningSession(
            id: id,
            accountID: accountID,
            itemID: itemID,
            startedAt: startedAt,
            updatedAt: updatedAt,
            realSeconds: realSeconds,
            currentTime: currentTime,
            duration: duration,
            title: title,
            author: author
        )
    }

    func replacingSessionID(_ sessionID: PlaybackSessionID)
        -> RemoteListeningSession
    {
        RemoteListeningSession(
            id: sessionID, accountID: accountID, itemID: itemID,
            startedAt: startedAt, updatedAt: updatedAt,
            realSeconds: realSeconds, currentTime: currentTime,
            duration: duration, title: title, author: author
        )
    }
}

public enum StatisticsCoverage: String, Codable, Sendable {
    case allDevices
    case thisApp
    case approximate
    case stale
}

public struct StatisticsTimeBounds: Codable, Equatable, Sendable {
    public let lower: Double
    public let upper: Double

    public var shouldShowUncertainty: Bool {
        upper - lower >= 15 * 60
    }

    public init(lower: Double, upper: Double) {
        self.lower = lower
        self.upper = upper
    }
}

public struct StatisticsSummary: Codable, Equatable, Sendable {
    public let realSeconds: Double
    public let localRealSeconds: Double
    public let audiobookSeconds: Double
    public let finishedRuntime: Double
    public let booksStarted: Int
    public let booksCompleted: Int
    public let chaptersStarted: Int
    public let chaptersCompleted: Int
    public let sessions: Int
    public let effectiveAverageSpeed: Double?
    public let realTimeCoverage: StatisticsCoverage
    public let allDeviceBounds: StatisticsTimeBounds

    public init(
        realSeconds: Double,
        localRealSeconds: Double,
        audiobookSeconds: Double,
        finishedRuntime: Double,
        booksStarted: Int,
        booksCompleted: Int,
        chaptersStarted: Int,
        chaptersCompleted: Int,
        sessions: Int,
        effectiveAverageSpeed: Double?,
        realTimeCoverage: StatisticsCoverage,
        allDeviceBounds: StatisticsTimeBounds? = nil
    ) {
        self.realSeconds = realSeconds
        self.localRealSeconds = localRealSeconds
        self.audiobookSeconds = audiobookSeconds
        self.finishedRuntime = finishedRuntime
        self.booksStarted = booksStarted
        self.booksCompleted = booksCompleted
        self.chaptersStarted = chaptersStarted
        self.chaptersCompleted = chaptersCompleted
        self.sessions = sessions
        self.effectiveAverageSpeed = effectiveAverageSpeed
        self.realTimeCoverage = realTimeCoverage
        self.allDeviceBounds =
            allDeviceBounds
            ?? StatisticsTimeBounds(lower: realSeconds, upper: realSeconds)
    }

    public static let empty = StatisticsSummary(
        realSeconds: 0,
        localRealSeconds: 0,
        audiobookSeconds: 0,
        finishedRuntime: 0,
        booksStarted: 0,
        booksCompleted: 0,
        chaptersStarted: 0,
        chaptersCompleted: 0,
        sessions: 0,
        effectiveAverageSpeed: nil,
        realTimeCoverage: .thisApp
    )

    public func withCoverage(_ coverage: StatisticsCoverage)
        -> StatisticsSummary
    {
        StatisticsSummary(
            realSeconds: realSeconds,
            localRealSeconds: localRealSeconds,
            audiobookSeconds: audiobookSeconds,
            finishedRuntime: finishedRuntime,
            booksStarted: booksStarted,
            booksCompleted: booksCompleted,
            chaptersStarted: chaptersStarted,
            chaptersCompleted: chaptersCompleted,
            sessions: sessions,
            effectiveAverageSpeed: effectiveAverageSpeed,
            realTimeCoverage: coverage,
            allDeviceBounds: allDeviceBounds
        )
    }
}

public struct StatisticsQuery: Codable, Hashable, Sendable {
    /// Reporting uses UTC Gregorian days, independent of device settings.
    public static let reportingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    public let accountID: AccountID?
    public let start: Date?
    public let end: Date?

    public init(
        accountID: AccountID? = nil,
        start: Date? = nil,
        end: Date? = nil
    ) {
        self.accountID = accountID
        self.start = start
        self.end = end
    }

    public func contains(accountID: AccountID, date: Date) -> Bool {
        if let requestedAccountID = self.accountID,
            requestedAccountID != accountID
        {
            return false
        }
        if let start, date < start {
            return false
        }
        if let end, date >= end {
            return false
        }
        return true
    }
}

public struct StatisticsDay: Codable, Identifiable, Equatable, Sendable {
    public let date: Date
    public let realSeconds: Double
    public let upperSeconds: Double
    public var id: Date { date }
}

public struct StatisticsBook: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let author: String
    public let realSeconds: Double
    public let audiobookSeconds: Double
    public let bounds: StatisticsTimeBounds
    public let coverage: StatisticsCoverage
    public let chaptersStarted: Int
    public let chaptersCompleted: Int
    public let completedAt: Date?
    public let finishedRuntime: Double
}

public struct StatisticsRecentSession: Codable, Identifiable, Equatable,
    Sendable
{
    public let id: String
    public let title: String
    public let startedAt: Date
    public let realSeconds: Double
    public let coverage: StatisticsCoverage
    public let bounds: StatisticsTimeBounds
    public let audiobookSeconds: Double?
}

public struct StatisticsExploration: Codable, Equatable, Sendable {
    public let days: [StatisticsDay]
    public let books: [StatisticsBook]
    public let recentSessions: [StatisticsRecentSession]

    public static let empty = StatisticsExploration(
        days: [], books: [], recentSessions: []
    )
}

public enum StatisticsRepositoryError: Error, Equatable, Sendable {
    case invalidSample
    case invalidSlice
    case invalidCompletion
    case persistenceFailed
    case invalidArchive
    case invalidAccountMapping
    case partialSessionResetRequiresFullSession
}

@Model
public final class ListeningSliceRecord {
    #Index<ListeningSliceRecord>([\.privateCloudSynchronized])

    @Attribute(.unique)
    var eventID: UUID
    var accountID: String
    var itemID: String
    var sessionID: String
    var startedAt: Date
    var endedAt: Date
    var startPosition: Double
    var endPosition: Double
    var realSeconds: Double
    var audiobookSeconds: Double
    var playbackRate: Double
    var chapterID: Int?
    var chapterTitle: String?
    var chapterStart: Double?
    var chapterEnd: Double?
    var title: String
    var author: String
    var duration: Double
    var privateCloudSynchronized: Bool?

    init(_ slice: ListeningSlice) {
        eventID = slice.id
        accountID = slice.accountID.rawValue
        itemID = slice.itemID.rawValue
        sessionID = slice.sessionID.rawValue
        startedAt = slice.startedAt
        endedAt = slice.endedAt
        startPosition = slice.startPosition
        endPosition = slice.endPosition
        realSeconds = slice.realSeconds
        audiobookSeconds = slice.audiobookSeconds
        playbackRate = slice.playbackRate
        chapterID = slice.chapterID
        chapterTitle = slice.chapterTitle
        chapterStart = slice.chapterStart
        chapterEnd = slice.chapterEnd
        title = slice.title
        author = slice.author
        duration = slice.duration
        privateCloudSynchronized = false
    }

    var domainValue: ListeningSlice {
        ListeningSlice(
            id: eventID,
            accountID: AccountID(rawValue: accountID),
            itemID: LibraryItemID(rawValue: itemID),
            sessionID: PlaybackSessionID(rawValue: sessionID),
            startedAt: startedAt,
            endedAt: endedAt,
            startPosition: startPosition,
            endPosition: endPosition,
            realSeconds: realSeconds,
            audiobookSeconds: audiobookSeconds,
            playbackRate: playbackRate,
            chapterID: chapterID,
            chapterTitle: chapterTitle,
            chapterStart: chapterStart,
            chapterEnd: chapterEnd,
            title: title,
            author: author,
            duration: duration
        )
    }
}

@Model
public final class CompletionMilestoneRecord {
    #Index<CompletionMilestoneRecord>([\.privateCloudSynchronized])

    @Attribute(.unique)
    var eventID: UUID
    var accountID: String
    var itemID: String
    var completedAt: Date
    var duration: Double
    var title: String
    var author: String
    var evidence: String
    var privateCloudSynchronized: Bool?

    init(_ milestone: CompletionMilestone) {
        eventID = milestone.id
        accountID = milestone.accountID.rawValue
        itemID = milestone.itemID.rawValue
        completedAt = milestone.completedAt
        duration = milestone.duration
        title = milestone.title
        author = milestone.author
        evidence = milestone.evidence.rawValue
        privateCloudSynchronized = false
    }

    var domainValue: CompletionMilestone? {
        guard let evidence = CompletionEvidence(rawValue: evidence) else {
            return nil
        }
        return CompletionMilestone(
            id: eventID,
            accountID: AccountID(rawValue: accountID),
            itemID: LibraryItemID(rawValue: itemID),
            completedAt: completedAt,
            duration: duration,
            title: title,
            author: author,
            evidence: evidence
        )
    }
}

@Model
public final class RemoteListeningSessionRecord {
    #Index<RemoteListeningSessionRecord>([\.privateCloudSynchronized])

    @Attribute(.unique)
    var compositeID: String
    var sessionID: String
    var accountID: String
    var itemID: String
    var startedAt: Date
    var updatedAt: Date
    var realSeconds: Double
    var currentTime: Double
    var duration: Double
    var title: String
    var author: String
    var privateCloudSynchronized: Bool?

    init(_ session: RemoteListeningSession) {
        compositeID = Self.compositeID(
            accountID: session.accountID,
            sessionID: session.id
        )
        sessionID = session.id.rawValue
        accountID = session.accountID.rawValue
        itemID = session.itemID.rawValue
        startedAt = session.startedAt
        updatedAt = session.updatedAt
        realSeconds = session.realSeconds
        currentTime = session.currentTime
        duration = session.duration
        title = session.title
        author = session.author
        privateCloudSynchronized = false
    }

    static func compositeID(
        accountID: AccountID,
        sessionID: PlaybackSessionID
    ) -> String {
        "\(accountID.rawValue)\u{1f}\(sessionID.rawValue)"
    }

    var domainValue: RemoteListeningSession {
        RemoteListeningSession(
            id: PlaybackSessionID(rawValue: sessionID),
            accountID: AccountID(rawValue: accountID),
            itemID: LibraryItemID(rawValue: itemID),
            startedAt: startedAt,
            updatedAt: updatedAt,
            realSeconds: realSeconds,
            currentTime: currentTime,
            duration: duration,
            title: title,
            author: author
        )
    }
}

@Model
public final class PrivateCloudStatisticsDeletionRecord {
    @Attribute(.unique)
    var recordName: String
    var recordType: String
    var accountID: String

    init(recordName: String, recordType: String, accountID: String) {
        self.recordName = recordName
        self.recordType = recordType
        self.accountID = accountID
    }
}

@Model
public final class StatisticsSessionAccountingRecord {
    @Attribute(.unique)
    var compositeID: String
    var accountID: String
    var sessionID: String
    var confirmedRealSeconds: Double
    var uncertainRealSeconds: Double
    var updatedAt: Date

    init(accountID: AccountID, sessionID: PlaybackSessionID) {
        compositeID = Self.compositeID(
            accountID: accountID,
            sessionID: sessionID
        )
        self.accountID = accountID.rawValue
        self.sessionID = sessionID.rawValue
        confirmedRealSeconds = 0
        uncertainRealSeconds = 0
        updatedAt = Date()
    }

    static func compositeID(
        accountID: AccountID,
        sessionID: PlaybackSessionID
    ) -> String {
        "\(accountID.rawValue)\u{1f}\(sessionID.rawValue)"
    }
}

@Model
public final class StatisticsHistoryImportRecord {
    @Attribute(.unique) var accountID: String
    var startedAt: Date?
    var lastCompletedAt: Date?
    var completedPages: Int
    var totalPages: Int

    init(accountID: AccountID) {
        self.accountID = accountID.rawValue
        startedAt = nil
        lastCompletedAt = nil
        completedPages = 0
        totalPages = 0
    }
}

public struct StatisticsHistoryProgress: Equatable, Sendable {
    public let startedAt: Date?
    public let lastCompletedAt: Date?
    public let completedPages: Int
    public let totalPages: Int

    public init(
        startedAt: Date?, lastCompletedAt: Date?,
        completedPages: Int, totalPages: Int
    ) {
        self.startedAt = startedAt
        self.lastCompletedAt = lastCompletedAt
        self.completedPages = completedPages
        self.totalPages = totalPages
    }
}

public struct StatisticsArchive: Codable, Sendable {
    public let version: Int
    public let exportedAt: Date
    public let slices: [ListeningSlice]
    public let completions: [CompletionMilestone]
    public let remoteSessions: [RemoteListeningSession]

    public init(
        version: Int = 1,
        exportedAt: Date = Date(),
        slices: [ListeningSlice],
        completions: [CompletionMilestone],
        remoteSessions: [RemoteListeningSession]
    ) {
        self.version = version
        self.exportedAt = exportedAt
        self.slices = slices
        self.completions = completions
        self.remoteSessions = remoteSessions
    }

    public func reidentified(as accountID: AccountID) -> StatisticsArchive {
        StatisticsArchive(
            version: version,
            exportedAt: exportedAt,
            slices: slices.map { $0.reidentified(as: accountID) },
            completions: completions.map { $0.reidentified(as: accountID) },
            remoteSessions: remoteSessions.map {
                $0.reidentified(as: accountID)
            }
        )
    }

    public func portableRedacted() -> StatisticsArchive {
        StatisticsArchive(
            version: version, exportedAt: exportedAt,
            slices: slices.map {
                $0.replacingSessionID(
                    Self.portableSessionID(
                        sessionID: $0.sessionID
                    ))
            },
            completions: completions,
            remoteSessions: remoteSessions.map {
                $0.replacingSessionID(
                    Self.portableSessionID(
                        sessionID: $0.id
                    ))
            }
        )
    }

    static func portableSessionID(sessionID: PlaybackSessionID)
        -> PlaybackSessionID
    {
        if sessionID.rawValue.hasPrefix("portable:") {
            return sessionID
        }
        let input =
            "bleat-statistics-session-v1\u{0}"
            + sessionID.rawValue
        let digest = SHA256.hash(data: Data(input.utf8))
        return PlaybackSessionID(
            rawValue: "portable:"
                + digest.map { String(format: "%02x", $0) }.joined())
    }
}

struct PrivateCloudStatisticsDeletion: Equatable, Sendable {
    let recordName: String
    let recordType: String
    let accountID: AccountID
}

public struct ListeningAccumulator: Sendable {
    private var previous: StatisticsPlaybackSample?
    private var pending: ListeningSlice?

    public init() {}

    public var uncommittedSlice: ListeningSlice? { pending }

    public mutating func ingest(
        _ sample: StatisticsPlaybackSample
    ) throws(StatisticsRepositoryError) -> [ListeningSlice] {
        guard Self.isValid(sample) else {
            throw .invalidSample
        }
        defer {
            previous = sample
        }
        guard let previous else {
            return []
        }
        guard previous.accountID == sample.accountID,
            previous.itemID == sample.itemID,
            previous.sessionID == sample.sessionID,
            previous.playbackGeneration == sample.playbackGeneration,
            previous.isAudibleAndAdvancing,
            sample.isAudibleAndAdvancing
        else {
            return flush()
        }

        let realDelta = sample.monotonicTime - previous.monotonicTime
        let positionDelta =
            sample.wholeBookPosition - previous.wholeBookPosition
        guard realDelta > 0, realDelta <= 10, positionDelta > 0.01 else {
            return flush()
        }
        let cappedAudiobookDelta = min(
            positionDelta,
            realDelta * previous.playbackRate + 0.5
        )
        guard cappedAudiobookDelta > 0 else {
            return flush()
        }

        let interval = ListeningSlice(
            accountID: sample.accountID,
            itemID: sample.itemID,
            sessionID: sample.sessionID,
            startedAt: previous.observedAt,
            endedAt: sample.observedAt,
            startPosition: previous.wholeBookPosition,
            endPosition: previous.wholeBookPosition + cappedAudiobookDelta,
            realSeconds: realDelta,
            audiobookSeconds: cappedAudiobookDelta,
            playbackRate: previous.playbackRate,
            chapterID: previous.chapter?.id,
            chapterTitle: previous.chapter?.title,
            chapterStart: previous.chapter?.start,
            chapterEnd: previous.chapter?.end,
            title: previous.title,
            author: previous.author,
            duration: previous.duration
        )

        if let pending, Self.canMerge(pending, interval) {
            self.pending = ListeningSlice(
                id: pending.id,
                accountID: pending.accountID,
                itemID: pending.itemID,
                sessionID: pending.sessionID,
                startedAt: pending.startedAt,
                endedAt: interval.endedAt,
                startPosition: pending.startPosition,
                endPosition: interval.endPosition,
                realSeconds: pending.realSeconds + interval.realSeconds,
                audiobookSeconds:
                    pending.audiobookSeconds + interval.audiobookSeconds,
                playbackRate: pending.playbackRate,
                chapterID: pending.chapterID,
                chapterTitle: pending.chapterTitle,
                chapterStart: pending.chapterStart,
                chapterEnd: pending.chapterEnd,
                title: pending.title,
                author: pending.author,
                duration: pending.duration
            )
        } else {
            var output = flush()
            pending = interval
            if interval.realSeconds >= 5 {
                output.append(contentsOf: flush())
            }
            return output
        }

        if self.pending?.realSeconds ?? 0 >= 5 {
            return flush()
        }
        return []
    }

    public mutating func finish() -> [ListeningSlice] {
        previous = nil
        return flush()
    }

    private mutating func flush() -> [ListeningSlice] {
        guard let pending else {
            return []
        }
        self.pending = nil
        return [pending]
    }

    private static func canMerge(
        _ lhs: ListeningSlice,
        _ rhs: ListeningSlice
    ) -> Bool {
        lhs.accountID == rhs.accountID
            && lhs.itemID == rhs.itemID
            && lhs.sessionID == rhs.sessionID
            && lhs.playbackRate == rhs.playbackRate
            && lhs.chapterID == rhs.chapterID
            && lhs.chapterTitle == rhs.chapterTitle
            && StatisticsQuery.reportingCalendar.isDate(
                lhs.startedAt,
                inSameDayAs: rhs.startedAt
            )
            && abs(lhs.endPosition - rhs.startPosition) <= 0.5
    }

    private static func isValid(
        _ sample: StatisticsPlaybackSample
    ) -> Bool {
        !sample.accountID.rawValue.isEmpty
            && !sample.itemID.rawValue.isEmpty
            && !sample.sessionID.rawValue.isEmpty
            && sample.monotonicTime.isFinite
            && sample.wholeBookPosition.isFinite
            && sample.wholeBookPosition >= 0
            && sample.playbackRate.isFinite
            && sample.playbackRate > 0
            && sample.duration.isFinite
            && sample.duration > 0
            && sample.title.rangeOfCharacter(from: .controlCharacters) == nil
            && sample.author.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

/// SwiftData exception approved for issue #26: ModelContext has synchronous
/// fetch/save APIs. Only this actor performs statistics persistence/aggregation;
/// callers await it without blocking MainActor. Remove this boundary when
/// SwiftData provides native asynchronous fetch/save operations.
public actor StatisticsRepository {
    private let modelContainer: ModelContainer
    private var accumulators:
        [StatisticsAggregation.SessionKey: ListeningAccumulator] = [:]

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    public func discardAfterPersistentReset() {
        accumulators.removeAll()
    }

    public func uncommittedSlice(accountID: AccountID?) -> ListeningSlice? {
        accumulators.values.compactMap(\.uncommittedSlice).first {
            accountID == nil || $0.accountID == accountID
        }
    }

    public func record(
        _ sample: StatisticsPlaybackSample
    ) throws(StatisticsRepositoryError) {
        let identity = StatisticsAggregation.SessionKey(
            account: sample.accountID, session: sample.sessionID)
        var accumulator = accumulators[identity] ?? ListeningAccumulator()
        let slices = try accumulator.ingest(sample)
        if !slices.isEmpty { try save(slices) }
        accumulators[identity] = accumulator
    }

    public func finish(
        sessionID: PlaybackSessionID
    ) throws(StatisticsRepositoryError) {
        let matching = accumulators.filter { $0.key.session == sessionID }
        let slices = matching.values.flatMap { value in
            var accumulator = value
            return accumulator.finish()
        }
        if !slices.isEmpty { try save(slices) }
        for identity in matching.keys { accumulators[identity] = nil }
    }

    public func recordCompletion(
        _ milestone: CompletionMilestone
    ) throws(StatisticsRepositoryError) {
        guard !milestone.accountID.rawValue.isEmpty,
            !milestone.itemID.rawValue.isEmpty,
            milestone.duration.isFinite,
            milestone.duration > 0
        else {
            throw .invalidCompletion
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let account = milestone.accountID.rawValue
        let item = milestone.itemID.rawValue
        let descriptor = FetchDescriptor<CompletionMilestoneRecord>(
            predicate: #Predicate {
                $0.accountID == account && $0.itemID == item
            }
        )
        do {
            guard try context.fetch(descriptor).isEmpty else {
                return
            }
            context.insert(CompletionMilestoneRecord(milestone))
            try saveMutation(context) { $0.completions.append(milestone) }
        } catch {
            throw .persistenceFailed
        }
    }

    public func upsertRemoteSessions(
        _ sessions: [RemoteListeningSession]
    ) throws(StatisticsRepositoryError) {
        guard !sessions.isEmpty else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let keys = sessions.flatMap { session in
                let raw = RemoteListeningSessionRecord.compositeID(
                    accountID: session.accountID, sessionID: session.id
                )
                let portable = RemoteListeningSessionRecord.compositeID(
                    accountID: session.accountID,
                    sessionID: StatisticsArchive.portableSessionID(
                        sessionID: session.id
                    )
                )
                return [raw, portable]
            }
            let existing = try context.fetch(
                FetchDescriptor<RemoteListeningSessionRecord>(
                    predicate: #Predicate { keys.contains($0.compositeID) }
                )
            )
            var byID = Dictionary(
                uniqueKeysWithValues: existing.map {
                    ($0.compositeID, $0)
                }
            )
            var updated: [RemoteListeningSession] = []
            for session in sessions {
                guard session.realSeconds.isFinite,
                    session.realSeconds >= 0,
                    session.duration.isFinite,
                    session.duration >= 0
                else {
                    throw StatisticsRepositoryError.invalidSlice
                }
                let compositeID = RemoteListeningSessionRecord.compositeID(
                    accountID: session.accountID,
                    sessionID: session.id
                )
                let portableID = RemoteListeningSessionRecord.compositeID(
                    accountID: session.accountID,
                    sessionID: StatisticsArchive.portableSessionID(
                        sessionID: session.id
                    )
                )
                if let stored = byID[compositeID] ?? byID[portableID] {
                    guard session.updatedAt > stored.updatedAt else {
                        continue
                    }
                    stored.itemID = session.itemID.rawValue
                    stored.startedAt = session.startedAt
                    stored.updatedAt = session.updatedAt
                    // A server-side deletion or correction must not silently
                    // reduce an already observed lifetime total.
                    stored.realSeconds = max(
                        stored.realSeconds, session.realSeconds)
                    stored.currentTime = session.currentTime
                    stored.duration = session.duration
                    stored.title = session.title
                    stored.author = session.author
                    stored.privateCloudSynchronized = false
                    updated.append(stored.domainValue)
                } else {
                    let record = RemoteListeningSessionRecord(session)
                    context.insert(record)
                    byID[compositeID] = record
                    updated.append(record.domainValue)
                }
            }
            try saveMutation(context) { state in
                for value in updated { state.upsert(value) }
            }
        } catch let error as StatisticsRepositoryError {
            throw error
        } catch {
            throw .persistenceFailed
        }
    }

    public func historyProgress(accountID: AccountID)
        throws(StatisticsRepositoryError) -> StatisticsHistoryProgress
    {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let rawID = accountID.rawValue
        do {
            let record = try context.fetch(
                FetchDescriptor<StatisticsHistoryImportRecord>(
                    predicate: #Predicate { $0.accountID == rawID }
                )
            ).first
            return StatisticsHistoryProgress(
                startedAt: record?.startedAt,
                lastCompletedAt: record?.lastCompletedAt,
                completedPages: record?.completedPages ?? 0,
                totalPages: record?.totalPages ?? 0
            )
        } catch {
            throw .persistenceFailed
        }
    }

    public func updateHistoryProgress(
        accountID: AccountID,
        completedPages: Int,
        totalPages: Int,
        completed: Bool,
        at date: Date = Date()
    ) throws(StatisticsRepositoryError) {
        guard completedPages >= 0, totalPages >= 0,
            completedPages <= totalPages
        else {
            throw .invalidArchive
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let rawID = accountID.rawValue
        do {
            let record =
                try context.fetch(
                    FetchDescriptor<StatisticsHistoryImportRecord>(
                        predicate: #Predicate { $0.accountID == rawID }
                    )
                ).first ?? StatisticsHistoryImportRecord(accountID: accountID)
            if record.modelContext == nil {
                context.insert(record)
            }
            if completedPages == 0 {
                record.startedAt = date
            }
            record.completedPages = completedPages
            record.totalPages = totalPages
            if completed {
                record.lastCompletedAt = date
            }
            try context.save()
        } catch {
            throw .persistenceFailed
        }
    }

    public func summary(
        query: StatisticsQuery = StatisticsQuery()
    ) throws(StatisticsRepositoryError) -> StatisticsSummary {
        try snapshot(query: query).summary
    }

    public func exploration(query: StatisticsQuery = StatisticsQuery())
        throws(StatisticsRepositoryError) -> StatisticsExploration
    {
        try snapshot(query: query).exploration
    }

    public func presentation(query: StatisticsQuery)
        throws(StatisticsRepositoryError) -> StatisticsPresentation
    {
        StatisticsPresentation(
            snapshot: try snapshot(query: query),
            liveSlice: uncommittedSlice(accountID: query.accountID))
    }

    /// Polling never enters the ledger fetch/aggregation path. A missing cache
    /// remains absent until an explicit load or refresh prepares it.
    public func livePresentation(query: StatisticsQuery)
        throws(StatisticsRepositoryError) -> StatisticsPresentation?
    {
        guard let value = try cachedSnapshot(query: query) else { return nil }
        return StatisticsPresentation(
            snapshot: value,
            liveSlice: uncommittedSlice(accountID: query.accountID))
    }

    private func cachedSnapshot(query: StatisticsQuery)
        throws(StatisticsRepositoryError) -> StatisticsSnapshot?
    {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let scope = query.accountID?.rawValue
        let start = query.start
        let end = query.end
        do {
            guard
                let record = try context.fetch(
                    FetchDescriptor<StatisticsSnapshotRecord>(
                        predicate: #Predicate {
                            $0.accountID == scope && $0.start == start
                                && $0.end == end
                        })
                ).first,
                let value = try? JSONDecoder().decode(
                    StatisticsSnapshot.self, from: record.payload)
            else { return nil }
            return value
        } catch { throw .persistenceFailed }
    }

    public func snapshot(query: StatisticsQuery = StatisticsQuery())
        throws(StatisticsRepositoryError) -> StatisticsSnapshot
    {
        if let value = try cachedSnapshot(query: query) { return value }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let start = query.start
        let end = query.end
        let scope = query.accountID?.rawValue
        do {
            let slices = try context.fetch(
                FetchDescriptor<ListeningSliceRecord>()
            )
            .map(\.domainValue)
            let completions = try context.fetch(
                FetchDescriptor<CompletionMilestoneRecord>()
            )
            .compactMap(\.domainValue)
            let remote = try context.fetch(
                FetchDescriptor<RemoteListeningSessionRecord>()
            )
            .map(\.domainValue)
            let accounting = try context.fetch(
                FetchDescriptor<StatisticsSessionAccountingRecord>()
            )
            .map {
                StatisticsAccounting(
                    accountID: AccountID(rawValue: $0.accountID),
                    sessionID: PlaybackSessionID(rawValue: $0.sessionID),
                    confirmed: $0.confirmedRealSeconds,
                    uncertain: $0.uncertainRealSeconds, updatedAt: $0.updatedAt)
            }
            var state = StatisticsAggregation.State(query: query)
            state.append(slices)
            state.completions = completions
            for value in remote { state.upsert(value) }
            for value in accounting { state.setAccounting(value) }
            let value = state.snapshot()
            do {
                for old in try context.fetch(
                    FetchDescriptor<StatisticsSnapshotRecord>(
                        predicate: #Predicate {
                            $0.accountID == scope
                        }))
                where (old.start == start && old.end == end)
                    || ((start != nil || end != nil)
                        && (old.start != nil || old.end != nil))
                { context.delete(old) }
                // Retain Lifetime and only the latest selected range per account.
                let record = StatisticsSnapshotRecord(
                    accountID: scope, start: start, end: end,
                    payload: try JSONEncoder().encode(value))
                record.incrementalPayload = try JSONEncoder().encode(state)
                context.insert(record)
                try context.save()
            }
            return value
        } catch {
            throw .persistenceFailed
        }
    }

    public func archive(
        query: StatisticsQuery = StatisticsQuery()
    ) throws(StatisticsRepositoryError) -> StatisticsArchive {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            return StatisticsArchive(
                slices: try context.fetch(
                    FetchDescriptor<ListeningSliceRecord>()
                ).map(\.domainValue).filter {
                    query.contains(
                        accountID: $0.accountID,
                        date: $0.startedAt
                    )
                },
                completions: try context.fetch(
                    FetchDescriptor<CompletionMilestoneRecord>()
                ).compactMap(\.domainValue).filter {
                    query.contains(
                        accountID: $0.accountID,
                        date: $0.completedAt
                    )
                },
                remoteSessions: try context.fetch(
                    FetchDescriptor<RemoteListeningSessionRecord>()
                ).map(\.domainValue).filter {
                    query.contains(
                        accountID: $0.accountID,
                        date: $0.startedAt
                    )
                }
            )
        } catch {
            throw .persistenceFailed
        }
    }

    func privateCloudArchive() throws(StatisticsRepositoryError)
        -> StatisticsArchive
    {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            return StatisticsArchive(
                slices: try context.fetch(
                    FetchDescriptor<ListeningSliceRecord>(
                        predicate: #Predicate {
                            $0.privateCloudSynchronized == false
                                || $0.privateCloudSynchronized == nil
                        }
                    )
                ).map(\.domainValue),
                completions: try context.fetch(
                    FetchDescriptor<CompletionMilestoneRecord>(
                        predicate: #Predicate {
                            $0.privateCloudSynchronized == false
                                || $0.privateCloudSynchronized == nil
                        }
                    )
                ).compactMap(\.domainValue),
                remoteSessions: try context.fetch(
                    FetchDescriptor<RemoteListeningSessionRecord>(
                        predicate: #Predicate {
                            $0.privateCloudSynchronized == false
                                || $0.privateCloudSynchronized == nil
                        }
                    )
                ).map(\.domainValue)
            )
        } catch {
            throw .persistenceFailed
        }
    }

    func markPrivateCloudArchiveSynchronized(
        _ archive: StatisticsArchive
    ) throws(StatisticsRepositoryError) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            for slice in archive.slices {
                let id = slice.id
                let descriptor = FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate { $0.eventID == id }
                )
                if let record = try context.fetch(descriptor).first,
                    record.domainValue == slice
                {
                    record.privateCloudSynchronized = true
                }
            }
            for completion in archive.completions {
                let id = completion.id
                let descriptor = FetchDescriptor<CompletionMilestoneRecord>(
                    predicate: #Predicate { $0.eventID == id }
                )
                if let record = try context.fetch(descriptor).first,
                    record.domainValue == completion
                {
                    record.privateCloudSynchronized = true
                }
            }
            for session in archive.remoteSessions {
                let compositeID = RemoteListeningSessionRecord.compositeID(
                    accountID: session.accountID,
                    sessionID: session.id
                )
                let descriptor =
                    FetchDescriptor<RemoteListeningSessionRecord>(
                        predicate: #Predicate {
                            $0.compositeID == compositeID
                        }
                    )
                if let record = try context.fetch(descriptor).first,
                    record.domainValue == session
                {
                    record.privateCloudSynchronized = true
                }
            }
            try context.save()
        } catch {
            throw .persistenceFailed
        }
    }

    func privateCloudDeletions() throws(StatisticsRepositoryError)
        -> [PrivateCloudStatisticsDeletion]
    {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            return try context.fetch(
                FetchDescriptor<PrivateCloudStatisticsDeletionRecord>()
            ).map {
                PrivateCloudStatisticsDeletion(
                    recordName: $0.recordName,
                    recordType: $0.recordType,
                    accountID: AccountID(rawValue: $0.accountID)
                )
            }
        } catch {
            throw .persistenceFailed
        }
    }

    func privateCloudRecordNames(
        accountID: AccountID
    ) throws(StatisticsRepositoryError) -> Set<String> {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let account = accountID.rawValue
        do {
            let sliceNames = try context.fetch(
                FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate { $0.accountID == account }
                )
            ).map {
                "slice.\($0.eventID.uuidString.lowercased())"
            }
            let completionNames = try context.fetch(
                FetchDescriptor<CompletionMilestoneRecord>(
                    predicate: #Predicate { $0.accountID == account }
                )
            ).map {
                "completion.\($0.eventID.uuidString.lowercased())"
            }
            let remoteSessionNames = try context.fetch(
                FetchDescriptor<RemoteListeningSessionRecord>(
                    predicate: #Predicate { $0.accountID == account }
                )
            ).map {
                "remote.\($0.accountID).\($0.sessionID)"
            }
            let deletionNames = try context.fetch(
                FetchDescriptor<PrivateCloudStatisticsDeletionRecord>(
                    predicate: #Predicate { $0.accountID == account }
                )
            ).map(\.recordName)
            return Set(
                sliceNames + completionNames + remoteSessionNames
                    + deletionNames
            )
        } catch {
            throw .persistenceFailed
        }
    }

    func resetPrivateCloudSynchronizationState()
        throws(StatisticsRepositoryError)
    {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            for record in try context.fetch(
                FetchDescriptor<ListeningSliceRecord>()
            ) {
                record.privateCloudSynchronized = false
            }
            for record in try context.fetch(
                FetchDescriptor<CompletionMilestoneRecord>()
            ) {
                record.privateCloudSynchronized = false
            }
            for record in try context.fetch(
                FetchDescriptor<RemoteListeningSessionRecord>()
            ) {
                record.privateCloudSynchronized = false
            }
            for deletion in try context.fetch(
                FetchDescriptor<PrivateCloudStatisticsDeletionRecord>()
            ) {
                context.delete(deletion)
            }
            try context.save()
        } catch {
            throw .persistenceFailed
        }
    }

    func clearPrivateCloudDeletions(
        recordNames: Set<String>
    ) throws(StatisticsRepositoryError) {
        guard !recordNames.isEmpty else {
            return
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            for record in try context.fetch(
                FetchDescriptor<PrivateCloudStatisticsDeletionRecord>()
            ) where recordNames.contains(record.recordName) {
                context.delete(record)
            }
            try context.save()
        } catch let error as StatisticsRepositoryError {
            throw error
        } catch {
            throw .persistenceFailed
        }
    }

    public func importArchive(
        _ archive: StatisticsArchive
    ) throws(StatisticsRepositoryError) {
        guard archive.version == 1,
            Set(archive.slices.map(\.id)).count == archive.slices.count,
            Set(archive.completions.map(\.id)).count
                == archive.completions.count,
            Set(
                archive.remoteSessions.map {
                    RemoteListeningSessionRecord.compositeID(
                        accountID: $0.accountID, sessionID: $0.id
                    )
                }
            ).count == archive.remoteSessions.count,
            archive.slices.allSatisfy(Self.isValid),
            archive.completions.allSatisfy({
                !$0.accountID.rawValue.isEmpty
                    && !$0.itemID.rawValue.isEmpty
                    && $0.duration.isFinite && $0.duration > 0
            }),
            archive.remoteSessions.allSatisfy({
                !$0.accountID.rawValue.isEmpty
                    && !$0.id.rawValue.isEmpty
                    && !$0.itemID.rawValue.isEmpty
                    && $0.realSeconds.isFinite && $0.realSeconds >= 0
                    && $0.currentTime.isFinite && $0.currentTime >= 0
                    && $0.duration.isFinite && $0.duration >= 0
            })
        else {
            throw .invalidArchive
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let existingSliceIDs = Set(
                try context.fetch(FetchDescriptor<ListeningSliceRecord>())
                    .map(\.eventID)
            )
            for slice in archive.slices
            where
                !existingSliceIDs.contains(slice.id)
            {
                context.insert(ListeningSliceRecord(slice))
            }
            let existingCompletionIDs = Set(
                try context.fetch(
                    FetchDescriptor<CompletionMilestoneRecord>()
                ).map(\.eventID)
            )
            for milestone in archive.completions
            where
                !existingCompletionIDs.contains(milestone.id)
            {
                context.insert(CompletionMilestoneRecord(milestone))
            }
            let existingRecords = try context.fetch(
                FetchDescriptor<RemoteListeningSessionRecord>()
            )
            var existingRemote: [String: RemoteListeningSessionRecord] = [:]
            var existingByPortableID: [String: RemoteListeningSessionRecord] =
                [:]
            for record in existingRecords {
                existingRemote[record.compositeID] = record
                let portable = StatisticsArchive.portableSessionID(
                    sessionID: PlaybackSessionID(rawValue: record.sessionID)
                )
                existingByPortableID[
                    record.accountID + "\u{1f}" + portable.rawValue
                ] = record
            }
            for session in archive.remoteSessions {
                let key = RemoteListeningSessionRecord.compositeID(
                    accountID: session.accountID, sessionID: session.id
                )
                let portableKey =
                    session.accountID.rawValue
                    + "\u{1f}" + session.id.rawValue
                if let stored = existingRemote[key]
                    ?? existingByPortableID[portableKey]
                {
                    if session.updatedAt > stored.updatedAt {
                        stored.itemID = session.itemID.rawValue
                        stored.startedAt = session.startedAt
                        stored.updatedAt = session.updatedAt
                        stored.realSeconds = max(
                            stored.realSeconds, session.realSeconds)
                        stored.currentTime = session.currentTime
                        stored.duration = session.duration
                        stored.title = session.title
                        stored.author = session.author
                        stored.privateCloudSynchronized = false
                    }
                } else {
                    context.insert(RemoteListeningSessionRecord(session))
                }
            }
            try saveMutation(context)
        } catch let error as StatisticsRepositoryError {
            throw error
        } catch {
            throw .persistenceFailed
        }
    }

    public func reset(
        query: StatisticsQuery
    ) throws(StatisticsRepositoryError) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let existingDeletionNames = Set(
                try context.fetch(
                    FetchDescriptor<PrivateCloudStatisticsDeletionRecord>()
                ).map(\.recordName)
            )
            var deletionNames = existingDeletionNames
            var affectedSessionKeys: Set<String> = []
            var remainingRealBySession: [String: Double] = [:]
            for record in try context.fetch(
                FetchDescriptor<ListeningSliceRecord>()
            ) {
                let sessionKey =
                    StatisticsSessionAccountingRecord
                    .compositeID(
                        accountID: AccountID(rawValue: record.accountID),
                        sessionID: PlaybackSessionID(rawValue: record.sessionID)
                    )
                guard
                    query.contains(
                        accountID: AccountID(rawValue: record.accountID),
                        date: record.startedAt
                    )
                else {
                    remainingRealBySession[sessionKey, default: 0] +=
                        record.realSeconds
                    continue
                }
                affectedSessionKeys.insert(sessionKey)
                let recordName =
                    "slice.\(record.eventID.uuidString.lowercased())"
                if deletionNames.insert(recordName).inserted {
                    context.insert(
                        PrivateCloudStatisticsDeletionRecord(
                            recordName: recordName,
                            recordType: "ListeningSlice",
                            accountID: record.accountID
                        )
                    )
                }
                context.delete(record)
            }
            for record in try context.fetch(
                FetchDescriptor<StatisticsSessionAccountingRecord>()
            )
            where affectedSessionKeys.contains(record.compositeID)
                && (remainingRealBySession[record.compositeID] ?? 0) > 0
                && (record.confirmedRealSeconds > 0
                    || record.uncertainRealSeconds > 0)
            {
                throw StatisticsRepositoryError
                    .partialSessionResetRequiresFullSession
            }
            for record in try context.fetch(
                FetchDescriptor<CompletionMilestoneRecord>()
            )
            where query.contains(
                accountID: AccountID(rawValue: record.accountID),
                date: record.completedAt
            ) {
                let recordName =
                    "completion.\(record.eventID.uuidString.lowercased())"
                if deletionNames.insert(recordName).inserted {
                    context.insert(
                        PrivateCloudStatisticsDeletionRecord(
                            recordName: recordName,
                            recordType: "CompletionMilestone",
                            accountID: record.accountID
                        )
                    )
                }
                context.delete(record)
            }
            for record in try context.fetch(
                FetchDescriptor<RemoteListeningSessionRecord>()
            )
            where query.contains(
                accountID: AccountID(rawValue: record.accountID),
                date: record.startedAt
            ) {
                let recordName =
                    "remote.\(record.accountID).\(record.sessionID)"
                if deletionNames.insert(recordName).inserted {
                    context.insert(
                        PrivateCloudStatisticsDeletionRecord(
                            recordName: recordName,
                            recordType: "RemoteListeningSession",
                            accountID: record.accountID
                        )
                    )
                }
                context.delete(record)
            }
            for record in try context.fetch(
                FetchDescriptor<StatisticsSessionAccountingRecord>()
            ) {
                let fullRange = query.start == nil && query.end == nil
                let selectedAccount =
                    query.accountID == nil
                    || query.accountID?.rawValue == record.accountID
                guard
                    (fullRange && selectedAccount)
                        || affectedSessionKeys.contains(record.compositeID)
                else { continue }
                context.delete(record)
            }
            for record in try context.fetch(
                FetchDescriptor<StatisticsHistoryImportRecord>()
            )
            where query.accountID == nil
                || query.accountID?.rawValue == record.accountID
            {
                record.lastCompletedAt = nil
                record.startedAt = nil
                record.completedPages = 0
                record.totalPages = 0
            }
            try saveMutation(context)
            let removed = accumulators.filter { identity, accumulator in
                guard
                    query.accountID == nil
                        || query.accountID == identity.account
                else { return false }
                if query.start == nil && query.end == nil { return true }
                guard let pending = accumulator.uncommittedSlice else {
                    return false
                }
                return query.contains(
                    accountID: pending.accountID, date: pending.startedAt)
            }.map(\.key)
            for identity in removed { accumulators[identity] = nil }
        } catch let error as StatisticsRepositoryError {
            throw error
        } catch {
            throw .persistenceFailed
        }
    }

    public func deleteSlice(
        id: UUID
    ) throws(StatisticsRepositoryError) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let descriptor = FetchDescriptor<ListeningSliceRecord>(
                predicate: #Predicate { $0.eventID == id }
            )
            if let record = try context.fetch(descriptor).first {
                context.delete(record)
                try saveMutation(context)
            }
        } catch {
            throw .persistenceFailed
        }
    }

    public func deleteCompletion(
        id: UUID
    ) throws(StatisticsRepositoryError) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let descriptor = FetchDescriptor<CompletionMilestoneRecord>(
                predicate: #Predicate { $0.eventID == id }
            )
            if let record = try context.fetch(descriptor).first {
                context.delete(record)
                try saveMutation(context)
            }
        } catch {
            throw .persistenceFailed
        }
    }

    public func deleteRemoteSession(
        accountID: AccountID,
        sessionID: PlaybackSessionID
    ) throws(StatisticsRepositoryError) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let compositeID = RemoteListeningSessionRecord.compositeID(
            accountID: accountID,
            sessionID: sessionID
        )
        do {
            let descriptor =
                FetchDescriptor<RemoteListeningSessionRecord>(
                    predicate: #Predicate {
                        $0.compositeID == compositeID
                    }
                )
            if let record = try context.fetch(descriptor).first {
                context.delete(record)
                try saveMutation(context)
            }
        } catch {
            throw .persistenceFailed
        }
    }

    private func save(
        _ slices: [ListeningSlice]
    ) throws(StatisticsRepositoryError) {
        guard slices.allSatisfy(Self.isValid) else {
            throw .invalidSlice
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            for slice in slices {
                context.insert(ListeningSliceRecord(slice))
            }
            try saveMutation(context) { $0.append(slices) }
        } catch {
            throw .persistenceFailed
        }
    }

    public func pendingRealSeconds(
        accountID: AccountID,
        sessionID: PlaybackSessionID
    ) throws(StatisticsRepositoryError) -> Double {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let account = accountID.rawValue
            let session = sessionID.rawValue
            let total = try context.fetch(
                FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate {
                        $0.accountID == account
                            && $0.sessionID == session
                    }
                )
            ).reduce(0) { $0 + $1.realSeconds }
            let compositeID =
                StatisticsSessionAccountingRecord.compositeID(
                    accountID: accountID,
                    sessionID: sessionID
                )
            let accounting = try context.fetch(
                FetchDescriptor<StatisticsSessionAccountingRecord>(
                    predicate: #Predicate {
                        $0.compositeID == compositeID
                    }
                )
            ).first
            return max(
                0,
                total
                    - (accounting?.confirmedRealSeconds ?? 0)
                    - (accounting?.uncertainRealSeconds ?? 0)
            )
        } catch {
            throw .persistenceFailed
        }
    }

    public func confirmSync(
        accountID: AccountID,
        sessionID: PlaybackSessionID,
        realSeconds: Double
    ) throws(StatisticsRepositoryError) {
        try updateAccounting(
            accountID: accountID,
            sessionID: sessionID,
            confirmedDelta: realSeconds,
            uncertainDelta: 0
        )
    }

    public func markSyncUncertain(
        accountID: AccountID,
        sessionID: PlaybackSessionID,
        realSeconds: Double
    ) throws(StatisticsRepositoryError) {
        try updateAccounting(
            accountID: accountID,
            sessionID: sessionID,
            confirmedDelta: 0,
            uncertainDelta: realSeconds
        )
    }

    private func updateAccounting(
        accountID: AccountID,
        sessionID: PlaybackSessionID,
        confirmedDelta: Double,
        uncertainDelta: Double
    ) throws(StatisticsRepositoryError) {
        guard confirmedDelta.isFinite,
            confirmedDelta >= 0,
            uncertainDelta.isFinite,
            uncertainDelta >= 0
        else {
            throw .invalidSlice
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let compositeID = StatisticsSessionAccountingRecord.compositeID(
            accountID: accountID,
            sessionID: sessionID
        )
        do {
            let descriptor =
                FetchDescriptor<StatisticsSessionAccountingRecord>(
                    predicate: #Predicate {
                        $0.compositeID == compositeID
                    }
                )
            let record =
                try context.fetch(descriptor).first
                ?? StatisticsSessionAccountingRecord(
                    accountID: accountID,
                    sessionID: sessionID
                )
            if record.modelContext == nil {
                context.insert(record)
            }
            record.confirmedRealSeconds += confirmedDelta
            record.uncertainRealSeconds += uncertainDelta
            record.updatedAt = Date()
            let value = StatisticsAccounting(
                accountID: accountID, sessionID: sessionID,
                confirmed: record.confirmedRealSeconds,
                uncertain: record.uncertainRealSeconds,
                updatedAt: record.updatedAt)
            try saveMutation(context) { $0.setAccounting(value) }
        } catch {
            throw .persistenceFailed
        }
    }

    private func saveMutation(
        _ context: ModelContext,
        update: ((inout StatisticsAggregation.State) -> Void)? = nil
    ) throws {
        guard context.hasChanges else { return }
        for cache in try context.fetch(
            FetchDescriptor<StatisticsSnapshotRecord>())
        {
            if let update, let payload = cache.incrementalPayload,
                var state = try? JSONDecoder().decode(
                    StatisticsAggregation.State.self, from: payload)
            {
                update(&state)
                let value = state.snapshot()
                cache.payload = try JSONEncoder().encode(value)
                cache.incrementalPayload = try JSONEncoder().encode(state)
            } else {
                context.delete(cache)
            }
        }
        try context.save()
    }

    private static func isValid(_ slice: ListeningSlice) -> Bool {
        !slice.accountID.rawValue.isEmpty
            && !slice.itemID.rawValue.isEmpty
            && !slice.sessionID.rawValue.isEmpty
            && slice.startedAt <= slice.endedAt
            && slice.startPosition.isFinite
            && slice.endPosition.isFinite
            && slice.endPosition >= slice.startPosition
            && slice.realSeconds.isFinite
            && slice.realSeconds > 0
            && slice.audiobookSeconds.isFinite
            && slice.audiobookSeconds > 0
            && slice.playbackRate.isFinite
            && slice.playbackRate > 0
            && slice.duration.isFinite
            && slice.duration > 0
    }
}
