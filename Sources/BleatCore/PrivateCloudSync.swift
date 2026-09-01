import CloudKit
import CryptoKit
import Foundation

public enum PrivateCloudSyncStatus: Equatable, Sendable {
    case disabled
    case idle
    case syncing
    case unavailable
    case failed
}

public enum PrivateCloudSyncOperation: String, Codable, Equatable, Sendable {
    case synchronize
    case setupZone = "setup_zone"
    case fetchChanges = "fetch_changes"
    case prepareLocalChanges = "prepare_local_changes"
    case uploadChanges = "upload_changes"
    case pushServerConfiguration = "push_server_configuration"
    case resolveServerConfiguration = "resolve_server_configuration"
    case enable
    case disable
    case cancel
    case deleteCloudData = "delete_cloud_data"
    case deleteAccount = "delete_account"
    case persistEngineState = "persist_engine_state"
    case applyFetchedChanges = "apply_fetched_changes"
    case reconcileSentChanges = "reconcile_sent_changes"
    case keepLocalConfiguration = "keep_local_configuration"
    case acceptCloudConfiguration = "accept_cloud_configuration"
}

public enum CloudKitFailureCode: Hashable, Sendable {
    case internalError
    case partialFailure
    case networkUnavailable
    case networkFailure
    case badContainer
    case serviceUnavailable
    case requestRateLimited
    case missingEntitlement
    case notAuthenticated
    case permissionFailure
    case unknownItem
    case invalidArguments
    case resultsTruncated
    case serverRecordChanged
    case serverRejectedRequest
    case assetFileNotFound
    case assetFileModified
    case incompatibleVersion
    case constraintViolation
    case operationCancelled
    case changeTokenExpired
    case batchRequestFailed
    case zoneBusy
    case badDatabase
    case quotaExceeded
    case zoneNotFound
    case limitExceeded
    case userDeletedZone
    case tooManyParticipants
    case alreadyShared
    case referenceViolation
    case managedAccountRestricted
    case participantMayNeedVerification
    case serverResponseLost
    case assetNotAvailable
    case accountTemporarilyUnavailable
    case participantAlreadyInvited
    case unknown(Int)

    public init(_ code: CKError.Code) {
        self =
            switch code {
            case .internalError: .internalError
            case .partialFailure: .partialFailure
            case .networkUnavailable: .networkUnavailable
            case .networkFailure: .networkFailure
            case .badContainer: .badContainer
            case .serviceUnavailable: .serviceUnavailable
            case .requestRateLimited: .requestRateLimited
            case .missingEntitlement: .missingEntitlement
            case .notAuthenticated: .notAuthenticated
            case .permissionFailure: .permissionFailure
            case .unknownItem: .unknownItem
            case .invalidArguments: .invalidArguments
            case .resultsTruncated: .resultsTruncated
            case .serverRecordChanged: .serverRecordChanged
            case .serverRejectedRequest: .serverRejectedRequest
            case .assetFileNotFound: .assetFileNotFound
            case .assetFileModified: .assetFileModified
            case .incompatibleVersion: .incompatibleVersion
            case .constraintViolation: .constraintViolation
            case .operationCancelled: .operationCancelled
            case .changeTokenExpired: .changeTokenExpired
            case .batchRequestFailed: .batchRequestFailed
            case .zoneBusy: .zoneBusy
            case .badDatabase: .badDatabase
            case .quotaExceeded: .quotaExceeded
            case .zoneNotFound: .zoneNotFound
            case .limitExceeded: .limitExceeded
            case .userDeletedZone: .userDeletedZone
            case .tooManyParticipants: .tooManyParticipants
            case .alreadyShared: .alreadyShared
            case .referenceViolation: .referenceViolation
            case .managedAccountRestricted: .managedAccountRestricted
            case .participantMayNeedVerification:
                .participantMayNeedVerification
            case .serverResponseLost: .serverResponseLost
            case .assetNotAvailable: .assetNotAvailable
            case .accountTemporarilyUnavailable:
                .accountTemporarilyUnavailable
            case .participantAlreadyInvited: .participantAlreadyInvited
            @unknown default: .unknown(code.rawValue)
            }
    }

    public var diagnosticCode: String {
        switch self {
        case .internalError: "internal_error"
        case .partialFailure: "partial_failure"
        case .networkUnavailable: "network_unavailable"
        case .networkFailure: "network_failure"
        case .badContainer: "bad_container"
        case .serviceUnavailable: "service_unavailable"
        case .requestRateLimited: "request_rate_limited"
        case .missingEntitlement: "missing_entitlement"
        case .notAuthenticated: "not_authenticated"
        case .permissionFailure: "permission_failure"
        case .unknownItem: "unknown_item"
        case .invalidArguments: "invalid_arguments"
        case .resultsTruncated: "results_truncated"
        case .serverRecordChanged: "server_record_changed"
        case .serverRejectedRequest: "server_rejected_request"
        case .assetFileNotFound: "asset_file_not_found"
        case .assetFileModified: "asset_file_modified"
        case .incompatibleVersion: "incompatible_version"
        case .constraintViolation: "constraint_violation"
        case .operationCancelled: "operation_cancelled"
        case .changeTokenExpired: "change_token_expired"
        case .batchRequestFailed: "batch_request_failed"
        case .zoneBusy: "zone_busy"
        case .badDatabase: "bad_database"
        case .quotaExceeded: "quota_exceeded"
        case .zoneNotFound: "zone_not_found"
        case .limitExceeded: "limit_exceeded"
        case .userDeletedZone: "user_deleted_zone"
        case .tooManyParticipants: "too_many_participants"
        case .alreadyShared: "already_shared"
        case .referenceViolation: "reference_violation"
        case .managedAccountRestricted: "managed_account_restricted"
        case .participantMayNeedVerification:
            "participant_may_need_verification"
        case .serverResponseLost: "server_response_lost"
        case .assetNotAvailable: "asset_not_available"
        case .accountTemporarilyUnavailable:
            "account_temporarily_unavailable"
        case .participantAlreadyInvited: "participant_already_invited"
        case .unknown(let rawValue): "unknown_\(rawValue)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .networkFailure, .serviceUnavailable,
            .requestRateLimited, .zoneBusy, .serverResponseLost,
            .accountTemporarilyUnavailable:
            true
        case .partialFailure, .batchRequestFailed:
            true
        default:
            false
        }
    }
}

public struct CloudKitFailure: Equatable, Sendable {
    public let code: CloudKitFailureCode
    public let partialFailureCodes: [CloudKitFailureCode]
    public let retryAfterSeconds: Double?

    public init(_ error: CKError) {
        code = CloudKitFailureCode(error.code)
        let partialCodes =
            error.partialErrorsByItemID?.values.compactMap {
                ($0 as? CKError).map { CloudKitFailureCode($0.code) }
            } ?? []
        partialFailureCodes = Array(Set(partialCodes)).sorted {
            $0.diagnosticCode < $1.diagnosticCode
        }
        if let retryAfter = error.retryAfterSeconds,
            retryAfter.isFinite, retryAfter >= 0
        {
            retryAfterSeconds = retryAfter
        } else {
            retryAfterSeconds = nil
        }
    }

    public var isRetryable: Bool {
        code.isRetryable || partialFailureCodes.contains(where: \.isRetryable)
    }

    var canRetryAfterConflictReconciliation: Bool {
        code == .partialFailure
            && !partialFailureCodes.isEmpty
            && partialFailureCodes.allSatisfy {
                $0 == .serverRecordChanged || $0 == .batchRequestFailed
            }
    }

    func sendRecovery(
        hasPendingConfigurationConflict: Bool,
        attempt: Int
    ) -> PrivateCloudSendRecovery {
        guard canRetryAfterConflictReconciliation else {
            return .fail
        }
        if hasPendingConfigurationConflict {
            return .awaitUserResolution
        }
        return attempt == 0 ? .retry : .fail
    }
}

enum PrivateCloudSendRecovery: Equatable, Sendable {
    case awaitUserResolution
    case retry
    case fail
}

public struct PrivateCloudSystemError: Equatable, Sendable {
    public let domain: String
    public let code: Int

    init(_ error: any Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
    }
}

public enum PrivateCloudSyncError: Error, Equatable, Sendable {
    case disabled
    case cancelled
    case invalidRecord
    case persistenceFailed
    case nonPrivateDatabase
    case engineUnavailable
    case cloudKit(CloudKitFailure)
    case unexpected(PrivateCloudSystemError)

    public var isRetryable: Bool {
        switch self {
        case .cloudKit(let failure): failure.isRetryable
        case .cancelled, .persistenceFailed, .engineUnavailable: true
        case .disabled, .invalidRecord, .nonPrivateDatabase, .unexpected:
            false
        }
    }
}

final class PrivateCloudDefaultsReference: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

public struct PrivateCloudSyncFailure: Error, Equatable, Sendable {
    public let operation: PrivateCloudSyncOperation
    public let cause: PrivateCloudSyncError

    public init(
        operation: PrivateCloudSyncOperation,
        cause: PrivateCloudSyncError
    ) {
        self.operation = operation
        self.cause = cause
    }
}

public enum PrivateCloudSyncEventPhase: Equatable, Sendable {
    case started
    case completed
    case failed(PrivateCloudSyncFailure)
}

public struct PrivateCloudSyncEvent: Equatable, Sendable {
    public let correlationID: UUID
    public let timestamp: Date
    public let operation: PrivateCloudSyncOperation
    public let phase: PrivateCloudSyncEventPhase
    public let durationMilliseconds: Int?
    public let recordCount: Int?

    public init(
        correlationID: UUID,
        timestamp: Date = Date(),
        operation: PrivateCloudSyncOperation,
        phase: PrivateCloudSyncEventPhase,
        durationMilliseconds: Int? = nil,
        recordCount: Int? = nil
    ) {
        self.correlationID = correlationID
        self.timestamp = timestamp
        self.operation = operation
        self.phase = phase
        self.durationMilliseconds = durationMilliseconds
        self.recordCount = recordCount
    }
}

public protocol PrivateCloudSyncEventRecording: Sendable {
    func record(_ event: PrivateCloudSyncEvent) async
}

public struct DisabledPrivateCloudSyncEventRecorder:
    PrivateCloudSyncEventRecording
{
    public init() {}

    public func record(_ event: PrivateCloudSyncEvent) async {}
}

