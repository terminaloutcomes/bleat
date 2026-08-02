import Foundation
import XCTest

@testable import BleatCore

final class PlaybackSessionTests: XCTestCase {
    func testOpensDirectSessionWithExactNativeAccountContract() async throws {
        let fixture = try Fixture(
            responses: [
                .init(
                    data: Self.sessionJSON(),
                    statusCode: 200
                )
            ]
        )

        let session = try await fixture.coordinator.openPlaybackSession(
            accountID: fixture.accountID,
            server: fixture.server,
            itemID: fixture.itemID,
            preference: .directPlay,
            supportedMimeTypes: ["audio/mp4", "audio/mpeg"],
            deviceInfo: Self.deviceInfo
        )
        let requests = await fixture.transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let encodedDevice = try XCTUnwrap(
            payload["deviceInfo"] as? [String: String]
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.net/audiobookshelf/api/items/item/play"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(payload["forceDirectPlay"] as? Bool, true)
        XCTAssertEqual(payload["forceTranscode"] as? Bool, false)
        XCTAssertEqual(payload["mediaPlayer"] as? String, "AVPlayer")
        XCTAssertEqual(
            payload["supportedMimeTypes"] as? [String],
            ["audio/mp4", "audio/mpeg"]
        )
        XCTAssertEqual(
            Set(encodedDevice.keys),
            [
                "deviceId",
                "clientName",
                "clientVersion",
                "manufacturer",
                "model",
            ]
        )
        XCTAssertNil(encodedDevice["deviceName"])
        XCTAssertEqual(session.id.rawValue, "session")
        XCTAssertEqual(session.libraryID.rawValue, "library")
        XCTAssertEqual(session.libraryItemID, fixture.itemID)
        XCTAssertEqual(session.bookID?.rawValue, "book")
        XCTAssertEqual(session.method, .directPlay)
        XCTAssertEqual(session.duration, 30)
        XCTAssertEqual(session.startTime, 4)
        XCTAssertEqual(session.currentTime, 4)
        XCTAssertEqual(session.chapters.map(\.title), ["One", "Two"])
        XCTAssertEqual(session.libraryItem.media.metadata.title, "Fixture Book")
        XCTAssertEqual(session.audioTracks.map(\.index), [2, 4])
        XCTAssertEqual(session.audioTracks.map(\.startOffset), [0, 12])

        let source = try session.source(for: fixture.server)
        guard case .direct(let tracks) = source else {
            return XCTFail("Expected direct playback tracks")
        }
        XCTAssertEqual(tracks.map(\.track.index), [2, 4])
        XCTAssertEqual(
            tracks.map(\.url.absoluteString),
            [
                "https://example.net/audiobookshelf/public/session/session/track/2",
                "https://example.net/audiobookshelf/public/session/session/track/4",
            ]
        )
        XCTAssertTrue(tracks.allSatisfy { $0.url.query == nil })
    }

    func testPlaybackPreferencesEncodeOnlyDocumentedForceFlags() async throws {
        let cases: [(PlaybackPreference, Bool, Bool)] = [
            (.automatic, false, false),
            (.directPlay, true, false),
            (.transcode, false, true),
        ]

        for (preference, forceDirectPlay, forceTranscode) in cases {
            let fixture = try Fixture(
                responses: [
                    .init(
                        data: Self.sessionJSON(),
                        statusCode: 200
                    )
                ]
            )

            _ = try await fixture.coordinator.openPlaybackSession(
                accountID: fixture.accountID,
                server: fixture.server,
                itemID: fixture.itemID,
                preference: preference,
                supportedMimeTypes: [],
                deviceInfo: Self.deviceInfo
            )
            let requests = await fixture.transport.recordedRequests()
            let request = try XCTUnwrap(requests.first)
            let body = try XCTUnwrap(request.httpBody)
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body) as? [String: Any]
            )

            XCTAssertEqual(
                payload["forceDirectPlay"] as? Bool,
                forceDirectPlay
            )
            XCTAssertEqual(
                payload["forceTranscode"] as? Bool,
                forceTranscode
            )
            XCTAssertEqual(
                Set(payload.keys),
                [
                    "forceDirectPlay",
                    "forceTranscode",
                    "mediaPlayer",
                    "supportedMimeTypes",
                    "deviceInfo",
                ]
            )
        }
    }

    func testRejectsInvalidInputsBeforeReadingCredentials() async throws {
        let fixture = try Fixture(responses: [])
        let invalidDevices = [
            PlaybackDeviceInfo(
                deviceID: "",
                clientName: "Bleat",
                clientVersion: "1",
                manufacturer: "Apple",
                model: "iPhone"
            ),
            PlaybackDeviceInfo(
                deviceID: "device",
                clientName: "Bleat\nInjected",
                clientVersion: "1",
                manufacturer: "Apple",
                model: "iPhone"
            ),
        ]

        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator.openPlaybackSession(
                accountID: fixture.accountID,
                server: fixture.server,
                itemID: LibraryItemID(rawValue: ""),
                supportedMimeTypes: [],
                deviceInfo: Self.deviceInfo
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackSessionError,
                .invalidLibraryItemID
            )
        }

        for device in invalidDevices {
            await XCTAssertThrowsErrorAsync(
                try await fixture.coordinator.openPlaybackSession(
                    accountID: fixture.accountID,
                    server: fixture.server,
                    itemID: fixture.itemID,
                    supportedMimeTypes: [],
                    deviceInfo: device
                )
            ) { error in
                XCTAssertEqual(
                    error as? PlaybackSessionError,
                    .invalidDeviceInfo
                )
            }
        }

        for mimeType in ["", "audio mp4", "audio", "audio/mp4\nInjected"] {
            await XCTAssertThrowsErrorAsync(
                try await fixture.coordinator.openPlaybackSession(
                    accountID: fixture.accountID,
                    server: fixture.server,
                    itemID: fixture.itemID,
                    supportedMimeTypes: [mimeType],
                    deviceInfo: Self.deviceInfo
                )
            ) { error in
                XCTAssertEqual(
                    error as? PlaybackSessionError,
                    .invalidSupportedMimeType
                )
            }
        }

        let requests = await fixture.transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func testStartFailuresRemainTyped() async throws {
        let cases: [(HTTPResponse, PlaybackSessionError)] = [
            (
                .init(data: Data(), statusCode: 403),
                .unexpectedStartStatus(403)
            ),
            (
                .init(data: Data("not-json".utf8), statusCode: 200),
                .malformedStartResponse
            ),
            (
                .init(
                    data: Self.sessionJSON(libraryItemID: "other"),
                    statusCode: 200
                ),
                .mismatchedLibraryItem(expected: "item", actual: "other")
            ),
            (
                .init(
                    data: Self.sessionJSON(
                        embeddedLibraryItemID: "other"
                    ),
                    statusCode: 200
                ),
                .mismatchedLibraryItem(expected: "item", actual: "other")
            ),
            (
                .init(
                    data: Self.sessionJSON(audioTracks: []),
                    statusCode: 200
                ),
                .invalidSessionResponse
            ),
            (
                .init(
                    data: Self.sessionJSON(sessionID: ""),
                    statusCode: 200
                ),
                .invalidSessionResponse
            ),
        ]

        for (response, expectedError) in cases {
            let fixture = try Fixture(responses: [response])
            await XCTAssertThrowsErrorAsync(
                try await fixture.coordinator.openPlaybackSession(
                    accountID: fixture.accountID,
                    server: fixture.server,
                    itemID: fixture.itemID,
                    supportedMimeTypes: [],
                    deviceInfo: Self.deviceInfo
                )
            ) { error in
                XCTAssertEqual(
                    error as? PlaybackSessionError,
                    expectedError
                )
            }
        }
    }

    func testAuthenticationFailureRemainsDistinct() async throws {
        let fixture = try Fixture(
            responses: [],
            includeCredentials: false
        )

        await XCTAssertThrowsErrorAsync(
            try await fixture.coordinator.openPlaybackSession(
                accountID: fixture.accountID,
                server: fixture.server,
                itemID: fixture.itemID,
                supportedMimeTypes: [],
                deviceInfo: Self.deviceInfo
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackSessionError,
                .authenticationFailed(.missingCredentials)
            )
        }
    }

    func testResolvesPrefixedHLSAndRejectsUnsafeReturnedPaths() async throws {
        let server = try NormalizedServerURL(
            "https://example.net/audiobookshelf"
        )
        let hlsSession = try await Self.decodeSession(
            Self.sessionJSON(
                method: 2,
                audioTracks: [
                    Self.track(
                        index: 1,
                        contentURL: "/hls/session/output.m3u8",
                        mimeType: "application/vnd.apple.mpegurl"
                    )
                ]
            )
        )

        XCTAssertEqual(
            try hlsSession.source(for: server),
            .hls(
                try XCTUnwrap(
                    URL(
                        string:
                            "https://example.net/audiobookshelf/hls/session/output.m3u8"
                    )
                )
            )
        )

        for path in [
            "https://other.example/output.m3u8",
            "/hls/session/output.m3u8?token=secret",
        ] {
            let session = try await Self.decodeSession(
                Self.sessionJSON(
                    method: 2,
                    audioTracks: [
                        Self.track(
                            index: 1,
                            contentURL: path,
                            mimeType: "application/vnd.apple.mpegurl"
                        )
                    ]
                )
            )
            XCTAssertThrowsError(try session.source(for: server)) { error in
                guard
                    case .routeConstructionFailed =
                        error as? PlaybackSourceError
                else {
                    return XCTFail("Expected route construction failure")
                }
            }
        }
    }

    func testUnsupportedAndMissingPlaybackSourcesAreTyped() async throws {
        let server = try NormalizedServerURL("https://example.net")
        let localSession = try await Self.decodeSession(
            Self.sessionJSON(method: 3)
        )
        let unknownSession = try await Self.decodeSession(
            Self.sessionJSON(method: 99)
        )

        await XCTAssertThrowsErrorAsync(
            try await Self.decodeSession(
                Self.sessionJSON(method: 2, audioTracks: [])
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackSessionError,
                .invalidSessionResponse
            )
        }

        await XCTAssertThrowsErrorAsync(
            try await Self.decodeSession(
                Self.sessionJSON(audioTracks: [
                    Self.track(
                        index: -1,
                        contentURL: "/invalid",
                        mimeType: "audio/mp4"
                    )
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackSessionError,
                .invalidSessionResponse
            )
        }

        XCTAssertThrowsError(try localSession.source(for: server)) { error in
            XCTAssertEqual(
                error as? PlaybackSourceError,
                .unsupportedMethod(.local)
            )
        }
        XCTAssertThrowsError(try unknownSession.source(for: server)) { error in
            XCTAssertEqual(
                error as? PlaybackSourceError,
                .unsupportedMethod(.unknown(99))
            )
        }
    }

    func testPlaybackMethodRoundTripsKnownAndUnknownValues() throws {
        for (value, expected) in [
            (0, PlaybackMethod.directPlay),
            (2, .transcode),
            (3, .local),
            (99, .unknown(99)),
        ] {
            let decoded = try JSONDecoder().decode(
                PlaybackMethod.self,
                from: Data(String(value).utf8)
            )
            let encoded = try JSONEncoder().encode(decoded)

            XCTAssertEqual(decoded, expected)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\(value)")
        }
    }

    func testClosePostsToAuthenticatedSessionRoute() async throws {
        let fixture = try Fixture(
            responses: [.init(data: Data(), statusCode: 200)]
        )

        try await fixture.coordinator.closePlaybackSession(
            accountID: fixture.accountID,
            server: fixture.server,
            sessionID: PlaybackSessionID(rawValue: "session")
        )
        let requests = await fixture.transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.net/audiobookshelf/api/session/session/close"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
    }

    func testSyncPostsExactMVPPositionContract() async throws {
        let fixture = try Fixture(
            responses: [.init(data: Data(), statusCode: 200)]
        )

        try await fixture.coordinator.syncPlaybackSession(
            accountID: fixture.accountID,
            server: fixture.server,
            sessionID: PlaybackSessionID(rawValue: "session"),
            currentTime: 12.5,
            duration: 30
        )
        let requests = await fixture.transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(request.httpBody)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Double]
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.net/audiobookshelf/api/session/session/sync"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
        XCTAssertEqual(
            payload,
            [
                "currentTime": 12.5,
                "timeListened": 0,
                "duration": 30,
            ]
        )
    }

    func testSyncValidationAndFailuresRemainTyped() async throws {
        let invalidCases:
            [(
                PlaybackSessionID,
                Double,
                Double,
                PlaybackSyncError
            )] = [
                (
                    PlaybackSessionID(rawValue: ""),
                    0,
                    30,
                    .invalidSessionID
                ),
                (
                    PlaybackSessionID(rawValue: "session"),
                    -.infinity,
                    30,
                    .invalidPosition
                ),
                (
                    PlaybackSessionID(rawValue: "session"),
                    0,
                    .nan,
                    .invalidDuration
                ),
                (
                    PlaybackSessionID(rawValue: "session"),
                    31,
                    30,
                    .positionExceedsDuration
                ),
            ]
        for (sessionID, currentTime, duration, expected) in invalidCases {
            let fixture = try Fixture(responses: [])
            await XCTAssertThrowsErrorAsync(
                try await fixture.coordinator.syncPlaybackSession(
                    accountID: fixture.accountID,
                    server: fixture.server,
                    sessionID: sessionID,
                    currentTime: currentTime,
                    duration: duration
                )
            ) { error in
                XCTAssertEqual(error as? PlaybackSyncError, expected)
            }
            let requests = await fixture.transport.recordedRequests()
            XCTAssertTrue(requests.isEmpty)
        }

        let rejectedFixture = try Fixture(
            responses: [.init(data: Data(), statusCode: 404)]
        )
        await XCTAssertThrowsErrorAsync(
            try await rejectedFixture.coordinator.syncPlaybackSession(
                accountID: rejectedFixture.accountID,
                server: rejectedFixture.server,
                sessionID: PlaybackSessionID(rawValue: "missing"),
                currentTime: 1,
                duration: 30
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackSyncError,
                .unexpectedStatus(404)
            )
        }

        let unauthenticatedFixture = try Fixture(
            responses: [],
            includeCredentials: false
        )
        await XCTAssertThrowsErrorAsync(
            try await unauthenticatedFixture.coordinator
                .syncPlaybackSession(
                    accountID: unauthenticatedFixture.accountID,
                    server: unauthenticatedFixture.server,
                    sessionID: PlaybackSessionID(rawValue: "session"),
                    currentTime: 1,
                    duration: 30
                )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackSyncError,
                .authenticationFailed(.missingCredentials)
            )
        }
    }

    func testCloseFailuresRemainTyped() async throws {
        let invalidFixture = try Fixture(responses: [])
        await XCTAssertThrowsErrorAsync(
            try await invalidFixture.coordinator.closePlaybackSession(
                accountID: invalidFixture.accountID,
                server: invalidFixture.server,
                sessionID: PlaybackSessionID(rawValue: "")
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackSessionError,
                .invalidSessionResponse
            )
        }

        let rejectedFixture = try Fixture(
            responses: [.init(data: Data(), statusCode: 404)]
        )
        await XCTAssertThrowsErrorAsync(
            try await rejectedFixture.coordinator.closePlaybackSession(
                accountID: rejectedFixture.accountID,
                server: rejectedFixture.server,
                sessionID: PlaybackSessionID(rawValue: "missing")
            )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackSessionError,
                .unexpectedCloseStatus(404)
            )
        }

        let unauthenticatedFixture = try Fixture(
            responses: [],
            includeCredentials: false
        )
        await XCTAssertThrowsErrorAsync(
            try await unauthenticatedFixture.coordinator
                .closePlaybackSession(
                    accountID: unauthenticatedFixture.accountID,
                    server: unauthenticatedFixture.server,
                    sessionID: PlaybackSessionID(rawValue: "session")
                )
        ) { error in
            XCTAssertEqual(
                error as? PlaybackSessionError,
                .authenticationFailed(.missingCredentials)
            )
        }
    }

    private static let deviceInfo = PlaybackDeviceInfo(
        deviceID: "bleat-test-device",
        clientName: "Bleat",
        clientVersion: "0.1.0",
        manufacturer: "Apple",
        model: "iPhone Simulator"
    )

    private static func track(
        index: Int,
        startOffset: Double = 0,
        duration: Double = 12,
        contentURL: String = "/api/items/item/file/1",
        mimeType: String = "audio/mp4"
    ) -> [String: Any] {
        [
            "index": index,
            "startOffset": startOffset,
            "duration": duration,
            "title": "Track \(index)",
            "contentUrl": contentURL,
            "mimeType": mimeType,
            "codec": "aac",
        ]
    }

    private static func sessionJSON(
        sessionID: String = "session",
        libraryItemID: String = "item",
        embeddedLibraryItemID: String? = nil,
        method: Int = 0,
        audioTracks: [[String: Any]] = [
            track(index: 2),
            track(
                index: 4,
                startOffset: 12,
                contentURL: "/api/items/item/file/2"
            ),
        ]
    ) -> Data {
        let payload: [String: Any] = [
            "id": sessionID,
            "libraryId": "library",
            "libraryItemId": libraryItemID,
            "bookId": "book",
            "mediaType": "book",
            "duration": 30,
            "playMethod": method,
            "startTime": 4,
            "currentTime": 4,
            "chapters": [
                ["id": 0, "start": 0, "end": 15, "title": "One"],
                ["id": 1, "start": 15, "end": 30, "title": "Two"],
            ],
            "audioTracks": audioTracks,
            "libraryItem": [
                "id": embeddedLibraryItemID ?? libraryItemID,
                "libraryId": "library",
                "mediaType": "book",
                "isFile": false,
                "media": [
                    "id": "book",
                    "metadata": [
                        "title": "Fixture Book",
                        "subtitle": "A fixture",
                    ],
                    "duration": 30,
                ],
            ],
        ]
        do {
            return try JSONSerialization.data(withJSONObject: payload)
        } catch {
            fatalError("Playback fixture must encode: \(error)")
        }
    }

    private static func decodeSession(
        _ data: Data
    ) async throws -> PlaybackSession {
        let fixture = try Fixture(
            responses: [.init(data: data, statusCode: 200)]
        )
        return try await fixture.coordinator.openPlaybackSession(
            accountID: fixture.accountID,
            server: fixture.server,
            itemID: fixture.itemID,
            supportedMimeTypes: [],
            deviceInfo: deviceInfo
        )
    }
}

