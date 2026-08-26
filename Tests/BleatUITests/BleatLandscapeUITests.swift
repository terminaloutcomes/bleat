import XCTest
import UIKit

final class BleatLandscapeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testPrimaryScreensRemainUsableInLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-signed-in"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        waitForOrientation(.portrait, in: app)
        rotate(.landscapeLeft, in: app)

        assertVisible(app.descendants(matching: .any)["home.shelves"], in: app)
        assertUsable(tabButton("Library", in: app), in: app).tap()
        assertVisible(app.descendants(matching: .any)["books.list"], in: app)

        assertUsable(tabButton("Home", in: app), in: app).tap()
        let book = app.descendants(matching: .any)["home.book.ui-book"]
        assertUsable(book, in: app).tap()
        let detail = app.descendants(matching: .any)["book.detail"]
        assertVisible(detail, in: app)
        let play = app.buttons["book.detail.play"]
        scrollUntilHittable(play, in: detail, app: app)
        assertUsable(play, in: app)
        let download = app.buttons["book.detail.download"]
        scrollUntilHittable(download, in: detail, app: app)
        assertUsable(download, in: app)

        assertUsable(tabButton("Downloads", in: app), in: app).tap()
        assertUsable(app.navigationBars["Downloads"], in: app)
        assertUsable(tabButton("Settings", in: app), in: app).tap()
        assertUsable(app.navigationBars["Settings"], in: app)

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
        assertVisible(app.descendants(matching: .any)["search.results"], in: app)
        assertUsable(app.buttons["search.done"], in: app).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testLoginRemainsUsableInLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-signed-out"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        waitForOrientation(.portrait, in: app)
        rotate(.landscapeLeft, in: app)

        let form = app.collectionViews["login.form"]
        let server = assertUsable(app.textFields["login.server"], in: app)
        server.tap()
        server.typeText("https://books.example")
        server.typeText("\n")
        let username = app.textFields["login.username"]
        scrollUntilHittable(username, in: form, app: app)
        assertUsable(username, in: app).tap()
        username.typeText("reader")
        username.typeText("\n")

        let password = app.secureTextFields["login.password"]
        scrollUntilHittable(password, in: form, app: app)
        assertUsable(password, in: app).tap()
        password.typeText("native-password")
        password.typeText("\n")

        let signedIn = app.otherElements["app.signedIn"]
        if !signedIn.waitForExistence(timeout: 2) {
            let submit = app.buttons["login.submit"]
            scrollUntilHittable(submit, in: form, app: app)
            XCTAssertTrue(submit.isEnabled)
            assertUsable(submit, in: app).tap()
        }
        assertVisible(signedIn, in: app)
    }

    @MainActor
    func testRotationPreservesNavigationAndPlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-playback"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        waitForOrientation(.portrait, in: app)

        let book = app.staticTexts["The Test Audiobook"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        play.tap()

        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5))
        XCTAssertTrue(miniPlayer.isHittable)
        miniPlayer.tap()
        let playerScreen = app.otherElements["player.screen"]
        assertUsable(playerScreen, in: app)
        let playerScroll = app.descendants(matching: .any)["player.scroll"]
        let playerToggle = app.buttons["player.toggle"]
        scrollUntilHittable(playerToggle, in: playerScroll, app: app)
        let playbackLabel = assertUsable(playerToggle, in: app).label

        rotate(.landscapeLeft, in: app)
        assertUsable(playerScreen, in: app)
        XCTAssertEqual(playerToggle.label, playbackLabel)
        playerToggle.tap()
        let paused = expectation(
            for: NSPredicate(format: "label == %@", "Play"),
            evaluatedWith: playerToggle
        )
        wait(for: [paused], timeout: 5)
        assertUsable(playerToggle, in: app)
        let preservedPlaybackLabel = playerToggle.label

        app.buttons["Close"].tap()
        let restoredMiniPlayer = assertUsable(
            app.buttons["player.mini.open"],
            in: app
        )
        XCTAssertTrue(restoredMiniPlayer.label.contains("The Test Audiobook"))
        assertUsable(tabButton("Settings", in: app), in: app).tap()
        assertUsable(app.navigationBars["Settings"], in: app)

        rotate(.portrait, in: app)
        assertUsable(app.navigationBars["Settings"], in: app)
        let portraitMiniPlayer = assertUsable(
            app.buttons["player.mini.open"],
            in: app
        )
        XCTAssertTrue(portraitMiniPlayer.label.contains("The Test Audiobook"))
        XCTAssertEqual(
            assertUsable(app.buttons["player.mini.toggle"], in: app).label,
            preservedPlaybackLabel
        )
    }

    @MainActor
    private func rotate(_ orientation: UIDeviceOrientation, in app: XCUIApplication) {
        XCUIDevice.shared.orientation = orientation
        waitForOrientation(orientation, in: app)
    }

    @MainActor
    private func waitForOrientation(
        _ orientation: UIDeviceOrientation,
        in app: XCUIApplication
    ) {
        let expectsLandscape = orientation == .landscapeLeft
            || orientation == .landscapeRight
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
        XCTAssertEqual(XCUIDevice.shared.orientation, orientation)
        XCTAssertTrue(app.exists)
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
        XCTAssertTrue(container.waitForExistence(timeout: 5), "Missing scroll container \(container)")
        for _ in 0..<20 {
            let elementExists = element.exists
            if elementExists,
                app.frame.contains(element.frame),
                element.isHittable
            {
                return
            }
            let scrollsTowardTop = !elementExists
                || element.frame.midY >= app.frame.midY
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
        XCTFail("Could not scroll to hittable element \(element) in \(container)")
    }
}
