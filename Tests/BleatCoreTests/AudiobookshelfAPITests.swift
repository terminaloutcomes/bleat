import Foundation
import XCTest

@testable import BleatCore

final class AudiobookshelfAPITests: XCTestCase {
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
