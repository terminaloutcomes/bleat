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
        let homeRequest = try LibraryHomeRequest(limit: 1)
        try await fixture.cache.saveHomeShelves(
            Self.shelves(
                libraryID: second.id,
                request: homeRequest,
                suffix: "second"
            ),
            request: homeRequest,
            libraryID: second.id,
            accountID: accountID
        )
        let userID = UserID(rawValue: "user")
        let detail = Self.detail(
            libraryID: second.id,
            itemID: "second-item",
            userID: userID
        )
        try await fixture.cache.saveBookDetail(
            detail,
            userID: userID,
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
        let deletedHome = try await fixture.cache.homeShelves(
            request: homeRequest,
            libraryID: second.id,
            accountID: accountID
        )
        let deletedDetail = try await fixture.cache.bookDetail(
            for: detail.id,
            in: second.id,
            userID: userID,
            accountID: accountID
        )
        XCTAssertEqual(libraries?.libraries, [first])
        XCTAssertNil(deletedPage)
        XCTAssertNil(deletedSearch)
        XCTAssertNil(deletedHome)
        XCTAssertNil(deletedDetail)
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

    func testPageCacheSeparatesMinifiedRequests() async throws {
        let fixture = try LibraryCacheFixture()
        let accountID = AccountID(rawValue: "account")
        let libraryID = LibraryID(rawValue: "library")
        let minifiedRequest = try LibraryItemsPageRequest(
            page: 0,
            limit: 1,
            minified: true
        )
        let expandedRequest = try LibraryItemsPageRequest(
            page: 0,
            limit: 1,
            minified: false
        )

        try await fixture.cache.savePage(
            Self.page(
                libraryID: libraryID,
                request: expandedRequest,
                itemID: "expanded"
            ),
            request: expandedRequest,
            libraryID: libraryID,
            accountID: accountID
        )
        let minifiedBeforeSave = try await fixture.cache.page(
            request: minifiedRequest,
            libraryID: libraryID,
            accountID: accountID
        )
        XCTAssertNil(minifiedBeforeSave)

        try await fixture.cache.savePage(
            Self.page(
                libraryID: libraryID,
                request: minifiedRequest,
                itemID: "minified"
            ),
            request: minifiedRequest,
            libraryID: libraryID,
            accountID: accountID
        )

        let expanded = try await fixture.cache.page(
            request: expandedRequest,
            libraryID: libraryID,
            accountID: accountID
        )
        let minified = try await fixture.cache.page(
            request: minifiedRequest,
            libraryID: libraryID,
            accountID: accountID
        )
        XCTAssertEqual(expanded?.page.items.first?.id.rawValue, "expanded")
        XCTAssertEqual(minified?.page.items.first?.id.rawValue, "minified")
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

    func testLegacyBookOnlySearchCacheDecodesAsGroupedResults()
        async throws
    {
        let fixture = try LibraryCacheFixture()
        let accountID = AccountID(rawValue: "account")
        let libraryID = LibraryID(rawValue: "library")
        let request = try LibrarySearchRequest(query: "legacy", limit: 1)
        let pageRequest = try LibraryItemsPageRequest(page: 0, limit: 1)
        let book = Self.page(
            libraryID: libraryID,
            request: pageRequest,
            itemID: "legacy-item"
        ).items[0]
        try await fixture.cache.saveSearchResults(
            LibrarySearchResults(books: [book]),
            request: request,
            libraryID: libraryID,
            accountID: accountID
        )

        let context = ModelContext(fixture.container)
        let record = try XCTUnwrap(
            context.fetch(FetchDescriptor<CachedLibrarySearchRecord>()).first
        )
        let currentPayload = try JSONEncoder().encode([book])
        var legacyBooks = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentPayload)
                as? [[String: Any]]
        )
        legacyBooks[0].removeValue(forKey: "authors")
        legacyBooks[0].removeValue(forKey: "series")
        legacyBooks[0].removeValue(forKey: "collapsedSeries")
        record.payload = try JSONSerialization.data(withJSONObject: legacyBooks)
        try context.save()

        let cached = try await LibraryCache(
            modelContainer: fixture.container
        ).searchResults(
            request: request,
            libraryID: libraryID,
            accountID: accountID
        )

        XCTAssertEqual(cached?.results.books, [book])
        XCTAssertEqual(cached?.results.authors, [])
        XCTAssertEqual(cached?.results.series, [])
    }

    func testHomeShelvesAreExactScopedAndPersistEmptyResults()
        async throws
    {
        let fixture = try LibraryCacheFixture()
        let accountA = AccountID(rawValue: "a")
        let accountB = AccountID(rawValue: "b")
        let accountEmpty = AccountID(rawValue: "empty")
        let libraryA = LibraryID(rawValue: "library-a")
        let libraryB = LibraryID(rawValue: "library-b")
        let request = try LibraryHomeRequest(limit: 1)
        let widerRequest = try LibraryHomeRequest(limit: 2)
        let noProgressRequest = try LibraryHomeRequest(
            limit: 1,
            includeProgress: false
        )
        try await fixture.cache.saveHomeShelves(
            Self.shelves(
                libraryID: libraryA,
                request: request,
                suffix: "a"
            ),
            request: request,
            libraryID: libraryA,
            accountID: accountA
        )
        try await fixture.cache.saveHomeShelves(
            Self.shelves(
                libraryID: libraryA,
                request: request,
                suffix: "b"
            ),
            request: request,
            libraryID: libraryA,
            accountID: accountB
        )
        try await fixture.cache.saveHomeShelves(
            Self.shelves(
                libraryID: libraryB,
                request: request,
                suffix: "library-b"
            ),
            request: request,
            libraryID: libraryB,
            accountID: accountA
        )
        try await fixture.cache.saveHomeShelves(
            Self.shelves(
                libraryID: libraryA,
                request: widerRequest,
                suffix: "wide"
            ),
            request: widerRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        try await fixture.cache.saveHomeShelves(
            Self.shelves(
                libraryID: libraryA,
                request: noProgressRequest,
                suffix: "no-progress"
            ),
            request: noProgressRequest,
            libraryID: libraryA,
            accountID: accountA
        )
        try await fixture.cache.saveHomeShelves(
            [],
            request: request,
            libraryID: libraryA,
            accountID: accountEmpty
        )

        let relaunched = LibraryCache(
            modelContainer: fixture.container
        )
        func firstItemID(
            accountID: AccountID,
            libraryID: LibraryID,
            request: LibraryHomeRequest
        ) async throws -> String? {
            try await relaunched.homeShelves(
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )?.shelves.first?.items.first?.id.rawValue
        }

        let a = try await firstItemID(
            accountID: accountA,
            libraryID: libraryA,
            request: request
        )
        let b = try await firstItemID(
            accountID: accountB,
            libraryID: libraryA,
            request: request
        )
        let otherLibrary = try await firstItemID(
            accountID: accountA,
            libraryID: libraryB,
            request: request
        )
        let wide = try await firstItemID(
            accountID: accountA,
            libraryID: libraryA,
            request: widerRequest
        )
        let noProgress = try await firstItemID(
            accountID: accountA,
            libraryID: libraryA,
            request: noProgressRequest
        )
        XCTAssertEqual(a, "item-a")
        XCTAssertEqual(b, "item-b")
        XCTAssertEqual(otherLibrary, "item-library-b")
        XCTAssertEqual(wide, "item-wide")
        XCTAssertEqual(noProgress, "item-no-progress")
        let empty = try await relaunched.homeShelves(
            request: request,
            libraryID: libraryA,
            accountID: accountEmpty
        )
        XCTAssertEqual(empty?.shelves, [])
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

        let homeRequest = try LibraryHomeRequest(limit: 1)
        let invalidShelf = LibraryBookShelf(
            id: "recent",
            label: "Recent",
            labelLocalizationKey: nil,
            items: Self.page(
                libraryID: LibraryID(rawValue: "other"),
                request: request,
                itemID: "item"
            ).items,
            total: 1
        )
        do {
            try await fixture.cache.saveHomeShelves(
                [invalidShelf],
                request: homeRequest,
                libraryID: libraryID,
                accountID: accountID
            )
            XCTFail("Expected invalid home shelf rejection")
        } catch {
            XCTAssertEqual(error, .invalidHomeShelves)
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

        let detail = Self.detail(
            libraryID: libraryID,
            itemID: "item",
            userID: UserID(rawValue: "user")
        )
        do {
            try await fixture.cache.saveBookDetail(
                detail,
                userID: UserID(rawValue: "other-user"),
                accountID: accountID
            )
            XCTFail("Expected mismatched detail user rejection")
        } catch {
            XCTAssertEqual(error, .invalidBookDetail)
        }
        do {
            _ = try await fixture.cache.bookDetail(
                for: detail.id,
                in: libraryID,
                userID: UserID(rawValue: ""),
                accountID: accountID
            )
            XCTFail("Expected empty detail user rejection")
        } catch {
            XCTAssertEqual(error, .invalidUserID)
        }
    }

    func testCorruptedStoredRecordsRemainTyped() async throws {
        let fixture = try LibraryCacheFixture()
        let context = ModelContext(fixture.container)
        context.insert(
            CachedLibraryCollectionRecord(
                accountID: "account",
                refreshedAt: Date()
            ))
        context.insert(
            CachedLibraryRecord(
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
        try XCTUnwrap(
            records.first {
                $0.accountID == "page-account"
            }
        ).payload = Data("not-json".utf8)
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
        try XCTUnwrap(
            searchRecords.first {
                $0.accountID == "search-account"
            }
        ).payload = Data("not-json".utf8)
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

        let homeRequest = try LibraryHomeRequest(limit: 1)
        try await fixture.cache.saveHomeShelves(
            Self.shelves(
                libraryID: LibraryID(rawValue: "library"),
                request: homeRequest,
                suffix: "corrupt"
            ),
            request: homeRequest,
            libraryID: LibraryID(rawValue: "library"),
            accountID: AccountID(rawValue: "home-account")
        )
        let homeContext = ModelContext(fixture.container)
        let homeRecords = try homeContext.fetch(
            FetchDescriptor<CachedLibraryHomeRecord>()
        )
        try XCTUnwrap(
            homeRecords.first {
                $0.accountID == "home-account"
            }
        ).payload = Data("not-json".utf8)
        try homeContext.save()
        do {
            _ = try await relaunched.homeShelves(
                request: homeRequest,
                libraryID: LibraryID(rawValue: "library"),
                accountID: AccountID(rawValue: "home-account")
            )
            XCTFail("Expected corrupt home payload")
        } catch {
            XCTAssertEqual(error, .invalidStoredHomeShelves)
        }

        let detail = Self.detail(
            libraryID: LibraryID(rawValue: "library"),
            itemID: "item",
            userID: UserID(rawValue: "user")
        )
        try await fixture.cache.saveBookDetail(
            detail,
            userID: UserID(rawValue: "user"),
            accountID: AccountID(rawValue: "detail-account")
        )
        let detailContext = ModelContext(fixture.container)
        let detailRecords = try detailContext.fetch(
            FetchDescriptor<CachedLibraryBookDetailRecord>()
        )
        try XCTUnwrap(
            detailRecords.first {
                $0.accountID == "detail-account"
            }
        ).payload = Data("not-json".utf8)
        try detailContext.save()
        do {
            _ = try await relaunched.bookDetail(
                for: detail.id,
                in: detail.libraryID,
                userID: UserID(rawValue: "user"),
                accountID: AccountID(rawValue: "detail-account")
            )
            XCTFail("Expected corrupt detail payload")
        } catch {
            XCTAssertEqual(error, .invalidStoredBookDetail)
        }
    }

    func testBookDetailCacheIsAccountUserLibraryAndItemScoped()
        async throws
    {
        let fixture = try LibraryCacheFixture()
        let libraryID = LibraryID(rawValue: "library")
        let itemID = LibraryItemID(rawValue: "item")
        let accountA = AccountID(rawValue: "account-a")
        let accountB = AccountID(rawValue: "account-b")
        let userA = UserID(rawValue: "user-a")
        let userB = UserID(rawValue: "user-b")
        let refreshA = Date(timeIntervalSince1970: 10)
        let detailA = Self.detail(
            libraryID: libraryID,
            itemID: itemID.rawValue,
            userID: userA,
            title: "Account A"
        )
        let detailB = Self.detail(
            libraryID: libraryID,
            itemID: itemID.rawValue,
            userID: userB,
            title: "Account B"
        )
        try await fixture.cache.saveBookDetail(
            detailA,
            userID: userA,
            accountID: accountA,
            refreshedAt: refreshA
        )
        try await fixture.cache.saveBookDetail(
            detailB,
            userID: userB,
            accountID: accountB
        )

        let relaunched = LibraryCache(modelContainer: fixture.container)
        let cachedA = try await relaunched.bookDetail(
            for: itemID,
            in: libraryID,
            userID: userA,
            accountID: accountA
        )
        let wrongUser = try await relaunched.bookDetail(
            for: itemID,
            in: libraryID,
            userID: userB,
            accountID: accountA
        )
        let wrongLibrary = try await relaunched.bookDetail(
            for: itemID,
            in: LibraryID(rawValue: "other"),
            userID: userA,
            accountID: accountA
        )
        XCTAssertEqual(cachedA?.detail, detailA)
        XCTAssertEqual(cachedA?.refreshedAt, refreshA)
        XCTAssertNil(wrongUser)
        XCTAssertNil(wrongLibrary)

        try await relaunched.invalidateLibrary(
            libraryID,
            for: accountA
        )
        let invalidatedA = try await relaunched.bookDetail(
            for: itemID,
            in: libraryID,
            userID: userA,
            accountID: accountA
        )
        let retainedB = try await relaunched.bookDetail(
            for: itemID,
            in: libraryID,
            userID: userB,
            accountID: accountB
        )
        XCTAssertNil(invalidatedA)
        XCTAssertEqual(retainedB?.detail, detailB)
        try await relaunched.removeAccount(accountB)
        let removedB = try await relaunched.bookDetail(
            for: itemID,
            in: libraryID,
            userID: userB,
            accountID: accountB
        )
        XCTAssertNil(removedB)
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
        let homeRequest = try LibraryHomeRequest(limit: 1)
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
            try await fixture.cache.saveHomeShelves(
                Self.shelves(
                    libraryID: libraryID,
                    request: homeRequest,
                    suffix: accountID.rawValue
                ),
                request: homeRequest,
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
        let invalidatedHome = try await fixture.cache.homeShelves(
            request: homeRequest,
            libraryID: libraryID,
            accountID: accountA
        )
        let retainedHome = try await fixture.cache.homeShelves(
            request: homeRequest,
            libraryID: libraryID,
            accountID: accountB
        )
        XCTAssertNil(invalidatedPage)
        XCTAssertNotNil(retainedPage)
        XCTAssertNil(invalidatedSearch)
        XCTAssertNotNil(retainedSearch)
        XCTAssertNil(invalidatedHome)
        XCTAssertNotNil(retainedHome)

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
        try await fixture.cache.saveHomeShelves(
            Self.shelves(
                libraryID: libraryID,
                request: homeRequest,
                suffix: "restored-a"
            ),
            request: homeRequest,
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
        let removedHome = try await fixture.cache.homeShelves(
            request: homeRequest,
            libraryID: libraryID,
            accountID: accountA
        )
        XCTAssertNil(removedLibraries)
        XCTAssertNotNil(retainedLibraries)
        XCTAssertNil(removedSearch)
        XCTAssertNil(removedHome)
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
                )
            ],
            total: 1,
            page: request.page,
            limit: request.limit
        )
    }

    private static func shelves(
        libraryID: LibraryID,
        request: LibraryHomeRequest,
        suffix: String
    ) throws -> [LibraryBookShelf] {
        let pageRequest = try LibraryItemsPageRequest(
            page: 0,
            limit: request.limit
        )
        return [
            LibraryBookShelf(
                id: "shelf-\(suffix)",
                label: "Shelf \(suffix)",
                labelLocalizationKey: "LabelShelf",
                items: page(
                    libraryID: libraryID,
                    request: pageRequest,
                    itemID: "item-\(suffix)"
                ).items,
                total: 1
            )
        ]
    }

    private static func detail(
        libraryID: LibraryID,
        itemID: String,
        userID: UserID,
        title: String = "Book"
    ) -> LibraryBookDetail {
        let typedItemID = LibraryItemID(rawValue: itemID)
        let bookID = BookID(rawValue: "book-\(itemID)")
        return LibraryBookDetail(
            id: typedItemID,
            libraryID: libraryID,
            bookID: bookID,
            title: title,
            subtitle: nil,
            authors: [
                LibraryBookContributor(
                    id: AuthorID(rawValue: "author")!,
                    name: "Author"
                )
            ],
            narrators: ["Narrator"],
            series: [],
            genres: ["Fiction"],
            tags: [],
            publishedYear: "2024",
            publishedDate: nil,
            publisher: nil,
            descriptionPlain: "Description",
            isbn: nil,
            asin: nil,
            language: "English",
            duration: 60,
            trackCount: 1,
            audioFileCount: 1,
            chapters: [
                PlaybackChapter(
                    id: 0,
                    start: 0,
                    end: 60,
                    title: "Chapter"
                )
            ],
            addedAtMilliseconds: 1,
            updatedAtMilliseconds: 2,
            isExplicit: false,
            isAbridged: false,
            progress: LibraryBookProgress(
                id: "progress-\(userID.rawValue)",
                userID: userID,
                libraryItemID: typedItemID,
                bookID: bookID,
                duration: 60,
                progress: 0.5,
                currentTime: 30,
                isFinished: false,
                hideFromContinueListening: false,
                lastUpdateMilliseconds: 2,
                startedAtMilliseconds: 1,
                finishedAtMilliseconds: nil
            )
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
            CachedLibraryHomeRecord.self,
            CachedLibraryBookDetailRecord.self,
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
        cache = LibraryCache(modelContainer: container)
    }
}
