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

    func testReconcilerDetectsBothChangedAndAdoptsSingleChange() {
        let baseline = progress(time: 10, updatedAt: 100)
        let remote = progress(time: 30, updatedAt: 200)

        XCTAssertEqual(
            DownloadedPositionReconciler.decide(
                savedPosition: 20,
                baseline: baseline,
                remote: remote,
                duration: 100
            ),
            .conflict(local: 20, server: 30)
        )
        XCTAssertEqual(
            DownloadedPositionReconciler.decide(
                savedPosition: 10,
                baseline: baseline,
                remote: remote,
                duration: 100
            ),
            .server(30)
        )
        XCTAssertEqual(
            DownloadedPositionReconciler.decide(
                savedPosition: 20,
                baseline: baseline,
                remote: baseline,
                duration: 100
            ),
            .local(20)
        )
    }

    private func progress(
        time: Double,
        updatedAt: Int64
    ) -> LibraryBookProgress {
        LibraryBookProgress(
            id: "progress",
            userID: UserID(rawValue: "user"),
            libraryItemID: LibraryItemID(rawValue: "item"),
            bookID: BookID(rawValue: "book"),
            duration: 100,
            progress: time / 100,
            currentTime: time,
            isFinished: false,
            hideFromContinueListening: false,
            lastUpdateMilliseconds: updatedAt,
            startedAtMilliseconds: 1,
            finishedAtMilliseconds: nil
        )
    }
}
