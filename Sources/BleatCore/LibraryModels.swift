import Foundation

public enum LibraryMediaType: Hashable, Sendable {
    case book
    case podcast
    case unknown(String)
}

extension LibraryMediaType: Codable {
    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
        let value: String
        switch self {
        case .book:
            value = "book"
        case .podcast:
            value = "podcast"
        case let .unknown(rawValue):
            value = rawValue
        }
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct LibrarySummary: Codable, Hashable, Sendable {
    public let id: LibraryID
    public let name: String
    public let mediaType: LibraryMediaType

    public init(
        id: LibraryID,
        name: String,
        mediaType: LibraryMediaType
    ) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
    }
}

extension LibrarySummary {
    var isValidForStorage: Bool {
        !id.rawValue.isEmpty
            && Self.isValidDisplayString(name)
            && mediaType.isValidForStorage
    }

    private static func isValidDisplayString(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

private extension LibraryMediaType {
    var isValidForStorage: Bool {
        switch self {
        case .book, .podcast:
            true
        case let .unknown(rawValue):
            !rawValue.isEmpty
                && rawValue.rangeOfCharacter(from: .controlCharacters) == nil
        }
    }
}

public enum LibraryItemSort: Hashable, Sendable {
    case title
    case author
    case addedAt
    case updatedAt
    case duration

    var queryValue: String {
        switch self {
        case .title:
            "media.metadata.title"
        case .author:
            "media.metadata.authorNameLF"
        case .addedAt:
            "addedAt"
        case .updatedAt:
            "updatedAt"
        case .duration:
            "media.duration"
        }
    }
}

public struct LibraryItemFilter: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws(LibraryPageRequestError) {
        guard !rawValue.isEmpty,
              rawValue.rangeOfCharacter(
                  from: .controlCharacters
              ) == nil
        else {
            throw .invalidFilter
        }
        self.rawValue = rawValue
    }
}

public enum LibraryPageRequestError: Error, Equatable, Sendable {
    case invalidPage
    case invalidLimit
    case invalidFilter
}

public struct LibraryItemsPageRequest: Hashable, Sendable {
    public let page: Int
    public let limit: Int
    public let sort: LibraryItemSort
    public let descending: Bool
    public let filter: LibraryItemFilter?
    public let includeProgress: Bool
    public let collapseSeries: Bool

    public init(
        page: Int,
        limit: Int = 50,
        sort: LibraryItemSort = .title,
        descending: Bool = false,
        filter: LibraryItemFilter? = nil,
        includeProgress: Bool = true,
        collapseSeries: Bool = true
    ) throws(LibraryPageRequestError) {
        guard page >= 0 else {
            throw .invalidPage
        }
        guard (1 ... 100).contains(limit) else {
            throw .invalidLimit
        }
        self.page = page
        self.limit = limit
        self.sort = sort
        self.descending = descending
        self.filter = filter
        self.includeProgress = includeProgress
        self.collapseSeries = collapseSeries
    }

    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "sort", value: sort.queryValue),
        ]
        if descending {
            items.append(URLQueryItem(name: "desc", value: "1"))
        }
        if let filter {
            items.append(
                URLQueryItem(name: "filter", value: filter.rawValue)
            )
        }
        items.append(URLQueryItem(name: "minified", value: "1"))
        if collapseSeries {
            items.append(
                URLQueryItem(name: "collapseseries", value: "1")
            )
        }
        if includeProgress {
            items.append(URLQueryItem(name: "include", value: "progress"))
        }
        return items
    }
}

public enum LibrarySearchRequestError: Error, Equatable, Sendable {
    case invalidQuery
    case invalidLimit
}

public struct LibrarySearchRequest: Hashable, Sendable {
    public let query: String
    public let limit: Int

    public init(
        query: String,
        limit: Int = 50
    ) throws(LibrarySearchRequestError) {
        let normalized = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty,
              normalized.count <= 200,
              normalized.rangeOfCharacter(
                  from: .controlCharacters
              ) == nil
        else {
            throw .invalidQuery
        }
        guard (1 ... 100).contains(limit) else {
            throw .invalidLimit
        }
        self.query = normalized
        self.limit = limit
    }

    var queryItems: [URLQueryItem] {
        [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
    }
}

public enum LibraryHomeRequestError: Error, Equatable, Sendable {
    case invalidLimit
}

public struct LibraryHomeRequest: Hashable, Sendable {
    public let limit: Int
    public let includeProgress: Bool

    public init(
        limit: Int = 10,
        includeProgress: Bool = true
    ) throws(LibraryHomeRequestError) {
        guard (1 ... 100).contains(limit) else {
            throw .invalidLimit
        }
        self.limit = limit
        self.includeProgress = includeProgress
    }

    var queryItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if includeProgress {
            items.append(
                URLQueryItem(name: "include", value: "progress")
            )
        }
        return items
    }
}

