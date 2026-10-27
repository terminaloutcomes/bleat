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

public enum ListeningRecordingFormat: String, Codable, Sendable {
    case continuousSegment = "continuous_segment_v2"
}

public enum ListeningRecordingState: String, Codable, Sendable {
    case active, finalized
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
    public let recordingFormat: ListeningRecordingFormat?
    public let recordingState: ListeningRecordingState?
    public let boundaryAfter: ListeningBoundary?
    public let lineage: ListeningSegmentLineage?
    public let acknowledgedResetIDs: [UUID]?

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
        duration: Double,
        recordingFormat: ListeningRecordingFormat? = nil,
        recordingState: ListeningRecordingState? = nil,
        boundaryAfter: ListeningBoundary? = nil,
        lineage: ListeningSegmentLineage? = nil,
        acknowledgedResetIDs: [UUID]? = nil
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
        self.recordingFormat = recordingFormat
        self.recordingState = recordingState
        self.boundaryAfter = boundaryAfter
        self.lineage = lineage
        self.acknowledgedResetIDs = acknowledgedResetIDs
    }

    func reidentified(as accountID: AccountID) -> ListeningSlice {
        ListeningSlice(
            id: lineage.map {
                ListeningSegmentCodec.identity(
                    accountID: accountID, lineage: $0)
            } ?? id,
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
            duration: duration, recordingFormat: recordingFormat,
            recordingState: recordingState, boundaryAfter: boundaryAfter,
            lineage: lineage, acknowledgedResetIDs: acknowledgedResetIDs
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
            duration: duration, recordingFormat: recordingFormat,
            recordingState: recordingState, boundaryAfter: boundaryAfter,
            lineage: lineage, acknowledgedResetIDs: acknowledgedResetIDs
        )
    }
    func splitAtReportingDay() -> (ListeningSlice, ListeningSlice)? {
        guard lineage == nil else { return nil }
        let boundary = StatisticsQuery.reportingCalendar.startOfDay(
            for: endedAt)
        guard startedAt < boundary, boundary < endedAt else { return nil }
        let fraction =
            boundary.timeIntervalSince(startedAt)
            / endedAt.timeIntervalSince(startedAt)
        func part(start: Date, end: Date, lower: Double, upper: Double)
            -> ListeningSlice
        {
            ListeningSlice(
                accountID: accountID, itemID: itemID, sessionID: sessionID,
                startedAt: start, endedAt: end,
                startPosition: startPosition + audiobookSeconds * lower,
                endPosition: startPosition + audiobookSeconds * upper,
                realSeconds: realSeconds * (upper - lower),
                audiobookSeconds: audiobookSeconds * (upper - lower),
                playbackRate: playbackRate,
                chapterID: chapterID, chapterTitle: chapterTitle,
                chapterStart: chapterStart,
                chapterEnd: chapterEnd, title: title, author: author,
                duration: duration,
                recordingFormat: recordingFormat,
                recordingState: recordingState, boundaryAfter: boundaryAfter,
                lineage: lineage, acknowledgedResetIDs: acknowledgedResetIDs
            )
        }
        return (
            part(start: startedAt, end: boundary, lower: 0, upper: fraction),
            part(start: boundary, end: endedAt, lower: fraction, upper: 1)
        )
    }

    var finalized: ListeningSlice {
        copying(state: .finalized)
    }

    func copying(
        state: ListeningRecordingState, boundary: ListeningBoundary? = nil
    ) -> ListeningSlice {
        ListeningSlice(
            id: id, accountID: accountID, itemID: itemID,
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt,
            startPosition: startPosition, endPosition: endPosition,
            realSeconds: realSeconds, audiobookSeconds: audiobookSeconds,
            playbackRate: playbackRate, chapterID: chapterID,
            chapterTitle: chapterTitle, chapterStart: chapterStart,
            chapterEnd: chapterEnd,
            title: title, author: author, duration: duration,
            recordingFormat: recordingFormat, recordingState: state,
            boundaryAfter: boundary ?? boundaryAfter, lineage: lineage,
            acknowledgedResetIDs: acknowledgedResetIDs)
    }

    /// Only newly observed quantities contribute to committed summaries. Keep
    /// the original start date so incremental range selection matches a rebuild;
    /// this transient contribution is never persisted or uploaded.
    func tail(after previous: ListeningSlice?) -> ListeningSlice? {
        guard let previous else { return self }
        guard realSeconds > previous.realSeconds else { return nil }
        return ListeningSlice(
            id: id, accountID: accountID, itemID: itemID,
            sessionID: sessionID, startedAt: startedAt, endedAt: endedAt,
            startPosition: previous.endPosition, endPosition: endPosition,
            realSeconds: realSeconds - previous.realSeconds,
            audiobookSeconds: audiobookSeconds - previous.audiobookSeconds,
            playbackRate: playbackRate, chapterID: chapterID,
            chapterTitle: chapterTitle,
            chapterStart: chapterStart, chapterEnd: chapterEnd, title: title,
            author: author,
            duration: duration, recordingFormat: recordingFormat,
            recordingState: recordingState, boundaryAfter: boundaryAfter,
            lineage: lineage, acknowledgedResetIDs: acknowledgedResetIDs)
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

public enum StatisticsRepositoryError: Error, Equatable, Sendable, Codable {
    case invalidSample
    case invalidSlice
    case invalidCompletion
    case persistenceFailed
    case invalidArchive
    case invalidAccountMapping
    case segmentFailure(ListeningSegmentFailure)
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
    var recordingFormat: ListeningRecordingFormat?
    var boundaryAfter: ListeningBoundary?
    var acknowledgedResetIDs: [UUID]?
    var segmentProtocolObserved: Bool?
    var isFinalized: Bool?
    var privateCloudSynchronized: Bool?
    var segmentPayload: Data?
    var segmentEnvelopeVersion: Int?
    var segmentReceiptDigest: Data?
    var segmentDeletionObserved: Bool?

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
        recordingFormat = slice.recordingFormat
        acknowledgedResetIDs = slice.acknowledgedResetIDs
        boundaryAfter = slice.boundaryAfter
        isFinalized = slice.recordingState != .active
        privateCloudSynchronized = false
        segmentPayload = nil
        segmentEnvelopeVersion = nil
        segmentReceiptDigest = nil
        segmentDeletionObserved = nil
    }

    convenience init(encodedSegment: Data) throws {
        let segment = try ListeningSegmentCodec.decode(encodedSegment)
        self.init(segment)
        segmentPayload = encodedSegment
        segmentEnvelopeVersion = segment.lineage?.version
    }

    func validatedValue() throws -> ListeningSlice {
        guard let segmentPayload else {
            guard segmentEnvelopeVersion == nil else {
                throw ListeningSegmentFailure(.validation, .invalidPayload)
            }
            return domainValue
        }
        let value = try ListeningSegmentCodec.decode(
            segmentPayload, expectedID: eventID)
        guard
            segmentEnvelopeVersion == nil
                || segmentEnvelopeVersion == value.lineage?.version,
            ListeningSegmentCodec.scalar(value) == domainValue
        else { throw ListeningSegmentFailure(.validation, .metadataConflict) }
        // Valid local bytes authoritatively recover an absent optional marker.
        if segmentEnvelopeVersion == nil {
            segmentEnvelopeVersion = value.lineage?.version
        }
        return value
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
            duration: duration, recordingFormat: recordingFormat,
            recordingState: recordingFormat == nil
                ? nil : (isFinalized == false ? .active : .finalized),
            boundaryAfter: boundaryAfter,
            acknowledgedResetIDs: acknowledgedResetIDs
        )
    }
}

