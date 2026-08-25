import Foundation

public enum DownloadManifestState: String, Codable, Sendable {
    case queued
    case downloading
    case paused
    case partial
    case complete
    case failed
    case deleting
}

public enum DownloadTrackState: String, Codable, Sendable {
    case queued
    case downloading
    case paused
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

public enum AutomaticCacheState: String, Codable, Equatable, Sendable {
    case queued
    case downloading
    case cached
    case failed
}

public struct AutomaticDownloadWindow: Codable, Equatable, Sendable {
    public let targetTrackIndexes: [Int]

    public init(targetTrackIndexes: Set<Int>) {
        self.targetTrackIndexes = targetTrackIndexes.sorted()
    }
}

public struct DownloadManifestEntry: Codable, Equatable, Sendable {
    public let trackIndex: Int
    public let expectedByteLength: Int64
    public let destinationEntry: String
    public let inode: String?
    public let startOffset: Double?
    public let duration: Double?
    public internal(set) var state: DownloadTrackState
    public internal(set) var observedByteLength: Int64?
    public internal(set) var placement: DownloadFilePlacement?
    public internal(set) var validator: DownloadValidator? = nil
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
    case invalidAutomaticWindow
    case invalidPurpose
}

public struct DownloadManifest: Codable, Equatable, Sendable {
    public let downloadID: DownloadID
    public let accountID: AccountID
    public let itemID: LibraryItemID
    public internal(set) var state: DownloadManifestState
    public internal(set) var purpose: DownloadPurpose
    public internal(set) var bookFinishedAt: Date?
    public private(set) var automaticWindow: AutomaticDownloadWindow?
    public private(set) var entries: [DownloadManifestEntry]

    public var expectedByteLength: Int64 {
        Self.saturatingSum(entries.map(\.expectedByteLength))
    }

    public var storedByteLength: Int64 {
        Self.saturatingSum(
            entries.compactMap(\.observedByteLength)
        )
    }

    public var isFullBookComplete: Bool {
        isCompleteAndFinalized
    }

    public var automaticTargetTrackIndexes: Set<Int>? {
        automaticWindow.map {
            Set($0.targetTrackIndexes)
        }
    }

    public var automaticExpectedByteLength: Int64? {
        guard let targets = automaticTargetTrackIndexes else {
            return nil
        }
        return Self.saturatingSum(
            entries.compactMap {
                targets.contains($0.trackIndex)
                    ? $0.expectedByteLength
                    : nil
            }
        )
    }

    public var automaticStoredByteLength: Int64? {
        guard let targets = automaticTargetTrackIndexes else {
            return nil
        }
        return Self.saturatingSum(
            entries.compactMap { entry in
                guard targets.contains(entry.trackIndex) else {
                    return nil
                }
                return min(
                    max(entry.observedByteLength ?? 0, 0),
                    entry.expectedByteLength
                )
            }
        )
    }

    public var automaticCacheState: AutomaticCacheState? {
        guard let targets = automaticTargetTrackIndexes else {
            return nil
        }
        let targetEntries = entries.filter {
            targets.contains($0.trackIndex)
        }
        if targetEntries.allSatisfy({
            $0.state == .complete
                && $0.placement == .finalized
                && $0.observedByteLength == $0.expectedByteLength
        }) {
            return .cached
        }
        if targetEntries.contains(where: { $0.state == .downloading }) {
            return .downloading
        }
        if targetEntries.contains(where: {
            $0.state == .partial || $0.state == .failed
        }) {
            return .failed
        }
        return .queued
    }

    public var isLegacyAutomaticCache: Bool {
        purpose == .automaticCache && automaticWindow == nil
    }

    public init(
        downloadID: DownloadID,
        accountID: AccountID,
        plan: DownloadPlan,
        purpose: DownloadPurpose = .manual,
        automaticTargetTrackIndexes: Set<Int>? = nil
    ) throws(DownloadManifestError) {
        let planTrackIndexes = Set(plan.tracks.map(\.index))
        switch purpose {
        case .manual:
            guard automaticTargetTrackIndexes == nil else {
                throw .invalidAutomaticWindow
            }
        case .automaticCache:
            guard let automaticTargetTrackIndexes,
                !automaticTargetTrackIndexes.isEmpty,
                automaticTargetTrackIndexes.isSubset(of: planTrackIndexes)
            else {
                throw .invalidAutomaticWindow
            }
        }
        self.downloadID = downloadID
        self.accountID = accountID
        itemID = plan.itemID
        state = .queued
        self.purpose = purpose
        bookFinishedAt = nil
        automaticWindow = automaticTargetTrackIndexes.map {
            AutomaticDownloadWindow(targetTrackIndexes: $0)
        }
        entries = plan.tracks.map {
            DownloadManifestEntry(
                trackIndex: $0.index,
                expectedByteLength: $0.expectedByteLength,
                destinationEntry: $0.destinationEntry,
                inode: $0.inode,
                startOffset: $0.startOffset,
                duration: $0.duration,
                state: .queued,
                validator: nil
            )
        }
    }

