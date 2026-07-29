import Foundation
import XCTest

@testable import BleatCore

final class DownloadStorageTests: XCTestCase {
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

        let observed = try fixture.layout.placeDownloadedFile(
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
            try fixture.layout.placeDownloadedFile(
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
        let observed = try fixture.layout.placeDownloadedFile(
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
        let observed = try fixture.layout.placeDownloadedFile(
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
        XCTAssertEqual(repaired.manifest.entries[0].observedByteLength, 2)
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
