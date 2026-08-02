import Foundation

public enum PlaybackMethod: Codable, Hashable, Sendable {
    case directPlay
    case transcode
    case local
    case unknown(Int)

    public var rawValue: Int {
        switch self {
        case .directPlay:
            0
        case .transcode:
            2
        case .local:
            3
        case .unknown(let value):
            value
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int.self)
        switch value {
        case 0:
            self = .directPlay
        case 2:
            self = .transcode
        case 3:
            self = .local
        default:
            self = .unknown(value)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum PlaybackPreference: Hashable, Sendable {
    case automatic
    case directPlay
    case transcode
}

public struct PlaybackDeviceInfo: Codable, Hashable, Sendable {
    public let deviceID: String
    public let clientName: String
    public let clientVersion: String
    public let manufacturer: String
    public let model: String

    public init(
        deviceID: String,
        clientName: String,
        clientVersion: String,
        manufacturer: String,
        model: String
    ) {
        self.deviceID = deviceID
        self.clientName = clientName
        self.clientVersion = clientVersion
        self.manufacturer = manufacturer
        self.model = model
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case clientName
        case clientVersion
        case manufacturer
        case model
    }
}

public struct PlaybackChapter: Codable, Hashable, Sendable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let title: String

    public init(id: Int, start: Double, end: Double, title: String) {
        self.id = id
        self.start = start
        self.end = end
        self.title = title
    }
}

public struct PlaybackBookMetadata: Decodable, Hashable, Sendable {
    public let title: String
    public let subtitle: String?
}

public struct PlaybackLibraryItemMedia: Decodable, Hashable, Sendable {
    public let id: BookID
    public let metadata: PlaybackBookMetadata
    public let duration: Double
}

public struct PlaybackLibraryItem: Decodable, Hashable, Sendable {
    public let id: LibraryItemID
    public let libraryID: LibraryID
    public let mediaType: String
    public let isFile: Bool
    public let media: PlaybackLibraryItemMedia

    enum CodingKeys: String, CodingKey {
        case id
        case libraryID = "libraryId"
        case mediaType
        case isFile
        case media
    }
}

public struct PlaybackAudioTrack: Decodable, Hashable, Sendable {
    public let index: Int
    public let startOffset: Double
    public let duration: Double
    public let title: String
    public let contentURL: String
    public let mimeType: String
    public let codec: String?

    enum CodingKeys: String, CodingKey {
        case index
        case startOffset
        case duration
        case title
        case contentURL = "contentUrl"
        case mimeType
        case codec
    }
}

public struct PlaybackSession: Hashable, Sendable {
    public let id: PlaybackSessionID
    public let libraryID: LibraryID
    public let libraryItemID: LibraryItemID
    public let bookID: BookID?
    public let mediaType: String
    public let duration: Double
    public let method: PlaybackMethod
    public let startTime: Double
    public let currentTime: Double
    public let chapters: [PlaybackChapter]
    public let libraryItem: PlaybackLibraryItem
    public let audioTracks: [PlaybackAudioTrack]

    fileprivate init(
        id: PlaybackSessionID,
        libraryID: LibraryID,
        libraryItemID: LibraryItemID,
        bookID: BookID?,
        mediaType: String,
        duration: Double,
        method: PlaybackMethod,
        startTime: Double,
        currentTime: Double,
        chapters: [PlaybackChapter],
        libraryItem: PlaybackLibraryItem,
        audioTracks: [PlaybackAudioTrack]
    ) {
        self.id = id
        self.libraryID = libraryID
        self.libraryItemID = libraryItemID
        self.bookID = bookID
        self.mediaType = mediaType
        self.duration = duration
        self.method = method
        self.startTime = startTime
        self.currentTime = currentTime
        self.chapters = chapters
        self.libraryItem = libraryItem
        self.audioTracks = audioTracks
    }

    public func source(
        for server: NormalizedServerURL
    ) throws(PlaybackSourceError) -> PlaybackSource {
        let routeBuilder = AudiobookshelfRouteBuilder(server: server)
        switch method {
        case .directPlay:
            var resolvedTracks: [DirectPlaybackTrack] = []
            for track in audioTracks {
                let url: URL
                do {
                    url = try routeBuilder.url(
                        for: .directPlay(
                            sessionID: id,
                            trackIndex: track.index
                        )
                    )
                } catch let error {
                    throw .routeConstructionFailed(error)
                }
                resolvedTracks.append(
                    DirectPlaybackTrack(track: track, url: url)
                )
            }
            return .direct(resolvedTracks)
        case .transcode:
            let returnedPath = audioTracks.first?.contentURL ?? ""
            do {
                return .hls(
                    try routeBuilder.serverRelativeContentURL(returnedPath)
                )
            } catch let error {
                throw .routeConstructionFailed(error)
            }
        case .local, .unknown:
            throw .unsupportedMethod(method)
        }
    }
}

public struct DirectPlaybackTrack: Hashable, Sendable {
    public let track: PlaybackAudioTrack
    public let url: URL

    public init(track: PlaybackAudioTrack, url: URL) {
        self.track = track
        self.url = url
    }
}

public enum PlaybackSource: Hashable, Sendable {
    case direct([DirectPlaybackTrack])
    case hls(URL)
}

public enum PlaybackSourceError: Error, Equatable, Sendable {
    case unsupportedMethod(PlaybackMethod)
    case routeConstructionFailed(RouteConstructionError)
}

public enum PlaybackSessionError: Error, Equatable, Sendable {
    case invalidLibraryItemID
    case invalidDeviceInfo
    case invalidSupportedMimeType
    case requestConstructionFailed(RouteConstructionError)
    case requestEncodingFailed
    case authenticationFailed(AuthenticatedRequestError)
    case requestFailed
    case unexpectedStartStatus(Int)
    case malformedStartResponse
    case invalidSessionResponse
    case mismatchedLibraryItem(expected: String, actual: String)
    case unexpectedCloseStatus(Int)
}

public enum PlaybackSyncError: Error, Equatable, Sendable {
    case invalidSessionID
    case invalidPosition
    case invalidDuration
    case invalidListeningTime
    case positionExceedsDuration
    case requestConstructionFailed(RouteConstructionError)
    case requestEncodingFailed
    case authenticationFailed(AuthenticatedRequestError)
    case requestFailed
    case unexpectedStatus(Int)
}

private struct PlaybackStartRequest: Encodable {
    let forceDirectPlay: Bool
    let forceTranscode: Bool
    let mediaPlayer: String
    let supportedMimeTypes: [String]
    let deviceInfo: PlaybackDeviceInfo
}

private struct PlaybackSyncRequest: Encodable {
    let currentTime: Double
    let timeListened: Double
    let duration: Double
}

private struct PlaybackSessionPayload: Decodable {
    let id: PlaybackSessionID
    let libraryID: LibraryID
    let libraryItemID: LibraryItemID
    let bookID: BookID?
    let mediaType: String
    let duration: Double
    let method: PlaybackMethod
    let startTime: Double
    let currentTime: Double
    let chapters: [PlaybackChapter]
    let libraryItem: PlaybackLibraryItem
    let audioTracks: [PlaybackAudioTrack]

    enum CodingKeys: String, CodingKey {
        case id
        case libraryID = "libraryId"
        case libraryItemID = "libraryItemId"
        case bookID = "bookId"
        case mediaType
        case duration
        case method = "playMethod"
        case startTime
        case currentTime
        case chapters
        case libraryItem
        case audioTracks
    }

    func validated(
        for requestedItemID: LibraryItemID
    ) throws(PlaybackSessionError) -> PlaybackSession {
        guard libraryItemID == requestedItemID else {
            throw .mismatchedLibraryItem(
                expected: requestedItemID.rawValue,
                actual: libraryItemID.rawValue
            )
        }
        guard libraryItem.id == libraryItemID else {
            throw .mismatchedLibraryItem(
                expected: libraryItemID.rawValue,
                actual: libraryItem.id.rawValue
            )
        }
        guard !id.rawValue.isEmpty,
            !libraryID.rawValue.isEmpty,
            !libraryItemID.rawValue.isEmpty,
            !mediaType.isEmpty,
            duration.isFinite,
            duration >= 0,
            startTime.isFinite,
            startTime >= 0,
            currentTime.isFinite,
            currentTime >= 0,
            !audioTracks.isEmpty,
            audioTracks.allSatisfy(Self.isValid)
        else {
            throw .invalidSessionResponse
        }

        return PlaybackSession(
            id: id,
            libraryID: libraryID,
            libraryItemID: libraryItemID,
            bookID: bookID,
            mediaType: mediaType,
            duration: duration,
            method: method,
            startTime: startTime,
            currentTime: currentTime,
            chapters: chapters,
            libraryItem: libraryItem,
            audioTracks: audioTracks
        )
    }

    private static func isValid(_ track: PlaybackAudioTrack) -> Bool {
        track.index >= 0
            && track.startOffset.isFinite
            && track.startOffset >= 0
            && track.duration.isFinite
            && track.duration >= 0
            && !track.title.isEmpty
            && !track.contentURL.isEmpty
            && !track.mimeType.isEmpty
    }
}

extension AuthCoordinator {
    public func openPlaybackSession(
        accountID: AccountID,
        server: NormalizedServerURL,
        itemID: LibraryItemID,
        preference: PlaybackPreference = .automatic,
        supportedMimeTypes: [String],
        deviceInfo: PlaybackDeviceInfo
    ) async throws(PlaybackSessionError) -> PlaybackSession {
        guard !itemID.rawValue.isEmpty else {
            throw .invalidLibraryItemID
        }
        guard Self.isValidPlaybackDeviceInfo(deviceInfo) else {
            throw .invalidDeviceInfo
        }
        guard supportedMimeTypes.allSatisfy(Self.isValidMIMEType) else {
            throw .invalidSupportedMimeType
        }

        let route = AudiobookshelfRoute.play(itemID)
        let requestURL: URL
        do {
            requestURL = try AudiobookshelfRouteBuilder(server: server)
                .url(for: route)
        } catch let error {
            throw .requestConstructionFailed(error)
        }

        let body = PlaybackStartRequest(
            forceDirectPlay: preference == .directPlay,
            forceTranscode: preference == .transcode,
            mediaPlayer: "AVPlayer",
            supportedMimeTypes: supportedMimeTypes,
            deviceInfo: deviceInfo
        )
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw .requestEncodingFailed
        }

        let response: HTTPResponse
        do {
            response = try await sendAuthenticated(
                request,
                route: route,
                accountID: accountID,
                server: server
            )
        } catch let error as AuthenticatedRequestError {
            throw .authenticationFailed(error)
        } catch {
            throw .requestFailed
        }
        guard response.statusCode == 200 else {
            throw .unexpectedStartStatus(response.statusCode)
        }

        let payload: PlaybackSessionPayload
        do {
            payload = try JSONDecoder().decode(
                PlaybackSessionPayload.self,
                from: response.data
            )
        } catch {
            throw .malformedStartResponse
        }
        return try payload.validated(for: itemID)
    }

    public func closePlaybackSession(
        accountID: AccountID,
        server: NormalizedServerURL,
        sessionID: PlaybackSessionID
    ) async throws(PlaybackSessionError) {
        guard !sessionID.rawValue.isEmpty else {
            throw .invalidSessionResponse
        }
        let route = AudiobookshelfRoute.closeSession(sessionID)
        let requestURL: URL
        do {
            requestURL = try AudiobookshelfRouteBuilder(server: server)
                .url(for: route)
        } catch let error {
            throw .requestConstructionFailed(error)
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"

        let response: HTTPResponse
        do {
            response = try await sendAuthenticated(
                request,
                route: route,
                accountID: accountID,
                server: server
            )
        } catch let error as AuthenticatedRequestError {
            throw .authenticationFailed(error)
        } catch {
            throw .requestFailed
        }
        guard response.statusCode == 200 else {
            throw .unexpectedCloseStatus(response.statusCode)
        }
    }

    public func syncPlaybackSession(
        accountID: AccountID,
        server: NormalizedServerURL,
        sessionID: PlaybackSessionID,
        currentTime: Double,
        duration: Double,
        timeListened: Double = 0
    ) async throws(PlaybackSyncError) {
        guard !sessionID.rawValue.isEmpty else {
            throw .invalidSessionID
        }
        guard currentTime.isFinite, currentTime >= 0 else {
            throw .invalidPosition
        }
        guard duration.isFinite, duration >= 0 else {
            throw .invalidDuration
        }
        guard timeListened.isFinite, timeListened >= 0 else {
            throw .invalidListeningTime
        }
        guard currentTime <= duration else {
            throw .positionExceedsDuration
        }

        let route = AudiobookshelfRoute.syncSession(sessionID)
        let requestURL: URL
        do {
            requestURL = try AudiobookshelfRouteBuilder(server: server)
                .url(for: route)
        } catch let error {
            throw .requestConstructionFailed(error)
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Content-Type"
        )
        do {
            request.httpBody = try JSONEncoder().encode(
                PlaybackSyncRequest(
                    currentTime: currentTime,
                    timeListened: timeListened,
                    duration: duration
                )
            )
        } catch {
            throw .requestEncodingFailed
        }

        let response: HTTPResponse
        do {
            response = try await sendAuthenticated(
                request,
                route: route,
                accountID: accountID,
                server: server
            )
        } catch let error as AuthenticatedRequestError {
            throw .authenticationFailed(error)
        } catch {
            throw .requestFailed
        }
        guard response.statusCode == 200 else {
            throw .unexpectedStatus(response.statusCode)
        }
    }

    private static func isValidPlaybackDeviceInfo(
        _ deviceInfo: PlaybackDeviceInfo
    ) -> Bool {
        [
            deviceInfo.deviceID,
            deviceInfo.clientName,
            deviceInfo.clientVersion,
            deviceInfo.manufacturer,
            deviceInfo.model,
        ].allSatisfy(Self.isNonEmptyHeaderSafeValue)
    }

    private static func isValidMIMEType(_ value: String) -> Bool {
        Self.isNonEmptyHeaderSafeValue(value)
            && value.contains("/")
            && !value.contains(" ")
    }

    private static func isNonEmptyHeaderSafeValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.rangeOfCharacter(
                from: .controlCharacters.union(.newlines)
            ) == nil
    }
}
