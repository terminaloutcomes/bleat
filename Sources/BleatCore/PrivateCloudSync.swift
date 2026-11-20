import CloudKit
import CryptoKit
import Foundation
import SwiftData

public enum PrivateCloudSyncStatus: Equatable, Sendable {
    case disabled
    case idle
    case syncing
    case unavailable
    case failed
}

public enum PrivateCloudSyncOperation: String, Codable, Equatable, Sendable {
    case synchronize
    case migrateLocalState = "migrate_local_state"
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

public enum CloudKitFailureCode: Hashable, Sendable, Codable {
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

public struct CloudKitFailure: Equatable, Sendable, Codable {
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

public struct PrivateCloudSystemError: Equatable, Sendable, Codable {
    public let domain: String
    public let code: Int

    init(_ error: any Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
    }
}

public enum PrivateCloudSyncError: Error, Equatable, Sendable, Codable {
    case disabled
    case cancelled
    case callbackTimedOut
    case stopping
    case invalidRecord
    case configurationSelectionChanged
    case persistenceFailed
    case storage(PrivateCloudStorageFailure)
    case nonPrivateDatabase
    case engineUnavailable
    case cloudKit(CloudKitFailure)
    case unexpected(PrivateCloudSystemError)

    public var isRetryable: Bool {
        switch self {
        case .cloudKit(let failure): failure.isRetryable
        case .storage(let failure):
            switch failure {
            case .invalidLegacyMetadata, .invalidLegacyState,
                .invalidStoredState,
                .migrationVerificationFailed:
                false
            case .metadataReadFailed, .metadataWriteFailed, .stateReadFailed,
                .stateWriteFailed:
                true
            }
        case .cancelled, .callbackTimedOut, .persistenceFailed,
            .engineUnavailable:
            true
        case .disabled, .stopping, .invalidRecord,
            .configurationSelectionChanged,
            .nonPrivateDatabase,
            .unexpected:
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

public struct PrivateCloudSyncFailure: Error, Equatable, Sendable, Codable {
    public let operation: PrivateCloudSyncOperation
    public let cause: PrivateCloudSyncError
    public let selectionCommitted: Bool

    public init(
        operation: PrivateCloudSyncOperation,
        cause: PrivateCloudSyncError,
        selectionCommitted: Bool = false
    ) {
        self.operation = operation
        self.cause = cause
        self.selectionCommitted = selectionCommitted
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

/// Pair each started correlation ID with a completed or failed event.
/// Remote telemetry bounds unmatched tracking to 64 spans, ending the oldest
/// on overflow. This does not time out or cancel the underlying CloudKit work.
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
        self.automaticDownloadLookahead =
            AutomaticDownloadLookaheadPreference.normalize(
                automaticDownloadLookahead
            ).rawValue
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
        automaticDownloadLookahead =
            AutomaticDownloadLookaheadPreference.normalize(
                try container.decode(
                    Int.self,
                    forKey: .automaticDownloadLookahead
                )
            ).rawValue
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
            AutomaticDownloadLookaheadPreference.defaultsKey
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
            automaticDownloadLookahead:
                AutomaticDownloadLookaheadPreference.load(
                    from: defaults
                ).rawValue,
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
            AutomaticDownloadLookaheadPreference(
                rawValue: snapshot.automaticDownloadLookahead
            ) != nil,
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
            AutomaticDownloadLookaheadPreference.normalize(
                snapshot.automaticDownloadLookahead
            ).rawValue,
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
    private let defaults: PrivateCloudPersistence
    private let legacyDefaults: UserDefaults
    private var storageReady = false
    private var storagePreparationTask: Task<Void, Error>?
    private let migrationBatchDidCommit: (@Sendable (Int) async throws -> Void)?
    private(set) var lastCommittedMetadataCount = 0
    private var synchronizedRecords: Set<CKRecord.ID> = []
    private var dirtyRecords: Set<CKRecord.ID> = []
    private var deletedRecords: Set<CKRecord.ID> = []
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
    private let synchronizedConfigurationKey =
        PrivateCloudPersistence.configurationBaselineKey
    private var synchronizedConfigurationData: Data?
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
    private var configurationUploadChoice:
        (revision: UUID, snapshot: CloudConfigurationSnapshot)?
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
        ),
        migrationBatchDidCommit: (@Sendable (Int) async throws -> Void)? = nil
    ) {
        self.statistics = statistics
        self.accounts = accounts
        self.credentialStore = credentialStore
        self.configuration = configuration
        self.migrationBatchDidCommit = migrationBatchDidCommit
        self.legacyDefaults = defaults.value
        self.defaults = PrivateCloudPersistence(
            container: statistics.modelContainer)
    }

    func prepareStorage() async throws {
        guard !storageReady else { return }
        if let storagePreparationTask {
            return try await storagePreparationTask.value
        }
        let task = Task { try await migrateStorage() }
        storagePreparationTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            storagePreparationTask = nil
        } catch {
            storagePreparationTask = nil
            throw error
        }
    }

    func cancelStoragePreparation() { storagePreparationTask?.cancel() }

    private func migrateStorage() async throws {
        if !(try defaults.migrationComplete()) {
            let archived: [String: Data]
            if let value = legacyDefaults.object(forKey: recordSystemFieldsKey)
            {
                guard let values = value as? [String: Data] else {
                    throw PrivateCloudSyncError.storage(.invalidLegacyMetadata)
                }
                archived = values
            } else {
                archived = [:]
            }
            let digests: [String: Data]
            let payloads: [String: Data]
            if let value = legacyDefaults.object(
                forKey: synchronizedPayloadDigestsKey)
            {
                guard let values = value as? [String: Data] else {
                    throw PrivateCloudSyncError.storage(.invalidLegacyState)
                }
                digests = values
            } else {
                digests = [:]
            }
            if let value = legacyDefaults.object(
                forKey: retainedRecordPayloadsKey)
            {
                guard let values = value as? [String: Data] else {
                    throw PrivateCloudSyncError.storage(.invalidLegacyState)
                }
                payloads = values
            } else {
                payloads = [:]
            }
            guard Set(payloads.keys).isSubset(of: Set(archived.keys)),
                Set(digests.keys).isSubset(of: Set(archived.keys))
            else {
                throw PrivateCloudSyncError.storage(.invalidLegacyState)
            }
            let entries = Array(archived).sorted { $0.key < $1.key }
            for offset in stride(from: 0, to: entries.count, by: 200) {
                try Task.checkCancellation()
                let batch = Array(
                    entries[offset..<min(offset + 200, entries.count)]
                ).map { ($0.key, $0.value) }
                try defaults.importBatch(
                    batch, digests: digests, payloads: payloads)
                try defaults.verifyBatch(
                    batch, digests: digests, payloads: payloads)
                if let migrationBatchDidCommit {
                    try await migrationBatchDidCommit(
                        min(offset + 200, entries.count))
                } else {
                    await Task.yield()
                }
            }
            try Task.checkCancellation()
            for key in PrivateCloudPersistence.stateKeys {
                if let value = legacyDefaults.object(forKey: key) {
                    switch key {
                    case PrivateCloudPersistence.engineKey:
                        guard let data = value as? Data,
                            (try? JSONDecoder().decode(
                                CKSyncEngine.State.Serialization.self,
                                from: data)) != nil
                        else {
                            throw PrivateCloudSyncError.storage(
                                .invalidLegacyState)
                        }
                    case pendingConfigurationConflictKey:
                        guard let data = value as? Data,
                            (try? JSONDecoder().decode(
                                CloudConfigurationConflict.self, from: data))
                                != nil
                        else {
                            throw PrivateCloudSyncError.storage(
                                .invalidLegacyState)
                        }
                    case pendingAccountChangesKey:
                        guard let data = value as? Data,
                            (try? JSONDecoder().decode(
                                [CloudServerConfigurationChange].self,
                                from: data)) != nil
                        else {
                            throw PrivateCloudSyncError.storage(
                                .invalidLegacyState)
                        }
                    case legacyAccountIdentityMappingsKey:
                        guard value is [String: String] else {
                            throw PrivateCloudSyncError.storage(
                                .invalidLegacyState)
                        }
                    case pendingLegacyRecordDeletionsKey:
                        guard value is [String: [String]] else {
                            throw PrivateCloudSyncError.storage(
                                .invalidLegacyState)
                        }
                    default:
                        guard value is [String] else {
                            throw PrivateCloudSyncError.storage(
                                .invalidLegacyState)
                        }
                    }
                    try defaults.set(value, forKey: key)
                    guard
                        let stored = try defaults.value(forKey: key)
                            as? NSObject,
                        let original = value as? NSObject,
                        stored.isEqual(original)
                    else {
                        throw PrivateCloudSyncError.storage(
                            .migrationVerificationFailed)
                    }
                }
            }
            if !entries.isEmpty {
                try defaults.set(
                    true, forKey: PrivateCloudPersistence.legacyNoticeNeededKey)
            }
            try defaults.set(true, forKey: PrivateCloudPersistence.migrationKey)
        }
        // Completion is durable before any legacy source is removed; this also
        // resumes cleanup after interruption between individual key removals.
        for key in [
            recordSystemFieldsKey, synchronizedPayloadDigestsKey,
            retainedRecordPayloadsKey,
        ] + PrivateCloudPersistence.stateKeys {
            if legacyDefaults.object(forKey: key) != nil {
                legacyDefaults.removeObject(forKey: key)
            }
        }
        if try defaults.value(
            forKey: PrivateCloudPersistence.legacyNoticeNeededKey) as? Bool
            == true
        {
            CloudStorageUpgradeNotice.detectLegacy(in: legacyDefaults)
        }
        if let value = try defaults.dictionary(
            forKey: legacyAccountIdentityMappingsKey)
        {
            guard let mappings = value as? [String: String] else {
                throw PrivateCloudSyncError.storage(.invalidStoredState)
            }
            legacyAccountIdentityMappings = mappings
        }
        if let value = try defaults.dictionary(
            forKey: pendingLegacyRecordDeletionsKey)
        {
            guard let deletions = value as? [String: [String]] else {
                throw PrivateCloudSyncError.storage(.invalidStoredState)
            }
            pendingLegacyRecordDeletions = deletions.mapValues(Set.init)
        }
        if let data = try defaults.data(forKey: pendingConfigurationConflictKey)
        {
            do {
                pendingConfigurationConflict = try JSONDecoder().decode(
                    CloudConfigurationConflict.self, from: data)
                pendingConfigurationConflictRevision = UUID()
            } catch { throw PrivateCloudSyncError.storage(.invalidStoredState) }
        }
        if let data = try defaults.data(forKey: pendingAccountChangesKey) {
            do {
                let changes = try JSONDecoder().decode(
                    [CloudServerConfigurationChange].self, from: data)
                pendingAccountChanges = Dictionary(grouping: changes, by: \.id)
                    .mapValues {
                        $0.sorted { $0.structuralKey < $1.structuralKey }
                    }
            } catch { throw PrivateCloudSyncError.storage(.invalidStoredState) }
        }
        synchronizedConfigurationData = try defaults.data(
            forKey: synchronizedConfigurationKey)
        if synchronizedConfigurationData == nil,
            let previous = try recordNamed("configuration.singleton"),
            let data = previous[Self.payloadKey] as? Data,
            synchronizedPayloadDigests[previous.recordID.recordName]
                == Self.payloadDigest(data)
        {
            // Recover only an acknowledged payload, never an unsent local edit.
            synchronizedConfigurationData = data
            try defaults.set(data, forKey: synchronizedConfigurationKey)
        }
        if let data = synchronizedConfigurationData {
            do {
                _ = try JSONDecoder().decode(
                    CloudConfigurationSnapshot.self, from: data)
            } catch { throw PrivateCloudSyncError.storage(.invalidStoredState) }
        }
        storageReady = true
    }

    func engineState() async throws -> Data? {
        try await prepareStorage()
        return try defaults.data(forKey: PrivateCloudPersistence.engineKey)
    }
    func clearEngineState() throws {
        try defaults.removeObject(forKey: PrivateCloudPersistence.engineKey)
    }
    func saveEngineState(_ data: Data) throws {
        try defaults.set(data, forKey: PrivateCloudPersistence.engineKey)
    }

    private func cachedRecord(_ id: CKRecord.ID) throws -> CKRecord? {
        if let record = records[id] { return record }
        guard let row = try defaults.metadata(id) else { return nil }
        guard
            let record = PrivateCloudPersistence.decodeSystemFields(
                row.systemFields)
        else {
            throw PrivateCloudSyncError.storage(.invalidLegacyMetadata)
        }
        if let payload = row.retainedPayload {
            record[Self.payloadKey] = payload as CKRecordValue
        }
        if let digest = row.synchronizedDigest {
            synchronizedPayloadDigests[id.recordName] = digest
        }
        records[id] = record
        return record
    }

    private func recordNamed(_ name: String) throws -> CKRecord? {
        if let record = records.values.first(where: {
            $0.recordID.recordName == name
        }) {
            return record
        }
        let context = defaults.context()
        let rows: [PrivateCloudRecordMetadata]
        do {
            rows = try context.fetch(
                FetchDescriptor<PrivateCloudRecordMetadata>(
                    predicate: #Predicate { $0.recordName == name }))
        } catch {
            throw PrivateCloudSyncError.storage(
                .metadataReadFailed(PrivateCloudSystemError(error)))
        }
        guard rows.count <= 1 else { throw PrivateCloudSyncError.invalidRecord }
        guard let row = rows.first else { return nil }
        return try cachedRecord(
            CKRecord.ID(
                recordName: row.recordName,
                zoneID: CKRecordZone.ID(
                    zoneName: row.zoneName, ownerName: row.ownerName)))
    }

    func prepareRecords(
        zoneID: CKRecordZone.ID
    ) async throws -> [CKRecord] {
        try await prepareStorage()
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
        if archive.slices.contains(where: { $0.recordingFormat == nil }) {
            CloudStorageUpgradeNotice.detectLegacy(in: legacyDefaults)
        }
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
            synchronizedRecords.remove(record.recordID)
            dirtyRecords.insert(record.recordID)
        }
        return localRecords.filter(needsUpload)
    }

    func record(for id: CKRecord.ID) throws -> CKRecord? {
        try cachedRecord(id)
    }

    func prepareDeletionChanges(
        zoneID: CKRecordZone.ID
    ) async throws -> [CKSyncEngine.PendingRecordZoneChange] {
        try await prepareStorage()
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
                    let canonicalRecord = try recordNamed(canonicalName),
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
        } catch let error as PrivateCloudSyncError {
            throw error
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
    }

    func apply(
        modifications: [CKDatabase.RecordZoneChange.Modification],
        deletions: [CKDatabase.RecordZoneChange.Deletion],
        checkActive: @Sendable () async throws -> Void = {}
    ) async throws -> [CKSyncEngine.PendingRecordZoneChange] {
        try await prepareStorage()
        try await checkActive()
        let fetchedResult = try await applyFetchedRecordsToleratingFailures(
            modifications.map(\.record),
            persistState: false,
            checkActive: checkActive
        )
        for deletion in deletions {
            try await checkActive()
            records.removeValue(forKey: deletion.recordID)
            deletedRecords.insert(deletion.recordID)
            synchronizedPayloadDigests[deletion.recordID.recordName] = nil
            try await applyDeletion(
                recordID: deletion.recordID,
                recordType: deletion.recordType
            )
        }
        try await checkActive()
        do {
            try await statistics.clearPrivateCloudDeletions(
                recordNames: Set(deletions.map { $0.recordID.recordName })
            )
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        try persistRecordState()
        if let failure = fetchedResult.failure {
            throw failure
        }
        return fetchedResult.pendingChanges
    }

    func applyFetchedRecords(
        _ fetchedRecords: [CKRecord],
        persistState: Bool = true,
        checkActive: @Sendable () async throws -> Void = {}
    ) async throws -> [CKSyncEngine.PendingRecordZoneChange] {
        try await prepareStorage()
        let result = try await applyFetchedRecordsToleratingFailures(
            fetchedRecords,
            persistState: persistState,
            checkActive: checkActive
        )
        if let failure = result.failure {
            throw failure
        }
        return result.pendingChanges
    }

    private func applyFetchedRecordsToleratingFailures(
        _ fetchedRecords: [CKRecord],
        persistState: Bool,
        checkActive: @Sendable () async throws -> Void = {}
    ) async throws -> (
        pendingChanges: [CKSyncEngine.PendingRecordZoneChange],
        failure: PrivateCloudSyncError?
    ) {
        var recordsToApply: [CKRecord] = []
        var pendingChanges: [CKSyncEngine.PendingRecordZoneChange] = []
        try await seedLegacyAccountMappingsFromAliases()
        try learnLegacyAccountMappings(from: fetchedRecords)
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
            try await checkActive()
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
                    previousRecord: try cachedRecord(record.recordID)
                )
                switch resolution {
                case .applyRemote:
                    recordsToApply.append(record)
                    if canonicalization.requiresUpload {
                        records[record.recordID] = record
                        synchronizedRecords.remove(record.recordID)
                        dirtyRecords.insert(record.recordID)
                        pendingChanges.append(.saveRecord(record.recordID))
                        try registerLegacyRecordDeletion(
                            canonicalization.legacyRecordID,
                            afterSaving: record.recordID
                        )
                    }
                case .preserveLocal(let data):
                    record[Self.payloadKey] = data as CKRecordValue
                    records[record.recordID] = record
                    synchronizedRecords.remove(record.recordID)
                    dirtyRecords.insert(record.recordID)
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
                        synchronizedRecords.remove(localRecord.recordID)
                        dirtyRecords.insert(localRecord.recordID)
                        pendingChanges.append(
                            .saveRecord(localRecord.recordID)
                        )
                        try registerLegacyRecordDeletion(
                            canonicalization.legacyRecordID,
                            afterSaving: localRecord.recordID
                        )
                        continue
                    }
                    records[fetchedRecord.recordID] = fetchedRecord
                    synchronizedRecords.remove(fetchedRecord.recordID)
                    dirtyRecords.insert(fetchedRecord.recordID)
                    try appendPendingAccountChange(change)
                    try registerLegacyRecordDeletion(
                        canonicalization.legacyRecordID,
                        afterSaving: record.recordID
                    )
                    markSynchronized(fetchedRecord)
                case .requestConfigurationConfirmation(let conflict):
                    records[record.recordID] = record
                    synchronizedRecords.remove(record.recordID)
                    dirtyRecords.insert(record.recordID)
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
        try await checkActive()
        let application = try await apply(
            recordsToApply,
            checkActive: checkActive
        )
        if firstFailure == nil {
            firstFailure = application.failure
        }
        for record in application.appliedRecords {
            records[record.recordID] = record
            synchronizedRecords.remove(record.recordID)
            dirtyRecords.insert(record.recordID)
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
            try await checkActive()
            try persistRecordState()
        }
        return (pendingChanges, firstFailure)
    }

    /// Applies one fetched record. Persist only changed metadata at this boundary
    /// or at the owning batch boundary when persistence is deferred.
    @discardableResult
    func applyFetchedRecord(
        _ record: CKRecord,
        persistSystemFields: Bool
    ) async throws -> Bool {
        try await prepareStorage()
        try learnLegacyAccountMappings(from: [record])
        let canonicalization = try canonicalizedCloudRecord(record)
        let incomingRecord = canonicalization.record
        let resolution = try await resolveIncomingRecord(
            incomingRecord,
            previousRecord: try cachedRecord(incomingRecord.recordID)
        )
        switch resolution {
        case .applyRemote:
            records[incomingRecord.recordID] = incomingRecord
            synchronizedRecords.remove(incomingRecord.recordID)
            dirtyRecords.insert(incomingRecord.recordID)
            try await apply(incomingRecord)
            if canonicalization.requiresUpload {
                try registerLegacyRecordDeletion(
                    canonicalization.legacyRecordID,
                    afterSaving: incomingRecord.recordID
                )
            } else {
                markSynchronized(incomingRecord)
            }
            if persistSystemFields {
                try persistRecordState()
            }
            return canonicalization.requiresUpload
        case .preserveLocal(let data):
            incomingRecord[Self.payloadKey] = data as CKRecordValue
            records[incomingRecord.recordID] = incomingRecord
            synchronizedRecords.remove(incomingRecord.recordID)
            dirtyRecords.insert(incomingRecord.recordID)
            if persistSystemFields {
                try persistRecordState()
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
                synchronizedRecords.remove(localRecord.recordID)
                dirtyRecords.insert(localRecord.recordID)
                try registerLegacyRecordDeletion(
                    canonicalization.legacyRecordID,
                    afterSaving: localRecord.recordID
                )
                if persistSystemFields {
                    try persistRecordState()
                }
                return true
            }
            records[record.recordID] = record
            synchronizedRecords.remove(record.recordID)
            dirtyRecords.insert(record.recordID)
            try appendPendingAccountChange(change)
            try registerLegacyRecordDeletion(
                canonicalization.legacyRecordID,
                afterSaving: incomingRecord.recordID
            )
            markSynchronized(record)
            if persistSystemFields {
                try persistRecordState()
            }
            return false
        case .requestConfigurationConfirmation(let conflict):
            records[record.recordID] = record
            synchronizedRecords.remove(record.recordID)
            dirtyRecords.insert(record.recordID)
            try setPendingConfigurationConflict(conflict)
            markSynchronized(record)
            if persistSystemFields {
                try persistRecordState()
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
            synchronizedRecords.remove(record.recordID)
            dirtyRecords.insert(record.recordID)
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
            deletedRecords.insert(recordID)
            synchronizedPayloadDigests[recordID.recordName] = nil
        }
        for (id, error) in failedRecordDeletes where error.code == .unknownItem
        {
            records.removeValue(forKey: id)
            deletedRecords.insert(id)
            synchronizedPayloadDigests[id.recordName] = nil
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
                synchronizedRecords.remove(failure.record.recordID)
                dirtyRecords.insert(failure.record.recordID)
                pendingChanges.append(.saveRecord(failure.record.recordID))
            default:
                break
            }
        }
        for (recordID, error) in failedRecordDeletes
        where error.code == .batchRequestFailed {
            pendingChanges.append(.deleteRecord(recordID))
        }
        try persistRecordState()
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
            synchronizedRecords.remove(serverRecord.recordID)
            dirtyRecords.insert(serverRecord.recordID)
            markSynchronized(serverRecord)
            return false
        }
        if local == server {
            records[serverRecord.recordID] = serverRecord
            synchronizedRecords.remove(serverRecord.recordID)
            dirtyRecords.insert(serverRecord.recordID)
            markSynchronized(serverRecord)
            return false
        }
        let explicitlyChosen =
            configurationUploadChoice.map {
                $0.revision == pendingConfigurationConflictRevision
                    && $0.snapshot == client && $0.snapshot == local
            } ?? false
        if pendingConfigurationConflict == nil || explicitlyChosen,
            let baseline = try synchronizedConfiguration(), server == baseline
        {
            do {
                serverRecord[Self.payloadKey] =
                    try Self.encodePayload(local) as CKRecordValue
            } catch { throw PrivateCloudSyncError.persistenceFailed }
            records[serverRecord.recordID] = serverRecord
            synchronizedRecords.remove(serverRecord.recordID)
            dirtyRecords.insert(serverRecord.recordID)
            return true
        }
        if pendingConfigurationConflict == nil,
            let baseline = try synchronizedConfiguration(), local == baseline
        {
            try await configuration.apply(server)
            records[serverRecord.recordID] = serverRecord
            synchronizedRecords.remove(serverRecord.recordID)
            dirtyRecords.insert(serverRecord.recordID)
            markSynchronized(serverRecord)
            return false
        }
        let conflict = CloudConfigurationConflict(local: local, iCloud: server)
        records[serverRecord.recordID] = serverRecord
        synchronizedRecords.remove(serverRecord.recordID)
        dirtyRecords.insert(serverRecord.recordID)
        try setPendingConfigurationConflict(conflict)
        markSynchronized(serverRecord)
        return false
    }

    func prepareAccountRecord(
        _ account: ServerAccount,
        zoneID: CKRecordZone.ID
    ) throws -> CKRecord {
        let record = try accountRecord(
            account,
            zoneID: zoneID,
            forceNewGeneration: true
        )
        var updated = pendingAccountChanges
        updated[account.id] = nil
        try persistPendingAccountChanges(updated)
        records[record.recordID] = record
        synchronizedRecords.remove(record.recordID)
        dirtyRecords.insert(record.recordID)
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
        _ change: CloudServerConfigurationChange
    ) throws {
        var candidates = pendingAccountChanges[change.id] ?? []
        guard
            !candidates.contains(where: {
                $0.incoming == change.incoming
            })
        else { return }
        candidates.append(change)
        candidates.sort { $0.structuralKey < $1.structuralKey }
        var updated = pendingAccountChanges
        updated[change.id] = candidates
        try persistPendingAccountChanges(updated)
    }

    private func persistPendingAccountChanges(
        _ updated: [AccountID: [CloudServerConfigurationChange]]
    ) throws {
        let changes = updated.values.flatMap { $0 }.sorted {
            $0.structuralKey < $1.structuralKey
        }
        let data: Data
        do { data = try JSONEncoder().encode(changes) } catch {
            throw PrivateCloudSyncError.storage(
                .stateWriteFailed(PrivateCloudSystemError(error)))
        }
        try defaults.set(data, forKey: pendingAccountChangesKey)
        pendingAccountChanges = updated
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
        guard let record = try recordNamed("configuration.singleton") else {
            throw PrivateCloudSyncError.invalidRecord
        }
        switch resolution {
        case .keepThisDevice:
            guard let revision = pendingConfigurationConflictRevision else {
                throw PrivateCloudSyncError.invalidRecord
            }
            let local = await configuration.snapshot()
            guard revision == pendingConfigurationConflictRevision else {
                throw PrivateCloudSyncError.configurationSelectionChanged
            }
            do {
                record[Self.payloadKey] =
                    try Self.encodePayload(local) as CKRecordValue
            } catch {
                throw PrivateCloudSyncError.persistenceFailed
            }
            records[record.recordID] = record
            synchronizedRecords.remove(record.recordID)
            dirtyRecords.insert(record.recordID)
            configurationUploadChoice = (revision, local)
            return record
        case .useICloud:
            let revision = pendingConfigurationConflictRevision
            do {
                try await configuration.apply(conflict.iCloud)
            } catch let error as PrivateCloudSyncError {
                throw error
            } catch {
                throw PrivateCloudSyncError.persistenceFailed
            }
            try completeCloudConfigurationSelection(
                revision: revision, snapshot: conflict.iCloud)
            return nil
        }
    }

    // Called after the configuration actor hop. A newer conflict owns its
    // baseline and prompt even if an older selection has finished applying.
    func completeCloudConfigurationSelection(
        revision: UUID?, snapshot: CloudConfigurationSnapshot
    ) throws {
        guard pendingConfigurationConflictRevision == revision else {
            throw PrivateCloudSyncError.configurationSelectionChanged
        }
        let data = try Self.encodePayload(snapshot)
        try defaults.set(data, forKey: synchronizedConfigurationKey)
        synchronizedConfigurationData = data
        try clearPendingConfigurationConflict()
    }

    func completeConfigurationConflictResolution(
        revision: UUID
    ) throws {
        guard pendingConfigurationConflictRevision == revision else {
            return
        }
        try clearPendingConfigurationConflict()
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
        var updated = pendingAccountChanges
        updated[accountID] = nil
        try persistPendingAccountChanges(updated)
        do {
            if change.current == nil {
                try await accounts.savePendingRestoredAccount(
                    change.incoming
                )
            } else {
                try await accounts.save(change.incoming)
            }
        } catch {
            var restored = pendingAccountChanges
            restored[accountID] = candidates
            try persistPendingAccountChanges(restored)
            throw PrivateCloudSyncError.persistenceFailed
        }
        do {
            return try prepareAccountRecord(change.incoming, zoneID: zoneID)
        } catch {
            throw PrivateCloudSyncFailure(
                operation: .resolveServerConfiguration,
                cause: PrivateCloudSyncCoordinator.mappedFailure(
                    operation: .resolveServerConfiguration,
                    error: error
                ).cause,
                selectionCommitted: true
            )
        }
    }

    func rejectServerConfigurationChange(
        accountID: AccountID,
        zoneID: CKRecordZone.ID
    ) async throws -> CKRecord? {
        guard
            let candidates = pendingAccountChanges[accountID],
            let change = candidates.first
        else {
            return nil
        }
        guard let current = change.current else {
            var ignored = try ignoredAccountIDs()
            ignored.insert(accountID.rawValue)
            try defaults.set(
                Array(ignored).sorted(),
                forKey: ignoredAccountsKey
            )
            var updated = pendingAccountChanges
            updated[accountID] = nil
            try persistPendingAccountChanges(updated)
            return nil
        }
        return try prepareAccountRecord(current, zoneID: zoneID)
    }

    func allRecordIDs() throws -> [CKRecord.ID] {
        Array(Set(try defaults.recordIDs()).union(records.keys))
    }

    func removeAllRecords() async throws {
        do {
            try await statistics.resetPrivateCloudSynchronizationState()
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        try defaults.removeMetadata()
        for key in [
            pendingConfigurationConflictKey, recordSystemFieldsKey,
            synchronizedPayloadDigestsKey, retainedRecordPayloadsKey,
            synchronizedConfigurationKey,
            PrivateCloudPersistence.engineKey,
        ] {
            legacyDefaults.removeObject(forKey: key)
            try defaults.removeObject(forKey: key)
        }
        pendingConfigurationConflict = nil
        pendingConfigurationConflictRevision = nil
        pendingConfigurationConflictIsInvalid = false
        try await prepareStorage()
        records.removeAll()
        dirtyRecords.removeAll()
        deletedRecords.removeAll()
        synchronizedPayloadDigests.removeAll()
        synchronizedConfigurationData = nil
        if pendingConfigurationConflictIsInvalid {
            try clearPendingConfigurationConflict()
        }
    }

    func ignoreAccountOnThisDevice(
        _ accountID: AccountID,
        includeStatistics: Bool
    ) throws {
        var ignored = try ignoredAccountIDs()
        ignored.insert(accountID.rawValue)
        try defaults.set(Array(ignored).sorted(), forKey: ignoredAccountsKey)
        if includeStatistics {
            var ignoredStatistics = try ignoredStatisticsAccountIDs()
            ignoredStatistics.insert(accountID.rawValue)
            try defaults.set(
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
        try await prepareStorage()
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
            try defaults.recordIDs(
                accountID: accountID, includeStatistics: includeStatistics))
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
            try cachedRecord(recordID)
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
            try cachedRecord(recordID)
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
        _ recordsToApply: [CKRecord],
        checkActive: @Sendable () async throws -> Void = {}
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
        let ignoredStatisticsAccounts = try ignoredStatisticsAccountIDs()
        let ignoredAccounts = try ignoredAccountIDs()
        for record in recordsToApply {
            try await checkActive()
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
                    guard value.recordingState != .active else {
                        throw PrivateCloudSyncError.invalidRecord
                    }
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
        try await checkActive()
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
                try await checkActive()
                try await statistics.markPrivateCloudArchiveSynchronized(
                    archive
                )
            }
            for account in accountsToSave {
                try await checkActive()
                try await accounts.save(account)
            }
            for snapshot in configurations {
                try await checkActive()
                try await configuration.apply(snapshot)
            }
        } catch let error as PrivateCloudSyncError {
            throw error
        } catch {
            throw PrivateCloudSyncError.invalidRecord
        }
        if slices.contains(where: { $0.recordingFormat == nil }) {
            CloudStorageUpgradeNotice.detectLegacy(in: legacyDefaults)
        }
        return (appliedRecords, firstFailure)
    }

    private func learnLegacyAccountMappings(from cloudRecords: [CKRecord])
        throws
    {
        var updated = legacyAccountIdentityMappings
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
                if updated[legacyID.rawValue]
                    != canonicalID.rawValue
                {
                    updated[legacyID.rawValue] =
                        canonicalID.rawValue
                    changed = true
                }
            }
        }
        guard changed else { return }
        try defaults.set(
            updated,
            forKey: legacyAccountIdentityMappingsKey
        )
        legacyAccountIdentityMappings = updated
    }

