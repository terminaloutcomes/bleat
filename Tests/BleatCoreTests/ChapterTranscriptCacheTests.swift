import Foundation
import SwiftData
import XCTest

@testable import BleatCore

final class ChapterTranscriptCacheTests: XCTestCase {
    func testTranscriptUpsertPersistsAndRemainsAccountBookScoped()
        async throws
    {
        let fixture = try ChapterTranscriptCacheFixture()
        let accountA = AccountID(rawValue: "account-a")
        let accountB = AccountID(rawValue: "account-b")
        let bookA = LibraryItemID(rawValue: "book-a")
        let bookB = LibraryItemID(rawValue: "book-b")

        try await fixture.cache.save(
            Self.transcript(chapterID: 9, text: "First version"),
            accountID: accountA,
            itemID: bookA
        )
        try await fixture.cache.save(
            Self.transcript(chapterID: 9, text: "Replacement"),
            accountID: accountA,
            itemID: bookA
        )
        try await fixture.cache.save(
            Self.transcript(chapterID: 9, text: "Other account"),
            accountID: accountB,
            itemID: bookA
        )
        try await fixture.cache.save(
            Self.transcript(chapterID: 9, text: "Other book"),
            accountID: accountA,
            itemID: bookB
        )

        let relaunched = ChapterTranscriptCache(
            modelContainer: fixture.container
        )
        let transcript = try await relaunched.transcripts(
            accountID: accountA,
            itemID: bookA
        )
        XCTAssertEqual(transcript.count, 1)
        XCTAssertEqual(transcript.first?.segments.first?.text, "Replacement")
    }

    func testTranscriptsSortByChapterTimeline() async throws {
        let fixture = try ChapterTranscriptCacheFixture()
        let accountID = AccountID(rawValue: "account")
        let itemID = LibraryItemID(rawValue: "book")
        try await fixture.cache.save(
            Self.transcript(
                chapterID: 2,
                startMilliseconds: 2_000,
                text: "Second"
            ),
            accountID: accountID,
            itemID: itemID
        )
        try await fixture.cache.save(
            Self.transcript(
                chapterID: 1,
                startMilliseconds: 1_000,
                text: "First"
            ),
            accountID: accountID,
            itemID: itemID
        )

        let transcripts = try await fixture.cache.transcripts(
            accountID: accountID,
            itemID: itemID
        )
        XCTAssertEqual(transcripts.map(\.chapterID), [1, 2])
    }

    func testSearchMatchesEveryTermIgnoringCaseAndOrderAcrossChapters() {
        let transcripts = [
            Self.transcript(
                chapterID: 1,
                text: "The cat sat on the mat"
            ),
            Self.transcript(chapterID: 2, text: "Nothing relevant here"),
            Self.transcript(chapterID: 3, text: "A MAT welcomed another CAT"),
        ]

        let matches = CachedChapterTranscriptSearch.matches(
            query: "  MaT\ncat  ",
            in: transcripts
        )

        XCTAssertEqual(matches.map(\.chapterID), [1, 3])
        XCTAssertEqual(
            matches.map(\.segment.text),
            ["The cat sat on the mat", "A MAT welcomed another CAT"]
        )
        XCTAssertEqual(
            CachedChapterTranscriptSearch.matches(
                query: "cat cat",
                in: transcripts
            ).map(\.chapterID),
            [1, 3]
        )
        XCTAssertEqual(
            CachedChapterTranscriptSearch.matches(
                query: "nothing",
                in: transcripts
            ).map(\.chapterID),
            [2]
        )
        XCTAssertTrue(
            CachedChapterTranscriptSearch.matches(
                query: "cat missing",
                in: transcripts
            ).isEmpty
        )
        XCTAssertTrue(
            CachedChapterTranscriptSearch.matches(
                query: "   ",
                in: transcripts
            ).isEmpty
        )
    }

