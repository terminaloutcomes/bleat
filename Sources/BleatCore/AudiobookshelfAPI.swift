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
    case invalidBookDetail
    case invalidSearchResults
    case invalidPersonalizedShelves
}

public actor AudiobookshelfAPI<
    Transport: HTTPTransport,
    CredentialStore: AccountCredentialStore
> {
    private let accountID: AccountID
    private let userID: UserID
    private let server: NormalizedServerURL
    private let authCoordinator: AuthCoordinator<Transport, CredentialStore>
    private let decoder: JSONDecoder

    public init(
        account: ServerAccount,
        authCoordinator: AuthCoordinator<Transport, CredentialStore>
    ) {
        accountID = account.id
        userID = account.user.id
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
        -> AudiobookshelfAPIResult<LibrarySearchResults>
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
        guard result.value.book.count <= request.limit,
              result.value.authors.count <= request.limit,
              result.value.series.count <= request.limit
        else {
            throw .invalidSearchResults
        }
        var books: [LibraryBookSummary] = []
        books.reserveCapacity(result.value.book.count)
        for match in result.value.book {
            books.append(
                try match.libraryItem.domainValue(
                    expectedLibraryID: libraryID
                )
            )
        }
        var authors: [LibrarySearchAuthorMatch] = []
        authors.reserveCapacity(result.value.authors.count)
        for author in result.value.authors {
            authors.append(try author.domainValue())
        }
        var series: [LibrarySearchSeriesMatch] = []
        series.reserveCapacity(result.value.series.count)
        for value in result.value.series {
            series.append(try value.domainValue())
        }
        return AudiobookshelfAPIResult(
            value: LibrarySearchResults(
                books: books,
                authors: authors,
                series: series
            ),
            correlationID: result.correlationID
        )
    }

    public func personalizedShelves(
        in libraryID: LibraryID,
        request: LibraryHomeRequest
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibraryBookShelf]>
    {
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibrary
        }
        let result: AudiobookshelfAPIResult<[PersonalizedShelfDTO]> =
            try await get(
                .personalized(libraryID),
                queryItems: request.queryItems,
                as: [PersonalizedShelfDTO].self
            )
        var seenShelfIDs: Set<String> = []
        var shelves: [LibraryBookShelf] = []
        for shelf in result.value {
            guard let entities = shelf.bookEntities else {
                continue
            }
            guard entities.count <= request.limit,
                  shelf.total >= entities.count,
                  !shelf.id.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  shelf.id.rangeOfCharacter(
                      from: .controlCharacters
                  ) == nil,
                  !shelf.label.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty,
                  shelf.label.rangeOfCharacter(
                      from: .controlCharacters
                  ) == nil,
                  shelf.labelLocalizationKey?.rangeOfCharacter(
                      from: .controlCharacters
                  ) == nil
            else {
                throw .invalidPersonalizedShelves
            }
            var items: [LibraryBookSummary] = []
            items.reserveCapacity(entities.count)
            for entity in entities {
                let item = try entity.domainValue(
                    expectedLibraryID: libraryID
                )
                if item.trackCount > 0 {
                    items.append(item)
                }
            }
            guard !items.isEmpty else {
                continue
            }
            guard seenShelfIDs.insert(shelf.id).inserted else {
                throw .invalidPersonalizedShelves
            }
            if shelf.kind == .continueListening {
                // The pinned query sorts only by progress update time, so equal
                // timestamps need a client-side opaque-ID tie-breaker.
                // https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/utils/queries/libraryItemsBookFilters.js#L240-L291
                let progressUpdates = try await progressUpdates(
                    for: items.map(\.id)
                )
                items.sort { left, right in
                    let leftUpdate = progressUpdates[left.id] ?? -1
                    let rightUpdate = progressUpdates[right.id] ?? -1
                    if leftUpdate != rightUpdate {
                        return leftUpdate > rightUpdate
                    }
                    return left.id.rawValue < right.id.rawValue
                }
            }
            shelves.append(LibraryBookShelf(
                id: shelf.id,
                label: shelf.label,
                labelLocalizationKey: shelf.labelLocalizationKey,
                items: items,
                total: shelf.total
            ))
        }
        return AudiobookshelfAPIResult(
            value: shelves,
            correlationID: result.correlationID
        )
    }

    private func progressUpdates(
        for itemIDs: [LibraryItemID]
    ) async throws(AudiobookshelfAPIError) -> [LibraryItemID: Int64] {
        let results = await withTaskGroup(
            of: Result<(LibraryItemID, Int64), AudiobookshelfAPIError>.self
        ) { group in
            for itemID in itemIDs {
                group.addTask {
                    do throws(AudiobookshelfAPIError) {
                        return .success(
                            try await self.progressUpdate(for: itemID)
                        )
                    } catch {
                        return .failure(error)
                    }
                }
            }

            var results: [
                Result<(LibraryItemID, Int64), AudiobookshelfAPIError>
            ] = []
            results.reserveCapacity(itemIDs.count)
            for await result in group {
                if case .failure = result {
                    group.cancelAll()
                }
                results.append(result)
            }
            return results
        }

        var updates: [LibraryItemID: Int64] = [:]
        updates.reserveCapacity(itemIDs.count)
        for result in results {
            let (itemID, lastUpdate) = try result.get()
            guard updates.updateValue(
                lastUpdate,
                forKey: itemID
            ) == nil else {
                throw AudiobookshelfAPIError.invalidPersonalizedShelves
            }
        }
        return updates
    }

    private func progressUpdate(
        for itemID: LibraryItemID
    ) async throws(AudiobookshelfAPIError) -> (LibraryItemID, Int64) {
        guard !Task.isCancelled else {
            throw .cancelled
        }
        let result: AudiobookshelfAPIResult<LibraryBookProgressDTO> =
            try await get(
                .progress(itemID),
                as: LibraryBookProgressDTO.self
            )
        guard let progress = result.value.domainValue(),
              progress.userID == userID,
              progress.libraryItemID == itemID,
              !progress.isFinished,
              !progress.hideFromContinueListening
        else {
            throw .invalidPersonalizedShelves
        }
        return (itemID, progress.lastUpdateMilliseconds)
    }

    public func bookDetail(
        for itemID: LibraryItemID,
        in libraryID: LibraryID
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<LibraryBookDetail>
    {
        guard !itemID.rawValue.isEmpty else {
            throw .invalidLibraryItem
        }
        guard !libraryID.rawValue.isEmpty else {
            throw .invalidLibrary
        }
        let result: AudiobookshelfAPIResult<LibraryBookDetailDTO> =
            try await get(
                .item(itemID),
                queryItems: [
                    URLQueryItem(name: "expanded", value: "1"),
                    URLQueryItem(name: "include", value: "progress"),
                ],
                as: LibraryBookDetailDTO.self
            )
        let detail = try result.value.domainValue(
            expectedItemID: itemID,
            expectedLibraryID: libraryID,
            expectedUserID: userID
        )
        return AudiobookshelfAPIResult(
            value: detail,
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
    let authors: [LibrarySearchAuthorMatchDTO]
    let series: [LibrarySearchSeriesMatchDTO]

    enum CodingKeys: String, CodingKey {
        case book
        case authors
        case series
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        book = try values.decode(
            [LibrarySearchBookMatchDTO].self,
            forKey: .book
        )
        authors = try values.decodeIfPresent(
            [LibrarySearchAuthorMatchDTO].self,
            forKey: .authors
        ) ?? []
        series = try values.decodeIfPresent(
            [LibrarySearchSeriesMatchDTO].self,
            forKey: .series
        ) ?? []
    }
}

private struct LibrarySearchBookMatchDTO: Decodable, Sendable {
    let libraryItem: LibraryItemDTO
}

private struct LibrarySearchAuthorMatchDTO: Decodable, Sendable {
    let id: AuthorID
    let name: String

    func domainValue() throws(AudiobookshelfAPIError) -> LibrarySearchAuthorMatch {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw .invalidSearchResults
        }
        return LibrarySearchAuthorMatch(id: id, name: name)
    }
}

private struct LibrarySearchSeriesMatchDTO: Decodable, Sendable {
    let id: SeriesID
    let name: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case series
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let nestedSeries = try values.decodeIfPresent(
            LibrarySearchSeriesIdentityDTO.self,
            forKey: .series
        ) {
            id = nestedSeries.id
            name = nestedSeries.name
        } else {
            id = try values.decode(SeriesID.self, forKey: .id)
            name = try values.decode(String.self, forKey: .name)
        }
    }

    func domainValue() throws(AudiobookshelfAPIError) -> LibrarySearchSeriesMatch {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw .invalidSearchResults
        }
        return LibrarySearchSeriesMatch(id: id, name: name)
    }
}

