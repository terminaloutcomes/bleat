import Foundation
import SwiftData
import XCTest

@testable import BleatCore

// MARK: - Synthetic dataset generator

/// Deterministic generator for 10,000-book performance fixtures.
///
/// Values are derived purely from the sequence index so every run produces
/// the same dataset, making timings comparable across runs and machines.
enum LibraryBookSummaryGenerator {
    /// Returns a book summary for the given zero-based sequence index.
    static func book(index: Int, libraryID: LibraryID) -> LibraryBookSummary {
        let authorPool = [
            "Author One", "Author Two", "Author Three", "Author Four",
            "Co-Author Alpha", "Co-Author Beta", "Writer One", "Writer Two",
            "Historian", "Poet", "Scientist", "Explorer", "Philosopher",
            "Novelist", "Critic", "Dreamer", "Traveler", "Archivist",
        ]
        let genrePool = [
            "Fiction", "Non-Fiction", "Science Fiction", "Fantasy",
            "Mystery", "Biography", "History", "Romance", "Thriller",
            "Adventure", "Horror", "Drama", "Comedy",
        ]
        let authorName = authorPool[index % authorPool.count]
        let seriesIndex = index % 12
        let seriesName = seriesIndex > 0 ? "Series \(seriesIndex)" : nil
        let genreCount = (index % 3) + 1
        let genres = (0..<genreCount).map { i in
            genrePool[(index + i) % genrePool.count]
        }
        let tagCount = index % 4
        let tags = (0..<tagCount).map { i in "tag-\((index + i) % 9)" }
        let years = ["1950", "1970", "1990", "2010", "2020"]
        let baseMillis = Int64(1_700_000_000_000) + Int64(index) * 3_600_000
        let authorID = AuthorID(rawValue: "author-\(index % authorPool.count)")!
        let seriesID = SeriesID(rawValue: "series-\(seriesIndex)")!

        return LibraryBookSummary(
            id: LibraryItemID(rawValue: "book-\(index)"),
            libraryID: libraryID,
            title: "Book Title \(index)",
            subtitle: index % 5 == 0 ? "Subtitle \(index)" : nil,
            authorName: authorName,
            narratorName: index % 3 == 0 ? "Narrator \(index % 7)" : nil,
            seriesName: seriesName,
            authors: [
                LibraryBookContributor(id: authorID, name: authorName)
            ],
            series: seriesName.map { name in
                [
                    LibraryBookSeries(
                        id: seriesID,
                        name: name,
                        sequence: "\(index % 20)"
                    )
                ]
            } ?? [],
            collapsedSeries: nil,
            genres: genres,
            tags: tags,
            publisher: index % 2 == 0 ? "Publisher \(index % 6)" : nil,
            publishedYear: years[index % years.count],
            duration: Double(45 + (index % 436)),
            trackCount: (index % 20) + 1,
            chapterCount: (index % 150) + 1,
            addedAtMilliseconds: baseMillis,
            updatedAtMilliseconds: baseMillis + Int64((index % 24) * 3_600_000),
            isExplicit: index % 10 == 0,
            isAbridged: index % 25 == 0
        )
    }

    /// Builds a page containing `limit` books starting at `page * limit`.
    static func page(
        pageIndex: Int,
        limit: Int,
        total: Int,
        libraryID: LibraryID
    ) -> LibraryItemsPage {
        let startIndex = pageIndex * limit
        let endIndex = min(startIndex + limit, total)
        let items = (startIndex..<endIndex).map { index in
            book(index: index, libraryID: libraryID)
        }
        return LibraryItemsPage(
            items: items,
            total: total,
            page: pageIndex,
            limit: limit
        )
    }
}

// MARK: - Fixture

/// Schema + container fixture mirroring `LibraryCacheTests`'s private fixture,
/// with both in-memory and on-disk configurations for the performance suite.
enum LibraryCachePerformanceFixture {
    private static func makeSchema() -> Schema {
        Schema([
            CachedLibraryCollectionRecord.self,
            CachedLibraryRecord.self,
            CachedLibraryPageRecord.self,
            CachedLibrarySearchRecord.self,
            CachedLibraryHomeRecord.self,
            CachedLibraryBookDetailRecord.self,
        ])
    }

    static func memory() throws -> (ModelContainer, LibraryCache) {
        let schema = makeSchema()
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            ]
        )
        return (container, LibraryCache(modelContainer: container))
    }

    static func onDisk(directory: URL) throws -> (ModelContainer, LibraryCache)
    {
        let schema = makeSchema()
        let storeURL = directory.appendingPathComponent("bleat-perf.sqlite")
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(schema: schema, url: storeURL)
            ]
        )
        return (container, LibraryCache(modelContainer: container))
    }
}

