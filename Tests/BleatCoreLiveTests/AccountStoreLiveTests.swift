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
        let libraries = try await AudiobookshelfAPI(
            account: account,
            authCoordinator: authCoordinator
        ).libraries()

        XCTAssertEqual(account.server, discovered.baseURL)
        XCTAssertEqual(account.user.username, username)
        XCTAssertEqual(account.connectionState, .connected)
        XCTAssertEqual(active, account)
        XCTAssertNotNil(storedCredentials)
        XCTAssertTrue(
            libraries.value.contains {
                $0.name == "Bleat Live Fixtures"
                    && $0.mediaType == .book
            }
        )
    }
}
