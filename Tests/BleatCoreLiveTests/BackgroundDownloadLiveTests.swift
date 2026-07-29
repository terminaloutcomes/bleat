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
            let registry = LiveDownloadTaskRegistry()
            let scheduler = LiveDownloadScheduler(registry: registry)
            let coordinator = DownloadCoordinator(
                scheduler: scheduler,
                authorizer: authCoordinator
            )
            let downloadID = DownloadID(
                rawValue: "\(accountID.rawValue)-\(itemOffset)"
            )
            let scheduled = try await coordinator.schedule(
                plan: plan,
                accountID: accountID,
                server: server,
                downloadID: downloadID
            )
            let requests = await registry.requests()

            XCTAssertEqual(scheduled.count, plan.tracks.count)
            XCTAssertEqual(requests.count, plan.tracks.count)
            var manifest = DownloadManifest(
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

                let response = try await transport.send(request)
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
            let unauthorized = try await transport.send(rejectedRequest)
            XCTAssertEqual(unauthorized.statusCode, 401)

            let replacement =
                try await coordinator
                .replaceUnauthorizedTask(
                    identity: scheduled[0].identity,
                    server: server,
                    rejectedRequest: rejectedRequest
                )
            let requestsAfterReplacement = await registry.requests()
            let replacementRequest = try XCTUnwrap(
                requestsAfterReplacement.last
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
            XCTAssertEqual(replacement.identity, scheduled[0].identity)
            let replacementResponse = try await transport.send(
                replacementRequest
            )
            XCTAssertEqual(replacementResponse.statusCode, 200)
            XCTAssertEqual(
                Int64(replacementResponse.data.count),
                plan.tracks[0].expectedByteLength
            )

            let relaunchedCoordinator = DownloadCoordinator(
                scheduler: LiveDownloadScheduler(registry: registry),
                authorizer: authCoordinator
            )
            let restored = await relaunchedCoordinator.restoreTasks()
            XCTAssertEqual(restored.count, scheduled.count + 1)
            XCTAssertTrue(
                restored.allSatisfy {
                    guard case .restored(let identity) = $0.state else {
                        return false
                    }
                    return identity.accountID == accountID
                        && identity.itemID == itemID
                        && identity.downloadID == downloadID
                })
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

private actor LiveDownloadTaskRegistry {
    private var snapshots: [BackgroundDownloadTaskSnapshot] = []
    private var recordedRequests: [URLRequest] = []
    private var nextIdentifier = 1

    func schedule(
        request: URLRequest,
        taskDescription: String
    ) -> Int {
        let identifier = nextIdentifier
        nextIdentifier += 1
        recordedRequests.append(request)
        snapshots.append(
            .init(
                taskIdentifier: identifier,
                taskDescription: taskDescription,
                originalRequest: request
            ))
        return identifier
    }

    func taskSnapshots() -> [BackgroundDownloadTaskSnapshot] {
        snapshots
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private struct LiveDownloadScheduler: BackgroundDownloadScheduling {
    let registry: LiveDownloadTaskRegistry

    func schedule(
        request: URLRequest,
        taskDescription: String
    ) async -> Int {
        await registry.schedule(
            request: request,
            taskDescription: taskDescription
        )
    }

    func taskSnapshots() async -> [BackgroundDownloadTaskSnapshot] {
        await registry.taskSnapshots()
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
