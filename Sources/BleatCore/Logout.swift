import Foundation

private struct LogoutResponse: Decodable {
    let redirectURL: String?

    enum CodingKeys: String, CodingKey {
        case redirectURL = "redirect_url"
    }
}

public enum RemoteLogoutStatus: Equatable, Sendable {
    case completed
    case noCredentials
    case credentialsUnavailable
    case requestFailed
    case rejected(Int)
}

public struct LogoutResult: Equatable, Sendable {
    public let remoteStatus: RemoteLogoutStatus
    public let providerLogoutURL: URL?

    public init(
        remoteStatus: RemoteLogoutStatus,
        providerLogoutURL: URL? = nil
    ) {
        self.remoteStatus = remoteStatus
        self.providerLogoutURL = providerLogoutURL
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
        let result = await performRemoteLogout(
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
        return result
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
        let result = await performRemoteLogout(
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
        return result
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
    ) async -> LogoutResult {
        let credentials: AuthenticationTokens?
        do {
            credentials = try await credentialStore.credentials(
                for: accountID
            )
        } catch {
            return LogoutResult(remoteStatus: .credentialsUnavailable)
        }
        guard let credentials else {
            return LogoutResult(remoteStatus: .noCredentials)
        }

        let logoutURL: URL
        do {
            logoutURL = try AudiobookshelfRouteBuilder(server: server)
                .url(for: .logout)
        } catch {
            return LogoutResult(remoteStatus: .requestFailed)
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
            return LogoutResult(remoteStatus: .requestFailed)
        }
        guard (200..<300).contains(response.statusCode) else {
            return LogoutResult(
                remoteStatus: .rejected(response.statusCode)
            )
        }
        return LogoutResult(
            remoteStatus: .completed,
            providerLogoutURL: Self.providerLogoutURL(from: response.data)
        )
    }

    private nonisolated static func providerLogoutURL(from data: Data) -> URL? {
        guard
            let value = try? JSONDecoder().decode(
                LogoutResponse.self,
                from: data
            ),
            let rawURL = value.redirectURL,
            let url = URL(string: rawURL),
            url.scheme?.lowercased() == "https",
            url.host != nil,
            url.user == nil,
            url.password == nil
        else {
            return nil
        }
        return url
    }

    private func clearAuthenticationState(for accountID: AccountID) {
        refreshAttempts[accountID]?.task.cancel()
        refreshAttempts[accountID] = nil
        completedRefreshes[accountID] = nil
    }
}
