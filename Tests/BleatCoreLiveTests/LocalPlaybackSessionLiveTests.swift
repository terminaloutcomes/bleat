import Foundation
import XCTest

@testable import BleatCore

final class LocalPlaybackSessionLiveTests: XCTestCase {
    func testPinnedRootAndPrefixImportOneIdempotentLocalSession()
        async throws
    {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide local session data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            try await verifyLocalSessionImport(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "local-session-\(index)"),
                username: username,
                password: password
            )
        }
    }

    private func verifyLocalSessionImport(
        server: NormalizedServerURL,
        accountID: AccountID,
        username: String,
        password: String
    ) async throws {
        let store = LiveCredentialStore()
        let coordinator = AuthCoordinator(
            transport: LocalDockerHTTPTransport(),
            credentialStore: store
        )
        let authenticated = try await coordinator.login(
            accountID: accountID,
            server: server,
            username: username,
            password: password
        )
        let account = try ServerAccount(
            id: accountID,
            server: server,
            serverVersion: "2.36.0",
            authenticationMethods: [.local],
            user: authenticated.user
        )
        let api = AudiobookshelfAPI(
            account: account,
            authCoordinator: coordinator
        )
        let libraries = try await api.libraries().value
        let library = try XCTUnwrap(
            libraries.first {
                $0.mediaType == .book
            }
        )
        let page = try await api.libraryItems(
            in: library.id,
            request: try LibraryItemsPageRequest(page: 0)
        ).value
        let item = try XCTUnwrap(
            page.items.first
        )
        let detail = try await api.bookDetail(
            for: item.id,
            in: library.id
        ).value
        let initialPosition = min(1, detail.duration)
        let initial = try LocalPlaybackSession.makeBookSession(
            libraryID: detail.libraryID,
            libraryItemID: detail.id,
            bookID: detail.bookID,
            title: detail.title,
            author: detail.authors.map(\.name).joined(separator: ", "),
            chapters: detail.chapters,
            duration: detail.duration,
            currentTime: initialPosition
        )
        let deviceInfo = PlaybackDeviceInfo(
            deviceID: "bleat-live-\(accountID.rawValue)",
            clientName: "Bleat",
            clientVersion: "0.1.0",
            manufacturer: "Apple",
            model: "Live Contract Test"
        )

        let first = try await coordinator.syncLocalPlaybackSessions(
            accountID: accountID,
            server: server,
            sessions: [initial],
            deviceInfo: deviceInfo
        )
        XCTAssertEqual(first.map(\.id), [initial.id])
        XCTAssertTrue(first.allSatisfy(\.success))

        let finalPosition = min(initialPosition + 1, detail.duration)
        let updated = try initial.updating(
            currentTime: finalPosition,
            now: Date().addingTimeInterval(1)
        )
        let second = try await coordinator.syncLocalPlaybackSessions(
            accountID: accountID,
            server: server,
            sessions: [updated],
            deviceInfo: deviceInfo
        )
        XCTAssertEqual(second.map(\.id), [initial.id])
        XCTAssertTrue(second.allSatisfy(\.success))

        let imported = try await importedSessions(
            coordinator: coordinator,
            accountID: accountID,
            server: server
        ).filter { $0.id == initial.id }
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported[0].currentTime, finalPosition, accuracy: 0.01)
        XCTAssertEqual(imported[0].timeListening ?? 0, 0)
    }

    private func importedSessions<
        Transport: HTTPTransport,
        CredentialStore: AccountCredentialStore
    >(
        coordinator: AuthCoordinator<Transport, CredentialStore>,
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws -> [ImportedLocalSession] {
        let route = AudiobookshelfRoute.listeningSessions
        var components = try XCTUnwrap(
            URLComponents(
                url: try AudiobookshelfRouteBuilder(server: server)
                    .url(for: route),
                resolvingAgainstBaseURL: false
            )
        )
        components.queryItems = [
            URLQueryItem(name: "itemsPerPage", value: "100"),
            URLQueryItem(name: "page", value: "0"),
        ]
        var request = URLRequest(url: try XCTUnwrap(components.url))
        request.httpMethod = "GET"
        let response = try await coordinator.sendAuthenticated(
            request,
            route: route,
            accountID: accountID,
            server: server
        )
        XCTAssertEqual(response.statusCode, 200)
        return try JSONDecoder().decode(
            ImportedLocalSessionPage.self,
            from: response.data
        ).sessions
    }
}

private struct ImportedLocalSessionPage: Decodable {
    let sessions: [ImportedLocalSession]
}

private struct ImportedLocalSession: Decodable {
    let id: PlaybackSessionID
    let currentTime: Double
    let timeListening: Double?
}
