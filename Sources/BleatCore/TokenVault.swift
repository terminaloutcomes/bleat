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

public actor TokenVault: AccountCredentialStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func credentials(
        for accountID: AccountID
    ) async throws -> AuthenticationTokens? {
        try storedCredentials(for: accountID)?.tokens
    }

    public func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) async throws {
        let nativeLogin = try storedCredentials(for: accountID)?.nativeLogin
        try save(
            StoredAccountCredentials(
                tokens: credentials,
                nativeLogin: nativeLogin
            ),
            for: accountID
        )
    }

    public func save(
        _ credentials: AuthenticationTokens,
        nativeLogin: NativeLoginCredentials,
        for accountID: AccountID
    ) async throws {
        try save(
            StoredAccountCredentials(
                tokens: credentials,
                nativeLogin: nativeLogin
            ),
            for: accountID
        )
    }

    public func nativeLoginCredentials(
        for accountID: AccountID
    ) async throws -> NativeLoginCredentials? {
        try storedCredentials(for: accountID)?.nativeLogin
    }

    private func storedCredentials(
        for accountID: AccountID
    ) throws -> StoredAccountCredentials? {
        let query = try baseQuery(for: accountID).merging([
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]) { _, new in new }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        if status == errSecItemNotFound {
            return nil
        }
        try Self.check(status)

        guard let data = result as? Data else {
            throw TokenVaultError.invalidStoredCredentials
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

    private func save(
        _ credentials: StoredAccountCredentials,
        for accountID: AccountID
    ) throws {
        let data = try JSONEncoder().encode(credentials)
        let query = try baseQuery(for: accountID)
        let updateValues: [CFString: Any] = [
            kSecValueData: data
        ]
        let addValues: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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

    public func deleteCredentials(
        for accountID: AccountID
    ) async throws {
        let status = SecItemDelete(
            try baseQuery(for: accountID) as CFDictionary
        )
        if status == errSecItemNotFound {
            return
        }
        try Self.check(status)
    }

    private func baseQuery(
        for accountID: AccountID
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
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
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
