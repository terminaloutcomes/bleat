import XCTest

final class BleatAccessibilityAuditUITests: XCTestCase {
    private enum AuditMode: String {
        case boldText = "bold-text"
        case increaseContrast = "increase-contrast"

        var enabledIdentifier: String {
            switch self {
            case .boldText: "accessibility.boldText"
            case .increaseContrast: "accessibility.increaseContrast"
            }
        }

        var disabledIdentifier: String {
            switch self {
            case .boldText: "accessibility.increaseContrast"
            case .increaseContrast: "accessibility.boldText"
            }
        }
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    @MainActor
    func testBoldTextLoginAccessibilityAudit() {
        runLoginAccessibilityAudit(mode: .boldText)
    }

    @MainActor
    func testBoldTextPrimaryJourneysAccessibilityAudit() {
        runPrimaryJourneysAccessibilityAudit(mode: .boldText)
    }

    @MainActor
    func testBoldTextPlaybackAccessibilityAudit() {
        runPlaybackAccessibilityAudit(mode: .boldText)
    }

    @MainActor
    func testIncreaseContrastLoginAccessibilityAudit() {
        runLoginAccessibilityAudit(mode: .increaseContrast)
    }

    @MainActor
    func testIncreaseContrastPrimaryJourneysAccessibilityAudit() {
        runPrimaryJourneysAccessibilityAudit(mode: .increaseContrast)
    }

    @MainActor
    func testIncreaseContrastPlaybackAccessibilityAudit() {
        runPlaybackAccessibilityAudit(mode: .increaseContrast)
    }

    @MainActor
    private func runLoginAccessibilityAudit(mode: AuditMode) {
        let app = launch(
            scenario: "--ui-testing-signed-out", mode: mode
        )
        assertAccessibilitySettings(mode: mode, in: app)

        let form = app.collectionViews["login.form"]
        assertVisible(form, in: app)
        let server = assertUsable(app.textFields["login.server"], in: app)
        XCTAssertFalse(server.frame.isEmpty)

        let username = app.textFields["login.username"]
        scrollUntilHittable(username, in: form, app: app)
        assertUsable(username, in: app)

        let password = app.secureTextFields["login.password"]
        scrollUntilHittable(password, in: form, app: app)
        assertUsable(password, in: app)
        let passwordVisibility = app.buttons["Show password"]
        scrollUntilHittable(passwordVisibility, in: form, app: app)
        assertMinimumTarget(passwordVisibility, in: app)
        let submit = app.buttons["login.submit"]
        scrollUntilHittable(submit, in: form, app: app)
        assertMinimumTarget(submit, in: app)
        let diagnostics = app.buttons["login.diagnostics"]
        scrollUntilHittable(diagnostics, in: form, app: app)
        assertMinimumTarget(diagnostics, in: app)
        recordScreenshot(named: "login", mode: mode, app: app)
    }

