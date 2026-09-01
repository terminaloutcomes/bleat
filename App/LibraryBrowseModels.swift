import BleatCore

enum LibraryBrowseFilter: Hashable, Sendable {
    case all
    case progress(LibraryProgressFilter)
    case author(id: AuthorID, name: String)
    case series(id: SeriesID, name: String)

    var itemFilter: LibraryItemFilter? {
        switch self {
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
        case .author, .series:
            true
        case .all, .progress:
            false
        }
    }
}
