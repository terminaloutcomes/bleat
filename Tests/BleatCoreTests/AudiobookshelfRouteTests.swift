import Foundation
import XCTest

@testable import BleatCore

final class AudiobookshelfRouteTests: XCTestCase {
    private static let builder: AudiobookshelfRouteBuilder = {
        do {
            let server = try NormalizedServerURL(
                "https://example.net/audiobookshelf/"
            )
            return AudiobookshelfRouteBuilder(server: server)
        } catch {
            fatalError("Static test server URL must be valid: \(error)")
        }
    }()

    func testBuildsEveryAuditedRouteUnderServerPrefix() throws {
        let libraryID = LibraryID(rawValue: "library")
        let itemID = LibraryItemID(rawValue: "item")
        let sessionID = PlaybackSessionID(rawValue: "session")
        let routes: [(AudiobookshelfRoute, String)] = [
            (.status, "/status"),
            (.login, "/login"),
            (.beginOpenID, "/auth/openid"),
            (.completeOpenID, "/auth/openid/callback"),
            (.refresh, "/auth/refresh"),
            (.logout, "/logout"),
            (.authorize, "/api/authorize"),
            (.libraries, "/api/libraries"),
            (.libraryItems(libraryID), "/api/libraries/library/items"),
            (.personalized(libraryID), "/api/libraries/library/personalized"),
            (.search(libraryID), "/api/libraries/library/search"),
            (.item(itemID), "/api/items/item"),
            (.play(itemID), "/api/items/item/play"),
            (
                .directPlay(sessionID: sessionID, trackIndex: 4),
                "/public/session/session/track/4"
            ),
            (.syncSession(sessionID), "/api/session/session/sync"),
            (.closeSession(sessionID), "/api/session/session/close"),
            (.syncLocalSession, "/api/session/local"),
            (.syncLocalSessions, "/api/session/local-all"),
            (.progress(itemID), "/api/me/progress/item"),
            (.allProgress, "/api/me/progress"),
            (.listeningStats, "/api/me/listening-stats"),
            (.listeningSessions, "/api/me/listening-sessions"),
            (
                .itemListeningSessions(itemID),
                "/api/me/item/listening-sessions/item"
            ),
            (.yearlyStats(2026), "/api/me/stats/year/2026"),
            (.bookmarks(itemID), "/api/me/bookmarks/item"),
            (.bookmark(itemID), "/api/me/item/item/bookmark"),
            (
                .deleteBookmark(itemID: itemID, time: 12.5),
                "/api/me/item/item/bookmark/12.5"
            ),
            (
                .downloadFile(itemID: itemID, inode: "42"),
                "/api/items/item/file/42/download"
            ),
            (.cover(itemID), "/api/items/item/cover"),
            (.metadata(itemID), "/api/items/item/media"),
        ]

        for (route, path) in routes {
            XCTAssertEqual(
                try Self.builder.url(for: route).absoluteString,
                "https://example.net/audiobookshelf\(path)",
                "Unexpected URL for \(route)"
            )
        }
    }

    func testDiagnosticEndpointsDiscardEveryOpaqueRouteValue() {
        let secret = "must-not-appear"
        let libraryID = LibraryID(rawValue: secret)
        let itemID = LibraryItemID(rawValue: secret)
        let sessionID = PlaybackSessionID(rawValue: secret)
        let routes: [AudiobookshelfRoute] = [
            .status, .login, .beginOpenID, .completeOpenID, .refresh,
            .logout, .authorize, .libraries, .libraryItems(libraryID),
            .personalized(libraryID), .search(libraryID), .item(itemID),
            .play(itemID),
            .directPlay(sessionID: sessionID, trackIndex: 9),
            .syncSession(sessionID), .closeSession(sessionID),
            .syncLocalSession, .syncLocalSessions, .progress(itemID),
            .allProgress, .listeningStats, .listeningSessions,
            .itemListeningSessions(itemID), .yearlyStats(2026),
            .bookmarks(itemID), .bookmark(itemID),
            .deleteBookmark(itemID: itemID, time: 123.5),
            .downloadFile(itemID: itemID, inode: secret),
            .cover(itemID), .metadata(itemID),
        ]

        XCTAssertEqual(
            Set(routes.map(\.diagnosticEndpoint)),
            Set(DiagnosticEndpoint.allCases).subtracting([.openIDSession])
        )
        XCTAssertTrue(
            routes.allSatisfy {
                !$0.diagnosticEndpoint.rawValue.contains(secret)
            }
        )
    }

    func testPercentEncodesOpaquePathComponents() throws {
        let itemID = LibraryItemID(rawValue: "item/with space?#%")

        let url = try Self.builder.url(for: .item(itemID))

        XCTAssertEqual(
            url.absoluteString,
            "https://example.net/audiobookshelf/api/items/item%2Fwith%20space%3F%23%25"
        )
    }

