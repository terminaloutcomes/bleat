import Foundation
import Security

public enum TokenVaultError: Error, Equatable, Sendable {
    case invalidService
    case invalidAccountID
    case invalidStoredCredentials
    case missingEntitlement
    case interactionNotAllowed
    case unexpectedStatus(OSStatus)
}

extension TokenVaultError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidService:
            "The Keychain service identifier is empty."
        case .invalidAccountID:
            "The Keychain account identifier is empty."
        case .invalidStoredCredentials:
            "The stored Keychain credentials are invalid."
        case .missingEntitlement:
            "The app is missing a required Keychain entitlement."
        case .interactionNotAllowed:
            "Keychain interaction is not currently allowed."
        case .unexpectedStatus(let status):
            "Keychain returned status \(status)."
        }
    }
}

/// Stores rotating session tokens separately from the native login credential.
///
/// Session tokens always remain in a non-synchronizing, device-only Keychain
/// item. The native login can use iCloud Keychain so another device can obtain
/// its own rotating token pair without sharing an active server session.
public actor TokenVault: AccountCredentialStore {
    public let tokenService: String
    public let nativeLoginService: String
    public let legacyService: String?
    public private(set) var synchronizesNativeLogin: Bool

    /// Compatibility initializer for device-only stores and existing tests.
    public init(service: String) {
        tokenService = service
        nativeLoginService = service
        legacyService = nil
        synchronizesNativeLogin = false
    }

    public init(
        tokenService: String,
        nativeLoginService: String,
        legacyService: String?,
        synchronizesNativeLogin: Bool
    ) {
        self.tokenService = tokenService
        self.nativeLoginService = nativeLoginService
        self.legacyService = legacyService
        self.synchronizesNativeLogin = synchronizesNativeLogin
    }

    public var service: String {
        tokenService
    }

    public func credentials(
        for accountID: AccountID
    ) async throws -> AuthenticationTokens? {
        try migrateLegacyCredentialsIfNeeded(for: accountID)
        guard let data = try storedData(
            service: tokenService,
            accountID: accountID,
            synchronizable: false
        ) else {
            return nil
        }
        if let tokens = try? JSONDecoder().decode(
            AuthenticationTokens.self,
            from: data
        ) {
            return tokens
        }
        if tokenService == nativeLoginService,
            let stored = try? JSONDecoder().decode(
                StoredAccountCredentials.self,
                from: data
            )
        {
            return stored.tokens
        }
        throw TokenVaultError.invalidStoredCredentials
    }

    public func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) async throws {
        if tokenService == nativeLoginService {
            let nativeLogin = try storedUnifiedCredentials(
                for: accountID
            )?.nativeLogin
            try saveData(
                JSONEncoder().encode(
                    StoredAccountCredentials(
                        tokens: credentials,
                        nativeLogin: nativeLogin
                    )
                ),
                service: tokenService,
                accountID: accountID,
                synchronizable: false
            )
            return
        }
        try saveData(
            JSONEncoder().encode(credentials),
            service: tokenService,
            accountID: accountID,
            synchronizable: false
        )
    }

    public func save(
        _ credentials: AuthenticationTokens,
        nativeLogin: NativeLoginCredentials,
        for accountID: AccountID
    ) async throws {
        if tokenService == nativeLoginService {
            try saveData(
                JSONEncoder().encode(
                    StoredAccountCredentials(
                        tokens: credentials,
                        nativeLogin: nativeLogin
                    )
                ),
                service: tokenService,
                accountID: accountID,
                synchronizable: false
            )
            return
        }

        try saveData(
            JSONEncoder().encode(credentials),
            service: tokenService,
            accountID: accountID,
            synchronizable: false
        )
        do {
            try saveData(
                JSONEncoder().encode(nativeLogin),
                service: nativeLoginService,
                accountID: accountID,
                synchronizable: synchronizesNativeLogin
            )
        } catch {
            try? deleteItem(
                service: tokenService,
                accountID: accountID,
                synchronizable: false
            )
            throw error
        }
    }

    public func nativeLoginCredentials(
        for accountID: AccountID
    ) async throws -> NativeLoginCredentials? {
        try migrateLegacyCredentialsIfNeeded(for: accountID)
        if tokenService == nativeLoginService {
            return try storedUnifiedCredentials(
                for: accountID
            )?.nativeLogin
        }
        guard let data = try storedData(
            service: nativeLoginService,
            accountID: accountID,
            synchronizable: synchronizesNativeLogin
        ) else {
            return nil
        }
        guard let nativeLogin = try? JSONDecoder().decode(
            NativeLoginCredentials.self,
            from: data
        ) else {
            throw TokenVaultError.invalidStoredCredentials
        }
        return nativeLogin
    }

    public func deleteCredentials(
        for accountID: AccountID
    ) async throws {
        try deleteSessionTokens(for: accountID)
        try deleteNativeLoginCredentials(for: accountID)
        if let legacyService {
            try deleteItem(
                service: legacyService,
                accountID: accountID,
                synchronizable: false
            )
        }
    }

    nonisolated func deleteSessionTokens(
        for accountID: AccountID
    ) throws {
        try deleteItem(
            service: tokenService,
            accountID: accountID,
            synchronizable: false
        )
    }

    public func deleteSessionCredentials(
        for accountID: AccountID
    ) async throws {
        try deleteSessionTokens(for: accountID)
    }

    func deleteNativeLoginCredentials(
        for accountID: AccountID
    ) throws {
        guard tokenService != nativeLoginService else {
            try deleteItem(
                service: tokenService,
                accountID: accountID,
                synchronizable: false
            )
            return
        }
        try deleteItem(
            service: nativeLoginService,
            accountID: accountID,
            synchronizable: synchronizesNativeLogin
        )
    }

    public func setSynchronizesNativeLogin(
        _ enabled: Bool,
        accountIDs: [AccountID]
    ) throws {
        guard tokenService != nativeLoginService,
            enabled != synchronizesNativeLogin
        else {
            synchronizesNativeLogin = enabled
            return
        }
        let sourceSynchronizable = synchronizesNativeLogin
        var credentialsByAccount: [(AccountID, Data)] = []
        for accountID in accountIDs {
            guard let data = try storedData(
                service: nativeLoginService,
                accountID: accountID,
                synchronizable: sourceSynchronizable
            ) else {
                continue
            }
            guard (try? JSONDecoder().decode(
                NativeLoginCredentials.self,
                from: data
            )) != nil else {
                throw TokenVaultError.invalidStoredCredentials
            }
            credentialsByAccount.append((accountID, data))
        }

        do {
            for (accountID, data) in credentialsByAccount {
                try saveData(
                    data,
                    service: nativeLoginService,
                    accountID: accountID,
                    synchronizable: enabled
                )
            }
        } catch {
            for (accountID, _) in credentialsByAccount {
                try? deleteItem(
                    service: nativeLoginService,
                    accountID: accountID,
                    synchronizable: enabled
                )
            }
            throw error
        }

        do {
            for (accountID, _) in credentialsByAccount {
                try deleteItem(
                    service: nativeLoginService,
                    accountID: accountID,
                    synchronizable: sourceSynchronizable
                )
            }
        } catch {
            for (accountID, data) in credentialsByAccount {
                try? saveData(
                    data,
                    service: nativeLoginService,
                    accountID: accountID,
                    synchronizable: sourceSynchronizable
                )
                try? deleteItem(
                    service: nativeLoginService,
                    accountID: accountID,
                    synchronizable: enabled
                )
            }
            throw error
        }
        synchronizesNativeLogin = enabled
    }

    private func migrateLegacyCredentialsIfNeeded(
        for accountID: AccountID
    ) throws {
        guard tokenService != nativeLoginService,
            let legacyService,
            let data = try storedData(
                service: legacyService,
                accountID: accountID,
                synchronizable: false
            )
        else {
            return
        }

        let stored: StoredAccountCredentials
        if let decoded = try? JSONDecoder().decode(
            StoredAccountCredentials.self,
            from: data
        ) {
            stored = decoded
        } else if let tokens = try? JSONDecoder().decode(
            AuthenticationTokens.self,
            from: data
        ) {
            stored = StoredAccountCredentials(
                tokens: tokens,
                nativeLogin: nil
            )
        } else {
            throw TokenVaultError.invalidStoredCredentials
        }

        try saveData(
            JSONEncoder().encode(stored.tokens),
            service: tokenService,
            accountID: accountID,
            synchronizable: false
        )
        if let nativeLogin = stored.nativeLogin {
            do {
                try saveData(
                    JSONEncoder().encode(nativeLogin),
                    service: nativeLoginService,
                    accountID: accountID,
                    synchronizable: synchronizesNativeLogin
                )
            } catch {
                try? deleteItem(
                    service: tokenService,
                    accountID: accountID,
                    synchronizable: false
                )
                throw error
            }
        }
        try deleteItem(
            service: legacyService,
            accountID: accountID,
            synchronizable: false
        )
    }

    private func storedUnifiedCredentials(
        for accountID: AccountID
    ) throws -> StoredAccountCredentials? {
        guard let data = try storedData(
            service: tokenService,
            accountID: accountID,
            synchronizable: false
        ) else {
            return nil
        }
        if let stored = try? JSONDecoder().decode(
            StoredAccountCredentials.self,
            from: data
        ) {
            return stored
        }
        if let tokens = try? JSONDecoder().decode(
            AuthenticationTokens.self,
            from: data
        ) {
            return StoredAccountCredentials(
                tokens: tokens,
                nativeLogin: nil
            )
        }
        throw TokenVaultError.invalidStoredCredentials
    }

    private func storedData(
        service: String,
        accountID: AccountID,
        synchronizable: Bool
    ) throws -> Data? {
        let query = try baseQuery(
            service: service,
            accountID: accountID,
            synchronizable: synchronizable
        ).merging([
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]) { _, new in new }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        try Self.check(status)
        guard let data = result as? Data else {
            throw TokenVaultError.invalidStoredCredentials
        }
        return data
    }

    private func saveData(
        _ data: Data,
        service: String,
        accountID: AccountID,
        synchronizable: Bool
    ) throws {
        let query = try baseQuery(
            service: service,
            accountID: accountID,
            synchronizable: synchronizable
        )
        let updateValues: [CFString: Any] = [
            kSecValueData: data
        ]
        let accessibility: CFString = synchronizable
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addValues: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: accessibility,
        ]

        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            updateValues as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            try Self.check(updateStatus)
            return
        }

        let addStatus = SecItemAdd(
            query.merging(addValues) { _, new in new } as CFDictionary,
            nil
        )
        if addStatus == errSecDuplicateItem {
            try Self.check(
                SecItemUpdate(
                    query as CFDictionary,
                    updateValues as CFDictionary
                )
            )
            return
        }
        try Self.check(addStatus)
    }

    private nonisolated func deleteItem(
        service: String,
        accountID: AccountID,
        synchronizable: Bool
    ) throws {
        let status = SecItemDelete(
            try baseQuery(
                service: service,
                accountID: accountID,
                synchronizable: synchronizable
            ) as CFDictionary
        )
        if status == errSecItemNotFound {
            return
        }
        try Self.check(status)
    }

    private nonisolated func baseQuery(
        service: String,
        accountID: AccountID,
        synchronizable: Bool
    ) throws(TokenVaultError) -> [CFString: Any] {
        guard !service.isEmpty else {
            throw .invalidService
        }
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID.rawValue,
            kSecAttrSynchronizable:
                synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
        ]
    }

    static func check(
        _ status: OSStatus
    ) throws(TokenVaultError) {
        switch status {
        case errSecSuccess:
            return
        case errSecMissingEntitlement:
            throw .missingEntitlement
        case errSecInteractionNotAllowed:
            throw .interactionNotAllowed
        default:
            throw .unexpectedStatus(status)
        }
    }
}

private struct StoredAccountCredentials: Codable {
    let tokens: AuthenticationTokens
    let nativeLogin: NativeLoginCredentials?
}
