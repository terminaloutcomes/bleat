import BleatCore
import XCTest

@testable import Bleat

@MainActor
final class DeepLinkTests: XCTestCase {
    func testCanonicalRoutesRoundTripIncludingEncodedEntityIDs() throws {
        let authorID = try XCTUnwrap(AuthorID(rawValue: "author/one"))
        let seriesID = try XCTUnwrap(SeriesID(rawValue: "series/one"))
        let scope = DeepLinkScope(
            accountID: AccountID(rawValue: "account-1"),
            libraryID: LibraryID(rawValue: "library-1")
        )
        let routes: [DeepLinkRoute] = [
            .home,
            .library,
            .downloads,
            .nowPlaying,
            .settings(.root),
            .settings(.diagnostics),
            .settings(.statistics),
            .settings(.about),
            .search(query: "The Book", scope: .all, target: scope),
            .search(query: "The Book", scope: .book, target: scope),
            .search(query: "The Book", scope: .author, target: scope),
            .search(query: "The Book", scope: .series, target: scope),
            .book(id: LibraryItemID(rawValue: "book/one"), target: scope),
            .author(id: authorID, target: scope),
            .series(id: seriesID, target: scope),
        ]

        for route in routes {
            let url = try XCTUnwrap(DeepLinkFormatter.format(route))
            XCTAssertEqual(try DeepLinkParser.parse(url), route)
        }
    }

    func testParserRejectsMalformedOrAmbiguousLinks() {
        let invalid = [
            "https://book/item",
            "bleat://book",
            "bleat://book/%0A",
            "bleat://author/%20author",
            "bleat://series/series?library=one&library=two",
            "bleat://search?q=",
            "bleat://search?q=book&scope=book",
            "bleat://settings/unknown",
            "bleat://home/path",
            "bleat://home/",
            "bleat://settings//diagnostics",
            "bleat://book//item",
            "bleat://search//author?q=book",
            "bleat://now-playing#fragment",
        ]

        for value in invalid {
            XCTAssertThrowsError(try DeepLinkParser.parse(URL(string: value)!))
        }
    }

    func testLatestValidLinkWinsAndMalformedLinksLeaveItQueued() throws {
        let coordinator = AppNavigationCoordinator()
        let first = try XCTUnwrap(URL(string: "bleat://library"))
        let second = try XCTUnwrap(URL(string: "bleat://search?q=second"))
        let malformed = try XCTUnwrap(URL(string: "bleat://search?q="))

        coordinator.receive(url: first)
        coordinator.receive(url: malformed)
        XCTAssertEqual(coordinator.pendingRoute, .library)

        coordinator.receive(url: second)
        XCTAssertEqual(
            coordinator.pendingRoute,
            .search(
                query: "second",
                scope: .all,
                target: DeepLinkScope(accountID: nil, libraryID: nil)
            )
        )
    }

    func testStartupInboxQueuesOnlyTheLatestValidLink() throws {
        let inbox = AppDeepLinkInbox()
        let first = try XCTUnwrap(URL(string: "bleat://library"))
        let malformed = try XCTUnwrap(URL(string: "bleat://search?q="))
        let second = try XCTUnwrap(URL(string: "bleat://settings/about"))

        XCTAssertTrue(inbox.receive(url: first))
        XCTAssertFalse(inbox.receive(url: malformed))
        XCTAssertTrue(inbox.receive(url: second))
        XCTAssertEqual(inbox.revision, 2)
        XCTAssertEqual(inbox.takePendingRoute(), .settings(.about))
        XCTAssertNil(inbox.takePendingRoute())
    }

    func testSettingsShortcutQueuesSettingsRoot() {
        let inbox = AppDeepLinkInbox()

        inbox.openSettings()

        XCTAssertEqual(inbox.takePendingRoute(), .settings(.root))
    }
}
