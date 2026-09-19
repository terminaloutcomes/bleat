import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class MetadataEditingTests {
    @Test
    func testBookDetailSummaryMapsAvailableDomainFields() {
        let detail = fixtureDetail()
        let summary = detail.summary

        #expect(summary.id == detail.id)
        #expect(summary.libraryID == detail.libraryID)
        #expect(summary.title == detail.title)
        #expect(summary.subtitle == detail.subtitle)
        #expect(summary.authorName == detail.authors.first?.name)
        #expect(summary.narratorName == detail.narrators.first)
        #expect(summary.seriesName == detail.series.first?.name)
        #expect(summary.authors == detail.authors)
        #expect(summary.series == detail.series)
        #expect(summary.collapsedSeries == nil)
        #expect(summary.genres == detail.genres)
        #expect(summary.publisher == detail.publisher)
        #expect(summary.publishedYear == detail.publishedYear)
        #expect(summary.duration == detail.duration)
        #expect(summary.trackCount == detail.trackCount)
        #expect(summary.chapterCount == detail.chapters.count)
        #expect(summary.addedAtMilliseconds == detail.addedAtMilliseconds)
        #expect(summary.updatedAtMilliseconds == detail.updatedAtMilliseconds)
        #expect(summary.isExplicit == detail.isExplicit)
        #expect(summary.isAbridged == detail.isAbridged)
    }

    @Test
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
        let object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(patch)
            ) as? [String: Any])
        let metadata = try #require(object["metadata"] as? [String: Any])

        #expect(!(patch.isEmpty))
        #expect(Set(object.keys) == ["metadata", "tags"])
        #expect(Set(metadata.keys) == ["title", "subtitle", "authors"])
        #expect(metadata["title"] as? String == "Updated title")
        #expect(metadata["subtitle"] is NSNull)
        #expect(
            metadata["authors"] as? [[String: String]] == [
                ["name": "Second Author"]
            ])
        #expect(object["tags"] as? [String] == ["favorite"])
    }

    @Test
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

        #expect(!(patch.isStale(comparedTo: detail)))
        #expect(patch.isStale(comparedTo: latest))
    }

    @Test
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
        let request = try #require(recordedRequest)
        #expect(request.httpMethod == "PATCH")
        #expect(
            request.url?.absoluteString
                == "https://books.example/audiobookshelf/api/items/item-1/media"
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer access-token")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")
                == "application/json")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any])
        let metadata = try #require(object["metadata"] as? [String: Any])
        #expect(Set(metadata.keys) == ["publisher"])
        #expect(metadata["publisher"] as? String == "New Publisher")
    }

    @Test
    func testCoverUploadUsesAuthenticatedMultipartContract() async throws {
        let accountID = AccountID(rawValue: "account")
        let transport = MetadataTestTransport(
            response: HTTPResponse(
                data: Data(
                    #"{"success":true,"cover":"/cover.jpg"}"#.utf8
                ),
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
        let jpeg = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])

        try await coordinator.updateBookCover(
            accountID: accountID,
            server: NormalizedServerURL(
                "https://books.example/audiobookshelf"
            ),
            itemID: LibraryItemID(rawValue: "item-1"),
            jpegData: jpeg
        )

        let recordedRequest = await transport.recordedRequest()
        let request = try #require(recordedRequest)
        let contentType = try #require(
            request.value(forHTTPHeaderField: "Content-Type"))
        let body = try #require(request.httpBody)
        #expect(request.httpMethod == "POST")
        #expect(
            request.url?.absoluteString
                == "https://books.example/audiobookshelf/api/items/item-1/cover"
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer access-token")
        #expect(
            contentType.hasPrefix(
                "multipart/form-data; boundary=Bleat-"
            ))
        #expect(
            body.range(
                of: Data(
                    ("Content-Disposition: form-data; "
                        + "name=\"cover\"; filename=\"cover.jpg\"\r\n"
                        + "Content-Type: image/jpeg\r\n\r\n").utf8
                )
            ) != nil)
        #expect(body.range(of: jpeg) != nil)
    }

    @Test
    func testBookDeletionUsesAuthenticatedPrefixedContract() async throws {
        for (mode, expectedURL) in [
            (
                BookDeletionMode.libraryRecordOnly,
                "https://books.example/audiobookshelf/api/items/item-1"
            ),
            (
                BookDeletionMode.libraryRecordAndFiles,
                "https://books.example/audiobookshelf/api/items/item-1?hard=1"
            ),
        ] {
            let accountID = AccountID(rawValue: "account")
            let transport = MetadataTestTransport(
                response: HTTPResponse(data: Data(), statusCode: 200)
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

            try await coordinator.deleteBook(
                accountID: accountID,
                server: NormalizedServerURL(
                    "https://books.example/audiobookshelf"
                ),
                itemID: LibraryItemID(rawValue: "item-1"),
                mode: mode
            )

            let recordedRequest = await transport.recordedRequest()
            let request = try #require(recordedRequest)
            #expect(request.httpMethod == "DELETE")
            #expect(request.url?.absoluteString == expectedURL)
            #expect(
                request.value(forHTTPHeaderField: "Authorization")
                    == "Bearer access-token")
            #expect(request.httpBody == nil)
        }
    }

    @Test
    func testBookDeletionMapsPermissionAndMissingItemStatuses() async throws {
        for (status, expectedError) in [
            (403, BookDeletionError.permissionDenied),
            (404, BookDeletionError.itemNotFound),
            (500, BookDeletionError.unexpectedStatus(500)),
        ] {
            let accountID = AccountID(rawValue: "account-\(status)")
            let transport = MetadataTestTransport(
                response: HTTPResponse(data: Data(), statusCode: status)
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

            do {
                try await coordinator.deleteBook(
                    accountID: accountID,
                    server: NormalizedServerURL(
                        "https://books.example"
                    ),
                    itemID: LibraryItemID(rawValue: "item-1"),
                    mode: .libraryRecordOnly
                )
                Issue.record("Expected deletion to fail for status \(status)")
            } catch let error as BookDeletionError {
                #expect(error == expectedError)
            }
        }
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
                    id: AuthorID(rawValue: "author-1")!,
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

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) -> HTTPResponse {
        let request = tracedRequest.request
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
