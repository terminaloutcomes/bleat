import Foundation
import SwiftData
import XCTest

@testable import BleatCore

final class LibraryCacheTests: XCTestCase {
    func testEmptyLibrarySnapshotPersistsAcrossCacheActors() async throws {
        let fixture = try LibraryCacheFixture()
        let accountID = AccountID(rawValue: "account")
        let refreshedAt = Date(timeIntervalSince1970: 100)

        try await fixture.cache.replaceLibraries(
            [],
            for: accountID,
            refreshedAt: refreshedAt
        )

        let relaunched = LibraryCache(modelContainer: fixture.container)
        let snapshot = try await relaunched.libraries(for: accountID)
        XCTAssertEqual(snapshot?.libraries, [])
        XCTAssertEqual(snapshot?.refreshedAt, refreshedAt)
    }

    func testLibraryReplacementPreservesOrderAndRemovesDeletedPages()
        async throws
    {
        let fixture = try LibraryCacheFixture()
        let accountID = AccountID(rawValue: "account")
        let first = Self.library(id: "first", name: "First")
        let second = Self.library(id: "second", name: "Second")
        try await fixture.cache.replaceLibraries(
            [second, first],
            for: accountID
        )
        let request = try LibraryItemsPageRequest(page: 0, limit: 1)
        try await fixture.cache.savePage(
            Self.page(
                libraryID: second.id,
                request: request,
                itemID: "second-item"
            ),
            request: request,
            libraryID: second.id,
            accountID: accountID
        )

        try await fixture.cache.replaceLibraries(
            [first],
            for: accountID
        )

        let libraries = try await fixture.cache.libraries(for: accountID)
        let deletedPage = try await fixture.cache.page(
            request: request,
            libraryID: second.id,
            accountID: accountID
        )
        XCTAssertEqual(libraries?.libraries, [first])
        XCTAssertNil(deletedPage)
    }

