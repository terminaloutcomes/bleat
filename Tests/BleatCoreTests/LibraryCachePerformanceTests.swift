import Darwin
import Foundation
import QuartzCore
import SwiftData
import Testing

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
@Suite(.serialized)
final class LibraryCachePerformanceTests {
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
    @Test
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

        #expect(elapsed > 0)
        // Loose upper bound: 200 page upserts should stay well under 10s on
        // any modern host. Recorded as evidence; not a release gate.
        #expect(elapsed < 10.0, "200-page write exceeded 10s")
        print(
            "perf-summary cache.write.10kBooks.seconds="
                + String(format: "%.6f", elapsed)
        )
    }

    // MARK: Reads

    /// Reading 200 cached pages (10,000 books) back from an in-memory cache
    /// must complete in bounded time. Decode happens inside the `LibraryCache`
    /// actor, off the main actor.
    @Test
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
            #expect(snapshot != nil, "every seeded page must decode back")
            #expect(snapshot?.page.items.count == Self.pageLimit)
        }
        let elapsed = CACurrentMediaTime() - start

        #expect(elapsed > 0)
        #expect(elapsed < 10.0, "200-page read exceeded 10s")
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
    @Test
    func testCacheReadsDoNotBlockTheMainActor() async throws {
        let childMode = CacheHeartbeatChildMode(
            rawValue: ProcessInfo.processInfo.environment[
                "BLEAT_CACHE_HEARTBEAT_CHILD"] ?? ""
        )
        switch childMode {
        case .hang?, .startupHang?:
            // The parent must kill and reap a process whose async test never
            // completes. This exercises the watchdog cleanup path directly.
            if childMode == .hang {
                writeCacheChildReadyMarker(mode: .hang)
            }
            let (stream, continuation) = AsyncStream<Void>.makeStream()
            defer { continuation.finish() }
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            return
        case .cancellation?:
            writeCacheChildReadyMarker(mode: .cancellation)
            let preCancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return try await runCacheHeartbeatChild(
                    mode: .hang, timeout: .seconds(60))
            }
            do {
                _ = try await preCancelled.value
                Issue.record("Pre-cancelled supervisor launched a child")
            } catch is CancellationError {}

            let startupLifecycle = CacheHeartbeatChildLifecycle()
            let launched = BoundedTestCounter()
            let startingChild = Task {
                try await runCacheHeartbeatChild(
                    mode: .startupHang, timeout: .seconds(60),
                    launchNotifications: launched, lifecycle: startupLifecycle)
            }
            let launch = await launched.wait(
                untilAtLeast: 1, timeout: .seconds(15))
            #expect(
                launch.reached, "startup child must launch before cancellation")
            startingChild.cancel()
            try await expectCacheChildCancellation(
                startingChild, lifecycle: startupLifecycle)

            let lifecycle = CacheHeartbeatChildLifecycle()
            let ready = BoundedTestCounter()
            let child = Task {
                try await runCacheHeartbeatChild(
                    mode: .hang, timeout: .seconds(60),
                    readyNotifications: ready, lifecycle: lifecycle)
            }
            let readiness = await ready.wait(
                untilAtLeast: 1, timeout: .seconds(15))
            #expect(
                readiness.reached,
                "nested hanging child must report readiness before cancellation"
            )
            child.cancel()
            try await expectCacheChildCancellation(child, lifecycle: lifecycle)
            print("cache-read-child=cancellation-cleanup-complete")
            return
        case .workload?:
            writeCacheChildReadyMarker(mode: .workload)
            try await Self.runCacheReadHeartbeatWorkload()
            print("cache-read-child=workload-complete")
            return
        case nil:
            break
        }

        let hangingChild = try await runCacheHeartbeatChild(
            mode: .hang,
            timeout: .seconds(1)
        )
        #expect(
            hangingChild.didTimeOut,
            "test child should time out and be terminated; child output: \(hangingChild.output)"
        )
        #expect(
            hangingChild.ready,
            "hanging child did not enter its controlled suspension before timeout; output: \(hangingChild.output)"
        )
        guard hangingChild.didTimeOut else { return }

        let workloadChild = try await runCacheHeartbeatChild(
            mode: .workload,
            timeout: .seconds(60)
        )
        #expect(
            !workloadChild.didTimeOut,
            "cache workload child exceeded 60s and was terminated; output: \(workloadChild.output)"
        )
        #expect(
            workloadChild.exitStatus == 0,
            "cache workload child failed with exit status \(String(describing: workloadChild.exitStatus)); output: \(workloadChild.output)"
        )
        #expect(
            workloadChild.ready,
            "workload child did not enter the selected test; output: \(workloadChild.output)"
        )
        #expect(
            workloadChild.executedTests == 1,
            "expected exactly one child test execution, got \(String(describing: workloadChild.executedTests)); report: \(workloadChild.report)"
        )
        #expect(
            workloadChild.testNames == [
                "testCacheReadsDoNotBlockTheMainActor()"
            ],
            "child xUnit report did not contain the selected test identity; report: \(workloadChild.report)"
        )
        #expect(
            workloadChild.output.contains("cache-read-child=workload-complete"),
            "selected test did not report workload completion; output: \(workloadChild.output)"
        )
    }

    /// The outer process watchdog bounds even a regression in cancellation
    /// cleanup, which otherwise could strand this test's structured task.
    @Test
    func testCacheHeartbeatChildCancellationReapsChild() async throws {
        let result = try await runCacheHeartbeatChild(
            mode: .cancellation, timeout: .seconds(25))
        #expect(
            !result.didTimeOut,
            "cancellation supervisor hung; output: \(result.output)")
        #expect(
            result.exitStatus == 0,
            "cancellation supervisor failed; output: \(result.output)")
        #expect(result.executedTests == 1)
        #expect(result.testNames == ["testCacheReadsDoNotBlockTheMainActor()"])
        #expect(
            result.output.contains(
                "cache-read-child=cancellation-cleanup-complete"))
    }

    private static func runCacheReadHeartbeatWorkload() async throws {
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
        // The task handle stays owned here and is always awaited. If a cache
        // read ignores cancellation indefinitely, the parent test process
        // enforces the hard deadline and kills/reaps this entire child.
        let readsTask = Task {
            do {
                for (index, request) in requests.enumerated() {
                    try Task.checkCancellation()
                    _ = try await cache.page(
                        request: request,
                        libraryID: libraryID,
                        accountID: accountID
                    )
                    try Task.checkCancellation()
                    if index == 0 {
                        await probe.markStarted()
                    }
                }
                await probe.markFinished()
            } catch {
                await probe.markFinished()
                throw error
            }
        }

        let startWait = await probe.waitForStarted(timeout: .seconds(30))
        let readsActuallyStarted = await probe.isStarted()
        let readsStarted = startWait.reached && readsActuallyStarted
        #expect(
            readsStarted,
            "cache read workload did not start before heartbeat measurement; elapsed \(startWait.elapsed), limit \(startWait.timeout)"
        )
        guard readsStarted else {
            readsTask.cancel()
            try await readsTask.value
            Issue.record(
                "Read workload finished before its first cache page completed")
            return
        }

        var mainActorTicks = 0
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if await probe.isFinished() { break }
            _ = await MainActor.run { true }
            mainActorTicks &+= 1
            try? await Task.sleep(for: .milliseconds(10))
        }
        let completionWait = await probe.waitForFinished(timeout: .seconds(5))
        #expect(
            completionWait.reached,
            "cache read workload did not complete; elapsed \(completionWait.elapsed), limit \(completionWait.timeout)"
        )
        if !completionWait.reached {
            readsTask.cancel()
        }
        // Awaiting the owned task is intentional: cooperative cancellation
        // joins it; the outer process watchdog handles a truly stuck read.
        try await readsTask.value

        #expect(
            completionWait.reached && mainActorTicks > 0,
            "main-actor heartbeat must advance while cache reads are underway; ticks=\(mainActorTicks)"
        )
        print(
            "perf-summary cache.read.mainActorHeartbeatTicks=\(mainActorTicks)")
    }

    // MARK: On-disk storage size

    /// Evidence: on-disk SwiftData store holding 10,000 cached books (200
    /// JSON-blob pages) records its file size for the release baseline.
    @Test
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

        #expect(
            mainBytes > 0, "SQLite store file must exist after 10k-book seed")
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

