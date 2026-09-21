import Foundation
import SwiftData

@Model
public final class StatisticsSnapshotRecord {
    var accountID: String?
    var payload: Data
    var start: Date?
    var end: Date?

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

struct StatisticsAccounting: Sendable {
    let accountID: AccountID
    let sessionID: PlaybackSessionID
    let confirmed: Double
    let uncertain: Double
    let updatedAt: Date
}

/// Shared reconciliation for Lifetime, ranges, charts and drill-downs.
/// Remote history has a session date, not a per-day or rate-aware timeline.
enum StatisticsAggregation {
    struct SessionKey: Hashable {
        let account: AccountID
        let session: PlaybackSessionID
    }

    struct BookKey: Hashable {
        let account: AccountID
        let item: LibraryItemID
        // Length framing keeps opaque identifiers collision-free in UI identity.
        var id: String {
            "\(account.rawValue.utf8.count):\(account.rawValue)\(item.rawValue)"
        }
    }

    struct ChapterKey: Hashable {
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
        // Hash each distinct session only once, even in a large ledger.
        var aliases: [PlaybackSessionID: PlaybackSessionID] = [:]
        func key(_ account: AccountID, _ session: PlaybackSessionID)
            -> SessionKey
        {
            let canonical: PlaybackSessionID
            if let known = aliases[session] {
                canonical = known
            } else {
                canonical = StatisticsArchive.portableSessionID(
                    sessionID: session)
                aliases[session] = canonical
            }
            return SessionKey(account: account, session: canonical)
        }
        let selected = slices.filter {
            query.contains(accountID: $0.accountID, date: $0.startedAt)
        }
        let selectedRemote = remote.filter {
            query.contains(accountID: $0.accountID, date: $0.startedAt)
        }
        let localBySession = Dictionary(grouping: selected) {
            key($0.accountID, $0.sessionID)
        }
        var fullLocal: [SessionKey: Double] = [:]
        for slice in slices {
            fullLocal[key(slice.accountID, slice.sessionID), default: 0] +=
                slice.realSeconds
        }
        var accountingBySession: [SessionKey: StatisticsAccounting] = [:]
        for value in accounting {
            accountingBySession[key(value.accountID, value.sessionID)] = value
        }
        var remoteBySession: [SessionKey: RemoteListeningSession] = [:]
        for value in selectedRemote {
            let identity = key(value.accountID, value.id)
            if let old = remoteBySession[identity],
                old.updatedAt >= value.updatedAt
            {
                continue
            }
            remoteBySession[identity] = value
        }
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
        for identity in Set(localBySession.keys).union(remoteBySession.keys) {
            let local = localBySession[identity] ?? []
            let remote = remoteBySession[identity]
            guard let item = remote?.itemID ?? local.first?.itemID,
                let date = remote?.startedAt ?? local.map(\.startedAt).min()
            else { continue }
            let book = BookKey(account: identity.account, item: item)
            let localTime = local.reduce(0) { $0 + $1.realSeconds }
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
                            >= (local.map(\.endedAt).max() ?? .distantPast)
                    lower = max(remote.realSeconds, localTime)
                    upper = coversLocal ? lower : remote.realSeconds + localTime
                } else {
                    let resolved =
                        record.map {
                            remote.updatedAt > $0.updatedAt
                                && remote.realSeconds >= confirmed + uncertain
                        } ?? false
                    lower = max(remote.realSeconds, selectedConfirmed) + pending
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
                remote?.title ?? local.first?.title ?? "Untitled",
                remote?.author ?? local.first?.author ?? ""
            )
            // Remote sessions use their authoritative stored date. Local-only
            // sessions retain the ledger's midnight splits.
            if remote != nil {
                let day = StatisticsQuery.reportingCalendar.startOfDay(
                    for: date)
                days[day] = add(days[day] ?? zero, bounds)
            } else {
                for slice in local {
                    let day = StatisticsQuery.reportingCalendar.startOfDay(
                        for: slice.startedAt)
                    let fraction =
                        localTime > 0 ? slice.realSeconds / localTime : 0
                    days[day] = add(
                        days[day] ?? zero,
                        StatisticsTimeBounds(
                            lower: lower * fraction, upper: upper * fraction))
                }
            }
            sessions.append(
                StatisticsRecentSession(
                    id:
                        "\(identity.account.rawValue.utf8.count):\(identity.account.rawValue)\(identity.session.rawValue)",
                    title: bookMetadata[book]?.0 ?? "Untitled", startedAt: date,
                    realSeconds: lower,
                    coverage: lower != upper
                        ? .approximate
                        : (remote == nil ? .thisApp : .allDevices),
                    bounds: bounds,
                    audiobookSeconds: local.isEmpty
                        ? nil : local.reduce(0) { $0 + $1.audiobookSeconds }))
        }
        let localBooks = Dictionary(grouping: selected) {
            BookKey(account: $0.accountID, item: $0.itemID)
        }
        let chapters = Dictionary(
            grouping: selected.filter { $0.chapterID != nil }
        ) {
            ChapterKey(
                book: BookKey(account: $0.accountID, item: $0.itemID),
                chapter: $0.chapterID ?? 0,
                title: $0.chapterTitle, start: $0.chapterStart,
                end: $0.chapterEnd)
        }
        var startedByBook: [BookKey: Int] = [:]
        var completedByBook: [BookKey: Int] = [:]
        for (chapter, values) in chapters {
            let heard = values.reduce(0) { $0 + $1.audiobookSeconds }
            let length = (chapter.end ?? 0) - (chapter.start ?? 0)
            if heard >= (length > 0 ? min(10, length) : 10) {
                startedByBook[chapter.book, default: 0] += 1
            }
            guard let start = chapter.start, let end = chapter.end, end > start
            else { continue }
            let intervals = values.map {
                max(
                    start, $0.startPosition)...max(
                        max(start, $0.startPosition), min(end, $0.endPosition))
            }
            .sorted { $0.lowerBound < $1.lowerBound }
            var covered = 0.0
            var previousEnd = start
            for interval in intervals {
                covered += max(
                    0,
                    min(end, interval.upperBound)
                        - max(previousEnd, interval.lowerBound))
                previousEnd = max(previousEnd, interval.upperBound)
            }
            if covered >= length * 0.9
                && values.contains(where: { $0.endPosition >= end - 0.5 })
            {
                completedByBook[chapter.book, default: 0] += 1
            }
        }
        var finished: [BookKey: CompletionMilestone] = [:]
        for value in completions
        where query.contains(
            accountID: value.accountID, date: value.completedAt)
        {
            let book = BookKey(account: value.accountID, item: value.itemID)
            if let old = finished[book], old.completedAt <= value.completedAt {
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
            let local = localBooks[book] ?? []
            let bounds = bookBounds[book] ?? zero
            let hasRemote = remoteBooks.contains(book)
            let audiobookTime: Double = local.reduce(0.0) {
                $0 + $1.audiobookSeconds
            }
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
        let localReal = selected.reduce(0) { $0 + $1.realSeconds }
        let audiobook = selected.reduce(0) { $0 + $1.audiobookSeconds }
        return StatisticsSnapshot(
            summary: StatisticsSummary(
                realSeconds: total.lower, localRealSeconds: localReal,
                audiobookSeconds: audiobook,
                finishedRuntime: finished.values.reduce(0) { $0 + $1.duration },
                booksStarted: bookBounds.filter { book, bounds in
                    max(
                        bounds.lower,
                        localBooks[book]?.reduce(0.0) { $0 + $1.realSeconds }
                            ?? 0) >= 30
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
