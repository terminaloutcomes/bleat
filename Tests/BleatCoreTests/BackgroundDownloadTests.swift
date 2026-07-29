import Foundation
import XCTest

@testable import BleatCore

final class BackgroundDownloadTests: XCTestCase {
    func testExpandedItemBuildsSafeOrderedPerFilePlan() throws {
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Self.expandedItemJSON()
        )

        XCTAssertEqual(plan.itemID.rawValue, "item")
        XCTAssertEqual(plan.tracks.map(\.index), [0, 1, 2])
        XCTAssertEqual(plan.tracks.map(\.inode), ["101", "102", "103"])
        XCTAssertEqual(
            plan.tracks.map(\.expectedByteLength),
            [11, 22, 33]
        )
        XCTAssertEqual(
            plan.tracks.map(\.destinationEntry),
            ["00000.aac", "00001.m4b", "00002.mp3"]
        )
        XCTAssertEqual(
            plan.tracks.map(\.safeExtension),
            [.aac, .m4b, .mp3]
        )
    }

    func testExpandedItemRejectsUnsafeOrUnexpectedFiles() {
        let cases: [(String, DownloadPlanError)] = [
            (
                Self.singleTrackJSON(
                    filename: "../book.mp3",
                    mimeType: "audio/mpeg"
                ),
                .unsafeFilename(trackIndex: 0)
            ),
            (
                Self.singleTrackJSON(
                    filename: "book.exe",
                    mimeType: "application/octet-stream"
                ),
                .unsupportedMediaType(
                    trackIndex: 0,
                    mimeType: "application/octet-stream"
                )
            ),
            (
                Self.singleTrackJSON(
                    filename: "book.mp3",
                    mimeType: "audio/mp4"
                ),
                .incompatibleExtension(
                    trackIndex: 0,
                    mimeType: "audio/mp4"
                )
            ),
        ]

        for (json, expectedError) in cases {
            XCTAssertThrowsError(
                try DownloadPlan.decodeExpandedItem(from: Data(json.utf8))
            ) { error in
                XCTAssertEqual(error as? DownloadPlanError, expectedError)
            }
        }
    }

    func testTaskDescriptionRoundTripsWithoutSecretsOrServerURL() throws {
        let identity = try Self.identity()
        let description = try identity.taskDescription()
        let restored = try DownloadTaskIdentity.decodeTaskDescription(
            description
        )

        XCTAssertEqual(restored, identity)
        XCTAssertTrue(
            description.hasPrefix(
                DownloadTaskIdentity.taskDescriptionPrefix
            )
        )
        XCTAssertFalse(description.contains("access-token"))
        XCTAssertFalse(description.contains("example.net"))
    }

    func testCoordinatorRestoresMappingsAcrossInstances() async throws {
        let registry = DownloadTaskRegistry()
        let schedulerBeforeTermination = TestDownloadScheduler(
            registry: registry
        )
        let authorizer = StaticDownloadAuthorizer()
        let firstCoordinator = DownloadCoordinator(
            scheduler: schedulerBeforeTermination,
            authorizer: authorizer
        )
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Self.expandedItemJSON()
        )
        let accountID = AccountID(rawValue: "account")
        let downloadID = DownloadID(rawValue: "download")
        let server = try NormalizedServerURL(
            "https://example.net/audiobookshelf"
        )

        let scheduled = try await firstCoordinator.schedule(
            plan: plan,
            accountID: accountID,
            server: server,
            downloadID: downloadID
        )

        let schedulerAfterRelaunch = TestDownloadScheduler(
            registry: registry
        )
        let relaunchedCoordinator = DownloadCoordinator(
            scheduler: schedulerAfterRelaunch,
            authorizer: authorizer
        )
        let restored = await relaunchedCoordinator.restoreTasks()

        XCTAssertEqual(scheduled.count, 3)
        XCTAssertEqual(
            restored,
            scheduled.map {
                RestoredDownloadTask(
                    taskIdentifier: $0.systemTaskIdentifier,
                    state: .restored($0.identity)
                )
            }
        )
        let requests = await registry.requests()
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization")
                == "Bearer static-access"
        })
        XCTAssertTrue(requests.allSatisfy { $0.url?.query == nil })
    }

    func testRestorationReportsMissingAndInvalidDescriptions() async {
        let registry = DownloadTaskRegistry(snapshots: [
            .init(
                taskIdentifier: 4,
                taskDescription: nil,
                originalRequest: nil
            ),
            .init(
                taskIdentifier: 5,
                taskDescription: "not-a-bleat-task",
                originalRequest: nil
            ),
        ])
        let coordinator = DownloadCoordinator(
            scheduler: TestDownloadScheduler(registry: registry),
            authorizer: StaticDownloadAuthorizer()
        )

        let restored = await coordinator.restoreTasks()

        XCTAssertEqual(
            restored,
            [
                .init(taskIdentifier: 4, state: .missingDescription),
                .init(taskIdentifier: 5, state: .invalidDescription),
            ]
        )
    }

    func testDownloadRequestUsesExactRouteAndBearerHeader() async throws {
        let accountID = AccountID(rawValue: "account")
        let tokens = try AuthenticationTokens(
            accessToken: "access-token",
            refreshToken: "refresh-token"
        )
        let store = DownloadCredentialStore(
            credentials: [accountID: tokens]
        )
        let coordinator = AuthCoordinator(
            transport: DownloadRefreshTransport(),
            credentialStore: store
        )
        let server = try NormalizedServerURL(
            "https://example.net/audiobookshelf"
        )
        let identity = try Self.identity(accountID: accountID)

        let request = try await coordinator.makeAuthorizedDownloadRequest(
            identity: identity,
            server: server
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.net/audiobookshelf/api/items/item/file/101/download"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-token"
        )
        XCTAssertNil(request.url?.query)
    }

    func testUnauthorizedTaskGetsNewRequestAfterSingleFlightRefresh()
        async throws
    {
        let accountID = AccountID(rawValue: "account")
        let oldTokens = try AuthenticationTokens(
            accessToken: "old-access",
            refreshToken: "old-refresh"
        )
        let store = DownloadCredentialStore(
            credentials: [accountID: oldTokens]
        )
        let transport = DownloadRefreshTransport()
        let authCoordinator = AuthCoordinator(
            transport: transport,
            credentialStore: store
        )
        let registry = DownloadTaskRegistry()
        let coordinator = DownloadCoordinator(
            scheduler: TestDownloadScheduler(registry: registry),
            authorizer: authCoordinator
        )
        let server = try NormalizedServerURL(
            "https://example.net/audiobookshelf"
        )
        let identity = try Self.identity(accountID: accountID)
        let rejectedRequest = try await authCoordinator
            .makeAuthorizedDownloadRequest(
                identity: identity,
                server: server
            )

        let replacement = try await coordinator.replaceUnauthorizedTask(
            identity: identity,
            server: server,
            rejectedRequest: rejectedRequest
        )
        let requests = await registry.requests()
        let replacementRequest = try XCTUnwrap(requests.last)

        XCTAssertEqual(replacement.identity, identity)
        XCTAssertEqual(
            replacementRequest.value(
                forHTTPHeaderField: "Authorization"
            ),
            "Bearer new-access"
        )
        XCTAssertNotEqual(
            replacementRequest.value(
                forHTTPHeaderField: "Authorization"
            ),
            rejectedRequest.value(forHTTPHeaderField: "Authorization")
        )
        XCTAssertNil(replacementRequest.url?.query)
        let refreshCount = await transport.refreshCount()
        XCTAssertEqual(refreshCount, 1)
    }

    func testReplacementRejectsWrongRouteAndMissingBearer() async throws {
        let accountID = AccountID(rawValue: "account")
        let tokens = try AuthenticationTokens(
            accessToken: "access",
            refreshToken: "refresh"
        )
        let coordinator = AuthCoordinator(
            transport: DownloadRefreshTransport(),
            credentialStore: DownloadCredentialStore(
                credentials: [accountID: tokens]
            )
        )
        let server = try NormalizedServerURL("https://example.net")
        let identity = try Self.identity(accountID: accountID)

        await XCTAssertThrowsErrorAsync(
            try await coordinator.makeReplacementDownloadRequest(
                identity: identity,
                server: server,
                rejectedRequest: URLRequest(
                    url: URL(string: "https://example.net/api/libraries")!
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadAuthorizationError,
                .rejectedRequestDoesNotMatchDownload
            )
        }

        let correctURL = try AudiobookshelfRouteBuilder(server: server)
            .url(for: .downloadFile(itemID: identity.itemID, inode: "101"))
        await XCTAssertThrowsErrorAsync(
            try await coordinator.makeReplacementDownloadRequest(
                identity: identity,
                server: server,
                rejectedRequest: URLRequest(url: correctURL)
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadAuthorizationError,
                .missingRejectedAuthorization
            )
        }
    }

    func testManifestCannotCompletePartialTemporaryOrWrongLengthTrack()
        throws
    {
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.singleTrackJSON().utf8)
        )
        var manifest = DownloadManifest(
            downloadID: DownloadID(rawValue: "download"),
            accountID: AccountID(rawValue: "account"),
            plan: plan
        )

        XCTAssertThrowsError(try manifest.finish()) { error in
            XCTAssertEqual(
                error as? DownloadManifestError,
                .incompleteTrack(0)
            )
        }
        XCTAssertThrowsError(
            try manifest.markComplete(
                trackIndex: 0,
                observedByteLength: 10,
                placement: .temporary
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadManifestError,
                .trackNotFinalized(0)
            )
        }
        XCTAssertThrowsError(
            try manifest.markComplete(
                trackIndex: 0,
                observedByteLength: 9,
                placement: .finalized
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadManifestError,
                .byteLengthMismatch(
                    trackIndex: 0,
                    expected: 10,
                    observed: 9
                )
            )
        }

        try manifest.markComplete(
            trackIndex: 0,
            observedByteLength: 10,
            placement: .finalized
        )
        try manifest.finish()
        XCTAssertEqual(manifest.state, .complete)
    }

    func testDecoderRejectsCompleteManifestPointingAtPartialFile()
        throws
    {
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.singleTrackJSON().utf8)
        )
        var manifest = DownloadManifest(
            downloadID: DownloadID(rawValue: "download"),
            accountID: AccountID(rawValue: "account"),
            plan: plan
        )
        try manifest.markPartial(
            trackIndex: 0,
            observedByteLength: 5,
            placement: .temporary
        )
        let data = try JSONEncoder().encode(manifest)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["state"] = "complete"
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DownloadManifest.self,
                from: corrupted
            )
        )
    }

    func testBackgroundSessionContractIsStableAndBounded() {
        XCTAssertEqual(
            bleatBackgroundDownloadSessionIdentifier,
            "app.bleat.background-downloads.v1"
        )
        XCTAssertEqual(
            SystemBackgroundDownloadScheduler
                .defaultMaximumConnectionsPerHost,
            3
        )
    }

    private static func identity(
        accountID: AccountID = AccountID(rawValue: "account")
    ) throws -> DownloadTaskIdentity {
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(singleTrackJSON(size: 11).utf8)
        )
        return try DownloadTaskIdentity(
            downloadID: DownloadID(rawValue: "download"),
            accountID: accountID,
            itemID: plan.itemID,
            track: plan.tracks[0]
        )
    }

    private static func expandedItemJSON() -> Data {
        Data("""
        {
          "id": "item",
          "media": {
            "audioFiles": [
              {
                "ino": "101",
                "metadata": {"filename": "01.aac", "size": 11},
                "mimeType": "audio/aac"
              },
              {
                "ino": "102",
                "metadata": {"filename": "02.m4b", "size": 22},
                "mimeType": "audio/mp4; charset=binary"
              },
              {
                "ino": "103",
                "metadata": {"filename": "03.mp3", "size": 33},
                "mimeType": "audio/mpeg"
              }
            ]
          }
        }
        """.utf8)
    }

    private static func singleTrackJSON(
        filename: String = "book.mp3",
        size: Int64 = 10,
        mimeType: String = "audio/mpeg"
    ) -> String {
        """
        {
          "id": "item",
          "media": {
            "audioFiles": [{
              "ino": "101",
              "metadata": {
                "filename": "\(filename)",
                "size": \(size)
              },
              "mimeType": "\(mimeType)"
            }]
          }
        }
        """
    }
}

