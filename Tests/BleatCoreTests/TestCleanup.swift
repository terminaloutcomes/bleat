import Foundation
import Testing

@testable import BleatCore

/// Await cleanup on both exits, retaining the original operation failure.
func withTestCleanup<T>(
    _ cleanup: () async throws -> Void,
    isolation: isolated (any Actor)? = #isolation,
    operation: () async throws -> T
) async throws -> T {
    let result: T
    do {
        result = try await operation()
    } catch {
        do {
            try await cleanup()
        } catch {
            Issue.record(error, "Test cleanup failed")
        }
        throw error
    }
    try await cleanup()
    return result
}

#if targetEnvironment(simulator)
    let keychainHostAvailable = false
#else
    let keychainHostAvailable = true
#endif

/// Probe only synthetic, uniquely scoped credentials; unexpected failures fail
/// trait evaluation instead of being misreported as an entitlement skip.
func synchronizedKeychainAvailable() async throws -> Bool {
    guard keychainHostAvailable else { return false }
    let suffix = UUID().uuidString
    let store = TokenVault(
        tokenService: "com.terminaloutcomes.bleat.tests.probe.token.\(suffix)",
        nativeLoginService:
            "com.terminaloutcomes.bleat.tests.probe.login.\(suffix)",
        legacyService: nil,
        synchronizesNativeLogin: true
    )
    return try await withTestCleanup(
        { try await store.deleteAllCredentials() },
        operation: {
            do {
                try await store.save(
                    AuthenticationTokens(
                        accessToken: "probe", refreshToken: "probe"),
                    nativeLogin: NativeLoginCredentials(
                        userID: UserID(rawValue: "probe"),
                        username: "probe",
                        password: "probe"
                    ),
                    for: AccountID(rawValue: "probe")
                )
                return true
            } catch TokenVaultError.missingEntitlement {
                return false
            }
        })
}
