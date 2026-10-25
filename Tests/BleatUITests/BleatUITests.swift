import CoreGraphics
import UIKit
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
    let sheet = app.sheets["Save Password?"]
    guard sheet.waitForExistence(timeout: 5) else { return }
    let notNow = sheet.buttons["Not Now"]
    let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate(format: "exists == true AND hittable == true"),
        object: notNow)
    guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
        XCTFail("Save Password dismissal did not become interactive")
        return
    }
    notNow.tap()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 10))
}

final class BleatUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func testCloudAccountSelectionCancelDefersUntilNextLaunch() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-cloud-account-selection"]
        )
        let cancel = app.buttons["icloud.accountSelection.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["app.signedIn"].exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
    }

    @MainActor
    func testCloudAccountSelectionSwipeDefersUntilNextLaunch() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-cloud-account-selection"]
        )
        let cancel = app.buttons["icloud.accountSelection.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
        let sheet = app.navigationBars["Accounts from iCloud"]
        XCTAssertTrue(sheet.exists)
        let start = sheet.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let end = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)
        )
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))

        app.terminate()
        app.launch()
        XCTAssertTrue(cancel.waitForExistence(timeout: 10))
    }

    @MainActor
    func testCloudAccountSelectionFailureShowsErrorAndAllowsRetry() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-cloud-account-selection",
                "--ui-testing-cloud-selection-fail-once",
            ]
        )
        let candidate = app.buttons["icloud.accountCandidate.ui-account"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        candidate.tap()
        let useSelected = app.buttons["icloud.accountSelection.useSelected"]
        useSelected.tap()
        let error = app.descendants(matching: .any)[
            "icloud.accountSelection.error"
        ]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(useSelected.isEnabled)
        useSelected.tap()
        XCTAssertTrue(useSelected.waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testCloudAccountSelectionNonretryableFailureCanBeDismissed() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-cloud-account-selection",
                "--ui-testing-cloud-selection-nonretryable",
            ]
        )
        let candidate = app.buttons["icloud.accountCandidate.ui-account"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        candidate.tap()
        let useSelected = app.buttons["icloud.accountSelection.useSelected"]
        useSelected.tap()
        let error = app.descendants(matching: .any)[
            "icloud.accountSelection.error"
        ]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertFalse(useSelected.isEnabled)
        let cancel = app.buttons["icloud.accountSelection.cancel"]
        XCTAssertTrue(cancel.isEnabled)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testCloudAccountSelectionPostCommitFailureShowsAlert() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-cloud-account-selection",
                "--ui-testing-cloud-auth-failure",
            ]
        )
        let candidate = app.buttons["icloud.accountCandidate.ui-account"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        candidate.tap()
        app.buttons["icloud.accountSelection.useSelected"].tap()
        let alert = app.alerts["Cannot Restore iCloud Account"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["icloud.accountSelection.cancel"].exists)
        alert.buttons["OK"].tap()
    }

    @MainActor
    func
        testCloudAccountSelectionCommittedSendFailureClosesChoiceAndShowsAlert()
    {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-cloud-account-selection",
                "--ui-testing-cloud-selection-send-failure",
            ]
        )
        let candidate = app.buttons["icloud.accountCandidate.ui-account"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))
        candidate.tap()
        app.buttons["icloud.accountSelection.useSelected"].tap()
        let alert = app.alerts["Cannot Restore iCloud Account"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.buttons["icloud.accountSelection.useSelected"].exists)
        alert.buttons["OK"].tap()
    }

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
    func testLaunchingScreenDescribesStartupWork() async throws {
        let app = launch(scenario: "--ui-testing-launching")
        // Exercise delayed automation attachment beyond the old five-second
        // fixture timeout, which let startup finish before CI inspected it.
        try await Task.sleep(for: .seconds(6))
        let launchScreen = app.descendants(matching: .any)["app.launching"]
        let expectedLabel = "Starting Bleat. Restoring your account"

        XCTAssertTrue(launchScreen.waitForExistence(timeout: 10))
        let launchStatus = expectation(
            for: NSPredicate(format: "label == %@", expectedLabel),
            evaluatedWith: launchScreen
        )
        await fulfillment(of: [launchStatus], timeout: 10)
        XCTAssertEqual(
            launchScreen.label,
            expectedLabel
        )
        launchScreen.tap()
        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(timeout: 10)
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
        XCTAssertEqual(
            app.buttons["book.detail.author.0"].frame.midY,
            app.buttons["book.detail.author.1"].frame.midY,
            accuracy: 1
        )
        XCTAssertTrue(
            app.buttons["book.detail.series.0"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["book.detail.series.0"].isHittable)
        XCTAssertTrue(
            app.buttons["book.detail.series.1"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["book.detail.series.1"].isHittable)
        XCTAssertEqual(
            app.buttons["book.detail.series.0"].frame.midY,
            app.buttons["book.detail.series.1"].frame.midY,
            accuracy: 1
        )
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
    func testColdResumeFailureOffersRetryAndKeepsSelectedBookAfterDismissal() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-resume-failure"])
        let alert = app.alerts["Server unavailable"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["Retry"].exists)
        alert.buttons["Cancel"].tap()
        let mini = app.buttons["player.mini.open"]
        XCTAssertTrue(mini.waitForExistence(timeout: 3))
        mini.tap()
        XCTAssertTrue(
            app.staticTexts["player.error"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["player.retry"].exists)
        app.buttons["player.retry"].tap()
        XCTAssertTrue(app.buttons["player.toggle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["player.toggle"].label, "Pause")
    }

    @MainActor
    func testColdResumeAuthenticationOffersAccountEditor() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: [
                "--ui-testing-resume-failure",
                "--ui-testing-resume-authentication",
            ])
        let alert = app.alerts["Sign in again"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        XCTAssertTrue(alert.buttons["Sign In"].exists)
        alert.buttons["Sign In"].tap()
        XCTAssertTrue(
            app.textFields["accountEditor.server"].waitForExistence(timeout: 5))
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
    func testMiniPlayerMaintainsReadableAccessoryContrast() throws {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-dynamic-type-audit"])
        let play = app.buttons["home.book.ui-book.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        let playing = expectation(
            for: NSPredicate(format: "label == %@", "playing"),
            evaluatedWith: app.staticTexts["testing.playback.state"])
        wait(for: [playing], timeout: 10)

        let miniPlayer = app.descendants(matching: .any)["player.mini"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        app.swipeUp()
        app.swipeUp()

        let screenshot = app.screenshot()
        let miniPlayerImage = try crop(
            screenshot.image,
            to: miniPlayer.frame,
            in: app.frame
        )
        let attachment = XCTAttachment(image: miniPlayerImage)
        attachment.name = "mini-player-accessory-contrast"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertTrue(app.buttons["player.mini.open"].isHittable)
        XCTAssertTrue(app.buttons["player.mini.toggle"].isHittable)
        let miniPlayerFrame = miniPlayer.frame
        // XCTest audits rendered foreground/background contrast per element,
        // so a readable title cannot hide unreadable secondary text or controls.
        try app.performAccessibilityAudit(for: .contrast) { issue in
            guard let element = issue.element, !element.frame.isEmpty else {
                return false
            }
            return !element.frame.intersects(miniPlayerFrame)
        }
    }

    @MainActor
    func testMiniPlayerIsAbsentBeforePlayback() {
        let app = launch(scenario: "--ui-testing-playback")
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.descendants(matching: .any)["player.mini"].exists)
    }

    @MainActor
    func testBookDetailDisclosuresAndConfirmedChapterNavigation() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-multiple-accounts"]
        )
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
        let account = app.descendants(matching: .any)["book.detail.account"]
        XCTAssertFalse(duration.exists)
        XCTAssertFalse(account.exists)
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
        XCTAssertTrue(account.waitForExistence(timeout: 3))
        XCTAssertTrue(account.label.contains("reader"))
        XCTAssertTrue(account.label.contains("books.example"))
        XCTAssertEqual(language.frame.maxX, genres.frame.maxX, accuracy: 1)
        XCTAssertGreaterThan(account.frame.minY, genres.frame.minY)
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
    func testBookDetailTimeoutShowsRetryAndRecovers() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-book-detail-timeout"]
        )
        let book = app.buttons["home.book.ui-book"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()
        let retry = app.buttons["Try Again"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Request timed out"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["book.detail.loading"].exists)
        retry.tap()
        XCTAssertTrue(
            app.buttons["book.detail.play"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(retry.exists)
    }

    @MainActor
    func testSecondSeriesBookDetailRemainsLoaded() {
        let app = launch(scenario: "--ui-testing-signed-in")
        let book = app.buttons["home.book.ui-book"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()
        let series = app.buttons["book.detail.series.0"]
        XCTAssertTrue(series.waitForExistence(timeout: 5))
        series.tap()
        let secondBook = app.buttons["series.book.1"]
        XCTAssertTrue(secondBook.waitForExistence(timeout: 5))
        secondBook.tap()

        assertBookDetailRemainsLoaded(app, title: "Test Series Volume Two")
    }

    @MainActor
    func testRepeatedSeriesBookDetailKeepsOnlyTopEntryActive() {
        let app = launch(scenario: "--ui-testing-signed-in")
        let homeBook = app.buttons["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 5))
        homeBook.tap()
        let series = app.buttons["book.detail.series.0"]
        XCTAssertTrue(series.waitForExistence(timeout: 5))
        series.tap()
        let firstBook = app.buttons["series.book.0"]
        XCTAssertTrue(firstBook.waitForExistence(timeout: 5))
        firstBook.tap()
        XCTAssertTrue(series.waitForExistence(timeout: 5))
        series.tap()
        XCTAssertTrue(firstBook.waitForExistence(timeout: 5))
        firstBook.tap()
        assertBookDetailRemainsLoaded(app, title: "Test Series Volume One")

        app.navigationBars["Test Series Volume One"].buttons.firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["Test Series"].waitForExistence(timeout: 5))
        app.navigationBars["Test Series"].buttons.firstMatch.tap()
        assertBookDetailRemainsLoaded(app, title: "Test Series Volume One")
    }

    @MainActor
    private func assertBookDetailRemainsLoaded(
        _ app: XCUIApplication, title: String
    ) {
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let loading = app.descendants(matching: .any)["book.detail.loading"]
        XCTAssertEqual(
            XCTWaiter.wait(
                for: [
                    XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "exists == true"),
                        object: loading
                    )
                ],
                timeout: 3
            ),
            .timedOut,
            "Loaded series book detail must not return to the loading state"
        )
        XCTAssertTrue(play.exists)
        XCTAssertTrue(app.navigationBars[title].exists)
    }

    @MainActor
    func testBookDetailPlacesChapterProgressBelowPlayback() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-transcription-server-progress"
            ]
        )
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.tap()

        let play = app.buttons["book.detail.play"]
        let chapter = app.staticTexts["book.detail.progress.chapter"]
        let percentage = app.staticTexts["book.detail.progress.percentage"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertTrue(chapter.waitForExistence(timeout: 3))
        XCTAssertEqual(chapter.label, "Chapter 2/2")
        XCTAssertEqual(percentage.label, "96%")
        XCTAssertGreaterThanOrEqual(chapter.frame.minY, play.frame.maxY)
    }

    @MainActor
    func testBookDetailDownloadStatusWrapsAtLargestDynamicType() {
        assertBookDetailDownloadStatusFits(
            contentSize: .accessibilityExtraExtraExtraLarge
        )
    }

    @MainActor
    func testBookDetailDownloadStatusFitsAtDefaultDynamicType() {
        assertBookDetailDownloadStatusFits(contentSize: .large)
    }

    @MainActor
    private func assertBookDetailDownloadStatusFits(
        contentSize: UIContentSizeCategory,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = launch(
            scenario: "--ui-testing-context-download-removal",
            additionalArguments: [
                "--ui-testing-paused-download",
                "-UIPreferredContentSizeCategoryName",
                contentSize.rawValue,
            ]
        )
        let book = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(
            book.waitForExistence(timeout: 10), file: file, line: line)
        book.tap()
        let detail = app.descendants(matching: .any)["book.detail"]
        let status = app.descendants(matching: .any)[
            "book.detail.downloadStatus"
        ]
        let stop = app.buttons["book.detail.download.stop"]
        for _ in 0..<20 {
            if status.exists, stop.isHittable,
                app.frame.contains(status.frame)
            {
                break
            }
            detail.swipeUp()
        }
        XCTAssertTrue(status.exists, file: file, line: line)
        XCTAssertTrue(status.label.contains("Paused"), file: file, line: line)
        XCTAssertTrue(
            status.label.contains("80/160 KB"), file: file, line: line)
        XCTAssertTrue(app.frame.contains(status.frame), file: file, line: line)
        XCTAssertTrue(stop.isHittable, file: file, line: line)
        XCTAssertTrue(app.frame.contains(stop.frame), file: file, line: line)
        XCTAssertLessThanOrEqual(
            status.frame.maxX, stop.frame.minX, file: file, line: line)
        let progress = app.progressIndicators["book.detail.downloadProgress"]
        XCTAssertTrue(progress.exists, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            status.frame.minX, progress.frame.minX - 0.5, file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            status.frame.maxX, progress.frame.maxX + 0.5, file: file, line: line
        )
        XCTAssertLessThanOrEqual(
            status.frame.maxY, progress.frame.minY, file: file, line: line)

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Book detail download - \(contentSize.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testBookDetailHidesDownloadForCachedBook() {
        let app = launch(
            scenario: "--ui-testing-context-download-removal",
            additionalArguments: ["--ui-testing-automatic-context-download"]
        )
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.tap()

        XCTAssertTrue(
            app.staticTexts["book.detail.title"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.buttons["book.detail.download"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["book.detail.downloadStatus"]
                .exists
        )
    }

    @MainActor
    func testCompletedAutomaticWindowHasNoDownloadActions() {
        let app = launch(
            scenario: "--ui-testing-context-download-removal",
            additionalArguments: [
                "--ui-testing-automatic-context-download",
                "--ui-testing-complete-automatic-window",
            ]
        )
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.tap()

        let status = app.descendants(matching: .any)[
            "book.detail.downloadStatus"
        ]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("Downloaded"))
        XCTAssertEqual(
            app.progressIndicators["book.detail.downloadProgress"].value
                as? String,
            "100%"
        )
        XCTAssertFalse(app.buttons["book.detail.download.start"].exists)

        app.navigationBars.buttons.firstMatch.tap()
        tabButton("Downloads", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["Downloaded"].waitForExistence(timeout: 3))
        XCTAssertEqual(
            app.progressIndicators[
                "downloads.progress.ui-downloaded-download"
            ].value as? String,
            "100%"
        )
        XCTAssertFalse(app.buttons["downloads.start"].exists)

        tabButton("Home", in: app).tap()
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        XCTAssertFalse(
            app.buttons["book.context.ui-book.download"].exists
        )
        XCTAssertTrue(
            app.buttons["book.context.ui-book.removeDownload"].exists
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
        tabButton("Downloads", in: app).tap()
        let completePreparation = app.buttons[
            "testing.download.completePreparation"]
        XCTAssertTrue(completePreparation.waitForExistence(timeout: 3))
        completePreparation.tap()
        // The fixture has no media server; observe metadata preparation only.
        XCTAssertTrue(
            app.progressIndicators.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@", "downloads.progress.")
            ).firstMatch.waitForExistence(timeout: 20),
            "Context download did not create its record before removal")
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
    func testBookContextMenuRemovesLocalDownloadFromHome() {
        let app = launch(
            scenario: "--ui-testing-context-download-removal"
        )
        let downloadedPlay = app.buttons["home.downloaded.ui-book.play"]
        XCTAssertTrue(downloadedPlay.waitForExistence(timeout: 3))
        downloadedPlay.tap()
        XCTAssertTrue(
            app.buttons["player.mini.open"].waitForExistence(timeout: 3)
        )

        // Keep the five-second fixture active while exercising the context menu.
        let miniToggle = app.buttons["player.mini.toggle"]
        let playbackReady = expectation(
            for: NSPredicate(format: "label == %@", "Pause"),
            evaluatedWith: miniToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playbackReady], timeout: 10), .completed
        )
        miniToggle.tap()
        let playbackPaused = expectation(
            for: NSPredicate(format: "label == %@", "Play"),
            evaluatedWith: miniToggle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playbackPaused], timeout: 3), .completed
        )

        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        let remove = app.buttons[
            "book.context.ui-book.removeDownload"
        ]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        XCTAssertFalse(remove.isEnabled)
        app.buttons["Mark Unplayed"].tap()
        XCTAssertTrue(remove.waitForNonExistence(timeout: 3))

        XCTAssertTrue(miniToggle.waitForExistence(timeout: 3))
        let start = miniToggle.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: 80))
        )
        XCTAssertTrue(miniToggle.waitForNonExistence(timeout: 3))
        let removableHomeBook = app.descendants(matching: .any)[
            "home.book.ui-book"
        ]
        XCTAssertTrue(removableHomeBook.waitForExistence(timeout: 3))
        removableHomeBook.press(forDuration: 1)
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        XCTAssertTrue(remove.isEnabled)
        remove.tap()

        tabButton("Downloads", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["No Downloads"].waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testBookContextMenuRemovesLocalDownloadFromLibrary() {
        let app = launch(
            scenario: "--ui-testing-context-download-removal"
        )
        tabButton("Library", in: app).tap()
        let libraryBook = app.descendants(matching: .any)[
            "library.book.ui-book"
        ]
        XCTAssertTrue(libraryBook.waitForExistence(timeout: 3))
        libraryBook.press(forDuration: 1)
        let remove = app.buttons[
            "book.context.ui-book.removeDownload"
        ]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        XCTAssertTrue(remove.isEnabled)
        remove.tap()

        tabButton("Downloads", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["No Downloads"].waitForExistence(timeout: 3)
        )
        tabButton("Library", in: app).tap()
        libraryBook.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Download"].waitForExistence(timeout: 3))
        XCTAssertFalse(remove.exists)
    }

    @MainActor
    func testContextDownloadAndRemovalAreMutuallyExclusive() async throws {
        let app = launch(
            scenario: "--ui-testing-context-download-removal",
            additionalArguments: [
                "--ui-testing-automatic-context-download",
                "--ui-testing-slow-context-download",
            ]
        )
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        let download = app.buttons["Download"]
        let remove = app.buttons[
            "book.context.ui-book.removeDownload"
        ]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        XCTAssertFalse(download.exists)
        remove.tap()

        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        XCTAssertFalse(remove.exists)
        download.tap()

        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        XCTAssertFalse(download.isEnabled)
        XCTAssertFalse(remove.exists)
        app.buttons["Mark Unplayed"].tap()
        tabButton("Downloads", in: app).tap()
        let completePreparation = app.buttons[
            "testing.download.completePreparation"]
        XCTAssertTrue(completePreparation.waitForExistence(timeout: 3))
        completePreparation.tap()
        // The prior cached record was removed above. A new row proves that
        // the replacement request finished metadata preparation.
        XCTAssertTrue(
            app.progressIndicators.matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@", "downloads.progress.")
            ).firstMatch.waitForExistence(timeout: 20),
            "Replacement context download did not create its record")
    }

    @MainActor
    func testContextDownloadRemovalFailureUsesOriginatingAlert() {
        let app = launch(
            scenario: "--ui-testing-context-download-removal-failure"
        )
        let homeBook = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(homeBook.waitForExistence(timeout: 3))
        homeBook.press(forDuration: 1)
        let remove = app.buttons[
            "book.context.ui-book.removeDownload"
        ]
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()

        XCTAssertTrue(
            app.staticTexts[
                "Bleat could not access downloaded media storage."
            ].waitForExistence(timeout: 3)
        )
        app.buttons["OK"].tap()
        tabButton("Downloads", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["The Downloaded Audiobook"]
                .waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testTypedHomeFailureWithoutDownloads() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-typed-home-failure"])
        XCTAssertTrue(
            app.staticTexts["Sign in again"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "Your saved sign-in is no longer accepted by the server."
            ].exists)
    }

    @MainActor
    func testTypedHomeFailureKeepsDownloads() {
        let app = launch(
            scenario: "--ui-testing-home-download-unavailable",
            additionalArguments: ["--ui-testing-typed-home-failure"])
        XCTAssertTrue(
            app.staticTexts["Sign in again"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "Your saved sign-in is no longer accepted by the server."
            ].exists)
        XCTAssertTrue(app.staticTexts["The Downloaded Audiobook"].exists)
    }

    @MainActor
    func testTypedLibraryFailure() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-typed-library-failure"])
        tabButton("Library", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["Access denied"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "This account is not allowed to perform that action."
            ].exists)
    }

    @MainActor
    func testTypedCategoryFailureKeepsRetry() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-typed-category-failure"])
        tabButton("Library", in: app).tap()
        let modes = app.buttons["library.browseMode"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        modes.tap()
        app.buttons["By Author"].tap()
        XCTAssertTrue(
            app.staticTexts["Access denied"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "This account is not allowed to perform that action."
            ].exists)
        XCTAssertTrue(app.buttons["library.categories.retry"].exists)
    }

    @MainActor
    func testTypedSearchFailure() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-typed-search-failure"])
        tabButton("Search", in: app).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Test")
        XCTAssertTrue(
            app.staticTexts["Too many requests"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "The Audiobookshelf server asked Bleat to try again later."
            ].exists)
    }

    @MainActor
    func testTypedBookDetailFailureKeepsRetry() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-typed-detail-failure"])
        let book = app.buttons["home.book.ui-book"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()
        XCTAssertTrue(
            app.staticTexts["Too many requests"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "The Audiobookshelf server asked Bleat to try again later."
            ].exists)
        XCTAssertTrue(app.buttons["Try Again"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testDownloadErrorBannerDismissesWithoutRemovingBook() {
        let app = launch(
            scenario: "--ui-testing-context-download-removal-failure"
        )
        tabButton("Downloads", in: app).tap()
        let book = app.staticTexts["The Downloaded Audiobook"]
        XCTAssertTrue(book.waitForExistence(timeout: 3))
        app.buttons["downloads.removeAll"].tap()
        app.buttons["Remove Downloads"].tap()

        let banner = app.descendants(matching: .any)["downloads.error"]
        XCTAssertTrue(banner.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Download storage unavailable"].exists)
        XCTAssertTrue(
            app.staticTexts["Bleat could not access downloaded media storage."]
                .exists)
        XCTAssertTrue(book.exists)
        let dismiss = app.buttons["downloads.error.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 3))
        dismiss.tap()
        XCTAssertTrue(banner.waitForNonExistence(timeout: 3))
        XCTAssertTrue(book.exists)
    }

    @MainActor
    func testCloudStorageNoticeAcknowledgmentSurvivesForegroundAndRelaunch() {
        assertCloudStorageNoticeAcknowledgmentSurvivesForegroundAndRelaunch(
            legacyAcknowledged: false)
    }

    @MainActor
    func testLegacyDismissedCloudStorageNoticeRequiresRevisedConfirmation() {
        assertCloudStorageNoticeAcknowledgmentSurvivesForegroundAndRelaunch(
            legacyAcknowledged: true)
    }

    @MainActor
    private func
        assertCloudStorageNoticeAcknowledgmentSurvivesForegroundAndRelaunch(
            legacyAcknowledged: Bool
        )
    {
        let scenario = "--ui-testing-signed-in"
        let noticeArgument = "--ui-testing-cloud-storage-notice"
        var arguments = [
            noticeArgument, "--ui-testing-cloud-storage-notice-reset",
        ]
        if legacyAcknowledged {
            arguments.append(
                "--ui-testing-cloud-storage-notice-legacy-acknowledged")
        }
        let app = launch(
            scenario: scenario,
            additionalArguments: arguments)
        defer {
            app.terminate()
            app.launchArguments = [
                scenario, "--ui-testing-cloud-storage-notice-clear",
            ]
            app.launch()
            app.terminate()
        }
        let notice = app.alerts["Cloud storage update"]
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.buttons["All my devices are updated"].exists)
        XCTAssertTrue(notice.buttons["Later"].isHittable)
        notice.buttons["Later"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        let settings = tabButton("Settings", in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertTrue(settings.isHittable)
        settings.tap()
        XCTAssertTrue(
            settings.wait(for: \.isSelected, toEqual: true, timeout: 5))
        XCTAssertFalse(notice.exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.buttons["Later"].isHittable)
        notice.buttons["Later"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launchArguments = [scenario, noticeArgument]
        app.launch()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertTrue(notice.buttons["All my devices are updated"].isHittable)
        notice.buttons["All my devices are updated"].tap()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(
            tabButton("Settings", in: app)
                .wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertFalse(notice.waitForExistence(timeout: 2))
        app.terminate()
        app.launchArguments = [scenario, noticeArgument]
        app.launch()
        XCTAssertTrue(
            tabButton("Settings", in: app)
                .wait(for: \.isHittable, toEqual: true, timeout: 5))
        XCTAssertFalse(notice.waitForExistence(timeout: 2))
    }

    @MainActor
    func testSignedInAlertsPresentInSequence() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-signed-in-alert-queue"]
        )
        let playback = app.alerts["Playback unavailable"]
        XCTAssertTrue(playback.waitForExistence(timeout: 3))
        XCTAssertFalse(app.alerts["Server unavailable"].exists)
        playback.buttons["OK"].tap()
        XCTAssertTrue(
            app.alerts["Server unavailable"].waitForExistence(timeout: 3)
        )
        app.alerts["Server unavailable"].buttons["OK"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForNonExistence(timeout: 3))
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
    func testSeriesMembershipDraftEditingAndCancellation() throws {
        let app = launch(scenario: "--ui-testing-signed-in")
        let book = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        app.buttons["Edit"].tap()
        let add = app.buttons["metadata.series.add"]
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        let first = app.buttons["metadata.series.item.0"]
        let second = app.buttons["metadata.series.item.1"]
        XCTAssertTrue(first.label.contains("Test Series"))
        XCTAssertTrue(second.label.contains("Companion Series"))
        second.tap()
        let name = app.textFields["metadata.series.name"]
        let sequence = app.textFields["metadata.series.sequence"]
        XCTAssertEqual(name.value as? String, "Companion Series")
        XCTAssertEqual(sequence.value as? String, "1")
        sequence.tap()
        sequence.typeText(" cancelled")
        app.buttons["metadata.series.cancel"].tap()
        second.tap()
        XCTAssertEqual(sequence.value as? String, "1")
        sequence.tap()
        sequence.typeText(XCUIKeyboardKey.delete.rawValue + "2a")
        app.buttons["metadata.series.commit"].tap()
        XCTAssertTrue(second.label.contains("2a"))
        first.tap()
        XCTAssertEqual(sequence.value as? String, "1")
        app.buttons["metadata.series.cancel"].tap()
        second.tap()
        XCTAssertEqual(sequence.value as? String, "2a")
        app.buttons["metadata.series.remove"].tap()
        XCTAssertTrue(second.waitForNonExistence(timeout: 3))
        XCTAssertTrue(first.label.contains("Test Series"))

        add.tap()
        XCTAssertEqual(name.value as? String, "Series")
        XCTAssertEqual(sequence.value as? String, "Sequence")
        app.buttons["metadata.series.commit"].tap()
        XCTAssertTrue(app.staticTexts["metadata.series.error"].exists)
        name.tap()
        name.typeText("  Test Series  ")
        sequence.tap()
        sequence.typeText("  001.5 | Part II, bonus  ")
        app.buttons["metadata.series.commit"].tap()
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        second.tap()
        XCTAssertEqual(name.value as? String, "Test Series")
        XCTAssertEqual(sequence.value as? String, "001.5 | Part II, bonus")
        app.buttons["metadata.series.cancel"].tap()
        first.tap()
        app.buttons["metadata.series.remove"].tap()
        XCTAssertTrue(first.label.contains("001.5 | Part II, bonus"))
        first.tap()
        app.buttons["metadata.series.remove"].tap()
        XCTAssertTrue(first.waitForNonExistence(timeout: 3))
        add.tap()
        app.buttons["metadata.series.cancel"].tap()
        XCTAssertFalse(first.exists)
        add.tap()
        name.tap()
        name.typeText("No Sequence")
        app.buttons["metadata.series.commit"].tap()
        first.tap()
        XCTAssertEqual(name.value as? String, "No Sequence")
        XCTAssertEqual(sequence.value as? String, "Sequence")
        app.buttons["metadata.series.cancel"].tap()

        app.buttons["Cancel"].tap()
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        app.buttons["Edit"].tap()
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        XCTAssertTrue(first.label.contains("Test Series"))
        XCTAssertTrue(second.label.contains("Companion Series"))
    }

    @MainActor
    func testBookEditorDisplaysCachedCover() throws {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-cover-image"])
        let book = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()
        XCTAssertTrue(
            app.buttons["book.detail.actions"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(try redCoverFraction(app.screenshot().image), 0.01)
        app.buttons["book.detail.actions"].tap()
        app.buttons["Edit"].tap()
        XCTAssertTrue(
            app.textFields["metadata.title"].waitForExistence(timeout: 5))
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        let screenshot = form.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertGreaterThan(
            try redCoverFraction(screenshot.image), 0.04,
            "The editor must render the cached red cover, not its grey placeholder"
        )
    }

    @MainActor
    func testBookContextEditorDisplaysCover() throws {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-cover-image"])
        let book = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.press(forDuration: 1)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3))
        edit.tap()
        XCTAssertTrue(
            app.textFields["metadata.title"].waitForExistence(timeout: 5))
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(
            try redCoverFraction(form.screenshot().image), 0.04)
    }

    private func redCoverFraction(_ image: UIImage) throws -> Double {
        let width = 128
        let height = 256
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(
            try XCTUnwrap(image.cgImage),
            in: CGRect(x: 0, y: 0, width: width, height: height))
        let count = stride(from: 0, to: pixels.count, by: 4).count {
            pixels[$0] > 150 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80
        }
        return Double(count) / Double(width * height)
    }

    @MainActor
    func testBookDetailEditSurvivesSameBookDownloadProgress() {
        checkEditDuringDownload(
            scenario: "--ui-testing-context-download-removal")
    }

    @MainActor
    func testBookDetailEditSurvivesUnrelatedDownloadProgress() {
        checkEditDuringDownload(scenario: "--ui-testing-home-shelf-order")
    }

    @MainActor
    private func checkEditDuringDownload(
        scenario: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = launch(
            scenario: scenario,
            additionalArguments: ["--ui-testing-edit-download-progress"])
        let book = app.descendants(matching: .any)["home.book.ui-book"]
        XCTAssertTrue(book.waitForExistence(timeout: 5), file: file, line: line)
        book.tap()
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(
            actions.waitForExistence(timeout: 5), file: file, line: line)
        let menuStarted = Date()
        actions.tap()
        XCTAssertLessThan(
            Date().timeIntervalSince(menuStarted), 10,
            "Progress kept the actions menu busy until the download finished",
            file: file, line: line)
        let edit = app.buttons["Edit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 3), file: file, line: line)
        // Native menu actions expose their title, not a custom accessibility value.
        let advance = app.buttons["Advance Download (0)"]
        XCTAssertTrue(
            advance.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(advance.isHittable, file: file, line: line)
        advance.tap()
        XCTAssertTrue(
            app.buttons["Advance Download (2)"].waitForExistence(timeout: 10),
            "Expected two download progress callbacks while Edit remained open",
            file: file, line: line)
        XCTAssertTrue(
            edit.exists, "Download progress dismissed the actions menu",
            file: file, line: line)
        guard edit.exists else { return }
        edit.tap()
        let title = app.textFields["metadata.title"]
        XCTAssertTrue(
            title.waitForExistence(timeout: 3), file: file, line: line)
        guard title.exists else { return }
        title.tap()
        title.typeText(" draft")
        let draft = title.value as? String
        let completion = app.buttons["testing.download.complete"]
        XCTAssertTrue(
            completion.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertEqual(
            completion.label, "Download: running",
            "Enter the draft while the download is active", file: file,
            line: line)
        XCTAssertTrue(completion.isHittable, file: file, line: line)
        completion.tap()
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                completion.label == "Download: completed"
            }, object: nil)
        XCTAssertEqual(
            XCTWaiter.wait(for: [completed], timeout: 10), .completed,
            "The completed fixture must restore its downloaded record before the draft assertion",
            file: file, line: line
        )
        XCTAssertTrue(
            title.exists, "Download progress dismissed the editor", file: file,
            line: line)
        XCTAssertEqual(title.value as? String, draft, file: file, line: line)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(
            actions.waitForExistence(timeout: 3), file: file, line: line)
        actions.tap()
        app.buttons["Edit"].tap()
        XCTAssertTrue(
            title.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertNotEqual(
            title.value as? String, draft, "Cancel should discard the draft",
            file: file, line: line)
        title.tap()
        title.typeText(" saved")
        app.buttons["metadata.save"].tap()
        XCTAssertTrue(
            title.waitForNonExistence(timeout: 5), file: file, line: line)
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

        tabButton("Library", in: app).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["library.book.ui-book"]
                .waitForExistence(timeout: 5)
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
        let keyboardSearch = app.keyboards.buttons["Search"]
        if keyboardSearch.exists, keyboardSearch.isHittable {
            keyboardSearch.tap()
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
        }
        let searchResults = app.descendants(matching: .any)["search.results"]
        scrollUntilClear(
            author,
            of: [
                searchField,
                app.buttons["search.done"],
                app.keyboards.firstMatch,
            ],
            in: searchResults,
            app: app
        )
        let searchDone = app.buttons["search.done"]
        if searchDone.exists, searchDone.isHittable {
            searchDone.tap()
            XCTAssertTrue(searchDone.waitForNonExistence(timeout: 3))
            XCTAssertTrue(author.waitForExistence(timeout: 3))
        }
        author.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)
        ).tap()
        let clear = app.buttons["library.activeFilter.clear"]
        XCTAssertTrue(clear.waitForExistence(timeout: 10))
        XCTAssertTrue(searchField.waitForNonExistence(timeout: 3))
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
        scrollUntilClear(
            series,
            of: [
                searchField,
                app.buttons["search.done"],
                app.keyboards.firstMatch,
            ],
            in: searchResults,
            app: app
        )
        if searchDone.exists, searchDone.isHittable {
            searchDone.tap()
            XCTAssertTrue(searchDone.waitForNonExistence(timeout: 3))
            XCTAssertTrue(series.waitForExistence(timeout: 3))
        }
        series.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)
        ).tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["series.results"]
                .waitForExistence(timeout: 5)
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
    func testStatisticsShowsImportedBookAndSessionDetailsAtLargestTextSize() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-open-settings", "--ui-testing-statistics",
                "-UIPreferredContentSizeCategoryName",
                UIContentSizeCategory.accessibilityExtraExtraExtraLarge
                    .rawValue,
            ])
        tabButton("Settings", in: app).tap()
        let link = app.descendants(matching: .any)["settings.statistics"]
            .firstMatch
        for _ in 0..<12 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(
            app.navigationBars["Listening Statistics"].waitForExistence(
                timeout: 5))
        let book = app.buttons["statistics.book"].firstMatch
        for _ in 0..<16 where !book.isHittable { app.swipeUp() }
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book.tap()
        XCTAssertTrue(
            app.navigationBars["Statistics Example"].waitForExistence(
                timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "1 hr 0 min")
            ).firstMatch.exists)
        let coverage = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS %@", "All Devices (imported history)")
        ).firstMatch
        for _ in 0..<4 where !coverage.isHittable { app.swipeUp() }
        let bookScreenshot = XCTAttachment(screenshot: app.screenshot())
        bookScreenshot.lifetime = .keepAlways
        add(bookScreenshot)
        XCTAssertTrue(coverage.exists)
        app.navigationBars.buttons.firstMatch.tap()
        let session = app.buttons["statistics.session"].firstMatch
        for _ in 0..<8 where !session.isHittable { app.swipeUp() }
        XCTAssertTrue(session.exists)
        session.tap()
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Started")
            ).firstMatch.waitForExistence(timeout: 5))
        for _ in 0..<4 where !coverage.isHittable { app.swipeUp() }
        let sessionScreenshot = XCTAttachment(screenshot: app.screenshot())
        sessionScreenshot.lifetime = .keepAlways
        add(sessionScreenshot)
        XCTAssertTrue(coverage.exists)
        XCTAssertFalse(app.staticTexts["Audiobook Time in This App"].exists)
    }

    @MainActor
    func testStatisticsResetRequiresSelectedScopeAndDestructiveConfirmation() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-open-settings", "--ui-testing-statistics",
            ])
        tabButton("Settings", in: app).tap()
        let link = app.buttons["settings.statistics"]
        for _ in 0..<12 where !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        let account = app.buttons["statistics.account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.tap()
        app.buttons["reader@books.example"].tap()
        let range = app.buttons["statistics.range"]
        range.tap()
        app.buttons["Last 7 Days"].tap()
        let reset = app.buttons["statistics.reset"]
        for _ in 0..<12 where !reset.isHittable { app.swipeUp() }
        XCTAssertTrue(reset.exists)
        reset.tap()
        let confirm = app.buttons["Delete reader@books.example Statistics"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "Last 7 Days")
            ).firstMatch.exists)
        let cancel = app.buttons["Cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertTrue(reset.exists)
        reset.tap()
        confirm.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["statistics.book"].exists)
    }

    @MainActor
    func testDownloadSettingsControlsReflectAndUpdatePreferences() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "-bleat.downloads.networkPolicy.v1", "wifiOnly",
                "-bleat.downloads.maximumConcurrentDownloads.v1", "5",
                "-bleat.downloads.automaticLookahead.v1", "5",
                "-bleat.downloads.automaticCleanupPolicy.v1",
                "afterTwentyFourHours",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        tabButton("Settings", in: app).tap()

        let wifiOnly = app.descendants(matching: .any)[
            "settings.downloads.wifiOnly"
        ]
        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.downloads.wifiOnly",
            direction: .up
        )
        XCTAssertTrue(wifiOnly.waitForExistence(timeout: 3))
        XCTAssertEqual(wifiOnly.value as? String, "1")
        wifiOnly.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
        XCTAssertEqual(wifiOnly.value as? String, "0")
        wifiOnly.coordinate(
            withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)
        ).tap()
        XCTAssertEqual(wifiOnly.value as? String, "1")

        let settingsForm = app.descendants(matching: .any)["settings.form"]
        settingsForm.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.75)
        ).press(
            forDuration: 0.05,
            thenDragTo: settingsForm.coordinate(
                withNormalizedOffset: CGVector(dx: 0.1, dy: 0.55)
            )
        )

        let maximumConcurrent = app.descendants(matching: .any)[
            "settings.downloads.maximumConcurrent"
        ]
        XCTAssertTrue(maximumConcurrent.waitForExistence(timeout: 3))
        XCTAssertEqual(maximumConcurrent.value as? String, "5")
        app.buttons[
            "settings.downloads.maximumConcurrent-Increment"
        ].tap()
        XCTAssertEqual(maximumConcurrent.value as? String, "10")
        app.buttons[
            "settings.downloads.maximumConcurrent-Decrement"
        ].tap()
        XCTAssertEqual(maximumConcurrent.value as? String, "5")

        let filesAhead = app.descendants(matching: .any)[
            "settings.downloads.filesAhead"
        ]
        XCTAssertTrue(filesAhead.waitForExistence(timeout: 3))
        XCTAssertEqual(filesAhead.value as? String, "5")
        app.buttons["settings.downloads.filesAhead-Increment"].tap()
        XCTAssertEqual(filesAhead.value as? String, "10")
        app.buttons["settings.downloads.filesAhead-Decrement"].tap()
        XCTAssertEqual(filesAhead.value as? String, "5")

        settingsForm.coordinate(
            withNormalizedOffset: CGVector(dx: 0.1, dy: 0.7)
        ).press(
            forDuration: 0.05,
            thenDragTo: settingsForm.coordinate(
                withNormalizedOffset: CGVector(dx: 0.1, dy: 0.55)
            )
        )

        let automaticCleanup = app.descendants(matching: .any)[
            "settings.downloads.automaticCleanup"
        ]
        XCTAssertTrue(automaticCleanup.waitForExistence(timeout: 3))
        XCTAssertTrue(
            automaticCleanup.label.contains("24 Hours After Finishing")
                || (automaticCleanup.value as? String)?.contains(
                    "24 Hours After Finishing"
                ) == true
        )
        automaticCleanup.tap()
        let afterChapter = app.buttons["After Finishing Each Chapter"]
        XCTAssertTrue(afterChapter.waitForExistence(timeout: 3))
        afterChapter.tap()
        XCTAssertTrue(
            automaticCleanup.label.contains("After Finishing Each Chapter")
                || (automaticCleanup.value as? String)?.contains(
                    "After Finishing Each Chapter"
                ) == true
        )
        automaticCleanup.tap()
        let afterTwentyFourHours = app.buttons["24 Hours After Finishing"]
        XCTAssertTrue(afterTwentyFourHours.waitForExistence(timeout: 3))
        afterTwentyFourHours.tap()
        XCTAssertTrue(
            automaticCleanup.label.contains("24 Hours After Finishing")
                || (automaticCleanup.value as? String)?.contains(
                    "24 Hours After Finishing"
                ) == true
        )
    }

    @MainActor
    func testDownloadSettingsUseDiscreteFilesAheadValues() throws {
        let app = launch(scenario: "--ui-testing-signed-in")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            ))
        tabButton("Settings", in: app).tap()

        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.downloads.filesAhead",
            direction: .up
        )
        let filesAhead = app.descendants(matching: .any)[
            "settings.downloads.filesAhead"
        ]
        XCTAssertTrue(filesAhead.waitForExistence(timeout: 3))
        XCTAssertTrue(filesAhead.label.contains("Files Ahead"))

        let increment =
            app.buttons["settings.downloads.filesAhead-Increment"]
        let decrement =
            app.buttons["settings.downloads.filesAhead-Decrement"]
        XCTAssertTrue(increment.exists)
        XCTAssertTrue(decrement.exists)

        for _ in 0..<4 where filesAhead.value as? String != "1" {
            decrement.tap()
        }
        XCTAssertEqual(filesAhead.value as? String, "1")

        increment.tap()
        XCTAssertEqual(filesAhead.value as? String, "3")
        increment.tap()
        XCTAssertEqual(filesAhead.value as? String, "5")
        increment.tap()
        XCTAssertEqual(filesAhead.value as? String, "10")
        increment.tap()
        XCTAssertEqual(filesAhead.value as? String, "All")
    }

    @MainActor
    func testRestoredAccountCanBeRemoved() async throws {
        let app = launch(scenario: "--ui-testing-signed-in")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            ))
        tabButton("Settings", in: app).tap()

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

        Self.scrollUntilHittable(
            app: app,
            identifier: "settings.account.ui-account",
            direction: .down
        )
        let account = app.buttons["settings.account.ui-account"]
        guard account.waitForExistence(timeout: 3) else {
            XCTFail("Restored account row did not become visible")
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
    func testAboutLinksAndDiagnosticBuildMetadata() {
        let app = launch(scenario: "--ui-testing-signed-in")
        tabButton("Settings", in: app).tap()
        Self.scrollUntilHittable(
            app: app, identifier: "settings.about", direction: .up
        )
        app.buttons["settings.about"].tap()
        XCTAssertTrue(app.staticTexts["Version"].waitForExistence(timeout: 3))
        for (identifier, label) in [
            ("settings.about.website", "Website"),
            ("settings.about.news", "News"),
        ] {
            let link = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(link.waitForExistence(timeout: 3))
            XCTAssertEqual(link.label, label)
            XCTAssertTrue(link.isEnabled)
            XCTAssertTrue(link.isHittable)
        }
        for label in ["Compiled", "Developer", "Bundle ID"] {
            XCTAssertFalse(app.staticTexts[label].exists)
        }

        app.navigationBars.buttons.firstMatch.tap()
        Self.scrollUntilHittable(
            app: app, identifier: "settings.diagnostics", direction: .up
        )
        app.buttons["settings.diagnostics"].tap()
        for label in ["Compiled", "Developer", "Bundle ID"] {
            XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 3))
        }
    }

    @MainActor
    func testDiagnosticTelemetryConsentLivesInSystemSettings() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-reset-telemetry-consent"]
        )
        tabButton("Settings", in: app).tap()
        Self.scrollUntilHittable(
            app: app, identifier: "settings.diagnostics", direction: .up
        )
        app.buttons["settings.diagnostics"].tap()
        Self.scrollUntilHittable(
            app: app, identifier: "diagnostics.telemetry.settings",
            direction: .up
        )
        XCTAssertFalse(app.switches["diagnostics.telemetry.enabled"].exists)
        let settingsLink = app.descendants(matching: .any)[
            "diagnostics.telemetry.settings"]
        XCTAssertTrue(settingsLink.isEnabled)
        XCTAssertTrue(settingsLink.isHittable)
        settingsLink.tap()

        let settings = XCUIApplication(
            bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        let toggle = settings.switches["Share diagnostic telemetry"]
        if !toggle.waitForExistence(timeout: 3) {
            Self.scrollUntilHittable(
                app: settings, identifier: "com.apple.settings.apps",
                direction: .up
            )
            settings.buttons["Apps"].tap()
            XCTAssertTrue(
                settings.buttons["Bleat"].waitForExistence(timeout: 5))
            settings.buttons["Bleat"].tap()
        }
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 10), settings.debugDescription)
        // XCTest launches Bleat in an isolated preference domain. Verify the
        // actual system control here; app tests cover foreground and launch
        // reconciliation in the app's own domain.
        if toggle.value as? String == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                .tap()
        }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .tap()
        XCTAssertEqual(toggle.value as? String, "1")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .tap()
        XCTAssertEqual(toggle.value as? String, "0")
        app.activate()
        XCTAssertTrue(app.staticTexts["diagnostics.telemetry.consent"].exists)
    }

    @MainActor
    func testSystemSettingsLinkAvailableWhenStartupUnavailable() {
        let app = launch(scenario: "--ui-testing-unavailable-startup")
        let diagnostics = app.buttons["app.diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 3))
        diagnostics.tap()
        Self.scrollUntilHittable(
            app: app, identifier: "diagnostics.telemetry.settings",
            direction: .up
        )
        XCTAssertFalse(app.switches["diagnostics.telemetry.enabled"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["diagnostics.telemetry.settings"]
                .isHittable)
    }

    @MainActor
    func testClearCloudKitDataKeepsLocalAccountAndTurnsOffSync() {
        let app = launch(scenario: "--ui-testing-signed-in")
        tabButton("Settings", in: app).tap()
        Self.scrollUntilHittable(
            app: app, identifier: "settings.icloud.clear", direction: .up
        )
        let clear = app.buttons["settings.icloud.clear"]
        let diagnostics = app.buttons["settings.diagnostics"]
        XCTAssertTrue(diagnostics.exists)
        XCTAssertGreaterThan(clear.frame.minY, diagnostics.frame.maxY)
        clear.tap()
        let confirm = app.alerts["Clear My CloudKit Data?"].buttons[
            "settings.icloud.clear.confirm"
        ].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(
            app.staticTexts["settings.icloud.clear.completed"]
                .waitForExistence(timeout: 5)
        )
        Self.scrollUntilHittable(
            app: app, identifier: "settings.icloud.enabled", direction: .down)
        XCTAssertEqual(
            app.switches["settings.icloud.enabled"].value as? String, "0")
        tabButton("Library", in: app).tap()
        XCTAssertTrue(
            app.staticTexts["The Test Audiobook"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLibraryCategoryModesBackAndStatus() {
        assertLibraryCategoryModes()
    }

    @MainActor
    func testLibraryCategoryModesAtLargestDynamicType() {
        assertLibraryCategoryModes(additionalArguments: [
            "-UIPreferredContentSizeCategoryName",
            UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue,
        ])
    }

    @MainActor
    private func assertLibraryCategoryModes(additionalArguments: [String] = [])
    {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: additionalArguments)
        tabButton("Library", in: app).tap()
        let modes = app.buttons["library.browseMode"]
        let status = app.buttons["library.filter"]
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        XCTAssertTrue(status.isHittable)
        XCTAssertTrue(modes.isHittable)
        XCTAssertLessThan(
            modes.frame.midX, app.buttons["library.sort"].frame.midX)
        for (label, id) in [
            ("By Author", "author-1"), ("By Series", "series-1"),
            ("By Collections", "collection-1"), ("By Narrators", "narrator-1"),
        ] {
            modes.tap()
            app.buttons[label].tap()
            let category = app.buttons["library.category.\(id)"]
            XCTAssertTrue(category.waitForExistence(timeout: 5))
            XCTAssertTrue(category.isHittable)
            XCTAssertTrue(category.label.contains("1 books"))
            category.tap()
            let back = app.buttons["library.activeFilter.clear"]
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            XCTAssertEqual(back.label, "Back")
            back.tap()
            XCTAssertTrue(category.waitForExistence(timeout: 5))
        }
        status.tap()
        app.collectionViews.buttons["All Books"].tap()
        XCTAssertTrue(
            app.buttons["library.category.narrator-1"].waitForExistence(
                timeout: 5))
        XCTAssertEqual(modes.label, "By Narrators")
        status.tap()
        app.collectionViews.buttons["Not Finished"].tap()
        XCTAssertEqual(modes.label, "By Narrators")
        app.buttons["library.category.narrator-1"].tap()
        XCTAssertTrue(
            app.buttons["library.activeFilter.clear"].waitForExistence(
                timeout: 5))
        status.tap()
        app.collectionViews.buttons["All Books"].tap()
        XCTAssertEqual(modes.label, "By Narrators")
        XCTAssertTrue(app.buttons["library.activeFilter.clear"].exists)
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
    func testBookDetailUsesPullToRefresh() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: ["--ui-testing-book-detail-refresh"]
        )
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        let open = app.buttons["home.book.ui-book"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.tap()

        let detail = app.descendants(matching: .any)["book.detail"]
        let title = app.staticTexts["book.detail.title"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, "The Test Audiobook")
        XCTAssertFalse(app.buttons["book.detail.reload"].exists)

        pullToRefresh(detail)
        XCTAssertTrue(detail.exists)
        XCTAssertTrue(
            app.staticTexts["The Refreshed Book Detail"]
                .waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testBookDetailRefreshFailureKeepsContentVisible() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-book-detail-refresh-failure"
            ]
        )
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        let open = app.buttons["home.book.ui-book"]
        XCTAssertTrue(open.waitForExistence(timeout: 3))
        open.tap()

        let detail = app.descendants(matching: .any)["book.detail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 3))
        pullToRefresh(detail)

        XCTAssertTrue(
            app.descendants(matching: .any)["book.detail.refreshError"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertEqual(
            app.staticTexts["book.detail.title"].label,
            "The Test Audiobook"
        )
        XCTAssertTrue(app.buttons["Try Again"].exists)
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
    func testHomeShelfCardsStayTopAlignedAcrossTitleHeights() {
        let app = launch(scenario: "--ui-testing-signed-in")
        let twoLineTitleCard = app.buttons["home.book.ui-book"]
        let oneLineTitleCard = app.buttons["home.book.ui-home-series"]

        XCTAssertTrue(twoLineTitleCard.waitForExistence(timeout: 3))
        XCTAssertTrue(oneLineTitleCard.waitForExistence(timeout: 3))
        XCTAssertEqual(
            twoLineTitleCard.frame.minY,
            oneLineTitleCard.frame.minY,
            accuracy: 1
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
        XCTAssertTrue(app.staticTexts["Server unavailable"].exists)
        XCTAssertTrue(
            app.staticTexts["Bleat could not reach the Audiobookshelf server."]
                .exists)
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
                UIContentSizeCategory.accessibilityExtraExtraExtraLarge
                    .rawValue,
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
            app.staticTexts["library.heading"].waitForExistence(timeout: 3)
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
        let playbackStarted = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@", "Pause The Test Audiobook"),
            object: play
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playbackStarted], timeout: 3), .completed
        )
        app.buttons["player.mini.open"].swipeDown(velocity: .fast)
        XCTAssertTrue(miniToggle.waitForNonExistence(timeout: 10))

        let restartedPlay = app.buttons["book.detail.play"]
        XCTAssertTrue(restartedPlay.waitForExistence(timeout: 3))
        restartedPlay.tap()
        miniToggle = app.buttons["player.mini.toggle"]
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 3))
        let pause = app.buttons["book.detail.play"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        let playbackRequested = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@", "Pause The Test Audiobook"),
            object: pause
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playbackRequested], timeout: 3),
            .completed
        )
        XCTAssertEqual(pause.label, "Pause The Test Audiobook")
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
        app.buttons["player.mini.open"].swipeDown(velocity: .fast)
        XCTAssertTrue(miniToggle.waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testMiniPlayerRestoresWhenStopIsSuperseded() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-delayed-playback-sync"]
        )
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3))
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        XCTAssertTrue(play.isEnabled)
        XCTAssertTrue(play.isHittable)
        play.tap()
        let started = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@", "Pause The Test Audiobook"),
            object: play)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 3), .completed)
        let miniToggle = app.buttons["player.mini.toggle"]
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 3))
        app.buttons["player.mini.open"].swipeDown(velocity: .fast)
        XCTAssertTrue(miniToggle.waitForNonExistence(timeout: 3))

        let completeSync = app.buttons["testing.playback.completeSync"]
        XCTAssertTrue(completeSync.waitForExistence(timeout: 3))
        XCTAssertTrue(completeSync.isHittable)

        // A new Start replaces the retired player while the old Stop awaits
        // synchronization. Pausing that replacement must survive old cleanup.
        let playbackStopped = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@", "Start The Test Audiobook"),
            object: play
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playbackStopped], timeout: 3), .completed
        )
        let stoppingGeneration = completeSync.value as? String
        XCTAssertNotNil(stoppingGeneration)
        play.tap()
        let replacementAdmitted = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value != %@", stoppingGeneration ?? ""),
            object: completeSync)
        XCTAssertEqual(
            XCTWaiter.wait(for: [replacementAdmitted], timeout: 3), .completed)
        XCTAssertFalse(miniToggle.exists)
        // Preparation preserves serialized progress writes. Release the old
        // sync only after the replacement has retired Stop's generation.
        completeSync.tap()
        let playbackResumed = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@", "Pause The Test Audiobook"),
            object: play
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [playbackResumed], timeout: 3), .completed
        )
        play.tap()
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 10))
        XCTAssertEqual(miniToggle.label, "Play")
        XCTAssertTrue(miniToggle.isHittable)
        miniToggle.tap()
        let restoredPlayback = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Pause"),
            object: miniToggle)
        XCTAssertEqual(
            XCTWaiter.wait(for: [restoredPlayback], timeout: 3), .completed)
        XCTAssertEqual(miniToggle.label, "Pause")
    }

    @MainActor
    func testMiniPlayerReportsSystemReduceMotionSetting() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-accessibility-audit"]
        )
        let state = app.staticTexts["accessibility.reduceMotion"]
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(
            state.label,
            ProcessInfo.processInfo.environment["BLEAT_EXPECT_REDUCE_MOTION"]
                ?? (UIAccessibility.isReduceMotionEnabled
                    ? "enabled" : "disabled")
        )
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
        app.buttons["player.mini.open"].swipeUp(velocity: .fast)
        let playerScreen = app.otherElements["player.screen"]
        XCTAssertTrue(playerScreen.waitForExistence(timeout: 3))
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        XCTAssertEqual(close.label, "Close")
        XCTAssertTrue(close.isHittable)
        XCTAssertGreaterThanOrEqual(close.frame.width, 44)
        XCTAssertGreaterThanOrEqual(close.frame.height, 44)
        close.tap()
        XCTAssertTrue(playerScreen.waitForNonExistence(timeout: 3))
        XCTAssertTrue(miniToggle.waitForExistence(timeout: 3))
    }

    @MainActor
    func testFailedPlaybackCanBeReopenedRetriedAndCancelled() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-loaded-playback-failure"]
        )
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        let fail = app.buttons["testing.playback.fail"]
        XCTAssertTrue(fail.waitForExistence(timeout: 3))
        fail.tap()
        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        miniPlayer.tap()
        let error = app.staticTexts["player.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertEqual(
            error.label,
            "Bleat could not read this audiobook's media."
        )
        app.buttons["Close"].tap()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        miniPlayer.tap()
        XCTAssertTrue(app.buttons["player.retry"].waitForExistence(timeout: 3))
        app.buttons["player.retry"].tap()
        XCTAssertTrue(error.waitForNonExistence(timeout: 10))

        app.buttons["Close"].tap()
        fail.tap()
        miniPlayer.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        app.buttons["player.cancel"].tap()
        XCTAssertTrue(miniPlayer.waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testNowPlayingCoverOpensBookDetail() {
        assertNowPlayingBookControlOpensDetail("player.book.cover")
    }

    @MainActor
    func testNowPlayingTitleOpensBookDetail() {
        assertNowPlayingBookControlOpensDetail("player.book.title")
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
        XCTAssertTrue(previousChapter.waitForExistence(timeout: 3))
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
    private func waitForPlaybackTimeUpdate(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let position = app.sliders["player.position"]
        XCTAssertTrue(
            position.exists,
            "Playback position must remain observable while the menu is open",
            file: file, line: line)
        let initial = try XCTUnwrap(
            position.value as? String, file: file, line: line)
        let updated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard position.exists, let value = position.value as? String
                else { return false }
                return !value.isEmpty && value != initial
            }, object: nil)
        await fulfillment(of: [updated], timeout: 10)
        XCTAssertNotEqual(
            position.value as? String, initial,
            "Expected an actual playback-time update while the menu remained open; initial=\(initial), observed=\(String(describing: position.value))",
            file: file, line: line)
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

        try await waitForPlaybackTimeUpdate(in: app)

        XCTAssertTrue(increasedRate.exists)
        XCTAssertTrue(increasedRate.isHittable)
        increasedRate.tap()
        XCTAssertEqual(rateMenu.label, "Playback Speed")
        XCTAssertEqual(rateMenu.value as? String, "1.25×")
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
        try await waitForPlaybackTimeUpdate(in: app)
        XCTAssertTrue(chapter.exists)
        XCTAssertTrue(chapter.isHittable)
        chapter.tap()

        let sleepTimer = app.buttons["player.sleepTimer"]
        XCTAssertTrue(sleepTimer.waitForExistence(timeout: 3))
        sleepTimer.tap()
        let fiveMinutes = app.collectionViews.buttons["5 minutes"].firstMatch
        XCTAssertTrue(fiveMinutes.waitForExistence(timeout: 3))
        try await waitForPlaybackTimeUpdate(in: app)
        XCTAssertTrue(fiveMinutes.exists)
        XCTAssertTrue(fiveMinutes.isHittable)
        fiveMinutes.tap()
        XCTAssertEqual(sleepTimer.label, "Timer Set")
        XCTAssertEqual(sleepTimer.value as? String, "5 minutes remaining")
        XCTAssertTrue(sleepTimer.staticTexts["5m"].exists)

        sleepTimer.tap()
        let cancelTimer = app.collectionViews.buttons["Cancel Timer"].firstMatch
        XCTAssertTrue(cancelTimer.waitForExistence(timeout: 3))
        cancelTimer.tap()
        XCTAssertEqual(sleepTimer.label, "Sleep Timer")
        XCTAssertTrue((sleepTimer.value as? String ?? "").isEmpty)

        let bookmarks = app.buttons["player.bookmarks"]
        XCTAssertTrue(bookmarks.waitForExistence(timeout: 3))
        bookmarks.tap()
        let addBookmark = app.collectionViews.buttons["Add Bookmark"].firstMatch
        XCTAssertTrue(addBookmark.waitForExistence(timeout: 3))
        try await waitForPlaybackTimeUpdate(in: app)
        XCTAssertTrue(addBookmark.exists)
        XCTAssertTrue(addBookmark.isHittable)
    }

    @MainActor
    func testBookmarkEditorShowsFailedSaveAndDismissesAfterSuccess() {
        let successfulApp = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: ["--ui-testing-delayed-playback-sync"]
        )
        XCTAssertTrue(
            successfulApp.otherElements["app.signedIn"]
                .waitForExistence(timeout: 3)
        )
        successfulApp.buttons["home.book.ui-book.play"].tap()
        XCTAssertTrue(
            successfulApp.buttons["player.mini.open"]
                .waitForExistence(timeout: 3)
        )
        successfulApp.buttons["player.mini.open"].tap()
        successfulApp.buttons["player.bookmarks"].tap()
        successfulApp.buttons["Add Bookmark"].tap()
        let successfulTitle = successfulApp.textFields["bookmark.title"]
        XCTAssertTrue(successfulTitle.waitForExistence(timeout: 3))
        successfulApp.buttons["bookmark.save"].tap()
        XCTAssertTrue(successfulTitle.waitForNonExistence(timeout: 5))
        successfulApp.terminate()

        let failedApp = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: [
                "--ui-testing-delayed-playback-sync",
                "--ui-testing-bookmark-save-failure",
            ]
        )
        XCTAssertTrue(
            failedApp.otherElements["app.signedIn"]
                .waitForExistence(timeout: 3)
        )
        failedApp.buttons["home.book.ui-book.play"].tap()
        XCTAssertTrue(
            failedApp.buttons["player.mini.open"].waitForExistence(
                timeout: 3
            )
        )
        failedApp.buttons["player.mini.open"].tap()
        failedApp.buttons["player.bookmarks"].tap()
        failedApp.buttons["Add Bookmark"].tap()
        let failedTitle = failedApp.textFields["bookmark.title"]
        XCTAssertTrue(failedTitle.waitForExistence(timeout: 3))
        XCTAssertFalse(failedApp.staticTexts["bookmark.error"].exists)

        failedApp.buttons["bookmark.save"].tap()

        XCTAssertTrue(
            failedApp.staticTexts["bookmark.error"].waitForExistence(
                timeout: 5
            )
        )
        XCTAssertTrue(failedTitle.exists)
        XCTAssertTrue(failedApp.buttons["bookmark.save"].isEnabled)
        failedTitle.tap()
        failedTitle.typeText(" revised")
        let editedTitle = failedTitle.value as? String
        XCTAssertTrue(editedTitle?.contains("revised") == true)

        failedApp.buttons["Cancel"].tap()
        failedApp.buttons["player.bookmarks"].tap()
        let existingBookmark = failedApp.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "A useful moment")
        ).firstMatch
        XCTAssertTrue(existingBookmark.waitForExistence(timeout: 3))
        existingBookmark.tap()
        failedApp.buttons["Rename"].tap()
        let renameTitle = failedApp.textFields["bookmark.title"]
        XCTAssertTrue(renameTitle.waitForExistence(timeout: 3))
        XCTAssertFalse(failedApp.staticTexts["bookmark.error"].exists)
        failedApp.buttons["bookmark.save"].tap()
        XCTAssertTrue(
            failedApp.staticTexts["bookmark.error"].waitForExistence(
                timeout: 5
            )
        )
        XCTAssertTrue(renameTitle.exists)
    }

    @MainActor
    func testBookmarkEditorDoesNotShowPriorLoadFailure() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: [
                "--ui-testing-delayed-playback-sync",
                "--ui-testing-bookmark-load-failure",
            ]
        )
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.buttons["home.book.ui-book.play"].tap()
        XCTAssertTrue(
            app.buttons["player.mini.open"].waitForExistence(timeout: 3)
        )
        app.buttons["player.mini.open"].tap()
        XCTAssertTrue(
            app.staticTexts["player.bookmarkError"].waitForExistence(
                timeout: 3
            )
        )
        app.buttons["player.bookmarks"].tap()
        app.buttons["Add Bookmark"].tap()
        XCTAssertTrue(
            app.textFields["bookmark.title"].waitForExistence(timeout: 3)
        )
        XCTAssertFalse(app.staticTexts["bookmark.error"].exists)
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
        XCTAssertTrue(app.buttons["book.detail.viewOnServer"].exists)
        XCTAssertTrue(app.buttons["book.detail.viewOnServer"].isEnabled)
        XCTAssertFalse(app.buttons["book.detail.edit"].exists)
        XCTAssertFalse(app.buttons["book.detail.download"].exists)
    }

    @MainActor
    func testViewOnServerOpensSystemBrowserWithoutEditPermission() {
        let app = launch(scenario: "--ui-testing-limited-permissions")
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 5))
        app.staticTexts["The Test Audiobook"].tap()
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5))
        actions.tap()
        let viewOnServer = app.buttons["book.detail.viewOnServer"]
        XCTAssertTrue(viewOnServer.waitForExistence(timeout: 3))
        XCTAssertTrue(viewOnServer.isEnabled)
        XCTAssertTrue(viewOnServer.isHittable)
        viewOnServer.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        let opened = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                safari.state == .runningForeground
                    && app.state != .runningForeground
            },
            object: nil
        )
        let handoff = XCTWaiter.wait(for: [opened], timeout: 15)
        if handoff != .completed {
            let screenshot = XCTAttachment(
                screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Browser handoff foreground state"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(handoff, .completed)
        XCTAssertNotEqual(app.state, .runningForeground)
    }

    @MainActor
    func testInterruptedTranscriptionShowsNamedRetryActionsAtTop() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
                "--ui-testing-transcription-resumable",
                "--ui-testing-transcription-failed",
            ])
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3))
        app.staticTexts["The Test Audiobook"].tap()
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        app.buttons["book.detail.transcription"].tap()
        let resumeProgress = app.staticTexts["transcription.resumeProgress"]
        XCTAssertTrue(resumeProgress.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["transcription.resumeChapter.1"].exists)
        let retryRemaining = app.buttons["transcription.retryRemaining"]
        XCTAssertTrue(retryRemaining.exists)
        XCTAssertTrue(retryRemaining.isEnabled)
        let terminalState = app.staticTexts["transcription.terminalState"]
        XCTAssertTrue(terminalState.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "transcription.attemptedChapter.0"
            ].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "transcription.failedChapter.1"
            ].exists)
        XCTAssertTrue(app.buttons["transcription.retryFailure"].exists)
        let firstChapter = app.buttons["transcription.chapter.0"]
        XCTAssertTrue(firstChapter.exists)
        XCTAssertLessThan(resumeProgress.frame.minY, firstChapter.frame.minY)
        XCTAssertLessThan(terminalState.frame.minY, firstChapter.frame.minY)
        XCTAssertFalse(app.buttons["Cancelling…"].exists)
    }

    @MainActor
    func testFailedTranscriptionDoesNotResumeDifferentPendingSelection() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
                "--ui-testing-transcription-resumable",
                "--ui-testing-transcription-failed",
                "--ui-testing-transcription-mismatched-failure",
            ])
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3))
        app.staticTexts["The Test Audiobook"].tap()
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        app.buttons["book.detail.transcription"].tap()

        let retryFailure = app.buttons["transcription.retryFailure"]
        XCTAssertTrue(retryFailure.waitForExistence(timeout: 3))
        retryFailure.tap()

        XCTAssertTrue(
            app.buttons["Replace Selection"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testCachedTranscriptionCannotBeQueuedAgain() {
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
        transcription.tap()

        let startTranscription = app.buttons["transcription.start"]
        XCTAssertTrue(startTranscription.waitForExistence(timeout: 3))
        XCTAssertFalse(startTranscription.isEnabled)
        XCTAssertEqual(startTranscription.label, "Transcribed")
        let select = app.buttons["transcription.select"]
        XCTAssertTrue(select.waitForExistence(timeout: 3))
        XCTAssertFalse(select.isEnabled)
        XCTAssertFalse(app.buttons["transcription.selectAll"].exists)
        XCTAssertFalse(app.buttons["transcription.startBatch"].exists)
    }

    @MainActor
    func testTranscriptScreenDeletesLocalTranscriptAfterConfirmation() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        app.buttons["book.detail.actions"].tap()
        app.buttons["book.detail.transcription"].tap()

        let delete = app.buttons["transcription.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let confirmation = app.sheets.buttons["Delete Transcript Data"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()

        let start = app.buttons["transcription.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 3))
        XCTAssertTrue(start.isEnabled)
        XCTAssertEqual(start.label, "Start Transcription")
        XCTAssertFalse(app.otherElements["transcription.terminalState"].exists)
        XCTAssertFalse(delete.exists)
    }

    @MainActor
    func testBookDetailDeletesTranscriptWithoutRemovingTranscriptionAction() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        actions.tap()
        let delete = app.buttons["book.detail.deleteTranscript"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let confirmation = app.sheets.buttons["Delete Transcript Data"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()

        actions.tap()
        XCTAssertTrue(app.buttons["book.detail.transcription"].exists)
        XCTAssertFalse(
            app.buttons["book.detail.deleteTranscript"].exists
        )
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
        XCTAssertFalse(app.progressIndicators.firstMatch.exists)
        XCTAssertTrue(
            app.staticTexts["Transcribed 2 chapters in 2m 5s."]
                .waitForExistence(timeout: 3)
        )

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
    func testPartialTranscriptExportExplainsCoverageBeforeSharing() {
        let app = launch(
            scenario: "--ui-testing-playback",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-partial-transcription-cache",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        let book = app.staticTexts["The Test Audiobook"]
        XCTAssertTrue(book.isEnabled)
        XCTAssertTrue(book.isHittable)
        book.tap()
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 3))
        XCTAssertTrue(actions.isEnabled)
        XCTAssertTrue(actions.isHittable)
        actions.tap()
        let transcription = app.buttons["book.detail.transcription"]
        XCTAssertTrue(transcription.waitForExistence(timeout: 3))
        XCTAssertTrue(transcription.isEnabled)
        XCTAssertTrue(transcription.isHittable)
        transcription.tap()

        let export = app.buttons["transcription.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 3))
        XCTAssertTrue(export.isEnabled)
        XCTAssertTrue(export.isHittable)
        export.tap()
        let subRip = app.buttons["transcription.export.subRip"]
        XCTAssertTrue(subRip.waitForExistence(timeout: 3))
        XCTAssertTrue(subRip.isEnabled)
        XCTAssertTrue(subRip.isHittable)
        subRip.tap()

        XCTAssertTrue(
            app.staticTexts[
                "Only 1 of 2 chapters have transcript data. Bleat will export the available transcript."
            ].waitForExistence(timeout: 3)
        )
        let confirmExport = app.buttons["Export SRT"]
        XCTAssertTrue(confirmExport.exists)
        XCTAssertTrue(confirmExport.isEnabled)
        XCTAssertTrue(confirmExport.isHittable)
        confirmExport.tap()

        let saveToFiles = app.cells["Save to Files"]
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 3))
        // The system share grid's cell can extend below its visible action.
        let saveToFilesLabel = saveToFiles.staticTexts["Save to Files"]
        XCTAssertTrue(saveToFilesLabel.waitForExistence(timeout: 3))
        XCTAssertTrue(saveToFilesLabel.isEnabled)
        XCTAssertTrue(saveToFilesLabel.isHittable)
        saveToFilesLabel.tap()
        let files = XCUIApplication(
            bundleIdentifier: "com.apple.DocumentManagerUICore.SaveToFiles"
        )
        let navigation = files.navigationBars.firstMatch
        let filename = files.textFields["DOCPicker.filenameTextField"]
        // The retained failure shows native picker readiness arriving just
        // after three seconds. Use the existing system-handoff failure budget,
        // and require the intended exported document as well as navigation.
        let started = ContinuousClock.now
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                navigation.exists && filename.exists && filename.isHittable
                    && (filename.value as? String) == "The Test Audiobook"
            }, object: nil)
        let outcome = XCTWaiter.wait(for: [ready], timeout: 15)
        if outcome != .completed {
            let screenshot = XCTAttachment(screenshot: files.screenshot())
            screenshot.name = "Partial transcript native file picker handoff"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
        XCTAssertEqual(
            outcome, .completed,
            "Expected native picker for the exported transcript within 15 seconds; elapsed=\(started.duration(to: ContinuousClock.now)); \(files.debugDescription)"
        )
    }

    @MainActor
    func testTranscriptGoToCurrentPositionHighlightsSavedSegment() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
                "--ui-testing-transcription-position",
                "--ui-testing-accessibility-audit",
                "--ui-testing-long-transcript",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        app.buttons["book.detail.actions"].tap()
        app.buttons["book.detail.transcription"].tap()

        let action = app.buttons["transcription.goToCurrentPosition"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        XCTAssertTrue(action.isHittable)
        let motion = app.staticTexts["transcription.reduceMotion"]
        XCTAssertTrue(motion.waitForExistence(timeout: 3))
        XCTAssertTrue(["enabled", "disabled"].contains(motion.label))
        let setting = XCTAttachment(string: "Reduce Motion: \(motion.label)")
        setting.name = "Transcript navigation system setting"
        setting.lifetime = .keepAlways
        add(setting)
        let highlight = app.buttons["transcription.currentPositionHighlight"]
        let completed = app.staticTexts["transcription.completedHighlightCount"]
        XCTAssertTrue(completed.waitForExistence(timeout: 3))
        XCTAssertEqual(Int(completed.label), 0)
        action.tap()

        // App idling can outlast the pulse. The audit counter records completed
        // highlight lifecycles without changing the real two-second lifetime.
        let firstHighlight = expectation(
            for: NSPredicate(format: "label == %@", "1"),
            evaluatedWith: completed)
        wait(for: [firstHighlight], timeout: 3)
        XCTAssertTrue(highlight.waitForNonExistence(timeout: 3))
        let target = app.buttons["transcription.segment.1.30"]
        XCTAssertTrue(target.isHittable)
        XCTAssertTrue(target.label.contains("Another DOOMSDAY mention"))

        // Navigating to the same segment again must restore and clear its highlight.
        for _ in 0..<12 where !action.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(action.isHittable)
        action.tap()
        let secondHighlight = expectation(
            for: NSPredicate(format: "label == %@", "2"),
            evaluatedWith: completed)
        wait(for: [secondHighlight], timeout: 3)
        XCTAssertTrue(highlight.waitForNonExistence(timeout: 3))
        XCTAssertTrue(target.isHittable)
        XCTAssertTrue(target.label.contains("Another DOOMSDAY mention"))

        app.terminate()
        let relaunched = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
            ]
        )
        XCTAssertTrue(
            relaunched.otherElements["app.signedIn"].waitForExistence(
                timeout: 3
            )
        )
        relaunched.staticTexts["The Test Audiobook"].tap()
        relaunched.buttons["book.detail.actions"].tap()
        relaunched.buttons["book.detail.transcription"].tap()
        let relaunchedAction = relaunched.buttons[
            "transcription.goToCurrentPosition"
        ]
        XCTAssertTrue(relaunchedAction.waitForExistence(timeout: 3))
        relaunchedAction.tap()
        let message = relaunched.staticTexts[
            "transcription.currentPositionMessage"
        ]
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertEqual(
            message.label,
            "No playback position is available for this audiobook."
        )
    }

    @MainActor
    func
        testTranscriptGoToCurrentPositionUsesServerProgressWithoutLocalPlayback()
    {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
                "--ui-testing-transcription-server-progress",
            ]
        )
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3))
        app.staticTexts["The Test Audiobook"].tap()
        let percentage = app.staticTexts["book.detail.progress.percentage"]
        XCTAssertTrue(percentage.waitForExistence(timeout: 3))
        XCTAssertEqual(percentage.label, "96%")
        app.buttons["book.detail.actions"].tap()
        app.buttons["book.detail.transcription"].tap()
        let action = app.buttons["transcription.goToCurrentPosition"]
        XCTAssertTrue(action.waitForExistence(timeout: 3))
        action.tap()
        let highlight = app.buttons["transcription.currentPositionHighlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 3))
        XCTAssertTrue(highlight.label.contains("Another DOOMSDAY mention"))
        XCTAssertFalse(
            app.staticTexts["transcription.currentPositionMessage"].exists)
    }

    @MainActor
    func testTranscriptCurrentPositionWaitsForCacheLoad() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
                "--ui-testing-gated-transcription-cache",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        app.buttons["book.detail.actions"].tap()
        app.buttons["book.detail.transcription"].tap()

        XCTAssertTrue(
            app.otherElements["transcription.view"].waitForExistence(
                timeout: 3
            )
        )
        let release = app.buttons["testing.transcriptionCache.release"]
        XCTAssertTrue(release.waitForExistence(timeout: 30))
        defer {
            if release.exists { release.tap() }
        }
        let action = app.buttons["transcription.goToCurrentPosition"]
        XCTAssertFalse(action.exists)
        release.tap()
        XCTAssertTrue(action.waitForExistence(timeout: 30))
        XCTAssertTrue(
            app.buttons["transcription.segment.0.0"].waitForExistence(
                timeout: 30)
        )
    }

    @MainActor
    func testTranscriptGoToCurrentPositionExplainsUntranscribedChapter() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
                "--ui-testing-transcription-server-progress",
                "--ui-testing-transcription-current-chapter-untranscribed",
            ]
        )

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        app.buttons["book.detail.actions"].tap()
        app.buttons["book.detail.transcription"].tap()
        app.buttons["transcription.goToCurrentPosition"].tap()

        let confirmation = app.alerts.buttons["Start Transcription"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.alerts.staticTexts[
                "Chapter ‘Chapter Two’ has not been transcribed."
            ].exists
        )
        app.alerts.buttons["Cancel"].tap()
        let chapter = app.buttons["transcription.chapter.1"]
        XCTAssertTrue(chapter.isSelected)
        XCTAssertTrue(chapter.isHittable)
        XCTAssertTrue(app.buttons["transcription.start"].isEnabled)
        let message = app.staticTexts["transcription.currentPositionMessage"]
        XCTAssertTrue(message.waitForExistence(timeout: 3))
        XCTAssertEqual(
            message.label,
            "Chapter ‘Chapter Two’ has not been transcribed."
        )
        app.buttons["transcription.select"].tap()
        app.buttons["transcription.goToCurrentPosition"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertFalse(app.buttons["transcription.startBatch"].exists)
        XCTAssertTrue(chapter.isSelected)
        app.buttons["transcription.goToCurrentPosition"].tap()
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()
        let terminalState = app.staticTexts["transcription.terminalState"]
        XCTAssertTrue(terminalState.waitForExistence(timeout: 5))
        XCTAssertEqual(
            terminalState.label,
            "Download the selected source audio before resuming."
        )
        XCTAssertTrue(app.buttons["Download Audiobook"].exists)
        XCTAssertFalse(
            app.buttons["transcription.currentPositionHighlight"].exists
        )
    }

    @MainActor
    func testTranscriptGoToCurrentPositionRevealsNoSpeechChapterFromSearch() {
        let app = launch(
            scenario: "--ui-testing-signed-in",
            additionalArguments: [
                "--ui-testing-transcription-available",
                "--ui-testing-transcription-cache",
                "--ui-testing-transcription-server-progress",
                "--ui-testing-transcription-current-chapter-no-speech",
            ]
        )
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3))
        app.staticTexts["The Test Audiobook"].tap()
        app.buttons["book.detail.actions"].tap()
        app.buttons["book.detail.transcription"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("Doomsday")
        app.buttons["transcription.goToCurrentPosition"].tap()
        let chapter = app.buttons["transcription.chapter.1"]
        XCTAssertTrue(chapter.waitForExistence(timeout: 3))
        XCTAssertTrue(chapter.isSelected)
        XCTAssertTrue(chapter.isHittable)
        XCTAssertEqual(
            app.staticTexts["transcription.currentPositionMessage"].label,
            "No speech was detected in Chapter Two."
        )
        XCTAssertFalse(app.alerts.buttons["Start Transcription"].exists)
        XCTAssertFalse(app.buttons["transcription.start"].isEnabled)
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
        let auditsLargestText = additionalArguments.contains(
            UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue)
        if auditsLargestText {
            app.launchArguments.append("--ui-testing-dynamic-type-audit")
        }
        app.launch()
        if auditsLargestText {
            let textSize = app.staticTexts["accessibility.dynamicTypeSize"]
            XCTAssertTrue(textSize.waitForExistence(timeout: 10))
            XCTAssertEqual(textSize.label, "accessibility5")
        }
        return app
    }

    @MainActor
    private func assertNowPlayingBookControlOpensDetail(
        _ identifier: String
    ) {
        let app = launch(scenario: "--ui-testing-playback")

        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 3)
        )
        app.staticTexts["The Test Audiobook"].tap()
        let play = app.buttons["book.detail.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 3))
        play.tap()

        tabButton("Downloads", in: app).tap()
        XCTAssertTrue(
            app.navigationBars["Downloads"].waitForExistence(timeout: 3)
        )
        let miniPlayer = app.buttons["player.mini.open"]
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 3))
        miniPlayer.tap()

        let openBook = app.buttons[identifier]
        XCTAssertTrue(openBook.waitForExistence(timeout: 3))
        XCTAssertTrue(openBook.isHittable)
        openBook.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["book.detail"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(tabButton("Library", in: app).isSelected)
        XCTAssertFalse(app.otherElements["player.screen"].exists)
    }

    private func crop(
        _ image: UIImage,
        to elementFrame: CGRect,
        in applicationFrame: CGRect
    ) throws -> UIImage {
        guard let source = image.cgImage else {
            throw XCTSkip("Could not read the application screenshot")
        }
        let scaleX = CGFloat(source.width) / applicationFrame.width
        let scaleY = CGFloat(source.height) / applicationFrame.height
        let cropRect = CGRect(
            x: (elementFrame.minX - applicationFrame.minX) * scaleX,
            y: (elementFrame.minY - applicationFrame.minY) * scaleY,
            width: elementFrame.width * scaleX,
            height: elementFrame.height * scaleY
        ).integral
        guard let cropped = source.cropping(to: cropRect) else {
            throw XCTSkip("Could not crop the mini-player from the screenshot")
        }
        return UIImage(cgImage: cropped)
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
        maxAttempts: Int = 20,
        file: StaticString = #filePath,
        line: UInt = #line
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
        XCTFail(
            "Could not scroll to hittable element \(identifier) after \(maxAttempts) attempts",
            file: file,
            line: line
        )
    }

    @MainActor
    private func scrollUntilClear(
        _ element: XCUIElement,
        of obstacles: [XCUIElement],
        in container: XCUIElement,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
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
        XCTFail(
            "Could not scroll search result clear of search chrome",
            file: file,
            line: line
        )
    }
}

