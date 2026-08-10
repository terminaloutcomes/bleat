import Foundation
import SwiftData

public enum AccountConnectionState: String, Codable, Sendable {
    case connected
    case offline
    case reauthenticationRequired
}

public enum ServerAccountValidationError: Error, Equatable, Sendable {
    case invalidAccountID
    case invalidRemoteUserID
    case invalidUsername
    case invalidServerVersion
    case localAuthenticationUnavailable
    case serverMismatch
}

public struct ServerAccount: Codable, Hashable, Identifiable, Sendable {
    public let id: AccountID
    public let server: NormalizedServerURL
    public let localServer: NormalizedServerURL?
    public let localServerValidated: Bool
    public let serverVersion: String
    public let authenticationMethods: [AuthenticationMethod]
    public let user: AuthenticatedUser
    public let connectionState: AccountConnectionState

    public init(
        id: AccountID,
        server: NormalizedServerURL,
        localServer: NormalizedServerURL? = nil,
        localServerValidated: Bool = false,
        serverVersion: String,
        authenticationMethods: [AuthenticationMethod],
        user: AuthenticatedUser,
        connectionState: AccountConnectionState = .connected
    ) throws(ServerAccountValidationError) {
        guard !id.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !user.id.rawValue.isEmpty else {
            throw .invalidRemoteUserID
        }
        guard !user.username.isEmpty,
              user.username.rangeOfCharacter(
                  from: .controlCharacters
              ) == nil
        else {
            throw .invalidUsername
        }
        guard AudiobookshelfServerVersion(serverVersion) != nil else {
            throw .invalidServerVersion
        }
        guard authenticationMethods.contains(.local)
            || authenticationMethods.contains(.openID)
        else {
            throw .localAuthenticationUnavailable
        }
        self.id = id
        self.server = server
        self.localServer = localServer == server ? nil : localServer
        self.localServerValidated =
            self.localServer != nil && localServerValidated
        self.serverVersion = serverVersion
        self.authenticationMethods = authenticationMethods
        self.user = user
        self.connectionState = connectionState
    }

    public init(
        authenticatedAccount: AuthenticatedAccount,
        discoveredServer: DiscoveredServer
    ) throws(ServerAccountValidationError) {
        guard authenticatedAccount.server == discoveredServer.baseURL else {
            throw .serverMismatch
        }
        try self.init(
            id: authenticatedAccount.id,
            server: authenticatedAccount.server,
            serverVersion: discoveredServer.version.original,
            authenticationMethods: discoveredServer.authenticationMethods,
            user: authenticatedAccount.user
        )
    }

    public var supportsLocalAuthentication: Bool {
        authenticationMethods.contains(.local)
    }

    public var supportsOpenIDAuthentication: Bool {
        authenticationMethods.contains(.openID)
    }

    public func updatingConnectionState(
        _ state: AccountConnectionState
    ) throws(ServerAccountValidationError) -> ServerAccount {
        try ServerAccount(
            id: id,
            server: server,
            localServer: localServer,
            localServerValidated: localServerValidated,
            serverVersion: serverVersion,
            authenticationMethods: authenticationMethods,
            user: user,
            connectionState: state
        )
    }

    public func updatingLocalServer(
        _ localServer: NormalizedServerURL?,
        validated: Bool = false
    ) throws(ServerAccountValidationError) -> ServerAccount {
        try ServerAccount(
            id: id,
            server: server,
            localServer: localServer,
            localServerValidated: validated,
            serverVersion: serverVersion,
            authenticationMethods: authenticationMethods,
            user: user,
            connectionState: connectionState
        )
    }

