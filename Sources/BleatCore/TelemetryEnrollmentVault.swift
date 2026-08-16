import Foundation
import Security

public enum TelemetryEnrollmentVaultError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidStoredEnrollment
    case missingEntitlement
    case interactionNotAllowed
    case unexpectedStatus(OSStatus)
}

/// Persists only the App Attest key identifier and opaque installation ID.
///
/// The single record is non-synchronizing and device-only. Bearer tokens are
/// intentionally owned only by `TelemetryTokenProvider` memory.
public actor TelemetryEnrollmentVault: TelemetryEnrollmentStoring {
    private let service: String
    private let account: String

    public init(service: String, account: String = "enrollment-v1") {
        self.service = service
        self.account = account
    }

    public func enrollment() async throws -> TelemetryEnrollment? {
        let query = try baseQuery().merging([
            kSecReturnData: kCFBooleanTrue as Any,
            kSecMatchLimit: kSecMatchLimitOne,
        ]) { _, new in new }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        try Self.check(status)
        guard let data = result as? Data,
            let enrollment = try? JSONDecoder().decode(
                TelemetryEnrollment.self,
                from: data
            ),
            !enrollment.keyID.isEmpty
        else {
            throw TelemetryEnrollmentVaultError.invalidStoredEnrollment
        }
        return enrollment
    }

    public func save(_ enrollment: TelemetryEnrollment) async throws {
        guard !enrollment.keyID.isEmpty else {
            throw TelemetryEnrollmentVaultError.invalidStoredEnrollment
        }
        let data = try JSONEncoder().encode(enrollment)
        let query = try baseQuery()
        let update: [CFString: Any] = [kSecValueData: data]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            update as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            try Self.check(updateStatus)
            return
        }
        let add: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let addStatus = SecItemAdd(
            query.merging(add) { _, new in new } as CFDictionary,
            nil
        )
        if addStatus == errSecDuplicateItem {
            try Self.check(
                SecItemUpdate(
                    query as CFDictionary,
                    update as CFDictionary
                )
            )
            return
        }
        try Self.check(addStatus)
    }

    public func delete() async throws {
        let status = SecItemDelete(try baseQuery() as CFDictionary)
        if status == errSecItemNotFound {
            return
        }
        try Self.check(status)
    }

    private func baseQuery() throws -> [CFString: Any] {
        guard !service.isEmpty, !account.isEmpty else {
            throw TelemetryEnrollmentVaultError.invalidConfiguration
        }
        return [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
        ]
    }

    static func check(_ status: OSStatus) throws {
        switch status {
        case errSecSuccess:
            return
        case errSecMissingEntitlement:
            throw TelemetryEnrollmentVaultError.missingEntitlement
        case errSecInteractionNotAllowed:
            throw TelemetryEnrollmentVaultError.interactionNotAllowed
        default:
            throw TelemetryEnrollmentVaultError.unexpectedStatus(status)
        }
    }
}
