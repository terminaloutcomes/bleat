import Security
@testable import BleatCore
import XCTest

final class KeychainEntitlementTests: XCTestCase {
    func testApplicationHostCanPersistCredentialsInKeychain() async throws {
        let store = TokenVault(
            service: "com.yaleman.bleat.app-tests.\(UUID().uuidString)"
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

    func testApplicationHostPersistsDeviceOnlyTelemetryEnrollment()
        async throws
    {
        let vault = TelemetryEnrollmentVault(
            service: "com.yaleman.bleat.telemetry-tests.\(UUID().uuidString)"
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
}
