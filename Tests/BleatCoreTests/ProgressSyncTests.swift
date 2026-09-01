import Foundation
import XCTest

@testable import BleatCore

final class ProgressSyncTests: XCTestCase {
    func testAllProgressUsesAuthenticatedPathPrefixedRouteAndExcludesPodcasts()
        async throws
    {
        let accountID = AccountID(rawValue: "account")
        let response = HTTPResponse(
            data: Data(
                #"{"mediaProgress":[{"id":"first","userId":"user","libraryItemId":"item-one","episodeId":null,"mediaItemId":"book-one","mediaItemType":"book","duration":100,"progress":1,"currentTime":100,"isFinished":true,"hideFromContinueListening":false,"lastUpdate":12,"startedAt":1,"finishedAt":12,"futureField":"ignored"},{"id":"podcast","userId":"user","libraryItemId":"podcast-item","episodeId":"episode","mediaItemId":"podcast-media","mediaItemType":"podcast","duration":10,"progress":0.5,"currentTime":5,"isFinished":false,"hideFromContinueListening":false,"lastUpdate":13,"startedAt":2,"finishedAt":null}]}"#
                    .utf8
            ),
            statusCode: 200
        )
        let transport = ProgressTestTransport(
            responses: [response, response]
        )
        let coordinator = try Self.coordinator(
            accountID: accountID,
            transport: transport
        )

        let progress = try await coordinator.allBookProgress(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            server: NormalizedServerURL(
                "https://books.example/audiobookshelf"
            )
        )
        let rootProgress = try await coordinator.allBookProgress(
            accountID: accountID,
            userID: UserID(rawValue: "user"),
            server: NormalizedServerURL("https://books.example")
        )

        XCTAssertEqual(
            progress.map { $0.libraryItemID.rawValue },
            ["item-one"]
        )
        XCTAssertEqual(progress.map { $0.isFinished }, [true])
        XCTAssertEqual(rootProgress, progress)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(
            requests.compactMap { $0.url?.path },
            [
                "/audiobookshelf/api/me/progress",
                "/api/me/progress",
            ]
        )
        XCTAssertTrue(
            requests.allSatisfy {
                $0.httpMethod == "GET"
                    && $0.value(forHTTPHeaderField: "Authorization")
                        == "Bearer access"
            }
        )
    }

