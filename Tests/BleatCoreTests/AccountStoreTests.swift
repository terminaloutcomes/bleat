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
        XCTAssertEqual(Set(accounts.map(\.id)), [
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
            server: "https://example.net/prefix/",
            userID: "remote-user",
            username: "Reader"
        )
        let duplicate = try Self.account(
            accountID: "duplicate",
            server: "https://EXAMPLE.net/prefix",
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
        context.insert(ServerAccountRecord(
            accountID: "corrupt",
            serverURL: "https://example.net",
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
            server: "https://example.net",
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
        XCTAssertThrowsError(
            try ServerAccount(
                id: valid.id,
                server: valid.server,
                serverVersion: "2.36.0",
                authenticationMethods: [.openID],
                user: valid.user
            )
        ) { error in
            XCTAssertEqual(
                error as? ServerAccountValidationError,
                .localAuthenticationUnavailable
            )
        }
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

        XCTAssertEqual(account.id, accountID)
        XCTAssertEqual(account.user.id.rawValue, "remote-user")
        let active = try await fixture.store.activeAccount()
        let storedCredentials = await credentialStore.credentials(
            for: accountID
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
            server: "https://example.net",
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

        let newCredentials = await credentialStore.credentials(
            for: newID
        )
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
            server: "https://example.net",
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
        let remainingCredentials = await credentials.credentials(for: newID)
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
        _ = try await coordinator.loginAndPersistAccount(
            accountID: accountID,
            discoveredServer: discovered,
            username: "reader",
            password: "correct",
            accountStore: fixture.store
        )

        let signOut = try await coordinator.signOutPersistedAccount(
            accountID: accountID,
            accountStore: fixture.store
        )
        let signedOutAccount = try await fixture.store.account(id: accountID)
        let signedOutCredentials = await credentials.credentials(
            for: accountID
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
            accountID: accountID,
            accountStore: fixture.store
        )
        let removedAccount = try await fixture.store.account(id: accountID)
        let removedCredentials = await credentials.credentials(for: accountID)
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
            baseURL: try NormalizedServerURL("https://example.net"),
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
        let schema = Schema([ServerAccountRecord.self])
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
        let tokens = includeTokens
            ? """
            ,"accessToken":"access-token","refreshToken":"refresh-token"
            """
            : ""
        return Data("""
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
