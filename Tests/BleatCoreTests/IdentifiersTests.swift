import Foundation
import XCTest

@testable import BleatCore

final class IdentifiersTests: XCTestCase {
    func testRawValueAndDescriptionArePreserved() {
        let accountID = AccountID(rawValue: "account-1")

        XCTAssertEqual(accountID.rawValue, "account-1")
        XCTAssertEqual(accountID.description, "account-1")
    }

    func testRoundTripsThroughCodable() throws {
        let original = LibraryItemID(rawValue: "opaque/not-a-uuid")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            LibraryItemID.self,
            from: data
        )

        XCTAssertEqual(decoded, original)
    }

    func testDifferentKindsCanUseTheSameOpaqueValue() {
        let libraryID = LibraryID(rawValue: "same")
        let itemID = LibraryItemID(rawValue: "same")

        XCTAssertEqual(libraryID.rawValue, itemID.rawValue)
    }

    func testAuthorAndSeriesIDsRejectEmptyAndControlCharacters() throws {
        XCTAssertNil(AuthorID(rawValue: ""))
        XCTAssertNil(AuthorID(rawValue: "author\n1"))
        XCTAssertNil(SeriesID(rawValue: ""))
        XCTAssertNil(SeriesID(rawValue: "series\u{0000}1"))

        XCTAssertEqual(AuthorID(rawValue: "author-1")?.rawValue, "author-1")
        XCTAssertEqual(SeriesID(rawValue: "series-1")?.rawValue, "series-1")

        XCTAssertThrowsError(
            try JSONDecoder().decode(AuthorID.self, from: Data("\"\"".utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SeriesID.self, from: Data("\"series\\n1\"".utf8))
        )
    }
}