    func testPageCacheIsAccountLibraryAndQueryScopedAcrossRelaunch()
        async throws
    {
        let fixture = try LibraryCacheFixture()
        let accountA = AccountID(rawValue: "a")
        let accountB = AccountID(rawValue: "b")
        let libraryA = LibraryID(rawValue: "library-a")
        let libraryB = LibraryID(rawValue: "library-b")
        let titleRequest = try LibraryItemsPageRequest(
            page: 0,
            limit: 1,
            sort: .title
        )
        let addedRequest = try LibraryItemsPageRequest(
            page: 0,
            limit: 1,
            sort: .addedAt,
            descending: true
        )
        try await fixture.cache.savePage(
            Self.page(
                libraryID: libraryA,
                request: titleRequest,
                itemID: "a-title"
            ),
            request: titleRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        try await fixture.cache.savePage(
            Self.page(
                libraryID: libraryA,
                request: addedRequest,
                itemID: "a-added"
            ),
            request: addedRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        try await fixture.cache.savePage(
            Self.page(
                libraryID: libraryA,
                request: titleRequest,
                itemID: "b-title"
            ),
            request: titleRequest,
            libraryID: libraryA,
            accountID: accountB
        )
        try await fixture.cache.savePage(
            Self.page(
                libraryID: libraryB,
                request: titleRequest,
                itemID: "other-library"
            ),
            request: titleRequest,
            libraryID: libraryB,
            accountID: accountA
        )

        let relaunched = LibraryCache(modelContainer: fixture.container)
        let aTitle = try await relaunched.page(
            request: titleRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        let aAdded = try await relaunched.page(
            request: addedRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        let bTitle = try await relaunched.page(
            request: titleRequest,
            libraryID: libraryA,
            accountID: accountB
        )
        let otherLibrary = try await relaunched.page(
            request: titleRequest,
            libraryID: libraryB,
            accountID: accountA
        )
        XCTAssertEqual(aTitle?.page.items.first?.id.rawValue, "a-title")
        XCTAssertEqual(aAdded?.page.items.first?.id.rawValue, "a-added")
        XCTAssertEqual(bTitle?.page.items.first?.id.rawValue, "b-title")
        XCTAssertEqual(
            otherLibrary?.page.items.first?.id.rawValue,
            "other-library"
        )
    }

    func testPageReplacementUpdatesPayloadAndRefreshTime() async throws {
        let fixture = try LibraryCacheFixture()
        let accountID = AccountID(rawValue: "account")
        let libraryID = LibraryID(rawValue: "library")
        let request = try LibraryItemsPageRequest(page: 0, limit: 1)
        try await fixture.cache.savePage(
            Self.page(
                libraryID: libraryID,
                request: request,
                itemID: "old"
            ),
            request: request,
            libraryID: libraryID,
            accountID: accountID,
            refreshedAt: Date(timeIntervalSince1970: 1)
        )
        let newRefresh = Date(timeIntervalSince1970: 2)
        try await fixture.cache.savePage(
            Self.page(
                libraryID: libraryID,
                request: request,
                itemID: "new"
            ),
            request: request,
            libraryID: libraryID,
            accountID: accountID,
            refreshedAt: newRefresh
        )

        let snapshot = try await fixture.cache.page(
            request: request,
            libraryID: libraryID,
            accountID: accountID
        )
        XCTAssertEqual(snapshot?.page.items.first?.id.rawValue, "new")
        XCTAssertEqual(snapshot?.refreshedAt, newRefresh)
    }

    func testInvalidInputsAndPagesRemainTyped() async throws {
        let fixture = try LibraryCacheFixture()
        let accountID = AccountID(rawValue: "account")
        let libraryID = LibraryID(rawValue: "library")
        let request = try LibraryItemsPageRequest(page: 0, limit: 1)

        do {
            try await fixture.cache.replaceLibraries(
                [
                    Self.library(id: "duplicate", name: "One"),
                    Self.library(id: "duplicate", name: "Two"),
                ],
                for: accountID
            )
            XCTFail("Expected duplicate library rejection")
        } catch {
            XCTAssertEqual(
                error,
                .duplicateLibraryID(
                    LibraryID(rawValue: "duplicate")
                )
            )
        }

        do {
            try await fixture.cache.savePage(
                Self.page(
                    libraryID: LibraryID(rawValue: "other"),
                    request: request,
                    itemID: "item"
                ),
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
            XCTFail("Expected mismatched page rejection")
        } catch {
            XCTAssertEqual(error, .invalidPage)
        }

        do {
            try await fixture.cache.replaceLibraries(
                [Self.library(id: "invalid", name: " \n ")],
                for: accountID
            )
            XCTFail("Expected invalid library rejection")
        } catch {
            XCTAssertEqual(error, .invalidLibrary)
        }

        do {
            try await fixture.cache.savePage(
                Self.page(
                    libraryID: libraryID,
                    request: request,
                    itemID: "item",
                    title: " \n "
                ),
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
            XCTFail("Expected invalid item rejection")
        } catch {
            XCTAssertEqual(error, .invalidPage)
        }
    }

    func testCorruptedStoredRecordsRemainTyped() async throws {
        let fixture = try LibraryCacheFixture()
        let context = ModelContext(fixture.container)
        context.insert(CachedLibraryCollectionRecord(
            accountID: "account",
            refreshedAt: Date()
        ))
        context.insert(CachedLibraryRecord(
            cacheKey: "corrupt-library",
            accountID: "account",
            libraryID: "library",
            position: 0,
            payload: Data("not-json".utf8),
            refreshedAt: Date()
        ))
        try context.save()

        do {
            _ = try await fixture.cache.libraries(
                for: AccountID(rawValue: "account")
            )
            XCTFail("Expected corrupt library payload")
        } catch {
            XCTAssertEqual(
                error,
                .invalidStoredLibrary(
                    LibraryID(rawValue: "library")
                )
            )
        }

        let request = try LibraryItemsPageRequest(page: 0, limit: 1)
        try await fixture.cache.savePage(
            Self.page(
                libraryID: LibraryID(rawValue: "library"),
                request: request,
                itemID: "item"
            ),
            request: request,
            libraryID: LibraryID(rawValue: "library"),
            accountID: AccountID(rawValue: "page-account")
        )
        let pageContext = ModelContext(fixture.container)
        let records = try pageContext.fetch(
            FetchDescriptor<CachedLibraryPageRecord>()
        )
        try XCTUnwrap(records.first {
            $0.accountID == "page-account"
        }).payload = Data("not-json".utf8)
        try pageContext.save()
        do {
            _ = try await fixture.cache.page(
                request: request,
                libraryID: LibraryID(rawValue: "library"),
                accountID: AccountID(rawValue: "page-account")
            )
            XCTFail("Expected corrupt page payload")
        } catch {
            XCTAssertEqual(error, .invalidStoredPage)
        }
    }

    func testInvalidationAndAccountRemovalAreScoped() async throws {
        let fixture = try LibraryCacheFixture()
        let accountA = AccountID(rawValue: "a")
        let accountB = AccountID(rawValue: "b")
        let libraryID = LibraryID(rawValue: "library")
        let request = try LibraryItemsPageRequest(page: 0, limit: 1)
        for accountID in [accountA, accountB] {
            try await fixture.cache.replaceLibraries(
                [Self.library(id: "library", name: "Books")],
                for: accountID
            )
            try await fixture.cache.savePage(
                Self.page(
                    libraryID: libraryID,
                    request: request,
                    itemID: accountID.rawValue
                ),
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
        }

        try await fixture.cache.invalidateLibrary(
            libraryID,
            for: accountA
        )
        let invalidatedPage = try await fixture.cache.page(
            request: request,
            libraryID: libraryID,
            accountID: accountA
        )
        let retainedPage = try await fixture.cache.page(
            request: request,
            libraryID: libraryID,
            accountID: accountB
        )
        XCTAssertNil(invalidatedPage)
        XCTAssertNotNil(retainedPage)

        try await fixture.cache.removeAccount(accountA)
        let removedLibraries = try await fixture.cache.libraries(for: accountA)
        let retainedLibraries = try await fixture.cache.libraries(for: accountB)
        XCTAssertNil(removedLibraries)
        XCTAssertNotNil(retainedLibraries)
    }

    private static func library(
        id: String,
        name: String
    ) -> LibrarySummary {
        LibrarySummary(
            id: LibraryID(rawValue: id),
            name: name,
            mediaType: .book
        )
    }

    private static func page(
        libraryID: LibraryID,
        request: LibraryItemsPageRequest,
        itemID: String,
        title: String? = nil
    ) -> LibraryItemsPage {
        LibraryItemsPage(
            items: [
                LibraryBookSummary(
                    id: LibraryItemID(rawValue: itemID),
                    libraryID: libraryID,
                    title: title ?? "Book \(itemID)",
                    subtitle: nil,
                    authorName: nil,
                    narratorName: nil,
                    seriesName: nil,
                    genres: [],
                    publisher: nil,
                    publishedYear: nil,
                    duration: 60,
                    trackCount: 1,
                    chapterCount: 0,
                    addedAtMilliseconds: 1,
                    updatedAtMilliseconds: 2,
                    isExplicit: false,
                    isAbridged: false
                ),
            ],
            total: 1,
            page: request.page,
            limit: request.limit
        )
    }
}

private struct LibraryCacheFixture {
    let container: ModelContainer
    let cache: LibraryCache

    init() throws {
        let schema = Schema([
            CachedLibraryCollectionRecord.self,
            CachedLibraryRecord.self,
            CachedLibraryPageRecord.self,
        ])
        container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                ),
            ]
        )
        cache = LibraryCache(modelContainer: container)
    }
}