public struct LibraryBookSummary: Codable, Hashable, Sendable {
    public let id: LibraryItemID
    public let libraryID: LibraryID
    public let title: String
    public let subtitle: String?
    public let authorName: String?
    public let narratorName: String?
    public let seriesName: String?
    public let genres: [String]
    public let publisher: String?
    public let publishedYear: String?
    public let duration: Double
    public let trackCount: Int
    public let chapterCount: Int
    public let addedAtMilliseconds: Int64
    public let updatedAtMilliseconds: Int64
    public let isExplicit: Bool
    public let isAbridged: Bool
}

public struct LibraryBookContributor: Codable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct LibraryBookSeries: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let sequence: String?

    public init(id: String, name: String, sequence: String?) {
        self.id = id
        self.name = name
        self.sequence = sequence
    }
}

public struct LibraryBookProgress: Codable, Hashable, Sendable {
    public let id: String
    public let userID: UserID
    public let libraryItemID: LibraryItemID
    public let bookID: BookID
    public let duration: Double
    public let progress: Double
    public let currentTime: Double
    public let isFinished: Bool
    public let hideFromContinueListening: Bool
    public let lastUpdateMilliseconds: Int64
    public let startedAtMilliseconds: Int64
    public let finishedAtMilliseconds: Int64?

    public init(
        id: String,
        userID: UserID,
        libraryItemID: LibraryItemID,
        bookID: BookID,
        duration: Double,
        progress: Double,
        currentTime: Double,
        isFinished: Bool,
        hideFromContinueListening: Bool,
        lastUpdateMilliseconds: Int64,
        startedAtMilliseconds: Int64,
        finishedAtMilliseconds: Int64?
    ) {
        self.id = id
        self.userID = userID
        self.libraryItemID = libraryItemID
        self.bookID = bookID
        self.duration = duration
        self.progress = progress
        self.currentTime = currentTime
        self.isFinished = isFinished
        self.hideFromContinueListening = hideFromContinueListening
        self.lastUpdateMilliseconds = lastUpdateMilliseconds
        self.startedAtMilliseconds = startedAtMilliseconds
        self.finishedAtMilliseconds = finishedAtMilliseconds
    }
}

public struct LibraryBookDetail: Codable, Hashable, Sendable {
    public let id: LibraryItemID
    public let libraryID: LibraryID
    public let bookID: BookID
    public let title: String
    public let subtitle: String?
    public let authors: [LibraryBookContributor]
    public let narrators: [String]
    public let series: [LibraryBookSeries]
    public let genres: [String]
    public let tags: [String]
    public let publishedYear: String?
    public let publishedDate: String?
    public let publisher: String?
    public let descriptionPlain: String?
    public let isbn: String?
    public let asin: String?
    public let language: String?
    public let duration: Double
    public let trackCount: Int
    public let audioFileCount: Int
    public let chapters: [PlaybackChapter]
    public let addedAtMilliseconds: Int64
    public let updatedAtMilliseconds: Int64
    public let isExplicit: Bool
    public let isAbridged: Bool
    public let progress: LibraryBookProgress?

    public init(
        id: LibraryItemID,
        libraryID: LibraryID,
        bookID: BookID,
        title: String,
        subtitle: String?,
        authors: [LibraryBookContributor],
        narrators: [String],
        series: [LibraryBookSeries],
        genres: [String],
        tags: [String],
        publishedYear: String?,
        publishedDate: String?,
        publisher: String?,
        descriptionPlain: String?,
        isbn: String?,
        asin: String?,
        language: String?,
        duration: Double,
        trackCount: Int,
        audioFileCount: Int,
        chapters: [PlaybackChapter],
        addedAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64,
        isExplicit: Bool,
        isAbridged: Bool,
        progress: LibraryBookProgress?
    ) {
        self.id = id
        self.libraryID = libraryID
        self.bookID = bookID
        self.title = title
        self.subtitle = subtitle
        self.authors = authors
        self.narrators = narrators
        self.series = series
        self.genres = genres
        self.tags = tags
        self.publishedYear = publishedYear
        self.publishedDate = publishedDate
        self.publisher = publisher
        self.descriptionPlain = descriptionPlain
        self.isbn = isbn
        self.asin = asin
        self.language = language
        self.duration = duration
        self.trackCount = trackCount
        self.audioFileCount = audioFileCount
        self.chapters = chapters
        self.addedAtMilliseconds = addedAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        self.isExplicit = isExplicit
        self.isAbridged = isAbridged
        self.progress = progress
    }
}

