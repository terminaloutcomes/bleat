import XCTest

/// 10,000-book Simulator performance baseline for GitHub issue
/// #46 / spec section 19.
///
/// Launches the app with the `--ui-testing-large-library` scenario, which
/// routes `AppModel` browsing through `UITestAppService`'s synthetic 10,000-
/// book paged dataset (see `App/UITestAppService.swift`). The fixture is
/// included only when the performance script defines `BLEAT_UI_TESTING`.
///
/// Records launch time, time-to-first-page, bounded "Load More" paging,
/// search responsiveness, and a qualitative responsiveness note. Energy is
/// not measurable on the Simulator and is recorded as deferred.
final class BleatPerformanceUITests: XCTestCase {
    private let scenario = "--ui-testing-large-library"
    private let seedCount =
        ProcessInfo.processInfo.environment[
            "BLEAT_PERF_SEED_COUNT"
        ] ?? "10000"

    @MainActor
    func testTenKBooksLaunchBrowsingAndSearchPerformance() throws {
        let app = XCUIApplication()
        app.launchArguments = [scenario]
        app.launchEnvironment["BLEAT_PERF_SEED_COUNT"] = seedCount
        let launchStart = CACurrentMediaTime()
        app.launch()

        // The app lands on the Home tab; switch to Library to browse the
        // 10,000-book dataset.
        let libraryTab = tabButton("Library", in: app)
        XCTAssertTrue(
            libraryTab.waitForExistence(timeout: 30),
            "Library tab must be available after launch"
        )
        libraryTab.tap()

        // Time-to-first-page: first book row appearing means the library
        // loaded and rendered the first 20 books.
        let firstRow = app.buttons["library.book.book-0"]
        XCTAssertTrue(
            firstRow.waitForExistence(timeout: 30),
            "first library book must appear within 30s of launch"
        )
        let timeToFirstPage = CACurrentMediaTime() - launchStart
        XCTAssertGreaterThan(timeToFirstPage, 0)

        // Capture resident memory after the first page renders.
        let memoryAfterLaunch = app.staticTexts["perf.memory"].label

        // Bounded "Load More" paging: the button sits below the rendered
        // rows, so scroll the list to reveal it before each tap. Measure
        // 3 bounded taps. A SwiftUI List exposes a scrollable container (scrollView,
        // collectionView, or table depending on OS); swipe on whichever is
        // present rather than a specific row, which may be recycled out of
        // the lazy tree.
        let loadMore = app.buttons["books.loadMore"]
        let scrollContainer: XCUIElement = {
            for candidate in [
                app.scrollViews.firstMatch,
                app.collectionViews.firstMatch,
                app.tables.firstMatch,
            ] where candidate.exists {
                return candidate
            }
            return app.scrollViews.firstMatch
        }()
        let pagingStart = CACurrentMediaTime()
        var tapsCompleted = 0
        let boundedTaps = 3
        for tap in 1...boundedTaps {
            // Reveal the Load More button by swiping up until it exists.
            var revealAttempts = 0
            while !loadMore.exists && revealAttempts < 8 {
                scrollContainer.swipeUp(velocity: .fast)
                revealAttempts += 1
            }
            guard loadMore.waitForExistence(timeout: 5) else { break }
            loadMore.tap()
            // Prove the page actually loaded by waiting for the first row
            // of the newly loaded page to appear. At limit 20, page N
            // (0-indexed) starts at book-{20*N}; after tap number `tap`,
            // page `tap` loads, whose first book is book-{20*tap}. This
            // avoids counting taps that fire before the previous load
            // completes, which `waitForExistence` on the Load More button
            // itself cannot distinguish because the button has not yet
            // disappeared.
            let expectedNewRow = app.buttons[
                "library.book.book-\(20 * tap)"
            ]
            var rowRevealAttempts = 0
            while !expectedNewRow.exists && rowRevealAttempts < 10 {
                scrollContainer.swipeUp(velocity: .slow)
                rowRevealAttempts += 1
            }
            guard expectedNewRow.waitForExistence(timeout: 10) else { break }
            tapsCompleted += 1
        }
        let pagingElapsed = CACurrentMediaTime() - pagingStart

        // Capture resident memory after paging.
        let memoryAfterPaging = app.staticTexts["perf.memory"].label

        // Search responsiveness: navigate to the dedicated Search tab and
        // type a query. The search field may need an explicit present
        // action on some OS versions.
        tabButton("Search", in: app).tap()
        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 3) {
            let presentSearch = app.navigationBars["Search"].buttons["Search"]
            XCTAssertTrue(presentSearch.waitForExistence(timeout: 3))
            presentSearch.tap()
        }
        XCTAssertTrue(
            searchField.waitForExistence(timeout: 5),
            "search field must be available on the Search tab"
        )
        searchField.tap()
        let searchStart = CACurrentMediaTime()
        searchField.typeText("Book")
        let firstSearchResult = app.buttons["search.book.book-0"]
        let searchAppeared = firstSearchResult.waitForExistence(timeout: 15)
        let searchElapsed = CACurrentMediaTime() - searchStart

        // Capture resident memory after search.
        let memoryAfterSearch = app.staticTexts["perf.memory"].label

        let summary = """
            Performance evidence: 10,000-book Simulator baseline
            scenario: \(scenario)
            seedCount: \(seedCount)
            os: \(ProcessInfo.processInfo.operatingSystemVersionString)
            - timeToFirstPage.seconds: \(String(format: "%.3f", timeToFirstPage))
            - loadMore.tapsCompleted: \(tapsCompleted)
            - loadMore.3taps.seconds: \(String(format: "%.3f", pagingElapsed))
            - search.resultsAppeared: \(searchAppeared)
            - search.seconds: \(String(format: "%.3f", searchElapsed))
            - memory.afterLaunch.bytes: \(memoryAfterLaunch)
            - memory.afterPaging.bytes: \(memoryAfterPaging)
            - memory.afterSearch.bytes: \(memoryAfterSearch)
            - energy: Simulator cannot measure energy; physical-device evidence deferred
            """
        print(
            "perf-summary "
                + summary.replacingOccurrences(of: "\n", with: " | "))
        let attachment = XCTAttachment(string: summary)
        attachment.name = "performance-baseline.json"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertLessThan(
            timeToFirstPage, 30.0, "first page must render within 30s")
        XCTAssertEqual(
            tapsCompleted,
            boundedTaps,
            "all \(boundedTaps) Load More taps must complete"
        )
        // The bound reflects Simulator scroll-to-reveal cost, not page-load
        // cost (the host-side AppModel test evidences 500 pages decode in
        // ~1.6s). 3 bounded Load More cycles must stay under 120s.
        XCTAssertLessThan(
            pagingElapsed, 120.0, "Load More paging must stay bounded")
        XCTAssertTrue(searchAppeared, "search results must appear")
        XCTAssertLessThan(
            searchElapsed, 15.0, "search results must appear within 15s")
    }
}
