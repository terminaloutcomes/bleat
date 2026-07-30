import Foundation

public enum RemoteLogoutStatus: Equatable, Sendable {
    case completed
    case noCredentials
    case credentialsUnavailable
    case requestFailed
    case rejected(Int)
}

public struct LogoutResult: Equatable, Sendable {
    public let remoteStatus: RemoteLogoutStatus

    public init(remoteStatus: RemoteLogoutStatus) {
        self.remoteStatus = remoteStatus
    }
}

public enum LogoutError: Error, Equatable, Sendable {
    case invalidAccountID
    case accountOperationInProgress
    case credentialDeletionFailed
}

extension AuthCoordinator {
    func isSigningOut(accountID: AccountID) -> Bool {
        accountsSigningOut.contains(accountID)
    }

    public func logout(
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws -> LogoutResult {
        guard !accountID.rawValue.isEmpty else {
            throw LogoutError.invalidAccountID
        }
        guard !accountsLoggingIn.contains(accountID),
              !accountsSigningOut.contains(accountID)
        else {
            throw LogoutError.accountOperationInProgress
        }

        accountOperationGenerations[accountID, default: 0] &+= 1
        accountsSigningOut.insert(accountID)
        defer {
            accountsSigningOut.remove(accountID)
        }

        await settleRefreshBeforeLogout(for: accountID)
        let remoteStatus = await performRemoteLogout(
            accountID: accountID,
            server: server
        )

        do {
            try await credentialStore.deleteCredentials(for: accountID)
        } catch {
            clearAuthenticationState(for: accountID)
            reauthenticationRequiredAccounts.insert(accountID)
            throw LogoutError.credentialDeletionFailed
        }

        clearAuthenticationState(for: accountID)
        reauthenticationRequiredAccounts.remove(accountID)
        return LogoutResult(remoteStatus: remoteStatus)
    }

    public func logoutKeepingNativeLogin(
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws -> LogoutResult {
        guard !accountID.rawValue.isEmpty else {
            throw LogoutError.invalidAccountID
        }
        guard !accountsLoggingIn.contains(accountID),
              !accountsSigningOut.contains(accountID)
        else {
            throw LogoutError.accountOperationInProgress
        }

        accountOperationGenerations[accountID, default: 0] &+= 1
        accountsSigningOut.insert(accountID)
        defer {
            accountsSigningOut.remove(accountID)
        }

        await settleRefreshBeforeLogout(for: accountID)
        let remoteStatus = await performRemoteLogout(
            accountID: accountID,
            server: server
        )
        do {
            try await credentialStore.deleteSessionCredentials(
                for: accountID
            )
        } catch {
            clearAuthenticationState(for: accountID)
            reauthenticationRequiredAccounts.insert(accountID)
            throw LogoutError.credentialDeletionFailed
        }
        clearAuthenticationState(for: accountID)
        reauthenticationRequiredAccounts.remove(accountID)
        return LogoutResult(remoteStatus: remoteStatus)
    }

    private func settleRefreshBeforeLogout(
        for accountID: AccountID
    ) async {
        guard let attempt = refreshAttempts[accountID] else {
            return
        }
        _ = await attempt.task.value
        if refreshAttempts[accountID]?.id == attempt.id {
            refreshAttempts[accountID] = nil
        }
    }

    private func performRemoteLogout(
        accountID: AccountID,
        server: NormalizedServerURL
    ) async -> RemoteLogoutStatus {
        let credentials: AuthenticationTokens?
        do {
            credentials = try await credentialStore.credentials(
                for: accountID
            )
        } catch {
            return .credentialsUnavailable
        }
        guard let credentials else {
            return .noCredentials
        }

        let logoutURL: URL
        do {
            logoutURL = try AudiobookshelfRouteBuilder(server: server)
                .url(for: .logout)
        } catch {
            return .requestFailed
        }
        var request = URLRequest(url: logoutURL)
        request.httpMethod = "POST"
        request.setValue(
            credentials.refreshToken,
            forHTTPHeaderField: "x-refresh-token"
        )

        let response: HTTPResponse
        do {
            response = try await transport.send(
                TracedHTTPRequest(
                    request: request,
                    endpoint: .logout
                )
            )
        } catch {
            return .requestFailed
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            return .rejected(response.statusCode)
        }
        return .completed
    }

    private func clearAuthenticationState(for accountID: AccountID) {
        refreshAttempts[accountID]?.task.cancel()
        refreshAttempts[accountID] = nil
        completedRefreshes[accountID] = nil
    }
}
