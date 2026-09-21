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