private actor DownloadTaskRegistry {
    private var storedSnapshots: [BackgroundDownloadTaskSnapshot]
    private var recordedRequests: [URLRequest] = []
    private var nextIdentifier = 1

    init(snapshots: [BackgroundDownloadTaskSnapshot] = []) {
        storedSnapshots = snapshots
    }

    func schedule(
        request: URLRequest,
        taskDescription: String
    ) -> Int {
        let identifier = nextIdentifier
        nextIdentifier += 1
        recordedRequests.append(request)
        storedSnapshots.append(.init(
            taskIdentifier: identifier,
            taskDescription: taskDescription,
            originalRequest: request
        ))
        return identifier
    }

    func snapshots() -> [BackgroundDownloadTaskSnapshot] {
        storedSnapshots
    }

    func requests() -> [URLRequest] {
        recordedRequests
    }
}

private struct TestDownloadScheduler: BackgroundDownloadScheduling {
    let registry: DownloadTaskRegistry

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
        await registry.snapshots()
    }
}

private struct StaticDownloadAuthorizer: DownloadRequestAuthorizing {
    func makeAuthorizedDownloadRequest(
        identity: DownloadTaskIdentity,
        server: NormalizedServerURL
    ) throws -> URLRequest {
        let url = try AudiobookshelfRouteBuilder(server: server).url(
            for: .downloadFile(
                itemID: identity.itemID,
                inode: identity.inode
            )
        )
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            "Bearer static-access",
            forHTTPHeaderField: "Authorization"
        )
        return request
    }

    func makeReplacementDownloadRequest(
        identity: DownloadTaskIdentity,
        server: NormalizedServerURL,
        rejectedRequest _: URLRequest
    ) throws -> URLRequest {
        try makeAuthorizedDownloadRequest(identity: identity, server: server)
    }
}