    init(reidentifying manifest: DownloadManifest, as accountID: AccountID) {
        downloadID = manifest.downloadID
        self.accountID = accountID
        itemID = manifest.itemID
        state = manifest.state
        purpose = manifest.purpose
        bookFinishedAt = manifest.bookFinishedAt
        automaticWindow = manifest.automaticWindow
        entries = manifest.entries
    }

    public mutating func markDownloading(
        trackIndex: Int,
        observedByteLength: Int64? = nil,
        validator: DownloadValidator? = nil
    ) throws(DownloadManifestError) {
        let index = try entryIndex(for: trackIndex)
        entries[index].state = .downloading
        if let observedByteLength {
            guard observedByteLength >= 0 else {
                throw .invalidObservedByteLength
            }
            entries[index].observedByteLength = observedByteLength
            entries[index].placement = .temporary
        }
        entries[index].validator = validator ?? entries[index].validator
        state = .downloading
    }

    public mutating func markPaused(
        trackIndex: Int,
        observedByteLength: Int64,
        validator: DownloadValidator? = nil
    ) throws(DownloadManifestError) {
        guard observedByteLength >= 0 else {
            throw .invalidObservedByteLength
        }
        let index = try entryIndex(for: trackIndex)
        entries[index].state = .paused
        entries[index].observedByteLength = observedByteLength
        entries[index].placement = observedByteLength > 0 ? .temporary : nil
        entries[index].validator = validator ?? entries[index].validator
        state = .paused
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

    public mutating func reconcileStoredBytes(
        trackIndex: Int,
        observedByteLength: Int64
    ) throws(DownloadManifestError) {
        guard observedByteLength >= 0 else {
            throw .invalidObservedByteLength
        }
        let index = try entryIndex(for: trackIndex)
        entries[index].observedByteLength = observedByteLength
        entries[index].placement = observedByteLength > 0 ? .temporary : nil
        updateIncompleteState()
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
        updateIncompleteState()
    }

    public mutating func markFailed(
        trackIndex: Int,
        observedByteLength: Int64? = nil
    ) throws(DownloadManifestError) {
        let index = try entryIndex(for: trackIndex)
        entries[index].state = .failed
        if let observedByteLength {
            guard observedByteLength >= 0 else {
                throw .invalidObservedByteLength
            }
            entries[index].observedByteLength = observedByteLength
            entries[index].placement = observedByteLength > 0 ? .temporary : nil
        }
        state = .failed
    }

    public mutating func markQueued(
        trackIndex: Int
    ) throws(DownloadManifestError) {
        let index = try entryIndex(for: trackIndex)
        entries[index].state = .queued
        entries[index].observedByteLength = nil
        entries[index].placement = nil
        entries[index].validator = nil
        updateIncompleteState()
    }

    public mutating func markBookFinished(at date: Date?) {
        guard purpose == .automaticCache else {
            return
        }
        bookFinishedAt = date
    }

    public mutating func setAutomaticWindow(
        targetTrackIndexes: Set<Int>
    ) throws(DownloadManifestError) {
        guard purpose == .automaticCache else {
            throw .invalidPurpose
        }
        let entryIndexes = Set(entries.map(\.trackIndex))
        guard !targetTrackIndexes.isEmpty,
            targetTrackIndexes.isSubset(of: entryIndexes)
        else {
            throw .invalidAutomaticWindow
        }
        automaticWindow = AutomaticDownloadWindow(
            targetTrackIndexes: targetTrackIndexes
        )
    }

    public mutating func promoteToManual() {
        purpose = .manual
        bookFinishedAt = nil
        automaticWindow = nil
        updateIncompleteState()
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
        case automaticWindow
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
        automaticWindow = try container.decodeIfPresent(
            AutomaticDownloadWindow.self,
            forKey: .automaticWindow
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
                    && Self.isValidTimelineMetadata($0)
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
        if let automaticWindow {
            let targets = automaticWindow.targetTrackIndexes
            guard purpose == .automaticCache,
                !targets.isEmpty,
                Set(targets).count == targets.count,
                targets == targets.sorted(),
                Set(targets).isSubset(of: Set(trackIndexes))
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .automaticWindow,
                    in: container,
                    debugDescription:
                        "Automatic cache window metadata is invalid"
                )
            }
        }
        guard purpose == .automaticCache || automaticWindow == nil else {
            throw DecodingError.dataCorruptedError(
                forKey: .automaticWindow,
                in: container,
                debugDescription:
                    "Manual downloads cannot contain an automatic cache window"
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
        try container.encodeIfPresent(
            automaticWindow,
            forKey: .automaticWindow
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

    private static func isValidTimelineMetadata(
        _ entry: DownloadManifestEntry
    ) -> Bool {
        switch (entry.startOffset, entry.duration) {
        case (nil, nil):
            true
        case (let startOffset?, let duration?):
            startOffset.isFinite
                && startOffset >= 0
                && duration.isFinite
                && duration > 0
        case (.some, nil), (nil, .some):
            false
        }
    }

    private mutating func updateIncompleteState() {
        if isCompleteAndFinalized {
            state = .complete
        } else if entries.allSatisfy({ $0.state == .queued }) {
            state = .queued
        } else if entries.contains(where: { $0.state == .downloading }) {
            state = .downloading
        } else if entries.contains(where: { $0.state == .paused }) {
            state = .paused
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
