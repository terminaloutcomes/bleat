import Foundation

public enum AudiobookshelfLiveConnectionState: Equatable, Sendable {
    case connecting
    case authenticated
    case disconnected
    case suspendedForLowDataMode
    case failed(AudiobookshelfLiveUpdateFailure)
}

public enum AudiobookshelfLiveUpdateFailure: Error, Equatable, Sendable {
    case invalidSocketURL
    case credentialsUnavailable
    case authenticationRejected
    case transportUnavailable
    case malformedPacket
}

public struct AudiobookshelfLiveItemChange: Equatable, Sendable {
    public let libraryIDs: Set<LibraryID>
    public let itemIDs: Set<LibraryItemID>

    public init(
        libraryIDs: Set<LibraryID>,
        itemIDs: Set<LibraryItemID>
    ) {
        self.libraryIDs = libraryIDs
        self.itemIDs = itemIDs
    }
}

public struct AudiobookshelfLivePlaybackProgress: Equatable, Sendable {
    public let itemID: LibraryItemID
    public let sessionID: PlaybackSessionID?
    public let deviceDescription: String?
    public let currentTime: Double
    public let duration: Double
    public let isFinished: Bool
    public let lastUpdateMilliseconds: Int64

    public init(
        itemID: LibraryItemID,
        sessionID: PlaybackSessionID?,
        deviceDescription: String?,
        currentTime: Double,
        duration: Double,
        isFinished: Bool,
        lastUpdateMilliseconds: Int64
    ) {
        self.itemID = itemID
        self.sessionID = sessionID
        self.deviceDescription = deviceDescription
        self.currentTime = currentTime
        self.duration = duration
        self.isFinished = isFinished
        self.lastUpdateMilliseconds = lastUpdateMilliseconds
    }
}

public enum AudiobookshelfLiveEvent: Equatable, Sendable {
    case libraryChanged(LibraryID)
    case itemsChanged(AudiobookshelfLiveItemChange)
    case playbackProgress(AudiobookshelfLivePlaybackProgress)
}

public enum AudiobookshelfLiveUpdate: Equatable, Sendable {
    case connection(AudiobookshelfLiveConnectionState)
    case connectionAttempt(AudiobookshelfLiveConnectionAttempt)
    case event(AudiobookshelfLiveEvent)
}

public struct AudiobookshelfLiveServerEndpoint: Equatable, Sendable {
    public let server: NormalizedServerURL
    public let usage: ServerEndpointUsage

    public init(server: NormalizedServerURL, usage: ServerEndpointUsage) {
        self.server = server
        self.usage = usage
    }
}

public struct AudiobookshelfLiveConnectionAttempt: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case started
        case authenticated
        case failed(AudiobookshelfLiveConnectionFailure)
        case cancelled
    }

    public let id: UUID
    public let usage: ServerEndpointUsage
    public let retryBucket: RemoteTelemetryRetryBucket
    public let phase: Phase

    public init(
        id: UUID,
        usage: ServerEndpointUsage,
        retryBucket: RemoteTelemetryRetryBucket,
        phase: Phase
    ) {
        self.id = id
        self.usage = usage
        self.retryBucket = retryBucket
        self.phase = phase
    }
}

public struct AudiobookshelfLiveConnectionFailure: Equatable, Sendable {
    public let cause: AudiobookshelfLiveUpdateFailure
    public let stage: AudiobookshelfLiveConnectionFailureStage

    public init(
        cause: AudiobookshelfLiveUpdateFailure,
        stage: AudiobookshelfLiveConnectionFailureStage
    ) {
        self.cause = cause
        self.stage = stage
    }
}

public enum AudiobookshelfLiveConnectionFailureStage: Equatable, Sendable {
    case requestConstruction
    case credentialRetrieval
    case socketReceive
    case socketSend
    case protocolDecoding
    case authentication
    case credentialRecovery
}

public enum AudiobookshelfSocketPacket: Equatable, Sendable {
    case engineOpen
    case namespaceConnected
    case ping(String)
    case event(AudiobookshelfLiveEvent)
    case initialized
    case authenticationRejected
    case ignored
}

public struct AudiobookshelfSocketCodec: Sendable {
    public init() {}