extension ListeningSliceRecord {
    func extend(to slice: ListeningSlice) {
        endedAt = slice.endedAt
        endPosition = slice.endPosition
        realSeconds = slice.realSeconds
        audiobookSeconds = slice.audiobookSeconds
        isFinalized = slice.recordingState != .active
        boundaryAfter = slice.boundaryAfter
        acknowledgedResetIDs = slice.acknowledgedResetIDs
        privateCloudSynchronized = false
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
    public let resetEnvelopes: [ListeningSlice]?
    public let completions: [CompletionMilestone]
    public let remoteSessions: [RemoteListeningSession]

    public init(
        version: Int = 1,
        exportedAt: Date = Date(),
        slices: [ListeningSlice],
        completions: [CompletionMilestone],
        remoteSessions: [RemoteListeningSession],
        resetEnvelopes: [ListeningSlice]? = nil
    ) {
        let resets =
            (resetEnvelopes ?? [])
            + slices.filter { $0.lineage?.kind == .resetAnchors }
        self.version =
            (!resets.isEmpty || slices.contains(where: { $0.lineage != nil }))
            ? max(2, version) : version
        self.exportedAt = exportedAt
        self.slices = slices.filter { $0.lineage?.kind != .resetAnchors }
        self.resetEnvelopes = resets.isEmpty ? nil : resets
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
            },
            resetEnvelopes: resetEnvelopes?.map {
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

struct PrivateCloudStatisticsSnapshot: Sendable {
    let archive: StatisticsArchive
    let payloads: [UUID: Data]
    let retirementGeneration: UInt64
}

struct CurrentListeningUpload: Sendable {
    let value: ListeningSlice
    let payload: Data?
}

struct PrivateCloudStatisticsDeletion: Equatable, Sendable {
    let recordName: String
    let recordType: String
    let accountID: AccountID
}

public struct StatisticsSessionListeningTime: Equatable, Sendable {
    public let total: Double
    public let pending: Double

    public init(total: Double, pending: Double) {
        self.total = total
        self.pending = pending
    }
}

public struct ListeningAccumulator: Sendable {
    private var previous: StatisticsPlaybackSample?
    fileprivate private(set) var pending: ListeningSlice?
    private var checkpoint: ListeningSlice?

    private let acknowledgedResetIDs: [UUID]?
    public init(acknowledgedResetIDs: [UUID]? = nil) {
        self.acknowledgedResetIDs = acknowledgedResetIDs
    }

    var resetBoundaryDate: Date? { pending?.startedAt ?? previous?.observedAt }
    func acknowledgesReset(_ id: UUID) -> Bool {
        (acknowledgedResetIDs ?? []).contains(id)
    }

    public var uncommittedSlice: ListeningSlice? {
        pending?.tail(after: checkpoint)
    }

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
        if previous.accountID != sample.accountID {
            return flush(.accountChanged)
        }
        if previous.itemID != sample.itemID { return flush(.bookChanged) }
        if previous.sessionID != sample.sessionID {
            return flush(.sessionChanged)
        }
        if previous.playbackGeneration != sample.playbackGeneration {
            return flush(.playbackGenerationChanged)
        }
        if !previous.isAudibleAndAdvancing || !sample.isAudibleAndAdvancing {
            return flush(.inaudibleSample)
        }

        let realDelta = sample.monotonicTime - previous.monotonicTime
        let positionDelta =
            sample.wholeBookPosition - previous.wholeBookPosition
        guard realDelta > 0, realDelta <= 10, positionDelta > 0.01 else {
            return flush(
                positionDelta <= 0.01
                    ? .positionDiscontinuity : .observationDiscontinuity)
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
            duration: previous.duration, recordingFormat: .continuousSegment,
            recordingState: .active, acknowledgedResetIDs: acknowledgedResetIDs
        )

        var output: [ListeningSlice]
        if let (first, second) = interval.splitAtReportingDay() {
            output = append(first)
            output.append(contentsOf: flush())
            output.append(contentsOf: append(second))
        } else {
            output = append(interval)
        }
        if previous.playbackRate != sample.playbackRate
            || previous.chapter != sample.chapter
        {
            output.append(
                contentsOf: flush(
                    previous.playbackRate != sample.playbackRate
                        ? .rateChanged : .chapterChanged))
        }
        return output
    }

    private mutating func append(_ interval: ListeningSlice) -> [ListeningSlice]
    {
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
                duration: pending.duration, recordingFormat: .continuousSegment,
                recordingState: .active,
                acknowledgedResetIDs: acknowledgedResetIDs
            )
        } else {
            let boundary: ListeningBoundary =
                pending.map {
                    ListeningContinuityPolicy.sameContext($0, interval)
                        ? .positionDiscontinuity : .metadataChanged
                } ?? .metadataChanged
            var output = flush(boundary)
            pending = interval
            if interval.realSeconds >= 5 {
                output.append(interval)
                checkpoint = interval
            }
            return output
        }

        if let pending,
            pending.realSeconds - (checkpoint?.realSeconds ?? 0) >= 5
        {
            checkpoint = pending
            return [pending]
        }
        return []
    }

    public mutating func finish(boundary: ListeningBoundary = .explicitStop)
        -> [ListeningSlice]
    {
        previous = nil
        return flush(boundary)
    }

    private mutating func flush(_ boundary: ListeningBoundary? = nil)
        -> [ListeningSlice]
    {
        guard let pending else {
            return []
        }
        self.pending = nil
        checkpoint = nil
        return [pending.copying(state: .finalized, boundary: boundary)]
    }

