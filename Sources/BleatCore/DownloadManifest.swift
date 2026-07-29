import Foundation

public enum DownloadManifestState: String, Codable, Sendable {
    case queued
    case downloading
    case partial
    case complete
    case failed
    case deleting
}

public enum DownloadTrackState: String, Codable, Sendable {
    case queued
    case downloading
    case partial
    case complete
    case failed
}

public enum DownloadFilePlacement: String, Codable, Sendable {
    case temporary
    case finalized
}

public enum DownloadPurpose: String, Codable, Sendable {
    case manual
    case automaticCache
}

public struct DownloadManifestEntry: Codable, Equatable, Sendable {
    public let trackIndex: Int
    public let expectedByteLength: Int64
    public let destinationEntry: String
    public internal(set) var state: DownloadTrackState
    public internal(set) var observedByteLength: Int64?
    public internal(set) var placement: DownloadFilePlacement?
}

public enum DownloadManifestError: Error, Equatable, Sendable {
    case noTracks
    case trackNotFound(Int)
    case invalidObservedByteLength
    case byteLengthMismatch(
        trackIndex: Int,
        expected: Int64,
        observed: Int64
    )
    case trackNotFinalized(Int)
    case incompleteTrack(Int)
}

public struct DownloadManifest: Codable, Equatable, Sendable {
    public let downloadID: DownloadID
    public let accountID: AccountID
    public let itemID: LibraryItemID
    public internal(set) var state: DownloadManifestState
    public internal(set) var purpose: DownloadPurpose
    public internal(set) var bookFinishedAt: Date?
    public private(set) var entries: [DownloadManifestEntry]

    public var expectedByteLength: Int64 {
        Self.saturatingSum(entries.map(\.expectedByteLength))
    }

    public var storedByteLength: Int64 {
        Self.saturatingSum(
            entries.compactMap(\.observedByteLength)
        )
    }

    public init(
        downloadID: DownloadID,
        accountID: AccountID,
        plan: DownloadPlan,
        purpose: DownloadPurpose = .manual
    ) {
        self.downloadID = downloadID
        self.accountID = accountID
        itemID = plan.itemID
        state = .queued
        self.purpose = purpose
        bookFinishedAt = nil
        entries = plan.tracks.map {
            DownloadManifestEntry(
                trackIndex: $0.index,
                expectedByteLength: $0.expectedByteLength,
                destinationEntry: $0.destinationEntry,
                state: .queued
            )
        }
    }

    public mutating func markDownloading(
        trackIndex: Int
    ) throws(DownloadManifestError) {
        let index = try entryIndex(for: trackIndex)
        entries[index].state = .downloading
        state = .downloading
    }

    public mutating func markPartial(
        trackIndex: Int,
        observedByteLength: Int64,
        placement: DownloadFilePlacement
    ) throws(DownloadManifestError) {
        guard observedByteLength >= 0 else {
            throw .invalidObservedByteLength
        }
        let index = try entryIndex(for: trackIndex)
        entries[index].state = .partial
        entries[index].observedByteLength = observedByteLength
        entries[index].placement = placement
        state = .partial
    }

    public mutating func markComplete(
        trackIndex: Int,
        observedByteLength: Int64,
        placement: DownloadFilePlacement
    ) throws(DownloadManifestError) {
        guard observedByteLength >= 0 else {
            throw .invalidObservedByteLength
        }
        let index = try entryIndex(for: trackIndex)
        let entry = entries[index]
        guard entry.expectedByteLength == observedByteLength else {
            throw .byteLengthMismatch(
                trackIndex: trackIndex,
                expected: entry.expectedByteLength,
                observed: observedByteLength
            )
        }
        guard placement == .finalized else {
            throw .trackNotFinalized(trackIndex)
        }
        entries[index].state = .complete
        entries[index].observedByteLength = observedByteLength
        entries[index].placement = placement
        state = .partial
    }

    public mutating func markFailed(
        trackIndex: Int
    ) throws(DownloadManifestError) {
        let index = try entryIndex(for: trackIndex)
        entries[index].state = .failed
        state = .failed
    }

