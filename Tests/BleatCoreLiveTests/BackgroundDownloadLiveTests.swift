import Foundation
import XCTest

@testable import BleatCore

final class BackgroundDownloadLiveTests: XCTestCase {
    func testPinnedRootAndPrefixPerFileDownloadContracts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live download data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            try await verifyDownloadContracts(
                server: secureLiveServerURL(for: liveURL),
                accountID: AccountID(rawValue: "download-\(index)"),
                username: username,
                password: password
            )
        }
    }

    private func verifyDownloadContracts(
        server: NormalizedServerURL,
        accountID: AccountID,
        username: String,
        password: String
    ) async throws {
        let store = LiveCredentialStore()
        let transport = LocalDockerHTTPTransport()
        let authCoordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        _ = try await authCoordinator.login(
            accountID: accountID,
            server: server,
            username: username,
            password: password
        )

        let itemIDs = try await seededItemIDs(
            coordinator: authCoordinator,
            accountID: accountID,
            server: server
        )
        XCTAssertEqual(itemIDs.count, 3)

        for (itemOffset, itemID) in itemIDs.enumerated() {
            let plan = try await authCoordinator.downloadPlan(
                accountID: accountID,
                server: server,
                itemID: itemID
            )
            let downloadID = DownloadID(
                rawValue: "\(accountID.rawValue)-\(itemOffset)"
            )
            var identities: [DownloadTaskIdentity] = []
            var requests: [URLRequest] = []
            for track in plan.tracks {
                let identity = try DownloadTaskIdentity(
                    downloadID: downloadID,
                    accountID: accountID,
                    itemID: itemID,
                    track: track
                )
                identities.append(identity)
                requests.append(
                    try await authCoordinator.makeAuthorizedDownloadRequest(
                        identity: identity,
                        server: server
                    )
                )
            }

            XCTAssertEqual(identities.count, plan.tracks.count)
            XCTAssertEqual(requests.count, plan.tracks.count)
            var manifest = try DownloadManifest(
                downloadID: downloadID,
                accountID: accountID,
                plan: plan
            )
            for (track, request) in zip(plan.tracks, requests) {
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNotNil(
                    request.value(forHTTPHeaderField: "Authorization")
                )
                XCTAssertNil(request.url?.query)
                XCTAssertEqual(
                    request.url,
                    try AudiobookshelfRouteBuilder(server: server).url(
                        for: .downloadFile(
                            itemID: itemID,
                            inode: track.inode
                        )
                    )
                )

                let response = try await transport.send(
                    TracedHTTPRequest(
                        request: request,
                        endpoint: .downloadFile
                    )
                )
                XCTAssertEqual(response.statusCode, 200)
                XCTAssertEqual(
                    Int64(response.data.count),
                    track.expectedByteLength
                )
                try manifest.markComplete(
                    trackIndex: track.index,
                    observedByteLength: Int64(response.data.count),
                    placement: .finalized
                )
            }
            try manifest.finish()
            XCTAssertEqual(manifest.state, .complete)

            let firstRequest = try XCTUnwrap(requests.first)
            var rejectedRequest = firstRequest
            rejectedRequest.setValue(
                "Bearer expired-live-token",
                forHTTPHeaderField: "Authorization"
            )
            let unauthorized = try await transport.send(
                TracedHTTPRequest(
                    request: rejectedRequest,
                    endpoint: .downloadFile
                )
            )
            XCTAssertEqual(unauthorized.statusCode, 401)

            let replacementRequest =
                try await authCoordinator
                .makeReplacementDownloadRequest(
                    identity: identities[0],
                    server: server,
                    rejectedRequest: rejectedRequest
                )
            XCTAssertNotEqual(
                replacementRequest.value(
                    forHTTPHeaderField: "Authorization"
                ),
                rejectedRequest.value(
                    forHTTPHeaderField: "Authorization"
                )
            )
            XCTAssertNil(replacementRequest.url?.query)
            let replacementResponse = try await transport.send(
                TracedHTTPRequest(
                    request: replacementRequest,
                    endpoint: .downloadFile
                )
            )
            XCTAssertEqual(replacementResponse.statusCode, 200)
            XCTAssertEqual(
                Int64(replacementResponse.data.count),
                plan.tracks[0].expectedByteLength
            )

        }
    }

    private func seededItemIDs<
        Transport: HTTPTransport,
        CredentialStore: AccountCredentialStore
    >(
        coordinator: AuthCoordinator<Transport, CredentialStore>,
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws -> [LibraryItemID] {
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
            DownloadLiveLibrariesResponse.self,
            from: librariesResponse.data
        )
        let library = try XCTUnwrap(
            libraries.libraries.first {
                $0.name == "Bleat Live Fixtures"
            }
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
            DownloadLiveItemsResponse.self,
            from: itemsResponse.data
        )
        return items.results.map(\.id)
    }

}

private struct DownloadLiveLibrariesResponse: Decodable {
    let libraries: [DownloadLiveLibrary]
}

private struct DownloadLiveLibrary: Decodable {
    let id: LibraryID
    let name: String
}

private struct DownloadLiveItemsResponse: Decodable {
    let results: [DownloadLiveItem]
}

private struct DownloadLiveItem: Decodable {
    let id: LibraryItemID
}
