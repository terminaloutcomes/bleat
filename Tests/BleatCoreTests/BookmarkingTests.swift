import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class BookmarkingTests {
    @Test
    func testBookmarkCRUDUsesAuthenticatedPrefixedContracts() async throws {
        let accountID = AccountID(rawValue: "account")
        let transport = BookmarkTestTransport(
            responses: [
                HTTPResponse(
                    data: Data(
                        #"{"bookmarks":[{"libraryItemId":"item","time":20.5,"title":"Later","createdAt":2},{"libraryItemId":"item","time":10,"title":"Earlier","createdAt":1}]}"#
                            .utf8
                    ),
                    statusCode: 200
                ),
                HTTPResponse(
                    data: Data(
                        #"{"libraryItemId":"item","time":12.5,"title":"Chapter","createdAt":3}"#
                            .utf8
                    ),
                    statusCode: 200
                ),
                HTTPResponse(
                    data: Data(
                        #"{"libraryItemId":"item","time":12.5,"title":"Renamed","createdAt":3}"#
                            .utf8
                    ),
                    statusCode: 200
                ),
                HTTPResponse(data: Data(), statusCode: 200),
            ]
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: BookmarkTestCredentialStore(
                accountID: accountID,
                credentials: try AuthenticationTokens(
                    accessToken: "access-token",
                    refreshToken: "refresh-token"
                )
            )
        )
        let server = try NormalizedServerURL(
            "https://books.example/audiobookshelf"
        )
        let itemID = LibraryItemID(rawValue: "item")

        let bookmarks = try await coordinator.bookmarks(
            accountID: accountID,
            server: server,
            itemID: itemID
        )
        let created = try await coordinator.mutateBookmark(
            accountID: accountID,
            server: server,
            itemID: itemID,
            time: 12.5,
            title: " Chapter ",
            mutation: .create
        )
        let renamed = try await coordinator.mutateBookmark(
            accountID: accountID,
            server: server,
            itemID: itemID,
            time: 12.5,
            title: "Renamed",
            mutation: .rename
        )
        try await coordinator.deleteBookmark(
            accountID: accountID,
            server: server,
            itemID: itemID,
            time: 12.5
        )

        #expect(bookmarks.map(\.title) == ["Earlier", "Later"])
        #expect(created.title == "Chapter")
        #expect(renamed.title == "Renamed")
        let requests = await transport.recordedRequests()
        #expect(
            requests.map(\.httpMethod) == ["GET", "POST", "PATCH", "DELETE"])
        #expect(
            requests.map { $0.url?.path } == [
                "/audiobookshelf/api/me/bookmarks/item",
                "/audiobookshelf/api/me/item/item/bookmark",
                "/audiobookshelf/api/me/item/item/bookmark",
                "/audiobookshelf/api/me/item/item/bookmark/12.5",
            ])
        #expect(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization")
                    == "Bearer access-token"
            })
        let createBody = try #require(requests[1].httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: createBody)
                as? [String: Any])
        #expect(object["time"] as? Double == 12.5)
        #expect(object["title"] as? String == "Chapter")
    }

    @Test
    func testBookmarkValidationFailsBeforeTransport() async throws {
        let accountID = AccountID(rawValue: "account")
        let transport = BookmarkTestTransport(responses: [])
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: BookmarkTestCredentialStore(
                accountID: accountID,
                credentials: try AuthenticationTokens(
                    accessToken: "access-token",
                    refreshToken: "refresh-token"
                )
            )
        )
        let server = try NormalizedServerURL("https://books.example")

        await assertThrowsErrorAsync(
            try await coordinator.mutateBookmark(
                accountID: accountID,
                server: server,
                itemID: LibraryItemID(rawValue: "item"),
                time: .nan,
                title: "Title",
                mutation: .create
            )
        ) { error in
            #expect(error as? BookmarkError == .invalidTime)
        }
        await assertThrowsErrorAsync(
            try await coordinator.mutateBookmark(
                accountID: accountID,
                server: server,
                itemID: LibraryItemID(rawValue: "item"),
                time: 1,
                title: " ",
                mutation: .create
            )
        ) { error in
            #expect(error as? BookmarkError == .emptyTitle)
        }
        let requests = await transport.recordedRequests()
        #expect(requests.isEmpty)
    }
}

private actor BookmarkTestTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) throws -> HTTPResponse {
        let request = tracedRequest.request
        requests.append(request)
        guard !responses.isEmpty else {
            throw BookmarkTestError.noResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private enum BookmarkTestError: Error {
    case noResponse
}

private actor BookmarkTestCredentialStore: AccountCredentialStore {
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
