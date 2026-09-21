import CloudKit
import Foundation
import SwiftData
import Testing

@testable import BleatCore

@Suite(.serialized)
final class PrivateCloudSyncTests {
    @Test
    func testEveryPrivateCloudErrorPreservesDiagnosticFailureCode() {
        let cases: [(PrivateCloudSyncError, DiagnosticFailureCode)] = [
            (.disabled, .privateCloudDisabled),
            (.cancelled, .privateCloudCancelled),
            (.callbackTimedOut, .privateCloudCallbackTimedOut),
            (.stopping, .privateCloudStopping),
            (.invalidRecord, .privateCloudInvalidRecord),
            (.persistenceFailed, .privateCloudPersistenceFailed),
            (.nonPrivateDatabase, .privateCloudNonPrivateDatabase),
            (.engineUnavailable, .privateCloudEngineUnavailable),
            (
                .cloudKit(CloudKitFailure(CKError(.networkFailure))),
                .privateCloudKitFailed
            ),
            (
                .unexpected(
                    PrivateCloudSystemError(NSError(domain: "test", code: 1))),
                .privateCloudUnexpected
            ),
        ]
        for (error, expected) in cases {
            #expect(error.diagnosticFailureCode == expected)
            let event = DiagnosticEvent.privateCloudFailed(
                failure: PrivateCloudSyncFailure(
                    operation: .synchronize, cause: error),
                correlationID: UUID(),
                durationMilliseconds: 0
            )
            #expect(event.failureCode == expected)
        }
    }