    public func socketURL(
        for server: NormalizedServerURL
    ) throws(AudiobookshelfLiveUpdateFailure) -> URL {
        guard var components = URLComponents(
            url: server.url,
            resolvingAgainstBaseURL: false
        ) else {
            throw .invalidSocketURL
        }
        components.scheme = "wss"
        var path = components.percentEncodedPath
        if path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path + "/socket.io/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        guard let url = components.url else {
            throw .invalidSocketURL
        }
        return url
    }

    public func authenticationPacket(accessToken: String) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: ["auth", accessToken]
        )
        return "42" + String(
            decoding: data ?? Data("[]".utf8),
            as: UTF8.self
        )
    }

    public func socketRequest(
        for server: NormalizedServerURL
    ) throws(AudiobookshelfLiveUpdateFailure) -> URLRequest {
        var request = URLRequest(url: try socketURL(for: server))
        request.allowsConstrainedNetworkAccess = false
        return request
    }

    public func decode(
        _ text: String
    ) throws(AudiobookshelfLiveUpdateFailure) -> AudiobookshelfSocketPacket {
        if text.hasPrefix("0") {
            return .engineOpen
        }
        if text.hasPrefix("40") {
            return .namespaceConnected
        }
        if text.hasPrefix("2") {
            return .ping(String(text.dropFirst()))
        }
        guard text.hasPrefix("42") else {
            return .ignored
        }
        guard
            let data = String(text.dropFirst(2)).data(using: .utf8),
            let values = try? JSONSerialization.jsonObject(with: data)
                as? [Any],
            let rawName = values.first as? String
        else {
            throw .malformedPacket
        }
        guard let name = ServerEventName(rawValue: rawName) else {
            return .ignored
        }
        switch name {
        case .initialized:
            return .initialized
        case .authenticationRejected:
            return .authenticationRejected
        case .libraryAdded, .libraryUpdated, .libraryRemoved:
            let payload: LibraryPayload = try payload(values)
            guard !payload.id.isEmpty else {
                throw .malformedPacket
            }
            return .event(.libraryChanged(
                LibraryID(rawValue: payload.id)
            ))
        case .itemAdded, .itemUpdated, .itemRemoved:
            let payload: ItemPayload = try payload(values)
            return .event(.itemsChanged(try itemChange([payload])))
        case .itemsAdded, .itemsUpdated:
            let payload: [ItemPayload] = try payload(values)
            return .event(.itemsChanged(try itemChange(payload)))
        case .progressUpdated:
            let payload: ProgressPayload = try payload(values)
            return .event(.playbackProgress(try payload.domainValue()))
        }
    }

    private func payload<Value: Decodable>(
        _ values: [Any]
    ) throws(AudiobookshelfLiveUpdateFailure) -> Value {
        guard values.count >= 2,
            JSONSerialization.isValidJSONObject(values[1]),
            let decoded = try? JSONDecoder().decode(
                Value.self,
                from: JSONSerialization.data(withJSONObject: values[1])
            )
        else {
            throw .malformedPacket
        }
        return decoded
    }

    private func itemChange(
        _ payloads: [ItemPayload]
    ) throws(AudiobookshelfLiveUpdateFailure) -> AudiobookshelfLiveItemChange {
        guard !payloads.isEmpty,
            payloads.allSatisfy({
                !$0.id.isEmpty && !$0.libraryId.isEmpty
            })
        else {
            throw .malformedPacket
        }
        return AudiobookshelfLiveItemChange(
            libraryIDs: Set(payloads.map {
                LibraryID(rawValue: $0.libraryId)
            }),
            itemIDs: Set(payloads.map {
                LibraryItemID(rawValue: $0.id)
            })
        )
    }
}