private struct CacheHeartbeatChildResult {
    let didTimeOut: Bool
    let ready: Bool
    let exitStatus: Int32?
    let executedTests: Int?
    let testNames: [String]?
    let output: String
    let report: String?
}

private enum CacheHeartbeatChildMode: String {
    case hang
    case startupHang
    case workload
    case cancellation
}

private enum CacheHeartbeatChildEvent: Sendable {
    case exited(Int32)
    case timedOut
    case cancelled
}

private actor CacheHeartbeatChildOutput {
    private var bytes = Data()
    private var ready = false
    private var exitStatus: Int32?
    private let readyNotifications = BoundedTestCounter()
    private let readyMarker = Data("cache-child-ready:".utf8)

    func append(_ byte: UInt8) async {
        bytes.append(byte)
        guard !ready, bytes.range(of: readyMarker) != nil else {
            return
        }
        ready = true
        await readyNotifications.increment()
    }

    func recordExit(_ status: Int32) async {
        exitStatus = status
        await readyNotifications.increment()
    }

    func waitUntilReadyOrExit(timeout: Duration) async -> BoundedTestWaitResult
    {
        if ready || exitStatus != nil {
            return BoundedTestWaitResult(
                reached: ready,
                elapsed: .zero,
                timeout: timeout
            )
        }
        let result = await readyNotifications.wait(
            untilAtLeast: 1,
            timeout: timeout
        )
        return BoundedTestWaitResult(
            reached: ready,
            elapsed: result.elapsed,
            timeout: timeout
        )
    }

    func snapshot() -> (ready: Bool, output: String) {
        (ready, String(decoding: bytes, as: UTF8.self))
    }
}

