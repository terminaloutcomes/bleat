import BleatCore
import Foundation

struct DeepLinkScope: Hashable, Sendable {
    let accountID: AccountID?
    let libraryID: LibraryID?
}

enum DeepLinkSearchScope: Hashable, Sendable {
    case all
    case book
    case author
    case series
}

enum DeepLinkSettingsDestination: Hashable, Sendable {
    case root
    case diagnostics
    case statistics
    case about
}

enum DeepLinkRoute: Hashable, Sendable {
    case home
    case library
    case downloads
    case search(query: String, scope: DeepLinkSearchScope, target: DeepLinkScope)
    case book(id: LibraryItemID, target: DeepLinkScope)
    case author(id: AuthorID, target: DeepLinkScope)
    case series(id: SeriesID, target: DeepLinkScope)
    case settings(DeepLinkSettingsDestination)
    case nowPlaying
}

enum DeepLinkParseError: Error, Equatable, Sendable {
    case invalidURL
}

enum DeepLinkParser {
    static func parse(_ url: URL) throws(DeepLinkParseError) -> DeepLinkRoute {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "bleat",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let host = components.host?.lowercased()
        else {
            throw .invalidURL
        }
        let encodedPath = components.percentEncodedPath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !encodedPath.contains(where: \.isEmpty) else {
            throw .invalidURL
        }
        var path: [String] = []
        path.reserveCapacity(encodedPath.count)
        for component in encodedPath {
            guard let value = String(component).removingPercentEncoding else {
                throw DeepLinkParseError.invalidURL
            }
            path.append(value)
        }
        var query = try queryValues(components.queryItems ?? [])
        switch host {
        case "home":
            return try empty(path, query, route: .home)
        case "library":
            return try empty(path, query, route: .library)
        case "downloads":
            return try empty(path, query, route: .downloads)
        case "now-playing":
            return try empty(path, query, route: .nowPlaying)
        case "settings":
            guard query.isEmpty else { throw .invalidURL }
            switch path {
            case []: return .settings(.root)
            case ["diagnostics"], ["diag"]: return .settings(.diagnostics)
            case ["statistics"], ["stats"]: return .settings(.statistics)
            case ["about"]: return .settings(.about)
            default: throw .invalidURL
            }
        case "search":
            let scope: DeepLinkSearchScope
            switch path {
            case []: scope = .all
            case ["book"]: scope = .book
            case ["author"]: scope = .author
            case ["series"]: scope = .series
            default: throw .invalidURL
            }
            guard let value = query.removeValue(forKey: "q"),
                  let search = valid(value, maximumLength: 256),
                  query.keys.allSatisfy({ $0 == "account" || $0 == "library" })
            else { throw .invalidURL }
            return .search(
                query: search,
                scope: scope,
                target: try scopeValues(query)
            )
        case "book", "author", "series":
            guard path.count == 1,
                  let raw = valid(path[0], maximumLength: 512),
                  query.keys.allSatisfy({ $0 == "account" || $0 == "library" })
            else { throw .invalidURL }
            let target = try scopeValues(query)
            switch host {
            case "book":
                return .book(id: LibraryItemID(rawValue: raw), target: target)
            case "author":
                guard let id = AuthorID(rawValue: raw) else { throw .invalidURL }
                return .author(id: id, target: target)
            default:
                guard let id = SeriesID(rawValue: raw) else { throw .invalidURL }
                return .series(id: id, target: target)
            }
        default:
            throw .invalidURL
        }
    }

    private static func empty(
        _ path: [String],
        _ query: [String: String],
        route: DeepLinkRoute
    ) throws(DeepLinkParseError) -> DeepLinkRoute {
        guard path.isEmpty, query.isEmpty else { throw .invalidURL }
        return route
    }

    private static func queryValues(
        _ items: [URLQueryItem]
    ) throws(DeepLinkParseError) -> [String: String] {
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value,
                  values[item.name] == nil
            else { throw .invalidURL }
            values[item.name] = value
        }
        return values
    }

    private static func scopeValues(
        _ values: [String: String]
    ) throws(DeepLinkParseError) -> DeepLinkScope {
        let account: AccountID?
        if let value = values["account"] {
            guard let value = valid(value, maximumLength: 512) else {
                throw .invalidURL
            }
            account = AccountID(rawValue: value)
        } else {
            account = nil
        }
        let library: LibraryID?
        if let value = values["library"] {
            guard let value = valid(value, maximumLength: 512) else {
                throw .invalidURL
            }
            library = LibraryID(rawValue: value)
        } else {
            library = nil
        }
        return DeepLinkScope(accountID: account, libraryID: library)
    }

    private static func valid(_ value: String, maximumLength: Int) -> String? {
        guard !value.isEmpty,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count <= maximumLength,
              value.rangeOfCharacter(from: .controlCharacters) == nil
        else { return nil }
        return value
    }
}

enum DeepLinkFormatter {
    static func format(_ route: DeepLinkRoute) -> URL? {
        var components = URLComponents()
        components.scheme = "bleat"

        switch route {
        case .home:
            components.host = "home"
        case .library:
            components.host = "library"
        case .downloads:
            components.host = "downloads"
        case .nowPlaying:
            components.host = "now-playing"
        case let .settings(destination):
            components.host = "settings"
            switch destination {
            case .root:
                break
            case .diagnostics:
                components.path = "/diagnostics"
            case .statistics:
                components.path = "/statistics"
            case .about:
                components.path = "/about"
            }
        case let .search(query, scope, target):
            components.host = "search"
            switch scope {
            case .all:
                break
            case .book:
                components.path = "/book"
            case .author:
                components.path = "/author"
            case .series:
                components.path = "/series"
            }
            components.queryItems = queryItems(
                base: [URLQueryItem(name: "q", value: query)],
                target: target
            )
        case let .book(id, target):
            components.host = "book"
            guard setPathComponent(id.rawValue, on: &components) else {
                return nil
            }
            components.queryItems = queryItems(base: [], target: target)
        case let .author(id, target):
            components.host = "author"
            guard setPathComponent(id.rawValue, on: &components) else {
                return nil
            }
            components.queryItems = queryItems(base: [], target: target)
        case let .series(id, target):
            components.host = "series"
            guard setPathComponent(id.rawValue, on: &components) else {
                return nil
            }
            components.queryItems = queryItems(base: [], target: target)
        }
        return components.url
    }

    private static func queryItems(
        base: [URLQueryItem],
        target: DeepLinkScope
    ) -> [URLQueryItem] {
        var items = base
        if let accountID = target.accountID {
            items.append(URLQueryItem(name: "account", value: accountID.rawValue))
        }
        if let libraryID = target.libraryID {
            items.append(URLQueryItem(name: "library", value: libraryID.rawValue))
        }
        return items
    }

    private static func setPathComponent(
        _ value: String,
        on components: inout URLComponents
    ) -> Bool {
        let allowed = CharacterSet.urlPathAllowed.subtracting(
            CharacterSet(charactersIn: "/")
        )
        guard let encoded = value.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) else {
            return false
        }
        components.percentEncodedPath = "/\(encoded)"
        return true
    }
}