    @MainActor
    private func runPrimaryJourneysAccessibilityAudit(mode: AuditMode) {
        let app = launch(scenario: "--ui-testing-signed-in", mode: mode)
        assertAccessibilitySettings(mode: mode, in: app)

        let homeBook = app.buttons["home.book.ui-book"]
        let homePlay = app.buttons["home.book.ui-book.play"]
        assertMinimumTarget(homeBook, in: app)
        assertMinimumTarget(homePlay, in: app)
        recordScreenshot(named: "home", mode: mode, app: app)

        assertUsable(tabButton("Library", in: app), in: app).tap()
        assertVisible(app.descendants(matching: .any)["books.list"], in: app)
        for element in [
            app.buttons["library.sort"],
            app.buttons["library.sortDirection"],
            app.descendants(matching: .any)["library.filter"],
            app.buttons["library.book.ui-book"],
            app.buttons["library.book.ui-book.play"],
        ] {
            assertMinimumTarget(element, in: app)
        }
        recordScreenshot(named: "library", mode: mode, app: app)

        assertUsable(tabButton("Home", in: app), in: app).tap()
        homeBook.tap()
        let detail = app.descendants(matching: .any)["book.detail"]
        assertVisible(detail, in: app)
        for identifier in [
            "book.detail.author.0",
            "book.detail.author.1",
            "book.detail.series.0",
            "book.detail.series.1",
            "book.detail.play",
            "book.detail.download",
        ] {
            let control = app.buttons[identifier]
            scrollUntilHittable(control, in: detail, app: app)
            assertMinimumTarget(control, in: app)
        }
        scrollAboveFloatingTabs(
            app.buttons["book.detail.download"],
            in: detail,
            app: app
        )

        recordScreenshot(named: "book-detail", mode: mode, app: app)
        let actions = app.buttons["book.detail.actions"]
        assertMinimumTarget(actions, in: app).tap()
        let edit = app.buttons["book.detail.edit"]
        assertUsable(edit, in: app).tap()
        assertUsable(app.textFields["metadata.title"], in: app)
        assertMinimumTarget(app.buttons["metadata.save"], in: app)
        recordScreenshot(named: "book-editor", mode: mode, app: app)
        assertUsable(app.buttons["Cancel"], in: app).tap()
        assertUsable(app.navigationBars.buttons.firstMatch, in: app).tap()

        assertUsable(tabButton("Downloads", in: app), in: app).tap()
        assertVisible(app.navigationBars["Downloads"], in: app)
        assertVisible(app.staticTexts["No Downloads"], in: app)
        recordScreenshot(named: "downloads", mode: mode, app: app)

        assertUsable(tabButton("Settings", in: app), in: app).tap()
        let settings = app.descendants(matching: .any)["settings.form"]
        let account = app.buttons["settings.account.ui-account"]
        scrollUntilHittable(account, in: settings, app: app)
        assertMinimumTarget(account, in: app)
        let addAccount = app.buttons["settings.addAccount"]
        scrollUntilHittable(addAccount, in: settings, app: app)
        assertMinimumTarget(addAccount, in: app)
        let maximumConcurrent =
            app.descendants(matching: .any)[
                "settings.downloads.maximumConcurrent"
            ]
        let decrementMaximumConcurrent = maximumConcurrent.buttons.firstMatch
        scrollUntilHittable(decrementMaximumConcurrent, in: settings, app: app)
        scrollAboveFloatingTabs(
            decrementMaximumConcurrent,
            in: settings,
            app: app,
            clearance: 220
        )
        assertVisible(maximumConcurrent, in: app)
        assertUsable(decrementMaximumConcurrent, in: app)
        assertUsable(
            maximumConcurrent.buttons.element(boundBy: 1),
            in: app
        )
        recordScreenshot(named: "settings", mode: mode, app: app)
        let reset = app.buttons["settings.resetLocalData"]
        scrollUntilHittable(reset, in: settings, app: app)
        assertMinimumTarget(reset, in: app)

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
        assertVisible(
            app.descendants(matching: .any)["search.results"], in: app)
        assertMinimumTarget(app.buttons["search.book.ui-search-book"], in: app)
        assertMinimumTarget(
            app.buttons["search.book.ui-search-book.play"], in: app
        )
        assertMinimumTarget(app.buttons["search.author.author-1"], in: app)
        let seriesResult = assertMinimumTarget(
            app.buttons["search.series.series-1"], in: app
        )
        let searchDone = assertUsable(app.buttons["search.done"], in: app)
        scrollUntilClear(
            seriesResult,
            of: [search, searchDone, app.keyboards.firstMatch],
            in: app.descendants(matching: .any)["search.results"],
            app: app
        )
        recordScreenshot(named: "search", mode: mode, app: app)
        if searchDone.exists, searchDone.isHittable {
            searchDone.tap()
        }
    }

    @MainActor
    private func runPlaybackAccessibilityAudit(mode: AuditMode) {
        let app = launch(
            scenario: "--ui-testing-playback",
            mode: mode,
            additionalArguments: ["--ui-testing-multi-file-playback"]
        )
        assertAccessibilitySettings(mode: mode, in: app)
        app.buttons["home.book.ui-book"].tap()

        let detail = app.descendants(matching: .any)["book.detail"]
        let play = app.buttons["book.detail.play"]
        scrollUntilHittable(play, in: detail, app: app)
        assertMinimumTarget(play, in: app).tap()

        let miniPlayer = assertMinimumTarget(
            app.buttons["player.mini.open"], in: app
        )
        let miniToggle = assertMinimumTarget(
            app.buttons["player.mini.toggle"], in: app
        )
        XCTAssertFalse(
            miniPlayer.frame.intersects(miniToggle.frame),
            "Mini-player open and play/pause targets overlap"
        )
        for label in ["Home", "Library", "Downloads", "Settings", "Search"] {
            let tab = assertUsable(tabButton(label, in: app), in: app)
            XCTAssertFalse(
                miniPlayer.frame.intersects(tab.frame),
                "Mini-player overlaps the \(label) tab"
            )
        }
        recordScreenshot(named: "mini-player", mode: mode, app: app)

        miniPlayer.tap()
        let playerScroll = app.descendants(matching: .any)["player.scroll"]
        assertVisible(app.otherElements["player.screen"], in: app)
        for identifier in [
            "player.previousChapter",
            "player.skipBackward",
            "player.toggle",
            "player.skipForward",
            "player.nextChapter",
            "player.position",
            "player.rate",
            "player.chapters",
            "player.audioFiles",
            "player.sleepTimer",
            "player.bookmarks",
            "player.airPlay",
        ] {
            let control = app.descendants(matching: .any)[identifier]
            scrollUntilHittable(control, in: playerScroll, app: app)
            assertMinimumTarget(control, in: app)
        }
        recordScreenshot(named: "now-playing", mode: mode, app: app)

        app.buttons["player.chapters"].tap()
        assertMinimumTarget(app.buttons["player.chapter.0"], in: app)
        recordScreenshot(named: "chapters", mode: mode, app: app)
        assertUsable(app.buttons["Done"], in: app).tap()

        scrollUntilHittable(
            app.buttons["player.bookmarks"], in: playerScroll, app: app
        )
        app.buttons["player.bookmarks"].tap()
        assertUsable(app.buttons["Add Bookmark"], in: app).tap()
        assertUsable(app.textFields["bookmark.title"], in: app)
        recordScreenshot(named: "bookmark-editor", mode: mode, app: app)
        assertUsable(app.buttons["Cancel"], in: app).tap()
    }

