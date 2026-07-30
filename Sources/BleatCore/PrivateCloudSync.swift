import CloudKit
import Foundation

public enum PrivateCloudSyncStatus: Equatable, Sendable {
    case disabled
    case idle
    case syncing
    case unavailable
    case failed
}

public enum PrivateCloudSyncError: Error, Equatable, Sendable {
    case disabled
    case accountUnavailable
    case invalidRecord
    case persistenceFailed
    case cloudUnavailable
}

public struct CloudConfigurationSnapshot:
    Codable, Equatable, Sendable
{
    public let defaultPlaybackRate: Double
    public let resumeRewindSeconds: Int
    public let skipBackwardSeconds: Int
    public let skipForwardSeconds: Int
    public let downloadNetworkPolicy: String
    public let automaticDownloadLookahead: Int
    public let automaticDownloadCleanupPolicy: String

    public init(
        defaultPlaybackRate: Double,
        resumeRewindSeconds: Int,
        skipBackwardSeconds: Int,
        skipForwardSeconds: Int,
        downloadNetworkPolicy: String,
        automaticDownloadLookahead: Int,
        automaticDownloadCleanupPolicy: String
    ) {
        self.defaultPlaybackRate = defaultPlaybackRate
        self.resumeRewindSeconds = resumeRewindSeconds
        self.skipBackwardSeconds = skipBackwardSeconds
        self.skipForwardSeconds = skipForwardSeconds
        self.downloadNetworkPolicy = downloadNetworkPolicy
        self.automaticDownloadLookahead = automaticDownloadLookahead
        self.automaticDownloadCleanupPolicy =
            automaticDownloadCleanupPolicy
    }
}