private actor DownloadCredentialStore: AccountCredentialStore {
    private var stored: [AccountID: AuthenticationTokens]

    init(credentials: [AccountID: AuthenticationTokens]) {
        stored = credentials
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        stored[accountID]
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        stored[accountID] = credentials
    }

    func deleteCredentials(for accountID: AccountID) {
        stored[accountID] = nil
    }
}

private actor DownloadRefreshTransport: HTTPTransport {
    private var refreshRequests = 0

    func send(_ request: URLRequest) -> HTTPResponse {
        refreshRequests += 1
        return HTTPResponse(
            data: Self.refreshResponse(),
            statusCode: 200
        )
    }

    func refreshCount() -> Int {
        refreshRequests
    }

    private static func refreshResponse() -> Data {
        Data("""
        {
          "user": {
            "id": "user",
            "username": "reader",
            "type": "user",
            "permissions": {
              "download": true,
              "update": false,
              "delete": false,
              "upload": false,
              "createEreader": false,
              "accessAllLibraries": true,
              "accessAllTags": true,
              "accessExplicitContent": true,
              "selectedTagsNotAccessible": false
            },
            "librariesAccessible": [],
            "itemTagsSelected": [],
            "accessToken": "new-access",
            "refreshToken": "new-refresh"
          }
        }
        """.utf8)
    }
}