    func testTaskStatePersistsOutcomeFailureAndElapsedTime() async throws {
        let fixture = try ChapterTranscriptCacheFixture()
        let accountID = AccountID(rawValue: "account")
        let itemID = LibraryItemID(rawValue: "book")
        let startedAt = Date(timeIntervalSince1970: 100)
        let failed = CachedChapterTranscriptionTaskState(
            taskID: UUID(),
            selectedChapterIDs: [1, 3, 5],
            completedChapterIDs: [1],
            currentChapterID: 3,
            outcome: .failed,
            failure: .analyzerInputFailed,
            startedAt: startedAt,
            finishedAt: startedAt.addingTimeInterval(12.345),
            durationMilliseconds: 12_345
        )

        try await fixture.cache.saveTaskState(
            failed,
            accountID: accountID,
            itemID: itemID
        )

        let relaunched = ChapterTranscriptCache(
            modelContainer: fixture.container
        )
        let restored = try await relaunched.taskState(
            accountID: accountID,
            itemID: itemID
        )
        XCTAssertEqual(restored, failed)
    }

    func testTaskStateRejectsInvalidSuccess() async throws {
        let fixture = try ChapterTranscriptCacheFixture()
        let invalid = CachedChapterTranscriptionTaskState(
            taskID: UUID(),
            selectedChapterIDs: [1, 2],
            completedChapterIDs: [1],
            currentChapterID: nil,
            outcome: .succeeded,
            failure: nil,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 101),
            durationMilliseconds: 1_000
        )

