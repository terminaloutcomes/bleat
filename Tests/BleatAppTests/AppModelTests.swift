import AVFoundation
import BleatCore
import XCTest

@testable import Bleat

@MainActor
final class AppModelTests: XCTestCase {
    func
        testAutomaticDownloadWaitsForStablePlaybackAndReservesBandwidthAgainOnStall()
    {
        var gate = AutomaticDownloadPlaybackGate()

        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: false,
                timeControlStatus: .paused,
                now: 0
            ),
            .allowAutomaticDownloads
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                now: 1
            ),
            .reserveForPlayback
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .playing,
                now: 2
            ),
            .reserveForPlayback
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .playing,
                now: 11
            ),
            .reserveForPlayback
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .playing,
                now: 12
            ),
            .allowAutomaticDownloads
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                now: 13
            ),
            .reserveForPlayback
        )
        XCTAssertEqual(
            gate.decision(
                isPlayingIntent: true,
                timeControlStatus: .playing,
                now: 14
            ),
            .reserveForPlayback
        )
    }

    func testDisplayedDownloadBytesIncludeInflightTransferAndClampToExpected() {
        XCTAssertEqual(
            DownloadModel.combinedDownloadedByteLength(
                storedByteLength: 100,
                transferredByteLengths: [20, 30],
                expectedByteLength: 200
            ),
            150
        )
        XCTAssertEqual(
            DownloadModel.combinedDownloadedByteLength(
                storedByteLength: 100,
                transferredByteLengths: [Int64.max],
                expectedByteLength: 200
            ),
            200
        )
        XCTAssertEqual(
            DownloadModel.combinedDownloadedByteLength(
                storedByteLength: -1,
                transferredByteLengths: [25],
                expectedByteLength: 200
            ),
            25
        )
    }

    func testAutomaticDownloadBytesAndStateUseOnlyActiveWindow()
        throws
    {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: (0..<10).map { index in
                DownloadTrackPlan(
                    index: index,
                    inode: "\(index)",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: String(
                        format: "%05d.mp3",
                        index
                    )
                )
            }
        )
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "automatic"),
            accountID: AccountID(rawValue: "account"),
            plan: plan,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [2, 3, 4, 5, 6]
        )
        for index in 2...6 {
            try manifest.markComplete(
                trackIndex: index,
                observedByteLength: 10,
                placement: .finalized
            )
        }
        let record = DownloadedBookRecord(
            manifest: manifest,
            detail: fixtureBookDetail(
                item: fixturePage(
                    libraryID: fixtureLibrary().id
                ).items[0]
            )
        )

        XCTAssertEqual(record.manifest.automaticCacheState, .cached)
        XCTAssertEqual(
            record.manifest.automaticExpectedByteLength,
            50
        )
        XCTAssertFalse(record.manifest.isFullBookComplete)
        XCTAssertEqual(
            DownloadModel.scopedDownloadedByteLength(
                for: record,
                transferredByteLengthsByTrack: [
                    0: 10,
                    9: Int64.max,
                ]
            ),
            50
        )

        try manifest.setAutomaticWindow(
            targetTrackIndexes: [5, 6, 7, 8, 9]
        )
        try manifest.markDownloading(trackIndex: 7)
        let shifted = DownloadedBookRecord(
            manifest: manifest,
            detail: record.detail
        )
        XCTAssertEqual(
            shifted.manifest.automaticCacheState,
            .downloading
        )
        XCTAssertEqual(
            DownloadModel.scopedDownloadedByteLength(
                for: shifted,
                transferredByteLengthsByTrack: [
                    1: 10,
                    7: 5,
                ]
            ),
            25
        )
    }

    func testCoverURLRetainsPrefixAndUsesCacheDimensionsWithoutToken()
        throws
    {
        let server = try NormalizedServerURL(
            "https://books.example/audiobookshelf"
        )

        let url = try XCTUnwrap(
            BookCoverURL.make(
                server: server,
                itemID: LibraryItemID(rawValue: "item/one"),
                updatedAtMilliseconds: 123,
                width: 600,
                height: 400
            )
        )
        let components = try XCTUnwrap(
            URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )
        )

        XCTAssertEqual(
            components.percentEncodedPath,
            "/audiobookshelf/api/items/item%2Fone/cover"
        )
        XCTAssertEqual(
            components.queryItems,
            [
                URLQueryItem(name: "width", value: "600"),
                URLQueryItem(name: "height", value: "400"),
                URLQueryItem(name: "format", value: "jpeg"),
                URLQueryItem(name: "ts", value: "123"),
            ]
        )
        XCTAssertFalse(
            components.queryItems?.contains {
                ["token", "access_token"].contains($0.name.lowercased())
            } ?? true
        )
    }

    func testDownloadRepairPlannerPreservesHealthyTracksAndRejectsDrift()
        throws
    {
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8).utf8
            )
        )
        let item = fixturePage(
            libraryID: fixtureLibrary().id
        ).items[0]
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "download"),
            accountID: AccountID(rawValue: "account"),
            plan: plan
        )
        try manifest.markComplete(
            trackIndex: 0,
            observedByteLength: 4,
            placement: .finalized
        )
        try manifest.markFailed(trackIndex: 1)
        let record = DownloadedBookRecord(
            manifest: manifest,
            detail: fixtureBookDetail(item: item)
        )

        let tracks = try DownloadRepairPlanner.tracks(
            record: record,
            plan: plan
        )

        XCTAssertEqual(tracks.map(\.index), [1])
        XCTAssertThrowsError(
            try DownloadRepairPlanner.tracks(
                record: record,
                plan: DownloadPlan.decodeExpandedItem(
                    from: Data(
                        Self.downloadPlanJSON(secondSize: 9).utf8
                    )
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadModelFailure,
                .repairPlanChanged
            )
        }
    }

    func testAutomaticRepairUsesWindowWhilePromotionUsesFullBook()
        throws
    {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: (0..<3).map { index in
                DownloadTrackPlan(
                    index: index,
                    inode: "\(index)",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: String(
                        format: "%05d.mp3",
                        index
                    )
                )
            }
        )
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "automatic"),
            accountID: AccountID(rawValue: "account"),
            plan: plan,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [1]
        )
        try manifest.markComplete(
            trackIndex: 0,
            observedByteLength: 10,
            placement: .finalized
        )
        try manifest.markFailed(trackIndex: 1)
        try manifest.markFailed(trackIndex: 2)
        let record = DownloadedBookRecord(
            manifest: manifest,
            detail: fixtureBookDetail(
                item: fixturePage(
                    libraryID: fixtureLibrary().id
                ).items[0]
            )
        )

        XCTAssertEqual(
            try DownloadRepairPlanner.tracks(
                record: record,
                plan: plan
            ).map(\.index),
            [1]
        )
        XCTAssertEqual(
            try DownloadRepairPlanner.tracks(
                record: record,
                plan: plan,
                scope: .fullBook
            ).map(\.index),
            [1, 2]
        )
    }

    func testAccountRemovalChoiceKeepsOrDeletesDownloads()
        async throws
    {
        let account = try fixtureAccount()
        let plan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8).utf8
            )
        )
        let item = fixtureBook(
            id: plan.itemID.rawValue,
            title: "Downloaded",
            libraryID: fixtureLibrary().id
        )
        var roots: [URL] = []
        defer {
            for root in roots {
                try? FileManager.default.removeItem(at: root)
            }
        }

        for (disposition, expectedCount) in [
            (AccountDownloadDisposition.keep, 1),
            (.delete, 0),
        ] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "BleatAccountRemoval-\(UUID().uuidString)",
                    isDirectory: true
                )
            roots.append(root)
            let storage = DownloadStorage(
                layout: try DownloadStorageLayout(rootURL: root)
            )
            _ = try await storage.create(
                downloadID: DownloadID(
                    rawValue: UUID().uuidString.lowercased()
                ),
                accountID: account.id,
                plan: plan,
                detail: fixtureBookDetail(item: item)
            )
            let service = TestAppService(
                activeAccount: .success(account),
                libraries: .success([])
            )
            let model = AppModel(
                service: service,
                downloadsStorageRootURL: root
            )
            await model.start()
            XCTAssertEqual(model.downloads.records.count, 1)

            await model.removeAccount(downloads: disposition)

            XCTAssertEqual(
                model.downloads.records.count,
                expectedCount
            )
            XCTAssertEqual(model.phase, .signedOut)
            if disposition == .keep {
                let relaunched = AppModel(
                    service: TestAppService(
                        activeAccount: .success(nil)
                    ),
                    downloadsStorageRootURL: root
                )
                await relaunched.start()
                XCTAssertEqual(relaunched.phase, .signedOut)
                XCTAssertEqual(
                    relaunched.downloads.records.count,
                    1
                )
            }
        }
    }

    func testBulkDownloadRemovalKeepsProtectedPlaybackRecord()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatBulkRemoval-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        let account = try fixtureAccount()
        let firstPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8).utf8
            )
        )
        let secondPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8)
                    .replacingOccurrences(
                        of: "\"item-1\"",
                        with: "\"item-2\""
                    )
                    .utf8
            )
        )
        let protectedID = DownloadID(rawValue: "protected-download")
        _ = try await storage.create(
            downloadID: protectedID,
            accountID: account.id,
            plan: firstPlan,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: firstPlan.itemID.rawValue,
                    title: "Playing",
                    libraryID: fixtureLibrary().id
                )
            )
        )
        _ = try await storage.create(
            downloadID: DownloadID(rawValue: "removable-download"),
            accountID: account.id,
            plan: secondPlan,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: secondPlan.itemID.rawValue,
                    title: "Remove Me",
                    libraryID: fixtureLibrary().id
                )
            )
        )
        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(nil)),
            storageRootURL: root
        )
        await model.start(account: nil)

        await model.removeAll(excluding: protectedID)

        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(
            model.records.first?.manifest.downloadID,
            protectedID
        )
    }

    func testExpiredAutomaticCacheIsRemovedWithoutDeletingManualDownload()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatAutomaticCleanup-\(UUID().uuidString)",
                isDirectory: true
            )
        let suite = "AutomaticCleanupTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let storage = DownloadStorage(
            layout: try DownloadStorageLayout(rootURL: root)
        )
        let account = try fixtureAccount()
        let automaticPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let manualPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8)
                    .replacingOccurrences(
                        of: "\"item-1\"",
                        with: "\"item-2\""
                    )
                    .utf8
            )
        )
        var automatic = try await storage.create(
            downloadID: DownloadID(rawValue: "automatic"),
            accountID: account.id,
            plan: automaticPlan,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: automaticPlan.itemID.rawValue,
                    title: "Automatic",
                    libraryID: fixtureLibrary().id
                )
            ),
            purpose: .automaticCache,
            automaticTargetTrackIndexes: Set(
                automaticPlan.tracks.map(\.index)
            )
        )
        automatic = try await storage.markBookFinished(
            automatic,
            at: Date().addingTimeInterval(-(25 * 60 * 60))
        )
        XCTAssertNotNil(automatic.manifest.bookFinishedAt)
        _ = try await storage.create(
            downloadID: DownloadID(rawValue: "manual"),
            accountID: account.id,
            plan: manualPlan,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: manualPlan.itemID.rawValue,
                    title: "Manual",
                    libraryID: fixtureLibrary().id
                )
            )
        )
        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(nil)),
            defaults: defaults,
            storageRootURL: root
        )

        await model.start(account: nil)

        XCTAssertEqual(
            model.records.map(\.manifest.itemID),
            [
                manualPlan.itemID
            ])
        XCTAssertEqual(model.records.first?.manifest.purpose, .manual)
    }

    func testLegacyAutomaticCacheIsDiscardedWithoutDeletingManualDownload()
        async throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatLegacyAutomatic-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let layout = try DownloadStorageLayout(rootURL: root)
        let storage = DownloadStorage(layout: layout)
        let account = try fixtureAccount()
        let legacyPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(Self.downloadPlanJSON(secondSize: 8).utf8)
        )
        let manualPlan = try DownloadPlan.decodeExpandedItem(
            from: Data(
                Self.downloadPlanJSON(secondSize: 8)
                    .replacingOccurrences(
                        of: "\"item-1\"",
                        with: "\"item-2\""
                    )
                    .utf8
            )
        )
        let manualDetail = fixtureBookDetail(
            item: fixtureBook(
                id: manualPlan.itemID.rawValue,
                title: "Manual",
                libraryID: fixtureLibrary().id
            )
        )
        _ = try await storage.create(
            downloadID: DownloadID(rawValue: "manual"),
            accountID: account.id,
            plan: manualPlan,
            detail: manualDetail
        )

        let legacyManifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "legacy-automatic"),
            accountID: account.id,
            plan: legacyPlan,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [0]
        )
        let legacyRecord = DownloadedBookRecord(
            manifest: legacyManifest,
            detail: fixtureBookDetail(
                item: fixtureBook(
                    id: legacyPlan.itemID.rawValue,
                    title: "Legacy Automatic",
                    libraryID: fixtureLibrary().id
                )
            )
        )
        let legacyURL = layout.recordURL(
            accountID: account.id,
            itemID: legacyPlan.itemID
        )
        try FileManager.default.createDirectory(
            at: legacyURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(legacyRecord)
            ) as? [String: Any]
        )
        var legacyManifestObject = try XCTUnwrap(
            legacyObject["manifest"] as? [String: Any]
        )
        legacyManifestObject["automaticWindow"] = nil
        legacyObject["manifest"] = legacyManifestObject
        try JSONSerialization.data(
            withJSONObject: legacyObject
        ).write(to: legacyURL)

        let model = DownloadModel(
            service: TestAppService(activeAccount: .success(nil)),
            storageRootURL: root
        )
        await model.start(account: nil)

        XCTAssertEqual(model.records.count, 1)
        XCTAssertEqual(
            model.records.first?.manifest.downloadID,
            DownloadID(rawValue: "manual")
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: legacyURL.path)
        )
    }

    func testDownloadFailuresHaveDistinctMessages() {
        let failures: [DownloadModelFailure] = [
            .storageUnavailable,
            .permissionDenied,
            .preparationFailed,
            .repairPlanChanged,
            .insufficientStorage(
                requiredBytes: 1_000,
                availableBytes: 500
            ),
            .transferFailed,
        ]

        XCTAssertTrue(failures.allSatisfy { !$0.message.isEmpty })
        XCTAssertEqual(Set(failures.map(\.message)).count, failures.count)
    }

    func testDownloadNetworkPolicyPersistsAndControlsRequests() throws {
        let suite = "DownloadNetworkPolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let service = TestAppService(activeAccount: .success(nil))
        let first = DownloadModel(
            service: service,
            defaults: defaults
        )
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://books.example/file"))
        )
        request.setValue(
            "Bearer access",
            forHTTPHeaderField: "Authorization"
        )

        XCTAssertEqual(first.networkPolicy, .wifiOnly)
        let wifiRequest = DownloadNetworkPolicy.wifiOnly.applying(
            to: request
        )
        XCTAssertFalse(wifiRequest.allowsExpensiveNetworkAccess)
        XCTAssertEqual(
            wifiRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer access"
        )
        first.setNetworkPolicy(.allowCellular)
        let restored = DownloadModel(
            service: service,
            defaults: defaults
        )
        XCTAssertEqual(restored.networkPolicy, .allowCellular)
        XCTAssertTrue(
            DownloadNetworkPolicy.allowCellular.applying(to: request)
                .allowsExpensiveNetworkAccess
        )
        XCTAssertEqual(
            DownloadNetworkDecision.decide(
                policy: .allowCellular,
                expectedBytes:
                    DownloadModel.largeDownloadThresholdBytes,
                largeDownloadThresholdBytes:
                    DownloadModel.largeDownloadThresholdBytes
            ),
            .confirmCellular(
                expectedBytes:
                    DownloadModel.largeDownloadThresholdBytes
            )
        )
        XCTAssertEqual(
            DownloadNetworkDecision.decide(
                policy: .wifiOnly,
                expectedBytes: Int64.max,
                largeDownloadThresholdBytes:
                    DownloadModel.largeDownloadThresholdBytes
            ),
            .schedule
        )
    }

    func testAutomaticDownloadSettingsUseRequestedDefaultsAndPersist()
        throws
    {
        let suite = "AutomaticDownloadSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let service = TestAppService(activeAccount: .success(nil))
        let first = DownloadModel(service: service, defaults: defaults)

        XCTAssertEqual(first.automaticLookaheadCount, 5)
        XCTAssertEqual(
            first.automaticCleanupPolicy,
            .afterTwentyFourHours
        )

        first.setAutomaticLookaheadCount(9)
        first.setAutomaticCleanupPolicy(.afterChapter)
        let restored = DownloadModel(service: service, defaults: defaults)
        XCTAssertEqual(restored.automaticLookaheadCount, 9)
        XCTAssertEqual(restored.automaticCleanupPolicy, .afterChapter)

        restored.setAutomaticLookaheadCount(0)
        XCTAssertEqual(restored.automaticLookaheadCount, 1)
        restored.setAutomaticLookaheadCount(99)
        XCTAssertEqual(restored.automaticLookaheadCount, 20)
    }

    func testAutomaticDownloadPlannerUsesWholeFilesForChapterWindow()
        throws
    {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: (0..<10).map { index in
                DownloadTrackPlan(
                    index: index,
                    inode: "\(index)",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: String(
                        format: "%05d.mp3",
                        index
                    ),
                    startOffset: Double(index * 60),
                    duration: 60
                )
            }
        )
        let chapters = (0..<20).map { index in
            PlaybackChapter(
                id: index,
                start: Double(index * 30),
                end: Double((index + 1) * 30),
                title: "Chapter \(index + 1)"
            )
        }
        let activity = AutomaticDownloadActivity(
            kind: .progress,
            detail: fixtureBookDetail(
                item: fixturePage(libraryID: fixtureLibrary().id).items[0]
            ),
            account: try fixtureAccount(),
            currentTime: 15,
            chapters: chapters,
            fileRanges: []
        )

        XCTAssertEqual(
            AutomaticDownloadPlanner.targetTrackIndexes(
                plan: plan,
                activity: activity,
                lookaheadCount: 5
            ),
            [0, 1, 2]
        )

        let laterActivity = AutomaticDownloadActivity(
            kind: .progress,
            detail: activity.detail,
            account: activity.account,
            currentTime: 125,
            chapters: chapters,
            fileRanges: []
        )
        XCTAssertEqual(
            AutomaticDownloadPlanner.completedTrackIndexes(
                plan: plan,
                activity: laterActivity
            ),
            [0, 1]
        )
    }

    func testAutomaticDownloadPlannerFallsBackToCurrentPlusFilesAhead()
        throws
    {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "item"),
            tracks: (0..<10).map { index in
                DownloadTrackPlan(
                    index: index,
                    inode: "\(index)",
                    expectedByteLength: 10,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: String(
                        format: "%05d.mp3",
                        index
                    )
                )
            }
        )
        let ranges = (0..<10).map { index in
            AutomaticDownloadFileRange(
                index: index,
                start: Double(index * 60),
                end: Double((index + 1) * 60)
            )
        }
        let activity = AutomaticDownloadActivity(
            kind: .progress,
            detail: fixtureBookDetail(
                item: fixturePage(libraryID: fixtureLibrary().id).items[0]
            ),
            account: try fixtureAccount(),
            currentTime: 125,
            chapters: [],
            fileRanges: ranges
        )

        XCTAssertEqual(
            AutomaticDownloadPlanner.targetTrackIndexes(
                plan: plan,
                activity: activity,
                lookaheadCount: 5
            ),
            [2, 3, 4, 5, 6, 7]
        )

        let singleFile = DownloadPlan(
            itemID: plan.itemID,
            tracks: [plan.tracks[0]]
        )
        XCTAssertEqual(
            AutomaticDownloadPlanner.targetTrackIndexes(
                plan: singleFile,
                activity: activity,
                lookaheadCount: 5
            ),
            [0]
        )
    }

    func testPlaybackPreferencesPersistRateRewindAndSkipIntervals()
        throws
    {
        let suite = "PlaybackPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let first = PlaybackPreferencesStore(defaults: defaults)

        XCTAssertEqual(first.playbackRate(), 1)
        XCTAssertEqual(first.resumeRewind(), .tenSeconds)
        XCTAssertEqual(first.skipBackward(), .fifteenSeconds)
        XCTAssertEqual(first.skipForward(), .thirtySeconds)
        first.savePlaybackRate(1.37)
        first.saveResumeRewind(.thirtySeconds)
        first.saveSkipBackward(.fortyFiveSeconds)
        first.saveSkipForward(.sixtySeconds)

        let restored = PlaybackPreferencesStore(defaults: defaults)
        XCTAssertEqual(restored.playbackRate(), 1.35, accuracy: 0.001)
        XCTAssertEqual(restored.resumeRewind(), .thirtySeconds)
        XCTAssertEqual(restored.skipBackward(), .fortyFiveSeconds)
        XCTAssertEqual(restored.skipForward(), .sixtySeconds)
        restored.savePlaybackRate(10)
        XCTAssertEqual(restored.playbackRate(), 3)
        restored.savePlaybackRate(0)
        XCTAssertEqual(restored.playbackRate(), 0.5)
        restored.savePlaybackRate(.nan)
        XCTAssertEqual(restored.playbackRate(), 1)
    }

    func testBookmarkMutationStorePersistsAndAppliesOptimisticChanges()
        throws
    {
        let suite = "BookmarkMutationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let accountID = AccountID(rawValue: "account")
        let itemID = LibraryItemID(rawValue: "item")
        let bookmark = AudioBookmark(
            libraryItemID: itemID,
            time: 42,
            title: "Queued",
            createdAtMilliseconds: 1
        )
        let store = BookmarkMutationStore(defaults: defaults)
        let mutation = try store.enqueue(
            accountID: accountID,
            bookmark: bookmark,
            kind: .create,
            status: .failed
        )

        let restored = BookmarkMutationStore(defaults: defaults)
        XCTAssertEqual(
            try restored.mutations(accountID: accountID),
            [mutation]
        )
        XCTAssertEqual(
            restored.applying([mutation], to: []),
            [bookmark]
        )
        XCTAssertEqual(
            BookmarkReconciliationDecision.decide(
                mutation: mutation,
                remote: [bookmark]
            ),
            .complete
        )
        XCTAssertEqual(
            BookmarkReconciliationDecision.decide(
                mutation: mutation,
                remote: []
            ),
            .create(title: "Queued")
        )
        let renamed = try store.enqueue(
            accountID: accountID,
            bookmark: bookmark,
            kind: .rename,
            title: "Renamed",
            status: .pending
        )
        XCTAssertEqual(
            BookmarkReconciliationDecision.decide(
                mutation: renamed,
                remote: [bookmark]
            ),
            .rename(bookmark, title: "Renamed")
        )
        let deleted = try store.enqueue(
            accountID: accountID,
            bookmark: bookmark,
            kind: .delete,
            status: .pending
        )
        XCTAssertEqual(
            BookmarkReconciliationDecision.decide(
                mutation: deleted,
                remote: []
            ),
            .complete
        )

        try restored.markPending(accountID: accountID)
        XCTAssertEqual(
            try restored.mutations(accountID: accountID)[0].status,
            .pending
        )
        try restored.remove(mutation.id)
        XCTAssertEqual(
            try restored.mutations(accountID: accountID),
            [renamed, deleted]
        )
        try restored.removeAll(accountID: accountID)
        XCTAssertTrue(try restored.mutations(accountID: accountID).isEmpty)
    }

    func testResumeRewindRequiresFiveMinutePauseAndClampsAtBookStart() {
        let pausedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertNil(
            PlaybackResumeRewindDecision.target(
                currentTime: 100,
                pausedAt: pausedAt,
                now: pausedAt.addingTimeInterval(299),
                setting: .tenSeconds
            )
        )
        XCTAssertNil(
            PlaybackResumeRewindDecision.target(
                currentTime: 100,
                pausedAt: pausedAt,
                now: pausedAt.addingTimeInterval(600),
                setting: .off
            )
        )
        XCTAssertEqual(
            PlaybackResumeRewindDecision.target(
                currentTime: 8,
                pausedAt: pausedAt,
                now: pausedAt.addingTimeInterval(300),
                setting: .tenSeconds
            ),
            0
        )
    }

    func testEndOfChapterSleepUsesWholeBookBoundary() {
        let chapters = [
            PlaybackChapter(id: 1, start: 0, end: 60, title: "One"),
            PlaybackChapter(id: 2, start: 60, end: 130, title: "Two"),
        ]

        XCTAssertEqual(
            PlaybackChapterSleepDecision.target(
                chapters: chapters,
                currentTime: 75,
                duration: 130
            ),
            130
        )
        XCTAssertNil(
            PlaybackChapterSleepDecision.target(
                chapters: chapters,
                currentTime: 130,
                duration: 130
            )
        )
    }

    func testPlaybackObservationRequiresReadyAdvancingPlayback() {
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: true,
                itemStatus: .unknown,
                timeControlStatus: .playing,
                hasConfirmedAdvance: true
            ),
            .buffering
        )
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: true,
                itemStatus: .readyToPlay,
                timeControlStatus: .waitingToPlayAtSpecifiedRate,
                hasConfirmedAdvance: true
            ),
            .buffering
        )
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: true,
                itemStatus: .readyToPlay,
                timeControlStatus: .playing,
                hasConfirmedAdvance: false
            ),
            .buffering
        )
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: true,
                itemStatus: .readyToPlay,
                timeControlStatus: .playing,
                hasConfirmedAdvance: true
            ),
            .playing
        )
        XCTAssertEqual(
            PlaybackObservationDecision.decide(
                isPlaybackRequested: false,
                itemStatus: .readyToPlay,
                timeControlStatus: .playing,
                hasConfirmedAdvance: true
            ),
            .paused
        )
    }

    func testPlaybackWatchdogBuffersThenRecoversAtExactDeadlines() {
        XCTAssertEqual(
            PlaybackWatchdogDecision.decide(
                isPlaybackRequested: true,
                lastConfirmedAdvanceAt: 100,
                now: 101.99
            ),
            .none
        )
        XCTAssertEqual(
            PlaybackWatchdogDecision.decide(
                isPlaybackRequested: true,
                lastConfirmedAdvanceAt: 100,
                now: 102
            ),
            .showBuffering
        )
        XCTAssertEqual(
            PlaybackWatchdogDecision.decide(
                isPlaybackRequested: true,
                lastConfirmedAdvanceAt: 100,
                now: 112
            ),
            .recover
        )
        XCTAssertEqual(
            PlaybackWatchdogDecision.decide(
                isPlaybackRequested: false,
                lastConfirmedAdvanceAt: 100,
                now: 200
            ),
            .none
        )
    }

    func testPlaybackRecoveryPolicyBoundsRebuildAndSessionReplacement() {
        var streamingPolicy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            streamingPolicy.action(
                for: .stalled,
                isStreaming: true,
                isTranscoded: false
            ),
            .rebuildCurrentSource
        )
        XCTAssertEqual(
            streamingPolicy.action(
                for: .itemFailure,
                isStreaming: true,
                isTranscoded: false
            ),
            .reopenSession(.automatic)
        )
        XCTAssertEqual(
            streamingPolicy.action(
                for: .missingSession,
                isStreaming: true,
                isTranscoded: false
            ),
            .fail
        )

        var hlsPolicy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            hlsPolicy.action(
                for: .itemFailure,
                isStreaming: true,
                isTranscoded: true
            ),
            .rebuildCurrentSource
        )
        XCTAssertEqual(
            hlsPolicy.action(
                for: .itemFailure,
                isStreaming: true,
                isTranscoded: true
            ),
            .reopenSession(.automatic)
        )
        XCTAssertEqual(
            hlsPolicy.action(
                for: .itemFailure,
                isStreaming: true,
                isTranscoded: true
            ),
            .fail
        )

        var localPolicy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            localPolicy.action(
                for: .stalled,
                isStreaming: false,
                isTranscoded: false
            ),
            .rebuildCurrentSource
        )
        XCTAssertEqual(
            localPolicy.action(
                for: .itemFailure,
                isStreaming: false,
                isTranscoded: false
            ),
            .fail
        )
        localPolicy.sustainedPlaybackConfirmed()
        XCTAssertEqual(
            localPolicy.action(
                for: .stalled,
                isStreaming: false,
                isTranscoded: false
            ),
            .rebuildCurrentSource
        )
    }

    func testPlaybackRecoveryPolicyForcesTranscodeOnceForDecoderFailure() {
        var policy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            policy.action(
                for: .decoderFailure,
                isStreaming: true,
                isTranscoded: false
            ),
            .reopenSession(.transcode)
        )
        XCTAssertEqual(
            policy.action(
                for: .decoderFailure,
                isStreaming: true,
                isTranscoded: false
            ),
            .fail
        )
        XCTAssertEqual(
            policy.action(
                for: .missingSession,
                isStreaming: true,
                isTranscoded: true
            ),
            .reopenSession(.automatic)
        )

        var transcodedPolicy = PlaybackRecoveryPolicy()
        XCTAssertEqual(
            transcodedPolicy.action(
                for: .decoderFailure,
                isStreaming: true,
                isTranscoded: true
            ),
            .fail
        )
    }

    func testPlaybackItemFailureClassificationUsesTypedCodesOnly() {
        let decoderError = NSError(
            domain: AVFoundationErrorDomain,
            code: AVError.Code.decoderNotFound.rawValue
        )
        XCTAssertEqual(
            PlaybackItemFailureClassifier.classify(
                error: decoderError,
                errorLogStatusCodes: []
            ),
            .decoderFailure
        )
        XCTAssertEqual(
            PlaybackItemFailureClassifier.classify(
                error: nil,
                errorLogStatusCodes: [404]
            ),
            .missingSession
        )
        XCTAssertEqual(
            PlaybackItemFailureClassifier.classify(
                error: NSError(
                    domain: "TestError",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "decoder failed after a 404"
                    ]
                ),
                errorLogStatusCodes: []
            ),
            .itemFailure
        )
    }

    func testMediaServicesResetIntentOnlyRecoversStablePlaybackStates() {
        XCTAssertEqual(
            PlaybackMediaServicesResetIntent.decide(for: .playing),
            .play
        )
        XCTAssertEqual(
            PlaybackMediaServicesResetIntent.decide(for: .buffering),
            .play
        )
        XCTAssertEqual(
            PlaybackMediaServicesResetIntent.decide(for: .paused),
            .pause
        )
        XCTAssertEqual(
            PlaybackMediaServicesResetIntent.decide(for: .ready),
            .pause
        )
        XCTAssertNil(
            PlaybackMediaServicesResetIntent.decide(for: .preparing)
        )
        XCTAssertNil(
            PlaybackMediaServicesResetIntent.decide(for: .ended)
        )
        XCTAssertNil(
            PlaybackMediaServicesResetIntent.decide(
                for: .failed(.mediaUnavailable)
            )
        )
    }

    func testQueueRecoverySelectsTrackAtWholeBookBoundary() throws {
        let tracks = [
            AppPlaybackTrack(
                url: URL(fileURLWithPath: "/one.m4b"),
                startOffset: 0,
                duration: 10,
                title: "One"
            ),
            AppPlaybackTrack(
                url: URL(fileURLWithPath: "/two.m4b"),
                startOffset: 10,
                duration: 10,
                title: "Two"
            ),
            AppPlaybackTrack(
                url: URL(fileURLWithPath: "/three.m4b"),
                startOffset: 20,
                duration: 10,
                title: "Three"
            ),
        ]
        let preparation = AppPlaybackPreparation(
            sessionID: nil,
            itemID: LibraryItemID(rawValue: "item"),
            title: "Book",
            duration: 30,
            currentTime: 0,
            chapters: [],
            source: .direct(tracks)
        )

        let beforeBoundary = try AppPlaybackQueuePlanner.make(
            preparation: preparation,
            wholeBookTime: 19.5
        )
        XCTAssertEqual(beforeBoundary.tracks, Array(tracks[1...]))
        XCTAssertEqual(beforeBoundary.localTime, 9.5)

        let atBoundary = try AppPlaybackQueuePlanner.make(
            preparation: preparation,
            wholeBookTime: 20
        )
        XCTAssertEqual(atBoundary.tracks, [tracks[2]])
        XCTAssertEqual(atBoundary.localTime, 0)
    }

    func testMediaServicesResetRestoresPlayingAndPausedIntent() async throws {
        for shouldPlay in [true, false] {
            let fixture = try playbackRecoveryFixture()
            defer {
                fixture.cleanUp()
            }
            let activation = TestAudioSessionActivation()
            let playback = fixture.model(activation: activation)

            await playback.startDownloaded(
                detail: fixture.detail,
                trackURLs: [fixture.audioURL],
                accountID: fixture.accountID,
                account: nil
            )
            XCTAssertTrue(playback.isPlaybackRequested)
            XCTAssertTrue(
                playback.state == .buffering || playback.state == .playing
            )
            playback.setRate(1.35)
            if !shouldPlay {
                playback.pause()
                XCTAssertEqual(playback.state, .paused)
            }

            await playback.handleMediaServicesReset()

            XCTAssertEqual(playback.isPlaybackRequested, shouldPlay)
            if shouldPlay {
                XCTAssertTrue(
                    playback.state == .buffering
                        || playback.state == .playing
                )
            } else {
                XCTAssertEqual(playback.state, .paused)
            }
            XCTAssertEqual(playback.rate, 1.35, accuracy: 0.001)
            XCTAssertEqual(activation.callCount, 2)
        }
    }

    func testMediaServicesResetRebuildsAcrossAudioFileBoundary()
        async throws
    {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let activation = TestAudioSessionActivation()
        let playback = fixture.model(activation: activation)

        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL, fixture.audioURL],
            accountID: fixture.accountID,
            account: nil
        )
        let boundary = try XCTUnwrap(
            playback.audioFiles.last?.startOffset
        )
        await playback.seek(to: boundary)
        XCTAssertEqual(playback.currentAudioFileIndex, 1)

        await playback.handleMediaServicesReset()

        XCTAssertTrue(playback.isPlaybackRequested)
        XCTAssertTrue(
            playback.state == .buffering || playback.state == .playing
        )
        XCTAssertEqual(playback.currentAudioFileIndex, 1)
        XCTAssertEqual(playback.currentTime, boundary, accuracy: 0.1)
    }

    func testMediaServicesResetRebuildFailureIsTyped() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let activation = TestAudioSessionActivation()
        let planning = TestPlaybackQueuePlanning(failingCall: 2)
        let playback = fixture.model(
            activation: activation,
            queuePlanning: {
                try planning.make(
                    preparation: $0,
                    wholeBookTime: $1
                )
            }
        )

        await playback.startDownloaded(
            detail: fixture.detail,
            trackURLs: [fixture.audioURL],
            accountID: fixture.accountID,
            account: nil
        )
        XCTAssertTrue(playback.isPlaybackRequested)
        XCTAssertTrue(
            playback.state == .buffering || playback.state == .playing
        )

        await playback.handleMediaServicesReset()

        XCTAssertEqual(playback.state, .failed(.mediaUnavailable))
        XCTAssertEqual(activation.callCount, 2)
        XCTAssertEqual(planning.callCount, 2)
    }

    func testLocalSessionStorePersistsAndRemovesOnlyAcknowledgedIDs()
        throws
    {
        let suite = "LocalPlaybackSessionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let accountID = AccountID(rawValue: "account")
        let first = try localSession(
            id: "d9ef37df-6838-4dd5-9875-266ae49db169",
            itemID: "item-1"
        )
        let second = try localSession(
            id: "5eef37df-6838-4dd5-9875-266ae49db169",
            itemID: "item-2"
        )
        let store = LocalPlaybackSessionStore(defaults: defaults)
        try store.save(first, accountID: accountID)
        try store.save(second, accountID: accountID)

        let restored = LocalPlaybackSessionStore(defaults: defaults)
        XCTAssertEqual(
            try restored.pending(accountID: accountID).map(\.id),
            [first.id, second.id]
        )
        try restored.removeAcknowledged(
            accountID: accountID,
            sessionIDs: [first.id]
        )

        XCTAssertEqual(
            try restored.pending(accountID: accountID).map(\.id),
            [second.id]
        )
    }

    func testPendingLocalSessionsRetryWithSameIDUntilAcknowledged()
        async throws
    {
        let suite = "LocalPlaybackSessionRetryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let account = try fixtureAccount()
        let first = try localSession(
            id: "d9ef37df-6838-4dd5-9875-266ae49db169",
            itemID: "item-1"
        )
        let second = try localSession(
            id: "5eef37df-6838-4dd5-9875-266ae49db169",
            itemID: "item-2"
        )
        let store = LocalPlaybackSessionStore(defaults: defaults)
        try store.save(first, accountID: account.id)
        try store.save(second, accountID: account.id)
        let service = TestAppService(
            activeAccount: .success(account),
            localSessionSync: .success([
                LocalPlaybackSessionSyncResult(
                    id: first.id,
                    success: true,
                    progressSynced: true,
                    error: nil
                ),
                LocalPlaybackSessionSyncResult(
                    id: second.id,
                    success: false,
                    progressSynced: false,
                    error: "retry"
                ),
            ])
        )
        let playback = PlaybackModel(
            service: service,
            localSessionStore: store
        )

        await playback.syncPendingLocalSessions(for: account)

        XCTAssertEqual(
            try store.pending(accountID: account.id).map(\.id),
            [second.id]
        )
        await service.setLocalSessionSync(
            .success([
                LocalPlaybackSessionSyncResult(
                    id: second.id,
                    success: true,
                    progressSynced: true,
                    error: nil
                )
            ])
        )
        await playback.syncPendingLocalSessions(for: account)

        XCTAssertTrue(try store.pending(accountID: account.id).isEmpty)
        let requests = await service.localSessionSyncRequests()
        XCTAssertEqual(
            requests.map { $0.sessions.map(\.id) },
            [
                [first.id, second.id],
                [second.id],
            ]
        )
    }

    func testStartWithoutSavedAccountShowsLogin() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.account)
        XCTAssertEqual(model.libraries, .idle)
    }

    func testDiagnosticsRecordLifecycleAndTypedAuthFailureWithoutInputs()
        async
    {
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .failure(
                .onboarding(
                    .authenticationFailed(.invalidCredentials)
                )
            )
        )
        let recorder = AppDiagnosticRecorderSpy()
        let model = AppModel(
            service: service,
            diagnostics: recorder
        )

        await model.start()
        _ = await model.login(
            serverAddress: "https://secret.example/private",
            username: "private-user",
            password: "private-password"
        )

        let events = await recorder.events()
        XCTAssertTrue(
            events.contains {
                $0.operation == .appStart
                    && $0.name == .operationCompleted
            }
        )
        XCTAssertTrue(
            events.contains {
                $0.fromState == .launching
                    && $0.toState == .signedOut
            }
        )
        XCTAssertTrue(
            events.contains {
                $0.operation == .login
                    && $0.failureCode == .invalidCredentials
            }
        )
        let exportedText = events.map(\.text).joined(separator: "\n")
        XCTAssertFalse(exportedText.contains("secret.example"))
        XCTAssertFalse(exportedText.contains("private-user"))
        XCTAssertFalse(exportedText.contains("private-password"))
    }

    func testStartRestoresAccountAndLoadsFirstAudiobookLibrary() async throws {
        let account = try fixtureAccount()
        let audiobookLibrary = fixtureLibrary()
        let podcastLibrary = LibrarySummary(
            id: LibraryID(rawValue: "podcasts"),
            name: "Podcasts",
            mediaType: .podcast
        )
        let page = fixturePage(libraryID: audiobookLibrary.id)
        let shelves = fixtureShelves(libraryID: audiobookLibrary.id)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([podcastLibrary, audiobookLibrary]),
            firstPage: .success(page),
            homeShelves: .success(shelves)
        )
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(model.libraries, .loaded([audiobookLibrary]))
        XCTAssertEqual(model.selectedLibrary, audiobookLibrary)
        XCTAssertEqual(model.books, .loaded(page))
        XCTAssertEqual(model.homeShelves, .loaded(shelves))
        let pageRequests = await service.pageRequests()
        XCTAssertEqual(pageRequests, [audiobookLibrary.id])
        let homeRequests = await service.homeRequests()
        XCTAssertEqual(homeRequests, [audiobookLibrary.id])
    }

    func testStartRunsOnlyOnce() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.start()
        await model.start()

        let requestCount = await service.activeAccountRequestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testSwitchAccountPersistsSelectionAndReloadsBrowsingContext()
        async throws
    {
        let first = try fixtureAccount()
        let second = try fixtureAccount(
            accountID: "account-2",
            userID: "user-2",
            username: "second",
            server: "https://second.example"
        )
        let service = TestAppService(
            accounts: .success([first, second]),
            activeAccount: .success(first)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.switchAccount(to: second)

        XCTAssertEqual(model.account, second)
        XCTAssertEqual(model.accounts, [first, second])
        XCTAssertEqual(model.accountActionStatus, .idle)
        let activated = await service.activatedAccounts()
        XCTAssertEqual(activated, [second])
        XCTAssertFalse(model.playback.hasActiveBook)
    }

    func testStartFailureShowsUnavailableState() async {
        let service = TestAppService(
            activeAccount: .failure(.accountStore(.persistenceFailed))
        )
        let model = AppModel(service: service)

        await model.start()

        XCTAssertEqual(model.phase, .unavailable(.accountUnavailable))
    }

    func testBootstrapFailureRemainsUnavailableWhenRootStarts() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(
            service: service,
            bootstrapError: .persistenceUnavailable
        )

        await model.start()

        XCTAssertEqual(model.phase, .unavailable(.persistenceUnavailable))
        let requestCount = await service.activeAccountRequestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testNativeLoginForwardsUsernamePasswordAndLoadsLibrary() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .success(account),
            libraries: .success([library]),
            firstPage: .success(page)
        )
        let model = AppModel(service: service)

        await model.login(
            serverAddress: "https://books.example/audiobookshelf",
            username: "reader",
            password: "correct horse"
        )

        let loginRequests = await service.loginRequests()
        XCTAssertEqual(
            loginRequests,
            [
                LoginRequest(
                    serverAddress: "https://books.example/audiobookshelf",
                    username: "reader",
                    password: "correct horse"
                )
            ]
        )
        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.loginStatus, .idle)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(model.books, .loaded(page))
    }

    func testRejectedNativeCredentialsRemainSignedOut() async {
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .failure(
                .onboarding(
                    .authenticationFailed(.invalidCredentials)
                )
            )
        )
        let model = AppModel(service: service)

        await model.start()
        await model.login(
            serverAddress: "https://books.example",
            username: "reader",
            password: "wrong"
        )

        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertEqual(model.loginStatus, .failed(.invalidCredentials))
        XCTAssertNil(model.account)
    }

    func testReauthenticationUsesSavedAccountAndReloadsLibrary()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(account),
            login: .success(account),
            libraries: .success([library]),
            firstPage: .success(page)
        )
        let model = AppModel(service: service)
        await model.start()

        let authenticated = await model.reauthenticate(
            password: "new password"
        )

        XCTAssertTrue(authenticated)
        let requests = await service.reauthenticationRequests()
        XCTAssertEqual(
            requests,
            [
                ReauthenticationRequest(
                    accountID: account.id,
                    password: "new password"
                )
            ]
        )
        XCTAssertEqual(model.loginStatus, .idle)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(model.books, .loaded(page))
    }

    func testDiagnosticsReportContainsStateWithoutAccountSecrets()
        async throws
    {
        let account = try fixtureAccount(
            accountID: "private-account-id",
            userID: "private-user-id",
            username: "private-username",
            server: "https://private.example/library"
        )
        let library = fixtureLibrary()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id))
        )
        let model = AppModel(service: service)
        await model.start()

        let report = model.diagnosticsReport(
            generatedAt: Date(timeIntervalSince1970: 1_721_865_600),
            environment: DiagnosticsEnvironment(
                appVersion: "0.1.0",
                appBuild: "7",
                operatingSystem: "iOS 26.0"
            )
        )

        XCTAssertEqual(report.serverVersion, "2.36.0")
        XCTAssertEqual(report.connectionState, "Connected")
        XCTAssertEqual(report.accountCount, 1)
        XCTAssertEqual(report.libraryState, "Loaded")
        XCTAssertEqual(report.playbackState, "Idle")
        XCTAssertTrue(report.errorCodes.isEmpty)
        XCTAssertTrue(report.text.contains("App: 0.1.0 (7)"))
        XCTAssertTrue(report.text.contains("Server version: 2.36.0"))
        XCTAssertFalse(report.text.contains("private-account-id"))
        XCTAssertFalse(report.text.contains("private-user-id"))
        XCTAssertFalse(report.text.contains("private-username"))
        XCTAssertFalse(report.text.contains("private.example"))
    }

    func testDiagnosticsReportUsesTypedErrorCodes() async throws {
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .failure(
                .onboarding(
                    .authenticationFailed(.invalidCredentials)
                )
            )
        )
        let model = AppModel(service: service)
        await model.start()

        _ = await model.login(
            serverAddress: "https://private.example",
            username: "private-username",
            password: "private-password"
        )
        let report = model.diagnosticsReport(
            environment: DiagnosticsEnvironment(
                appVersion: "0.1.0",
                appBuild: "7",
                operatingSystem: "iOS 26.0"
            )
        )

        XCTAssertEqual(report.errorCodes, ["invalid_credentials"])
        XCTAssertTrue(
            report.text.contains(
                "Active error codes: invalid_credentials"
            )
        )
        XCTAssertFalse(report.text.contains("private-password"))
        XCTAssertFalse(report.text.contains("private-username"))
        XCTAssertFalse(report.text.contains("private.example"))
    }

    func testConcurrentLoginIsIgnoredWhileSubmissionIsActive() async throws {
        let account = try fixtureAccount()
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(nil),
            login: .success(account),
            libraries: .success([]),
            loginGate: gate
        )
        let model = AppModel(service: service)

        let firstLogin = Task { @MainActor in
            await model.login(
                serverAddress: "https://books.example",
                username: "reader",
                password: "first"
            )
        }
        await gate.waitUntilEntered()

        await model.login(
            serverAddress: "https://other.example",
            username: "other",
            password: "second"
        )
        await gate.release()
        _ = await firstLogin.value

        let loginRequestCount = await service.loginRequests().count
        XCTAssertEqual(loginRequestCount, 1)
    }

    func testLibraryFailureAndRetry() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .failure(
                .libraryRepository(.remote(.unexpectedStatus(503)))
            )
        )
        let model = AppModel(service: service)

        await model.start()
        XCTAssertEqual(model.libraries, .failed(.libraryUnavailable))

        await service.setLibraries(.success([library]))
        await service.setFirstPage(
            .success(fixturePage(libraryID: library.id))
        )
        await model.loadLibraries()

        XCTAssertEqual(model.libraries, .loaded([library]))
        XCTAssertEqual(model.selectedLibrary, library)
    }

    func testSelectingLibraryHandlesPageFailure() async throws {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            firstPage: .failure(
                .libraryRepository(.remote(.invalidPage))
            )
        )
        let model = AppModel(service: service)

        await model.start()
        await model.selectLibrary(fixtureLibrary())

        XCTAssertEqual(model.books, .failed(.libraryUnavailable))
    }

    func testLoadingNextLibraryPageAppendsBooks() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstBook = fixtureBook(
            id: "item-1",
            title: "First",
            libraryID: library.id
        )
        let secondBook = fixtureBook(
            id: "item-2",
            title: "Second",
            libraryID: library.id
        )
        let firstPage = LibraryItemsPage(
            items: [firstBook],
            total: 2,
            page: 0,
            limit: 1
        )
        let nextPage = LibraryItemsPage(
            items: [secondBook],
            total: 2,
            page: 1,
            limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(firstPage),
            nextPage: .success(nextPage)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadNextBooksPage()

        XCTAssertEqual(
            model.books,
            .loaded(
                LibraryItemsPage(
                    items: [firstBook, secondBook],
                    total: 2,
                    page: 1,
                    limit: 1
                )
            )
        )
        XCTAssertEqual(model.libraryPaginationState, .idle)
        let selections = await service.pageSelections()
        XCTAssertEqual(
            selections,
            [
                PageSelection(
                    page: 0,
                    sort: .title,
                    descending: false,
                    filter: nil
                ),
                PageSelection(
                    page: 1,
                    sort: .title,
                    descending: false,
                    filter: nil
                ),
            ]
        )
    }

    func testLibrarySortAndProgressFilterReloadFromFirstPage()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstBook = fixturePage(libraryID: library.id).items[0]
        let firstPage = LibraryItemsPage(
            items: [firstBook],
            total: 2,
            page: 0,
            limit: 1
        )
        let nextPage = LibraryItemsPage(
            items: [
                fixtureBook(
                    id: "item-2",
                    title: "Second",
                    libraryID: library.id
                )
            ],
            total: 2,
            page: 1,
            limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(firstPage),
            nextPage: .success(nextPage)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setLibrarySort(.addedAt)
        await model.setLibrarySortDescending(true)
        await model.setLibraryProgressFilter(.inProgress)
        await model.loadNextBooksPage()

        XCTAssertEqual(model.librarySort, .addedAt)
        XCTAssertTrue(model.librarySortDescending)
        XCTAssertEqual(model.libraryProgressFilter, .inProgress)
        let selections = await service.pageSelections()
        XCTAssertEqual(
            selections,
            [
                PageSelection(
                    page: 0,
                    sort: .title,
                    descending: false,
                    filter: nil
                ),
                PageSelection(
                    page: 0,
                    sort: .addedAt,
                    descending: false,
                    filter: nil
                ),
                PageSelection(
                    page: 0,
                    sort: .addedAt,
                    descending: true,
                    filter: nil
                ),
                PageSelection(
                    page: 0,
                    sort: .addedAt,
                    descending: true,
                    filter: LibraryItemFilter(progress: .inProgress)
                ),
                PageSelection(
                    page: 1,
                    sort: .addedAt,
                    descending: true,
                    filter: LibraryItemFilter(progress: .inProgress)
                ),
            ]
        )
    }

    func testLoadingNextLibraryPageFailureKeepsExistingBooks()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let firstPage = LibraryItemsPage(
            items: [
                fixtureBook(
                    id: "item-1",
                    title: "First",
                    libraryID: library.id
                )
            ],
            total: 2,
            page: 0,
            limit: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(firstPage),
            nextPage: .failure(
                .libraryRepository(.remote(.unexpectedStatus(503)))
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadNextBooksPage()

        XCTAssertEqual(model.books, .loaded(firstPage))
        XCTAssertEqual(
            model.libraryPaginationState,
            .failed(.libraryUnavailable)
        )
    }

    func testLoadingWithoutAccountUsesTypedFailure() async {
        let service = TestAppService(activeAccount: .success(nil))
        let model = AppModel(service: service)

        await model.loadLibraries()
        XCTAssertEqual(model.libraries, .failed(.accountUnavailable))

        await model.selectLibrary(fixtureLibrary())
        XCTAssertEqual(model.books, .failed(.accountUnavailable))
        XCTAssertEqual(
            model.homeShelves,
            .failed(.accountUnavailable)
        )

        await model.removeAccount()
        XCTAssertEqual(
            model.accountActionStatus,
            .failed(.accountUnavailable)
        )

        await model.search(query: "a book")
        XCTAssertEqual(
            model.searchResults,
            .failed(.accountUnavailable)
        )

        let book = fixturePage(libraryID: fixtureLibrary().id).items[0]
        await model.loadBookDetail(book)
        XCTAssertEqual(model.selectedBookID, book.id)
        XCTAssertEqual(
            model.bookDetail,
            .failed(.accountUnavailable)
        )
    }

    func testSearchTrimsQueryAndPublishesResults() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let result = fixturePage(libraryID: library.id).items
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            search: .success(result)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.search(query: "  A Book  ")

        XCTAssertEqual(model.searchQuery, "  A Book  ")
        XCTAssertEqual(model.searchResults, .loaded(result))
        let requests = await service.searchRequests()
        XCTAssertEqual(
            requests,
            [
                SearchRequest(
                    accountID: account.id,
                    libraryID: library.id,
                    query: "A Book"
                )
            ]
        )
    }

    func testBlankSearchClearsWithoutCallingService() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.search(query: "   ")

        XCTAssertEqual(model.searchResults, .idle)
        let requests = await service.searchRequests()
        XCTAssertEqual(requests, [])
    }

    func testSearchFailureRemainsTyped() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            search: .failure(
                .searchCoordinator(
                    .repository(.remote(.unexpectedStatus(503)))
                )
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.search(query: "a book")

        XCTAssertEqual(model.searchResults, .failed(.searchUnavailable))
    }

    func testSupersededSearchCannotPublishLateResult() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let oldResult = fixturePage(libraryID: library.id).items
        let newResult = [
            LibraryBookSummary(
                id: LibraryItemID(rawValue: "item-2"),
                libraryID: library.id,
                title: "New Result",
                subtitle: nil,
                authorName: nil,
                narratorName: nil,
                seriesName: nil,
                genres: [],
                publisher: nil,
                publishedYear: nil,
                duration: 1,
                trackCount: 1,
                chapterCount: 0,
                addedAtMilliseconds: 1,
                updatedAtMilliseconds: 1,
                isExplicit: false,
                isAbridged: false
            )
        ]
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(fixturePage(libraryID: library.id)),
            search: .success(oldResult),
            searchGate: gate
        )
        let model = AppModel(service: service)
        await model.start()

        let oldSearch = Task { @MainActor in
            await model.search(query: "old")
        }
        await gate.waitUntilEntered()
        await service.setSearch(.success(newResult))

        await model.search(query: "new")
        await gate.release()
        await oldSearch.value

        XCTAssertEqual(model.searchQuery, "new")
        XCTAssertEqual(model.searchResults, .loaded(newResult))
    }

    func testChangingLibraryResetsSearchState() async throws {
        let account = try fixtureAccount()
        let firstLibrary = fixtureLibrary()
        let secondLibrary = LibrarySummary(
            id: LibraryID(rawValue: "library-2"),
            name: "Second Library",
            mediaType: .book
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([firstLibrary, secondLibrary]),
            firstPage: .success(fixturePage(libraryID: firstLibrary.id)),
            search: .success([])
        )
        let model = AppModel(service: service)
        await model.start()
        await model.search(query: "query")

        await service.setFirstPage(
            .success(fixturePage(libraryID: secondLibrary.id))
        )
        await model.selectLibrary(secondLibrary)

        XCTAssertEqual(model.searchQuery, "")
        XCTAssertEqual(model.searchResults, .idle)
    }

    func testBookDetailLoadsForExactAccountLibraryAndItem() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let bookmark = AudioBookmark(
            libraryItemID: detail.id,
            time: 600,
            title: "A useful moment",
            createdAtMilliseconds: 1
        )
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            bookmarks: .success([bookmark])
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadBookDetail(page.items[0])

        XCTAssertEqual(model.selectedBookID, detail.id)
        XCTAssertEqual(model.bookDetail, .loaded(detail))
        XCTAssertEqual(model.bookBookmarks, .loaded([bookmark]))
        let requests = await service.bookDetailRequests()
        XCTAssertEqual(
            requests,
            [
                BookDetailRequest(
                    accountID: account.id,
                    libraryID: library.id,
                    itemID: detail.id
                )
            ]
        )
        let bookmarkRequests = await service.bookmarkRequests()
        XCTAssertEqual(
            bookmarkRequests,
            [
                BookmarkRequest(
                    accountID: account.id,
                    itemID: detail.id
                )
            ]
        )
    }

    func testBookDetailBookmarkFailureDoesNotHideDetail() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            bookmarks: .failure(.bookmark(.requestFailed))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadBookDetail(page.items[0])

        XCTAssertEqual(model.bookDetail, .loaded(detail))
        XCTAssertEqual(
            model.bookBookmarks,
            .failed(.bookmarkUnavailable)
        )
    }

    func testBookDetailFailureRemainsTyped() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .failure(.bookDetail(.noCachedValue))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.loadBookDetail(page.items[0])

        XCTAssertEqual(model.bookDetail, .failed(.bookUnavailable))
    }

    func testMetadataSaveForwardsDraftAndPublishesSuccess() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail)
        )
        let model = AppModel(service: service)
        await model.start()
        var draft = BookMetadataDraft(detail: detail)
        draft.title = "Updated title"

        await model.saveBookEdits(
            draft: draft,
            baseline: detail,
            coverJPEGData: nil
        )

        XCTAssertEqual(model.bookEditSaveState, .saved)
        XCTAssertEqual(model.bookDetail, .loaded(detail))
        let requests = await service.metadataSaveRequests()
        XCTAssertEqual(
            requests,
            [
                MetadataSaveRequest(
                    accountID: account.id,
                    baseline: detail,
                    draft: draft,
                    overwrite: false
                )
            ]
        )
    }

    func testBookEditSavesMetadataBeforeUploadingStagedCover() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            metadataSave: .success(.saved(detail)),
            coverReplacement: .success(detail)
        )
        let model = AppModel(service: service)
        await model.start()
        var draft = BookMetadataDraft(detail: detail)
        draft.title = "Updated title"

        await model.saveBookEdits(
            draft: draft,
            baseline: detail,
            coverJPEGData: jpegData
        )

        XCTAssertEqual(model.bookEditSaveState, .saved)
        let coverRequests = await service.coverReplacementRequests()
        XCTAssertEqual(
            coverRequests,
            [
                CoverReplacementRequest(
                    accountID: account.id,
                    detail: detail,
                    jpegData: jpegData
                )
            ]
        )
    }

    func testBookEditRetainsSavedMetadataWhenCoverUploadFails()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            metadataSave: .success(.saved(detail)),
            coverReplacement: .failure(
                .coverUpdate(.uploadRejected)
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.saveBookEdits(
            draft: BookMetadataDraft(detail: detail),
            baseline: detail,
            coverJPEGData: Data([1])
        )

        XCTAssertEqual(
            model.bookEditSaveState,
            .metadataSavedCoverFailed(detail, .metadataUnavailable)
        )
        XCTAssertEqual(model.bookDetail, .loaded(detail))
    }

    func testBookDeletionForwardsModeAndRefreshesLibrary()
        async throws
    {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail),
            bookDeletion: .success(
                .deletedWithCacheCleanupFailure
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.deleteBook(
            detail,
            mode: .libraryRecordAndFiles
        )

        let deletionRequests = await service.bookDeletionRequests()
        XCTAssertEqual(
            deletionRequests,
            [
                BookDeletionRequest(
                    accountID: account.id,
                    detail: detail,
                    mode: .libraryRecordAndFiles
                )
            ]
        )
        XCTAssertEqual(
            model.bookDeletionState,
            .deleted(
                BookDeletionCleanupStatus(
                    cacheCleanupFailed: true,
                    localDownloadCleanupFailed: false
                )
            )
        )
        let pageRequestCount = await service.pageRequests().count
        XCTAssertEqual(pageRequestCount, 2)
    }

    func testSetFinishedUpdatesProgressAndRefetchesDetail() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let service = TestAppService(
            activeAccount: .success(account),
            bookDetail: .success(detail)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setFinished(true, detail: detail)

        XCTAssertEqual(model.bookProgressUpdateState, .saved)
        XCTAssertEqual(model.bookDetail, .loaded(detail))
        let updates = await service.progressUpdateRequests()
        XCTAssertEqual(
            updates,
            [
                ProgressUpdateRequest(
                    accountID: account.id,
                    itemID: detail.id,
                    update: BookProgressUpdate(isFinished: true)
                )
            ]
        )
        let detailRequests = await service.bookDetailRequests()
        XCTAssertEqual(
            detailRequests,
            [
                BookDetailRequest(
                    accountID: account.id,
                    libraryID: library.id,
                    itemID: detail.id
                )
            ]
        )
    }

    func testSetFinishedFailureDoesNotRefetchDetail() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let item = fixturePage(libraryID: library.id).items[0]
        let detail = fixtureBookDetail(item: item)
        let service = TestAppService(
            activeAccount: .success(account),
            progressUpdate: .failure(.progress(.unexpectedStatus(503)))
        )
        let model = AppModel(service: service)
        await model.start()

        await model.setFinished(false, detail: detail)

        XCTAssertEqual(
            model.bookProgressUpdateState,
            .failed(.progressUnavailable)
        )
        let detailRequests = await service.bookDetailRequests()
        XCTAssertTrue(detailRequests.isEmpty)
    }

    func testPlaybackStartRequestsAutomaticServerPreference() async throws {
        let fixture = try playbackRecoveryFixture()
        defer {
            fixture.cleanUp()
        }
        let account = try fixtureAccount()
        let preparation = AppPlaybackPreparation(
            sessionID: PlaybackSessionID(rawValue: "session"),
            itemID: fixture.detail.id,
            title: fixture.detail.title,
            duration: 1,
            currentTime: 0,
            chapters: fixture.detail.chapters,
            source: .direct([
                AppPlaybackTrack(
                    url: fixture.audioURL,
                    startOffset: 0,
                    duration: 1,
                    title: "Track 1"
                )
            ])
        )
        let service = TestAppService(
            activeAccount: .success(account),
            playback: [.success(preparation)]
        )
        let playback = fixture.model(
            activation: TestAudioSessionActivation(),
            service: service
        )

        await playback.start(detail: fixture.detail, account: account)

        let requests = await service.playbackOpenRequests()
        XCTAssertEqual(
            requests,
            [
                PlaybackOpenRequest(
                    accountID: account.id,
                    itemID: fixture.detail.id,
                    preference: .automatic
                )
            ]
        )
        await playback.stop()
    }

    func testPlaybackSessionFailureRemainsTyped() async throws {
        let account = try fixtureAccount()
        let library = fixtureLibrary()
        let page = fixturePage(libraryID: library.id)
        let detail = fixtureBookDetail(item: page.items[0])
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([library]),
            firstPage: .success(page),
            bookDetail: .success(detail)
        )
        let model = AppModel(service: service)
        await model.start()

        await model.playback.start(detail: detail, account: account)

        XCTAssertEqual(
            model.playback.state,
            .failed(.playbackUnavailable)
        )
        XCTAssertEqual(model.playback.itemID, detail.id)
    }

    func testRemoveAccountClearsSignedInState() async throws {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([])
        )
        let model = AppModel(service: service)
        await model.start()

        await model.removeAccount()

        let removedAccounts = await service.removedAccounts()
        XCTAssertEqual(removedAccounts, [account])
        XCTAssertEqual(model.phase, .signedOut)
        XCTAssertNil(model.account)
        XCTAssertNil(model.selectedLibrary)
        XCTAssertEqual(model.libraries, .idle)
        XCTAssertEqual(model.books, .idle)
        XCTAssertEqual(model.homeShelves, .idle)
        XCTAssertEqual(model.accountActionStatus, .idle)
    }

    func testRemoveAccountFailurePreservesSignedInState() async throws {
        let account = try fixtureAccount()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([]),
            removeAccount: .failure(
                .accountRemoval(.logoutRequestFailed)
            )
        )
        let model = AppModel(service: service)
        await model.start()

        await model.removeAccount()

        XCTAssertEqual(model.phase, .signedIn)
        XCTAssertEqual(model.account, account)
        XCTAssertEqual(
            model.accountActionStatus,
            .failed(.accountRemovalFailed)
        )
    }

    func testConcurrentAccountRemovalIsIgnored() async throws {
        let account = try fixtureAccount()
        let gate = AsyncGate()
        let service = TestAppService(
            activeAccount: .success(account),
            libraries: .success([]),
            removeGate: gate
        )
        let model = AppModel(service: service)
        await model.start()

        let firstRemoval = Task { @MainActor in
            await model.removeAccount()
        }
        await gate.waitUntilEntered()

        await model.removeAccount()
        await gate.release()
        await firstRemoval.value

        let removalCount = await service.removedAccounts().count
        XCTAssertEqual(removalCount, 1)
        XCTAssertEqual(model.phase, .signedOut)
    }

    func testServiceErrorsMapToStablePresentationFailures() {
        let cases: [(AppServiceError, AppFailure)] = [
            (.invalidServerURL(.empty), .invalidServerAddress),
            (
                .invalidServerURL(.unsupportedScheme("http")),
                .serverRequiresHTTPS
            ),
            (.discovery(.uninitialized), .serverNotReady),
            (
                .discovery(.unsupportedServerVersion("2.25.0")),
                .serverUnsupported
            ),
            (
                .discovery(.invalidServerVersion("not-a-version")),
                .serverUnsupported
            ),
            (
                .discovery(.unexpectedHTTPStatus(500)),
                .serverUnavailable
            ),
            (.discoveryRequestFailed, .serverUnavailable),
            (
                .onboarding(.localAuthenticationUnavailable),
                .localLoginUnavailable
            ),
            (
                .onboarding(
                    .authenticationFailed(.invalidCredentials)
                ),
                .invalidCredentials
            ),
            (
                .onboarding(
                    .authenticationFailed(
                        .credentialStorageUnavailable
                    )
                ),
                .secureCredentialStorageUnavailable
            ),
            (
                .onboarding(
                    .authenticationFailed(.malformedLoginResponse)
                ),
                .loginFailed
            ),
            (
                .onboarding(.authenticationRequestFailed),
                .loginFailed
            ),
            (.accountStore(.persistenceFailed), .accountUnavailable),
            (
                .libraryRepository(.noCachedValue),
                .libraryUnavailable
            ),
            (.pageRequest(.invalidPage), .libraryUnavailable),
            (.homeRequest(.invalidLimit), .homeUnavailable),
            (.searchRequest(.invalidQuery), .searchUnavailable),
            (
                .searchCoordinator(.cancelled),
                .searchUnavailable
            ),
            (.bookDetail(.noCachedValue), .bookUnavailable),
            (
                .playbackSession(.requestFailed),
                .playbackUnavailable
            ),
            (
                .playbackSource(.missingAudioTracks),
                .playbackUnavailable
            ),
            (
                .playbackSync(.unexpectedStatus(503)),
                .playbackUnavailable
            ),
            (
                .localPlaybackSession(.unexpectedStatus(503)),
                .progressUnavailable
            ),
            (
                .progress(.unexpectedStatus(503)),
                .progressUnavailable
            ),
            (.metadataPatch(.emptyTitle), .invalidMetadata),
            (
                .metadataUpdate(.unexpectedStatus(503)),
                .metadataUnavailable
            ),
            (.downloadPlan(.unexpectedStatus(503)), .mediaUnavailable),
            (
                .downloadAuthorization(.invalidAccountID),
                .mediaUnavailable
            ),
            (.coverUpdate(.uploadRejected), .metadataUnavailable),
            (
                .accountRemoval(.logoutRequestFailed),
                .accountRemovalFailed
            ),
            (
                .libraryCache(.persistenceFailed),
                .accountRemovalFailed
            ),
        ]

        for (error, expected) in cases {
            XCTAssertEqual(
                AppFailure(serviceError: error),
                expected,
                "Unexpected mapping for \(error)"
            )
        }
    }

    func testPresentationFailuresHaveUserMessages() {
        let failures: [AppFailure] = [
            .persistenceUnavailable,
            .invalidServerAddress,
            .serverUnavailable,
            .serverRequiresHTTPS,
            .serverNotReady,
            .serverUnsupported,
            .localLoginUnavailable,
            .invalidCredentials,
            .secureCredentialStorageUnavailable,
            .loginFailed,
            .accountUnavailable,
            .libraryUnavailable,
            .homeUnavailable,
            .searchUnavailable,
            .bookUnavailable,
            .playbackDenied,
            .playbackUnavailable,
            .progressUnavailable,
            .mediaUnavailable,
            .invalidMetadata,
            .metadataUnavailable,
            .bookmarkUnavailable,
            .accountRemovalFailed,
        ]

        XCTAssertTrue(failures.allSatisfy { !$0.message.isEmpty })
        XCTAssertEqual(Set(failures.map(\.message)).count, failures.count)
    }

    func testSecureCredentialStorageFailureHasRedactedDiagnosticCode() {
        let failure = AppFailure(
            serviceError: .onboarding(
                .authenticationFailed(
                    .credentialStorageUnavailable
                )
            )
        )

        XCTAssertEqual(
            failure,
            .secureCredentialStorageUnavailable
        )
        XCTAssertEqual(
            failure.diagnosticFailureCode,
            .secureCredentialStorageUnavailable
        )
        XCTAssertEqual(
            failure.diagnosticFailureCode.rawValue,
            "secure_credential_storage_unavailable"
        )
    }

    private func fixtureAccount(
        accountID: String = "account-1",
        userID: String = "user-1",
        username: String = "reader",
        server: String = "https://books.example"
    ) throws -> ServerAccount {
        try ServerAccount(
            id: AccountID(rawValue: accountID),
            server: NormalizedServerURL(server),
            serverVersion: "2.36.0",
            authenticationMethods: [.local],
            user: AuthenticatedUser(
                id: UserID(rawValue: userID),
                username: username,
                type: .user,
                permissions: UserPermissions(
                    download: true,
                    update: false,
                    delete: false,
                    upload: false,
                    createEReader: false,
                    accessAllLibraries: true,
                    accessAllTags: true,
                    accessExplicitContent: true,
                    selectedTagsNotAccessible: false
                ),
                accessibleLibraryIDs: [],
                selectedItemTags: []
            )
        )
    }

    private func fixtureLibrary() -> LibrarySummary {
        LibrarySummary(
            id: LibraryID(rawValue: "library-1"),
            name: "Audiobooks",
            mediaType: .book
        )
    }

    private func fixturePage(libraryID: LibraryID) -> LibraryItemsPage {
        LibraryItemsPage(
            items: [
                fixtureBook(
                    id: "item-1",
                    title: "A Book",
                    libraryID: libraryID
                )
            ],
            total: 1,
            page: 0,
            limit: 50
        )
    }

    private func fixtureBook(
        id: String,
        title: String,
        libraryID: LibraryID
    ) -> LibraryBookSummary {
        LibraryBookSummary(
            id: LibraryItemID(rawValue: id),
            libraryID: libraryID,
            title: title,
            subtitle: nil,
            authorName: "An Author",
            narratorName: "A Narrator",
            seriesName: nil,
            genres: ["Fiction"],
            publisher: nil,
            publishedYear: "2026",
            duration: 3_600,
            trackCount: 1,
            chapterCount: 2,
            addedAtMilliseconds: 1,
            updatedAtMilliseconds: 2,
            isExplicit: false,
            isAbridged: false
        )
    }

    private func fixtureBookDetail(
        item: LibraryBookSummary
    ) -> LibraryBookDetail {
        LibraryBookDetail(
            id: item.id,
            libraryID: item.libraryID,
            bookID: BookID(rawValue: "book-1"),
            title: item.title,
            subtitle: "A subtitle",
            authors: [
                LibraryBookContributor(
                    id: "author-1",
                    name: "An Author"
                )
            ],
            narrators: ["A Narrator"],
            series: [],
            genres: item.genres,
            tags: [],
            publishedYear: item.publishedYear,
            publishedDate: nil,
            publisher: item.publisher,
            descriptionPlain: "A detailed description.",
            isbn: nil,
            asin: nil,
            language: "English",
            duration: item.duration,
            trackCount: item.trackCount,
            audioFileCount: item.trackCount,
            chapters: [],
            addedAtMilliseconds: item.addedAtMilliseconds,
            updatedAtMilliseconds: item.updatedAtMilliseconds,
            isExplicit: item.isExplicit,
            isAbridged: item.isAbridged,
            progress: nil
        )
    }

    private func fixtureShelves(
        libraryID: LibraryID
    ) -> [LibraryBookShelf] {
        [
            LibraryBookShelf(
                id: "continue-listening",
                label: "Continue Listening",
                labelLocalizationKey: nil,
                items: fixturePage(libraryID: libraryID).items,
                total: 1
            )
        ]
    }

    private static func downloadPlanJSON(secondSize: Int) -> String {
        """
        {
          "id": "item-1",
          "media": {
            "audioFiles": [
              {
                "ino": "1",
                "mimeType": "audio/mpeg",
                "metadata": {"filename": "one.mp3", "size": 4}
              },
              {
                "ino": "2",
                "mimeType": "audio/mpeg",
                "metadata": {
                  "filename": "two.mp3",
                  "size": \(secondSize)
                }
              }
            ]
          }
        }
        """
    }

    private func localSession(
        id: String,
        itemID: String
    ) throws -> LocalPlaybackSession {
        try LocalPlaybackSession(
            id: PlaybackSessionID(rawValue: id),
            libraryID: LibraryID(rawValue: "library"),
            libraryItemID: LibraryItemID(rawValue: itemID),
            bookID: BookID(rawValue: "book-\(itemID)"),
            mediaMetadata: LocalPlaybackMediaMetadata(title: itemID),
            chapters: [],
            displayTitle: itemID,
            displayAuthor: "Author",
            duration: 100,
            startTime: 10,
            currentTime: 20,
            startedAtMilliseconds: 1_000,
            updatedAtMilliseconds: 2_000
        )
    }

    private func playbackRecoveryFixture() throws -> PlaybackRecoveryFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "BleatPlaybackRecovery-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let audioURL = root.appendingPathComponent("silence.caf")
        let format = try XCTUnwrap(
            AVAudioFormat(
                standardFormatWithSampleRate: 8_000,
                channels: 1
            )
        )
        let audioFile = try AVAudioFile(
            forWriting: audioURL,
            settings: format.settings
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: 8_000
            )
        )
        buffer.frameLength = 8_000
        try audioFile.write(from: buffer)

        let defaultsSuite = "PlaybackRecoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: defaultsSuite)
        )
        let item = fixturePage(libraryID: fixtureLibrary().id).items[0]
        return PlaybackRecoveryFixture(
            root: root,
            defaultsSuite: defaultsSuite,
            defaults: defaults,
            audioURL: audioURL,
            accountID: AccountID(rawValue: "recovery-account"),
            detail: fixtureBookDetail(item: item),
            service: TestAppService(activeAccount: .success(nil))
        )
    }
}