private actor CacheHeartbeatChildLifecycle {
    private var process: Process?
    private var reportDirectory: URL?
    private var rescueTask: Task<Void, Never>?
    private var rescued = false

    func record(process: Process, reportDirectory: URL) {
        self.process = process
        self.reportDirectory = reportDirectory
        // Independently contain a regression in the supervisor itself. Five
        // seconds is a rescue budget, never a readiness or success criterion.
        rescueTask = Task.detached {
            do {
                try await Task.sleep(for: .seconds(5))
            } catch { return }
            await self.rescueIfRunning()
        }
    }

    private func rescueIfRunning() {
        guard let process, process.isRunning else { return }
        rescued = true
        killCacheHeartbeatChild(process)
    }

    func finishRescue() async -> Bool {
        rescueTask?.cancel()
        await rescueTask?.value
        rescueTask = nil
        return rescued
    }

    func isCleanedUp() -> Bool {
        guard let process, let reportDirectory else { return false }
        return !process.isRunning
            && !FileManager.default.fileExists(atPath: reportDirectory.path)
    }
}

private func expectCacheChildCancellation(
    _ task: Task<CacheHeartbeatChildResult, Error>,
    lifecycle: CacheHeartbeatChildLifecycle
) async throws {
    let outcome = await task.result
    let rescued = await lifecycle.finishRescue()
    #expect(
        !rescued,
        "Supervisor cancellation required the independent rescue watchdog")
    #expect(await lifecycle.isCleanedUp())
    switch outcome {
    case .success:
        Issue.record("Cancelled child supervisor returned a result")
    case .failure(let error):
        guard error is CancellationError else { throw error }
    }
}

private func killCacheHeartbeatChild(_ process: Process) {
    guard process.isRunning else { return }
    let result = Darwin.kill(process.processIdentifier, SIGKILL)
    let failure = errno
    if result != 0 && failure != ESRCH {
        Issue.record("Could not kill owned cache child: errno=\(failure)")
    }
}

private final class CacheHeartbeatXUnitParser: NSObject, XMLParserDelegate {
    private(set) var testNames: [String] = []

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "testcase", let name = attributeDict["name"] else {
            return
        }
        testNames.append(name)
    }
}

