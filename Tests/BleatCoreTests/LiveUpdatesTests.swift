import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class LiveUpdatesTests {
    @Test
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

        #expect(attempts.count == 2)
        let started = try #require(attempts.first)
        let failed = try #require(attempts.last)
        #expect(started.id == failed.id)
        #expect(started.usage == .local)
        #expect(started.retryBucket == .none)
        #expect(started.phase == .started)
        #expect(failed.usage == .local)
        #expect(
            failed.phase
                == .failed(
                    AudiobookshelfLiveConnectionFailure(
                        cause: .credentialsUnavailable,
                        stage: .credentialRetrieval
                    )
                ))
    }

    @Test
    func testSocketRequestDisallowsConstrainedNetworkAccess() throws {
        let request = try AudiobookshelfSocketCodec().socketRequest(
            for: NormalizedServerURL("https://example.test/prefix")
        )

        #expect(
            request.url?.absoluteString
                == "wss://example.test/prefix/socket.io/?EIO=4&transport=websocket"
        )
        #expect(!(request.allowsConstrainedNetworkAccess))
    }

    @Test
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

        #expect(root.scheme == "wss")
        #expect(root.absoluteString.contains("/socket.io/?"))
        #expect(
            prefixed.absoluteString.contains(
                "/audiobookshelf/socket.io/?"
            ))
        #expect(
            URLComponents(
                url: prefixed,
                resolvingAgainstBaseURL: false
            )?.queryItems == [
                URLQueryItem(name: "EIO", value: "4"),
                URLQueryItem(name: "transport", value: "websocket"),
            ])
    }

    @Test
    func testCodecDecodesLibraryItemAndProgressEvents() throws {
        let codec = AudiobookshelfSocketCodec()

        #expect(
            try codec.decode(
                #"42["item_updated",{"id":"item","libraryId":"library","unknown":true}]"#
            )
                == .event(
                    .itemsChanged(
                        AudiobookshelfLiveItemChange(
                            libraryIDs: [LibraryID(rawValue: "library")],
                            itemIDs: [LibraryItemID(rawValue: "item")]
                        )
                    )))
        #expect(
            try codec.decode(
                #"42["user_item_progress_updated",{"sessionId":"session","deviceDescription":"Other Phone","data":{"libraryItemId":"item","duration":100,"currentTime":25,"isFinished":false,"lastUpdate":123,"unknown":true}}]"#
            )
                == .event(
                    .playbackProgress(
                        AudiobookshelfLivePlaybackProgress(
                            itemID: LibraryItemID(rawValue: "item"),
                            sessionID: PlaybackSessionID(rawValue: "session"),
                            deviceDescription: "Other Phone",
                            currentTime: 25,
                            duration: 100,
                            isFinished: false,
                            lastUpdateMilliseconds: 123
                        )
                    )))
    }

    @Test
    func testCodecHandlesProtocolPacketsAndRejectsMalformedPayloads()
        throws
    {
        let codec = AudiobookshelfSocketCodec()

        #expect(try codec.decode("0{}") == .engineOpen)
        #expect(try codec.decode("40{}") == .namespaceConnected)
        #expect(try codec.decode("2") == .ping(""))
        #expect(
            try codec.decode(#"42["init",{"userId":"user"}]"#) == .initialized)
        #expect(
            try codec.decode(#"42["future_event",{"secret":"value"}]"#)
                == .ignored)
        if let caughtError = #expect(
            throws: (any Error).self,
            performing: {
                try codec.decode(
                    #"42["item_updated",{"id":"","libraryId":"library"}]"#
                )
            })
        {
            #expect(
                caughtError as? AudiobookshelfLiveUpdateFailure
                    == .malformedPacket)
        }
    }

    @Test
    func testAuthenticationPacketKeepsTokenOutOfSocketURL() throws {
        let codec = AudiobookshelfSocketCodec()
        let url = try codec.socketURL(
            for: NormalizedServerURL("https://books.example")
        )

        #expect(!(url.absoluteString.contains("secret-token")))
        #expect(
            codec.authenticationPacket(accessToken: "secret-token")
                == #"42["auth","secret-token"]"#)
    }
}