@MainActor
private final class TestAudioSessionActivation: @unchecked Sendable {
    private(set) var callCount = 0

    func activate() {
        callCount += 1
    }
}

@MainActor
private final class TestPlaybackQueuePlanning: @unchecked Sendable {
    private let failingCall: Int?
    private(set) var callCount = 0

    init(failingCall: Int? = nil) {
        self.failingCall = failingCall
    }

    func make(
        preparation: AppPlaybackPreparation,
        wholeBookTime: Double
    ) throws -> AppPlaybackQueuePlan {
        callCount += 1
        if callCount == failingCall {
            throw AppPlaybackBuildError.missingTracks
        }
        return try AppPlaybackQueuePlanner.make(
            preparation: preparation,
            wholeBookTime: wholeBookTime
        )
    }
}

@MainActor
private struct PlaybackRecoveryFixture {
    let root: URL
    let defaultsSuite: String
    let defaults: UserDefaults
    let audioURL: URL
    let accountID: AccountID
    let detail: LibraryBookDetail
    let service: TestAppService

    func model(
        activation: TestAudioSessionActivation,
        service: TestAppService? = nil,
        queuePlanning:
            @escaping @MainActor @Sendable (
                AppPlaybackPreparation,
                Double
            ) throws -> AppPlaybackQueuePlan = {
                try AppPlaybackQueuePlanner.make(
                    preparation: $0,
                    wholeBookTime: $1
                )
            }
    ) -> PlaybackModel {
        PlaybackModel(
            service: service ?? self.service,
            positionStore: PlaybackPositionStore(defaults: defaults),
            localSessionStore: LocalPlaybackSessionStore(defaults: defaults),
            bookmarkMutationStore: BookmarkMutationStore(
                defaults: defaults
            ),
            preferencesStore: PlaybackPreferencesStore(defaults: defaults),
            audioSessionActivation: {
                activation.activate()
            },
            queuePlanning: queuePlanning
        )
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: defaultsSuite)
        try? FileManager.default.removeItem(at: root)
    }
}

