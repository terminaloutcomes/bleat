import Foundation

public enum BearerAuthorizationError: Error, Equatable, Sendable {
    case missingURL
    case insecureURL
    case embeddedCredentials
    case tokenBearingURL
    case invalidAccessToken
}

public struct BearerRequestAuthorizer: Sendable {
    public init() {}

    public func authorize(
        _ request: URLRequest,
        accessToken: String
    ) throws(BearerAuthorizationError) -> URLRequest {
        guard let url = request.url,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              )
        else {
            throw .missingURL
        }
        guard components.scheme?.lowercased() == "https" else {
            throw .insecureURL
        }
        guard components.user == nil, components.password == nil else {
            throw .embeddedCredentials
        }
        guard components.queryItems?.contains(where: {
            let name = $0.name.lowercased()
            return name == "token" || name == "access_token"
        }) != true else {
            throw .tokenBearingURL
        }
        guard !accessToken.isEmpty,
              accessToken.rangeOfCharacter(
                  from: .whitespacesAndNewlines.union(.controlCharacters)
              ) == nil
        else {
            throw .invalidAccessToken
        }

        var authorizedRequest = request
        authorizedRequest.setValue(
            "Bearer \(accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        return authorizedRequest
    }
}

public enum LocalAuthenticationError: Error, Equatable, Sendable {
    case invalidAccountID
    case accountOperationInProgress
    case invalidCredentials
    case unexpectedLoginStatus(Int)
    case malformedLoginResponse
    case missingAccessToken
    case missingRefreshToken
    case tokenValidationFailed
    case unexpectedAuthorizationStatus(Int)
    case malformedAuthorizationResponse
    case authorizedUserMismatch(expected: String, actual: String)
    case credentialPersistenceFailed
}

public actor AuthCoordinator<
    Transport: HTTPTransport,
    CredentialStore: AccountCredentialStore
> {
    let transport: Transport
    let credentialStore: CredentialStore
    private let encoder: JSONEncoder
    let decoder: JSONDecoder
    let requestAuthorizer: BearerRequestAuthorizer
    var openIDAttempt: OpenIDAttempt?
    var refreshAttempts: [AccountID: RefreshAttempt]
    var completedRefreshes: [AccountID: CompletedRefresh]
    var nextRefreshAttemptID: UInt64
    var reauthenticationRequiredAccounts: Set<AccountID>
    var accountsLoggingIn: Set<AccountID>
    var accountsSigningOut: Set<AccountID>
    var accountOperationGenerations: [AccountID: UInt64]

    public init(
        transport: Transport,
        credentialStore: CredentialStore
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        encoder = JSONEncoder()
        decoder = JSONDecoder()
        requestAuthorizer = BearerRequestAuthorizer()
        openIDAttempt = nil
        refreshAttempts = [:]
        completedRefreshes = [:]
        nextRefreshAttemptID = 0
        reauthenticationRequiredAccounts = []
        accountsLoggingIn = []
        accountsSigningOut = []
        accountOperationGenerations = [:]
    }

    public func login(
        accountID: AccountID,
        server: NormalizedServerURL,
        username: String,
        password: String
    ) async throws -> AuthenticatedAccount {
        guard !accountID.rawValue.isEmpty else {
            throw LocalAuthenticationError.invalidAccountID
        }
        guard !accountsLoggingIn.contains(accountID),
              !accountsSigningOut.contains(accountID)
        else {
            throw LocalAuthenticationError.accountOperationInProgress
        }
        accountOperationGenerations[accountID, default: 0] &+= 1
        accountsLoggingIn.insert(accountID)
        defer {
            accountsLoggingIn.remove(accountID)
        }

        let routeBuilder = AudiobookshelfRouteBuilder(server: server)
        let loginURL = try routeBuilder.url(for: .login)
        var loginRequest = URLRequest(url: loginURL)
        loginRequest.httpMethod = "POST"
        loginRequest.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        loginRequest.setValue("true", forHTTPHeaderField: "x-return-tokens")
        loginRequest.httpBody = try encoder.encode(
            LoginRequest(username: username, password: password)
        )

        let loginResponse = try await transport.send(loginRequest)
        loginRequest.httpBody = nil
        switch loginResponse.statusCode {
        case 200:
            break
        case 401:
            throw LocalAuthenticationError.invalidCredentials
        default:
            throw LocalAuthenticationError.unexpectedLoginStatus(
                loginResponse.statusCode
            )
        }

        let loginPayload: AuthenticationResponse
        do {
            loginPayload = try decoder.decode(
                AuthenticationResponse.self,
                from: loginResponse.data
            )
        } catch {
            throw LocalAuthenticationError.malformedLoginResponse
        }

        guard let accessToken = loginPayload.user.accessToken,
              !accessToken.isEmpty
        else {
            throw LocalAuthenticationError.missingAccessToken
        }
        guard let refreshToken = loginPayload.user.refreshToken,
              !refreshToken.isEmpty
        else {
            throw LocalAuthenticationError.missingRefreshToken
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
                throw LocalAuthenticationError.missingAccessToken
            case .invalidRefreshToken:
                throw LocalAuthenticationError.missingRefreshToken
            }
        }

        let authorizeURL = try routeBuilder.url(for: .authorize)
        var authorizeRequest = URLRequest(url: authorizeURL)
        authorizeRequest.httpMethod = "POST"
        authorizeRequest = try requestAuthorizer.authorize(
            authorizeRequest,
            accessToken: tokens.accessToken
        )

        let authorizeResponse = try await transport.send(authorizeRequest)
        switch authorizeResponse.statusCode {
        case 200:
            break
        case 401:
            throw LocalAuthenticationError.tokenValidationFailed
        default:
            throw LocalAuthenticationError.unexpectedAuthorizationStatus(
                authorizeResponse.statusCode
            )
        }

        let authorizationPayload: AuthenticationResponse
        do {
            authorizationPayload = try decoder.decode(
                AuthenticationResponse.self,
                from: authorizeResponse.data
            )
        } catch {
            throw LocalAuthenticationError.malformedAuthorizationResponse
        }

        guard authorizationPayload.user.id == loginPayload.user.id else {
            throw LocalAuthenticationError.authorizedUserMismatch(
                expected: loginPayload.user.id.rawValue,
                actual: authorizationPayload.user.id.rawValue
            )
        }

        do {
            try await credentialStore.save(tokens, for: accountID)
        } catch {
            throw LocalAuthenticationError.credentialPersistenceFailed
        }
        completedRefreshes[accountID] = nil
        reauthenticationRequiredAccounts.remove(accountID)

        return AuthenticatedAccount(
            id: accountID,
            server: server,
            user: authorizationPayload.user.authenticatedUser
        )
    }
}

private struct LoginRequest: Encodable {
    let username: String
    let password: String
}

struct AuthenticationResponse: Decodable {
    let user: AuthenticationUserPayload
}

struct AuthenticationUserPayload: Decodable {
    let id: UserID
    let username: String
    let type: AudiobookshelfUserType
    let permissions: UserPermissions
    let accessibleLibraryIDs: [LibraryID]
    let selectedItemTags: [String]
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case type
        case permissions
        case accessibleLibraryIDs = "librariesAccessible"
        case selectedItemTags = "itemTagsSelected"
        case accessToken
        case refreshToken
    }

    var authenticatedUser: AuthenticatedUser {
        AuthenticatedUser(
            id: id,
            username: username,
            type: type,
            permissions: permissions,
            accessibleLibraryIDs: accessibleLibraryIDs,
            selectedItemTags: selectedItemTags
        )
    }
}
