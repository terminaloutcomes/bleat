import Foundation
import XCTest

@testable import BleatCore

final class AudiobookshelfAPITests: XCTestCase {
    func testPageRequestValidationAndExactQueryContract() throws {
        XCTAssertThrowsError(
            try LibraryItemsPageRequest(page: -1)
        ) { error in
            XCTAssertEqual(
                error as? LibraryPageRequestError,
                .invalidPage
            )
        }
        for limit in [0, 101] {
            XCTAssertThrowsError(
                try LibraryItemsPageRequest(page: 0, limit: limit)
            ) { error in
                XCTAssertEqual(
                    error as? LibraryPageRequestError,
                    .invalidLimit
                )
            }
        }
        XCTAssertThrowsError(
            try LibraryItemFilter("bad\nfilter")
        ) { error in
            XCTAssertEqual(
                error as? LibraryPageRequestError,
                .invalidFilter
            )
        }

        let filter = try LibraryItemFilter("genres.Fiction & Fantasy")
        let request = try LibraryItemsPageRequest(
            page: 2,
            limit: 50,
            sort: .author,
            descending: true,
            filter: filter
        )
        XCTAssertEqual(request.queryItems, [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "page", value: "2"),
            URLQueryItem(
                name: "sort",
                value: "media.metadata.authorNameLF"
            ),
            URLQueryItem(name: "desc", value: "1"),
            URLQueryItem(
                name: "filter",
                value: "genres.Fiction & Fantasy"
            ),
            URLQueryItem(name: "minified", value: "1"),
            URLQueryItem(name: "collapseseries", value: "1"),
            URLQueryItem(name: "include", value: "progress"),
        ])