public actor AudiobookshelfLiveEventClient {
    public typealias ServerProvider =
        @Sendable () async -> AudiobookshelfLiveServerEndpoint
    public typealias AccessTokenProvider =
        @Sendable () async throws -> String
    public typealias AccessTokenRecovery =
        @Sendable (_ rejectedToken: String) async throws -> String

    public typealias TransportFailureHandler =
        @Sendable (_ server: NormalizedServerURL) async -> Void
    public typealias AuthenticationHandler =
        @Sendable (_ server: NormalizedServerURL) async -> Void

    private let serverProvider: ServerProvider
    private let tokenProvider: AccessTokenProvider
    private let tokenRecovery: AccessTokenRecovery
    private let onTransportFailure: TransportFailureHandler
    private let onAuthenticated: AuthenticationHandler
    private let codec = AudiobookshelfSocketCodec()
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    public init(
        serverProvider: @escaping ServerProvider,
        tokenProvider: @escaping AccessTokenProvider,
        tokenRecovery: @escaping AccessTokenRecovery,
        onTransportFailure: @escaping TransportFailureHandler = { _ in },
        onAuthenticated: @escaping AuthenticationHandler = { _ in }
    ) {
        self.serverProvider = serverProvider
        self.tokenProvider = tokenProvider
        self.tokenRecovery = tokenRecovery
        self.onTransportFailure = onTransportFailure
        self.onAuthenticated = onAuthenticated
    }

    public func updates() -> AsyncStream<AudiobookshelfLiveUpdate> {
        task?.cancel()
        return AsyncStream { continuation in
            task = Task {
                await run(continuation: continuation)
            }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.stop() }
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    public func reconnect() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func run(
        continuation: AsyncStream<AudiobookshelfLiveUpdate>.Continuation
    ) async {
        var retry = 0
        while !Task.isCancelled {
            continuation.yield(.connection(.connecting))
            let authenticated = await connectOnce(
                retryCount: retry,
                continuation: continuation
            )
            guard !Task.isCancelled else {
                break
            }
            if authenticated {
                retry = 0
            } else {
                retry += 1
            }
            continuation.yield(.connection(.disconnected))
            let seconds = min(30, 1 << min(retry, 4))
            try? await Task.sleep(for: .seconds(seconds))
        }
        continuation.yield(.connection(.disconnected))
        continuation.finish()
    }

    private func connectOnce(
        retryCount: Int,
        continuation: AsyncStream<AudiobookshelfLiveUpdate>.Continuation
    ) async -> Bool {
        let endpoint = await serverProvider()
        let server = endpoint.server
        let attemptID = UUID()
        let retryBucket = RemoteTelemetryRetryBucket(retryCount: retryCount)
        continuation.yield(
            .connectionAttempt(
                AudiobookshelfLiveConnectionAttempt(
                    id: attemptID,
                    usage: endpoint.usage,
                    retryBucket: retryBucket,
                    phase: .started
                )
            ))
        var attemptFinished = false

        func finishAttempt(
            _ phase: AudiobookshelfLiveConnectionAttempt.Phase
        ) {
            guard !attemptFinished else { return }
            attemptFinished = true
            continuation.yield(
                .connectionAttempt(
                    AudiobookshelfLiveConnectionAttempt(
                        id: attemptID,
                        usage: endpoint.usage,
                        retryBucket: retryBucket,
                        phase: phase
                    )
                ))
        }

        let request: URLRequest
        do {
            request = try codec.socketRequest(for: server)
        } catch let failure {
            finishAttempt(.failed(AudiobookshelfLiveConnectionFailure(
                cause: failure,
                stage: .requestConstruction
            )))
            continuation.yield(.connection(.failed(failure)))
            return false
        }

        let initialToken: String
        do {
            initialToken = try await tokenProvider()
        } catch {
            finishAttempt(.failed(AudiobookshelfLiveConnectionFailure(
                cause: .credentialsUnavailable,
                stage: .credentialRetrieval
            )))
            continuation.yield(.connection(.failed(.credentialsUnavailable)))
            return false
        }

        let socket = URLSession.shared.webSocketTask(with: request)
        self.socket = socket
        socket.resume()
        var token = initialToken
        var didRecoverAuthentication = false
        var authenticated = false
        var failureStage = AudiobookshelfLiveConnectionFailureStage.socketReceive

        do {
            while !Task.isCancelled {
                failureStage = .socketReceive
                let message = try await socket.receive()
                failureStage = .protocolDecoding
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    guard let value = String(data: data, encoding: .utf8)
                    else {
                        throw AudiobookshelfLiveUpdateFailure.malformedPacket
                    }
                    text = value
                @unknown default:
                    continue
                }
                switch try codec.decode(text) {
                case .engineOpen:
                    failureStage = .socketSend
                    try await socket.send(.string("40"))
                case .namespaceConnected:
                    failureStage = .socketSend
                    try await socket.send(.string(
                        codec.authenticationPacket(accessToken: token)
                    ))
                case .ping(let payload):
                    failureStage = .socketSend
                    try await socket.send(.string("3" + payload))
                case .initialized:
                    authenticated = true
                    finishAttempt(.authenticated)
                    await onAuthenticated(server)
                    continuation.yield(.connection(.authenticated))
                case .authenticationRejected:
                    guard !didRecoverAuthentication else {
                        finishAttempt(.failed(AudiobookshelfLiveConnectionFailure(
                            cause: .authenticationRejected,
                            stage: .authentication
                        )))
                        continuation.yield(
                            .connection(.failed(.authenticationRejected))
                        )
                        return false
                    }
                    didRecoverAuthentication = true
                    do {
                        token = try await tokenRecovery(token)
                    } catch {
                        finishAttempt(.failed(AudiobookshelfLiveConnectionFailure(
                            cause: .credentialsUnavailable,
                            stage: .credentialRecovery
                        )))
                        continuation.yield(
                            .connection(.failed(.credentialsUnavailable))
                        )
                        return false
                    }
                    do {
                        try await socket.send(.string(
                            codec.authenticationPacket(accessToken: token)
                        ))
                    } catch {
                        finishAttempt(.failed(AudiobookshelfLiveConnectionFailure(
                            cause: .transportUnavailable,
                            stage: .socketSend
                        )))
                        continuation.yield(
                            .connection(.failed(.transportUnavailable))
                        )
                        return false
                    }
                case .event(let event):
                    guard authenticated else {
                        continue
                    }
                    continuation.yield(.event(event))
                case .ignored:
                    continue
                }
            }
        } catch is CancellationError {
            finishAttempt(.cancelled)
            return authenticated
        } catch let failure as AudiobookshelfLiveUpdateFailure {
            finishAttempt(.failed(AudiobookshelfLiveConnectionFailure(
                cause: failure,
                stage: failureStage
            )))
            continuation.yield(.connection(.failed(failure)))
        } catch {
            finishAttempt(.failed(AudiobookshelfLiveConnectionFailure(
                cause: .transportUnavailable,
                stage: failureStage
            )))
            continuation.yield(.connection(.failed(.transportUnavailable)))
            await onTransportFailure(server)
        }
        socket.cancel(with: .goingAway, reason: nil)
        if self.socket === socket {
            self.socket = nil
        }
        return authenticated
    }
}

