import Foundation

public enum PlaybackMethod: Int, Codable, Hashable, Sendable {
    case directPlay = 0
    case transcode = 2
    case local = 3
}

public enum AudiobookshelfRoute: Hashable, Sendable {
    case status
    case login
    case beginOpenID
    case completeOpenID
    case refresh
    case logout
    case authorize
    case libraries
    case libraryItems(LibraryID)
    case personalized(LibraryID)
    case search(LibraryID)
    case item(LibraryItemID)
    case play(LibraryItemID)
    case directPlay(sessionID: PlaybackSessionID, trackIndex: Int)
    case syncSession(PlaybackSessionID)
    case closeSession(PlaybackSessionID)
    case syncLocalSession
    case syncLocalSessions
    case progress(LibraryItemID)
    case allProgress
    case listeningStats
    case listeningSessions
    case itemListeningSessions(LibraryItemID)
    case yearlyStats(Int)
    case bookmarks(LibraryItemID)
    case deleteBookmark(itemID: LibraryItemID, time: Double)
    case downloadFile(itemID: LibraryItemID, inode: String)
    case cover(LibraryItemID)
    case metadata(LibraryItemID)

    fileprivate var pathComponents: [String] {
        switch self {
        case .status:
            ["status"]
        case .login:
            ["login"]
        case .beginOpenID:
            ["auth", "openid"]
        case .completeOpenID:
            ["auth", "openid", "callback"]
        case .refresh:
            ["auth", "refresh"]
        case .logout:
            ["logout"]
        case .authorize:
            ["api", "authorize"]
        case .libraries:
            ["api", "libraries"]
        case let .libraryItems(libraryID):
            ["api", "libraries", libraryID.rawValue, "items"]
        case let .personalized(libraryID):
            ["api", "libraries", libraryID.rawValue, "personalized"]
        case let .search(libraryID):
            ["api", "libraries", libraryID.rawValue, "search"]
        case let .item(itemID):
            ["api", "items", itemID.rawValue]
        case let .play(itemID):
            ["api", "items", itemID.rawValue, "play"]
        case let .directPlay(sessionID, trackIndex):
            ["public", "session", sessionID.rawValue, "track", String(trackIndex)]
        case let .syncSession(sessionID):
            ["api", "session", sessionID.rawValue, "sync"]
        case let .closeSession(sessionID):
            ["api", "session", sessionID.rawValue, "close"]
        case .syncLocalSession:
            ["api", "session", "local"]
        case .syncLocalSessions:
            ["api", "session", "local-all"]
        case let .progress(itemID):
            ["api", "me", "progress", itemID.rawValue]
        case .allProgress:
            ["api", "me", "progress"]
        case .listeningStats:
            ["api", "me", "listening-stats"]
        case .listeningSessions:
            ["api", "me", "listening-sessions"]
        case let .itemListeningSessions(itemID):
            ["api", "me", "item", "listening-sessions", itemID.rawValue]
        case let .yearlyStats(year):
            ["api", "me", "stats", "year", String(year)]
        case let .bookmarks(itemID):
            ["api", "me", "bookmarks", itemID.rawValue]
        case let .deleteBookmark(itemID, time):
            ["api", "me", "item", itemID.rawValue, "bookmark", Self.secondsPathComponent(time)]
        case let .downloadFile(itemID, inode):
            ["api", "items", itemID.rawValue, "file", inode, "download"]
        case let .cover(itemID):
            ["api", "items", itemID.rawValue, "cover"]
        case let .metadata(itemID):
            ["api", "items", itemID.rawValue, "media"]
        }
    }

    private static func secondsPathComponent(_ seconds: Double) -> String {
        if seconds.rounded() == seconds {
            return String(Int64(seconds))
        }
        return String(seconds)
    }
}

public enum RouteConstructionError: Error, Equatable, Sendable {
    case invalidBaseURL
    case invalidPathComponent(String)
    case invalidReturnedPath
    case returnedAbsoluteURL
    case tokenBearingURL
    case invalidTrackIndex(Int)
    case invalidBookmarkTime(Double)
}

