import Foundation
import SwiftData
import XCTest

@testable import BleatCore

final class AccountStoreTests: XCTestCase {
    func testStoresMultipleUsersAndServersWithOneActiveContext()
        async throws
    {
        let fixture = try StoreFixture()
        let first = try Self.account(
            accountID: "first",
            server: "https://one.example/audiobookshelf",
            userID: "user-one",
            username: "Alice"
        )
        let second = try Self.account(
            accountID: "second",
            server: "https://one.example/audiobookshelf",
            userID: "user-two",
            username: "Bob"
        )
        let third = try Self.account(
            accountID: "third",
            server: "https://two.example",
            userID: "user-one",
            username: "Alice"
        )

        try await fixture.store.save(first)
        try await fixture.store.save(second)
        try await fixture.store.save(third, makeActive: true)

        let accounts = try await fixture.store.accounts()
        let active = try await fixture.store.activeAccount()
        XCTAssertEqual(
            Set(accounts.map(\.id)),
            [
                first.id,
                second.id,
                third.id,
            ])
        XCTAssertEqual(active?.id, third.id)

        let relaunched = AccountStore(modelContainer: fixture.container)
        let relaunchedActive = try await relaunched.activeAccount()
        let relaunchedAccounts = try await relaunched.accounts()
        XCTAssertEqual(relaunchedActive?.id, third.id)
        XCTAssertEqual(relaunchedAccounts.count, 3)
    }

    func testRejectsDuplicateRemoteUserOnSameNormalizedServer()
        async throws
    {
        let fixture = try StoreFixture()
        let existing = try Self.account(
            accountID: "existing",
            server: "https://example.com/prefix/",
            userID: "remote-user",
            username: "Reader"
        )
        let duplicate = try Self.account(
            accountID: "duplicate",
            server: "https://EXAMPLE.com/prefix",
            userID: "remote-user",
            username: "Reader"
        )
        try await fixture.store.save(existing)

        do {
            try await fixture.store.save(duplicate)
            XCTFail("Expected duplicate remote account rejection")
        } catch {
            XCTAssertEqual(
                error,
                .duplicateRemoteAccount(
                    existingAccountID: existing.id
                )
            )
        }
        let storedAccounts = try await fixture.store.accounts()
        XCTAssertEqual(storedAccounts, [existing])
    }

    func testConnectionStateAndActiveSelectionPersistAcrossStoreActors()
        async throws
    {
        let fixture = try StoreFixture()
        let first = try Self.account(
            accountID: "a",
            server: "https://a.example",
            userID: "user-a",
            username: "A"
        )
        let second = try Self.account(
            accountID: "b",
            server: "https://b.example",
            userID: "user-b",
            username: "B"
        )
        try await fixture.store.save(first)
        try await fixture.store.save(second)

        try await fixture.store.setConnectionState(
            .reauthenticationRequired,
            for: second.id
        )
        try await fixture.store.setActiveAccount(id: second.id)

        let relaunched = AccountStore(modelContainer: fixture.container)
        let relaunchedSecond = try await relaunched.account(id: second.id)
        let relaunchedActive = try await relaunched.activeAccount()
        XCTAssertEqual(
            relaunchedSecond?.connectionState,
            .reauthenticationRequired
        )
        XCTAssertEqual(relaunchedActive?.id, second.id)
    }