// MARK: - Performance tests

/// Host-side 10,000-book cache performance baseline for spec section 19 /
/// GitHub issue #46.
///
/// These tests run on the host via `swift test` (no Simulator, no Docker).
/// They evidence that cache writes, reads, and decode of 10,000 cached books
/// (stored as 200 JSON-blob pages at limit 50) stay off the main actor and
/// complete in bounded time. Timings and storage totals are printed as
/// machine-readable `perf-summary` lines for release evidence retention.
final class LibraryCachePerformanceTests: XCTestCase {
    static let totalBooks = 10_000
    static let pageLimit = 50
    static let pageCount = totalBooks / pageLimit  // 200

    private static func makeRequest(pageIndex: Int) throws
        -> LibraryItemsPageRequest
    {
        try LibraryItemsPageRequest(
            page: pageIndex,
            limit: pageLimit,
            sort: .title,
            descending: false,
            filter: nil,
            includeProgress: false,
            collapseSeries: false,
            minified: true
        )
    }

    private static func makePages(libraryID: LibraryID) -> [LibraryItemsPage] {
        (0..<pageCount).map { pageIndex in
            LibraryBookSummaryGenerator.page(
                pageIndex: pageIndex,
                limit: pageLimit,
                total: totalBooks,
                libraryID: libraryID
            )
        }
    }

    // MARK: Writes

