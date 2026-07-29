import Foundation

public enum AuthenticatedRequestError: Error, Equatable, Sendable {
    case invalidAccountID
    case accountOperationInProgress
    case authenticationEndpoint
    case requestDoesNotMatchRoute
    case credentialsReadFailed
    case missingCredentials
    case authorizationFailed(BearerAuthorizationError)
    case requestTransportFailed
    case refreshRequestConstructionFailed
    case refreshTransportFailed
    case refreshCancelled
    case refreshRejected
    case unexpectedRefreshStatus(Int)
    case malformedRefreshResponse
    case missingAccessToken
    case missingRefreshToken
    case credentialPersistenceFailed
    case retriedRequestUnauthorized
}

struct RefreshAttempt: Sendable {
    let id: UInt64
    let task: Task<
        Result<AuthenticationTokens, AuthenticatedRequestError>,
        Never
    >
}

struct CompletedRefresh: Sendable {
    let rejectedAccessToken: String
    let result: Result<
        AuthenticationTokens,
        AuthenticatedRequestError
    >
}

extension AuthCoordinator {
    public func sendAuthenticated(
        _ request: URLRequest,
        route: AudiobookshelfRoute,
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws -> HTTPResponse {
        guard !accountID.rawValue.isEmpty else {
            throw AuthenticatedRequestError.invalidAccountID
        }
        guard !accountsSigningOut.contains(accountID) else {
            throw AuthenticatedRequestError.accountOperationInProgress
        }
        guard !route.isAuthenticationEndpoint else {
            throw AuthenticatedRequestError.authenticationEndpoint
        }
        guard requestMatchesRoute(
            request,
            route: route,
            server: server
        ) else {
            throw AuthenticatedRequestError.requestDoesNotMatchRoute
        }

        let initialTokens = try await storedCredentials(for: accountID)
        let initialResponse = try await send(
            request,
            accessToken: initialTokens.accessToken
        )
        guard initialResponse.statusCode == 401 else {
            return initialResponse
        }

        let refreshedTokens = try await credentialsAfterUnauthorizedResponse(
            accountID: accountID,
            server: server,
            rejectedAccessToken: initialTokens.accessToken
        )
        guard !accountsSigningOut.contains(accountID) else {
            throw AuthenticatedRequestError.accountOperationInProgress
        }
        let retriedResponse = try await send(
            request,
            accessToken: refreshedTokens.accessToken
        )
        guard retriedResponse.statusCode != 401 else {
            reauthenticationRequiredAccounts.insert(accountID)
            throw AuthenticatedRequestError.retriedRequestUnauthorized
        }
        return retriedResponse
    }

    public func requiresReauthentication(
        for accountID: AccountID
    ) -> Bool {
        reauthenticationRequiredAccounts.contains(accountID)
    }

    private func requestMatchesRoute(
        _ request: URLRequest,
        route: AudiobookshelfRoute,
        server: NormalizedServerURL
    ) -> Bool {
        guard let requestURL = request.url,
              var requestComponents = URLComponents(
                  url: requestURL,
                  resolvingAgainstBaseURL: false
              )
        else {
            return false
        }

        guard let expectedURL = try? AudiobookshelfRouteBuilder(server: server)
            .url(for: route)
        else {
            return false
        }
        requestComponents.query = nil
        return requestComponents.url == expectedURL
    }

    func storedCredentials(
        for accountID: AccountID
    ) async throws -> AuthenticationTokens {
        let credentials: AuthenticationTokens?
        do {
            credentials = try await credentialStore.credentials(
                for: accountID
            )
        } catch {
            throw AuthenticatedRequestError.credentialsReadFailed
        }
        guard let credentials else {
            reauthenticationRequiredAccounts.insert(accountID)
            throw AuthenticatedRequestError.missingCredentials
        }
        return credentials
    }

    private func send(
        _ request: URLRequest,
        accessToken: String
    ) async throws -> HTTPResponse {
        let authorizedRequest: URLRequest
        do {
            authorizedRequest = try requestAuthorizer.authorize(
                request,
                accessToken: accessToken
            )
        } catch let error {
            throw AuthenticatedRequestError.authorizationFailed(error)
        }

        do {
            return try await transport.send(authorizedRequest)
        } catch {
            throw AuthenticatedRequestError.requestTransportFailed
        }
    }

    func credentialsAfterUnauthorizedResponse(
        accountID: AccountID,
        server: NormalizedServerURL,
        rejectedAccessToken: String
    ) async throws -> AuthenticationTokens {
        let currentTokens = try await storedCredentials(for: accountID)
        guard !accountsSigningOut.contains(accountID) else {
            throw AuthenticatedRequestError.accountOperationInProgress
        }
        if currentTokens.accessToken != rejectedAccessToken {
            return currentTokens
        }
        if let completed = completedRefreshes[accountID],
           completed.rejectedAccessToken == rejectedAccessToken
        {
            return try completed.result.get()
        }

        if let attempt = refreshAttempts[accountID] {
            return try await finishRefresh(
                attempt,
                accountID: accountID,
                rejectedAccessToken: rejectedAccessToken
            )
        }

        nextRefreshAttemptID &+= 1
        let attemptID = nextRefreshAttemptID
        let transport = transport
        let credentialStore = credentialStore
        let task: Task<
            Result<AuthenticationTokens, AuthenticatedRequestError>,
            Never
        > = Task {
            do {
                return .success(
                    try await Self.refresh(
                        accountID: accountID,
                        server: server,
                        refreshToken: currentTokens.refreshToken,
                        transport: transport,
                        credentialStore: credentialStore
                    )
                )
            } catch let error as AuthenticatedRequestError {
                return .failure(error)
            } catch {
                return .failure(.refreshTransportFailed)
            }
        }
        let attempt = RefreshAttempt(id: attemptID, task: task)
        refreshAttempts[accountID] = attempt
        return try await finishRefresh(
            attempt,
            accountID: accountID,
            rejectedAccessToken: rejectedAccessToken
        )
    }

    private func finishRefresh(
        _ attempt: RefreshAttempt,
        accountID: AccountID,
        rejectedAccessToken: String
    ) async throws -> AuthenticationTokens {
        switch await attempt.task.value {
        case let .success(tokens):
            completedRefreshes[accountID] = CompletedRefresh(
                rejectedAccessToken: rejectedAccessToken,
                result: .success(tokens)
            )
            clearRefreshAttempt(attempt, accountID: accountID)
            reauthenticationRequiredAccounts.remove(accountID)
            return tokens
        case let .failure(error):
            completedRefreshes[accountID] = CompletedRefresh(
                rejectedAccessToken: rejectedAccessToken,
                result: .failure(error)
            )
            clearRefreshAttempt(attempt, accountID: accountID)
            reauthenticationRequiredAccounts.insert(accountID)
            throw error
        }
    }

    private func clearRefreshAttempt(
        _ attempt: RefreshAttempt,
        accountID: AccountID
    ) {
        guard refreshAttempts[accountID]?.id == attempt.id else {
            return
        }
        refreshAttempts[accountID] = nil
    }

    private static func refresh(
        accountID: AccountID,
        server: NormalizedServerURL,
        refreshToken: String,
        transport: Transport,
        credentialStore: CredentialStore
    ) async throws(AuthenticatedRequestError) -> AuthenticationTokens {
        let refreshURL: URL
        do {
            refreshURL = try AudiobookshelfRouteBuilder(server: server)
                .url(for: .refresh)
        } catch {
            throw .refreshRequestConstructionFailed
        }
        var request = URLRequest(url: refreshURL)
        request.httpMethod = "POST"
        request.setValue(
            refreshToken,
            forHTTPHeaderField: "x-refresh-token"
        )

        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            if Task.isCancelled {
                throw AuthenticatedRequestError.refreshCancelled
            }
            throw AuthenticatedRequestError.refreshTransportFailed
        }
        guard !Task.isCancelled else {
            throw AuthenticatedRequestError.refreshCancelled
        }
        switch response.statusCode {
        case 200:
            break
        case 401:
            throw AuthenticatedRequestError.refreshRejected
        default:
            throw AuthenticatedRequestError.unexpectedRefreshStatus(
                response.statusCode
            )
        }

        let payload: AuthenticationResponse
        do {
            payload = try JSONDecoder().decode(
                AuthenticationResponse.self,
                from: response.data
            )
        } catch {
            throw AuthenticatedRequestError.malformedRefreshResponse
        }
        guard let accessToken = payload.user.accessToken else {
            throw AuthenticatedRequestError.missingAccessToken
        }
        guard let refreshToken = payload.user.refreshToken else {
            throw AuthenticatedRequestError.missingRefreshToken
        }

        let tokens: AuthenticationTokens
        do {
            tokens = try AuthenticationTokens(
                accessToken: accessToken,
                refreshToken: refreshToken
            )
        } catch let error {
            switch error {
            case .invalidAccessToken:
                throw AuthenticatedRequestError.missingAccessToken
            case .invalidRefreshToken:
                throw AuthenticatedRequestError.missingRefreshToken
            }
        }

        do {
            guard !Task.isCancelled else {
                throw AuthenticatedRequestError.refreshCancelled
            }
            try await credentialStore.save(tokens, for: accountID)
        } catch let error as AuthenticatedRequestError {
            throw error
        } catch {
            throw AuthenticatedRequestError.credentialPersistenceFailed
        }
        return tokens
    }
}

private extension AudiobookshelfRoute {
    var isAuthenticationEndpoint: Bool {
        switch self {
        case .login, .beginOpenID, .completeOpenID, .refresh, .logout,
             .authorize:
            true
        default:
            false
        }
    }
}
