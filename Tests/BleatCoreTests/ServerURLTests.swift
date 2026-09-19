import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class ServerURLTests {
    @Test
    func testCodableRoundTripRevalidatesStoredURL() throws {
        let server = try NormalizedServerURL(
            "https://Example.COM/audiobookshelf/"
        )
        let data = try JSONEncoder().encode(server)

        #expect(
            try JSONDecoder().decode(
                NormalizedServerURL.self,
                from: data
            ) == server)
        #expect(
            throws: (any Error).self,
            performing: {
                try JSONDecoder().decode(
                    NormalizedServerURL.self,
                    from: Data("\"http://example.com\"".utf8)
                )
            })
    }

    @Test
    func testNormalizesHostAndFinalTrailingSlash() throws {
        let server = try NormalizedServerURL(
            "  HTTPS://example.com:8443/audiobookshelf/  "
        )

        #expect(
            server.url.absoluteString
                == "https://example.com:8443/audiobookshelf")
    }

    @Test
    func testRemovesQueryAndFragment() throws {
        let server = try NormalizedServerURL(
            "https://example.com/prefix?token=discard#fragment"
        )

        #expect(server.url.absoluteString == "https://example.com/prefix")
    }

    @Test
    func testRootPathNormalizesWithoutTrailingSlash() throws {
        let server = try NormalizedServerURL("https://example.com/")

        #expect(server.url.absoluteString == "https://example.com")
    }

    @Test
    func testRemovesOnlyOneFinalTrailingSlash() throws {
        let server = try NormalizedServerURL(
            "https://example.com/audiobookshelf//"
        )

        #expect(
            server.url.absoluteString == "https://example.com/audiobookshelf/")
    }

    @Test
    func testPreservesEncodedPathPrefix() throws {
        let server = try NormalizedServerURL(
            "https://example.com/audio%20books/"
        )

        #expect(
            server.url.absoluteString == "https://example.com/audio%20books")
    }

    @Test
    func testRejectsEmptyInput() {
        if let error = #expect(
            throws: (any Error).self,
            performing: { try NormalizedServerURL(" \n ") })
        {
            #expect(error as? ServerURLValidationError == .empty)
        }
    }

    @Test
    func testRejectsMalformedInput() {
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try NormalizedServerURL("https://[not-an-ipv6-address")
            })
        {
            #expect(error as? ServerURLValidationError == .malformed)
        }
    }

    @Test
    func testRejectsNonHTTPSAndMissingScheme() {
        assertValidationError(
            "http://example.com",
            equals: .unsupportedScheme("http")
        )
        assertValidationError(
            "example.com",
            equals: .unsupportedScheme(nil)
        )
    }

    @Test
    func testRejectsMissingHost() {
        assertValidationError(
            "https:///audiobookshelf",
            equals: .missingHost
        )
    }

    @Test
    func testRejectsEmbeddedCredentials() {
        assertValidationError(
            "https://user@example.com",
            equals: .embeddedCredentials
        )
        assertValidationError(
            "https://user:password@example.com",
            equals: .embeddedCredentials
        )
    }

    private func assertValidationError(
        _ input: String,
        equals expected: ServerURLValidationError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        if let error = #expect(
            throws: (any Error).self, sourceLocation: sourceLocation,
            performing: { try NormalizedServerURL(input) })
        {
            #expect(
                error as? ServerURLValidationError == expected,
                sourceLocation: sourceLocation)
        }
    }
}
