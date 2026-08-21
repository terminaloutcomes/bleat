import CloudKit
import Foundation
import SwiftData
import XCTest
@testable import BleatCore

final class PrivateCloudSyncTests: XCTestCase {
    func testCloudKitFailurePreservesExactCodeRetryAndPartialCodes() {
        let error = CKError(
            .partialFailure,
            userInfo: [
                CKErrorRetryAfterKey: 2.5,
                CKPartialErrorsByItemIDKey: [
                    "first": CKError(.networkFailure),
                    "second": CKError(.permissionFailure),
                    "duplicate": CKError(.networkFailure),
                ],
            ]
        )

        let failure = CloudKitFailure(error)

        XCTAssertEqual(failure.code, .partialFailure)
        XCTAssertEqual(
            failure.partialFailureCodes,
            [.networkFailure, .permissionFailure]
        )
        XCTAssertEqual(failure.retryAfterSeconds, 2.5)
        XCTAssertTrue(failure.isRetryable)
    }

    func testOnlyConflictPartialFailureAllowsOneReconciliationRetry() {
        let conflict = CloudKitFailure(
            CKError(
                .partialFailure,
                userInfo: [
                    CKPartialErrorsByItemIDKey: [
                        "record": CKError(.serverRecordChanged),
                        "batch": CKError(.batchRequestFailed),
                    ]
                ]
            )
        )
        let mixed = CloudKitFailure(
            CKError(
                .partialFailure,
                userInfo: [
                    CKPartialErrorsByItemIDKey: [
                        "record": CKError(.serverRecordChanged),
                        "permission": CKError(.permissionFailure),
                    ]
                ]
            )
        )

        XCTAssertTrue(conflict.canRetryAfterConflictReconciliation)
        XCTAssertFalse(mixed.canRetryAfterConflictReconciliation)
        XCTAssertEqual(
            conflict.sendRecovery(
                hasPendingConfigurationConflict: true,
                attempt: 0
            ),
            .awaitUserResolution
        )
        XCTAssertEqual(
            conflict.sendRecovery(
                hasPendingConfigurationConflict: false,
                attempt: 0
            ),
            .retry
        )
        XCTAssertEqual(
            conflict.sendRecovery(
                hasPendingConfigurationConflict: false,
                attempt: 1
            ),
            .fail
        )
        XCTAssertEqual(
            mixed.sendRecovery(
                hasPendingConfigurationConflict: true,
                attempt: 0
            ),
            .fail
        )
    }

    func testCloudKitDiagnosticIncludesOperationAndTypedFailureDetails() {
        let correlationID = UUID()
        let failure = PrivateCloudSyncFailure(
            operation: .applyFetchedChanges,
            cause: .cloudKit(
                CloudKitFailure(
                    CKError(
                        .requestRateLimited,
                        userInfo: [CKErrorRetryAfterKey: 1.25]
                    )
                )
            )
        )

        let event = DiagnosticEvent.privateCloudFailed(
            failure: failure,
            correlationID: correlationID,
            durationMilliseconds: 17
        )

        XCTAssertEqual(event.operation, .privateCloudSync)
        XCTAssertEqual(event.failureCode, .privateCloudKitFailed)
        XCTAssertEqual(event.privateCloud?.operation, .applyFetchedChanges)
        XCTAssertEqual(
            event.privateCloud?.cloudKitCode,
            "request_rate_limited"
        )
        XCTAssertEqual(event.privateCloud?.retryAfterMilliseconds, 1_250)
        XCTAssertTrue(
            event.text.contains("cloud_operation=apply_fetched_changes")
        )
        XCTAssertTrue(
            event.text.contains("cloudkit_code=request_rate_limited")
        )
        XCTAssertFalse(event.text.contains("localizedDescription"))
    }

    func testConfigurationSnapshotDefaultsHeadphoneCommands() async throws {
        let suite = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let store = try makeStore(suite: suite)

        let snapshot = await store.snapshot()

        XCTAssertEqual(snapshot.previousCommandAction, .skipBackward)
        XCTAssertEqual(snapshot.nextCommandAction, .skipForward)
    }