    enum CodingKeys: String, CodingKey {
        case id
        case server
        case localServer
        case localServerValidated
        case serverVersion
        case authenticationMethods
        case user
        case connectionState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(AccountID.self, forKey: .id),
                server: container.decode(
                    NormalizedServerURL.self,
                    forKey: .server
                ),
                localServer: container.decodeIfPresent(
                    NormalizedServerURL.self,
                    forKey: .localServer
                ),
                localServerValidated: try container.decodeIfPresent(
                    Bool.self,
                    forKey: .localServerValidated
                ) ?? false,
                serverVersion: container.decode(
                    String.self,
                    forKey: .serverVersion
                ),
                authenticationMethods: container.decode(
                    [AuthenticationMethod].self,
                    forKey: .authenticationMethods
                ),
                user: container.decode(
                    AuthenticatedUser.self,
                    forKey: .user
                ),
                connectionState: container.decode(
                    AccountConnectionState.self,
                    forKey: .connectionState
                )
            )
        } catch let error as ServerAccountValidationError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Stored server account failed validation: \(error)"
                )
            )
        }
    }
}

@Model
public final class ServerAccountRecord {
    @Attribute(.unique)
    var accountID: String
    var serverURL: String
    var remoteUserID: String
    var profileData: Data
    var isActiveBrowsingAccount: Bool

    init(
        accountID: String,
        serverURL: String,
        remoteUserID: String,
        profileData: Data,
        isActiveBrowsingAccount: Bool
    ) {
        self.accountID = accountID
        self.serverURL = serverURL
        self.remoteUserID = remoteUserID
        self.profileData = profileData
        self.isActiveBrowsingAccount = isActiveBrowsingAccount
    }
}

public enum AccountStoreError: Error, Equatable, Sendable {
    case accountNotFound(AccountID)
    case duplicateRemoteAccount(existingAccountID: AccountID)
    case profileEncodingFailed
    case invalidStoredAccount(AccountID)
    case persistenceFailed
}

public enum AccountOnboardingError: Error, Equatable, Sendable {
    case localAuthenticationUnavailable
    case authenticationFailed(LocalAuthenticationError)
    case openIDAuthenticationUnavailable
    case openIDAuthenticationFailed(OpenIDAuthenticationError)
    case authenticationRequestFailed
    case invalidAccount(ServerAccountValidationError)
    case accountPersistenceFailed(AccountStoreError)
    case credentialRollbackFailed
}

public enum AccountLifecycleError: Error, Equatable, Sendable {
    case accountNotFound(AccountID)
    case logoutFailed(LogoutError)
    case logoutRequestFailed
    case accountStoreFailed(AccountStoreError)
}