    /// Saving 200 pages (10,000 books) into an in-memory cache must complete
    /// in bounded time. Each save encodes one page to JSON and upserts one
    /// `CachedLibraryPageRecord` inside the `LibraryCache` actor (off-main).
    func testTenKBooksCacheWritePerformance() async throws {
        let (_, cache) = try LibraryCachePerformanceFixture.memory()
        let accountID = AccountID(rawValue: "perf-account")
        let libraryID = LibraryID(rawValue: "perf-library")
        let pages = Self.makePages(libraryID: libraryID)

        let start = CACurrentMediaTime()
        for (pageIndex, page) in pages.enumerated() {
            let request = try Self.makeRequest(pageIndex: pageIndex)
            try await cache.savePage(
                page,
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
        }
        let elapsed = CACurrentMediaTime() - start

        XCTAssertGreaterThan(elapsed, 0)
        // Loose upper bound: 200 page upserts should stay well under 10s on
        // any modern host. Recorded as evidence; not a release gate.
        XCTAssertLessThan(elapsed, 10.0, "200-page write exceeded 10s")
        print(
            "perf-summary cache.write.10kBooks.seconds="
                + String(format: "%.6f", elapsed)
        )
    }

    // MARK: Reads

    /// Reading 200 cached pages (10,000 books) back from an in-memory cache
    /// must complete in bounded time. Decode happens inside the `LibraryCache`
    /// actor, off the main actor.
    func testTenKBooksCacheReadPerformance() async throws {
        let (_, cache) = try LibraryCachePerformanceFixture.memory()
        let accountID = AccountID(rawValue: "perf-account")
        let libraryID = LibraryID(rawValue: "perf-library")
        let requests = try (0..<Self.pageCount).map(Self.makeRequest)
        for (pageIndex, request) in requests.enumerated() {
            let page = LibraryBookSummaryGenerator.page(
                pageIndex: pageIndex,
                limit: Self.pageLimit,
                total: Self.totalBooks,
                libraryID: libraryID
            )
            try await cache.savePage(
                page,
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
        }

        let start = CACurrentMediaTime()
        for request in requests {
            let snapshot = try await cache.page(
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
            XCTAssertNotNil(snapshot, "every seeded page must decode back")
            XCTAssertEqual(snapshot?.page.items.count, Self.pageLimit)
        }
        let elapsed = CACurrentMediaTime() - start

        XCTAssertGreaterThan(elapsed, 0)
        XCTAssertLessThan(elapsed, 10.0, "200-page read exceeded 10s")
        print(
            "perf-summary cache.read.10kBooks.seconds="
                + String(format: "%.6f", elapsed)
        )
    }

    // MARK: Off-main-actor regression

    /// Regression: cache decode must not block the main actor. The
    /// `LibraryCache` actor runs `page(...)` off-main; this test evidences
    /// that by confirming a main-actor heartbeat keeps advancing while 200
    /// cache reads run concurrently.
    func testCacheReadsDoNotBlockTheMainActor() async throws {
        let (_, cache) = try LibraryCachePerformanceFixture.memory()
        let accountID = AccountID(rawValue: "perf-account")
        let libraryID = LibraryID(rawValue: "perf-library")
        let requests = try (0..<Self.pageCount).map(Self.makeRequest)
        for (pageIndex, request) in requests.enumerated() {
            let page = LibraryBookSummaryGenerator.page(
                pageIndex: pageIndex,
                limit: Self.pageLimit,
                total: Self.totalBooks,
                libraryID: libraryID
            )
            try await cache.savePage(
                page,
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
        }

        let probe = ReadsCompletionProbe()
        let readsTask = Task.detached {
            for (index, request) in requests.enumerated() {
                _ = try await cache.page(
                    request: request,
                    libraryID: libraryID,
                    accountID: accountID
                )
                if index == 0 {
                    await probe.markStarted()
                }
            }
            await probe.markFinished()
        }

        // Wait for the read workload to actually start before counting
        // heartbeat ticks. Otherwise the first main-actor hop could occur
        // before any decode is underway, and `ticks > 0` would not prove
        // the main actor stays responsive while decoding happens.
        let startDeadline = Date().addingTimeInterval(30)
        while Date() < startDeadline {
            if await probe.isStarted() { break }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        let readsStarted = await probe.isStarted()
        XCTAssertTrue(
            readsStarted,
            "detached read workload must start before heartbeat is measured"
        )

        var mainActorTicks = 0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            // Check that the read workload is still underway BEFORE hopping
            // to the main actor and counting a tick. Otherwise the workload
            // could finish before the first check and `ticks > 0` would not
            // prove any overlapping main-actor progress.
            if await probe.isFinished() { break }
            // Hop to the main actor and back. If cache work were running on
            // the main actor, this hop could not complete and ticks would
            // not advance.
            _ = await MainActor.run { true }
            mainActorTicks &+= 1
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try await readsTask.value

        XCTAssertGreaterThan(
            mainActorTicks,
            0,
            "main-actor heartbeat must advance while cache reads are underway"
        )
        print(
            "perf-summary cache.read.mainActorHeartbeatTicks=\(mainActorTicks)"
        )
    }

    // MARK: On-disk storage size

    /// Evidence: on-disk SwiftData store holding 10,000 cached books (200
    /// JSON-blob pages) records its file size for the release baseline.
    func testTenKBooksOnDiskStorageSize() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bleat-perf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let (_, cache) = try LibraryCachePerformanceFixture.onDisk(
            directory: tempDir
        )
        let accountID = AccountID(rawValue: "perf-account")
        let libraryID = LibraryID(rawValue: "perf-library")
        let requests = try (0..<Self.pageCount).map(Self.makeRequest)
        for (pageIndex, request) in requests.enumerated() {
            let page = LibraryBookSummaryGenerator.page(
                pageIndex: pageIndex,
                limit: Self.pageLimit,
                total: Self.totalBooks,
                libraryID: libraryID
            )
            try await cache.savePage(
                page,
                request: request,
                libraryID: libraryID,
                accountID: accountID
            )
        }

        let storeURL = tempDir.appendingPathComponent("bleat-perf.sqlite")
        let walURL = tempDir.appendingPathComponent("bleat-perf.sqlite-wal")
        let shmURL = tempDir.appendingPathComponent("bleat-perf.sqlite-shm")
        let mainBytes = fileBytes(at: storeURL)
        let walBytes = fileBytes(at: walURL)
        let shmBytes = fileBytes(at: shmURL)
        let totalBytes = mainBytes + walBytes + shmBytes

        XCTAssertGreaterThan(
            mainBytes, 0, "SQLite store file must exist after 10k-book seed")
        print(
            "perf-summary cache.storage.10kBooks.sqliteBytes=\(mainBytes)"
        )
        print(
            "perf-summary cache.storage.10kBooks.walBytes=\(walBytes)"
        )
        print(
            "perf-summary cache.storage.10kBooks.shmBytes=\(shmBytes)"
        )
        print(
            "perf-summary cache.storage.10kBooks.totalBytes=\(totalBytes)"
        )
    }
}

// MARK: - Completion probe

/// Lightweight flag actor used to synchronize the off-main regression test
/// on the read workload actually starting and completing. The `started`
/// flag is set after the first `cache.page(...)` call returns inside the
/// detached task, so the heartbeat loop can prove main-actor progress
/// while decode work is genuinely underway rather than before it begins.
actor ReadsCompletionProbe {
    private var started = false
    private var finished = false

    func markStarted() { started = true }
    func markFinished() { finished = true }
    func isStarted() -> Bool { started }
    func isFinished() -> Bool { finished }
}

// MARK: - File helper

private func fileBytes(at url: URL) -> Int64 {
    guard
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
        let size = attrs[.size] as? NSNumber
    else {
        return 0
    }
    return size.int64Value
}
