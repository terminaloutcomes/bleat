import CloudKit
import Foundation
import SwiftData

/// Private migration evidence, not a full CloudKit backup. Each record contains
/// its original application payload, not serialized CKRecord system fields.
public struct PrivateCloudHistoryArchive: Codable, Sendable {
    public static let currentVersion = 1
    public static let maximumArchiveBytes = 64 * 1024 * 1024
    static let maximumPayloadBytes = 40 * 1024 * 1024
    static let maximumRecords = 50_000

    public enum Failure: String, Error, Codable, Sendable {
        case invalidArchive, unsupportedVersion, incompleteCapture
        case invalidRecord, duplicateRecord, accountMismatch
        case captureFailed, replayFailed, archiveTooLarge
    }

    public enum Scope: String, Codable, Sendable {
        case listeningSlices
    }

    struct Record: Codable, Sendable {
        let name: String
        let payload: Data
    }

    public struct Summary: Codable, Equatable, Sendable {
        public let version: Int
        public let scope: Scope
        public let completeForScope: Bool
        public let legacySliceCount: Int
        public let currentSliceCount: Int
        public let accountCount: Int
        public let sourceBuild: String?
    }

    public struct ReplaySummary: Codable, Equatable, Sendable {
        public let source: Summary
        public let preparedCanonicalUploadCount: Int
    }

    public let version: Int
    public let scope: Scope
    public let completeForScope: Bool
    public let sourceBuild: String?
    private let records: [Record]

    static func capture(_ source: [CKRecord], sourceBuild: String? = nil) throws
        -> Self
    {
        let archive = Self(
            version: currentVersion, scope: .listeningSlices,
            completeForScope: true, sourceBuild: sourceBuild,
            records: try source.filter { $0.recordType == "ListeningSlice" }.map
            {
                guard let payload = $0["payload"] as? Data else {
                    throw Failure.invalidRecord
                }
                return Record(name: $0.recordID.recordName, payload: payload)
            }.sorted { $0.name < $1.name }
        )
        _ = try archive.validated()
        return archive
    }

    public static func decode(_ data: Data) throws -> Self {
        struct Header: Decodable { let version: Int }
        guard data.count <= maximumArchiveBytes else {
            throw Failure.archiveTooLarge
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw Failure.invalidArchive
        }
        guard header.version == currentVersion else {
            throw Failure.unsupportedVersion
        }
        guard let archive = try? decoder.decode(Self.self, from: data) else {
            throw Failure.invalidArchive
        }
        _ = try archive.validated()
        return archive
    }

    public func encoded() throws -> Data {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumArchiveBytes else {
            throw Failure.archiveTooLarge
        }
        return data
    }

    public func preview() throws -> Summary {
        let values = try validated().map(\.1)
        let legacy = values.filter { $0.recordingFormat == nil }.count
        return Summary(
            version: version, scope: scope, completeForScope: completeForScope,
            legacySliceCount: legacy, currentSliceCount: values.count - legacy,
            accountCount: Set(values.map(\.accountID)).count,
            sourceBuild: sourceBuild
        )
    }

    public func sourceAccountIDs() throws -> Set<AccountID> {
        Set(try validated().map { $0.1.accountID })
    }

    // Compare structure to the codec's typed representation. Preserve original
    // bytes but reject unknown keys (including nested opaque future fields).
    static func matchesShape(_ source: Any, _ typed: Any) -> Bool {
        if let source = source as? [String: Any],
            let typed = typed as? [String: Any]
        {
            return source.allSatisfy { key, value in
                typed[key].map { matchesShape(value, $0) } ?? false
            }
        }
        if let source = source as? [Any], let typed = typed as? [Any] {
            return source.count == typed.count
                && zip(source, typed).allSatisfy { matchesShape($0, $1) }
        }
        return type(of: source) == type(of: typed)
            || (source is NSNumber && typed is NSNumber)
    }