public actor CloudConfigurationStore {
    private enum Key {
        static let defaultPlaybackRate =
            "bleat.playback.defaultRate.v1"
        static let resumeRewind =
            "bleat.playback.resumeRewind.v1"
        static let skipBackward =
            "bleat.playback.skipBackward.v1"
        static let skipForward =
            "bleat.playback.skipForward.v1"
        static let downloadNetworkPolicy =
            "bleat.downloads.networkPolicy.v1"
        static let automaticDownloadLookahead =
            "bleat.downloads.automaticLookahead.v1"
        static let automaticDownloadCleanupPolicy =
            "bleat.downloads.automaticCleanupPolicy.v1"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func snapshot() -> CloudConfigurationSnapshot {
        CloudConfigurationSnapshot(
            defaultPlaybackRate: defaults.object(
                forKey: Key.defaultPlaybackRate
            ) == nil ? 1 : defaults.double(
                forKey: Key.defaultPlaybackRate
            ),
            resumeRewindSeconds: defaults.object(
                forKey: Key.resumeRewind
            ) == nil ? 10 : defaults.integer(
                forKey: Key.resumeRewind
            ),
            skipBackwardSeconds: defaults.object(
                forKey: Key.skipBackward
            ) == nil ? 15 : defaults.integer(
                forKey: Key.skipBackward
            ),
            skipForwardSeconds: defaults.object(
                forKey: Key.skipForward
            ) == nil ? 30 : defaults.integer(
                forKey: Key.skipForward
            ),
            downloadNetworkPolicy: defaults.string(
                forKey: Key.downloadNetworkPolicy
            ) ?? "wifiOnly",
            automaticDownloadLookahead: defaults.object(
                forKey: Key.automaticDownloadLookahead
            ) == nil ? 5 : defaults.integer(
                forKey: Key.automaticDownloadLookahead
            ),
            automaticDownloadCleanupPolicy: defaults.string(
                forKey: Key.automaticDownloadCleanupPolicy
            ) ?? "afterTwentyFourHours"
        )
    }

    public func apply(_ snapshot: CloudConfigurationSnapshot) throws {
        guard snapshot.defaultPlaybackRate.isFinite,
            (0.5...3).contains(snapshot.defaultPlaybackRate),
            [0, 5, 10, 15, 30].contains(
                snapshot.resumeRewindSeconds
            ),
            [5, 10, 15, 30, 45, 60].contains(
                snapshot.skipBackwardSeconds
            ),
            [5, 10, 15, 30, 45, 60].contains(
                snapshot.skipForwardSeconds
            ),
            (1...20).contains(snapshot.automaticDownloadLookahead),
            ["wifiOnly", "allowCellular"].contains(
                snapshot.downloadNetworkPolicy
            ),
            [
                "afterBook",
                "afterChapter",
                "afterTwentyFourHours",
            ].contains(snapshot.automaticDownloadCleanupPolicy)
        else {
            throw PrivateCloudSyncError.invalidRecord
        }
        defaults.set(
            snapshot.defaultPlaybackRate,
            forKey: Key.defaultPlaybackRate
        )
        defaults.set(
            snapshot.resumeRewindSeconds,
            forKey: Key.resumeRewind
        )
        defaults.set(
            snapshot.skipBackwardSeconds,
            forKey: Key.skipBackward
        )
        defaults.set(
            snapshot.skipForwardSeconds,
            forKey: Key.skipForward
        )
        defaults.set(
            snapshot.downloadNetworkPolicy,
            forKey: Key.downloadNetworkPolicy
        )
        defaults.set(
            snapshot.automaticDownloadLookahead,
            forKey: Key.automaticDownloadLookahead
        )
        defaults.set(
            snapshot.automaticDownloadCleanupPolicy,
            forKey: Key.automaticDownloadCleanupPolicy
        )
    }
}

private actor PrivateCloudSyncStore {
    static let zoneName = "BleatPrivateData"
    static let payloadKey = "payload"

    private let statistics: StatisticsRepository
    private let accounts: AccountStore
    private let credentialStore: (any AccountCredentialStore)?
    private let configuration: CloudConfigurationStore
    private let defaults = UserDefaults.standard
    private let ignoredAccountsKey =
        "bleat.cloudKit.ignoredAccounts.v1"
    private let ignoredStatisticsKey =
        "bleat.cloudKit.ignoredStatisticsAccounts.v1"
    private var records: [CKRecord.ID: CKRecord] = [:]

    init(
        statistics: StatisticsRepository,
        accounts: AccountStore,
        credentialStore: (any AccountCredentialStore)?,
        configuration: CloudConfigurationStore
    ) {
        self.statistics = statistics
        self.accounts = accounts
        self.credentialStore = credentialStore
        self.configuration = configuration
    }

    func prepareRecords(
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord] {
        let archive: StatisticsArchive
        let accountValues: [ServerAccount]
        do {
            archive = try await statistics.archive()
            accountValues = try await accounts.accounts()
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }

        var prepared: [CKRecord] = []
        for slice in archive.slices {
            prepared.append(
                try record(
                    type: "ListeningSlice",
                    name: "slice.\(slice.id.uuidString.lowercased())",
                    value: slice,
                    zoneID: zoneID
                )
            )
        }
        for completion in archive.completions {
            prepared.append(
                try record(
                    type: "CompletionMilestone",
                    name:
                        "completion."
                        + completion.id.uuidString.lowercased(),
                    value: completion,
                    zoneID: zoneID
                )
            )
        }
        for session in archive.remoteSessions {
            prepared.append(
                try record(
                    type: "RemoteListeningSession",
                    name:
                        "remote.\(session.accountID.rawValue)."
                        + session.id.rawValue,
                    value: session,
                    zoneID: zoneID
                )
            )
        }
        for account in accountValues {
            prepared.append(
                try record(
                    type: "ServerAccount",
                    name: "account.\(account.id.rawValue)",
                    value: account,
                    zoneID: zoneID
                )
            )
        }
        prepared.append(
            try record(
                type: "Configuration",
                name: "configuration.singleton",
                value: await configuration.snapshot(),
                zoneID: zoneID
            )
        )
        for record in prepared {
            records[record.recordID] = record
        }
        return prepared
    }

    func record(for id: CKRecord.ID) -> CKRecord? {
        records[id]
    }

    func apply(
        modifications: [CKDatabase.RecordZoneChange.Modification],
        deletions: [CKDatabase.RecordZoneChange.Deletion]
    ) async throws {
        for modification in modifications {
            let record = modification.record
            records[record.recordID] = record
            try await apply(record)
        }
        for deletion in deletions {
            records.removeValue(forKey: deletion.recordID)
            try await applyDeletion(
                recordID: deletion.recordID,
                recordType: deletion.recordType
            )
        }
    }

    func allRecordIDs() -> [CKRecord.ID] {
        Array(records.keys)
    }

    func removeAllRecords() {
        records.removeAll()
    }

    func ignoreAccountOnThisDevice(
        _ accountID: AccountID,
        includeStatistics: Bool
    ) {
        var ignored = ignoredAccountIDs()
        ignored.insert(accountID.rawValue)
        defaults.set(Array(ignored).sorted(), forKey: ignoredAccountsKey)
        if includeStatistics {
            var ignoredStatistics = ignoredStatisticsAccountIDs()
            ignoredStatistics.insert(accountID.rawValue)
            defaults.set(
                Array(ignoredStatistics).sorted(),
                forKey: ignoredStatisticsKey
            )
        }
    }

    func recordIDs(
        for accountID: AccountID,
        includeStatistics: Bool
    ) -> [CKRecord.ID] {
        records.values.compactMap { record in
            if record.recordType == "ServerAccount" {
                return record.recordID.recordName
                    == "account.\(accountID.rawValue)"
                    ? record.recordID : nil
            }
            guard includeStatistics,
                let data = record[Self.payloadKey] as? Data
            else {
                return nil
            }
            switch record.recordType {
            case "ListeningSlice":
                return (try? JSONDecoder().decode(
                    ListeningSlice.self,
                    from: data
                ).accountID) == accountID ? record.recordID : nil
            case "CompletionMilestone":
                return (try? JSONDecoder().decode(
                    CompletionMilestone.self,
                    from: data
                ).accountID) == accountID ? record.recordID : nil
            case "RemoteListeningSession":
                return (try? JSONDecoder().decode(
                    RemoteListeningSession.self,
                    from: data
                ).accountID) == accountID ? record.recordID : nil
            default:
                return nil
            }
        }
    }

    private func record<Value: Encodable>(
        type: CKRecord.RecordType,
        name: String,
        value: Value,
        zoneID: CKRecordZone.ID
    ) throws -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: name,
            zoneID: zoneID
        )
        let record = records[recordID]
            ?? CKRecord(recordType: type, recordID: recordID)
        do {
            record[Self.payloadKey] =
                try JSONEncoder().encode(value) as CKRecordValue
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        return record
    }

    private func apply(_ record: CKRecord) async throws {
        guard let data = record[Self.payloadKey] as? Data else {
            throw PrivateCloudSyncError.invalidRecord
        }
        do {
            switch record.recordType {
            case "ListeningSlice":
                let value = try JSONDecoder().decode(
                    ListeningSlice.self,
                    from: data
                )
                if !ignoredStatisticsAccountIDs().contains(
                    value.accountID.rawValue
                ) {
                    try await statistics.importArchive(
                        StatisticsArchive(
                            slices: [value],
                            completions: [],
                            remoteSessions: []
                        )
                    )
                }
            case "CompletionMilestone":
                let value = try JSONDecoder().decode(
                    CompletionMilestone.self,
                    from: data
                )
                if !ignoredStatisticsAccountIDs().contains(
                    value.accountID.rawValue
                ) {
                    try await statistics.importArchive(
                        StatisticsArchive(
                            slices: [],
                            completions: [value],
                            remoteSessions: []
                        )
                    )
                }
            case "RemoteListeningSession":
                let value = try JSONDecoder().decode(
                    RemoteListeningSession.self,
                    from: data
                )
                if !ignoredStatisticsAccountIDs().contains(
                    value.accountID.rawValue
                ) {
                    try await statistics.upsertRemoteSessions([value])
                }
            case "ServerAccount":
                let value = try JSONDecoder().decode(
                    ServerAccount.self,
                    from: data
                )
                if !ignoredAccountIDs().contains(value.id.rawValue) {
                    try await accounts.save(value)
                }
            case "Configuration":
                let value = try JSONDecoder().decode(
                    CloudConfigurationSnapshot.self,
                    from: data
                )
                try await configuration.apply(value)
            default:
                return
            }
        } catch let error as PrivateCloudSyncError {
            throw error
        } catch {
            throw PrivateCloudSyncError.invalidRecord
        }
    }

    private func applyDeletion(
        recordID: CKRecord.ID,
        recordType: CKRecord.RecordType
    ) async throws {
        let name = recordID.recordName
        do {
            switch recordType {
            case "ListeningSlice":
                guard let id = UUID(
                    uuidString: name.replacingOccurrences(
                        of: "slice.",
                        with: ""
                    )
                ) else {
                    throw PrivateCloudSyncError.invalidRecord
                }
                try await statistics.deleteSlice(id: id)
            case "CompletionMilestone":
                guard let id = UUID(
                    uuidString: name.replacingOccurrences(
                        of: "completion.",
                        with: ""
                    )
                ) else {
                    throw PrivateCloudSyncError.invalidRecord
                }
                try await statistics.deleteCompletion(id: id)
            case "RemoteListeningSession":
                let components = name.dropFirst("remote.".count).split(
                    separator: ".",
                    maxSplits: 1
                )
                guard components.count == 2 else {
                    throw PrivateCloudSyncError.invalidRecord
                }
                try await statistics.deleteRemoteSession(
                    accountID: AccountID(rawValue: String(components[0])),
                    sessionID: PlaybackSessionID(
                        rawValue: String(components[1])
                    )
                )
            case "ServerAccount":
                let rawID = name.replacingOccurrences(
                    of: "account.",
                    with: ""
                )
                let accountID = AccountID(rawValue: rawID)
                try await credentialStore?.deleteCredentials(for: accountID)
                _ = try await accounts.removeAccount(
                    id: accountID
                )
            default:
                return
            }
        } catch let error as PrivateCloudSyncError {
            throw error
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
    }

    private func ignoredAccountIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: ignoredAccountsKey) ?? [])
    }

    private func ignoredStatisticsAccountIDs() -> Set<String> {
        Set(defaults.stringArray(forKey: ignoredStatisticsKey) ?? [])
    }
}

