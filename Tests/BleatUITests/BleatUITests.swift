import XCTest

@MainActor
private func tabButton(
    _ label: String,
    in app: XCUIApplication
) -> XCUIElement {
    let matches = app.buttons.matching(
        NSPredicate(format: "label == %@", label)
    )
    let count = matches.count
    guard count > 0 else {
        return matches.firstMatch
    }
    for selectedLabel in [
        "Home",
        "Library",
        "Search",
        "Downloads",
        "Settings",
    ] {
        let selectedMatches = app.buttons.matching(
            NSPredicate(format: "label == %@", selectedLabel)
        )
        let sharedCount = min(count, selectedMatches.count)
        for index in 0..<sharedCount
        where selectedMatches.element(boundBy: index).isSelected {
            return matches.element(boundBy: index)
        }
    }
    return matches.element(boundBy: count - 1)
}

@MainActor
private func pullToRefresh(_ element: XCUIElement) {
    let start = element.coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)
    )
    let end = element.coordinate(
        withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)
    )
    start.press(forDuration: 0.1, thenDragTo: end)
}

@MainActor
private func dismissSavePasswordPromptIfNeeded(app: XCUIApplication) {
    let notNow = app.buttons["Not Now"]
    if notNow.waitForExistence(timeout: 5) {
        notNow.tap()
        _ = notNow.waitForNonExistence(timeout: 3)
    }
}

final class BleatUITests: XCTestCase {
    @MainActor
    func testAcceptsExternalURLConfirmationFromHost() throws {
        #if !EXTERNAL_URL_DRIVER
            throw XCTSkip(
                "The external URL driver is invoked only by scripts/test-deep-links.sh."
            )
        #else
        let defaults = UserDefaults.standard
        let readyKey = "bleatUITestExternalURLDriverReady"
        let completeKey = "bleatUITestExternalURLDriverComplete"
        defaults.removeObject(forKey: completeKey)
        defaults.set(true, forKey: readyKey)
        defaults.synchronize()
        defer {
            defaults.removeObject(forKey: readyKey)
            defaults.removeObject(forKey: completeKey)
            defaults.synchronize()
        }

        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let deadline = Date().addingTimeInterval(300)
        var acceptedConfirmation = false

        while Date() < deadline && !defaults.bool(forKey: completeKey) {
            let open = springboard.buttons["Open"]
            if open.waitForExistence(timeout: 0.5) {
                open.tap()
                acceptedConfirmation = true
            }
            defaults.synchronize()
        }

        XCTAssertTrue(acceptedConfirmation)
        XCTAssertTrue(defaults.bool(forKey: completeKey))
        #endif
    }

    @MainActor
    func testLaunchingScreenDescribesStartupWork() {
        let app = launch(scenario: "--ui-testing-launching")
        let launchScreen = app.descendants(matching: .any)["app.launching"]
        let expectedLabel = "Starting Bleat. Restoring downloads"

        XCTAssertTrue(launchScreen.waitForExistence(timeout: 3))
        let launchStatus = expectation(
            for: NSPredicate(format: "label == %@", expectedLabel),
            evaluatedWith: launchScreen
        )
        wait(for: [launchStatus], timeout: 3)
        XCTAssertEqual(
            launchScreen.label,
            expectedLabel
        )
    }