public actor CompositePrivateCloudSyncEventRecorder:
    PrivateCloudSyncEventRecording
{
    private let recorders: [any PrivateCloudSyncEventRecording]

    public init(_ recorders: [any PrivateCloudSyncEventRecording]) {
        self.recorders = recorders
    }

    public func record(_ event: PrivateCloudSyncEvent) async {
        for recorder in recorders {
            await recorder.record(event)
        }
    }
}

public struct DiagnosticPrivateCloudSyncEventRecorder:
    PrivateCloudSyncEventRecording
{
    private let diagnostics: any DiagnosticRecording

    public init(diagnostics: any DiagnosticRecording) {
        self.diagnostics = diagnostics
    }

    public func record(_ event: PrivateCloudSyncEvent) async {
        let diagnostic: DiagnosticEvent
        switch event.phase {
        case .started:
            diagnostic = .privateCloudStarted(
                operation: event.operation,
                correlationID: event.correlationID
            )
        case .completed:
            diagnostic = .privateCloudCompleted(
                operation: event.operation,
                correlationID: event.correlationID,
                durationMilliseconds: event.durationMilliseconds ?? 0,
                recordCount: event.recordCount
            )
        case .failed(let failure):
            diagnostic = .privateCloudFailed(
                failure: failure,
                correlationID: event.correlationID,
                durationMilliseconds: event.durationMilliseconds ?? 0,
                recordCount: event.recordCount
            )
        }
        await diagnostics.record(diagnostic)
    }
}

public struct CloudServerConfigurationChange:
    Codable, Equatable, Identifiable, Sendable
{
    public let current: ServerAccount?
    public let incoming: ServerAccount

    public var id: AccountID {
        incoming.id
    }

    var structuralKey: String {
        [
            incoming.id.rawValue,
            incoming.server.url.absoluteString,
            incoming.localServer?.url.absoluteString ?? "",
            incoming.user.id.rawValue,
            incoming.user.username,
        ].map { "\($0.utf8.count):\($0)" }.joined()
    }

    public init(current: ServerAccount?, incoming: ServerAccount) {
        self.current = current
        self.incoming = incoming
    }
}

public struct CloudConfigurationConflict:
    Codable, Equatable, Identifiable, Sendable
{
    public let local: CloudConfigurationSnapshot
    public let iCloud: CloudConfigurationSnapshot

    public var id: String { "configuration.singleton" }

    public init(
        local: CloudConfigurationSnapshot,
        iCloud: CloudConfigurationSnapshot
    ) {
        self.local = local
        self.iCloud = iCloud
    }
}

public enum CloudConfigurationConflictResolution: Equatable, Sendable {
    case keepThisDevice
    case useICloud
}

struct CloudServerAccountRecordPayload: Codable, Equatable {
    static let currentSchemaVersion = 2
    static let supportedSchemaVersions = 1...currentSchemaVersion

    let schemaVersion: Int
    let generationID: UUID
    let supersededGenerationID: UUID?
    let supersededPayloadDigest: Data?
    let account: ServerAccount
    let legacyAccountIDs: [AccountID]

    init(
        generationID: UUID = UUID(),
        supersededGenerationID: UUID? = nil,
        supersededPayloadDigest: Data?,
        account: ServerAccount,
        legacyAccountIDs: [AccountID] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generationID = generationID
        self.supersededGenerationID = supersededGenerationID
        self.supersededPayloadDigest = supersededPayloadDigest
        self.account = account
        self.legacyAccountIDs = legacyAccountIDs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generationID
        case supersededGenerationID
        case supersededPayloadDigest
        case account
        case legacyAccountIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        generationID = try values.decode(UUID.self, forKey: .generationID)
        supersededGenerationID = try values.decodeIfPresent(
            UUID.self,
            forKey: .supersededGenerationID
        )
        supersededPayloadDigest = try values.decodeIfPresent(
            Data.self,
            forKey: .supersededPayloadDigest
        )
        account = try values.decode(ServerAccount.self, forKey: .account)
        legacyAccountIDs =
            try values.decodeIfPresent(
                [AccountID].self,
                forKey: .legacyAccountIDs
            ) ?? []
    }
}

public enum HeadphoneCommandAction:
    String, Codable, CaseIterable, Identifiable, Sendable
{
    case skipBackward
    case skipForward
    case previousChapter
    case nextChapter

    public var id: String {
        rawValue
    }
}

