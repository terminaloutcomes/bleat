import CryptoKit
import Foundation

public struct DownloadedBookRecord: Codable, Equatable, Sendable {
    public internal(set) var manifest: DownloadManifest
    public let detail: LibraryBookDetail

    public init(
        manifest: DownloadManifest,
        detail: LibraryBookDetail
    ) {
        self.manifest = manifest
        self.detail = detail
    }
}

public enum DownloadStorageError: Error, Equatable, Sendable {
    case invalidRoot
    case mismatchedBook
    case duplicateDownload
    case recordNotFound
    case trackNotFound
    case invalidTemporaryFile
    case byteLengthMismatch(expected: Int64, observed: Int64)
    case requirementOverflow
    case capacityUnavailable
    case insufficientSpace(requiredBytes: Int64, availableBytes: Int64)
    case persistenceFailed
    case invalidStoredRecord
}

public struct DownloadStorageRequirement: Equatable, Sendable {
    public static let minimumSafetyMarginBytes: Int64 = 256 * 1_024 * 1_024

    public let expectedBytes: Int64
    public let safetyMarginBytes: Int64
    public let requiredBytes: Int64

    public init(plan: DownloadPlan) throws(DownloadStorageError) {
        try self.init(tracks: plan.tracks)
    }

    public init(
        tracks: [DownloadTrackPlan]
    ) throws(DownloadStorageError) {
        var expected: Int64 = 0
        for track in tracks {
            let (sum, overflow) = expected.addingReportingOverflow(
                track.expectedByteLength
            )
            guard !overflow else {
                throw .requirementOverflow
            }
            expected = sum
        }
        let safetyMargin =
            expected == 0
            ? 0
            : max(
                Self.minimumSafetyMarginBytes,
                expected / 10
            )
        let (required, overflow) = expected.addingReportingOverflow(
            safetyMargin
        )
        guard !overflow else {
            throw .requirementOverflow
        }
        expectedBytes = expected
        safetyMarginBytes = safetyMargin
        requiredBytes = required
    }

    public func validate(
        availableBytes: Int64
    ) throws(DownloadStorageError) {
        guard availableBytes >= 0 else {
            throw .capacityUnavailable
        }
        guard availableBytes >= requiredBytes else {
            throw .insufficientSpace(
                requiredBytes: requiredBytes,
                availableBytes: availableBytes
            )
        }
    }
}

public struct DownloadStorageLayout: Sendable {
    public let rootURL: URL

    public init(rootURL: URL) throws(DownloadStorageError) {
        guard rootURL.isFileURL else {
            throw .invalidRoot
        }
        self.rootURL = rootURL.standardizedFileURL
    }

    public func bookDirectory(
        accountID: AccountID,
        itemID: LibraryItemID
    ) -> URL {
        rootURL
            .appendingPathComponent(
                Self.safeComponent(accountID.rawValue),
                isDirectory: true
            )
            .appendingPathComponent(
                Self.safeComponent(itemID.rawValue),
                isDirectory: true
            )
    }

    public func recordURL(
        accountID: AccountID,
        itemID: LibraryItemID
    ) -> URL {
        bookDirectory(accountID: accountID, itemID: itemID)
            .appendingPathComponent("record.json", isDirectory: false)
    }

    public func destinationURL(
        for identity: DownloadTaskIdentity
    ) -> URL {
        bookDirectory(
            accountID: identity.accountID,
            itemID: identity.itemID
        ).appendingPathComponent(
            identity.destinationEntry,
            isDirectory: false
        )
    }

