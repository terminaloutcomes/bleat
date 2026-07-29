import BleatCore
import XCTest

@testable import Bleat

@MainActor
final class PlaybackPositionStoreTests: XCTestCase {
    func testPositionsPersistAndRemainAccountScoped() throws {
        let suite = "PlaybackPositionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let first = PlaybackPositionStore(defaults: defaults)
        let itemID = LibraryItemID(rawValue: "same-item")

        try first.save(
            42.5,
            accountID: AccountID(rawValue: "first"),
            itemID: itemID
        )
        try first.save(
            9,
            accountID: AccountID(rawValue: "second"),
            itemID: itemID
        )
        let relaunched = PlaybackPositionStore(defaults: defaults)

        XCTAssertEqual(
            relaunched.position(
                accountID: AccountID(rawValue: "first"),
                itemID: itemID
            ),
            42.5
        )
        XCTAssertEqual(
            relaunched.position(
                accountID: AccountID(rawValue: "second"),
                itemID: itemID
            ),
            9
        )
    }

    func testInvalidPositionIsRejectedWithoutOverwriting() throws {
        let suite = "PlaybackPositionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let store = PlaybackPositionStore(defaults: defaults)
        let accountID = AccountID(rawValue: "account")
        let itemID = LibraryItemID(rawValue: "item")
        try store.save(10, accountID: accountID, itemID: itemID)

        XCTAssertThrowsError(
            try store.save(
                .nan,
                accountID: accountID,
                itemID: itemID
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackPositionStoreError,
                .invalidPosition
            )
        }
        XCTAssertEqual(
            store.position(accountID: accountID, itemID: itemID),
            10
        )
    }
}
