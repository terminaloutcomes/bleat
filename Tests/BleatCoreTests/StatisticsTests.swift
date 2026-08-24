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
