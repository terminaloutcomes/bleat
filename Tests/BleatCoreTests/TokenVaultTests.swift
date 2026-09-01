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

    func testDeleteAllCredentialsRemovesEveryAccountAndCredentialKind()
        async throws
    {
        #if targetEnvironment(simulator)
            throw XCTSkip(
                "Requires the future app test host's Keychain entitlement"
            )
        #else
            let suffix = UUID().uuidString
            let store = TokenVault(
                tokenService:
                    "com.terminaloutcomes.bleat.tests.token.\(suffix)",
                nativeLoginService:
                    "com.terminaloutcomes.bleat.tests.login.\(suffix)",
                legacyService:
                    "com.terminaloutcomes.bleat.tests.legacy.\(suffix)",
                synchronizesNativeLogin: false
            )
            let firstAccount = AccountID(rawValue: "first")
            let secondAccount = AccountID(rawValue: "second")
            let tokens = try AuthenticationTokens(
                accessToken: "access",
                refreshToken: "refresh"
            )
            let login = try NativeLoginCredentials(
                userID: UserID(rawValue: "reader"),
                username: "reader",
                password: "password"
            )
            addTeardownBlock {
                try await store.deleteAllCredentials()
            }

            try await store.save(tokens, nativeLogin: login, for: firstAccount)
            try await store.save(tokens, nativeLogin: login, for: secondAccount)

            try await store.deleteAllCredentials()

            let firstTokens = try await store.credentials(for: firstAccount)
            let secondTokens = try await store.credentials(for: secondAccount)
            let firstLogin = try await store.nativeLoginCredentials(
                for: firstAccount
            )
            let secondLogin = try await store.nativeLoginCredentials(
                for: secondAccount
            )
            XCTAssertNil(firstTokens)
            XCTAssertNil(secondTokens)
            XCTAssertNil(firstLogin)
            XCTAssertNil(secondLogin)
        #endif
    }

    func
        testDeleteAllCredentialsRemovesNativeLoginAfterICloudKeychainIsDisabled()
        async throws
    {
        #if targetEnvironment(simulator)
            throw XCTSkip(
                "Requires the future app test host's Keychain entitlement"
            )
        #else
            let suffix = UUID().uuidString
            let tokenService =
                "com.terminaloutcomes.bleat.tests.token.\(suffix)"
            let nativeLoginService =
                "com.terminaloutcomes.bleat.tests.login.\(suffix)"
            let enabledStore = TokenVault(
                tokenService: tokenService,
                nativeLoginService: nativeLoginService,
                legacyService: nil,
                synchronizesNativeLogin: true
            )
            let disabledStore = TokenVault(
                tokenService: tokenService,
                nativeLoginService: nativeLoginService,
                legacyService: nil,
                synchronizesNativeLogin: false
            )
            let account = AccountID(rawValue: "account")
            let login = try NativeLoginCredentials(
                userID: UserID(rawValue: "reader"),
                username: "reader",
                password: "password"
            )
            addTeardownBlock {
                try await enabledStore.deleteAllCredentials()
            }

            do {
                try await enabledStore.save(
                    try AuthenticationTokens(
                        accessToken: "access",
                        refreshToken: "refresh"
                    ),
                    nativeLogin: login,
                    for: account
                )
            } catch TokenVaultError.missingEntitlement {
                throw XCTSkip("Requires an iCloud Keychain entitlement")
            }
            try await disabledStore.deleteAllCredentials()

            let remainingLogin =
                try await enabledStore
                .nativeLoginCredentials(for: account)
            XCTAssertNil(remainingLogin)
        #endif
    }

    func testIdentityMigrationPreservesExistingCanonicalCredentials()
        async throws
    {
        #if targetEnvironment(simulator)
            throw XCTSkip(
                "Requires the future app test host's Keychain entitlement"
            )
        #else
            let suffix = UUID().uuidString
            let store = TokenVault(
                tokenService:
                    "com.terminaloutcomes.bleat.tests.token.\(suffix)",
                nativeLoginService:
                    "com.terminaloutcomes.bleat.tests.login.\(suffix)",
                legacyService: nil,
                synchronizesNativeLogin: false
            )
            let legacyID = AccountID(rawValue: "legacy")
            let canonicalID = AccountID(rawValue: "canonical")
            let legacyTokens = try AuthenticationTokens(
                accessToken: "legacy-access",
                refreshToken: "legacy-refresh"
            )
            let canonicalTokens = try AuthenticationTokens(
                accessToken: "canonical-access",
                refreshToken: "canonical-refresh"
            )
            let legacyLogin = try NativeLoginCredentials(
                userID: UserID(rawValue: "user"),
                username: "legacy-reader",
                password: "legacy-password"
            )
            let canonicalLogin = try NativeLoginCredentials(
                userID: UserID(rawValue: "user"),
                username: "canonical-reader",
                password: "canonical-password"
            )
            addTeardownBlock {
                try await store.deleteCredentials(for: legacyID)
                try await store.deleteCredentials(for: canonicalID)
            }
            try await store.save(
                legacyTokens,
                nativeLogin: legacyLogin,
                for: legacyID
            )
            try await store.save(
                canonicalTokens,
                nativeLogin: canonicalLogin,
                for: canonicalID
            )

            try await store.migrateCredentials(
                from: legacyID,
                to: canonicalID
            )

            let migratedTokens = try await store.credentials(for: canonicalID)
            let migratedLogin = try await store.nativeLoginCredentials(
                for: canonicalID
            )
            XCTAssertEqual(migratedTokens, canonicalTokens)
            XCTAssertEqual(migratedLogin, canonicalLogin)
        #endif
    }

    func testRejectsEmptyAccountID() async throws {
        let store = TokenVault(
            service: "com.terminaloutcomes.bleat.tests.\(UUID().uuidString)"
        )
        let emptyAccount = AccountID(rawValue: "")

        await assertThrowsErrorAsync(
            try await store.credentials(for: emptyAccount)
        ) { error in
            XCTAssertEqual(
                error as? TokenVaultError,
                .invalidAccountID
            )
        }
        await assertThrowsErrorAsync(
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
        await assertThrowsErrorAsync(
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

        await assertThrowsErrorAsync(
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
            await assertThrowsErrorAsync(
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
