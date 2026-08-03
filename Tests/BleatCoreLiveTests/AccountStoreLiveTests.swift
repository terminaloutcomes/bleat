import Foundation
import SwiftData
import XCTest

@testable import BleatCore

final class AccountStoreLiveTests: XCTestCase {
    func testPinnedRootAndPrefixNativeAccountsPersist() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
              let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
              let username = environment["BLEAT_LIVE_USERNAME"],
              let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live account data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            try await verifyAccountPersistence(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "persisted-\(index)"),
                username: username,
                password: password
            )
        }
    }

    private func verifyAccountPersistence(
        server: NormalizedServerURL,
        accountID: AccountID,
        username: String,
        password: String
    ) async throws {
        let transport = LocalDockerHTTPTransport()
        let discovered = try await ServerDiscoveryClient(
            transport: transport
        ).discover(server)
        XCTAssertEqual(discovered.version.original, "2.36.0")
        XCTAssertTrue(discovered.authenticationMethods.contains(.local))

        let credentials = LiveCredentialStore()
        let authCoordinator = AuthCoordinator(
            transport: transport,
            credentialStore: credentials
        )
        let schema = Schema([ServerAccountRecord.self])
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    isStoredInMemoryOnly: true
                ),
            ]
        )
        let store = AccountStore(modelContainer: container)

        let account = try await authCoordinator.loginAndPersistAccount(
            accountID: accountID,
            discoveredServer: discovered,
            username: username,
            password: password,
            accountStore: store
        )
        let relaunched = AccountStore(modelContainer: container)
        let active = try await relaunched.activeAccount()
        let storedCredentials = await credentials.credentials(
            for: accountID
        )
        let api = AudiobookshelfAPI(
            account: account,
            authCoordinator: authCoordinator
        )
        let libraries = try await api.libraries()
        let seededLibrary = try XCTUnwrap(
            libraries.value.first {
                $0.name == "Bleat Live Fixtures"
                    && $0.mediaType == .book
            }
        )
        let firstPage = try await api.libraryItems(
            in: seededLibrary.id,
            request: try LibraryItemsPageRequest(
                page: 0,
                limit: 2,
                sort: .title
            )
        )
        let firstItem = try XCTUnwrap(firstPage.value.items.first)
        let navigationPage = try await api.libraryItems(
            in: seededLibrary.id,
            request: try LibraryItemsPageRequest(
                page: 0,
                limit: 10,
                sort: .title,
                includeProgress: false,
                collapseSeries: false
            )
        )
        var navigationDetails: [LibraryBookDetail] = []
        for item in navigationPage.value.items {
            navigationDetails.append(
                try await api.bookDetail(
                    for: item.id,
                    in: seededLibrary.id
                ).value
            )
        }
        let multiMetadataItem = try XCTUnwrap(
            navigationDetails.first {
                $0.authors.count >= 2 && $0.series.count >= 2
            }
        )
        let linkedAuthor = try XCTUnwrap(multiMetadataItem.authors.first)
        let linkedSeries = try XCTUnwrap(multiMetadataItem.series.first)
        let authorPage = try await api.libraryItems(
            in: seededLibrary.id,
            request: try LibraryItemsPageRequest(
                page: 0,
                limit: 10,
                sort: .title,
                filter: LibraryItemFilter(authorID: linkedAuthor.id),
                includeProgress: false,
                collapseSeries: false
            )
        )
        let seriesPage = try await api.libraryItems(
            in: seededLibrary.id,
            request: try LibraryItemsPageRequest(
                page: 0,
                limit: 10,
                sort: .sequence,
                filter: LibraryItemFilter(seriesID: linkedSeries.id),
                includeProgress: false,
                collapseSeries: false
            )
        )
        let collapsedPage = try await api.libraryItems(
            in: seededLibrary.id,
            request: try LibraryItemsPageRequest(
                page: 0,
                limit: 10,
                sort: .title,
                includeProgress: false,
                collapseSeries: true
            )
        )
        let detail = try await api.bookDetail(
            for: firstItem.id,
            in: seededLibrary.id
        )
        let search = try await api.search(
            in: seededLibrary.id,
            request: try LibrarySearchRequest(
                query: "direct",
                limit: 12
            )
        )
        let groupedSearch = try await api.search(
            in: seededLibrary.id,
            request: try LibrarySearchRequest(
                query: "Fixture",
                limit: 12
            )
        )
        let home = try await api.personalizedShelves(
            in: seededLibrary.id,
            request: try LibraryHomeRequest(limit: 10)
        )

        XCTAssertEqual(account.server, discovered.baseURL)
        XCTAssertEqual(account.user.username, username)
        XCTAssertEqual(account.connectionState, .connected)
        XCTAssertEqual(active, account)
        XCTAssertNotNil(storedCredentials)
        XCTAssertEqual(firstPage.value.items.count, 2)
        XCTAssertEqual(firstPage.value.total, 2)
        XCTAssertFalse(firstPage.value.hasNextPage)
        XCTAssertEqual(navigationPage.value.items.count, 3)
        var authorPageContainsLinkedAuthor = false
        for item in authorPage.value.items {
            let authorDetail = try await api.bookDetail(
                for: item.id,
                in: seededLibrary.id
            )
            if authorDetail.value.authors.contains(
                where: { $0.id == linkedAuthor.id }
            ) {
                authorPageContainsLinkedAuthor = true
                break
            }
        }
        XCTAssertTrue(authorPageContainsLinkedAuthor)
        XCTAssertEqual(
            seriesPage.value.items.compactMap {
                $0.series.first(where: { $0.id == linkedSeries.id })?.sequence
            },
            ["1", "2"]
        )
        XCTAssertTrue(
            collapsedPage.value.browseEntries.contains {
                guard case let .series(series, representative: _) = $0 else {
                    return false
                }
                return series.id == linkedSeries.id
            }
        )
        XCTAssertTrue(
            firstPage.value.items.allSatisfy {
                $0.libraryID == seededLibrary.id
                    && !$0.title.isEmpty
                    && $0.duration > 0
            }
        )
        XCTAssertEqual(detail.value.id, firstItem.id)
        XCTAssertEqual(detail.value.libraryID, seededLibrary.id)
        XCTAssertEqual(detail.value.title, firstItem.title)
        XCTAssertGreaterThan(detail.value.trackCount, 0)
        XCTAssertGreaterThan(detail.value.duration, 0)
        XCTAssertEqual(search.value.count, 1)
        XCTAssertEqual(search.value.first?.title, "direct")
        XCTAssertEqual(
            search.value.first?.libraryID,
            seededLibrary.id
        )
        XCTAssertTrue(groupedSearch.value.authors.contains {
            $0.id == linkedAuthor.id
        })
        XCTAssertTrue(groupedSearch.value.series.contains {
            $0.id == linkedSeries.id
        })
        XCTAssertFalse(home.value.isEmpty)
        XCTAssertTrue(
            home.value.allSatisfy { shelf in
                !shelf.items.isEmpty
                    && shelf.items.count <= 10
                    && shelf.items.allSatisfy {
                        $0.libraryID == seededLibrary.id
                            && $0.trackCount > 0
                    }
            }
        )
    }
}
