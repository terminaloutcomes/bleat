import Foundation
import XCTest

@testable import BleatCore

final class PlaybackSessionLiveTests: XCTestCase {
    func testPinnedRootAndPrefixPlaybackContracts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
              let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
              let username = environment["BLEAT_LIVE_USERNAME"],
              let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live playback data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            try await verifyPlaybackContracts(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "playback-\(index)"),
                username: username,
                password: password
            )
        }
    }

    private func verifyPlaybackContracts(
        server: NormalizedServerURL,
        accountID: AccountID,
        username: String,
        password: String
    ) async throws {
        let store = LiveCredentialStore()
        let transport = LocalDockerHTTPTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        _ = try await coordinator.login(
            accountID: accountID,
            server: server,
            username: username,
            password: password
        )
        let items = try await seededItems(
            coordinator: coordinator,
            accountID: accountID,
            server: server
        )
        let directItem = try item(endingIn: "/direct", from: items)
        let multiTrackItem = try item(
            endingIn: "/multi-track",
            from: items
        )
        let transcodeItem = try item(
            endingIn: "/transcode",
            from: items
        )

        try await verifyDirectRanges(
            itemID: directItem.id,
            coordinator: coordinator,
            transport: transport,
            store: store,
            accountID: accountID,
            server: server
        )
        try await verifyMultiTrackTransition(
            itemID: multiTrackItem.id,
            coordinator: coordinator,
            transport: transport,
            accountID: accountID,
            server: server
        )
        try await verifyHLS(
            itemID: transcodeItem.id,
            coordinator: coordinator,
            transport: transport,
            store: store,
            accountID: accountID,
            server: server
        )
    }

    private func seededItems<
        Transport: HTTPTransport,
        CredentialStore: AccountCredentialStore
    >(
        coordinator: AuthCoordinator<Transport, CredentialStore>,
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws -> [LiveLibraryItem] {
        let builder = AudiobookshelfRouteBuilder(server: server)
        var librariesRequest = URLRequest(
            url: try builder.url(for: .libraries)
        )
        librariesRequest.httpMethod = "GET"
        let librariesResponse = try await coordinator.sendAuthenticated(
            librariesRequest,
            route: .libraries,
            accountID: accountID,
            server: server
        )
        XCTAssertEqual(librariesResponse.statusCode, 200)
        let libraries = try JSONDecoder().decode(
            LiveLibrariesResponse.self,
            from: librariesResponse.data
        )
        let library = try XCTUnwrap(
            libraries.libraries.first { $0.name == "Bleat Live Fixtures" }
        )

        let route = AudiobookshelfRoute.libraryItems(library.id)
        var itemsRequest = URLRequest(url: try builder.url(for: route))
        itemsRequest.httpMethod = "GET"
        let itemsResponse = try await coordinator.sendAuthenticated(
            itemsRequest,
            route: route,
            accountID: accountID,
            server: server
        )
        XCTAssertEqual(itemsResponse.statusCode, 200)
        let items = try JSONDecoder().decode(
            LiveLibraryItemsResponse.self,
            from: itemsResponse.data
        )
        XCTAssertEqual(items.total, 3)
        return items.results
    }

    private func item(
        endingIn pathSuffix: String,
        from items: [LiveLibraryItem]
    ) throws -> LiveLibraryItem {
        try XCTUnwrap(items.first { $0.path.hasSuffix(pathSuffix) })
    }

    private func verifyDirectRanges<
        Transport: HTTPTransport,
        CredentialStore: AccountCredentialStore
    >(
        itemID: LibraryItemID,
        coordinator: AuthCoordinator<Transport, CredentialStore>,
        transport: LocalDockerHTTPTransport,
        store: LiveCredentialStore,
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws {
        let session = try await coordinator.openPlaybackSession(
            accountID: accountID,
            server: server,
            itemID: itemID,
            preference: .directPlay,
            supportedMimeTypes: ["audio/mp4", "audio/mpeg"],
            deviceInfo: Self.deviceInfo(accountID)
        )
        XCTAssertEqual(session.method, .directPlay)
        let source = try session.source(for: server)
        guard case let .direct(tracks) = source else {
            return XCTFail("Expected direct playback")
        }
        XCTAssertEqual(tracks.count, 1)
        let mediaURL = try XCTUnwrap(tracks.first?.url)
        try await assertTokenFree(mediaURL, store: store, accountID: accountID)

        let probe = try await range(
            0 ... 0,
            from: mediaURL,
            transport: transport
        )
        let totalSize = try totalSize(from: probe)
        XCTAssertGreaterThan(totalSize, 96)

        let ranges = [
            0 ... 31,
            (totalSize / 2) ... (totalSize / 2 + 31),
            (totalSize - 32) ... (totalSize - 1),
        ]
        for requestedRange in ranges {
            let response = try await range(
                requestedRange,
                from: mediaURL,
                transport: transport
            )
            XCTAssertEqual(response.statusCode, 206)
            XCTAssertEqual(response.data.count, requestedRange.count)
            XCTAssertEqual(
                response.header(named: "Content-Range"),
                "bytes \(requestedRange.lowerBound)-\(requestedRange.upperBound)/\(totalSize)"
            )
        }

        try await coordinator.syncPlaybackSession(
            accountID: accountID,
            server: server,
            sessionID: session.id,
            currentTime: min(1, session.duration),
            duration: session.duration
        )
        try await coordinator.closePlaybackSession(
            accountID: accountID,
            server: server,
            sessionID: session.id
        )
        let closedResponse = try await transport.send(
            TracedHTTPRequest(
                request: URLRequest(url: mediaURL),
                endpoint: .directPlay
            )
        )
        XCTAssertEqual(closedResponse.statusCode, 404)
    }

    private func verifyMultiTrackTransition<
        Transport: HTTPTransport,
        CredentialStore: AccountCredentialStore
    >(
        itemID: LibraryItemID,
        coordinator: AuthCoordinator<Transport, CredentialStore>,
        transport: LocalDockerHTTPTransport,
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws {
        let session = try await coordinator.openPlaybackSession(
            accountID: accountID,
            server: server,
            itemID: itemID,
            preference: .directPlay,
            supportedMimeTypes: [
                "audio/aac",
                "audio/mp4",
                "audio/mpeg",
            ],
            deviceInfo: Self.deviceInfo(accountID)
        )
        let source = try session.source(for: server)
        guard case let .direct(tracks) = source else {
            return XCTFail("Expected direct multi-track playback")
        }

        XCTAssertEqual(tracks.count, 3)
        XCTAssertEqual(tracks.map(\.track.index), [1, 2, 3])
        XCTAssertEqual(tracks.first?.track.startOffset, 0)
        XCTAssertTrue(
            zip(
                tracks.map(\.track.startOffset),
                tracks.dropFirst().map(\.track.startOffset)
            ).allSatisfy { pair in
                pair.0 < pair.1
            }
        )

        let firstURL = try XCTUnwrap(tracks.first?.url)
        let secondURL = tracks[1].url
        let firstProbe = try await range(
            0 ... 0,
            from: firstURL,
            transport: transport
        )
        let firstSize = try totalSize(from: firstProbe)
        let firstLastByte = try await range(
            (firstSize - 1) ... (firstSize - 1),
            from: firstURL,
            transport: transport
        )
        let secondFirstByte = try await range(
            0 ... 0,
            from: secondURL,
            transport: transport
        )

        XCTAssertEqual(firstLastByte.statusCode, 206)
        XCTAssertEqual(firstLastByte.data.count, 1)
        XCTAssertEqual(secondFirstByte.statusCode, 206)
        XCTAssertEqual(secondFirstByte.data.count, 1)

        try await coordinator.closePlaybackSession(
            accountID: accountID,
            server: server,
            sessionID: session.id
        )
    }

    private func verifyHLS<
        Transport: HTTPTransport,
        CredentialStore: AccountCredentialStore
    >(
        itemID: LibraryItemID,
        coordinator: AuthCoordinator<Transport, CredentialStore>,
        transport: LocalDockerHTTPTransport,
        store: LiveCredentialStore,
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws {
        let session = try await coordinator.openPlaybackSession(
            accountID: accountID,
            server: server,
            itemID: itemID,
            preference: .transcode,
            supportedMimeTypes: ["audio/mp4", "audio/mpeg"],
            deviceInfo: Self.deviceInfo(accountID)
        )
        XCTAssertEqual(session.method, .transcode)
        guard case let .hls(playlistURL) = try session.source(for: server) else {
            return XCTFail("Expected HLS playback")
        }
        try await assertTokenFree(
            playlistURL,
            store: store,
            accountID: accountID
        )

        let playlistResponse = try await transport.send(
            TracedHTTPRequest(
                request: URLRequest(url: playlistURL),
                endpoint: .directPlay
            )
        )
        XCTAssertEqual(playlistResponse.statusCode, 200)
        let playlist = String(decoding: playlistResponse.data, as: UTF8.self)
        let segments = playlist.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(segments.count, 2)
        XCTAssertTrue(
            segments.allSatisfy {
                !$0.hasPrefix("/") && URL(string: $0)?.scheme == nil
            }
        )

        let segmentURLs = try segments.map { segment in
            try XCTUnwrap(
                URL(string: segment, relativeTo: playlistURL)?.absoluteURL
            )
        }
        let firstSegment = try await waitForSuccess(
            at: try XCTUnwrap(segmentURLs.first),
            transport: transport
        )
        let soughtSegment = try await waitForSuccess(
            at: try XCTUnwrap(segmentURLs.last),
            transport: transport
        )
        XCTAssertEqual(firstSegment.statusCode, 200)
        XCTAssertFalse(firstSegment.data.isEmpty)
        XCTAssertEqual(soughtSegment.statusCode, 200)
        XCTAssertFalse(soughtSegment.data.isEmpty)

        try await coordinator.closePlaybackSession(
            accountID: accountID,
            server: server,
            sessionID: session.id
        )
        let closedPlaylist = try await transport.send(
            TracedHTTPRequest(
                request: URLRequest(url: playlistURL),
                endpoint: .directPlay
            )
        )
        let closedSegment = try await transport.send(
            TracedHTTPRequest(
                request: URLRequest(url: try XCTUnwrap(segmentURLs.first)),
                endpoint: .directPlay
            )
        )
        XCTAssertEqual(closedPlaylist.statusCode, 404)
        XCTAssertEqual(closedSegment.statusCode, 404)
    }

    private func waitForSuccess(
        at url: URL,
        transport: LocalDockerHTTPTransport
    ) async throws -> HTTPResponse {
        var lastResponse: HTTPResponse?
        for _ in 0 ..< 100 {
            let response = try await transport.send(
                TracedHTTPRequest(
                    request: URLRequest(url: url),
                    endpoint: .directPlay
                )
            )
            if response.statusCode == 200 {
                return response
            }
            lastResponse = response
            try await Task.sleep(for: .milliseconds(50))
        }
        return try XCTUnwrap(lastResponse)
    }

    private func range(
        _ requestedRange: ClosedRange<Int>,
        from url: URL,
        transport: LocalDockerHTTPTransport
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.setValue(
            "bytes=\(requestedRange.lowerBound)-\(requestedRange.upperBound)",
            forHTTPHeaderField: "Range"
        )
        return try await transport.send(
            TracedHTTPRequest(request: request, endpoint: .directPlay)
        )
    }

    private func totalSize(from response: HTTPResponse) throws -> Int {
        XCTAssertEqual(response.statusCode, 206)
        let contentRange = try XCTUnwrap(
            response.header(named: "Content-Range")
        )
        let totalText = try XCTUnwrap(contentRange.split(separator: "/").last)
        return try XCTUnwrap(Int(totalText))
    }

    private func assertTokenFree(
        _ url: URL,
        store: LiveCredentialStore,
        accountID: AccountID
    ) async throws {
        let storedCredentials = await store.credentials(for: accountID)
        let tokens = try XCTUnwrap(storedCredentials)
        XCTAssertNil(url.query)
        XCTAssertFalse(url.absoluteString.contains(tokens.accessToken))
        XCTAssertFalse(url.absoluteString.contains(tokens.refreshToken))
    }

    private static func deviceInfo(
        _ accountID: AccountID
    ) -> PlaybackDeviceInfo {
        PlaybackDeviceInfo(
            deviceID: "bleat-live-\(accountID.rawValue)",
            clientName: "Bleat",
            clientVersion: "0.1.0",
            manufacturer: "Apple",
            model: "Live Contract Test"
        )
    }
}

private struct LiveLibrariesResponse: Decodable {
    let libraries: [LiveLibrary]
}

private struct LiveLibrary: Decodable {
    let id: LibraryID
    let name: String
}

private struct LiveLibraryItemsResponse: Decodable {
    let results: [LiveLibraryItem]
    let total: Int
}

private struct LiveLibraryItem: Decodable {
    let id: LibraryItemID
    let path: String
}