private struct LibrarySearchSeriesIdentityDTO: Decodable, Sendable {
    let id: SeriesID
    let name: String
}

private enum PersonalizedShelfKind: Equatable, Sendable {
    case continueListening
    case other
}

/// Pinned contract:
/// https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/utils/queries/libraryFilters.js#L38-L71
private struct PersonalizedShelfDTO: Decodable, Sendable {
    let id: String
    let label: String
    let labelLocalizationKey: String?
    let total: Int
    let bookEntities: [LibraryItemDTO]?

    var kind: PersonalizedShelfKind {
        switch id {
        case "continue-listening":
            .continueListening
        default:
            .other
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case labelLocalizationKey = "labelStringKey"
        case type
        case entities
        case total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(
            keyedBy: CodingKeys.self
        )
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        labelLocalizationKey = try container.decodeIfPresent(
            String.self,
            forKey: .labelLocalizationKey
        )
        total = try container.decode(Int.self, forKey: .total)
        let type = try container.decode(String.self, forKey: .type)
        if type == "book" {
            bookEntities = try container.decode(
                [LibraryItemDTO].self,
                forKey: .entities
            )
        } else {
            bookEntities = nil
        }
    }
}

private struct LibraryItemDTO: Decodable, Sendable {
    let id: LibraryItemID
    let libraryID: LibraryID
    let addedAt: Int64
    let updatedAt: Int64
    let mediaType: String
    let media: LibraryBookDTO
    let collapsedSeries: LibraryCollapsedSeriesDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case libraryID = "libraryId"
        case addedAt
        case updatedAt
        case mediaType
        case media
        case collapsedSeries
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
              (media.metadata.authors ?? []).allSatisfy({
                  Self.isValidDisplayString($0.name)
              }),
              (media.metadata.series ?? []).allSatisfy({
                  Self.isValidDisplayString($0.name)
                      && Self.isValidOptionalDisplayString($0.sequence)
              }),
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
            authors: media.metadata.authors ?? [],
            series: media.metadata.series ?? [],
            collapsedSeries: try collapsedSeries?.domainValue(),
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
    let authors: [LibraryBookContributor]?
    let series: [LibraryBookSeries]?
    let genres: [String]
    let publishedYear: String?
    let publisher: String?
    let explicit: Bool
    let abridged: Bool

