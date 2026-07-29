import Foundation

public struct APICorrelationID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AudiobookshelfAPIResult<Value: Sendable>: Sendable {
    public let value: Value
    public let correlationID: APICorrelationID

    public init(
        value: Value,
        correlationID: APICorrelationID
    ) {
        self.value = value
        self.correlationID = correlationID
    }
}

public enum AudiobookshelfAPIError: Error, Equatable, Sendable {
    case invalidAccountID
    case routeConstruction(RouteConstructionError)
    case authentication(AuthenticatedRequestError)
    case cancelled
    case unexpectedStatus(Int)
    case malformedResponse
    case invalidLibrary
    case invalidPage
    case invalidLibraryItem
    case invalidSearchResults
}

public actor AudiobookshelfAPI<
    Transport: HTTPTransport,
    CredentialStore: AccountCredentialStore
> {
    private let accountID: AccountID
    private let server: NormalizedServerURL
    private let authCoordinator: AuthCoordinator<Transport, CredentialStore>
    private let decoder: JSONDecoder

    public init(
        account: ServerAccount,
        authCoordinator: AuthCoordinator<Transport, CredentialStore>
    ) {
        accountID = account.id
        server = account.server
        self.authCoordinator = authCoordinator
        decoder = JSONDecoder()
    }

    public func libraries() async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibrarySummary]>
    {
        let result: AudiobookshelfAPIResult<LibrariesResponseDTO> =
            try await get(.libraries, as: LibrariesResponseDTO.self)
        let libraries: [LibrarySummary]
        do {
            libraries = try result.value.libraries.map { library in
                guard !library.id.rawValue.isEmpty,
                      !library.name.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                else {
                    throw AudiobookshelfAPIError.invalidLibrary
                }
                return LibrarySummary(
                    id: library.id,
                    name: library.name,
                    mediaType: library.mediaType.domainValue
                )
            }
        } catch let error as AudiobookshelfAPIError {
            throw error
        } catch {
            throw .invalidLibrary
        }
        return AudiobookshelfAPIResult(
            value: libraries,
            correlationID: result.correlationID
        )
    }

    public func libraryItems(
        in libraryID: LibraryID,
        request: LibraryItemsPageRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<LibraryItemsPage>
    {
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibrary
        }
        let result: AudiobookshelfAPIResult<LibraryItemsPageDTO> =
            try await get(
                .libraryItems(libraryID),
                queryItems: request.queryItems,
                as: LibraryItemsPageDTO.self
            )
        guard result.value.total >= 0,
              result.value.page == request.page,
              result.value.limit == request.limit,
              result.value.results.count <= request.limit
        else {
            throw .invalidPage
        }
        var items: [LibraryBookSummary] = []
        items.reserveCapacity(result.value.results.count)
        for item in result.value.results {
            items.append(
                try item.domainValue(expectedLibraryID: libraryID)
            )
        }
        return AudiobookshelfAPIResult(
            value: LibraryItemsPage(
                items: items,
                total: result.value.total,
                page: result.value.page,
                limit: result.value.limit
            ),
            correlationID: result.correlationID
        )
    }

    public func search(
        in libraryID: LibraryID,
        request: LibrarySearchRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibraryBookSummary]>
    {
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibrary
        }
        let result: AudiobookshelfAPIResult<LibrarySearchResponseDTO> =
            try await get(
                .search(libraryID),
                queryItems: request.queryItems,
                as: LibrarySearchResponseDTO.self
            )
        guard result.value.book.count <= request.limit else {
            throw .invalidSearchResults
        }
        var items: [LibraryBookSummary] = []
        items.reserveCapacity(result.value.book.count)
        for match in result.value.book {
            items.append(
                try match.libraryItem.domainValue(
                    expectedLibraryID: libraryID
                )
            )
        }
        return AudiobookshelfAPIResult(
            value: items,
            correlationID: result.correlationID
        )
    }

    private func get<Response: Decodable & Sendable>(
        _ route: AudiobookshelfRoute,
        queryItems: [URLQueryItem] = [],
        as responseType: Response.Type
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<Response>
    {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        let url: URL
        do {
            url = try AudiobookshelfRouteBuilder(server: server).url(
                for: route,
                queryItems: queryItems
            )
        } catch let error {
            throw .routeConstruction(error)
        }

        let correlationID = APICorrelationID()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            correlationID.rawValue.uuidString.lowercased(),
            forHTTPHeaderField: "X-Bleat-Request-ID"
        )

        let response: HTTPResponse
        do {
            response = try await authCoordinator.sendAuthenticated(
                request,
                route: route,
                accountID: accountID,
                server: server
            )
        } catch let error as AuthenticatedRequestError {
            if error == .requestCancelled {
                throw .cancelled
            }
            throw .authentication(error)
        } catch {
            if Task.isCancelled {
                throw .cancelled
            }
            throw .authentication(.requestTransportFailed)
        }
        guard !Task.isCancelled else {
            throw .cancelled
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw .unexpectedStatus(response.statusCode)
        }

        let value: Response
        do {
            value = try decoder.decode(responseType, from: response.data)
        } catch {
            throw .malformedResponse
        }
        return AudiobookshelfAPIResult(
            value: value,
            correlationID: correlationID
        )
    }
}

