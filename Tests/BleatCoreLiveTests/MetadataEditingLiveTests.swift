import Foundation
import XCTest

@testable import BleatCore

final class MetadataEditingLiveTests: XCTestCase {
    func testPinnedRootAndPrefixMetadataUpdates() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live metadata data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            try await verifyMetadataUpdate(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "metadata-\(index)"),
                username: username,
                password: password,
                marker: "Bleat live metadata \(index)"
            )
        }
    }

    private func verifyMetadataUpdate(
        server: NormalizedServerURL,
        accountID: AccountID,
        username: String,
        password: String,
        marker: String
    ) async throws {
        let transport = LocalDockerHTTPTransport()
        let discovered = try await ServerDiscoveryClient(
            transport: transport
        ).discover(server)
        let credentials = LiveCredentialStore()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: credentials
        )
        let authenticated = try await coordinator.login(
            accountID: accountID,
            server: discovered.baseURL,
            username: username,
            password: password
        )
        XCTAssertTrue(authenticated.user.permissions.update)
        let account = try ServerAccount(
            authenticatedAccount: authenticated,
            discoveredServer: discovered
        )
        let api = AudiobookshelfAPI(
            account: account,
            authCoordinator: coordinator
        )
        let libraries = try await api.libraries()
        let library = try XCTUnwrap(
            libraries.value.first {
                $0.name == "Bleat Live Fixtures"
            }
        )
        let page = try await api.libraryItems(
            in: library.id,
            request: try LibraryItemsPageRequest(
                page: 0,
                limit: 1,
                sort: .title
            )
        )
        let item = try XCTUnwrap(page.value.items.first)
        let originalResponse = try await api.bookDetail(
            for: item.id,
            in: library.id
        )
        let original = originalResponse.value
        var draft = BookMetadataDraft(detail: original)
        draft.publisher = marker

        try await coordinator.updateBookMetadata(
            accountID: accountID,
            server: account.server,
            itemID: item.id,
            patch: try BookMetadataPatch(
                baseline: original,
                draft: draft
            )
        )

        let updatedResponse = try await api.bookDetail(
            for: item.id,
            in: library.id
        )
        let updated = updatedResponse.value
        XCTAssertEqual(updated.publisher, marker)

        var restoreDraft = BookMetadataDraft(detail: updated)
        restoreDraft.publisher = original.publisher ?? ""
        try await coordinator.updateBookMetadata(
            accountID: accountID,
            server: account.server,
            itemID: item.id,
            patch: try BookMetadataPatch(
                baseline: updated,
                draft: restoreDraft
            )
        )
    }
}
