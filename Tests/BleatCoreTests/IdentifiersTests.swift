import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class IdentifiersTests {
    @Test
    func testRawValueAndDescriptionArePreserved() {
        let accountID = AccountID(rawValue: "account-1")

        #expect(accountID.rawValue == "account-1")
        #expect(accountID.description == "account-1")
    }

    @Test
    func testRoundTripsThroughCodable() throws {
        let original = LibraryItemID(rawValue: "opaque/not-a-uuid")

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(
            LibraryItemID.self,
            from: data
        )

        #expect(decoded == original)
    }

    @Test
    func testDifferentKindsCanUseTheSameOpaqueValue() {
        let libraryID = LibraryID(rawValue: "same")
        let itemID = LibraryItemID(rawValue: "same")

        #expect(libraryID.rawValue == itemID.rawValue)
    }

    @Test
    func testCanonicalAccountIdentityUsesPrimaryServerAndRemoteUser() throws {
        let server = try NormalizedServerURL(
            "https://EXAMPLE.com/audiobookshelf/"
        )
        let equivalent = try NormalizedServerURL(
            "https://example.com/audiobookshelf"
        )
        let user = UserID(rawValue: "remote-user")

        #expect(
            AccountID.canonical(server: server, userID: user)
                == AccountID.canonical(server: equivalent, userID: user))
        #expect(
            AccountID.canonical(server: server, userID: user)
                != AccountID.canonical(
                    server: server,
                    userID: UserID(rawValue: "another-user")
                ))
    }

    @Test
    func testAuthorAndSeriesIDsRejectEmptyAndControlCharacters() throws {
        #expect(AuthorID(rawValue: "") == nil)
        #expect(AuthorID(rawValue: "author\n1") == nil)
        #expect(SeriesID(rawValue: "") == nil)
        #expect(SeriesID(rawValue: "series\u{0000}1") == nil)

        #expect(AuthorID(rawValue: "author-1")?.rawValue == "author-1")
        #expect(SeriesID(rawValue: "series-1")?.rawValue == "series-1")

        #expect(
            throws: (any Error).self,
            performing: {
                try JSONDecoder().decode(AuthorID.self, from: Data("\"\"".utf8))
            })
        #expect(
            throws: (any Error).self,
            performing: {
                try JSONDecoder().decode(
                    SeriesID.self, from: Data("\"series\\n1\"".utf8))
            })
    }
}
