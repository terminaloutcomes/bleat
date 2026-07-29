import Foundation

public enum DownloadAuthorizationError: Error, Equatable, Sendable {
    case invalidAccountID
    case accountOperationInProgress
    case rejectedRequestDoesNotMatchDownload
    case missingRejectedAuthorization
    case malformedRejectedAuthorization
    case routeConstruction(RouteConstructionError)
    case authenticatedRequest(AuthenticatedRequestError)
}

public enum DownloadPlanRequestError: Error, Equatable, Sendable {
    case invalidItemID
    case routeConstruction(RouteConstructionError)
    case authenticatedRequest(AuthenticatedRequestError)
    case unexpectedStatus(Int)
    case invalidPlan(DownloadPlanError)
}

extension AuthCoordinator: DownloadRequestAuthorizing {
    public func downloadPlan(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID
    ) async throws(DownloadPlanRequestError) -> DownloadPlan {
        guard !itemID.rawValue.isEmpty else {
            throw .invalidItemID
        }
        let route = AudiobookshelfRoute.item(itemID)
        let url: URL
        do {
            url = try AudiobookshelfRouteBuilder(server: server).url(
                for: route,
                queryItems: [
                    URLQueryItem(name: "expanded", value: "1"),
                    URLQueryItem(name: "include", value: "progress"),
                ]
            )
        } catch let error {
            throw .routeConstruction(error)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let response: HTTPResponse
        do {
            response = try await sendAuthenticated(
                request,
                route: route,
                accountID: accountID,
                server: server
            )
        } catch let error as AuthenticatedRequestError {
            throw .authenticatedRequest(error)
        } catch {
            throw .authenticatedRequest(.requestTransportFailed)
        }
        guard response.statusCode == 200 else {
            throw .unexpectedStatus(response.statusCode)
        }
        do {
            return try DownloadPlan.decodeExpandedItem(
                from: response.data
            )
        } catch let error {
            throw .invalidPlan(error)
        }
    }

    public func makeAuthorizedDownloadRequest(
        identity: DownloadTaskIdentity,
        server: NormalizedServerURL
    ) async throws -> URLRequest {
        try validateDownloadAccount(identity.accountID)
        let tokens: AuthenticationTokens
        do {
            tokens = try await storedCredentials(for: identity.accountID)
        } catch let error as AuthenticatedRequestError {
            throw DownloadAuthorizationError.authenticatedRequest(error)
        }
        return try authorizeDownloadRequest(
            identity: identity,
            server: server,
            accessToken: tokens.accessToken
        )
    }

    public func makeReplacementDownloadRequest(
        identity: DownloadTaskIdentity,
        server: NormalizedServerURL,
        rejectedRequest: URLRequest
    ) async throws -> URLRequest {
        try validateDownloadAccount(identity.accountID)
        let route = AudiobookshelfRoute.downloadFile(
            itemID: identity.itemID,
            inode: identity.inode
        )
        guard
            requestMatchesDownload(
                rejectedRequest,
                route: route,
                server: server
            )
        else {
            throw DownloadAuthorizationError
                .rejectedRequestDoesNotMatchDownload
        }
        guard
            let authorization = rejectedRequest.value(
                forHTTPHeaderField: "Authorization"
            )
        else {
            throw DownloadAuthorizationError.missingRejectedAuthorization
        }
        let components = authorization.split(
            separator: " ",
            omittingEmptySubsequences: false
        )
        guard components.count == 2,
            components[0].lowercased() == "bearer",
            !components[1].isEmpty
        else {
            throw DownloadAuthorizationError.malformedRejectedAuthorization
        }

        let tokens: AuthenticationTokens
        do {
            tokens = try await credentialsAfterUnauthorizedResponse(
                accountID: identity.accountID,
                server: server,
                rejectedAccessToken: String(components[1])
            )
        } catch let error as AuthenticatedRequestError {
            throw DownloadAuthorizationError.authenticatedRequest(error)
        }
        return try authorizeDownloadRequest(
            identity: identity,
            server: server,
            accessToken: tokens.accessToken
        )
    }

    private func validateDownloadAccount(
        _ accountID: AccountID
    ) throws(DownloadAuthorizationError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !accountsLoggingIn.contains(accountID),
            !accountsSigningOut.contains(accountID)
        else {
            throw .accountOperationInProgress
        }
    }

    private func authorizeDownloadRequest(
        identity: DownloadTaskIdentity,
        server: NormalizedServerURL,
        accessToken: String
    ) throws -> URLRequest {
        let route = AudiobookshelfRoute.downloadFile(
            itemID: identity.itemID,
            inode: identity.inode
        )
        let url: URL
        do {
            url = try AudiobookshelfRouteBuilder(server: server)
                .url(for: route)
        } catch let error {
            throw DownloadAuthorizationError.routeConstruction(error)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        do {
            return try requestAuthorizer.authorize(
                request,
                accessToken: accessToken
            )
        } catch let error {
            throw DownloadAuthorizationError.authenticatedRequest(
                .authorizationFailed(error)
            )
        }
    }

    private func requestMatchesDownload(
        _ request: URLRequest,
        route: AudiobookshelfRoute,
        server: NormalizedServerURL
    ) -> Bool {
        guard let requestURL = request.url,
            requestURL.query == nil,
            let expectedURL = try? AudiobookshelfRouteBuilder(server: server)
                .url(for: route)
        else {
            return false
        }
        return requestURL == expectedURL
    }
}