public struct CloudConfigurationSnapshot:
    Codable, Equatable, Sendable
{
    public let defaultPlaybackRate: Double
    public let resumeRewindSeconds: Int
    public let skipBackwardSeconds: Int
    public let skipForwardSeconds: Int
    public let previousCommandAction: HeadphoneCommandAction
    public let nextCommandAction: HeadphoneCommandAction
    public let downloadNetworkPolicy: String
    public let maximumConcurrentDownloads: Int
    public let automaticDownloadLookahead: Int
    public let automaticDownloadCleanupPolicy: String

    public init(
        defaultPlaybackRate: Double,
        resumeRewindSeconds: Int,
        skipBackwardSeconds: Int,
        skipForwardSeconds: Int,
        previousCommandAction: HeadphoneCommandAction,
        nextCommandAction: HeadphoneCommandAction,
        downloadNetworkPolicy: String,
        maximumConcurrentDownloads: Int,
        automaticDownloadLookahead: Int,
        automaticDownloadCleanupPolicy: String
    ) {
        self.defaultPlaybackRate = defaultPlaybackRate
        self.resumeRewindSeconds = resumeRewindSeconds
        self.skipBackwardSeconds = skipBackwardSeconds
        self.skipForwardSeconds = skipForwardSeconds
        self.previousCommandAction = previousCommandAction
        self.nextCommandAction = nextCommandAction
        self.downloadNetworkPolicy = downloadNetworkPolicy
        self.maximumConcurrentDownloads =
            MaximumConcurrentDownloadsPreference.normalize(
                maximumConcurrentDownloads
            )
        self.automaticDownloadLookahead = automaticDownloadLookahead
        self.automaticDownloadCleanupPolicy =
            automaticDownloadCleanupPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case defaultPlaybackRate
        case resumeRewindSeconds
        case skipBackwardSeconds
        case skipForwardSeconds
        case previousCommandAction
        case nextCommandAction
        case downloadNetworkPolicy
        case maximumConcurrentDownloads
        case automaticDownloadLookahead
        case automaticDownloadCleanupPolicy
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultPlaybackRate = try container.decode(
            Double.self,
            forKey: .defaultPlaybackRate
        )
        resumeRewindSeconds = try container.decode(
            Int.self,
            forKey: .resumeRewindSeconds
        )
        skipBackwardSeconds = try container.decode(
            Int.self,
            forKey: .skipBackwardSeconds
        )
        skipForwardSeconds = try container.decode(
            Int.self,
            forKey: .skipForwardSeconds
        )
        previousCommandAction =
            try container.decodeIfPresent(
                HeadphoneCommandAction.self,
                forKey: .previousCommandAction
            ) ?? .skipBackward
        nextCommandAction =
            try container.decodeIfPresent(
                HeadphoneCommandAction.self,
                forKey: .nextCommandAction
            ) ?? .skipForward
        downloadNetworkPolicy = try container.decode(
            String.self,
            forKey: .downloadNetworkPolicy
        )
        maximumConcurrentDownloads =
            MaximumConcurrentDownloadsPreference.normalize(
                try container.decodeIfPresent(
                    Int.self,
                    forKey: .maximumConcurrentDownloads
                ) ?? MaximumConcurrentDownloadsPreference.defaultValue
            )
        automaticDownloadLookahead = try container.decode(
            Int.self,
            forKey: .automaticDownloadLookahead
        )
        automaticDownloadCleanupPolicy = try container.decode(
            String.self,
            forKey: .automaticDownloadCleanupPolicy
        )
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
        static let previousCommandAction =
            "bleat.playback.previousCommandAction.v1"
        static let nextCommandAction =
            "bleat.playback.nextCommandAction.v1"
        static let downloadNetworkPolicy =
            "bleat.downloads.networkPolicy.v1"
        static let maximumConcurrentDownloads =
            MaximumConcurrentDownloadsPreference.defaultsKey
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
            ) == nil
                ? 1
                : defaults.double(
                    forKey: Key.defaultPlaybackRate
                ),
            resumeRewindSeconds: defaults.object(
                forKey: Key.resumeRewind
            ) == nil
                ? 10
                : defaults.integer(
                    forKey: Key.resumeRewind
                ),
            skipBackwardSeconds: defaults.object(
                forKey: Key.skipBackward
            ) == nil
                ? 15
                : defaults.integer(
                    forKey: Key.skipBackward
                ),
            skipForwardSeconds: defaults.object(
                forKey: Key.skipForward
            ) == nil
                ? 30
                : defaults.integer(
                    forKey: Key.skipForward
                ),
            previousCommandAction: defaults.string(
                forKey: Key.previousCommandAction
            ).flatMap(HeadphoneCommandAction.init(rawValue:))
                ?? .skipBackward,
            nextCommandAction: defaults.string(
                forKey: Key.nextCommandAction
            ).flatMap(HeadphoneCommandAction.init(rawValue:))
                ?? .skipForward,
            downloadNetworkPolicy: defaults.string(
                forKey: Key.downloadNetworkPolicy
            ) ?? "wifiOnly",
            maximumConcurrentDownloads:
                MaximumConcurrentDownloadsPreference.load(
                    from: defaults
                ).value,
            automaticDownloadLookahead: defaults.object(
                forKey: Key.automaticDownloadLookahead
            ) == nil
                ? 5
                : defaults.integer(
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
            snapshot.previousCommandAction.rawValue,
            forKey: Key.previousCommandAction
        )
        defaults.set(
            snapshot.nextCommandAction.rawValue,
            forKey: Key.nextCommandAction
        )
        defaults.set(
            snapshot.downloadNetworkPolicy,
            forKey: Key.downloadNetworkPolicy
        )
        defaults.set(
            MaximumConcurrentDownloadsPreference.normalize(
                snapshot.maximumConcurrentDownloads
            ),
            forKey: Key.maximumConcurrentDownloads
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

actor PrivateCloudSyncStore {
    static let zoneName = "BleatPrivateData"
    static let payloadKey = "payload"

    private let statistics: StatisticsRepository
    private let accounts: AccountStore
    private let credentialStore: (any AccountCredentialStore)?
    private let configuration: CloudConfigurationStore
    private let defaults: UserDefaults
    private let recordSystemFieldsKey =
        "bleat.cloudKit.recordSystemFields.v1"
    private let synchronizedPayloadDigestsKey =
        "bleat.cloudKit.synchronizedPayloadDigests.v1"
    private let retainedRecordPayloadsKey =
        "bleat.cloudKit.retainedRecordPayloads.v1"
    private let ignoredAccountsKey =
        "bleat.cloudKit.ignoredAccounts.v1"
    private let ignoredStatisticsKey =
        "bleat.cloudKit.ignoredStatisticsAccounts.v1"
    private let pendingConfigurationConflictKey =
        "bleat.cloudKit.pendingConfigurationConflict.v1"
    private let pendingAccountChangesKey =
        "bleat.cloudKit.pendingAccountChanges.v1"
    private let legacyAccountIdentityMappingsKey =
        "bleat.cloudKit.legacyAccountIdentityMappings.v1"
    private let pendingLegacyRecordDeletionsKey =
        "bleat.cloudKit.pendingLegacyRecordDeletions.v1"
    private var records: [CKRecord.ID: CKRecord] = [:]
    private var synchronizedPayloadDigests: [String: Data] = [:]
    private var pendingAccountChanges:
        [AccountID: [CloudServerConfigurationChange]] = [:]
    private var pendingConfigurationConflict: CloudConfigurationConflict?
    private var pendingConfigurationConflictRevision: UUID?
    private var pendingConfigurationConflictIsInvalid = false
    private var legacyAccountIdentityMappings: [String: String] = [:]
    private var pendingLegacyRecordDeletions: [String: Set<String>] = [:]

    private enum IncomingRecordResolution {
        case applyRemote
        case preserveLocal(Data)
        case requestAccountConfirmation(CloudServerConfigurationChange)
        case requestConfigurationConfirmation(CloudConfigurationConflict)
    }

    private struct CanonicalizedCloudRecord {
        let record: CKRecord
        let legacyRecordID: CKRecord.ID?
        let requiresUpload: Bool
    }

    init(
        statistics: StatisticsRepository,
        accounts: AccountStore,
        credentialStore: (any AccountCredentialStore)?,
        configuration: CloudConfigurationStore,
        defaults: PrivateCloudDefaultsReference = PrivateCloudDefaultsReference(
            .standard
        )
    ) {
        self.statistics = statistics
        self.accounts = accounts
        self.credentialStore = credentialStore
        self.configuration = configuration
        self.defaults = defaults.value
        if let archivedRecords = defaults.value.dictionary(
            forKey: recordSystemFieldsKey
        ) as? [String: Data] {
            for data in archivedRecords.values {
                guard let record = Self.decodeSystemFields(data) else {
                    continue
                }
                records[record.recordID] = record
            }
        }
        synchronizedPayloadDigests =
            defaults.value.dictionary(
                forKey: synchronizedPayloadDigestsKey
            ) as? [String: Data] ?? [:]
        legacyAccountIdentityMappings =
            defaults.value.dictionary(
                forKey: legacyAccountIdentityMappingsKey
            ) as? [String: String] ?? [:]
        pendingLegacyRecordDeletions =
            (defaults.value.dictionary(
                forKey: pendingLegacyRecordDeletionsKey
            ) as? [String: [String]] ?? [:]).mapValues(Set.init)
        if let retainedPayloads = defaults.value.dictionary(
            forKey: retainedRecordPayloadsKey
        ) as? [String: Data] {
            for (recordName, payload) in retainedPayloads {
                guard
                    let record = records.first(where: {
                        $0.key.recordName == recordName
                    })?.value
                else {
                    continue
                }
                record[Self.payloadKey] = payload as CKRecordValue
            }
        }
        if let data = defaults.value.data(
            forKey: pendingConfigurationConflictKey
        ) {
            guard
                let conflict = try? JSONDecoder().decode(
                    CloudConfigurationConflict.self,
                    from: data
                )
            else {
                pendingConfigurationConflictIsInvalid = true
                return
            }
            pendingConfigurationConflict = conflict
            pendingConfigurationConflictRevision = UUID()
            if let record = records.first(where: {
                $0.key.recordName == "configuration.singleton"
                    && $0.value.recordType == "Configuration"
            })?.value,
                let payload = try? JSONEncoder().encode(conflict.iCloud)
            {
                record[Self.payloadKey] = payload as CKRecordValue
            }
        }
        if let data = defaults.value.data(forKey: pendingAccountChangesKey),
            let changes = try? JSONDecoder().decode(
                [CloudServerConfigurationChange].self,
                from: data
            )
        {
            pendingAccountChanges = Dictionary(grouping: changes, by: \.id)
                .mapValues { candidates in
                    candidates.sorted { $0.structuralKey < $1.structuralKey }
                }
        }
    }

    func prepareRecords(
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord] {
        guard !pendingConfigurationConflictIsInvalid else {
            throw PrivateCloudSyncError.invalidRecord
        }
        try await seedLegacyAccountMappingsFromAliases()
        let archive: StatisticsArchive
        let accountValues: [ServerAccount]
        do {
            archive = try await statistics.privateCloudArchive()
            accountValues = try await accounts.accounts()
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }

        var localRecords: [CKRecord] = []
        for slice in archive.slices {
            localRecords.append(
                try record(
                    type: "ListeningSlice",
                    name: "slice.\(slice.id.uuidString.lowercased())",
                    value: slice,
                    zoneID: zoneID
                )
            )
        }
        for completion in archive.completions {
            localRecords.append(
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
            localRecords.append(
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
            guard pendingAccountChanges[account.id] == nil else {
                continue
            }
            localRecords.append(
                try accountRecord(
                    account,
                    zoneID: zoneID,
                    forceNewGeneration: false
                )
            )
        }
        if pendingConfigurationConflict == nil {
            localRecords.append(
                try record(
                    type: "Configuration",
                    name: "configuration.singleton",
                    value: await configuration.snapshot(),
                    zoneID: zoneID
                )
            )
        }
        for record in localRecords {
            records[record.recordID] = record
        }
        return localRecords.filter(needsUpload)
    }

    func record(for id: CKRecord.ID) -> CKRecord? {
        records[id]
    }

    func prepareDeletionChanges(
        zoneID: CKRecordZone.ID
    ) async throws -> [CKSyncEngine.PendingRecordZoneChange] {
        do {
            var changes: [CKSyncEngine.PendingRecordZoneChange] =
                try await statistics.privateCloudDeletions().map {
                    CKSyncEngine.PendingRecordZoneChange.deleteRecord(
                        CKRecord.ID(
                            recordName: $0.recordName,
                            zoneID: zoneID
                        )
                    )
                }
            for (canonicalName, legacyNames) in pendingLegacyRecordDeletions {
                guard
                    let canonicalRecord = records.first(where: {
                        $0.key.recordName == canonicalName
                    })?.value,
                    !needsUpload(canonicalRecord)
                else {
                    continue
                }
                changes.append(
                    contentsOf: legacyNames.map {
                        CKSyncEngine.PendingRecordZoneChange.deleteRecord(
                            CKRecord.ID(recordName: $0, zoneID: zoneID)
                        )
                    }
                )
            }
            return changes
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
    }

    func apply(
        modifications: [CKDatabase.RecordZoneChange.Modification],
        deletions: [CKDatabase.RecordZoneChange.Deletion]
    ) async throws -> [CKSyncEngine.PendingRecordZoneChange] {
        let fetchedResult = try await applyFetchedRecordsToleratingFailures(
            modifications.map(\.record),
            persistState: false
        )
        for deletion in deletions {
            records.removeValue(forKey: deletion.recordID)
            synchronizedPayloadDigests[deletion.recordID.recordName] = nil
            try await applyDeletion(
                recordID: deletion.recordID,
                recordType: deletion.recordType
            )
        }
        do {
            try await statistics.clearPrivateCloudDeletions(
                recordNames: Set(deletions.map { $0.recordID.recordName })
            )
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        persistRecordState()
        if let failure = fetchedResult.failure {
            throw failure
        }
        return fetchedResult.pendingChanges
    }

    func applyFetchedRecords(
        _ fetchedRecords: [CKRecord],
        persistState: Bool = true
    ) async throws -> [CKSyncEngine.PendingRecordZoneChange] {
        let result = try await applyFetchedRecordsToleratingFailures(
            fetchedRecords,
            persistState: persistState
        )
        if let failure = result.failure {
            throw failure
        }
        return result.pendingChanges
    }

    private func applyFetchedRecordsToleratingFailures(
        _ fetchedRecords: [CKRecord],
        persistState: Bool
    ) async throws -> (
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        failure: PrivateCloudSyncError?
    ) {
        var recordsToApply: [CKRecord] = []
        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        try await seedLegacyAccountMappingsFromAliases()
        learnLegacyAccountMappings(from: fetchedRecords)
        let pendingDeletionNames: Set<String>
        do {
            pendingDeletionNames = Set(
                try await statistics.privateCloudDeletions().map(\.recordName)
            )
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        var firstFailure: PrivateCloudSyncError?
        for fetchedRecord in fetchedRecords {
            let canonicalization: CanonicalizedCloudRecord
            do {
                canonicalization = try canonicalizedCloudRecord(fetchedRecord)
            } catch let error as PrivateCloudSyncError {
                if firstFailure == nil {
                    firstFailure = error
                }
                continue
            } catch {
                if firstFailure == nil {
                    firstFailure = .invalidRecord
                }
                continue
            }
            let record = canonicalization.record
            guard !pendingDeletionNames.contains(record.recordID.recordName)
            else {
                continue
            }
            do {
                let resolution = try await resolveIncomingRecord(
                    record,
                    previousRecord: records[record.recordID]
                )
                switch resolution {
                case .applyRemote:
                    recordsToApply.append(record)
                    if canonicalization.requiresUpload {
                        records[record.recordID] = record
                        pendingChanges.append(.saveRecord(record.recordID))
                        registerLegacyRecordDeletion(
                            canonicalization.legacyRecordID,
                            afterSaving: record.recordID
                        )
                    }
                case .preserveLocal(let data):
                    record[Self.payloadKey] = data as CKRecordValue
                    records[record.recordID] = record
                    pendingChanges.append(.saveRecord(record.recordID))
                case .requestAccountConfirmation(let change):
                    if canonicalization.legacyRecordID != nil,
                        let current = change.current
                    {
                        let localRecord = try accountRecord(
                            current,
                            zoneID: record.recordID.zoneID,
                            forceNewGeneration: false
                        )
                        records[localRecord.recordID] = localRecord
                        pendingChanges.append(
                            .saveRecord(localRecord.recordID)
                        )
                        registerLegacyRecordDeletion(
                            canonicalization.legacyRecordID,
                            afterSaving: localRecord.recordID
                        )
                        continue
                    }
                    records[fetchedRecord.recordID] = fetchedRecord
                    appendPendingAccountChange(change)
                    registerLegacyRecordDeletion(
                        canonicalization.legacyRecordID,
                        afterSaving: record.recordID
                    )
                    markSynchronized(fetchedRecord)
                case .requestConfigurationConfirmation(let conflict):
                    records[record.recordID] = record
                    try setPendingConfigurationConflict(conflict)
                    markSynchronized(record)
                }
            } catch let error as PrivateCloudSyncError {
                if firstFailure == nil {
                    firstFailure = error
                }
            } catch {
                if firstFailure == nil {
                    firstFailure = .invalidRecord
                }
            }
        }
        let application = try await apply(recordsToApply)
        if firstFailure == nil {
            firstFailure = application.failure
        }
        for record in application.appliedRecords {
            records[record.recordID] = record
            if !pendingChanges.contains(where: {
                if case .saveRecord(let recordID) = $0 {
                    return recordID == record.recordID
                }
                return false
            }) {
                markSynchronized(record)
            }
        }
        if persistState {
            persistRecordState()
        }
        return (pendingChanges, firstFailure)
    }

    @discardableResult
    func applyFetchedRecord(
        _ record: CKRecord,
        persistSystemFields: Bool = true
    ) async throws -> Bool {
        learnLegacyAccountMappings(from: [record])
        let canonicalization = try canonicalizedCloudRecord(record)
        let incomingRecord = canonicalization.record
        let resolution = try await resolveIncomingRecord(
            incomingRecord,
            previousRecord: records[incomingRecord.recordID]
        )
        switch resolution {
        case .applyRemote:
            records[incomingRecord.recordID] = incomingRecord
            try await apply(incomingRecord)
            if canonicalization.requiresUpload {
                registerLegacyRecordDeletion(
                    canonicalization.legacyRecordID,
                    afterSaving: incomingRecord.recordID
                )
            } else {
                markSynchronized(incomingRecord)
            }
            if persistSystemFields {
                persistRecordState()
            }
            return canonicalization.requiresUpload
        case .preserveLocal(let data):
            incomingRecord[Self.payloadKey] = data as CKRecordValue
            records[incomingRecord.recordID] = incomingRecord
            if persistSystemFields {
                persistRecordState()
            }
            return true
        case .requestAccountConfirmation(let change):
            if canonicalization.legacyRecordID != nil,
                let current = change.current
            {
                let localRecord = try accountRecord(
                    current,
                    zoneID: incomingRecord.recordID.zoneID,
                    forceNewGeneration: false
                )
                records[localRecord.recordID] = localRecord
                registerLegacyRecordDeletion(
                    canonicalization.legacyRecordID,
                    afterSaving: localRecord.recordID
                )
                if persistSystemFields {
                    persistRecordState()
                }
                return true
            }
            records[record.recordID] = record
            appendPendingAccountChange(change)
            registerLegacyRecordDeletion(
                canonicalization.legacyRecordID,
                afterSaving: incomingRecord.recordID
            )
            markSynchronized(record)
            if persistSystemFields {
                persistRecordState()
            }
            return false
        case .requestConfigurationConfirmation(let conflict):
            records[record.recordID] = record
            try setPendingConfigurationConflict(conflict)
            markSynchronized(record)
            if persistSystemFields {
                persistRecordState()
            }
            return false
        }
    }

    func reconcileSentRecordZoneChanges(
        savedRecords: [CKRecord],
        deletedRecordIDs: [CKRecord.ID],
        failedRecordSaves: [(record: CKRecord, error: CKError)],
        failedRecordDeletes: [CKRecord.ID: CKError]
    ) async throws -> [CKSyncEngine.PendingRecordZoneChange] {
        for record in savedRecords {
            records[record.recordID] = record
            markSynchronized(record)
        }
        let savedStatistics = try statisticsArchive(from: savedRecords)
        if !savedStatistics.slices.isEmpty
            || !savedStatistics.completions.isEmpty
            || !savedStatistics.remoteSessions.isEmpty
        {
            do {
                try await statistics.markPrivateCloudArchiveSynchronized(
                    savedStatistics
                )
            } catch {
                throw PrivateCloudSyncError.persistenceFailed
            }
        }
        for recordID in deletedRecordIDs {
            records.removeValue(forKey: recordID)
            synchronizedPayloadDigests[recordID.recordName] = nil
        }
        let confirmedDeletedRecordNames = Set(
            deletedRecordIDs.map(\.recordName)
                + failedRecordDeletes.compactMap { element in
                    element.value.code == .unknownItem
                        ? element.key.recordName : nil
                }
        )
        do {
            try await statistics.clearPrivateCloudDeletions(
                recordNames: confirmedDeletedRecordNames
            )
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }

        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        for record in savedRecords {
            let legacyRecordNames =
                pendingLegacyRecordDeletions[
                    record.recordID.recordName
                ] ?? []
            pendingChanges.append(
                contentsOf: legacyRecordNames.map {
                    .deleteRecord(
                        CKRecord.ID(
                            recordName: $0,
                            zoneID: record.recordID.zoneID
                        )
                    )
                }
            )
        }
        if !confirmedDeletedRecordNames.isEmpty {
            pendingLegacyRecordDeletions =
                pendingLegacyRecordDeletions
                .compactMapValues { names in
                    let remaining = names.subtracting(
                        confirmedDeletedRecordNames
                    )
                    return remaining.isEmpty ? nil : remaining
                }
        }
        for failure in failedRecordSaves {
            switch failure.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failure.error.serverRecord else {
                    throw PrivateCloudSyncError.invalidRecord
                }
                if try await reconcileServerRecordConflict(
                    serverRecord: serverRecord,
                    clientRecord: failure.record
                ) {
                    pendingChanges.append(.saveRecord(serverRecord.recordID))
                }
            case .batchRequestFailed:
                records[failure.record.recordID] = failure.record
                pendingChanges.append(.saveRecord(failure.record.recordID))
            default:
                break
            }
        }
        for (recordID, error) in failedRecordDeletes
        where error.code == .batchRequestFailed {
            pendingChanges.append(.deleteRecord(recordID))
        }
        persistRecordState()
        return pendingChanges
    }

    private func reconcileServerRecordConflict(
        serverRecord: CKRecord,
        clientRecord: CKRecord
    ) async throws -> Bool {
        guard serverRecord.recordID == clientRecord.recordID,
            serverRecord.recordType == clientRecord.recordType
        else {
            throw PrivateCloudSyncError.invalidRecord
        }
        guard serverRecord.recordType == "Configuration" else {
            return try await applyFetchedRecord(
                serverRecord,
                persistSystemFields: false
            )
        }

        guard let clientData = clientRecord[Self.payloadKey] as? Data,
            let serverData = serverRecord[Self.payloadKey] as? Data
        else {
            throw PrivateCloudSyncError.invalidRecord
        }
        let client: CloudConfigurationSnapshot
        let server: CloudConfigurationSnapshot
        do {
            client = try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: clientData
            )
            server = try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: serverData
            )
        } catch {
            throw PrivateCloudSyncError.invalidRecord
        }
        let local = await configuration.snapshot()
        if client == server {
            records[serverRecord.recordID] = serverRecord
            markSynchronized(serverRecord)
            return false
        }
        if local == server {
            records[serverRecord.recordID] = serverRecord
            markSynchronized(serverRecord)
            return false
        }
        if local == client {
            let conflict = CloudConfigurationConflict(
                local: local,
                iCloud: server
            )
            records[serverRecord.recordID] = serverRecord
            try setPendingConfigurationConflict(conflict)
            markSynchronized(serverRecord)
            return false
        }
        do {
            serverRecord[Self.payloadKey] =
                try Self.encodePayload(local) as CKRecordValue
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        records[serverRecord.recordID] = serverRecord
        return true
    }

    func prepareAccountRecord(
        _ account: ServerAccount,
        zoneID: CKRecordZone.ID
    ) throws -> CKRecord {
        pendingAccountChanges[account.id] = nil
        persistPendingAccountChanges()
        let record = try accountRecord(
            account,
            zoneID: zoneID,
            forceNewGeneration: true
        )
        records[record.recordID] = record
        return record
    }

    func pendingServerConfigurationChanges()
        -> [CloudServerConfigurationChange]
    {
        pendingAccountChanges.values.flatMap { $0 }.sorted {
            if $0.incoming.id != $1.incoming.id {
                return $0.incoming.id.rawValue < $1.incoming.id.rawValue
            }
            return $0.structuralKey < $1.structuralKey
        }
    }

    private func appendPendingAccountChange(
        _ change: CloudServerConfigurationChange,
        persist: Bool = true
    ) {
        var candidates = pendingAccountChanges[change.id] ?? []
        guard
            !candidates.contains(where: {
                $0.incoming == change.incoming
            })
        else { return }
        candidates.append(change)
        candidates.sort { $0.structuralKey < $1.structuralKey }
        pendingAccountChanges[change.id] = candidates
        if persist { persistPendingAccountChanges() }
    }

    private func persistPendingAccountChanges() {
        let changes = pendingAccountChanges.values.flatMap { $0 }.sorted {
            $0.structuralKey < $1.structuralKey
        }
        if let data = try? JSONEncoder().encode(changes) {
            defaults.set(data, forKey: pendingAccountChangesKey)
        }
    }

    private func firstPendingAccountChange(
        accountID: AccountID
    ) -> CloudServerConfigurationChange? {
        pendingAccountChanges[accountID]?.sorted {
            $0.incoming.user.username.localizedStandardCompare(
                $1.incoming.user.username
            ) == .orderedAscending
        }.first
    }

    func configurationConflict() -> CloudConfigurationConflict? {
        pendingConfigurationConflict
    }

    func configurationConflictRevision() -> UUID? {
        pendingConfigurationConflictRevision
    }

    func resolveConfigurationConflict(
        _ resolution: CloudConfigurationConflictResolution
    ) async throws -> CKRecord? {
        guard let conflict = pendingConfigurationConflict else {
            return nil
        }
        guard
            let (recordID, record) = records.first(where: {
                $0.key.recordName == "configuration.singleton"
                    && $0.value.recordType == "Configuration"
            })
        else {
            throw PrivateCloudSyncError.invalidRecord
        }
        switch resolution {
        case .keepThisDevice:
            let local = await configuration.snapshot()
            do {
                record[Self.payloadKey] =
                    try Self.encodePayload(local) as CKRecordValue
            } catch {
                throw PrivateCloudSyncError.persistenceFailed
            }
            records[recordID] = record
            return record
        case .useICloud:
            do {
                try await configuration.apply(conflict.iCloud)
            } catch let error as PrivateCloudSyncError {
                throw error
            } catch {
                throw PrivateCloudSyncError.persistenceFailed
            }
            clearPendingConfigurationConflict()
            return nil
        }
    }

    func completeConfigurationConflictResolution(
        revision: UUID
    ) {
        guard pendingConfigurationConflictRevision == revision else {
            return
        }
        clearPendingConfigurationConflict()
    }

    func acceptServerConfigurationChange(
        accountID: AccountID,
        selected: ServerAccount? = nil,
        zoneID: CKRecordZone.ID
    ) async throws -> CKRecord? {
        guard let candidates = pendingAccountChanges[accountID],
            let change = selected.flatMap({ selection in
                candidates.first { $0.incoming == selection }
            }) ?? firstPendingAccountChange(accountID: accountID)
        else {
            return nil
        }
        pendingAccountChanges[accountID] = nil
        persistPendingAccountChanges()
        do {
            if change.current == nil {
                try await accounts.savePendingRestoredAccount(
                    change.incoming
                )
            } else {
                try await accounts.save(change.incoming)
            }
        } catch {
            pendingAccountChanges[accountID] = candidates
            persistPendingAccountChanges()
            throw PrivateCloudSyncError.persistenceFailed
        }
        return try prepareAccountRecord(change.incoming, zoneID: zoneID)
    }

    func rejectServerConfigurationChange(
        accountID: AccountID,
        zoneID: CKRecordZone.ID
    ) async throws -> CKRecord? {
        guard
            let candidates = pendingAccountChanges.removeValue(
                forKey: accountID
            ), let change = candidates.first
        else {
            return nil
        }
        persistPendingAccountChanges()
        guard let current = change.current else {
            var ignored = ignoredAccountIDs()
            ignored.insert(accountID.rawValue)
            defaults.set(
                Array(ignored).sorted(),
                forKey: ignoredAccountsKey
            )
            return nil
        }
        return try prepareAccountRecord(current, zoneID: zoneID)
    }

    func allRecordIDs() -> [CKRecord.ID] {
        Array(records.keys)
    }

    func removeAllRecords() async throws {
        do {
            try await statistics.resetPrivateCloudSynchronizationState()
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        records.removeAll()
        synchronizedPayloadDigests.removeAll()
        defaults.removeObject(forKey: recordSystemFieldsKey)
        defaults.removeObject(forKey: synchronizedPayloadDigestsKey)
        defaults.removeObject(forKey: retainedRecordPayloadsKey)
        if pendingConfigurationConflictIsInvalid {
            clearPendingConfigurationConflict()
        }
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
        includeStatistics: Bool,
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord.ID] {
        var matchingRecordIDs = Set(
            records.values.compactMap { record in
                if record.recordType == "ServerAccount" {
                    let recordAccountID = AccountID(
                        rawValue: String(
                            record.recordID.recordName.dropFirst(
                                "account.".count
                            )
                        )
                    )
                    return recordAccountID == accountID
                        || canonicalAccountID(for: recordAccountID)
                            == accountID
                        ? record.recordID : nil
                }
                guard includeStatistics,
                    let data = record[Self.payloadKey] as? Data
                else {
                    return nil
                }
                switch record.recordType {
                case "ListeningSlice":
                    return
                        (try? JSONDecoder().decode(
                            ListeningSlice.self,
                            from: data
                        ).accountID).map {
                            $0 == accountID
                                || canonicalAccountID(for: $0) == accountID
                        } == true ? record.recordID : nil
                case "CompletionMilestone":
                    return
                        (try? JSONDecoder().decode(
                            CompletionMilestone.self,
                            from: data
                        ).accountID).map {
                            $0 == accountID
                                || canonicalAccountID(for: $0) == accountID
                        } == true ? record.recordID : nil
                case "RemoteListeningSession":
                    return
                        (try? JSONDecoder().decode(
                            RemoteListeningSession.self,
                            from: data
                        ).accountID).map {
                            $0 == accountID
                                || canonicalAccountID(for: $0) == accountID
                        } == true ? record.recordID : nil
                default:
                    return nil
                }
            }
        )
        matchingRecordIDs.formUnion(
            legacyAccountIdentityMappings.compactMap { legacy, canonical in
                canonical == accountID.rawValue
                    ? CKRecord.ID(
                        recordName: "account.\(legacy)",
                        zoneID: zoneID
                    ) : nil
            }
        )
        if includeStatistics {
            do {
                let recordNames = try await statistics.privateCloudRecordNames(
                    accountID: accountID
                )
                matchingRecordIDs.formUnion(
                    recordNames.map {
                        CKRecord.ID(recordName: $0, zoneID: zoneID)
                    }
                )
            } catch {
                throw PrivateCloudSyncError.persistenceFailed
            }
        }
        return Array(matchingRecordIDs)
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
        let record =
            records[recordID]
            ?? CKRecord(recordType: type, recordID: recordID)
        do {
            record[Self.payloadKey] =
                try Self.encodePayload(value) as CKRecordValue
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        return record
    }

    private func accountRecord(
        _ account: ServerAccount,
        zoneID: CKRecordZone.ID,
        forceNewGeneration: Bool
    ) throws -> CKRecord {
        let recordID = CKRecord.ID(
            recordName: "account.\(account.id.rawValue)",
            zoneID: zoneID
        )
        let record =
            records[recordID]
            ?? CKRecord(recordType: "ServerAccount", recordID: recordID)
        let previousData = record[Self.payloadKey] as? Data
        let legacyAccountIDs = legacyAccountIdentityMappings.compactMap {
            legacy, canonical in
            canonical == account.id.rawValue
                ? AccountID(rawValue: legacy) : nil
        }.sorted { $0.rawValue < $1.rawValue }
        if !forceNewGeneration,
            let previousData,
            let previousPayload = try? decodeAccountPayload(previousData),
            previousPayload.schemaVersion
                == CloudServerAccountRecordPayload.currentSchemaVersion,
            previousPayload.account == account,
            previousPayload.legacyAccountIDs == legacyAccountIDs
        {
            return record
        }
        let payload = CloudServerAccountRecordPayload(
            supersededGenerationID: previousData.flatMap {
                try? JSONDecoder().decode(
                    CloudServerAccountRecordPayload.self,
                    from: $0
                ).generationID
            },
            supersededPayloadDigest: previousData.map(Self.payloadDigest),
            account: account,
            legacyAccountIDs: legacyAccountIDs
        )
        do {
            record[Self.payloadKey] =
                try Self.encodePayload(payload) as CKRecordValue
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        return record
    }

    private func apply(_ record: CKRecord) async throws {
        let application = try await apply([record])
        if let failure = application.failure {
            throw failure
        }
    }

    private func statisticsArchive(
        from cloudRecords: [CKRecord]
    ) throws -> StatisticsArchive {
        var slices: [ListeningSlice] = []
        var completions: [CompletionMilestone] = []
        var remoteSessions: [RemoteListeningSession] = []
        do {
            for record in cloudRecords {
                guard
                    record.recordType == "ListeningSlice"
                        || record.recordType == "CompletionMilestone"
                        || record.recordType == "RemoteListeningSession"
                else {
                    continue
                }
                guard let data = record[Self.payloadKey] as? Data else {
                    throw PrivateCloudSyncError.invalidRecord
                }
                switch record.recordType {
                case "ListeningSlice":
                    slices.append(
                        try JSONDecoder().decode(
                            ListeningSlice.self,
                            from: data
                        )
                    )
                case "CompletionMilestone":
                    completions.append(
                        try JSONDecoder().decode(
                            CompletionMilestone.self,
                            from: data
                        )
                    )
                case "RemoteListeningSession":
                    remoteSessions.append(
                        try JSONDecoder().decode(
                            RemoteListeningSession.self,
                            from: data
                        )
                    )
                default:
                    continue
                }
            }
            return StatisticsArchive(
                slices: slices,
                completions: completions,
                remoteSessions: remoteSessions
            )
        } catch let error as PrivateCloudSyncError {
            throw error
        } catch {
            throw PrivateCloudSyncError.invalidRecord
        }
    }

    private func apply(
        _ recordsToApply: [CKRecord]
    ) async throws -> (
        appliedRecords: [CKRecord],
        failure: PrivateCloudSyncError?
    ) {
        var slices: [ListeningSlice] = []
        var completions: [CompletionMilestone] = []
        var remoteSessions: [RemoteListeningSession] = []
        var accountsToSave: [ServerAccount] = []
        var configurations: [CloudConfigurationSnapshot] = []
        var appliedRecords: [CKRecord] = []
        var firstFailure: PrivateCloudSyncError?
        let ignoredStatisticsAccounts = ignoredStatisticsAccountIDs()
        let ignoredAccounts = ignoredAccountIDs()
        for record in recordsToApply {
            do {
                guard let data = record[Self.payloadKey] as? Data else {
                    throw PrivateCloudSyncError.invalidRecord
                }
                switch record.recordType {
                case "ListeningSlice":
                    let value = try JSONDecoder().decode(
                        ListeningSlice.self,
                        from: data
                    )
                    if !ignoredStatisticsAccounts.contains(
                        value.accountID.rawValue
                    ) {
                        slices.append(value)
                    }
                case "CompletionMilestone":
                    let value = try JSONDecoder().decode(
                        CompletionMilestone.self,
                        from: data
                    )
                    if !ignoredStatisticsAccounts.contains(
                        value.accountID.rawValue
                    ) {
                        completions.append(value)
                    }
                case "RemoteListeningSession":
                    let value = try JSONDecoder().decode(
                        RemoteListeningSession.self,
                        from: data
                    )
                    if !ignoredStatisticsAccounts.contains(
                        value.accountID.rawValue
                    ) {
                        remoteSessions.append(value)
                    }
                case "ServerAccount":
                    let value = try decodeAccountPayload(data).account
                    if !ignoredAccounts.contains(value.id.rawValue) {
                        accountsToSave.append(value)
                    }
                case "Configuration":
                    configurations.append(
                        try JSONDecoder().decode(
                            CloudConfigurationSnapshot.self,
                            from: data
                        )
                    )
                default:
                    break
                }
                appliedRecords.append(record)
            } catch let error as PrivateCloudSyncError {
                if firstFailure == nil {
                    firstFailure = error
                }
            } catch {
                if firstFailure == nil {
                    firstFailure = .invalidRecord
                }
            }
        }
        do {
            if !slices.isEmpty || !completions.isEmpty
                || !remoteSessions.isEmpty
            {
                let archive = StatisticsArchive(
                    slices: slices,
                    completions: completions,
                    remoteSessions: remoteSessions
                )
                try await statistics.importArchive(archive)
                try await statistics.markPrivateCloudArchiveSynchronized(
                    archive
                )
            }
            for account in accountsToSave {
                try await accounts.save(account)
            }
            for snapshot in configurations {
                try await configuration.apply(snapshot)
            }
        } catch let error as PrivateCloudSyncError {
            throw error
        } catch {
            throw PrivateCloudSyncError.invalidRecord
        }
        return (appliedRecords, firstFailure)
    }

    private func learnLegacyAccountMappings(from cloudRecords: [CKRecord]) {
        var changed = false
        for record in cloudRecords where record.recordType == "ServerAccount" {
            guard let data = record[Self.payloadKey] as? Data,
                let payload = try? decodeAccountPayload(data)
            else {
                continue
            }
            let canonicalID = AccountID.canonical(
                server: payload.account.server,
                userID: payload.account.user.id
            )
            for legacyID in payload.legacyAccountIDs + [payload.account.id]
            where legacyID != canonicalID {
                if legacyAccountIdentityMappings[legacyID.rawValue]
                    != canonicalID.rawValue
                {
                    legacyAccountIdentityMappings[legacyID.rawValue] =
                        canonicalID.rawValue
                    changed = true
                }
            }
        }
        guard changed else { return }
        defaults.set(
            legacyAccountIdentityMappings,
            forKey: legacyAccountIdentityMappingsKey
        )
    }

    private func seedLegacyAccountMappingsFromAliases() async throws {
        let aliases: [AccountIdentityMigration]
        do {
            aliases = try await accounts.identityAliases()
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        var changed = false
        for alias in aliases {
            if let existing = legacyAccountIdentityMappings[
                alias.legacyID.rawValue
            ], existing != alias.canonicalID.rawValue {
                throw PrivateCloudSyncError.invalidRecord
            }
            if legacyAccountIdentityMappings[alias.legacyID.rawValue] == nil {
                legacyAccountIdentityMappings[alias.legacyID.rawValue] =
                    alias.canonicalID.rawValue
                changed = true
            }
        }
        guard changed else { return }
        defaults.set(
            legacyAccountIdentityMappings,
            forKey: legacyAccountIdentityMappingsKey
        )
    }

    private func canonicalizedCloudRecord(
        _ record: CKRecord
    ) throws -> CanonicalizedCloudRecord {
        guard let data = record[Self.payloadKey] as? Data else {
            throw PrivateCloudSyncError.invalidRecord
        }
        let canonicalRecord: CKRecord
        let canonicalData: Data
        switch record.recordType {
        case "ServerAccount":
            let payload = try decodeAccountPayload(data)
            let canonicalID = AccountID.canonical(
                server: payload.account.server,
                userID: payload.account.user.id
            )
            let canonicalAccount = try payload.account.reidentified(
                as: canonicalID
            )
            let aliases = Set(
                payload.legacyAccountIDs
                    + (payload.account.id == canonicalID
                        ? [] : [payload.account.id])
                    + legacyAccountIdentityMappings.compactMap {
                        legacy, canonical in
                        canonical == canonicalID.rawValue
                            ? AccountID(rawValue: legacy) : nil
                    }
            ).sorted { $0.rawValue < $1.rawValue }
            let canonicalPayload = CloudServerAccountRecordPayload(
                generationID: payload.generationID,
                supersededGenerationID: payload.supersededGenerationID,
                supersededPayloadDigest: payload.supersededPayloadDigest,
                account: canonicalAccount,
                legacyAccountIDs: aliases
            )
            canonicalData = try Self.encodePayload(canonicalPayload)
            let canonicalIDValue = CKRecord.ID(
                recordName: "account.\(canonicalID.rawValue)",
                zoneID: record.recordID.zoneID
            )
            canonicalRecord =
                records[canonicalIDValue]
                ?? CKRecord(
                    recordType: record.recordType,
                    recordID: canonicalIDValue
                )
        case "ListeningSlice":
            let value = try JSONDecoder().decode(
                ListeningSlice.self, from: data)
            guard let canonical = canonicalAccountID(for: value.accountID)
            else {
                return CanonicalizedCloudRecord(
                    record: record,
                    legacyRecordID: nil,
                    requiresUpload: false
                )
            }
            canonicalData = try Self.encodePayload(
                value.reidentified(as: canonical)
            )
            canonicalRecord = record
        case "CompletionMilestone":
            let value = try JSONDecoder().decode(
                CompletionMilestone.self,
                from: data
            )
            guard let canonical = canonicalAccountID(for: value.accountID)
            else {
                return CanonicalizedCloudRecord(
                    record: record,
                    legacyRecordID: nil,
                    requiresUpload: false
                )
            }
            canonicalData = try Self.encodePayload(
                value.reidentified(as: canonical)
            )
            canonicalRecord = record
        case "RemoteListeningSession":
            let value = try JSONDecoder().decode(
                RemoteListeningSession.self,
                from: data
            )
            guard let canonical = canonicalAccountID(for: value.accountID)
            else {
                return CanonicalizedCloudRecord(
                    record: record,
                    legacyRecordID: nil,
                    requiresUpload: false
                )
            }
            let canonicalValue = value.reidentified(as: canonical)
            canonicalData = try Self.encodePayload(canonicalValue)
            let canonicalIDValue = CKRecord.ID(
                recordName: "remote.\(canonical.rawValue).\(value.id.rawValue)",
                zoneID: record.recordID.zoneID
            )
            canonicalRecord =
                records[canonicalIDValue]
                ?? CKRecord(
                    recordType: record.recordType,
                    recordID: canonicalIDValue
                )
        default:
            return CanonicalizedCloudRecord(
                record: record,
                legacyRecordID: nil,
                requiresUpload: false
            )
        }
        let requiresUpload =
            canonicalRecord.recordID != record.recordID
            || canonicalData != data
        guard requiresUpload else {
            return CanonicalizedCloudRecord(
                record: record,
                legacyRecordID: nil,
                requiresUpload: false
            )
        }
        canonicalRecord[Self.payloadKey] = canonicalData as CKRecordValue
        return CanonicalizedCloudRecord(
            record: canonicalRecord,
            legacyRecordID: canonicalRecord.recordID == record.recordID
                ? nil : record.recordID,
            requiresUpload: true
        )
    }

    private func canonicalAccountID(
        for accountID: AccountID
    ) -> AccountID? {
        guard let rawValue = legacyAccountIdentityMappings[accountID.rawValue],
            rawValue != accountID.rawValue
        else {
            return nil
        }
        return AccountID(rawValue: rawValue)
    }

    private func registerLegacyRecordDeletion(
        _ legacyRecordID: CKRecord.ID?,
        afterSaving canonicalRecordID: CKRecord.ID
    ) {
        guard let legacyRecordID,
            legacyRecordID != canonicalRecordID
        else {
            return
        }
        pendingLegacyRecordDeletions[
            canonicalRecordID.recordName,
            default: []
        ].insert(legacyRecordID.recordName)
        persistPendingLegacyRecordDeletions()
    }

    private func persistPendingLegacyRecordDeletions() {
        defaults.set(
            pendingLegacyRecordDeletions.mapValues {
                $0.sorted()
            },
            forKey: pendingLegacyRecordDeletionsKey
        )
    }

    private func resolveIncomingRecord(
        _ record: CKRecord,
        previousRecord: CKRecord?
    ) async throws -> IncomingRecordResolution {
        guard let incomingData = record[Self.payloadKey] as? Data else {
            throw PrivateCloudSyncError.invalidRecord
        }

        do {
            switch record.recordType {
            case "ServerAccount":
                let incomingPayload = try decodeAccountPayload(incomingData)
                let incoming = incomingPayload.account
                if ignoredAccountIDs().contains(incoming.id.rawValue) {
                    return .applyRemote
                }
                let current = try await accounts.account(id: incoming.id)
                if let previousRecord,
                    let previousData =
                        previousRecord[Self.payloadKey] as? Data,
                    let previousPayload = try? JSONDecoder().decode(
                        CloudServerAccountRecordPayload.self,
                        from: previousData
                    ),
                    previousPayload.schemaVersion
                        == CloudServerAccountRecordPayload
                        .currentSchemaVersion,
                    previousPayload.account == current,
                    previousPayload.supersededGenerationID
                        == incomingPayload.generationID
                        || previousPayload.supersededPayloadDigest
                            == Self.payloadDigest(incomingData)
                {
                    return .preserveLocal(previousData)
                }
                guard current != incoming else {
                    return .applyRemote
                }
                return .requestAccountConfirmation(
                    CloudServerConfigurationChange(
                        current: current,
                        incoming: incoming
                    )
                )
            case "Configuration":
                guard let previousRecord,
                    let previousData = previousRecord[Self.payloadKey] as? Data
                else {
                    return .applyRemote
                }
                let previous = try JSONDecoder().decode(
                    CloudConfigurationSnapshot.self,
                    from: previousData
                )
                let incoming = try JSONDecoder().decode(
                    CloudConfigurationSnapshot.self,
                    from: incomingData
                )
                let local = await configuration.snapshot()
                guard local != previous, local != incoming else {
                    return .applyRemote
                }
                return .requestConfigurationConfirmation(
                    CloudConfigurationConflict(
                        local: local,
                        iCloud: incoming
                    )
                )
            default:
                return .applyRemote
            }
        } catch let error as PrivateCloudSyncError {
            throw error
        } catch {
            throw PrivateCloudSyncError.invalidRecord
        }
    }

    private func decodeAccountPayload(
        _ data: Data
    ) throws -> CloudServerAccountRecordPayload {
        if let payload = try? JSONDecoder().decode(
            CloudServerAccountRecordPayload.self,
            from: data
        ) {
            guard
                CloudServerAccountRecordPayload.supportedSchemaVersions
                    .contains(payload.schemaVersion)
            else {
                throw PrivateCloudSyncError.invalidRecord
            }
            return payload
        }
        return CloudServerAccountRecordPayload(
            supersededPayloadDigest: nil,
            account: try JSONDecoder().decode(ServerAccount.self, from: data)
        )
    }

    private static func payloadDigest(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    private func applyDeletion(
        recordID: CKRecord.ID,
        recordType: CKRecord.RecordType
    ) async throws {
        let name = recordID.recordName
        do {
            switch recordType {
            case "ListeningSlice":
                guard
                    let id = UUID(
                        uuidString: name.replacingOccurrences(
                            of: "slice.",
                            with: ""
                        )
                    )
                else {
                    throw PrivateCloudSyncError.invalidRecord
                }
                try await statistics.deleteSlice(id: id)
            case "CompletionMilestone":
                guard
                    let id = UUID(
                        uuidString: name.replacingOccurrences(
                            of: "completion.",
                            with: ""
                        )
                    )
                else {
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

    private func needsUpload(_ record: CKRecord) -> Bool {
        guard let data = record[Self.payloadKey] as? Data else {
            return true
        }
        return synchronizedPayloadDigests[record.recordID.recordName]
            != Self.payloadDigest(data)
    }

    private func markSynchronized(_ record: CKRecord) {
        if record.recordType == "ListeningSlice"
            || record.recordType == "CompletionMilestone",
            record.recordChangeTag != nil
        {
            synchronizedPayloadDigests[record.recordID.recordName] = nil
            return
        }
        guard let data = record[Self.payloadKey] as? Data else {
            return
        }
        synchronizedPayloadDigests[record.recordID.recordName] =
            Self.payloadDigest(data)
    }

    private func persistRecordState() {
        persistPendingLegacyRecordDeletions()
        let archivedRecords = records.reduce(
            into: [String: Data]()
        ) { result, element in
            result[element.key.recordName] = Self.encodeSystemFields(
                element.value
            )
        }
        defaults.set(archivedRecords, forKey: recordSystemFieldsKey)
        let recordTypes = Dictionary(
            uniqueKeysWithValues: records.map {
                ($0.key.recordName, $0.value.recordType)
            }
        )
        let durablePayloadDigests = synchronizedPayloadDigests.filter {
            recordName, _ in
            guard let type = recordTypes[recordName] else {
                return false
            }
            return type != "ListeningSlice"
                && type != "CompletionMilestone"
        }
        defaults.set(
            durablePayloadDigests,
            forKey: synchronizedPayloadDigestsKey
        )
        let retainedPayloads = records.reduce(
            into: [String: Data]()
        ) { result, element in
            guard
                element.value.recordType == "ServerAccount"
                    || element.value.recordType == "Configuration",
                let data = element.value[Self.payloadKey] as? Data
            else {
                return
            }
            result[element.key.recordName] = data
        }
        defaults.set(retainedPayloads, forKey: retainedRecordPayloadsKey)
    }

    private static func encodePayload<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func setPendingConfigurationConflict(
        _ conflict: CloudConfigurationConflict
    ) throws {
        do {
            defaults.set(
                try JSONEncoder().encode(conflict),
                forKey: pendingConfigurationConflictKey
            )
            pendingConfigurationConflict = conflict
            pendingConfigurationConflictRevision = UUID()
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
    }

    private func clearPendingConfigurationConflict() {
        pendingConfigurationConflict = nil
        pendingConfigurationConflictRevision = nil
        pendingConfigurationConflictIsInvalid = false
        defaults.removeObject(forKey: pendingConfigurationConflictKey)
    }

    private static func encodeSystemFields(_ record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard
            let unarchiver = try? NSKeyedUnarchiver(
                forReadingFrom: data
            )
        else {
            return nil
        }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
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
    private let eventRecorder: any PrivateCloudSyncEventRecording
    private let configurationFailure: PrivateCloudSyncError?
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
        eventRecorder: any PrivateCloudSyncEventRecording =
            DisabledPrivateCloudSyncEventRecorder(),
        container: CKContainer = CKContainer(
            identifier: PrivateCloudSyncCoordinator.containerIdentifier
        )
    ) {
        store = PrivateCloudSyncStore(
            statistics: statistics,
            accounts: accounts,
            credentialStore: credentialStore,
            configuration: configuration,
            defaults: PrivateCloudDefaultsReference(defaults)
        )
        self.defaults = defaults
        self.eventRecorder = eventRecorder
        let serialization: CKSyncEngine.State.Serialization?
        if let data = defaults.data(forKey: stateKey) {
            do {
                serialization = try JSONDecoder().decode(
                    CKSyncEngine.State.Serialization.self,
                    from: data
                )
            } catch {
                serialization = nil
                let failure = PrivateCloudSyncFailure(
                    operation: .persistEngineState,
                    cause: .persistenceFailed
                )
                Task {
                    let correlationID = UUID()
                    await eventRecorder.record(
                        PrivateCloudSyncEvent(
                            correlationID: correlationID,
                            operation: failure.operation,
                            phase: .started
                        )
                    )
                    await eventRecorder.record(
                        PrivateCloudSyncEvent(
                            correlationID: correlationID,
                            operation: failure.operation,
                            phase: .failed(failure),
                            durationMilliseconds: 0
                        )
                    )
                }
            }
        } else {
            serialization = nil
        }
        // Bleat synchronizes listening history and account configuration. Keep
        // that user data in the owner's private database even though the
        // container schema also exists for CloudKit's public database scope.
        let database = container.privateCloudDatabase
        configurationFailure = Self.configurationFailure(
            for: database.databaseScope
        )
        guard configurationFailure == nil else {
            engine = nil
            return
        }
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = false
        configuration.subscriptionID = "bleat-private-sync-v1"
        engine = CKSyncEngine(configuration)
    }

    static func configurationFailure(
        for databaseScope: CKDatabase.Scope
    ) -> PrivateCloudSyncError? {
        databaseScope == .private ? nil : .nonPrivateDatabase
    }

    private func configuredEngine() throws(PrivateCloudSyncError)
        -> CKSyncEngine
    {
        if let configurationFailure {
            throw configurationFailure
        }
        guard let engine else {
            throw PrivateCloudSyncError.engineUnavailable
        }
        return engine
    }

    public var isEnabled: Bool {
        defaults.object(forKey: enabledKey) == nil
            ? true
            : defaults.bool(forKey: enabledKey)
    }

    public func synchronize() async throws(PrivateCloudSyncFailure) {
        try await perform(.synchronize) {
            guard isEnabled else {
                throw PrivateCloudSyncError.disabled
            }
            let engine = try configuredEngine()
            try await perform(.setupZone) {
                engine.state.add(
                    pendingDatabaseChanges: [
                        .saveZone(CKRecordZone(zoneID: zoneID))
                    ]
                )
                try await engine.sendChanges()
            }
            try await perform(.fetchChanges) {
                try await engine.fetchChanges(
                    CKSyncEngine.FetchChangesOptions(
                        scope: .zoneIDs([zoneID])
                    )
                )
            }
            let records = try await perform(
                .prepareLocalChanges,
                count: { $0.records.count + $0.deletions.count }
            ) {
                let records = try await store.prepareRecords(zoneID: zoneID)
                let deletions = try await store.prepareDeletionChanges(
                    zoneID: zoneID
                )
                return (records: records, deletions: deletions)
            }
            engine.state.add(
                pendingRecordZoneChanges:
                    records.records.map { .saveRecord($0.recordID) }
                    + records.deletions
            )
            let recordCount = records.records.count + records.deletions.count
            try await perform(
                .uploadChanges,
                count: { _ in recordCount },
                failureRecordCount: recordCount
            ) {
                try await sendRecordChanges(
                    engine: engine,
                    CKSyncEngine.SendChangesOptions(
                        scope: .zoneIDs([zoneID])
                    )
                )
            }
        }
    }

    public func cancelSynchronization() async {
        let correlationID = UUID()
        let startedAt = ContinuousClock.now
        await eventRecorder.record(
            PrivateCloudSyncEvent(
                correlationID: correlationID,
                operation: .cancel,
                phase: .started
            )
        )
        guard let engine else {
            await recordCompletion(
                operation: .cancel,
                correlationID: correlationID,
                startedAt: startedAt
            )
            return
        }
        await engine.cancelOperations()
        await recordCompletion(
            operation: .cancel,
            correlationID: correlationID,
            startedAt: startedAt
        )
    }

    public func forcePushServerConfiguration(
        _ account: ServerAccount
    ) async throws(PrivateCloudSyncFailure) {
        try await perform(.pushServerConfiguration) {
            guard isEnabled else {
                throw PrivateCloudSyncError.disabled
            }
            let engine = try configuredEngine()
            let record = try await store.prepareAccountRecord(
                account,
                zoneID: zoneID
            )
            engine.state.add(
                pendingRecordZoneChanges: [
                    .saveRecord(record.recordID)
                ]
            )
            try await sendRecordChanges(
                engine: engine,
                CKSyncEngine.SendChangesOptions(
                    scope: .recordIDs([record.recordID])
                )
            )
        }
    }

    public func pendingServerConfigurationChanges() async
        -> [CloudServerConfigurationChange]
    {
        await store.pendingServerConfigurationChanges()
    }

    public func pendingConfigurationConflict() async
        -> CloudConfigurationConflict?
    {
        await store.configurationConflict()
    }

    public func resolveConfigurationConflict(
        _ resolution: CloudConfigurationConflictResolution
    ) async throws(PrivateCloudSyncFailure) {
        let operation: PrivateCloudSyncOperation =
            switch resolution {
            case .keepThisDevice: .keepLocalConfiguration
            case .useICloud: .acceptCloudConfiguration
            }
        try await perform(operation) {
            guard isEnabled else {
                throw PrivateCloudSyncError.disabled
            }
            guard await store.configurationConflict() != nil,
                let revision = await store.configurationConflictRevision()
            else {
                return
            }
            let record = try await store.resolveConfigurationConflict(
                resolution
            )
            guard let record else {
                return
            }
            let engine = try configuredEngine()
            engine.state.add(
                pendingRecordZoneChanges: [.saveRecord(record.recordID)]
            )
            try await sendRecordChanges(
                engine: engine,
                CKSyncEngine.SendChangesOptions(
                    scope: .recordIDs([record.recordID])
                )
            )
            await store.completeConfigurationConflictResolution(
                revision: revision
            )
        }
    }

    public func resolveServerConfigurationChange(
        accountID: AccountID,
        selected: ServerAccount? = nil,
        accept: Bool
    ) async throws(PrivateCloudSyncFailure) {
        try await perform(.resolveServerConfiguration) {
            let record: CKRecord?
            if accept {
                record = try await store.acceptServerConfigurationChange(
                    accountID: accountID,
                    selected: selected,
                    zoneID: zoneID
                )
            } else {
                record = try await store.rejectServerConfigurationChange(
                    accountID: accountID,
                    zoneID: zoneID
                )
            }
            guard let record else {
                return
            }
            let engine = try configuredEngine()
            engine.state.add(
                pendingRecordZoneChanges: [
                    .saveRecord(record.recordID)
                ]
            )
            try await sendRecordChanges(
                engine: engine,
                CKSyncEngine.SendChangesOptions(
                    scope: .recordIDs([record.recordID])
                )
            )
        }
    }

    public func setEnabled(
        _ enabled: Bool,
        deleteCloudData: Bool
    ) async throws(PrivateCloudSyncFailure) {
        if enabled {
            try await perform(.enable) {
                _ = try configuredEngine()
                defaults.set(true, forKey: enabledKey)
                do {
                    try await synchronize()
                } catch let failure as PrivateCloudSyncFailure {
                    throw failure.cause
                }
            }
            return
        }

        try await perform(.disable) {
            if deleteCloudData {
                let engine = try configuredEngine()
                await engine.cancelOperations()
                do {
                    try await perform(.deleteCloudData) {
                        engine.state.add(
                            pendingDatabaseChanges: [.deleteZone(zoneID)]
                        )
                        try await engine.sendChanges()
                        try await store.removeAllRecords()
                        defaults.removeObject(forKey: stateKey)
                    }
                } catch let failure as PrivateCloudSyncFailure {
                    throw failure.cause
                }
            } else {
                // Local opt-out must remain available when a source or
                // entitlement bug prevented the CloudKit engine from being
                // created. No database access is needed to retain cloud data.
                await engine?.cancelOperations()
            }
            defaults.set(false, forKey: enabledKey)
        }
    }

    public func deleteAccountEverywhere(
        _ accountID: AccountID,
        includeStatistics: Bool
    ) async throws(PrivateCloudSyncFailure) {
        try await perform(.deleteAccount) {
            guard isEnabled else {
                throw PrivateCloudSyncError.disabled
            }
            let engine = try configuredEngine()
            _ = try await store.prepareRecords(zoneID: zoneID)
            let recordIDs = try await store.recordIDs(
                for: accountID,
                includeStatistics: includeStatistics,
                zoneID: zoneID
            )
            engine.state.add(
                pendingRecordZoneChanges: recordIDs.map {
                    .deleteRecord($0)
                }
            )
            try await sendRecordChanges(
                engine: engine,
                CKSyncEngine.SendChangesOptions(
                    scope: .recordIDs(recordIDs)
                )
            )
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
            let correlationID = UUID()
            let startedAt = ContinuousClock.now
            await eventRecorder.record(
                PrivateCloudSyncEvent(
                    correlationID: correlationID,
                    operation: .persistEngineState,
                    phase: .started
                )
            )
            do {
                let data = try JSONEncoder().encode(
                    update.stateSerialization
                )
                defaults.set(data, forKey: stateKey)
                await recordCompletion(
                    operation: .persistEngineState,
                    correlationID: correlationID,
                    startedAt: startedAt
                )
            } catch {
                await recordFailure(
                    Self.mappedFailure(
                        operation: .persistEngineState,
                        error: PrivateCloudSyncError.persistenceFailed
                    ),
                    correlationID: correlationID,
                    startedAt: startedAt
                )
            }
        case .fetchedRecordZoneChanges(let changes):
            let correlationID = UUID()
            let startedAt = ContinuousClock.now
            let recordCount =
                changes.modifications.count + changes.deletions.count
            await eventRecorder.record(
                PrivateCloudSyncEvent(
                    correlationID: correlationID,
                    operation: .applyFetchedChanges,
                    phase: .started
                )
            )
            do {
                let pendingChanges = try await store.apply(
                    modifications: changes.modifications,
                    deletions: changes.deletions
                )
                syncEngine.state.add(
                    pendingRecordZoneChanges: pendingChanges
                )
                await recordCompletion(
                    operation: .applyFetchedChanges,
                    correlationID: correlationID,
                    startedAt: startedAt,
                    recordCount: recordCount
                )
            } catch {
                await recordFailure(
                    Self.mappedFailure(
                        operation: .applyFetchedChanges,
                        error: error
                    ),
                    correlationID: correlationID,
                    startedAt: startedAt,
                    recordCount: recordCount
                )
            }
        case .sentRecordZoneChanges(let changes):
            let correlationID = UUID()
            let startedAt = ContinuousClock.now
            let recordCount =
                changes.savedRecords.count
                + changes.deletedRecordIDs.count
                + changes.failedRecordSaves.count
                + changes.failedRecordDeletes.count
            await eventRecorder.record(
                PrivateCloudSyncEvent(
                    correlationID: correlationID,
                    operation: .reconcileSentChanges,
                    phase: .started
                )
            )
            do {
                let pendingChanges =
                    try await store
                    .reconcileSentRecordZoneChanges(
                        savedRecords: changes.savedRecords,
                        deletedRecordIDs: changes.deletedRecordIDs,
                        failedRecordSaves: changes.failedRecordSaves.map {
                            (record: $0.record, error: $0.error)
                        },
                        failedRecordDeletes: changes.failedRecordDeletes
                    )
                syncEngine.state.add(
                    pendingRecordZoneChanges: pendingChanges
                )
                await recordCompletion(
                    operation: .reconcileSentChanges,
                    correlationID: correlationID,
                    startedAt: startedAt,
                    recordCount: recordCount
                )
            } catch {
                await recordFailure(
                    Self.mappedFailure(
                        operation: .reconcileSentChanges,
                        error: error
                    ),
                    correlationID: correlationID,
                    startedAt: startedAt,
                    recordCount: recordCount
                )
            }
        default:
            break
        }
    }

    static func mappedFailure(
        operation: PrivateCloudSyncOperation,
        error: any Error
    ) -> PrivateCloudSyncFailure {
        if let failure = error as? PrivateCloudSyncFailure {
            return failure
        }
        let cause: PrivateCloudSyncError
        if Task.isCancelled || error is CancellationError {
            cause = .cancelled
        } else if let error = error as? PrivateCloudSyncError {
            cause = error
        } else if let error = error as? CKError {
            cause =
                error.code == .operationCancelled
                ? .cancelled
                : .cloudKit(CloudKitFailure(error))
        } else {
            cause = .unexpected(PrivateCloudSystemError(error))
        }
        return PrivateCloudSyncFailure(operation: operation, cause: cause)
    }

    private func perform<Value>(
        _ operation: PrivateCloudSyncOperation,
        count: ((Value) -> Int?)? = nil,
        failureRecordCount: Int? = nil,
        _ body: () async throws -> Value
    ) async throws(PrivateCloudSyncFailure) -> Value {
        let correlationID = UUID()
        let startedAt = ContinuousClock.now
        await eventRecorder.record(
            PrivateCloudSyncEvent(
                correlationID: correlationID,
                operation: operation,
                phase: .started
            )
        )
        do {
            let value = try await body()
            await recordCompletion(
                operation: operation,
                correlationID: correlationID,
                startedAt: startedAt,
                recordCount: count?(value)
            )
            return value
        } catch {
            let failure = Self.mappedFailure(
                operation: operation,
                error: error
            )
            await recordFailure(
                PrivateCloudSyncFailure(
                    operation: operation,
                    cause: failure.cause
                ),
                correlationID: correlationID,
                startedAt: startedAt,
                recordCount: failureRecordCount
            )
            throw failure
        }
    }

    private func sendRecordChanges(
        engine: CKSyncEngine,
        _ options: CKSyncEngine.SendChangesOptions
    ) async throws {
        for attempt in 0...1 {
            do {
                try await engine.sendChanges(options)
                return
            } catch let error as CKError {
                let failure = CloudKitFailure(error)
                let recovery = failure.sendRecovery(
                    hasPendingConfigurationConflict:
                        await store.configurationConflict() != nil,
                    attempt: attempt
                )
                switch recovery {
                case .awaitUserResolution:
                    return
                case .retry:
                    continue
                case .fail:
                    throw error
                }
            }
        }
    }

    private func recordCompletion(
        operation: PrivateCloudSyncOperation,
        correlationID: UUID,
        startedAt: ContinuousClock.Instant,
        recordCount: Int? = nil
    ) async {
        await eventRecorder.record(
            PrivateCloudSyncEvent(
                correlationID: correlationID,
                operation: operation,
                phase: .completed,
                durationMilliseconds: Self.durationMilliseconds(
                    since: startedAt
                ),
                recordCount: recordCount
            )
        )
    }

    private func recordFailure(
        _ failure: PrivateCloudSyncFailure,
        correlationID: UUID,
        startedAt: ContinuousClock.Instant,
        recordCount: Int? = nil
    ) async {
        await eventRecorder.record(
            PrivateCloudSyncEvent(
                correlationID: correlationID,
                operation: failure.operation,
                phase: .failed(failure),
                durationMilliseconds: Self.durationMilliseconds(
                    since: startedAt
                ),
                recordCount: recordCount
            )
        )
    }

    private static func durationMilliseconds(
        since startedAt: ContinuousClock.Instant
    ) -> Int {
        let duration = startedAt.duration(to: .now)
        let components = duration.components
        let seconds = components.seconds * 1_000
        let attoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: seconds + attoseconds)
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
