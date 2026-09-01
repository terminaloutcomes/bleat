import Security
import XCTest

@testable import BleatCore

final class KeychainEntitlementTests: XCTestCase {
    func testApplicationHostCanPersistCredentialsInKeychain() async throws {
        let store = TokenVault(
            service: "com.terminaloutcomes.bleat.app-tests.\(UUID().uuidString)"
        )
        let accountID = AccountID(rawValue: "keychain-entitlement")
        let tokens = try AuthenticationTokens(
            accessToken: "test-access",
            refreshToken: "test-refresh"
        )
        let nativeLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "test-user"),
            username: "reader",
            password: "test-password"
        )
        addTeardownBlock {
            try await store.deleteCredentials(for: accountID)
        }

        let initiallyStored = try await store.credentials(for: accountID)
        XCTAssertNil(initiallyStored)
        try await store.save(
            tokens,
            nativeLogin: nativeLogin,
            for: accountID
        )

        let storedTokens = try await store.credentials(for: accountID)
        let storedNativeLogin =
            try await store.nativeLoginCredentials(for: accountID)
        XCTAssertEqual(storedTokens, tokens)
        XCTAssertEqual(storedNativeLogin, nativeLogin)

        try await store.deleteCredentials(for: accountID)
        let deletedCredentials = try await store.credentials(for: accountID)
        XCTAssertNil(deletedCredentials)
    }

    func testApplicationHostKeepsRotatingTokensDeviceOnly()
        async throws
    {
        let suffix = UUID().uuidString
        let tokenService =
            "com.terminaloutcomes.bleat.app-tests.session.\(suffix)"
        let nativeLoginService =
            "com.terminaloutcomes.bleat.app-tests.native-login.\(suffix)"
        let store = TokenVault(
            tokenService: tokenService,
            nativeLoginService: nativeLoginService,
            legacyService: nil,
            synchronizesNativeLogin: true
        )
        let accountID = AccountID(rawValue: "keychain-device-only")
        let tokens = try AuthenticationTokens(
            accessToken: "test-access",
            refreshToken: "test-refresh"
        )
        let nativeLogin = try NativeLoginCredentials(
            userID: UserID(rawValue: "test-user"),
            username: "reader",
            password: "test-password"
        )
        addTeardownBlock {
            try await store.deleteCredentials(for: accountID)
        }

        try await store.save(
            tokens,
            nativeLogin: nativeLogin,
            for: accountID
        )

        XCTAssertTrue(
            try hasKeychainItem(
                service: tokenService,
                accountID: accountID,
                synchronizable: false,
                accessibility:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
        )
        XCTAssertTrue(
            try hasKeychainItem(
                service: nativeLoginService,
                accountID: accountID,
                synchronizable: true,
                accessibility: kSecAttrAccessibleAfterFirstUnlock
            )
        )
    }

    func testApplicationHostPersistsDeviceOnlyTelemetryEnrollment()
        async throws
    {
        let vault = TelemetryEnrollmentVault(
            service:
                "com.terminaloutcomes.bleat.telemetry-tests.\(UUID().uuidString)"
        )
        let enrollment = TelemetryEnrollment(
            keyID: "opaque-app-attest-key-id",
            installationID: UUID()
        )
        addTeardownBlock { try await vault.delete() }

        let initiallyStored = try await vault.enrollment()
        XCTAssertNil(initiallyStored)
        try await vault.save(enrollment)
        let restored = try await vault.enrollment()
        XCTAssertEqual(restored, enrollment)

        try await vault.delete()
        let deleted = try await vault.enrollment()
        XCTAssertNil(deleted)
    }

    func testTelemetryEnrollmentVaultReportsInvalidConfiguration() async {
        let vault = TelemetryEnrollmentVault(service: "")
        do {
            _ = try await vault.enrollment()
            XCTFail("invalid Keychain configuration unexpectedly succeeded")
        } catch let error as TelemetryEnrollmentVaultError {
            XCTAssertEqual(error, .invalidConfiguration)
        } catch {
            XCTFail("unexpected error type: \(type(of: error))")
        }
    }

    func testTelemetryEnrollmentVaultPreservesMissingEntitlementFailure() {
        XCTAssertThrowsError(
            try TelemetryEnrollmentVault.check(errSecMissingEntitlement)
        ) { error in
            XCTAssertEqual(
                error as? TelemetryEnrollmentVaultError,
                .missingEntitlement
            )
        }
    }

    private func hasKeychainItem(
        service: String,
        accountID: AccountID,
        synchronizable: Bool,
        accessibility: CFString
    ) throws -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: accountID.rawValue,
            kSecAttrSynchronizable:
                synchronizable ? kCFBooleanTrue as Any : kCFBooleanFalse as Any,
            kSecAttrAccessible: accessibility,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        default:
            throw TokenVaultError.unexpectedStatus(status)
        }
    }
}
