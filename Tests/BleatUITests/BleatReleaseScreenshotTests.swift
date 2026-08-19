import XCTest

final class BleatReleaseScreenshotTests: XCTestCase {
    private var screenshotSuffix: String = ""

    @MainActor
    func testReleaseScreenshots() throws {
        let environment = try screenshotEnvironment()
        screenshotSuffix = environment.appearance == "dark" ? "-dark" : ""
        let app = XCUIApplication()
        app.launch()

        signIn(environment, app: app)
        captureHome(app)
        captureLibrary(app)
        captureBookDetailAndChapters(app)
        captureNowPlaying(app)
        captureSettings(app)
        captureSearch(app)
    }

    @MainActor
    private func signIn(
        _ environment: ScreenshotEnvironment,
        app: XCUIApplication
    ) {
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        server.tap()
        if let value = server.value as? String, !value.isEmpty {
            server.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 2))
            selectAll.tap()
        }
        server.typeText(environment.server)
        app.textFields["login.username"].tap()
        app.textFields["login.username"].typeText(environment.username)
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText(environment.password)
        app.buttons["login.submit"].tap()

        let signedIn = app.otherElements["app.signedIn"]
        XCTAssertTrue(signedIn.waitForExistence(timeout: 45))
        dismissSavePasswordPromptIfNeeded(app: app)
    }

    @MainActor
    private func captureHome(_ app: XCUIApplication) {
        XCTAssertTrue(
            app.descendants(matching: .any)["home.shelves"].waitForExistence(
                timeout: 30
            )
        )
        XCTAssertTrue(
            app.staticTexts["Continue Listening"].waitForExistence(timeout: 30)
        )
        XCTAssertTrue(
            app.staticTexts["Thirteen Hours of Goat Sounds"].exists
        )
        XCTAssertTrue(app.descendants(matching: .any)["home.account"].exists)
        waitForLoadingIndicatorsToDisappear(in: app)
        attachScreenshot(named: "01-home.png")
    }

    @MainActor
    private func captureLibrary(_ app: XCUIApplication) {
        app.buttons.matching(identifier: "books.vertical").firstMatch.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["books.list"].waitForExistence(
                timeout: 30
            )
        )
        let skills = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Barnyard Skills")
        ).firstMatch
        XCTAssertTrue(skills.waitForExistence(timeout: 30))
        waitForLoadingIndicatorsToDisappear(in: app)
        attachScreenshot(named: "02-library.png")
    }

    @MainActor
    private func captureBookDetailAndChapters(_ app: XCUIApplication) {
        let heroSeries = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "The Complete Goat Audio Archive"
            )
        ).firstMatch
        XCTAssertTrue(heroSeries.waitForExistence(timeout: 20))
        heroSeries.tap()

        let hero = app.staticTexts["Thirteen Hours of Goat Sounds"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        hero.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["book.detail"].waitForExistence(
                timeout: 30
            )
        )
        XCTAssertTrue(
            app.buttons["book.detail.author.0"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.buttons["book.detail.series.0"].waitForExistence(timeout: 10)
        )
        waitForLoadingIndicatorsToDisappear(in: app)
        attachScreenshot(named: "03-goat-sounds-detail.png")

        scrollUntilVisible(chapter(named: "romantic goats", in: app), in: app)
        scrollUntilVisible(
            chapter(named: "oh no leave each other alone", in: app),
            in: app
        )
        attachScreenshot(named: "04-goat-sounds-chapters.png")
    }

    @MainActor
    private func captureNowPlaying(_ app: XCUIApplication) {
        scrollUntilVisible(app.buttons["book.detail.play"], in: app, up: false)
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.isHittable)
        play.tap()
        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 45))
        miniPlayer.tap()
        XCTAssertTrue(
            app.otherElements["player.screen"].waitForExistence(timeout: 20)
        )
        let chapter = app.staticTexts["player.currentChapter"]
        let romanticGoats = expectation(
            for: NSPredicate(format: "label == %@", "romantic goats"),
            evaluatedWith: chapter
        )
        wait(for: [romanticGoats], timeout: 20)
        XCTAssertEqual(chapter.label, "romantic goats")
        waitForLoadingIndicatorsToDisappear(in: app)
        attachScreenshot(named: "05-now-playing.png")
        app.buttons["Close"].tap()
    }

    @MainActor
    private func captureSearch(_ app: XCUIApplication) {
        app.buttons.matching(identifier: "magnifyingglass").firstMatch.tap()
        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 2) {
            let presentSearch = app.navigationBars["Search"].buttons["Search"]
            XCTAssertTrue(presentSearch.waitForExistence(timeout: 10))
            presentSearch.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("goat")
        XCTAssertTrue(
            app.descendants(matching: .any)["search.results"].waitForExistence(
                timeout: 20
            )
        )
        XCTAssertTrue(
            app.staticTexts["Goat Ops: Incident Response for the Modern Barnyard"]
                .waitForExistence(timeout: 20)
        )
        dismissKeyboardIfPresent(in: app)
        XCTAssertTrue(
            app.staticTexts["Goat Ops: Incident Response for the Modern Barnyard"]
                .waitForExistence(timeout: 5)
        )
        waitForLoadingIndicatorsToDisappear(in: app)
        attachScreenshot(named: "06-search.png")
    }

    @MainActor
    private func captureSettings(_ app: XCUIApplication) {
        app.buttons.matching(identifier: "gearshape").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["kid"].waitForExistence(timeout: 10))
        let barnyard = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@", "barnyard.terminaloutcomes.com")
        ).firstMatch
        XCTAssertTrue(barnyard.waitForExistence(timeout: 10))
        attachScreenshot(named: "07-settings.png")
    }

    @MainActor
    private func waitForLoadingIndicatorsToDisappear(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            let visible = (0..<app.activityIndicators.count).contains { index in
                let indicator = app.activityIndicators.element(boundBy: index)
                return indicator.exists && !indicator.frame.isEmpty
            }
            if !visible {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Timed out waiting for visible loading indicators to disappear")
    }

    @MainActor
    private func scrollUntilVisible(
        _ element: XCUIElement,
        in app: XCUIApplication,
        up: Bool = true
    ) {
        for _ in 0..<20 {
            if element.waitForExistence(timeout: 0.5), element.isHittable {
                return
            }
            if up {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
        XCTFail("Expected element was not visible: \(element)")
    }

    @MainActor
    private func chapter(named title: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                "book.detail.chapter.",
                title
            )
        ).firstMatch
    }

    @MainActor
    private func dismissKeyboardIfPresent(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else {
            return
        }
        let dismiss = app.buttons["Done"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let suffixed: String
        if screenshotSuffix.isEmpty {
            suffixed = name
        } else if name.hasSuffix(".png") {
            suffixed = String(name.dropLast(4)) + screenshotSuffix + ".png"
        } else {
            suffixed = name + screenshotSuffix
        }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = suffixed
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func screenshotEnvironment() throws -> ScreenshotEnvironment {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLEAT_SCREENSHOT_ENABLED"] == "1" else {
            throw XCTSkip(
                "Run scripts/capture-release-screenshots.sh to provide screenshot data."
            )
        }
        guard let server = environment["BLEAT_SCREENSHOT_APP_URL"],
            let username = environment["BLEAT_SCREENSHOT_USERNAME"],
            let password = environment["BLEAT_SCREENSHOT_PASSWORD"]
        else {
            throw ScreenshotEnvironmentError.incomplete
        }
        let appearance = environment["BLEAT_SCREENSHOT_APPEARANCE"] ?? "light"
        return ScreenshotEnvironment(
            server: server,
            username: username,
            password: password,
            appearance: appearance
        )
    }
}

private struct ScreenshotEnvironment {
    let server: String
    let username: String
    let password: String
    let appearance: String
}

private enum ScreenshotEnvironmentError: Error {
    case incomplete
}