final class BleatLiveUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private enum LiveCoverFailure: Error {
        case transport
        case unexpectedStatus(Int)
        case malformedResponse
        case invalidImage
    }

    @MainActor
    func testLiveExternalCoverReplacementSurvivesProcessRelaunch() async throws
    {
        let environment = try await liveEnvironment()
        let configuration = ProcessInfo.processInfo.environment
        guard let rawControl = configuration["BLEAT_LIVE_CONTROL_URL"],
            let control = URL(string: rawControl),
            control.scheme == "http",
            ["127.0.0.1", "localhost", "::1"].contains(control.host ?? ""),
            let itemID = configuration["BLEAT_LIVE_COVER_ITEM_ID"],
            !itemID.isEmpty,
            itemID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else {
            throw XCTSkip(
                "Requires the disposable loopback cover-replacement harness")
        }

        var login = URLRequest(url: control.appendingPathComponent("login"))
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": environment.username, "password": environment.password,
        ])
        let loginData = try await liveCoverResponse(login)
        guard
            let payload = try JSONSerialization.jsonObject(with: loginData)
                as? [String: Any], let user = payload["user"] as? [String: Any],
            let token = user["accessToken"] as? String, !token.isEmpty
        else { throw LiveCoverFailure.malformedResponse }

        let itemURL = control.appendingPathComponent("api/items/\(itemID)")
        let redTimestamp = try await replaceLiveCover(
            at: itemURL, token: token, color: .red)
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchArguments = [
            "-bleat.downloads.automaticLookahead.v1", "0",
            "--release-screenshot-disable-nearby-server-discovery",
        ]
        app.launch()
        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(timeout: 10))
        let server = app.textFields["login.server"]
        server.tap(withNumberOfTaps: 3, numberOfTouches: 1)
        server.typeText(environment.server)
        let username = app.textFields["login.username"]
        username.tap()
        username.typeText(environment.username)
        let password = app.secureTextFields["login.password"]
        password.tap()
        password.typeText(environment.password)
        app.buttons["login.submit"].tap()
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 30))
        dismissSavePasswordPromptIfNeeded(app: app)

        let card = app.buttons["home.book.\(itemID)"].firstMatch
        try await assertLiveCover(
            card, blue: false, name: "External red cover before termination")
        // Termination discards the app process and its in-memory loader while
        // deliberately retaining the same installation and persistent cache.
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        let blueTimestamp = try await replaceLiveCover(
            at: itemURL, token: token, color: .blue)
        XCTAssertGreaterThan(blueTimestamp, redTimestamp)
        app.launch()
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.textFields["login.server"].exists)
        try await assertLiveCover(
            card, blue: true, name: "External blue cover after process relaunch"
        )
    }

    @MainActor
    private func liveCoverResponse(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch { throw LiveCoverFailure.transport }
        guard let http = response as? HTTPURLResponse else {
            throw LiveCoverFailure.malformedResponse
        }
        guard http.statusCode == 200 else {
            throw LiveCoverFailure.unexpectedStatus(http.statusCode)
        }
        return data
    }

    @MainActor
    private func replaceLiveCover(
        at itemURL: URL, token: String, color: UIColor
    ) async throws -> Int64 {
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 96, height: 96))
        let jpeg = renderer.jpegData(withCompressionQuality: 1) { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
        }
        let boundary = "Bleat-live-cover-\(UUID().uuidString)"
        var upload = URLRequest(url: itemURL.appendingPathComponent("cover"))
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        upload.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type")
        var body = Data(
            ("--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"cover\"; filename=\"cover.jpg\"\r\n"
                + "Content-Type: image/jpeg\r\n\r\n").utf8)
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        upload.httpBody = body
        let uploaded = try await liveCoverResponse(upload)
        guard
            let result = try JSONSerialization.jsonObject(with: uploaded)
                as? [String: Any], result["success"] as? Bool == true,
            let cover = result["cover"] as? String, !cover.isEmpty
        else { throw LiveCoverFailure.malformedResponse }

        var detail = URLRequest(url: itemURL)
        detail.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let metadata = try await liveCoverResponse(detail)
        guard
            let item = try JSONSerialization.jsonObject(with: metadata)
                as? [String: Any],
            let timestamp = item["updatedAt"] as? NSNumber
        else { throw LiveCoverFailure.malformedResponse }
        var components = try XCTUnwrap(
            URLComponents(
                url: itemURL.appendingPathComponent("cover"),
                resolvingAgainstBaseURL: false))
        components.queryItems = [
            URLQueryItem(name: "width", value: "360"),
            URLQueryItem(name: "height", value: "360"),
            URLQueryItem(name: "format", value: "jpeg"),
            URLQueryItem(name: "ts", value: timestamp.stringValue),
        ]
        var fetch = URLRequest(url: try XCTUnwrap(components.url))
        fetch.cachePolicy = .reloadIgnoringLocalCacheData
        fetch.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let bytes = try await liveCoverResponse(fetch)
        let image = try XCTUnwrap(UIImage(data: bytes))
        let fractions = try liveCoverFractions(image)
        if color == .blue {
            XCTAssertGreaterThan(fractions.blue, 0.95)
            XCTAssertLessThan(fractions.red, 0.01)
        } else {
            XCTAssertGreaterThan(fractions.red, 0.95)
            XCTAssertLessThan(fractions.blue, 0.01)
        }
        return timestamp.int64Value
    }

    @MainActor
    private func assertLiveCover(
        _ card: XCUIElement, blue: Bool, name: String
    ) async throws {
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(card.isHittable)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                guard card.exists, card.frame.width >= 140,
                    card.frame.height >= card.frame.width,
                    let fractions = try? self.liveCoverFractions(
                        card.screenshot().image, cropCard: true)
                else { return false }
                return blue
                    ? fractions.blue > 0.95 && fractions.red < 0.01
                    : fractions.red > 0.95 && fractions.blue < 0.01
            }, object: nil)
        let result = await XCTWaiter.fulfillment(of: [ready], timeout: 30)
        let screenshot = card.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(result, .completed, name)
        let fractions = try liveCoverFractions(screenshot.image, cropCard: true)
        XCTAssertGreaterThan(blue ? fractions.blue : fractions.red, 0.95, name)
        XCTAssertLessThan(blue ? fractions.red : fractions.blue, 0.01, name)
    }

    private func liveCoverFractions(
        _ image: UIImage, cropCard: Bool = false
    ) throws -> (red: Double, blue: Double) {
        var source = try XCTUnwrap(image.cgImage)
        if cropCard {
            // ShelfBookCard starts with a square cover. Its central upper
            // half excludes rounded corners, text, and the lower-right play
            // control; the screenshot includes the rendered sibling cover.
            guard source.width >= 140, source.height >= source.width else {
                throw LiveCoverFailure.invalidImage
            }
            let side = CGFloat(source.width)
            source = try XCTUnwrap(
                source.cropping(
                    to: CGRect(
                        x: side * 0.2, y: side * 0.15,
                        width: side * 0.6, height: side * 0.5)))
        }
        guard source.width > 0, source.height > 0 else {
            throw LiveCoverFailure.invalidImage
        }
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &pixels, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
        let offsets = stride(from: 0, to: pixels.count, by: 4)
        let red = offsets.count {
            pixels[$0] > 180 && pixels[$0 + 1] < 70 && pixels[$0 + 2] < 70
        }
        let blue = offsets.count {
            pixels[$0] < 70 && pixels[$0 + 1] < 70 && pixels[$0 + 2] > 180
        }
        return (
            Double(red) / Double(size * size),
            Double(blue) / Double(size * size)
        )
    }

    #if BLEAT_STATISTICS_VALIDATION
        @MainActor
        func testStatisticsValidationRun() async throws {
            let environment = try await liveEnvironment()
            let mode = try XCTUnwrap(
                ProcessInfo.processInfo.environment[
                    "BLEAT_STATISTICS_VALIDATION_MODE"
                ]
            )
            executionTimeAllowance = mode == "duration" ? 4_200 : 900

            var app = XCUIApplication()
            app.launchArguments = [
                "-bleat.downloads.automaticLookahead.v1", "0",
                "--release-screenshot-disable-nearby-server-discovery",
            ]
            app.launch()

            if app.textFields["login.server"].waitForExistence(timeout: 5) {
                let server = app.textFields["login.server"]
                server.tap(withNumberOfTaps: 3, numberOfTouches: 1)
                server.typeText(environment.server)
                let username = app.textFields["login.username"]
                username.tap()
                username.typeText(environment.username)
                let password = app.secureTextFields["login.password"]
                password.tap()
                password.typeText(environment.password)
                app.buttons["login.submit"].tap()
            }
            XCTAssertTrue(
                app.otherElements["app.signedIn"].waitForExistence(timeout: 30)
            )
            dismissSavePasswordPromptIfNeeded(app: app)

            if mode == "prepare" {
                try await prepareStatisticsValidationMedia(in: app)
                return
            }

            try await startStatisticsValidationPlayback(in: app)
            let configuredSeconds = try XCTUnwrap(
                ProcessInfo.processInfo.environment[
                    "BLEAT_STATISTICS_VALIDATION_SECONDS"
                ].flatMap(Double.init)
            )
            let backgroundSeconds =
                ProcessInfo.processInfo.environment[
                    "BLEAT_STATISTICS_BACKGROUND_SECONDS"
                ].flatMap(Double.init) ?? 0
            let foregroundLead = min(600, configuredSeconds / 3)
            let foregroundTail =
                configuredSeconds - foregroundLead
                - backgroundSeconds
            XCTAssertGreaterThanOrEqual(foregroundTail, 0)

            let start = ProcessInfo.processInfo.systemUptime
            app.buttons["player.toggle"].tap()
            try await Task.sleep(for: .seconds(foregroundLead))
            if backgroundSeconds > 0 {
                XCUIDevice.shared.press(.home)
                try await Task.sleep(for: .seconds(backgroundSeconds))
                app.activate()
                XCTAssertTrue(
                    app.otherElements["player.screen"].waitForExistence(
                        timeout: 30)
                )
            }
            try await Task.sleep(for: .seconds(foregroundTail))
            app.buttons["player.toggle"].tap()
            let end = ProcessInfo.processInfo.systemUptime
            let elapsed = end - start
            XCTAssertEqual(elapsed, configuredSeconds, accuracy: 5)

            let evidence = """
                mode=\(mode)
                monotonic_start=\(start)
                monotonic_end=\(end)
                elapsed_seconds=\(elapsed)
                background_seconds=\(backgroundSeconds)
                rate=\(app.buttons["player.rate"].value ?? "missing")
                """
            let attachment = XCTAttachment(string: evidence)
            attachment.name = "statistics-validation-timing"
            attachment.lifetime = .keepAlways
            add(attachment)

            app.terminate()
            app = XCUIApplication()
            app.launchArguments = [
                "--release-screenshot-disable-nearby-server-discovery"
            ]
            app.launch()
            XCTAssertTrue(
                app.otherElements["app.signedIn"].waitForExistence(timeout: 30)
            )
            tabButton("Settings", in: app).tap()
            let statistics = app.buttons["settings.statistics"]
            scrollUntilHittable(statistics, in: app, direction: .up)
            statistics.tap()
            XCTAssertTrue(
                app.navigationBars["Listening Statistics"].waitForExistence(
                    timeout: 30)
            )
            app.swipeDown()
            try await Task.sleep(for: .seconds(5))
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "statistics-after-relaunch-and-refresh"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }

        @MainActor
        private func prepareStatisticsValidationMedia(
            in app: XCUIApplication
        ) async throws {
            let remotePlay = app.buttons.matching(
                NSPredicate(
                    format:
                        "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                    "home.book.", ".play", "Play four-hour-silence"
                )
            ).firstMatch
            XCTAssertTrue(remotePlay.waitForExistence(timeout: 60))
            app.buttons.matching(
                NSPredicate(
                    format: "identifier == %@ AND label == %@",
                    String(remotePlay.identifier.dropLast(".play".count)),
                    "Open four-hour-silence"
                )
            ).firstMatch.tap()
            XCTAssertTrue(
                app.staticTexts["book.detail.title"].waitForExistence(
                    timeout: 30)
            )
            XCTAssertEqual(
                app.staticTexts["book.detail.title"].label,
                "four-hour-silence"
            )
            let download = app.buttons["book.detail.download"]
            XCTAssertTrue(download.waitForExistence(timeout: 30))
            download.tap()
            XCTAssertTrue(download.waitForNonExistence(timeout: 300))
            app.navigationBars.buttons.firstMatch.tap()

            let downloadedPlay = statisticsValidationDownloadedPlay(in: app)
            XCTAssertTrue(downloadedPlay.waitForExistence(timeout: 300))
            downloadedPlay.tap()
            let miniPlayer = app.buttons["player.mini.open"]
            XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30))
            miniPlayer.tap()
            XCTAssertTrue(
                app.otherElements["player.screen"].waitForExistence(timeout: 30)
            )
            app.buttons["player.toggle"].tap()
            app.buttons["player.rate"].tap()
            app.buttons["2×"].tap()
            XCTAssertEqual(app.buttons["player.rate"].value as? String, "2×")
            try await Task.sleep(for: .seconds(6))
        }

        @MainActor
        private func startStatisticsValidationPlayback(
            in app: XCUIApplication
        ) async throws {
            tabButton("Home", in: app).tap()
            let downloadedPlay = statisticsValidationDownloadedPlay(in: app)
            XCTAssertTrue(downloadedPlay.waitForExistence(timeout: 60))
            downloadedPlay.tap()
            let miniPlayer = app.buttons["player.mini.open"]
            XCTAssertTrue(miniPlayer.waitForExistence(timeout: 30))
            miniPlayer.tap()
            XCTAssertTrue(
                app.otherElements["player.screen"].waitForExistence(timeout: 30)
            )
            app.buttons["player.toggle"].tap()
            if app.buttons["player.rate"].value as? String != "2×" {
                app.buttons["player.rate"].tap()
                app.buttons["2×"].tap()
            }
            XCTAssertEqual(app.buttons["player.rate"].value as? String, "2×")
            try await Task.sleep(for: .seconds(6))
        }

        @MainActor
        private func statisticsValidationDownloadedPlay(
            in app: XCUIApplication
        ) -> XCUIElement {
            app.buttons.matching(
                NSPredicate(
                    format:
                        "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND label == %@",
                    "home.downloaded.", ".play", "Play four-hour-silence"
                )
            ).firstMatch
        }
    #endif

    @MainActor
    func testLiveOnlineLoginPlaybackAndDownload() async throws {
        #if os(macOS)
            // Native macOS intentionally does not construct the remote
            // telemetry runtime. This broad iOS journey enables telemetry for
            // the Release secret-leakage scan; signed macOS authentication,
            // Keychain persistence, and relaunch have separate app-hosted and
            // manual validation, so running this journey there would claim
            // coverage for a deliberately unsupported surface.
            throw XCTSkip(
                "Remote telemetry and this Release leakage journey are iOS-only"
            )
        #endif
        let environment = try await liveEnvironment()
        var app = XCUIApplication()
        app.launchArguments = [
            "-bleat.downloads.automaticLookahead.v1", "1",
            "-bleat.playback.skipForward.v1", "5",
        ]
        app.launch()

        XCTAssertTrue(
            app.textFields["login.server"].waitForExistence(timeout: 10)
        )
        let serverField = app.textFields["login.server"]
        serverField.tap()
        if let value = serverField.value as? String,
            !value.isEmpty,
            value != serverField.label
        {
            serverField.press(forDuration: 1)
            let selectAll = app.menuItems["Select All"]
            XCTAssertTrue(selectAll.waitForExistence(timeout: 2))
            selectAll.tap()
        }
        serverField.typeText(environment.server)
        XCTAssertEqual(serverField.value as? String, environment.server)
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
        ].firstMatch
        XCTAssertTrue(remoteOpen.waitForExistence(timeout: 20))
        let liveBookID = String(
            remoteOpen.identifier.dropFirst("home.book.".count)
        )
        XCTAssertFalse(liveBookID.isEmpty)
        XCTAssertTrue(remotePlay.isHittable)
        XCTAssertTrue(remoteOpen.isHittable)
        XCTAssertEqual(remotePlay.frame.width, 44, accuracy: 0.5)
        XCTAssertEqual(remotePlay.frame.height, 44, accuracy: 0.5)

        remoteOpen.tap()
        XCTAssertTrue(
            app.staticTexts["book.detail.title"].waitForExistence(timeout: 20)
        )
        XCTAssertFalse(app.buttons["player.mini.open"].exists)
        if !releaseSecretScanIsEnabled {
            try await verifyLiveFinishedProgressConflict(
                app: app, environment: environment, itemID: liveBookID)
        }
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
        app.buttons["book.detail.play"].tap()

        // Completed automatic downloads leave the transient transfer UI and
        // appear in Home's fully downloaded collection.
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
        XCTAssertTrue(downloadedPlay.waitForExistence(timeout: 60))
        tabButton("Library", in: app).tap()
        XCTAssertTrue(
            app.buttons["book.detail.play"].waitForExistence(timeout: 20)
        )
        XCTAssertFalse(app.buttons["book.detail.download.start"].exists)
        app.buttons["book.detail.play"].tap()

        miniPlayer.tap()
        XCTAssertTrue(
            app.otherElements["player.screen"].waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.buttons["player.skipBackward"].waitForExistence(timeout: 10)
        )
        // Resume may be near the end of this short fixture. Reset before
        // exercising transport controls so natural completion cannot remove them.
        app.buttons["player.chapters"].tap()
        let firstChapter = app.buttons["player.chapter.0"]
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 10))
        firstChapter.tap()
        try await Task.sleep(for: .seconds(12))
        app.buttons["player.skipForward"].tap()
        app.buttons["player.toggle"].tap()
        app.buttons["player.toggle"].tap()
        // Keep menu navigation independent of XCTest's accessibility wait time.
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

        stopMiniPlayer(in: app)
        tabButton("Home", in: app).tap()
        XCTAssertTrue(remoteOpen.waitForExistence(timeout: 20))
        remoteOpen.press(forDuration: 1)
        let removeCached = app.buttons[
            "book.context.\(liveBookID).removeDownload"
        ]
        XCTAssertTrue(removeCached.waitForExistence(timeout: 10))
        XCTAssertFalse(
            app.buttons["book.context.\(liveBookID).download"].exists
        )
        removeCached.tap()
        XCTAssertTrue(removeCached.waitForNonExistence(timeout: 10))

        XCTAssertTrue(remoteOpen.waitForExistence(timeout: 20))
        remoteOpen.press(forDuration: 1)
        let download = app.buttons[
            "book.context.\(liveBookID).download"
        ]
        XCTAssertTrue(download.waitForExistence(timeout: 10))
        download.tap()

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

    private struct LiveFinishedProgress: Decodable, Equatable {
        let isFinished: Bool
        let currentTime: Double
        let lastUpdate: Int64
    }

    @MainActor
    private func verifyLiveFinishedProgressConflict(
        app: XCUIApplication,
        environment: (server: String, username: String, password: String),
        itemID: String
    ) async throws {
        let base = try XCTUnwrap(URL(string: environment.server))
        // This journey is run only by the disposable loopback server harness.
        XCTAssertTrue(["localhost", "127.0.0.1"].contains(base.host ?? ""))
        var login = URLRequest(url: base.appendingPathComponent("login"))
        login.httpMethod = "POST"
        login.setValue("true", forHTTPHeaderField: "x-return-tokens")
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONSerialization.data(withJSONObject: [
            "username": environment.username, "password": environment.password,
        ])
        let loginData = try await liveCoverResponse(login)
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: loginData) as? [String: Any])
        let user = try XCTUnwrap(payload["user"] as? [String: Any])
        let token = try XCTUnwrap(user["accessToken"] as? String)
        let progressURL = base.appendingPathComponent("api/me/progress")
            .appendingPathComponent(itemID)
        let initial = try await liveFinishedProgress(
            url: progressURL, token: token)
        let initialLabel =
            initial?.isFinished == true ? "Mark Unfinished" : "Mark Finished"
        let finalLabel =
            initial?.isFinished == true ? "Mark Finished" : "Mark Unfinished"

        func chooseAction(expected: String, submit: Bool = true) async {
            let actions = app.buttons["book.detail.actions"]
            XCTAssertTrue(actions.waitForExistence(timeout: 20))
            XCTAssertTrue(actions.isEnabled)
            XCTAssertTrue(actions.isHittable)
            actions.tap()
            let finished = app.buttons["book.detail.finished"]
            XCTAssertTrue(finished.waitForExistence(timeout: 10))
            let ready = expectation(
                for: NSPredicate(
                    format: "label == %@ AND enabled == true", expected),
                evaluatedWith: finished)
            await fulfillment(of: [ready], timeout: 20)
            XCTAssertTrue(finished.isHittable)
            if submit { finished.tap() }
        }

        await chooseAction(expected: initialLabel)
        let keepServer = app.buttons["Keep Server Progress"]
        XCTAssertTrue(keepServer.waitForExistence(timeout: 20))
        XCTAssertTrue(keepServer.isEnabled)
        XCTAssertTrue(keepServer.isHittable)
        let unmodified = try await liveFinishedProgress(
            url: progressURL, token: token)
        XCTAssertEqual(unmodified, initial)
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists {
            XCTAssertTrue(cancel.isEnabled)
            XCTAssertTrue(cancel.isHittable)
            cancel.tap()
        } else {
            // iOS 27 presents a native popover and omits its cancel-role
            // button. Its backdrop is the native non-destructive dismissal.
            XCTAssertTrue(app.staticTexts["Review Progress"].exists)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2))
                .tap()
        }
        XCTAssertTrue(keepServer.waitForNonExistence(timeout: 10))
        let cancelled = try await liveFinishedProgress(
            url: progressURL, token: token)
        XCTAssertEqual(cancelled, initial)

        await chooseAction(expected: initialLabel)
        XCTAssertTrue(keepServer.waitForExistence(timeout: 20))
        XCTAssertTrue(keepServer.isEnabled)
        XCTAssertTrue(keepServer.isHittable)
        keepServer.tap()
        XCTAssertTrue(keepServer.waitForNonExistence(timeout: 10))
        let adopted = try await liveFinishedProgress(
            url: progressURL, token: token)
        XCTAssertEqual(adopted, initial)
        // Confirm the operation has completed before terminating its process.
        let actions = app.buttons["book.detail.actions"]
        XCTAssertTrue(actions.isEnabled)
        XCTAssertTrue(actions.isHittable)
        actions.tap()
        let finished = app.buttons["book.detail.finished"]
        let adoptionCompleted = expectation(
            for: NSPredicate(
                format: "enabled == true AND label == %@", initialLabel),
            evaluatedWith: finished)
        await fulfillment(of: [adoptionCompleted], timeout: 20)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        app.launch()
        XCTAssertTrue(
            app.otherElements["app.signedIn"].waitForExistence(timeout: 30))
        dismissSavePasswordPromptIfNeeded(app: app)
        let card = app.buttons["home.book.\(itemID)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30))
        XCTAssertTrue(card.isEnabled)
        XCTAssertTrue(card.isHittable)
        card.tap()
        XCTAssertTrue(
            app.staticTexts["book.detail.title"].waitForExistence(timeout: 20))

        // A second client changes server position after the persisted common
        // snapshot. The app must preserve it until the explicit user choice.
        var external = URLRequest(url: progressURL)
        external.httpMethod = "PATCH"
        external.setValue(
            "Bearer \(token)", forHTTPHeaderField: "Authorization")
        external.setValue(
            "application/json", forHTTPHeaderField: "Content-Type")
        external.httpBody = try JSONSerialization.data(withJSONObject: [
            "currentTime": (initial?.currentTime ?? 0) + 3,
            "progress": 0.25,
        ])
        _ = try await liveCoverResponse(external)
        let changed = try await liveFinishedProgress(
            url: progressURL, token: token)
        XCTAssertNotEqual(changed, initial)
        await chooseAction(expected: initialLabel)
        XCTAssertTrue(
            app.staticTexts["Progress Changed"].waitForExistence(timeout: 20))
        XCTAssertTrue(keepServer.exists)
        let preserved = try await liveFinishedProgress(
            url: progressURL, token: token)
        XCTAssertEqual(preserved, changed)
        let useDevice = app.buttons[
            initial?.isFinished == true
                ? "Mark Unfinished on Server" : "Mark Finished on Server"]
        XCTAssertTrue(useDevice.isEnabled)
        XCTAssertTrue(useDevice.isHittable)
        useDevice.tap()
        XCTAssertTrue(useDevice.waitForNonExistence(timeout: 10))
        // The menu changes only after the production model receives HTTP 200.
        await chooseAction(expected: finalLabel, submit: false)
        let committed = try await liveFinishedProgress(
            url: progressURL, token: token)
        XCTAssertEqual(committed?.isFinished, !(initial?.isFinished ?? false))
        // Restore through the app, accepting a fresh conflict if the confirmed
        // PATCH's separate readback has not established the next checkpoint yet.
        XCTAssertTrue(finished.isEnabled)
        XCTAssertTrue(finished.isHittable)
        finished.tap()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var restoredServer = try await liveFinishedProgress(
            url: progressURL, token: token)
        while restoredServer?.isFinished != (initial?.isFinished ?? false),
            ContinuousClock.now < deadline
        {
            let restore = app.buttons[
                initial?.isFinished == true
                    ? "Mark Finished on Server" : "Mark Unfinished on Server"]
            if restore.exists, restore.isEnabled, restore.isHittable {
                restore.tap()
            }
            // Poll a semantic server postcondition; the 250ms cadence bounds
            // request traffic while the independent app request commits.
            try await Task.sleep(for: .milliseconds(250))
            restoredServer = try await liveFinishedProgress(
                url: progressURL, token: token)
        }
        XCTAssertEqual(restoredServer?.isFinished, initial?.isFinished ?? false)
        XCTAssertTrue(actions.isEnabled)
        XCTAssertTrue(actions.isHittable)
        actions.tap()
        let restored = expectation(
            for: NSPredicate(
                format: "enabled == true AND label == %@", initialLabel),
            evaluatedWith: finished)
        await fulfillment(of: [restored], timeout: 20)
        // The native menu makes the background title non-hittable. Its
        // observed left backdrop dismisses without activating a book action.
        let title = app.staticTexts["book.detail.title"]
        XCTAssertTrue(title.isEnabled)
        XCTAssertTrue(finished.isHittable)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.2)).tap()
        XCTAssertTrue(finished.waitForNonExistence(timeout: 10))
        XCTAssertTrue(title.wait(for: \.isHittable, toEqual: true, timeout: 10))
        let afterDismiss = try await liveFinishedProgress(
            url: progressURL, token: token)
        XCTAssertEqual(afterDismiss, restoredServer)
    }

    @MainActor
    private func liveFinishedProgress(url: URL, token: String) async throws
        -> LiveFinishedProgress?
    {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        if http.statusCode == 404 { return nil }
        XCTAssertEqual(http.statusCode, 200)
        return try JSONDecoder().decode(LiveFinishedProgress.self, from: data)
    }

    @MainActor
    func testLiveOfflineCachedDownloadAndLocalProgress() throws {
        try requireLiveConfiguration()
        let app = XCUIApplication()
        app.launchArguments = ["-bleat.playback.skipForward.v1", "5"]
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
        app.buttons["player.chapters"].tap()
        let firstChapter = app.buttons["player.chapter.0"]
        XCTAssertTrue(firstChapter.waitForExistence(timeout: 10))
        firstChapter.tap()
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
        direction: LiveScrollDirection,
        file: StaticString = #filePath,
        line: UInt = #line
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
        let exists = element.exists
        let hittable = exists && element.isHittable
        XCTAssertTrue(
            hittable,
            "Expected \(element) to exist and be hittable after 20 \(direction) swipes; "
                + "observed exists=\(exists), hittable=\(hittable)",
            file: file, line: line)
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
            guard
                let rawURL = environment[
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
