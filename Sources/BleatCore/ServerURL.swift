import Foundation

public enum ServerURLValidationError: Error, Equatable, Sendable {
    case empty
    case malformed
    case unsupportedScheme(String?)
    case missingHost
    case embeddedCredentials
}

public struct NormalizedServerURL: Hashable, Sendable {
    public let url: URL

    public init(_ input: String) throws(ServerURLValidationError) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw .empty
        }

        guard var components = URLComponents(string: trimmed) else {
            throw .malformed
        }
        guard components.scheme?.lowercased() == "https" else {
            throw .unsupportedScheme(components.scheme)
        }
        guard components.host?.isEmpty == false else {
            throw .missingHost
        }
        guard components.user == nil, components.password == nil else {
            throw .embeddedCredentials
        }

        components.scheme = "https"
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil

        if components.percentEncodedPath.count > 1,
            components.percentEncodedPath.hasSuffix("/")
        {
            components.percentEncodedPath.removeLast()
        }
        if components.percentEncodedPath == "/" {
            components.percentEncodedPath = ""
        }

        guard let normalizedURL = components.url else {
            throw .malformed
        }
        url = normalizedURL
    }
}

extension NormalizedServerURL: Codable {
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Stored server URL is not a valid normalized HTTPS URL"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }
}
