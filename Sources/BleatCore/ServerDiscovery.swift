import Foundation

public enum AuthenticationMethod: Hashable, Sendable {
    case local
    case openID
    case unknown(String)

    public var rawValue: String {
        switch self {
        case .local:
            "local"
        case .openID:
            "openid"
        case let .unknown(value):
            value
        }
    }
}

extension AuthenticationMethod: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "local":
            self = .local
        case "openid":
            self = .openID
        default:
            self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AuthenticationFormData: Codable, Hashable, Sendable {
    public let openIDButtonText: String?
    public let openIDAutoLaunch: Bool?
    public let loginCustomMessage: String?

    enum CodingKeys: String, CodingKey {
        case openIDButtonText = "authOpenIDButtonText"
        case openIDAutoLaunch = "authOpenIDAutoLaunch"
        case loginCustomMessage = "authLoginCustomMessage"
    }
}

/// The response returned by Audiobookshelf's unauthenticated `GET /status`.
///
/// Contract source:
/// https://github.com/advplyr/audiobookshelf/blob/96d4021a3cd45f67bf374b65abafbe5d73e926b5/server/Server.js
public struct ServerStatusResponse: Decodable, Hashable, Sendable {
    public let app: String
    public let serverVersion: String
    public let isInitialized: Bool
    public let language: String
    public let authenticationMethods: [AuthenticationMethod]
    public let authenticationFormData: AuthenticationFormData?

    enum CodingKeys: String, CodingKey {
        case app
        case serverVersion
        case isInitialized = "isInit"
        case language
        case authenticationMethods = "authMethods"
        case authenticationFormData = "authFormData"
    }
}

public struct AudiobookshelfServerVersion:
    Comparable,
    CustomStringConvertible,
    Hashable,
    Sendable
{
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let original: String

    fileprivate init(
        major: Int,
        minor: Int,
        patch: Int,
        original: String
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.original = original
    }

    public init?(_ value: String) {
        let numericVersion = value.split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: true
        ).first
        guard let numericVersion else {
            return nil
        }

        let components = numericVersion.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              let major = Int(components[0]),
              let minor = Int(components[1]),
              let patch = Int(components[2]),
              major >= 0,
              minor >= 0,
              patch >= 0
        else {
            return nil
        }

        self.init(
            major: major,
            minor: minor,
            patch: patch,
            original: value
        )
    }

    public static func < (
        lhs: AudiobookshelfServerVersion,
        rhs: AudiobookshelfServerVersion
    ) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String {
        original
    }

    public static let minimumSupported = AudiobookshelfServerVersion(
        major: 2,
        minor: 26,
        patch: 0,
        original: "2.26.0"
    )
}

public struct DiscoveredServer: Hashable, Sendable {
    public let baseURL: NormalizedServerURL
    public let version: AudiobookshelfServerVersion
    public let language: String
    public let authenticationMethods: [AuthenticationMethod]
    public let authenticationFormData: AuthenticationFormData?

    public init(
        baseURL: NormalizedServerURL,
        version: AudiobookshelfServerVersion,
        language: String,
        authenticationMethods: [AuthenticationMethod],
        authenticationFormData: AuthenticationFormData?
    ) {
        self.baseURL = baseURL
        self.version = version
        self.language = language
        self.authenticationMethods = authenticationMethods
        self.authenticationFormData = authenticationFormData
    }
}

public enum ServerDiscoveryError: Error, Equatable, Sendable {
    case redirectMissingLocation
    case redirectRequiresConfirmation(URL)
    case tooManyRedirects
    case invalidRedirect(URL)
    case unexpectedHTTPStatus(Int)
    case malformedResponse
    case wrongApplication(String)
    case uninitialized
    case invalidServerVersion(String)
    case unsupportedServerVersion(String)
}

public struct ServerDiscoveryClient<Transport: HTTPTransport>: Sendable {
    private let transport: Transport
    private let decoder: JSONDecoder

    public init(transport: Transport) {
        self.transport = transport
        decoder = JSONDecoder()
    }

    public func discover(
        _ server: NormalizedServerURL
    ) async throws -> DiscoveredServer {
        let initialStatusURL = try AudiobookshelfRouteBuilder(server: server)
            .url(for: .status)
        let (response, resolvedStatusURL) = try await fetchStatus(
            at: initialStatusURL,
            remainingRedirects: 1
        )

        guard response.statusCode == 200 else {
            throw ServerDiscoveryError.unexpectedHTTPStatus(
                response.statusCode
            )
        }

        let status: ServerStatusResponse
        do {
            status = try decoder.decode(
                ServerStatusResponse.self,
                from: response.data
            )
        } catch {
            throw ServerDiscoveryError.malformedResponse
        }

        guard status.app == "audiobookshelf" else {
            throw ServerDiscoveryError.wrongApplication(status.app)
        }
        guard status.isInitialized else {
            throw ServerDiscoveryError.uninitialized
        }
        guard let version = AudiobookshelfServerVersion(
            status.serverVersion
        ) else {
            throw ServerDiscoveryError.invalidServerVersion(
                status.serverVersion
            )
        }
        guard version >= AudiobookshelfServerVersion.minimumSupported else {
            throw ServerDiscoveryError.unsupportedServerVersion(
                status.serverVersion
            )
        }

        let resolvedBaseURL = resolvedStatusURL.deletingLastPathComponent()
        let normalizedBaseURL: NormalizedServerURL
        do {
            normalizedBaseURL = try NormalizedServerURL(
                resolvedBaseURL.absoluteString
            )
        } catch {
            throw ServerDiscoveryError.invalidRedirect(resolvedStatusURL)
        }

        return DiscoveredServer(
            baseURL: normalizedBaseURL,
            version: version,
            language: status.language,
            authenticationMethods: status.authenticationMethods,
            authenticationFormData: status.authenticationFormData
        )
    }

    private func fetchStatus(
        at url: URL,
        remainingRedirects: Int
    ) async throws -> (HTTPResponse, URL) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15

        let response = try await transport.send(
            TracedHTTPRequest(
                request: request,
                endpoint: .status
            )
        )
        guard Self.isRedirect(response.statusCode) else {
            return (response, response.url ?? url)
        }
        guard remainingRedirects > 0 else {
            throw ServerDiscoveryError.tooManyRedirects
        }
        guard let location = response.header(named: "Location"),
              let redirectURL = URL(string: location, relativeTo: url)?.absoluteURL
        else {
            throw ServerDiscoveryError.redirectMissingLocation
        }
        guard redirectURL.user == nil, redirectURL.password == nil,
              redirectURL.scheme?.lowercased() == "https",
              redirectURL.host != nil
        else {
            throw ServerDiscoveryError.invalidRedirect(redirectURL)
        }
        guard Self.hasSameOrigin(url, redirectURL) else {
            throw ServerDiscoveryError.redirectRequiresConfirmation(
                redirectURL
            )
        }

        return try await fetchStatus(
            at: redirectURL,
            remainingRedirects: remainingRedirects - 1
        )
    }

    private static func isRedirect(_ statusCode: Int) -> Bool {
        [301, 302, 303, 307, 308].contains(statusCode)
    }

    private static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? 443
    }
}