@ModelActor
public actor AccountStore {
    public func save(
        _ account: ServerAccount,
        makeActive: Bool = false
    ) throws(AccountStoreError) {
        let records = try fetchRecords()
        if let duplicate = records.first(where: {
            $0.serverURL == account.server.url.absoluteString
                && $0.remoteUserID == account.user.id.rawValue
                && $0.accountID != account.id.rawValue
        }) {
            throw .duplicateRemoteAccount(
                existingAccountID: AccountID(
                    rawValue: duplicate.accountID
                )
            )
        }

        let profileData: Data
        do {
            profileData = try JSONEncoder().encode(account)
        } catch {
            throw .profileEncodingFailed
        }

        let shouldActivate = makeActive
            || records.isEmpty
            || !records.contains(where: \.isActiveBrowsingAccount)
        if shouldActivate {
            records.forEach {
                $0.isActiveBrowsingAccount = false
            }
        }
        if let existing = records.first(where: {
            $0.accountID == account.id.rawValue
        }) {
            existing.serverURL = account.server.url.absoluteString
            existing.remoteUserID = account.user.id.rawValue
            existing.profileData = profileData
            if shouldActivate {
                existing.isActiveBrowsingAccount = true
            }
        } else {
            modelContext.insert(ServerAccountRecord(
                accountID: account.id.rawValue,
                serverURL: account.server.url.absoluteString,
                remoteUserID: account.user.id.rawValue,
                profileData: profileData,
                isActiveBrowsingAccount: shouldActivate
            ))
        }
        try saveContext()
    }

    public func accounts() throws(AccountStoreError) -> [ServerAccount] {
        try fetchRecords()
            .map(decode)
            .sorted {
                let usernameOrder = $0.user.username.localizedStandardCompare(
                    $1.user.username
                )
                if usernameOrder == .orderedSame {
                    return $0.server.url.absoluteString
                        < $1.server.url.absoluteString
                }
                return usernameOrder == .orderedAscending
            }
    }

    public func account(
        id: AccountID
    ) throws(AccountStoreError) -> ServerAccount? {
        guard let record = try fetchRecords().first(where: {
            $0.accountID == id.rawValue
        }) else {
            return nil
        }
        return try decode(record)
    }

    public func activeAccount() throws(AccountStoreError) -> ServerAccount? {
        guard let record = try fetchRecords().first(where: {
            $0.isActiveBrowsingAccount
        }) else {
            return nil
        }
        return try decode(record)
    }

    public func setActiveAccount(
        id: AccountID
    ) throws(AccountStoreError) {
        let records = try fetchRecords()
        guard records.contains(where: {
            $0.accountID == id.rawValue
        }) else {
            throw .accountNotFound(id)
        }
        records.forEach {
            $0.isActiveBrowsingAccount = $0.accountID == id.rawValue
        }
        try saveContext()
    }

    public func setConnectionState(
        _ state: AccountConnectionState,
        for id: AccountID
    ) throws(AccountStoreError) {
        let records = try fetchRecords()
        guard let record = records.first(where: {
            $0.accountID == id.rawValue
        }) else {
            throw .accountNotFound(id)
        }
        let account = try decode(record)
        let updated: ServerAccount
        do {
            updated = try account.updatingConnectionState(state)
            record.profileData = try JSONEncoder().encode(updated)
        } catch let error as AccountStoreError {
            throw error
        } catch {
            throw .profileEncodingFailed
        }
        try saveContext()
    }

    public func setLocalServer(
        _ localServer: NormalizedServerURL?,
        validated: Bool = false,
        for id: AccountID
    ) throws(AccountStoreError) {
        let records = try fetchRecords()
        guard let record = records.first(where: {
            $0.accountID == id.rawValue
        }) else {
            throw .accountNotFound(id)
        }
        let account = try decode(record)
        do {
            let updated = try account.updatingLocalServer(
                localServer,
                validated: validated
            )
            record.profileData = try JSONEncoder().encode(updated)
        } catch {
            throw .profileEncodingFailed
        }
        try saveContext()
    }

    @discardableResult
    public func removeAccount(
        id: AccountID
    ) throws(AccountStoreError) -> Bool {
        let records = try fetchRecords()
        guard let record = records.first(where: {
            $0.accountID == id.rawValue
        }) else {
            return false
        }
        let removedActiveAccount = record.isActiveBrowsingAccount
        modelContext.delete(record)
        if removedActiveAccount,
           let replacement = records
               .filter({ $0 !== record })
               .sorted(by: { $0.accountID < $1.accountID })
               .first
        {
            replacement.isActiveBrowsingAccount = true
        }
        try saveContext()
        return true
    }

    private func fetchRecords() throws(AccountStoreError)
        -> [ServerAccountRecord]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<ServerAccountRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    private func decode(
        _ record: ServerAccountRecord
    ) throws(AccountStoreError) -> ServerAccount {
        do {
            return try JSONDecoder().decode(
                ServerAccount.self,
                from: record.profileData
            )
        } catch {
            throw .invalidStoredAccount(
                AccountID(rawValue: record.accountID)
            )
        }
    }

    private func saveContext() throws(AccountStoreError) {
        do {
            try modelContext.save()
        } catch {
            throw .persistenceFailed
        }
    }
}

