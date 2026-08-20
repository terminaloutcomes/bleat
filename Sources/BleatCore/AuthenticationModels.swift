import Foundation

public enum AudiobookshelfUserType: Hashable, Sendable {
    case root
    case admin
    case user
    case guest
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .root:
            "root"
        case .admin:
            "admin"
        case .user:
            "user"
        case .guest:
            "guest"
        case .unknown(let value):
            value
        }
    }
}

extension AudiobookshelfUserType: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "root":
            self = .root
        case "admin":
            self = .admin
        case "user":
            self = .user
        case "guest":
            self = .guest
        default:
            self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Permission fields returned by the pinned Audiobookshelf user serializer.
///
/// Contract source:
/// https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/models/User.js
public struct UserPermissions: Codable, Hashable, Sendable {
    public let download: Bool
    public let update: Bool
    public let delete: Bool
    public let upload: Bool
    public let createEReader: Bool
    public let accessAllLibraries: Bool
    public let accessAllTags: Bool
    public let accessExplicitContent: Bool
    public let selectedTagsNotAccessible: Bool

    public init(
        download: Bool,
        update: Bool,
        delete: Bool,
        upload: Bool,
        createEReader: Bool,
        accessAllLibraries: Bool,
        accessAllTags: Bool,
        accessExplicitContent: Bool,
        selectedTagsNotAccessible: Bool
    ) {
        self.download = download
        self.update = update
        self.delete = delete
        self.upload = upload
        self.createEReader = createEReader
        self.accessAllLibraries = accessAllLibraries
        self.accessAllTags = accessAllTags
        self.accessExplicitContent = accessExplicitContent
        self.selectedTagsNotAccessible = selectedTagsNotAccessible
    }

    enum CodingKeys: String, CodingKey {
        case download
        case update
        case delete
        case upload
        case createEReader = "createEreader"
        case accessAllLibraries
        case accessAllTags
        case accessExplicitContent
        case selectedTagsNotAccessible
    }

    /// Decodes permissions tolerantly: any key that is absent defaults to
    /// `false` rather than failing the decode.
    ///
    /// Audiobookshelf introduces permission fields additively and does not
    /// backfill existing users' stored permission blobs — for example
    /// `createEreader`, added in advplyr/audiobookshelf#3531 with no
    /// migration. The server serialises permissions as-stored, so an account
    /// created before a permission existed arrives without that key. Decoding
    /// every field as required would abort the entire login payload for such
    /// accounts; defaulting a missing permission to "not granted" is both
    /// safe and forward-compatible with permissions added in the future.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func flag(_ key: CodingKeys) throws -> Bool {
            try container.decodeIfPresent(Bool.self, forKey: key) ?? false
        }
        self.download = try flag(.download)
        self.update = try flag(.update)
        self.delete = try flag(.delete)
        self.upload = try flag(.upload)
        self.createEReader = try flag(.createEReader)
        self.accessAllLibraries = try flag(.accessAllLibraries)
        self.accessAllTags = try flag(.accessAllTags)
        self.accessExplicitContent = try flag(.accessExplicitContent)
        self.selectedTagsNotAccessible = try flag(.selectedTagsNotAccessible)
    }
}

public struct AuthenticatedUser: Codable, Hashable, Sendable {
    public let id: UserID
    public let username: String
    public let type: AudiobookshelfUserType
    public let permissions: UserPermissions
    public let accessibleLibraryIDs: [LibraryID]
    public let selectedItemTags: [String]

    public init(
        id: UserID,
        username: String,
        type: AudiobookshelfUserType,
        permissions: UserPermissions,
        accessibleLibraryIDs: [LibraryID],
        selectedItemTags: [String]
    ) {
        self.id = id
        self.username = username
        self.type = type
        self.permissions = permissions
        self.accessibleLibraryIDs = accessibleLibraryIDs
        self.selectedItemTags = selectedItemTags
    }

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case type
        case permissions
        case accessibleLibraryIDs = "librariesAccessible"
        case selectedItemTags = "itemTagsSelected"
    }
}

public struct AuthenticationTokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String

    public init(
        accessToken: String,
        refreshToken: String
    ) throws(AuthenticationTokenError) {
        guard Self.isValid(accessToken) else {
            throw .invalidAccessToken
        }
        guard Self.isValid(refreshToken) else {
            throw .invalidRefreshToken
        }

        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accessToken = try container.decode(
            String.self,
            forKey: .accessToken
        )
        let refreshToken = try container.decode(
            String.self,
            forKey: .refreshToken
        )

        do {
            try self.init(
                accessToken: accessToken,
                refreshToken: refreshToken
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Stored authentication tokens are invalid"
                )
            )
        }
    }

    private static func isValid(_ token: String) -> Bool {
        !token.isEmpty
            && token.rangeOfCharacter(
                from: .whitespacesAndNewlines.union(.controlCharacters)
            ) == nil
    }
}

public enum AuthenticationTokenError: Error, Equatable, Sendable {
    case invalidAccessToken
    case invalidRefreshToken
}

public struct NativeLoginCredentials: Codable, Equatable, Sendable {
    public let userID: UserID
    public let username: String
    public let password: String

    public init(
        userID: UserID,
        username: String,
        password: String
    ) throws(NativeLoginCredentialError) {
        guard !userID.rawValue.isEmpty else {
            throw .invalidUserID
        }
        guard !username.isEmpty,
            username.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            throw .invalidUsername
        }
        guard !password.isEmpty else {
            throw .invalidPassword
        }
        self.userID = userID
        self.username = username
        self.password = password
    }
}

public enum NativeLoginCredentialError: Error, Equatable, Sendable {
    case invalidUserID
    case invalidUsername
    case invalidPassword
}

public struct AuthenticatedAccount: Hashable, Sendable {
    public let id: AccountID
    public let server: NormalizedServerURL
    public let user: AuthenticatedUser

    public init(
        id: AccountID,
        server: NormalizedServerURL,
        user: AuthenticatedUser
    ) {
        self.id = id
        self.server = server
        self.user = user
    }
}

public protocol AccountCredentialStore: Sendable {
    func credentials(
        for accountID: AccountID
    ) async throws -> AuthenticationTokens?

    func save(
        _ credentials: AuthenticationTokens,
        for accountID: AccountID
    ) async throws

    func save(
        _ credentials: AuthenticationTokens,
        nativeLogin: NativeLoginCredentials,
        for accountID: AccountID
    ) async throws

    func nativeLoginCredentials(
        for accountID: AccountID
    ) async throws -> NativeLoginCredentials?

    func deleteCredentials(for accountID: AccountID) async throws

    func deleteSessionCredentials(for accountID: AccountID) async throws
}

extension AccountCredentialStore {
    public func save(
        _ credentials: AuthenticationTokens,
        nativeLogin: NativeLoginCredentials,
        for accountID: AccountID
    ) async throws {
        try await save(credentials, for: accountID)
    }

    public func deleteSessionCredentials(
        for accountID: AccountID
    ) async throws {
        try await deleteCredentials(for: accountID)
    }

    public func nativeLoginCredentials(
        for accountID: AccountID
    ) async throws -> NativeLoginCredentials? {
        nil
    }
}
