import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class LocalPlaybackSessionTests {
    @Test
    func testBatchUsesExactAuthenticatedContractAndListeningTime()
        async throws
    {
        let accountID = AccountID(rawValue: "account")
        let session = try Self.session(timeListening: 12.5)
        let transport = LocalSessionTestTransport(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        {"results":[{"id":"\(session.id.rawValue)","success":true,"progressSynced":true,"error":null}]}
                        """.utf8
                    ),
                    statusCode: 200
                )
            ]
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: LocalSessionTestCredentialStore(
                accountID: accountID
            )
        )

        let results = try await coordinator.syncLocalPlaybackSessions(
            accountID: accountID,
            server: try NormalizedServerURL(
                "https://books.example/audiobookshelf"
            ),
            sessions: [session],
            deviceInfo: Self.deviceInfo
        )

        #expect(results.count == 1)
        #expect(results[0].id == session.id)
        #expect(results[0].success)
        #expect(results[0].progressSynced)
        let requests = await transport.recordedRequests()
        let request = try #require(requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/audiobookshelf/api/session/local-all")
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer access")
        let body = try #require(request.httpBody)
        let object = try #require(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any])
        let sessions = try #require(object["sessions"] as? [[String: Any]])
        let encoded = try #require(sessions.first)
        #expect(encoded["id"] as? String == session.id.rawValue)
        #expect(encoded["playMethod"] as? Int == 3)
        #expect(encoded["timeListening"] as? Double == 12.5)
        #expect(encoded["currentTime"] as? Double == 25)
        #expect(encoded["updatedAt"] as? Int == 2_000)
        #expect(
            (object["deviceInfo"] as? [String: Any])?["deviceId"]
                as? String == "device")
    }

    @Test
    func testUpdatingPreservesUUIDAndSessionStart() throws {
        let original = try Self.session()

        let updated = try original.updating(
            currentTime: 40,
            now: Date(timeIntervalSince1970: 3)
        )

        #expect(updated.id == original.id)
        #expect(updated.startTime == 10)
        #expect(updated.startedAtMilliseconds == 1_000)
        #expect(updated.currentTime == 40)
        #expect(updated.updatedAtMilliseconds == 3_000)
        #expect(updated.timeListening == 0)
    }

    @Test
    func testFailedResultWithoutProgressFlagRemainsTyped() async throws {
        let accountID = AccountID(rawValue: "account")
        let session = try Self.session()
        let transport = LocalSessionTestTransport(
            responses: [
                HTTPResponse(
                    data: Data(
                        """
                        {"results":[{"id":"\(session.id.rawValue)","success":false,"error":"Media item not found"}]}
                        """.utf8
                    ),
                    statusCode: 200
                )
            ]
        )
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: LocalSessionTestCredentialStore(
                accountID: accountID
            )
        )

        let result = try await coordinator.syncLocalPlaybackSessions(
            accountID: accountID,
            server: try NormalizedServerURL("https://books.example"),
            sessions: [session],
            deviceInfo: Self.deviceInfo
        )[0]

        #expect(!(result.success))
        #expect(!(result.progressSynced))
        #expect(result.error == "Media item not found")
    }

    @Test
    func testRejectsDuplicateIDsAndMismatchedResponse() async throws {
        let accountID = AccountID(rawValue: "account")
        let session = try Self.session()
        let duplicateCoordinator = AuthCoordinator(
            transport: LocalSessionTestTransport(responses: []),
            credentialStore: LocalSessionTestCredentialStore(
                accountID: accountID
            )
        )
        do {
            _ = try await duplicateCoordinator.syncLocalPlaybackSessions(
                accountID: accountID,
                server: try NormalizedServerURL("https://books.example"),
                sessions: [session, session],
                deviceInfo: Self.deviceInfo
            )
            Issue.record("Expected duplicate session rejection")
        } catch let error {
            #expect(error as? LocalPlaybackSessionError == .duplicateSessionID)
        }

        let responseCoordinator = AuthCoordinator(
            transport: LocalSessionTestTransport(
                responses: [
                    HTTPResponse(
                        data: Data(
                            #"{"results":[{"id":"5eef37df-6838-4dd5-9875-266ae49db169","success":true,"progressSynced":true}]}"#
                                .utf8
                        ),
                        statusCode: 200
                    )
                ]
            ),
            credentialStore: LocalSessionTestCredentialStore(
                accountID: accountID
            )
        )
        do {
            _ = try await responseCoordinator.syncLocalPlaybackSessions(
                accountID: accountID,
                server: try NormalizedServerURL("https://books.example"),
                sessions: [session],
                deviceInfo: Self.deviceInfo
            )
            Issue.record("Expected mismatched result rejection")
        } catch let error {
            #expect(error as? LocalPlaybackSessionError == .malformedResponse)
        }
    }

    @Test
    func testSessionValidationRejectsNonV4IDAndInvalidPosition() throws {
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try Self.session(
                    id: "00000000-0000-0000-0000-000000000000"
                )
            })
        {
            #expect(error as? LocalPlaybackSessionError == .invalidSessionID)
        }
        if let error = #expect(
            throws: (any Error).self,
            performing: { try Self.session(currentTime: 101) })
        {
            #expect(error as? LocalPlaybackSessionError == .invalidPosition)
        }
    }

    private static let deviceInfo = PlaybackDeviceInfo(
        deviceID: "device",
        clientName: "Bleat",
        clientVersion: "0.1",
        manufacturer: "Apple",
        model: "iPhone"
    )

    private static func session(
        id: String = "d9ef37df-6838-4dd5-9875-266ae49db169",
        currentTime: Double = 25,
        timeListening: Double = 0
    ) throws -> LocalPlaybackSession {
        try LocalPlaybackSession(
            id: PlaybackSessionID(rawValue: id),
            libraryID: LibraryID(rawValue: "library"),
            libraryItemID: LibraryItemID(rawValue: "item"),
            bookID: BookID(rawValue: "book"),
            mediaMetadata: LocalPlaybackMediaMetadata(title: "Example"),
            chapters: [],
            displayTitle: "Example",
            displayAuthor: "Author",
            duration: 100,
            timeListening: timeListening,
            startTime: 10,
            currentTime: currentTime,
            startedAtMilliseconds: 1_000,
            updatedAtMilliseconds: 2_000
        )
    }
}

private actor LocalSessionTestTransport: HTTPTransport {
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
            throw LocalSessionTestTransportError.noResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private enum LocalSessionTestTransportError: Error {
    case noResponse
}

private actor LocalSessionTestCredentialStore: AccountCredentialStore {
    private let accountID: AccountID
    private var credentials: AuthenticationTokens?

    init(accountID: AccountID) {
        self.accountID = accountID
        credentials = try? AuthenticationTokens(
            accessToken: "access",
            refreshToken: "refresh"
        )
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        accountID == self.accountID ? credentials : nil
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        if accountID == self.accountID {
            self.credentials = credentials
        }
    }

    func deleteCredentials(for accountID: AccountID) {
        if accountID == self.accountID {
            credentials = nil
        }
    }
}
