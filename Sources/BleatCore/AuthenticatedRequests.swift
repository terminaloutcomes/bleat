import Foundation

public enum AuthenticatedRequestError: Error, Equatable, Sendable {
    case invalidAccountID
    case accountOperationInProgress
    case authenticationEndpoint
    case requestDoesNotMatchRoute
    case credentialsReadFailed
    case missingCredentials
    case authorizationFailed(BearerAuthorizationError)
    case requestCancelled
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
    case savedLoginCredentialsReadFailed
    case automaticReauthenticationFailed(LocalAuthenticationError)
    case automaticReauthenticationTransportFailed
    case retriedRequestUnauthorized
}

struct RefreshAttempt: Sendable {
    let id: UInt64
    let rejectedAccessToken: String
    let task:
        Task<
            Result<AuthenticationTokens, AuthenticationRecoveryFailure>,
            Never
        >
}

enum AuthenticationRecoveryDisposition: Sendable {
    case retryable
    case reauthenticationRequired
}

struct AuthenticationRecoveryFailure: Error, Sendable {
    let error: AuthenticatedRequestError
    let disposition: AuthenticationRecoveryDisposition
}

struct CompletedRefresh: Sendable {
    let rejectedAccessToken: String
    let result:
        Result<
            AuthenticationTokens,
            AuthenticatedRequestError
        >
}

extension AuthCoordinator {
    public func accessToken(
        for accountID: AccountID
    ) async throws(AuthenticatedRequestError) -> String {
        do {
            return try await storedCredentials(for: accountID).accessToken
        } catch let error as AuthenticatedRequestError {
            throw error
        } catch {
            throw .credentialsReadFailed
        }
    }

    public func recoverAccessToken(
        for accountID: AccountID,
        server: NormalizedServerURL,
        rejectedAccessToken: String
    ) async throws(AuthenticatedRequestError) -> String {
        do {
            return try await credentialsAfterUnauthorizedResponse(
                accountID: accountID,
                server: server,
                rejectedAccessToken: rejectedAccessToken
            ).accessToken
        } catch let error as AuthenticatedRequestError {
            throw error
        } catch {
            throw .refreshTransportFailed
        }
    }

