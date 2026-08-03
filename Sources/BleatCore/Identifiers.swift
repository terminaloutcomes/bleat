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

/// A server-scoped author identifier. Unlike the older generic ID aliases,
/// author and series IDs are validated at every remote boundary because they
/// are used to construct server-side browse filters.
public struct AuthorID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid author identifier"
            )
        }
        self = value
    }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

public struct SeriesID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard Self.isValid(rawValue) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Invalid series identifier"
            )
        }
        self = value
    }

    private static func isValid(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

public let AppIdentifier: String = "com.yaleman.Bleat"
