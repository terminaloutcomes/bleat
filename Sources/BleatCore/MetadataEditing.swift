import Foundation

public struct BookMetadataSeriesDraft: Equatable, Sendable {
    public var name: String
    public var sequence: String

    public init(name: String, sequence: String) {
        self.name = name
        self.sequence = sequence
    }
}

public struct BookMetadataDraft: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var authors: [String]
    public var narrators: [String]
    public var series: [BookMetadataSeriesDraft]
    public var genres: [String]
    public var publishedYear: String
    public var publishedDate: String
    public var publisher: String
    public var description: String
    public var isbn: String
    public var asin: String
    public var language: String
    public var tags: [String]
    public var isExplicit: Bool
    public var isAbridged: Bool

    public init(detail: LibraryBookDetail) {
        title = detail.title
        subtitle = detail.subtitle ?? ""
        authors = detail.authors.map(\.name)
        narrators = detail.narrators
        series = detail.series.map {
            BookMetadataSeriesDraft(
                name: $0.name,
                sequence: $0.sequence ?? ""
            )
        }
        genres = detail.genres
        publishedYear = detail.publishedYear ?? ""
        publishedDate = detail.publishedDate ?? ""
        publisher = detail.publisher ?? ""
        description = detail.descriptionPlain ?? ""
        isbn = detail.isbn ?? ""
        asin = detail.asin ?? ""
        language = detail.language ?? ""
        tags = detail.tags
        isExplicit = detail.isExplicit
        isAbridged = detail.isAbridged
    }
}

public enum BookMetadataPatchError: Error, Equatable, Sendable {
    case emptyTitle
    case invalidText
}

public struct BookMetadataPatch: Encodable, Sendable {
    private let baselineItemID: LibraryItemID
    private let baselineUpdatedAtMilliseconds: Int64
    private let baseline: BookMetadataSnapshot
    private let updated: BookMetadataSnapshot

    public init(
        baseline: LibraryBookDetail,
        draft: BookMetadataDraft
    ) throws(BookMetadataPatchError) {
        baselineItemID = baseline.id
        baselineUpdatedAtMilliseconds =
            baseline.updatedAtMilliseconds
        self.baseline = BookMetadataSnapshot(detail: baseline)
        updated = try BookMetadataSnapshot(draft: draft)
    }

    public var isEmpty: Bool {
        baseline == updated
    }

    public func isStale(
        comparedTo latest: LibraryBookDetail
    ) -> Bool {
        latest.id != baselineItemID
            || latest.updatedAtMilliseconds
                != baselineUpdatedAtMilliseconds
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: OuterCodingKeys.self)
        if baseline.metadata != updated.metadata {
            try container.encode(
                MetadataChanges(
                    baseline: baseline.metadata,
                    updated: updated.metadata
                ),
                forKey: .metadata
            )
        }
        if baseline.tags != updated.tags {
            try container.encode(updated.tags, forKey: .tags)
        }
    }

    private enum OuterCodingKeys: String, CodingKey {
        case metadata
        case tags
    }
}

public enum BookMetadataUpdateError: Error, Equatable, Sendable {
    case invalidItemID
    case emptyPatch
    case requestConstructionFailed(RouteConstructionError)
    case requestEncodingFailed
    case authenticationFailed(AuthenticatedRequestError)
    case requestFailed
    case unexpectedStatus(Int)
    case malformedResponse
    case updateRejected
}

extension AuthCoordinator {
    public func updateBookMetadata(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID,
        patch: BookMetadataPatch
    ) async throws(BookMetadataUpdateError) {
        guard !itemID.rawValue.isEmpty else {
            throw .invalidItemID
        }
        guard !patch.isEmpty else {
            throw .emptyPatch
        }
        let route = AudiobookshelfRoute.metadata(itemID)
        let url: URL
        do {
            url = try AudiobookshelfRouteBuilder(server: server).url(
                for: route
            )
        } catch let error {
            throw .requestConstructionFailed(error)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        do {
            request.httpBody = try JSONEncoder().encode(patch)
        } catch {
            throw .requestEncodingFailed
        }

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
        guard response.statusCode == 200 else {
            throw .unexpectedStatus(response.statusCode)
        }
        let result: MetadataUpdateResponse
        do {
            result = try JSONDecoder().decode(
                MetadataUpdateResponse.self,
                from: response.data
            )
        } catch {
            throw .malformedResponse
        }
        guard result.updated else {
            throw .updateRejected
        }
    }
}

private struct BookMetadataSnapshot: Equatable, Sendable {
    let metadata: BookMetadataValues
    let tags: [String]

    init(detail: LibraryBookDetail) {
        metadata = BookMetadataValues(
            title: detail.title,
            subtitle: detail.subtitle,
            authors: detail.authors.map(\.name),
            narrators: detail.narrators,
            series: detail.series.map {
                BookMetadataSeriesValue(
                    name: $0.name,
                    sequence: $0.sequence
                )
            },
            genres: detail.genres,
            publishedYear: detail.publishedYear,
            publishedDate: detail.publishedDate,
            publisher: detail.publisher,
            description: detail.descriptionPlain,
            isbn: detail.isbn,
            asin: detail.asin,
            language: detail.language,
            isExplicit: detail.isExplicit,
            isAbridged: detail.isAbridged
        )
        tags = detail.tags
    }

