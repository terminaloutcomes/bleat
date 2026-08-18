import CloudKit
import Foundation
import SwiftData
import XCTest
@testable import BleatCore

final class PrivateCloudSyncTests: XCTestCase {
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

    func testFetchedConfigurationDoesNotOverwriteLocalEditSinceBaseline()
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

        XCTAssertEqual(preserved, localEdit)
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
        let configuration = try makeStore(suite: suite)
        return SyncStoreFixture(
            suite: suite,
            zoneID: CKRecordZone.ID(
                zoneName: "test",
                ownerName: CKCurrentUserDefaultName
            ),
            accounts: accounts,
            configuration: configuration,
            store: PrivateCloudSyncStore(
                statistics: StatisticsRepository(
                    modelContainer: container
                ),
                accounts: accounts,
                credentialStore: nil,
                configuration: configuration
            )
        )
    }
}

private struct SyncStoreFixture {
    let suite: String
    let zoneID: CKRecordZone.ID
    let accounts: AccountStore
    let configuration: CloudConfigurationStore
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