    enum CodingKeys: String, CodingKey {
        case title
        case subtitle
        case authorName
        case narratorName
        case seriesName
        case authors
        case series
        case genres
        case publishedYear
        case publisher
        case explicit
        case abridged
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        subtitle = try values.decodeIfPresent(String.self, forKey: .subtitle)
        authorName = try values.decodeIfPresent(
            String.self,
            forKey: .authorName
        )
        narratorName = try values.decodeIfPresent(
            String.self,
            forKey: .narratorName
        )
        seriesName = try values.decodeIfPresent(
            String.self,
            forKey: .seriesName
        )
        authors = try values.decodeIfPresent(
            [LibraryBookContributor].self,
            forKey: .authors
        )
        if values.contains(.series),
           try !values.decodeNil(forKey: .series)
        {
            if let seriesList = try? values.decode(
                [LibraryBookSeries].self,
                forKey: .series
            ) {
                series = seriesList
            } else {
                series = [
                    try values.decode(
                        LibraryBookSeries.self,
                        forKey: .series
                    ),
                ]
            }
        } else {
            series = nil
        }
        genres = try values.decode([String].self, forKey: .genres)
        publishedYear = try values.decodeIfPresent(
            String.self,
            forKey: .publishedYear
        )
        publisher = try values.decodeIfPresent(
            String.self,
            forKey: .publisher
        )
        explicit = try values.decode(Bool.self, forKey: .explicit)
        abridged = try values.decode(Bool.self, forKey: .abridged)
    }
}

private struct LibraryCollapsedSeriesDTO: Decodable, Sendable {
    let id: SeriesID
    let name: String
    let libraryItemIDs: [LibraryItemID]
    let numBooks: Int
    let sequenceList: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case libraryItemIDs = "libraryItemIds"
        case numBooks
        case sequenceList = "seriesSequenceList"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(SeriesID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        libraryItemIDs = try values.decodeIfPresent(
            [LibraryItemID].self,
            forKey: .libraryItemIDs
        ) ?? []
        numBooks = try values.decode(Int.self, forKey: .numBooks)
        if let values = try? values.decode(
            [String].self,
            forKey: .sequenceList
        ) {
            sequenceList = values
        } else if let value = try values.decodeIfPresent(
            String.self,
            forKey: .sequenceList
        ) {
            sequenceList = [value]
        } else {
            sequenceList = nil
        }
    }

