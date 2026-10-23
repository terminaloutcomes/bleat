import UIKit
import XCTest

final class BleatIPadKeyboardUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testNativeCommandModifierEditingCalibration() throws {
        let app = try launchSignedIn()
        defer { app.terminate() }
        app.open(try XCTUnwrap(URL(string: "bleat://search?q=test")))
        let field = app.searchFields.firstMatch
        if !field.exists {
            let presentSearch = app.navigationBars["Search"].buttons["Search"]
            XCTAssertTrue(presentSearch.waitForExistence(timeout: 5))
            presentSearch.tap()
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        waitForValue(field, key: "value", equalTo: "test")
        command("a", in: app)
        app.typeKey("x", modifierFlags: [])
        waitForValue(field, key: "value", equalTo: "x")
        retainScreenshot(
            app, name: "Native Command-A replaces the field selection")
    }

    @MainActor
    func testCommandSearchFromBrowsingFocusesWithoutTap() throws {
        let app = try launchSignedIn()
        defer { app.terminate() }
        command("f", in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Search"].exists)
        app.typeKey("t", modifierFlags: [])
        app.typeKey("e", modifierFlags: [])
        app.typeKey("s", modifierFlags: [])
        app.typeKey("t", modifierFlags: [])
        waitForValue(field, key: "value", equalTo: "test")
        retainScreenshot(app, name: "Command-F focuses search from browsing")
    }

    @MainActor
    func testCommandKeysControlPausedPlaybackPositionAndRate() throws {
        let app = try launchPlayer()
        defer { app.terminate() }
        let toggle = app.buttons["player.toggle"]
        command("p", in: app)
        waitForValue(toggle, key: "label", equalTo: "Play")
        command("p", in: app)
        waitForValue(toggle, key: "label", equalTo: "Pause")
        command("p", in: app)
        waitForValue(toggle, key: "label", equalTo: "Play")

        let initial = try elapsedSeconds(in: app)
        command(XCUIKeyboardKey.rightArrow.rawValue, in: app)
        waitForElapsed(initial + 5, in: app)
        command(XCUIKeyboardKey.leftArrow.rawValue, in: app)
        waitForElapsed(initial, in: app)
        let rate = app.buttons["player.rate"]
        XCTAssertEqual(rate.value as? String, "1×")
        command("+", in: app)
        waitForValue(rate, key: "value", equalTo: "1.25×")
        command("-", in: app)
        waitForValue(rate, key: "value", equalTo: "1×")
        XCTAssertEqual(toggle.label, "Play")
        XCTAssertEqual(try elapsedSeconds(in: app), initial)
        retainScreenshot(app, name: "Native iPad keyboard transport and rate")
    }

    @MainActor
    func testCommandSearchFocusPreservesQueryAndTextEditingBlocksTransport()
        throws
    {
        let app = try launchPlayer()
        defer { app.terminate() }
        app.buttons["player.toggle"].tap()
        waitForValue(
            app.buttons["player.toggle"], key: "label", equalTo: "Play")
        let initial = try elapsedSeconds(in: app)

        command("f", in: app)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Search"].exists)
        XCTAssertTrue(
            app.otherElements["player.screen"].waitForNonExistence(timeout: 5))
        // No tap: successful typing demonstrates that Command-F moved focus.
        app.typeKey("t", modifierFlags: [])
        app.typeKey("e", modifierFlags: [])
        app.typeKey("s", modifierFlags: [])
        app.typeKey("t", modifierFlags: [])
        waitForValue(field, key: "value", equalTo: "test")
        let done = app.buttons["search.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCTAssertTrue(done.isHittable)
        done.tap()
        tabButton("Home", in: app).tap()
        command("f", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Search"].exists)
        XCTAssertEqual(field.value as? String, "test")

        // Command-left belongs to the text responder; the following insertion
        // proves caret movement as well as preventing a playback seek.
        command(XCUIKeyboardKey.leftArrow.rawValue, in: app)
        app.typeKey("x", modifierFlags: [])
        waitForValue(field, key: "value", equalTo: "xtest")
        app.typeKey(" ", modifierFlags: [])
        waitForValue(field, key: "value", equalTo: "x test")
        command("p", in: app)
        command(XCUIKeyboardKey.rightArrow.rawValue, in: app)
        command("+", in: app)
        XCTAssertEqual(field.value as? String, "x test")
        XCTAssertEqual(app.buttons["player.mini.toggle"].label, "Play")
        retainScreenshot(
            app,
            name: "Command-F focuses retained query and editing consumes keys")
        XCTAssertTrue(done.isHittable)
        done.tap()
        openPlayer(in: app)
        XCTAssertEqual(app.buttons["player.toggle"].label, "Play")
        XCTAssertEqual(try elapsedSeconds(in: app), initial)
        XCTAssertEqual(app.buttons["player.rate"].value as? String, "1.25×")
        command("+", in: app)
        waitForValue(app.buttons["player.rate"], key: "value", equalTo: "1.5×")
        command("f", in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.typeKey("y", modifierFlags: [])
        waitForValue(field, key: "value", equalTo: "x testy")
        command("-", in: app)
        done.tap()
        openPlayer(in: app)
        XCTAssertEqual(app.buttons["player.rate"].value as? String, "1.25×")
        XCTAssertEqual(try elapsedSeconds(in: app), initial)
        command(XCUIKeyboardKey.rightArrow.rawValue, in: app)
        waitForElapsed(initial + 5, in: app)
    }

    @MainActor
    func testBookmarkModalBlocksCommandsUntilDismissal() throws {
        let app = try launchPlayer()
        defer { app.terminate() }
        app.buttons["player.toggle"].tap()
        waitForValue(
            app.buttons["player.toggle"], key: "label", equalTo: "Play")
        let initial = try elapsedSeconds(in: app)
        let bookmarks = app.buttons["player.bookmarks"]
        scrollUntilHittable(bookmarks, in: app.scrollViews["player.scroll"])
        bookmarks.tap()
        let add = app.buttons["Add Bookmark"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertTrue(add.isHittable)
        add.tap()
        let title = app.textFields["bookmark.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let originalTitle = try XCTUnwrap(title.value as? String)
        command("p", in: app)
        command(XCUIKeyboardKey.rightArrow.rawValue, in: app)
        command("+", in: app)
        command("f", in: app)
        XCTAssertTrue(title.exists)
        XCTAssertEqual(title.value as? String, originalTitle)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        retainScreenshot(
            app,
            name: "Bookmark modal retains presentation under native commands")
        let cancel = app.navigationBars["New Bookmark"].buttons["Cancel"]
        XCTAssertTrue(cancel.isHittable)
        cancel.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["player.toggle"].label, "Play")
        XCTAssertEqual(try elapsedSeconds(in: app), initial)
        XCTAssertEqual(app.buttons["player.rate"].value as? String, "1×")
        command("+", in: app)
        waitForValue(app.buttons["player.rate"], key: "value", equalTo: "1.25×")
        bookmarks.tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        command("-", in: app)
        cancel.tap()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["player.rate"].value as? String, "1.25×")
        command(XCUIKeyboardKey.rightArrow.rawValue, in: app)
        waitForElapsed(initial + 5, in: app)
        command("p", in: app)
        waitForValue(
            app.buttons["player.toggle"], key: "label", equalTo: "Pause")
        command("p", in: app)
        waitForValue(
            app.buttons["player.toggle"], key: "label", equalTo: "Play")
        command("f", in: app)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Search"].exists)
    }

    @MainActor
    private func launchPlayer(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> XCUIApplication {
        let app = try launchSignedIn(file: file, line: line)
        let book = app.buttons["home.book.ui-book"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(book.isHittable, file: file, line: line)
        book.tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(play.isHittable, file: file, line: line)
        play.tap()
        waitForValue(
            app.buttons["player.mini.toggle"], key: "label", equalTo: "Pause",
            file: file, line: line)
        openPlayer(in: app, file: file, line: line)
        waitForValue(
            app.buttons["player.toggle"], key: "label", equalTo: "Pause",
            file: file, line: line)
        return app
    }

    @MainActor
    private func launchSignedIn(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> XCUIApplication {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip(
                "Native iPad keyboard shortcuts require an iPad destination")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-playback",
            "-bleat.downloads.automaticLookahead.v1", "0",
            "-bleat.playback.skipForward.v1", "5",
            "-bleat.playback.skipBackward.v1", "5",
            "-bleat.playback.defaultRate.v1", "1",
        ]
        app.launch()
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 5),
            file: file, line: line)
        return app
    }

    @MainActor
    private func openPlayer(
        in app: XCUIApplication, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mini = app.buttons["player.mini.open"]
        XCTAssertTrue(mini.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(mini.isHittable, file: file, line: line)
        // Use the existing supported swipe-to-open route. The separate iPad
        // tap/presentation failures remain retained and are not declared fixed
        // by this keyboard-dispatch suite.
        mini.swipeUp(velocity: .fast)
        XCTAssertTrue(
            app.buttons["player.toggle"].waitForExistence(timeout: 5),
            file: file, line: line)
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement, in scroll: XCUIElement,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            scroll.swipeUp()
        }
        XCTFail(
            "Control did not become hittable after eight scrolls", file: file,
            line: line)
    }

    @MainActor
    private func command(_ key: String, in app: XCUIApplication) {
        app.typeKey(key, modifierFlags: .command)
    }

    @MainActor
    private func waitForValue(
        _ element: XCUIElement, key: String, equalTo value: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND %K == %@", key, value),
            object: element)
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 5), .completed, file: file,
            line: line)
        let observed = key == "label" ? element.label : element.value as? String
        XCTAssertEqual(observed, value, file: file, line: line)
    }

    @MainActor
    private func elapsedSeconds(
        in app: XCUIApplication, file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Int {
        let position = app.sliders["player.position"]
        XCTAssertTrue(position.exists, file: file, line: line)
        let value = try XCTUnwrap(
            position.value as? String, file: file, line: line)
        let elapsed = try XCTUnwrap(
            value.components(separatedBy: " elapsed").first, file: file,
            line: line)
        let parts = elapsed.split(separator: ":").compactMap { Int($0) }
        XCTAssertTrue(
            parts.count == 2 || parts.count == 3,
            "Unexpected position: \(value)", file: file, line: line)
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    @MainActor
    private func waitForElapsed(
        _ seconds: Int, in app: XCUIApplication,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let formatted =
            seconds >= 3_600
            ? String(
                format: "%d:%02d:%02d", seconds / 3_600, seconds % 3_600 / 60,
                seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "exists == true AND value BEGINSWITH %@",
                formatted + " elapsed, "),
            object: app.sliders["player.position"])
        XCTAssertEqual(
            XCTWaiter.wait(for: [ready], timeout: 5), .completed, file: file,
            line: line)
        XCTAssertEqual(
            try elapsedSeconds(in: app, file: file, line: line), seconds,
            file: file, line: line)
    }

    @MainActor
    private func retainScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
