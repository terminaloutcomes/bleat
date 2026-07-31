import BleatCore
import XCTest

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
}