    @Test
    func testCoordinatorAcceptsOnlyPrivateCloudKitDatabaseScope() {
        #expect(
            PrivateCloudSyncCoordinator.configurationFailure(for: .private)
                == nil)
        #expect(
            PrivateCloudSyncCoordinator.configurationFailure(for: .public)
                == .nonPrivateDatabase)
        #expect(
            PrivateCloudSyncCoordinator.configurationFailure(for: .shared)
                == .nonPrivateDatabase)
    }

    @Test
    func testFetchedCallbackDeadlinePausesInBackgroundAndBlocksRetryUntilDrain()
        async throws
    {
        let lifecycle = PrivateCloudSyncLifecycle()
        await lifecycle.setForeground(false)
        let run = try await lifecycle.begin(deadline: .milliseconds(30))
        let callback = await run.beginCallback {}
        try await Task.sleep(for: .milliseconds(50))
        let expiredInBackground = await run.checkDeadline(for: callback)
        #expect(!(expiredInBackground))

        await lifecycle.setForeground(true)
        try await Task.sleep(for: .milliseconds(50))
        let expiredInForeground = await run.checkDeadline(for: callback)
        #expect(expiredInForeground)
        let result = await run.waitForResult()
        guard case .failure(let failure) = result else {
            Issue.record("Expected a typed callback timeout")
            return
        }
        #expect(failure.operation == .applyFetchedChanges)
        #expect(failure.cause == .callbackTimedOut)
        do {
            _ = try await lifecycle.begin()
            Issue.record("Retry must wait for the old callback")
        } catch {
            #expect(error == .stopping)
        }

        await run.endCallback(callback)
        await lifecycle.finish(run)
        await run.complete(.failure(failure))
        await run.waitForDrain()
        _ = try await lifecycle.begin()
    }

    @Test
    func testFetchedCallbackProgressResetsNoProgressDeadline() async throws {
        let run = PrivateCloudSyncRun(deadline: .seconds(1))
        let callback = await run.beginCallback {}
        try await Task.sleep(for: .milliseconds(600))
        try await run.checkCallback(callback)
        try await Task.sleep(for: .milliseconds(600))
        let expiredAfterProgress = await run.checkDeadline(for: callback)
        #expect(!(expiredAfterProgress))
        let failureAfterProgress = await run.failure()
        #expect(failureAfterProgress == nil)
        try await Task.sleep(for: .milliseconds(600))
        // The watchdog can record the timeout before this manual check. Verify
        // the recorded outcome, not which caller first noticed expiration.
        _ = await run.checkDeadline(for: callback)
        let failure = await run.failure()
        #expect(
            failure
                == PrivateCloudSyncFailure(
                    operation: .applyFetchedChanges,
                    cause: .callbackTimedOut
                ))
        await run.endCallback(callback)
    }

    @Test
    func testFetchedCallbackFailureOverridesSuccessfulEngineCompletion()
        async throws
    {
        let run = PrivateCloudSyncRun()
        let failure = PrivateCloudSyncFailure(
            operation: .applyFetchedChanges,
            cause: .invalidRecord
        )
        await run.failCallback(failure)
        await run.complete(.success(()))
        let result = await run.waitForResult()
        guard case .failure(let reported) = result else {
            Issue.record("A failed callback must fail the overall sync")
            return
        }
        #expect(reported == failure)
    }

    @Test
    func testInterruptedFetchedBatchCanReconcileOnRetry() async throws {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let records = try (0..<3).map { index in
            let slice = makeSlice(index: index)
            return try makeRecord(
                type: "ListeningSlice",
                name: "slice.\(slice.id.uuidString.lowercased())",
                value: slice,
                zoneID: fixture.zoneID
            )
        }
        let checkpoint = FetchedBatchCheckpoint(failAt: 3)
        do {
            _ = try await fixture.store.applyFetchedRecords(
                records,
                checkActive: { try await checkpoint.check() }
            )
            Issue.record("Expected the interrupted batch to stop")
        } catch let error as PrivateCloudSyncError {
            #expect(error == .callbackTimedOut)
        }
        let beforeRetry = try await fixture.statistics.archive()
        #expect(beforeRetry.slices.isEmpty)

        _ = try await fixture.store.applyFetchedRecords(records)
        let afterRetry = try await fixture.statistics.archive()
        #expect(afterRetry.slices.count == 3)
    }

    @Test
    func testNonPrivateDatabaseHasSpecificDiagnosticCode() {
        let event = DiagnosticEvent.privateCloudFailed(
            failure: PrivateCloudSyncFailure(
                operation: .synchronize,
                cause: .nonPrivateDatabase
            ),
            correlationID: UUID(),
            durationMilliseconds: 0
        )

        #expect(event.failureCode == .privateCloudNonPrivateDatabase)
        #expect(
            PrivateCloudSyncError.nonPrivateDatabase
                .remoteTelemetryFailureCategory == .sourceBug)
    }

    @Test
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

        #expect(failure.code == .partialFailure)
        #expect(
            failure.partialFailureCodes == [
                .networkFailure, .permissionFailure,
            ])
        #expect(failure.retryAfterSeconds == 2.5)
        #expect(failure.isRetryable)
    }

    @Test
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

        #expect(conflict.canRetryAfterConflictReconciliation)
        #expect(!(mixed.canRetryAfterConflictReconciliation))
        #expect(
            conflict.sendRecovery(
                hasPendingConfigurationConflict: true,
                attempt: 0
            ) == .awaitUserResolution)
        #expect(
            conflict.sendRecovery(
                hasPendingConfigurationConflict: false,
                attempt: 0
            ) == .retry)
        #expect(
            conflict.sendRecovery(
                hasPendingConfigurationConflict: false,
                attempt: 1
            ) == .fail)
        #expect(
            mixed.sendRecovery(
                hasPendingConfigurationConflict: true,
                attempt: 0
            ) == .fail)
    }

    @Test
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

        #expect(event.operation == .privateCloudSync)
        #expect(event.failureCode == .privateCloudKitFailed)
        #expect(event.privateCloud?.operation == .applyFetchedChanges)
        #expect(event.privateCloud?.cloudKitCode == "request_rate_limited")
        #expect(event.privateCloud?.retryAfterMilliseconds == 1_250)
        #expect(event.count == 23)
        #expect(event.text.contains("cloud_operation=apply_fetched_changes"))
        #expect(event.text.contains("cloudkit_code=request_rate_limited"))
        #expect(!(event.text.contains("localizedDescription")))
    }

    @Test
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
        let event = try #require(events.first)
        #expect(event.privateCloud?.operation == .uploadChanges)
        #expect(event.count == 17)
        #expect(event.text.contains("count=17"))
    }

    @Test
    func testCloudKitStageDiagnosticIncludesPrivacySafeRecordCount() {
        let event = DiagnosticEvent.privateCloudCompleted(
            operation: .prepareLocalChanges,
            correlationID: UUID(),
            durationMilliseconds: 23,
            recordCount: 17
        )

        #expect(event.text.contains("cloud_operation=prepare_local_changes"))
        #expect(event.text.contains("duration_ms=23"))
        #expect(event.text.contains("count=17"))
    }

    @Test
    func testConfigurationSnapshotDefaultsHeadphoneCommands() async throws {
        let suite = makeSuite()
        defer {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let store = try makeStore(suite: suite)

        let snapshot = await store.snapshot()

        #expect(snapshot.previousCommandAction == .skipBackward)
        #expect(snapshot.nextCommandAction == .skipForward)
    }

    @Test
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
                nextCommandAction: .nextChapter,
                maximumConcurrentDownloads: 15,
                automaticDownloadLookahead:
                    AutomaticDownloadLookaheadPreference.all.rawValue
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

        #expect(restored.previousCommandAction == .previousChapter)
        #expect(restored.nextCommandAction == .nextChapter)
        #expect(restored.maximumConcurrentDownloads == 15)
        #expect(
            restored.automaticDownloadLookahead
                == AutomaticDownloadLookaheadPreference.all.rawValue)
    }

    @Test
    func testConfigurationNormalizesLookaheadBeforeApplying() async throws {
        let suite = makeSuite()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let store = try makeStore(suite: suite)
        let cases: [(Int, AutomaticDownloadLookaheadPreference)] = [
            (Int.min, .one), (-1, .one), (0, .one), (2, .one),
            (4, .three), (8, .five), (10, .ten), (11, .all), (Int.max, .all),
        ]
        for (input, expected) in cases {
            let payload = LegacyCloudConfigurationSnapshot(
                defaultPlaybackRate: 1,
                resumeRewindSeconds: 10,
                skipBackwardSeconds: 15,
                skipForwardSeconds: 30,
                downloadNetworkPolicy: "wifiOnly",
                automaticDownloadLookahead: input,
                automaticDownloadCleanupPolicy: "afterTwentyFourHours"
            )
            let decoded = try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: JSONEncoder().encode(payload)
            )
            #expect(decoded.automaticDownloadLookahead == expected.rawValue)
            try await store.apply(decoded)
            let restored = await store.snapshot()
            #expect(restored.automaticDownloadLookahead == expected.rawValue)
        }
    }

    @Test
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

        #expect(decoded.previousCommandAction == .skipBackward)
        #expect(decoded.nextCommandAction == .skipForward)
        #expect(decoded.maximumConcurrentDownloads == 5)
    }

    @Test
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

        #expect(
            throws: (any Error).self,
            performing: {
                try JSONDecoder().decode(
                    CloudConfigurationSnapshot.self,
                    from: data
                )
            })
    }

    @Test
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
        let cloudAccountRecord = try #require(
            records.first { $0.recordType == "ServerAccount" })

        let edited = try makeAccount(
            server: "https://remote.example",
            localServer: "https://local.example"
        )
        try await fixture.accounts.save(edited)
        try await fixture.store.applyFetchedRecord(
            cloudAccountRecord, persistSystemFields: true)

        let preserved = try await fixture.accounts.account(id: edited.id)
        let pending = await fixture.store
            .pendingServerConfigurationChanges()
        #expect(preserved == edited)
        #expect(
            pending == [
                CloudServerConfigurationChange(
                    current: edited,
                    incoming: original
                )
            ])
        let rejected = try await fixture.store
            .rejectServerConfigurationChange(
                accountID: edited.id,
                zoneID: fixture.zoneID
            )
        let preparedAccountRecord = try #require(rejected)
        let data = try #require(
            preparedAccountRecord[PrivateCloudSyncStore.payloadKey] as? Data)
        #expect(
            try JSONDecoder().decode(
                CloudServerAccountRecordPayload.self,
                from: data
            ).account == edited)
    }

    @Test
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
        let initialRecord = try #require(
            initialRecords.first { $0.recordType == "ServerAccount" })
        let initialData = try #require(
            initialRecord[PrivateCloudSyncStore.payloadKey] as? Data)
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
        let pushedData = try #require(
            pushedRecord[PrivateCloudSyncStore.payloadKey] as? Data)
        let pushedPayload = try JSONDecoder().decode(
            CloudServerAccountRecordPayload.self,
            from: pushedData
        )

        try await fixture.store.applyFetchedRecord(
            delayedRecord, persistSystemFields: true)

        let stored = try await fixture.accounts.account(id: edited.id)
        let pending = await fixture.store
            .pendingServerConfigurationChanges()
        let retainedRecordValue = await fixture.store.record(
            for: pushedRecord.recordID
        )
        let retainedRecord = try #require(retainedRecordValue)
        let retainedData = try #require(
            retainedRecord[PrivateCloudSyncStore.payloadKey] as? Data)
        #expect(stored == edited)
        #expect(pending.isEmpty)
        #expect(retainedData == pushedData)
        #expect(pushedPayload.account == edited)
        #expect(
            pushedPayload.supersededGenerationID == initialPayload.generationID)
        #expect(pushedPayload.supersededPayloadDigest != nil)
    }

    @Test
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
        let baseline = try #require(
            records.first { $0.recordType == "ServerAccount" })
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

        try await fixture.store.applyFetchedRecord(
            incoming, persistSystemFields: true)
        let stored = try await fixture.accounts.account(id: remoteUpdate.id)
        let pending = await fixture.store
            .pendingServerConfigurationChanges()

        #expect(stored == original)
        #expect(
            pending == [
                CloudServerConfigurationChange(
                    current: original,
                    incoming: remoteUpdate
                )
            ])

        _ = try await fixture.store.acceptServerConfigurationChange(
            accountID: remoteUpdate.id,
            zoneID: fixture.zoneID
        )
        let accepted = try await fixture.accounts.account(
            id: remoteUpdate.id
        )

        #expect(accepted == remoteUpdate)
    }

    @Test
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

        try await fixture.store.applyFetchedRecord(
            record, persistSystemFields: true)

        let stored = try await fixture.accounts.account(id: incoming.id)
        let pending = await fixture.store
            .pendingServerConfigurationChanges()
        #expect(stored == nil)
        #expect(
            pending == [
                CloudServerConfigurationChange(
                    current: nil,
                    incoming: incoming
                )
            ])
    }

    @Test
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
        let firstLegacy =
            try canonical
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
        let saved = try #require(savedValue)

        #expect(changes.isEmpty)
        #expect(
            Set(
                pending.compactMap {
                    if case .saveRecord(let recordID) = $0 { return recordID }
                    return nil
                }) == [canonicalRecordID])

        let followUp = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: [saved],
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        #expect(
            Set(
                followUp.compactMap {
                    if case .deleteRecord(let recordID) = $0 { return recordID }
                    return nil
                }) == [firstRecord.recordID, secondRecord.recordID])
        let restoredStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(fixture.defaults)
        )
        let restoredDeletions =
            try await restoredStore
            .prepareDeletionChanges(zoneID: fixture.zoneID)
        #expect(
            Set(
                restoredDeletions.compactMap {
                    if case .deleteRecord(let recordID) = $0 { return recordID }
                    return nil
                }) == [firstRecord.recordID, secondRecord.recordID])
        _ = try await restoredStore.reconcileSentRecordZoneChanges(
            savedRecords: [],
            deletedRecordIDs: [firstRecord.recordID, secondRecord.recordID],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        let confirmedDeletions =
            try await restoredStore
            .prepareDeletionChanges(zoneID: fixture.zoneID)
        #expect(confirmedDeletions.isEmpty)
        let data = try #require(
            saved[PrivateCloudSyncStore.payloadKey] as? Data)
        let payload = try JSONDecoder().decode(
            CloudServerAccountRecordPayload.self,
            from: data
        )
        #expect(payload.account == canonical)
        #expect(payload.legacyAccountIDs == [firstLegacy.id, secondLegacy.id])
    }

    @Test
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
        let cloudConfigurationRecord = try #require(
            records.first { $0.recordType == "Configuration" })
        let localEdit = makeSnapshot(
            previousCommandAction: .previousChapter,
            nextCommandAction: .nextChapter
        )
        try await fixture.configuration.apply(localEdit)

        try await fixture.store.applyFetchedRecord(
            cloudConfigurationRecord,
            persistSystemFields: true
        )
        let preserved = await fixture.configuration.snapshot()
        let conflict = await fixture.store.configurationConflict()

        #expect(preserved == localEdit)
        #expect(
            conflict
                == CloudConfigurationConflict(
                    local: localEdit,
                    iCloud: makeSnapshot(
                        previousCommandAction: .skipBackward,
                        nextCommandAction: .skipForward
                    )
                ))
    }

    @Test
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
        let clientRecord = try #require(
            records.first { $0.recordType == "Configuration" })
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

        #expect(pending.isEmpty)
        #expect(cached === serverRecord)
    }

    @Test
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
        let clientRecord = try #require(
            records.first { $0.recordType == "Configuration" })
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
        let cached = try #require(cachedValue)
        let cachedData = try #require(
            cached[PrivateCloudSyncStore.payloadKey] as? Data)

        #expect(pending == [.saveRecord(clientRecord.recordID)])
        #expect(cached === serverRecord)
        #expect(
            try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: cachedData
            ) == localEdit)
    }

    @Test
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
        let clientRecord = try #require(
            records.first { $0.recordType == "Configuration" })
        let clientData = try #require(
            clientRecord[PrivateCloudSyncStore.payloadKey] as? Data)
        let clientJSON = try JSONSerialization.jsonObject(with: clientData)
        let structurallyEquivalentClientData = try JSONSerialization.data(
            withJSONObject: clientJSON,
            options: [.prettyPrinted, .sortedKeys]
        )
        #expect(clientData != structurallyEquivalentClientData)
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

        #expect(pending.isEmpty)
        #expect(
            conflict
                == CloudConfigurationConflict(
                    local: makeSnapshot(
                        previousCommandAction: .skipBackward,
                        nextCommandAction: .skipForward
                    ),
                    iCloud: serverSnapshot
                ))
    }

    @Test
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
        let record = try #require(
            records.first { $0.recordType == "Configuration" })
        let cloud = makeSnapshot(
            previousCommandAction: .nextChapter,
            nextCommandAction: .previousChapter
        )
        record[PrivateCloudSyncStore.payloadKey] =
            try JSONEncoder().encode(cloud) as CKRecordValue
        try await fixture.store.applyFetchedRecord(
            record, persistSystemFields: true)

        let outgoing = try await fixture.store.resolveConfigurationConflict(
            .useICloud
        )
        let remainingConflict = await fixture.store.configurationConflict()
        let applied = await fixture.configuration.snapshot()

        #expect(outgoing == nil)
        #expect(remainingConflict == nil)
        #expect(applied == cloud)
    }

    @Test
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
        let record = try #require(
            records.first { $0.recordType == "Configuration" })
        let local = makeSnapshot(
            previousCommandAction: .previousChapter,
            nextCommandAction: .nextChapter
        )
        try await fixture.configuration.apply(local)
        try await fixture.store.applyFetchedRecord(
            record, persistSystemFields: true)

        let outgoingValue = try await fixture.store
            .resolveConfigurationConflict(.keepThisDevice)
        let outgoing = try #require(outgoingValue)
        let payload = try #require(
            outgoing[PrivateCloudSyncStore.payloadKey] as? Data)

        #expect(
            try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: payload
            ) == local)
        let remainingConflict = await fixture.store.configurationConflict()
        #expect(remainingConflict != nil)
    }

    @Test
    func testExplicitFetchedRecordPersistenceSurvivesStoreRecreation()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        let snapshot = await fixture.configuration.snapshot()
        let prepared = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let record = try #require(
            prepared.first { $0.recordType == "Configuration" })

        try await fixture.store.applyFetchedRecord(
            record,
            persistSystemFields: true
        )
        let restoredStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(
                try #require(UserDefaults(suiteName: fixture.suite))
            )
        )
        let restoredValue = await restoredStore.record(for: record.recordID)
        let restored = try #require(restoredValue)
        #expect(restored.recordID == record.recordID)
        #expect(restored.recordType == record.recordType)
        #expect(
            try JSONDecoder().decode(
                CloudConfigurationSnapshot.self,
                from: #require(
                    restored[PrivateCloudSyncStore.payloadKey] as? Data)
            ) == snapshot)
        let pending = try await restoredStore.prepareRecords(
            zoneID: fixture.zoneID
        )
        #expect(pending.isEmpty)
    }

    @Test
    func testBatchedAccountConflictsPersistCompletedStateAfterRecreation()
        async throws
    {
        let fixture = try makeSyncStoreFixture()
        defer {
            UserDefaults.standard.removePersistentDomain(
                forName: fixture.suite
            )
        }
        for server in ["https://first.example", "https://second.example"] {
            try await fixture.accounts.save(
                makeAccount(server: server, localServer: nil)
            )
        }
        let prepared = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        let accounts = prepared.filter { $0.recordType == "ServerAccount" }
        #expect(accounts.count == 2)
        let serverRecords = accounts.map { client in
            let server = CKRecord(
                recordType: client.recordType,
                recordID: client.recordID
            )
            server[PrivateCloudSyncStore.payloadKey] =
                client[PrivateCloudSyncStore.payloadKey]
            return server
        }
        let pending = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: prepared.filter { $0.recordType != "ServerAccount" },
            deletedRecordIDs: [],
            failedRecordSaves: zip(accounts, serverRecords).map {
                client, server in
                (
                    record: client,
                    error: serverConflictError(
                        clientRecord: client,
                        serverRecord: server
                    )
                )
            },
            failedRecordDeletes: [:]
        )
        #expect(pending.isEmpty)
        let restoredStore = PrivateCloudSyncStore(
            statistics: fixture.statistics,
            accounts: fixture.accounts,
            credentialStore: nil,
            configuration: fixture.configuration,
            defaults: PrivateCloudDefaultsReference(
                try #require(UserDefaults(suiteName: fixture.suite))
            )
        )
        for server in serverRecords {
            let restoredValue = await restoredStore.record(for: server.recordID)
            let restored = try #require(restoredValue)
            #expect(restored.recordID == server.recordID)
            #expect(restored.recordType == server.recordType)
            #expect(
                try JSONDecoder().decode(
                    CloudServerAccountRecordPayload.self,
                    from: #require(
                        restored[PrivateCloudSyncStore.payloadKey] as? Data)
                )
                    == (try JSONDecoder().decode(
                        CloudServerAccountRecordPayload.self,
                        from: #require(
                            server[PrivateCloudSyncStore.payloadKey] as? Data)
                    )))
        }
        let nextSync = try await restoredStore.prepareRecords(
            zoneID: fixture.zoneID
        )
        #expect(nextSync.isEmpty)
    }

    @Test
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

        #expect(restored?.recordID == recordID)
        #expect(restored?.recordType == "Configuration")
    }

    @Test
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
        #expect(initial.map(\.recordType) == ["Configuration"])

        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: initial,
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )

        let unchanged = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        #expect(unchanged.isEmpty)

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
        #expect(unchangedAfterRelaunch.isEmpty)
    }

    @Test
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

        #expect(retry.map(\.recordID) == initial.map(\.recordID))
    }

    @Test
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

        #expect(changed.map(\.recordType) == ["Configuration"])
    }

    @Test
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
        #expect(
            Set(initial.map(\.recordType)) == [
                "ListeningSlice", "Configuration",
            ])

        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: initial,
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )

        let unchanged = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        #expect(unchanged.isEmpty)
    }

    @Test
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

        #expect(prepared.contains { $0.recordType == "ListeningSlice" })
    }

    @Test
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
        let sliceRecord = try #require(
            initial.first { $0.recordType == "ListeningSlice" })
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
        #expect(reconciliation.map(\.recordType) == ["ListeningSlice"])

        _ = try await restoredStore.reconcileSentRecordZoneChanges(
            savedRecords: reconciliation,
            deletedRecordIDs: [],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        let nextSync = try await restoredStore.prepareRecords(
            zoneID: fixture.zoneID
        )
        #expect(nextSync.isEmpty)
    }

    @Test
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
        #expect(initial == [.deleteRecord(recordID)])
        #expect(retry == initial)

        _ = try await fixture.store.reconcileSentRecordZoneChanges(
            savedRecords: [],
            deletedRecordIDs: [recordID],
            failedRecordSaves: [],
            failedRecordDeletes: [:]
        )
        let confirmed = try await fixture.store.prepareDeletionChanges(
            zoneID: fixture.zoneID
        )
        #expect(confirmed.isEmpty)
    }

    @Test
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
        #expect(archive.slices.isEmpty)
        let deletions = try await fixture.store.prepareDeletionChanges(
            zoneID: fixture.zoneID
        )
        #expect(deletions.count == 1)
    }

    @Test
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
            Issue.record("Expected the invalid fetched record to be reported")
        } catch let error as PrivateCloudSyncError {
            #expect(error == .invalidRecord)
        }

        let archive = try await fixture.statistics.archive()
        #expect(archive.slices == [slice])
    }

    @Test
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
        #expect(unchanged.isEmpty)

        try await fixture.store.removeAllRecords()

        let afterZoneDeletion = try await fixture.store.prepareRecords(
            zoneID: fixture.zoneID
        )
        #expect(
            afterZoneDeletion.contains { $0.recordType == "ListeningSlice" })
    }

    @Test
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

        #expect(
            recordIDs.contains {
                $0.recordName
                    == "slice.\(slice.id.uuidString.lowercased())"
            })
    }

    @Test
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

        #expect(
            recordIDs.map(\.recordName) == [
                "slice.\(slice.id.uuidString.lowercased())"
            ])
    }

    @Test
    func testNestedFailurePreservesSpecificOperation() {
        let stageFailure = PrivateCloudSyncFailure(
            operation: .fetchChanges,
            cause: .cloudKit(CloudKitFailure(CKError(.networkFailure)))
        )

        let mapped = PrivateCloudSyncCoordinator.mappedFailure(
            operation: .synchronize,
            error: stageFailure
        )

        #expect(mapped == stageFailure)
    }

    @Test
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

        #expect(archive.slices.count == 100)
        #expect(archive.completions.count == 100)
    }

    @Test
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
        let clientRecord = try #require(
            records.first { $0.recordType == "Configuration" })
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

        #expect(
            restoredConflict
                == CloudConfigurationConflict(
                    local: makeSnapshot(
                        previousCommandAction: .skipBackward,
                        nextCommandAction: .skipForward
                    ),
                    iCloud: cloud
                ))
        #expect(!(prepared.contains { $0.recordType == "Configuration" }))
    }

    @Test
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
            Issue.record("Expected invalid persisted conflict to stop uploads")
        } catch let error as PrivateCloudSyncError {
            #expect(error == .invalidRecord)
        }
    }

    @Test
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
            Issue.record("Expected invalid persisted conflict to stop uploads")
        } catch let error as PrivateCloudSyncError {
            #expect(error == .invalidRecord)
        }

        try await restoredStore.removeAllRecords()

        #expect(fixture.defaults.data(forKey: conflictKey) == nil)
        let preparedAfterDeletion = try await restoredStore.prepareRecords(
            zoneID: fixture.zoneID
        )
        #expect(
            preparedAfterDeletion.contains {
                $0.recordType == "Configuration"
            })
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
        #expect(prepared.contains { $0.recordType == "Configuration" })
    }

    private func makeSuite() -> String {
        "PrivateCloudSyncTests.\(UUID().uuidString)"
    }

    private func makeStore(
        suite: String
    ) throws -> CloudConfigurationStore {
        let defaults = try #require(UserDefaults(suiteName: suite))
        return CloudConfigurationStore(defaults: defaults)
    }

    private func makeSnapshot(
        previousCommandAction: HeadphoneCommandAction,
        nextCommandAction: HeadphoneCommandAction,
        maximumConcurrentDownloads: Int = 5,
        automaticDownloadLookahead: Int = 5
    ) -> CloudConfigurationSnapshot {
        CloudConfigurationSnapshot(
            defaultPlaybackRate: 1,
            resumeRewindSeconds: 10,
            skipBackwardSeconds: 15,
            skipForwardSeconds: 30,
            previousCommandAction: previousCommandAction,
            nextCommandAction: nextCommandAction,
            downloadNetworkPolicy: "wifiOnly",
            maximumConcurrentDownloads: maximumConcurrentDownloads,
            automaticDownloadLookahead: automaticDownloadLookahead,
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
        let configurationDefaults = try #require(UserDefaults(suiteName: suite))
        let recordDefaults = try #require(UserDefaults(suiteName: suite))
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

private actor FetchedBatchCheckpoint {
    private var count = 0
    private let failAt: Int

    init(failAt: Int) { self.failAt = failAt }

    func check() throws {
        count += 1
        if count == failAt { throw PrivateCloudSyncError.callbackTimedOut }
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