        do {
            try await fixture.cache.saveTaskState(
                invalid,
                accountID: AccountID(rawValue: "account"),
                itemID: LibraryItemID(rawValue: "book")
            )
            XCTFail("Expected invalid task state rejection")
        } catch {
            XCTAssertEqual(error, .invalidTaskState)
        }
    }

    func testOlderTaskStateCannotReplaceNewerResult() async throws {
        let fixture = try ChapterTranscriptCacheFixture()
        let accountID = AccountID(rawValue: "account")
        let itemID = LibraryItemID(rawValue: "book")
        let newer = Self.taskState(
            outcome: .succeeded,
            finishedAt: Date(timeIntervalSince1970: 200)
        )
        let older = Self.taskState(
            outcome: .failed,
            finishedAt: Date(timeIntervalSince1970: 150)
        )

        try await fixture.cache.saveTaskState(
            newer,
            accountID: accountID,
            itemID: itemID
        )
        try await fixture.cache.saveTaskState(
            older,
            accountID: accountID,
            itemID: itemID
        )

        let restored = try await fixture.cache.taskState(
            accountID: accountID,
            itemID: itemID
        )
        XCTAssertEqual(restored, newer)
    }

    func testRemovingAccountDeletesOnlyItsTranscripts() async throws {
        let fixture = try ChapterTranscriptCacheFixture()
        let accountA = AccountID(rawValue: "account-a")
        let accountB = AccountID(rawValue: "account-b")
        let itemID = LibraryItemID(rawValue: "book")
        try await fixture.cache.save(
            Self.transcript(chapterID: 1, text: "A"),
            accountID: accountA,
            itemID: itemID
        )
        try await fixture.cache.save(
            Self.transcript(chapterID: 1, text: "B"),
            accountID: accountB,
            itemID: itemID
        )
        try await fixture.cache.saveTaskState(
            Self.taskState(
                outcome: .failed,
                finishedAt: Date(timeIntervalSince1970: 200)
            ),
            accountID: accountA,
            itemID: itemID
        )

        try await fixture.cache.removeAccount(accountA)

        let removed = try await fixture.cache.transcripts(
            accountID: accountA,
            itemID: itemID
        )
        let retained = try await fixture.cache.transcripts(
            accountID: accountB,
            itemID: itemID
        )
        let removedTaskState = try await fixture.cache.taskState(
            accountID: accountA,
            itemID: itemID
        )
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(retained.first?.segments.first?.text, "B")
        XCTAssertNil(removedTaskState)
    }

    func testRemovingBookDeletesTranscriptAndTaskStateOnlyForExactScope()
        async throws
    {
        let fixture = try ChapterTranscriptCacheFixture()
        let accountA = AccountID(rawValue: "account-a")
        let accountB = AccountID(rawValue: "account-b")
        let bookA = LibraryItemID(rawValue: "book-a")
        let bookB = LibraryItemID(rawValue: "book-b")
        let scopes = [
            (accountA, bookA, "deleted"),
            (accountA, bookB, "other book"),
            (accountB, bookA, "other account"),
        ]
        for (accountID, itemID, text) in scopes {
            try await fixture.cache.save(
                Self.transcript(chapterID: 1, text: text),
                accountID: accountID,
                itemID: itemID
            )
            try await fixture.cache.saveTaskState(
                Self.taskState(
                    outcome: .succeeded,
                    finishedAt: Date(timeIntervalSince1970: 200)
                ),
                accountID: accountID,
                itemID: itemID
            )
        }

        let containedBeforeDeletion = try await fixture.cache.containsData(
            accountID: accountA,
            itemID: bookA
        )
        XCTAssertTrue(containedBeforeDeletion)
        try await fixture.cache.removeBook(
            accountID: accountA,
            itemID: bookA
        )

        let relaunched = ChapterTranscriptCache(
            modelContainer: fixture.container
        )
        let containedAfterDeletion = try await relaunched.containsData(
            accountID: accountA,
            itemID: bookA
        )
        let deletedTranscripts = try await relaunched.transcripts(
            accountID: accountA,
            itemID: bookA
        )
        let deletedTaskState = try await relaunched.taskState(
            accountID: accountA,
            itemID: bookA
        )
        let otherBookTranscripts = try await relaunched.transcripts(
            accountID: accountA,
            itemID: bookB
        )
        let otherAccountTranscripts = try await relaunched.transcripts(
            accountID: accountB,
            itemID: bookA
        )
        XCTAssertFalse(containedAfterDeletion)
        XCTAssertTrue(deletedTranscripts.isEmpty)
        XCTAssertNil(deletedTaskState)
        XCTAssertEqual(
            otherBookTranscripts.first?.segments.first?.text,
            "other book"
        )
        XCTAssertEqual(
            otherAccountTranscripts.first?.segments.first?.text,
            "other account"
        )
    }

    func testRejectsInvalidTranscript() async throws {
        let fixture = try ChapterTranscriptCacheFixture()
        let invalid = CachedChapterTranscript(
            chapterID: 1,
            chapterTitle: "Chapter",
            chapterStartMilliseconds: 0,
            chapterEndMilliseconds: 1_000,
            localeIdentifier: "en-AU",
            segments: [
                CachedTranscriptSegment(
                    startMilliseconds: 500,
                    endMilliseconds: 400,
                    text: "Invalid"
                )
            ]
        )

        do {
            try await fixture.cache.save(
                invalid,
                accountID: AccountID(rawValue: "account"),
                itemID: LibraryItemID(rawValue: "book")
            )
            XCTFail("Expected invalid transcript rejection")
        } catch {
            XCTAssertEqual(error, .invalidTranscript)
        }
    }

    private static func transcript(
        chapterID: Int,
        startMilliseconds: Int64 = 1_000,
        text: String
    ) -> CachedChapterTranscript {
        CachedChapterTranscript(
            chapterID: chapterID,
            chapterTitle: "Chapter \(chapterID)",
            chapterStartMilliseconds: startMilliseconds,
            chapterEndMilliseconds: startMilliseconds + 1_000,
            localeIdentifier: "en-AU",
            segments: [
                CachedTranscriptSegment(
                    startMilliseconds: startMilliseconds,
                    endMilliseconds: startMilliseconds + 500,
                    text: text
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static func taskState(
        outcome: CachedChapterTranscriptionTaskOutcome,
        finishedAt: Date
    ) -> CachedChapterTranscriptionTaskState {
        CachedChapterTranscriptionTaskState(
            taskID: UUID(),
            selectedChapterIDs: [1],
            completedChapterIDs: outcome == .succeeded ? [1] : [],
            currentChapterID: outcome == .failed ? 1 : nil,
            outcome: outcome,
            failure: outcome == .failed ? .analyzerInputFailed : nil,
            startedAt: finishedAt.addingTimeInterval(-1),
            finishedAt: finishedAt,
            durationMilliseconds: 1_000
        )
    }
}

private struct ChapterTranscriptCacheFixture {
    let container: ModelContainer
    let cache: ChapterTranscriptCache

    init() throws {
        let schema = Schema([
            CachedChapterTranscriptRecord.self,
            CachedChapterTranscriptionTaskRecord.self,
        ])
        container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                )
            ]
        )
        cache = ChapterTranscriptCache(modelContainer: container)
    }
}