public final class PrivateCloudSyncCoordinator:
    CKSyncEngineDelegate,
    @unchecked Sendable
{
    public static let containerIdentifier =
        "iCloud.com.terminaloutcomes.Bleat"

    private let store: PrivateCloudSyncStore
    private let defaults: UserDefaults
    private let stateKey = "bleat.cloudKit.syncEngineState.v1"
    private let enabledKey = "bleat.cloudKit.enabled.v1"
    private let zoneID = CKRecordZone.ID(
        zoneName: PrivateCloudSyncStore.zoneName,
        ownerName: CKCurrentUserDefaultName
    )
    private var engine: CKSyncEngine?

    public init(
        statistics: StatisticsRepository,
        accounts: AccountStore,
        credentialStore: (any AccountCredentialStore)? = nil,
        configuration: CloudConfigurationStore =
            CloudConfigurationStore(),
        defaults: UserDefaults = .standard,
        container: CKContainer = CKContainer(
            identifier: PrivateCloudSyncCoordinator.containerIdentifier
        )
    ) {
        store = PrivateCloudSyncStore(
            statistics: statistics,
            accounts: accounts,
            credentialStore: credentialStore,
            configuration: configuration
        )
        self.defaults = defaults
        let serialization = defaults.data(forKey: stateKey).flatMap {
            try? JSONDecoder().decode(
                CKSyncEngine.State.Serialization.self,
                from: $0
            )
        }
        var configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = false
        configuration.subscriptionID = "bleat-private-sync-v1"
        engine = CKSyncEngine(configuration)
    }

    public var isEnabled: Bool {
        defaults.object(forKey: enabledKey) == nil
            ? true
            : defaults.bool(forKey: enabledKey)
    }

    public func synchronize() async throws(PrivateCloudSyncError) {
        guard isEnabled else {
            throw .disabled
        }
        guard let engine else {
            throw .cloudUnavailable
        }
        do {
            engine.state.add(
                pendingDatabaseChanges: [
                    .saveZone(CKRecordZone(zoneID: zoneID))
                ]
            )
            try await engine.sendChanges()
            try await engine.fetchChanges(
                CKSyncEngine.FetchChangesOptions(
                    scope: .zoneIDs([zoneID])
                )
            )
            let records = try await store.prepareRecords(zoneID: zoneID)
            engine.state.add(
                pendingRecordZoneChanges: records.map {
                    .saveRecord($0.recordID)
                }
            )
            try await engine.sendChanges(
                CKSyncEngine.SendChangesOptions(
                    scope: .zoneIDs([zoneID])
                )
            )
        } catch let error as CKError {
            switch error.code {
            case .notAuthenticated, .accountTemporarilyUnavailable:
                throw .accountUnavailable
            default:
                throw .cloudUnavailable
            }
        } catch let error as PrivateCloudSyncError {
            throw error
        } catch {
            throw .cloudUnavailable
        }
    }

    public func setEnabled(
        _ enabled: Bool,
        deleteCloudData: Bool
    ) async throws(PrivateCloudSyncError) {
        guard let engine else {
            throw .cloudUnavailable
        }
        if enabled {
            defaults.set(true, forKey: enabledKey)
            try await synchronize()
            return
        }

        await engine.cancelOperations()
        if deleteCloudData {
            do {
                engine.state.add(
                    pendingDatabaseChanges: [.deleteZone(zoneID)]
                )
                try await engine.sendChanges()
                await store.removeAllRecords()
                defaults.removeObject(forKey: stateKey)
            } catch {
                throw .cloudUnavailable
            }
        }
        defaults.set(false, forKey: enabledKey)
    }

    public func deleteAccountEverywhere(
        _ accountID: AccountID,
        includeStatistics: Bool
    ) async throws(PrivateCloudSyncError) {
        guard isEnabled else {
            throw .disabled
        }
        guard let engine else {
            throw .cloudUnavailable
        }
        do {
            _ = try await store.prepareRecords(zoneID: zoneID)
            let recordIDs = await store.recordIDs(
                for: accountID,
                includeStatistics: includeStatistics
            )
            engine.state.add(
                pendingRecordZoneChanges: recordIDs.map {
                    .deleteRecord($0)
                }
            )
            try await engine.sendChanges(
                CKSyncEngine.SendChangesOptions(
                    scope: .recordIDs(recordIDs)
                )
            )
        } catch {
            throw .cloudUnavailable
        }
    }

    public func ignoreAccountOnThisDevice(
        _ accountID: AccountID,
        includeStatistics: Bool
    ) async {
        await store.ignoreAccountOnThisDevice(
            accountID,
            includeStatistics: includeStatistics
        )
    }

    public func handleEvent(
        _ event: CKSyncEngine.Event,
        syncEngine: CKSyncEngine
    ) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(
                update.stateSerialization
            ) {
                defaults.set(data, forKey: stateKey)
            }
        case .fetchedRecordZoneChanges(let changes):
            try? await store.apply(
                modifications: changes.modifications,
                deletions: changes.deletions
            )
        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges:
                syncEngine.state.pendingRecordZoneChanges.filter {
                    context.options.scope.contains($0)
                },
            recordProvider: { [store] recordID in
                await store.record(for: recordID)
            }
        )
    }
}
