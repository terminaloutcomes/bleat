import Foundation

public struct LocalPlaybackMediaMetadata: Codable, Hashable, Sendable {
    public let title: String

    public init(title: String) {
        self.title = title
    }
}

public struct LocalPlaybackSession: Codable, Hashable, Sendable {
    public let id: PlaybackSessionID
    public let libraryID: LibraryID
    public let libraryItemID: LibraryItemID
    public let bookID: BookID
    public let episodeID: String?
    public let mediaType: String
    public let mediaMetadata: LocalPlaybackMediaMetadata
    public let chapters: [PlaybackChapter]
    public let displayTitle: String
    public let displayAuthor: String
    public let coverPath: String?
    public let duration: Double
    public let playMethod: PlaybackMethod
    public let mediaPlayer: String
    public let timeListening: Double
    public let startTime: Double
    public let currentTime: Double
    public let startedAtMilliseconds: Int64
    public let updatedAtMilliseconds: Int64

    public init(
        id: PlaybackSessionID,
        libraryID: LibraryID,
        libraryItemID: LibraryItemID,
        bookID: BookID,
        mediaMetadata: LocalPlaybackMediaMetadata,
        chapters: [PlaybackChapter],
        displayTitle: String,
        displayAuthor: String,
        coverPath: String? = nil,
        duration: Double,
        startTime: Double,
        currentTime: Double,
        startedAtMilliseconds: Int64,
        updatedAtMilliseconds: Int64
    ) throws(LocalPlaybackSessionError) {
        self.id = id
        self.libraryID = libraryID
        self.libraryItemID = libraryItemID
        self.bookID = bookID
        episodeID = nil
        mediaType = "book"
        self.mediaMetadata = mediaMetadata
        self.chapters = chapters
        self.displayTitle = displayTitle
        self.displayAuthor = displayAuthor
        self.coverPath = coverPath
        self.duration = duration
        playMethod = .local
        mediaPlayer = "AVPlayer"
        timeListening = 0
        self.startTime = startTime
        self.currentTime = currentTime
        self.startedAtMilliseconds = startedAtMilliseconds
        self.updatedAtMilliseconds = updatedAtMilliseconds
        try validate()
    }

    public static func makeBookSession(
        libraryID: LibraryID,
        libraryItemID: LibraryItemID,
        bookID: BookID,
        title: String,
        author: String,
        chapters: [PlaybackChapter],
        duration: Double,
        currentTime: Double,
        now: Date = Date()
    ) throws(LocalPlaybackSessionError) -> Self {
        let milliseconds = Self.milliseconds(since1970: now)
        return try Self(
            id: PlaybackSessionID(
                rawValue: UUID().uuidString.lowercased()
            ),
            libraryID: libraryID,
            libraryItemID: libraryItemID,
            bookID: bookID,
            mediaMetadata: LocalPlaybackMediaMetadata(title: title),
            chapters: chapters,
            displayTitle: title,
            displayAuthor: author,
            duration: duration,
            startTime: currentTime,
            currentTime: currentTime,
            startedAtMilliseconds: milliseconds,
            updatedAtMilliseconds: milliseconds
        )
    }

    public func updating(
        currentTime: Double,
        now: Date = Date()
    ) throws(LocalPlaybackSessionError) -> Self {
        try Self(
            id: id,
            libraryID: libraryID,
            libraryItemID: libraryItemID,
            bookID: bookID,
            mediaMetadata: mediaMetadata,
            chapters: chapters,
            displayTitle: displayTitle,
            displayAuthor: displayAuthor,
            coverPath: coverPath,
            duration: duration,
            startTime: startTime,
            currentTime: currentTime,
            startedAtMilliseconds: startedAtMilliseconds,
            updatedAtMilliseconds: Self.milliseconds(since1970: now)
        )
    }

    func validate() throws(LocalPlaybackSessionError) {
        guard Self.isVersion4UUID(id.rawValue) else {
            throw .invalidSessionID
        }
        guard !libraryID.rawValue.isEmpty,
            !libraryItemID.rawValue.isEmpty,
            !bookID.rawValue.isEmpty,
            !mediaMetadata.title.isEmpty,
            !displayTitle.isEmpty,
            !mediaPlayer.isEmpty
        else {
            throw .invalidMetadata
        }
        guard duration.isFinite, duration >= 0 else {
            throw .invalidDuration
        }
        guard startTime.isFinite,
            currentTime.isFinite,
            startTime >= 0,
            currentTime >= 0,
            startTime <= duration,
            currentTime <= duration
        else {
            throw .invalidPosition
        }
        guard startedAtMilliseconds >= 0,
            updatedAtMilliseconds >= startedAtMilliseconds
        else {
            throw .invalidTimestamp
        }
        guard playMethod == .local, timeListening == 0 else {
            throw .invalidMVPAccounting
        }
    }