private struct Fixture {
    let accountID = AccountID(rawValue: "account")
    let itemID = LibraryItemID(rawValue: "item")
    let server: NormalizedServerURL
    let transport: PlaybackTestTransport
    let coordinator:
        AuthCoordinator<
            PlaybackTestTransport,
            PlaybackTestCredentialStore
        >

    init(
        responses: [HTTPResponse],
        includeCredentials: Bool = true
    ) throws {
        server = try NormalizedServerURL(
            "https://example.net/audiobookshelf"
        )
        transport = PlaybackTestTransport(responses: responses)
        let credentials =
            includeCredentials
            ? try AuthenticationTokens(
                accessToken: "access-token",
                refreshToken: "refresh-token"
            )
            : nil
        let store = PlaybackTestCredentialStore(
            accountID: accountID,
            credentials: credentials
        )
        coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
    }
}

private actor PlaybackTestTransport: HTTPTransport {
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
            throw PlaybackTestError.noResponse
        }
        return responses.removeFirst()
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}

private actor PlaybackTestCredentialStore: AccountCredentialStore {
    private let accountID: AccountID
    private var storedCredentials: AuthenticationTokens?

    init(
        accountID: AccountID,
        credentials: AuthenticationTokens?
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

private enum PlaybackTestError: Error {
    case noResponse
}