    func testLegacyIdentityMigrationRekeysAccountAndStatistics()
        async throws
    {
        let fixture = try StoreFixture()
        let legacy = try Self.account(
            accountID: "device-generated-id",
            server: "https://example.com/audiobookshelf",
            userID: "remote-user",
            username: "Reader"
        )
        try await fixture.store.save(legacy)
        let statistics = StatisticsRepository(modelContainer: fixture.container)
        let slice = ListeningSlice(
            accountID: legacy.id,
            itemID: LibraryItemID(rawValue: "item"),
            sessionID: PlaybackSessionID(rawValue: "session"),
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
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
        try await statistics.importArchive(
            StatisticsArchive(
                slices: [slice],
                completions: [],
                remoteSessions: []
            )
        )

        let migrations = try await fixture.store.legacyIdentityMigrations()
        try await fixture.store.applyIdentityMigrations(migrations)

        let canonicalID = AccountID.canonical(
            server: legacy.server,
            userID: legacy.user.id
        )
        let removedLegacy = try await fixture.store.account(id: legacy.id)
        let migratedAccount = try await fixture.store.account(id: canonicalID)
        XCTAssertNil(removedLegacy)
        XCTAssertEqual(migratedAccount?.id, canonicalID)
        let archive = try await statistics.privateCloudArchive()
        XCTAssertEqual(archive.slices.map(\.accountID), [canonicalID])
        let aliases = try await fixture.store.identityAliases()
        XCTAssertEqual(
            aliases,
            [
                AccountIdentityMigration(
                    legacyID: legacy.id,
                    canonicalID: canonicalID
                )
            ]
        )
    }

    func testPendingRestoredAccountSurvivesRelaunchInactive() async throws {
        let fixture = try StoreFixture()
        let restored = try Self.account(
            accountID: "restored",
            server: "https://books.example",
            userID: "remote-user",
            username: "Reader"
        )

        try await fixture.store.savePendingRestoredAccount(restored)

        let relaunched = AccountStore(modelContainer: fixture.container)
        let pending = try await relaunched.account(id: restored.id)
        XCTAssertEqual(pending?.connectionState, .reauthenticationRequired)
        let active = try await relaunched.activeAccount()
        XCTAssertNil(active)
    }

    func testContradictoryAliasIsTypedAndPreservesOriginal() async throws {
        let fixture = try StoreFixture()
        let legacy = try Self.account(
            accountID: "legacy",
            server: "https://books.example",
            userID: "remote-user",
            username: "Reader"
        )
        try await fixture.store.save(legacy)
        let first = AccountID(rawValue: "canonical-one")
        _ = try await fixture.store.applyIdentityMigrations([
            AccountIdentityMigration(legacyID: legacy.id, canonicalID: first)
        ])

        do {
            _ = try await fixture.store.applyIdentityMigrations([
                AccountIdentityMigration(
                    legacyID: legacy.id,
                    canonicalID: AccountID(rawValue: "canonical-two")
                )
            ])
            XCTFail("Expected contradictory alias failure")
        } catch {
            XCTAssertEqual(
                error,
                .contradictoryIdentityAlias(
                    legacyID: legacy.id,
                    existingCanonicalID: first,
                    requestedCanonicalID: AccountID(
                        rawValue: "canonical-two"
                    )
                )
            )
        }
        let aliases = try await fixture.store.identityAliases()
        XCTAssertEqual(aliases.first?.canonicalID, first)
    }

    func testLocalServerPersistsWithoutChangingPrimaryIdentity() async throws {
        let fixture = try StoreFixture()
        let account = try Self.account(
            accountID: "local-server",
            server: "https://books.example",
            userID: "user",
            username: "Reader"
        )
        try await fixture.store.save(account)

        let local = try NormalizedServerURL("https://books.home")
        try await fixture.store.setLocalServer(
            local,
            validated: true,
            for: account.id
        )

        let storedAccount = try await fixture.store.account(id: account.id)
        let stored = try XCTUnwrap(storedAccount)
        XCTAssertEqual(stored.server, account.server)
        XCTAssertEqual(stored.localServer, local)
        XCTAssertTrue(stored.localServerValidated)
    }

    func testReplacingPrimaryServerRekeysExistingAccountData() async throws {
        let fixture = try StoreFixture()
        let original = try Self.account(
            accountID: "old-canonical-id",
            server: "https://old.example",
            userID: "remote-user",
            username: "Reader"
        )
        try await fixture.store.save(original)
        let replacementServer = try NormalizedServerURL("https://new.example")
        let replacementID = AccountID.canonical(
            server: replacementServer,
            userID: original.user.id
        )
        let replacement = try ServerAccount(
            id: replacementID,
            server: replacementServer,
            serverVersion: original.serverVersion,
            authenticationMethods: original.authenticationMethods,
            user: original.user
        )

        try await fixture.store.replaceAccountIdentity(
            from: original.id,
            with: replacement
        )

        let removedAccount = try await fixture.store.account(id: original.id)
        let storedReplacement = try await fixture.store.account(
            id: replacementID
        )
        let activeAccount = try await fixture.store.activeAccount()
        XCTAssertNil(removedAccount)
        XCTAssertEqual(storedReplacement, replacement)
        XCTAssertEqual(activeAccount?.id, replacementID)
    }

    func testRemovingActiveAccountSelectsDeterministicReplacement()
        async throws
    {
        let fixture = try StoreFixture()
        let a = try Self.account(
            accountID: "a",
            server: "https://a.example",
            userID: "a",
            username: "A"
        )
        let b = try Self.account(
            accountID: "b",
            server: "https://b.example",
            userID: "b",
            username: "B"
        )
        try await fixture.store.save(a)
        try await fixture.store.save(b, makeActive: true)

        let removed = try await fixture.store.removeAccount(id: b.id)
        let active = try await fixture.store.activeAccount()
        let removedAgain = try await fixture.store.removeAccount(id: b.id)
        let accounts = try await fixture.store.accounts()
        XCTAssertTrue(removed)
        XCTAssertEqual(active?.id, a.id)
        XCTAssertFalse(removedAgain)
        XCTAssertEqual(accounts, [a])
    }

    func testMissingAccountOperationsRemainTyped() async throws {
        let fixture = try StoreFixture()
        let missing = AccountID(rawValue: "missing")

        do {
            try await fixture.store.setActiveAccount(id: missing)
            XCTFail("Expected missing account error")
        } catch {
            XCTAssertEqual(error, .accountNotFound(missing))
        }
        do {
            try await fixture.store.setConnectionState(
                .offline,
                for: missing
            )
            XCTFail("Expected missing account error")
        } catch {
            XCTAssertEqual(error, .accountNotFound(missing))
        }
        let missingAccount = try await fixture.store.account(id: missing)
        let active = try await fixture.store.activeAccount()
        XCTAssertNil(missingAccount)
        XCTAssertNil(active)
    }

    func testCorruptStoredProfileIsRejectedWithoutLeakingPayload()
        async throws
    {
        let fixture = try StoreFixture()
        let context = ModelContext(fixture.container)
        context.insert(
            ServerAccountRecord(
                accountID: "corrupt",
                serverURL: "https://example.com",
                remoteUserID: "user",
                profileData: Data("access-token refresh-token".utf8),
                isActiveBrowsingAccount: true
            ))
        try context.save()

        do {
            _ = try await fixture.store.accounts()
            XCTFail("Expected invalid stored account")
        } catch {
            XCTAssertEqual(
                error,
                .invalidStoredAccount(
                    AccountID(rawValue: "corrupt")
                )
            )
        }
    }

    func testServerAccountValidationAndCodableExcludeCredentials()
        throws
    {
        let valid = try Self.account(
            accountID: "account",
            server: "https://example.com",
            userID: "user",
            username: "Reader"
        )
        let data = try JSONEncoder().encode(valid)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(
            ServerAccount.self,
            from: data
        )

        XCTAssertEqual(decoded, valid)
        XCTAssertTrue(valid.supportsLocalAuthentication)
        XCTAssertFalse(encoded.contains("access-token"))
        XCTAssertFalse(encoded.contains("refresh-token"))
        XCTAssertFalse(encoded.contains("password"))
        let invalidData = try JSONEncoder().encode(
            UncheckedServerAccount(
                id: AccountID(rawValue: ""),
                server: valid.server,
                serverVersion: valid.serverVersion,
                authenticationMethods: valid.authenticationMethods,
                user: valid.user,
                connectionState: valid.connectionState
            )
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                ServerAccount.self,
                from: invalidData
            )
        )

        XCTAssertThrowsError(
            try ServerAccount(
                id: AccountID(rawValue: ""),
                server: valid.server,
                serverVersion: "2.36.0",
                authenticationMethods: [.local],
                user: valid.user
            )
        ) { error in
            XCTAssertEqual(
                error as? ServerAccountValidationError,
                .invalidAccountID
            )
        }
        XCTAssertThrowsError(
            try ServerAccount(
                id: valid.id,
                server: valid.server,
                serverVersion: "not-a-version",
                authenticationMethods: [.local],
                user: valid.user
            )
        ) { error in
            XCTAssertEqual(
                error as? ServerAccountValidationError,
                .invalidServerVersion
            )
        }
        let openIDOnly = try ServerAccount(
            id: valid.id,
            server: valid.server,
            serverVersion: "2.36.0",
            authenticationMethods: [.openID],
            user: valid.user
        )
        XCTAssertFalse(openIDOnly.supportsLocalAuthentication)
        XCTAssertTrue(openIDOnly.supportsOpenIDAuthentication)
    }

