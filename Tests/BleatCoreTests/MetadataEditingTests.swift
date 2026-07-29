import Foundation
import XCTest

@testable import BleatCore

final class MetadataEditingTests: XCTestCase {
    func testPatchEncodesOnlyChangedFieldsAndExplicitNulls() throws {
        let detail = fixtureDetail()
        var draft = BookMetadataDraft(detail: detail)
        draft.title = " Updated title "
        draft.subtitle = ""
        draft.authors = ["Second Author"]
        draft.tags = ["favorite"]

        let patch = try BookMetadataPatch(
            baseline: detail,
            draft: draft
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(patch)
            ) as? [String: Any]
        )
        let metadata = try XCTUnwrap(
            object["metadata"] as? [String: Any]
        )

        XCTAssertFalse(patch.isEmpty)
        XCTAssertEqual(Set(object.keys), ["metadata", "tags"])
        XCTAssertEqual(
            Set(metadata.keys),
            ["title", "subtitle", "authors"]
        )
        XCTAssertEqual(metadata["title"] as? String, "Updated title")
        XCTAssertTrue(metadata["subtitle"] is NSNull)
        XCTAssertEqual(
            metadata["authors"] as? [[String: String]],
            [["name": "Second Author"]]
        )
        XCTAssertEqual(object["tags"] as? [String], ["favorite"])
    }

    func testPatchDetectsChangedServerRevision() throws {
        let detail = fixtureDetail()
        var draft = BookMetadataDraft(detail: detail)
        draft.title = "Updated title"
        let patch = try BookMetadataPatch(
            baseline: detail,
            draft: draft
        )
        let latest = LibraryBookDetail(
            id: detail.id,
            libraryID: detail.libraryID,
            bookID: detail.bookID,
            title: detail.title,
            subtitle: detail.subtitle,
            authors: detail.authors,
            narrators: detail.narrators,
            series: detail.series,
            genres: detail.genres,
            tags: detail.tags,
            publishedYear: detail.publishedYear,
            publishedDate: detail.publishedDate,
            publisher: detail.publisher,
            descriptionPlain: detail.descriptionPlain,
            isbn: detail.isbn,
            asin: detail.asin,
            language: detail.language,
            duration: detail.duration,
            trackCount: detail.trackCount,
            audioFileCount: detail.audioFileCount,
            chapters: detail.chapters,
            addedAtMilliseconds: detail.addedAtMilliseconds,
            updatedAtMilliseconds: 3,
            isExplicit: detail.isExplicit,
            isAbridged: detail.isAbridged,
            progress: detail.progress
        )

        XCTAssertFalse(patch.isStale(comparedTo: detail))
        XCTAssertTrue(patch.isStale(comparedTo: latest))
    }

    func testUpdateSendsAuthenticatedPatchToPrefixedRoute() async throws {
        let accountID = AccountID(rawValue: "account")
        let transport = MetadataTestTransport(
            response: HTTPResponse(
                data: Data(#"{"updated":true}"#.utf8),
                statusCode: 200
            )
        )
        let store = MetadataTestCredentialStore(
            accountID: accountID,
            credentials: try AuthenticationTokens(
                accessToken: "access-token",
                refreshToken: "refresh-token"
            )
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let detail = fixtureDetail()
        var draft = BookMetadataDraft(detail: detail)
        draft.publisher = "New Publisher"
        let patch = try BookMetadataPatch(
            baseline: detail,
            draft: draft
        )

        try await coordinator.updateBookMetadata(
            accountID: accountID,
            server: NormalizedServerURL(
                "https://books.example/audiobookshelf"
            ),
            itemID: detail.id,
            patch: patch
        )

        let recordedRequest = await transport.recordedRequest()
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://books.example/audiobookshelf/api/items/item-1/media"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        let metadata = try XCTUnwrap(
            object["metadata"] as? [String: Any]
        )
        XCTAssertEqual(Set(metadata.keys), ["publisher"])
        XCTAssertEqual(
            metadata["publisher"] as? String,
            "New Publisher"
        )
    }

    private func fixtureDetail() -> LibraryBookDetail {
        LibraryBookDetail(
            id: LibraryItemID(rawValue: "item-1"),
            libraryID: LibraryID(rawValue: "library-1"),
            bookID: BookID(rawValue: "book-1"),
            title: "Original title",
            subtitle: "Original subtitle",
            authors: [
                LibraryBookContributor(
                    id: "author-1",
                    name: "First Author"
                )
            ],
            narrators: ["Narrator"],
            series: [],
            genres: ["Fiction"],
            tags: [],
            publishedYear: "2026",
            publishedDate: nil,
            publisher: "Publisher",
            descriptionPlain: "Description",
            isbn: nil,
            asin: nil,
            language: "English",
            duration: 3_600,
            trackCount: 1,
            audioFileCount: 1,
            chapters: [],
            addedAtMilliseconds: 1,
            updatedAtMilliseconds: 2,
            isExplicit: false,
            isAbridged: false,
            progress: nil
        )
    }
}

private actor MetadataTestTransport: HTTPTransport {
    private let response: HTTPResponse
    private var request: URLRequest?

    init(response: HTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) -> HTTPResponse {
        self.request = request
        return response
    }

    func recordedRequest() -> URLRequest? {
        request
    }
}

private actor MetadataTestCredentialStore: AccountCredentialStore {
    private let accountID: AccountID
    private var storedCredentials: AuthenticationTokens?

    init(
        accountID: AccountID,
        credentials: AuthenticationTokens
    ) {
        self.accountID = accountID
        storedCredentials = credentials
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        accountID == self.accountID ? storedCredentials : nil
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        guard accountID == self.accountID else {
            return
        }
        storedCredentials = credentials
    }

    func deleteCredentials(for accountID: AccountID) {
        guard accountID == self.accountID else {
            return
        }
        storedCredentials = nil
    }
}
