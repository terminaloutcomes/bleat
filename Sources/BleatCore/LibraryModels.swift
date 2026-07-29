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
