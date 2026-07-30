import Foundation

public enum AudiobookshelfLiveConnectionState: Equatable, Sendable {
    case connecting
    case authenticated
    case disconnected
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
    case event(AudiobookshelfLiveEvent)
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
            data: data ?? Data("[]".utf8),
            encoding: .utf8
        )!
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
    public typealias AccessTokenProvider =
        @Sendable () async throws -> String
    public typealias AccessTokenRecovery =
        @Sendable (_ rejectedToken: String) async throws -> String

    private let server: NormalizedServerURL
    private let tokenProvider: AccessTokenProvider
    private let tokenRecovery: AccessTokenRecovery
    private let codec = AudiobookshelfSocketCodec()
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?

    public init(
        server: NormalizedServerURL,
        tokenProvider: @escaping AccessTokenProvider,
        tokenRecovery: @escaping AccessTokenRecovery
    ) {
        self.server = server
        self.tokenProvider = tokenProvider
        self.tokenRecovery = tokenRecovery
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

    private func run(
        continuation: AsyncStream<AudiobookshelfLiveUpdate>.Continuation
    ) async {
        var retry = 0
        while !Task.isCancelled {
            continuation.yield(.connection(.connecting))
            let authenticated = await connectOnce(continuation: continuation)
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
        continuation: AsyncStream<AudiobookshelfLiveUpdate>.Continuation
    ) async -> Bool {
        let url: URL
        let initialToken: String
        do {
            url = try codec.socketURL(for: server)
            initialToken = try await tokenProvider()
        } catch let failure as AudiobookshelfLiveUpdateFailure {
            continuation.yield(.connection(.failed(failure)))
            return false
        } catch {
            continuation.yield(.connection(.failed(.credentialsUnavailable)))
            return false
        }

        let socket = URLSession.shared.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        var token = initialToken
        var didRecoverAuthentication = false
        var authenticated = false

        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
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
                    try await socket.send(.string("40"))
                case .namespaceConnected:
                    try await socket.send(.string(
                        codec.authenticationPacket(accessToken: token)
                    ))
                case .ping(let payload):
                    try await socket.send(.string("3" + payload))
                case .initialized:
                    authenticated = true
                    continuation.yield(.connection(.authenticated))
                case .authenticationRejected:
                    guard !didRecoverAuthentication else {
                        continuation.yield(
                            .connection(.failed(.authenticationRejected))
                        )
                        return false
                    }
                    didRecoverAuthentication = true
                    do {
                        token = try await tokenRecovery(token)
                        try await socket.send(.string(
                            codec.authenticationPacket(accessToken: token)
                        ))
                    } catch {
                        continuation.yield(
                            .connection(.failed(.credentialsUnavailable))
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
            return authenticated
        } catch let failure as AudiobookshelfLiveUpdateFailure {
            continuation.yield(.connection(.failed(failure)))
        } catch {
            continuation.yield(.connection(.failed(.transportUnavailable)))
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
