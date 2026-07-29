import Foundation
import XCTest

@testable import BleatCore

final class LocalAuthenticationLiveTests: XCTestCase {
    func testPinnedRootAndPrefixLocalAuthenticationContracts() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rootURL = environment["BLEAT_LIVE_ROOT_URL"],
            let prefixURL = environment["BLEAT_LIVE_PREFIX_URL"],
            let username = environment["BLEAT_LIVE_USERNAME"],
            let password = environment["BLEAT_LIVE_PASSWORD"]
        else {
            throw XCTSkip(
                "Run scripts/test-live.sh to provide live authentication data"
            )
        }

        for (index, liveURL) in [rootURL, prefixURL].enumerated() {
            let server = try secureLiveServerURL(for: liveURL)
            let accountID = AccountID(rawValue: "live-\(index)")
            let store = LiveCredentialStore()
            let client = AuthCoordinator(
                transport: LocalDockerHTTPTransport(),
                credentialStore: store
            )

            let account = try await client.login(
                accountID: accountID,
                server: server,
                username: username,
                password: password
            )
            let storedCredentials = await store.credentials(for: accountID)

            XCTAssertEqual(account.id, accountID)
            XCTAssertEqual(account.server, server)
            XCTAssertEqual(account.user.username, username)
            XCTAssertEqual(account.user.type, .root)
            XCTAssertTrue(account.user.permissions.accessAllLibraries)
            XCTAssertNotNil(storedCredentials)

            let initialTokens = try XCTUnwrap(storedCredentials)
            let rejectedAccessTokens = try AuthenticationTokens(
                accessToken: "rejected-access-\(index)",
                refreshToken: initialTokens.refreshToken
            )
            await store.save(rejectedAccessTokens, for: accountID)
            var librariesRequest = URLRequest(
                url: try AudiobookshelfRouteBuilder(server: server)
                    .url(for: .libraries)
            )
            librariesRequest.httpMethod = "GET"

            let librariesResponse = try await client.sendAuthenticated(
                librariesRequest,
                route: .libraries,
                accountID: accountID,
                server: server
            )
            let storedRotatedTokens =
                await store.credentials(for: accountID)
            let rotatedTokens = try XCTUnwrap(storedRotatedTokens)
            let requiresReauthentication =
                await client.requiresReauthentication(for: accountID)

            XCTAssertEqual(librariesResponse.statusCode, 200)
            XCTAssertNotEqual(
                rotatedTokens.accessToken,
                rejectedAccessTokens.accessToken
            )
            XCTAssertNotEqual(
                rotatedTokens.refreshToken,
                initialTokens.refreshToken
            )
            XCTAssertFalse(requiresReauthentication)

            let logoutResult = try await client.logout(
                accountID: accountID,
                server: server
            )
            let credentialsAfterLogout =
                await store.credentials(for: accountID)
            let requiresReauthenticationAfterLogout =
                await client.requiresReauthentication(for: accountID)
            var rejectedRefreshRequest = URLRequest(
                url: try AudiobookshelfRouteBuilder(server: server)
                    .url(for: .refresh)
            )
            rejectedRefreshRequest.httpMethod = "POST"
            rejectedRefreshRequest.setValue(
                rotatedTokens.refreshToken,
                forHTTPHeaderField: "x-refresh-token"
            )
            let rejectedRefreshResponse =
                try await LocalDockerHTTPTransport().send(
                    rejectedRefreshRequest
                )

            XCTAssertEqual(logoutResult.remoteStatus, .completed)
            XCTAssertNil(credentialsAfterLogout)
            XCTAssertFalse(requiresReauthenticationAfterLogout)
            XCTAssertEqual(rejectedRefreshResponse.statusCode, 401)

            let recoveryAccountID = AccountID(
                rawValue: "live-recovery-\(index)"
            )
            let recoveryStore = LiveCredentialStore()
            let recoveryTransport = LocalDockerHTTPTransport()
            let recoveryCoordinator = AuthCoordinator(
                transport: recoveryTransport,
                credentialStore: recoveryStore
            )
            _ = try await recoveryCoordinator.login(
                accountID: recoveryAccountID,
                server: server,
                username: username,
                password: password
            )
            let storedRecoveryTokens =
                await recoveryStore.credentials(for: recoveryAccountID)
            let recoveryTokens = try XCTUnwrap(storedRecoveryTokens)
            var invalidateRefreshRequest = URLRequest(
                url: try AudiobookshelfRouteBuilder(server: server)
                    .url(for: .logout)
            )
            invalidateRefreshRequest.httpMethod = "POST"
            invalidateRefreshRequest.setValue(
                recoveryTokens.refreshToken,
                forHTTPHeaderField: "x-refresh-token"
            )
            let invalidationResponse = try await recoveryTransport.send(
                invalidateRefreshRequest
            )
            XCTAssertEqual(invalidationResponse.statusCode, 200)

            let rejectedRecoveryTokens = try AuthenticationTokens(
                accessToken: "rejected-recovery-access-\(index)",
                refreshToken: recoveryTokens.refreshToken
            )
            await recoveryStore.save(
                rejectedRecoveryTokens,
                for: recoveryAccountID
            )
            let recoveredResponse =
                try await recoveryCoordinator.sendAuthenticated(
                    librariesRequest,
                    route: .libraries,
                    accountID: recoveryAccountID,
                    server: server
                )
            let storedAutomaticallyRecoveredTokens =
                await recoveryStore.credentials(for: recoveryAccountID)
            let automaticallyRecoveredTokens = try XCTUnwrap(
                storedAutomaticallyRecoveredTokens
            )
            let retainedNativeLogin =
                await recoveryStore
                .nativeLoginCredentials(for: recoveryAccountID)

            XCTAssertEqual(recoveredResponse.statusCode, 200)
            XCTAssertNotEqual(
                automaticallyRecoveredTokens.accessToken,
                rejectedRecoveryTokens.accessToken
            )
            XCTAssertNotEqual(
                automaticallyRecoveredTokens.refreshToken,
                rejectedRecoveryTokens.refreshToken
            )
            XCTAssertEqual(retainedNativeLogin?.username, username)
            _ = try await recoveryCoordinator.logout(
                accountID: recoveryAccountID,
                server: server
            )

            let rejectedStore = LiveCredentialStore()
            let rejectedCoordinator = AuthCoordinator(
                transport: LocalDockerHTTPTransport(),
                credentialStore: rejectedStore
            )
            do {
                _ = try await rejectedCoordinator.login(
                    accountID: accountID,
                    server: server,
                    username: username,
                    password: "\(password)-incorrect"
                )
                XCTFail("Expected invalid credentials to be rejected")
            } catch {
                XCTAssertEqual(
                    error as? LocalAuthenticationError,
                    .invalidCredentials
                )
            }
            let rejectedCredentials =
                await rejectedStore.credentials(for: accountID)
            XCTAssertNil(rejectedCredentials)
        }
    }

}
