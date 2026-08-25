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
            durationMilliseconds: 17,
            recordCount: 23
        )

        XCTAssertEqual(event.operation, .privateCloudSync)
        XCTAssertEqual(event.failureCode, .privateCloudKitFailed)
        XCTAssertEqual(event.privateCloud?.operation, .applyFetchedChanges)
        XCTAssertEqual(
            event.privateCloud?.cloudKitCode,
            "request_rate_limited"
        )
        XCTAssertEqual(event.privateCloud?.retryAfterMilliseconds, 1_250)
        XCTAssertEqual(event.count, 23)
        XCTAssertTrue(
            event.text.contains("cloud_operation=apply_fetched_changes")
        )
        XCTAssertTrue(
            event.text.contains("cloudkit_code=request_rate_limited")
        )
        XCTAssertFalse(event.text.contains("localizedDescription"))
    }

    func testFailedCloudKitEventRecorderPreservesRecordCount() async throws {
        let diagnostics = PrivateCloudDiagnosticRecorderSpy()
        let recorder = DiagnosticPrivateCloudSyncEventRecorder(
            diagnostics: diagnostics
        )
        let failure = PrivateCloudSyncFailure(
            operation: .uploadChanges,
            cause: .cloudKit(CloudKitFailure(CKError(.networkFailure)))
        )

        await recorder.record(
            PrivateCloudSyncEvent(
                correlationID: UUID(),
                operation: .uploadChanges,
                phase: .failed(failure),
                durationMilliseconds: 42,
                recordCount: 17
            )
        )

        let events = await diagnostics.events()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.privateCloud?.operation, .uploadChanges)
        XCTAssertEqual(event.count, 17)
        XCTAssertTrue(event.text.contains("count=17"))
    }

    func testCloudKitStageDiagnosticIncludesPrivacySafeRecordCount() {
        let event = DiagnosticEvent.privateCloudCompleted(
            operation: .prepareLocalChanges,
            correlationID: UUID(),
            durationMilliseconds: 23,
            recordCount: 17
        )

        XCTAssertTrue(
            event.text.contains("cloud_operation=prepare_local_changes")
        )
        XCTAssertTrue(event.text.contains("duration_ms=23"))
        XCTAssertTrue(event.text.contains("count=17"))
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
            server: "https://remote.example",
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
            server: "https://remote.example",
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
            server: "https://remote.example",
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

        _ = try await fixture.store.acceptServerConfigurationChange(
            accountID: remoteUpdate.id,
            zoneID: fixture.zoneID
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

    func testTwoLegacyDeviceAccountsConvergeWithoutDuplicatePrompts()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let canonical = try makeAccount(
            server: "https://remote.example",
            localServer: "https://local.example"
        )
        try await fixture.accounts.save(canonical)
        let firstLegacy = try canonical
            .updatingLocalServer(nil)
            .reidentified(as: AccountID(rawValue: "device-one"))
        let secondLegacy = try canonical.reidentified(
            as: AccountID(rawValue: "device-two")
        )
        let firstRecord = try makeRecord(
            type: "ServerAccount",
            name: "account.device-one",
            value: firstLegacy,
            zoneID: fixture.zoneID
        )
        let secondRecord = try makeRecord(
            type: "ServerAccount",
            name: "account.device-two",
            value: secondLegacy,
            zoneID: fixture.zoneID
        )

        let pending = try await fixture.store.applyFetchedRecords([
            firstRecord,
            secondRecord,
        ])
        let changes = await fixture.store.pendingServerConfigurationChanges()
        let canonicalRecordID = CKRecord.ID(
            recordName: "account.\(canonical.id.rawValue)",
            zoneID: fixture.zoneID
        )
        let savedValue = await fixture.store.record(for: canonicalRecordID)
        let saved = try XCTUnwrap(savedValue)

        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(
            Set(pending.compactMap {
                if case .saveRecord(let recordID) = $0 { return recordID }
                return nil
            }),
            [canonicalRecordID]
        )

        let followUp = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: [saved],
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        XCTAssertEqual(
            Set(followUp.compactMap {
                if case .deleteRecord(let recordID) = $0 { return recordID }
                return nil
            }),
            [firstRecord.recordID, secondRecord.recordID]
        )
        let restoredStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(fixture.defaults)
        )
        let restoredDeletions = try await restoredStore
            .prepareDeletionChanges(zoneID: fixture.zoneID)
        XCTAssertEqual(
            Set(restoredDeletions.compactMap {
                if case .deleteRecord(let recordID) = $0 { return recordID }
                return nil
            }),
            [firstRecord.recordID, secondRecord.recordID]
        )
        _ = try await restoredStore.reconcileSentRecordZoneChanges(
            savedRecords: [],
            deletedRecordIDs: [firstRecord.recordID, secondRecord.recordID],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        let confirmedDeletions = try await restoredStore
            .prepareDeletionChanges(zoneID: fixture.zoneID)
        XCTAssertTrue(confirmedDeletions.isEmpty)
        let data = try XCTUnwrap(
            saved[PrivateCloudSyncStore.payloadKey] as? Data
        )
        let payload = try JSONDecoder().decode(
            CloudServerAccountRecordPayload.self,
            from: data
        )
        XCTAssertEqual(payload.account, canonical)
        XCTAssertEqual(
            payload.legacyAccountIDs,
            [firstLegacy.id, secondLegacy.id]
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

    func testStructurallyEquivalentSentConfigurationConflictWaitsForDecision()
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
        let clientData = try XCTUnwrap(
            clientRecord[PrivateCloudSyncStore.payloadKey] as? Data
        )
        let clientJSON = try JSONSerialization.jsonObject(with: clientData)
        let structurallyEquivalentClientData = try JSONSerialization.data(
            withJSONObject: clientJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        XCTAssertNotEqual(clientData, structurallyEquivalentClientData)
        clientRecord[PrivateCloudSyncStore.payloadKey] =
            structurallyEquivalentClientData as CKRecordValue
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

    func testUnchangedRecordsAreNotPreparedAgainAfterSuccessfulSend()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let initial = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertEqual(initial.map(\.recordType), ["Configuration"])

        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: initial,
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )

        let unchanged = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertTrue(unchanged.isEmpty)

        let restoredStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(fixture.defaults)
        )
        let unchangedAfterRelaunch = try await restoredStore.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertTrue(unchangedAfterRelaunch.isEmpty)
    }

    func testUnconfirmedRecordsRemainPreparedForRetry() async throws {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let initial = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )

        let retry = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )

        XCTAssertEqual(retry.map(\.recordID), initial.map(\.recordID))
    }

    func testOnlyChangedConfigurationIsPreparedAfterBaseline() async throws {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let initial = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: initial,
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        try await fixture.configuration.apply(
            makeSnapshot(
                previousCommandAction: .previousChapter,
                nextCommandAction: .nextChapter
            )
        )

        let changed = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )

        XCTAssertEqual(changed.map(\.recordType), ["Configuration"])
    }

    func testSynchronizedStatisticsAreExcludedFromLaterPreparation()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let slice = makeSlice(index: 0)
        try await fixture.statistics.importArchive(
            StatisticsArchive(
                slices: [slice],
                completions: [],
                remoteSessions: []
            )
        )
        let initial = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertEqual(
            Set(initial.map(\.recordType)),
            ["ListeningSlice", "Configuration"]
        )

        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: initial,
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )

        let unchanged = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertTrue(unchanged.isEmpty)
    }

    func testLegacyNilStatisticsSyncStateIsPreparedForReconciliation()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let slice = makeSlice(index: 0)
        let context = ModelContext(fixture.container)
        let legacyRecord = ListeningSliceRecord(slice)
        legacyRecord.privateCloudSynchronized = nil
        context.insert(legacyRecord)
        try context.save()

        let prepared = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )

        XCTAssertTrue(
            prepared.contains { $0.recordType == "ListeningSlice" }
        )
    }

    func testDirtyStatisticsSurviveRelaunchAndAreReconciledOnce()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let slice = makeSlice(index: 0)
        try await fixture.statistics.importArchive(
            StatisticsArchive(
                slices: [slice],
                completions: [],
                remoteSessions: []
            )
        )
        let initial = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let sliceRecord = try XCTUnwrap(
            initial.first { $0.recordType == "ListeningSlice" }
        )
        let otherRecords = initial.filter {
            $0.recordType != "ListeningSlice"
        }
        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: otherRecords,
            deletedRecordIDs: [],
            failedRecordSaves: [
                (
                    record: sliceRecord,
                    error: CKError(.networkFailure)
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
        let reconciliation = try await restoredStore.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertEqual(
            reconciliation.map(\.recordType),
            ["ListeningSlice"]
        )

        _ = try await restoredStore.reconcileSentRecordZoneChanges(
            savedRecords: reconciliation,
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        let nextSync = try await restoredStore.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertTrue(nextSync.isEmpty)
    }

    func testDeletedStatisticsRemainPendingUntilCloudKitConfirmsDeletion()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let slice = makeSlice(index: 0)
        try await fixture.statistics.importArchive(
            StatisticsArchive(
                slices: [slice],
                completions: [],
                remoteSessions: []
            )
        )
        try await fixture.statistics.reset(
            query: StatisticsQuery(accountID: slice.accountID)
        )
        let recordID = CKRecord.ID(
            recordName: "slice.\(slice.id.uuidString.lowercased())",
            zoneID: fixture.zoneID
        )

        let initial = try await fixture.store.prepareDeletionChanges(
            zoneID: fixture.zoneID
        )
        let retry = try await fixture.store.prepareDeletionChanges(
            zoneID: fixture.zoneID
        )
        XCTAssertEqual(initial, [.deleteRecord(recordID)])
        XCTAssertEqual(retry, initial)

        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: [],
            deletedRecordIDs: [recordID],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        let confirmed = try await fixture.store.prepareDeletionChanges(
            zoneID: fixture.zoneID
        )
        XCTAssertTrue(confirmed.isEmpty)
    }

    func testFetchedRecordDoesNotOverridePendingLocalDeletion()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let slice = makeSlice(index: 0)
        try await fixture.statistics.importArchive(
            StatisticsArchive(
                slices: [slice],
                completions: [],
                remoteSessions: []
            )
        )
        try await fixture.statistics.reset(
            query: StatisticsQuery(accountID: slice.accountID)
        )
        let fetched = try makeRecord(
            type: "ListeningSlice",
            name: "slice.\(slice.id.uuidString.lowercased())",
            value: slice,
            zoneID: fixture.zoneID
        )

        _ = try await fixture.store.applyFetchedRecords([fetched])

        let archive = try await fixture.statistics.archive()
        XCTAssertTrue(archive.slices.isEmpty)
        let deletions = try await fixture.store.prepareDeletionChanges(
            zoneID: fixture.zoneID
        )
        XCTAssertEqual(deletions.count, 1)
    }

    func testValidFetchedRecordsPersistWhenAnotherRecordIsInvalid()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let slice = makeSlice(index: 0)
        let valid = try makeRecord(
            type: "ListeningSlice",
            name: "slice.\(slice.id.uuidString.lowercased())",
            value: slice,
            zoneID: fixture.zoneID
        )
        let invalid = CKRecord(
            recordType: "CompletionMilestone",
            recordID: CKRecord.ID(
                recordName: "completion.invalid",
                zoneID: fixture.zoneID
            )
        )
        invalid[PrivateCloudSyncStore.payloadKey] =
            Data([0x00]) as CKRecordValue

        do {
            _ = try await fixture.store.applyFetchedRecords([valid, invalid])
            XCTFail("Expected the invalid fetched record to be reported")
        } catch let error as PrivateCloudSyncError {
            XCTAssertEqual(error, .invalidRecord)
        }

        let archive = try await fixture.statistics.archive()
        XCTAssertEqual(archive.slices, [slice])
    }

    func testDeletingCloudZoneMakesLocalStatisticsUploadableAgain()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let slice = makeSlice(index: 0)
        try await fixture.statistics.importArchive(
            StatisticsArchive(
                slices: [slice],
                completions: [],
                remoteSessions: []
            )
        )
        let initial = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: initial,
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        let unchanged = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertTrue(unchanged.isEmpty)

        try await fixture.store.removeAllRecords()

        let afterZoneDeletion = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertTrue(
            afterZoneDeletion.contains { $0.recordType == "ListeningSlice" }
        )
    }

    func testAccountDeletionFindsCleanStatisticsAfterStoreRecreation()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let slice = makeSlice(index: 0)
        try await fixture.statistics.importArchive(
            StatisticsArchive(
                slices: [slice],
                completions: [],
                remoteSessions: []
            )
        )
        let initial = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: initial,
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

        let recordIDs = try await restoredStore.recordIDs(
            for: slice.accountID,
            includeStatistics: true,
            zoneID: fixture.zoneID
        )

        XCTAssertTrue(
            recordIDs.contains {
                $0.recordName
                    == "slice.\(slice.id.uuidString.lowercased())"
            }
        )
    }

    func testAccountDeletionFindsPendingStatisticsDeletionAfterStoreRecreation()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let slice = makeSlice(index: 0)
        try await fixture.statistics.importArchive(
            StatisticsArchive(
                slices: [slice],
                completions: [],
                remoteSessions: []
            )
        )
        try await fixture.statistics.reset(
            query: StatisticsQuery(accountID: slice.accountID)
        )
        let restoredStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(fixture.defaults)
        )

        let recordIDs = try await restoredStore.recordIDs(
            for: slice.accountID,
            includeStatistics: true,
            zoneID: fixture.zoneID
        )

        XCTAssertEqual(
            recordIDs.map(\.recordName),
            ["slice.\(slice.id.uuidString.lowercased())"]
        )
    }

    func testNestedFailurePreservesSpecificOperation() {
        let stageFailure = PrivateCloudSyncFailure(
            operation: .fetchChanges,
            cause: .cloudKit(CloudKitFailure(CKError(.networkFailure)))
        )

        let mapped = PrivateCloudSyncCoordinator.mappedFailure(
            operation: .synchronize,
            error: stageFailure
        )

        XCTAssertEqual(mapped, stageFailure)
    }

    func testFetchedStatisticsBatchIsImportedIdempotently() async throws {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let records = try (0..<100).flatMap { index -> [CKRecord] in
            let slice = makeSlice(index: index)
            let completion = CompletionMilestone(
                accountID: slice.accountID,
                itemID: slice.itemID,
                completedAt: slice.startedAt,
                duration: 60,
                title: "Book",
                author: "Author",
                evidence: .naturalEnd
            )
            return try [
                makeRecord(
                    type: "ListeningSlice",
                    name: "slice.\(slice.id.uuidString.lowercased())",
                    value: slice,
                    zoneID: fixture.zoneID
                ),
                makeRecord(
                    type: "CompletionMilestone",
                    name:
                        "completion."
                        + completion.id.uuidString.lowercased(),
                    value: completion,
                    zoneID: fixture.zoneID
                ),
            ]
        }

        _ = try await fixture.store.applyFetchedRecords(records)
        _ = try await fixture.store.applyFetchedRecords(records)
        let archive = try await fixture.statistics.archive()

        XCTAssertEqual(archive.slices.count, 100)
        XCTAssertEqual(archive.completions.count, 100)
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

    func testDeletingCloudDataClearsInvalidPersistedConfigurationConflict()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let conflictKey =
            "bleat.cloudKit.pendingConfigurationConflict.v1"
        fixture.defaults.set(Data([0x00, 0x01]), forKey: conflictKey)
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

        try await restoredStore.removeAllRecords()

        XCTAssertNil(fixture.defaults.data(forKey: conflictKey))
        let preparedAfterDeletion = try await restoredStore.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertTrue(
            preparedAfterDeletion.contains {
                $0.recordType == "Configuration"
            }
        )
        let relaunchedStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(fixture.defaults)
        )
        let prepared = try await relaunchedStore.prepareRecords(
            zoneID: fixture.zoneID
        )
        XCTAssertTrue(
            prepared.contains { $0.recordType == "Configuration" }
        )
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
        let normalizedServer = try NormalizedServerURL(server)
        let user = AuthenticatedUser(
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
        return try ServerAccount(
            id: AccountID.canonical(
                server: normalizedServer,
                userID: user.id
            ),
            server: normalizedServer,
            localServer: try localServer.map(NormalizedServerURL.init),
            localServerValidated: localServer != nil,
            serverVersion: "2.29.0",
            authenticationMethods: [.local],
            user: user
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

    private func makeRecord<Value: Encodable>(
        type: CKRecord.RecordType,
        name: String,
        value: Value,
        zoneID: CKRecordZone.ID
    ) throws -> CKRecord {
        let record = CKRecord(
            recordType: type,
            recordID: CKRecord.ID(recordName: name, zoneID: zoneID)
        )
        record[PrivateCloudSyncStore.payloadKey] =
            try JSONEncoder().encode(value) as CKRecordValue
        return record
    }

    private func makeSlice(index: Int) -> ListeningSlice {
        let startedAt = Date(timeIntervalSince1970: Double(index))
        return ListeningSlice(
            accountID: AccountID(rawValue: "account"),
            itemID: LibraryItemID(rawValue: "item-\(index)"),
            sessionID: PlaybackSessionID(rawValue: "session-\(index)"),
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1),
            startPosition: 0,
            endPosition: 1,
            realSeconds: 1,
            audiobookSeconds: 1,
            playbackRate: 1,
            chapterID: nil,
            chapterTitle: nil,
            chapterStart: nil,
            chapterEnd: nil,
            title: "Book",
            author: "Author",
            duration: 60
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
            container: container,
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
    let container: ModelContainer
    let defaults: UserDefaults
    let statistics: StatisticsRepository
    let store: PrivateCloudSyncStore
}

private actor PrivateCloudDiagnosticRecorderSpy: DiagnosticRecording {
    private var recordedEvents: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        recordedEvents.append(event)
    }

    func events() -> [DiagnosticEvent] {
        recordedEvents
    }
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