    public func placeDownloadedFile(
        from temporaryURL: URL,
        identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) -> Int64 {
        let fileManager = FileManager.default
        guard temporaryURL.isFileURL,
            fileManager.fileExists(atPath: temporaryURL.path)
        else {
            throw .invalidTemporaryFile
        }
        let observed = Self.fileSize(at: temporaryURL)
        guard observed == identity.expectedByteLength else {
            throw .byteLengthMismatch(
                expected: identity.expectedByteLength,
                observed: observed
            )
        }
        let directory = bookDirectory(
            accountID: identity.accountID,
            itemID: identity.itemID
        )
        let destination = destinationURL(for: identity)
        let partial = directory.appendingPathComponent(
            identity.destinationEntry + ".partial",
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Self.excludeFromBackup(directory)
            if fileManager.fileExists(atPath: partial.path) {
                try fileManager.removeItem(at: partial)
            }
            try fileManager.moveItem(at: temporaryURL, to: partial)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
            #if os(iOS)
                try fileManager.setAttributes(
                    [
                        .protectionKey:
                            FileProtectionType
                            .completeUntilFirstUserAuthentication
                    ],
                    ofItemAtPath: destination.path
                )
            #endif
        } catch {
            throw .persistenceFailed
        }
        return observed
    }

    fileprivate func availableCapacity()
        throws(DownloadStorageError) -> Int64
    {
        var probe = rootURL
        while !FileManager.default.fileExists(atPath: probe.path),
            probe.pathComponents.count > 1
        {
            probe.deleteLastPathComponent()
        }
        do {
            let values = try probe.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ])
            if let available =
                values.volumeAvailableCapacityForImportantUsage,
                available >= 0
            {
                return available
            }
            let attributes =
                try FileManager.default.attributesOfFileSystem(
                    forPath: probe.path
                )
            if let available = (attributes[.systemFreeSize] as? NSNumber)?
                .int64Value,
                available >= 0
            {
                return available
            }
        } catch {
            throw .capacityUnavailable
        }
        throw .capacityUnavailable
    }

    private static func safeComponent(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private static func excludeFromBackup(
        _ url: URL
    ) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

public actor DownloadStorage {
    private let layout: DownloadStorageLayout
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(layout: DownloadStorageLayout) {
        self.layout = layout
    }

    public func preflight(
        plan: DownloadPlan
    ) throws(DownloadStorageError) -> DownloadStorageRequirement {
        try preflight(tracks: plan.tracks)
    }

    public func preflight(
        tracks: [DownloadTrackPlan]
    ) throws(DownloadStorageError) -> DownloadStorageRequirement {
        let requirement = try DownloadStorageRequirement(tracks: tracks)
        try requirement.validate(
            availableBytes: layout.availableCapacity()
        )
        return requirement
    }

    @discardableResult
    public func create(
        downloadID: DownloadID,
        accountID: AccountID,
        plan: DownloadPlan,
        detail: LibraryBookDetail,
        purpose: DownloadPurpose = .manual
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        guard plan.itemID == detail.id else {
            throw .mismatchedBook
        }
        let recordURL = layout.recordURL(
            accountID: accountID,
            itemID: plan.itemID
        )
        guard !FileManager.default.fileExists(atPath: recordURL.path)
        else {
            throw .duplicateDownload
        }
        let record = DownloadedBookRecord(
            manifest: DownloadManifest(
                downloadID: downloadID,
                accountID: accountID,
                plan: plan,
                purpose: purpose
            ),
            detail: detail
        )
        try persist(record)
        return record
    }

    public func promoteToManual(
        _ storedRecord: DownloadedBookRecord
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(storedRecord)
        record.manifest.promoteToManual()
        try persist(record)
        return record
    }

    public func markBookFinished(
        _ storedRecord: DownloadedBookRecord,
        at date: Date?
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(storedRecord)
        record.manifest.markBookFinished(at: date)
        try persist(record)
        return record
    }

    public func removeCompletedTracks(
        from storedRecord: DownloadedBookRecord,
        trackIndexes: Set<Int>
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(storedRecord)
        let directory = layout.bookDirectory(
            accountID: record.manifest.accountID,
            itemID: record.manifest.itemID
        )
        do {
            for entry in record.manifest.entries
            where trackIndexes.contains(entry.trackIndex)
                && entry.state == .complete
            {
                let destination = directory.appendingPathComponent(
                    entry.destinationEntry,
                    isDirectory: false
                )
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try record.manifest.markQueued(
                    trackIndex: entry.trackIndex
                )
            }
            try persist(record)
        } catch is DownloadManifestError {
            throw .trackNotFound
        } catch let error as DownloadStorageError {
            throw error
        } catch {
            throw .persistenceFailed
        }
        return record
    }

    public func markDownloading(
        _ identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(identity)
        do {
            try record.manifest.markDownloading(
                trackIndex: identity.trackIndex
            )
        } catch {
            throw .trackNotFound
        }
        try persist(record)
        return record
    }

    public func markComplete(
        _ identity: DownloadTaskIdentity,
        observedByteLength: Int64
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(identity)
        guard
            let entry = record.manifest.entries.first(where: {
                $0.trackIndex == identity.trackIndex
                    && $0.destinationEntry == identity.destinationEntry
            })
        else {
            throw .trackNotFound
        }
        guard entry.expectedByteLength == observedByteLength else {
            throw .byteLengthMismatch(
                expected: entry.expectedByteLength,
                observed: observedByteLength
            )
        }
        let destination = layout.destinationURL(for: identity)
        let storedSize = Self.fileSize(at: destination)
        guard storedSize == observedByteLength else {
            throw .byteLengthMismatch(
                expected: observedByteLength,
                observed: storedSize
            )
        }
        do {
            try record.manifest.markComplete(
                trackIndex: identity.trackIndex,
                observedByteLength: observedByteLength,
                placement: .finalized
            )
            if record.manifest.entries.allSatisfy({
                $0.state == .complete
            }) {
                try record.manifest.finish()
            }
        } catch {
            throw .persistenceFailed
        }
        try persist(record)
        return record
    }

    public func markFailed(
        _ identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(identity)
        do {
            try record.manifest.markFailed(
                trackIndex: identity.trackIndex
            )
        } catch {
            throw .trackNotFound
        }
        try persist(record)
        return record
    }

    public func records() throws(DownloadStorageError)
        -> [DownloadedBookRecord]
    {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: layout.rootURL.path) else {
            return []
        }
        guard
            let enumerator = fileManager.enumerator(
                at: layout.rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            throw .persistenceFailed
        }
        var records: [DownloadedBookRecord] = []
        for case let url as URL in enumerator
        where url.lastPathComponent == "record.json" {
            do {
                let data = try Data(contentsOf: url)
                let record = try decoder.decode(
                    DownloadedBookRecord.self,
                    from: data
                )
                records.append(try reconcileCompletedFiles(in: record))
            } catch {
                throw .invalidStoredRecord
            }
        }
        return records.sorted {
            $0.detail.title.localizedStandardCompare(
                $1.detail.title
            ) == .orderedAscending
        }
    }

    public func localTrackURLs(
        for record: DownloadedBookRecord
    ) throws(DownloadStorageError) -> [URL] {
        let reconciled = try reconcileCompletedFiles(in: record)
        guard reconciled.manifest.state == .complete else {
            throw .invalidStoredRecord
        }
        let entries = reconciled.manifest.entries.sorted {
            $0.trackIndex < $1.trackIndex
        }
        var urls: [URL] = []
        urls.reserveCapacity(entries.count)
        for entry in entries {
            guard
                let safeExtension = Self.safeExtension(
                    destinationEntry: entry.destinationEntry
                )
            else {
                throw .invalidStoredRecord
            }
            let track = DownloadTrackPlan(
                index: entry.trackIndex,
                inode: "stored",
                expectedByteLength: entry.expectedByteLength,
                mimeType: "stored",
                safeExtension: safeExtension,
                destinationEntry: entry.destinationEntry
            )
            let identity: DownloadTaskIdentity
            do {
                identity = try DownloadTaskIdentity(
                    downloadID: reconciled.manifest.downloadID,
                    accountID: reconciled.manifest.accountID,
                    itemID: reconciled.manifest.itemID,
                    track: track
                )
            } catch {
                throw DownloadStorageError.invalidStoredRecord
            }
            let url = layout.destinationURL(for: identity)
            guard
                Self.fileSize(at: url)
                    == entry.expectedByteLength
            else {
                throw DownloadStorageError.invalidStoredRecord
            }
            urls.append(url)
        }
        return urls
    }

    private func reconcileCompletedFiles(
        in storedRecord: DownloadedBookRecord
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = storedRecord
        var changed = false
        for entry in record.manifest.entries where entry.state == .complete {
            let url =
                layout
                .bookDirectory(
                    accountID: record.manifest.accountID,
                    itemID: record.manifest.itemID
                )
                .appendingPathComponent(
                    entry.destinationEntry,
                    isDirectory: false
                )
            let observed = Self.fileSize(at: url)
            guard observed != entry.expectedByteLength else {
                continue
            }
            do {
                try record.manifest.markPartial(
                    trackIndex: entry.trackIndex,
                    observedByteLength: max(observed, 0),
                    placement: .temporary
                )
            } catch {
                throw .invalidStoredRecord
            }
            changed = true
        }
        if changed {
            try persist(record)
        }
        return record
    }

    public func remove(
        _ record: DownloadedBookRecord
    ) throws(DownloadStorageError) {
        let directory = layout.bookDirectory(
            accountID: record.manifest.accountID,
            itemID: record.manifest.itemID
        )
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            throw .persistenceFailed
        }
    }

    private func load(
        _ identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        let url = layout.recordURL(
            accountID: identity.accountID,
            itemID: identity.itemID
        )
        do {
            let record = try decoder.decode(
                DownloadedBookRecord.self,
                from: Data(contentsOf: url)
            )
            guard record.manifest.downloadID == identity.downloadID,
                record.manifest.accountID == identity.accountID,
                record.manifest.itemID == identity.itemID
            else {
                throw DownloadStorageError.invalidStoredRecord
            }
            return record
        } catch let error as DownloadStorageError {
            throw error
        } catch  where !FileManager.default.fileExists(atPath: url.path) {
            throw .recordNotFound
        } catch {
            throw .invalidStoredRecord
        }
    }

    private func load(
        _ storedRecord: DownloadedBookRecord
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        let url = layout.recordURL(
            accountID: storedRecord.manifest.accountID,
            itemID: storedRecord.manifest.itemID
        )
        do {
            let record = try decoder.decode(
                DownloadedBookRecord.self,
                from: Data(contentsOf: url)
            )
            guard
                record.manifest.downloadID
                    == storedRecord.manifest.downloadID,
                record.manifest.accountID
                    == storedRecord.manifest.accountID,
                record.manifest.itemID
                    == storedRecord.manifest.itemID
            else {
                throw DownloadStorageError.invalidStoredRecord
            }
            return record
        } catch let error as DownloadStorageError {
            throw error
        } catch  where !FileManager.default.fileExists(atPath: url.path) {
            throw .recordNotFound
        } catch {
            throw .invalidStoredRecord
        }
    }

    private func persist(
        _ record: DownloadedBookRecord
    ) throws(DownloadStorageError) {
        let url = layout.recordURL(
            accountID: record.manifest.accountID,
            itemID: record.manifest.itemID
        )
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(record).write(
                to: url,
                options: [
                    .atomic,
                    .completeFileProtectionUntilFirstUserAuthentication,
                ]
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = url
            try mutableURL.setResourceValues(values)
        } catch {
            throw .persistenceFailed
        }
    }

    private static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    private static func safeExtension(
        destinationEntry: String
    ) -> SafeAudioExtension? {
        let rawValue = URL(fileURLWithPath: destinationEntry)
            .pathExtension
        return SafeAudioExtension(rawValue: rawValue)
    }
}
