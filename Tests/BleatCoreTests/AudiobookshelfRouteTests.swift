import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class AudiobookshelfRouteTests {
    private static let builder: AudiobookshelfRouteBuilder = {
        do {
            let server = try NormalizedServerURL(
                "https://example.com/audiobookshelf/"
            )
            return AudiobookshelfRouteBuilder(server: server)
        } catch {
            fatalError("Static test server URL must be valid: \(error)")
        }
    }()

    @Test
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
            #expect(
                try Self.builder.url(for: route).absoluteString
                    == "https://example.com/audiobookshelf\(path)",
                "Unexpected URL for \(route)")
        }
    }

    @Test
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

        #expect(
            Set(routes.map(\.diagnosticEndpoint))
                == Set(DiagnosticEndpoint.allCases).subtracting([.openIDSession]
                ))
        #expect(
            routes.allSatisfy {
                !$0.diagnosticEndpoint.rawValue.contains(secret)
            })
    }

    @Test
    func testPercentEncodesOpaquePathComponents() throws {
        let itemID = LibraryItemID(rawValue: "item/with space?#%")

        let url = try Self.builder.url(for: .item(itemID))

        #expect(
            url.absoluteString
                == "https://example.com/audiobookshelf/api/items/item%2Fwith%20space%3F%23%25"
        )
    }

    @Test
    func testEncodesTraversalLikeOpaqueIDWithoutChangingRoute() throws {
        let itemID = LibraryItemID(rawValue: "..")

        let url = try Self.builder.url(for: .item(itemID))

        #expect(
            url.absoluteString
                == "https://example.com/audiobookshelf/api/items/%2E%2E")
    }

    @Test
    func testEncodesSingleDotOpaqueIDWithoutChangingRoute() throws {
        let itemID = LibraryItemID(rawValue: ".")

        let url = try Self.builder.url(for: .item(itemID))

        #expect(
            url.absoluteString
                == "https://example.com/audiobookshelf/api/items/%2E")
    }

    @Test
    func testRejectsEmptyOpaquePathComponent() {
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try Self.builder.url(
                    for: .item(LibraryItemID(rawValue: ""))
                )
            })
        {
            #expect(
                error as? RouteConstructionError == .invalidPathComponent(""))
        }
    }

    @Test
    func testDoesNotAddDuplicateSlashToRetainedPrefixSlash() throws {
        let server = try NormalizedServerURL(
            "https://example.com/audiobookshelf//"
        )
        let builder = AudiobookshelfRouteBuilder(server: server)

        let url = try builder.url(for: .status)

        #expect(
            url.absoluteString == "https://example.com/audiobookshelf/status")
    }

    @Test
    func testBuildsQueryItemsWithoutDroppingPrefix() throws {
        let url = try Self.builder.url(
            for: .search(LibraryID(rawValue: "library")),
            queryItems: [
                URLQueryItem(name: "q", value: "one & two"),
                URLQueryItem(name: "limit", value: "50"),
            ]
        )

        #expect(
            url.absoluteString
                == "https://example.com/audiobookshelf/api/libraries/library/search?q=one%20%26%20two&limit=50"
        )
    }

    @Test
    func testRejectsTokenQueryItems() {
        for tokenName in ["token", "TOKEN", "access_token"] {
            if let error = #expect(
                throws: (any Error).self,
                performing: {
                    try Self.builder.url(
                        for: .status,
                        queryItems: [
                            URLQueryItem(name: tokenName, value: "secret")
                        ]
                    )
                })
            {
                #expect(error as? RouteConstructionError == .tokenBearingURL)
            }
        }
    }

    @Test
    func testAppendsReturnedHLSPathUnderServerPrefix() throws {
        let url = try Self.builder.serverRelativeContentURL(
            "/hls/session/output.m3u8"
        )

        #expect(
            url.absoluteString
                == "https://example.com/audiobookshelf/hls/session/output.m3u8")
    }

    @Test
    func testReturnedPathMayOmitLeadingSlashAndPreserveSafeQuery() throws {
        let url = try Self.builder.serverRelativeContentURL(
            "hls/session/output.m3u8?quality=high%20quality"
        )

        #expect(
            url.absoluteString
                == "https://example.com/audiobookshelf/hls/session/output.m3u8?quality=high%20quality"
        )
    }

    @Test
    func testReturnedPathPreservesEncodedSegments() throws {
        let url = try Self.builder.serverRelativeContentURL(
            "/hls/session%2Fopaque/output.m3u8"
        )

        #expect(
            url.absoluteString
                == "https://example.com/audiobookshelf/hls/session%2Fopaque/output.m3u8"
        )
    }

    @Test
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
            #expect(
                throws: (any Error).self, "Expected rejection for \(path)",
                performing: { try Self.builder.serverRelativeContentURL(path) })
        }
    }

    @Test
    func testRejectsTokenBearingReturnedPaths() {
        for path in [
            "/hls/output.m3u8?token=secret",
            "/hls/output.m3u8?ACCESS_TOKEN=secret",
        ] {
            if let error = #expect(
                throws: (any Error).self,
                performing: { try Self.builder.serverRelativeContentURL(path) })
            {
                #expect(error as? RouteConstructionError == .tokenBearingURL)
            }
        }
    }

    @Test
    func testRejectsInvalidTrackIndexAndBookmarkTime() {
        if let error = #expect(
            throws: (any Error).self,
            performing: {
                try Self.builder.url(
                    for: .directPlay(
                        sessionID: PlaybackSessionID(rawValue: "session"),
                        trackIndex: -1
                    )
                )
            })
        {
            #expect(error as? RouteConstructionError == .invalidTrackIndex(-1))
        }

        for time in [-1.0, .infinity, .nan] {
            #expect(
                throws: (any Error).self,
                performing: {
                    try Self.builder.url(
                        for: .deleteBookmark(
                            itemID: LibraryItemID(rawValue: "item"),
                            time: time
                        )
                    )
                })
        }
    }

    @Test
    func testFormatsWholeSecondBookmarkWithoutDecimalSuffix() throws {
        let url = try Self.builder.url(
            for: .deleteBookmark(
                itemID: LibraryItemID(rawValue: "item"),
                time: 12
            )
        )

        #expect(
            url.absoluteString
                == "https://example.com/audiobookshelf/api/me/item/item/bookmark/12"
        )
    }
}