    public func sendAuthenticated(
        _ request: URLRequest,
        route: AudiobookshelfRoute,
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws -> HTTPResponse {
        guard !accountID.rawValue.isEmpty else {
            throw AuthenticatedRequestError.invalidAccountID
        }
        guard !accountsLoggingIn.contains(accountID),
            !accountsSigningOut.contains(accountID)
        else {
            throw AuthenticatedRequestError.accountOperationInProgress
        }
        let operationGeneration = accountOperationGenerations[
            accountID,
            default: 0
        ]
        guard !route.isAuthenticationEndpoint else {
            throw AuthenticatedRequestError.authenticationEndpoint
        }
        guard
            requestMatchesRoute(
                request,
                route: route,
                server: server
            )
        else {
            throw AuthenticatedRequestError.requestDoesNotMatchRoute
        }

        let initialTokens = try await credentialsForInitialRequest(
            accountID: accountID,
            server: server
        )
        let tracedRequest = TracedHTTPRequest(
            request: request,
            endpoint: route.diagnosticEndpoint,
            correlationID:
                request.value(forHTTPHeaderField: "X-Bleat-Request-ID")
                .flatMap(UUID.init(uuidString:)) ?? UUID()
        )
        let initialResponse = try await send(
            tracedRequest,
            accessToken: initialTokens.accessToken
        )
        guard
            accountOperationIsCurrent(
                accountID,
                generation: operationGeneration
            )
        else {
            throw AuthenticatedRequestError.accountOperationInProgress
        }
        guard initialResponse.statusCode == 401 else {
            return initialResponse
        }

        let refreshedTokens = try await credentialsAfterUnauthorizedResponse(
            accountID: accountID,
            server: server,
            rejectedAccessToken: initialTokens.accessToken
        )
        guard
            accountOperationIsCurrent(
                accountID,
                generation: operationGeneration
            )
        else {
            throw AuthenticatedRequestError.accountOperationInProgress
        }
        let retriedResponse = try await send(
            tracedRequest,
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

        guard
            let expectedURL = try? AudiobookshelfRouteBuilder(server: server)
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

    private func credentialsForInitialRequest(
        accountID: AccountID,
        server: NormalizedServerURL
    ) async throws(AuthenticatedRequestError) -> AuthenticationTokens {
        do {
            return try await storedCredentials(for: accountID)
        } catch AuthenticatedRequestError.missingCredentials {
            // A second device intentionally has no synchronized session tokens.
            // Use its synchronized native login to establish a fresh local
            // session before issuing the original request.
        } catch let error as AuthenticatedRequestError {
            throw error
        } catch {
            throw .credentialsReadFailed
        }

        let nativeLogin: NativeLoginCredentials
        do {
            guard let savedLogin = try await credentialStore
                .nativeLoginCredentials(for: accountID)
            else {
                throw AuthenticatedRequestError.missingCredentials
            }
            nativeLogin = savedLogin
        } catch let error as AuthenticatedRequestError {
            throw error
        } catch {
            reauthenticationRequiredAccounts.remove(accountID)
            throw .savedLoginCredentialsReadFailed
        }

        do {
            let result = try await Self.authenticateLocally(
                accountID: accountID,
                server: server,
                username: nativeLogin.username,
                password: nativeLogin.password,
                expectedUserID: nativeLogin.userID,
                persistCredentials: true,
                transport: transport,
                credentialStore: credentialStore
            )
            reauthenticationRequiredAccounts.remove(accountID)
            return result.tokens
        } catch let error as LocalAuthenticationError {
            switch error.recoveryDisposition {
            case .retryable:
                reauthenticationRequiredAccounts.remove(accountID)
            case .reauthenticationRequired:
                reauthenticationRequiredAccounts.insert(accountID)
            }
            throw .automaticReauthenticationFailed(error)
        } catch {
            reauthenticationRequiredAccounts.remove(accountID)
            throw .automaticReauthenticationTransportFailed
        }
    }

    private func send(
        _ tracedRequest: TracedHTTPRequest,
        accessToken: String
    ) async throws -> HTTPResponse {
        let authorizedRequest: URLRequest
        do {
            authorizedRequest = try requestAuthorizer.authorize(
                tracedRequest.request,
                accessToken: accessToken
            )
        } catch let error {
            throw AuthenticatedRequestError.authorizationFailed(error)
        }

        do {
            return try await transport.send(
                tracedRequest.replacingRequest(authorizedRequest)
            )
        } catch {
            if Task.isCancelled {
                throw AuthenticatedRequestError.requestCancelled
            }
            throw AuthenticatedRequestError.requestTransportFailed
        }
    }

    func credentialsAfterUnauthorizedResponse(
        accountID: AccountID,
        server: NormalizedServerURL,
        rejectedAccessToken: String
    ) async throws -> AuthenticationTokens {
        let operationGeneration = accountOperationGenerations[
            accountID,
            default: 0
        ]
        let currentTokens = try await storedCredentials(for: accountID)
        guard
            accountOperationIsCurrent(
                accountID,
                generation: operationGeneration
            )
        else {
            throw AuthenticatedRequestError.accountOperationInProgress
        }
        if let attempt = refreshAttempts[accountID] {
            let tokens = try await finishRefresh(
                attempt,
                accountID: accountID
            )
            guard
                accountOperationIsCurrent(
                    accountID,
                    generation: operationGeneration
                )
            else {
                throw AuthenticatedRequestError.accountOperationInProgress
            }
            return tokens
        }

        if let completed = completedRefreshes[accountID],
            completed.rejectedAccessToken == rejectedAccessToken
        {
            let tokens = try completed.result.get()
            guard
                accountOperationIsCurrent(
                    accountID,
                    generation: operationGeneration
                )
            else {
                throw AuthenticatedRequestError.accountOperationInProgress
            }
            return tokens
        }

        if currentTokens.accessToken != rejectedAccessToken {
            return currentTokens
        }

        nextRefreshAttemptID &+= 1
        let attemptID = nextRefreshAttemptID
        let transport = transport
        let credentialStore = credentialStore
        let task:
            Task<
                Result<AuthenticationTokens, AuthenticationRecoveryFailure>,
                Never
            > = Task {
                do {
                    return .success(
                        try await Self.refreshOrReauthenticate(
                            accountID: accountID,
                            server: server,
                            refreshToken: currentTokens.refreshToken,
                            transport: transport,
                            credentialStore: credentialStore
                        )
                    )
                } catch let failure as AuthenticationRecoveryFailure {
                    return .failure(failure)
                } catch {
                    return .failure(
                        AuthenticationRecoveryFailure(
                            error: .refreshTransportFailed,
                            disposition: .retryable
                        )
                    )
                }
            }
        let attempt = RefreshAttempt(
            id: attemptID,
            rejectedAccessToken: rejectedAccessToken,
            task: task
        )
        refreshAttempts[accountID] = attempt
        let tokens = try await finishRefresh(
            attempt,
            accountID: accountID
        )
        guard
            accountOperationIsCurrent(
                accountID,
                generation: operationGeneration
            )
        else {
            throw AuthenticatedRequestError.accountOperationInProgress
        }
        return tokens
    }

    private func accountOperationIsCurrent(
        _ accountID: AccountID,
        generation: UInt64
    ) -> Bool {
        accountOperationGenerations[accountID, default: 0] == generation
            && !accountsLoggingIn.contains(accountID)
            && !accountsSigningOut.contains(accountID)
    }

    private func finishRefresh(
        _ attempt: RefreshAttempt,
        accountID: AccountID
    ) async throws -> AuthenticationTokens {
        let result = await attempt.task.value
        let isCurrentAttempt =
            refreshAttempts[accountID]?.id == attempt.id

        switch result {
        case .success(let tokens):
            if isCurrentAttempt {
                completedRefreshes[accountID] = CompletedRefresh(
                    rejectedAccessToken: attempt.rejectedAccessToken,
                    result: .success(tokens)
                )
                clearRefreshAttempt(attempt, accountID: accountID)
                reauthenticationRequiredAccounts.remove(accountID)
            }
            return tokens
        case .failure(let failure):
            if isCurrentAttempt {
                switch failure.disposition {
                case .retryable:
                    completedRefreshes[accountID] = nil
                case .reauthenticationRequired:
                    completedRefreshes[accountID] = CompletedRefresh(
                        rejectedAccessToken: attempt.rejectedAccessToken,
                        result: .failure(failure.error)
                    )
                    reauthenticationRequiredAccounts.insert(accountID)
                }
                clearRefreshAttempt(attempt, accountID: accountID)
            }
            throw failure.error
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

    private static func refreshOrReauthenticate(
        accountID: AccountID,
        server: NormalizedServerURL,
        refreshToken: String,
        transport: Transport,
        credentialStore: CredentialStore
    ) async throws(AuthenticationRecoveryFailure) -> AuthenticationTokens {
        let refreshError: AuthenticatedRequestError
        do {
            return try await refresh(
                accountID: accountID,
                server: server,
                refreshToken: refreshToken,
                transport: transport,
                credentialStore: credentialStore
            )
        } catch let error {
            guard error.usesSavedLoginRecovery else {
                throw AuthenticationRecoveryFailure(
                    error: error,
                    disposition: .retryable
                )
            }
            refreshError = error
        }

        let nativeLogin: NativeLoginCredentials?
        do {
            nativeLogin = try await credentialStore.nativeLoginCredentials(
                for: accountID
            )
        } catch {
            throw AuthenticationRecoveryFailure(
                error: .savedLoginCredentialsReadFailed,
                disposition: .retryable
            )
        }
        guard let nativeLogin else {
            throw AuthenticationRecoveryFailure(
                error: refreshError,
                disposition: .reauthenticationRequired
            )
        }

        do {
            return try await authenticateLocally(
                accountID: accountID,
                server: server,
                username: nativeLogin.username,
                password: nativeLogin.password,
                expectedUserID: nativeLogin.userID,
                persistCredentials: true,
                transport: transport,
                credentialStore: credentialStore
            ).tokens
        } catch let error as LocalAuthenticationError {
            throw AuthenticationRecoveryFailure(
                error: .automaticReauthenticationFailed(error),
                disposition: error.recoveryDisposition
            )
        } catch {
            throw AuthenticationRecoveryFailure(
                error: .automaticReauthenticationTransportFailed,
                disposition: .retryable
            )
        }
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
            response = try await transport.send(
                TracedHTTPRequest(
                    request: request,
                    endpoint: .refresh
                )
            )
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

extension AuthenticatedRequestError {
    fileprivate var usesSavedLoginRecovery: Bool {
        switch self {
        case .refreshRejected, .unexpectedRefreshStatus,
            .malformedRefreshResponse, .missingAccessToken,
            .missingRefreshToken, .credentialPersistenceFailed:
            true
        default:
            false
        }
    }
}

extension LocalAuthenticationError {
    fileprivate var recoveryDisposition: AuthenticationRecoveryDisposition {
        switch self {
        case .invalidCredentials, .tokenValidationFailed,
            .authorizedUserMismatch:
            .reauthenticationRequired
        default:
            .retryable
        }
    }
}

extension AudiobookshelfRoute {
    fileprivate var isAuthenticationEndpoint: Bool {
        switch self {
        case .login, .beginOpenID, .completeOpenID, .refresh, .logout,
            .authorize:
            true
        default:
            false
        }
    }
}
