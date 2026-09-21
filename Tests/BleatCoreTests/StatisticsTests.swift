import Foundation
import SwiftData
import Testing

@testable import BleatCore

@Suite(.serialized)
final class StatisticsTests {
    @Test
    func testAccumulatorCountsAudiblePlaybackAndRejectsSeekTime()
        throws
    {
        var accumulator = ListeningAccumulator()
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(
            try accumulator.ingest(
                sample(
                    observedAt: start,
                    monotonicTime: 10,
                    position: 20
                )
            ) == [])
        let slices = try accumulator.ingest(
            sample(
                observedAt: start.addingTimeInterval(6),
                monotonicTime: 16,
                position: 29
            )
        )
        #expect(slices.count == 1)
        #expect(abs((slices[0].realSeconds) - (6)) <= 0.001)
        #expect(abs((slices[0].audiobookSeconds) - (9)) <= 0.001)

        _ = try accumulator.ingest(
            sample(
                observedAt: start.addingTimeInterval(7),
                monotonicTime: 17,
                position: 200,
                generation: 2
            )
        )
        #expect(accumulator.finish().isEmpty)
    }

    @Test
    func testRepositorySummarizesAndAccountsForDeliveredTime()
        async throws
    {
        let repository = try repository()
        let start = Date(timeIntervalSince1970: 1_000)
        try await repository.record(
            sample(
                observedAt: start,
                monotonicTime: 10,
                position: 0
            )
        )
        try await repository.record(
            sample(
                observedAt: start.addingTimeInterval(30),
                monotonicTime: 40,
                position: 45
            )
        )
        try await repository.finish(sessionID: sessionID)
        try await repository.recordCompletion(
            CompletionMilestone(
                accountID: accountID,
                itemID: itemID,
                completedAt: start.addingTimeInterval(31),
                duration: 3_600,
                title: "Example",
                author: "Reader",
                evidence: .naturalEnd
            )
        )

        let summary = try await repository.summary(
            query: StatisticsQuery(accountID: accountID)
        )
        #expect(abs((summary.realSeconds) - (0)) <= 0.001)
        #expect(summary.booksCompleted == 1)
        #expect(abs((summary.finishedRuntime) - (3_600)) <= 0.001)

        try await repository.record(
            sample(
                observedAt: start.addingTimeInterval(40),
                monotonicTime: 50,
                position: 50
            )
        )
        try await repository.record(
            sample(
                observedAt: start.addingTimeInterval(46),
                monotonicTime: 56,
                position: 59
            )
        )
        try await repository.finish(sessionID: sessionID)
        let pending = try await repository.pendingRealSeconds(
            accountID: accountID,
            sessionID: sessionID
        )
        #expect(abs((pending) - (6)) <= 0.001)
        try await repository.confirmSync(
            accountID: accountID,
            sessionID: sessionID,
            realSeconds: pending
        )
        let remaining = try await repository.pendingRealSeconds(
            accountID: accountID,
            sessionID: sessionID
        )
        #expect(abs((remaining) - (0)) <= 0.001)
    }

    @Test
    func testSessionIdentityIncludesAccount() async throws {
        let repository = try repository()
        let start = Date(timeIntervalSince1970: 2_000)
        let otherAccount = AccountID(rawValue: "other-account")
        let sharedSession = PlaybackSessionID(rawValue: "shared-session")
        let slices = [accountID, otherAccount].map { accountID in
            ListeningSlice(
                accountID: accountID,
                itemID: itemID,
                sessionID: sharedSession,
                startedAt: start,
                endedAt: start.addingTimeInterval(6),
                startPosition: 0,
                endPosition: 6,
                realSeconds: 6,
                audiobookSeconds: 6,
                playbackRate: 1,
                chapterID: nil,
                chapterTitle: nil,
                chapterStart: nil,
                chapterEnd: nil,
                title: "Example",
                author: "Reader",
                duration: 100
            )
        }
        try await repository.importArchive(
            StatisticsArchive(
                slices: slices,
                completions: [],
                remoteSessions: []
            )
        )

        let summary = try await repository.summary()

        #expect(summary.sessions == 2)
        #expect(abs((summary.realSeconds) - (12)) <= 0.001)
    }