    init(draft: BookMetadataDraft) throws(BookMetadataPatchError) {
        let title = draft.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !title.isEmpty else {
            throw .emptyTitle
        }
        let authors = Self.normalizedList(draft.authors)
        let narrators = Self.normalizedList(draft.narrators)
        let genres = Self.normalizedList(draft.genres)
        let tags = Self.normalizedList(draft.tags)
        let series: [BookMetadataSeriesValue] =
            draft.series.compactMap { value in
                let name = value.name.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !name.isEmpty else {
                    return nil
                }
                return BookMetadataSeriesValue(
                    name: name,
                    sequence: Self.optionalText(value.sequence)
                )
            }
        var allText = [title]
        allText.append(contentsOf: authors)
        allText.append(contentsOf: narrators)
        allText.append(contentsOf: genres)
        allText.append(contentsOf: tags)
        for value in series {
            allText.append(value.name)
            allText.append(value.sequence ?? "")
        }
        allText.append(contentsOf: [
            draft.subtitle,
            draft.publishedYear,
            draft.publishedDate,
            draft.publisher,
            draft.description,
            draft.isbn,
            draft.asin,
            draft.language,
        ])
        guard allText.allSatisfy(Self.isValidText) else {
            throw .invalidText
        }

        metadata = BookMetadataValues(
            title: title,
            subtitle: Self.optionalText(draft.subtitle),
            authors: authors,
            narrators: narrators,
            series: series,
            genres: genres,
            publishedYear: Self.optionalText(draft.publishedYear),
            publishedDate: Self.optionalText(draft.publishedDate),
            publisher: Self.optionalText(draft.publisher),
            description: Self.optionalText(draft.description),
            isbn: Self.optionalText(draft.isbn),
            asin: Self.optionalText(draft.asin),
            language: Self.optionalText(draft.language),
            isExplicit: draft.isExplicit,
            isAbridged: draft.isAbridged
        )
        self.tags = tags
    }

    private static func normalizedList(_ values: [String]) -> [String] {
        values.compactMap { value in
            let normalized = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return normalized.isEmpty ? nil : normalized
        }
    }

    private static func optionalText(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }

    private static func isValidText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                || $0 == "\n"
                || $0 == "\r"
                || $0 == "\t"
        }
    }
}

private struct BookMetadataValues: Equatable, Sendable {
    let title: String
    let subtitle: String?
    let authors: [String]
    let narrators: [String]
    let series: [BookMetadataSeriesValue]
    let genres: [String]
    let publishedYear: String?
    let publishedDate: String?
    let publisher: String?
    let description: String?
    let isbn: String?
    let asin: String?
    let language: String?
    let isExplicit: Bool
    let isAbridged: Bool
}

private struct BookMetadataSeriesValue: Equatable, Sendable {
    let name: String
    let sequence: String?
}

private struct MetadataChanges: Encodable {
    let baseline: BookMetadataValues
    let updated: BookMetadataValues

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeChange(
            baseline.title,
            updated.title,
            key: .title,
            into: &container
        )
        try encodeChange(
            baseline.subtitle,
            updated.subtitle,
            key: .subtitle,
            into: &container
        )
        if baseline.authors != updated.authors {
            try container.encode(
                updated.authors.map(MetadataAuthor.init),
                forKey: .authors
            )
        }
        try encodeChange(
            baseline.narrators,
            updated.narrators,
            key: .narrators,
            into: &container
        )
        if baseline.series != updated.series {
            try container.encode(
                updated.series.map(MetadataSeries.init),
                forKey: .series
            )
        }
        try encodeChange(
            baseline.genres,
            updated.genres,
            key: .genres,
            into: &container
        )
        try encodeChange(
            baseline.publishedYear,
            updated.publishedYear,
            key: .publishedYear,
            into: &container
        )
        try encodeChange(
            baseline.publishedDate,
            updated.publishedDate,
            key: .publishedDate,
            into: &container
        )
        try encodeChange(
            baseline.publisher,
            updated.publisher,
            key: .publisher,
            into: &container
        )
        try encodeChange(
            baseline.description,
            updated.description,
            key: .description,
            into: &container
        )
        try encodeChange(
            baseline.isbn,
            updated.isbn,
            key: .isbn,
            into: &container
        )
        try encodeChange(
            baseline.asin,
            updated.asin,
            key: .asin,
            into: &container
        )
        try encodeChange(
            baseline.language,
            updated.language,
            key: .language,
            into: &container
        )
        try encodeChange(
            baseline.isExplicit,
            updated.isExplicit,
            key: .explicit,
            into: &container
        )
        try encodeChange(
            baseline.isAbridged,
            updated.isAbridged,
            key: .abridged,
            into: &container
        )
    }

    private func encodeChange<Value: Encodable & Equatable>(
        _ baseline: Value,
        _ updated: Value,
        key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if baseline != updated {
            try container.encode(updated, forKey: key)
        }
    }

    private func encodeChange<Value: Encodable & Equatable>(
        _ baseline: Value?,
        _ updated: Value?,
        key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        guard baseline != updated else {
            return
        }
        if let updated {
            try container.encode(updated, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case subtitle
        case authors
        case narrators
        case series
        case genres
        case publishedYear
        case publishedDate
        case publisher
        case description
        case isbn
        case asin
        case language
        case explicit
        case abridged
    }
}

private struct MetadataAuthor: Encodable {
    let name: String

    init(_ name: String) {
        self.name = name
    }
}

private struct MetadataSeries: Encodable {
    let name: String
    let sequence: String?

    init(_ value: BookMetadataSeriesValue) {
        name = value.name
        sequence = value.sequence
    }
}

private struct MetadataUpdateResponse: Decodable {
    let updated: Bool
}