extension LibraryBookDetail {
    func isValidForStorage(
        in libraryID: LibraryID,
        for userID: UserID
    ) -> Bool {
        !id.rawValue.isEmpty
            && self.libraryID == libraryID
            && !bookID.rawValue.isEmpty
            && Self.isValidDisplayString(title)
            && Self.isValidOptionalString(subtitle)
            && authors.allSatisfy {
                Self.isValidDisplayString($0.id)
                    && Self.isValidDisplayString($0.name)
            }
            && narrators.allSatisfy(Self.isValidDisplayString)
            && series.allSatisfy {
                Self.isValidDisplayString($0.id)
                    && Self.isValidDisplayString($0.name)
                    && Self.isValidOptionalString($0.sequence)
            }
            && genres.allSatisfy(Self.isValidDisplayString)
            && tags.allSatisfy(Self.isValidDisplayString)
            && Self.isValidOptionalString(publishedYear)
            && Self.isValidOptionalString(publishedDate)
            && Self.isValidOptionalString(publisher)
            && Self.isValidOptionalString(descriptionPlain)
            && Self.isValidOptionalString(isbn)
            && Self.isValidOptionalString(asin)
            && Self.isValidOptionalString(language)
            && duration.isFinite
            && duration > 0
            && trackCount > 0
            && audioFileCount >= trackCount
            && addedAtMilliseconds >= 0
            && updatedAtMilliseconds >= 0
            && Self.areValid(chapters: chapters, duration: duration)
            && Self.isValid(
                progress: progress,
                itemID: id,
                bookID: bookID,
                userID: userID
            )
    }

    private static func areValid(
        chapters: [PlaybackChapter],
        duration: Double
    ) -> Bool {
        var chapterIDs: Set<Int> = []
        return chapters.allSatisfy { chapter in
            chapterIDs.insert(chapter.id).inserted
                && chapter.start.isFinite
                && chapter.start >= 0
                && chapter.start <= duration
                && chapter.end.isFinite
                && chapter.end >= chapter.start
                && isValidOptionalString(chapter.title)
        }
    }

    private static func isValid(
        progress: LibraryBookProgress?,
        itemID: LibraryItemID,
        bookID: BookID,
        userID: UserID
    ) -> Bool {
        guard let progress else {
            return true
        }
        return isValidDisplayString(progress.id)
            && progress.userID == userID
            && progress.libraryItemID == itemID
            && progress.bookID == bookID
            && progress.duration.isFinite
            && progress.duration >= 0
            && progress.progress.isFinite
            && (0 ... 1).contains(progress.progress)
            && progress.currentTime.isFinite
            && progress.currentTime >= 0
            && progress.lastUpdateMilliseconds >= 0
            && progress.startedAtMilliseconds >= 0
            && (progress.finishedAtMilliseconds ?? 0) >= 0
    }

    private static func isValidDisplayString(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func isValidOptionalString(_ value: String?) -> Bool {
        guard let value else {
            return true
        }
        return value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

extension LibraryBookSummary {
    func isValidForStorage(in libraryID: LibraryID) -> Bool {
        !id.rawValue.isEmpty
            && self.libraryID == libraryID
            && Self.isValidDisplayString(title)
            && Self.isValidOptionalDisplayString(subtitle)
            && Self.isValidOptionalDisplayString(authorName)
            && Self.isValidOptionalDisplayString(narratorName)
            && Self.isValidOptionalDisplayString(seriesName)
            && genres.allSatisfy(Self.isValidDisplayString)
            && Self.isValidOptionalDisplayString(publisher)
            && Self.isValidOptionalDisplayString(publishedYear)
            && duration.isFinite
            && duration >= 0
            && trackCount >= 0
            && chapterCount >= 0
            && addedAtMilliseconds >= 0
            && updatedAtMilliseconds >= 0
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

public struct LibraryBookShelf: Codable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let labelLocalizationKey: String?
    public let items: [LibraryBookSummary]
    public let total: Int

    public init(
        id: String,
        label: String,
        labelLocalizationKey: String?,
        items: [LibraryBookSummary],
        total: Int
    ) {
        self.id = id
        self.label = label
        self.labelLocalizationKey = labelLocalizationKey
        self.items = items
        self.total = total
    }

    func isValidForStorage(
        request: LibraryHomeRequest,
        libraryID: LibraryID
    ) -> Bool {
        Self.isValidDisplayString(id)
            && Self.isValidDisplayString(label)
            && Self.isValidOptionalDisplayString(labelLocalizationKey)
            && total >= items.count
            && items.count <= request.limit
            && !items.isEmpty
            && items.allSatisfy {
                $0.trackCount > 0
                    && $0.isValidForStorage(in: libraryID)
            }
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

public struct LibraryItemsPage: Codable, Hashable, Sendable {
    public let items: [LibraryBookSummary]
    public let total: Int
    public let page: Int
    public let limit: Int

    public var hasNextPage: Bool {
        guard limit > 0, total > 0 else {
            return false
        }
        return page < (total - 1) / limit
    }

    func isValidForStorage(
        request: LibraryItemsPageRequest,
        libraryID: LibraryID
    ) -> Bool {
        page == request.page
            && limit == request.limit
            && total >= 0
            && items.count <= limit
            && items.allSatisfy {
                $0.isValidForStorage(in: libraryID)
            }
    }
}