    private func seedLegacyAccountMappingsFromAliases() async throws {
        let aliases: [AccountIdentityMigration]
        do {
            aliases = try await accounts.identityAliases()
        } catch {
            throw PrivateCloudSyncError.persistenceFailed
        }
        var updated = legacyAccountIdentityMappings
        var changed = false
        for alias in aliases {
            if let existing = updated[
                alias.legacyID.rawValue
            ], existing != alias.canonicalID.rawValue {
                throw PrivateCloudSyncError.invalidRecord
            }
            if updated[alias.legacyID.rawValue] == nil {
                updated[alias.legacyID.rawValue] =
                    alias.canonicalID.rawValue
                changed = true
            }
        }
        guard changed else { return }
        try defaults.set(
            updated,
            forKey: legacyAccountIdentityMappingsKey
        )
        legacyAccountIdentityMappings = updated
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
                try cachedRecord(canonicalIDValue)
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
                try cachedRecord(canonicalIDValue)
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
    ) throws {
        guard let legacyRecordID,
            legacyRecordID != canonicalRecordID
        else {
            return
        }
        pendingLegacyRecordDeletions[
            canonicalRecordID.recordName,
            default: []
        ].insert(legacyRecordID.recordName)
        try persistPendingLegacyRecordDeletions()
    }

