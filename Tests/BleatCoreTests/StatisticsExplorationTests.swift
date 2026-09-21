import Foundation
import SwiftData
import Testing

@testable import BleatCore

@Suite(.serialized)
struct StatisticsExplorationTests {
    private let account = AccountID(rawValue: "statistics-account")
    private let item = LibraryItemID(rawValue: "statistics-book")
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test
    func importedHistoryAppearsInChartBookAndSessionWithoutInventingRate()
        async throws
    {
        let repository = try repository()
        let remote = session(realSeconds: 90)
        try await repository.upsertRemoteSessions([remote])
        let result = try await repository.snapshot()
        #expect(result.summary.booksStarted == 1)
        #expect(result.exploration.days.reduce(0) { $0 + $1.realSeconds } == 90)
        #expect(result.exploration.books.first?.realSeconds == 90)
        #expect(result.exploration.books.first?.coverage == .allDevices)
        #expect(result.exploration.books.first?.chaptersCompleted == 0)
        #expect(
            result.exploration.recentSessions.first?.audiobookSeconds == nil)
        #expect(result.summary.effectiveAverageSpeed == nil)
    }

    @Test
    func portableSessionsReconcileAcrossRelaunchAndPreserveNewerObservedTime()
        async throws
    {
        let container = try container()
        let repository = StatisticsRepository(modelContainer: container)
        let slice = slice(index: 0)
        let remote = session(realSeconds: 10)
        let archive = StatisticsArchive(
            slices: [slice], completions: [], remoteSessions: [remote]
        ).portableRedacted()
        try await repository.importArchive(archive)
        let first = try await repository.snapshot()
        #expect(first.summary.realSeconds == 10)
        let reopened = StatisticsRepository(modelContainer: container)
        try await reopened.importArchive(archive)
        try await reopened.upsertRemoteSessions([remote])
        let repeated = try await reopened.snapshot()
        #expect(repeated == first)
        try await reopened.upsertRemoteSessions([session(realSeconds: 5)])
        #expect(try await reopened.summary().realSeconds == 10)
        #expect(try await reopened.archive().slices.count == 1)
    }

    @Test
    func rangeAndAccountScopesDoNotCollideAndCacheInvalidatesOnReset()
        async throws
    {
        let repository = try repository()
        let other = AccountID(rawValue: "other-account")
        try await repository.importArchive(
            StatisticsArchive(
                slices: [
                    slice(index: 0), slice(index: 1).reidentified(as: other),
                ],
                completions: [], remoteSessions: []))
        #expect(try await repository.summary().localRealSeconds == 10)
        let query = StatisticsQuery(
            accountID: account, start: date, end: date.addingTimeInterval(5))
        #expect(
            try await repository.snapshot(query: query).summary.localRealSeconds
                == 5)
        try await repository.reset(query: query)
        #expect(try await repository.summary().localRealSeconds == 5)
        #expect(
            try await repository.snapshot(query: query).summary.localRealSeconds
                == 0)
        #expect(
            try await repository.summary(
                query: StatisticsQuery(accountID: other)
            ).localRealSeconds == 5)
    }

    @Test
    func repeatedChapterSegmentsDoNotCompleteUnheardTimeline() {
        let repeated = (0..<20).map { _ in
            slice(index: 0, chapterStart: 0, chapterEnd: 100, startPosition: 95)
        }
        let result = StatisticsAggregation.snapshot(
            slices: repeated, completions: [], remote: [], accounting: [],
            query: StatisticsQuery())
        #expect(result.summary.chaptersStarted == 1)
        #expect(result.summary.chaptersCompleted == 0)
        #expect(result.exploration.books.first?.chaptersCompleted == 0)
    }

    @Test
    func duplicateCompletionEventsCountOneHistoricalRuntime() {
        let completions = [0.0, 100.0].map { offset in
            CompletionMilestone(
                accountID: account, itemID: item,
                completedAt: date.addingTimeInterval(offset),
                duration: 100, title: "Book", author: "Author",
                evidence: .naturalEnd)
        }
        let result = StatisticsAggregation.snapshot(
            slices: [], completions: completions, remote: [], accounting: [],
            query: StatisticsQuery())
        #expect(result.summary.booksCompleted == 1)
        #expect(result.summary.finishedRuntime == 100)
        #expect(result.exploration.books.first?.completedAt == date)
    }

    @Test
    func presentationKeepsPersistedAndLiveSlicesConsistentAcrossFlush()
        async throws
    {
        let repository = try repository()
        for second in 0...6 {
            try await repository.record(
                StatisticsPlaybackSample(
                    accountID: account, itemID: item,
                    sessionID: PlaybackSessionID(rawValue: "session"),
                    observedAt: date.addingTimeInterval(Double(second)),
                    monotonicTime: Double(second),
                    wholeBookPosition: Double(second), playbackRate: 1,
                    playbackGeneration: 1,
                    isAudibleAndAdvancing: true, chapter: nil, title: "Book",
                    author: "Author", duration: 100))
            let result = try await repository.presentation(
                query: StatisticsQuery())
            #expect(
                result.snapshot.summary.localRealSeconds
                    + (result.liveSlice?.realSeconds ?? 0) == Double(second))
        }
    }

    @Test
    func resetRemovesLiveSliceAndAccountCollisionKeepsBothAccumulators()
        async throws
    {
        let repository = try repository()
        let other = AccountID(rawValue: "other")
        for selectedAccount in [account, other] {
            for second in 0...2 {
                try await repository.record(
                    StatisticsPlaybackSample(
                        accountID: selectedAccount, itemID: item,
                        sessionID: PlaybackSessionID(rawValue: "collision"),
                        observedAt: date.addingTimeInterval(Double(second)),
                        monotonicTime: Double(second),
                        wholeBookPosition: Double(second), playbackRate: 1,
                        playbackGeneration: 1,
                        isAudibleAndAdvancing: true, chapter: nil,
                        title: "Book", author: "Author", duration: 100))
            }
        }
        #expect(
            await repository.uncommittedSlice(accountID: account)?.realSeconds
                == 2)
        #expect(
            await repository.uncommittedSlice(accountID: other)?.realSeconds
                == 2)
        try await repository.reset(query: StatisticsQuery(accountID: account))
        #expect(await repository.uncommittedSlice(accountID: account) == nil)
        #expect(
            await repository.uncommittedSlice(accountID: other)?.realSeconds
                == 2)
        try await repository.finish(
            sessionID: PlaybackSessionID(rawValue: "collision"))
        #expect(try await repository.summary().localRealSeconds == 2)
    }

    @Test
    func dailyBucketsAndCachedRangesRemainUTCWhenDeviceTimeZoneChanges()
        async throws
    {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        NSTimeZone.default = try #require(
            TimeZone(identifier: "Australia/Brisbane"))
        let container = try container()
        let repository = StatisticsRepository(modelContainer: container)
        // 2024-01-01 00:30 UTC is still December 31 in Los Angeles.
        let instant = Date(timeIntervalSince1970: 1_704_069_000)
        let day = Date(timeIntervalSince1970: 1_704_067_200)
        try await repository.upsertRemoteSessions([
            RemoteListeningSession(
                id: PlaybackSessionID(rawValue: "utc-session"),
                accountID: account, itemID: item,
                startedAt: instant, updatedAt: instant, realSeconds: 60,
                currentTime: 60,
                duration: 100, title: "UTC Example", author: "Author")
        ])
        let first = try await repository.snapshot()
        #expect(first.exploration.days.map(\.date) == [day])
        NSTimeZone.default = try #require(
            TimeZone(identifier: "America/Los_Angeles"))
        let reopened = StatisticsRepository(modelContainer: container)
        #expect(try await reopened.snapshot() == first)
        let range = StatisticsQuery(
            accountID: account,
            start: StatisticsQuery.reportingCalendar.startOfDay(for: instant),
            end: StatisticsQuery.reportingCalendar.date(
                byAdding: .day, value: 1, to: day))
        #expect(range.start == day)
        #expect(try await reopened.summary(query: range).realSeconds == 60)
        #expect(
            StatisticsQuery.reportingCalendar.timeZone.secondsFromGMT() == 0)
    }

    #if BLEAT_STATISTICS_PERFORMANCE
        @Test
        func stored250000SlicesArchiveResetAndCachedRelaunch() async throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent("statistics.store")
            let schema = Schema(BleatPersistenceModelCatalog.currentModelTypes)
            let clock = ContinuousClock()
            var opened: ModelContainer? = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url))
            var repository: StatisticsRepository? = StatisticsRepository(
                modelContainer: try #require(opened))
            let slices = (0..<250_000).map { slice(index: $0) }
            let archive = StatisticsArchive(
                slices: slices, completions: [], remoteSessions: [])
            let heartbeat = Task { @MainActor in
                var ticks = 0
                var previous = clock.now
                var largestGap = Duration.zero
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                    let now = clock.now
                    largestGap = max(largestGap, previous.duration(to: now))
                    previous = now
                    ticks += 1
                }
                return (ticks, largestGap)
            }
            let importedAt = clock.now
            try await repository?.importArchive(archive)
            heartbeat.cancel()
            let responsiveness = await heartbeat.value
            print(
                "statistics_performance main_actor_max_gap=\(responsiveness.1), ticks=\(responsiveness.0)"
            )
            #expect(responsiveness.0 > 1)
            #expect(responsiveness.1 < .milliseconds(500))
            print(
                "statistics_performance import_250000=\(importedAt.duration(to: clock.now))"
            )
            let aggregatedAt = clock.now
            let first = try await repository?.snapshot()
            print(
                "statistics_performance aggregate_250000=\(aggregatedAt.duration(to: clock.now))"
            )
            #expect(first?.summary.localRealSeconds == 1_250_000)
            let encodedAt = clock.now
            let encoded = try JSONEncoder().encode(archive.portableRedacted())
            let decoded = try JSONDecoder().decode(
                StatisticsArchive.self, from: encoded)
            print(
                "statistics_performance archive_roundtrip_250000=\(encodedAt.duration(to: clock.now))"
            )
            let repeatedAt = clock.now
            try await repository?.importArchive(decoded)
            print(
                "statistics_performance reimport_250000=\(repeatedAt.duration(to: clock.now))"
            )
            #expect(
                try await repository?.summary().localRealSeconds == 1_250_000)
            repository = nil
            opened = nil
            let reopenedAt = clock.now
            let reopened = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: url))
            let reader = StatisticsRepository(modelContainer: reopened)
            let cached = try await reader.summary()
            let elapsed = reopenedAt.duration(to: clock.now)
            print("statistics_performance cached_relaunch_250000=\(elapsed)")
            #expect(cached.localRealSeconds == 1_250_000)
            #expect(elapsed < .milliseconds(500))
            let resetAt = clock.now
            try await reader.reset(
                query: StatisticsQuery(
                    accountID: account, end: date.addingTimeInterval(500)))
            print(
                "statistics_performance reset_100_of_250000=\(resetAt.duration(to: clock.now))"
            )
            #expect(try await reader.summary().localRealSeconds == 1_249_500)
        }

    #endif

    private func container() throws -> ModelContainer {
        let schema = Schema(BleatPersistenceModelCatalog.currentModelTypes)
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(
                schema: schema, isStoredInMemoryOnly: true))
    }

    private func repository() throws -> StatisticsRepository {
        StatisticsRepository(modelContainer: try container())
    }

    private func session(realSeconds: Double) -> RemoteListeningSession {
        RemoteListeningSession(
            id: PlaybackSessionID(rawValue: "session"), accountID: account,
            itemID: item,
            startedAt: date, updatedAt: date.addingTimeInterval(100),
            realSeconds: realSeconds,
            currentTime: realSeconds, duration: 100, title: "Book",
            author: "Author")
    }

    private func slice(
        index: Int, chapterStart: Double? = nil, chapterEnd: Double? = nil,
        startPosition: Double = 0
    ) -> ListeningSlice {
        ListeningSlice(
            accountID: account, itemID: item,
            sessionID: PlaybackSessionID(
                rawValue: index == 0 ? "session" : "session-\(index / 100)"),
            startedAt: date.addingTimeInterval(Double(index * 5)),
            endedAt: date.addingTimeInterval(Double(index * 5 + 5)),
            startPosition: startPosition, endPosition: startPosition + 5,
            realSeconds: 5, audiobookSeconds: 5, playbackRate: 1,
            chapterID: chapterStart == nil ? nil : 1, chapterTitle: nil,
            chapterStart: chapterStart, chapterEnd: chapterEnd,
            title: "Book", author: "Author", duration: 100)
    }
}
