import Foundation
import Testing

@testable import BleatCore

@Suite(.serialized)
final class LiveUpdatesTests {
    @Test
    func testUnchangedEndpointPreservesPendingConnection() async throws {
        let primary = try NormalizedServerURL("https://example.test/primary")
        let local = try NormalizedServerURL("https://example.test/prefix")
        let router = ServerEndpointRouter()
        await router.configure(primary: primary, local: local)
        let initial = await router.preferredServer(for: primary)
        let endpoint = AudiobookshelfLiveServerEndpoint(
            server: local, usage: .local, pathGeneration: initial.pathGeneration
        )
        let gate = LiveCredentialGate()
        let client = AudiobookshelfLiveEventClient(
            serverProvider: { endpoint },
            tokenProvider: { try await gate.retrieve() },
            tokenRecovery: { _ in throw CancellationError() })
        let stream = await client.updates()
        let drain = Task { for await _ in stream {} }
        var entries = gate.entries.makeAsyncIterator()
        #expect(await entries.next() == true)
        for _ in 0..<100 {
            #expect(
                await client.reconnectIfNeeded(
                    endpoint: endpoint, routingChanged: false) == false)
        }
        let generation = await router.networkPathDidChange()
        await router.markLocalAvailable(
            for: primary, pathGeneration: generation)
        await router.finishNetworkPathEvaluation(generation)
        let preserved = AudiobookshelfLiveServerEndpoint(
            server: local, usage: .local, pathGeneration: generation)
        #expect(
            await client.reconnectIfNeeded(
                endpoint: preserved, routingChanged: false) == false)
        let current = try #require(await client.connectionEndpoint)
        #expect(current.pathGeneration == generation)
        #expect(current.pathGeneration != initial.pathGeneration)
        await router.markLocalUnavailable(
            ServerEndpointCandidate(
                url: current.server.url, primary: primary, isLocal: true,
                pathGeneration: generation))
        #expect(await router.preferredServer(for: primary).usage == .primary)
        await client.stop()
        await gate.fail()
        await drain.value
    }

    @Test
    func
        testRouteOrEndpointChangeRetiresPendingCredentialsAndStopSuppressesRestart()
        async throws
    {
        for routingChanged in [true, false] {
            let endpoint = AudiobookshelfLiveServerEndpoint(
                server: try NormalizedServerURL("https://example.test/local"),
                usage: .local)
            let replacement = try NormalizedServerURL(
                "https://example.test/primary")
            let gate = LiveCredentialGate()
            let client = AudiobookshelfLiveEventClient(
                serverProvider: { endpoint },
                tokenProvider: { try await gate.retrieve() },
                tokenRecovery: { _ in throw CancellationError() })
            let stream = await client.updates()
            let cancelled = Task { () -> Bool in
                for await update in stream {
                    if case .connectionAttempt(let attempt) = update,
                        attempt.phase == .cancelled
                    {
                        return true
                    }
                }
                return false
            }
            var entries = gate.entries.makeAsyncIterator()
            #expect(await entries.next() == true)
            #expect(
                await client.reconnectIfNeeded(
                    endpoint: routingChanged
                        ? endpoint
                        : AudiobookshelfLiveServerEndpoint(
                            server: replacement, usage: .primary),
                    routingChanged: routingChanged))
            await gate.succeed()
            #expect(await cancelled.value)
            await client.stop()
            #expect(
                await client.reconnectIfNeeded(
                    endpoint: AudiobookshelfLiveServerEndpoint(
                        server: replacement, usage: .primary),
                    routingChanged: true) == false)
        }
    }

    @Test
    func testRetiredStreamTerminationCannotStopReplacement() async throws {
        let endpoint = AudiobookshelfLiveServerEndpoint(
            server: try NormalizedServerURL("https://example.test"),
            usage: .local)
        let gate = LiveServerProviderGate(endpoint: endpoint)
        let client = AudiobookshelfLiveEventClient(
            serverProvider: { await gate.next() },
            tokenProvider: {
                throw AudiobookshelfLiveUpdateFailure.credentialsUnavailable
            },
            tokenRecovery: { _ in
                throw AudiobookshelfLiveUpdateFailure.credentialsUnavailable
            })
        var entries = gate.entries.makeAsyncIterator()
        let old = await client.updates()
        let drainOld = Task { for await _ in old {} }
        #expect(await entries.next() == 1)
        let replacement = await client.updates()
        #expect(await entries.next() == 2)
        await gate.release(1)
        await drainOld.value
        await gate.release(2)
        let receivedFailure = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await update in replacement {
                    if case .connection(.failed(.credentialsUnavailable)) =
                        update
                    {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        await client.stop()
        #expect(receivedFailure)
    }

    @Test
    func testStopWhileRestoringEndpointDoesNotRetrieveCredentials() async throws
    {
        let endpoint = AudiobookshelfLiveServerEndpoint(
            server: try NormalizedServerURL("https://example.test"),
            usage: .local)
        let gate = LiveServerProviderGate(endpoint: endpoint)
        let credentials = LiveCredentialProbe()
        let client = AudiobookshelfLiveEventClient(
            serverProvider: { await gate.next() },
            tokenProvider: {
                await credentials.called()
                throw AudiobookshelfLiveUpdateFailure.credentialsUnavailable
            },
            tokenRecovery: { _ in
                throw AudiobookshelfLiveUpdateFailure.credentialsUnavailable
            })
        var entries = gate.entries.makeAsyncIterator()
        let updates = await client.updates()
        let drain = Task { for await _ in updates {} }
        #expect(await entries.next() == 1)
        await client.stop()
        await gate.release(1)
        await drain.value
        #expect(await credentials.count == 0)
    }

    @Test
    func
        testStopDuringCredentialRetrievalReportsCancellationWithoutOpeningSocket()
        async throws
    {
        let endpoint = AudiobookshelfLiveServerEndpoint(
            server: try NormalizedServerURL("https://example.test"),
            usage: .local)
        let gate = LiveCredentialGate()
        let client = AudiobookshelfLiveEventClient(
            serverProvider: { endpoint },
            tokenProvider: { try await gate.retrieve() },
            tokenRecovery: { _ in
                throw AudiobookshelfLiveUpdateFailure.credentialsUnavailable
            })
        let stream = await client.updates()
        let drain = Task { () -> [AudiobookshelfLiveUpdate] in
            var updates: [AudiobookshelfLiveUpdate] = []
            for await update in stream { updates.append(update) }
            return updates
        }
        var entries = gate.entries.makeAsyncIterator()
        #expect(await entries.next() == true)
        await client.stop()
        await gate.fail()
        let updates = await drain.value
        #expect(
            updates.contains {
                if case .connectionAttempt(let attempt) = $0 {
                    return attempt.phase == .cancelled
                }
                return false
            })
        #expect(
            !updates.contains {
                if case .connection(.failed) = $0 { return true }
                return false
            })
    }

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

