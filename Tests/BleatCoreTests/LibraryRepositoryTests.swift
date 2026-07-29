import Foundation
import SwiftData
import XCTest

@testable import BleatCore

final class LibraryRepositoryTests: XCTestCase {
    func testRemoteResultsPersistForCacheOnlyRelaunch() async throws {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        let library = Self.library()
        let request = try LibraryItemsPageRequest(page: 0, limit: 1)
        let page = Self.page(request: request)
        let librariesCorrelation = APICorrelationID()
        let pageCorrelation = APICorrelationID()
        let remote = RepositoryRemote(
            libraries: [.success([library], librariesCorrelation)],
            pages: [.success(page, pageCorrelation)]
        )
        let repository = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: remote,
            cache: fixture.cache
        )

        let remoteLibraries = try await repository.libraries(
            policy: .remoteOnly
        )
        let remotePage = try await repository.libraryItems(
            in: library.id,
            request: request,
            policy: .remoteOnly
        )

        XCTAssertEqual(remoteLibraries.value, [library])
        XCTAssertEqual(remoteLibraries.source, .remote)
        XCTAssertEqual(
            remoteLibraries.correlationID,
            librariesCorrelation
        )
        XCTAssertEqual(remotePage.value, page)
        XCTAssertEqual(remotePage.source, .remote)
        XCTAssertEqual(remotePage.correlationID, pageCorrelation)

