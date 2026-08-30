import XCTest

final class BleatDynamicTypeUITests: XCTestCase {
    private let largestContentSizeArguments = [
        "-UIPreferredContentSizeCategoryName",
        "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
    ]

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testLoginRemainsUsableAtLargestDynamicType() {
        let app = launch(scenario: "--ui-testing-signed-out")
        let form = app.collectionViews["login.form"]

        let server = assertUsable(app.textFields["login.server"], in: app)
        server.tap()
        server.typeText("https://books.example")

        let username = app.textFields["login.username"]
        scrollUntilHittable(username, in: form, app: app)
        assertUsable(username, in: app).tap()
        username.typeText("reader")

        let password = app.secureTextFields["login.password"]
        scrollUntilHittable(password, in: form, app: app)
        assertUsable(password, in: app).tap()
        password.typeText("native-password")
        let keyboardDone = app.keyboards.buttons["Done"]
        XCTAssertTrue(keyboardDone.waitForExistence(timeout: 10))
        XCTAssertTrue(keyboardDone.isHittable)
        keyboardDone.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))

        let signedIn = app.otherElements["app.signedIn"]
        let submit = app.buttons["login.submit"]
        scrollUntilHittable(submit, in: form, app: app)
        XCTAssertTrue(submit.isEnabled)
        assertUsable(submit, in: app).tap()
        assertVisible(signedIn, in: app)
    }

    @MainActor
    func testPrimaryJourneysRemainUsableAtLargestDynamicType() {
        let app = launch(scenario: "--ui-testing-signed-in")

        assertVisible(app.descendants(matching: .any)["home.shelves"], in: app)
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        assertUsable(homeBook, in: app)

        assertUsable(tabButton("Library", in: app), in: app).tap()
        let library = app.descendants(matching: .any)["books.list"]
        assertVisible(library, in: app)
        let libraryBook = app.buttons["library.book.ui-book"]
        let quickPlay = app.buttons["library.book.ui-book.play"]
        assertUsable(libraryBook, in: app)
        assertUsable(quickPlay, in: app)

        assertUsable(tabButton("Home", in: app), in: app).tap()
        assertUsable(homeBook, in: app).tap()
        let detail = app.descendants(matching: .any)["book.detail"]
        assertVisible(detail, in: app)
        assertVisible(
            app.descendants(matching: .any)["book.detail.title"],
            in: app
        )
        for identifier in [
            "book.detail.author.0",
            "book.detail.author.1",
            "book.detail.series.0",
            "book.detail.series.1",
        ] {
            let control = app.buttons[identifier]
            scrollUntilHittable(control, in: detail, app: app)
            assertUsable(control, in: app)
        }
        for identifier in ["book.detail.play", "book.detail.download"] {
            let control = app.buttons[identifier]
            scrollUntilHittable(control, in: detail, app: app)
            assertUsable(control, in: app)
        }
        assertUsable(app.navigationBars.buttons.firstMatch, in: app).tap()

        assertUsable(tabButton("Downloads", in: app), in: app).tap()
        assertUsable(app.navigationBars["Downloads"], in: app)
        assertVisible(app.staticTexts["No Downloads"], in: app)

        assertUsable(tabButton("Settings", in: app), in: app).tap()
        let settings = app.collectionViews.firstMatch
        assertVisible(app.navigationBars["Settings"], in: app)
        let reset = app.buttons["settings.resetLocalData"]
        scrollUntilHittable(reset, in: settings, app: app)
        assertUsable(reset, in: app).tap()
        let resetMessage = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "This cannot be undone."
            )
        ).firstMatch
        assertVisible(resetMessage, in: app)
        assertUsable(
            app.buttons["settings.resetLocalData.confirm"].firstMatch,
            in: app
        )
        let dismissRegion = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "dismiss popup")
        ).firstMatch
        assertUsable(dismissRegion, in: app).tap()
        XCTAssertTrue(
            app.buttons["settings.resetLocalData.confirm"].firstMatch
                .waitForNonExistence(timeout: 5)
        )

        assertUsable(tabButton("Search", in: app), in: app).tap()
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 1) {
            assertUsable(
                app.navigationBars["Search"].buttons["Search"],
                in: app
            ).tap()
        }
        assertUsable(search, in: app).tap()
        search.typeText("Test")
        let searchResults = app.descendants(matching: .any)["search.results"]
        assertVisible(searchResults, in: app)
        assertUsable(app.buttons["search.book.ui-search-book"], in: app)
        assertUsable(app.buttons["search.done"], in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testPlaybackRemainsUsableAtLargestDynamicType() {
        let app = launch(scenario: "--ui-testing-playback")
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        assertUsable(homeBook, in: app).tap()

        let detail = app.descendants(matching: .any)["book.detail"]
        let play = app.buttons["book.detail.play"]
        scrollUntilHittable(play, in: detail, app: app)
        assertUsable(play, in: app).tap()

        let miniPlayer = app.buttons["player.mini.open"]
        let miniToggle = app.buttons["player.mini.toggle"]
        assertUsable(miniPlayer, in: app)
        assertUsable(miniToggle, in: app)
        for label in ["Home", "Library", "Downloads", "Settings", "Search"] {
            let tab = assertUsable(tabButton(label, in: app), in: app)
            XCTAssertFalse(
                miniPlayer.frame.intersects(tab.frame),
                "Mini-player overlaps the \(label) tab"
            )
        }

        miniPlayer.tap()
        let playerScreen = app.otherElements["player.screen"]
        let playerScroll = app.descendants(matching: .any)["player.scroll"]
        assertVisible(playerScreen, in: app)
        assertVisible(playerScroll, in: app)
        assertVisible(app.staticTexts["player.currentChapter"], in: app)

        for identifier in [
            "player.toggle",
            "player.rate",
            "player.chapters",
            "player.sleepTimer",
            "player.bookmarks",
            "player.airPlay",
        ] {
            let control = app.descendants(matching: .any)[identifier]
            scrollUntilHittable(control, in: playerScroll, app: app)
            assertUsable(control, in: app)
        }

        let chapters = app.buttons["player.chapters"]
        chapters.tap()
        let chapterPicker = app.descendants(matching: .any)[
            "player.chapterPicker"
        ]
        assertVisible(chapterPicker, in: app)
        assertUsable(app.buttons["player.chapter.0"], in: app)
        assertUsable(app.buttons["Done"], in: app).tap()
        XCTAssertTrue(chapterPicker.waitForNonExistence(timeout: 5))

        scrollUntilHittable(
            app.buttons["player.bookmarks"],
            in: playerScroll,
            app: app
        )
        app.buttons["player.bookmarks"].tap()
        assertUsable(app.buttons["Add Bookmark"], in: app).tap()
        assertUsable(app.textFields["bookmark.title"], in: app)
        assertUsable(app.buttons["Cancel"], in: app).tap()
        XCTAssertTrue(
            app.textFields["bookmark.title"].waitForNonExistence(timeout: 5)
        )

        assertUsable(app.buttons["Close"], in: app).tap()
        assertVisible(app.descendants(matching: .any)["book.detail"], in: app)
    }

    @MainActor
    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [scenario] + largestContentSizeArguments
        app.launch()
        return app
    }

    @MainActor
    @discardableResult
    private func assertUsable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)")
        assertWithinWindow(element, in: app)
        XCTAssertTrue(
            element.isHittable,
            "Not hittable \(element), element frame: \(element.frame), application frame: \(app.frame)"
        )
        return element
    }

    @MainActor
    private func assertVisible(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "Missing \(element)")
        assertWithinWindow(element, in: app)
    }

    @MainActor
    private func assertWithinWindow(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertFalse(element.frame.isEmpty, "Empty frame for \(element)")
        XCTAssertTrue(
            app.frame.contains(element.frame),
            "Out-of-bounds \(element), element frame: \(element.frame), application frame: \(app.frame)"
        )
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in container: XCUIElement,
        app: XCUIApplication
    ) {
        XCTAssertTrue(
            container.waitForExistence(timeout: 5),
            "Missing scroll container \(container)"
        )
        for _ in 0..<30 {
            if element.exists,
                app.frame.contains(element.frame),
                element.isHittable
            {
                return
            }
            let scrollsTowardTop = !element.exists
                || element.frame.midY >= app.frame.midY
            let start = container.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 0.1,
                    dy: scrollsTowardTop ? 0.7 : 0.3
                )
            )
            let end = container.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 0.1,
                    dy: scrollsTowardTop ? 0.4 : 0.6
                )
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not scroll to hittable element \(element) in \(container)")
    }
}