    @Test
    func testAmbiguousSyncKeepsExactLocalTimeAndBoundsAllDevices()
        async throws
    {
        let repository = try repository()
        let start = Date(timeIntervalSince1970: 3_000)
        let slice = ListeningSlice(
            accountID: accountID, itemID: itemID, sessionID: sessionID,
            startedAt: start, endedAt: start.addingTimeInterval(6),
            startPosition: 0, endPosition: 6,
            realSeconds: 6, audiobookSeconds: 6, playbackRate: 1,
            chapterID: nil, chapterTitle: nil,
            chapterStart: nil, chapterEnd: nil,
            title: "Example", author: "Reader", duration: 100
        )
        try await repository.importArchive(
            StatisticsArchive(
                slices: [slice], completions: [], remoteSessions: []
            ))
        try await repository.confirmSync(
            accountID: accountID, sessionID: sessionID, realSeconds: 4
        )
        try await repository.markSyncUncertain(
            accountID: accountID, sessionID: sessionID, realSeconds: 2
        )
        let uncertain = try await repository.summary()
        #expect(uncertain.localRealSeconds == 6)
        #expect(uncertain.allDeviceBounds.lower == 4)
        #expect(uncertain.allDeviceBounds.upper == 6)
        #expect(uncertain.realTimeCoverage == .approximate)

        try await repository.upsertRemoteSessions([
            RemoteListeningSession(
                id: sessionID, accountID: accountID, itemID: itemID,
                startedAt: start, updatedAt: Date().addingTimeInterval(60),
                realSeconds: 6, currentTime: 6, duration: 100,
                title: "Example", author: "Reader"
            )
        ])
        let reconciled = try await repository.summary()
        #expect(reconciled.allDeviceBounds.lower == 6)
        #expect(reconciled.allDeviceBounds.upper == 6)
    }

    @Test
    func testInvalidArchiveLeavesLedgerUnchanged() async throws {
        let repository = try repository()
        let invalid = RemoteListeningSession(
            id: sessionID, accountID: accountID, itemID: itemID,
            startedAt: Date(), updatedAt: Date(),
            realSeconds: -1, currentTime: 0, duration: 100,
            title: "Example", author: "Reader"
        )
        do {
            try await repository.importArchive(
                StatisticsArchive(
                    slices: [], completions: [], remoteSessions: [invalid]
                ))
            Issue.record("Invalid archive should fail")
        } catch let error {
            #expect(error == .invalidArchive)
        }
        let archive = try await repository.archive()
        #expect(archive.remoteSessions.isEmpty)
    }

