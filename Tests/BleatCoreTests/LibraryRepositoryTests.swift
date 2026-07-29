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
}

private enum RepositoryRemoteStep<Value: Sendable>: Sendable {
    case success(Value, APICorrelationID)
    case failure(AudiobookshelfAPIError)
}

private actor RepositoryRemote: LibraryRemoteDataSource {
    private var librarySteps: [RepositoryRemoteStep<[LibrarySummary]>]
    private var pageSteps: [RepositoryRemoteStep<LibraryItemsPage>]
    private var libraryCallCount = 0
    private var pageCallCount = 0

    init(
        libraries: [RepositoryRemoteStep<[LibrarySummary]>] = [],
        pages: [RepositoryRemoteStep<LibraryItemsPage>] = []
    ) {
        librarySteps = libraries
        pageSteps = pages
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

    func callCounts() -> (libraries: Int, pages: Int) {
        (libraryCallCount, pageCallCount)
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