    func testLoginPersistsAccountAndCredentialsTransactionally()
        async throws
    {
        let fixture = try StoreFixture()
        let accountID = AccountID(rawValue: "account")
        let credentialStore = OnboardingCredentialStore()
        let transport = OnboardingTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: credentialStore
        )

        let account = try await coordinator.loginAndPersistAccount(
            accountID: accountID,
            discoveredServer: try Self.discoveredServer(),
            username: "reader",
            password: "correct",
            accountStore: fixture.store
        )

        let canonicalID = AccountID.canonical(
            server: account.server,
            userID: account.user.id
        )
        XCTAssertEqual(account.id, canonicalID)
        XCTAssertEqual(account.user.id.rawValue, "remote-user")
        let active = try await fixture.store.activeAccount()
        let storedCredentials = await credentialStore.credentials(
            for: canonicalID
        )
        let deleteCount = await credentialStore.deleteCount()
        XCTAssertEqual(active, account)
        XCTAssertEqual(
            storedCredentials,
            try AuthenticationTokens(
                accessToken: "access-token",
                refreshToken: "refresh-token"
            )
        )
        XCTAssertEqual(deleteCount, 0)
    }

    func testDuplicateOnboardingRollsBackOnlyNewCredentials()
        async throws
    {
        let fixture = try StoreFixture()
        let existing = try Self.account(
            accountID: "existing",
            server: "https://example.com",
            userID: "remote-user",
            username: "reader"
        )
        try await fixture.store.save(existing)
        let newID = AccountID(rawValue: "new")
        let credentialStore = OnboardingCredentialStore()
        let coordinator = AuthCoordinator(
            transport: OnboardingTransport(),
            credentialStore: credentialStore
        )

        do {
            _ = try await coordinator.loginAndPersistAccount(
                accountID: newID,
                discoveredServer: try Self.discoveredServer(),
                username: "reader",
                password: "correct",
                accountStore: fixture.store
            )
            XCTFail("Expected duplicate account persistence failure")
        } catch {
            XCTAssertEqual(
                error as? AccountOnboardingError,
                .accountPersistenceFailed(
                    .duplicateRemoteAccount(
                        existingAccountID: existing.id
                    )
                )
            )
        }

        let canonicalID = AccountID.canonical(
            server: existing.server,
            userID: existing.user.id
        )
        let newCredentials = await credentialStore.credentials(for: canonicalID)
        let deleteCount = await credentialStore.deleteCount()
        let accounts = try await fixture.store.accounts()
        XCTAssertNil(newCredentials)
        XCTAssertEqual(deleteCount, 1)
        XCTAssertEqual(accounts, [existing])
    }

    func testOnboardingRejectsNonLocalServerBeforeTransport()
        async throws
    {
        let fixture = try StoreFixture()
        let credentials = OnboardingCredentialStore()
        let transport = OnboardingTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: credentials
        )
        let server = try Self.discoveredServer(
            authenticationMethods: [.openID]
        )

        do {
            _ = try await coordinator.loginAndPersistAccount(
                accountID: AccountID(rawValue: "account"),
                discoveredServer: server,
                username: "reader",
                password: "password",
                accountStore: fixture.store
            )
            XCTFail("Expected local authentication requirement")
        } catch {
            XCTAssertEqual(error, .localAuthenticationUnavailable)
        }
        let requestCount = await transport.requestCount()
        let accounts = try await fixture.store.accounts()
        XCTAssertEqual(requestCount, 0)
        XCTAssertTrue(accounts.isEmpty)
    }

    func testOnboardingReportsCredentialRollbackFailure() async throws {
        let fixture = try StoreFixture()
        let existing = try Self.account(
            accountID: "existing",
            server: "https://example.com",
            userID: "remote-user",
            username: "reader"
        )
        try await fixture.store.save(existing)
        let newID = AccountID(rawValue: "new")
        let credentials = OnboardingCredentialStore(
            failsDeletion: true
        )
        let coordinator = AuthCoordinator(
            transport: OnboardingTransport(),
            credentialStore: credentials
        )

        do {
            _ = try await coordinator.loginAndPersistAccount(
                accountID: newID,
                discoveredServer: try Self.discoveredServer(),
                username: "reader",
                password: "correct",
                accountStore: fixture.store
            )
            XCTFail("Expected credential rollback failure")
        } catch {
            XCTAssertEqual(
                error as? AccountOnboardingError,
                .credentialRollbackFailed
            )
        }
        let canonicalID = AccountID.canonical(
            server: existing.server,
            userID: existing.user.id
        )
        let remainingCredentials = await credentials.credentials(
            for: canonicalID
        )
        let accounts = try await fixture.store.accounts()
        XCTAssertNotNil(remainingCredentials)
        XCTAssertEqual(accounts, [existing])
    }

    func testPersistedSignOutAndRemovalUseStoredServerAndClearCredentials()
        async throws
    {
        let fixture = try StoreFixture()
        let accountID = AccountID(rawValue: "account")
        let credentials = OnboardingCredentialStore()
        let transport = OnboardingTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: credentials
        )
        let discovered = try Self.discoveredServer()
        let account = try await coordinator.loginAndPersistAccount(
            accountID: accountID,
            discoveredServer: discovered,
            username: "reader",
            password: "correct",
            accountStore: fixture.store
        )
        let canonicalID = account.id

        let signOut = try await coordinator.signOutPersistedAccount(
            accountID: canonicalID,
            accountStore: fixture.store
        )
        let signedOutAccount = try await fixture.store.account(id: canonicalID)
        let signedOutCredentials = await credentials.credentials(
            for: canonicalID
        )
        XCTAssertEqual(signOut.remoteStatus, .completed)
        XCTAssertEqual(
            signedOutAccount?.connectionState,
            .reauthenticationRequired
        )
        XCTAssertNil(signedOutCredentials)
        let firstLogoutTokens = await transport.logoutRefreshTokens()
        XCTAssertEqual(firstLogoutTokens, ["refresh-token"])

        _ = try await coordinator.loginAndPersistAccount(
            accountID: accountID,
            discoveredServer: discovered,
            username: "reader",
            password: "correct",
            accountStore: fixture.store
        )
        let removal = try await coordinator.removePersistedAccount(
            accountID: canonicalID,
            accountStore: fixture.store
        )
        let removedAccount = try await fixture.store.account(id: canonicalID)
        let removedCredentials = await credentials.credentials(for: canonicalID)
        XCTAssertEqual(removal.remoteStatus, .completed)
        XCTAssertNil(removedAccount)
        XCTAssertNil(removedCredentials)
        let allLogoutTokens = await transport.logoutRefreshTokens()
        XCTAssertEqual(
            allLogoutTokens,
            ["refresh-token", "refresh-token"]
        )
    }

    func testPersistedLifecycleRejectsUnknownAccountBeforeLogout()
        async throws
    {
        let fixture = try StoreFixture()
        let transport = OnboardingTransport()
        let coordinator = AuthCoordinator(
            transport: transport,
            credentialStore: OnboardingCredentialStore()
        )
        let missing = AccountID(rawValue: "missing")

        do {
            _ = try await coordinator.signOutPersistedAccount(
                accountID: missing,
                accountStore: fixture.store
            )
            XCTFail("Expected missing persisted account")
        } catch {
            XCTAssertEqual(
                error,
                .accountNotFound(missing)
            )
        }
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    private static func account(
        accountID: String,
        server: String,
        userID: String,
        username: String
    ) throws -> ServerAccount {
        try ServerAccount(
            id: AccountID(rawValue: accountID),
            server: NormalizedServerURL(server),
            serverVersion: "2.36.0",
            authenticationMethods: [.local],
            user: user(id: userID, username: username)
        )
    }

    private static func user(
        id: String,
        username: String
    ) -> AuthenticatedUser {
        AuthenticatedUser(
            id: UserID(rawValue: id),
            username: username,
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
    }

    private static func discoveredServer(
        authenticationMethods: [AuthenticationMethod] = [.local]
    ) throws -> DiscoveredServer {
        DiscoveredServer(
            baseURL: try NormalizedServerURL("https://example.com"),
            version: try XCTUnwrap(
                AudiobookshelfServerVersion("2.36.0")
            ),
            language: "en-us",
            authenticationMethods: authenticationMethods,
            authenticationFormData: nil
        )
    }
}

private struct StoreFixture {
    let container: ModelContainer
    let store: AccountStore

    init() throws {
        let schema = Schema(BleatPersistenceModelCatalog.allModelTypes)
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        store = AccountStore(modelContainer: container)
    }
}

private actor OnboardingCredentialStore: AccountCredentialStore {
    private var stored: [AccountID: AuthenticationTokens] = [:]
    private var deletions = 0
    private let failsDeletion: Bool

    init(failsDeletion: Bool = false) {
        self.failsDeletion = failsDeletion
    }

    func credentials(
        for accountID: AccountID
    ) -> AuthenticationTokens? {
        stored[accountID]
    }

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) {
        stored[accountID] = credentials
    }

    func deleteCredentials(for accountID: AccountID) throws {
        if failsDeletion {
            throw OnboardingTestError.credentialDeletion
        }
        deletions += 1
        stored[accountID] = nil
    }

    func deleteCount() -> Int {
        deletions
    }
}

