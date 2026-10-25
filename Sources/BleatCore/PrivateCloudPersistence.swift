import CloudKit
import Foundation
import SwiftData

public enum PrivateCloudStorageFailure: Error, Codable, Equatable, Sendable {
    case invalidLegacyMetadata
    case invalidLegacyState
    case invalidStoredState
    case migrationVerificationFailed
    case metadataReadFailed(PrivateCloudSystemError)
    case metadataWriteFailed(PrivateCloudSystemError)
    case stateReadFailed(PrivateCloudSystemError)
    case stateWriteFailed(PrivateCloudSystemError)
    var systemError: PrivateCloudSystemError? {
        switch self {
        case .metadataReadFailed(let error), .metadataWriteFailed(let error),
            .stateReadFailed(let error), .stateWriteFailed(let error):
            error
        default: nil
        }
    }

}

@Model
public final class PrivateCloudRecordMetadata {
    #Index<PrivateCloudRecordMetadata>([\.recordName], [\.accountID])
    @Attribute(.unique) var identity: String
    var recordName: String
    var zoneName: String
    var ownerName: String
    var recordType: String
    var accountID: String?
    var systemFields: Data
    var synchronizedDigest: Data?
    var retainedPayload: Data?

    init(
        record: CKRecord, systemFields: Data, accountID: String?, digest: Data?,
        payload: Data?
    ) {
        identity = PrivateCloudPersistence.identity(record.recordID)
        recordName = record.recordID.recordName
        zoneName = record.recordID.zoneID.zoneName
        ownerName = record.recordID.zoneID.ownerName
        recordType = record.recordType
        self.accountID = accountID
        self.systemFields = systemFields
        synchronizedDigest = digest
        retainedPayload = payload
    }
}

@Model
public final class PrivateCloudStateRecord {
    @Attribute(.unique) var key: String
    var payload: Data
    init(key: String, payload: Data) {
        self.key = key
        self.payload = payload
    }
}

struct PrivateCloudMetadataValue: Sendable {
    let systemFields: Data
    let synchronizedDigest: Data?
    let retainedPayload: Data?
}

/// User-approved SwiftData boundary for issue #355. ModelContext only exposes
/// synchronous fetch/save. PrivateCloudSyncStore owns all calls on its actor;
/// no work runs in its composition initializer or blocks MainActor. Replace
/// this boundary when SwiftData offers native asynchronous transactions.
struct PrivateCloudPersistence: Sendable {
    let container: ModelContainer
    static let legacyNoticeNeededKey = "cloud_metadata_legacy_notice_v2"
    static let migrationKey = "cloud_metadata_migration_v2"
    static let metadataKey = "bleat.cloudKit.recordSystemFields.v1"
    static let digestKey = "bleat.cloudKit.synchronizedPayloadDigests.v1"
    static let retainedKey = "bleat.cloudKit.retainedRecordPayloads.v1"
    static let engineKey = "bleat.cloudKit.syncEngineState.v1"
    static let stateKeys = [
        engineKey,
        "bleat.cloudKit.ignoredAccounts.v1",
        "bleat.cloudKit.ignoredStatisticsAccounts.v1",
        "bleat.cloudKit.pendingConfigurationConflict.v1",
        "bleat.cloudKit.pendingAccountChanges.v1",
        "bleat.cloudKit.legacyAccountIdentityMappings.v1",
        "bleat.cloudKit.pendingLegacyRecordDeletions.v1",
    ]

    static func identity(_ id: CKRecord.ID) -> String {
        [id.zoneID.ownerName, id.zoneID.zoneName, id.recordName]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }

    func context() -> ModelContext {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        return context
    }