    private func persistPendingLegacyRecordDeletions() throws {
        try defaults.set(
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
                if try ignoredAccountIDs().contains(incoming.id.rawValue) {
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
                let incoming = try JSONDecoder().decode(
                    CloudConfigurationSnapshot.self,
                    from: incomingData
                )
                let local = await configuration.snapshot()
                if pendingConfigurationConflict == nil, local != incoming {
                    if let baseline = try synchronizedConfiguration() {
                        if incoming == baseline {
                            return .preserveLocal(try Self.encodePayload(local))
                        }
                        if local == baseline { return .applyRemote }
                    } else if previousRecord == nil {
                        return .applyRemote
                    }
                    return .requestConfigurationConfirmation(
                        CloudConfigurationConflict(
                            local: local, iCloud: incoming))
                }
                guard local != incoming else {
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

    private func ignoredAccountIDs() throws -> Set<String> {
        Set(try defaults.stringArray(forKey: ignoredAccountsKey) ?? [])
    }

    private func ignoredStatisticsAccountIDs() throws -> Set<String> {
        Set(try defaults.stringArray(forKey: ignoredStatisticsKey) ?? [])
    }

    private func needsUpload(_ record: CKRecord) -> Bool {
        guard let data = record[Self.payloadKey] as? Data else {
            return true
        }
        return synchronizedPayloadDigests[record.recordID.recordName]
            != Self.payloadDigest(data)
    }

    private func markSynchronized(_ record: CKRecord) {
        synchronizedRecords.insert(record.recordID)
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
        if record.recordType == "Configuration" {
            synchronizedConfigurationData = data
        }
        synchronizedPayloadDigests[record.recordID.recordName] =
            Self.payloadDigest(data)
    }

    private func persistRecordState() throws {
        if let data = synchronizedConfigurationData {
            try defaults.set(data, forKey: synchronizedConfigurationKey)
        }
        try persistPendingLegacyRecordDeletions()
        try defaults.commit(
            records: dirtyRecords.compactMap { records[$0] },
            deleted: deletedRecords, digests: synchronizedPayloadDigests,
            retainingPayloadFor: dirtyRecords.subtracting(synchronizedRecords))
        lastCommittedMetadataCount = dirtyRecords.count + deletedRecords.count
        synchronizedRecords.removeAll()
        dirtyRecords.removeAll()
        deletedRecords.removeAll()
        records.removeAll()
        synchronizedPayloadDigests.removeAll()
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
            try defaults.set(
                try JSONEncoder().encode(conflict),
                forKey: pendingConfigurationConflictKey
            )
            pendingConfigurationConflict = conflict
            pendingConfigurationConflictRevision = UUID()
            configurationUploadChoice = nil
        } catch let error as PrivateCloudSyncError {
            throw error
        } catch {
            throw PrivateCloudSyncError.storage(
                .stateWriteFailed(PrivateCloudSystemError(error)))
        }
    }

    private func synchronizedConfiguration() throws
        -> CloudConfigurationSnapshot?
    {
        guard let data = synchronizedConfigurationData else { return nil }
        do {
            return try JSONDecoder().decode(
                CloudConfigurationSnapshot.self, from: data)
        } catch { throw PrivateCloudSyncError.storage(.invalidStoredState) }
    }

    private func clearPendingConfigurationConflict() throws {
        try defaults.removeObject(forKey: pendingConfigurationConflictKey)
        pendingConfigurationConflict = nil
        pendingConfigurationConflictRevision = nil
        configurationUploadChoice = nil
        pendingConfigurationConflictIsInvalid = false
    }

}

/// One visible result may finish before CloudKit has drained. The run remains
/// owned by the lifecycle until its underlying operation and delegate return.
actor PrivateCloudSyncRun {
    private var reported: Result<Void, PrivateCloudSyncFailure>?
    private var resultWaiter:
        CheckedContinuation<Result<Void, PrivateCloudSyncFailure>, Never>?
    private var drained = false
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var callbackWaiters: [CheckedContinuation<Void, Never>] = []
    private var callbackFailure: PrivateCloudSyncFailure?
    private var foreground = true
    private var callbacks:
        [UUID: (elapsed: Duration, since: ContinuousClock.Instant?)] = [:]
    private var watchdogs: [UUID: Task<Void, Never>] = [:]
    private var cancellationTask: Task<Void, Never>?
    private let deadline: Duration
    private let currentInstant: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (Duration) async throws -> Void

    init(
        deadline: Duration = .seconds(60),
        currentInstant: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock.now
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.deadline = deadline
        self.currentInstant = currentInstant
        self.sleep = sleep
    }

    func waitForResult() async -> Result<Void, PrivateCloudSyncFailure> {
        if let reported { return reported }
        return await withCheckedContinuation { resultWaiter = $0 }
    }

    func waitForDrain() async {
        if drained { return }
        await withCheckedContinuation { drainWaiters.append($0) }
    }

    func setForeground(_ foreground: Bool) {
        guard self.foreground != foreground else { return }
        let now = currentInstant()
        for (id, value) in callbacks {
            let elapsed =
                value.elapsed
                + (value.since.map { $0.duration(to: now) } ?? .zero)
            callbacks[id] = (elapsed, foreground ? now : nil)
        }
        self.foreground = foreground
    }

    func beginCallback(
        cancelOperations: @escaping @Sendable () async -> Void
    ) -> UUID {
        let id = UUID()
        callbacks[id] = (.zero, foreground ? currentInstant() : nil)
        watchdogs[id] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard let delay = await self.watchdogDelay(for: id) else {
                    return
                }
                do { try await self.sleep(delay) } catch { return }
                if await self.checkDeadline(for: id) {
                    await self.requestCancellation(cancelOperations)
                    return
                }
            }
        }
        return id
    }

    func endCallback(_ id: UUID) {
        callbacks[id] = nil
        watchdogs.removeValue(forKey: id)?.cancel()
        if callbacks.isEmpty {
            for waiter in callbackWaiters { waiter.resume() }
            callbackWaiters.removeAll()
        }
    }

    func waitForCallbacks() async {
        if callbacks.isEmpty { return }
        await withCheckedContinuation { callbackWaiters.append($0) }
    }

    func requestCancellation(
        _ cancelOperations: @escaping @Sendable () async -> Void
    ) {
        guard cancellationTask == nil else { return }
        // CloudKit marks delegate execution with task-local state. A child
        // Task inherits it and cancelOperations traps in that context. Do not
        // await cancellation from the delegate, which must return first.
        cancellationTask = Task.detached {
            await cancelOperations()
        }
    }

    func waitForCancellation() async {
        await cancellationTask?.value
    }

    func checkDeadline(for id: UUID) -> Bool {
        guard let callback = callbacks[id], callbackFailure == nil else {
            return false
        }
        let elapsed =
            callback.elapsed
            + (callback.since.map { $0.duration(to: currentInstant()) } ?? .zero)
        guard elapsed >= deadline else { return false }
        failCallback(
            PrivateCloudSyncFailure(
                operation: .applyFetchedChanges,
                cause: .callbackTimedOut
            )
        )
        return true
    }

    func checkCallback(_ id: UUID) throws(PrivateCloudSyncError) {
        if let callbackFailure { throw callbackFailure.cause }
        guard callbacks[id] != nil else { return }
        callbacks[id] = (.zero, foreground ? currentInstant() : nil)
    }

    func failure() -> PrivateCloudSyncFailure? { callbackFailure }

    private func watchdogDelay(for id: UUID) -> Duration? {
        guard let callback = callbacks[id], callbackFailure == nil else {
            return nil
        }
        guard foreground else { return .seconds(1) }
        let elapsed =
            callback.elapsed
            + (callback.since.map { $0.duration(to: currentInstant()) } ?? .zero)
        let remaining = deadline - elapsed
        return remaining > .zero
            ? min(remaining, .seconds(1)) : .milliseconds(1)
    }

    func failCallback(_ failure: PrivateCloudSyncFailure) {
        guard callbackFailure == nil else { return }
        callbackFailure = failure
        report(.failure(failure))
    }

    func complete(_ result: Result<Void, PrivateCloudSyncFailure>) {
        if let callbackFailure {
            report(.failure(callbackFailure))
        } else {
            report(result)
        }
        drained = true
        for waiter in drainWaiters { waiter.resume() }
        drainWaiters.removeAll()
        for task in watchdogs.values { task.cancel() }
        watchdogs.removeAll()
    }

    private func report(_ result: Result<Void, PrivateCloudSyncFailure>) {
        guard reported == nil else { return }
        reported = result
        resultWaiter?.resume(returning: result)
        resultWaiter = nil
    }
}

actor PrivateCloudSyncLifecycle {
    private var run: PrivateCloudSyncRun?
    private var foreground = true

    func begin(
        deadline: Duration = .seconds(60),
        currentInstant: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock.now
        },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) async throws(PrivateCloudSyncError) -> PrivateCloudSyncRun {
        guard run == nil else { throw .stopping }
        let next = PrivateCloudSyncRun(
            deadline: deadline,
            currentInstant: currentInstant,
            sleep: sleep
        )
        await next.setForeground(foreground)
        run = next
        return next
    }

