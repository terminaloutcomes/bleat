import XCTest

final class BleatUITests: XCTestCase {
    @MainActor
    func testNativeLoginShowsSignedInTabs() {
        let app = launch(scenario: "--ui-testing-signed-out")
        let server = app.textFields["login.server"]
        let username = app.textFields["login.username"]
        let password = app.secureTextFields["login.password"]
        let submit = app.buttons["login.submit"]

        XCTAssertTrue(server.waitForExistence(timeout: 3))
        XCTAssertFalse(submit.isEnabled)

        server.tap()
        server.typeText("https://books.example")
        username.tap()
        username.typeText("reader")
        password.tap()
        password.typeText("native-password")

        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            ))
        let screenSize = XCUIScreen.main.screenshot().image.size
        XCTAssertEqual(
            app.frame.size.width,
            screenSize.width,
            accuracy: 1
        )
        XCTAssertEqual(
            app.frame.size.height,
            screenSize.height,
            accuracy: 1
        )
        XCTAssertTrue(app.buttons["Home"].exists)
        XCTAssertTrue(app.buttons["Library"].exists)
        XCTAssertTrue(app.buttons["Search"].exists)
        XCTAssertTrue(app.buttons["Downloads"].exists)
        XCTAssertTrue(app.buttons["Settings"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["home.account"].exists
        )
        XCTAssertTrue(app.staticTexts["The Test Audiobook"].exists)

        app.staticTexts["The Test Audiobook"].tap()
        let description = app.staticTexts["book.detail.description"]
        XCTAssertTrue(description.waitForExistence(timeout: 3))
        XCTAssertEqual(
            description.label,
            "An expanded audiobook loaded from the server."
        )
        XCTAssertTrue(app.buttons["book.detail.play"].exists)
        XCTAssertTrue(app.buttons["book.detail.play"].isHittable)
        XCTAssertTrue(app.buttons["book.detail.download"].exists)
        XCTAssertTrue(app.buttons["book.detail.finished"].exists)
        let edit = app.buttons["book.detail.edit"]
        XCTAssertTrue(edit.exists)
        edit.tap()
        XCTAssertTrue(
            app.textFields["metadata.title"].waitForExistence(
                timeout: 3
            )
        )
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.firstMatch.tap()

        app.buttons["Search"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("Test")
        XCTAssertTrue(
            app.staticTexts["The Search Result"].waitForExistence(
                timeout: 3
            ))
    }

    @MainActor
    func testRejectedNativeLoginShowsTypedErrorAndNoOIDCControl() {
        let app = launch(scenario: "--ui-testing-reject-login")

        app.textFields["login.server"].tap()
        app.textFields["login.server"].typeText("https://books.example")
        app.textFields["login.username"].tap()
        app.textFields["login.username"].typeText("reader")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("native-password")
        app.buttons["login.submit"].tap()

        let error = app.staticTexts["login.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertEqual(
            error.label,
            "The username or password was not accepted."
        )
        XCTAssertEqual(
            app.secureTextFields["login.password"].value as? String,
            "Password"
        )
        XCTAssertFalse(app.buttons["Sign in with OpenID"].exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    @MainActor
    func testRestoredAccountCanBeRemoved() {
        let app = launch(scenario: "--ui-testing-signed-in")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            ))
        app.buttons["Settings"].tap()

        let wifiOnly = app.switches["settings.downloads.wifiOnly"]
        XCTAssertTrue(wifiOnly.waitForExistence(timeout: 3))
        XCTAssertEqual(wifiOnly.value as? String, "1")
        let reauthenticate = app.buttons["settings.reauthenticate"]
        XCTAssertTrue(reauthenticate.waitForExistence(timeout: 3))
        reauthenticate.tap()
        XCTAssertTrue(
            app.secureTextFields["reauthentication.password"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["reader"].exists)
        XCTAssertTrue(app.staticTexts["https://books.example"].exists)
        app.buttons["Cancel"].tap()

        let addAccount = app.buttons["settings.addAccount"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 3))
        addAccount.tap()
        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(
                timeout: 3
            )
        )
        app.buttons["Cancel"].tap()

        app.swipeUp()
        XCTAssertTrue(
            app.staticTexts["Resume Rewind"].waitForExistence(
                timeout: 3
            )
        )
        let diagnostics = app.buttons["settings.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 3))
        diagnostics.tap()
        XCTAssertTrue(
            app.navigationBars["Diagnostics"].waitForExistence(
                timeout: 3
            )
        )
        app.swipeUp()
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "diagnostics.serverVersion"
            ].waitForExistence(timeout: 3)
        )
        app.swipeUp()
        XCTAssertTrue(
            app.buttons["diagnostics.export"].waitForExistence(timeout: 3)
        )
        app.navigationBars.buttons.firstMatch.tap()

        let removeAccount = app.buttons["settings.removeAccount"]
        XCTAssertTrue(removeAccount.waitForExistence(timeout: 3))
        removeAccount.tap()
        let confirmRemoval = app.sheets.buttons["Remove Account"]
        XCTAssertTrue(confirmRemoval.waitForExistence(timeout: 3))
        confirmRemoval.tap()

        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(
                timeout: 3
            ))
    }

    @MainActor
    func testLibraryLoadsAnotherPage() {
        let app = launch(scenario: "--ui-testing-signed-in")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            )
        )
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(
            app.staticTexts["The Test Audiobook"].waitForExistence(
                timeout: 3
            )
        )
        let sort = app.buttons["library.sort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 3))
        sort.tap()
        app.buttons["Recently Added"].tap()
        let filter = app.buttons["library.filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 3))
        filter.tap()
        app.buttons["In Progress"].tap()
        XCTAssertTrue(
            app.staticTexts["The Test Audiobook"].waitForExistence(
                timeout: 3
            )
        )
        let loadMore = app.buttons["books.loadMore"]
        XCTAssertTrue(loadMore.waitForExistence(timeout: 3))
        loadMore.tap()

        XCTAssertTrue(
            app.staticTexts["The Second Audiobook"].waitForExistence(
                timeout: 3
            )
        )
        XCTAssertFalse(loadMore.exists)
    }

    @MainActor
    private func launch(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [scenario]
        app.launch()
        return app
    }
}
