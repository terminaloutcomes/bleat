import XCTest
import UIKit

final class BleatLandscapeUITests: XCTestCase {
    @MainActor
    func testPrimaryScreensRemainUsableInLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-signed-in"]
        app.launch()
        rotate(.landscapeLeft, in: app)

        assertVisible(app.descendants(matching: .any)["home.shelves"], in: app)
        assertUsable(tabButton("Library", in: app), in: app).tap()
        assertVisible(app.descendants(matching: .any)["books.list"], in: app)

        assertUsable(tabButton("Search", in: app), in: app).tap()
        let search = app.searchFields.firstMatch
        assertUsable(search, in: app).tap()
        search.typeText("Test")
        assertVisible(app.descendants(matching: .any)["search.results"], in: app)

        assertUsable(tabButton("Home", in: app), in: app).tap()
        let book = app.descendants(matching: .any)["home.book.ui-book"]
        assertUsable(book, in: app).tap()
        assertVisible(app.descendants(matching: .any)["book.detail"], in: app)
        assertUsable(app.buttons["book.detail.play"], in: app)
        assertUsable(app.buttons["book.detail.download"], in: app)

        assertUsable(tabButton("Downloads", in: app), in: app).tap()
        assertUsable(app.navigationBars["Downloads"], in: app)
        assertUsable(tabButton("Settings", in: app), in: app).tap()
        assertUsable(app.navigationBars["Settings"], in: app)
    }

    @MainActor
    func testLoginRemainsUsableInLandscape() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-signed-out"]
        app.launch()
        rotate(.landscapeLeft, in: app)

        assertUsable(app.textFields["login.server"], in: app)
        assertUsable(app.textFields["login.username"], in: app)
        let password = app.secureTextFields["login.password"]
        scrollUntilHittable(password, in: app)
        assertUsable(password, in: app)
        assertUsable(app.buttons["login.submit"], in: app)
    }

    @MainActor
    func testRotationPreservesNavigationAndPlayback() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-playback"]
        app.launch()

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
        assertUsable(app.otherElements["player.screen"], in: app)
        assertUsable(app.buttons["player.toggle"], in: app)

        rotate(.landscapeLeft, in: app)
        assertUsable(app.otherElements["player.screen"], in: app)
        assertUsable(app.buttons["player.toggle"], in: app)

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
        assertUsable(app.buttons["player.mini.open"], in: app)
    }

    @MainActor
    private func rotate(_ orientation: UIDeviceOrientation, in app: XCUIApplication) {
        XCUIDevice.shared.orientation = orientation
        let settled = expectation(description: "Orientation settles")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 5)
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
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        let form = app.tables.firstMatch
        for _ in 0..<5 {
            if element.waitForExistence(timeout: 1), element.isHittable {
                return
            }
            if form.exists {
                form.swipeUp()
            } else {
                app.swipeUp()
            }
        }
    }
}
