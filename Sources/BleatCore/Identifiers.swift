import Foundation

/// A remote or local identifier tagged with its domain at compile time.
public struct TypedID<Kind>: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension TypedID: CustomStringConvertible {
    public var description: String {
        rawValue
    }
}

public enum AccountIDKind: Sendable {}
public enum UserIDKind: Sendable {}
public enum LibraryIDKind: Sendable {}
public enum LibraryItemIDKind: Sendable {}
public enum BookIDKind: Sendable {}
public enum PlaybackSessionIDKind: Sendable {}
public enum DownloadIDKind: Sendable {}
public enum ChapterIDKind: Sendable {}

public typealias AccountID = TypedID<AccountIDKind>
public typealias UserID = TypedID<UserIDKind>
public typealias LibraryID = TypedID<LibraryIDKind>
public typealias LibraryItemID = TypedID<LibraryItemIDKind>
public typealias BookID = TypedID<BookIDKind>
public typealias PlaybackSessionID = TypedID<PlaybackSessionIDKind>
public typealias DownloadID = TypedID<DownloadIDKind>
public typealias ChapterID = TypedID<ChapterIDKind>

public let AppIdentifier: String = "com.yaleman.Bleat"