    @MainActor
    private func launch(
        scenario: String,
        mode: AuditMode,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments =
            [
                scenario,
                "--ui-testing-accessibility-audit",
                "--ui-testing-accessibility-mode=\(mode.rawValue)",
            ] + additionalArguments
        app.launch()
        return app
    }

    @MainActor
    private func assertAccessibilitySettings(
        mode: AuditMode,
        in app: XCUIApplication
    ) {
        let enabled = app.staticTexts[mode.enabledIdentifier]
        let disabled = app.staticTexts[mode.disabledIdentifier]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        XCTAssertTrue(disabled.waitForExistence(timeout: 10))
        XCTAssertEqual(
            enabled.label, "enabled",
            "The requested \(mode.rawValue) setting is not enabled"
        )
        XCTAssertEqual(
            disabled.label, "disabled",
            "The non-requested accessibility setting is unexpectedly enabled"
        )
    }

    @MainActor
    private func recordScreenshot(
        named name: String,
        mode: AuditMode,
        app: XCUIApplication
    ) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "\(mode.rawValue)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    @discardableResult
    private func assertMinimumTarget(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: 10), "Missing \(element)")
        XCTAssertTrue(element.isHittable, "Not hittable \(element)")
        XCTAssertTrue(
            app.frame.contains(element.frame), "Out-of-bounds \(element)")
        XCTAssertGreaterThanOrEqual(
            element.frame.width, 43.5,
            "Target is narrower than 44 points: \(element)"
        )
        XCTAssertGreaterThanOrEqual(
            element.frame.height, 43.5,
            "Target is shorter than 44 points: \(element)"
        )
        return element
    }

    @MainActor
    @discardableResult
    private func assertUsable(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) -> XCUIElement {
        XCTAssertTrue(
            element.waitForExistence(timeout: 10), "Missing \(element)")
        XCTAssertTrue(element.isHittable, "Not hittable \(element)")
        XCTAssertTrue(
            app.frame.contains(element.frame), "Out-of-bounds \(element)")
        return element
    }

    @MainActor
    private func assertVisible(_ element: XCUIElement, in app: XCUIApplication)
    {
        XCTAssertTrue(
            element.waitForExistence(timeout: 10), "Missing \(element)")
        XCTAssertFalse(element.frame.isEmpty, "Empty frame for \(element)")
        XCTAssertTrue(
            app.frame.contains(element.frame), "Out-of-bounds \(element)")
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in container: XCUIElement,
        app: XCUIApplication
    ) {
        XCTAssertTrue(container.waitForExistence(timeout: 5))
        for _ in 0..<30 {
            if element.exists, app.frame.contains(element.frame),
                element.isHittable
            {
                return
            }
            let scrollsTowardTop =
                !element.exists || element.frame.midY >= app.frame.midY
            let start = container.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 0.1, dy: scrollsTowardTop ? 0.7 : 0.3)
            )
            let end = container.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 0.1, dy: scrollsTowardTop ? 0.4 : 0.6)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not scroll to hittable element \(element)")
    }

    @MainActor
    private func scrollAboveFloatingTabs(
        _ element: XCUIElement,
        in container: XCUIElement,
        app: XCUIApplication,
        clearance: CGFloat = 24
    ) {
        let bottomTabs = ["Home", "Library", "Downloads", "Settings", "Search"]
            .map { tabButton($0, in: app) }
            .filter { $0.exists && $0.frame.midY > app.frame.midY }
        guard let tabTop = bottomTabs.map(\.frame.minY).min() else { return }
        let clearBottom = tabTop - clearance
        for _ in 0..<12 {
            if element.exists, element.isHittable,
                element.frame.maxY <= clearBottom
            {
                XCTAssertTrue(
                    bottomTabs.allSatisfy {
                        !$0.frame.intersects(element.frame)
                    },
                    "Element overlaps a floating tab"
                )
                return
            }
            let start = container.coordinate(
                withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)
            )
            let end = container.coordinate(
                withNormalizedOffset: CGVector(dx: 0.1, dy: 0.45)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Could not scroll element above the floating tabs")
    }

    @MainActor
    private func scrollUntilClear(
        _ element: XCUIElement,
        of obstacles: [XCUIElement],
        in container: XCUIElement,
        app: XCUIApplication
    ) {
        for _ in 0..<12 {
            let visibleObstacles = obstacles.filter { $0.exists }
            if element.exists, element.isHittable,
                app.frame.contains(element.frame),
                visibleObstacles.allSatisfy({
                    !$0.frame.intersects(element.frame)
                })
            {
                return
            }
            container.swipeUp()
        }
        let obstacleFrames = obstacles.filter { $0.exists }.map {
            "\($0): \($0.frame)"
        }.joined(separator: "; ")
        XCTFail(
            "Could not scroll \(element) at \(element.frame) clear of "
                + obstacleFrames
        )
    }

}