    func current() -> PrivateCloudSyncRun? { run }

    func setForeground(_ foreground: Bool) async {
        self.foreground = foreground
        await run?.setForeground(foreground)
    }

    func finish(_ finished: PrivateCloudSyncRun) {
        if run === finished { run = nil }
    }

    func waitForDrain() async {
        await run?.waitForDrain()
    }
}

public actor PrivateCloudSyncCoordinator:
    CKSyncEngineDelegate
{
    public static let containerIdentifier =
        "iCloud.com.terminaloutcomes.Bleat"

    private let store: PrivateCloudSyncStore
    private let defaults: UserDefaults
    private let eventRecorder: any PrivateCloudSyncEventRecording
    private let configurationFailure: PrivateCloudSyncError?
    private let container: CKContainer
    private let enabledKey = "bleat.cloudKit.enabled.v1"
    private let zoneID = CKRecordZone.ID(
        zoneName: PrivateCloudSyncStore.zoneName,
        ownerName: CKCurrentUserDefaultName
    )
    private var engine: CKSyncEngine?
    private let lifecycle = PrivateCloudSyncLifecycle()

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
        self.container = container
        self.eventRecorder = eventRecorder
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
        engine = nil
    }

    private func makeEngine(
        database: CKDatabase,
        serialization: CKSyncEngine.State.Serialization?
    ) -> CKSyncEngine {
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: serialization,
            delegate: self
        )
        configuration.automaticallySync = false
        configuration.subscriptionID = "bleat-private-sync-v1"
        return CKSyncEngine(configuration)
    }