private struct LibrariesResponseDTO: Decodable, Sendable {
    let libraries: [LibraryDTO]
}

private struct LibraryDTO: Decodable, Sendable {
    let id: LibraryID
    let name: String
    let mediaType: LibraryMediaTypeDTO
}

private enum LibraryMediaTypeDTO: Decodable, Sendable {
    case book
    case podcast
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "book":
            self = .book
        case "podcast":
            self = .podcast
        default:
            self = .unknown(value)
        }
    }

    var domainValue: LibraryMediaType {
        switch self {
        case .book:
            .book
        case .podcast:
            .podcast
        case let .unknown(value):
            .unknown(value)
        }
    }
}

private struct LibraryItemsPageDTO: Decodable, Sendable {
    let results: [LibraryItemDTO]
    let total: Int
    let limit: Int
    let page: Int
}

private struct LibrarySearchResponseDTO: Decodable, Sendable {
    let book: [LibrarySearchBookMatchDTO]
}

private struct LibrarySearchBookMatchDTO: Decodable, Sendable {
    let libraryItem: LibraryItemDTO
}

private struct LibraryItemDTO: Decodable, Sendable {
    let id: LibraryItemID
    let libraryID: LibraryID
    let addedAt: Int64
    let updatedAt: Int64
    let mediaType: String
    let media: LibraryBookDTO

    enum CodingKeys: String, CodingKey {
        case id
        case libraryID = "libraryId"
        case addedAt
        case updatedAt
        case mediaType
        case media
    }

    func domainValue(
        expectedLibraryID: LibraryID
    ) throws(AudiobookshelfAPIError) -> LibraryBookSummary {
        guard !id.rawValue.isEmpty,
              libraryID == expectedLibraryID,
              mediaType == "book",
              Self.isValidDisplayString(media.metadata.title),
              Self.isValidOptionalDisplayString(media.metadata.subtitle),
              Self.isValidOptionalDisplayString(media.metadata.authorName),
              Self.isValidOptionalDisplayString(media.metadata.narratorName),
              Self.isValidOptionalDisplayString(media.metadata.seriesName),
              Self.isValidOptionalDisplayString(media.metadata.publisher),
              Self.isValidOptionalDisplayString(
                  media.metadata.publishedYear
              ),
              media.metadata.genres.allSatisfy(Self.isValidDisplayString),
              media.duration.isFinite,
              media.duration >= 0,
              media.numTracks >= 0,
              media.numChapters >= 0,
              addedAt >= 0,
              updatedAt >= 0
        else {
            throw .invalidLibraryItem
        }
        return LibraryBookSummary(
            id: id,
            libraryID: libraryID,
            title: media.metadata.title,
            subtitle: Self.nonEmpty(media.metadata.subtitle),
            authorName: Self.nonEmpty(media.metadata.authorName),
            narratorName: Self.nonEmpty(media.metadata.narratorName),
            seriesName: Self.nonEmpty(media.metadata.seriesName),
            genres: media.metadata.genres,
            publisher: Self.nonEmpty(media.metadata.publisher),
            publishedYear: Self.nonEmpty(media.metadata.publishedYear),
            duration: media.duration,
            trackCount: media.numTracks,
            chapterCount: media.numChapters,
            addedAtMilliseconds: addedAt,
            updatedAtMilliseconds: updatedAt,
            isExplicit: media.metadata.explicit,
            isAbridged: media.metadata.abridged
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value,
              !value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty
        else {
            return nil
        }
        return value
    }

    private static func isValidDisplayString(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func isValidOptionalDisplayString(
        _ value: String?
    ) -> Bool {
        guard let value else {
            return true
        }
        return value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

private struct LibraryBookDTO: Decodable, Sendable {
    let metadata: LibraryBookMetadataDTO
    let numTracks: Int
    let numChapters: Int
    let duration: Double
}

private struct LibraryBookMetadataDTO: Decodable, Sendable {
    let title: String
    let subtitle: String?
    let authorName: String?
    let narratorName: String?
    let seriesName: String?
    let genres: [String]
    let publishedYear: String?
    let publisher: String?
    let explicit: Bool
    let abridged: Bool
}
