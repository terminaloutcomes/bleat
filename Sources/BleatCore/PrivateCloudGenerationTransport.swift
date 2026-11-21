import CloudKit
import Foundation

/// Live restore transport. Publication selects a verified new zone without
/// deleting anything. It does not fence another device's ordinary writes;
/// the caller must arrange a maintenance pause and retire its local engine.
actor PrivateCloudGenerationTransport {
    enum Failure: String, Error, Sendable {
        case invalidTarget, unsupportedData, accountChanged, staleTarget
        case stagingFailed, verificationFailed, notPublished, indeterminate
    }

    struct Selection: Equatable, Sendable {
        let zoneID: CKRecordZone.ID
        let revision: UUID?
        let accountBinding: String
    }

    struct Active: Sendable {
        let selection: Selection
        let archive: PrivateCloudBackup

        var zoneID: CKRecordZone.ID { selection.zoneID }
        var revision: UUID? { selection.revision }
    }

    private struct Selector: Codable {
        static let version = 1
        let version: Int
        let generation: UUID
        let revision: UUID
        let accountBinding: String

        init(generation: UUID, revision: UUID, accountBinding: String) {
            version = Self.version
            self.generation = generation
            self.revision = revision
            self.accountBinding = accountBinding
        }
    }

    private struct Session: Equatable, Sendable {
        let owner: CKRecord.ID
        let binding: String
    }

    private struct SelectorRead {
        let selection: Selection
        let record: CKRecord?
    }

    private static let controlZoneName = "BleatRestoreControl"
    private static let dataZonePrefix = "BleatRestoredData-"
    private static let selectorName = "active-generation"
    private static let maximumPages = 4_096
    private static let batchRecordLimit = 100
    private static let batchPayloadLimit = 1_000_000
    private let container: CKContainer
    private let database: CKDatabase
    private var replacing = false

    init(container: CKContainer) {
        self.container = container
        database = container.privateCloudDatabase
    }

    func readSelection() async throws -> Selection {
        let session = try await openSession()
        return try await readSelector(in: session).selection
    }

    func readActive(allowMissingLegacy: Bool = false) async throws -> Active {
        let session = try await openSession()
        return try await readActive(
            in: session, allowMissingLegacy: allowMissingLegacy)
    }

    func replace(
        _ backup: PrivateCloudBackup, reviewed: Active,
        prepareLocal: @Sendable (String) async throws -> Void
    ) async throws -> Active {
        guard !replacing else { throw Failure.staleTarget }
        replacing = true
        defer { replacing = false }
        let session = try await openSession()
        let desired = try backup.restoreMaterial()
        guard desired.accountBinding == session.binding,
            reviewed.selection.accountBinding == session.binding
        else { throw Failure.accountChanged }
        let preimage = try reviewed.archive.restoreMaterial()
        _ = try await requireReview(reviewed, preimage: preimage, in: session)
        if desired == preimage { return reviewed }

        let candidate = Selector(
            generation: UUID(), revision: UUID(),
            accountBinding: session.binding)
        let next = selection(for: candidate, in: session)
        do {
            try await requireSession(session)
            let zone = try await database.save(
                CKRecordZone(zoneID: next.zoneID))
            guard zone.zoneID == next.zoneID,
                zone.capabilities.contains(.atomic)
            else { throw Failure.invalidTarget }
            try await write(desired.records, to: next.zoneID, in: session)
            let verified = try await scan(next.zoneID, in: session)
            guard try verified.restoreMaterial() == desired else {
                throw Failure.verificationFailed
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.stagingFailed
        }

        let selectorID = Self.selectorID(in: session)
        let selectorRecord: CKRecord
        do {
            // A recoverable local candidate must exist before publication. If this
            // callback fails, the ordinary selector still references its preimage.
            try await prepareLocal(next.zoneID.zoneName)
            try await requireSession(session)

            // Creating a control zone is not publication. It is safe to retain
            // an empty control zone and the unselected stage after interruption.
            try await requireSession(session)
            let existingZones = try await database.allRecordZones()
            let controlZoneID = Self.zoneID(Self.controlZoneName)
            if let control = existingZones.first(where: {
                $0.zoneID == controlZoneID
            }) {
                guard control.capabilities.contains(.atomic) else {
                    throw Failure.invalidTarget
                }
            } else {
                try await requireSession(session)
                let control = try await database.save(
                    CKRecordZone(zoneID: controlZoneID))
                guard control.zoneID == controlZoneID,
                    control.capabilities.contains(.atomic)
                else { throw Failure.invalidTarget }
            }
            let previous = try await requireReview(
                reviewed, preimage: preimage, in: session)
            let pointer = try await readSelector(in: session)
            guard pointer.selection == previous.selection else {
                throw Failure.staleTarget
            }
            try Task.checkCancellation()
            selectorRecord =
                pointer.record
                ?? CKRecord(
                    recordType: PrivateCloudBackup.Kind.configuration.rawValue,
                    recordID: selectorID)
            selectorRecord["payload"] =
                try JSONEncoder().encode(candidate)
                as CKRecordValue

        } catch Failure.staleTarget {
            throw Failure.staleTarget
        } catch {
            // No selector request has been submitted. The local pending
            // marker can be abandoned without risking a blind retry.
            throw Failure.notPublished
        }

        do {
            let result = try await database.modifyRecords(
                saving: [selectorRecord], deleting: [],
                savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard result.deleteResults.isEmpty, result.saveResults.count == 1,
                let saved = result.saveResults[selectorID]
            else { throw Failure.indeterminate }
            _ = try saved.get()
        } catch let error as CKError where error.code == .serverRecordChanged {
            throw Failure.staleTarget
        } catch {
            // A cancellation or network error after submission does not
            // establish that the selector failed to commit.
            guard let observed = try? await readSelector(in: session),
                observed.selection == next
            else { throw Failure.indeterminate }
        }
        // A successful save only establishes publication, not that another
        // selection or ordinary write has not superseded the verified result.
        guard let observed = try? await readActive(in: session),
            observed.selection == next,
            (try? observed.archive.restoreMaterial()) == desired
        else { throw Failure.indeterminate }
        return observed
    }

    private func requireReview(
        _ reviewed: Active, preimage: PrivateCloudBackup.RestoreMaterial,
        in session: Session
    ) async throws -> Active {
        let current = try await readActive(
            in: session, allowMissingLegacy: reviewed.revision == nil)
        guard current.selection == reviewed.selection,
            try current.archive.restoreMaterial() == preimage
        else { throw Failure.staleTarget }
        return current
    }

    private func openSession() async throws -> Session {
        guard
            container.containerIdentifier
                == PrivateCloudSyncCoordinator.containerIdentifier,
            database.databaseScope == .private
        else { throw Failure.invalidTarget }
        try Task.checkCancellation()
        let owner = try await container.userRecordID()
        return Session(
            owner: owner,
            binding: PrivateCloudBackup.binding(
                container: PrivateCloudSyncCoordinator.containerIdentifier,
                cloudUserRecordName: owner.recordName)
        )
    }

    private func requireSession(_ session: Session) async throws {
        try Task.checkCancellation()
        guard try await container.userRecordID() == session.owner else {
            throw Failure.accountChanged
        }
        try Task.checkCancellation()
    }

    private func readActive(
        in session: Session, allowMissingLegacy: Bool = false
    ) async throws -> Active {
        let before = try await readSelector(in: session).selection
        let zones = try await database.allRecordZones()
        guard zones.allSatisfy({ Self.isKnownZone($0.zoneID) }) else {
            throw Failure.unsupportedData
        }
        let archive: PrivateCloudBackup
        do {
            archive = try await scan(before.zoneID, in: session)
        } catch let error as CKError
            where
            error.code == .zoneNotFound && before.revision == nil
            && allowMissingLegacy
        {
            archive = try PrivateCloudBackup.capture(
                records: [], accountBinding: session.binding)
        }
        let after = try await readSelector(in: session).selection
        guard after == before else { throw Failure.staleTarget }
        return Active(selection: after, archive: archive)
    }

    private func readSelector(in session: Session) async throws -> SelectorRead
    {
        try await requireSession(session)
        let selectorID = Self.selectorID(in: session)
        let record: CKRecord
        do {
            record = try await database.record(for: selectorID)
        } catch let error as CKError
            where
            error.code == .zoneNotFound || error.code == .unknownItem
        {
            try await requireSession(session)
            return SelectorRead(
                selection: Selection(
                    zoneID: Self.zoneID(PrivateCloudSyncStore.zoneName),
                    revision: nil, accountBinding: session.binding),
                record: nil)
        }
        try await requireSession(session)
        guard record.recordID == selectorID, record.recordChangeTag != nil,
            record.recordType == PrivateCloudBackup.Kind.configuration.rawValue,
            Set(record.allKeys()) == ["payload"], record.parent == nil,
            record.share == nil, record.encryptedValues.allKeys().isEmpty,
            let payload = record["payload"] as? Data, payload.count <= 1_024,
            let object = try? JSONSerialization.jsonObject(with: payload)
                as? [String: Any],
            Set(object.keys) == [
                "version", "generation", "revision", "accountBinding",
            ],
            let selector = try? JSONDecoder().decode(
                Selector.self, from: payload),
            selector.version == Selector.version,
            selector.accountBinding == session.binding
        else { throw Failure.unsupportedData }
        return SelectorRead(
            selection: selection(for: selector, in: session), record: record)
    }

    private func scan(_ zone: CKRecordZone.ID, in session: Session)
        async throws -> PrivateCloudBackup
    {
        var cursor: CKServerChangeToken?
        var records: [CKRecord.ID: PrivateCloudBackup.Entry] = [:]
        var bytes = 0
        for _ in 0..<Self.maximumPages {
            try await requireSession(session)
            let page = try await database.recordZoneChanges(
                inZoneWith: zone, since: cursor, resultsLimit: 100)
            try await requireSession(session)
            for deletion in page.deletions {
                guard deletion.recordID.zoneID == zone,
                    page.modificationResultsByID[deletion.recordID] == nil
                else { throw Failure.unsupportedData }
                bytes -=
                    records.removeValue(forKey: deletion.recordID)?
                    .payload.count ?? 0
            }
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard record.recordID == id, id.zoneID == zone else {
                    throw Failure.unsupportedData
                }
                let entry = try PrivateCloudBackup.Entry(cloudRecord: record)
                let previous = records.updateValue(entry, forKey: id)
                bytes += entry.payload.count - (previous?.payload.count ?? 0)
                guard bytes <= PrivateCloudBackup.maximumPayloadBytes,
                    records.count <= PrivateCloudBackup.maximumRecords
                else { throw PrivateCloudBackup.Failure.archiveTooLarge }
            }
            if !page.moreComing {
                return try PrivateCloudBackup.capture(
                    records: Array(records.values),
                    accountBinding: session.binding,
                    sourceBuild: Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleVersion") as? String)
            }
            cursor = page.changeToken
        }
        throw Failure.verificationFailed
    }

    private func write(
        _ entries: [PrivateCloudBackup.Entry], to zone: CKRecordZone.ID,
        in session: Session
    ) async throws {
        var batch: [CKRecord] = []
        var bytes = 0
        for entry in entries {
            try Task.checkCancellation()
            if !batch.isEmpty,
                batch.count == Self.batchRecordLimit
                    || bytes + entry.payload.count > Self.batchPayloadLimit
            {
                try await writeBatch(batch, in: session)
                batch = []
                bytes = 0
            }
            let record = CKRecord(
                recordType: entry.kind.rawValue,
                recordID: CKRecord.ID(recordName: entry.name, zoneID: zone))
            record["payload"] = entry.payload as CKRecordValue
            batch.append(record)
            bytes += entry.payload.count
        }
        if !batch.isEmpty { try await writeBatch(batch, in: session) }
    }

    private func writeBatch(_ batch: [CKRecord], in session: Session)
        async throws
    {
        try await requireSession(session)
        do {
            let result = try await database.modifyRecords(
                saving: batch, deleting: [],
                savePolicy: .ifServerRecordUnchanged, atomically: true)
            guard result.deleteResults.isEmpty,
                Set(result.saveResults.keys) == Set(batch.map(\.recordID))
            else { throw Failure.stagingFailed }
            for save in result.saveResults.values { _ = try save.get() }
        } catch let error as CKError
            where
            error.code == .limitExceeded && batch.count > 1
        {
            // Only an unpublished stage can be safely split into operations.
            let midpoint = batch.count / 2
            try await writeBatch(Array(batch[..<midpoint]), in: session)
            try await writeBatch(Array(batch[midpoint...]), in: session)
        }
        try await requireSession(session)
    }

    private func selection(for selector: Selector, in session: Session)
        -> Selection
    {
        Selection(
            zoneID: Self.zoneID(
                Self.dataZonePrefix
                    + selector.generation.uuidString.lowercased()),
            revision: selector.revision, accountBinding: session.binding)
    }

    private static func isKnownZone(_ zone: CKRecordZone.ID) -> Bool {
        if [
            CKRecordZone.default().zoneID,
            zoneID(PrivateCloudSyncStore.zoneName),
            zoneID(controlZoneName),
        ].contains(zone) {
            return true
        }
        guard zone.ownerName == CKCurrentUserDefaultName,
            zone.zoneName.hasPrefix(dataZonePrefix)
        else { return false }
        let suffix = String(zone.zoneName.dropFirst(dataZonePrefix.count))
        return UUID(uuidString: suffix)?.uuidString.lowercased() == suffix
    }

    private static func zoneID(_ name: String) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
    }

    private static func selectorID(in session: Session) -> CKRecord.ID {
        // Selector lookup is account-scoped even if the device switches Apple
        // Accounts inside a suspended CloudKit operation.
        CKRecord.ID(
            recordName: "\(selectorName).\(session.binding)",
            zoneID: zoneID(controlZoneName))
    }
}
