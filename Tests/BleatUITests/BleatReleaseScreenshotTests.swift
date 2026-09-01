import UIKit
import XCTest

final class BleatReleaseScreenshotTests: XCTestCase {
    private var screenshotSuffix: String = ""

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testReleaseScreenshots() throws {
        let environment = try screenshotEnvironment()
        screenshotSuffix = environment.appearance == "dark" ? "-dark" : ""
        let app = XCUIApplication()
        app.launchArguments = [
            "--release-screenshot-disable-nearby-server-discovery"
        ]
        app.launch()

        ensureSignedOut(app)
        apply(environment.orientation, to: app)
        captureLogin(app)
        signIn(environment, app: app)
        captureHome(app)
        captureLibrary(app)
        captureBookDetailAndChapters(app)
        captureNowPlaying(app)
        captureDownloads(app)
        captureSettings(app)
        captureSearch(app)
    }

    @MainActor
    private func apply(
        _ orientation: ScreenshotOrientation,
        to app: XCUIApplication
    ) {
        let deviceOrientation: UIDeviceOrientation =
            orientation == .landscapeLeft
            ? .landscapeLeft
            : .portrait
        XCUIDevice.shared.orientation = deviceOrientation
        let expectsLandscape = orientation == .landscapeLeft
        let geometryMatches = expectation(
            for: NSPredicate { object, _ in
                guard let application = object as? XCUIApplication else {
                    return false
                }
                let frame = application.frame
                guard !frame.isEmpty else { return false }
                return expectsLandscape
                    ? frame.width > frame.height
                    : frame.height > frame.width
            },
            evaluatedWith: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [geometryMatches], timeout: 5),
            .completed,
            "Application geometry did not settle for \(orientation): \(app.frame)"
        )
        XCTAssertEqual(XCUIDevice.shared.orientation, deviceOrientation)
        XCTAssertTrue(app.exists)
    }

    @MainActor
    private func captureLogin(_ app: XCUIApplication) {
        let form = app.collectionViews["login.form"]
        XCTAssertTrue(form.waitForExistence(timeout: 20))
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        XCTAssertTrue(app.textFields["login.username"].exists)
        XCTAssertTrue(
            app.staticTexts["login.nearby.noResults"].waitForExistence(
                timeout: 20
            )
        )
        XCTAssertFalse(app.buttons["login.nearby.server"].exists)
        XCTAssertEqual(server.value as? String, server.label)
        attachScreenshot(named: "00-login.png")
    }

    @MainActor
    private func signIn(
        _ environment: ScreenshotEnvironment,
        app: XCUIApplication
    ) {
        let form = app.collectionViews["login.form"]
        let server = app.textFields["login.server"]
        scrollUntilHittable(server, in: form, app: app)
        server.tap()
        if let value = server.value as? String,
            !value.isEmpty,
            value != server.label
        {
            server.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 2))
            selectAll.tap()
        }
        server.typeText(environment.server)
        server.typeText("\n")

        let username = app.textFields["login.username"]
        scrollUntilHittable(username, in: form, app: app)
        username.tap()
        username.typeText(environment.username)
        username.typeText("\n")

        let password = app.secureTextFields["login.password"]
        scrollUntilHittable(password, in: form, app: app)
        password.tap()
        password.typeText(environment.password)
        password.typeText("\n")

        let signedIn = app.otherElements["app.signedIn"]
        if !signedIn.waitForExistence(timeout: 2) {
            let submit = app.buttons["login.submit"]
            scrollUntilHittable(submit, in: form, app: app)
            XCTAssertTrue(submit.isEnabled)
            submit.tap()
        }
        XCTAssertTrue(signedIn.waitForExistence(timeout: 45))
        dismissSavePasswordPromptIfNeeded(app: app)
    }

    @MainActor
    private func captureHome(_ app: XCUIApplication) {
        selectRootTab(named: "Home", in: app)
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
        selectRootTab(named: "Library", in: app)
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

        let hero = app.buttons.matching(
            NSPredicate(
                format: "label BEGINSWITH %@",
                "Open Thirteen Hours of Goat Sounds"
            )
        ).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        hero.tap()
        let detail = app.descendants(matching: .any)["book.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.buttons["book.detail.author.0"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.buttons["book.detail.series.0"].waitForExistence(timeout: 10)
        )
        waitForLoadingIndicatorsToDisappear(in: app)
        attachScreenshot(named: "03-goat-sounds-detail.png")

        let chaptersDisclosure = app.descendants(matching: .any)[
            "book.detail.chapters.disclosure"
        ]
        scrollUntilHittable(
            chaptersDisclosure,
            in: detail,
            app: app
        )
        chaptersDisclosure.tap()

        scrollUntilHittable(
            chapter(named: "romantic goats", in: app),
            in: detail,
            app: app
        )
        scrollUntilHittable(
            chapter(named: "oh no leave each other alone", in: app),
            in: detail,
            app: app
        )
        attachScreenshot(named: "04-goat-sounds-chapters.png")
    }

    @MainActor
    private func captureNowPlaying(_ app: XCUIApplication) {
        let play = app.buttons["book.detail.play"]
        scrollUntilHittable(
            play,
            in: app.descendants(matching: .any)["book.detail"],
            app: app,
            scrollsTowardTopWhenMissing: false
        )
        XCTAssertTrue(play.isHittable)
        play.tap()
        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 45))
        XCTAssertTrue(miniPlayer.isHittable)
        attachScreenshot(named: "05-mini-player.png")
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
        let playerScroll = app.descendants(matching: .any)["player.scroll"]
        scrollUntilHittable(
            app.buttons["player.toggle"], in: playerScroll, app: app)
        waitForLoadingIndicatorsToDisappear(in: app)
        attachScreenshot(named: "06-now-playing.png")
        app.buttons["Close"].tap()
    }

    @MainActor
    private func captureDownloads(_ app: XCUIApplication) {
        selectRootTab(named: "Downloads", in: app)
        XCTAssertTrue(
            app.navigationBars["Downloads"].waitForExistence(timeout: 10))
        attachScreenshot(named: "07-downloads.png")
    }

    @MainActor
    private func captureSearch(_ app: XCUIApplication) {
        selectRootTab(named: "Search", in: app)
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
            app.staticTexts[
                "Goat Ops: Incident Response for the Modern Barnyard"
            ]
            .waitForExistence(timeout: 20)
        )
        dismissKeyboardIfPresent(in: app)
        XCTAssertTrue(
            app.staticTexts[
                "Goat Ops: Incident Response for the Modern Barnyard"
            ]
            .waitForExistence(timeout: 5)
        )
        waitForLoadingIndicatorsToDisappear(in: app)
        attachScreenshot(named: "08-search.png")
        let done = app.buttons["search.done"]
        if done.exists {
            done.tap()
            XCTAssertTrue(
                app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    private func captureSettings(_ app: XCUIApplication) {
        selectRootTab(named: "Settings", in: app)
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["kid"].waitForExistence(timeout: 10))
        let barnyard = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "label CONTAINS %@", "barnyard.terminaloutcomes.com")
        ).firstMatch
        XCTAssertTrue(barnyard.waitForExistence(timeout: 10))
        attachScreenshot(named: "09-settings.png")
    }

    @MainActor
    private func ensureSignedOut(_ app: XCUIApplication) {
        guard app.otherElements["app.signedIn"].waitForExistence(timeout: 2)
        else {
            return
        }
        selectRootTab(named: "Settings", in: app)
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let account = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "settings.account.")
        ).firstMatch
        scrollUntilVisible(account, in: app, up: false)
        account.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)
        ).tap()

        let remove = app.buttons["accountEditor.removeAccount"]
        scrollUntilHittable(
            remove,
            in: app.collectionViews["accountEditor.form"],
            app: app
        )
        remove.tap()
        let thisDevice = app.sheets.buttons["Only on This Device"]
        XCTAssertTrue(thisDevice.waitForExistence(timeout: 10))
        thisDevice.tap()
        let keepHistory = app.sheets.buttons["Keep Listening History"]
        XCTAssertTrue(keepHistory.waitForExistence(timeout: 10))
        keepHistory.tap()
        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(timeout: 20)
        )
    }

    @MainActor
    private func selectRootTab(named label: String, in app: XCUIApplication) {
        let button = app.buttons.matching(
            NSPredicate(format: "label == %@", label)
        ).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
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
        up: Bool = true,
        below navigationBar: XCUIElement? = nil
    ) {
        for _ in 0..<20 {
            let elementExists = element.waitForExistence(timeout: 0.5)
            let clearsNavigationBar =
                elementExists
                && (navigationBar.map {
                    element.frame.minY >= $0.frame.maxY
                } ?? true)
            if elementExists,
                element.isHittable,
                clearsNavigationBar
            {
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
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in container: XCUIElement,
        app: XCUIApplication,
        scrollsTowardTopWhenMissing: Bool = true
    ) {
        XCTAssertTrue(
            container.waitForExistence(timeout: 5),
            "Missing scroll container \(container)"
        )
        for _ in 0..<20 {
            let elementExists = element.exists
            if elementExists,
                app.frame.contains(element.frame),
                element.isHittable
            {
                return
            }
            let scrollsTowardTop =
                elementExists
                ? element.frame.midY >= app.frame.midY
                : scrollsTowardTopWhenMissing
            let start = container.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 0.1,
                    dy: scrollsTowardTop ? 0.65 : 0.35
                )
            )
            let end = container.coordinate(
                withNormalizedOffset: CGVector(
                    dx: 0.1,
                    dy: scrollsTowardTop ? 0.45 : 0.55
                )
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail(
            "Could not scroll to hittable element \(element) in \(container)")
    }

    @MainActor
    private func chapter(named title: String, in app: XCUIApplication)
        -> XCUIElement
    {
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
        let results = app.descendants(matching: .any)["search.results"]
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        results.swipeDown()
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
        guard
            let orientation = ScreenshotOrientation(
                rawValue: environment["BLEAT_SCREENSHOT_ORIENTATION"]
                    ?? "portrait"
            )
        else {
            throw ScreenshotEnvironmentError.invalidOrientation
        }
        return ScreenshotEnvironment(
            server: server,
            username: username,
            password: password,
            appearance: appearance,
            orientation: orientation
        )
    }
}

private struct ScreenshotEnvironment {
    let server: String
    let username: String
    let password: String
    let appearance: String
    let orientation: ScreenshotOrientation
}

private enum ScreenshotOrientation: String {
    case portrait
    case landscapeLeft
}

private enum ScreenshotEnvironmentError: Error {
    case incomplete
    case invalidOrientation
}
