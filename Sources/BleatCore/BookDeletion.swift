import Foundation

public enum BookDeletionMode: Equatable, Sendable {
    case libraryRecordOnly
    case libraryRecordAndFiles
}

public enum BookDeletionError: Error, Equatable, Sendable {
    case invalidItemID
    case requestConstructionFailed(RouteConstructionError)
    case authenticationFailed(AuthenticatedRequestError)
    case requestFailed
    case permissionDenied
    case itemNotFound
    case unexpectedStatus(Int)
}

extension AuthCoordinator {
    /// Deletes a library item using the pinned Audiobookshelf item route.
    ///
    /// Contract source:
    /// https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/controllers/LibraryItemController.js
    public func deleteBook(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID,
        mode: BookDeletionMode
    ) async throws(BookDeletionError) {
        guard !itemID.rawValue.isEmpty else {
            throw .invalidItemID
        }

        let route = AudiobookshelfRoute.item(itemID)
        let queryItems =
            mode == .libraryRecordAndFiles
            ? [URLQueryItem(name: "hard", value: "1")]
            : []
        let url: URL
        do {
            url = try AudiobookshelfRouteBuilder(server: server).url(
                for: route,
                queryItems: queryItems
            )
        } catch let error {
            throw .requestConstructionFailed(error)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"

        let response: HTTPResponse
        do {
            response = try await sendAuthenticated(
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

        switch response.statusCode {
        case 200:
            return
        case 403:
            throw .permissionDenied
        case 404:
            throw .itemNotFound
        default:
            throw .unexpectedStatus(response.statusCode)
        }
    }
}
