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
    case invalidAutomaticWindow
    case invalidTemporaryFile
    case invalidPartialOffset(expected: Int64, observed: Int64)
    case partialFileTooLarge(expected: Int64, observed: Int64)
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
        try self.init(expectedBytes: expected)
    }

    public init(
        expectedBytes: Int64
    ) throws(DownloadStorageError) {
        guard expectedBytes >= 0 else {
            throw .requirementOverflow
        }
        let safetyMargin =
            expectedBytes == 0
            ? 0
            : max(
                Self.minimumSafetyMarginBytes,
                expectedBytes / 10
            )
        let (required, overflow) = expectedBytes.addingReportingOverflow(
            safetyMargin
        )
        guard !overflow else {
            throw .requirementOverflow
        }
        self.expectedBytes = expectedBytes
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

    public static func applicationSupport()
        throws(DownloadStorageError) -> DownloadStorageLayout
    {
        guard let supportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw .invalidRoot
        }
        return try DownloadStorageLayout(
            rootURL: supportURL.appendingPathComponent(
                "Bleat/Downloads",
                isDirectory: true
            )
        )
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

    public func partialURL(
        for identity: DownloadTaskIdentity
    ) -> URL {
        bookDirectory(
            accountID: identity.accountID,
            itemID: identity.itemID
        ).appendingPathComponent(
            identity.destinationEntry + ".partial",
            isDirectory: false
        )
    }

    public func partialByteLength(
        for identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) -> Int64 {
        let partial = partialURL(for: identity)
        guard FileManager.default.fileExists(atPath: partial.path) else {
            return 0
        }
        let observed = Self.fileSize(at: partial)
        guard observed >= 0 else {
            throw .persistenceFailed
        }
        guard observed <= identity.expectedByteLength else {
            throw .partialFileTooLarge(
                expected: identity.expectedByteLength,
                observed: observed
            )
        }
        return observed
    }

    public func appendChunk(
        from temporaryURL: URL,
        identity: DownloadTaskIdentity,
        expectedOffset: Int64,
        expectedChunkLength: Int64
    ) throws(DownloadStorageError) -> Int64 {
        let fileManager = FileManager.default
        guard temporaryURL.isFileURL,
            fileManager.fileExists(atPath: temporaryURL.path)
        else {
            throw .invalidTemporaryFile
        }
        let chunkLength = Self.fileSize(at: temporaryURL)
        guard chunkLength == expectedChunkLength else {
            throw .byteLengthMismatch(
                expected: expectedChunkLength,
                observed: chunkLength
            )
        }
        let existing = try partialByteLength(for: identity)
        guard existing == expectedOffset else {
            throw .invalidPartialOffset(
                expected: expectedOffset,
                observed: existing
            )
        }
        let (resultingLength, overflow) = existing.addingReportingOverflow(
            chunkLength
        )
        guard !overflow, resultingLength <= identity.expectedByteLength else {
            throw .partialFileTooLarge(
                expected: identity.expectedByteLength,
                observed: overflow ? Int64.max : resultingLength
            )
        }
        let directory = bookDirectory(
            accountID: identity.accountID,
            itemID: identity.itemID
        )
        let partial = partialURL(for: identity)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Self.excludeFromBackup(directory)
            if !fileManager.fileExists(atPath: partial.path) {
                guard
                    fileManager.createFile(atPath: partial.path, contents: nil)
                else {
                    throw DownloadStorageError.persistenceFailed
                }
            }
            let source = try FileHandle(forReadingFrom: temporaryURL)
            let destination = try FileHandle(forWritingTo: partial)
            do {
                try destination.seekToEnd()
                while let data = try source.read(upToCount: 1_048_576),
                    !data.isEmpty
                {
                    try destination.write(contentsOf: data)
                }
                try destination.synchronize()
                try source.close()
                try destination.close()
            } catch {
                try? source.close()
                try? destination.close()
                throw error
            }
            let observed = Self.fileSize(at: partial)
            guard observed == resultingLength else {
                throw DownloadStorageError.byteLengthMismatch(
                    expected: resultingLength,
                    observed: observed
                )
            }
            return observed
        } catch let error as DownloadStorageError {
            throw error
        } catch {
            throw .persistenceFailed
        }
    }

    public func finalizePartial(
        _ identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) -> Int64 {
        let fileManager = FileManager.default
        let partial = partialURL(for: identity)
        let observed = try partialByteLength(for: identity)
        guard observed == identity.expectedByteLength else {
            throw .byteLengthMismatch(
                expected: identity.expectedByteLength,
                observed: observed
            )
        }
        let destination = destinationURL(for: identity)
        do {
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
            return observed
        } catch {
            throw .persistenceFailed
        }
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

    public func migrateAccountIdentity(
        from legacyID: AccountID,
        to canonicalID: AccountID
    ) throws(DownloadStorageError) {
        guard legacyID != canonicalID else { return }
        let matchingRecords = try records().filter {
            $0.manifest.accountID == legacyID
        }
        let fileManager = FileManager.default
        for record in matchingRecords {
            let source = layout.bookDirectory(
                accountID: legacyID,
                itemID: record.manifest.itemID
            )
            let destination = layout.bookDirectory(
                accountID: canonicalID,
                itemID: record.manifest.itemID
            )
            var migrated = record
            migrated.manifest = DownloadManifest(
                reidentifying: record.manifest,
                as: canonicalID
            )
            if fileManager.fileExists(atPath: destination.path) {
                guard !fileManager.fileExists(atPath: source.path),
                    let destinationRecord = try? decoder.decode(
                        DownloadedBookRecord.self,
                        from: Data(
                            contentsOf: destination.appendingPathComponent(
                                "record.json",
                                isDirectory: false
                            )
                        )
                    ),
                    destinationRecord.manifest.downloadID
                        == record.manifest.downloadID,
                    destinationRecord.manifest.itemID
                        == record.manifest.itemID,
                    destinationRecord.manifest.accountID == legacyID
                else {
                    throw .duplicateDownload
                }
                try persist(migrated)
                continue
            }
            guard fileManager.fileExists(atPath: source.path) else {
                throw .persistenceFailed
            }
            do {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: source, to: destination)
                do {
                    try persist(migrated)
                } catch {
                    try? fileManager.moveItem(at: destination, to: source)
                    throw error
                }
            } catch let error as DownloadStorageError {
                throw error
            } catch {
                throw .persistenceFailed
            }
        }
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
        return try preflight(requirement)
    }

    public func preflightRemaining(
        record: DownloadedBookRecord,
        tracks: [DownloadTrackPlan]
    ) throws(DownloadStorageError) -> DownloadStorageRequirement {
        var remainingBytes: Int64 = 0
        for track in tracks {
            guard
                let entry = record.manifest.entries.first(where: {
                    $0.trackIndex == track.index
                        && $0.expectedByteLength == track.expectedByteLength
                        && $0.destinationEntry == track.destinationEntry
                })
            else {
                throw .trackNotFound
            }
            let identity: DownloadTaskIdentity
            do {
                identity = try DownloadTaskIdentity(
                    downloadID: record.manifest.downloadID,
                    accountID: record.manifest.accountID,
                    itemID: record.manifest.itemID,
                    track: track
                )
            } catch {
                throw .invalidStoredRecord
            }
            let committed = try layout.partialByteLength(for: identity)
            let remaining = max(entry.expectedByteLength - committed, 0)
            let (sum, overflow) = remainingBytes.addingReportingOverflow(
                remaining
            )
            guard !overflow else {
                throw .requirementOverflow
            }
            remainingBytes = sum
        }
        return try preflight(
            DownloadStorageRequirement(expectedBytes: remainingBytes)
        )
    }

    private func preflight(
        _ requirement: DownloadStorageRequirement
    ) throws(DownloadStorageError) -> DownloadStorageRequirement {
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
        purpose: DownloadPurpose = .manual,
        automaticTargetTrackIndexes: Set<Int>? = nil
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
        let manifest: DownloadManifest
        do {
            manifest = try DownloadManifest(
                downloadID: downloadID,
                accountID: accountID,
                plan: plan,
                purpose: purpose,
                automaticTargetTrackIndexes:
                    automaticTargetTrackIndexes
            )
        } catch {
            throw .invalidAutomaticWindow
        }
        let record = DownloadedBookRecord(
            manifest: manifest,
            detail: detail
        )
        try persist(record)
        return record
    }

    public func updateAutomaticWindow(
        _ storedRecord: DownloadedBookRecord,
        targetTrackIndexes: Set<Int>
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(storedRecord)
        do {
            try record.manifest.setAutomaticWindow(
                targetTrackIndexes: targetTrackIndexes
            )
        } catch {
            throw .invalidAutomaticWindow
        }
        try persist(record)
        return record
    }

    public func promoteToManual(
        _ storedRecord: DownloadedBookRecord
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(storedRecord)
        guard record.manifest.purpose == .automaticCache,
            record.manifest.automaticWindow != nil
        else {
            throw .invalidAutomaticWindow
        }
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

    public func markDownloading(
        _ identity: DownloadTaskIdentity,
        observedByteLength: Int64,
        validator: DownloadValidator?
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(identity)
        do {
            try record.manifest.markDownloading(
                trackIndex: identity.trackIndex,
                observedByteLength: observedByteLength,
                validator: validator
            )
        } catch {
            throw .trackNotFound
        }
        try persist(record)
        return record
    }

    public func markPaused(
        _ identity: DownloadTaskIdentity,
        observedByteLength: Int64
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(identity)
        do {
            try record.manifest.markPaused(
                trackIndex: identity.trackIndex,
                observedByteLength: observedByteLength
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

    public func markQueued(
        _ identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = try load(identity)
        do {
            try record.manifest.markQueued(
                trackIndex: identity.trackIndex
            )
        } catch {
            throw .trackNotFound
        }
        try persist(record)
        return record
    }

    public func removeTrackFiles(
        _ identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) {
        let directory = layout.bookDirectory(
            accountID: identity.accountID,
            itemID: identity.itemID
        )
        let destination = directory.appendingPathComponent(
            identity.destinationEntry,
            isDirectory: false
        )
        let partial = directory.appendingPathComponent(
            identity.destinationEntry + ".partial",
            isDirectory: false
        )
        do {
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
        } catch {
            throw .persistenceFailed
        }
    }

    public func partialByteLength(
        _ identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) -> Int64 {
        try layout.partialByteLength(for: identity)
    }

    public func discardPartial(
        _ identity: DownloadTaskIdentity
    ) throws(DownloadStorageError) {
        let partial = layout.partialURL(for: identity)
        do {
            if FileManager.default.fileExists(atPath: partial.path) {
                try FileManager.default.removeItem(at: partial)
            }
        } catch {
            throw .persistenceFailed
        }
    }

    public func commitChunk(
        _ identity: DownloadTaskIdentity,
        temporaryURL: URL,
        range: DownloadByteRange,
        validator: DownloadValidator?
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        let committed = try layout.appendChunk(
            from: temporaryURL,
            identity: identity,
            expectedOffset: range.start,
            expectedChunkLength: range.length
        )
        if committed == identity.expectedByteLength {
            _ = try layout.finalizePartial(identity)
            return try markComplete(
                identity,
                observedByteLength: committed
            )
        }
        return try markDownloading(
            identity,
            observedByteLength: committed,
            validator: validator
        )
    }

    public func recordCommittedChunk(
        _ identity: DownloadTaskIdentity,
        committedByteLength: Int64,
        validator: DownloadValidator?,
        finalized: Bool
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        if finalized {
            return try markComplete(
                identity,
                observedByteLength: committedByteLength
            )
        }
        return try markDownloading(
            identity,
            observedByteLength: committedByteLength,
            validator: validator
        )
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
            let record: DownloadedBookRecord
            do {
                let data = try Data(contentsOf: url)
                record = try decoder.decode(
                    DownloadedBookRecord.self,
                    from: data
                )
            } catch {
                try removeInvalidRecord(at: url, fileManager: fileManager)
                continue
            }
            do {
                records.append(try reconcileCompletedFiles(in: record))
            } catch DownloadStorageError.invalidStoredRecord {
                try removeInvalidRecord(at: url, fileManager: fileManager)
            } catch let error {
                throw error
            }
        }
        return records.sorted {
            $0.detail.title.localizedStandardCompare(
                $1.detail.title
            ) == .orderedAscending
        }
    }

    private func removeInvalidRecord(
        at recordURL: URL,
        fileManager: FileManager
    ) throws(DownloadStorageError) {
        do {
            try fileManager.removeItem(
                at: recordURL.deletingLastPathComponent()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    public func localTrackURLs(
        for record: DownloadedBookRecord
    ) throws(DownloadStorageError) -> [URL] {
        let reconciled = try reconcileCompletedFiles(in: record)
        guard reconciled.manifest.state == .complete else {
            throw .invalidStoredRecord
        }
        let trackIndexes = Set(
            reconciled.manifest.entries.map(\.trackIndex)
        )
        let urlsByTrackIndex = try localTrackURLs(
            for: reconciled,
            trackIndexes: trackIndexes
        )
        var urls: [URL] = []
        for entry in reconciled.manifest.entries.sorted(by: {
            $0.trackIndex < $1.trackIndex
        }) {
            guard let url = urlsByTrackIndex[entry.trackIndex] else {
                throw .invalidStoredRecord
            }
            urls.append(url)
        }
        return urls
    }

    public func localTrackURLs(
        for record: DownloadedBookRecord,
        trackIndexes: Set<Int>
    ) throws(DownloadStorageError) -> [Int: URL] {
        guard !trackIndexes.isEmpty else {
            throw .trackNotFound
        }
        let reconciled = try reconcileCompletedFiles(in: record)
        let entries = reconciled.manifest.entries.filter {
            trackIndexes.contains($0.trackIndex)
        }
        guard entries.count == trackIndexes.count else {
            throw .trackNotFound
        }
        var urlsByTrackIndex: [Int: URL] = [:]
        urlsByTrackIndex.reserveCapacity(entries.count)
        for entry in entries {
            guard entry.state == .complete,
                entry.placement == .finalized,
                entry.observedByteLength == entry.expectedByteLength
            else {
                throw .invalidStoredRecord
            }
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
            urlsByTrackIndex[entry.trackIndex] = url
        }
        return urlsByTrackIndex
    }

    private func reconcileCompletedFiles(
        in storedRecord: DownloadedBookRecord
    ) throws(DownloadStorageError) -> DownloadedBookRecord {
        var record = storedRecord
        var changed = false
        for entry in record.manifest.entries {
            let directory = layout.bookDirectory(
                accountID: record.manifest.accountID,
                itemID: record.manifest.itemID
            )
            let destination = directory.appendingPathComponent(
                entry.destinationEntry,
                isDirectory: false
            )
            let finalizedLength = Self.fileSize(at: destination)
            if finalizedLength == entry.expectedByteLength {
                if entry.state != .complete
                    || entry.placement != .finalized
                    || entry.observedByteLength != entry.expectedByteLength
                {
                    do {
                        try record.manifest.markComplete(
                            trackIndex: entry.trackIndex,
                            observedByteLength: finalizedLength,
                            placement: .finalized
                        )
                    } catch {
                        throw .invalidStoredRecord
                    }
                    changed = true
                }
                let partial = directory.appendingPathComponent(
                    entry.destinationEntry + ".partial",
                    isDirectory: false
                )
                if FileManager.default.fileExists(atPath: partial.path) {
                    do {
                        try FileManager.default.removeItem(at: partial)
                    } catch {
                        throw .persistenceFailed
                    }
                }
                continue
            }

            if finalizedLength >= 0 {
                do {
                    try FileManager.default.removeItem(at: destination)
                } catch {
                    throw .persistenceFailed
                }
            }

            guard let identity = try? identity(for: entry, in: record),
                entry.inode != nil
            else {
                throw .invalidStoredRecord
            }
            let partialLength: Int64
            do {
                partialLength = try layout.partialByteLength(for: identity)
            } catch .partialFileTooLarge {
                try discardPartial(identity)
                do {
                    try record.manifest.markFailed(
                        trackIndex: entry.trackIndex,
                        observedByteLength: 0
                    )
                } catch {
                    throw .invalidStoredRecord
                }
                changed = true
                continue
            } catch {
                throw error
            }
            if entry.state == .complete
                || partialLength != (entry.observedByteLength ?? 0)
            {
                do {
                    if entry.state == .complete {
                        try record.manifest.markPartial(
                            trackIndex: entry.trackIndex,
                            observedByteLength: partialLength,
                            placement: .temporary
                        )
                    } else {
                        try record.manifest.reconcileStoredBytes(
                            trackIndex: entry.trackIndex,
                            observedByteLength: partialLength
                        )
                    }
                } catch {
                    throw .invalidStoredRecord
                }
                changed = true
            }
        }
        if record.manifest.entries.allSatisfy({ $0.state == .complete }),
            record.manifest.state != .complete
        {
            do {
                try record.manifest.finish()
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

    private func identity(
        for entry: DownloadManifestEntry,
        in record: DownloadedBookRecord
    ) throws -> DownloadTaskIdentity {
        let track = DownloadTrackPlan(
            index: entry.trackIndex,
            inode: entry.inode ?? "stored",
            expectedByteLength: entry.expectedByteLength,
            mimeType: "stored",
            safeExtension: Self.safeExtension(
                destinationEntry: entry.destinationEntry
            ) ?? .mp3,
            destinationEntry: entry.destinationEntry,
            startOffset: entry.startOffset,
            duration: entry.duration
        )
        return try DownloadTaskIdentity(
            downloadID: record.manifest.downloadID,
            accountID: record.manifest.accountID,
            itemID: record.manifest.itemID,
            track: track
        )
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
