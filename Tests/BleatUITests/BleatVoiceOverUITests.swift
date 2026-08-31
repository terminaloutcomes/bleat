import XCTest

final class BleatVoiceOverUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testLoginVoiceOverSemantics() throws {
        let app = launch(scenario: "--ui-testing-signed-out")
        let form = app.collectionViews["login.form"]

        assertAnnouncement(app.textFields["login.server"], label: "Server URL")
        assertAnnouncement(app.textFields["login.username"], label: "Username")
        assertAnnouncement(
            app.secureTextFields["login.password"], label: "Password"
        )
        assertAnnouncement(app.buttons["Show password"], label: "Show password")
        assertAnnouncement(app.buttons["login.submit"], label: "Sign In")

        assertTopToBottomOrder(
            [
                app.textFields["login.server"],
                app.textFields["login.username"],
                app.secureTextFields["login.password"],
            ],
            in: form
        )
        try auditVisibleSemantics(in: app)
    }

    @MainActor
    func testPrimaryJourneyVoiceOverSemantics() throws {
        let app = launch(scenario: "--ui-testing-signed-in")

        assertAnnouncement(
            app.buttons["home.book.ui-book"],
            label: "Open The Test Audiobook"
        )
        assertAnnouncement(
            app.buttons["home.book.ui-book.play"],
            label: "Play The Test Audiobook"
        )
        assertSelectedTab("Home", in: app)
        try auditVisibleSemantics(in: app)

        tabButton("Library", in: app).tap()
        assertAnnouncement(app.buttons["library.sort"], label: "Title")
        assertAnnouncement(
            app.buttons["library.sortDirection"], label: "Ascending"
        )
        assertAnnouncement(
            app.descendants(matching: .any)["library.filter"],
            label: "All Books"
        )
        assertSelectedTab("Library", in: app)
        try auditVisibleSemantics(in: app)

        tabButton("Home", in: app).tap()
        app.buttons["home.book.ui-book"].tap()
        let detail = app.descendants(matching: .any)["book.detail"]
        assertAnnouncement(
            app.buttons["book.detail.play"], label: "Start The Test Audiobook"
        )
        assertAnnouncement(
            app.buttons["book.detail.download"],
            label: "Download The Test Audiobook"
        )
        assertAnnouncement(
            app.buttons["book.detail.author.0"],
            label: "Show books by Test Author"
        )
        scrollUntilHittable(
            app.buttons["book.detail.download"], in: detail, app: app
        )
        try auditVisibleSemantics(in: app)
        app.navigationBars.buttons.firstMatch.tap()

        tabButton("Downloads", in: app).tap()
        assertAnnouncement(
            app.staticTexts["No Downloads"], label: "No Downloads")
        assertSelectedTab("Downloads", in: app)
        try auditVisibleSemantics(in: app)

        tabButton("Settings", in: app).tap()
        let settings = app.descendants(matching: .any)["settings.form"]
        let reset = app.buttons["settings.resetLocalData"]
        scrollUntilHittable(reset, in: settings, app: app)
        assertAnnouncement(reset, label: "Reset All Local Data")
        reset.tap()
        let resetMessage = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "This cannot be undone."
            )
        ).firstMatch
        assertAnnouncement(
            resetMessage,
            labelPrefix: "This cannot be undone."
        )
        assertAnnouncement(
            app.buttons["settings.resetLocalData.confirm"].firstMatch,
            label: "Reset All Local Data"
        )
        assertAnnouncement(
            app.buttons["settings.resetLocalData.cancel"].firstMatch,
            label: "Cancel"
        )
        try auditVisibleSemantics(in: app)
        app.buttons["settings.resetLocalData.cancel"].firstMatch.tap()

        tabButton("Search", in: app).tap()
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 1) {
            app.navigationBars["Search"].buttons["Search"].tap()
        }
        search.tap()
        search.typeText("Test")
        assertAnnouncement(
            app.buttons["search.book.ui-search-book"],
            label: "Open The Search Result"
        )
        assertAnnouncement(
            app.buttons["search.book.ui-search-book.play"],
            label: "Play The Search Result"
        )
        let searchDone = app.buttons["search.done"]
        if searchDone.exists, searchDone.isHittable {
            searchDone.tap()
        }
        try auditVisibleSemantics(in: app)
    }

    @MainActor
    func testPlaybackVoiceOverSemantics() throws {
        let app = launch(scenario: "--ui-testing-playback")
        app.buttons["home.book.ui-book"].tap()
        let detail = app.descendants(matching: .any)["book.detail"]
        let play = app.buttons["book.detail.play"]
        scrollUntilHittable(play, in: detail, app: app)
        play.tap()

        let miniOpen = app.buttons["player.mini.open"]
        assertAnnouncement(
            miniOpen,
            label:
                "Open Now Playing, The Test Audiobook by Test Author, Test Coauthor",
            value: "Chapter One"
        )
        assertAnnouncement(app.buttons["player.mini.toggle"], label: "Pause")
        miniOpen.tap()

        let playerScroll = app.descendants(matching: .any)["player.scroll"]
        let position = app.sliders["player.position"]
        assertAnnouncement(
            position,
            label: "Playback Position",
            valueSuffix: "remaining"
        )
        for (identifier, label) in [
            ("player.previousChapter", "Previous Chapter"),
            ("player.toggle", "Pause"),
            ("player.nextChapter", "Next Chapter"),
        ] {
            assertAnnouncement(app.buttons[identifier], label: label)
        }
        assertAnnouncement(
            app.buttons["player.skipBackward"],
            labelPrefix: "Back ",
            labelSuffix: " seconds"
        )
        assertAnnouncement(
            app.buttons["player.skipForward"],
            labelPrefix: "Forward ",
            labelSuffix: " seconds"
        )

        let rate = app.buttons["player.rate"]
        scrollUntilHittable(rate, in: playerScroll, app: app)
        assertAnnouncement(rate, label: "Playback Speed", value: "1×")
        assertAnnouncement(app.buttons["player.chapters"], label: "Chapters")
        assertAnnouncement(
            app.buttons["player.sleepTimer"], label: "Sleep Timer"
        )
        assertAnnouncement(app.buttons["player.bookmarks"], label: "Bookmarks")
        assertAnnouncement(
            app.descendants(matching: .any)["player.airPlay"],
            label: "AirPlay"
        )
        try auditVisibleSemantics(in: app)

        app.buttons["player.chapters"].tap()
        let currentChapter = app.buttons["player.chapter.0"]
        assertAnnouncement(currentChapter, label: "Chapter One")
        XCTAssertTrue(currentChapter.isSelected)
        assertAnnouncement(
            app.buttons["player.chapter.1"], label: "Chapter Two")
        try auditVisibleSemantics(in: app)
    }

    @MainActor
    private func launch(scenario: String) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [scenario]
        app.launch()
        return app
    }

    @MainActor
    private func auditVisibleSemantics(in app: XCUIApplication) throws {
        try app.performAccessibilityAudit(
            for: [.sufficientElementDescription, .trait]
        )
    }

    @MainActor
    private func assertSelectedTab(
        _ label: String,
        in app: XCUIApplication
    ) {
        let tab = tabButton(label, in: app)
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        XCTAssertEqual(tab.label, label)
        XCTAssertTrue(tab.isSelected, "\(label) tab does not announce selected")
    }

    @MainActor
    private func assertAnnouncement(
        _ element: XCUIElement,
        label: String? = nil,
        labelPrefix: String? = nil,
        labelSuffix: String? = nil,
        value: String? = nil,
        valueSuffix: String? = nil
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: 10), "Missing \(element)")
        if let label {
            XCTAssertEqual(element.label, label)
        }
        if let labelPrefix {
            XCTAssertTrue(element.label.hasPrefix(labelPrefix), element.label)
        }
        if let labelSuffix {
            XCTAssertTrue(element.label.hasSuffix(labelSuffix), element.label)
        }
        let announcedValue = element.value as? String
        if let value {
            XCTAssertEqual(announcedValue, value)
        }
        if let valueSuffix {
            XCTAssertTrue(
                announcedValue?.hasSuffix(valueSuffix) == true,
                announcedValue ?? "Missing accessibility value"
            )
        }
    }

    @MainActor
    private func assertTopToBottomOrder(
        _ elements: [XCUIElement],
        in container: XCUIElement
    ) {
        XCTAssertTrue(container.waitForExistence(timeout: 10))
        var previousMinimumY = -CGFloat.greatestFiniteMagnitude
        for element in elements {
            XCTAssertTrue(element.waitForExistence(timeout: 10))
            XCTAssertGreaterThan(
                element.frame.minY,
                previousMinimumY,
                "Expected top-to-bottom VoiceOver reading order"
            )
            previousMinimumY = element.frame.minY
        }
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in container: XCUIElement,
        app: XCUIApplication
    ) {
        XCTAssertTrue(container.waitForExistence(timeout: 5))
        for _ in 0..<30 {
            if element.exists, element.isHittable,
                app.frame.contains(element.frame)
            {
                return
            }
            container.swipeUp()
        }
        XCTFail("Could not reach \(element)")
    }
}