private enum OnboardingTestError: Error {
    case credentialDeletion
}

private struct UncheckedServerAccount: Encodable {
    let id: AccountID
    let server: NormalizedServerURL
    let serverVersion: String
    let authenticationMethods: [AuthenticationMethod]
    let user: AuthenticatedUser
    let connectionState: AccountConnectionState
}

private actor OnboardingTransport: HTTPTransport {
    private var requests: [URLRequest] = []
    private var recordedLogoutRefreshTokens: [String] = []

    func send(
        _ tracedRequest: TracedHTTPRequest
    ) -> HTTPResponse {
        let request = tracedRequest.request
        requests.append(request)
        if request.url?.path.hasSuffix("/login") == true {
            return .init(
                data: Self.userJSON(includeTokens: true),
                statusCode: 200
            )
        }
        if request.url?.path.hasSuffix("/api/authorize") == true {
            return .init(
                data: Self.userJSON(includeTokens: false),
                statusCode: 200
            )
        }
        if request.url?.path.hasSuffix("/logout") == true {
            recordedLogoutRefreshTokens.append(
                request.value(
                    forHTTPHeaderField: "x-refresh-token"
                ) ?? ""
            )
            return .init(data: Data(), statusCode: 200)
        }
        return .init(data: Data(), statusCode: 404)
    }

    func requestCount() -> Int {
        requests.count
    }

    func logoutRefreshTokens() -> [String] {
        recordedLogoutRefreshTokens
    }

    private static func userJSON(includeTokens: Bool) -> Data {
        let tokens =
            includeTokens
            ? """
            ,"accessToken":"access-token","refreshToken":"refresh-token"
            """
            : ""
        return Data(
            """
            {
              "user": {
                "id": "remote-user",
                "username": "reader",
                "type": "user",
                "permissions": {
                  "download": true,
                  "update": false,
                  "delete": false,
                  "upload": false,
                  "createEreader": false,
                  "accessAllLibraries": true,
                  "accessAllTags": true,
                  "accessExplicitContent": true,
                  "selectedTagsNotAccessible": false
                },
                "librariesAccessible": [],
                "itemTagsSelected": []
                \(tokens)
              }
            }
            """.utf8)
    }
}
