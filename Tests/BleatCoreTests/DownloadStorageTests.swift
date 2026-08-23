import Foundation
import XCTest

@testable import BleatCore

extension DownloadStorageLayout {
    fileprivate func placeCompleteTestFile(
        from temporaryURL: URL,
        identity: DownloadTaskIdentity
    ) throws -> Int64 {
        _ = try appendChunk(
            from: temporaryURL,
            identity: identity,
            expectedOffset: 0,
            expectedChunkLength: identity.expectedByteLength
        )
        return try finalizePartial(identity)
    }
}

final class DownloadStorageTests: XCTestCase {
    func testFinalizedLateTrackKeepsRemainingTracksPaused() async throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let secondTrack = DownloadTrackPlan(
            index: 1,
            inode: "102",
            expectedByteLength: 4,
            mimeType: "audio/mpeg",
            safeExtension: .mp3,
            destinationEntry: "00001.mp3"
        )
        let plan = DownloadPlan(
            itemID: fixture.itemID,
            tracks: fixture.plan.tracks + [secondTrack]
        )
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: plan,
            detail: fixture.detail
        )
        let firstIdentity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: plan.tracks[0]
        )
        let secondIdentity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: secondTrack
        )
        _ = try await fixture.storage.markPaused(
            firstIdentity,
            observedByteLength: 0
        )
        _ = try await fixture.storage.markPaused(
            secondIdentity,
            observedByteLength: 0
        )
        let chunk = fixture.rootURL.appendingPathComponent("late.chunk")
        try Data([1, 2, 3, 4]).write(to: chunk)
        _ = try fixture.layout.appendChunk(
            from: chunk,
            identity: firstIdentity,
            expectedOffset: 0,
            expectedChunkLength: 4
        )
        _ = try fixture.layout.finalizePartial(firstIdentity)

        let updated = try await fixture.storage.recordCommittedChunk(
            firstIdentity,
            committedByteLength: 4,
            validator: nil,
            finalized: true
        )

        XCTAssertEqual(updated.manifest.state, .paused)
        XCTAssertEqual(
            updated.manifest.entries.first(where: { $0.trackIndex == 1 })?
                .state,
            .paused
        )
    }

    func testDurableChunksSurviveRecreationAndFinalizeAtExactLength()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let first = fixture.rootURL.appendingPathComponent("first.chunk")
        try Data([1, 2]).write(to: first)

        let committed = try fixture.layout.appendChunk(
            from: first,
            identity: identity,
            expectedOffset: 0,
            expectedChunkLength: 2
        )
        _ = try await fixture.storage.markPaused(
            identity,
            observedByteLength: committed
        )

        let relaunched = DownloadStorage(layout: fixture.layout)
        let relaunchedRecords = try await relaunched.records()
        let paused = try XCTUnwrap(relaunchedRecords.first)
        let relaunchedPartialLength = try await relaunched.partialByteLength(
            identity
        )
        XCTAssertEqual(paused.manifest.state, .paused)
        XCTAssertEqual(paused.manifest.storedByteLength, 2)
        XCTAssertEqual(relaunchedPartialLength, 2)

        let second = fixture.rootURL.appendingPathComponent("second.chunk")
        try Data([3, 4]).write(to: second)
        XCTAssertEqual(
            try fixture.layout.appendChunk(
                from: second,
                identity: identity,
                expectedOffset: 2,
                expectedChunkLength: 2
            ),
            4
        )
        XCTAssertEqual(try fixture.layout.finalizePartial(identity), 4)
        XCTAssertEqual(
            try Data(contentsOf: fixture.layout.destinationURL(for: identity)),
            Data([1, 2, 3, 4])
        )
    }

    func testChunkAppendRejectsWrongOffsetAndOversizedResult() async throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let chunk = fixture.rootURL.appendingPathComponent("chunk")
        try Data([1, 2, 3]).write(to: chunk)

        XCTAssertThrowsError(
            try fixture.layout.appendChunk(
                from: chunk,
                identity: identity,
                expectedOffset: 1,
                expectedChunkLength: 3
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadStorageError,
                .invalidPartialOffset(expected: 1, observed: 0)
            )
        }
        _ = try fixture.layout.appendChunk(
            from: chunk,
            identity: identity,
            expectedOffset: 0,
            expectedChunkLength: 3
        )
        XCTAssertThrowsError(
            try fixture.layout.appendChunk(
                from: chunk,
                identity: identity,
                expectedOffset: 3,
                expectedChunkLength: 3
            )
        )
    }

    func testStorageRequirementUsesSafetyMarginAndTypedCapacityFailure()
        throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let requirement = try DownloadStorageRequirement(
            plan: fixture.plan
        )

        XCTAssertEqual(requirement.expectedBytes, 4)
        XCTAssertEqual(
            requirement.safetyMarginBytes,
            DownloadStorageRequirement.minimumSafetyMarginBytes
        )
        XCTAssertEqual(
            requirement.requiredBytes,
            4 + DownloadStorageRequirement.minimumSafetyMarginBytes
        )
        XCTAssertNoThrow(
            try requirement.validate(
                availableBytes: requirement.requiredBytes
            )
        )
        XCTAssertThrowsError(
            try requirement.validate(
                availableBytes: requirement.requiredBytes - 1
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadStorageError,
                .insufficientSpace(
                    requiredBytes: requirement.requiredBytes,
                    availableBytes: requirement.requiredBytes - 1
                )
            )
        }
        let emptyRepair = try DownloadStorageRequirement(tracks: [])
        XCTAssertEqual(emptyRepair.requiredBytes, 0)
    }

    func testStorageRequirementRejectsOverflow() {
        let tracks = [
            DownloadTrackPlan(
                index: 0,
                inode: "1",
                expectedByteLength: Int64.max,
                mimeType: "audio/mpeg",
                safeExtension: .mp3,
                destinationEntry: "00000.mp3"
            ),
            DownloadTrackPlan(
                index: 1,
                inode: "2",
                expectedByteLength: 1,
                mimeType: "audio/mpeg",
                safeExtension: .mp3,
                destinationEntry: "00001.mp3"
            ),
        ]

        XCTAssertThrowsError(
            try DownloadStorageRequirement(tracks: tracks)
        ) { error in
            XCTAssertEqual(
                error as? DownloadStorageError,
                .requirementOverflow
            )
        }
    }

    func testStoragePreflightReadsCapacityFromVolume() async throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }

        let requirement = try await fixture.storage.preflight(
            plan: fixture.plan
        )

        XCTAssertEqual(requirement.expectedBytes, 4)
        XCTAssertGreaterThan(requirement.requiredBytes, 4)
    }

    func testFinalizedFilesAndManifestSurviveStoreRecreation()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let record = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let temporaryURL = fixture.rootURL.appendingPathComponent(
            "temporary"
        )
        try Data([1, 2, 3, 4]).write(to: temporaryURL)

        let observed = try fixture.layout.placeCompleteTestFile(
            from: temporaryURL,
            identity: identity
        )
        let completed = try await fixture.storage.markComplete(
            identity,
            observedByteLength: observed
        )
        let relaunched = DownloadStorage(layout: fixture.layout)
        let records = try await relaunched.records()
        let urls = try await relaunched.localTrackURLs(for: completed)

        XCTAssertEqual(record.manifest.state, .queued)
        XCTAssertEqual(completed.manifest.state, .complete)
        XCTAssertEqual(completed.manifest.expectedByteLength, 4)
        XCTAssertEqual(completed.manifest.storedByteLength, 4)
        XCTAssertEqual(records, [completed])
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(try Data(contentsOf: urls[0]), Data([1, 2, 3, 4]))
        XCTAssertFalse(
            urls[0].path.contains(fixture.accountID.rawValue)
        )
        XCTAssertFalse(urls[0].path.contains(fixture.itemID.rawValue))
    }

    func testRejectsWrongLengthBeforeFinalPlacement() async throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let temporaryURL = fixture.rootURL.appendingPathComponent(
            "temporary"
        )
        try Data([1, 2]).write(to: temporaryURL)

        XCTAssertThrowsError(
            try fixture.layout.placeCompleteTestFile(
                from: temporaryURL,
                identity: identity
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadStorageError,
                .byteLengthMismatch(expected: 4, observed: 2)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.destinationURL(
                    for: identity
                ).path
            )
        )
    }

    func testMissingCompletedFileBecomesRepairablePartial()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let temporaryURL = fixture.rootURL.appendingPathComponent(
            "temporary"
        )
        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        let observed = try fixture.layout.placeCompleteTestFile(
            from: temporaryURL,
            identity: identity
        )
        let completed = try await fixture.storage.markComplete(
            identity,
            observedByteLength: observed
        )
        try FileManager.default.removeItem(
            at: fixture.layout.destinationURL(for: identity)
        )

        let records = try await fixture.storage.records()

        let repaired = try XCTUnwrap(records.first)
        XCTAssertEqual(repaired.manifest.state, .partial)
        XCTAssertEqual(repaired.manifest.entries[0].state, .partial)
        XCTAssertEqual(repaired.manifest.entries[0].observedByteLength, 0)
        XCTAssertEqual(
            repaired.manifest.entries[0].placement,
            .temporary
        )
        do {
            _ = try await fixture.storage.localTrackURLs(for: completed)
            XCTFail("Expected the stale complete record to require repair")
        } catch {
            XCTAssertEqual(error, .invalidStoredRecord)
        }
    }

    func testCorruptCompletedFileBecomesRepairablePartial()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let temporaryURL = fixture.rootURL.appendingPathComponent(
            "temporary"
        )
        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        let observed = try fixture.layout.placeCompleteTestFile(
            from: temporaryURL,
            identity: identity
        )
        _ = try await fixture.storage.markComplete(
            identity,
            observedByteLength: observed
        )
        try Data([1, 2]).write(
            to: fixture.layout.destinationURL(for: identity)
        )

        let records = try await fixture.storage.records()

        let repaired = try XCTUnwrap(records.first)
        XCTAssertEqual(repaired.manifest.state, .partial)
        XCTAssertEqual(repaired.manifest.entries[0].state, .partial)
        XCTAssertEqual(repaired.manifest.entries[0].observedByteLength, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.layout.destinationURL(for: identity).path
            )
        )
    }

    func testFinalizedFileCompletesManifestAfterInterruptedPersistence()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let temporaryURL = fixture.rootURL.appendingPathComponent("chunk")
        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        _ = try fixture.layout.placeCompleteTestFile(
            from: temporaryURL,
            identity: identity
        )

        let records = try await fixture.storage.records()
        let record = try XCTUnwrap(records.first)

        XCTAssertEqual(record.manifest.state, .complete)
        XCTAssertEqual(record.manifest.entries[0].state, .complete)
        XCTAssertEqual(record.manifest.entries[0].placement, .finalized)
    }

    func testRemainingPreflightCountsOnlyMissingPartialBytes()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let record = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let temporaryURL = fixture.rootURL.appendingPathComponent("partial")
        try Data([1, 2]).write(to: temporaryURL)
        _ = try fixture.layout.appendChunk(
            from: temporaryURL,
            identity: identity,
            expectedOffset: 0,
            expectedChunkLength: 2
        )

        let requirement = try await fixture.storage.preflightRemaining(
            record: record,
            tracks: fixture.plan.tracks
        )

        XCTAssertEqual(requirement.expectedBytes, 2)
    }

    func testOversizedPartialFailsOnlyItsOwnRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let partial = fixture.layout.partialURL(for: identity)
        try FileManager.default.createDirectory(
            at: partial.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([1, 2, 3, 4, 5]).write(to: partial)

        let otherItemID = LibraryItemID(rawValue: "other-item")
        let otherPlan = DownloadPlan(
            itemID: otherItemID,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "other-inode",
                    expectedByteLength: 1,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                )
            ]
        )
        let otherDetail = LibraryBookDetail(
            id: otherItemID,
            libraryID: fixture.detail.libraryID,
            bookID: BookID(rawValue: "other-book"),
            title: "Other Book",
            subtitle: nil,
            authors: [],
            narrators: [],
            series: [],
            genres: [],
            tags: [],
            publishedYear: nil,
            publishedDate: nil,
            publisher: nil,
            descriptionPlain: nil,
            isbn: nil,
            asin: nil,
            language: nil,
            duration: 1,
            trackCount: 1,
            audioFileCount: 1,
            chapters: [],
            addedAtMilliseconds: 1,
            updatedAtMilliseconds: 1,
            isExplicit: false,
            isAbridged: false,
            progress: nil
        )
        _ = try await fixture.storage.create(
            downloadID: DownloadID(rawValue: "other-download"),
            accountID: fixture.accountID,
            plan: otherPlan,
            detail: otherDetail
        )

        let records = try await fixture.storage.records()

        XCTAssertEqual(records.count, 2)
        let repaired = try XCTUnwrap(
            records.first { $0.manifest.downloadID == fixture.downloadID }
        )
        XCTAssertEqual(repaired.manifest.entries[0].state, .failed)
        XCTAssertEqual(repaired.manifest.entries[0].observedByteLength, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testMalformedRecordIsDeletedWithoutHidingHealthyRecords()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let invalidDirectory = fixture.rootURL
            .appendingPathComponent("invalid-account", isDirectory: true)
            .appendingPathComponent("invalid-book", isDirectory: true)
        try FileManager.default.createDirectory(
            at: invalidDirectory,
            withIntermediateDirectories: true
        )
        try Data("not-json".utf8).write(
            to: invalidDirectory.appendingPathComponent("record.json")
        )

        let records = try await fixture.storage.records()

        XCTAssertEqual(records.map(\.manifest.downloadID), [fixture.downloadID])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: invalidDirectory.path)
        )
    }

    func testCompletedLegacyRecordWithoutInodeIsPreserved()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: fixture.plan.tracks[0]
        )
        let temporaryURL = fixture.rootURL.appendingPathComponent("legacy")
        try Data([1, 2, 3, 4]).write(to: temporaryURL)
        let observed = try fixture.layout.placeCompleteTestFile(
            from: temporaryURL,
            identity: identity
        )
        _ = try await fixture.storage.markComplete(
            identity,
            observedByteLength: observed
        )

        let recordURL = fixture.layout.recordURL(
            accountID: fixture.accountID,
            itemID: fixture.itemID
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: recordURL)
            ) as? [String: Any]
        )
        var manifest = try XCTUnwrap(object["manifest"] as? [String: Any])
        var entries = try XCTUnwrap(
            manifest["entries"] as? [[String: Any]]
        )
        entries[0].removeValue(forKey: "inode")
        manifest["entries"] = entries
        object["manifest"] = manifest
        try JSONSerialization.data(withJSONObject: object).write(
            to: recordURL,
            options: .atomic
        )

        let records = try await fixture.storage.records()
        let record = try XCTUnwrap(records.first)

        XCTAssertEqual(record.manifest.state, .complete)
        XCTAssertNil(record.manifest.entries[0].inode)
        let urls = try await fixture.storage.localTrackURLs(for: record)
        XCTAssertEqual(urls.count, 1)
    }

    func testAutomaticCacheMetadataAndTrackRemovalPersist()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let plan = DownloadPlan(
            itemID: fixture.itemID,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "101",
                    expectedByteLength: 4,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3",
                    startOffset: 0,
                    duration: 60
                ),
                DownloadTrackPlan(
                    index: 1,
                    inode: "102",
                    expectedByteLength: 2,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00001.mp3",
                    startOffset: 60,
                    duration: 60
                ),
            ]
        )
        var record = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: plan,
            detail: fixture.detail,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [1]
        )
        let finishedAt = Date(timeIntervalSince1970: 123)
        record = try await fixture.storage.markBookFinished(
            record,
            at: finishedAt
        )
        XCTAssertEqual(record.manifest.purpose, .automaticCache)
        XCTAssertEqual(record.manifest.bookFinishedAt, finishedAt)
        XCTAssertEqual(
            record.manifest.automaticTargetTrackIndexes,
            [1]
        )

        for (track, data) in [
            (plan.tracks[1], Data([5, 6])),
            (plan.tracks[0], Data([1, 2, 3, 4])),
        ] {
            let identity = try DownloadTaskIdentity(
                downloadID: fixture.downloadID,
                accountID: fixture.accountID,
                itemID: fixture.itemID,
                track: track
            )
            let temporaryURL = fixture.rootURL.appendingPathComponent(
                "temporary-\(track.index)"
            )
            try data.write(to: temporaryURL)
            let observed = try fixture.layout.placeCompleteTestFile(
                from: temporaryURL,
                identity: identity
            )
            record = try await fixture.storage.markComplete(
                identity,
                observedByteLength: observed
            )
            if track.index == 1 {
                XCTAssertEqual(
                    record.manifest.entries[1].startOffset,
                    60
                )
                XCTAssertEqual(record.manifest.entries[1].duration, 60)
                XCTAssertEqual(record.manifest.state, .partial)
                XCTAssertFalse(record.manifest.isFullBookComplete)
                XCTAssertEqual(
                    record.manifest.automaticCacheState,
                    .cached
                )
                XCTAssertEqual(
                    record.manifest.automaticExpectedByteLength,
                    2
                )
                XCTAssertEqual(
                    record.manifest.automaticStoredByteLength,
                    2
                )
                let localChapterFiles =
                    try await fixture.storage.localTrackURLs(
                        for: record,
                        trackIndexes: [1]
                    )
                XCTAssertEqual(localChapterFiles.keys.sorted(), [1])
                do {
                    _ = try await fixture.storage.localTrackURLs(
                        for: record,
                        trackIndexes: [0, 1]
                    )
                    XCTFail("Expected the missing track to be rejected")
                } catch {
                    XCTAssertEqual(error, .invalidStoredRecord)
                }
                record = try await fixture.storage.updateAutomaticWindow(
                    record,
                    targetTrackIndexes: [0, 1]
                )
                XCTAssertEqual(
                    record.manifest.automaticCacheState,
                    .queued
                )
                XCTAssertEqual(
                    record.manifest.automaticExpectedByteLength,
                    6
                )
            }
        }
        XCTAssertEqual(record.manifest.state, .complete)
        XCTAssertTrue(record.manifest.isFullBookComplete)
        XCTAssertEqual(record.manifest.automaticCacheState, .cached)

        record = try await fixture.storage.updateAutomaticWindow(
            record,
            targetTrackIndexes: [1]
        )

        record = try await fixture.storage.removeCompletedTracks(
            from: record,
            trackIndexes: [0]
        )
        XCTAssertEqual(record.manifest.state, .partial)
        XCTAssertEqual(record.manifest.entries[0].state, .queued)
        XCTAssertEqual(record.manifest.entries[1].state, .complete)
        XCTAssertEqual(record.manifest.storedByteLength, 2)
        XCTAssertEqual(record.manifest.automaticCacheState, .cached)
        XCTAssertEqual(record.manifest.automaticStoredByteLength, 2)

        let records = try await fixture.storage.records()
        XCTAssertEqual(records, [record])
    }

    func testLegacyManifestDefaultsToManualPurpose() throws {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(
                    try DownloadManifest(
                        downloadID: fixture.downloadID,
                        accountID: fixture.accountID,
                        plan: fixture.plan
                    )
                )
            ) as? [String: Any]
        )
        object["purpose"] = nil
        object["bookFinishedAt"] = nil

        let decoded = try JSONDecoder().decode(
            DownloadManifest.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.purpose, .manual)
        XCTAssertNil(decoded.bookFinishedAt)
    }

    func testAutomaticWindowValidationPromotionAndLegacyDetection()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }

        XCTAssertThrowsError(
            try DownloadManifest(
                downloadID: fixture.downloadID,
                accountID: fixture.accountID,
                plan: fixture.plan,
                purpose: .automaticCache
            )
        ) { error in
            XCTAssertEqual(
                error as? DownloadManifestError,
                .invalidAutomaticWindow
            )
        }

        do {
            _ = try await fixture.storage.create(
                downloadID: fixture.downloadID,
                accountID: fixture.accountID,
                plan: fixture.plan,
                detail: fixture.detail,
                purpose: .automaticCache
            )
            XCTFail("Expected an automatic cache window")
        } catch {
            XCTAssertEqual(error, .invalidAutomaticWindow)
        }

        let record = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [0]
        )
        let promoted = try await fixture.storage.promoteToManual(record)

        XCTAssertEqual(promoted.manifest.purpose, .manual)
        XCTAssertNil(promoted.manifest.automaticWindow)
        XCTAssertNil(promoted.manifest.automaticCacheState)

        let current = try DownloadManifest(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [0]
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(current)
            ) as? [String: Any]
        )
        legacyObject["automaticWindow"] = nil
        let decoded = try JSONDecoder().decode(
            DownloadManifest.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertTrue(decoded.isLegacyAutomaticCache)
    }

    func testAutomaticWindowIgnoresNonTargetCorruption()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let plan = DownloadPlan(
            itemID: fixture.itemID,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "101",
                    expectedByteLength: 4,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                ),
                DownloadTrackPlan(
                    index: 1,
                    inode: "102",
                    expectedByteLength: 2,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00001.mp3"
                ),
            ]
        )
        var record = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: plan,
            detail: fixture.detail,
            purpose: .automaticCache,
            automaticTargetTrackIndexes: [1]
        )
        for (track, data) in [
            (plan.tracks[0], Data([1, 2, 3, 4])),
            (plan.tracks[1], Data([5, 6])),
        ] {
            let identity = try DownloadTaskIdentity(
                downloadID: fixture.downloadID,
                accountID: fixture.accountID,
                itemID: fixture.itemID,
                track: track
            )
            let temporaryURL = fixture.rootURL.appendingPathComponent(
                "corruption-\(track.index)"
            )
            try data.write(to: temporaryURL)
            let observed = try fixture.layout.placeCompleteTestFile(
                from: temporaryURL,
                identity: identity
            )
            record = try await fixture.storage.markComplete(
                identity,
                observedByteLength: observed
            )
        }

        let firstIdentity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: plan.tracks[0]
        )
        try Data([1]).write(
            to: fixture.layout.destinationURL(for: firstIdentity)
        )
        let recordsAfterNonTargetCorruption =
            try await fixture.storage.records()
        record = try XCTUnwrap(
            recordsAfterNonTargetCorruption.first
        )
        XCTAssertEqual(record.manifest.state, .partial)
        XCTAssertEqual(record.manifest.automaticCacheState, .cached)

        let secondIdentity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: plan.tracks[1]
        )
        try Data([5]).write(
            to: fixture.layout.destinationURL(for: secondIdentity)
        )
        let recordsAfterTargetCorruption =
            try await fixture.storage.records()
        record = try XCTUnwrap(
            recordsAfterTargetCorruption.first
        )
        XCTAssertEqual(record.manifest.automaticCacheState, .failed)
    }

    func testRemovingRecordDeletesOnlyItsOpaqueBookDirectory()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let record = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: fixture.plan,
            detail: fixture.detail
        )
        let sibling = fixture.rootURL.appendingPathComponent("keep")
        try Data([1]).write(to: sibling)

        try await fixture.storage.remove(record)

        let remaining = try await fixture.storage.records()
        XCTAssertEqual(remaining, [])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sibling.path)
        )
    }

    func testRemoveTrackFilesDeletesPartialAndFinalFiles()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let plan = DownloadPlan(
            itemID: fixture.itemID,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "101",
                    expectedByteLength: 4,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                ),
                DownloadTrackPlan(
                    index: 1,
                    inode: "102",
                    expectedByteLength: 2,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00001.mp3"
                ),
            ]
        )
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: plan,
            detail: fixture.detail
        )

        let identity0 = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: plan.tracks[0]
        )
        let identity1 = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: plan.tracks[1]
        )

        let tempURL0 = fixture.rootURL.appendingPathComponent("temp0")
        let tempURL1 = fixture.rootURL.appendingPathComponent("temp1")
        try Data([1, 2, 3, 4]).write(to: tempURL0)
        try Data([5, 6]).write(to: tempURL1)

        let observed0 = try fixture.layout.placeCompleteTestFile(
            from: tempURL0,
            identity: identity0
        )
        let observed1 = try fixture.layout.placeCompleteTestFile(
            from: tempURL1,
            identity: identity1
        )

        _ = try await fixture.storage.markComplete(
            identity0,
            observedByteLength: observed0
        )
        _ = try await fixture.storage.markComplete(
            identity1,
            observedByteLength: observed1
        )

        let destination0 = fixture.layout.destinationURL(for: identity0)
        let destination1 = fixture.layout.destinationURL(for: identity1)
        let partial0 = destination0.deletingPathExtension()
            .appendingPathExtension("mp3.partial")
        let partial1 = destination1.deletingPathExtension()
            .appendingPathExtension("mp3.partial")

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination0.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial0.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial1.path))

        try await fixture.storage.removeTrackFiles(identity0)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destination0.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial0.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial1.path))

        let record = try await fixture.storage.records().first!
        XCTAssertEqual(record.manifest.entries[1].state, .complete)
    }

    func testRemoveTrackFilesDeletesPartialFileWhenDownloadInProgress()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let plan = DownloadPlan(
            itemID: fixture.itemID,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "101",
                    expectedByteLength: 4,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                )
            ]
        )
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: plan,
            detail: fixture.detail
        )

        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: plan.tracks[0]
        )

        let directory = fixture.layout.bookDirectory(
            accountID: identity.accountID,
            itemID: identity.itemID
        )
        let partial = directory.appendingPathComponent(
            identity.destinationEntry + ".partial",
            isDirectory: false
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data([1, 2]).write(to: partial)

        let destination = fixture.layout.destinationURL(for: identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        try await fixture.storage.removeTrackFiles(identity)

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testRemoveTrackFilesIgnoresMissingFiles()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.removeRoot() }
        let plan = DownloadPlan(
            itemID: fixture.itemID,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "101",
                    expectedByteLength: 4,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                )
            ]
        )
        _ = try await fixture.storage.create(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            plan: plan,
            detail: fixture.detail
        )

        let identity = try DownloadTaskIdentity(
            downloadID: fixture.downloadID,
            accountID: fixture.accountID,
            itemID: fixture.itemID,
            track: plan.tracks[0]
        )

        try await fixture.storage.removeTrackFiles(identity)

        let destination = fixture.layout.destinationURL(for: identity)
        let partial = destination.deletingPathExtension()
            .appendingPathExtension("mp3.partial")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }
}

