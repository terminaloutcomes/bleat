import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class BackgroundDownloadTests {
    @Test
    func testMaximumConcurrentDownloadsTransitionsAndNormalization() throws {
        #expect(
            MaximumConcurrentDownloadsPreference.permittedValues == Array(1...5)
                + Array(stride(from: 10, through: 100, by: 5)))
        #expect(MaximumConcurrentDownloadsPreference(1).decremented.value == 1)
        #expect(!(MaximumConcurrentDownloadsPreference(1).canDecrement))
        #expect(MaximumConcurrentDownloadsPreference(4).incremented.value == 5)
        #expect(MaximumConcurrentDownloadsPreference(5).incremented.value == 10)
        #expect(MaximumConcurrentDownloadsPreference(10).decremented.value == 5)
        #expect(
            MaximumConcurrentDownloadsPreference(95).incremented.value == 100)
        #expect(
            MaximumConcurrentDownloadsPreference(100).incremented.value == 100)
        #expect(!(MaximumConcurrentDownloadsPreference(100).canIncrement))

        let expected = [
            -10: 1,
            0: 1,
            1: 1,
            6: 5,
            7: 5,
            8: 10,
            12: 10,
            13: 15,
            101: 100,
        ]
        for (input, normalized) in expected {
            #expect(
                MaximumConcurrentDownloadsPreference.normalize(input)
                    == normalized)
        }

        let suite = "MaximumConcurrentDownloadsPreference.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(
            MaximumConcurrentDownloadsPreference.load(from: defaults).value == 5
        )
        defaults.set(
            "invalid",
            forKey: MaximumConcurrentDownloadsPreference.defaultsKey
        )
        #expect(
            MaximumConcurrentDownloadsPreference.load(from: defaults).value == 5
        )
        #expect(
            defaults.integer(
                forKey: MaximumConcurrentDownloadsPreference.defaultsKey
            ) == 5)
        defaults.set(
            8,
            forKey: MaximumConcurrentDownloadsPreference.defaultsKey
        )
        #expect(
            MaximumConcurrentDownloadsPreference.load(from: defaults).value
                == 10)
        #expect(
            defaults.integer(
                forKey: MaximumConcurrentDownloadsPreference.defaultsKey
            ) == 10)
    }

    @Test
    func testAutomaticDownloadLookaheadTransitionsAndPersistence() throws {
        #expect(
            AutomaticDownloadLookaheadPreference.allCases == [
                .one, .three, .five, .ten, .all,
            ])
        #expect(AutomaticDownloadLookaheadPreference.one.decremented == .one)
        #expect(!(AutomaticDownloadLookaheadPreference.one.canDecrement))
        #expect(AutomaticDownloadLookaheadPreference.one.incremented == .three)
        #expect(AutomaticDownloadLookaheadPreference.ten.incremented == .all)
        #expect(AutomaticDownloadLookaheadPreference.all.decremented == .ten)
        #expect(!(AutomaticDownloadLookaheadPreference.all.canIncrement))
        #expect(AutomaticDownloadLookaheadPreference.all.label == "All")
        #expect(AutomaticDownloadLookaheadPreference.all.limitedCount == nil)
        let expected: [(Int, AutomaticDownloadLookaheadPreference)] = [
            (Int.min, .one), (-2, .one), (-1, .one), (0, .one),
            (1, .one), (2, .one), (3, .three), (4, .three),
            (5, .five), (6, .five), (7, .five), (8, .five), (9, .five),
            (10, .ten), (11, .all), (20, .all), (99, .all), (Int.max, .all),
        ]
        for (input, preference) in expected {
            #expect(
                AutomaticDownloadLookaheadPreference.normalize(input)
                    == preference, "Input: \(input)")
        }

        let suite =
            "AutomaticDownloadLookaheadPreference.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(
            AutomaticDownloadLookaheadPreference.load(from: defaults) == .five)
        for preference in AutomaticDownloadLookaheadPreference.allCases {
            defaults.set(
                preference.rawValue,
                forKey: AutomaticDownloadLookaheadPreference.defaultsKey
            )
            #expect(
                AutomaticDownloadLookaheadPreference.load(from: defaults)
                    == preference)
        }
        defaults.set(
            true, forKey: AutomaticDownloadLookaheadPreference.defaultsKey)
        #expect(
            AutomaticDownloadLookaheadPreference.load(from: defaults) == .five)
        defaults.set(
            0, forKey: AutomaticDownloadLookaheadPreference.defaultsKey)
        #expect(
            AutomaticDownloadLookaheadPreference.load(from: defaults) == .one)
        defaults.set(
            4,
            forKey: AutomaticDownloadLookaheadPreference.defaultsKey
        )
        #expect(
            AutomaticDownloadLookaheadPreference.load(from: defaults) == .three)
        #expect(
            defaults.integer(
                forKey: AutomaticDownloadLookaheadPreference.defaultsKey
            ) == 3)
    }

    @Test
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

        #expect(manifest.state == .cancelled)
        #expect(manifest.entries[0].state == .cancelled)
        #expect(manifest.entries[0].observedByteLength == nil)
    }

    @Test
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

        #expect(manifest.state == .queued)
        #expect(manifest.entries.map(\.state) == [.complete, .queued, .queued])

        try manifest.markDownloading(trackIndex: 1)
        try manifest.markComplete(
            trackIndex: 1,
            observedByteLength: 10,
            placement: .finalized
        )

        #expect(manifest.state == .queued)
        #expect(manifest.entries[2].state == .queued)
    }

    @Test
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

        #expect(manifest.entries[0].state == .failed)
        #expect(manifest.entries[1].state == .downloading)
        #expect(manifest.state == .downloading)

        try manifest.markFailed(trackIndex: 1)
        #expect(manifest.state == .failed)
    }

    @Test
    func testRangeChunksBuildBoundedHeadersAndValidateResponses() throws {
        let first = try #require(
            try DownloadByteRange.next(
                committedByteLength: 0,
                expectedByteLength: 20,
                chunkByteLength: 16
            ))
        let final = try #require(
            try DownloadByteRange.next(
                committedByteLength: 16,
                expectedByteLength: 20,
                chunkByteLength: 16
            ))
        let validator = DownloadValidator.strongETag("\"version-1\"")
        let request = DownloadRangeRequest.applying(
            range: final,
            validator: validator,
            to: URLRequest(url: URL(string: "https://example.com/file")!)
        )

        #expect(first == (try DownloadByteRange(start: 0, endInclusive: 15)))
        #expect(final == (try DownloadByteRange(start: 16, endInclusive: 19)))
        #expect(request.value(forHTTPHeaderField: "Range") == "bytes=16-19")
        #expect(
            request.value(forHTTPHeaderField: "If-Range") == "\"version-1\"")
        #expect(
            throws: Never.self,
            performing: {
                try DownloadRangeResponseValidator.validate(
                    statusCode: 206,
                    contentRangeHeader: "bytes 16-19/20",
                    requestedRange: final,
                    expectedTotalByteLength: 20
                )
            })
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try DownloadRangeResponseValidator.validate(
                    statusCode: 206,
                    contentRangeHeader: "bytes 18-19/20",
                    requestedRange: final,
                    expectedTotalByteLength: 20
                )
            })
        {
            #expect(error as? DownloadRangeError == .mismatchedContentRange)
        }
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try DownloadRangeResponseValidator.validate(
                    statusCode: 200,
                    contentRangeHeader: nil,
                    requestedRange: final,
                    expectedTotalByteLength: 20
                )
            })
        {
            #expect(error as? DownloadRangeError == .unexpectedStatus(200))
        }
    }

    @Test
    func testChunkDescriptionRoundTripsWithoutCredentials() throws {
        let descriptor = DownloadChunkTaskDescription(
            identity: try Self.identity(),
            range: try DownloadByteRange(start: 0, endInclusive: 10),
            validator: .lastModified("Sat, 23 Aug 2026 12:00:00 GMT")
        )
        let encoded = try descriptor.encode()

        #expect(try DownloadChunkTaskDescription.decode(encoded) == descriptor)
        #expect(
            try DownloadTaskIdentity.decodeTaskDescription(encoded)
                == descriptor.identity)
        #expect(!(encoded.contains("access-token")))
        #expect(!(encoded.contains("example.com")))
    }

    @Test
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
        let data = try #require(Data(base64Encoded: payload))
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var identity = try #require(object["identity"] as? [String: Any])
        identity["destinationEntry"] = "../escape.mp3"
        object["identity"] = identity
        let malformed =
            DownloadChunkTaskDescription.prefix
            + (try JSONSerialization.data(withJSONObject: object))
            .base64EncodedString()

        if let error = #expect(
            throws: (any Error).self,
            performing: { try DownloadChunkTaskDescription.decode(malformed) })
        {
            #expect(error as? DownloadRangeError == .invalidRange)
        }
    }

    @Test
    func testExpandedItemBuildsSafeOrderedPerFilePlan() throws {
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Self.expandedItemJSON()
        )

        #expect(plan.itemID.rawValue == "item")
        #expect(plan.tracks.map(\.index) == [0, 1, 2])
        #expect(plan.tracks.map(\.inode) == ["101", "102", "103"])
        #expect(plan.tracks.map(\.expectedByteLength) == [11, 22, 33])
        #expect(
            plan.tracks.map(\.destinationEntry) == [
                "00000.aac", "00001.m4b", "00002.mp3",
            ])
        #expect(plan.tracks.map(\.safeExtension) == [.aac, .m4b, .mp3])
        #expect(plan.tracks.map(\.startOffset) == [0, 11, 33])
        #expect(plan.tracks.map(\.duration) == [11, 22, 33])
    }

    @Test
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
            if let error = #expect(
                throws: (any Error).self,
                performing: {
                    try DownloadPlan.decodeExpandedItem(from: Data(json.utf8))
                })
            {
                #expect(error as? DownloadPlanError == expectedError)
            }
        }
    }

    @Test
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

        #expect(request.httpMethod == "GET")
        #expect(
            request.url?.absoluteString
                == "https://example.com/audiobookshelf/api/items/item/file/101/download"
        )
        #expect(
            request.value(forHTTPHeaderField: "Authorization")
                == "Bearer access-token")
        #expect(request.url?.query == nil)
    }

    @Test
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

        #expect(
            replacementRequest.value(
                forHTTPHeaderField: "Authorization"
            ) == "Bearer new-access")
        #expect(
            replacementRequest.value(
                forHTTPHeaderField: "Authorization"
            ) != rejectedRequest.value(forHTTPHeaderField: "Authorization"))
        #expect(
            replacementRequest.value(forHTTPHeaderField: "Range")
                == "bytes=16-31")
        #expect(
            replacementRequest.value(forHTTPHeaderField: "If-Range")
                == "\"version-1\"")
        #expect(replacementRequest.url?.query == nil)
        let refreshCount = await transport.refreshCount()
        #expect(refreshCount == 1)
    }

    @Test
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

        await assertThrowsErrorAsync(
            try await coordinator.makeReplacementDownloadRequest(
                identity: identity,
                server: server,
                rejectedRequest: URLRequest(
                    url: URL(string: "https://example.com/api/libraries")!
                )
            )
        ) { error in
            #expect(
                error as? DownloadAuthorizationError
                    == .rejectedRequestDoesNotMatchDownload)
        }

        let correctURL = try AudiobookshelfRouteBuilder(server: server)
            .url(for: .downloadFile(itemID: identity.itemID, inode: "101"))
        await assertThrowsErrorAsync(
            try await coordinator.makeReplacementDownloadRequest(
                identity: identity,
                server: server,
                rejectedRequest: URLRequest(url: correctURL)
            )
        ) { error in
            #expect(
                error as? DownloadAuthorizationError
                    == .missingRejectedAuthorization)
        }
    }

    @Test
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

        if let error = #expect(
            throws: (any Error).self, performing: { try manifest.finish() })
        {
            #expect(error as? DownloadManifestError == .incompleteTrack(0))
        }
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try manifest.markComplete(
                    trackIndex: 0,
                    observedByteLength: 10,
                    placement: .temporary
                )
            })
        {
            #expect(error as? DownloadManifestError == .trackNotFinalized(0))
        }
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try manifest.markComplete(
                    trackIndex: 0,
                    observedByteLength: 9,
                    placement: .finalized
                )
            })
        {
            #expect(
                error as? DownloadManifestError
                    == .byteLengthMismatch(
                        trackIndex: 0,
                        expected: 10,
                        observed: 9
                    ))
        }

        try manifest.markComplete(
            trackIndex: 0,
            observedByteLength: 10,
            placement: .finalized
        )
        try manifest.finish()
        #expect(manifest.state == .complete)
    }

    @Test
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
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["state"] = "complete"
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        #expect(
            throws: (any Error).self,
            performing: {
                try JSONDecoder().decode(
                    DownloadManifest.self,
                    from: corrupted
                )
            })
    }

    @Test
    func testBackgroundSessionContractIsStableAndBounded() {
        #expect(
            bleatBackgroundDownloadSessionIdentifier
                == "app.bleat.background-downloads.v1")
        #expect(bleatBackgroundDownloadMaximumConnectionsPerHost == 100)
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
