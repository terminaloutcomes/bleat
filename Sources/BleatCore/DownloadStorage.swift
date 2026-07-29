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
    case persistenceFailed
    case invalidStoredRecord
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

    @discardableResult
    public func create(
        downloadID: DownloadID,
        accountID: AccountID,
        plan: DownloadPlan,
        detail: LibraryBookDetail
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
                plan: plan
            ),
            detail: detail
        )
        try persist(record)
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
                records.append(
                    try decoder.decode(
                        DownloadedBookRecord.self,
                        from: data
                    ))
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
        guard record.manifest.state == .complete else {
            throw .invalidStoredRecord
        }
        let entries = record.manifest.entries.sorted {
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
                    downloadID: record.manifest.downloadID,
                    accountID: record.manifest.accountID,
                    itemID: record.manifest.itemID,
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