        let sortValues = try [
            LibraryItemSort.title,
            .author,
            .addedAt,
            .updatedAt,
            .duration,
        ].map {
            try LibraryItemsPageRequest(
                page: 0,
                sort: $0,
                includeProgress: false,
                collapseSeries: false
            ).queryItems
                .first { $0.name == "sort" }?
                .value
        }
        XCTAssertEqual(sortValues, [
            "media.metadata.title",
            "media.metadata.authorNameLF",
            "addedAt",
            "updatedAt",
            "media.duration",
        ])
    }

    func testLibraryItemsMapsPinnedFixtureAndPagination() async throws {
        let fixture = try APIFixture(
            responses: [
                HTTPResponse(
                    data: try Self.fixture(
                        named: "library-items-minified"
                    ),
                    statusCode: 200
                ),
            ]
        )
        let request = try LibraryItemsPageRequest(
            page: 0,
            limit: 2,
            descending: true
        )

        let result = try await fixture.api.libraryItems(
            in: LibraryID(rawValue: "library"),
            request: request
        )
        let recordedRequests =
            await fixture.transport.recordedRequests()
        let sent = try XCTUnwrap(recordedRequests.first)
        let queryItems = try XCTUnwrap(
            URLComponents(
                url: try XCTUnwrap(sent.url),
                resolvingAgainstBaseURL: false
            )?.queryItems
        )

        XCTAssertEqual(result.value.total, 3)
        XCTAssertEqual(result.value.page, 0)
        XCTAssertEqual(result.value.limit, 2)
        XCTAssertTrue(result.value.hasNextPage)
        XCTAssertEqual(result.value.items.count, 2)
        let first = result.value.items[0]
        XCTAssertEqual(first.id, LibraryItemID(rawValue: "item-one"))
        XCTAssertEqual(first.libraryID, LibraryID(rawValue: "library"))
        XCTAssertEqual(first.title, "The First Book")
        XCTAssertEqual(first.subtitle, nil)
        XCTAssertEqual(first.authorName, "First Author")
        XCTAssertEqual(first.narratorName, nil)
        XCTAssertEqual(first.seriesName, "A Series #1")
        XCTAssertEqual(first.genres, ["Fiction"])
        XCTAssertEqual(first.publisher, nil)
        XCTAssertEqual(first.publishedYear, "2024")
        XCTAssertEqual(first.duration, 7200.5)
        XCTAssertEqual(first.trackCount, 2)
        XCTAssertEqual(first.chapterCount, 4)
        XCTAssertFalse(first.isExplicit)
        XCTAssertFalse(first.isAbridged)
        XCTAssertEqual(result.value.items[1].title, "Second Book")
        XCTAssertTrue(result.value.items[1].isExplicit)
        XCTAssertTrue(result.value.items[1].isAbridged)
        XCTAssertEqual(
            sent.url?.path,
            "/audiobookshelf/api/libraries/library/items"
        )
        XCTAssertEqual(queryItems, request.queryItems)
    }

    func testLibraryItemPageAndItemFailuresRemainTyped() async throws {
        let invalidCases: [(Data, AudiobookshelfAPIError)] = [
            (
                Self.pageJSON(
                    total: -1,
                    limit: 1,
                    page: 0,
                    itemLibraryID: "library"
                ),
                .invalidPage
            ),
            (
                Self.pageJSON(
                    total: 1,
                    limit: 2,
                    page: 0,
                    itemLibraryID: "library"
                ),
                .invalidPage
            ),
            (
                Self.pageJSON(
                    total: 1,
                    limit: 1,
                    page: 0,
                    itemLibraryID: "other"
                ),
                .invalidLibraryItem
            ),
            (
                Self.pageJSON(
                    total: 1,
                    limit: 1,
                    page: 0,
                    itemLibraryID: "library",
                    mediaType: "podcast"
                ),
                .invalidLibraryItem
            ),
        ]

        for (data, expectedError) in invalidCases {
            let fixture = try APIFixture(
                responses: [
                    HTTPResponse(data: data, statusCode: 200),
                ]
            )
            let request = try LibraryItemsPageRequest(
                page: 0,
                limit: 1
            )
            do {
                _ = try await fixture.api.libraryItems(
                    in: LibraryID(rawValue: "library"),
                    request: request
                )
                XCTFail("Expected invalid page or item")
            } catch {
                XCTAssertEqual(error, expectedError)
            }
        }

        let fixture = try APIFixture(responses: [])
        let request = try LibraryItemsPageRequest(page: 0)
        do {
            _ = try await fixture.api.libraryItems(
                in: LibraryID(rawValue: ""),
                request: request
            )
            XCTFail("Expected invalid library")
        } catch {
            XCTAssertEqual(error, .invalidLibrary)
        }
        let recordedRequests =
            await fixture.transport.recordedRequests()
        XCTAssertTrue(recordedRequests.isEmpty)
    }

    func testLibrariesUsesNativeAccountAndMapsForwardCompatibleDTOs()
        async throws
    {
        let response = HTTPResponse(
            data: Data(
                """
                {
                  "libraries": [
                    {
                      "id": "books",
                      "name": "Audiobooks",
                      "mediaType": "book",
                      "unknownFutureField": true
                    },
                    {
                      "id": "future",
                      "name": "Future Media",
                      "mediaType": "spoken-word-v2"
                    }
                  ],
                  "unknownEnvelopeField": 123
                }
                """.utf8
            ),
            statusCode: 200
        )
        let fixture = try APIFixture(responses: [response])

        let result = try await fixture.api.libraries()
        let requests = await fixture.transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let correlationHeader = try XCTUnwrap(
            request.value(forHTTPHeaderField: "X-Bleat-Request-ID")
        )

        XCTAssertEqual(result.value, [
            LibrarySummary(
                id: LibraryID(rawValue: "books"),
                name: "Audiobooks",
                mediaType: .book
            ),
            LibrarySummary(
                id: LibraryID(rawValue: "future"),
                name: "Future Media",
                mediaType: .unknown("spoken-word-v2")
            ),
        ])
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.net/audiobookshelf/api/libraries"
        )
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertEqual(
            UUID(uuidString: correlationHeader),
            result.correlationID.rawValue
        )
        XCTAssertEqual(requests.count, 1)
    }

    func testLibraryFailuresRemainTyped() async throws {
        let cases: [(HTTPResponse, AudiobookshelfAPIError)] = [
            (
                HTTPResponse(data: Data(), statusCode: 503),
                .unexpectedStatus(503)
            ),
            (
                HTTPResponse(
                    data: Data("{\"libraries\":".utf8),
                    statusCode: 200
                ),
                .malformedResponse
            ),
            (
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "libraries": [{
                            "id": "",
                            "name": "Broken",
                            "mediaType": "book"
                          }]
                        }
                        """.utf8
                    ),
                    statusCode: 200
                ),
                .invalidLibrary
            ),
            (
                HTTPResponse(
                    data: Data(
                        """
                        {
                          "libraries": [{
                            "id": "library",
                            "name": "   ",
                            "mediaType": "book"
                          }]
                        }
                        """.utf8
                    ),
                    statusCode: 200
                ),
                .invalidLibrary
            ),
        ]

        for (response, expectedError) in cases {
            let fixture = try APIFixture(responses: [response])
            do {
                _ = try await fixture.api.libraries()
                XCTFail("Expected typed API failure")
            } catch {
                XCTAssertEqual(error, expectedError)
            }
        }
    }

    func testMissingCredentialsRemainTyped() async throws {
        let fixture = try APIFixture(
            responses: [],
            includeCredentials: false
        )

        do {
            _ = try await fixture.api.libraries()
            XCTFail("Expected missing credentials")
        } catch {
            XCTAssertEqual(
                error,
                .authentication(.missingCredentials)
            )
        }
        let requests = await fixture.transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testCancellationRemainsTypedAndSendsNoRequest() async throws {
        let fixture = try APIFixture(responses: [])
        let task = Task {
            try await fixture.api.libraries()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(
                error as? AudiobookshelfAPIError,
                .cancelled
            )
        }
        let requests = await fixture.transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    private static func fixture(named name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: nil
            )?.first {
                $0.lastPathComponent == "\(name).json"
            }
        )
        return try Data(contentsOf: url)
    }

    private static func pageJSON(
        total: Int,
        limit: Int,
        page: Int,
        itemLibraryID: String,
        mediaType: String = "book"
    ) -> Data {
        Data(
            """
            {
              "results": [{
                "id": "item",
                "libraryId": "\(itemLibraryID)",
                "addedAt": 1,
                "updatedAt": 2,
                "mediaType": "\(mediaType)",
                "media": {
                  "metadata": {
                    "title": "Book",
                    "genres": [],
                    "explicit": false,
                    "abridged": false
                  },
                  "numTracks": 1,
                  "numChapters": 0,
                  "duration": 60
                }
              }],
              "total": \(total),
              "limit": \(limit),
              "page": \(page)
            }
            """.utf8
        )
    }
}

private struct APIFixture {
    let transport: APIScriptTransport
    let api: AudiobookshelfAPI<APIScriptTransport, APICredentialStore>

    init(
        responses: [HTTPResponse],
        includeCredentials: Bool = true
    ) throws {
        transport = APIScriptTransport(responses: responses)
        let credentials = APICredentialStore(
            credentials: includeCredentials
                ? try AuthenticationTokens(
                    accessToken: "access-token",
                    refreshToken: "refresh-token"
                )
                : nil
        )
        let account = try ServerAccount(
            id: AccountID(rawValue: "account"),
            server: NormalizedServerURL(
                "https://example.net/audiobookshelf"
            ),
            serverVersion: "2.36.0",
            authenticationMethods: [.local],
            user: AuthenticatedUser(
                id: UserID(rawValue: "user"),
                username: "reader",
                type: .user,
                permissions: UserPermissions(
                    download: true,
                    update: false,
                    delete: false,
                    upload: false,
                    createEReader: false,
                    accessAllLibraries: true,
                    accessAllTags: true,
                    accessExplicitContent: true,
                    selectedTagsNotAccessible: false
                ),
                accessibleLibraryIDs: [],
                selectedItemTags: []
            )
        )
        api = AudiobookshelfAPI(
            account: account,
            authCoordinator: AuthCoordinator(
                transport: transport,
                credentialStore: credentials
            )
        )
    }
}

private actor APICredentialStore: AccountCredentialStore {
    private var stored: AuthenticationTokens?

    init(credentials: AuthenticationTokens?) {
        stored = credentials
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        stored
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        stored = credentials
    }

    func deleteCredentials(for accountID: AccountID) {
        stored = nil
    }
}

private actor APIScriptTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try Task.checkCancellation()
        requests.append(request)
        guard !responses.isEmpty else {
            throw APITestError.missingResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private enum APITestError: Error {
    case missingResponse
}