    func domainValue() throws(AudiobookshelfAPIError) -> LibraryCollapsedSeries {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.rangeOfCharacter(from: .controlCharacters) == nil,
              numBooks >= 1,
              libraryItemIDs.count <= numBooks,
              libraryItemIDs.allSatisfy({ !$0.rawValue.isEmpty }),
              sequenceList?.allSatisfy({
                  $0.rangeOfCharacter(from: .controlCharacters) == nil
              }) ?? true
        else {
            throw .invalidLibraryItem
        }
        return LibraryCollapsedSeries(
            id: id,
            name: name,
            libraryItemIDs: libraryItemIDs,
            numBooks: numBooks,
            sequenceList: sequenceList
        )
    }
}

private struct LibraryBookDetailDTO: Decodable, Sendable {
    let id: LibraryItemID
    let libraryID: LibraryID
    let addedAt: Int64
    let updatedAt: Int64
    let mediaType: String
    let media: ExpandedLibraryBookDTO
    let userMediaProgress: LibraryBookProgressDTO?

    enum CodingKeys: String, CodingKey {
        case id
        case libraryID = "libraryId"
        case addedAt
        case updatedAt
        case mediaType
        case media
        case userMediaProgress
    }

    func domainValue(
        expectedItemID: LibraryItemID,
        expectedLibraryID: LibraryID,
        expectedUserID: UserID
    ) throws(AudiobookshelfAPIError) -> LibraryBookDetail {
        guard id == expectedItemID,
              libraryID == expectedLibraryID,
              mediaType == "book",
              media.libraryItemID == expectedItemID,
              !media.id.rawValue.isEmpty,
              media.numChapters == media.chapters.count
        else {
            throw .invalidBookDetail
        }
        let progress: LibraryBookProgress?
        if let userMediaProgress {
            progress = try userMediaProgress.domainValue(
                expectedItemID: expectedItemID,
                expectedBookID: media.id,
                expectedUserID: expectedUserID
            )
        } else {
            progress = nil
        }
        let detail = LibraryBookDetail(
            id: id,
            libraryID: libraryID,
            bookID: media.id,
            title: media.metadata.title,
            subtitle: Self.nonEmpty(media.metadata.subtitle),
            authors: media.metadata.authors,
            narrators: media.metadata.narrators,
            series: media.metadata.series.map {
                LibraryBookSeries(
                    id: $0.id,
                    name: $0.name,
                    sequence: Self.nonEmpty($0.sequence)
                )
            },
            genres: media.metadata.genres,
            tags: media.tags,
            publishedYear: Self.nonEmpty(media.metadata.publishedYear),
            publishedDate: Self.nonEmpty(media.metadata.publishedDate),
            publisher: Self.nonEmpty(media.metadata.publisher),
            descriptionPlain: Self.nonEmpty(
                media.metadata.descriptionPlain
            ),
            isbn: Self.nonEmpty(media.metadata.isbn),
            asin: Self.nonEmpty(media.metadata.asin),
            language: Self.nonEmpty(media.metadata.language),
            duration: media.duration,
            trackCount: media.numTracks,
            audioFileCount: media.numAudioFiles,
            chapters: media.chapters,
            addedAtMilliseconds: addedAt,
            updatedAtMilliseconds: updatedAt,
            isExplicit: media.metadata.explicit,
            isAbridged: media.metadata.abridged,
            progress: progress
        )
        guard detail.isValidForStorage(
            in: expectedLibraryID,
            for: expectedUserID
        ) else {
            throw .invalidBookDetail
        }
        return detail
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
}

private struct ExpandedLibraryBookDTO: Decodable, Sendable {
    let id: BookID
    let libraryItemID: LibraryItemID
    let metadata: ExpandedLibraryBookMetadataDTO
    let tags: [String]
    let numTracks: Int
    let numAudioFiles: Int
    let numChapters: Int
    let duration: Double
    let chapters: [PlaybackChapter]