    func metadata(_ id: CKRecord.ID) throws -> PrivateCloudMetadataValue? {
        let key = Self.identity(id)
        do {
            let context = context()
            guard
                let row = try context.fetch(
                    FetchDescriptor<PrivateCloudRecordMetadata>(
                        predicate: #Predicate { $0.identity == key })
                ).first
            else { return nil }
            return PrivateCloudMetadataValue(
                systemFields: row.systemFields,
                synchronizedDigest: row.synchronizedDigest,
                retainedPayload: row.retainedPayload)
        } catch {
            throw PrivateCloudSyncError.storage(
                .metadataReadFailed(PrivateCloudSystemError(error)))
        }
    }

    func recordIDs(accountID: AccountID? = nil, includeStatistics: Bool = true)
        throws -> [CKRecord.ID]
    {
        do {
            let context = context()
            let records: [PrivateCloudRecordMetadata]
            if let accountID {
                let account = accountID.rawValue
                if includeStatistics {
                    records = try context.fetch(
                        FetchDescriptor<PrivateCloudRecordMetadata>(
                            predicate: #Predicate { $0.accountID == account }))
                } else {
                    records = try context.fetch(
                        FetchDescriptor<PrivateCloudRecordMetadata>(
                            predicate: #Predicate {
                                $0.accountID == account
                                    && $0.recordType == "ServerAccount"
                            }))
                }
            } else {
                records = try context.fetch(
                    FetchDescriptor<PrivateCloudRecordMetadata>())
            }
            return records.map {
                CKRecord.ID(
                    recordName: $0.recordName,
                    zoneID: CKRecordZone.ID(
                        zoneName: $0.zoneName, ownerName: $0.ownerName))
            }
        } catch {
            throw PrivateCloudSyncError.storage(
                .metadataReadFailed(PrivateCloudSystemError(error)))
        }
    }

    func commit(
        records: [CKRecord], deleted: Set<CKRecord.ID>, digests: [String: Data],
        retainingPayloadFor: Set<CKRecord.ID> = []
    ) throws {
        let context = context()
        do {
            for id in deleted {
                let key = Self.identity(id)
                for row in try context.fetch(
                    FetchDescriptor<PrivateCloudRecordMetadata>(
                        predicate: #Predicate { $0.identity == key }))
                { context.delete(row) }
            }
            for record in records {
                let key = Self.identity(record.recordID)
                let fields = Self.encodeSystemFields(record)
                let payload =
                    (record.recordType == "ServerAccount"
                        || record.recordType == "Configuration"
                        || retainingPayloadFor.contains(record.recordID))
                    ? record[PrivateCloudSyncStore.payloadKey] as? Data : nil
                let accountID = try Self.accountID(
                    record: record, context: context)
                if let row = try context.fetch(
                    FetchDescriptor<PrivateCloudRecordMetadata>(
                        predicate: #Predicate { $0.identity == key })
                ).first {
                    row.systemFields = fields
                    row.synchronizedDigest = digests[record.recordID.recordName]
                    row.retainedPayload = payload
                    if let accountID { row.accountID = accountID }
                } else {
                    context.insert(
                        PrivateCloudRecordMetadata(
                            record: record, systemFields: fields,
                            accountID: accountID,
                            digest: digests[record.recordID.recordName],
                            payload: payload))
                }
            }
            try context.save()
        } catch let error as PrivateCloudSyncError { throw error } catch {
            throw PrivateCloudSyncError.storage(
                .metadataWriteFailed(PrivateCloudSystemError(error)))
        }
    }

    private static func accountID(record: CKRecord, context: ModelContext)
        throws
        -> String?
    {
        if let payload = record[PrivateCloudSyncStore.payloadKey] as? Data {
            switch record.recordType {
            case "ListeningSlice":
                return
                    (try? JSONDecoder().decode(
                        ListeningSlice.self, from: payload))?.accountID.rawValue
            case "CompletionMilestone":
                return
                    (try? JSONDecoder().decode(
                        CompletionMilestone.self, from: payload))?.accountID
                    .rawValue
            case "RemoteListeningSession":
                return
                    (try? JSONDecoder().decode(
                        RemoteListeningSession.self, from: payload))?.accountID
                    .rawValue
            case "ServerAccount":
                return
                    (try? JSONDecoder().decode(
                        CloudServerAccountRecordPayload.self, from: payload))?
                    .account.id.rawValue
            default: return nil
            }
        }
        do {
            let name = record.recordID.recordName
            if record.recordType == "ListeningSlice", name.hasPrefix("slice."),
                let id = UUID(
                    uuidString: String(name.dropFirst("slice.".count)))
            {
                return try context.fetch(
                    FetchDescriptor<ListeningSliceRecord>(
                        predicate: #Predicate { $0.eventID == id })
                ).first?.accountID
            }
            if record.recordType == "CompletionMilestone",
                name.hasPrefix("completion."),
                let id = UUID(
                    uuidString: String(name.dropFirst("completion.".count)))
            {
                return try context.fetch(
                    FetchDescriptor<CompletionMilestoneRecord>(
                        predicate: #Predicate { $0.eventID == id })
                ).first?.accountID
            }
            if record.recordType == "ServerAccount", name.hasPrefix("account.")
            {
                return String(name.dropFirst("account.".count))
            }
            if record.recordType == "RemoteListeningSession" {
                let matches = try context.fetch(
                    FetchDescriptor<RemoteListeningSessionRecord>()
                ).filter {
                    "remote.\($0.accountID).\($0.sessionID)" == name
                }
                guard matches.count <= 1 else {
                    throw PrivateCloudSyncError.storage(.invalidLegacyMetadata)
                }
                return matches.first?.accountID
            }
        } catch let error as PrivateCloudSyncError { throw error } catch {
            throw PrivateCloudSyncError.storage(
                .metadataReadFailed(PrivateCloudSystemError(error)))
        }

        return nil
    }

    func value(forKey key: String) throws -> Any? {
        do {
            guard
                let row = try context().fetch(
                    FetchDescriptor<PrivateCloudStateRecord>(
                        predicate: #Predicate { $0.key == key })
                ).first
            else { return nil }
            return try PropertyListSerialization.propertyList(
                from: row.payload, format: nil)
        } catch {
            throw PrivateCloudSyncError.storage(
                .stateReadFailed(PrivateCloudSystemError(error)))
        }
    }

    func set(_ value: Any, forKey key: String) throws {
        let context = context()
        do {
            let payload = try PropertyListSerialization.data(
                fromPropertyList: value, format: .binary, options: 0)
            if let row = try context.fetch(
                FetchDescriptor<PrivateCloudStateRecord>(
                    predicate: #Predicate { $0.key == key })
            ).first {
                row.payload = payload
            } else {
                context.insert(
                    PrivateCloudStateRecord(key: key, payload: payload))
            }
            try context.save()
        } catch {
            throw PrivateCloudSyncError.storage(
                .stateWriteFailed(PrivateCloudSystemError(error)))
        }
    }
    func removeObject(forKey key: String) throws {
        let context = context()
        do {
            for row in try context.fetch(
                FetchDescriptor<PrivateCloudStateRecord>(
                    predicate: #Predicate { $0.key == key }))
            { context.delete(row) }
            try context.save()
        } catch {
            throw PrivateCloudSyncError.storage(
                .stateWriteFailed(PrivateCloudSystemError(error)))
        }
    }
    func dictionary(forKey key: String) throws -> [String: Any]? {
        guard let value = try value(forKey: key) else { return nil }
        guard let result = value as? [String: Any] else {
            throw PrivateCloudSyncError.storage(.invalidStoredState)
        }
        return result
    }
    func data(forKey key: String) throws -> Data? {
        guard let value = try value(forKey: key) else { return nil }
        guard let result = value as? Data else {
            throw PrivateCloudSyncError.storage(.invalidStoredState)
        }
        return result
    }
    func stringArray(forKey key: String) throws -> [String]? {
        guard let value = try value(forKey: key) else { return nil }
        guard let result = value as? [String] else {
            throw PrivateCloudSyncError.storage(.invalidStoredState)
        }
        return result
    }

    func migrationComplete() throws -> Bool {
        guard let value = try value(forKey: Self.migrationKey) else {
            return false
        }
        guard let result = value as? Bool else {
            throw PrivateCloudSyncError.storage(.invalidStoredState)
        }
        return result
    }

    func importBatch(
        _ values: [(String, Data)], digests: [String: Data],
        payloads: [String: Data]
    ) throws {
        let context = context()
        do {
            for (name, data) in values {
                guard let record = Self.decodeSystemFields(data),
                    record.recordID.recordName == name
                else {
                    throw PrivateCloudSyncError.storage(.invalidLegacyMetadata)
                }
                let key = Self.identity(record.recordID)
                if let payload = payloads[name] {
                    record[PrivateCloudSyncStore.payloadKey] =
                        payload as CKRecordValue
                }
                if let row = try context.fetch(
                    FetchDescriptor<PrivateCloudRecordMetadata>(
                        predicate: #Predicate { $0.identity == key })
                ).first {
                    // The migration must faithfully copy opaque secure archives.
                    // Exact bytes here verify storage fidelity, not CKRecord semantics.
                    guard row.systemFields == data else {
                        throw PrivateCloudSyncError.storage(
                            .migrationVerificationFailed)
                    }
                    row.synchronizedDigest = digests[name]
                    row.retainedPayload = payloads[name]
                } else {
                    context.insert(
                        PrivateCloudRecordMetadata(
                            record: record, systemFields: data,
                            accountID: try Self.accountID(
                                record: record, context: context),
                            digest: digests[name], payload: payloads[name]))
                }
            }
            try context.save()
        } catch let error as PrivateCloudSyncError { throw error } catch {
            throw PrivateCloudSyncError.storage(
                .metadataWriteFailed(PrivateCloudSystemError(error)))
        }
    }

    // Migration fidelity intentionally verifies opaque archives, hash identities,
    // and retained wire payload bytes, never semantic application value equality.
    func verifyBatch(
        _ values: [(String, Data)], digests: [String: Data],
        payloads: [String: Data]
    ) throws {
        for (name, data) in values {
            guard let record = Self.decodeSystemFields(data),
                record.recordID.recordName == name,
                let row = try metadata(record.recordID),
                row.systemFields == data,
                row.synchronizedDigest == digests[name],
                row.retainedPayload == payloads[name]
            else {
                throw PrivateCloudSyncError.storage(
                    .migrationVerificationFailed)
            }
        }
    }

    func removeMetadata() throws {
        let context = context()
        do {
            try context.delete(model: PrivateCloudRecordMetadata.self)
            try context.save()
        } catch {
            throw PrivateCloudSyncError.storage(
                .metadataWriteFailed(PrivateCloudSystemError(error)))
        }
    }

    static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }
    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data)
        else { return nil }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        defer { unarchiver.finishDecoding() }
        guard unarchiver.containsValue(forKey: "RecordType"),
            let type = unarchiver.decodeObject(
                of: NSString.self, forKey: "RecordType"), !type.isEqual(to: ""),
            unarchiver.containsValue(forKey: "RecordID"),
            unarchiver.decodeObject(of: CKRecord.ID.self, forKey: "RecordID")
                != nil,
            unarchiver.error == nil
        else { return nil }
        let record = CKRecord(coder: unarchiver)
        return unarchiver.error == nil ? record : nil
    }
}

public enum CloudStorageUpgradeNotice {
    public static let introducedInVersion = "2026.10.14"
    private static let detectedKey = "bleat.cloudStorageUpgrade.v2.detected"
    // The revised notice requires explicit device-update confirmation. The old
    // OK acknowledgement must not suppress it; retain legacy detection so an
    // already migrated installation can present it without another migration.
    private static let acknowledgedKey =
        "bleat.cloudStorageUpgrade.v3.acknowledged"
    public static func detectLegacy(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: detectedKey) else { return }
        defaults.set(true, forKey: detectedKey)
    }
    public static func isPending(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: detectedKey)
            && !defaults.bool(forKey: acknowledgedKey)
    }
    public static func acknowledge(in defaults: UserDefaults) {
        defaults.set(true, forKey: acknowledgedKey)
    }
}