    static func configurationFailure(
        for databaseScope: CKDatabase.Scope
    ) -> PrivateCloudSyncError? {
        databaseScope == .private ? nil : .nonPrivateDatabase
    }

    private func configuredEngine() async throws(PrivateCloudSyncError)
        -> CKSyncEngine
    {
        if let configurationFailure {
            throw configurationFailure
        }
        if let engine { return engine }
        let serialization: CKSyncEngine.State.Serialization?
        do {
            if let data = try await store.engineState() {
                serialization = try JSONDecoder().decode(
                    CKSyncEngine.State.Serialization.self, from: data)
            } else {
                serialization = nil
            }
        } catch let error as PrivateCloudSyncError { throw error } catch {
            throw .storage(.invalidStoredState)
        }
        // Actor reentrancy permits another caller to initialize while awaiting storage.
        if let engine { return engine }
        let newEngine = makeEngine(
            database: container.privateCloudDatabase,
            serialization: serialization)
        engine = newEngine
        return newEngine
    }

    public var isEnabled: Bool {
        defaults.object(forKey: enabledKey) == nil
            ? true
            : defaults.bool(forKey: enabledKey)
    }

    public func synchronize() async throws(PrivateCloudSyncFailure) {
        let run: PrivateCloudSyncRun
        do {
            run = try await lifecycle.begin()
        } catch {
            throw PrivateCloudSyncFailure(
                operation: .synchronize,
                cause: error
            )
        }
        Task { [self] in
            let result: Result<Void, PrivateCloudSyncFailure>
            do {
                try await synchronizeOnce(run: run)
                result = .success(())
            } catch let failure as PrivateCloudSyncFailure {
                result = .failure(failure)
            } catch {
                result = .failure(
                    Self.mappedFailure(
                        operation: .synchronize,
                        error: error
                    ))
            }
            await run.waitForCallbacks()
            await run.waitForCancellation()
            await lifecycle.finish(run)
            await run.complete(result)
        }
        switch await run.waitForResult() {
        case .success: return
        case .failure(let failure): throw failure
        }
    }

