import Foundation
import XCTest

@testable import BleatCore

final class LiveUpdatesTests: XCTestCase {
    func testConnectionAttemptReportsEndpointRoleAndTypedFailure()
        async throws
    {
        let endpoint = AudiobookshelfLiveServerEndpoint(
            server: try NormalizedServerURL("https://example.test"),
            usage: .local
        )
        let client = AudiobookshelfLiveEventClient(
            serverProvider: {
                endpoint
            },
            tokenProvider: {
                throw AudiobookshelfLiveUpdateFailure.credentialsUnavailable
            },
            tokenRecovery: { _ in
                throw AudiobookshelfLiveUpdateFailure.credentialsUnavailable
            }
        )
        let updates = await client.updates()
        var attempts: [AudiobookshelfLiveConnectionAttempt] = []
        for await update in updates {
            guard case .connectionAttempt(let attempt) = update else {
                continue
            }
            attempts.append(attempt)
            if case .failed = attempt.phase {
                break
            }
        }
        await client.stop()

        XCTAssertEqual(attempts.count, 2)
        let started = try XCTUnwrap(attempts.first)
        let failed = try XCTUnwrap(attempts.last)
        XCTAssertEqual(started.id, failed.id)
        XCTAssertEqual(started.usage, .local)
        XCTAssertEqual(started.retryBucket, .none)
        XCTAssertEqual(started.phase, .started)
        XCTAssertEqual(failed.usage, .local)
        XCTAssertEqual(
            failed.phase,
            .failed(
                AudiobookshelfLiveConnectionFailure(
                    cause: .credentialsUnavailable,
                    stage: .credentialRetrieval
                )
            )
        )
    }

    func testSocketRequestDisallowsConstrainedNetworkAccess() throws {
        let request = try AudiobookshelfSocketCodec().socketRequest(
            for: NormalizedServerURL("https://example.test/prefix")
        )

        XCTAssertEqual(
            request.url?.absoluteString,
            "wss://example.test/prefix/socket.io/?EIO=4&transport=websocket"
        )
        XCTAssertFalse(request.allowsConstrainedNetworkAccess)
    }

    func testSocketURLPreservesRootAndServerPrefix() throws {
        let codec = AudiobookshelfSocketCodec()
        let root = try codec.socketURL(
            for: NormalizedServerURL("https://books.example")
        )
        let prefixed = try codec.socketURL(
            for: NormalizedServerURL(
                "https://books.example/audiobookshelf"
            )
        )

        XCTAssertEqual(root.scheme, "wss")
        XCTAssertTrue(root.absoluteString.contains("/socket.io/?"))
        XCTAssertTrue(
            prefixed.absoluteString.contains(
                "/audiobookshelf/socket.io/?"
            )
        )
        XCTAssertEqual(
            URLComponents(
                url: prefixed,
                resolvingAgainstBaseURL: false
            )?.queryItems,
            [
                URLQueryItem(name: "EIO", value: "4"),
                URLQueryItem(name: "transport", value: "websocket"),
            ]
        )
    }

    func testCodecDecodesLibraryItemAndProgressEvents() throws {
        let codec = AudiobookshelfSocketCodec()

        XCTAssertEqual(
            try codec.decode(
                #"42["item_updated",{"id":"item","libraryId":"library","unknown":true}]"#
            ),
            .event(.itemsChanged(
                AudiobookshelfLiveItemChange(
                    libraryIDs: [LibraryID(rawValue: "library")],
                    itemIDs: [LibraryItemID(rawValue: "item")]
                )
            ))
        )
        XCTAssertEqual(
            try codec.decode(
                #"42["user_item_progress_updated",{"sessionId":"session","deviceDescription":"Other Phone","data":{"libraryItemId":"item","duration":100,"currentTime":25,"isFinished":false,"lastUpdate":123,"unknown":true}}]"#
            ),
            .event(.playbackProgress(
                AudiobookshelfLivePlaybackProgress(
                    itemID: LibraryItemID(rawValue: "item"),
                    sessionID: PlaybackSessionID(rawValue: "session"),
                    deviceDescription: "Other Phone",
                    currentTime: 25,
                    duration: 100,
                    isFinished: false,
                    lastUpdateMilliseconds: 123
                )
            ))
        )
    }

    func testCodecHandlesProtocolPacketsAndRejectsMalformedPayloads()
        throws
    {
        let codec = AudiobookshelfSocketCodec()

        XCTAssertEqual(try codec.decode("0{}"), .engineOpen)
        XCTAssertEqual(try codec.decode("40{}"), .namespaceConnected)
        XCTAssertEqual(try codec.decode("2"), .ping(""))
        XCTAssertEqual(
            try codec.decode(#"42["init",{"userId":"user"}]"#),
            .initialized
        )
        XCTAssertEqual(
            try codec.decode(#"42["future_event",{"secret":"value"}]"#),
            .ignored
        )
        XCTAssertThrowsError(
            try codec.decode(
                #"42["item_updated",{"id":"","libraryId":"library"}]"#
            )
        ) {
            XCTAssertEqual(
                $0 as? AudiobookshelfLiveUpdateFailure,
                .malformedPacket
            )
        }
    }

    func testAuthenticationPacketKeepsTokenOutOfSocketURL() throws {
        let codec = AudiobookshelfSocketCodec()
        let url = try codec.socketURL(
            for: NormalizedServerURL("https://books.example")
        )

        XCTAssertFalse(url.absoluteString.contains("secret-token"))
        XCTAssertEqual(
            codec.authenticationPacket(accessToken: "secret-token"),
            #"42["auth","secret-token"]"#
        )
    }
}
