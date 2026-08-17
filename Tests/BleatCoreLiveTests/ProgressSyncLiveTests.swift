import Foundation
import XCTest

@testable import BleatCore

final class ProgressSyncLiveTests: XCTestCase {
    func testPinnedRootAndPrefixProgressContracts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live progress data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            try await verifyProgress(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "progress-\(index)"),
                username: username,
                password: password
            )
        }
    }

    private func verifyProgress(
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
        let discovered = try await ServerDiscoveryClient(
            transport: transport
        ).discover(server)
        let api = AudiobookshelfAPI(
            account: try ServerAccount(
                authenticatedAccount: authenticated,
                discoveredServer: discovered
            ),
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
        let testDuration = max(item.duration, 120)

        try await coordinator.updateBookProgress(
            accountID: accountID,
            server: server,
            itemID: item.id,
            update: BookProgressUpdate(
                duration: testDuration,
                currentTime: 7,
                progress: 7 / testDuration,
                isFinished: false
            )
        )
        let fetchedProgress = try await coordinator.bookProgress(
            accountID: accountID,
            server: server,
            itemID: item.id
        )
        let progress = try XCTUnwrap(fetchedProgress)
        XCTAssertEqual(progress.currentTime, 7, accuracy: 0.001)
        XCTAssertFalse(progress.isFinished)

        try await coordinator.updateBookProgress(
            accountID: accountID,
            server: server,
            itemID: item.id,
            update: BookProgressUpdate(isFinished: true)
        )
        let fetchedFinished = try await coordinator.bookProgress(
            accountID: accountID,
            server: server,
            itemID: item.id
        )
        let finished = try XCTUnwrap(fetchedFinished)
        XCTAssertTrue(finished.isFinished)
        let allFinished = try await coordinator.allBookProgress(
            accountID: accountID,
            userID: authenticated.user.id,
            server: server
        )
        XCTAssertTrue(
            allFinished.contains {
                $0.libraryItemID == item.id && $0.isFinished
            }
        )

        try await coordinator.updateBookProgress(
            accountID: accountID,
            server: server,
            itemID: item.id,
            update: BookProgressUpdate(isFinished: false)
        )
        let fetchedUnfinished = try await coordinator.bookProgress(
            accountID: accountID,
            server: server,
            itemID: item.id
        )
        let unfinished = try XCTUnwrap(fetchedUnfinished)
        XCTAssertFalse(unfinished.isFinished)
        let allUnfinished = try await coordinator.allBookProgress(
            accountID: accountID,
            userID: authenticated.user.id,
            server: server
        )
        XCTAssertTrue(
            allUnfinished.contains {
                $0.libraryItemID == item.id && !$0.isFinished
            }
        )
    }
}