private enum ServerEventName: String {
    case initialized = "init"
    case authenticationRejected = "auth_failed"
    case libraryAdded = "library_added"
    case libraryUpdated = "library_updated"
    case libraryRemoved = "library_removed"
    case itemAdded = "item_added"
    case itemUpdated = "item_updated"
    case itemRemoved = "item_removed"
    case itemsAdded = "items_added"
    case itemsUpdated = "items_updated"
    case progressUpdated = "user_item_progress_updated"
}

private struct LibraryPayload: Decodable {
    let id: String
}

private struct ItemPayload: Decodable {
    let id: String
    let libraryId: String
}

private struct ProgressPayload: Decodable {
    let sessionId: String?
    let deviceDescription: String?
    let data: ProgressData

    struct ProgressData: Decodable {
        let libraryItemId: String
        let duration: Double
        let currentTime: Double
        let isFinished: Bool
        let lastUpdate: Int64
    }

    func domainValue()
        throws(AudiobookshelfLiveUpdateFailure)
        -> AudiobookshelfLivePlaybackProgress
    {
        guard !data.libraryItemId.isEmpty,
            data.duration.isFinite, data.duration >= 0,
            data.currentTime.isFinite, data.currentTime >= 0,
            data.lastUpdate >= 0
        else {
            throw .malformedPacket
        }
        let cleanDescription = deviceDescription?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(120)
        let safeDescription = cleanDescription.flatMap { value in
            value.rangeOfCharacter(from: .controlCharacters) == nil
                && !value.isEmpty
                ? String(value)
                : nil
        }
        return AudiobookshelfLivePlaybackProgress(
            itemID: LibraryItemID(rawValue: data.libraryItemId),
            sessionID: sessionId.flatMap {
                $0.isEmpty ? nil : PlaybackSessionID(rawValue: $0)
            },
            deviceDescription: safeDescription,
            currentTime: data.currentTime,
            duration: data.duration,
            isFinished: data.isFinished,
            lastUpdateMilliseconds: data.lastUpdate
        )
    }
}