    func testConfigurationSnapshotRoundTripsHeadphoneCommands() async throws {
        let sourceSuite = makeSuite()
        let targetSuite = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: sourceSuite)
            UserDefaults.standard.removePersistentDomain(forName: targetSuite)
        }
        let source = try makeStore(suite: sourceSuite)
        let target = try makeStore(suite: targetSuite)
        try await source.apply(
            makeSnapshot(
                previousCommandAction: .previousChapter,
                nextCommandAction: .nextChapter
            )
        )

        let snapshot = await source.snapshot()
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(
            CloudConfigurationSnapshot.self,
            from: encoded
        )
        try await target.apply(decoded)
        let restored = await target.snapshot()

        XCTAssertEqual(restored.previousCommandAction, .previousChapter)
        XCTAssertEqual(restored.nextCommandAction, .nextChapter)
    }

    func testLegacyConfigurationDefaultsMissingHeadphoneCommands() throws {
        let legacy = LegacyCloudConfigurationSnapshot(
            defaultPlaybackRate: 1.25,
            resumeRewindSeconds: 10,
            skipBackwardSeconds: 15,
            skipForwardSeconds: 30,
            downloadNetworkPolicy: "wifiOnly",
            automaticDownloadLookahead: 5,
            automaticDownloadCleanupPolicy: "afterTwentyFourHours"
        )

        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(
            CloudConfigurationSnapshot.self,
            from: data
        )

        XCTAssertEqual(decoded.previousCommandAction, .skipBackward)
        XCTAssertEqual(decoded.nextCommandAction, .skipForward)
    }

    func testConfigurationRejectsInvalidHeadphoneCommand() throws {
        let invalid = InvalidCloudConfigurationSnapshot(
            defaultPlaybackRate: 1,
            resumeRewindSeconds: 10,
            skipBackwardSeconds: 15,
            skipForwardSeconds: 30,
            previousCommandAction: "invalid",
            nextCommandAction: "skipForward",
            downloadNetworkPolicy: "wifiOnly",
            automaticDownloadLookahead: 5,
            automaticDownloadCleanupPolicy: "afterTwentyFourHours"
        )
        let data = try JSONEncoder().encode(invalid)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: data
            )
        )
    }

    func testRejectingFetchedAccountChangePreservesAndReturnsLocalEdit()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let original = try makeAccount(
            server: "https://remote.example",
            localServer: nil
        )
        try await fixture.accounts.save(original)
        let records = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let cloudAccountRecord = try XCTUnwrap(
            records.first { $0.recordType == "ServerAccount" }
        )

        let edited = try makeAccount(
            server: "https://primary.example",
            localServer: "https://local.example"
        )
        try await fixture.accounts.save(edited)
        try await fixture.store.applyFetchedRecord(cloudAccountRecord)

        let preserved = try await fixture.accounts.account(id: edited.id)
        let pending = await fixture.store
            .pendingServerConfigurationChanges()
        XCTAssertEqual(preserved, edited)
        XCTAssertEqual(
            pending,
            [
                CloudServerConfigurationChange(
                    current: edited,
                    incoming: original
                )
            ]
        )
        let rejected = try await fixture.store
            .rejectServerConfigurationChange(
                accountID: edited.id,
                zoneID: fixture.zoneID
            )
        let preparedAccountRecord = try XCTUnwrap(
            rejected
        )
        let data = try XCTUnwrap(
            preparedAccountRecord[PrivateCloudSyncStore.payloadKey] as? Data
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                CloudServerAccountRecordPayload.self,
                from: data
            ).account,
            edited
        )
    }

    func testDelayedSupersededAccountGenerationDoesNotPromptOrRevert()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let original = try makeAccount(
            server: "https://remote.example",
            localServer: nil
        )
        try await fixture.accounts.save(original)
        let initialRecords = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let initialRecord = try XCTUnwrap(
            initialRecords.first { $0.recordType == "ServerAccount" }
        )
        let initialData = try XCTUnwrap(
            initialRecord[PrivateCloudSyncStore.payloadKey] as? Data
        )
        let initialPayload = try JSONDecoder().decode(
            CloudServerAccountRecordPayload.self,
            from: initialData
        )
        let delayedRecord = CKRecord(
            recordType: initialRecord.recordType,
            recordID: initialRecord.recordID
        )
        delayedRecord[PrivateCloudSyncStore.payloadKey] =
            initialData as CKRecordValue

        let edited = try makeAccount(
            server: "https://primary.example",
            localServer: "https://local.example"
        )
        try await fixture.accounts.save(edited)
        let pushedRecord = try await fixture.store.prepareAccountRecord(
            edited,
            zoneID: fixture.zoneID
        )
        let pushedData = try XCTUnwrap(
            pushedRecord[PrivateCloudSyncStore.payloadKey] as? Data
        )
        let pushedPayload = try JSONDecoder().decode(
            CloudServerAccountRecordPayload.self,
            from: pushedData
        )

        try await fixture.store.applyFetchedRecord(delayedRecord)

        let stored = try await fixture.accounts.account(id: edited.id)
        let pending = await fixture.store
            .pendingServerConfigurationChanges()
        let retainedRecordValue = await fixture.store.record(
            for: pushedRecord.recordID
        )
        let retainedRecord = try XCTUnwrap(retainedRecordValue)
        let retainedData = try XCTUnwrap(
            retainedRecord[PrivateCloudSyncStore.payloadKey] as? Data
        )
        XCTAssertEqual(stored, edited)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(retainedData, pushedData)
        XCTAssertEqual(pushedPayload.account, edited)
        XCTAssertEqual(
            pushedPayload.supersededGenerationID,
            initialPayload.generationID
        )
        XCTAssertNotNil(pushedPayload.supersededPayloadDigest)
    }

    func testFetchedAccountUpdateRequiresConfirmationBeforeApplying()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let original = try makeAccount(
            server: "https://remote.example",
            localServer: nil
        )
        try await fixture.accounts.save(original)
        let records = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let baseline = try XCTUnwrap(
            records.first { $0.recordType == "ServerAccount" }
        )
        let incoming = CKRecord(
            recordType: baseline.recordType,
            recordID: baseline.recordID
        )
        let remoteUpdate = try makeAccount(
            server: "https://primary.example",
            localServer: "https://local.example"
        )
        incoming[PrivateCloudSyncStore.payloadKey] =
            try JSONEncoder().encode(remoteUpdate) as CKRecordValue

        try await fixture.store.applyFetchedRecord(incoming)
        let stored = try await fixture.accounts.account(id: remoteUpdate.id)
        let pending = await fixture.store
            .pendingServerConfigurationChanges()

        XCTAssertEqual(stored, original)
        XCTAssertEqual(
            pending,
            [
                CloudServerConfigurationChange(
                    current: original,
                    incoming: remoteUpdate
                )
            ]
        )

        try await fixture.store.acceptServerConfigurationChange(
            accountID: remoteUpdate.id
        )
        let accepted = try await fixture.accounts.account(
            id: remoteUpdate.id
        )

        XCTAssertEqual(accepted, remoteUpdate)
    }

    func testFetchedCloudOnlyAccountRequiresConfirmationBeforeAdding()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let incoming = try makeAccount(
            server: "https://primary.example",
            localServer: "https://local.example"
        )
        let record = CKRecord(
            recordType: "ServerAccount",
            recordID: CKRecord.ID(
                recordName: "account.\(incoming.id.rawValue)",
                zoneID: fixture.zoneID
            )
        )
        record[PrivateCloudSyncStore.payloadKey] =
            try JSONEncoder().encode(incoming) as CKRecordValue

        try await fixture.store.applyFetchedRecord(record)

        let stored = try await fixture.accounts.account(id: incoming.id)
        let pending = await fixture.store
            .pendingServerConfigurationChanges()
        XCTAssertNil(stored)
        XCTAssertEqual(
            pending,
            [
                CloudServerConfigurationChange(
                    current: nil,
                    incoming: incoming
                )
            ]
        )
    }

    func testFetchedConfigurationConflictWaitsForUserDecision()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let records = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let cloudConfigurationRecord = try XCTUnwrap(
            records.first { $0.recordType == "Configuration" }
        )
        let localEdit = makeSnapshot(
            previousCommandAction: .previousChapter,
            nextCommandAction: .nextChapter
        )
        try await fixture.configuration.apply(localEdit)

        try await fixture.store.applyFetchedRecord(
            cloudConfigurationRecord
        )
        let preserved = await fixture.configuration.snapshot()
        let conflict = await fixture.store.configurationConflict()

        XCTAssertEqual(preserved, localEdit)
        XCTAssertEqual(
            conflict,
            CloudConfigurationConflict(
                local: localEdit,
                iCloud: makeSnapshot(
                    previousCommandAction: .skipBackward,
                    nextCommandAction: .skipForward
                )
            )
        )
    }

    func testMatchingServerConflictCachesServerRecordWithoutAnotherSave()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let records = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let clientRecord = try XCTUnwrap(
            records.first { $0.recordType == "Configuration" }
        )
        let serverRecord = CKRecord(
            recordType: clientRecord.recordType,
            recordID: clientRecord.recordID
        )
        serverRecord[PrivateCloudSyncStore.payloadKey] =
            clientRecord[PrivateCloudSyncStore.payloadKey]

        let pending = try await fixture.store
            .reconcileSentRecordZoneChanges(
                savedRecords: [],
                deletedRecordIDs: [],
                failedRecordSaves: [
                    (
                        record: clientRecord,
                        error: serverConflictError(
                            clientRecord: clientRecord,
                            serverRecord: serverRecord
                        )
                    )
                ],
                failedRecordDeletes: [:]
            )
        let cached = await fixture.store.record(for: clientRecord.recordID)

        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(cached === serverRecord)
    }

    func testConfigurationConflictAfterNewLocalEditRebasesAndRetries()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let records = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let clientRecord = try XCTUnwrap(
            records.first { $0.recordType == "Configuration" }
        )
        let serverRecord = CKRecord(
            recordType: clientRecord.recordType,
            recordID: clientRecord.recordID
        )
        let serverSnapshot = makeSnapshot(
            previousCommandAction: .nextChapter,
            nextCommandAction: .previousChapter
        )
        serverRecord[PrivateCloudSyncStore.payloadKey] =
            try JSONEncoder().encode(serverSnapshot) as CKRecordValue
        let localEdit = makeSnapshot(
            previousCommandAction: .previousChapter,
            nextCommandAction: .nextChapter
        )
        try await fixture.configuration.apply(localEdit)

        let pending = try await fixture.store
            .reconcileSentRecordZoneChanges(
                savedRecords: [],
                deletedRecordIDs: [],
                failedRecordSaves: [
                    (
                        record: clientRecord,
                        error: serverConflictError(
                            clientRecord: clientRecord,
                            serverRecord: serverRecord
                        )
                    )
                ],
                failedRecordDeletes: [:]
            )
        let cachedValue = await fixture.store.record(
            for: clientRecord.recordID
        )
        let cached = try XCTUnwrap(cachedValue)
        let cachedData = try XCTUnwrap(
            cached[PrivateCloudSyncStore.payloadKey] as? Data
        )

        XCTAssertEqual(pending, [.saveRecord(clientRecord.recordID)])
        XCTAssertTrue(cached === serverRecord)
        XCTAssertEqual(
            try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: cachedData
            ),
            localEdit
        )
    }

    func testAmbiguousSentConfigurationConflictWaitsForUserDecision()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let records = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let clientRecord = try XCTUnwrap(
            records.first { $0.recordType == "Configuration" }
        )
        let serverRecord = CKRecord(
            recordType: clientRecord.recordType,
            recordID: clientRecord.recordID
        )
        let serverSnapshot = makeSnapshot(
            previousCommandAction: .nextChapter,
            nextCommandAction: .previousChapter
        )
        serverRecord[PrivateCloudSyncStore.payloadKey] =
            try JSONEncoder().encode(serverSnapshot) as CKRecordValue

        let pending = try await fixture.store
            .reconcileSentRecordZoneChanges(
                savedRecords: [],
                deletedRecordIDs: [],
                failedRecordSaves: [
                    (
                        record: clientRecord,
                        error: serverConflictError(
                            clientRecord: clientRecord,
                            serverRecord: serverRecord
                        )
                    )
                ],
                failedRecordDeletes: [:]
            )
        let conflict = await fixture.store.configurationConflict()

        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(
            conflict,
            CloudConfigurationConflict(
                local: makeSnapshot(
                    previousCommandAction: .skipBackward,
                    nextCommandAction: .skipForward
                ),
                iCloud: serverSnapshot
            )
        )
    }

    func testUsingICloudResolvesConfigurationConflict() async throws {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let records = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let record = try XCTUnwrap(
            records.first { $0.recordType == "Configuration" }
        )
        let cloud = makeSnapshot(
            previousCommandAction: .nextChapter,
            nextCommandAction: .previousChapter
        )
        record[PrivateCloudSyncStore.payloadKey] =
            try JSONEncoder().encode(cloud) as CKRecordValue
        try await fixture.store.applyFetchedRecord(record)

        let outgoing = try await fixture.store.resolveConfigurationConflict(
            .useICloud
        )
        let remainingConflict = await fixture.store.configurationConflict()
        let applied = await fixture.configuration.snapshot()

        XCTAssertNil(outgoing)
        XCTAssertNil(remainingConflict)
        XCTAssertEqual(applied, cloud)
    }

    func testKeepingThisDevicePreparesCurrentConfigurationForUpload()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let records = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let record = try XCTUnwrap(
            records.first { $0.recordType == "Configuration" }
        )
        let local = makeSnapshot(
            previousCommandAction: .previousChapter,
            nextCommandAction: .nextChapter
        )
        try await fixture.configuration.apply(local)
        try await fixture.store.applyFetchedRecord(record)

        let outgoingValue = try await fixture.store
            .resolveConfigurationConflict(.keepThisDevice)
        let outgoing = try XCTUnwrap(
            outgoingValue
        )
        let payload = try XCTUnwrap(
            outgoing[PrivateCloudSyncStore.payloadKey] as? Data
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: payload
            ),
            local
        )
        let remainingConflict = await fixture.store.configurationConflict()
        XCTAssertNotNil(remainingConflict)
    }

    func testSavedRecordSystemFieldsSurviveStoreRecreation() async throws {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let recordID = CKRecord.ID(
            recordName: "configuration.singleton",
            zoneID: fixture.zoneID
        )
        let savedRecord = CKRecord(
            recordType: "Configuration",
            recordID: recordID
        )
        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: [savedRecord],
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        let restoredStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(fixture.defaults)
        )

        let restored = await restoredStore.record(for: recordID)

        XCTAssertEqual(restored?.recordID, recordID)
        XCTAssertEqual(restored?.recordType, "Configuration")
    }

    func testPendingConfigurationConflictSurvivesStoreRecreation()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let records = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let clientRecord = try XCTUnwrap(
            records.first { $0.recordType == "Configuration" }
        )
        let serverRecord = CKRecord(
            recordType: clientRecord.recordType,
            recordID: clientRecord.recordID
        )
        let cloud = makeSnapshot(
            previousCommandAction: .nextChapter,
            nextCommandAction: .previousChapter
        )
        serverRecord[PrivateCloudSyncStore.payloadKey] =
            try JSONEncoder().encode(cloud) as CKRecordValue
        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: [],
            deletedRecordIDs: [],
            failedRecordSaves: [
                (
                    record: clientRecord,
                    error: serverConflictError(
                        clientRecord: clientRecord,
                        serverRecord: serverRecord
                    )
                )
            ],
            failedRecordDeletes: [:]
        )

        let restoredStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(fixture.defaults)
        )
        let restoredConflict = await restoredStore.configurationConflict()
        let prepared = try await restoredStore.prepareRecords(
            zoneID: fixture.zoneID
        )

        XCTAssertEqual(
            restoredConflict,
            CloudConfigurationConflict(
                local: makeSnapshot(
                    previousCommandAction: .skipBackward,
                    nextCommandAction: .skipForward
                ),
                iCloud: cloud
            )
        )
        XCTAssertFalse(
            prepared.contains { $0.recordType == "Configuration" }
        )
    }

    func testInvalidPersistedConfigurationConflictFailsClosed()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        fixture.defaults.set(
            Data([0x00, 0x01]),
            forKey: "bleat.cloudKit.pendingConfigurationConflict.v1"
        )
        let restoredStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(fixture.defaults)
        )

        do {
            _ = try await restoredStore.prepareRecords(
                zoneID: fixture.zoneID
            )
            XCTFail("Expected invalid persisted conflict to stop uploads")
        } catch let error as PrivateCloudSyncError {
            XCTAssertEqual(error, .invalidRecord)
        }
    }

    private func makeSuite() -> String {
        "PrivateCloudSyncTests.\(UUID().uuidString)"
    }

    private func makeStore(
        suite: String
    ) throws -> CloudConfigurationStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return CloudConfigurationStore(defaults: defaults)
    }

    private func makeSnapshot(
        previousCommandAction: HeadphoneCommandAction,
        nextCommandAction: HeadphoneCommandAction
    ) -> CloudConfigurationSnapshot {
        CloudConfigurationSnapshot(
            defaultPlaybackRate: 1,
            resumeRewindSeconds: 10,
            skipBackwardSeconds: 15,
            skipForwardSeconds: 30,
            previousCommandAction: previousCommandAction,
            nextCommandAction: nextCommandAction,
            downloadNetworkPolicy: "wifiOnly",
            automaticDownloadLookahead: 5,
            automaticDownloadCleanupPolicy: "afterTwentyFourHours"
        )
    }

    private func makeAccount(
        server: String,
        localServer: String?
    ) throws -> ServerAccount {
        try ServerAccount(
            id: AccountID(rawValue: "account"),
            server: NormalizedServerURL(server),
            localServer: try localServer.map(NormalizedServerURL.init),
            localServerValidated: localServer != nil,
            serverVersion: "2.29.0",
            authenticationMethods: [.local],
            user: AuthenticatedUser(
                id: UserID(rawValue: "user"),
                username: "reader",
                type: .user,
                permissions: UserPermissions(
                    download: true,
                    update: false,
                    delete: false,
                    upload: false,
                    createEReader: false,
                    accessAllLibraries: true,
                    accessAllTags: true,
                    accessExplicitContent: true,
                    selectedTagsNotAccessible: false
                ),
                accessibleLibraryIDs: [],
                selectedItemTags: []
            )
        )
    }

    private func serverConflictError(
        clientRecord: CKRecord,
        serverRecord: CKRecord
    ) -> CKError {
        CKError(
            .serverRecordChanged,
            userInfo: [
                CKRecordChangedErrorClientRecordKey: clientRecord,
                CKRecordChangedErrorServerRecordKey: serverRecord,
            ]
        )
    }

    private func makeSyncStoreFixture() throws -> SyncStoreFixture {
        let schema = Schema(BleatPersistenceModelCatalog.allModelTypes)
        let modelConfiguration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [modelConfiguration]
        )
        let accounts = AccountStore(modelContainer: container)
        let suite = makeSuite()
        let configurationDefaults = try XCTUnwrap(
            UserDefaults(suiteName: suite)
        )
        let recordDefaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let configuration = CloudConfigurationStore(
            defaults: configurationDefaults
        )
        let statistics = StatisticsRepository(modelContainer: container)
        return SyncStoreFixture(
            suite: suite,
            zoneID: CKRecordZone.ID(
                zoneName: "test",
                ownerName: CKCurrentUserDefaultName
            ),
            accounts: accounts,
            configuration: configuration,
            defaults: recordDefaults,
            statistics: statistics,
            store: PrivateCloudSyncStore(
                statistics: statistics,
                accounts: accounts,
                credentialStore: nil,
                configuration: configuration,
                defaults: PrivateCloudDefaultsReference(recordDefaults)
            )
        )
    }
}

private struct SyncStoreFixture {
    let suite: String
    let zoneID: CKRecordZone.ID
    let accounts: AccountStore
    let configuration: CloudConfigurationStore
    let defaults: UserDefaults
    let statistics: StatisticsRepository
    let store: PrivateCloudSyncStore
}

private struct LegacyCloudConfigurationSnapshot: Encodable {
    let defaultPlaybackRate: Double
    let resumeRewindSeconds: Int
    let skipBackwardSeconds: Int
    let skipForwardSeconds: Int
    let downloadNetworkPolicy: String
    let automaticDownloadLookahead: Int
    let automaticDownloadCleanupPolicy: String
}

private struct InvalidCloudConfigurationSnapshot: Encodable {
    let defaultPlaybackRate: Double
    let resumeRewindSeconds: Int
    let skipBackwardSeconds: Int
    let skipForwardSeconds: Int
    let previousCommandAction: String
    let nextCommandAction: String
    let downloadNetworkPolicy: String
    let automaticDownloadLookahead: Int
    let automaticDownloadCleanupPolicy: String
}