private struct Fixture {
    let accountID = AccountID(rawValue: "account/private")
    let itemID = LibraryItemID(rawValue: "item/private")
    let downloadID = DownloadID(rawValue: "download")
    let rootURL: URL
    let layout: DownloadStorageLayout
    let storage: DownloadStorage
    let plan: DownloadPlan
    let detail: LibraryBookDetail

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        layout = try DownloadStorageLayout(rootURL: rootURL)
        storage = DownloadStorage(layout: layout)
        plan = DownloadPlan(
            itemID: itemID,
            tracks: [
                DownloadTrackPlan(
                    index: 0,
                    inode: "101",
                    expectedByteLength: 4,
                    mimeType: "audio/mpeg",
                    safeExtension: .mp3,
                    destinationEntry: "00000.mp3"
                )
            ]
        )
        detail = LibraryBookDetail(
            id: itemID,
            libraryID: LibraryID(rawValue: "library"),
            bookID: BookID(rawValue: "book"),
            title: "Downloaded Book",
            subtitle: nil,
            authors: [],
            narrators: [],
            series: [],
            genres: [],
            tags: [],
            publishedYear: nil,
            publishedDate: nil,
            publisher: nil,
            descriptionPlain: nil,
            isbn: nil,
            asin: nil,
            language: nil,
            duration: 60,
            trackCount: 1,
            audioFileCount: 1,
            chapters: [],
            addedAtMilliseconds: 1,
            updatedAtMilliseconds: 1,
            isExplicit: false,
            isAbridged: false,
            progress: nil
        )
    }

    func removeRoot() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
