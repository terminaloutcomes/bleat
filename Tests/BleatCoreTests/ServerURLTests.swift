import Foundation
import XCTest

@testable import BleatCore

final class ServerURLTests: XCTestCase {
    func testCodableRoundTripRevalidatesStoredURL() throws {
        let server = try NormalizedServerURL(
            "https://Example.COM/audiobookshelf/"
        )
        let data = try JSONEncoder().encode(server)

        XCTAssertEqual(
            try JSONDecoder().decode(
                NormalizedServerURL.self,
                from: data
            ),
            server
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                NormalizedServerURL.self,
                from: Data("\"http://example.com\"".utf8)
            )
        )
    }

    func testNormalizesHostAndFinalTrailingSlash() throws {
        let server = try NormalizedServerURL(
            "  HTTPS://example.com:8443/audiobookshelf/  "
        )

        XCTAssertEqual(
            server.url.absoluteString,
            "https://example.com:8443/audiobookshelf"
        )
    }

    func testRemovesQueryAndFragment() throws {
        let server = try NormalizedServerURL(
            "https://example.com/prefix?token=discard#fragment"
        )

        XCTAssertEqual(
            server.url.absoluteString,
            "https://example.com/prefix"
        )
    }

    func testRootPathNormalizesWithoutTrailingSlash() throws {
        let server = try NormalizedServerURL("https://example.com/")

        XCTAssertEqual(server.url.absoluteString, "https://example.com")
    }

    func testRemovesOnlyOneFinalTrailingSlash() throws {
        let server = try NormalizedServerURL(
            "https://example.com/audiobookshelf//"
        )

        XCTAssertEqual(
            server.url.absoluteString,
            "https://example.com/audiobookshelf/"
        )
    }

    func testPreservesEncodedPathPrefix() throws {
        let server = try NormalizedServerURL(
            "https://example.com/audio%20books/"
        )

        XCTAssertEqual(
            server.url.absoluteString,
            "https://example.com/audio%20books"
        )
    }

    func testRejectsEmptyInput() {
        XCTAssertThrowsError(
            try NormalizedServerURL(" \n ")
        ) { error in
            XCTAssertEqual(error as? ServerURLValidationError, .empty)
        }
    }

    func testRejectsMalformedInput() {
        XCTAssertThrowsError(
            try NormalizedServerURL("https://[not-an-ipv6-address")
        ) { error in
            XCTAssertEqual(error as? ServerURLValidationError, .malformed)
        }
    }

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

    func testRejectsMissingHost() {
        assertValidationError(
            "https:///audiobookshelf",
            equals: .missingHost
        )
    }

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
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try NormalizedServerURL(input),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? ServerURLValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }
}