extension AuthCoordinator {
    public func loginAndPersistAccount(
        accountID: AccountID,
        discoveredServer: DiscoveredServer,
        username: String,
        password: String,
        expectedUserID: UserID? = nil,
        accountStore: AccountStore,
        makeActive: Bool = true,
        onAuthenticationCompleted: @escaping @Sendable () async -> Void = {}
    ) async throws(AccountOnboardingError) -> ServerAccount {
        guard discoveredServer.authenticationMethods.contains(.local) else {
            throw .localAuthenticationUnavailable
        }

        let authenticated: AuthenticatedAccount
        do {
            authenticated = try await login(
                accountID: accountID,
                server: discoveredServer.baseURL,
                username: username,
                password: password,
                expectedUserID: expectedUserID
            )
        } catch let error as LocalAuthenticationError {
            throw .authenticationFailed(error)
        } catch {
            throw .authenticationRequestFailed
        }

        await onAuthenticationCompleted()

        let account: ServerAccount
        do {
            account = try ServerAccount(
                authenticatedAccount: authenticated,
                discoveredServer: discoveredServer
            )
        } catch let error {
            try await rollbackOnboardingCredentials(
                accountID: accountID,
                originalError: .invalidAccount(error)
            )
        }

        do {
            try await accountStore.save(account, makeActive: makeActive)
        } catch let error {
            try await rollbackOnboardingCredentials(
                accountID: accountID,
                originalError: .accountPersistenceFailed(error)
            )
        }
        return account
    }

    func rollbackOnboardingCredentials(
        accountID: AccountID,
        originalError: AccountOnboardingError
    ) async throws(AccountOnboardingError) -> Never {
        do {
            try await credentialStore.deleteCredentials(for: accountID)
        } catch {
            throw .credentialRollbackFailed
        }
        throw originalError
    }

    public func signOutPersistedAccount(
        accountID: AccountID,
        accountStore: AccountStore
    ) async throws(AccountLifecycleError) -> LogoutResult {
        guard let account = try await storedAccount(
            id: accountID,
            accountStore: accountStore
        ) else {
            throw .accountNotFound(accountID)
        }
        let result: LogoutResult
        do {
            result = try await logout(
                accountID: accountID,
                server: account.server
            )
        } catch let error as LogoutError {
            throw .logoutFailed(error)
        } catch {
            throw .logoutRequestFailed
        }
        do {
            try await accountStore.setConnectionState(
                .reauthenticationRequired,
                for: accountID
            )
        } catch let error {
            throw .accountStoreFailed(error)
        }
        return result
    }

    public func removePersistedAccount(
        accountID: AccountID,
        accountStore: AccountStore
    ) async throws(AccountLifecycleError) -> LogoutResult {
        guard let account = try await storedAccount(
            id: accountID,
            accountStore: accountStore
        ) else {
            throw .accountNotFound(accountID)
        }
        let result: LogoutResult
        do {
            result = try await logout(
                accountID: accountID,
                server: account.server
            )
        } catch let error as LogoutError {
            throw .logoutFailed(error)
        } catch {
            throw .logoutRequestFailed
        }
        do {
            _ = try await accountStore.removeAccount(id: accountID)
        } catch let error {
            throw .accountStoreFailed(error)
        }
        return result
    }

    public func removePersistedAccountFromDevice(
        accountID: AccountID,
        accountStore: AccountStore
    ) async throws(AccountLifecycleError) -> LogoutResult {
        guard let account = try await storedAccount(
            id: accountID,
            accountStore: accountStore
        ) else {
            throw .accountNotFound(accountID)
        }
        let result: LogoutResult
        do {
            result = try await logoutKeepingNativeLogin(
                accountID: accountID,
                server: account.server
            )
        } catch let error as LogoutError {
            throw .logoutFailed(error)
        } catch {
            throw .logoutRequestFailed
        }
        do {
            _ = try await accountStore.removeAccount(id: accountID)
        } catch let error {
            throw .accountStoreFailed(error)
        }
        return result
    }

    private func storedAccount(
        id: AccountID,
        accountStore: AccountStore
    ) async throws(AccountLifecycleError) -> ServerAccount? {
        do {
            return try await accountStore.account(id: id)
        } catch let error {
            throw .accountStoreFailed(error)
        }
    }
}
