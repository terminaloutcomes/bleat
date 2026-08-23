import Foundation

public struct DownloadByteRange: Codable, Equatable, Sendable {
    public let start: Int64
    public let endInclusive: Int64

    public init(start: Int64, endInclusive: Int64) throws {
        guard start >= 0, endInclusive >= start else {
            throw DownloadRangeError.invalidRange
        }
        self.start = start
        self.endInclusive = endInclusive
    }

    public var length: Int64 {
        endInclusive - start + 1
    }

    public static func next(
        committedByteLength: Int64,
        expectedByteLength: Int64,
        chunkByteLength: Int64
    ) throws -> DownloadByteRange? {
        guard committedByteLength >= 0,
            expectedByteLength >= 0,
            committedByteLength <= expectedByteLength,
            chunkByteLength > 0
        else {
            throw DownloadRangeError.invalidRange
        }
        guard committedByteLength < expectedByteLength else {
            return nil
        }
        let remaining = expectedByteLength - committedByteLength
        return try DownloadByteRange(
            start: committedByteLength,
            endInclusive: committedByteLength + min(remaining, chunkByteLength)
                - 1
        )
    }
}

public enum DownloadValidator: Codable, Equatable, Sendable {
    case strongETag(String)
    case lastModified(String)

    public var headerValue: String {
        switch self {
        case .strongETag(let value), .lastModified(let value): value
        }
    }
}

public struct DownloadContentRange: Equatable, Sendable {
    public let start: Int64
    public let endInclusive: Int64
    public let totalByteLength: Int64

    public init?(headerValue: String) {
        let parts = headerValue.split(
            separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bytes" else {
            return nil
        }
        let rangeAndTotal = parts[1].split(
            separator: "/", omittingEmptySubsequences: false)
        guard rangeAndTotal.count == 2,
            let total = Int64(rangeAndTotal[1]),
            total >= 0
        else {
            return nil
        }
        let bounds = rangeAndTotal[0].split(
            separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
            let start = Int64(bounds[0]),
            let end = Int64(bounds[1]),
            start >= 0,
            end >= start,
            end < total
        else {
            return nil
        }
        self.start = start
        endInclusive = end
        totalByteLength = total
    }
}

public enum DownloadRangeError: Error, Equatable, Sendable {
    case invalidRange
    case unexpectedStatus(Int)
    case missingOrInvalidContentRange
    case mismatchedContentRange
    case mismatchedTotalByteLength
}

public struct DownloadChunkTaskDescription: Codable, Equatable, Sendable {
    public static let prefix = "bleat-download-chunk-v1:"

    public let identity: DownloadTaskIdentity
    public let range: DownloadByteRange
    public let validator: DownloadValidator?

    public init(
        identity: DownloadTaskIdentity,
        range: DownloadByteRange,
        validator: DownloadValidator?
    ) {
        self.identity = identity
        self.range = range
        self.validator = validator
    }

    public func encode() throws -> String {
        let data = try JSONEncoder().encode(self)
        return Self.prefix + data.base64EncodedString()
    }

    public static func decode(_ value: String) throws -> Self {
        guard value.hasPrefix(prefix),
            let data = Data(
                base64Encoded: String(value.dropFirst(prefix.count)))
        else {
            throw DownloadRangeError.invalidRange
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}

public enum DownloadRangeResponseValidator {
    public static func validate(
        statusCode: Int,
        contentRangeHeader: String?,
        requestedRange: DownloadByteRange,
        expectedTotalByteLength: Int64
    ) throws(DownloadRangeError) {
        guard statusCode == 206 else {
            throw .unexpectedStatus(statusCode)
        }
        guard let contentRangeHeader,
            let contentRange = DownloadContentRange(
                headerValue: contentRangeHeader)
        else {
            throw .missingOrInvalidContentRange
        }
        guard contentRange.start == requestedRange.start,
            contentRange.endInclusive == requestedRange.endInclusive
        else {
            throw .mismatchedContentRange
        }
        guard contentRange.totalByteLength == expectedTotalByteLength else {
            throw .mismatchedTotalByteLength
        }
    }

    public static func validator(
        etag: String?,
        lastModified: String?
    ) -> DownloadValidator? {
        if let etag,
            !etag.hasPrefix("W/"),
            !etag.isEmpty
        {
            return .strongETag(etag)
        }
        if let lastModified, !lastModified.isEmpty {
            return .lastModified(lastModified)
        }
        return nil
    }
}

public enum DownloadRangeRequest {
    public static func applying(
        range: DownloadByteRange,
        validator: DownloadValidator?,
        to request: URLRequest
    ) -> URLRequest {
        var request = request
        request.setValue(
            "bytes=\(range.start)-\(range.endInclusive)",
            forHTTPHeaderField: "Range"
        )
        if let validator {
            request.setValue(
                validator.headerValue,
                forHTTPHeaderField: "If-Range"
            )
        } else {
            request.setValue(nil, forHTTPHeaderField: "If-Range")
        }
        return request
    }
}