    @MainActor
    func testNativeLoginShowsSignedInTabs() {
        let app = launch(scenario: "--ui-testing-signed-out")
        let server = app.textFields["login.server"]
        let username = app.textFields["login.username"]
        let password = app.secureTextFields["login.password"]
        let submit = app.buttons["login.submit"]

        XCTAssertTrue(server.waitForExistence(timeout: 3))
        XCTAssertEqual(server.label, "Server URL")
        XCTAssertFalse(submit.isEnabled)
        XCTAssertFalse(app.buttons["login.offlineDownloads"].exists)

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
        dismissSavePasswordPromptIfNeeded(app: app)
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

        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.tap()
        let description = app.staticTexts["book.detail.description"]
        XCTAssertTrue(description.waitForExistence(timeout: 3))
        XCTAssertEqual(
            description.label,
            "An expanded audiobook loaded from the server."
        )
        XCTAssertTrue(app.buttons["book.detail.play"].exists)
        XCTAssertTrue(app.buttons["book.detail.play"].isHittable)
        XCTAssertTrue(app.buttons["book.detail.download"].exists)
        XCTAssertTrue(
            app.buttons["book.detail.author.0"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["book.detail.author.0"].isHittable)
        XCTAssertTrue(
            app.buttons["book.detail.author.1"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["book.detail.author.1"].isHittable)
        XCTAssertTrue(
            app.buttons["book.detail.series.0"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["book.detail.series.0"].isHittable)
        XCTAssertTrue(
            app.buttons["book.detail.series.1"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["book.detail.series.1"].isHittable)
        XCTAssertTrue(
            app.descendants(matching: .any)["book.detail.chapter.0"]
                .waitForExistence(timeout: 3)
        )
        let bookmark = app.descendants(matching: .any)[
            "book.detail.bookmark"
        ]
        for _ in 0..<3 where !bookmark.exists {
            app.swipeUp()
        }
        XCTAssertTrue(bookmark.waitForExistence(timeout: 3))
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.exists)
        actions.tap()
        let edit = app.buttons["book.detail.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.buttons["book.detail.finished"]
                .waitForExistence(timeout: 3)
        )
        edit.tap()
        XCTAssertTrue(
            app.textFields["metadata.title"].waitForExistence(
                timeout: 3
            )
        )
        app.buttons["Cancel"].tap()
        app.navigationBars.buttons.firstMatch.tap()

        tabButton("Search", in: app).tap()
        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 1) {
            let presentSearch = app.navigationBars["Search"]
                .buttons["Search"]
            XCTAssertTrue(presentSearch.waitForExistence(timeout: 3))
            presentSearch.tap()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("Test")
        XCTAssertTrue(
            app.staticTexts["The Search Result"].waitForExistence(
                timeout: 3
            ))
        let author = app.buttons["search.author.author-1"]
        XCTAssertTrue(author.waitForExistence(timeout: 3))
        let series = app.buttons["search.series.series-1"]
        if !series.waitForExistence(timeout: 1) {
            app.swipeUp()
        }
        XCTAssertTrue(series.waitForExistence(timeout: 3))
    }

    @MainActor
    func testAuthorAndSeriesControlsUseTheirBrowseDestinations() {
        let app = launch(scenario: "--ui-testing-signed-in")
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )

        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.tap()
        let author = app.buttons["book.detail.author.0"]
        XCTAssertTrue(author.waitForExistence(timeout: 3))
        author.tap()

        let clear = app.buttons["library.activeFilter.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Author: Test Author"].exists)
        clear.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 3))

        let libraryBook = app.descendants(matching: .any)[
            "library.book.ui-book"
        ]
        XCTAssertTrue(libraryBook.waitForExistence(timeout: 3))
        libraryBook.tap()
        let secondAuthor = app.buttons["book.detail.author.1"]
        XCTAssertTrue(secondAuthor.waitForExistence(timeout: 3))
        secondAuthor.tap()
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Author: Test Coauthor"].exists)
        clear.tap()
        XCTAssertTrue(clear.waitForNonExistence(timeout: 3))

        XCTAssertTrue(libraryBook.waitForExistence(timeout: 3))
        libraryBook.tap()
        let series = app.buttons["book.detail.series.0"]
        XCTAssertTrue(series.waitForExistence(timeout: 3))
        series.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["series.results"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.navigationBars["Test Series"].exists)
        app.navigationBars["Test Series"].buttons.firstMatch.tap()
        XCTAssertTrue(
            app.buttons["book.detail.series.1"].waitForExistence(timeout: 3)
        )
        app.buttons["book.detail.series.1"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["series.results"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.navigationBars["Companion Series"].exists)
    }

    @MainActor
    func testGroupedSearchSelectionsReachAuthorAndSeriesDestinations() {
        let app = launch(scenario: "--ui-testing-signed-in")
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )

        tabButton("Search", in: app).tap()
        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 1) {
            let presentSearch = app.navigationBars["Search"].buttons["Search"]
            XCTAssertTrue(presentSearch.waitForExistence(timeout: 3))
            presentSearch.tap()
        }
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        searchField.tap()
        searchField.typeText("Test")

        let author = app.buttons["search.author.author-1"]
        XCTAssertTrue(author.waitForExistence(timeout: 3))
        author.tap()
        let clear = app.buttons["library.activeFilter.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Author: Test Author"].exists)
        clear.tap()

        tabButton("Search", in: app).tap()
        let series = app.buttons["search.series.series-1"]
        if !series.waitForExistence(timeout: 1) {
            app.swipeUp()
        }
        XCTAssertTrue(series.waitForExistence(timeout: 3))
        series.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["series.results"]
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testNativeLoginShowsCurrentSubmissionStage() {
        let app = launch(scenario: "--ui-testing-submission-progress")
        let submit = app.buttons["login.submit"]

        app.textFields["login.server"].tap()
        app.textFields["login.server"].typeText("https://books.example")
        app.textFields["login.username"].tap()
        app.textFields["login.username"].typeText("reader")
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText("native-password")
        submit.tap()

        let checkingServer = expectation(
            for: NSPredicate(format: "label == %@", "Checking server…"),
            evaluatedWith: submit
        )
        wait(for: [checkingServer], timeout: 3)
        XCTAssertFalse(submit.isEnabled)
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
        XCTAssertNotEqual(
            app.secureTextFields["login.password"].value as? String,
            "Password"
        )
        XCTAssertFalse(app.buttons["Sign in with OpenID"].exists)
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

    @MainActor
    func testRestoredAccountCanBeRemoved() async throws {
        let app = launch(scenario: "--ui-testing-signed-in")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            ))
        tabButton("Settings", in: app).tap()

        let wifiOnly = app.switches["settings.downloads.wifiOnly"]
        XCTAssertTrue(wifiOnly.waitForExistence(timeout: 3))
        XCTAssertEqual(wifiOnly.value as? String, "1")
        let filesAhead = app.steppers["settings.downloads.filesAhead"]
        XCTAssertTrue(filesAhead.waitForExistence(timeout: 3))
        XCTAssertTrue(filesAhead.label.contains("Files Ahead: 5"))

        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.downloads.automaticCleanup",
            direction: .up
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "settings.downloads.automaticCleanup"
            ].waitForExistence(timeout: 3)
        )

        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.account.ui-account",
            direction: .down
        )
        let reauthenticate = app.buttons["settings.account.ui-account"]
        XCTAssertTrue(reauthenticate.waitForExistence(timeout: 3))
        // SwiftUI plain Button labels with trailing images can intercept the
        // default center tap target; tap on the leading edge instead.
        reauthenticate.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)
        ).tap()
        XCTAssertTrue(
            app.secureTextFields["accountEditor.password"]
                .waitForExistence(timeout: 3)
        )
        let usernameField = app.textFields["accountEditor.username"]
        XCTAssertTrue(usernameField.waitForExistence(timeout: 3))
        XCTAssertEqual(usernameField.value as? String, "reader")
        let serverField = app.textFields["accountEditor.server"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 3))
        XCTAssertEqual(
            serverField.value as? String,
            "https://books.example"
        )
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
            app.buttons["settings.playback.skipBackward"].waitForExistence(
                timeout: 3
            )
        )
        XCTAssertTrue(
            app.buttons["settings.playback.skipForward"].waitForExistence(
                timeout: 3
            )
        )
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
        Self.scrollUntilHittable(
            app: app,
            identifier: "diagnostics.serverVersion",
            direction: .up
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "diagnostics.serverVersion"
            ].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "diagnostics.webSocketEndpoint"
            ].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "diagnostics.lastServerConnection"
            ].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "diagnostics.webSocketState"
            ].waitForExistence(timeout: 3)
        )
        Self.scrollUntilHittable(
            app: app,
            identifier: "diagnostics.export",
            direction: .up
        )
        XCTAssertTrue(
            app.buttons["diagnostics.export"].waitForExistence(timeout: 3)
        )
        let recentLogs = app.buttons["diagnostics.exportRecentLogs"]
        XCTAssertTrue(recentLogs.waitForExistence(timeout: 3))
        recentLogs.tap()
        let activityView = app.otherElements["diagnostics.activityView"]
        XCTAssertTrue(activityView.waitForExistence(timeout: 5))
        let closeShareSheet = app.buttons["header.closeButton"]
        XCTAssertTrue(closeShareSheet.waitForExistence(timeout: 3))
        closeShareSheet.tap()
        XCTAssertTrue(activityView.waitForNonExistence(timeout: 3))
        app.navigationBars.buttons.firstMatch.tap()

        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.account.ui-account",
            direction: .down
        )
        let account = app.buttons["settings.account.ui-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)
        ).tap()
        let removeAccount = app.buttons["accountEditor.removeAccount"]
        XCTAssertTrue(removeAccount.waitForExistence(timeout: 3))
        removeAccount.tap()
        let removeFromDevice = app.sheets.buttons[
            "Only on This Device"
        ]
        XCTAssertTrue(removeFromDevice.waitForExistence(timeout: 3))
        removeFromDevice.tap()
        let keepHistory = app.sheets.buttons["Keep Listening History"]
        XCTAssertTrue(keepHistory.waitForExistence(timeout: 3))
        keepHistory.tap()

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
        tabButton("Library", in: app).tap()
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

        let collapsedSeries = app.buttons["library.series.series-1"]
        XCTAssertTrue(collapsedSeries.waitForExistence(timeout: 3))
        collapsedSeries.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["series.results"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Test Series Volume One"].exists)
        XCTAssertTrue(app.staticTexts["Test Series Volume Two"].exists)
        XCTAssertFalse(loadMore.exists)
    }

    @MainActor
    func testHomeAndLibraryUsePullToRefresh() {
        let app = launch(scenario: "--ui-testing-refresh")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            )
        )
        XCTAssertFalse(app.buttons["home.reload"].exists)
        let home = app.descendants(matching: .any)["home.shelves"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        pullToRefresh(home)
        XCTAssertTrue(
            app.staticTexts["The Refreshed Home Audiobook"]
                .waitForExistence(timeout: 3)
        )

        tabButton("Library", in: app).tap()
        XCTAssertFalse(app.buttons["library.reload"].exists)
        let library = app.descendants(matching: .any)["books.list"]
        XCTAssertTrue(library.waitForExistence(timeout: 3))
        pullToRefresh(library)
        XCTAssertTrue(
            app.staticTexts["The Refreshed Library Audiobook"]
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testBottomMiniPlayerLeavesTabsNavigable() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            )
        )
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        let miniPlayer = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "The Test Audiobook",
                "Test Author"
            )
        ).firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(miniPlayer.frame.midY, app.frame.midY)
        let usesBottomTabBar = app.frame.width < 600

        let library = tabButton("Library", in: app)
        XCTAssertTrue(library.isHittable)
        if usesBottomTabBar {
            XCTAssertLessThan(miniPlayer.frame.maxY, library.frame.minY)
        }
        library.tap()
        if usesBottomTabBar {
            XCTAssertTrue(
                app.navigationBars["Library"].waitForExistence(timeout: 3)
            )
        }

        let search = tabButton("Search", in: app)
        XCTAssertTrue(search.isHittable)
        search.tap()
        if usesBottomTabBar {
            XCTAssertTrue(
                app.descendants(matching: .any)["search.screen"]
                    .waitForExistence(timeout: 3)
            )
        }

        let downloads = tabButton("Downloads", in: app)
        XCTAssertTrue(downloads.isHittable)
        downloads.tap()
        if usesBottomTabBar {
            XCTAssertTrue(
                app.navigationBars["Downloads"].waitForExistence(timeout: 3)
            )
        }

        let settings = tabButton("Settings", in: app)
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        if usesBottomTabBar {
            XCTAssertTrue(
                app.navigationBars["Settings"].waitForExistence(timeout: 3)
            )
        }

        let home = tabButton("Home", in: app)
        XCTAssertTrue(home.isHittable)
        home.tap()
        if usesBottomTabBar {
            XCTAssertTrue(
                app.navigationBars["The Test Audiobook"]
                    .waitForExistence(timeout: 3)
            )
        }
    }

    @MainActor
    func testMiniPlayerSwipesDownToStopWhilePlayingAndPaused() {
        let app = launch(scenario: "--ui-testing-playback")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        var miniToggle = app.buttons["player.mini.toggle"]
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 3))
        swipeDownToStop(miniToggle)
        let playingDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"),
            object: miniToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playingDismissed], timeout: 3),
            .completed
        )
        XCTAssertTrue(miniToggle.waitForNonExistence(timeout: 10))

        let restartedPlay = app.buttons["book.detail.play"]
        XCTAssertTrue(restartedPlay.waitForExistence(timeout: 3))
        restartedPlay.tap()
        miniToggle = app.buttons["player.mini.toggle"]
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 3))
        let pause = app.buttons["book.detail.play"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        let playbackRequested = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Pause"),
            object: pause
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playbackRequested], timeout: 3),
            .completed
        )
        XCTAssertEqual(pause.label, "Pause")
        pause.tap()
        let playbackPaused = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Play"),
            object: miniToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playbackPaused], timeout: 3),
            .completed
        )
        XCTAssertEqual(miniToggle.label, "Play")
        swipeDownToStop(miniToggle)
        let pausedDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == false"),
            object: miniToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [pausedDismissed], timeout: 3),
            .completed
        )
        XCTAssertTrue(miniToggle.waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testMiniPlayerSwipesUpToOpenNowPlaying() {
        let app = launch(scenario: "--ui-testing-playback")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        let miniToggle = app.buttons["player.mini.toggle"]
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 3))
        swipeUpToOpenNowPlaying(miniToggle)
        let playerScreen = app.otherElements["player.screen"]
        XCTAssertTrue(playerScreen.waitForExistence(timeout: 3))
        app.buttons["Close"].tap()
        XCTAssertTrue(playerScreen.waitForNonExistence(timeout: 3))
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 3))
    }

    @MainActor
    private func swipeDownToStop(_ element: XCUIElement) {
        let start = element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: 80))
        )
    }

    @MainActor
    private func swipeUpToOpenNowPlaying(_ element: XCUIElement) {
        let start = element.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: -80))
        )
    }

    @MainActor
    func testLargeScrubberJumpsRequireConfirmationWithoutGuardingCommands() {
        let app = launch(scenario: "--ui-testing-playback")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        let miniPlayer = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "The Test Audiobook",
                "Test Author"
            )
        ).firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        miniPlayer.tap()

        let slider = app.sliders["player.position"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        let alert = app.alerts["Confirm Position Change"]

        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let cancelJump = alert.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelJump.isHittable)
        cancelJump.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))

        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))

        slider.adjust(toNormalizedSliderPosition: 0.01)
        XCTAssertFalse(alert.waitForExistence(timeout: 1))

        slider.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        let confirmJump = alert.buttons["Jump"].firstMatch
        XCTAssertTrue(confirmJump.isHittable)
        confirmJump.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))

        let skipForward = app.buttons["player.skipForward"]
        XCTAssertTrue(skipForward.waitForExistence(timeout: 3))
        XCTAssertTrue(skipForward.isHittable)
        skipForward.tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 1))

        let chapters = app.buttons["player.chapters"]
        XCTAssertTrue(chapters.waitForExistence(timeout: 3))
        XCTAssertTrue(chapters.isHittable)
        chapters.tap()
        app.buttons["Chapter One"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 1))
    }

    @MainActor
    func testPlaybackRateMenuRemainsStableAcrossTimeUpdates() async throws {
        let app = launch(scenario: "--ui-testing-playback")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        let miniPlayer = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "The Test Audiobook",
                "Test Author"
            )
        ).firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        miniPlayer.tap()

        let rateMenu = app.buttons["player.rate"]
        XCTAssertTrue(rateMenu.waitForExistence(timeout: 3))
        rateMenu.tap()
        let increasedRate = app.collectionViews.buttons["1.25×"].firstMatch
        XCTAssertTrue(increasedRate.waitForExistence(timeout: 3))

        try await Task.sleep(for: .seconds(2))

        XCTAssertTrue(increasedRate.exists)
        XCTAssertTrue(increasedRate.isHittable)
        increasedRate.tap()
        XCTAssertEqual(rateMenu.label, "1.25×")
    }

    @MainActor
    func testPlaybackActionMenusRemainStableAcrossTimeUpdates() async throws {
        let app = launch(scenario: "--ui-testing-playback")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        let miniPlayer = app.buttons.matching(
            NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@",
                "The Test Audiobook",
                "Test Author"
            )
        ).firstMatch
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        miniPlayer.tap()

        let chapters = app.buttons["player.chapters"]
        XCTAssertTrue(chapters.waitForExistence(timeout: 3))
        chapters.tap()
        let chapter = app.collectionViews.buttons["Chapter One"].firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 3))
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(chapter.exists)
        XCTAssertTrue(chapter.isHittable)
        chapter.tap()

        let sleepTimer = app.buttons["player.sleepTimer"]
        XCTAssertTrue(sleepTimer.waitForExistence(timeout: 3))
        sleepTimer.tap()
        let fiveMinutes = app.collectionViews.buttons["5 minutes"].firstMatch
        XCTAssertTrue(fiveMinutes.waitForExistence(timeout: 3))
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(fiveMinutes.exists)
        XCTAssertTrue(fiveMinutes.isHittable)
        fiveMinutes.tap()

        let bookmarks = app.buttons["player.bookmarks"]
        XCTAssertTrue(bookmarks.waitForExistence(timeout: 3))
        bookmarks.tap()
        let addBookmark = app.collectionViews.buttons["Add Bookmark"].firstMatch
        XCTAssertTrue(addBookmark.waitForExistence(timeout: 3))
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(addBookmark.exists)
        XCTAssertTrue(addBookmark.isHittable)
    }

    @MainActor
    func testLimitedPermissionsShowPlayWithoutEditOrDownload() {
        let app = launch(scenario: "--ui-testing-limited-permissions")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            )
        )
        app.staticTexts["The Test Audiobook"].tap()

        XCTAssertTrue(
            app.buttons["book.detail.play"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.buttons["book.detail.actions"].exists)
        XCTAssertFalse(app.buttons["book.detail.edit"].exists)
        XCTAssertFalse(app.buttons["book.detail.download"].exists)
    }

    @MainActor
    func testBookEditorOwnsCoverAndServerDeletionControls() {
        let app = launch(scenario: "--ui-testing-signed-in")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            )
        )
        app.staticTexts["The Test Audiobook"].tap()

        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        let edit = app.buttons["book.detail.edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["book.detail.cover"].exists)
        edit.tap()

        XCTAssertTrue(
            app.buttons["book.edit.cover"].waitForExistence(timeout: 3)
        )
        let delete = app.buttons["book.edit.delete"]
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(app.buttons["Remove from Library"].exists)
        XCTAssertTrue(app.buttons["Delete Files from Server"].exists)
    }

    @MainActor
    func testCoreJourneyAtLargestDynamicType() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "-UIPreferredContentSizeCategoryName",
                "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            )
        )
        let library = tabButton("Library", in: app)
        XCTAssertTrue(library.exists)
        library.tap()
        XCTAssertTrue(
            app.staticTexts["The Test Audiobook"].waitForExistence(
                timeout: 3
            )
        )
        app.staticTexts["The Test Audiobook"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["book.detail.title"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.buttons["book.detail.play"].waitForExistence(timeout: 3)
        )
        for identifier in [
            "book.detail.author.0",
            "book.detail.author.1",
            "book.detail.series.0",
            "book.detail.series.1",
        ] {
            Self.scrollUntilHittable(
                app: app,
                identifier: identifier,
                direction: .down
            )
            XCTAssertTrue(app.buttons[identifier].isHittable)
        }
    }

    @MainActor
    func testSeriesCoverBrowserDisablesDepthMotionWhenRequested() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-reduce-motion"]
        )

        let book = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(book.waitForExistence(timeout: 3))
        book.tap()
        let series = app.buttons["book.detail.series.0"]
        XCTAssertTrue(series.waitForExistence(timeout: 3))
        series.tap()

        let coverBrowser = app.descendants(matching: .any)[
            "series.coverBrowser.reducedMotion"
        ]
        XCTAssertTrue(coverBrowser.waitForExistence(timeout: 3))
        coverBrowser.swipeLeft()
        XCTAssertTrue(coverBrowser.exists)
    }

    @MainActor
    private func launch(
        scenario: String,
        additionalArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [scenario] + additionalArguments
        app.launch()
        return app
    }

    enum ScrollDirection {
        case up, down
    }

    @MainActor
    private static func scrollUntilHittable(
        app: XCUIApplication,
        identifier: String,
        direction: ScrollDirection,
        maxAttempts: Int = 20
    ) {
        let element = app.descendants(matching: .any)[identifier]
        for _ in 0..<maxAttempts {
            if element.waitForExistence(timeout: 0.5) && element.isHittable {
                return
            }
            if direction == .up {
                app.swipeUp()
            } else {
                app.swipeDown()
            }
        }
    }
}