    private func validated() throws -> [(Record, ListeningSlice)] {
        guard version == Self.currentVersion else {
            throw Failure.unsupportedVersion
        }
        guard completeForScope else { throw Failure.incompleteCapture }
        if let sourceBuild {
            guard sourceBuild.utf8.count <= 64, !sourceBuild.isEmpty,
                sourceBuild.utf8.allSatisfy({
                    (48...57).contains($0) || $0 == 46
                })
            else { throw Failure.invalidArchive }
        }
        guard records.count <= Self.maximumRecords else {
            throw Failure.archiveTooLarge
        }
        var availableBytes = Self.maximumPayloadBytes
        var names = Set<String>()
        return try records.sorted { $0.name < $1.name }.map { record in
            guard record.payload.count <= availableBytes else {
                throw Failure.archiveTooLarge
            }
            availableBytes -= record.payload.count
            guard names.insert(record.name).inserted else {
                throw Failure.duplicateRecord
            }
            guard
                record.payload.count
                    <= ListeningSegmentCodec.maximumPayloadBytes,
                let value = try? ListeningSegmentCodec.decode(record.payload),
                value.recordingState != .active,
                record.name == "slice.\(value.id.uuidString.lowercased())",
                let json = try? JSONSerialization.jsonObject(
                    with: record.payload),
                let typedBytes = try? ListeningSegmentCodec.encode(value),
                let typed = try? JSONSerialization.jsonObject(with: typedBytes),
                Self.matchesShape(json, typed)
            else { throw Failure.invalidRecord }
            return (record, value)
        }
    }

    /// Replay always stages in memory with no CKContainer, credentials, or
    /// target account store. A failed attempt publishes no result and can retry.
    /// Account confirmation is identity-only; cross-account remapping is refused.
    public func replay(confirmedAccountIDs: Set<AccountID>) async throws
        -> StatisticsSummary
    {
        try await replayEvidence(confirmedAccountIDs: confirmedAccountIDs)
            .summary
    }

    public func replaySummary(confirmedAccountIDs: Set<AccountID>) async throws
        -> ReplaySummary
    {
        let source = try preview()
        let result = try await replayEvidence(
            confirmedAccountIDs: confirmedAccountIDs)
        return ReplaySummary(
            source: source,
            preparedCanonicalUploadCount: result.preparedSlices.filter {
                $0.recordingFormat != nil
            }.count
        )
    }

    struct ReplayEvidence: Sendable {
        let summary: StatisticsSummary
        let preparedSlices: [ListeningSlice]
    }

    func replayEvidence(
        confirmedAccountIDs: Set<AccountID>,
        afterInitialApply: @Sendable () async throws -> Void = {}
    ) async throws -> ReplayEvidence {
        let verified = try validated()
        guard Set(verified.map { $0.1.accountID }) == confirmedAccountIDs else {
            throw Failure.accountMismatch
        }
        do {
            try Task.checkCancellation()
            let schema = Schema(BleatPersistenceModelCatalog.allModelTypes)
            let model = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        schema: schema, isStoredInMemoryOnly: true,
                        cloudKitDatabase: .none
                    )
                ]
            )
            let suite = "bleat.archive-replay.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite),
                let configurationDefaults = UserDefaults(suiteName: suite)
            else {
                throw Failure.replayFailed
            }
            defer { defaults.removePersistentDomain(forName: suite) }
            let statistics = StatisticsRepository(modelContainer: model)
            let store = PrivateCloudSyncStore(
                statistics: statistics,
                accounts: AccountStore(modelContainer: model),
                credentialStore: nil,
                configuration: CloudConfigurationStore(
                    defaults: configurationDefaults),
                defaults: PrivateCloudDefaultsReference(defaults)
            )
            let zone = CKRecordZone.ID(zoneName: "OfflineArchiveReplay")
            let records = verified.map { source, _ in
                let record = CKRecord(
                    recordType: "ListeningSlice",
                    recordID: CKRecord.ID(recordName: source.name, zoneID: zone)
                )
                record["payload"] = source.payload as CKRecordValue
                return record
            }
            _ = try await store.applyFetchedRecords(
                records, persistState: false
            ) {
                try Task.checkCancellation()
            }
            try await afterInitialApply()
            let first = try await statistics.summary()
            let firstRecords = try await statistics.archive()
            _ = try await store.applyFetchedRecords(
                records, persistState: false
            ) {
                try Task.checkCancellation()
            }
            let second = try await statistics.summary()
            let secondRecords = try await statistics.archive()
            guard first == second, firstRecords.slices == secondRecords.slices,
                firstRecords.resetEnvelopes == secondRecords.resetEnvelopes
            else { throw Failure.replayFailed }
            // Exercise the same explicit canonical-upgrade path as the app.
            CloudStorageUpgradeNotice.confirmCanonicalRetirement(in: defaults)
            let prepared = try await store.prepareRecords(
                zoneID: zone, allowCompaction: true)
            let migrated = try await statistics.summary()
            guard migrated == first else { throw Failure.replayFailed }
            try Task.checkCancellation()
            return ReplayEvidence(
                summary: migrated,
                preparedSlices: try prepared.filter {
                    $0.recordType == "ListeningSlice"
                }
                .map(ListeningSegmentCodec.decode)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.replayFailed
        }
    }
}
