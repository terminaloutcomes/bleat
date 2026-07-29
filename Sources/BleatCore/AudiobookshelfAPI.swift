import Foundation

public struct APICorrelationID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AudiobookshelfAPIResult<Value: Sendable>: Sendable {
    public let value: Value
    public let correlationID: APICorrelationID

    public init(
        value: Value,
        correlationID: APICorrelationID
    ) {
        self.value = value
        self.correlationID = correlationID
    }
}

public enum LibraryMediaType: Hashable, Sendable {
    case book
    case podcast
    case unknown(String)
}

public struct LibrarySummary: Hashable, Sendable {
    public let id: LibraryID
    public let name: String
    public let mediaType: LibraryMediaType

    public init(
        id: LibraryID,
        name: String,
        mediaType: LibraryMediaType
    ) {
        self.id = id
        self.name = name
        self.mediaType = mediaType
    }
}

public enum AudiobookshelfAPIError: Error, Equatable, Sendable {
    case invalidAccountID
    case routeConstruction(RouteConstructionError)
    case authentication(AuthenticatedRequestError)
    case cancelled
    case unexpectedStatus(Int)
    case malformedResponse
    case invalidLibrary
}

public actor AudiobookshelfAPI<
    Transport: HTTPTransport,
    CredentialStore: AccountCredentialStore
> {
    private let accountID: AccountID
    private let server: NormalizedServerURL
    private let authCoordinator: AuthCoordinator<Transport, CredentialStore>
    private let decoder: JSONDecoder

    public init(
        account: ServerAccount,
        authCoordinator: AuthCoordinator<Transport, CredentialStore>
    ) {
        accountID = account.id
        server = account.server
        self.authCoordinator = authCoordinator
        decoder = JSONDecoder()
    }

    public func libraries() async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<[LibrarySummary]>
    {
        let result: AudiobookshelfAPIResult<LibrariesResponseDTO> =
            try await get(.libraries, as: LibrariesResponseDTO.self)
        let libraries: [LibrarySummary]
        do {
            libraries = try result.value.libraries.map { library in
                guard !library.id.rawValue.isEmpty,
                      !library.name.trimmingCharacters(
                          in: .whitespacesAndNewlines
                      ).isEmpty
                else {
                    throw AudiobookshelfAPIError.invalidLibrary
                }
                return LibrarySummary(
                    id: library.id,
                    name: library.name,
                    mediaType: library.mediaType.domainValue
                )
            }
        } catch let error as AudiobookshelfAPIError {
            throw error
        } catch {
            throw .invalidLibrary
        }
        return AudiobookshelfAPIResult(
            value: libraries,
            correlationID: result.correlationID
        )
    }

    private func get<Response: Decodable & Sendable>(
        _ route: AudiobookshelfRoute,
        queryItems: [URLQueryItem] = [],
        as responseType: Response.Type
    ) async throws(AudiobookshelfAPIError)
        -> AudiobookshelfAPIResult<Response>
    {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        let url: URL
        do {
            url = try AudiobookshelfRouteBuilder(server: server).url(
                for: route,
                queryItems: queryItems
            )
        } catch let error {
            throw .routeConstruction(error)
        }

        let correlationID = APICorrelationID()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(
            correlationID.rawValue.uuidString.lowercased(),
            forHTTPHeaderField: "X-Bleat-Request-ID"
        )

        let response: HTTPResponse
        do {
            response = try await authCoordinator.sendAuthenticated(
                request,
                route: route,
                accountID: accountID,
                server: server
            )
        } catch let error as AuthenticatedRequestError {
            if error == .requestCancelled {
                throw .cancelled
            }
            throw .authentication(error)
        } catch {
            if Task.isCancelled {
                throw .cancelled
            }
            throw .authentication(.requestTransportFailed)
        }
        guard !Task.isCancelled else {
            throw .cancelled
        }
        guard (200 ..< 300).contains(response.statusCode) else {
            throw .unexpectedStatus(response.statusCode)
        }

        let value: Response
        do {
            value = try decoder.decode(responseType, from: response.data)
        } catch {
            throw .malformedResponse
        }
        return AudiobookshelfAPIResult(
            value: value,
            correlationID: correlationID
        )
    }
}

private struct LibrariesResponseDTO: Decodable, Sendable {
    let libraries: [LibraryDTO]
}

private struct LibraryDTO: Decodable, Sendable {
    let id: LibraryID
    let name: String
    let mediaType: LibraryMediaTypeDTO
}

private enum LibraryMediaTypeDTO: Decodable, Sendable {
    case book
    case podcast
    case unknown(String)

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "book":
            self = .book
        case "podcast":
            self = .podcast
        default:
            self = .unknown(value)
        }
    }

    var domainValue: LibraryMediaType {
        switch self {
        case .book:
            .book
        case .podcast:
            .podcast
        case let .unknown(value):
            .unknown(value)
        }
    }
}
