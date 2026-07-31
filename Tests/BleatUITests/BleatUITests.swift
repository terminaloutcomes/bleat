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
        XCTAssertEqual(
            app.staticTexts["book.detail.series"].label,
            "Test Series #1"
        )
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
        XCTAssertTrue(edit.exists)
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
        tabButton("Settings", in: app).tap()

        let wifiOnly = app.switches["settings.downloads.wifiOnly"]
        XCTAssertTrue(wifiOnly.waitForExistence(timeout: 3))
        XCTAssertEqual(wifiOnly.value as? String, "1")
        let filesAhead = app.steppers["settings.downloads.filesAhead"]
        XCTAssertTrue(filesAhead.waitForExistence(timeout: 3))
        XCTAssertTrue(filesAhead.label.contains("Files Ahead: 5"))
        XCTAssertTrue(
            app.buttons["settings.downloads.automaticCleanup"]
                .waitForExistence(timeout: 3)
        )
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
        app.swipeUp()
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
                "diagnostics.webSocketState"
            ].waitForExistence(timeout: 3)
        )
        app.swipeUp()
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

        let account = app.buttons["settings.account.ui-account"]
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        account.tap()
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

        XCTAssertTrue(
            app.staticTexts["The Second Audiobook"].waitForExistence(
                timeout: 3
            )
        )
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
    func testTopMiniPlayerLeavesTabsNavigable() {
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
        XCTAssertLessThan(miniPlayer.frame.midY, app.frame.midY)
        let usesBottomTabBar = app.frame.width < 600

        let library = tabButton("Library", in: app)
        XCTAssertTrue(library.isHittable)
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
    func testMiniPlayerSwipesAwayWhilePlayingAndPaused() {
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
        swipeUpToDismiss(miniToggle)
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
        swipeUpToDismiss(miniToggle)
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
    private func swipeUpToDismiss(_ element: XCUIElement) {
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
        tabButton("Library", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["multi-track"].waitForExistence(timeout: 20)
        )
        app.staticTexts["multi-track"].tap()
        XCTAssertTrue(
            app.buttons["book.detail.play"].waitForExistence(timeout: 20)
        )
        app.buttons["book.detail.play"].tap()

        let miniPlayer = app.buttons["multi-track"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30))
        miniPlayer.tap()
        XCTAssertTrue(
            app.otherElements["player.screen"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.buttons["player.skipBackward"].waitForExistence(timeout: 10)
        )
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
        try await Task.sleep(for: .seconds(12))
        app.buttons["Stop"].tap()

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
    func testLiveOfflineCachedDownloadAndPendingSync() throws {
        _ = try liveEnvironment()
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 30
            )
        )
        tabButton("Library", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["multi-track"].waitForExistence(timeout: 20)
        )
        app.staticTexts["multi-track"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        XCTAssertEqual(play.label, "Play")
        play.tap()

        let miniPlayer = app.buttons["multi-track"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30))
        miniPlayer.tap()
        XCTAssertTrue(
            app.otherElements["player.screen"].waitForExistence(timeout: 10)
        )
        app.buttons["player.skipForward"].tap()
        app.buttons["player.toggle"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["player.syncError"]
                .waitForExistence(timeout: 20)
        )
        app.buttons["player.toggle"].tap()
        app.buttons["Done"].tap()

        tabButton("Downloads", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["multi-track"].waitForExistence(timeout: 10)
        )
        XCTAssertFalse(app.buttons["Play Offline"].exists)
        app.terminate()
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