    @Test
    func testPortableArchiveHidesSessionIDsAndReimportDoesNotDuplicate()
        async throws
    {
        let repository = try repository()
        let start = Date(timeIntervalSince1970: 4_000)
        let rawSession = PlaybackSessionID(rawValue: "bearer-like-session")
        let remote = RemoteListeningSession(
            id: rawSession, accountID: accountID, itemID: itemID,
            startedAt: start, updatedAt: start,
            realSeconds: 10, currentTime: 10, duration: 100,
            title: "Example", author: "Reader"
        )
        try await repository.upsertRemoteSessions([remote])
        let portable = try await repository.archive().portableRedacted()
        let json = try JSONEncoder().encode(portable)
        #expect(
            !(String(decoding: json, as: UTF8.self)
                .contains(rawSession.rawValue)))
        #expect(
            portable.remoteSessions[0].id.rawValue
                .hasPrefix("portable:"))
        try await repository.importArchive(portable)
        try await repository.importArchive(portable)
        let result = try await repository.archive()
        #expect(result.remoteSessions.count == 1)
        #expect(result.remoteSessions.first?.id == rawSession)

        let cleanRepository = try self.repository()
        try await cleanRepository.importArchive(portable)
        try await cleanRepository.upsertRemoteSessions([remote])
        let cleanArchive = try await cleanRepository.archive()
        #expect(cleanArchive.remoteSessions.count == 1)
        let cleanSummary = try await cleanRepository.summary()
        #expect(cleanSummary.realSeconds == 10)
    }

    @Test
    func testRangeResetPreservesOtherSessionAccounting() async throws {
        let repository = try repository()
        let early = Date(timeIntervalSince1970: 5_000)
        let later = early.addingTimeInterval(86_400)
        let otherSession = PlaybackSessionID(rawValue: "other-session")
        let slices = [(sessionID, early), (otherSession, later)].map {
            session, date in
            ListeningSlice(
                accountID: accountID, itemID: itemID,
                sessionID: session, startedAt: date,
                endedAt: date.addingTimeInterval(10),
                startPosition: 0, endPosition: 10,
                realSeconds: 10, audiobookSeconds: 10,
                playbackRate: 1, chapterID: nil,
                chapterTitle: nil, chapterStart: nil,
                chapterEnd: nil, title: "Example",
                author: "Reader", duration: 100
            )
        }
        try await repository.importArchive(
            StatisticsArchive(
                slices: slices, completions: [], remoteSessions: []
            ))
        for session in [sessionID, otherSession] {
            try await repository.confirmSync(
                accountID: accountID, sessionID: session,
                realSeconds: 10
            )
        }
        try await repository.reset(
            query: StatisticsQuery(
                accountID: accountID, start: early,
                end: early.addingTimeInterval(86_400)
            ))
        let pending = try await repository.pendingRealSeconds(
            accountID: accountID, sessionID: otherSession
        )
        #expect(pending == 0)
        let retained = try await repository.archive()
        #expect(retained.slices.count == 1)
    }

    @Test
    func testRangeResetRejectsPartiallySyncedSplitSession() async throws {
        let repository = try repository()
        let early = Date(timeIntervalSince1970: 7_000)
        let later = early.addingTimeInterval(86_400)
        let slices = [early, later].map { date in
            ListeningSlice(
                accountID: accountID, itemID: itemID,
                sessionID: sessionID, startedAt: date,
                endedAt: date.addingTimeInterval(10),
                startPosition: 0, endPosition: 10,
                realSeconds: 10, audiobookSeconds: 10,
                playbackRate: 1, chapterID: nil,
                chapterTitle: nil, chapterStart: nil,
                chapterEnd: nil, title: "Example",
                author: "Reader", duration: 100
            )
        }
        try await repository.importArchive(
            StatisticsArchive(
                slices: slices, completions: [], remoteSessions: []
            ))
        try await repository.confirmSync(
            accountID: accountID, sessionID: sessionID,
            realSeconds: 10
        )
        do {
            try await repository.reset(
                query: StatisticsQuery(
                    accountID: accountID, start: early, end: later
                ))
            Issue.record(
                "Expected an ambiguous split-session reset to be rejected")
        } catch let error {
            #expect(error == .partialSessionResetRequiresFullSession)
        }
        let pending = try await repository.pendingRealSeconds(
            accountID: accountID, sessionID: sessionID
        )
        #expect(pending == 10)
        let archive = try await repository.archive()
        #expect(archive.slices.count == 2)
    }

    @Test
    func testRangeResetRejectsMixedConfirmedAndUncertainSplitSession()
        async throws
    {
        let repository = try repository()
        let early = Date(timeIntervalSince1970: 9_000)
        let later = early.addingTimeInterval(86_400)
        let slices = [early, later].map { date in
            ListeningSlice(
                accountID: accountID, itemID: itemID,
                sessionID: sessionID, startedAt: date,
                endedAt: date.addingTimeInterval(10),
                startPosition: 0, endPosition: 10,
                realSeconds: 10, audiobookSeconds: 10,
                playbackRate: 1, chapterID: nil,
                chapterTitle: nil, chapterStart: nil,
                chapterEnd: nil, title: "Example",
                author: "Reader", duration: 100
            )
        }
        try await repository.importArchive(
            StatisticsArchive(
                slices: slices, completions: [], remoteSessions: []
            ))
        try await repository.markSyncUncertain(
            accountID: accountID, sessionID: sessionID, realSeconds: 10
        )
        try await repository.confirmSync(
            accountID: accountID, sessionID: sessionID, realSeconds: 10
        )
        do {
            try await repository.reset(
                query: StatisticsQuery(
                    accountID: accountID, start: later,
                    end: later.addingTimeInterval(86_400)
                ))
            Issue.record(
                "Expected an ambiguous split-session reset to be rejected")
        } catch let error {
            #expect(error == .partialSessionResetRequiresFullSession)
        }
        let archive = try await repository.archive()
        #expect(archive.slices.count == 2)
    }

    @Test
    func testRangeResetCannotResendConfirmedRetainedTime() async throws {
        let repository = try repository()
        let early = Date(timeIntervalSince1970: 11_000)
        let later = early.addingTimeInterval(86_400)
        let slices = [early, later].map { date in
            ListeningSlice(
                accountID: accountID, itemID: itemID,
                sessionID: sessionID, startedAt: date,
                endedAt: date.addingTimeInterval(10),
                startPosition: 0, endPosition: 10,
                realSeconds: 10, audiobookSeconds: 10,
                playbackRate: 1, chapterID: nil,
                chapterTitle: nil, chapterStart: nil,
                chapterEnd: nil, title: "Example",
                author: "Reader", duration: 100
            )
        }
        try await repository.importArchive(
            StatisticsArchive(
                slices: slices, completions: [], remoteSessions: []
            ))
        try await repository.confirmSync(
            accountID: accountID, sessionID: sessionID, realSeconds: 10
        )
        do {
            try await repository.reset(
                query: StatisticsQuery(
                    accountID: accountID, start: later,
                    end: later.addingTimeInterval(86_400)
                ))
            Issue.record("Expected a split-session reset to be rejected")
        } catch let error {
            #expect(error == .partialSessionResetRequiresFullSession)
        }
        let archive = try await repository.archive()
        let pending = try await repository.pendingRealSeconds(
            accountID: accountID, sessionID: sessionID
        )
        #expect(archive.slices.count == 2)
        #expect(pending == 10)
    }

    private let accountID = AccountID(rawValue: "account")
    private let itemID = LibraryItemID(rawValue: "item")
    private let sessionID = PlaybackSessionID(rawValue: "session")

    private func repository() throws -> StatisticsRepository {
        let schema = Schema([
            ListeningSliceRecord.self,
            CompletionMilestoneRecord.self,
            RemoteListeningSessionRecord.self,
            PrivateCloudStatisticsDeletionRecord.self,
            StatisticsSessionAccountingRecord.self,
            StatisticsHistoryImportRecord.self,
            StatisticsSnapshotRecord.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
        return StatisticsRepository(modelContainer: container)
    }

    private func sample(
        observedAt: Date,
        monotonicTime: TimeInterval,
        position: Double,
        generation: UInt64 = 1
    ) -> StatisticsPlaybackSample {
        StatisticsPlaybackSample(
            accountID: accountID,
            itemID: itemID,
            sessionID: sessionID,
            observedAt: observedAt,
            monotonicTime: monotonicTime,
            wholeBookPosition: position,
            playbackRate: 1.5,
            playbackGeneration: generation,
            isAudibleAndAdvancing: true,
            chapter: nil,
            title: "Example",
            author: "Reader",
            duration: 3_600
        )
    }
}