    private static func canMerge(_ lhs: ListeningSlice, _ rhs: ListeningSlice)
        -> Bool
    {
        ListeningContinuityPolicy.canJoin(lhs, rhs, evidence: .liveSamples)
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
    let modelContainer: ModelContainer
    private var canonicalReconciliationNeeded = true
    private var retirementGeneration: UInt64 = 0
    private var resetActionCache: [AccountID: [ListeningResetAction]]?
    private var resetMonotonicFence: [AccountID: TimeInterval] = [:]
    private let monotonicNow: @Sendable () -> TimeInterval
    private let canonicalHistoryEnabled: @Sendable () -> Bool
    private var accumulators:
        [StatisticsAggregation.SessionKey: ListeningAccumulator] = [:]
    private struct Observation {
        let query: StatisticsQuery
        let continuation: AsyncStream<StatisticsUpdate>.Continuation
        var state: StatisticsUpdate
    }
    private var observations: [UUID: Observation] = [:]
    private var preparedSnapshots: [StatisticsQuery: StatisticsSnapshot] = [:]
    private var updateRevision: UInt64 = 0
    private var recoveredActiveSegments = false
    private var latestSamples:
        [StatisticsAggregation.SessionKey: (generation: UInt64, time: Double)] =
            [:]

    public func updates(
        id: UUID, query: StatisticsQuery, accountIDs: [AccountID]
    )
        -> AsyncStream<StatisticsUpdate>
    {
        stopUpdates(id: id)
        let (stream, continuation) = AsyncStream<StatisticsUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        var history:
            [AccountID: Result<
                StatisticsHistoryProgress, StatisticsRepositoryError
            >] = [:]
        for accountID in accountIDs {
            do {
                history[accountID] = .success(
                    try historyProgress(accountID: accountID))
            } catch { history[accountID] = .failure(error) }
        }
        updateRevision &+= 1
        let presentation: StatisticsUpdate.Presentation
        if let snapshot = preparedSnapshots[query] {
            presentation = .committed(
                StatisticsPresentation(
                    snapshot: snapshot,
                    liveSlice: uncommittedSlice(accountID: query.accountID)))
        } else {
            presentation = .unprepared
        }
        let state = StatisticsUpdate(
            revision: updateRevision, presentationRevision: updateRevision,
            presentation: presentation, history: history)
        observations[id] = Observation(
            query: query, continuation: continuation, state: state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.stopUpdates(id: id) }
        }
        continuation.yield(state)
        return stream
    }

    public func currentUpdate(id: UUID) -> StatisticsUpdate? {
        observations[id]?.state
    }

    public func stopUpdates(id: UUID) {
        guard let observation = observations.removeValue(forKey: id) else {
            return
        }
        observation.continuation.finish()
        if !observations.values.contains(where: {
            $0.query == observation.query
        }) {
            preparedSnapshots[observation.query] = nil
        }
    }

    private func publishPresentation(
        liveOnly: Bool = false, query: StatisticsQuery? = nil
    ) {
        for id in Array(observations.keys) {
            guard var observation = observations[id],
                query == nil || observation.query == query
            else { continue }
            let presentation: StatisticsUpdate.Presentation
            if let snapshot = preparedSnapshots[observation.query] {
                let value = StatisticsPresentation(
                    snapshot: snapshot,
                    liveSlice: uncommittedSlice(
                        accountID: observation.query.accountID))
                if liveOnly {
                    switch observation.state.presentation {
                    case .live(let previous), .committed(let previous):
                        if previous.snapshot == value.snapshot,
                            previous.liveSlice == value.liveSlice
                        {
                            continue
                        }
                    case .unprepared, .invalidated: break
                    }
                }
                // A pending committed change must survive subsequent live samples.
                if liveOnly, case .live = observation.state.presentation {
                    presentation = .live(value)
                } else if liveOnly,
                    case .unprepared = observation.state.presentation
                {
                    presentation = .live(value)
                } else {
                    presentation = .committed(value)
                }
            } else {
                if liveOnly { continue }
                presentation = .invalidated
            }
            updateRevision &+= 1
            observation.state = StatisticsUpdate(
                revision: updateRevision, presentationRevision: updateRevision,
                presentation: presentation, history: observation.state.history)
            observations[id] = observation
            observation.continuation.yield(observation.state)
        }
    }

    /// Acknowledge delivery so later samples can be throttled independently of
    /// the last committed update. Revisions prevent acknowledging newer data.
    public func acknowledgeUpdate(id: UUID, revision: UInt64) {
        guard var observation = observations[id],
            observation.state.presentationRevision == revision,
            case .committed(let value) = observation.state.presentation
        else { return }
        observation.state = StatisticsUpdate(
            revision: observation.state.revision,
            presentationRevision: revision,
            presentation: .live(value), history: observation.state.history)
        observations[id] = observation
    }

    private func publishHistory(
        accountID: AccountID,
        progress: Result<StatisticsHistoryProgress, StatisticsRepositoryError>
    ) {
        for id in Array(observations.keys) {
            guard var observation = observations[id],
                observation.state.history[accountID] != nil
            else { continue }
            var history = observation.state.history
            history[accountID] = progress
            updateRevision &+= 1
            observation.state = StatisticsUpdate(
                revision: updateRevision,
                presentationRevision: observation.state.presentationRevision,
                presentation: observation.state.presentation, history: history)
            observations[id] = observation
            observation.continuation.yield(observation.state)
        }
    }