private struct LoginRequest: Equatable, Sendable {
    let serverAddress: String
    let username: String
    let password: String
}

private struct ReauthenticationRequest: Equatable, Sendable {
    let accountID: AccountID
    let password: String
}

private struct PlaybackOpenRequest: Equatable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
    let preference: PlaybackPreference
}

private struct SearchRequest: Equatable, Sendable {
    let accountID: AccountID
    let libraryID: LibraryID
    let query: String
}

private struct PageSelection: Equatable, Sendable {
    let page: Int
    let sort: LibraryItemSort
    let descending: Bool
    let filter: LibraryItemFilter?
}

private struct BookDetailRequest: Equatable, Sendable {
    let accountID: AccountID
    let libraryID: LibraryID
    let itemID: LibraryItemID
}

private struct BookmarkRequest: Equatable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
}

private struct MetadataSaveRequest: Equatable, Sendable {
    let accountID: AccountID
    let baseline: LibraryBookDetail
    let draft: BookMetadataDraft
    let overwrite: Bool
}

private struct CoverReplacementRequest: Equatable, Sendable {
    let accountID: AccountID
    let detail: LibraryBookDetail
    let jpegData: Data
}

private struct BookDeletionRequest: Equatable, Sendable {
    let accountID: AccountID
    let detail: LibraryBookDetail
    let mode: BookDeletionMode
}