    func testEncodesTraversalLikeOpaqueIDWithoutChangingRoute() throws {
        let itemID = LibraryItemID(rawValue: "..")

        let url = try Self.builder.url(for: .item(itemID))

        XCTAssertEqual(
            url.absoluteString,
            "https://example.net/audiobookshelf/api/items/%2E%2E"
        )
    }

    func testEncodesSingleDotOpaqueIDWithoutChangingRoute() throws {
        let itemID = LibraryItemID(rawValue: ".")

        let url = try Self.builder.url(for: .item(itemID))

        XCTAssertEqual(
            url.absoluteString,
            "https://example.net/audiobookshelf/api/items/%2E"
        )
    }

    func testRejectsEmptyOpaquePathComponent() {
        XCTAssertThrowsError(
            try Self.builder.url(
                for: .item(LibraryItemID(rawValue: ""))
            )
        ) { error in
            XCTAssertEqual(
                error as? RouteConstructionError,
                .invalidPathComponent("")
            )
        }
    }

    func testDoesNotAddDuplicateSlashToRetainedPrefixSlash() throws {
        let server = try NormalizedServerURL(
            "https://example.net/audiobookshelf//"
        )
        let builder = AudiobookshelfRouteBuilder(server: server)

        let url = try builder.url(for: .status)

        XCTAssertEqual(
            url.absoluteString,
            "https://example.net/audiobookshelf/status"
        )
    }

    func testBuildsQueryItemsWithoutDroppingPrefix() throws {
        let url = try Self.builder.url(
            for: .search(LibraryID(rawValue: "library")),
            queryItems: [
                URLQueryItem(name: "q", value: "one & two"),
                URLQueryItem(name: "limit", value: "50"),
            ]
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.net/audiobookshelf/api/libraries/library/search?q=one%20%26%20two&limit=50"
        )
    }

    func testRejectsTokenQueryItems() {
        for tokenName in ["token", "TOKEN", "access_token"] {
            XCTAssertThrowsError(
                try Self.builder.url(
                    for: .status,
                    queryItems: [URLQueryItem(name: tokenName, value: "secret")]
                )
            ) { error in
                XCTAssertEqual(
                    error as? RouteConstructionError,
                    .tokenBearingURL
                )
            }
        }
    }

    func testAppendsReturnedHLSPathUnderServerPrefix() throws {
        let url = try Self.builder.serverRelativeContentURL(
            "/hls/session/output.m3u8"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.net/audiobookshelf/hls/session/output.m3u8"
        )
    }

    func testReturnedPathMayOmitLeadingSlashAndPreserveSafeQuery() throws {
        let url = try Self.builder.serverRelativeContentURL(
            "hls/session/output.m3u8?quality=high%20quality"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.net/audiobookshelf/hls/session/output.m3u8?quality=high%20quality"
        )
    }

    func testReturnedPathPreservesEncodedSegments() throws {
        let url = try Self.builder.serverRelativeContentURL(
            "/hls/session%2Fopaque/output.m3u8"
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.net/audiobookshelf/hls/session%2Fopaque/output.m3u8"
        )
    }

    func testRejectsUnsafeReturnedPaths() {
        let invalidPaths = [
            "",
            "https://[",
            "https://other.example/hls/output.m3u8",
            "//other.example/hls/output.m3u8",
            "/hls/../secret",
            "/hls/%2E%2E/secret",
            "/hls/output.m3u8#fragment",
        ]

        for path in invalidPaths {
            XCTAssertThrowsError(
                try Self.builder.serverRelativeContentURL(path),
                "Expected rejection for \(path)"
            )
        }
    }

    func testRejectsTokenBearingReturnedPaths() {
        for path in [
            "/hls/output.m3u8?token=secret",
            "/hls/output.m3u8?ACCESS_TOKEN=secret",
        ] {
            XCTAssertThrowsError(
                try Self.builder.serverRelativeContentURL(path)
            ) { error in
                XCTAssertEqual(
                    error as? RouteConstructionError,
                    .tokenBearingURL
                )
            }
        }
    }

    func testRejectsInvalidTrackIndexAndBookmarkTime() {
        XCTAssertThrowsError(
            try Self.builder.url(
                for: .directPlay(
                    sessionID: PlaybackSessionID(rawValue: "session"),
                    trackIndex: -1
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? RouteConstructionError,
                .invalidTrackIndex(-1)
            )
        }

        for time in [-1.0, .infinity, .nan] {
            XCTAssertThrowsError(
                try Self.builder.url(
                    for: .deleteBookmark(
                        itemID: LibraryItemID(rawValue: "item"),
                        time: time
                    )
                )
            )
        }
    }

    func testFormatsWholeSecondBookmarkWithoutDecimalSuffix() throws {
        let url = try Self.builder.url(
            for: .deleteBookmark(
                itemID: LibraryItemID(rawValue: "item"),
                time: 12
            )
        )

        XCTAssertEqual(
            url.absoluteString,
            "https://example.net/audiobookshelf/api/me/item/item/bookmark/12"
        )
    }
}
