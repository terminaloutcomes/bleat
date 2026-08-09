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

    func testSearchIsCaseInsensitiveAcrossCachedChapters() {
        let transcripts = [
            Self.transcript(chapterID: 1, text: "The Doomsday Scenario"),
            Self.transcript(chapterID: 2, text: "Nothing relevant here"),
            Self.transcript(chapterID: 3, text: "DOOMSDAY arrives"),
        ]

        let matches = CachedChapterTranscriptSearch.matches(
            query: "doomsday",
            in: transcripts
        )

        XCTAssertEqual(matches.map(\.chapterID), [1, 3])
        XCTAssertEqual(
            matches.map(\.segment.text),
            ["The Doomsday Scenario", "DOOMSDAY arrives"]
        )
        XCTAssertTrue(
            CachedChapterTranscriptSearch.matches(
                query: "   ",
                in: transcripts
            ).isEmpty
        )
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

        try await fixture.cache.removeAccount(accountA)

        let removed = try await fixture.cache.transcripts(
            accountID: accountA,
            itemID: itemID
        )
        let retained = try await fixture.cache.transcripts(
            accountID: accountB,
            itemID: itemID
        )
        XCTAssertTrue(removed.isEmpty)
        XCTAssertEqual(retained.first?.segments.first?.text, "B")
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
}

private struct ChapterTranscriptCacheFixture {
    let container: ModelContainer
    let cache: ChapterTranscriptCache

    init() throws {
        let schema = Schema([CachedChapterTranscriptRecord.self])
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
