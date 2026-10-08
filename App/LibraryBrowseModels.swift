import BleatCore
import Foundation

enum LibraryBrowseMode: String, CaseIterable, Hashable, Sendable {
    case title, author, series, collections, narrators

    var label: String {
        switch self {
        case .title: "By Title"
        case .author: "By Author"
        case .series: "By Series"
        case .collections: "By Collections"
        case .narrators: "By Narrators"
        }
    }

    var categoryKind: LibraryCategoryKind? {
        switch self {
        case .title: nil
        case .author: .authors
        case .series: .series
        case .collections: .collections
        case .narrators: .narrators
        }
    }
}

enum LibraryBrowseFilter: Hashable, Sendable {
    case all
    case narrator(name: String)
    case collection(LibraryCategory)
    case progress(LibraryProgressFilter)
    case author(id: AuthorID, name: String)
    case series(id: SeriesID, name: String)

    var itemFilter: LibraryItemFilter? {
        switch self {
        case .collection:
            nil
        case .narrator(let name):
            LibraryItemFilter(narrator: name)
        case .all:
            nil
        case .progress(let filter):
            LibraryItemFilter(progress: filter)
        case .author(let id, _):
            LibraryItemFilter(authorID: id)
        case .series(let id, _):
            LibraryItemFilter(seriesID: id)
        }
    }

    var label: String {
        switch self {
        case .collection(let category):
            "Collection: \(category.name)"
        case .narrator(let name):
            "Narrator: \(name)"
        case .all:
            "All Books"
        case .progress(let filter):
            switch filter {
            case .finished:
                "Finished"
            case .inProgress:
                "In Progress"
            case .notStarted:
                "Not Started"
            case .notFinished:
                "Not Finished"
            }
        case .author(_, let name):
            "Author: \(name)"
        case .series(_, let name):
            "Series: \(name)"
        }
    }

    var isEntityScoped: Bool {
        switch self {
        case .author, .series, .collection, .narrator:
            true
        case .all, .progress:
            false
        }
    }
}

extension LibraryCategory {
    func page(sort: LibraryItemSort, descending: Bool) -> LibraryItemsPage {
        let ordered = books.sorted { left, right in
            let comparison: ComparisonResult
            switch sort {
            case .title, .sequence:
                comparison = left.title.localizedStandardCompare(right.title)
            case .author:
                comparison = (left.authorName ?? "").localizedStandardCompare(
                    right.authorName ?? "")
            case .addedAt:
                comparison =
                    left.addedAtMilliseconds == right.addedAtMilliseconds
                    ? .orderedSame
                    : left.addedAtMilliseconds < right.addedAtMilliseconds
                        ? .orderedAscending : .orderedDescending
            case .updatedAt:
                comparison =
                    left.updatedAtMilliseconds == right.updatedAtMilliseconds
                    ? .orderedSame
                    : left.updatedAtMilliseconds < right.updatedAtMilliseconds
                        ? .orderedAscending : .orderedDescending
            case .duration:
                comparison =
                    left.duration == right.duration
                    ? .orderedSame
                    : left.duration < right.duration
                        ? .orderedAscending : .orderedDescending
            }
            if comparison == .orderedSame {
                return left.id.rawValue < right.id.rawValue
            }
            return comparison
                == (descending ? .orderedDescending : .orderedAscending)
        }
        return LibraryItemsPage(
            items: ordered, total: ordered.count, page: 0,
            limit: max(1, ordered.count))
    }
}
