import BleatCore
import Foundation

/// Native lists are bounded, so larger catalogs use alphabetical folders.
/// Three folder pushes reserve the fifth navigation level for Now Playing.
struct CarPlayLibraryBrowser {
    enum Failure: Equatable, Sendable {
        case itemLimit, sectionLimit, depthLimit
    }

    struct Folder: Equatable, Sendable {
        let title: String
        let books: [LibraryBookSummary]
    }

    enum Entry: Equatable, Sendable {
        case book(LibraryBookSummary)
        case folder(Folder)
    }

    let contents: Result<[Entry], Failure>

    init(
        books: [LibraryBookSummary], maximumItems: Int,
        maximumSections: Int, depth: Int = 0, locale: Locale = .current
    ) {
        guard maximumSections > 0 else {
            contents = .failure(.sectionLimit)
            return
        }
        guard maximumItems > 0 else {
            contents = .failure(.itemLimit)
            return
        }
        let ordered = books.sorted {
            let comparison = Self.key($0).compare(
                Self.key($1),
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: locale)
            return comparison == .orderedSame
                ? $0.id.rawValue < $1.id.rawValue
                : comparison == .orderedAscending
        }
        if ordered.count <= maximumItems {
            contents = .success(ordered.map(Entry.book))
            return
        }
        guard maximumItems >= 2 else {
            contents = .failure(.itemLimit)
            return
        }
        guard depth < 3 else {
            contents = .failure(.depthLimit)
            return
        }
        var capacity = maximumItems
        for _ in depth..<3 {
            let result = capacity.multipliedReportingOverflow(by: maximumItems)
            capacity = result.overflow ? Int.max : result.partialValue
        }
        guard ordered.count <= capacity else {
            contents = .failure(.depthLimit)
            return
        }
        if depth == 0 {
            var buckets: [String: [LibraryBookSummary]] = [:]
            var letters: [String] = []
            for book in ordered {
                let letter = Self.bucket(Self.key(book), locale: locale)
                if buckets[letter] == nil { letters.append(letter) }
                buckets[letter, default: []].append(book)
            }
            if letters.count <= maximumItems {
                // A child needs enough remaining depth for its entire bucket.
                let childCapacity = capacity / maximumItems
                if buckets.values.allSatisfy({ $0.count <= childCapacity }) {
                    contents = .success(
                        letters.map {
                            .folder(Folder(title: $0, books: buckets[$0] ?? []))
                        })
                    return
                }
            }
        }
        let size = (ordered.count - 1) / maximumItems + 1
        contents = .success(
            stride(from: 0, to: ordered.count, by: size).map { start in
                let slice = Array(
                    ordered[start..<min(start + size, ordered.count)])
                let first = slice.first?.title ?? ""
                let last = slice.last?.title ?? first
                return .folder(
                    Folder(
                        title: first == last ? first : "\(first) – \(last)",
                        books: slice))
            })
    }

    private static func key(_ book: LibraryBookSummary) -> String {
        book.titleIndexKey ?? book.title
    }

    static func bucket(_ title: String, locale: Locale) -> String {
        let key = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: locale)
        guard let first = key.first,
            first.unicodeScalars.contains(where: CharacterSet.letters.contains)
        else { return "#" }
        return String(String(first).uppercased(with: locale).prefix(1))
    }
}

extension CarPlayLibraryBrowser.Failure: Error {}