/// Builds URLs for the audited Audiobookshelf contract.
///
/// Contract sources are listed in `audiobookshelf-ios-app-spec.md`, sections
/// 15 and 24. Returned playback paths are deliberately relative to the
/// normalized server base rather than the origin so reverse-proxy prefixes are
/// retained.
public struct AudiobookshelfRouteBuilder: Sendable {
    public let server: NormalizedServerURL

    public init(server: NormalizedServerURL) {
        self.server = server
    }

    public func url(
        for route: AudiobookshelfRoute,
        queryItems: [URLQueryItem] = []
    ) throws(RouteConstructionError) -> URL {
        switch route {
        case let .directPlay(_, trackIndex) where trackIndex < 0:
            throw .invalidTrackIndex(trackIndex)
        case let .deleteBookmark(_, time) where !time.isFinite || time < 0:
            throw .invalidBookmarkTime(time)
        default:
            break
        }
        return try buildURL(
            appending: route.pathComponents,
            queryItems: queryItems
        )
    }

    public func serverRelativeContentURL(
        _ returnedPath: String
    ) throws(RouteConstructionError) -> URL {
        guard var returned = URLComponents(string: returnedPath) else {
            throw .invalidReturnedPath
        }
        guard returned.scheme == nil, returned.host == nil, returned.user == nil,
              returned.password == nil
        else {
            throw .returnedAbsoluteURL
        }
        guard returned.fragment == nil else {
            throw .invalidReturnedPath
        }
        guard returned.queryItems?.contains(where: {
            let name = $0.name.lowercased()
            return name == "token" || name == "access_token"
        }) != true else {
            throw .tokenBearingURL
        }

        let returnedPath = returned.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !returnedPath.isEmpty,
              !returnedPath.contains(where: Self.isTraversalComponent)
        else {
            throw .invalidReturnedPath
        }
        let queryItems = returned.queryItems ?? []
        returned.queryItems = nil

        return try buildURL(
            appendingPercentEncoded: returnedPath,
            queryItems: queryItems
        )
    }

    private func buildURL(
        appending components: [String],
        queryItems: [URLQueryItem]
    ) throws(RouteConstructionError) -> URL {
        let encoded = try components.map(Self.encodePathComponent)
        return try buildURL(
            appendingPercentEncoded: encoded,
            queryItems: queryItems
        )
    }

    private func buildURL(
        appendingPercentEncoded components: [String],
        queryItems: [URLQueryItem]
    ) throws(RouteConstructionError) -> URL {
        guard !Self.containsToken(queryItems) else {
            throw .tokenBearingURL
        }
        guard var result = URLComponents(
            url: server.url,
            resolvingAgainstBaseURL: false
        ) else {
            throw .invalidBaseURL
        }

        var path = result.percentEncodedPath
        for component in components {
            if !path.hasSuffix("/") {
                path.append("/")
            }
            path.append(component)
        }
        result.percentEncodedPath = path
        result.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = result.url else {
            throw .invalidBaseURL
        }
        return url
    }

    private static func encodePathComponent(
        _ component: String
    ) throws(RouteConstructionError) -> String {
        guard !component.isEmpty else {
            throw .invalidPathComponent(component)
        }
        if component == "." {
            return "%2E"
        }
        if component == ".." {
            return "%2E%2E"
        }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        guard let encoded = component.addingPercentEncoding(
            withAllowedCharacters: allowed
        ) else {
            throw .invalidPathComponent(component)
        }
        return encoded
    }

    private static func containsToken(_ queryItems: [URLQueryItem]) -> Bool {
        queryItems.contains {
            let name = $0.name.lowercased()
            return name == "token" || name == "access_token"
        }
    }

    private static func isTraversalComponent(_ component: String) -> Bool {
        guard let decoded = component.removingPercentEncoding else {
            return true
        }
        return decoded == "." || decoded == ".."
    }
}