    public init(
        modelContainer: ModelContainer,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }, canonicalHistoryEnabled: @escaping @Sendable () -> Bool = { false }
    ) {
        self.modelContainer = modelContainer
        self.monotonicNow = monotonicNow
        self.canonicalHistoryEnabled = canonicalHistoryEnabled
    }

    public func discardAfterPersistentReset() {
        accumulators.removeAll()
        latestSamples.removeAll()
        recoveredActiveSegments = false
        preparedSnapshots.removeAll()
        publishPresentation()
        for accountID in Set(
            observations.values.flatMap { $0.state.history.keys })
        {
            publishHistory(
                accountID: accountID,
                progress: .success(
                    StatisticsHistoryProgress(
                        startedAt: nil, lastCompletedAt: nil, completedPages: 0,
                        totalPages: 0)))
        }
    }

    public func uncommittedSlice(accountID: AccountID?) -> ListeningSlice? {
        accumulators.values.compactMap(\.uncommittedSlice).first {
            accountID == nil || $0.accountID == accountID
        }
    }

    public func record(
        _ sample: StatisticsPlaybackSample
    ) throws(StatisticsRepositoryError) {
        try recoverActiveSegments()
        let identity = StatisticsAggregation.SessionKey(
            account: sample.accountID, session: sample.sessionID)
        if let latest = latestSamples[identity],
            sample.playbackGeneration < latest.generation
                || sample.monotonicTime <= latest.time
        {
            return
        }
        if let fence = resetMonotonicFence[sample.accountID],
            sample.monotonicTime <= fence
        {
            return
        }
        let resetIDs = try knownListeningResets()[sample.accountID]?.map(\.id)
            .sorted { $0.uuidString < $1.uuidString }
        var accumulator =
            accumulators[identity]
            ?? ListeningAccumulator(
                acknowledgedResetIDs: resetIDs?.isEmpty == false
                    ? resetIDs : nil)
        let slices = try accumulator.ingest(sample)
        if !slices.isEmpty { try save(slices, publish: false) }
        accumulators[identity] = accumulator
        latestSamples[identity] = (
            sample.playbackGeneration, sample.monotonicTime
        )
        publishPresentation(liveOnly: slices.isEmpty)
    }

    public func finish(
        sessionID: PlaybackSessionID
    ) throws(StatisticsRepositoryError) {
        let matching = accumulators.filter { $0.key.session == sessionID }
        let slices = matching.values.flatMap { value in
            var accumulator = value
            return accumulator.finish()
        }
        if !slices.isEmpty { try save(slices, publish: false) }
        for identity in matching.keys { accumulators[identity] = nil }
        publishPresentation()
    }

    public func finishAll() throws(StatisticsRepositoryError) {
        try recoverActiveSegments()
        let slices = accumulators.values.flatMap { value in
            var accumulator = value
            return accumulator.finish(boundary: .synchronizationCheckpoint)
        }
        if !slices.isEmpty { try save(slices, publish: false) }
        accumulators.removeAll()
        publishPresentation()
    }

    private func recoverActiveSegments() throws(StatisticsRepositoryError) {
        guard !recoveredActiveSegments else { return }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let records = try context.fetch(
                FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate { $0.isFinalized == false }))
            for record in records {
                record.isFinalized = true
                record.boundaryAfter = .processInterrupted
                record.privateCloudSynchronized = false
            }
            try context.save()
            recoveredActiveSegments = true
        } catch { throw .persistenceFailed }
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
            publishHistory(
                accountID: accountID,
                progress: .success(
                    StatisticsHistoryProgress(
                        startedAt: record.startedAt,
                        lastCompletedAt: record.lastCompletedAt,
                        completedPages: record.completedPages,
                        totalPages: record.totalPages)))
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    public func summary(
        query: StatisticsQuery = StatisticsQuery()
    ) throws(StatisticsRepositoryError) -> StatisticsSummary {
        try recoverActiveSegments()
        return try snapshot(query: query).summary
    }

    public func exploration(query: StatisticsQuery = StatisticsQuery())
        throws(StatisticsRepositoryError) -> StatisticsExploration
    {
        try snapshot(query: query).exploration
    }

    public func presentation(query: StatisticsQuery)
        throws(StatisticsRepositoryError) -> StatisticsPresentation
    {
        let value = try snapshot(query: query)
        if observations.values.contains(where: { $0.query == query }) {
            preparedSnapshots[query] = value
            publishPresentation(query: query)
        }
        return StatisticsPresentation(
            snapshot: value,
            liveSlice: uncommittedSlice(accountID: query.accountID))
    }

    /// Polling never enters the ledger fetch/aggregation path. A missing cache
    /// remains absent until an explicit load or refresh prepares it.
    public func livePresentation(query: StatisticsQuery)
        throws(StatisticsRepositoryError) -> StatisticsPresentation?
    {
        let snapshot: StatisticsSnapshot?
        if let prepared = preparedSnapshots[query] {
            snapshot = prepared
        } else {
            snapshot = try cachedSnapshot(query: query)
        }
        guard let value = snapshot else { return nil }
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
        if canonicalReconciliationNeeded {
            let context = ModelContext(modelContainer)
            context.autosaveEnabled = false
            do {
                _ = try reconcileListeningSegments(context)
                try saveMutation(context, publish: false)
                canonicalReconciliationNeeded = false
            } catch let failure as ListeningSegmentFailure {
                throw .segmentFailure(failure)
            } catch { throw .persistenceFailed }
        }
        if let value = try cachedSnapshot(query: query) { return value }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let start = query.start
        let end = query.end
        let scope = query.accountID?.rawValue
        do {
            let slices = try reconcileListeningSegments(context).groups.map(
                \.value)
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
            let resolution = try reconcileListeningSegments(context)
            var exported: [UUID: ListeningSlice] = [:]
            for group in resolution.groups
            where query.contains(
                accountID: group.value.accountID, date: group.value.startedAt)
            {
                var covered: Set<UUID> = []
                let candidates = group.representations.sorted {
                    let left =
                        (try? ListeningSegmentCodec.sourceIDs($0).count) ?? 0
                    let right =
                        (try? ListeningSegmentCodec.sourceIDs($1).count) ?? 0
                    return left == right
                        ? $0.id.uuidString < $1.id.uuidString : left > right
                }
                for value in candidates {
                    let ids = try ListeningSegmentCodec.sourceIDs(value)
                    guard !ids.isSubset(of: covered) else { continue }
                    exported[value.id] = value
                    covered.formUnion(ids)
                }
            }
            for reset in resolution.resetEnvelopes
            where query.accountID == nil || query.accountID == reset.accountID {
                exported[reset.id] = reset
            }
            if context.hasChanges { try saveMutation(context, publish: false) }
            return StatisticsArchive(
                slices: exported.values.sorted {
                    $0.id.uuidString < $1.id.uuidString
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    func privateCloudSnapshot(includeCanonicalSegments: Bool = true)
        throws(StatisticsRepositoryError)
        -> PrivateCloudStatisticsSnapshot
    {
        try recoverActiveSegments()
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let sliceDescriptor = FetchDescriptor<ListeningSliceRecord>(
                predicate: #Predicate {
                    $0.privateCloudSynchronized == false
                        || $0.privateCloudSynchronized == nil
                })
            let extendedDescriptor = FetchDescriptor<ListeningSliceRecord>(
                predicate: #Predicate { $0.segmentPayload != nil })
            let completionDescriptor = FetchDescriptor<
                CompletionMilestoneRecord
            >(
                predicate: #Predicate<CompletionMilestoneRecord> {
                    $0.privateCloudSynchronized == false
                        || $0.privateCloudSynchronized == nil
                })
            let sessionDescriptor = FetchDescriptor<
                RemoteListeningSessionRecord
            >(
                predicate: #Predicate<RemoteListeningSessionRecord> {
                    $0.privateCloudSynchronized == false
                        || $0.privateCloudSynchronized == nil
                })
            var pending: [UUID: ListeningSliceRecord] = [:]
            for row in try context.fetch(sliceDescriptor) {
                pending[row.eventID] = row
            }
            if includeCanonicalSegments {
                for row in try context.fetch(extendedDescriptor)
                where row.segmentReceiptDigest == nil {
                    pending[row.eventID] = row
                }
            }
            var slices: [ListeningSlice] = []
            var payloads: [UUID: Data] = [:]
            for row in pending.values
            where row.isFinalized != false
                && row.segmentDeletionObserved != true
            {
                let value = try row.validatedValue()
                if includeCanonicalSegments || value.lineage == nil {
                    slices.append(value)
                    if let data = row.segmentPayload {
                        payloads[value.id] = data
                    }
                }
            }
            let completions = try context.fetch(completionDescriptor)
                .compactMap(\.domainValue)
            let sessions = try context.fetch(sessionDescriptor).map(
                \.domainValue)
            return PrivateCloudStatisticsSnapshot(
                archive: StatisticsArchive(
                    slices: slices, completions: completions,
                    remoteSessions: sessions),
                payloads: payloads, retirementGeneration: retirementGeneration)
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    func markPrivateCloudArchiveSynchronized(
        _ archive: StatisticsArchive, confirmedUpload: Bool = false,
        savedPayloads: [UUID: Data] = [:]
    ) throws(StatisticsRepositoryError) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            for slice in archive.slices + (archive.resetEnvelopes ?? []) {
                let id = slice.id
                let descriptor = FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate { $0.eventID == id }
                )
                if let record = try context.fetch(descriptor).first,
                    try record.validatedValue() == slice
                {
                    record.privateCloudSynchronized = true
                    if slice.lineage != nil {
                        record.segmentProtocolObserved = true
                    }
                    if confirmedUpload, let data = record.segmentPayload {
                        guard let saved = savedPayloads[id], saved == data
                        else {
                            throw ListeningSegmentFailure(
                                .retirement, .incompleteReplacement)
                        }
                        // Intentional byte identity binds the receipt to the
                        // exact payload sent unchanged from the native row.
                        record.segmentReceiptDigest = Data(
                            SHA256.hash(data: data))
                    }
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
            let rows = try ListeningSegmentPersistence.rows(context)
            var receipts: Set<UUID> = []
            for row in rows {
                if let data = row.segmentPayload,
                    row.segmentReceiptDigest == Data(SHA256.hash(data: data))
                {
                    receipts.insert(row.eventID)
                }
            }
            let cleanup = try context.fetch(
                FetchDescriptor<ListeningSegmentCleanupRecord>()
            )
            .filter {
                !$0.requiredReceiptIDs.isEmpty
                    && Set($0.requiredReceiptIDs).isSubset(of: receipts)
            }
            .map {
                PrivateCloudStatisticsDeletion(
                    recordName: $0.recordName, recordType: "ListeningSlice",
                    accountID: AccountID(rawValue: $0.accountID))
            }
            return cleanup
                + (try context.fetch(
                    FetchDescriptor<PrivateCloudStatisticsDeletionRecord>()
                ).map {
                    PrivateCloudStatisticsDeletion(
                        recordName: $0.recordName,
                        recordType: $0.recordType,
                        accountID: AccountID(rawValue: $0.accountID)
                    )
                })
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
            let cleanupNames = try context.fetch(
                FetchDescriptor<ListeningSegmentCleanupRecord>()
            )
            .filter { $0.accountID == account }.map(\.recordName)
            return Set(
                sliceNames + completionNames + remoteSessionNames
                    + deletionNames + cleanupNames
            )
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
                record.segmentReceiptDigest = nil
                record.segmentDeletionObserved = nil
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
            for row in try context.fetch(
                FetchDescriptor<ListeningSegmentCleanupRecord>())
            where recordNames.contains(row.recordName) { context.delete(row) }
            try context.save()
        } catch let error as StatisticsRepositoryError {
            throw error
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    public func importArchive(
        _ archive: StatisticsArchive
    ) throws(StatisticsRepositoryError) {
        do {
            for value in archive.slices + (archive.resetEnvelopes ?? [])
            where value.lineage != nil {
                try ListeningSegmentCodec.validate(value)
            }
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch { throw .invalidArchive }
        guard archive.version == 1 || archive.version == 2,
            (archive.resetEnvelopes ?? []).allSatisfy({
                $0.lineage?.kind == .resetAnchors
            }),
            archive.slices.allSatisfy({ $0.lineage?.kind != .resetAnchors }),
            Set((archive.slices + (archive.resetEnvelopes ?? [])).map(\.id))
                .count == archive.slices.count
                + (archive.resetEnvelopes?.count ?? 0),
            archive.version >= 2
                || ((archive.resetEnvelopes ?? []).isEmpty
                    && archive.slices.allSatisfy { $0.lineage == nil }),
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
            archive.slices.allSatisfy({
                Self.isValid($0) && $0.recordingState != .active
            }),
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
            let before = try knownListeningResets()
            for slice in archive.slices + (archive.resetEnvelopes ?? []) {
                try ListeningSegmentPersistence.insert(slice, in: context)
                if slice.lineage != nil {
                    let id = slice.id
                    try context.fetch(
                        FetchDescriptor<ListeningSliceRecord>(
                            predicate: #Predicate { $0.eventID == id })
                    ).first?.segmentProtocolObserved = true
                }
            }
            _ = try reconcileListeningSegments(context)
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
            if !(archive.resetEnvelopes ?? []).isEmpty {
                retirementGeneration &+= 1
            }
            resetActionCache = nil
            let after = try knownListeningResets()
            for (account, actions) in after
            where !Set(actions.map(\.id)).isSubset(
                of: Set(before[account]?.map(\.id) ?? []))
            {
                let newActions = actions.filter {
                    !(before[account]?.map(\.id) ?? []).contains($0.id)
                }
                retireActiveRecording(for: account, actions: newActions)
            }
        } catch let error as StatisticsRepositoryError {
            throw error
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    public func reset(
        query: StatisticsQuery, knownAccountIDs: [AccountID] = [],
        resetAt: Date = Date()
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
            let physical = try ListeningSegmentPersistence.physical(context)
            let reportingRange = ListeningSegmentCodec.reportingRange(
                start: query.start, end: query.end)
            let current = try ListeningSegmentCodec.resolve(
                physical, applyingResets: !reportingRange)
            var selected: [AccountID: Set<UUID>] = [:]
            for group in current.groups {
                let value = group.value
                let key = StatisticsSessionAccountingRecord.compositeID(
                    accountID: value.accountID, sessionID: value.sessionID)
                if query.contains(
                    accountID: value.accountID, date: value.startedAt)
                {
                    selected[value.accountID, default: []].formUnion(
                        group.sources.keys)
                    affectedSessionKeys.insert(key)
                } else {
                    remainingRealBySession[key, default: 0] += value.realSeconds
                }
            }
            for record in try context.fetch(
                FetchDescriptor<StatisticsSessionAccountingRecord>())
            where affectedSessionKeys.contains(record.compositeID)
                && (remainingRealBySession[record.compositeID] ?? 0) > 0
                && (record.confirmedRealSeconds > 0
                    || record.uncertainRealSeconds > 0)
            {
                throw StatisticsRepositoryError
                    .partialSessionResetRequiresFullSession
            }
            if !reportingRange {
                for group in current.groups
                where query.accountID == nil
                    || query.accountID == group.value.accountID
                {
                    guard
                        group.representations.contains(where: {
                            $0.lineage?.kind == .observations
                        })
                    else { continue }
                    let cutsStart =
                        query.start.map {
                            group.value.startedAt < $0
                                && $0 < group.value.endedAt
                        } ?? false
                    let cutsEnd =
                        query.end.map {
                            group.value.startedAt < $0
                                && $0 < group.value.endedAt
                        } ?? false
                    if cutsStart || cutsEnd {
                        throw ListeningSegmentFailure(
                            .retirement, .partialRangeResetUnsupported)
                    }
                }
            }
            var accounts = Set(selected.keys)
            if let account = query.accountID {
                accounts.insert(account)
            } else if reportingRange {
                accounts.formUnion(knownAccountIDs)
                accounts.formUnion(physical.map(\.accountID))
                accounts.formUnion(
                    try context.fetch(
                        FetchDescriptor<CompletionMilestoneRecord>()
                    ).map { AccountID(rawValue: $0.accountID) })
                accounts.formUnion(
                    try context.fetch(
                        FetchDescriptor<RemoteListeningSessionRecord>()
                    ).map { AccountID(rawValue: $0.accountID) })
            }
            let action = ListeningResetAction(
                id: UUID(), start: query.start, end: query.end,
                issuedAt: resetAt,
                selection: reportingRange ? .reportingRange : .sourceIdentities)
            for account in accounts {
                let ids = selected[account] ?? []
                if ids.isEmpty && !reportingRange { continue }
                for envelope in try ListeningSegmentCodec.resetEnvelopes(
                    accountID: account, action: action, ids: ids)
                {
                    try ListeningSegmentPersistence.insert(
                        envelope, in: context)
                }
            }
            _ = try reconcileListeningSegments(context)
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
            try saveMutation(context, publish: false)
            retirementGeneration &+= 1
            resetActionCache = nil
            for account in accounts {
                retireActiveRecording(for: account, actions: [action])
            }
            for accountID in Set(
                observations.values.flatMap { $0.state.history.keys })
            where query.accountID == nil || query.accountID == accountID {
                publishHistory(
                    accountID: accountID,
                    progress: .success(
                        StatisticsHistoryProgress(
                            startedAt: nil, lastCompletedAt: nil,
                            completedPages: 0, totalPages: 0)))
            }
            publishPresentation()
        } catch let error as StatisticsRepositoryError {
            throw error
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    func observeCloudSliceDeletion(
        id: UUID
    ) throws(StatisticsRepositoryError) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let descriptor = FetchDescriptor<ListeningSliceRecord>(
                predicate: #Predicate { $0.eventID == id }
            )
            if let record = try context.fetch(descriptor).first {
                record.segmentDeletionObserved = true
                let others = try ListeningSegmentPersistence.physical(context)
                    .filter { $0.id != id }
                if try ListeningSegmentPersistence.canRemove(
                    record.validatedValue(), alternatives: others)
                {
                    context.delete(record)
                }
                try saveMutation(context)
            }
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    /// Account removal on this device is not a synchronized history reset.
    /// Existing reset metadata remains authoritative through a later re-add.
    public func removeAccountHistoryLocally(_ accountID: AccountID)
        throws(StatisticsRepositoryError)
    {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let owner = accountID.rawValue
        do {
            for row in try ListeningSegmentPersistence.rows(context)
            where row.accountID == owner {
                if try row.validatedValue().lineage?.kind != .resetAnchors {
                    context.delete(row)
                }
            }
            try context.delete(
                model: CompletionMilestoneRecord.self,
                where: #Predicate { $0.accountID == owner })
            try context.delete(
                model: RemoteListeningSessionRecord.self,
                where: #Predicate { $0.accountID == owner })
            try context.delete(
                model: StatisticsSessionAccountingRecord.self,
                where: #Predicate { $0.accountID == owner })
            try context.delete(
                model: StatisticsHistoryImportRecord.self,
                where: #Predicate { $0.accountID == owner })
            try saveMutation(context)
            accumulators = accumulators.filter { $0.key.account != accountID }
            resetMonotonicFence[accountID] = monotonicNow()
            retirementGeneration &+= 1
            resetActionCache = nil
            canonicalReconciliationNeeded = true
            preparedSnapshots.removeAll()
            publishPresentation()
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .segmentFailure(
                ListeningSegmentFailure(
                    .storageWrite, .writeFailed,
                    systemError: PrivateCloudSystemError(error)))
        }
    }

    public func deleteSlice(id: UUID) throws(StatisticsRepositoryError) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            if let row = try context.fetch(
                FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate { $0.eventID == id })
            ).first {
                context.delete(row)
                try saveMutation(context)
            }
        } catch { throw .persistenceFailed }
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    private func save(
        _ slices: [ListeningSlice], publish: Bool = true
    ) throws(StatisticsRepositoryError) {
        guard slices.allSatisfy(Self.isValid) else {
            throw .invalidSlice
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            var tails: [ListeningSlice] = []
            for slice in slices {
                let id = slice.id
                let previous = try context.fetch(
                    FetchDescriptor<ListeningSliceRecord>(
                        predicate: #Predicate { $0.eventID == id })
                ).first
                if let previous {
                    guard previous.isFinalized == false,
                        previous.accountID == slice.accountID.rawValue,
                        slice.realSeconds >= previous.realSeconds,
                        slice.audiobookSeconds >= previous.audiobookSeconds
                    else { throw StatisticsRepositoryError.invalidSlice }
                    if let tail = slice.tail(after: previous.domainValue) {
                        tails.append(tail)
                    }
                    previous.extend(to: slice)
                } else {
                    context.insert(ListeningSliceRecord(slice))
                    tails.append(slice)
                }
            }
            try saveMutation(context, publish: publish) { $0.append(tails) }
        } catch let error as StatisticsRepositoryError {
            throw error
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    public func pendingRealSeconds(
        accountID: AccountID,
        sessionID: PlaybackSessionID
    ) throws(StatisticsRepositoryError) -> Double {
        try sessionListeningTime(accountID: accountID, sessionID: sessionID)
            .pending
    }

    public func sessionListeningTime(
        accountID: AccountID,
        sessionID: PlaybackSessionID
    ) throws(StatisticsRepositoryError) -> StatisticsSessionListeningTime {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let account = accountID.rawValue
            let session = sessionID.rawValue
            _ = try reconcileListeningSegments(context)
            let owned = try ListeningSegmentPersistence.physical(context).filter
            {
                $0.accountID.rawValue == account
                    && ($0.sessionID.rawValue == session
                        || $0.lineage?.kind == .resetAnchors)
            }
            let total = try ListeningSegmentCodec.resolve(owned).groups.reduce(
                0
            ) { $0 + $1.value.realSeconds }
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
            let reported =
                (accounting?.confirmedRealSeconds ?? 0)
                + (accounting?.uncertainRealSeconds ?? 0)
            if context.hasChanges { try saveMutation(context, publish: false) }
            return StatisticsSessionListeningTime(
                total: max(total, reported),
                pending: max(0, total - reported)
            )
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
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
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .persistenceFailed
        }
    }

    private func saveMutation(
        _ context: ModelContext,
        publish: Bool = true,
        update: ((inout StatisticsAggregation.State) -> Void)? = nil
    ) throws {
        guard context.hasChanges else { return }
        var prepared: [StatisticsQuery: StatisticsSnapshot] = [:]
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
                let query = StatisticsQuery(
                    accountID: cache.accountID.map { AccountID(rawValue: $0) },
                    start: cache.start, end: cache.end)
                if observations.values.contains(where: { $0.query == query }) {
                    prepared[query] = value
                }
            } else {
                context.delete(cache)
            }
        }
        try context.save()
        preparedSnapshots = prepared
        if publish { publishPresentation() }
    }

    private func reconcileListeningSegments(_ context: ModelContext) throws
        -> ListeningSegmentResolution
    {
        try ListeningSegmentPersistence.reconcile(
            context, canonicalProtocolEnabled: canonicalHistoryEnabled())
    }

    func canonicalSegmentPayload(id: UUID) throws(StatisticsRepositoryError)
        -> Data?
    {
        let context = ModelContext(modelContainer)
        do {
            let row = try context.fetch(
                FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate { $0.eventID == id })
            ).first
            if let row { _ = try row.validatedValue() }
            return row?.segmentPayload
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .segmentFailure(
                ListeningSegmentFailure(
                    .storageRead, .readFailed,
                    systemError: PrivateCloudSystemError(error)))
        }
    }

    /// Existing source rows remain durable until an exact upload receipt exists.
    func prepareCanonicalCompaction() throws(StatisticsRepositoryError) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            // Compare the Codable enum after materialization: supported older
            // SwiftData runtimes need not expose it as a SQL-queryable keypath.
            let legacy = try context.fetch(
                FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate {
                        $0.isFinalized != false
                    })
            ).filter { $0.recordingFormat == nil }
            guard !legacy.isEmpty else { return }
            let current = try reconcileListeningSegments(context)
            var represented: Set<ListeningSourceIdentity> = []
            for group in current.groups {
                for value in group.representations
                where value.lineage?.kind == .observations {
                    represented.formUnion(
                        try ListeningSegmentCodec.sourceIDs(value).map {
                            ListeningSourceIdentity(
                                accountID: value.accountID, id: $0)
                        })
                }
            }
            // Bound each transaction. Interrupted runs retain every source;
            // subsequent passes exclude already represented identities.
            let originals = legacy.filter {
                !represented.contains(
                    ListeningSourceIdentity(
                        accountID: AccountID(rawValue: $0.accountID),
                        id: $0.eventID))
            }.sorted {
                if $0.startedAt != $1.startedAt {
                    return $0.startedAt < $1.startedAt
                }
                return $0.eventID.uuidString < $1.eventID.uuidString
            }.prefix(ListeningSegmentCodec.maximumSources * 8).map(
                \.domainValue)
            let replacements = try ListeningSegmentCodec.coalesce(originals)
            for value in replacements {
                if value.lineage == nil {
                    if let row = legacy.first(where: { $0.eventID == value.id })
                    {
                        row.recordingFormat = .continuousSegment
                        row.isFinalized = true
                        row.privateCloudSynchronized = false
                    }
                } else {
                    try ListeningSegmentPersistence.insert(value, in: context)
                }
            }
            try saveMutation(context)
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .segmentFailure(
                ListeningSegmentFailure(
                    .storageWrite, .writeFailed,
                    systemError: PrivateCloudSystemError(error)))
        }
    }

    func retireConfirmedCanonicalSources(additional: [ListeningSlice] = [])
        throws(StatisticsRepositoryError)
    {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let resolution = try reconcileListeningSegments(context)
            var replacements:
                [ListeningSourceIdentity: (ListeningSourceContribution, UUID)] =
                    [:]
            for row in try ListeningSegmentPersistence.rows(context) {
                guard let data = row.segmentPayload,
                    row.segmentReceiptDigest == Data(SHA256.hash(data: data))
                else { continue }
                let value = try row.validatedValue()
                guard value.lineage?.kind == .observations else { continue }
                for proof in try ListeningSegmentCodec.contributions(value) {
                    replacements[
                        ListeningSourceIdentity(
                            accountID: value.accountID, id: proof.id)] = (
                            proof, value.id
                        )
                }
            }
            let originals = try ListeningSegmentPersistence.rows(context).filter
            { $0.segmentPayload == nil && $0.recordingFormat == nil }
            for value in originals.map(\.domainValue) + additional
            where value.lineage == nil {
                let identity = ListeningSourceIdentity(
                    accountID: value.accountID, id: value.id)
                guard let (expected, replacementID) = replacements[identity]
                else { continue }
                guard
                    try ListeningSegmentCodec.contributions(value).first
                        == expected
                else {
                    throw ListeningSegmentFailure(.retirement, .sourceConflict)
                }
                try ListeningSegmentPersistence.enqueue(
                    name: "slice.\(value.id.uuidString.lowercased())",
                    accountID: value.accountID, requiring: [replacementID],
                    in: context)
                if let row = originals.first(where: { $0.eventID == value.id })
                {
                    context.delete(row)
                }
            }
            _ = resolution
            try saveMutation(context)
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .segmentFailure(
                ListeningSegmentFailure(
                    .storageWrite, .writeFailed,
                    systemError: PrivateCloudSystemError(error)))
        }
    }

    /// A complete fetch is not proof that a replacement covers a deleted row.
    /// The canonical protocol represents intentional resets with durable anchors;
    /// an uncovered physical deletion is repaired from authoritative local data.
    func finalizeObservedListeningDeletions() throws(StatisticsRepositoryError)
    {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            _ = try reconcileListeningSegments(context)
            let canonicalRows = try ListeningSegmentPersistence.rows(context)
            let canonicalAccounts = Set(
                canonicalRows.filter { $0.segmentProtocolObserved == true }.map(
                    \.accountID))
            for row in try ListeningSegmentPersistence.rows(context)
            where row.segmentDeletionObserved == true {
                let value = try row.validatedValue()
                let alternatives = try ListeningSegmentPersistence.physical(
                    context
                ).filter { $0.id != value.id }
                if try ListeningSegmentPersistence.canRemove(
                    value, alternatives: alternatives)
                {
                    context.delete(row)
                } else if value.lineage != nil || canonicalHistoryEnabled()
                    || canonicalAccounts.contains(value.accountID.rawValue)
                {
                    row.segmentDeletionObserved = nil
                    row.segmentReceiptDigest = nil
                    row.privateCloudSynchronized = false
                } else {
                    context.delete(row)
                }
            }
            try saveMutation(context)
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch { throw .persistenceFailed }
    }

    public func accountOwnershipDidChange() {
        retirementGeneration &+= 1
        resetActionCache = nil
        canonicalReconciliationNeeded = true
        preparedSnapshots.removeAll()
        publishPresentation()
    }

    func requireAccountResetReceipts(_ accountID: AccountID)
        throws(StatisticsRepositoryError)
    {
        do {
            let rows = try ListeningSegmentPersistence.rows(
                ModelContext(modelContainer)
            ).filter { $0.accountID == accountID.rawValue }
            let resets = try rows.filter {
                try $0.validatedValue().lineage?.kind == .resetAnchors
            }
            guard !resets.isEmpty,
                resets.allSatisfy({ row in
                    guard let data = row.segmentPayload else { return false }
                    return row.segmentReceiptDigest
                        == Data(SHA256.hash(data: data))
                })
            else { throw ListeningSegmentFailure(.retirement, .missingReceipt) }
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .segmentFailure(
                ListeningSegmentFailure(
                    .storageRead, .readFailed,
                    systemError: PrivateCloudSystemError(error)))
        }
    }

    func hasCanonicalPayloads() throws(StatisticsRepositoryError) -> Bool {
        do {
            return try ModelContext(modelContainer).fetchCount(
                FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate { $0.segmentPayload != nil })) > 0
        } catch { throw .persistenceFailed }
    }

    func validatePreparedHistory(generation: UInt64)
        throws(StatisticsRepositoryError)
    {
        guard generation == retirementGeneration else {
            throw .segmentFailure(
                ListeningSegmentFailure(.retirement, .stalePreparation))
        }
    }

    func currentListeningUpload(id: UUID) throws(StatisticsRepositoryError)
        -> CurrentListeningUpload?
    {
        let context = ModelContext(modelContainer)
        do {
            guard
                let row = try context.fetch(
                    FetchDescriptor<ListeningSliceRecord>(
                        predicate: #Predicate { $0.eventID == id })
                ).first,
                row.isFinalized != false, row.segmentDeletionObserved != true
            else { return nil }
            let value = try row.validatedValue()
            return CurrentListeningUpload(
                value: value, payload: row.segmentPayload)
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .segmentFailure(
                ListeningSegmentFailure(
                    .storageRead, .readFailed,
                    systemError: PrivateCloudSystemError(error)))
        }
    }

    /// A save may complete after reset removed its local row. Reconcile it only
    /// as evidence for compensating cleanup, never as a history import.
    func compensateLateListeningSaves(_ values: [ListeningSlice])
        throws(StatisticsRepositoryError)
    {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            for value in values {
                // A retired reset envelope is never resurrected by a late save.
                guard value.lineage?.kind != .resetAnchors else { continue }
                let id = value.id
                if let existing = try context.fetch(
                    FetchDescriptor<ListeningSliceRecord>(
                        predicate: #Predicate { $0.eventID == id })
                ).first {
                    if try existing.validatedValue() != value {
                        existing.privateCloudSynchronized = false
                    }
                    continue
                }
                if value.lineage != nil {
                    let owner = value.accountID.rawValue
                    if let alias = try context.fetch(
                        FetchDescriptor<AccountIdentityAliasRecord>(
                            predicate: #Predicate {
                                $0.legacyAccountID == owner
                            })
                    ).first {
                        let canonical = value.reidentified(
                            as: AccountID(rawValue: alias.canonicalAccountID))
                        let canonicalID = canonical.id
                        if let current = try context.fetch(
                            FetchDescriptor<ListeningSliceRecord>(
                                predicate: #Predicate {
                                    $0.eventID == canonicalID
                                })
                        ).first,
                            try ListeningSegmentCodec.equivalentRepresentation(
                                current.validatedValue(), canonical)
                        {
                            try ListeningSegmentPersistence.enqueue(
                                name: "slice.\(id.uuidString.lowercased())",
                                accountID: canonical.accountID,
                                requiring: [canonicalID], in: context)
                            continue
                        }
                    }
                }
                try ListeningSegmentPersistence.insert(value, in: context)
                _ = try reconcileListeningSegments(context)
                // No reset selected this stale save: it must not create local
                // history merely because a retired request completed.
                if let transient = try context.fetch(
                    FetchDescriptor<ListeningSliceRecord>(
                        predicate: #Predicate { $0.eventID == id })
                ).first {
                    context.delete(transient)
                }
            }
            try saveMutation(context)
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .segmentFailure(
                ListeningSegmentFailure(
                    .storageWrite, .writeFailed,
                    systemError: PrivateCloudSystemError(error)))
        }
    }

    private func knownListeningResets() throws(StatisticsRepositoryError)
        -> [AccountID: [ListeningResetAction]]
    {
        if let resetActionCache { return resetActionCache }
        let context = ModelContext(modelContainer)
        do {
            var actions: [AccountID: [UUID: ListeningResetAction]] = [:]
            for row in try context.fetch(
                FetchDescriptor<ListeningSliceRecord>(
                    predicate: #Predicate { $0.segmentPayload != nil }))
            {
                let value = try row.validatedValue()
                if let action = value.lineage?.resetAction {
                    actions[value.accountID, default: [:]][action.id] = action
                }
            }
            let result = actions.mapValues { Array($0.values) }
            resetActionCache = result
            return result
        } catch let failure as ListeningSegmentFailure {
            throw .segmentFailure(failure)
        } catch {
            throw .segmentFailure(
                ListeningSegmentFailure(
                    .storageRead, .readFailed,
                    systemError: PrivateCloudSystemError(error)))
        }
    }

    private func retireActiveRecording(
        for account: AccountID, actions: [ListeningResetAction]
    ) {
        var affected = false
        for identity in Array(accumulators.keys)
        where identity.account == account {
            guard let accumulator = accumulators[identity],
                let startedAt = accumulator.resetBoundaryDate
            else { continue }
            if actions.contains(where: { action in
                startedAt <= action.issuedAt
                    && !accumulator.acknowledgesReset(action.id)
                    && StatisticsQuery(start: action.start, end: action.end)
                        .contains(accountID: account, date: startedAt)
            }) {
                accumulators[identity] = nil
                affected = true
            }
        }
        if affected { resetMonotonicFence[account] = monotonicNow() }
    }

    private static func isValid(_ slice: ListeningSlice) -> Bool {
        if slice.lineage != nil {
            do {
                try ListeningSegmentCodec.validate(slice)
                return true
            } catch { return false }
        }
        return !slice.accountID.rawValue.isEmpty
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