private actor LiveServerProviderGate {
    nonisolated let entries: AsyncStream<Int>
    private let entryContinuation: AsyncStream<Int>.Continuation
    private let endpoint: AudiobookshelfLiveServerEndpoint
    private var count = 0
    private var waiters:
        [Int: CheckedContinuation<AudiobookshelfLiveServerEndpoint, Never>] =
            [:]

    init(endpoint: AudiobookshelfLiveServerEndpoint) {
        let stream = AsyncStream<Int>.makeStream()
        entries = stream.stream
        entryContinuation = stream.continuation
        self.endpoint = endpoint
    }

    func next() async -> AudiobookshelfLiveServerEndpoint {
        count += 1
        let id = count
        return await withCheckedContinuation {
            waiters[id] = $0
            entryContinuation.yield(id)
        }
    }

    func release(_ id: Int) {
        waiters.removeValue(forKey: id)?.resume(returning: endpoint)
    }
}

private actor LiveCredentialProbe {
    var count = 0
    func called() { count += 1 }
}

private actor LiveCredentialGate {
    nonisolated let entries: AsyncStream<Bool>
    private let entryContinuation: AsyncStream<Bool>.Continuation
    private var waiter: CheckedContinuation<String, Error>?
    init() {
        let stream = AsyncStream<Bool>.makeStream()
        entries = stream.stream
        entryContinuation = stream.continuation
    }
    func retrieve() async throws -> String {
        try await withCheckedThrowingContinuation {
            waiter = $0
            entryContinuation.yield(true)
        }
    }
    func succeed() {
        waiter?.resume(returning: "test-token")
        waiter = nil
    }
    func fail() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}
