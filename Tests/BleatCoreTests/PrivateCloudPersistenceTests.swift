import CloudKit
import Foundation
import SwiftData
import Testing

@testable import BleatCore

@Suite(.serialized)
struct PrivateCloudPersistenceTests {
    private func fixture(
        domains: inout OwnedDefaultsDomains,
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
        let defaults = try domains.make()
        let store = PrivateCloudSyncStore(
            statistics: StatisticsRepository(modelContainer: container),
            accounts: AccountStore(modelContainer: container),
            credentialStore: nil,
            configuration: CloudConfigurationStore(
                defaults: try domains.make()),
            defaults: PrivateCloudDefaultsReference(defaults),
            migrationBatchDidCommit: checkpoint)
        return (container, defaults, store)
    }

    private enum DefaultsOperationError: Error, Equatable {
        case afterData
        case afterConfiguration
    }

    @Test(
        arguments: [nil, .afterData, .afterConfiguration]
            as [DefaultsOperationError?])
    private func ownedDefaultsAreRemovedOnSuccessAndThrowingExit(
        failure: DefaultsOperationError?
    ) throws {
        let unrelatedName = UUID().uuidString
        let unrelated = try #require(UserDefaults(suiteName: unrelatedName))
        defer { unrelated.removePersistentDomain(forName: unrelatedName) }
        unrelated.set("preserved", forKey: "sentinel")
        var owned: [(String, UserDefaults)] = []
        func operation() throws {
            var domains = OwnedDefaultsDomains()
            defer { domains.removeAll() }
            let data = try domains.make()
            owned.append((try #require(domains.names.last), data))
            data.set("data", forKey: "sentinel")
            #expect(
                data.persistentDomain(forName: owned[0].0)?["sentinel"]
                    as? String == "data")
            if failure == .afterData { throw DefaultsOperationError.afterData }
            let configuration = try domains.make()
            owned.append((try #require(domains.names.last), configuration))
            configuration.set("configuration", forKey: "sentinel")
            #expect(
                configuration.persistentDomain(forName: owned[1].0)?["sentinel"]
                    as? String == "configuration")
            if failure == .afterConfiguration {
                throw DefaultsOperationError.afterConfiguration
            }
        }
        do {
            try operation()
            #expect(failure == nil)
        } catch let error as DefaultsOperationError {
            #expect(error == failure)
        }
        #expect(owned.count == (failure == .afterData ? 1 : 2))
        #expect(Set(owned.map { $0.0 }).count == owned.count)
        for (name, defaults) in owned {
            #expect(defaults.persistentDomain(forName: name)?.isEmpty != false)
        }
        #expect(
            unrelated.persistentDomain(forName: unrelatedName)?["sentinel"]
                as? String == "preserved")
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
        var domains = OwnedDefaultsDomains()
        defer { domains.removeAll() }
        let (container, defaults, store) = try fixture(domains: &domains)
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
                defaults: try domains.make()),
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
        var domains = OwnedDefaultsDomains()
        defer { domains.removeAll() }
        let (container, defaults, store) = try fixture(
            domains: &domains,
            checkpoint: { count in
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
                defaults: try domains.make()),
            defaults: PrivateCloudDefaultsReference(defaults))
        try await restarted.prepareStorage()
        #expect(
            try ModelContext(container).fetchCount(
                FetchDescriptor<PrivateCloudRecordMetadata>()) == 201)
    }

    @Test func malformedStoredStateDoesNotBecomeAnEmptyDefault() throws {
        var domains = OwnedDefaultsDomains()
        defer { domains.removeAll() }
        let (container, _, _) = try fixture(domains: &domains)
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
            var domains = OwnedDefaultsDomains()
            defer { domains.removeAll() }
            let (container, _, store) = try fixture(domains: &domains)
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
        var domains = OwnedDefaultsDomains()
        defer { domains.removeAll() }
        let (_, defaults, store) = try fixture(domains: &domains)
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

    @Test(.enabled(if: ReadOnlyMigrationChild.shouldRun))
    func failedMigrationSaveRetainsLegacyPreferences() async throws {
        if let marker = ProcessInfo.processInfo.environment[
            ReadOnlyMigrationChild.environmentKey]
        {
            try await ReadOnlyMigrationChild.perform(raw: marker)
            return
        }
        let result = await ReadOnlyMigrationChild.run()
        #expect(result.failures.isEmpty)
        #expect(result.cleanupFailures.isEmpty)
        #expect(result.resourcesRemoved)
        #expect(result.preferencesVerified)
        #expect(result.readersClosed && result.writersClosed)
        guard case .exited(let exit) = result.state else {
            Issue.record("Migration child exit/reap was not observed")
            return
        }
        #expect(exit.reason == .normal && exit.status == 0)
    }

    @Test
    func partialMigrationRetainsSourceAndResumesWithoutLosingCommittedRows()
        async throws
    {
        var domains = OwnedDefaultsDomains()
        defer { domains.removeAll() }
        let (container, defaults, store) = try fixture(domains: &domains)
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
        var domains = OwnedDefaultsDomains()
        defer { domains.removeAll() }
        let (container, defaults, store) = try fixture(domains: &domains)
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
        var domains = OwnedDefaultsDomains()
        defer { domains.removeAll() }
        let (_, defaults, store) = try fixture(domains: &domains)
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
        var domains = OwnedDefaultsDomains()
        defer { domains.removeAll() }
        for legacyAcknowledged in [false, true] {
            let defaults = try domains.make()
            let name = try #require(domains.names.last)
            #expect(!CloudStorageUpgradeNotice.isPending(in: defaults))
            if legacyAcknowledged {
                // Persist the exact old dismissed shape, without invoking the
                // current acknowledgement API to manufacture a legacy fixture.
                defaults.setPersistentDomain(
                    [
                        "bleat.cloudStorageUpgrade.v2.detected": true,
                        "bleat.cloudStorageUpgrade.v2.acknowledged": true,
                        "unrelated": "preserved",
                    ], forName: name)
            } else {
                CloudStorageUpgradeNotice.detectLegacy(in: defaults)
            }
            let reopened = try #require(UserDefaults(suiteName: name))
            #expect(CloudStorageUpgradeNotice.isPending(in: reopened))
            CloudStorageUpgradeNotice.detectLegacy(in: reopened)
            #expect(CloudStorageUpgradeNotice.isPending(in: reopened))
            CloudStorageUpgradeNotice.acknowledge(in: reopened)
            let confirmed = try #require(UserDefaults(suiteName: name))
            CloudStorageUpgradeNotice.detectLegacy(in: confirmed)
            #expect(!CloudStorageUpgradeNotice.isPending(in: confirmed))
            #expect(
                confirmed.persistentDomain(forName: name)?[
                    "bleat.cloudStorageUpgrade.v3.acknowledged"] as? Bool
                    == true)
            #expect(
                confirmed.bool(
                    forKey: "bleat.cloudStorageUpgrade.v2.acknowledged")
                    == legacyAcknowledged)
            if legacyAcknowledged {
                #expect(confirmed.string(forKey: "unrelated") == "preserved")
            }
            let otherInstallation = try domains.make()
            CloudStorageUpgradeNotice.detectLegacy(in: otherInstallation)
            #expect(CloudStorageUpgradeNotice.isPending(in: otherInstallation))
        }
        #expect(CloudStorageUpgradeNotice.introducedInVersion == "2026.10.14")
    }

    @Test func twoHundredMetadataChangesDoNotRewriteFiftyEightThousandRows()
        throws
    {
        var domains = OwnedDefaultsDomains()
        defer { domains.removeAll() }
        let (container, defaults, _) = try fixture(domains: &domains)
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

private struct OwnedDefaultsDomains {
    private(set) var names: [String] = []

    mutating func make() throws -> UserDefaults {
        let name = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        names.append(name)
        return defaults
    }

    func removeAll() {
        for name in names {
            UserDefaults().removePersistentDomain(forName: name)
        }
    }
}
