import Foundation
import XCTest

@testable import BleatCore

final class BackgroundDownloadTests: XCTestCase {
    func testCancelledTrackMakesIncompleteBookDurablyCancelled() throws {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "track-0",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                )
            ]
        )
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "download"),
            accountID: AccountID(rawValue: "account"),
            plan: plan
        )

        try manifest.markDownloading(trackIndex: 0)
        try manifest.markCancelled(trackIndex: 0)

        XCTAssertEqual(manifest.state, .cancelled)
        XCTAssertEqual(manifest.entries[0].state, .cancelled)
        XCTAssertNil(manifest.entries[0].observedByteLength)
    }

    func testRetryQueuesEveryCancelledTrackBeforeBoundedHandoff() throws {
        let tracks = (0..<3).map { index in
            DownloadTrackPlan(
                index: index,
                inode: "track-\(index)",
                expectedByteLength: 10,
                mimeType: "audio/mpeg",
                safeExtension: .mp3,
                destinationEntry: String(format: "%05d.mp3", index)
            )
        }
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "download"),
            accountID: AccountID(rawValue: "account"),
            plan: DownloadPlan(
                itemID: LibraryItemID(rawValue: "item"),
                tracks: tracks
            )
        )
        try manifest.markDownloading(trackIndex: 0)
        try manifest.markComplete(
            trackIndex: 0,
            observedByteLength: 10,
            placement: .finalized
        )
        try manifest.markCancelled(trackIndex: 1)
        try manifest.markCancelled(trackIndex: 2)

        manifest.prepareCancelledRetry()

        XCTAssertEqual(manifest.state, .queued)
        XCTAssertEqual(
            manifest.entries.map(\.state),
            [.complete, .queued, .queued]
        )

        try manifest.markDownloading(trackIndex: 1)
        try manifest.markComplete(
            trackIndex: 1,
            observedByteLength: 10,
            placement: .finalized
        )

        XCTAssertEqual(manifest.state, .queued)
        XCTAssertEqual(manifest.entries[2].state, .queued)
    }

    func testFailedTrackDoesNotFailBookWhileAnotherTrackIsDownloading()
        throws
    {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "track-0",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                ),
                DownloadTrackPlan(
                    index: 1,
                    inode: "track-1",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00001.mp3"
                ),
            ]
        )
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "download"),
            accountID: AccountID(rawValue: "account"),
            plan: plan
        )
        try manifest.markDownloading(trackIndex: 1)

        try manifest.markFailed(trackIndex: 0)

        XCTAssertEqual(manifest.entries[0].state, .failed)
        XCTAssertEqual(manifest.entries[1].state, .downloading)
        XCTAssertEqual(manifest.state, .downloading)

        try manifest.markFailed(trackIndex: 1)
        XCTAssertEqual(manifest.state, .failed)
    }

    func testRangeChunksBuildBoundedHeadersAndValidateResponses() throws {
        let first = try XCTUnwrap(
            DownloadByteRange.next(
                committedByteLength: 0,
                expectedByteLength: 20,
                chunkByteLength: 16
            )
        )
        let final = try XCTUnwrap(
            DownloadByteRange.next(
                committedByteLength: 16,
                expectedByteLength: 20,
                chunkByteLength: 16
            )
        )
        let validator = DownloadValidator.strongETag("\"version-1\"")
        let request = DownloadRangeRequest.applying(
            range: final,
            validator: validator,
            to: URLRequest(url: URL(string: "https://example.com/file")!)
        )

        XCTAssertEqual(first, try DownloadByteRange(start: 0, endInclusive: 15))
        XCTAssertEqual(
            final, try DownloadByteRange(start: 16, endInclusive: 19))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Range"), "bytes=16-19")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "If-Range"), "\"version-1\"")
        XCTAssertNoThrow(
            try DownloadRangeResponseValidator.validate(
                statusCode: 206,
                contentRangeHeader: "bytes 16-19/20",
                requestedRange: final,
                expectedTotalByteLength: 20
            )
        )
        XCTAssertThrowsError(
            try DownloadRangeResponseValidator.validate(
                statusCode: 206,
                contentRangeHeader: "bytes 18-19/20",
                requestedRange: final,
                expectedTotalByteLength: 20
            )
        ) { error in
            XCTAssertEqual(error as? DownloadRangeError, .mismatchedContentRange)
        }
        XCTAssertThrowsError(
            try DownloadRangeResponseValidator.validate(
                statusCode: 200,
                contentRangeHeader: nil,
                requestedRange: final,
                expectedTotalByteLength: 20
            )
        ) { error in
            XCTAssertEqual(error as? DownloadRangeError, .unexpectedStatus(200))
        }
    }

    func testChunkDescriptionRoundTripsWithoutCredentials() throws {
        let descriptor = DownloadChunkTaskDescription(
            identity: try Self.identity(),
            range: try DownloadByteRange(start: 0, endInclusive: 10),
            validator: .lastModified("Sat, 23 Aug 2026 12:00:00 GMT")
        )
        let encoded = try descriptor.encode()

        XCTAssertEqual(
            try DownloadChunkTaskDescription.decode(encoded), descriptor)
        XCTAssertEqual(
            try DownloadTaskIdentity.decodeTaskDescription(encoded),
            descriptor.identity
        )
        XCTAssertFalse(encoded.contains("access-token"))
        XCTAssertFalse(encoded.contains("example.com"))
    }

    func testChunkDescriptionRejectsSemanticallyInvalidIdentity() throws {
        let descriptor = DownloadChunkTaskDescription(
            identity: try Self.identity(),
            range: try DownloadByteRange(start: 0, endInclusive: 15),
            validator: nil
        )
        let encoded = try descriptor.encode()
        let payload = String(
            encoded.dropFirst(DownloadChunkTaskDescription.prefix.count)
        )
        let data = try XCTUnwrap(Data(base64Encoded: payload))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        var identity = try XCTUnwrap(
            object["identity"] as? [String: Any]
        )
        identity["destinationEntry"] = "../escape.mp3"
        object["identity"] = identity
        let malformed =
            DownloadChunkTaskDescription.prefix
            + (try JSONSerialization.data(withJSONObject: object))
            .base64EncodedString()

        XCTAssertThrowsError(
            try DownloadChunkTaskDescription.decode(malformed)
        ) { error in
            XCTAssertEqual(error as? DownloadRangeError, .invalidRange)
        }
    }

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
        XCTAssertEqual(
            plan.tracks.map(\.startOffset),
            [0, 11, 33]
        )
        XCTAssertEqual(plan.tracks.map(\.duration), [11, 22, 33])
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
            "https://example.com/audiobookshelf"
        )
        let identity = try Self.identity(accountID: accountID)

        let request = try await coordinator.makeAuthorizedDownloadRequest(
            identity: identity,
            server: server
        )

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://example.com/audiobookshelf/api/items/item/file/101/download"
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
        let server = try NormalizedServerURL(
            "https://example.com/audiobookshelf"
        )
        let identity = try Self.identity(accountID: accountID)
        var rejectedRequest =
            try await authCoordinator
            .makeAuthorizedDownloadRequest(
                identity: identity,
                server: server
            )
        rejectedRequest.setValue(
            "bytes=16-31",
            forHTTPHeaderField: "Range"
        )
        rejectedRequest.setValue(
            "\"version-1\"",
            forHTTPHeaderField: "If-Range"
        )

        let replacementRequest =
            try await authCoordinator
            .makeReplacementDownloadRequest(
                identity: identity,
                server: server,
                rejectedRequest: rejectedRequest
            )

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
        XCTAssertEqual(
            replacementRequest.value(forHTTPHeaderField: "Range"),
            "bytes=16-31"
        )
        XCTAssertEqual(
            replacementRequest.value(forHTTPHeaderField: "If-Range"),
            "\"version-1\""
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
        let server = try NormalizedServerURL("https://example.com")
        let identity = try Self.identity(accountID: accountID)

        await XCTAssertThrowsErrorAsync(
            try await coordinator.makeReplacementDownloadRequest(
                identity: identity,
                server: server,
                rejectedRequest: URLRequest(
                    url: URL(string: "https://example.com/api/libraries")!
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
        var manifest = try DownloadManifest(
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
        var manifest = try DownloadManifest(
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
            bleatBackgroundDownloadMaximumConnectionsPerHost,
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
        Data(
            """
            {
              "id": "item",
              "media": {
                "audioFiles": [
                  {
                    "ino": "101",
                    "metadata": {"filename": "01.aac", "size": 11},
                    "mimeType": "audio/aac",
                    "duration": 11
                  },
                  {
                    "ino": "102",
                    "metadata": {"filename": "02.m4b", "size": 22},
                    "mimeType": "audio/mp4; charset=binary",
                    "duration": 22
                  },
                  {
                    "ino": "103",
                    "metadata": {"filename": "03.mp3", "size": 33},
                    "mimeType": "audio/mpeg",
                    "duration": 33
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

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) -> HTTPResponse {
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
        Data(
            """
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
