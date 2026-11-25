import CloudKit
import Foundation
import SwiftData

/// Materializes a validated backup in a caller-owned fresh generation.
/// It has no CloudKit transport, credentials, or access to the normal model.
public enum PrivateCloudIsolatedMaterializer {
    public struct Inspection: Codable, Equatable, Sendable {
        public let accounts: Int
        public let configurations: Int
        public let listeningSlices: Int
        public let resetEnvelopes: Int
        public let completions: Int
        public let remoteSessions: Int
    }

    enum Failure: String, Error {
        case generationExists, missingMaterialization
        case configurationUnavailable, ambiguousAccount
        case materializedAccountsMismatch, readbackMismatch
    }

    /// The generation directory must be a new private directory owned by
    /// the caller, outside the application store and excluded from backups.
    static func materialize(
        _ entries: [PrivateCloudBackup.Entry], directory: URL
    ) async throws -> Inspection {
        try await materialize(entries, storeURL: storeURL(in: directory))
    }

    static func materialize(
        _ entries: [PrivateCloudBackup.Entry], storeURL: URL
    ) async throws -> Inspection {
        try Task.checkCancellation()
        let staged = try await apply(entries, storeURL: storeURL)
        try Task.checkCancellation()
        let reopened = try await Workspace(storeURL: storeURL, existing: true)
            .inspection()
        guard reopened == staged else { throw Failure.readbackMismatch }
        return reopened
    }

    static func inspect(directory: URL) async throws -> Inspection {
        let workspace = try Workspace(
            storeURL: storeURL(in: directory), existing: true)
        return try await workspace.inspection()
    }

    static func restoredConfiguration(storeURL: URL) async throws
        -> CloudConfigurationSnapshot?
    {
        try await Workspace(storeURL: storeURL, existing: true).configuration()
    }

    private static func storeURL(in directory: URL) -> URL {
        directory.appending(
            path: "materialized.store", directoryHint: .notDirectory)
    }

    private static func apply(
        _ entries: [PrivateCloudBackup.Entry], storeURL: URL
    ) async throws -> Inspection {
        let workspace = try Workspace(storeURL: storeURL, existing: false)
        let suite = "bleat.isolated-restore.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite),
            let configurationDefaults = UserDefaults(suiteName: suite)
        else { throw Failure.configurationUnavailable }
        defer { defaults.removePersistentDomain(forName: suite) }

        let configuration = CloudConfigurationStore(
            defaults: configurationDefaults)
        let store = PrivateCloudSyncStore(
            statistics: workspace.statistics, accounts: workspace.accounts,
            credentialStore: nil, configuration: configuration,
            defaults: PrivateCloudDefaultsReference(defaults)
        )
        let zone = CKRecordZone.ID(zoneName: "OfflineIsolatedRestore")
        let records = entries.map { entry in
            let record = CKRecord(
                recordType: entry.kind.rawValue,
                recordID: CKRecord.ID(recordName: entry.name, zoneID: zone)
            )
            record["payload"] = entry.payload as CKRecordValue
            return record
        }
        _ = try await store.applyFetchedRecords(
            records, persistState: false
        ) {
            try Task.checkCancellation()
        }
        // These account choices only affect the disposable account store.
        // Any synthesized pending upload is intentionally discarded.
        var confirmed = Set<AccountID>()
        for choice in await store.pendingServerConfigurationChanges() {
            try Task.checkCancellation()
            guard confirmed.insert(choice.incoming.id).inserted else {
                throw Failure.ambiguousAccount
            }
            _ = try await store.acceptServerConfigurationChange(
                accountID: choice.incoming.id, selected: choice.incoming,
                zoneID: zone
            )
        }
        if await store.configurationConflict() != nil {
            _ = try await store.resolveConfigurationConflict(
                .useICloud, zoneID: zone)
        }

        let decoder = JSONDecoder()
        let expectedAccounts = try Set(
            entries.filter { $0.kind == .account }.map { entry in
                let account: ServerAccount
                if let versioned = try? decoder.decode(
                    CloudServerAccountRecordPayload.self,
                    from: entry.payload
                ) {
                    account = versioned.account
                } else {
                    account = try decoder.decode(
                        ServerAccount.self, from: entry.payload)
                }
                return AccountID.canonical(
                    server: account.server, userID: account.user.id)
            }
        )
        guard
            try await Set(workspace.accounts.accounts().map(\.id))
                == expectedAccounts
        else { throw Failure.materializedAccountsMismatch }

        try Task.checkCancellation()
        let expectedSettings = try entries.first {
            $0.kind == .configuration
        }.map {
            try decoder.decode(
                CloudConfigurationSnapshot.self, from: $0.payload)
        }
        let settings = await configuration.snapshot()
        guard expectedSettings.map({ $0 == settings }) != false else {
            throw Failure.readbackMismatch
        }
        // UserDefaults is only the app's ingestion interface. Persist the
        // resulting preferences in the private generation for disk readback.
        try await workspace.finalizeConfiguration(
            expectedSettings == nil ? nil : settings)
        return try await workspace.inspection()
    }