private struct ProgressUpdateRequest: Equatable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
    let update: BookProgressUpdate
}

private struct LocalSessionSyncRequest: Equatable, Sendable {
    let accountID: AccountID
    let sessions: [LocalPlaybackSession]
    let deviceInfo: PlaybackDeviceInfo
}

private actor TestAppService: AppServicing {
    private var accountsResult: Result<[ServerAccount], AppServiceError>?
    private var activeAccountResult:
        Result<
            ServerAccount?,
            AppServiceError
        >
    private var loginResult: Result<ServerAccount, AppServiceError>
    private var librariesResult:
        Result<
            [LibrarySummary],
            AppServiceError
        >
    private var firstPageResult:
        Result<
            LibraryItemsPage,
            AppServiceError
        >
    private var nextPageResult:
        Result<
            LibraryItemsPage,
            AppServiceError
        >
    private var homeShelvesResult:
        Result<
            [LibraryBookShelf],
            AppServiceError
        >
    private var searchResult:
        Result<
            [LibraryBookSummary],
            AppServiceError
        >
    private var bookDetailResult:
        Result<
            LibraryBookDetail,
            AppServiceError
        >
    private var bookmarksResult:
        Result<
            [AudioBookmark],
            AppServiceError
        >
    private var metadataSaveResult:
        Result<AppMetadataSaveOutcome, AppServiceError>?
    private var coverReplacementResult:
        Result<LibraryBookDetail, AppServiceError>?
    private var bookDeletionResult:
        Result<AppBookDeletionOutcome, AppServiceError>
    private var progressUpdateResult: Result<Void, AppServiceError>
    private var localSessionSyncResult:
        Result<[LocalPlaybackSessionSyncResult], AppServiceError>
    private var playbackResults:
        [Result<AppPlaybackPreparation, AppServiceError>]
    private var removeAccountResult: Result<Void, AppServiceError>
    private let loginGate: AsyncGate?
    private let removeGate: AsyncGate?
    private let searchGate: AsyncGate?

    private var activeAccountRequests = 0
    private var recordedActivatedAccounts: [ServerAccount] = []
    private var recordedLogins: [LoginRequest] = []
    private var recordedReauthentications: [ReauthenticationRequest] = []
    private var recordedPageRequests: [LibraryID] = []
    private var recordedPageSelections: [PageSelection] = []
    private var recordedHomeRequests: [LibraryID] = []
    private var recordedSearchRequests: [SearchRequest] = []
    private var recordedBookDetailRequests: [BookDetailRequest] = []
    private var recordedPlaybackOpenRequests: [PlaybackOpenRequest] = []
    private var recordedBookmarkRequests: [BookmarkRequest] = []
    private var recordedMetadataSaveRequests: [MetadataSaveRequest] = []
    private var recordedCoverReplacementRequests: [CoverReplacementRequest] = []
    private var recordedBookDeletionRequests: [BookDeletionRequest] = []
    private var recordedProgressUpdateRequests: [ProgressUpdateRequest] = []
    private var recordedLocalSessionSyncRequests: [LocalSessionSyncRequest] = []
    private var recordedRemovedAccounts: [ServerAccount] = []

    init(
        accounts: Result<[ServerAccount], AppServiceError>? = nil,
        activeAccount: Result<ServerAccount?, AppServiceError>,
        login: Result<ServerAccount, AppServiceError> = .failure(
            .onboarding(.authenticationRequestFailed)
        ),
        libraries: Result<[LibrarySummary], AppServiceError> = .success([]),
        firstPage: Result<LibraryItemsPage, AppServiceError> = .failure(
            .libraryRepository(.noCachedValue)
        ),
        nextPage: Result<LibraryItemsPage, AppServiceError> = .failure(
            .libraryRepository(.noCachedValue)
        ),
        homeShelves: Result<[LibraryBookShelf], AppServiceError> = .success(
            []
        ),
        search: Result<[LibraryBookSummary], AppServiceError> = .failure(
            .searchCoordinator(.repository(.noCachedValue))
        ),
        bookDetail: Result<LibraryBookDetail, AppServiceError> = .failure(
            .bookDetail(.noCachedValue)
        ),
        bookmarks: Result<[AudioBookmark], AppServiceError> = .success([]),
        metadataSave:
            Result<AppMetadataSaveOutcome, AppServiceError>? = nil,
        coverReplacement:
            Result<LibraryBookDetail, AppServiceError>? = nil,
        bookDeletion:
            Result<AppBookDeletionOutcome, AppServiceError> = .success(
                .deleted
            ),
        progressUpdate: Result<Void, AppServiceError> = .success(()),
        localSessionSync:
            Result<
                [LocalPlaybackSessionSyncResult],
                AppServiceError
            > = .success([]),
        playback:
            [Result<AppPlaybackPreparation, AppServiceError>] = [],
        removeAccount: Result<Void, AppServiceError> = .success(()),
        loginGate: AsyncGate? = nil,
        removeGate: AsyncGate? = nil,
        searchGate: AsyncGate? = nil
    ) {
        accountsResult = accounts
        activeAccountResult = activeAccount
        loginResult = login
        librariesResult = libraries
        firstPageResult = firstPage
        nextPageResult = nextPage
        homeShelvesResult = homeShelves
        searchResult = search
        bookDetailResult = bookDetail
        bookmarksResult = bookmarks
        metadataSaveResult = metadataSave
        coverReplacementResult = coverReplacement
        bookDeletionResult = bookDeletion
        progressUpdateResult = progressUpdate
        localSessionSyncResult = localSessionSync
        playbackResults = playback
        removeAccountResult = removeAccount
        self.loginGate = loginGate
        self.removeGate = removeGate
        self.searchGate = searchGate
    }

    func accounts()
        async throws(AppServiceError) -> [ServerAccount]
    {
        if let accountsResult {
            return try value(from: accountsResult)
        }
        switch activeAccountResult {
        case .success(let account):
            return account.map { [$0] } ?? []
        case .failure(let error):
            throw error
        }
    }

    func activeAccount()
        async throws(AppServiceError) -> ServerAccount?
    {
        activeAccountRequests += 1
        return try value(from: activeAccountResult)
    }

    func activateAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        recordedActivatedAccounts.append(account)
    }

    func login(
        serverAddress: String,
        username: String,
        password: String
    ) async throws(AppServiceError) -> ServerAccount {
        recordedLogins.append(
            LoginRequest(
                serverAddress: serverAddress,
                username: username,
                password: password
            )
        )
        if let loginGate {
            await loginGate.enterAndWait()
        }
        return try value(from: loginResult)
    }

    func reauthenticate(
        _ account: ServerAccount,
        password: String
    ) async throws(AppServiceError) -> ServerAccount {
        recordedReauthentications.append(
            ReauthenticationRequest(
                accountID: account.id,
                password: password
            )
        )
        return try value(from: loginResult)
    }

    func libraries(
        for account: ServerAccount
    ) async throws(AppServiceError) -> [LibrarySummary] {
        try value(from: librariesResult)
    }

    func page(
        for account: ServerAccount,
        libraryID: LibraryID,
        page: Int,
        sort: LibraryItemSort,
        descending: Bool,
        filter: LibraryItemFilter?
    ) async throws(AppServiceError) -> LibraryItemsPage {
        recordedPageRequests.append(libraryID)
        recordedPageSelections.append(
            PageSelection(
                page: page,
                sort: sort,
                descending: descending,
                filter: filter
            )
        )
        if page == 0 {
            return try value(from: firstPageResult)
        }
        return try value(from: nextPageResult)
    }

    func homeShelves(
        for account: ServerAccount,
        libraryID: LibraryID
    ) async throws(AppServiceError) -> [LibraryBookShelf] {
        recordedHomeRequests.append(libraryID)
        return try value(from: homeShelvesResult)
    }

    func search(
        for account: ServerAccount,
        libraryID: LibraryID,
        query: String
    ) async throws(AppServiceError) -> [LibraryBookSummary] {
        recordedSearchRequests.append(
            SearchRequest(
                accountID: account.id,
                libraryID: libraryID,
                query: query
            )
        )
        let result = searchResult
        if recordedSearchRequests.count == 1,
            let searchGate
        {
            await searchGate.enterAndWait()
        }
        return try value(from: result)
    }

    func openPlayback(
        for account: ServerAccount,
        itemID: LibraryItemID,
        preference: PlaybackPreference,
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> AppPlaybackPreparation {
        recordedPlaybackOpenRequests.append(
            PlaybackOpenRequest(
                accountID: account.id,
                itemID: itemID,
                preference: preference
            )
        )
        guard !playbackResults.isEmpty else {
            throw .playbackSession(.requestFailed)
        }
        return try value(from: playbackResults.removeFirst())
    }

    func closePlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID
    ) async throws(AppServiceError) {}

    func syncPlayback(
        for account: ServerAccount,
        sessionID: PlaybackSessionID,
        currentTime: Double,
        duration: Double
    ) async throws(AppServiceError) {}

    func syncLocalPlaybackSessions(
        for account: ServerAccount,
        sessions: [LocalPlaybackSession],
        deviceInfo: PlaybackDeviceInfo
    ) async throws(AppServiceError) -> [LocalPlaybackSessionSyncResult] {
        recordedLocalSessionSyncRequests.append(
            LocalSessionSyncRequest(
                accountID: account.id,
                sessions: sessions,
                deviceInfo: deviceInfo
            )
        )
        return try value(from: localSessionSyncResult)
    }

    func bookDetail(
        for account: ServerAccount,
        libraryID: LibraryID,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookDetail {
        recordedBookDetailRequests.append(
            BookDetailRequest(
                accountID: account.id,
                libraryID: libraryID,
                itemID: itemID
            )
        )
        return try value(from: bookDetailResult)
    }

    func saveMetadata(
        for account: ServerAccount,
        baseline: LibraryBookDetail,
        draft: BookMetadataDraft,
        overwrite: Bool
    ) async throws(AppServiceError) -> AppMetadataSaveOutcome {
        recordedMetadataSaveRequests.append(
            MetadataSaveRequest(
                accountID: account.id,
                baseline: baseline,
                draft: draft,
                overwrite: overwrite
            )
        )
        if let metadataSaveResult {
            return try value(from: metadataSaveResult)
        }
        return .saved(baseline)
    }

    func downloadPlan(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> DownloadPlan {
        throw .downloadPlan(.invalidItemID)
    }

    func authorizedDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity
    ) async throws(AppServiceError) -> URLRequest {
        throw .downloadAuthorization(.invalidAccountID)
    }

    func replacementDownloadRequest(
        for account: ServerAccount,
        identity: DownloadTaskIdentity,
        rejectedRequest: URLRequest
    ) async throws(AppServiceError) -> URLRequest {
        throw .downloadAuthorization(.invalidAccountID)
    }

    func replaceCover(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        jpegData: Data
    ) async throws(AppServiceError) -> LibraryBookDetail {
        recordedCoverReplacementRequests.append(
            CoverReplacementRequest(
                accountID: account.id,
                detail: detail,
                jpegData: jpegData
            )
        )
        if let coverReplacementResult {
            return try value(from: coverReplacementResult)
        }
        return detail
    }

    func deleteBook(
        for account: ServerAccount,
        detail: LibraryBookDetail,
        mode: BookDeletionMode
    ) async throws(AppServiceError) -> AppBookDeletionOutcome {
        recordedBookDeletionRequests.append(
            BookDeletionRequest(
                accountID: account.id,
                detail: detail,
                mode: mode
            )
        )
        return try value(from: bookDeletionResult)
    }

    func bookmarks(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> [AudioBookmark] {
        recordedBookmarkRequests.append(
            BookmarkRequest(
                accountID: account.id,
                itemID: itemID
            )
        )
        return try value(from: bookmarksResult)
    }

    func createBookmark(
        for account: ServerAccount,
        itemID: LibraryItemID,
        time: Double,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark {
        AudioBookmark(
            libraryItemID: itemID,
            time: time,
            title: title,
            createdAtMilliseconds: 1
        )
    }

    func renameBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark,
        title: String
    ) async throws(AppServiceError) -> AudioBookmark {
        AudioBookmark(
            libraryItemID: bookmark.libraryItemID,
            time: bookmark.time,
            title: title,
            createdAtMilliseconds: bookmark.createdAtMilliseconds
        )
    }

    func deleteBookmark(
        for account: ServerAccount,
        bookmark: AudioBookmark
    ) async throws(AppServiceError) {}

    func bookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID
    ) async throws(AppServiceError) -> LibraryBookProgress? {
        nil
    }

    func updateBookProgress(
        for account: ServerAccount,
        itemID: LibraryItemID,
        update: BookProgressUpdate
    ) async throws(AppServiceError) {
        recordedProgressUpdateRequests.append(
            ProgressUpdateRequest(
                accountID: account.id,
                itemID: itemID,
                update: update
            )
        )
        try value(from: progressUpdateResult)
    }

    func removeAccount(
        _ account: ServerAccount
    ) async throws(AppServiceError) {
        recordedRemovedAccounts.append(account)
        if let removeGate {
            await removeGate.enterAndWait()
        }
        try value(from: removeAccountResult)
    }

    func setLibraries(
        _ result: Result<[LibrarySummary], AppServiceError>
    ) {
        librariesResult = result
    }

    func setFirstPage(
        _ result: Result<LibraryItemsPage, AppServiceError>
    ) {
        firstPageResult = result
    }

    func setSearch(
        _ result: Result<[LibraryBookSummary], AppServiceError>
    ) {
        searchResult = result
    }

    func activeAccountRequestCount() -> Int {
        activeAccountRequests
    }

    func activatedAccounts() -> [ServerAccount] {
        recordedActivatedAccounts
    }

    func loginRequests() -> [LoginRequest] {
        recordedLogins
    }

    func reauthenticationRequests() -> [ReauthenticationRequest] {
        recordedReauthentications
    }

    func pageRequests() -> [LibraryID] {
        recordedPageRequests
    }

    func pageSelections() -> [PageSelection] {
        recordedPageSelections
    }

    func homeRequests() -> [LibraryID] {
        recordedHomeRequests
    }

    func searchRequests() -> [SearchRequest] {
        recordedSearchRequests
    }

    func bookDetailRequests() -> [BookDetailRequest] {
        recordedBookDetailRequests
    }

    func playbackOpenRequests() -> [PlaybackOpenRequest] {
        recordedPlaybackOpenRequests
    }

    func bookmarkRequests() -> [BookmarkRequest] {
        recordedBookmarkRequests
    }

    func metadataSaveRequests() -> [MetadataSaveRequest] {
        recordedMetadataSaveRequests
    }

    func coverReplacementRequests() -> [CoverReplacementRequest] {
        recordedCoverReplacementRequests
    }

    func bookDeletionRequests() -> [BookDeletionRequest] {
        recordedBookDeletionRequests
    }

    func progressUpdateRequests() -> [ProgressUpdateRequest] {
        recordedProgressUpdateRequests
    }

    func setLocalSessionSync(
        _ result:
            Result<
                [LocalPlaybackSessionSyncResult],
                AppServiceError
            >
    ) {
        localSessionSyncResult = result
    }

    func localSessionSyncRequests() -> [LocalSessionSyncRequest] {
        recordedLocalSessionSyncRequests
    }

    func removedAccounts() -> [ServerAccount] {
        recordedRemovedAccounts
    }

    private func value<Value: Sendable>(
        from result: Result<Value, AppServiceError>
    ) throws(AppServiceError) -> Value {
        switch result {
        case .success(let value):
            value
        case .failure(let error):
            throw error
        }
    }
}

private actor AppDiagnosticRecorderSpy: DiagnosticRecording {
    private var recordedEvents: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        recordedEvents.append(event)
    }

    func events() -> [DiagnosticEvent] {
        recordedEvents
    }
}

private actor AsyncGate {
    private var entered = false
    private var released = false
    private var enteredContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        let continuations = enteredContinuations
        enteredContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }

        guard !released else {
            return
        }
        await withCheckedContinuation { continuation in
            releaseContinuations.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else {
            return
        }
        await withCheckedContinuation { continuation in
            enteredContinuations.append(continuation)
        }
    }

    func release() {
        released = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