    func testAllProgressRejectsWrongUserAndMalformedBookProgress() async throws
    {
        let valid =
            #"{"id":"progress","userId":"other-user","libraryItemId":"item","episodeId":null,"mediaItemId":"book","mediaItemType":"book","duration":100,"progress":0.25,"currentTime":25,"isFinished":false,"hideFromContinueListening":false,"lastUpdate":12,"startedAt":1,"finishedAt":null}"#
        let malformed =
            #"{"id":"progress","userId":"user","libraryItemId":"item","episodeId":null,"mediaItemId":"book","mediaItemType":"book","duration":-1,"progress":0.25,"currentTime":25,"isFinished":false,"hideFromContinueListening":false,"lastUpdate":12,"startedAt":1,"finishedAt":null}"#
        let transport = ProgressTestTransport(
            responses: [
                HTTPResponse(
                    data: Data(#"{"mediaProgress":[\#(valid)]}"#.utf8),
                    statusCode: 200
                ),
                HTTPResponse(
                    data: Data(#"{"mediaProgress":[\#(malformed)]}"#.utf8),
                    statusCode: 200
                ),
            ]
        )
        let accountID = AccountID(rawValue: "account")
        let coordinator = try Self.coordinator(
            accountID: accountID,
            transport: transport
        )
        let server = try NormalizedServerURL("https://books.example")

        for _ in 0..<2 {
            do {
                _ = try await coordinator.allBookProgress(
                    accountID: accountID,
                    userID: UserID(rawValue: "user"),
                    server: server
                )
                XCTFail("Expected malformed response")
            } catch let error {
                XCTAssertEqual(error, .malformedResponse)
            }
        }
    }

    func testAllProgressRejectsMismatchedAccountCredentials() async throws {
        let accountID = AccountID(rawValue: "account")
        let coordinator = try Self.coordinator(
            accountID: accountID,
            transport: ProgressTestTransport(responses: [])
        )

        do {
            _ = try await coordinator.allBookProgress(
                accountID: AccountID(rawValue: "different-account"),
                userID: UserID(rawValue: "user"),
                server: NormalizedServerURL("https://books.example")
            )
            XCTFail("Expected authentication failure")
        } catch let error as BookProgressError {
            guard case .authenticationFailed = error else {
                return XCTFail("Expected authentication failure, got \(error)")
            }
        }
    }

    func testFetchAndPatchUseExactAuthenticatedContract() async throws {
        let accountID = AccountID(rawValue: "account")
        let transport = ProgressTestTransport(
            responses: [
                HTTPResponse(
                    data: Data(
                        #"{"id":"progress","userId":"user","libraryItemId":"item","episodeId":null,"mediaItemId":"book","mediaItemType":"book","duration":100,"progress":0.25,"currentTime":25,"isFinished":false,"hideFromContinueListening":false,"lastUpdate":12,"startedAt":1,"finishedAt":null}"#
                            .utf8
                    ),
                    statusCode: 200
                ),
                HTTPResponse(data: Data(), statusCode: 200),
            ]
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: ProgressTestCredentialStore(
                accountID: accountID,
                credentials: try AuthenticationTokens(
                    accessToken: "access",
                    refreshToken: "refresh"
                )
            )
        )
        let server = try NormalizedServerURL(
            "https://books.example/audiobookshelf"
        )
        let itemID = LibraryItemID(rawValue: "item")

        let progress = try await coordinator.bookProgress(
            accountID: accountID,
            server: server,
            itemID: itemID
        )
        try await coordinator.updateBookProgress(
            accountID: accountID,
            server: server,
            itemID: itemID,
            update: BookProgressUpdate(
                duration: 100,
                currentTime: 30,
                progress: 0.3,
                isFinished: false
            )
        )

        XCTAssertEqual(progress?.currentTime, 25)
        XCTAssertEqual(progress?.lastUpdateMilliseconds, 12)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PATCH"])
        XCTAssertEqual(
            requests.map { $0.url?.path },
            [
                "/audiobookshelf/api/me/progress/item",
                "/audiobookshelf/api/me/progress/item",
            ]
        )
        XCTAssertTrue(
            requests.allSatisfy {
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer access"
            })
        let body = try XCTUnwrap(requests[1].httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["duration", "currentTime", "progress", "isFinished"]
        )
    }

    func testMissingProgressAndValidationRemainTyped() async throws {
        let accountID = AccountID(rawValue: "account")
        let transport = ProgressTestTransport(
            responses: [HTTPResponse(data: Data(), statusCode: 404)]
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: ProgressTestCredentialStore(
                accountID: accountID,
                credentials: try AuthenticationTokens(
                    accessToken: "access",
                    refreshToken: "refresh"
                )
            )
        )
        let server = try NormalizedServerURL("https://books.example")
        let itemID = LibraryItemID(rawValue: "item")

        let missing = try await coordinator.bookProgress(
            accountID: accountID,
            server: server,
            itemID: itemID
        )
        XCTAssertNil(missing)
        do {
            try await coordinator.updateBookProgress(
                accountID: accountID,
                server: server,
                itemID: itemID,
                update: BookProgressUpdate(currentTime: .nan)
            )
            XCTFail("Expected invalid time")
        } catch {
            XCTAssertEqual(error, .invalidCurrentTime)
        }
    }

    private static func coordinator(
        accountID: AccountID,
        transport: ProgressTestTransport
    ) throws -> AuthCoordinator<
        ProgressTestTransport,
        ProgressTestCredentialStore
    > {
        AuthCoordinator(
            transport: transport,
            credentialStore: ProgressTestCredentialStore(
                accountID: accountID,
                credentials: try AuthenticationTokens(
                    accessToken: "access",
                    refreshToken: "refresh"
                )
            )
        )
    }
}

private actor ProgressTestTransport: HTTPTransport {
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
            throw ProgressTestTransportError.noResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private enum ProgressTestTransportError: Error {
    case noResponse
}

private actor ProgressTestCredentialStore: AccountCredentialStore {
    private let accountID: AccountID
    private var stored: AuthenticationTokens?

    init(accountID: AccountID, credentials: AuthenticationTokens) {
        self.accountID = accountID
        stored = credentials
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        accountID == self.accountID ? stored : nil
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        if accountID == self.accountID {
            stored = credentials
        }
    }

    func deleteCredentials(for accountID: AccountID) {
        if accountID == self.accountID {
            stored = nil
        }
    }
}