        let relaunchedCache = LibraryCache(
            modelContainer: fixture.container
        )
        let offline = RepositoryRemote(
            libraries: [.failure(.unexpectedStatus(503))],
            pages: [.failure(.unexpectedStatus(503))]
        )
        let relaunched = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: offline,
            cache: relaunchedCache
        )
        let cachedLibraries = try await relaunched.libraries(
            policy: .cacheOnly
        )
        let cachedPage = try await relaunched.libraryItems(
            in: library.id,
            request: request,
            policy: .cacheOnly
        )

        XCTAssertEqual(cachedLibraries.value, [library])
        XCTAssertEqual(cachedLibraries.source, .cache)
        XCTAssertNil(cachedLibraries.correlationID)
        XCTAssertEqual(
            cachedLibraries.refreshedAt,
            remoteLibraries.refreshedAt
        )
        XCTAssertEqual(cachedPage.value, page)
        XCTAssertEqual(cachedPage.source, .cache)
        XCTAssertNil(cachedPage.correlationID)
        XCTAssertEqual(cachedPage.refreshedAt, remotePage.refreshedAt)
        let calls = await offline.callCounts()
        XCTAssertEqual(calls.libraries, 0)
        XCTAssertEqual(calls.pages, 0)
    }

    func testRemoteElseCacheFallsBackForLibrariesAndExactPage()
        async throws
    {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        let library = Self.library()
        let request = try LibraryItemsPageRequest(
            page: 1,
            limit: 2,
            sort: .addedAt,
            descending: true
        )
        let page = Self.page(request: request)
        try await fixture.cache.replaceLibraries([library], for: accountID)
        try await fixture.cache.savePage(
            page,
            request: request,
            libraryID: library.id,
            accountID: accountID
        )
        let remote = RepositoryRemote(
            libraries: [.failure(.unexpectedStatus(503))],
            pages: [.failure(.authentication(.missingCredentials))]
        )
        let repository = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: remote,
            cache: fixture.cache
        )

        let libraries = try await repository.libraries()
        let items = try await repository.libraryItems(
            in: library.id,
            request: request
        )

        XCTAssertEqual(libraries.value, [library])
        XCTAssertEqual(libraries.source, .cache)
        XCTAssertEqual(items.value, page)
        XCTAssertEqual(items.source, .cache)
    }

    func testCacheMissPreservesRemoteFailureAndCacheOnlyIsTyped()
        async throws
    {
        let fixture = try LibraryRepositoryFixture()
        let remoteError = AudiobookshelfAPIError.unexpectedStatus(503)
        let remote = RepositoryRemote(
            libraries: [.failure(remoteError)]
        )
        let repository = LibraryRepository(
            accountID: AccountID(rawValue: "account"),
            userID: UserID(rawValue: "user"),
            remote: remote,
            cache: fixture.cache
        )

        do {
            _ = try await repository.libraries()
            XCTFail("Expected remote failure")
        } catch {
            XCTAssertEqual(error, .remote(remoteError))
        }

        do {
            _ = try await repository.libraries(policy: .cacheOnly)
            XCTFail("Expected cache miss")
        } catch {
            XCTAssertEqual(error, .noCachedValue)
        }
    }

    func testRemoteOnlyDoesNotReadExistingCache() async throws {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        try await fixture.cache.replaceLibraries(
            [Self.library()],
            for: accountID
        )
        let remoteError = AudiobookshelfAPIError.unexpectedStatus(500)
        let repository = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: RepositoryRemote(
                libraries: [.failure(remoteError)]
            ),
            cache: fixture.cache
        )

        do {
            _ = try await repository.libraries(policy: .remoteOnly)
            XCTFail("Expected remote-only failure")
        } catch {
            XCTAssertEqual(error, .remote(remoteError))
        }
    }

    func testCancellationNeverReturnsStaleCache() async throws {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        try await fixture.cache.replaceLibraries(
            [Self.library()],
            for: accountID
        )
        let repository = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: RepositoryRemote(
                libraries: [.failure(.cancelled)]
            ),
            cache: fixture.cache
        )

        do {
            _ = try await repository.libraries()
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testSearchPersistsExactQueryAndFallsBackAfterRelaunch()
        async throws
    {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        let libraryID = LibraryID(rawValue: "library")
        let request = try LibrarySearchRequest(
            query: "  book  ",
            limit: 1
        )
        let pageRequest = try LibraryItemsPageRequest(
            page: 0,
            limit: 1
        )
        let items = Self.page(request: pageRequest).items
        let correlationID = APICorrelationID()
        let online = RepositoryRemote(
            searches: [.success(items, correlationID)]
        )
        let repository = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: online,
            cache: fixture.cache
        )

        let remote = try await repository.search(
            in: libraryID,
            request: request,
            policy: .remoteOnly
        )
        XCTAssertEqual(remote.value, items)
        XCTAssertEqual(remote.source, .remote)
        XCTAssertEqual(remote.correlationID, correlationID)

        let offlineError = AudiobookshelfAPIError.unexpectedStatus(503)
        let offline = RepositoryRemote(
            searches: [.failure(offlineError), .failure(offlineError)]
        )
        let relaunched = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: offline,
            cache: LibraryCache(modelContainer: fixture.container)
        )
        let fallback = try await relaunched.search(
            in: libraryID,
            request: request
        )
        XCTAssertEqual(fallback.value, items)
        XCTAssertEqual(fallback.source, .cache)
        XCTAssertNil(fallback.correlationID)
        XCTAssertEqual(fallback.refreshedAt, remote.refreshedAt)

        let widerRequest = try LibrarySearchRequest(
            query: "book",
            limit: 2
        )
        do {
            _ = try await relaunched.search(
                in: libraryID,
                request: widerRequest
            )
            XCTFail("Expected exact-query cache miss")
        } catch {
            XCTAssertEqual(error, .remote(offlineError))
        }
    }

    func testSearchCancellationNeverReturnsCachedResults()
        async throws
    {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        let libraryID = LibraryID(rawValue: "library")
        let request = try LibrarySearchRequest(
            query: "book",
            limit: 1
        )
        let pageRequest = try LibraryItemsPageRequest(
            page: 0,
            limit: 1
        )
        try await fixture.cache.saveSearchResults(
            Self.page(request: pageRequest).items,
            request: request,
            libraryID: libraryID,
            accountID: accountID
        )
        let repository = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: RepositoryRemote(
                searches: [.failure(.cancelled)]
            ),
            cache: fixture.cache
        )

        do {
            _ = try await repository.search(
                in: libraryID,
                request: request
            )
            XCTFail("Expected search cancellation")
        } catch {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testHomeShelvesPersistExactRequestAndFallbackAfterRelaunch()
        async throws
    {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        let libraryID = LibraryID(rawValue: "library")
        let request = try LibraryHomeRequest(limit: 1)
        let shelves = try Self.shelves(request: request)
        let correlationID = APICorrelationID()
        let online = RepositoryRemote(
            homes: [.success(shelves, correlationID)]
        )
        let repository = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: online,
            cache: fixture.cache
        )

        let remote = try await repository.personalizedShelves(
            in: libraryID,
            request: request,
            policy: .remoteOnly
        )
        XCTAssertEqual(remote.value, shelves)
        XCTAssertEqual(remote.source, .remote)
        XCTAssertEqual(remote.correlationID, correlationID)

        let offlineError = AudiobookshelfAPIError.unexpectedStatus(503)
        let offline = RepositoryRemote(
            homes: [.failure(offlineError), .failure(offlineError)]
        )
        let relaunched = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: offline,
            cache: LibraryCache(modelContainer: fixture.container)
        )
        let fallback = try await relaunched.personalizedShelves(
            in: libraryID,
            request: request
        )
        XCTAssertEqual(fallback.value, shelves)
        XCTAssertEqual(fallback.source, .cache)
        XCTAssertNil(fallback.correlationID)
        XCTAssertEqual(fallback.refreshedAt, remote.refreshedAt)

        let widerRequest = try LibraryHomeRequest(limit: 2)
        do {
            _ = try await relaunched.personalizedShelves(
                in: libraryID,
                request: widerRequest
            )
            XCTFail("Expected exact home-request cache miss")
        } catch {
            XCTAssertEqual(error, .remote(offlineError))
        }
    }

    func testHomeCancellationNeverReturnsCachedShelves()
        async throws
    {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        let libraryID = LibraryID(rawValue: "library")
        let request = try LibraryHomeRequest(limit: 1)
        try await fixture.cache.saveHomeShelves(
            Self.shelves(request: request),
            request: request,
            libraryID: libraryID,
            accountID: accountID
        )
        let repository = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            remote: RepositoryRemote(
                homes: [.failure(.cancelled)]
            ),
            cache: fixture.cache
        )

        do {
            _ = try await repository.personalizedShelves(
                in: libraryID,
                request: request
            )
            XCTFail("Expected home cancellation")
        } catch {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testBookDetailPersistsUserScopedAndFallsBackAfterRelaunch()
        async throws
    {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        let userID = UserID(rawValue: "user")
        let libraryID = LibraryID(rawValue: "library")
        let itemID = LibraryItemID(rawValue: "item")
        let detail = Self.detail(userID: userID)
        let correlationID = APICorrelationID()
        let online = RepositoryRemote(
            details: [.success(detail, correlationID)]
        )
        let repository = LibraryRepository(
            accountID: accountID,
            userID: userID,
            remote: online,
            cache: fixture.cache
        )

        let remote = try await repository.bookDetail(
            for: itemID,
            in: libraryID,
            policy: .remoteOnly
        )
        XCTAssertEqual(remote.value, detail)
        XCTAssertEqual(remote.source, .remote)
        XCTAssertEqual(remote.correlationID, correlationID)

        let offlineError = AudiobookshelfAPIError.unexpectedStatus(503)
        let relaunched = LibraryRepository(
            accountID: accountID,
            userID: userID,
            remote: RepositoryRemote(
                details: [.failure(offlineError)]
            ),
            cache: LibraryCache(modelContainer: fixture.container)
        )
        let fallback = try await relaunched.bookDetail(
            for: itemID,
            in: libraryID
        )
        XCTAssertEqual(fallback.value, detail)
        XCTAssertEqual(fallback.source, .cache)
        XCTAssertEqual(fallback.refreshedAt, remote.refreshedAt)
        XCTAssertNil(fallback.correlationID)

        let otherUser = LibraryRepository(
            accountID: accountID,
            userID: UserID(rawValue: "other-user"),
            remote: RepositoryRemote(),
            cache: LibraryCache(modelContainer: fixture.container)
        )
        do {
            _ = try await otherUser.bookDetail(
                for: itemID,
                in: libraryID,
                policy: .cacheOnly
            )
            XCTFail("Expected user-scoped detail cache miss")
        } catch {
            XCTAssertEqual(error, .noCachedValue)
        }
    }

    func testBookDetailCancellationNeverReturnsCachedProgress()
        async throws
    {
        let fixture = try LibraryRepositoryFixture()
        let accountID = AccountID(rawValue: "account")
        let userID = UserID(rawValue: "user")
        let detail = Self.detail(userID: userID)
        try await fixture.cache.saveBookDetail(
            detail,
            userID: userID,
            accountID: accountID
        )
        let repository = LibraryRepository(
            accountID: accountID,
            userID: userID,
            remote: RepositoryRemote(details: [.failure(.cancelled)]),
            cache: fixture.cache
        )

        do {
            _ = try await repository.bookDetail(
                for: detail.id,
                in: detail.libraryID
            )
            XCTFail("Expected detail cancellation")
        } catch {
            XCTAssertEqual(error, .cancelled)
        }
    }

    func testInvalidRemoteValueAndCorruptFallbackRemainTyped()
        async throws
    {
        let fixture = try LibraryRepositoryFixture()
        let invalidLibrary = LibrarySummary(
            id: LibraryID(rawValue: "library"),
            name: " \n ",
            mediaType: .book
        )
        let invalidRepository = LibraryRepository(
            accountID: AccountID(rawValue: "invalid"),
            userID: UserID(rawValue: "user"),
            remote: RepositoryRemote(
                libraries: [
                    .success(
                        [invalidLibrary],
                        APICorrelationID()
                    ),
                ]
            ),
            cache: fixture.cache
        )
        do {
            _ = try await invalidRepository.libraries(
                policy: .remoteOnly
            )
            XCTFail("Expected invalid cache value")
        } catch {
            XCTAssertEqual(error, .cache(.invalidLibrary))
        }

        let context = ModelContext(fixture.container)
        context.insert(CachedLibraryCollectionRecord(
            accountID: "corrupt",
            refreshedAt: Date()
        ))
        context.insert(CachedLibraryRecord(
            cacheKey: "corrupt",
            accountID: "corrupt",
            libraryID: "library",
            position: 0,
            payload: Data("not-json".utf8),
            refreshedAt: Date()
        ))
        try context.save()
        let remoteError = AudiobookshelfAPIError.unexpectedStatus(503)
        let corruptRepository = LibraryRepository(
            accountID: AccountID(rawValue: "corrupt"),
            userID: UserID(rawValue: "user"),
            remote: RepositoryRemote(
                libraries: [.failure(remoteError)]
            ),
            cache: LibraryCache(modelContainer: fixture.container)
        )
        do {
            _ = try await corruptRepository.libraries()
            XCTFail("Expected corrupt fallback")
        } catch {
            XCTAssertEqual(
                error,
                .fallbackCache(
                    remote: remoteError,
                    cache: .invalidStoredLibrary(
                        LibraryID(rawValue: "library")
                    )
                )
            )
        }
    }

    private static func library() -> LibrarySummary {
        LibrarySummary(
            id: LibraryID(rawValue: "library"),
            name: "Books",
            mediaType: .book
        )
    }

    private static func page(
        request: LibraryItemsPageRequest
    ) -> LibraryItemsPage {
        LibraryItemsPage(
            items: [
                LibraryBookSummary(
                    id: LibraryItemID(rawValue: "item"),
                    libraryID: LibraryID(rawValue: "library"),
                    title: "Book",
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
            total: 3,
            page: request.page,
            limit: request.limit
        )
    }

    private static func shelves(
        request: LibraryHomeRequest
    ) throws -> [LibraryBookShelf] {
        [
            LibraryBookShelf(
                id: "recently-added",
                label: "Recently Added",
                labelLocalizationKey: "LabelRecentlyAdded",
                items: page(
                    request: try LibraryItemsPageRequest(
                        page: 0,
                        limit: request.limit
                    )
                ).items,
                total: 3
            ),
        ]
    }

    private static func detail(userID: UserID) -> LibraryBookDetail {
        let itemID = LibraryItemID(rawValue: "item")
        let bookID = BookID(rawValue: "book")
        return LibraryBookDetail(
            id: itemID,
            libraryID: LibraryID(rawValue: "library"),
            bookID: bookID,
            title: "Book",
            subtitle: nil,
            authors: [
                LibraryBookContributor(id: "author", name: "Author"),
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
                ),
            ],
            addedAtMilliseconds: 1,
            updatedAtMilliseconds: 2,
            isExplicit: false,
            isAbridged: false,
            progress: LibraryBookProgress(
                id: "progress",
                userID: userID,
                libraryItemID: itemID,
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

private enum RepositoryRemoteStep<Value: Sendable>: Sendable {
    case success(Value, APICorrelationID)
    case failure(AudiobookshelfAPIError)
}

private actor RepositoryRemote: LibraryRemoteDataSource {
    private var librarySteps: [RepositoryRemoteStep<[LibrarySummary]>]
    private var pageSteps: [RepositoryRemoteStep<LibraryItemsPage>]
    private var searchSteps: [
        RepositoryRemoteStep<[LibraryBookSummary]>
    ]
    private var homeSteps: [
        RepositoryRemoteStep<[LibraryBookShelf]>
    ]
    private var detailSteps: [
        RepositoryRemoteStep<LibraryBookDetail>
    ]
    private var libraryCallCount = 0
    private var pageCallCount = 0
    private var searchCallCount = 0
    private var homeCallCount = 0
    private var detailCallCount = 0

    init(
        libraries: [RepositoryRemoteStep<[LibrarySummary]>] = [],
        pages: [RepositoryRemoteStep<LibraryItemsPage>] = [],
        searches: [
            RepositoryRemoteStep<[LibraryBookSummary]>
        ] = [],
        homes: [
            RepositoryRemoteStep<[LibraryBookShelf]>
        ] = [],
        details: [
            RepositoryRemoteStep<LibraryBookDetail>
        ] = []
    ) {
        librarySteps = libraries
        pageSteps = pages
        searchSteps = searches
        homeSteps = homes
        detailSteps = details
    }

    func libraries() async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibrarySummary]>
    {
        libraryCallCount += 1
        return try Self.result(from: next(&librarySteps))
    }

    func libraryItems(
        in libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<LibraryItemsPage>
    {
        pageCallCount += 1
        return try Self.result(from: next(&pageSteps))
    }

    func search(
        in libraryID: LibraryID,
        request: LibrarySearchRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibraryBookSummary]>
    {
        searchCallCount += 1
        return try Self.result(from: next(&searchSteps))
    }

    func personalizedShelves(
        in libraryID: LibraryID,
        request: LibraryHomeRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibraryBookShelf]>
    {
        homeCallCount += 1
        return try Self.result(from: next(&homeSteps))
    }

    func bookDetail(
        for itemID: LibraryItemID,
        in libraryID: LibraryID
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<LibraryBookDetail>
    {
        detailCallCount += 1
        return try Self.result(from: next(&detailSteps))
    }

    func callCounts() -> (
        libraries: Int,
        pages: Int,
        searches: Int,
        homes: Int,
        details: Int
    ) {
        (
            libraryCallCount,
            pageCallCount,
            searchCallCount,
            homeCallCount,
            detailCallCount
        )
    }

    private func next<Value>(
        _ steps: inout [RepositoryRemoteStep<Value>]
    ) -> RepositoryRemoteStep<Value> {
        guard !steps.isEmpty else {
            return .failure(.unexpectedStatus(500))
        }
        return steps.removeFirst()
    }

    private static func result<Value>(
        from step: RepositoryRemoteStep<Value>
    ) throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<Value>
    {
        switch step {
        case let .success(value, correlationID):
            AudiobookshelfAPIResult(
                value: value,
                correlationID: correlationID
            )
        case let .failure(error):
            throw error
        }
    }
}

private struct LibraryRepositoryFixture {
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
                ),
            ]
        )
        cache = LibraryCache(modelContainer: container)
    }
}
