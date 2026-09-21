import Foundation
import SwiftData

@Model
public final class StatisticsSnapshotRecord {
    var accountID: String?
    var payload: Data
    var start: Date?
    var end: Date?
    var incrementalPayload: Data?

    init(accountID: String?, start: Date?, end: Date?, payload: Data) {
        self.accountID = accountID
        self.payload = payload
        self.start = start
        self.end = end
    }
}

public struct StatisticsSnapshot: Codable, Equatable, Sendable {
    public let summary: StatisticsSummary
    public let exploration: StatisticsExploration

    public init(summary: StatisticsSummary, exploration: StatisticsExploration)
    {
        self.summary = summary
        self.exploration = exploration
    }
}

public struct StatisticsPresentation: Sendable {
    public let snapshot: StatisticsSnapshot
    public let liveSlice: ListeningSlice?

    public init(snapshot: StatisticsSnapshot, liveSlice: ListeningSlice?) {
        self.snapshot = snapshot
        self.liveSlice = liveSlice
    }
}

struct StatisticsAccounting: Codable, Sendable {
    let accountID: AccountID
    let sessionID: PlaybackSessionID
    let confirmed: Double
    let uncertain: Double
    let updatedAt: Date
}

/// Shared reconciliation for Lifetime, ranges, charts and drill-downs.
/// Remote history has a session date, not a per-day or rate-aware timeline.
enum StatisticsAggregation {
    struct SessionKey: Codable, Hashable {
        let account: AccountID
        let session: PlaybackSessionID
    }

    struct BookKey: Codable, Hashable {
        let account: AccountID
        let item: LibraryItemID
        // Length framing keeps opaque identifiers collision-free in UI identity.
        var id: String {
            "\(account.rawValue.utf8.count):\(account.rawValue)\(item.rawValue)"
        }
    }

    struct ChapterKey: Codable, Hashable {
        let book: BookKey
        let chapter: Int
        let title: String?
        let start: Double?
        let end: Double?
    }

    static func snapshot(
        slices: [ListeningSlice], completions: [CompletionMilestone],
        remote: [RemoteListeningSession], accounting: [StatisticsAccounting],
        query: StatisticsQuery
    ) -> StatisticsSnapshot {
        var state = State(query: query)
        state.append(slices)
        state.completions = completions
        for value in remote { state.upsert(value) }
        for value in accounting { state.setAccounting(value) }
        return state.snapshot()
    }

    struct LocalSession: Codable {
        var item: LibraryItemID
        var title: String
        var author: String
        var startedAt: Date
        var endedAt: Date
        var realSeconds = 0.0
        var audiobookSeconds = 0.0
        var days: [Date: Double] = [:]
    }

    struct Chapter: Codable {
        var heard = 0.0
        var reachesEnd = false
        var intervals: [ClosedRange<Double>] = []

        mutating func append(_ slice: ListeningSlice, key: ChapterKey) {
            heard += slice.audiobookSeconds
            guard let start = key.start, let end = key.end, end > start else {
                return
            }
            reachesEnd = reachesEnd || slice.endPosition >= end - 0.5
            let lower = max(start, slice.startPosition)
            let upper = max(lower, min(end, slice.endPosition))
            var merged: [ClosedRange<Double>] = []
            for interval in (intervals + [lower...upper]).sorted(by: {
                $0.lowerBound < $1.lowerBound
            }) {
                if let last = merged.last,
                    interval.lowerBound <= last.upperBound
                {
                    merged[merged.count - 1] =
                        last
                        .lowerBound...max(last.upperBound, interval.upperBound)
                } else {
                    merged.append(interval)
                }
            }
            intervals = merged
        }
    }

    /// Retains sufficient statistics, never the original slice ledger. Playback
    /// appends update only their session, book and chapter contributions.
    struct State: Codable {
        let query: StatisticsQuery
        var aliases: [PlaybackSessionID: PlaybackSessionID] = [:]
        var fullLocal: [SessionKey: Double] = [:]
        var localBySession: [SessionKey: LocalSession] = [:]
        var localBookReal: [BookKey: Double] = [:]
        var localBookAudio: [BookKey: Double] = [:]
        var chapters: [ChapterKey: Chapter] = [:]
        var remoteBySession: [SessionKey: RemoteListeningSession] = [:]
        var accountingBySession: [SessionKey: StatisticsAccounting] = [:]
        var completions: [CompletionMilestone] = []

        mutating func key(_ account: AccountID, _ session: PlaybackSessionID)
            -> SessionKey
        {
            let canonical =
                aliases[session]
                ?? StatisticsArchive.portableSessionID(sessionID: session)
            aliases[session] = canonical
            return SessionKey(account: account, session: canonical)
        }