    private actor Workspace {
        let statistics: StatisticsRepository
        let accounts: AccountStore
        private let persistence: PrivateCloudPersistence
        private static let receiptKey = "bleat.isolatedRestore.settings.v1"

        private struct SettingsReceipt: Codable {
            let snapshot: CloudConfigurationSnapshot?
        }

        // SwiftData still only provides synchronous initialization and
        // persistence primitives, as used by the existing app repositories.
        // The target is not opened by the application until confirmed activation.
        init(storeURL url: URL, existing: Bool) throws {
            guard
                FileManager.default.fileExists(atPath: url.path)
                    == existing
            else {
                throw existing
                    ? Failure.missingMaterialization
                    : Failure.generationExists
            }
            let schema = Schema(
                versionedSchema: BleatPersistenceSchemaCurrent.self)
            let model = try ModelContainer(
                for: schema,
                migrationPlan: BleatPersistenceSchemaMigrationPlan.self,
                configurations: [
                    ModelConfiguration(
                        schema: schema, url: url, cloudKitDatabase: .none
                    )
                ]
            )
            statistics = StatisticsRepository(modelContainer: model)
            accounts = AccountStore(modelContainer: model)
            persistence = PrivateCloudPersistence(container: model)
        }

        func finalizeConfiguration(
            _ snapshot: CloudConfigurationSnapshot?
        ) throws {
            // Ingestion can create migration bookkeeping even though no engine
            // exists. Do not adopt offline record IDs or inferred delete/upload
            // choices: the new engine will learn directly from its own zone.
            try persistence.removeMetadata()
            for key in PrivateCloudPersistence.stateKeys + [
                PrivateCloudPersistence.metadataKey,
                PrivateCloudPersistence.digestKey,
                PrivateCloudPersistence.retainedKey,
            ] {
                try persistence.removeObject(forKey: key)
            }
            let data = try JSONEncoder().encode(
                SettingsReceipt(snapshot: snapshot))
            try persistence.set(data, forKey: Self.receiptKey)
        }

        func configuration() throws -> CloudConfigurationSnapshot? {
            guard
                let data = try persistence.value(forKey: Self.receiptKey)
                    as? Data
            else { throw Failure.missingMaterialization }
            return try JSONDecoder().decode(SettingsReceipt.self, from: data)
                .snapshot
        }

        func inspection() async throws -> Inspection {
            let snapshot = try configuration()
            let accountCount = try await accounts.accounts().count
            let history = try await statistics.archive()
            return Inspection(
                accounts: accountCount,
                configurations: snapshot == nil ? 0 : 1,
                listeningSlices: history.slices.count,
                resetEnvelopes: history.resetEnvelopes?.count ?? 0,
                completions: history.completions.count,
                remoteSessions: history.remoteSessions.count
            )
        }
    }
}
