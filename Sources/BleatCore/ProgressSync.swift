import Foundation

public struct BookProgressUpdate: Encodable, Equatable, Sendable {
    public let duration: Double?
    public let currentTime: Double?
    public let progress: Double?
    public let isFinished: Bool?
    public let hideFromContinueListening: Bool?

    public init(
        duration: Double? = nil,
        currentTime: Double? = nil,
        progress: Double? = nil,
        isFinished: Bool? = nil,
        hideFromContinueListening: Bool? = nil
    ) {
        self.duration = duration
        self.currentTime = currentTime
        self.progress = progress
        self.isFinished = isFinished
        self.hideFromContinueListening = hideFromContinueListening
    }
}

public enum BookProgressError: Error, Equatable, Sendable {
    case invalidItemID
    case emptyUpdate
    case invalidDuration
    case invalidCurrentTime
    case invalidProgress
    case requestConstructionFailed(RouteConstructionError)
    case requestEncodingFailed
    case authenticationFailed(AuthenticatedRequestError)
    case requestFailed
    case unexpectedStatus(Int)
    case malformedResponse
}

extension AuthCoordinator {
    /// Implements the pinned v2.36.0 current-user progress contract.
    ///
    /// Contract source: `docs/audiobookshelf-ios-app-spec.md`, sections 11 and 24.
    public func bookProgress(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID
    ) async throws(BookProgressError) -> LibraryBookProgress? {
        let response = try await sendProgressRequest(
            accountID: accountID,
            server: server,
            itemID: itemID,
            method: "GET",
            body: nil
        )
        if response.statusCode == 404 {
            return nil
        }
        guard response.statusCode == 200 else {
            throw .unexpectedStatus(response.statusCode)
        }
        do {
            guard let progress = try JSONDecoder().decode(
                LibraryBookProgressDTO.self,
                from: response.data
            ).domainValue()
            else {
                throw BookProgressError.malformedResponse
            }
            return progress
        } catch let error as BookProgressError {
            throw error
        } catch {
            throw .malformedResponse
        }
    }

    public func updateBookProgress(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID,
        update: BookProgressUpdate
    ) async throws(BookProgressError) {
        try validate(update)
        let body: Data
        do {
            body = try JSONEncoder().encode(update)
        } catch {
            throw .requestEncodingFailed
        }
        let response = try await sendProgressRequest(
            accountID: accountID,
            server: server,
            itemID: itemID,
            method: "PATCH",
            body: body
        )
        guard response.statusCode == 200 else {
            throw .unexpectedStatus(response.statusCode)
        }
    }

    private func sendProgressRequest(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID,
        method: String,
        body: Data?
    ) async throws(BookProgressError) -> HTTPResponse {
        guard !itemID.rawValue.isEmpty else {
            throw .invalidItemID
        }
        let route = AudiobookshelfRoute.progress(itemID)
        let url: URL
        do {
            url = try AudiobookshelfRouteBuilder(server: server).url(
                for: route
            )
        } catch let error {
            throw .requestConstructionFailed(error)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue(
                "application/json",
                forHTTPHeaderField: "Content-Type"
            )
        }
        do {
            return try await sendAuthenticated(
                request,
                route: route,
                accountID: accountID,
                server: server
            )
        } catch let error as AuthenticatedRequestError {
            throw .authenticationFailed(error)
        } catch {
            throw .requestFailed
        }
    }

    private func validate(
        _ update: BookProgressUpdate
    ) throws(BookProgressError) {
        guard update != BookProgressUpdate() else {
            throw .emptyUpdate
        }
        if let duration = update.duration,
            !duration.isFinite || duration <= 0
        {
            throw .invalidDuration
        }
        if let currentTime = update.currentTime,
            !currentTime.isFinite || currentTime < 0
        {
            throw .invalidCurrentTime
        }
        if let progress = update.progress,
            !progress.isFinite || !(0...1).contains(progress)
        {
            throw .invalidProgress
        }
    }
}
