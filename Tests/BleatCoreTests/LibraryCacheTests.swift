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
        let searchRequest = try LibrarySearchRequest(
            query: "second",
            limit: 1
        )
        try await fixture.cache.saveSearchResults(
            Self.page(
                libraryID: second.id,
                request: request,
                itemID: "second-item"
            ).items,
            request: searchRequest,
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
        let deletedSearch = try await fixture.cache.searchResults(
            request: searchRequest,
            libraryID: second.id,
            accountID: accountID
        )
        XCTAssertEqual(libraries?.libraries, [first])
        XCTAssertNil(deletedPage)
        XCTAssertNil(deletedSearch)
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

    func testSearchCacheIsExactScopedAndPersistsEmptyResults()
        async throws
    {
        let fixture = try LibraryCacheFixture()
        let accountA = AccountID(rawValue: "a")
        let accountB = AccountID(rawValue: "b")
        let libraryA = LibraryID(rawValue: "library-a")
        let libraryB = LibraryID(rawValue: "library-b")
        let firstRequest = try LibrarySearchRequest(
            query: "  first  ",
            limit: 1
        )
        let widerRequest = try LibrarySearchRequest(
            query: "first",
            limit: 2
        )
        let emptyRequest = try LibrarySearchRequest(
            query: "missing",
            limit: 1
        )
        let pageRequest = try LibraryItemsPageRequest(
            page: 0,
            limit: 1
        )
        func item(
            libraryID: LibraryID,
            itemID: String
        ) -> LibraryBookSummary {
            Self.page(
                libraryID: libraryID,
                request: pageRequest,
                itemID: itemID
            ).items[0]
        }
        try await fixture.cache.saveSearchResults(
            [item(libraryID: libraryA, itemID: "a-first")],
            request: firstRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        try await fixture.cache.saveSearchResults(
            [item(libraryID: libraryA, itemID: "a-wide")],
            request: widerRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        try await fixture.cache.saveSearchResults(
            [item(libraryID: libraryA, itemID: "b-first")],
            request: firstRequest,
            libraryID: libraryA,
            accountID: accountB
        )
        try await fixture.cache.saveSearchResults(
            [item(libraryID: libraryB, itemID: "other-library")],
            request: firstRequest,
            libraryID: libraryB,
            accountID: accountA
        )
        try await fixture.cache.saveSearchResults(
            [],
            request: emptyRequest,
            libraryID: libraryA,
            accountID: accountA
        )

        let relaunched = LibraryCache(
            modelContainer: fixture.container
        )
        let aFirst = try await relaunched.searchResults(
            request: firstRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        let aWide = try await relaunched.searchResults(
            request: widerRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        let bFirst = try await relaunched.searchResults(
            request: firstRequest,
            libraryID: libraryA,
            accountID: accountB
        )
        let otherLibrary = try await relaunched.searchResults(
            request: firstRequest,
            libraryID: libraryB,
            accountID: accountA
        )
        let empty = try await relaunched.searchResults(
            request: emptyRequest,
            libraryID: libraryA,
            accountID: accountA
        )

        XCTAssertEqual(aFirst?.items.first?.id.rawValue, "a-first")
        XCTAssertEqual(aWide?.items.first?.id.rawValue, "a-wide")
        XCTAssertEqual(bFirst?.items.first?.id.rawValue, "b-first")
        XCTAssertEqual(
            otherLibrary?.items.first?.id.rawValue,
            "other-library"
        )
        XCTAssertEqual(empty?.items, [])
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

        let searchRequest = try LibrarySearchRequest(
            query: "book",
            limit: 1
        )
        do {
            try await fixture.cache.saveSearchResults(
                Self.page(
                    libraryID: LibraryID(rawValue: "other"),
                    request: request,
                    itemID: "item"
                ).items,
                request: searchRequest,
                libraryID: libraryID,
                accountID: accountID
            )
            XCTFail("Expected invalid search result rejection")
        } catch {
            XCTAssertEqual(error, .invalidSearchResults)
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

        let searchRequest = try LibrarySearchRequest(
            query: "book",
            limit: 1
        )
        try await fixture.cache.saveSearchResults(
            Self.page(
                libraryID: LibraryID(rawValue: "library"),
                request: request,
                itemID: "item"
            ).items,
            request: searchRequest,
            libraryID: LibraryID(rawValue: "library"),
            accountID: AccountID(rawValue: "search-account")
        )
        let searchContext = ModelContext(fixture.container)
        let searchRecords = try searchContext.fetch(
            FetchDescriptor<CachedLibrarySearchRecord>()
        )
        try XCTUnwrap(searchRecords.first {
            $0.accountID == "search-account"
        }).payload = Data("not-json".utf8)
        try searchContext.save()
        let relaunched = LibraryCache(
            modelContainer: fixture.container
        )
        do {
            _ = try await relaunched.searchResults(
                request: searchRequest,
                libraryID: LibraryID(rawValue: "library"),
                accountID: AccountID(rawValue: "search-account")
            )
            XCTFail("Expected corrupt search payload")
        } catch {
            XCTAssertEqual(error, .invalidStoredSearchResults)
        }
    }

    func testInvalidationAndAccountRemovalAreScoped() async throws {
        let fixture = try LibraryCacheFixture()
        let accountA = AccountID(rawValue: "a")
        let accountB = AccountID(rawValue: "b")
        let libraryID = LibraryID(rawValue: "library")
        let request = try LibraryItemsPageRequest(page: 0, limit: 1)
        let searchRequest = try LibrarySearchRequest(
            query: "book",
            limit: 1
        )
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
            try await fixture.cache.saveSearchResults(
                Self.page(
                    libraryID: libraryID,
                    request: request,
                    itemID: accountID.rawValue
                ).items,
                request: searchRequest,
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
        let invalidatedSearch = try await fixture.cache.searchResults(
            request: searchRequest,
            libraryID: libraryID,
            accountID: accountA
        )
        let retainedSearch = try await fixture.cache.searchResults(
            request: searchRequest,
            libraryID: libraryID,
            accountID: accountB
        )
        XCTAssertNil(invalidatedPage)
        XCTAssertNotNil(retainedPage)
        XCTAssertNil(invalidatedSearch)
        XCTAssertNotNil(retainedSearch)

        try await fixture.cache.saveSearchResults(
            Self.page(
                libraryID: libraryID,
                request: request,
                itemID: "restored-a"
            ).items,
            request: searchRequest,
            libraryID: libraryID,
            accountID: accountA
        )
        try await fixture.cache.removeAccount(accountA)
        let removedLibraries = try await fixture.cache.libraries(for: accountA)
        let retainedLibraries = try await fixture.cache.libraries(for: accountB)
        let removedSearch = try await fixture.cache.searchResults(
            request: searchRequest,
            libraryID: libraryID,
            accountID: accountA
        )
        XCTAssertNil(removedLibraries)
        XCTAssertNotNil(retainedLibraries)
        XCTAssertNil(removedSearch)
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
            CachedLibrarySearchRecord.self,
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