        mutating func append(_ slices: [ListeningSlice]) {
            for slice in slices {
                if let scope = query.accountID, scope != slice.accountID {
                    continue
                }
                let identity = key(slice.accountID, slice.sessionID)
                fullLocal[identity, default: 0] += slice.realSeconds
                guard
                    query.contains(
                        accountID: slice.accountID, date: slice.startedAt)
                else { continue }
                var local =
                    localBySession[identity]
                    ?? LocalSession(
                        item: slice.itemID, title: slice.title,
                        author: slice.author,
                        startedAt: slice.startedAt, endedAt: slice.endedAt)
                local.startedAt = min(local.startedAt, slice.startedAt)
                local.endedAt = max(local.endedAt, slice.endedAt)
                local.realSeconds += slice.realSeconds
                local.audiobookSeconds += slice.audiobookSeconds
                local.days[
                    StatisticsQuery.reportingCalendar.startOfDay(
                        for: slice.startedAt), default: 0] += slice.realSeconds
                localBySession[identity] = local
                let book = BookKey(account: slice.accountID, item: slice.itemID)
                localBookReal[book, default: 0] += slice.realSeconds
                localBookAudio[book, default: 0] += slice.audiobookSeconds
                if let chapterID = slice.chapterID {
                    let chapter = ChapterKey(
                        book: book, chapter: chapterID,
                        title: slice.chapterTitle, start: slice.chapterStart,
                        end: slice.chapterEnd)
                    chapters[chapter, default: Chapter()].append(
                        slice, key: chapter)
                }
            }
        }

        mutating func upsert(_ value: RemoteListeningSession) {
            if let scope = query.accountID, scope != value.accountID { return }
            let identity = key(value.accountID, value.id)
            if let old = remoteBySession[identity],
                old.updatedAt >= value.updatedAt
            {
                return
            }
            remoteBySession[identity] =
                query.contains(
                    accountID: value.accountID, date: value.startedAt)
                ? value : nil
        }

        mutating func setAccounting(_ value: StatisticsAccounting) {
            let identity = key(value.accountID, value.sessionID)
            accountingBySession[identity] = value
        }