    enum CodingKeys: String, CodingKey {
        case id
        case libraryItemID = "libraryItemId"
        case metadata
        case tags
        case numTracks
        case numAudioFiles
        case numChapters
        case duration
        case chapters
    }
}

private struct ExpandedLibraryBookMetadataDTO: Decodable, Sendable {
    let title: String
    let subtitle: String?
    let authors: [LibraryBookContributor]
    let narrators: [String]
    let series: [ExpandedLibraryBookSeriesDTO]
    let genres: [String]
    let publishedYear: String?
    let publishedDate: String?
    let publisher: String?
    let descriptionPlain: String?
    let isbn: String?
    let asin: String?
    let language: String?
    let explicit: Bool
    let abridged: Bool
}

private struct ExpandedLibraryBookSeriesDTO: Decodable, Sendable {
    let id: SeriesID
    let name: String
    let sequence: String?
}

struct LibraryBookProgressDTO: Decodable, Sendable {
    let id: String
    let userID: UserID
    let libraryItemID: LibraryItemID
    let episodeID: String?
    let mediaItemID: BookID
    let mediaItemType: String
    let duration: Double
    let progress: Double
    let currentTime: Double
    let isFinished: Bool
    let hideFromContinueListening: Bool
    let lastUpdate: Int64
    let startedAt: Int64
    let finishedAt: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "userId"
        case libraryItemID = "libraryItemId"
        case episodeID = "episodeId"
        case mediaItemID = "mediaItemId"
        case mediaItemType
        case duration
        case progress
        case currentTime
        case isFinished
        case hideFromContinueListening
        case lastUpdate
        case startedAt
        case finishedAt
    }

    func domainValue(
        expectedItemID: LibraryItemID,
        expectedBookID: BookID,
        expectedUserID: UserID
    ) throws(AudiobookshelfAPIError) -> LibraryBookProgress {
        guard let progress = domainValue(),
              libraryItemID == expectedItemID,
              mediaItemID == expectedBookID,
              userID == expectedUserID,
              progress.libraryItemID == expectedItemID
        else {
            throw .invalidBookDetail
        }
        return progress
    }

    func domainValue() -> LibraryBookProgress? {
        guard !id.isEmpty,
              !userID.rawValue.isEmpty,
              !libraryItemID.rawValue.isEmpty,
              episodeID == nil,
              !mediaItemID.rawValue.isEmpty,
              mediaItemType == "book",
              duration.isFinite,
              duration >= 0,
              progress.isFinite,
              (0 ... 1).contains(progress),
              currentTime.isFinite,
              currentTime >= 0,
              lastUpdate >= 0,
              startedAt >= 0,
              (finishedAt ?? 0) >= 0
        else {
            return nil
        }
        return LibraryBookProgress(
            id: id,
            userID: userID,
            libraryItemID: libraryItemID,
            bookID: mediaItemID,
            duration: duration,
            progress: progress,
            currentTime: currentTime,
            isFinished: isFinished,
            hideFromContinueListening: hideFromContinueListening,
            lastUpdateMilliseconds: lastUpdate,
            startedAtMilliseconds: startedAt,
            finishedAtMilliseconds: finishedAt
        )
    }
}