    public mutating func markQueued(
        trackIndex: Int
    ) throws(DownloadManifestError) {
        let index = try entryIndex(for: trackIndex)
        entries[index].state = .queued
        entries[index].observedByteLength = nil
        entries[index].placement = nil
        updateIncompleteState()
    }

    public mutating func promoteToManual() {
        purpose = .manual
        bookFinishedAt = nil
    }

    public mutating func markBookFinished(at date: Date?) {
        guard purpose == .automaticCache else {
            return
        }
        bookFinishedAt = date
    }

    public mutating func markDeleting() {
        state = .deleting
    }

    public mutating func finish() throws(DownloadManifestError) {
        guard !entries.isEmpty else {
            throw .noTracks
        }
        for entry in entries {
            guard entry.state == .complete else {
                throw .incompleteTrack(entry.trackIndex)
            }
            guard entry.placement == .finalized else {
                throw .trackNotFinalized(entry.trackIndex)
            }
            guard entry.observedByteLength == entry.expectedByteLength else {
                throw .byteLengthMismatch(
                    trackIndex: entry.trackIndex,
                    expected: entry.expectedByteLength,
                    observed: entry.observedByteLength ?? -1
                )
            }
        }
        state = .complete
    }

    enum CodingKeys: String, CodingKey {
        case downloadID
        case accountID
        case itemID
        case state
        case purpose
        case bookFinishedAt
        case entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadID = try container.decode(DownloadID.self, forKey: .downloadID)
        accountID = try container.decode(AccountID.self, forKey: .accountID)
        itemID = try container.decode(LibraryItemID.self, forKey: .itemID)
        state = try container.decode(DownloadManifestState.self, forKey: .state)
        purpose =
            try container.decodeIfPresent(
                DownloadPurpose.self,
                forKey: .purpose
            ) ?? .manual
        bookFinishedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .bookFinishedAt
        )
        entries = try container.decode(
            [DownloadManifestEntry].self,
            forKey: .entries
        )

        let trackIndexes = entries.map(\.trackIndex)
        guard !downloadID.rawValue.isEmpty,
            !accountID.rawValue.isEmpty,
            !itemID.rawValue.isEmpty,
            entries.allSatisfy({
                $0.trackIndex >= 0
                    && $0.expectedByteLength >= 0
                    && DownloadTaskIdentity.isValidDestinationEntry(
                        $0.destinationEntry
                    )
            }),
            Set(trackIndexes).count == trackIndexes.count
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .entries,
                in: container,
                debugDescription:
                    "Manifest identity or track metadata is invalid"
            )
        }
        guard state != .complete || isCompleteAndFinalized else {
            throw DecodingError.dataCorruptedError(
                forKey: .state,
                in: container,
                debugDescription:
                    "A complete manifest must contain only finalized complete tracks"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(downloadID, forKey: .downloadID)
        try container.encode(accountID, forKey: .accountID)
        try container.encode(itemID, forKey: .itemID)
        try container.encode(state, forKey: .state)
        try container.encode(purpose, forKey: .purpose)
        try container.encodeIfPresent(
            bookFinishedAt,
            forKey: .bookFinishedAt
        )
        try container.encode(entries, forKey: .entries)
    }

    private var isCompleteAndFinalized: Bool {
        !entries.isEmpty
            && entries.allSatisfy {
                $0.state == .complete
                    && $0.placement == .finalized
                    && $0.observedByteLength == $0.expectedByteLength
            }
    }

    private func entryIndex(
        for trackIndex: Int
    ) throws(DownloadManifestError) -> Int {
        guard
            let index = entries.firstIndex(where: {
                $0.trackIndex == trackIndex
            })
        else {
            throw .trackNotFound(trackIndex)
        }
        return index
    }

    private mutating func updateIncompleteState() {
        if entries.allSatisfy({ $0.state == .queued }) {
            state = .queued
        } else if entries.contains(where: { $0.state == .downloading }) {
            state = .downloading
        } else if entries.contains(where: { $0.state == .failed }) {
            state = .failed
        } else {
            state = .partial
        }
    }

    private static func saturatingSum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int64.max : sum
        }
    }
}
