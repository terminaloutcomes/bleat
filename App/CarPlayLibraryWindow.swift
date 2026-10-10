import BleatCore
import Foundation

/// Alphabetizes only the rendered window. Server page order still defines which
/// window owns a book; no global collation or whole-library letter jump is claimed.
struct CarPlayLibraryWindow {
    struct Group {
        let indexTitle: String?
        let books: [LibraryBookSummary]
    }

    let range: Range<Int>
    let groups: [Group]

    init(
        books: [LibraryBookSummary], start: Int,
        maximumItems: Int, maximumSections: Int,
        titleOrder: Bool = true, locale: Locale = .current
    ) {
        let start = min(max(0, start), max(0, books.count - 1))
        // Reserve both navigation rows, even on the first/last window, so limits
        // and pending/retry transitions cannot clip a book or navigation control.
        let capacity =
            maximumItems >= 3 ? maximumItems - 2 : max(0, maximumItems)
        let end = min(books.count, start + capacity)
        range = start..<end
        guard maximumSections > 0, end > start else {
            groups = []
            return
        }
        let window = Array(books[range])
        let ordered =
            titleOrder
            ? window.sorted {
                let comparison = Self.key($0).compare(
                    Self.key($1),
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: locale)
                return comparison == .orderedSame
                    ? $0.id.rawValue < $1.id.rawValue
                    : comparison == .orderedAscending
            } : window
        var grouped: [Group] = []
        for book in ordered {
            let bucket =
                titleOrder ? Self.bucket(Self.key(book), locale: locale) : nil
            if let last = grouped.last, last.indexTitle == bucket {
                grouped[grouped.count - 1] = Group(
                    indexTitle: bucket, books: last.books + [book])
            } else {
                grouped.append(Group(indexTitle: bucket, books: [book]))
            }
        }
        // A reduced section budget falls back to the ordinary native list;
        // never discard later letters to make the index fit.
        groups =
            grouped.count <= maximumSections
            ? grouped : [Group(indexTitle: nil, books: ordered)]
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
        // Uppercasing can expand a grapheme (for example ß). CarPlay accepts
        // one character, so retain only the first complete grapheme.
        return String(String(first).uppercased(with: locale).prefix(1))
    }
}
