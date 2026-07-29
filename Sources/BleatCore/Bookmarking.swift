import Foundation

public struct AudioBookmark: Codable, Equatable, Sendable, Identifiable {
    public var id: String {
        "\(libraryItemID.rawValue):\(time)"
    }

    public let libraryItemID: LibraryItemID
    public let time: Double
    public let title: String
    public let createdAtMilliseconds: Int64

    public init(
        libraryItemID: LibraryItemID,
        time: Double,
        title: String,
        createdAtMilliseconds: Int64
    ) {
        self.libraryItemID = libraryItemID
        self.time = time
        self.title = title
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case libraryItemID = "libraryItemId"
        case time
        case title
        case createdAtMilliseconds = "createdAt"
    }
}

public enum BookmarkMutation: Sendable {
    case create
    case rename
}

public enum BookmarkError: Error, Equatable, Sendable {
    case invalidItemID
    case invalidTime
    case emptyTitle
    case requestConstructionFailed(RouteConstructionError)
    case requestEncodingFailed
    case authenticationFailed(AuthenticatedRequestError)
    case requestFailed
    case unexpectedStatus(Int)
    case malformedResponse
}

extension AuthCoordinator {
    /// Implements the pinned v2.36.0 current-user bookmark contract.
    ///
    /// Contract source: `audiobookshelf-ios-app-spec.md`, sections 15 and 24.
    public func bookmarks(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID
    ) async throws(BookmarkError) -> [AudioBookmark] {
        let response = try await bookmarkRequest(
            accountID: accountID,
            server: server,
            route: .bookmarks(itemID),
            method: "GET"
        )
        guard response.statusCode == 200 else {
            throw .unexpectedStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(
                BookmarkListResponse.self,
                from: response.data
            ).bookmarks.sorted { $0.time < $1.time }
        } catch {
            throw .malformedResponse
        }
    }

    public func mutateBookmark(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID,
        time: Double,
        title: String,
        mutation: BookmarkMutation
    ) async throws(BookmarkError) -> AudioBookmark {
        guard time.isFinite, time >= 0 else {
            throw .invalidTime
        }
        let normalizedTitle = title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedTitle.isEmpty else {
            throw .emptyTitle
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(
                BookmarkMutationBody(
                    time: time,
                    title: normalizedTitle
                )
            )
        } catch {
            throw .requestEncodingFailed
        }
        let response = try await bookmarkRequest(
            accountID: accountID,
            server: server,
            route: .bookmark(itemID),
            method: mutation == .create ? "POST" : "PATCH",
            body: body
        )
        guard response.statusCode == 200 else {
            throw .unexpectedStatus(response.statusCode)
        }
        do {
            return try JSONDecoder().decode(
                AudioBookmark.self,
                from: response.data
            )
        } catch {
            throw .malformedResponse
        }
    }

    public func deleteBookmark(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID,
        time: Double
    ) async throws(BookmarkError) {
        guard time.isFinite, time >= 0 else {
            throw .invalidTime
        }
        let response = try await bookmarkRequest(
            accountID: accountID,
            server: server,
            route: .deleteBookmark(itemID: itemID, time: time),
            method: "DELETE"
        )
        guard response.statusCode == 200 else {
            throw .unexpectedStatus(response.statusCode)
        }
    }

    private func bookmarkRequest(
        accountID: AccountID,
        server: NormalizedServerURL,
        route: AudiobookshelfRoute,
        method: String,
        body: Data? = nil
    ) async throws(BookmarkError) -> HTTPResponse {
        let hasValidItemID: Bool =
            switch route {
            case .bookmarks(let itemID), .bookmark(let itemID):
                !itemID.rawValue.isEmpty
            case .deleteBookmark(let itemID, _):
                !itemID.rawValue.isEmpty
            default:
                false
            }
        guard hasValidItemID else {
            throw .invalidItemID
        }

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
}

private struct BookmarkListResponse: Decodable {
    let bookmarks: [AudioBookmark]
}

private struct BookmarkMutationBody: Encodable {
    let time: Double
    let title: String
}
