import Foundation
import XCTest

@testable import BleatCore

final class ProgressSyncTests: XCTestCase {
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
}

private actor ProgressTestTransport: HTTPTransport {
    private var responses: [HTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> HTTPResponse {
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
