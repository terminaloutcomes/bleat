import Security
import XCTest

@testable import BleatCore

final class TokenVaultTests: XCTestCase {
    func testRoundTripReplacementIsolationAccessibilityAndDeletion()
        async throws
    {
        #if targetEnvironment(simulator)
            throw XCTSkip(
                "Requires the future app test host's Keychain entitlement"
            )
        #else
            let service =
                "com.terminaloutcomes.bleat.tests.\(UUID().uuidString)"
            let store = TokenVault(service: service)
            let firstAccount = AccountID(rawValue: "first")
            let secondAccount = AccountID(rawValue: "second")
            let firstTokens = try AuthenticationTokens(
                accessToken: "first-access",
                refreshToken: "first-refresh"
            )
            let replacementTokens = try AuthenticationTokens(
                accessToken: "replacement-access",
                refreshToken: "replacement-refresh"
            )
            let secondTokens = try AuthenticationTokens(
                accessToken: "second-access",
                refreshToken: "second-refresh"
            )
            let firstNativeLogin = try NativeLoginCredentials(
                userID: UserID(rawValue: "first-user"),
                username: "reader",
                password: "saved-password"
            )
            addTeardownBlock {
                try await store.deleteCredentials(for: firstAccount)
                try await store.deleteCredentials(for: secondAccount)
            }

            let initiallyStored = try await store.credentials(for: firstAccount)
            XCTAssertNil(initiallyStored)

            try await store.save(
                firstTokens,
                nativeLogin: firstNativeLogin,
                for: firstAccount
            )
            try await store.save(secondTokens, for: secondAccount)
            let loadedFirst = try await store.credentials(for: firstAccount)
            let loadedSecond = try await store.credentials(for: secondAccount)
            let loadedFirstNativeLogin =
                try await store.nativeLoginCredentials(for: firstAccount)
            XCTAssertEqual(loadedFirst, firstTokens)
            XCTAssertEqual(loadedSecond, secondTokens)
            XCTAssertEqual(loadedFirstNativeLogin, firstNativeLogin)

            try await store.save(replacementTokens, for: firstAccount)
            let loadedReplacement = try await store.credentials(
                for: firstAccount)
            let retainedNativeLogin =
                try await store.nativeLoginCredentials(for: firstAccount)
            let hasExpectedAccessibility = try hasExpectedAccessibility(
                service: service,
                account: firstAccount.rawValue
            )
            XCTAssertEqual(loadedReplacement, replacementTokens)
            XCTAssertEqual(retainedNativeLogin, firstNativeLogin)
            XCTAssertTrue(hasExpectedAccessibility)

            try await store.deleteCredentials(for: firstAccount)
            try await store.deleteCredentials(for: firstAccount)
            let deletedFirst = try await store.credentials(for: firstAccount)
            let deletedNativeLogin =
                try await store.nativeLoginCredentials(for: firstAccount)
            let retainedSecond = try await store.credentials(for: secondAccount)
            XCTAssertNil(deletedFirst)
            XCTAssertNil(deletedNativeLogin)
            XCTAssertEqual(retainedSecond, secondTokens)
        #endif
    }

    func testRejectsEmptyAccountID() async throws {
        let store = TokenVault(
            service: "com.terminaloutcomes.bleat.tests.\(UUID().uuidString)"
        )
        let emptyAccount = AccountID(rawValue: "")

        await XCTAssertThrowsErrorAsync(
            try await store.credentials(for: emptyAccount)
        ) { error in
            XCTAssertEqual(
                error as? TokenVaultError,
                .invalidAccountID
            )
        }
        await XCTAssertThrowsErrorAsync(
            try await store.save(
                AuthenticationTokens(
                    accessToken: "access",
                    refreshToken: "refresh"
                ),
                for: emptyAccount
            )
        ) { error in
            XCTAssertEqual(
                error as? TokenVaultError,
                .invalidAccountID
            )
        }
        await XCTAssertThrowsErrorAsync(
            try await store.deleteCredentials(for: emptyAccount)
        ) { error in
            XCTAssertEqual(
                error as? TokenVaultError,
                .invalidAccountID
            )
        }
    }

    func testRejectsEmptyService() async throws {
        let store = TokenVault(service: "")

        await XCTAssertThrowsErrorAsync(
            try await store.credentials(
                for: AccountID(rawValue: "account")
            )
        ) { error in
            XCTAssertEqual(
                error as? TokenVaultError,
                .invalidService
            )
        }
    }

    func testRejectsMalformedStoredCredentials() async throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(
                "Requires the future app test host's Keychain entitlement"
            )
        #else
            let service =
                "com.terminaloutcomes.bleat.tests.\(UUID().uuidString)"
            let accountID = AccountID(rawValue: "malformed")
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: accountID.rawValue,
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
                kSecAttrAccessible:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData: Data("not-json".utf8),
            ]
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            XCTAssertEqual(addStatus, errSecSuccess)
            addTeardownBlock {
                SecItemDelete(query as CFDictionary)
            }

            let store = TokenVault(service: service)
            await XCTAssertThrowsErrorAsync(
                try await store.credentials(for: accountID)
            ) { error in
                XCTAssertEqual(
                    error as? TokenVaultError,
                    .invalidStoredCredentials
                )
            }
        #endif
    }

    func testReadsLegacyTokenOnlyItemWithoutInventingPassword() async throws {
        #if targetEnvironment(simulator)
            throw XCTSkip(
                "Requires the future app test host's Keychain entitlement"
            )
        #else
            let service =
                "com.terminaloutcomes.bleat.tests.\(UUID().uuidString)"
            let accountID = AccountID(rawValue: "legacy")
            let tokens = try AuthenticationTokens(
                accessToken: "legacy-access",
                refreshToken: "legacy-refresh"
            )
            let query: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: accountID.rawValue,
                kSecAttrSynchronizable: kCFBooleanFalse as Any,
                kSecAttrAccessible:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData: try JSONEncoder().encode(tokens),
            ]
            XCTAssertEqual(
                SecItemAdd(query as CFDictionary, nil),
                errSecSuccess
            )
            addTeardownBlock {
                SecItemDelete(query as CFDictionary)
            }

            let store = TokenVault(service: service)
            let loadedTokens = try await store.credentials(for: accountID)
            let nativeLogin =
                try await store.nativeLoginCredentials(for: accountID)
            XCTAssertEqual(loadedTokens, tokens)
            XCTAssertNil(nativeLogin)
        #endif
    }

    func testTypedErrorsHaveNonSecretDescriptions() {
        let cases: [(TokenVaultError, String)] = [
            (.invalidService, "The Keychain service identifier is empty."),
            (.invalidAccountID, "The Keychain account identifier is empty."),
            (
                .invalidStoredCredentials,
                "The stored Keychain credentials are invalid."
            ),
            (
                .missingEntitlement,
                "The app is missing a required Keychain entitlement."
            ),
            (
                .interactionNotAllowed,
                "Keychain interaction is not currently allowed."
            ),
            (
                .unexpectedStatus(-50),
                "Keychain returned status -50."
            ),
        ]

        for (error, expectedDescription) in cases {
            XCTAssertEqual(error.errorDescription, expectedDescription)
        }
    }

    func testMissingEntitlementStatusHasTypedError() {
        XCTAssertThrowsError(
            try TokenVault.check(errSecMissingEntitlement)
        ) { error in
            XCTAssertEqual(
                error as? TokenVaultError,
                .missingEntitlement
            )
        }
    }

    private func hasExpectedAccessibility(
        service: String,
        account: String
    ) throws -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrSynchronizable: kCFBooleanFalse as Any,
            kSecAttrAccessible:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
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
