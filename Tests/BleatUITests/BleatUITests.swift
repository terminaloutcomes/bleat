import XCTest

@MainActor
func tabButton(
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
func dismissSavePasswordPromptIfNeeded(app: XCUIApplication) {
    let notNow = app.buttons["Not Now"]
    if notNow.waitForExistence(timeout: 5) {
        notNow.tap()
        _ = notNow.waitForNonExistence(timeout: 3)
    }
}

final class BleatUITests: XCTestCase {
    @MainActor
    func testLoginExposesOpenIDSetupGuide() {
        let app = launch(scenario: "--ui-testing-openid")
        let server = app.textFields["login.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 3))
        server.tap()
        server.typeText("https://books.example")

        let openIDLogin = app.buttons["login.openid"]
        let setupGuide = app.descendants(matching: .any)[
            "login.openidSetupGuide"
        ]

        XCTAssertTrue(openIDLogin.waitForExistence(timeout: 3))
        XCTAssertEqual(openIDLogin.label, "Sign in with OpenID")
        XCTAssertTrue(setupGuide.waitForExistence(timeout: 3))
        XCTAssertEqual(setupGuide.label, "OpenID Setup Guide")
        XCTAssertTrue(setupGuide.isEnabled)
        XCTAssertFalse(app.webViews.firstMatch.exists)
    }

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
        let expectedLabel = "Starting Bleat. Restoring your account"

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
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
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
        Self.scrollUntilHittable(
            app: app,
            identifier: "book.detail.chapters.disclosure",
            direction: .up
        )
        let chaptersDisclosure = app.descendants(matching: .any)[
            "book.detail.chapters.disclosure"
        ]
        XCTAssertTrue(chaptersDisclosure.isHittable)
        chaptersDisclosure.tap()
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
    func testPlayableHomeCoverSeparatesPlaybackFromNavigation() {
        let app = launch(scenario: "--ui-testing-playback")
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )

        let play = app.buttons["home.book.ui-book.play"]
        let open = app.buttons["home.book.ui-book"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        XCTAssertEqual(play.label, "Play The Test Audiobook")
        XCTAssertTrue(play.isHittable)
        XCTAssertTrue(open.isHittable)
        XCTAssertEqual(play.frame.width, 44, accuracy: 0.5)
        XCTAssertEqual(play.frame.height, 44, accuracy: 0.5)

        open.tap()

        XCTAssertTrue(
            app.staticTexts["book.detail.title"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
        app.navigationBars["The Test Audiobook"].buttons.firstMatch.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 3))

        play.tap()

        XCTAssertTrue(
            app.buttons["player.mini.open"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        XCTAssertTrue(open.isHittable)
        let pauseLabel = expectation(
            for: NSPredicate(
                format: "label == %@",
                "Pause The Test Audiobook"
            ),
            evaluatedWith: play
        )
        wait(for: [pauseLabel], timeout: 3)

        play.tap()

        let resumedLabel = expectation(
            for: NSPredicate(
                format: "label == %@",
                "Play The Test Audiobook"
            ),
            evaluatedWith: play
        )
        wait(for: [resumedLabel], timeout: 3)
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        XCTAssertTrue(app.buttons["player.mini.open"].exists)
        app.buttons["player.mini.open"].tap()
        XCTAssertTrue(
            app.otherElements["player.screen"].waitForExistence(timeout: 3)
        )
        let playerScreen = app.otherElements["player.screen"]
        XCTAssertFalse(
            playerScreen.buttons.matching(
                NSPredicate(
                    format: "label == %@",
                    "Play The Test Audiobook"
                )
            ).firstMatch.exists
        )
        XCTAssertFalse(
            playerScreen.buttons.matching(
                NSPredicate(
                    format: "label == %@",
                    "Pause The Test Audiobook"
                )
            ).firstMatch.exists
        )
    }

    @MainActor
    func testBookDetailDisclosuresAndConfirmedChapterNavigation() {
        let app = launch(scenario: "--ui-testing-playback")
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )

        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.tap()

        let detailsDisclosure = app.descendants(matching: .any)[
            "book.detail.details.disclosure"
        ]
        Self.scrollUntilHittable(
            app: app,
            identifier: "book.detail.details.disclosure",
            direction: .up
        )
        XCTAssertTrue(detailsDisclosure.isHittable)
        let duration = app.staticTexts["book.detail.details.duration"]
        XCTAssertFalse(duration.exists)
        detailsDisclosure.tap()
        XCTAssertTrue(duration.waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.staticTexts.matching(
                NSPredicate(format: "label == %@", "Chapters")
            ).count,
            1
        )

        let language = app.staticTexts["book.detail.details.language"]
        let genres = app.staticTexts["book.detail.details.genres"]
        XCTAssertTrue(language.waitForExistence(timeout: 3))
        XCTAssertTrue(genres.waitForExistence(timeout: 3))
        XCTAssertEqual(language.frame.maxX, genres.frame.maxX, accuracy: 1)
        detailsDisclosure.tap()
        XCTAssertTrue(duration.waitForNonExistence(timeout: 3))

        let chaptersDisclosure = app.descendants(matching: .any)[
            "book.detail.chapters.disclosure"
        ]
        Self.scrollUntilHittable(
            app: app,
            identifier: "book.detail.chapters.disclosure",
            direction: .up
        )
        XCTAssertTrue(chaptersDisclosure.isHittable)
        XCTAssertEqual(chaptersDisclosure.label, "Chapters, 2")
        XCTAssertFalse(
            app.descendants(matching: .any)["book.detail.chapter.0"].exists
        )
        chaptersDisclosure.tap()

        let chapter = app.buttons["book.detail.chapter.1"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 3))
        XCTAssertTrue(chapter.isHittable)
        chapter.tap()

        let confirmation = app.alerts["Go to “Chapter Two”?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
        confirmation.buttons["book.detail.chapter.cancel"].firstMatch.tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["player.mini.open"].exists)

        chapter.tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["book.detail.chapter.confirm"].firstMatch.tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))
        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))

        let bookmark = app.descendants(matching: .any)[
            "book.detail.bookmark"
        ]
        Self.scrollUntilHittable(
            app: app,
            identifier: "book.detail.bookmark",
            direction: .up
        )
        XCTAssertTrue(bookmark.isHittable)
        XCTAssertGreaterThan(bookmark.frame.minY, chaptersDisclosure.frame.minY)

        miniPlayer.tap()
        let playerChapters = app.buttons["player.chapters"]
        XCTAssertTrue(playerChapters.waitForExistence(timeout: 3))
        playerChapters.tap()
        let selectedChapter = app.buttons["player.chapter.1"]
        XCTAssertTrue(selectedChapter.waitForExistence(timeout: 3))
        XCTAssertTrue(selectedChapter.isSelected)
    }

    @MainActor
    func testBookDetailChapterNavigationPresentsTypedPlaybackFailure() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-playback-failure"]
        )
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.descendants(matching: .any)["home.book.ui-book"].tap()
        Self.scrollUntilHittable(
            app: app,
            identifier: "book.detail.chapters.disclosure",
            direction: .up
        )
        app.descendants(matching: .any)[
            "book.detail.chapters.disclosure"
        ].tap()
        let chapter = app.buttons["book.detail.chapter.0"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 3))
        chapter.tap()
        let confirmation = app.alerts["Go to “Chapter One”?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.buttons["book.detail.chapter.confirm"].firstMatch.tap()
        XCTAssertTrue(confirmation.waitForNonExistence(timeout: 3))

        let failure = app.alerts["Server unavailable"]
        XCTAssertTrue(failure.waitForExistence(timeout: 3))
        XCTAssertTrue(
            failure.staticTexts[
                "Bleat could not reach the Audiobookshelf server."
            ].exists
        )
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
    }

    @MainActor
    func testPlayableCoverPreparationDisablesOnlyMatchingAction() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-slow-playback"]
        )
        let firstPlay = app.buttons["home.book.ui-book.play"]
        let firstOpen = app.buttons["home.book.ui-book"]
        let secondPlay = app.buttons["home.book.ui-book-two.play"]

        XCTAssertTrue(firstPlay.waitForExistence(timeout: 3))
        XCTAssertTrue(secondPlay.waitForExistence(timeout: 3))
        firstPlay.tap()

        let preparing = expectation(
            for: NSPredicate(
                format: "label == %@ AND enabled == false",
                "Preparing The Test Audiobook"
            ),
            evaluatedWith: firstPlay
        )
        wait(for: [preparing], timeout: 3)
        XCTAssertTrue(firstOpen.isHittable)
        XCTAssertTrue(secondPlay.isEnabled)
        XCTAssertTrue(secondPlay.isHittable)
        XCTAssertEqual(secondPlay.frame.width, 44, accuracy: 0.5)
        XCTAssertEqual(secondPlay.frame.height, 44, accuracy: 0.5)

        secondPlay.tap()

        let secondPlaying = expectation(
            for: NSPredicate(
                format: "label == %@",
                "Pause The Other Audiobook"
            ),
            evaluatedWith: secondPlay
        )
        wait(for: [secondPlaying], timeout: 10)
        XCTAssertEqual(firstPlay.label, "Play The Test Audiobook")
        XCTAssertTrue(firstPlay.isEnabled)
        XCTAssertTrue(app.buttons["player.mini.open"].exists)
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
    }

    @MainActor
    func testPlayableCoverPresentsTypedPlaybackFailure() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-playback-failure"]
        )
        let play = app.buttons["home.book.ui-book.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        let alert = app.alerts["Server unavailable"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            alert.staticTexts[
                "Bleat could not reach the Audiobookshelf server."
            ].exists
        )
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
        alert.buttons["OK"].tap()
    }

    @MainActor
    func testPlayableCoverPresentsTypedPermissionDenial() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-playback-denied"]
        )
        let play = app.buttons["home.book.ui-book.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        XCTAssertTrue(
            app.alerts["Access denied"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.alerts["Access denied"].staticTexts[
                "This account cannot access the audiobook's library."
            ].exists
        )
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
    }

    @MainActor
    func testPlayableCoversAppearOnEverySingleBookBrowseSurface() {
        let app = launch(scenario: "--ui-testing-signed-in")
        XCTAssertTrue(
            app.buttons["home.book.ui-book.play"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.buttons["home.book.ui-home-series"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            app.buttons["home.book.ui-home-series.play"].exists
        )

        app.buttons["home.book.ui-book"].tap()
        let series = app.buttons["book.detail.series.0"]
        XCTAssertTrue(series.waitForExistence(timeout: 3))
        series.tap()
        XCTAssertTrue(
            app.buttons["series.book.ui-series-one.play"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertEqual(
            app.buttons["series.book.0"].label,
            "Open Test Series Volume One, Book 1"
        )
        XCTAssertTrue(
            app.buttons["series.carousel.ui-series-one.play"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.buttons["book.detail.ui-series-one.play"].exists)

        tabButton("Library", in: app).tap()
        XCTAssertTrue(
            app.buttons["library.book.ui-book.play"]
                .waitForExistence(timeout: 3)
        )

        tabButton("Search", in: app).tap()
        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 1) {
            let presentSearch = app.navigationBars["Search"].buttons["Search"]
            XCTAssertTrue(presentSearch.waitForExistence(timeout: 3))
            presentSearch.tap()
        }
        searchField.tap()
        searchField.typeText("Test")
        XCTAssertTrue(
            app.buttons["search.book.ui-search-book.play"]
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testBookContextMenusCoverBrowseSurfacesWithoutActivatingCards() {
        let app = launch(scenario: "--ui-testing-signed-in")
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))

        homeBook.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Mark Unplayed"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Download"].exists)
        XCTAssertTrue(app.buttons["Edit"].exists)
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
        app.buttons["Mark Unplayed"].tap()
        XCTAssertTrue(
            app.buttons["Mark Unplayed"].waitForNonExistence(timeout: 3))
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "book.context.ui-book.loading"
            ].exists
        )
        XCTAssertFalse(app.staticTexts["Preparing The Test Audiobook"].exists)
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        XCTAssertFalse(app.buttons["player.mini.open"].exists)

        tabButton("Library", in: app).tap()
        let libraryBook = app.descendants(matching: .any)[
            "library.book.ui-book"
        ]
        XCTAssertTrue(libraryBook.waitForExistence(timeout: 3))
        libraryBook.press(forDuration: 1)
        let markPlayed = app.buttons["Mark Played"]
        XCTAssertTrue(markPlayed.waitForExistence(timeout: 3))
        markPlayed.tap()
        XCTAssertTrue(markPlayed.waitForNonExistence(timeout: 3))
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "book.context.ui-book.loading"
            ].exists
        )
        XCTAssertFalse(app.staticTexts["Preparing The Test Audiobook"].exists)
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        XCTAssertFalse(app.buttons["player.mini.open"].exists)

        tabButton("Search", in: app).tap()
        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 1) {
            let presentSearch = app.navigationBars["Search"].buttons["Search"]
            XCTAssertTrue(presentSearch.waitForExistence(timeout: 3))
            presentSearch.tap()
        }
        searchField.tap()
        searchField.typeText("Test")
        assertContextMenu(
            for: app.descendants(matching: .any)[
                "search.book.ui-search-book"
            ],
            progressLabel: "Mark Played",
            in: app
        )

        app.terminate()
        let seriesApp = launch(scenario: "--ui-testing-signed-in")
        let seriesHomeBook = seriesApp.descendants(matching: .any)[
            "home.book.ui-book"
        ]
        XCTAssertTrue(seriesHomeBook.waitForExistence(timeout: 3))
        seriesHomeBook.tap()
        let series = seriesApp.buttons["book.detail.series.0"]
        XCTAssertTrue(series.waitForExistence(timeout: 3))
        series.tap()
        assertContextMenu(
            for: seriesApp.descendants(matching: .any)["series.book.0"],
            progressLabel: "Mark Played",
            in: seriesApp
        )
        assertContextMenu(
            for: seriesApp.descendants(matching: .any)[
                "series.carousel.ui-series-one"
            ],
            progressLabel: "Mark Unplayed",
            in: seriesApp
        )
    }

    @MainActor
    func testBookContextMenuDownloadRunsInBackground()
        async throws
    {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-slow-context-download"
            ]
        )
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        download.tap()
        XCTAssertTrue(download.waitForNonExistence(timeout: 3))
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "book.context.ui-book.loading"
            ].exists
        )
        XCTAssertFalse(app.staticTexts["Preparing The Test Audiobook"].exists)
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        XCTAssertFalse(app.buttons["player.mini.open"].exists)

        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        let pendingDownload = app.buttons["Download"]
        XCTAssertTrue(pendingDownload.waitForExistence(timeout: 3))
        XCTAssertFalse(pendingDownload.isEnabled)
        app.buttons["Mark Unplayed"].tap()
        try await Task.sleep(for: .seconds(9))

        tabButton("Downloads", in: app).tap()
        let removeAll = app.buttons["downloads.removeAll"]
        XCTAssertTrue(removeAll.waitForExistence(timeout: 3))
        removeAll.tap()
        let confirmRemove = app.buttons["Remove Downloads"]
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 3))
        confirmRemove.tap()
        XCTAssertTrue(
            app.staticTexts["No Downloads"].waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testSeriesDownloadStartsEveryBook() {
        let app = launch(scenario: "--ui-testing-signed-in")
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.tap()
        let series = app.buttons["book.detail.series.0"]
        XCTAssertTrue(series.waitForExistence(timeout: 3))
        series.tap()

        let downloadSeries = app.buttons["series.download"]
        XCTAssertTrue(downloadSeries.waitForExistence(timeout: 3))
        downloadSeries.tap()
        let confirm = app.buttons["Download 2 Books"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        tabButton("Downloads", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["Test Series Volume One"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.staticTexts["Test Series Volume Two"]
                .waitForExistence(timeout: 3)
        )

        let removeAll = app.buttons["downloads.removeAll"]
        XCTAssertTrue(removeAll.waitForExistence(timeout: 3))
        removeAll.tap()
        let confirmRemove = app.buttons["Remove Downloads"]
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 3))
        confirmRemove.tap()
        XCTAssertTrue(
            app.staticTexts["No Downloads"].waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testBookContextMenuPresentsExistingEditorAndTranscriptionDirectly() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-transcription-available"]
        )
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        download.tap()
        XCTAssertTrue(download.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)

        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Mark Unplayed"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Download"].exists)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        XCTAssertTrue(
            app.textFields["metadata.title"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        app.buttons["Cancel"].tap()

        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        let transcribe = app.buttons["Transcribe"]
        XCTAssertTrue(transcribe.waitForExistence(timeout: 3))
        XCTAssertTrue(transcribe.isEnabled)
        transcribe.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["transcription.view"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        app.buttons["Done"].tap()

        tabButton("Downloads", in: app).tap()
        let removeAll = app.buttons["downloads.removeAll"]
        XCTAssertTrue(removeAll.waitForExistence(timeout: 3))
        removeAll.tap()
        let confirmRemove = app.buttons["Remove Downloads"]
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 3))
        confirmRemove.tap()
        XCTAssertTrue(
            app.staticTexts["No Downloads"].waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testBookContextMenuDownloadPreparationFailureUsesAlert() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-context-download-failure"
            ]
        )
        tabButton("Search", in: app).tap()
        let searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 1) {
            let presentSearch = app.navigationBars["Search"].buttons["Search"]
            XCTAssertTrue(presentSearch.waitForExistence(timeout: 3))
            presentSearch.tap()
        }
        searchField.tap()
        searchField.typeText("Test")
        let searchBook = app.descendants(matching: .any)[
            "search.book.ui-search-book"
        ]
        XCTAssertTrue(searchBook.waitForExistence(timeout: 3))
        searchBook.press(forDuration: 1)
        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        download.tap()

        let alert = app.alerts["Server unavailable"]
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "book.context.ui-search-book.loading"
            ].exists
        )
        XCTAssertFalse(app.staticTexts["Preparing Test Result"].exists)
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
        alert.buttons["OK"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testBookContextMenuRespectsPermissionsAndTranscriptionCapability() {
        let app = launch(
            scenario: "--ui-testing-limited-permissions",
            additionalArguments: ["--ui-testing-transcription-unavailable"]
        )
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)

        XCTAssertTrue(app.buttons["Mark Unplayed"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["Download"].exists)
        XCTAssertFalse(app.buttons["Edit"].exists)
        let transcription = app.buttons[
            "Transcription unavailable on this device"
        ]
        XCTAssertTrue(transcription.exists)
        XCTAssertFalse(transcription.isEnabled)
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
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 3))
        let clear = app.buttons["library.activeFilter.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Author: Test Author"].exists)
        clear.tap()

        tabButton("Search", in: app).tap()
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        XCTAssertEqual(searchField.value as? String, "Test")
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
        guard reauthenticate.waitForExistence(timeout: 3) else {
            XCTFail("Restored account row did not become visible")
            return
        }
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
        XCTAssertTrue(
            app.buttons["settings.playback.previousCommand"].waitForExistence(
                timeout: 3
            )
        )
        XCTAssertTrue(
            app.buttons["settings.playback.nextCommand"].waitForExistence(
                timeout: 3
            )
        )
        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.diagnostics",
            direction: .up
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
        Self.scrollUntilHittable(
            app: app,
            identifier: "diagnostics.webSocketState",
            direction: .up,
            maxAttempts: 4
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "diagnostics.webSocketState"
            ].waitForExistence(timeout: 3)
        )
        Self.scrollUntilHittable(
            app: app,
            identifier: "diagnostics.bonjourTroubleshooter",
            direction: .up
        )
        XCTAssertTrue(
            app.buttons["diagnostics.bonjourTroubleshooter"].waitForExistence(
                timeout: 3
            )
        )
        XCTAssertFalse(app.buttons["diagnostics.export"].exists)
        XCTAssertFalse(app.buttons["diagnostics.exportRecentLogs"].exists)
        let diagnosticsBack = app.buttons["BackButton"]
        XCTAssertTrue(diagnosticsBack.isHittable)
        diagnosticsBack.tap()
        XCTAssertTrue(
            app.navigationBars["Diagnostics"].waitForNonExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 3))

        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.account.ui-account",
            direction: .down
        )
        let account = app.buttons["settings.account.ui-account"]
        guard account.waitForExistence(timeout: 3) else {
            XCTFail(
                "Restored account row did not become visible after returning from Diagnostics"
            )
            return
        }
        let settingsBar = app.navigationBars["Settings"]
        for _ in 0..<3 where account.frame.minY < settingsBar.frame.maxY {
            app.swipeDown()
        }
        XCTAssertGreaterThanOrEqual(account.frame.minY, settingsBar.frame.maxY)
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
    func testResetLocalDataConfirmsAndRemainsSignedOutAfterRelaunch() {
        var app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-persist-local-data-reset",
                "--ui-testing-clear-local-data-reset",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        tabButton("Settings", in: app).tap()
        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.resetLocalData",
            direction: .up
        )
        let reset = app.buttons["settings.resetLocalData"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        reset.tap()

        let confirm = app.buttons[
            "settings.resetLocalData.confirm"
        ].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(timeout: 3)
        )

        app.terminate()
        app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-persist-local-data-reset"
            ]
        )
        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.otherElements["app.signedIn"].exists)
    }

    @MainActor
    func testDiagnosticTelemetryConsentIsExplicitAndPersistsOffline() {
        var app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-reset-telemetry-consent"]
        )
        tabButton("Settings", in: app).tap()

        XCTAssertFalse(
            app.switches["diagnostics.telemetry.enabled"].exists
        )
        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.diagnostics",
            direction: .up
        )
        app.buttons["settings.diagnostics"].tap()
        Self.scrollUntilHittable(
            app: app,
            identifier: "diagnostics.telemetry.enabled",
            direction: .up
        )
        var telemetry = app.switches["diagnostics.telemetry.enabled"]
        XCTAssertTrue(telemetry.waitForExistence(timeout: 3))
        XCTAssertEqual(telemetry.value as? String, "0")
        XCTAssertTrue(
            app.staticTexts["diagnostics.telemetry.explanation"].exists
        )

        app.swipeUp()
        telemetry = app.switches["diagnostics.telemetry.enabled"]
        telemetry.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
        let enabled = expectation(
            for: NSPredicate(format: "value == %@", "1"),
            evaluatedWith: telemetry
        )
        wait(for: [enabled], timeout: 3)

        app.terminate()
        app = launch(scenario: "--ui-testing-signed-out")
        XCTAssertFalse(
            app.switches["diagnostics.telemetry.enabled"].exists
        )
        Self.scrollUntilHittable(
            app: app,
            identifier: "login.diagnostics",
            direction: .up
        )
        app.buttons["login.diagnostics"].tap()
        Self.scrollUntilHittable(
            app: app,
            identifier: "diagnostics.telemetry.enabled",
            direction: .up
        )
        telemetry = app.switches["diagnostics.telemetry.enabled"]
        XCTAssertTrue(telemetry.waitForExistence(timeout: 3))
        XCTAssertEqual(telemetry.value as? String, "1")

        app.swipeUp()
        telemetry = app.switches["diagnostics.telemetry.enabled"]
        telemetry.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
        let disabled = expectation(
            for: NSPredicate(format: "value == %@", "0"),
            evaluatedWith: telemetry
        )
        wait(for: [disabled], timeout: 3)
    }

    @MainActor
    func testDiagnosticTelemetryConsentCanBeWithdrawnWhenStartupUnavailable() {
        let app = launch(
            scenario: "--ui-testing-unavailable-startup",
            additionalArguments: [
                "--ui-testing-enable-telemetry-consent"
            ]
        )

        let diagnostics = app.buttons["app.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 3))
        diagnostics.tap()

        Self.scrollUntilHittable(
            app: app,
            identifier: "diagnostics.telemetry.enabled",
            direction: .up
        )
        let telemetry = app.switches["diagnostics.telemetry.enabled"]
        XCTAssertTrue(telemetry.waitForExistence(timeout: 3))
        XCTAssertEqual(telemetry.value as? String, "1")

        telemetry.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
        let disabled = expectation(
            for: NSPredicate(format: "value == %@", "0"),
            evaluatedWith: telemetry
        )
        wait(for: [disabled], timeout: 3)
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
        XCTAssertTrue(home.exists)
        XCTAssertTrue(
            app.staticTexts["The Refreshed Home Audiobook"]
                .waitForExistence(timeout: 5)
        )

        tabButton("Library", in: app).tap()
        XCTAssertFalse(app.buttons["library.reload"].exists)
        let library = app.descendants(matching: .any)["books.list"]
        XCTAssertTrue(library.waitForExistence(timeout: 3))
        pullToRefresh(library)
        XCTAssertTrue(library.exists)
        XCTAssertTrue(
            app.staticTexts["The Refreshed Library Audiobook"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testHomeLoadingAndEmptyStatesUsePresentationIdentifiers() {
        let loadingApp = launch(scenario: "--ui-testing-home-loading")
        XCTAssertTrue(
            loadingApp.descendants(matching: .any)["home.loading"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            loadingApp.descendants(matching: .any)["home.empty"].exists
        )
        loadingApp.terminate()

        let emptyApp = launch(scenario: "--ui-testing-home-empty")
        XCTAssertTrue(
            emptyApp.descendants(matching: .any)["home.empty"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            emptyApp.descendants(matching: .any)["home.loading"].exists
        )
        XCTAssertFalse(
            emptyApp.descendants(matching: .any)["home.error"].exists
        )
    }

    @MainActor
    func testCompletedDownloadPlaysWhileHomeLoadsOrIsUnavailable() {
        let loadingApp = launch(
            scenario: "--ui-testing-home-download-loading"
        )
        XCTAssertTrue(
            loadingApp.descendants(matching: .any)["home.loading"]
                .waitForExistence(timeout: 3)
        )
        assertDownloadedHomeBookPlays(in: loadingApp)
        loadingApp.terminate()

        let unavailableApp = launch(
            scenario: "--ui-testing-home-download-unavailable"
        )
        XCTAssertTrue(
            unavailableApp.descendants(matching: .any)["home.error"]
                .waitForExistence(timeout: 3)
        )
        assertDownloadedHomeBookPlays(in: unavailableApp)
    }

    @MainActor
    func testHomeShelfOrderUsesPriorityShelfIdentities() {
        let app = launch(scenario: "--ui-testing-home-shelf-order")
        let home = app.descendants(matching: .any)["home.shelves"]
        XCTAssertTrue(home.waitForExistence(timeout: 3))

        let orderedIdentifiers = home.descendants(matching: .any)
            .allElementsBoundByIndex
            .map(\.identifier)
            .filter {
                $0 == "home.downloaded" || $0.hasPrefix("home.shelf.")
            }
            .reduce(into: [String]()) { identifiers, identifier in
                if identifiers.last != identifier {
                    identifiers.append(identifier)
                }
            }
        XCTAssertEqual(
            orderedIdentifiers,
            [
                "home.shelf.continue-listening",
                "home.shelf.recently-added",
                "home.downloaded",
                "home.shelf.continue-series",
                "home.shelf.discover",
            ]
        )
    }

    @MainActor
    func testFailedHomeRefreshKeepsExistingShelvesMounted() {
        let app = launch(scenario: "--ui-testing-home-refresh-failure")
        let home = app.descendants(matching: .any)["home.shelves"]
        let existingShelf = app.descendants(matching: .any)[
            "home.shelf.continue-listening"
        ]
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertTrue(existingShelf.waitForExistence(timeout: 3))

        pullToRefresh(home)

        XCTAssertTrue(
            app.descendants(matching: .any)["home.refreshError"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(existingShelf.exists)
        XCTAssertTrue(app.staticTexts["The Test Audiobook"].exists)
    }

    @MainActor
    func testEmptyLibraryShowsRefreshFailureWithoutReplacingEmptyState() {
        let app = launch(
            scenario: "--ui-testing-empty-library-refresh-failure"
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        tabButton("Library", in: app).tap()

        let library = app.descendants(matching: .any)["books.list"]
        XCTAssertTrue(library.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["No audiobook libraries"]
                .waitForExistence(timeout: 3)
        )

        pullToRefresh(library)

        XCTAssertTrue(
            app.descendants(matching: .any)["library.refreshError"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["No audiobook libraries"].exists)
    }

    @MainActor
    private func assertDownloadedHomeBookPlays(in app: XCUIApplication) {
        let shelf = app.descendants(matching: .any)["home.downloaded"]
        let play = app.buttons["home.downloaded.ui-downloaded.play"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 3))
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertTrue(play.isEnabled)
        play.tap()
        let miniToggle = app.buttons["player.mini.toggle"]
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 10))
        let playbackReady = expectation(
            for: NSPredicate(format: "label == %@", "Pause"),
            evaluatedWith: miniToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playbackReady], timeout: 3),
            .completed
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["player.preparing"]
                .waitForNonExistence(timeout: 3)
        )
    }

    @MainActor
    func testBottomMiniPlayerLeavesTabsNavigable() {
        let app = launch(
            scenario: "--ui-testing-playback",
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

        let miniPlayer = app.descendants(matching: .any)[
            "player.mini.open"
        ]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(miniPlayer.frame.midY, app.frame.midY)

        let home = tabButton("Home", in: app)
        let library = tabButton("Library", in: app)
        let search = tabButton("Search", in: app)
        XCTAssertTrue(home.waitForExistence(timeout: 3))
        XCTAssertTrue(library.waitForExistence(timeout: 3))
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.tabBars.count,
            1,
            "Mobile navigation uses the native system tab bar"
        )
        let tabTop = min(home.frame.minY, library.frame.minY, search.frame.minY)
        XCTAssertGreaterThan(tabTop, app.frame.midY)
        XCTAssertLessThan(miniPlayer.frame.maxY, tabTop)

        library.tap()
        XCTAssertTrue(
            app.navigationBars["Library"].waitForExistence(timeout: 3)
        )

        XCTAssertGreaterThan(search.frame.minX, library.frame.maxX)
        let downloads = tabButton("Downloads", in: app)
        XCTAssertTrue(downloads.isHittable)
        downloads.tap()
        XCTAssertTrue(
            app.navigationBars["Downloads"].waitForExistence(timeout: 3)
        )

        let settings = tabButton("Settings", in: app)
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(
            app.navigationBars["Settings"].waitForExistence(timeout: 3)
        )

        XCTAssertTrue(home.isHittable)
        home.tap()
        XCTAssertTrue(
            app.navigationBars["The Test Audiobook"]
                .waitForExistence(timeout: 3)
        )

        let currentSearch = tabButton("Search", in: app)
        XCTAssertTrue(currentSearch.isHittable)
        currentSearch.tap()
        XCTAssertTrue(
            app.navigationBars["Search"].waitForExistence(timeout: 3)
        )
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
        app.buttons["player.chapter.0"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 1))
    }

    @MainActor
    func testChapterPickerOpensAtSoleCurrentChapter() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-long-chapter-list"]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        miniPlayer.tap()

        let chapters = app.buttons["player.chapters"]
        XCTAssertTrue(chapters.waitForExistence(timeout: 3))
        chapters.tap()

        let currentChapter = app.buttons["player.chapter.18"]
        XCTAssertTrue(currentChapter.waitForExistence(timeout: 3))
        XCTAssertTrue(currentChapter.isHittable)
        XCTAssertTrue(currentChapter.isSelected)
        XCTAssertEqual(selectedChapterRowCount(in: app), 1)

        let previousChapter = app.buttons["player.chapter.17"]
        XCTAssertTrue(previousChapter.isHittable)
        previousChapter.tap()
        XCTAssertTrue(
            app.otherElements["player.chapterPicker"]
                .waitForNonExistence(timeout: 3)
        )

        chapters.tap()
        XCTAssertTrue(previousChapter.waitForExistence(timeout: 3))
        XCTAssertTrue(previousChapter.isHittable)
        XCTAssertTrue(previousChapter.isSelected)
        XCTAssertFalse(currentChapter.isSelected)
        XCTAssertEqual(selectedChapterRowCount(in: app), 1)
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
        let chapter = app.buttons["player.chapter.0"]
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
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.exists)
        actions.tap()
        let transcription = app.buttons["book.detail.transcription"]
        XCTAssertTrue(transcription.waitForExistence(timeout: 3))
        XCTAssertFalse(transcription.isEnabled)
        XCTAssertFalse(app.buttons["book.detail.edit"].exists)
        XCTAssertFalse(app.buttons["book.detail.download"].exists)
    }

    @MainActor
    func testBookTranscriptionLoadsCacheAndSearchesEveryChapterIgnoringCase() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            )
        )
        app.staticTexts["The Test Audiobook"].tap()

        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        let transcription = app.buttons["book.detail.transcription"]
        XCTAssertTrue(transcription.waitForExistence(timeout: 3))
        XCTAssertTrue(transcription.isEnabled)
        transcription.tap()

        XCTAssertTrue(
            app.otherElements["transcription.view"].waitForExistence(
                timeout: 3
            )
        )
        XCTAssertTrue(app.buttons["transcription.chapter.0"].exists)
        XCTAssertTrue(app.buttons["transcription.chapter.1"].exists)
        XCTAssertTrue(app.buttons["transcription.start"].exists)
        XCTAssertFalse(app.progressIndicators.firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts["Transcribed 2 chapters in 2m 5s."]
                .waitForExistence(timeout: 3)
        )

        let select = app.buttons["transcription.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        select.tap()
        let selectAll = app.buttons["transcription.selectAll"]
        XCTAssertTrue(selectAll.waitForExistence(timeout: 3))
        let startBatch = app.buttons["transcription.startBatch"]
        XCTAssertTrue(startBatch.exists)
        XCTAssertFalse(startBatch.isEnabled)
        selectAll.tap()
        XCTAssertTrue(startBatch.isEnabled)
        select.tap()
        XCTAssertTrue(app.buttons["transcription.start"].exists)

        let segment = app.buttons["transcription.segment.0.0"]
        XCTAssertTrue(segment.waitForExistence(timeout: 3))
        segment.tap()
        let copyText = app.buttons["Copy Text"]
        XCTAssertTrue(copyText.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Move Playback Here"].exists)
        copyText.tap()

        let search = app.searchFields["Search Transcriptions"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.press(forDuration: 1)
        let paste = app.menuItems["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 3))
        paste.tap()
        XCTAssertEqual(
            search.value as? String,
            "The Doomsday Scenario begins"
        )
        app.buttons["Clear text"].tap()
        search.typeText("begins doomsday")
        XCTAssertTrue(
            app.buttons["transcription.searchResult.0"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.buttons["transcription.searchResult.1"].exists)
        app.buttons["Clear text"].tap()
        search.typeText("doomsday")
        XCTAssertTrue(
            app.buttons["transcription.searchResult.0"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["transcription.searchResult.1"].exists)

        app.buttons["transcription.searchResult.1"].tap()
        let movePlayback = app.buttons["Move Playback Here"]
        XCTAssertTrue(movePlayback.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Copy Text"].exists)
        movePlayback.tap()
        XCTAssertTrue(app.otherElements["transcription.view"].exists)

        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        let chapterUpdated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Chapter Two"),
            object: miniPlayer
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [chapterUpdated], timeout: 3),
            .completed
        )
    }

    @MainActor
    func testTranscriptPlaybackFailureKeepsTranscriptVisible() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            )
        )
        app.staticTexts["The Test Audiobook"].tap()
        app.buttons["book.detail.actions"].tap()
        app.buttons["book.detail.transcription"].tap()

        let transcript = app.otherElements["transcription.view"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 3))
        let segment = app.buttons["transcription.segment.0.0"]
        XCTAssertTrue(segment.waitForExistence(timeout: 3))
        segment.tap()
        app.buttons["Move Playback Here"].tap()

        XCTAssertTrue(transcript.exists)
        let failureMessage =
            "Bleat could not reach the Audiobookshelf server."
        let failure = app.descendants(matching: .any)
            .matching(identifier: "transcription.playbackError")
            .matching(NSPredicate(format: "label == %@", failureMessage))
            .firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 3))
        XCTAssertEqual(failure.label, failureMessage)
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
        XCTAssertFalse(
            app.buttons.matching(
                NSPredicate(
                    format: "label == %@",
                    "Play The Test Audiobook"
                )
            ).firstMatch.exists
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

    @MainActor
    private func assertContextMenu(
        for element: XCUIElement,
        progressLabel: String,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(element.waitForExistence(timeout: 3))
        element.press(forDuration: 1)
        XCTAssertTrue(app.buttons[progressLabel].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
        app.buttons[progressLabel].tap()
        XCTAssertTrue(
            app.buttons[progressLabel].waitForNonExistence(timeout: 3))
    }

    @MainActor
    private func selectedChapterRowCount(in app: XCUIApplication) -> Int {
        let rows = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "player.chapter."
            )
        )
        return (0..<rows.count).reduce(into: 0) { count, index in
            if rows.element(boundBy: index).isSelected {
                count += 1
            }
        }
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
        let environment = try await liveEnvironment()
        var app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(timeout: 10)
        )
        let serverField = app.textFields["login.server"]
        serverField.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        serverField.typeText(environment.server)
        let usernameField = app.textFields["login.username"]
        usernameField.tap()
        usernameField.typeText(environment.username)
        let passwordField = app.secureTextFields["login.password"]
        passwordField.tap()
        passwordField.typeText(
            environment.password
        )
        app.buttons["login.submit"].tap()

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 30
            )
        )
        dismissSavePasswordPromptIfNeeded(app: app)

        let remotePlay = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "home.book.",
                ".play"
            )
        ).firstMatch
        XCTAssertTrue(remotePlay.waitForExistence(timeout: 30))
        let remoteOpen = app.buttons[
            String(remotePlay.identifier.dropLast(".play".count))
        ]
        XCTAssertTrue(remoteOpen.waitForExistence(timeout: 20))
        XCTAssertTrue(remotePlay.isHittable)
        XCTAssertTrue(remoteOpen.isHittable)
        XCTAssertEqual(remotePlay.frame.width, 44, accuracy: 0.5)
        XCTAssertEqual(remotePlay.frame.height, 44, accuracy: 0.5)

        remoteOpen.tap()
        XCTAssertTrue(
            app.staticTexts["book.detail.title"].waitForExistence(timeout: 20)
        )
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(remotePlay.waitForExistence(timeout: 20))

        remotePlay.tap()
        XCTAssertTrue(
            app.buttons["player.mini.open"].waitForExistence(timeout: 30)
        )
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        let remotePause = expectation(
            for: NSPredicate(format: "label BEGINSWITH %@", "Pause "),
            evaluatedWith: remotePlay
        )
        await fulfillment(of: [remotePause], timeout: 10)
        remotePlay.tap()
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        stopMiniPlayer(in: app)

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
        app.buttons["book.detail.download.fullBook"].tap()

        stopMiniPlayer(in: app)
        tabButton("Home", in: app).tap()
        let downloadedPlay = app.buttons.matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                "home.downloaded.",
                ".play",
                "Play multi-track"
            )
        ).firstMatch
        XCTAssertTrue(downloadedPlay.waitForExistence(timeout: 30))
        let downloadedOpen = app.buttons[
            String(downloadedPlay.identifier.dropLast(".play".count))
        ]
        XCTAssertTrue(downloadedOpen.waitForExistence(timeout: 20))
        XCTAssertTrue(downloadedPlay.isHittable)
        XCTAssertTrue(downloadedOpen.isHittable)
        XCTAssertEqual(downloadedPlay.frame.width, 44, accuracy: 0.5)
        XCTAssertEqual(downloadedPlay.frame.height, 44, accuracy: 0.5)

        downloadedOpen.tap()
        XCTAssertTrue(
            app.staticTexts["book.detail.title"].waitForExistence(timeout: 20)
        )
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(downloadedPlay.waitForExistence(timeout: 20))

        downloadedPlay.tap()
        XCTAssertTrue(
            app.buttons["player.mini.open"].waitForExistence(timeout: 30)
        )
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)
        if releaseSecretScanIsEnabled {
            app.terminate()
            app = XCUIApplication()
            app.launchArguments = [
                "--release-secret-scan-enable-telemetry"
            ]
            app.launch()
            XCTAssertTrue(
                app.otherElements["app.signedIn"].waitForExistence(
                    timeout: 30
                )
            )
            tabButton("Settings", in: app).tap()
            let diagnostics = app.buttons["settings.diagnostics"]
            scrollUntilHittable(diagnostics, in: app, direction: .up)
            XCTAssertTrue(diagnostics.isHittable)
            diagnostics.tap()
            XCTAssertTrue(
                app.navigationBars["Diagnostics"].waitForExistence(
                    timeout: 10
                )
            )
            XCTAssertTrue(
                app.descendants(matching: .any)[
                    "diagnostics.serverVersion"
                ].waitForExistence(timeout: 10)
            )
            app.navigationBars.buttons.firstMatch.tap()
            tabButton("Library", in: app).tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["books.list"]
                    .waitForExistence(timeout: 30)
            )
            try await Task.sleep(for: .seconds(12))
        }
        app.terminate()
    }

    @MainActor
    func testLiveOfflineCachedDownloadAndLocalProgress() throws {
        try requireLiveConfiguration()
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 30
            )
        )
        let downloadedPlay = app.buttons.matching(
            NSPredicate(
                format:
                    "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                "home.downloaded.",
                ".play",
                "Play multi-track"
            )
        ).firstMatch
        XCTAssertTrue(downloadedPlay.waitForExistence(timeout: 30))
        XCTAssertTrue(downloadedPlay.isHittable)
        downloadedPlay.tap()
        XCTAssertFalse(app.staticTexts["book.detail.title"].exists)

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
    func testReleaseSecretScanRefreshAfterTokenInvalidation() throws {
        guard releaseSecretScanIsEnabled else {
            throw XCTSkip("Run scripts/test-release-secret-leakage.sh")
        }
        try requireLiveConfiguration()
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 30)
        )
        tabButton("Library", in: app).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["books.list"]
                .waitForExistence(timeout: 30)
        )
        app.terminate()
    }

    @MainActor
    func testReleaseSecretScanLogout() throws {
        guard releaseSecretScanIsEnabled else {
            throw XCTSkip("Run scripts/test-release-secret-leakage.sh")
        }
        try requireLiveConfiguration()
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 30)
        )
        tabButton("Settings", in: app).tap()
        let account = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "settings.account."
            )
        ).firstMatch
        scrollUntilHittable(account, in: app, direction: .down)
        XCTAssertTrue(account.isHittable)
        account.tap()

        let remove = app.buttons["accountEditor.removeAccount"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        let thisDevice = app.sheets.buttons["Only on This Device"]
        XCTAssertTrue(thisDevice.waitForExistence(timeout: 10))
        thisDevice.tap()
        let deleteHistory = app.sheets.buttons["Delete Listening History"]
        XCTAssertTrue(deleteHistory.waitForExistence(timeout: 10))
        deleteHistory.tap()
        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(timeout: 30)
        )
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
        let quickPlayButtons = seriesResults.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "series.book.",
                ".play"
            )
        )
        XCTAssertGreaterThanOrEqual(quickPlayButtons.count, 2)
        let quickPlay = quickPlayButtons.element(boundBy: 1)
        XCTAssertTrue(quickPlay.isHittable)
        quickPlay.tap()
        XCTAssertTrue(
            app.buttons["player.mini.open"].waitForExistence(timeout: 30)
        )
        XCTAssertTrue(seriesResults.exists)
        stopMiniPlayer(in: app)
        playbackBook.tap()
    }

    @MainActor
    private func stopMiniPlayer(in app: XCUIApplication) {
        let toggle = app.buttons["player.mini.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30))
        let start = toggle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: 80))
        )
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 10))
    }

    private enum LiveScrollDirection {
        case up, down
    }

    @MainActor
    private func scrollUntilHittable(
        _ element: XCUIElement,
        in app: XCUIApplication,
        direction: LiveScrollDirection
    ) {
        for _ in 0..<20 {
            if element.waitForExistence(timeout: 0.5), element.isHittable {
                return
            }
            switch direction {
            case .up:
                app.swipeUp()
            case .down:
                app.swipeDown()
            }
        }
    }

    private var releaseSecretScanIsEnabled: Bool {
        ProcessInfo.processInfo.environment["BLEAT_RELEASE_SECRET_SCAN"] == "1"
    }

    @MainActor
    private func liveEnvironment() async throws -> (
        server: String,
        username: String,
        password: String
    ) {
        let environment = ProcessInfo.processInfo.environment
        guard let server = environment["BLEAT_LIVE_APP_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"]
        else {
            throw XCTSkip(
                "Run scripts/test-app-live.sh to provide live app data"
            )
        }
        let password: String?
        if releaseSecretScanIsEnabled {
            guard let rawURL = environment[
                "BLEAT_RELEASE_SECRET_BROKER_URL"
            ], let url = URL(string: rawURL)
            else {
                throw XCTSkip(
                    "Run scripts/test-release-secret-leakage.sh"
                )
            }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                data.count >= 16
            else {
                throw URLError(.badServerResponse)
            }
            password = String(data: data, encoding: .utf8)
        } else {
            password = environment["BLEAT_LIVE_PASSWORD"]
        }
        guard let password else {
            throw XCTSkip(
                "Run scripts/test-app-live.sh to provide live app data"
            )
        }
        return (server, username, password)
    }

    private func requireLiveConfiguration() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BLEAT_LIVE_APP_URL"] != nil,
            environment["BLEAT_LIVE_USERNAME"] != nil
        else {
            throw XCTSkip(
                "Run scripts/test-app-live.sh to provide live app data"
            )
        }
    }
}
