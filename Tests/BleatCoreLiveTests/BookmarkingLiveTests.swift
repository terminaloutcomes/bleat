import Foundation
import XCTest

@testable import BleatCore

final class BookmarkingLiveTests: XCTestCase {
    func testPinnedRootAndPrefixBookmarkCRUD() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live bookmark data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            try await verifyBookmarkCRUD(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "bookmark-\(index)"),
                username: username,
                password: password
            )
        }
    }

    private func verifyBookmarkCRUD(
        server: NormalizedServerURL,
        accountID: AccountID,
        username: String,
        password: String
    ) async throws {
        let transport = LocalDockerHTTPTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: LiveCredentialStore()
        )
        let authenticated = try await coordinator.login(
            accountID: accountID,
            server: server,
            username: username,
            password: password
        )
        let account = try ServerAccount(
            authenticatedAccount: authenticated,
            discoveredServer: try await ServerDiscoveryClient(
                transport: transport
            ).discover(server)
        )
        let api = AudiobookshelfAPI(
            account: account,
            authCoordinator: coordinator
        )
        let libraries = try await api.libraries()
        let library = try XCTUnwrap(libraries.value.first)
        let page = try await api.libraryItems(
            in: library.id,
            request: try LibraryItemsPageRequest(
                page: 0,
                limit: 1,
                sort: .title
            )
        )
        let item = try XCTUnwrap(page.value.items.first)

        let initiallyEmpty = try await coordinator.bookmarks(
            accountID: accountID,
            server: server,
            itemID: item.id
        )
        XCTAssertTrue(initiallyEmpty.isEmpty)
        let created = try await coordinator.mutateBookmark(
            accountID: accountID,
            server: server,
            itemID: item.id,
            time: 12.5,
            title: "Live bookmark",
            mutation: .create
        )
        XCTAssertEqual(created.title, "Live bookmark")
        let afterCreate = try await coordinator.bookmarks(
            accountID: accountID,
            server: server,
            itemID: item.id
        )
        XCTAssertEqual(afterCreate, [created])
        let renamed = try await coordinator.mutateBookmark(
            accountID: accountID,
            server: server,
            itemID: item.id,
            time: created.time,
            title: "Renamed live bookmark",
            mutation: .rename
        )
        XCTAssertEqual(renamed.title, "Renamed live bookmark")
        try await coordinator.deleteBookmark(
            accountID: accountID,
            server: server,
            itemID: item.id,
            time: renamed.time
        )
        let afterDelete = try await coordinator.bookmarks(
            accountID: accountID,
            server: server,
            itemID: item.id
        )
        XCTAssertTrue(afterDelete.isEmpty)
    }
}
