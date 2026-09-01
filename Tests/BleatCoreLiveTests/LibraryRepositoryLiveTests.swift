import Foundation
import SwiftData
import XCTest

@testable import BleatCore

/// Live 10,000-book paged-load and cache-fallback baseline for GitHub issue
/// #46 / spec section 19.
///
/// Phase 1 — paged-load: exercises the real pinned Audiobookshelf 2.36.0
/// decode path through `LibraryRepository` with `.remoteElseCache`, which
/// caches every page. The `AudiobookshelfAPI` actor decodes each response
/// off the main actor.
///
/// Phase 2 — cache fallback: after the server is torn down (simulated by a
/// failing remote data source), re-reads every page through the same
/// repository with `.remoteElseCache`. The remote call fails and the
/// repository returns each page from the SwiftData cache, evidencing that
/// browsing remains available with 10,000 cached books when the server is
/// unavailable.
///
/// Skipped unless `BLEAT_LARGE_LIBRARY_COUNT` is set, so
/// `./scripts/test-live.sh` does not pay the cost on every run.
final class LibraryRepositoryLiveTests: XCTestCase {
    func testPagedLoadAndCacheFallbackOfLargeLibrary()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard let largeCountString = environment["BLEAT_LARGE_LIBRARY_COUNT"],
            let largeCount = Int(largeCountString),
            largeCount > 0
        else {
            throw XCTSkip(
                "Set BLEAT_LARGE_LIBRARY_COUNT to exercise the 10k live paged-load"
            )
        }
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live server URLs"
            )
        }

        let limit = 100
        let expectedPages = (largeCount + limit - 1) / limit

        for liveURL in [rootURL, prefixURL] {
            try await verifyPagedLoadAndCacheFallback(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "large-\(UUID().uuidString)"),
                username: username,
                password: password,
                expectedCount: largeCount,
                limit: limit,
                expectedPages: expectedPages
            )
        }
    }

    private func verifyPagedLoadAndCacheFallback(
        server: NormalizedServerURL,
        accountID: AccountID,
        username: String,
        password: String,
        expectedCount: Int,
        limit: Int,
        expectedPages: Int
    ) async throws {
        let store = LiveCredentialStore()
        let transport = LocalDockerHTTPTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let authenticated = try await coordinator.login(
            accountID: accountID,
            server: server,
            username: username,
            password: password
        )
        let account = try ServerAccount(
            id: authenticated.id,
            server: authenticated.server,
            serverVersion: "2.36.0",
            authenticationMethods: [.local],
            user: authenticated.user
        )
        let api = AudiobookshelfAPI(
            account: account,
            authCoordinator: coordinator
        )

        let librariesResult = try await api.libraries()
        let library = try XCTUnwrap(
            librariesResult.value.first { $0.name == "Bleat Large Fixtures" },
            "Bleat Large Fixtures library must be seeded"
        )

        // Build an in-memory SwiftData cache so the repository persists
        // every page during the paged-load phase.
        let cache = try Self.makeInMemoryCache()

        // --- Phase 1: paged-load via the repository (populates cache) ---

        let repository = LibraryRepository(
            accountID: accountID,
            userID: account.user.id,
            remote: api,
            cache: cache
        )

        let requests = try (0..<expectedPages).map { pageIndex in
            try LibraryItemsPageRequest(
                page: pageIndex,
                limit: limit,
                sort: .addedAt,
                descending: false,
                filter: nil,
                includeProgress: false,
                collapseSeries: false,
                minified: true
            )
        }

        let loadStart = CACurrentMediaTime()
        var totalItems = 0
        var seenIDs = Set<LibraryItemID>()
        for request in requests {
            let result = try await repository.libraryItems(
                in: library.id,
                request: request,
                policy: .remoteElseCache
            )
            XCTAssertEqual(
                result.source, .remote, "phase 1 must serve from remote")
            let page = result.value
            XCTAssertEqual(
                page.page, request.page, "server must echo the requested page")
            XCTAssertEqual(
                page.limit, limit, "server must echo the requested limit")
            XCTAssertEqual(
                page.total, expectedCount, "server total must match seed count")
            XCTAssertLessThanOrEqual(
                page.items.count,
                limit,
                "page must not exceed the requested limit"
            )
            for item in page.items {
                XCTAssertTrue(
                    seenIDs.insert(item.id).inserted,
                    "item \(item.id.rawValue) must not repeat across pages"
                )
            }
            totalItems &+= page.items.count
        }
        let loadElapsed = CACurrentMediaTime() - loadStart

        XCTAssertEqual(
            totalItems, expectedCount, "must decode all seeded items")
        XCTAssertGreaterThan(loadElapsed, 0)
        XCTAssertLessThan(
            loadElapsed, 120.0, "10k live paged-load exceeded 120s")

        // --- Phase 2: cache fallback after server teardown ---

        // Simulate the background server being torn down by routing the
        // repository through a remote that always fails. The cache is the
        // same in-memory store populated in phase 1.
        let tornDownRepository = LibraryRepository(
            accountID: accountID,
            userID: account.user.id,
            remote: FailingLibraryRemoteDataSource(),
            cache: cache
        )

        let fallbackStart = CACurrentMediaTime()
        var fallbackItems = 0
        var fallbackPages = 0
        for request in requests {
            let result = try await tornDownRepository.libraryItems(
                in: library.id,
                request: request,
                policy: .remoteElseCache
            )
            XCTAssertEqual(
                result.source,
                .cache,
                "phase 2 must fall back to cache when the remote fails"
            )
            fallbackItems &+= result.value.items.count
            fallbackPages &+= 1
        }
        let fallbackElapsed = CACurrentMediaTime() - fallbackStart

        XCTAssertEqual(
            fallbackPages, expectedPages, "must serve every page from cache")
        XCTAssertEqual(
            fallbackItems, expectedCount, "must serve all 10k items from cache")
        XCTAssertGreaterThan(fallbackElapsed, 0)
        XCTAssertLessThan(
            fallbackElapsed, 30.0, "10k cache fallback exceeded 30s")

        print(
            "perf-summary live paged-load+fallback: "
                + "load \(requests.count) pages \(totalItems) items "
                + "\(String(format: "%.3f", loadElapsed))s, "
                + "fallback \(fallbackPages) pages \(fallbackItems) items "
                + "\(String(format: "%.3f", fallbackElapsed))s"
        )
    }

    // MARK: - Cache factory

    private static func makeInMemoryCache() throws -> LibraryCache {
        let schema = Schema([
            CachedLibraryCollectionRecord.self,
            CachedLibraryRecord.self,
            CachedLibraryPageRecord.self,
            CachedLibrarySearchRecord.self,
            CachedLibraryHomeRecord.self,
            CachedLibraryBookDetailRecord.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            ]
        )
        return LibraryCache(modelContainer: container)
    }
}

// MARK: - Failing remote stub

/// A `LibraryRemoteDataSource` whose every call fails, used to simulate the
/// background Audiobookshelf server being torn down for the cache-fallback
/// phase of the live performance baseline.
private actor FailingLibraryRemoteDataSource: LibraryRemoteDataSource {
    func libraries() async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibrarySummary]>
    {
        throw .unexpectedStatus(503)
    }

    func libraryItems(
        in libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<LibraryItemsPage>
    {
        throw .unexpectedStatus(503)
    }

    func search(
        in libraryID: LibraryID,
        request: LibrarySearchRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<LibrarySearchResults>
    {
        throw .unexpectedStatus(503)
    }

    func personalizedShelves(
        in libraryID: LibraryID,
        request: LibraryHomeRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibraryBookShelf]>
    {
        throw .unexpectedStatus(503)
    }

    func bookDetail(
        for itemID: LibraryItemID,
        in libraryID: LibraryID
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<LibraryBookDetail>
    {
        throw .unexpectedStatus(503)
    }
}