    private static func milliseconds(since1970 date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }

    private static func isVersion4UUID(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else {
            return false
        }
        return withUnsafeBytes(of: uuid.uuid) { bytes in
            (bytes[6] & 0xf0) == 0x40
                && (bytes[8] & 0xc0) == 0x80
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case libraryID = "libraryId"
        case libraryItemID = "libraryItemId"
        case bookID = "bookId"
        case episodeID = "episodeId"
        case mediaType
        case mediaMetadata
        case chapters
        case displayTitle
        case displayAuthor
        case coverPath
        case duration
        case playMethod
        case mediaPlayer
        case timeListening
        case startTime
        case currentTime
        case startedAtMilliseconds = "startedAt"
        case updatedAtMilliseconds = "updatedAt"
    }
}

public struct LocalPlaybackSessionSyncResult:
    Decodable,
    Equatable,
    Sendable
{
    public let id: PlaybackSessionID
    public let success: Bool
    public let progressSynced: Bool
    public let error: String?

    public init(
        id: PlaybackSessionID,
        success: Bool,
        progressSynced: Bool,
        error: String?
    ) {
        self.id = id
        self.success = success
        self.progressSynced = progressSynced
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case success
        case progressSynced
        case error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(PlaybackSessionID.self, forKey: .id)
        success = try container.decode(Bool.self, forKey: .success)
        progressSynced =
            try container.decodeIfPresent(
                Bool.self,
                forKey: .progressSynced
            ) ?? false
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}

public enum LocalPlaybackSessionError: Error, Equatable, Sendable {
    case emptyBatch
    case duplicateSessionID
    case invalidSessionID
    case invalidMetadata
    case invalidDuration
    case invalidPosition
    case invalidTimestamp
    case invalidMVPAccounting
    case invalidDeviceInfo
    case requestConstructionFailed(RouteConstructionError)
    case requestEncodingFailed
    case authenticationFailed(AuthenticatedRequestError)
    case requestFailed
    case unexpectedStatus(Int)
    case malformedResponse
}

private struct LocalPlaybackSessionBatchRequest: Encodable {
    let sessions: [LocalPlaybackSession]
    let deviceInfo: PlaybackDeviceInfo
}

private struct LocalPlaybackSessionBatchResponse: Decodable {
    let results: [LocalPlaybackSessionSyncResult]
}

extension AuthCoordinator {
    public func syncLocalPlaybackSessions(
        accountID: AccountID,
        server: NormalizedServerURL,
        sessions: [LocalPlaybackSession],
        deviceInfo: PlaybackDeviceInfo
    ) async throws(LocalPlaybackSessionError)
        -> [LocalPlaybackSessionSyncResult]
    {
        guard !sessions.isEmpty else {
            throw .emptyBatch
        }
        for session in sessions {
            try session.validate()
        }
        let requestedIDs = Set(sessions.map(\.id))
        guard requestedIDs.count == sessions.count else {
            throw .duplicateSessionID
        }
        guard Self.isValidLocalSessionDeviceInfo(deviceInfo) else {
            throw .invalidDeviceInfo
        }

        let route = AudiobookshelfRoute.syncLocalSessions
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
                LocalPlaybackSessionBatchRequest(
                    sessions: sessions,
                    deviceInfo: deviceInfo
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
        let results: [LocalPlaybackSessionSyncResult]
        do {
            results = try JSONDecoder().decode(
                LocalPlaybackSessionBatchResponse.self,
                from: response.data
            ).results
        } catch {
            throw .malformedResponse
        }
        guard results.count == sessions.count,
            Set(results.map(\.id)) == requestedIDs
        else {
            throw .malformedResponse
        }
        return results
    }

    private static func isValidLocalSessionDeviceInfo(
        _ deviceInfo: PlaybackDeviceInfo
    ) -> Bool {
        [
            deviceInfo.deviceID,
            deviceInfo.clientName,
            deviceInfo.clientVersion,
            deviceInfo.manufacturer,
            deviceInfo.model,
        ].allSatisfy {
            !$0.isEmpty
                && $0.rangeOfCharacter(
                    from: .controlCharacters.union(.newlines)
                ) == nil
        }
    }
}