        func snapshot() -> StatisticsSnapshot {
            let selectedRemote = Array(remoteBySession.values)
            var days: [Date: StatisticsTimeBounds] = [:]
            var bookBounds: [BookKey: StatisticsTimeBounds] = [:]
            var bookMetadata: [BookKey: (String, String)] = [:]
            var sessions: [StatisticsRecentSession] = []
            var total = StatisticsTimeBounds(lower: 0, upper: 0)
            func add(_ a: StatisticsTimeBounds, _ b: StatisticsTimeBounds)
                -> StatisticsTimeBounds
            {
                StatisticsTimeBounds(
                    lower: a.lower + b.lower, upper: a.upper + b.upper)
            }
            let zero = StatisticsTimeBounds(lower: 0, upper: 0)
            for identity in Set(localBySession.keys).union(remoteBySession.keys)
            {
                let local = localBySession[identity]
                let remote = remoteBySession[identity]
                guard let item = remote?.itemID ?? local?.item,
                    let date = remote?.startedAt ?? local?.startedAt
                else { continue }
                let book = BookKey(account: identity.account, item: item)
                let localTime = local?.realSeconds ?? 0
                let record = accountingBySession[identity]
                let confirmed = min(
                    fullLocal[identity] ?? 0, record?.confirmed ?? 0)
                let uncertain = min(
                    max(0, (fullLocal[identity] ?? 0) - confirmed),
                    record?.uncertain ?? 0)
                let selectedConfirmed = min(localTime, confirmed)
                let selectedUncertain = min(
                    max(0, localTime - selectedConfirmed), uncertain)
                let pending = max(
                    0, localTime - selectedConfirmed - selectedUncertain)
                let lower: Double
                let upper: Double
                if let remote {
                    if record == nil {
                        // Portable/CloudKit history can lack this device's sync
                        // bookkeeping. Never count a matching session twice or
                        // invent certainty until a newer snapshot covers it.
                        let coversLocal =
                            remote.realSeconds >= localTime
                            && remote.updatedAt
                                >= (local?.endedAt ?? .distantPast)
                        lower = max(remote.realSeconds, localTime)
                        upper =
                            coversLocal ? lower : remote.realSeconds + localTime
                    } else {
                        let resolved =
                            record.map {
                                remote.updatedAt > $0.updatedAt
                                    && remote.realSeconds >= confirmed
                                        + uncertain
                            } ?? false
                        lower =
                            max(remote.realSeconds, selectedConfirmed) + pending
                        upper = lower + (resolved ? 0 : selectedUncertain)
                    }
                } else {
                    lower = localTime - selectedUncertain
                    upper = localTime
                }
                let bounds = StatisticsTimeBounds(lower: lower, upper: upper)
                total = add(total, bounds)
                bookBounds[book] = add(bookBounds[book] ?? zero, bounds)
                bookMetadata[book] = (
                    remote?.title ?? local?.title ?? "Untitled",
                    remote?.author ?? local?.author ?? ""
                )
                // Remote sessions use their authoritative stored date. Local-only
                // sessions retain the ledger's midnight splits.
                if remote != nil {
                    let day = StatisticsQuery.reportingCalendar.startOfDay(
                        for: date)
                    days[day] = add(days[day] ?? zero, bounds)
                } else {
                    for (day, seconds) in local?.days ?? [:] {
                        let fraction =
                            localTime > 0 ? seconds / localTime : 0
                        days[day] = add(
                            days[day] ?? zero,
                            StatisticsTimeBounds(
                                lower: lower * fraction, upper: upper * fraction
                            ))
                    }
                }
                sessions.append(
                    StatisticsRecentSession(
                        id:
                            "\(identity.account.rawValue.utf8.count):\(identity.account.rawValue)\(identity.session.rawValue)",
                        title: bookMetadata[book]?.0 ?? "Untitled",
                        startedAt: date,
                        realSeconds: lower,
                        coverage: lower != upper
                            ? .approximate
                            : (remote == nil ? .thisApp : .allDevices),
                        bounds: bounds,
                        audiobookSeconds: local?.audiobookSeconds))
            }
            var startedByBook: [BookKey: Int] = [:]
            var completedByBook: [BookKey: Int] = [:]
            for (chapter, values) in chapters {
                let length = (chapter.end ?? 0) - (chapter.start ?? 0)
                if values.heard >= (length > 0 ? min(10, length) : 10) {
                    startedByBook[chapter.book, default: 0] += 1
                }
                guard let end = chapter.end, length > 0 else { continue }
                let covered = values.intervals.reduce(0.0) {
                    $0 + max(0, min(end, $1.upperBound) - $1.lowerBound)
                }
                if covered >= length * 0.9 && values.reachesEnd {
                    completedByBook[chapter.book, default: 0] += 1
                }
            }
            var finished: [BookKey: CompletionMilestone] = [:]
            for value in completions
            where query.contains(
                accountID: value.accountID, date: value.completedAt)
            {
                let book = BookKey(account: value.accountID, item: value.itemID)
                if let old = finished[book],
                    old.completedAt <= value.completedAt
                {
                    continue
                }
                finished[book] = value
                if bookMetadata[book] == nil {
                    bookMetadata[book] = (value.title, value.author)
                }
            }
            let remoteBooks = Set(
                selectedRemote.map {
                    BookKey(account: $0.accountID, item: $0.itemID)
                })
            let books: [StatisticsBook] = bookMetadata.map {
                book, metadata -> StatisticsBook in
                let bounds = bookBounds[book] ?? zero
                let hasRemote = remoteBooks.contains(book)
                let audiobookTime = localBookAudio[book] ?? 0
                let coverage: StatisticsCoverage =
                    bounds.lower != bounds.upper
                    ? .approximate : (hasRemote ? .allDevices : .thisApp)
                return StatisticsBook(
                    id: book.id, title: metadata.0, author: metadata.1,
                    realSeconds: bounds.lower, audiobookSeconds: audiobookTime,
                    bounds: bounds, coverage: coverage,
                    chaptersStarted: startedByBook[book] ?? 0,
                    chaptersCompleted: completedByBook[book] ?? 0,
                    completedAt: finished[book]?.completedAt,
                    finishedRuntime: finished[book]?.duration ?? 0)
            }.sorted {
                $0.realSeconds == $1.realSeconds
                    ? $0.id < $1.id : $0.realSeconds > $1.realSeconds
            }
            let localReal = localBookReal.values.reduce(0, +)
            let audiobook = localBookAudio.values.reduce(0, +)
            return StatisticsSnapshot(
                summary: StatisticsSummary(
                    realSeconds: total.lower, localRealSeconds: localReal,
                    audiobookSeconds: audiobook,
                    finishedRuntime: finished.values.reduce(0) {
                        $0 + $1.duration
                    },
                    booksStarted: bookBounds.filter { book, bounds in
                        max(
                            bounds.lower,
                            localBookReal[book] ?? 0) >= 30
                    }.count, booksCompleted: finished.count,
                    chaptersStarted: startedByBook.values.reduce(0, +),
                    chaptersCompleted: completedByBook.values.reduce(0, +),
                    sessions: sessions.count,
                    effectiveAverageSpeed: localReal > 0
                        ? audiobook / localReal : nil,
                    realTimeCoverage: total.lower != total.upper
                        ? .approximate
                        : (selectedRemote.isEmpty ? .thisApp : .allDevices),
                    allDeviceBounds: total),
                exploration: StatisticsExploration(
                    days: days.map {
                        StatisticsDay(
                            date: $0.key, realSeconds: $0.value.lower,
                            upperSeconds: $0.value.upper)
                    }.sorted { $0.date < $1.date },
                    books: books,
                    recentSessions: Array(
                        sessions.sorted {
                            $0.startedAt == $1.startedAt
                                ? $0.id < $1.id : $0.startedAt > $1.startedAt
                        }.prefix(30))))
        }
    }

}