/// Runs one selected test identity in a child process so a synchronous,
/// cancellation-insensitive SwiftData read cannot strand an async test task.
/// The parent observes process termination asynchronously and kills/reaps the
/// child at the deadline; no blocking wait or detached cache worker remains.
private func runCacheHeartbeatChild(
    mode: CacheHeartbeatChildMode,
    timeout: Duration,
    readyNotifications: BoundedTestCounter? = nil,
    launchNotifications: BoundedTestCounter? = nil,
    lifecycle: CacheHeartbeatChildLifecycle? = nil
) async throws -> CacheHeartbeatChildResult {
    try Task.checkCancellation()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let childReportDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("bleat-cache-child-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: childReportDirectory,
        withIntermediateDirectories: true
    )
    defer {
        do {
            try FileManager.default.removeItem(at: childReportDirectory)
        } catch {
            Issue.record(
                "Could not remove child test report directory: \(error)")
        }
    }
    let childReportURL = childReportDirectory.appendingPathComponent(
        "child.xunit.xml")

    if let bundleIndex = CommandLine.arguments.firstIndex(
        of: "--test-bundle-path"),
        CommandLine.arguments.indices.contains(bundleIndex + 1)
    {
        // The signed host lane invokes a provisioned SwiftPM helper. It needs
        // the test bundle and testing-library arguments on every child run.
        process.arguments = [
            "--test-bundle-path",
            CommandLine.arguments[bundleIndex + 1],
            "--testing-library",
            "swift-testing",
            "--no-parallel",
            "--filter",
            "testCacheReadsDoNotBlockTheMainActor",
            "--xunit-output",
            childReportURL.path,
        ]
    } else {
        // Unsigned SwiftPM host tests execute the test binary directly.
        process.arguments = [
            "--filter",
            "testCacheReadsDoNotBlockTheMainActor",
            "--no-parallel",
            "--xunit-output",
            childReportURL.path,
        ]
    }

    var environment = ProcessInfo.processInfo.environment
    environment["BLEAT_CACHE_HEARTBEAT_CHILD"] = mode.rawValue
    if environment["LLVM_PROFILE_FILE"]?.contains("%p") != true {
        // Preserve per-process child coverage without colliding with a parent
        // profile when the host lane did not already provide a PID template.
        environment["LLVM_PROFILE_FILE"] =
            childReportDirectory
            .appendingPathComponent("coverage-%p.profraw").path
    }
    process.environment = environment

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    let outputProbe = CacheHeartbeatChildOutput()
    let terminationEvents = AsyncStream<Int32> { continuation in
        process.terminationHandler = { terminatedProcess in
            continuation.yield(terminatedProcess.terminationStatus)
            continuation.finish()
        }
    }
    try Task.checkCancellation()
    try process.run()
    await lifecycle?.record(
        process: process, reportDirectory: childReportDirectory)
    let terminationTask = Task.detached {
        let event = await waitForCacheHeartbeatTermination(terminationEvents)
        if case .exited(let status) = event {
            await outputProbe.recordExit(status)
        }
        return event
    }
    do {
        try outputPipe.fileHandleForWriting.close()
    } catch {
        if process.isRunning {
            killCacheHeartbeatChild(process)
        }
        _ = await terminationTask.value
        throw error
    }

    // Drain output while the child runs; a pipe that is not consumed can fill
    // and block the test process before the timeout handler gets a chance.
    let outputReader = Task.detached {
        do {
            for try await byte in outputPipe.fileHandleForReading.bytes {
                await outputProbe.append(byte)
            }
        } catch {
            Issue.record("Could not read cache child output: \(error)")
        }
    }
    await launchNotifications?.increment()

    // Keep the readiness budget alive when the caller is already cancelled.
    // Cancellation kills the child, whose retained observer wakes readiness.
    let readinessTask = Task.detached {
        await outputProbe.waitUntilReadyOrExit(timeout: .seconds(15))
    }
    let readyWait = await withTaskCancellationHandler {
        await readinessTask.value
    } onCancel: {
        if process.isRunning {
            killCacheHeartbeatChild(process)
        }
    }
    let initialOutput = await outputProbe.snapshot()
    let ready = readyWait.reached && initialOutput.ready

    let event: CacheHeartbeatChildEvent
    if ready {
        await readyNotifications?.increment()
        event = await waitForCacheHeartbeatChild(
            terminationTask,
            process: process,
            timeout: timeout
        )
    } else {
        // A broken test filter or runner setup must also have bounded cleanup.
        let stillRunning = process.isRunning
        if stillRunning {
            killCacheHeartbeatChild(process)
        }
        let terminalEvent = await terminationTask.value
        event =
            Task.isCancelled
            ? .cancelled : (stillRunning ? .timedOut : terminalEvent)
    }

    await outputReader.value
    let outputSnapshot = await outputProbe.snapshot()
    let report = try? String(contentsOf: childReportURL, encoding: .utf8)
    let testNames = report.flatMap { reportText -> [String]? in
        let delegate = CacheHeartbeatXUnitParser()
        let parser = XMLParser(data: Data(reportText.utf8))
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.testNames
    }
    let executedTests = testNames?.count

    try Task.checkCancellation()
    switch event {
    case .cancelled:
        throw CancellationError()
    case .exited(let status):
        return CacheHeartbeatChildResult(
            didTimeOut: false,
            ready: ready,
            exitStatus: status,
            executedTests: executedTests,
            testNames: testNames,
            output: outputSnapshot.output,
            report: report
        )
    case .timedOut:
        return CacheHeartbeatChildResult(
            didTimeOut: true,
            ready: ready,
            exitStatus: nil,
            executedTests: executedTests,
            testNames: testNames,
            output: outputSnapshot.output,
            report: report
        )
    }
}

