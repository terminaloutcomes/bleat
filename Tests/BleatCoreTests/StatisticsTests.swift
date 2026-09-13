import Foundation
import SwiftData
import XCTest

@testable import BleatCore

final class StatisticsTests: XCTestCase {
    func testAccumulatorCountsAudiblePlaybackAndRejectsSeekTime()
        throws
    {
        var accumulator = ListeningAccumulator()
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            try accumulator.ingest(
                sample(
                    observedAt: start,
                    monotonicTime: 10,
                    position: 20
                )
            ),
            []
        )
        let slices = try accumulator.ingest(
            sample(
                observedAt: start.addingTimeInterval(6),
                monotonicTime: 16,
                position: 29
            )
        )
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].realSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(slices[0].audiobookSeconds, 9, accuracy: 0.001)

        _ = try accumulator.ingest(
            sample(
                observedAt: start.addingTimeInterval(7),
                monotonicTime: 17,
                position: 200,
                generation: 2
            )
        )
        XCTAssertTrue(accumulator.finish().isEmpty)
    }

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
        XCTAssertEqual(summary.realSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(summary.booksCompleted, 1)
        XCTAssertEqual(summary.finishedRuntime, 3_600, accuracy: 0.001)

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
        XCTAssertEqual(pending, 6, accuracy: 0.001)
        try await repository.confirmSync(
            accountID: accountID,
            sessionID: sessionID,
            realSeconds: pending
        )
        let remaining = try await repository.pendingRealSeconds(
            accountID: accountID,
            sessionID: sessionID
        )
        XCTAssertEqual(remaining, 0, accuracy: 0.001)
    }

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

        XCTAssertEqual(summary.sessions, 2)
        XCTAssertEqual(summary.realSeconds, 12, accuracy: 0.001)
    }

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
        try await repository.importArchive(StatisticsArchive(
            slices: [slice], completions: [], remoteSessions: []
        ))
        try await repository.confirmSync(
            accountID: accountID, sessionID: sessionID, realSeconds: 4
        )
        try await repository.markSyncUncertain(
            accountID: accountID, sessionID: sessionID, realSeconds: 2
        )
        let uncertain = try await repository.summary()
        XCTAssertEqual(uncertain.localRealSeconds, 6)
        XCTAssertEqual(uncertain.allDeviceBounds.lower, 4)
        XCTAssertEqual(uncertain.allDeviceBounds.upper, 6)
        XCTAssertEqual(uncertain.realTimeCoverage, .approximate)

        try await repository.upsertRemoteSessions([
            RemoteListeningSession(
                id: sessionID, accountID: accountID, itemID: itemID,
                startedAt: start, updatedAt: Date().addingTimeInterval(60),
                realSeconds: 6, currentTime: 6, duration: 100,
                title: "Example", author: "Reader"
            )
        ])
        let reconciled = try await repository.summary()
        XCTAssertEqual(reconciled.allDeviceBounds.lower, 6)
        XCTAssertEqual(reconciled.allDeviceBounds.upper, 6)
    }

    func testInvalidArchiveLeavesLedgerUnchanged() async throws {
        let repository = try repository()
        let invalid = RemoteListeningSession(
            id: sessionID, accountID: accountID, itemID: itemID,
            startedAt: Date(), updatedAt: Date(),
            realSeconds: -1, currentTime: 0, duration: 100,
            title: "Example", author: "Reader"
        )
        do {
            try await repository.importArchive(StatisticsArchive(
                slices: [], completions: [], remoteSessions: [invalid]
            ))
            XCTFail("Invalid archive should fail")
        } catch let error {
            XCTAssertEqual(error, .invalidArchive)
        }
        let archive = try await repository.archive()
        XCTAssertTrue(archive.remoteSessions.isEmpty)
    }

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
        XCTAssertFalse(String(decoding: json, as: UTF8.self)
            .contains(rawSession.rawValue))
        XCTAssertTrue(portable.remoteSessions[0].id.rawValue
            .hasPrefix("portable:"))
        try await repository.importArchive(portable)
        try await repository.importArchive(portable)
        let result = try await repository.archive()
        XCTAssertEqual(result.remoteSessions.count, 1)
        XCTAssertEqual(result.remoteSessions.first?.id, rawSession)

        let cleanRepository = try self.repository()
        try await cleanRepository.importArchive(portable)
        try await cleanRepository.upsertRemoteSessions([remote])
        let cleanArchive = try await cleanRepository.archive()
        XCTAssertEqual(cleanArchive.remoteSessions.count, 1)
        let cleanSummary = try await cleanRepository.summary()
        XCTAssertEqual(cleanSummary.realSeconds, 10)
    }

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
        try await repository.importArchive(StatisticsArchive(
            slices: slices, completions: [], remoteSessions: []
        ))
        for session in [sessionID, otherSession] {
            try await repository.confirmSync(
                accountID: accountID, sessionID: session,
                realSeconds: 10
            )
        }
        try await repository.reset(query: StatisticsQuery(
            accountID: accountID, start: early,
            end: early.addingTimeInterval(86_400)
        ))
        let pending = try await repository.pendingRealSeconds(
            accountID: accountID, sessionID: otherSession
        )
        XCTAssertEqual(pending, 0)
        let retained = try await repository.archive()
        XCTAssertEqual(retained.slices.count, 1)
    }

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
        try await repository.importArchive(StatisticsArchive(
            slices: slices, completions: [], remoteSessions: []
        ))
        try await repository.confirmSync(
            accountID: accountID, sessionID: sessionID,
            realSeconds: 10
        )
        do {
            try await repository.reset(query: StatisticsQuery(
                accountID: accountID, start: early, end: later
            ))
            XCTFail("Expected an ambiguous split-session reset to be rejected")
        } catch let error {
            XCTAssertEqual(error, .partialSessionResetRequiresFullSession)
        }
        let pending = try await repository.pendingRealSeconds(
            accountID: accountID, sessionID: sessionID
        )
        XCTAssertEqual(pending, 10)
        let archive = try await repository.archive()
        XCTAssertEqual(archive.slices.count, 2)
    }

    func testRangeResetRejectsMixedConfirmedAndUncertainSplitSession()
        async throws {
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
        try await repository.importArchive(StatisticsArchive(
            slices: slices, completions: [], remoteSessions: []
        ))
        try await repository.markSyncUncertain(
            accountID: accountID, sessionID: sessionID, realSeconds: 10
        )
        try await repository.confirmSync(
            accountID: accountID, sessionID: sessionID, realSeconds: 10
        )
        do {
            try await repository.reset(query: StatisticsQuery(
                accountID: accountID, start: later,
                end: later.addingTimeInterval(86_400)
            ))
            XCTFail("Expected an ambiguous split-session reset to be rejected")
        } catch let error {
            XCTAssertEqual(error, .partialSessionResetRequiresFullSession)
        }
        let archive = try await repository.archive()
        XCTAssertEqual(archive.slices.count, 2)
    }

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
        try await repository.importArchive(StatisticsArchive(
            slices: slices, completions: [], remoteSessions: []
        ))
        try await repository.confirmSync(
            accountID: accountID, sessionID: sessionID, realSeconds: 10
        )
        do {
            try await repository.reset(query: StatisticsQuery(
                accountID: accountID, start: later,
                end: later.addingTimeInterval(86_400)
            ))
            XCTFail("Expected a split-session reset to be rejected")
        } catch let error {
            XCTAssertEqual(error, .partialSessionResetRequiresFullSession)
        }
        let archive = try await repository.archive()
        let pending = try await repository.pendingRealSeconds(
            accountID: accountID, sessionID: sessionID
        )
        XCTAssertEqual(archive.slices.count, 2)
        XCTAssertEqual(pending, 10)
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
