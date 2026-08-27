import Foundation
import SwiftData
import XCTest

@testable import BleatCore

final class PersistenceMigrationTests: XCTestCase {
    func testReleasedStoreFixturesOpenWithCurrentCatalog() throws {
        for version in [
            BleatPersistenceSchemaVersion.v0_1_1,
            .v0_1_2,
            .v0_1_3,
        ] {
            try assertReleasedStoreFixtureMigrates(version: version)
        }
    }

    private func assertReleasedStoreFixtureMigrates(
        version: BleatPersistenceSchemaVersion
    ) throws {
        let fixture = try fixture(for: version)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("Bleat.store")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        do {
            let releasedSchema = Schema(versionedSchema: schema(for: version))
            let releasedContainer = try container(
                schema: releasedSchema,
                storeURL: storeURL
            )
            let releasedContext = ModelContext(releasedContainer)
            insertFixture(
                fixture,
                for: version,
                into: releasedContext
            )
            try releasedContext.save()
        }

        let currentSchema = Schema(
            versionedSchema: BleatPersistenceSchemaCurrent.self
        )
        let currentContainer = try container(
            schema: currentSchema,
            storeURL: storeURL,
            migrationPlan: BleatPersistenceSchemaMigrationPlan.self
        )
        let currentContext = ModelContext(currentContainer)
        let accounts = try currentContext.fetch(
            FetchDescriptor<ServerAccountRecord>(
                sortBy: [SortDescriptor(\.accountID)]
            )
        )
        let collections = try currentContext.fetch(
            FetchDescriptor<CachedLibraryCollectionRecord>(
                sortBy: [SortDescriptor(\.accountID)]
            )
        )

        XCTAssertEqual(accounts.map(\.accountID), fixture.accounts.map(\.id))
        XCTAssertEqual(collections.map(\.accountID), fixture.accounts.map(\.id))
        XCTAssertEqual(
            try currentContext.fetchCount(
                FetchDescriptor<CachedChapterTranscriptionTaskRecord>()
            ),
            version == .v0_1_1 ? 0 : 1
        )
    }

    private func container(
        schema: Schema,
        storeURL: URL,
        migrationPlan: (any SchemaMigrationPlan.Type)? = nil
    ) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: migrationPlan,
            configurations: [
                ModelConfiguration(
                    schema: schema,
                    url: storeURL,
                    cloudKitDatabase: .none
                )
            ]
        )
    }

    private func schema(
        for version: BleatPersistenceSchemaVersion
    ) -> any VersionedSchema.Type {
        switch version {
        case .v0_1_1:
            BleatPersistenceSchemaV0_1_1.self
        case .v0_1_2:
            BleatPersistenceSchemaV0_1_2.self
        case .v0_1_3:
            BleatPersistenceSchemaV0_1_3.self
        }
    }

    private func insertFixture(
        _ fixture: PersistenceMigrationFixture,
        for version: BleatPersistenceSchemaVersion,
        into context: ModelContext
    ) {
        for (index, account) in fixture.accounts.enumerated() {
            context.insert(
                BleatPersistenceSchemaV0_1_1.ServerAccountRecord(
                    accountID: account.id,
                    serverURL: account.server,
                    remoteUserID: account.user,
                    profileData: Data("redacted-profile-\(index)".utf8),
                    isActiveBrowsingAccount: index == 0
                )
            )
            context.insert(
                BleatPersistenceSchemaV0_1_1.CachedLibraryCollectionRecord(
                    accountID: account.id,
                    refreshedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        }
        if version != .v0_1_1 {
            context.insert(
                BleatPersistenceSchemaV0_1_2.CachedChapterTranscriptionTaskRecord(
                    taskKey: "migration-account-a\u{1f}book",
                    accountID: "migration-account-a",
                    libraryItemID: "book",
                    payload: Data("redacted-task".utf8),
                    finishedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            )
        }
    }

    private func fixture(
        for version: BleatPersistenceSchemaVersion
    ) throws -> PersistenceMigrationFixture {
        let filename = "\(version.rawValue).json"
        let url = try XCTUnwrap(
            Bundle.module.urls(
                forResourcesWithExtension: "json",
                subdirectory: nil
            )?.first(where: { $0.lastPathComponent == filename })
        )
        return try JSONDecoder().decode(
            PersistenceMigrationFixture.self,
            from: Data(contentsOf: url)
        )
    }
}

private enum BleatPersistenceSchemaVersion: String, CaseIterable, Sendable {
    case v0_1_1 = "0.1.1"
    case v0_1_2 = "0.1.2"
    case v0_1_3 = "0.1.3"
}

private struct PersistenceMigrationFixture: Decodable {
    let accounts: [Account]

    struct Account: Decodable {
        let id: String
        let server: String
        let user: String
    }
}