final class BleatLiveUITests: XCTestCase {
    @MainActor
    func testLiveOnlineLoginPlaybackAndDownload() async throws {
        let environment = try liveEnvironment()
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(timeout: 10)
        )
        app.textFields["login.server"].tap()
        app.textFields["login.server"].typeText(environment.server)
        app.textFields["login.username"].tap()
        app.textFields["login.username"].typeText(environment.username)
        app.secureTextFields["login.password"].tap()
        app.secureTextFields["login.password"].typeText(
            environment.password
        )
        app.buttons["login.submit"].tap()

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 30
            )
        )
        dismissSavePasswordPromptIfNeeded(app: app)
        openLiveLibraryBook(in: app)
        XCTAssertTrue(
            app.buttons["book.detail.play"].waitForExistence(timeout: 20)
        )
        app.buttons["book.detail.play"].tap()

        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30))
        miniPlayer.tap()
        XCTAssertTrue(
            app.otherElements["player.screen"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.buttons["player.skipBackward"].waitForExistence(timeout: 10)
        )
        try await Task.sleep(for: .seconds(12))
        app.buttons["player.skipForward"].tap()
        app.buttons["player.toggle"].tap()
        app.buttons["player.toggle"].tap()
        app.buttons["player.rate"].tap()
        app.buttons["1.25×"].tap()
        let chapters = app.buttons["player.chapters"]
        XCTAssertTrue(chapters.waitForExistence(timeout: 10))
        chapters.tap()
        app.buttons["02"].tap()
        let audioFiles = app.buttons["player.audioFiles"]
        XCTAssertTrue(audioFiles.waitForExistence(timeout: 10))
        audioFiles.tap()
        let secondFile = app.buttons["player.audioFile.1"]
        XCTAssertTrue(secondFile.waitForExistence(timeout: 10))
        secondFile.tap()
        app.buttons["Close"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["book.detail.downloadStatus"]
                .waitForExistence(timeout: 20)
        )
        XCTAssertTrue(
            app.staticTexts["Cached"].waitForExistence(timeout: 60)
        )
        XCTAssertTrue(
            app.buttons["book.detail.download.fullBook"]
                .waitForExistence(timeout: 10)
        )
        app.terminate()
    }

    @MainActor
    func testLiveOfflineCachedDownloadAndLocalProgress() throws {
        _ = try liveEnvironment()
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 30
            )
        )
        openLiveLibraryBook(in: app)
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertEqual(play.label, "Play")
        play.tap()

        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30))
        miniPlayer.tap()
        XCTAssertTrue(
            app.otherElements["player.screen"].waitForExistence(timeout: 10)
        )
        app.buttons["player.skipForward"].tap()
        app.buttons["player.toggle"].tap()
        XCTAssertFalse(
            app.descendants(matching: .any)["player.syncError"]
                .waitForExistence(timeout: 2)
        )
        app.buttons["player.toggle"].tap()
        app.buttons["Close"].tap()

        tabButton("Downloads", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["multi-track"].waitForExistence(timeout: 10)
        )
        XCTAssertFalse(app.buttons["Play Offline"].exists)
        app.terminate()
    }

    @MainActor
    private func openLiveLibraryBook(in app: XCUIApplication) {
        tabButton("Library", in: app).tap()
        let library = app.descendants(matching: .any)["books.list"]
        XCTAssertTrue(library.waitForExistence(timeout: 20))
        let series = library.buttons["Fixture Series, series, 2 books"]
        XCTAssertTrue(series.waitForExistence(timeout: 20))
        series.tap()
        let seriesResults = app.descendants(matching: .any)["series.results"]
        XCTAssertTrue(seriesResults.waitForExistence(timeout: 20))
        let multiMetadataBook = seriesResults.descendants(matching: .any)[
            "series.book.0"
        ]
        XCTAssertTrue(multiMetadataBook.waitForExistence(timeout: 20))
        multiMetadataBook.tap()
        for identifier in [
            "book.detail.author.0",
            "book.detail.author.1",
            "book.detail.series.0",
            "book.detail.series.1",
        ] {
            XCTAssertTrue(
                app.buttons[identifier].waitForExistence(timeout: 20)
            )
            XCTAssertTrue(app.buttons[identifier].isHittable)
        }
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 20))
        back.tap()

        let playbackBook = seriesResults.descendants(matching: .any)[
            "series.book.1"
        ]
        XCTAssertTrue(playbackBook.waitForExistence(timeout: 20))
        playbackBook.tap()
    }

    private func liveEnvironment() throws -> (
        server: String,
        username: String,
        password: String
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["BLEAT_LIVE_APP_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-app-live.sh to provide live app data"
            )
        }
        return (server, username, password)
    }
}