private func waitForCacheHeartbeatChild(
    _ terminationTask: Task<CacheHeartbeatChildEvent, Never>,
    process: Process,
    timeout: Duration
) async -> CacheHeartbeatChildEvent {
    await withTaskGroup(of: CacheHeartbeatChildEvent.self) { group in
        group.addTask {
            await terminationTask.value
        }
        group.addTask {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return .cancelled
            }
            return .timedOut
        }
        let firstEvent = await group.next() ?? .timedOut
        switch firstEvent {
        case .exited:
            group.cancelAll()
            return firstEvent
        case .timedOut, .cancelled:
            if process.isRunning {
                killCacheHeartbeatChild(process)
            }
            // The retained observer proves OS termination and reap.
            _ = await terminationTask.value
            _ = await group.next()
            group.cancelAll()
            return firstEvent
        }
    }
}

private func waitForCacheHeartbeatTermination(
    _ terminationEvents: AsyncStream<Int32>
) async -> CacheHeartbeatChildEvent {
    var iterator = terminationEvents.makeAsyncIterator()
    return .exited(await iterator.next() ?? -1)
}

private func writeCacheChildReadyMarker(mode: CacheHeartbeatChildMode) {
    FileHandle.standardOutput.write(
        Data("cache-child-ready:\(mode.rawValue)\n".utf8)
    )
}

// MARK: - Completion probe

/// Lightweight flag actor used to synchronize the off-main regression test
/// on the read workload actually starting and completing. The `started`
/// flag is set after the first `cache.page(...)` call returns inside the
/// owned task, so the heartbeat loop can prove main-actor progress
/// while decode work is genuinely underway rather than before it begins.
actor ReadsCompletionProbe {
    private var started = false
    private var finished = false
    private let startOutcomeNotifications = BoundedTestCounter()
    private let finishedNotifications = BoundedTestCounter()

    func markStarted() async {
        guard !started else { return }
        started = true
        await startOutcomeNotifications.increment()
    }

    func markFinished() async {
        guard !finished else { return }
        finished = true
        if !started {
            await startOutcomeNotifications.increment()
        }
        await finishedNotifications.increment()
    }

    func isStarted() -> Bool { started }
    func isFinished() -> Bool { finished }

    func waitForStarted(timeout: Duration) async -> BoundedTestWaitResult {
        await startOutcomeNotifications.wait(untilAtLeast: 1, timeout: timeout)
    }

    func waitForFinished(timeout: Duration) async -> BoundedTestWaitResult {
        await finishedNotifications.wait(untilAtLeast: 1, timeout: timeout)
    }
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
