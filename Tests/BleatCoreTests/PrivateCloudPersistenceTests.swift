import CloudKit
import Foundation
import SwiftData
import Testing

@testable import BleatCore

@Suite(.serialized)
struct PrivateCloudPersistenceTests {
    private func fixture(
        checkpoint: (@Sendable (Int) async throws -> Void)? = nil
    ) throws -> (
        ModelContainer, UserDefaults, PrivateCloudSyncStore
    ) {
        let schema = Schema(BleatPersistenceModelCatalog.allModelTypes)
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema, isStoredInMemoryOnly: true,
                    cloudKitDatabase: .none)
            ])
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let store = PrivateCloudSyncStore(
            statistics: StatisticsRepository(modelContainer: container),
            accounts: AccountStore(modelContainer: container),
            credentialStore: nil,
            configuration: CloudConfigurationStore(
                defaults: try #require(
                    UserDefaults(suiteName: UUID().uuidString))),
            defaults: PrivateCloudDefaultsReference(defaults),
            migrationBatchDidCommit: checkpoint)
        return (container, defaults, store)
    }

    private func record(_ name: String) -> CKRecord {
        CKRecord(
            recordType: "ListeningSlice",
            recordID: CKRecord.ID(
                recordName: name,
                zoneID: CKRecordZone.ID(
                    zoneName: "test", ownerName: CKCurrentUserDefaultName)))
    }

    @Test func migrationCopiesOpaqueArchivesAndRemovesOnlyVerifiedSources()
        async throws
    {
        let (container, defaults, store) = try fixture()
        let record = record("slice.\(UUID().uuidString.lowercased())")
        let data = PrivateCloudPersistence.encodeSystemFields(record)
        defaults.set(
            [record.recordID.recordName: data],
            forKey: PrivateCloudPersistence.metadataKey)
        defaults.set(
            ["account": "canonical"],
            forKey: "bleat.cloudKit.legacyAccountIdentityMappings.v1")
        defaults.set("preserved preference", forKey: "unrelated")
        try await store.prepareStorage()
        let storage = PrivateCloudPersistence(container: container)
        #expect(try storage.metadata(record.recordID)?.systemFields == data)
        #expect(try storage.migrationComplete())
        #expect(
            defaults.object(forKey: PrivateCloudPersistence.metadataKey) == nil)
        #expect(defaults.string(forKey: "unrelated") == "preserved preference")
        #expect(CloudStorageUpgradeNotice.isPending(in: defaults))
        let restored = PrivateCloudSyncStore(
            statistics: StatisticsRepository(modelContainer: container),
            accounts: AccountStore(modelContainer: container),
            credentialStore: nil,
            configuration: CloudConfigurationStore(
                defaults: try #require(
                    UserDefaults(suiteName: UUID().uuidString))),
            defaults: PrivateCloudDefaultsReference(defaults))
        try await restored.prepareStorage()
        #expect(
            try await restored.record(for: record.recordID)?.recordID
                == record.recordID)
    }

    @Test func cancelledMigrationRetainsCommittedProgressAndCoalescesCallers()
        async throws
    {
        let probe = MigrationCancellationProbe()
        let (container, defaults, store) = try fixture(checkpoint: { count in
            try await probe.checkpoint(count)
        })
        var archives: [String: Data] = [:]
        for index in 0..<201 {
            let value = record(String(format: "a%04d", index))
            archives[value.recordID.recordName] =
                PrivateCloudPersistence.encodeSystemFields(value)
        }
        defaults.set(archives, forKey: PrivateCloudPersistence.metadataKey)
        let taskCompletions = BoundedTestCounter()
        let first = Task {
            do {
                try await store.prepareStorage()
                await taskCompletions.increment()
            } catch {
                await taskCompletions.increment()
                throw error
            }
        }
        let second = Task {
            do {
                try await store.prepareStorage()
                await taskCompletions.increment()
            } catch {
                await taskCompletions.increment()
                throw error
            }
        }
        let checkpointWait = await probe.waitForEntry()
        #expect(
            checkpointWait.reached,
            "migration did not reach the 200-record checkpoint within \(checkpointWait.timeout); elapsed \(checkpointWait.elapsed)"
        )
        guard checkpointWait.reached else {
            await store.cancelStoragePreparation()
            let cleanupWait = await taskCompletions.wait(
                untilAtLeast: 2, timeout: .seconds(5))
            #expect(
                cleanupWait.reached,
                "cancelled migration callers did not finish; elapsed \(cleanupWait.elapsed), limit \(cleanupWait.timeout)"
            )
            return
        }
        let responsive = await MainActor.run { true }
        #expect(responsive)
        await store.cancelStoragePreparation()
        let completionWait = await taskCompletions.wait(
            untilAtLeast: 2, timeout: .seconds(5))
        #expect(
            completionWait.reached,
            "migration callers did not observe cancellation; elapsed \(completionWait.elapsed), limit \(completionWait.timeout)"
        )
        guard completionWait.reached else { return }
        for task in [first, second] {
            do {
                try await task.value
                Issue.record("Cancelled migration must stop")
            } catch { #expect(error is CancellationError) }
        }
        #expect(
            defaults.dictionary(forKey: PrivateCloudPersistence.metadataKey)?
                .count == 201)
        #expect(
            try ModelContext(container).fetchCount(
                FetchDescriptor<PrivateCloudRecordMetadata>()) == 200)
        let restarted = PrivateCloudSyncStore(
            statistics: StatisticsRepository(modelContainer: container),
            accounts: AccountStore(modelContainer: container),
            credentialStore: nil,
            configuration: CloudConfigurationStore(
                defaults: try #require(
                    UserDefaults(suiteName: UUID().uuidString))),
            defaults: PrivateCloudDefaultsReference(defaults))
        try await restarted.prepareStorage()
        #expect(
            try ModelContext(container).fetchCount(
                FetchDescriptor<PrivateCloudRecordMetadata>()) == 201)
    }

    @Test func malformedStoredStateDoesNotBecomeAnEmptyDefault() throws {
        let (container, _, _) = try fixture()
        let storage = PrivateCloudPersistence(container: container)
        try storage.set(
            "wrong shape", forKey: PrivateCloudPersistence.engineKey)
        do {
            _ = try storage.data(forKey: PrivateCloudPersistence.engineKey)
            Issue.record("Invalid state must fail")
        } catch let error as PrivateCloudSyncError {
            #expect(error == .storage(.invalidStoredState))
        }
        #expect(
            try storage.value(forKey: PrivateCloudPersistence.engineKey)
                as? String == "wrong shape")
    }

    @Test func malformedBookkeepingContentsRemainRetained() async throws {
        for key in [
            "bleat.cloudKit.legacyAccountIdentityMappings.v1",
            "bleat.cloudKit.pendingLegacyRecordDeletions.v1",
        ] {
            let (container, _, store) = try fixture()
            let storage = PrivateCloudPersistence(container: container)
            try storage.set(true, forKey: PrivateCloudPersistence.migrationKey)
            let malformed = ["retained": 42]
            try storage.set(malformed, forKey: key)
            do {
                try await store.prepareStorage()
                Issue.record("Malformed dictionary contents must fail closed")
            } catch let error as PrivateCloudSyncError {
                #expect(error == .storage(.invalidStoredState))
            }
            #expect(
                try storage.dictionary(forKey: key) as? [String: Int]
                    == malformed)
        }
    }

    @Test
    func secureArchiveWithMissingRequiredFieldsFailsWithoutAFrameworkTrap()
        async throws
    {
        let (_, defaults, store) = try fixture()
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        archiver.encode(
            "valid archive, absent record metadata", forKey: "unrelated")
        archiver.finishEncoding()
        defaults.set(
            ["retained": archiver.encodedData],
            forKey: PrivateCloudPersistence.metadataKey)
        do {
            try await store.prepareStorage()
            Issue.record("Missing required fields must fail")
        } catch let error as PrivateCloudSyncError {
            #expect(error == .storage(.invalidLegacyMetadata))
        }
        #expect(
            defaults.object(forKey: PrivateCloudPersistence.metadataKey) != nil)
    }

    @Test func nativeStorageFailureRetainsItsSpecificDomainCodeAndStage() {
        let native = NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let failure = PrivateCloudSyncFailure(
            operation: .migrateLocalState,
            cause: .storage(
                .metadataWriteFailed(PrivateCloudSystemError(native))))
        let event = DiagnosticEvent.privateCloudFailed(
            failure: failure,
            correlationID: UUID(), durationMilliseconds: 0)
        #expect(event.failureCode == .privateCloudMetadataWriteFailed)
        #expect(event.privateCloud?.operation == .migrateLocalState)
        #expect(event.privateCloud?.unexpectedErrorDomain == NSCocoaErrorDomain)
        #expect(
            event.privateCloud?.unexpectedErrorCode
                == NSFileWriteNoPermissionError)
        #expect(!event.text.contains("UserInfo"))
    }

    @Test func failedMigrationSaveRetainsLegacyPreferences() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema(BleatPersistenceModelCatalog.allModelTypes)
        let url = root.appendingPathComponent("read-only.store")
        do {
            _ = try ModelContainer(
                for: schema,
                configurations: [
                    ModelConfiguration(
                        schema: schema, url: url, cloudKitDatabase: .none)
                ])
        }
        let container = try ModelContainer(
            for: schema,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    url: url, allowsSave: false, cloudKitDatabase: .none)
            ])
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        let value = record("retained")
        defaults.set(
            ["retained": PrivateCloudPersistence.encodeSystemFields(value)],
            forKey: PrivateCloudPersistence.metadataKey)
        let store = PrivateCloudSyncStore(
            statistics: StatisticsRepository(modelContainer: container),
            accounts: AccountStore(modelContainer: container),
            credentialStore: nil,
            configuration: CloudConfigurationStore(
                defaults: try #require(
                    UserDefaults(suiteName: UUID().uuidString))),
            defaults: PrivateCloudDefaultsReference(defaults))
        do {
            try await store.prepareStorage()
            Issue.record("Read-only save must fail")
        } catch let error as PrivateCloudSyncError {
            guard case .storage(.metadataWriteFailed(let native)) = error else {
                Issue.record("Wrong failure kind")
                return
            }
            #expect(native.domain == NSCocoaErrorDomain)
            #expect(native.code == NSFileWriteNoPermissionError)
        }
        #expect(
            defaults.object(forKey: PrivateCloudPersistence.metadataKey) != nil)
        #expect(
            !(try PrivateCloudPersistence(container: container)
                .migrationComplete()))
    }

    @Test
    func partialMigrationRetainsSourceAndResumesWithoutLosingCommittedRows()
        async throws
    {
        let (container, defaults, store) = try fixture()
        var archives: [String: Data] = [:]
        for index in 0..<200 {
            let value = record(String(format: "a%04d", index))
            archives[value.recordID.recordName] =
                PrivateCloudPersistence.encodeSystemFields(value)
        }
        archives["z-invalid"] = Data([0, 1])
        defaults.set(archives, forKey: PrivateCloudPersistence.metadataKey)
        do {
            try await store.prepareStorage()
            Issue.record("Malformed archive must stop migration")
        } catch let error as PrivateCloudSyncError {
            #expect(error == .storage(.invalidLegacyMetadata))
        }
        #expect(
            defaults.dictionary(forKey: PrivateCloudPersistence.metadataKey)?
                .count == 201)
        #expect(
            try ModelContext(container).fetchCount(
                FetchDescriptor<PrivateCloudRecordMetadata>()) == 200)
        #expect(
            !(try PrivateCloudPersistence(container: container)
                .migrationComplete()))
        let repaired = record("z-invalid")
        archives["z-invalid"] = PrivateCloudPersistence.encodeSystemFields(
            repaired)
        defaults.set(archives, forKey: PrivateCloudPersistence.metadataKey)
        try await store.prepareStorage()
        #expect(
            try ModelContext(container).fetchCount(
                FetchDescriptor<PrivateCloudRecordMetadata>()) == 201)
        #expect(
            defaults.object(forKey: PrivateCloudPersistence.metadataKey) == nil)
    }

    @Test func malformedCoordinatorStateRetainsAllLegacyData() async throws {
        let (container, defaults, store) = try fixture()
        let value = record("retained")
        defaults.set(
            ["retained": PrivateCloudPersistence.encodeSystemFields(value)],
            forKey: PrivateCloudPersistence.metadataKey)
        defaults.set(Data([0, 1]), forKey: PrivateCloudPersistence.engineKey)
        do {
            try await store.prepareStorage()
            Issue.record("Invalid engine state must stop migration")
        } catch let error as PrivateCloudSyncError {
            #expect(error == .storage(.invalidLegacyState))
        }
        #expect(
            defaults.object(forKey: PrivateCloudPersistence.metadataKey) != nil)
        #expect(
            defaults.data(forKey: PrivateCloudPersistence.engineKey)
                == Data([0, 1]))
        #expect(
            !(try PrivateCloudPersistence(container: container)
                .migrationComplete()))
    }

    @Test func migrationRejectsArchiveIdentityMismatchWithoutDiscardingSource()
        async throws
    {
        let (_, defaults, store) = try fixture()
        defaults.set(
            [
                "wrong": PrivateCloudPersistence.encodeSystemFields(
                    record("right"))
            ], forKey: PrivateCloudPersistence.metadataKey)
        do {
            try await store.prepareStorage()
            Issue.record("Mismatched archive must be retained")
        } catch let error as PrivateCloudSyncError {
            #expect(error == .storage(.invalidLegacyMetadata))
        }
        #expect(
            defaults.dictionary(forKey: PrivateCloudPersistence.metadataKey)?
                .count == 1)
    }

    @Test func upgradeNoticeAcknowledgmentSurvivesRepeatedLegacyDetection()
        throws
    {
        let (_, defaults, _) = try fixture()
        #expect(!CloudStorageUpgradeNotice.isPending(in: defaults))
        CloudStorageUpgradeNotice.detectLegacy(in: defaults)
        #expect(CloudStorageUpgradeNotice.isPending(in: defaults))
        CloudStorageUpgradeNotice.acknowledge(in: defaults)
        CloudStorageUpgradeNotice.detectLegacy(in: defaults)
        #expect(!CloudStorageUpgradeNotice.isPending(in: defaults))
        #expect(CloudStorageUpgradeNotice.introducedInVersion == "2026.10.14")
    }

    @Test func twoHundredMetadataChangesDoNotRewriteFiftyEightThousandRows()
        throws
    {
        let (container, defaults, _) = try fixture()
        let storage = PrivateCloudPersistence(container: container)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var changed: [CKRecord] = []
        for index in 0..<58_404 {
            let value = record("slice.\(index)")
            let fields = PrivateCloudPersistence.encodeSystemFields(value)
            context.insert(
                PrivateCloudRecordMetadata(
                    record: value, systemFields: fields,
                    accountID: nil, digest: nil, payload: nil))
            if index < 200 { changed.append(value) }
        }
        try context.save()
        let sentinel = record("slice.58403")
        let before = try #require(
            storage.metadata(sentinel.recordID)?.systemFields)
        let digests = Dictionary(
            uniqueKeysWithValues: changed.map {
                ($0.recordID.recordName, Data([1]))
            })
        try storage.commit(records: changed, deleted: [], digests: digests)
        let verification = ModelContext(container)
        #expect(
            try verification.fetchCount(
                FetchDescriptor<PrivateCloudRecordMetadata>()) == 58_404)
        #expect(
            try verification.fetchCount(
                FetchDescriptor<PrivateCloudRecordMetadata>(
                    predicate: #Predicate { $0.synchronizedDigest != nil }))
                == 200)
        #expect(try storage.metadata(sentinel.recordID)?.systemFields == before)
        #expect(
            defaults.object(forKey: PrivateCloudPersistence.metadataKey) == nil)
    }
}

private actor MigrationCancellationProbe {
    private let checkpointEntries = BoundedTestCounter()

    func checkpoint(_ count: Int) async throws {
        #expect(count == 200)
        await checkpointEntries.increment()
        try await Task.sleep(for: .seconds(30))
    }

    func waitForEntry() async -> BoundedTestWaitResult {
        await checkpointEntries.wait(untilAtLeast: 1)
    }
}