    public func setForeground(_ foreground: Bool) async {
        await lifecycle.setForeground(foreground)
    }

    public func waitForSynchronizationDrain() async {
        await lifecycle.waitForDrain()
    }

    private func synchronizeOnce(
        run: PrivateCloudSyncRun
    ) async throws(PrivateCloudSyncFailure) {
        try await perform(.synchronize) {
            guard isEnabled else {
                throw PrivateCloudSyncError.disabled
            }
            try await perform(.migrateLocalState) {
                try await store.prepareStorage()
            }
            if let failure = await run.failure() { throw failure }
            guard isEnabled else { throw PrivateCloudSyncError.disabled }
            let engine = try await configuredEngine()
            try await perform(.setupZone) {
                engine.state.add(
                    pendingDatabaseChanges: [
                        .saveZone(CKRecordZone(zoneID: zoneID))
                    ]
                )
                try await engine.sendChanges()
            }
            do {
                try await perform(.fetchChanges) {
                    try await engine.fetchChanges(
                        CKSyncEngine.FetchChangesOptions(
                            scope: .zoneIDs([zoneID])
                        )
                    )
                    if let failure = await run.failure() { throw failure }
                }
            } catch {
                if let failure = await run.failure() { throw failure }
                throw error
            }
            await run.waitForCallbacks()
            if let failure = await run.failure() { throw failure }
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
        await store.cancelStoragePreparation()
        if let run = await lifecycle.current() {
            await run.failCallback(
                PrivateCloudSyncFailure(operation: .cancel, cause: .cancelled))
            await run.requestCancellation { [self] in
                await engine?.cancelOperations()
            }
            await run.waitForCancellation()
        } else {
            await engine?.cancelOperations()
        }

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
            let engine = try await configuredEngine()
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
            let engine = try await configuredEngine()
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
            engine.state.add(
                pendingRecordZoneChanges: [.saveRecord(record.recordID)]
            )
            try await sendRecordChanges(
                engine: engine,
                CKSyncEngine.SendChangesOptions(
                    scope: .recordIDs([record.recordID])
                )
            )
            try await store.completeConfigurationConflictResolution(
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
            let engine = try await configuredEngine()
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
            do {
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
            } catch {
                let failure = Self.mappedFailure(
                    operation: .resolveServerConfiguration,
                    error: error
                )
                throw PrivateCloudSyncFailure(
                    operation: failure.operation,
                    cause: failure.cause,
                    selectionCommitted: accept
                )
            }
        }
    }

    public func setEnabled(
        _ enabled: Bool,
        deleteCloudData: Bool
    ) async throws(PrivateCloudSyncFailure) {
        if enabled {
            try await perform(.enable) {
                _ = try await configuredEngine()
                defaults.set(true, forKey: enabledKey)
                do {
                    try await synchronize()
                } catch let failure as PrivateCloudSyncFailure {
                    throw failure.cause
                }
            }
            return
        }

        try await perform(deleteCloudData ? .deleteCloudData : .disable) {
            // Persist opt-out before cancellation or deletion can suspend or
            // fail, so foreground sync cannot repopulate the cleared zone.
            defaults.set(false, forKey: enabledKey)
            await cancelSynchronization()
            if deleteCloudData {
                if let configurationFailure { throw configurationFailure }
                await lifecycle.waitForDrain()
                let database = container.privateCloudDatabase
                do {
                    // Delete the entire app-owned zone directly. Sending the
                    // sync engine's queue could also upload pending records.
                    _ = try await database.deleteRecordZone(withID: zoneID)
                } catch let error as CKError where error.code == .zoneNotFound {
                    // An already absent zone has the requested empty state.
                }
                try await store.removeAllRecords()
                try await store.clearEngineState()
                self.engine = makeEngine(database: database, serialization: nil)
            } else {
                // Local opt-out must remain available when a source or
                // entitlement bug prevented the CloudKit engine from being
                // created. No database access is needed to retain cloud data.
                await engine?.cancelOperations()
            }
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
            let engine = try await configuredEngine()
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
    ) async throws(PrivateCloudSyncFailure) {
        do {
            try await store.prepareStorage()
            try await store.ignoreAccountOnThisDevice(
                accountID, includeStatistics: includeStatistics)
        } catch {
            throw Self.mappedFailure(operation: .deleteAccount, error: error)
        }
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
                try await store.saveEngineState(data)
                await recordCompletion(
                    operation: .persistEngineState,
                    correlationID: correlationID,
                    startedAt: startedAt
                )
            } catch {
                await recordFailure(
                    Self.mappedFailure(
                        operation: .persistEngineState,
                        error: error
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
            let run = await lifecycle.current()
            let cancelAfterTimeout: @Sendable () async -> Void = {
                await self.recordFailure(
                    PrivateCloudSyncFailure(
                        operation: .applyFetchedChanges,
                        cause: .callbackTimedOut
                    ),
                    correlationID: correlationID,
                    startedAt: startedAt,
                    recordCount: recordCount
                )
                await syncEngine.cancelOperations()
            }
            let callbackID = await run?.beginCallback(
                cancelOperations: cancelAfterTimeout
            )
            do {
                let pendingChanges = try await store.apply(
                    modifications: changes.modifications,
                    deletions: changes.deletions,
                    checkActive: {
                        if let callbackID {
                            try await run?.checkCallback(callbackID)
                        }
                    }
                )
                if let callbackID {
                    try await run?.checkCallback(callbackID)
                }
                syncEngine.state.add(
                    pendingRecordZoneChanges: pendingChanges
                )
                if let callbackID { await run?.endCallback(callbackID) }
                await recordCompletion(
                    operation: .applyFetchedChanges,
                    correlationID: correlationID,
                    startedAt: startedAt,
                    recordCount: recordCount
                )
            } catch {
                let failure = Self.mappedFailure(
                    operation: .applyFetchedChanges,
                    error: error
                )
                await run?.failCallback(failure)
                if failure.cause == .callbackTimedOut {
                    await run?.requestCancellation(cancelAfterTimeout)
                } else {
                    await recordFailure(
                        failure,
                        correlationID: correlationID,
                        startedAt: startedAt,
                        recordCount: recordCount
                    )
                    if let run {
                        await run.requestCancellation {
                            await syncEngine.cancelOperations()
                        }
                    } else {
                        Task.detached {
                            await syncEngine.cancelOperations()
                        }
                    }
                }
                if let callbackID { await run?.endCallback(callbackID) }
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
        if let error = error as? PrivateCloudSyncError {
            cause = error
        } else if let error = error as? CKError {
            cause =
                error.code == .operationCancelled
                ? .cancelled
                : .cloudKit(CloudKitFailure(error))
        } else if Task.isCancelled || error is CancellationError {
            cause = .cancelled
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
                failure,
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
                do { return try await store.record(for: recordID) } catch {
                    let failure = Self.mappedFailure(
                        operation: .prepareLocalChanges, error: error)
                    await self.lifecycle.current()?.failCallback(failure)
                    await self.recordFailure(
                        failure, correlationID: UUID(), startedAt: .now)
                    return nil
                }
            }
        )
    }
}
