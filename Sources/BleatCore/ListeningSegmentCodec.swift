import CloudKit
import CryptoKit
import Foundation

public struct ListeningResetAction: Codable, Equatable, Sendable {
    public enum Selection: String, Codable, Sendable {
        case reportingRange, sourceIdentities
    }
    public let selection: Selection
    public let id: UUID
    public let start: Date?
    public let end: Date?
    public let issuedAt: Date

    init(
        id: UUID, start: Date?, end: Date?, issuedAt: Date,
        selection: Selection = .reportingRange
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.issuedAt = issuedAt
        self.selection = selection
    }

    func selects(_ segment: ListeningSlice) -> Bool {
        selection == .reportingRange
            && !(segment.acknowledgedResetIDs ?? []).contains(id)
            && segment.startedAt <= issuedAt
            && StatisticsQuery(start: start, end: end).contains(
                accountID: segment.accountID, date: segment.startedAt)
    }
}

/// Compact accounting/retirement evidence, not a playback timeline. Live
/// entries contain UUID + measured quantities + a semantic digest. Reset entries
/// contain UUIDs only. No per-source timestamp or position is retained.
public struct ListeningSegmentLineage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case observations, resetAnchors
    }
    public let version: Int
    public let kind: Kind
    public let sourceData: Data
    public let resetAction: ListeningResetAction?
}

public struct ListeningSegmentFailure: Error, Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case decoding, encoding, validation, coalescing, resolution, retirement
        case storageRead, storageWrite
    }
    public enum Cause: String, Codable, Sendable {
        case invalidPayload, unsupportedVersion, invalidLineage, payloadTooLarge
        case invalidObservation, activeObservation, identityMismatch,
            sourceConflict
        case metadataConflict, incompatibleBounds, resetConflict,
            globalIdentityCollision
        case incompleteReplacement, missingReceipt, readFailed, writeFailed
        case partialRangeResetUnsupported, ambiguousResetOverlap,
            stalePreparation
    }
    public let stage: Stage
    public let cause: Cause
    public let systemError: PrivateCloudSystemError?
    init(
        _ stage: Stage, _ cause: Cause,
        systemError: PrivateCloudSystemError? = nil
    ) {
        self.stage = stage
        self.cause = cause
        self.systemError = systemError
    }
    public var diagnosticCode: String {
        "listening_segment.\(stage.rawValue).\(cause.rawValue)"
    }
    public var isRetryable: Bool {
        cause == .readFailed || cause == .writeFailed
            || cause == .missingReceipt || cause == .stalePreparation
    }
}

struct ListeningSourceIdentity: Hashable, Sendable {
    let accountID: AccountID
    let id: UUID
}

struct ListeningSourceContribution: Equatable, Sendable {
    let id: UUID
    let realSeconds: Double
    let audiobookSeconds: Double
    let digest: Data
}

struct ListeningResolvedGroup: Sendable {
    let value: ListeningSlice
    let sources: [UUID: ListeningSourceContribution]
    let representations: [ListeningSlice]
}

struct ListeningResetSupplement: Sendable {
    let accountID: AccountID
    let action: ListeningResetAction
    let ids: Set<UUID>
}

struct ListeningResetRemoval: Sendable {
    let accountID: AccountID
    let actionID: UUID
    let ids: Set<UUID>
}

struct ListeningSegmentResolution: Sendable {
    let groups: [ListeningResolvedGroup]
    let resetEnvelopes: [ListeningSlice]
    let supplements: [ListeningResetSupplement]
    let removals: [ListeningResetRemoval]
}

/// The existing canonical segment JSON codec, shared by native payload storage,
/// CloudKit envelopes, proof construction, and history import/export.
enum ListeningSegmentCodec {
    static let currentVersion = 1
    static let maximumSources = 1024
    static let maximumPayloadBytes = 768 * 1024

    static func encode(_ segment: ListeningSlice) throws -> Data {
        try validate(segment)
        let data = try serialize(segment)
        // The sharding reserve applies to extended envelopes. A singleton
        // keeps the existing scalar path and CloudKit's normal record limit.
        guard segment.lineage == nil || data.count <= maximumPayloadBytes else {
            throw ListeningSegmentFailure(.encoding, .payloadTooLarge)
        }
        return data
    }

    private static func serialize(_ segment: ListeningSlice) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return try encoder.encode(segment) } catch {
            throw ListeningSegmentFailure(.encoding, .invalidPayload)
        }
    }

    static func decode(_ data: Data, expectedID: UUID? = nil) throws
        -> ListeningSlice
    {
        let value: ListeningSlice
        do {
            value = try JSONDecoder().decode(ListeningSlice.self, from: data)
        } catch { throw ListeningSegmentFailure(.decoding, .invalidPayload) }
        guard value.lineage == nil || data.count <= maximumPayloadBytes else {
            throw ListeningSegmentFailure(.decoding, .payloadTooLarge)
        }
        if let expectedID, expectedID != value.id {
            throw ListeningSegmentFailure(.decoding, .identityMismatch)
        }
        try validate(value)
        return value
    }

    static func cloudRecord(
        _ segment: ListeningSlice, zoneID: CKRecordZone.ID,
        payload: Data? = nil, existing: CKRecord? = nil
    ) throws -> CKRecord {
        let data = try payload ?? encode(segment)
        guard try decode(data, expectedID: segment.id) == segment else {
            throw ListeningSegmentFailure(.encoding, .sourceConflict)
        }
        let id = CKRecord.ID(
            recordName: "slice.\(segment.id.uuidString.lowercased())",
            zoneID: zoneID)
        let record =
            existing ?? CKRecord(recordType: "ListeningSlice", recordID: id)
        guard record.recordID == id, record.recordType == "ListeningSlice"
        else {
            throw ListeningSegmentFailure(.encoding, .identityMismatch)
        }
        record["payload"] = data as CKRecordValue
        return record
    }

    static func decode(_ record: CKRecord) throws -> ListeningSlice {
        guard record.recordType == "ListeningSlice",
            record.recordID.recordName.hasPrefix("slice."),
            let id = UUID(
                uuidString: String(record.recordID.recordName.dropFirst(6))),
            let data = record["payload"] as? Data
        else { throw ListeningSegmentFailure(.decoding, .invalidPayload) }
        return try decode(data, expectedID: id)
    }

    static func contributions(_ value: ListeningSlice) throws
        -> [ListeningSourceContribution]
    {
        guard let lineage = value.lineage else {
            return [try contribution(value)]
        }
        guard lineage.kind == .observations else { return [] }
        return try decodeContributions(lineage.sourceData)
    }

    static func sourceIDs(_ value: ListeningSlice) throws -> Set<UUID> {
        if value.lineage?.kind == .resetAnchors {
            return try decodeIDs(value.lineage?.sourceData ?? Data())
        }
        return Set(try contributions(value).map(\.id))
    }

    static func equivalent(_ lhs: ListeningSlice, _ rhs: ListeningSlice) -> Bool
    {
        normalizedObservation(lhs) == normalizedObservation(rhs)
    }

    static func equivalentRepresentation(
        _ lhs: ListeningSlice, _ rhs: ListeningSlice
    ) -> Bool {
        normalizedObservation(lhs) == normalizedObservation(rhs)
            && lhs.lineage == rhs.lineage
    }

    private static func normalizedObservation(_ value: ListeningSlice)
        -> ListeningSlice
    {
        func canonical(_ text: String) -> String {
            text.precomposedStringWithCanonicalMapping
        }
        return ListeningSlice(
            id: value.id, accountID: AccountID(rawValue: ""),
            itemID: LibraryItemID(rawValue: canonical(value.itemID.rawValue)),
            sessionID: StatisticsArchive.portableSessionID(
                sessionID: value.sessionID),
            startedAt: value.startedAt, endedAt: value.endedAt,
            startPosition: value.startPosition == 0 ? 0 : value.startPosition,
            endPosition: value.endPosition == 0 ? 0 : value.endPosition,
            realSeconds: value.realSeconds,
            audiobookSeconds: value.audiobookSeconds,
            playbackRate: value.playbackRate, chapterID: value.chapterID,
            chapterTitle: value.chapterTitle.map(canonical),
            chapterStart: value.chapterStart,
            chapterEnd: value.chapterEnd, title: canonical(value.title),
            author: canonical(value.author),
            duration: value.duration, boundaryAfter: value.boundaryAfter,
            acknowledgedResetIDs: value.acknowledgedResetIDs?.sorted {
                $0.uuidString < $1.uuidString
            })
    }

    private static func contribution(_ value: ListeningSlice) throws
        -> ListeningSourceContribution
    {
        // Intentional, versioned semantic fingerprint. Account ownership is
        // scoped separately, and portable session identity survives export/rekey.
        let payload = try serialize(normalizedObservation(value))
        var framed = Data("bleat-source-semantics-v1\u{0}".utf8)
        framed.append(payload)
        return ListeningSourceContribution(
            id: value.id, realSeconds: value.realSeconds,
            audiobookSeconds: value.audiobookSeconds,
            digest: Data(SHA256.hash(data: framed)))
    }

    static func coalesce(_ originals: [ListeningSlice]) throws
        -> [ListeningSlice]
    {
        guard originals.allSatisfy({ $0.lineage == nil }) else {
            throw ListeningSegmentFailure(.coalescing, .invalidLineage)
        }
        for value in originals { try validate(value) }
        let ordered = originals.sorted(by: order)
        var runs: [[ListeningSlice]] = []
        for value in ordered {
            if let previous = runs.last?.last,
                ListeningContinuityPolicy.canJoin(
                    previous, value, evidence: .storedEndpoints),
                (runs.last?.count ?? 0) < maximumSources
            {
                runs[runs.count - 1].append(value)
            } else {
                runs.append([value])
            }
        }
        return try runs.flatMap(boundedRun)
    }

    private static func boundedRun(_ run: [ListeningSlice]) throws
        -> [ListeningSlice]
    {
        let value = try envelope(run)
        do {
            _ = try encode(value)
            return [value]
        } catch let failure as ListeningSegmentFailure
            where failure.cause == .payloadTooLarge && run.count > 1
        {
            let midpoint = run.count / 2
            return try boundedRun(Array(run[..<midpoint]))
                + boundedRun(Array(run[midpoint...]))
        }
    }

    private static func envelope(_ originals: [ListeningSlice]) throws
        -> ListeningSlice
    {
        guard let first = originals.first, let last = originals.last else {
            throw ListeningSegmentFailure(.coalescing, .invalidObservation)
        }
        if originals.count == 1 {
            return replacing(
                first, id: first.id, real: first.realSeconds,
                audio: first.audiobookSeconds, lineage: nil)
        }
        let sources = try originals.map(contribution)
        let data = try encodeContributions(sources)
        let lineage = ListeningSegmentLineage(
            version: currentVersion, kind: .observations,
            sourceData: data, resetAction: nil)
        return replacing(
            first, id: identity(accountID: first.accountID, lineage: lineage),
            end: last, real: total(sources, \.realSeconds),
            audio: total(sources, \.audiobookSeconds), lineage: lineage)
    }

    static func resetEnvelopes(
        accountID: AccountID, action: ListeningResetAction, ids: Set<UUID>
    ) throws -> [ListeningSlice] {
        let ordered = ids.sorted { $0.uuidString < $1.uuidString }
        let chunks: [[UUID]] =
            ordered.isEmpty
            ? [[]]
            : stride(from: 0, to: ordered.count, by: maximumSources).map {
                Array(ordered[$0..<min($0 + maximumSources, ordered.count)])
            }
        return try chunks.map { ids in
            let lineage = ListeningSegmentLineage(
                version: currentVersion, kind: .resetAnchors,
                sourceData: encodeIDs(ids), resetAction: action)
            let value = ListeningSlice(
                id: identity(accountID: accountID, lineage: lineage),
                accountID: accountID, itemID: LibraryItemID(rawValue: ""),
                sessionID: PlaybackSessionID(rawValue: ""),
                startedAt: Date(timeIntervalSince1970: 0),
                endedAt: Date(timeIntervalSince1970: 0),
                startPosition: 0, endPosition: 0, realSeconds: 0,
                audiobookSeconds: 0, playbackRate: 1,
                chapterID: nil, chapterTitle: nil, chapterStart: nil,
                chapterEnd: nil,
                title: "", author: "", duration: 0,
                recordingFormat: .continuousSegment,
                recordingState: .finalized, lineage: lineage)
            _ = try encode(value)
            return value
        }
    }

    static func resolve(
        _ representations: [ListeningSlice], applyingResets: Bool = true
    ) throws -> ListeningSegmentResolution {
        for value in representations { try validate(value, allowActive: true) }
        var groups: [ListeningResolvedGroup] = []
        let resets = representations.filter {
            $0.lineage?.kind == .resetAnchors
        }
        for value in representations.filter({
            $0.lineage?.kind != .resetAnchors
        }).sorted(by: order) {
            let items = try contributions(value)
            var sources: [UUID: ListeningSourceContribution] = [:]
            for item in items { sources[item.id] = item }
            var headers = [value]
            var keep: [ListeningResolvedGroup] = []
            for group in groups {
                guard group.value.accountID == value.accountID,
                    !Set(group.sources.keys).isDisjoint(with: sources.keys)
                else {
                    keep.append(group)
                    continue
                }
                guard sameLogicalContext(group.value, value) else {
                    throw ListeningSegmentFailure(
                        .resolution, .metadataConflict)
                }
                for (id, contribution) in group.sources {
                    if let previous = sources[id], previous != contribution {
                        throw ListeningSegmentFailure(
                            .resolution, .sourceConflict)
                    }
                    sources[id] = contribution
                }
                headers.append(contentsOf: group.representations)
            }
            let merged = try resolvedGroup(headers, sources: sources)
            keep.append(merged)
            groups = keep
        }
        if !applyingResets {
            return ListeningSegmentResolution(
                groups: groups.sorted { order($0.value, $1.value) },
                resetEnvelopes: resets, supplements: [], removals: [])
        }
        struct ResetKey: Hashable {
            let account: AccountID
            let action: UUID
        }
        var actions: [ResetKey: ListeningResetAction] = [:]
        var anchors: [ResetKey: Set<UUID>] = [:]
        for reset in resets {
            guard let action = reset.lineage?.resetAction else {
                throw ListeningSegmentFailure(.resolution, .invalidLineage)
            }
            let key = ResetKey(account: reset.accountID, action: action.id)
            if let previous = actions[key], previous != action {
                throw ListeningSegmentFailure(.resolution, .resetConflict)
            }
            actions[key] = action
            anchors[key, default: []].formUnion(try sourceIDs(reset))
        }
        var removed: Set<ListeningSourceIdentity> = []
        var supplements: [ListeningResetSupplement] = []
        var removals: [ListeningResetRemoval] = []
        // Reporting-day/account resets are stable under overlap union. Resolve
        // them before older exact-identity resets, which cannot expand silently.
        let orderedActions = actions.sorted {
            if $0.value.selection != $1.value.selection {
                return $0.value.selection == .reportingRange
            }
            return $0.key.action.uuidString < $1.key.action.uuidString
        }
        for (key, action) in orderedActions {
            let original = anchors[key] ?? []
            var expanded = original
            for group in groups where group.value.accountID == key.account {
                // Any matching historical representation may seed a reset.
                // Durable source anchors make subsequent overlap expansion monotonic.
                if group.representations.contains(where: action.selects)
                    || !expanded.isDisjoint(with: group.sources.keys)
                {
                    if action.selection == .sourceIdentities,
                        !Set(group.sources.keys).isSubset(of: expanded),
                        !group.sources.keys.allSatisfy({
                            removed.contains(
                                ListeningSourceIdentity(
                                    accountID: key.account, id: $0))
                        })
                    {
                        throw ListeningSegmentFailure(
                            .resolution, .ambiguousResetOverlap)
                    }
                    expanded.formUnion(group.sources.keys)
                }
            }
            removals.append(
                ListeningResetRemoval(
                    accountID: key.account, actionID: action.id, ids: expanded))
            removed.formUnion(
                expanded.map {
                    ListeningSourceIdentity(accountID: key.account, id: $0)
                })
            let extra = expanded.subtracting(original)
            if !extra.isEmpty {
                supplements.append(
                    ListeningResetSupplement(
                        accountID: key.account, action: action, ids: extra))
            }
        }
        groups.removeAll { group in
            group.sources.keys.contains {
                removed.contains(
                    ListeningSourceIdentity(
                        accountID: group.value.accountID, id: $0))
            }
        }
        return ListeningSegmentResolution(
            groups: groups.sorted { order($0.value, $1.value) },
            resetEnvelopes: resets, supplements: supplements, removals: removals
        )
    }

    private static func resolvedGroup(
        _ representations: [ListeningSlice],
        sources: [UUID: ListeningSourceContribution]
    ) throws -> ListeningResolvedGroup {
        guard let first = representations.min(by: order),
            let last = representations.max(by: { $0.endedAt < $1.endedAt })
        else {
            throw ListeningSegmentFailure(.resolution, .invalidLineage)
        }
        var reach = first.endedAt
        for header in representations.sorted(by: order) {
            guard sameLogicalContext(first, header),
                header.startedAt
                    <= reach.addingTimeInterval(
                        ListeningContinuityPolicy.wallGapTolerance),
                header.startPosition
                    + ListeningContinuityPolicy.storedMediaGapTolerance
                    >= first.startPosition
            else {
                throw ListeningSegmentFailure(.resolution, .incompatibleBounds)
            }
            reach = max(reach, header.endedAt)
        }
        if representations.count == 1 {
            return ListeningResolvedGroup(
                value: first, sources: sources, representations: representations
            )
        }
        // This value is a transient logical view, never another physical upload.
        let lineage = ListeningSegmentLineage(
            version: currentVersion, kind: .observations,
            sourceData: try encodeContributions(
                Array(sources.values), bounded: false), resetAction: nil)
        let session =
            representations.first {
                !$0.sessionID.rawValue.hasPrefix("portable:")
            }?.sessionID ?? first.sessionID
        let value = replacing(
            first.replacingSessionID(session),
            id: identity(accountID: first.accountID, lineage: lineage),
            end: last, real: total(Array(sources.values), \.realSeconds),
            audio: total(Array(sources.values), \.audiobookSeconds),
            lineage: nil)
        return ListeningResolvedGroup(
            value: value, sources: sources, representations: representations)
    }

    private static func sameLogicalContext(
        _ lhs: ListeningSlice, _ rhs: ListeningSlice
    ) -> Bool {
        ListeningContinuityPolicy.sameContext(
            lhs.replacingSessionID(
                StatisticsArchive.portableSessionID(sessionID: lhs.sessionID)),
            rhs.replacingSessionID(
                StatisticsArchive.portableSessionID(sessionID: rhs.sessionID)))
            && ListeningContinuityPolicy.sameReportingDay(
                lhs.startedAt, rhs.startedAt)
    }

    static func scalar(_ value: ListeningSlice) -> ListeningSlice {
        ListeningSlice(
            id: value.id, accountID: value.accountID, itemID: value.itemID,
            sessionID: value.sessionID, startedAt: value.startedAt,
            endedAt: value.endedAt,
            startPosition: value.startPosition, endPosition: value.endPosition,
            realSeconds: value.realSeconds,
            audiobookSeconds: value.audiobookSeconds,
            playbackRate: value.playbackRate, chapterID: value.chapterID,
            chapterTitle: value.chapterTitle,
            chapterStart: value.chapterStart, chapterEnd: value.chapterEnd,
            title: value.title,
            author: value.author, duration: value.duration,
            recordingFormat: value.recordingFormat,
            recordingState: value.recordingState,
            boundaryAfter: value.boundaryAfter,
            acknowledgedResetIDs: value.acknowledgedResetIDs)
    }

    private static func replacing(
        _ first: ListeningSlice, id: UUID, end: ListeningSlice? = nil,
        real: Double, audio: Double, lineage: ListeningSegmentLineage?
    ) -> ListeningSlice {
        let last = end ?? first
        return ListeningSlice(
            id: id, accountID: first.accountID, itemID: first.itemID,
            sessionID: first.sessionID, startedAt: first.startedAt,
            endedAt: last.endedAt,
            startPosition: first.startPosition, endPosition: last.endPosition,
            realSeconds: real, audiobookSeconds: audio,
            playbackRate: first.playbackRate,
            chapterID: first.chapterID, chapterTitle: first.chapterTitle,
            chapterStart: first.chapterStart, chapterEnd: first.chapterEnd,
            title: first.title, author: first.author, duration: first.duration,
            recordingFormat: .continuousSegment, recordingState: .finalized,
            boundaryAfter: last.boundaryAfter, lineage: lineage,
            acknowledgedResetIDs: first.acknowledgedResetIDs)
    }

    private static func order(_ lhs: ListeningSlice, _ rhs: ListeningSlice)
        -> Bool
    {
        if lhs.accountID != rhs.accountID {
            return lhs.accountID.rawValue < rhs.accountID.rawValue
        }
        let leftSession = StatisticsArchive.portableSessionID(
            sessionID: lhs.sessionID)
        let rightSession = StatisticsArchive.portableSessionID(
            sessionID: rhs.sessionID)
        if leftSession != rightSession {
            return leftSession.rawValue < rightSession.rawValue
        }
        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt < rhs.startedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func total(
        _ sources: [ListeningSourceContribution],
        _ key: KeyPath<ListeningSourceContribution, Double>
    ) -> Double {
        sources.sorted { $0.id.uuidString < $1.id.uuidString }.reduce(0) {
            $0 + $1[keyPath: key]
        }
    }

    static func identity(accountID: AccountID, lineage: ListeningSegmentLineage)
        -> UUID
    {
        var data = Data("bleat-segment-lineage-v1\u{0}".utf8)
        func field(_ value: Data) {
            data.append(contentsOf: String(value.count).utf8)
            data.append(0x3a)
            data.append(value)
        }
        field(Data(accountID.rawValue.utf8))
        field(Data(lineage.kind.rawValue.utf8))
        // Fixed-width lineage is intentionally part of the identity protocol.
        field(lineage.sourceData)
        if let reset = lineage.resetAction {
            field(Data(reset.id.uuidString.lowercased().utf8))
            field(Data(reset.selection.rawValue.utf8))
            for date in [reset.start, reset.end, Optional(reset.issuedAt)] {
                if let date {
                    let seconds = date.timeIntervalSinceReferenceDate
                    var bits = (seconds == 0 ? 0.0 : seconds).bitPattern
                        .littleEndian
                    field(Data([1]) + withUnsafeBytes(of: &bits) { Data($0) })
                } else {
                    field(Data([0]))
                }
            }
        }
        let hash = Array(SHA256.hash(data: data).prefix(16))
        return UUID(
            uuid: (
                hash[0], hash[1], hash[2], hash[3], hash[4], hash[5],
                (hash[6] & 0x0f) | 0x50, hash[7], (hash[8] & 0x3f) | 0x80,
                hash[9], hash[10], hash[11], hash[12], hash[13], hash[14],
                hash[15]
            ))
    }

    private static func encodeIDs(_ ids: [UUID]) -> Data {
        var result = Data()
        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            var uuid = id.uuid
            withUnsafeBytes(of: &uuid) { result.append(contentsOf: $0) }
        }
        return result
    }

    private static func decodeIDs(_ data: Data) throws -> Set<UUID> {
        guard data.count % 16 == 0 else {
            throw ListeningSegmentFailure(.validation, .invalidLineage)
        }
        let bytes = Array(data)
        var result: Set<UUID> = []
        for start in stride(from: 0, to: bytes.count, by: 16) {
            let id = uuid(bytes, start)
            guard result.insert(id).inserted else {
                throw ListeningSegmentFailure(.validation, .invalidLineage)
            }
        }
        return result
    }

    private static func encodeContributions(
        _ values: [ListeningSourceContribution], bounded: Bool = true
    ) throws -> Data {
        if bounded, values.count > maximumSources {
            throw ListeningSegmentFailure(.encoding, .payloadTooLarge)
        }
        var data = Data()
        var seen: Set<UUID> = []
        for value in values.sorted(by: { $0.id.uuidString < $1.id.uuidString })
        {
            guard seen.insert(value.id).inserted, value.digest.count == 32
            else {
                throw ListeningSegmentFailure(.encoding, .invalidLineage)
            }
            data.append(encodeIDs([value.id]))
            var real = value.realSeconds.bitPattern.littleEndian
            var audio = value.audiobookSeconds.bitPattern.littleEndian
            withUnsafeBytes(of: &real) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &audio) { data.append(contentsOf: $0) }
            data.append(value.digest)
        }
        return data
    }

    private static func decodeContributions(_ data: Data) throws
        -> [ListeningSourceContribution]
    {
        guard !data.isEmpty, data.count % 64 == 0,
            data.count / 64 <= maximumSources
        else {
            throw ListeningSegmentFailure(.validation, .invalidLineage)
        }
        let bytes = Array(data)
        var result: [ListeningSourceContribution] = []
        var seen: Set<UUID> = []
        for start in stride(from: 0, to: bytes.count, by: 64) {
            let id = uuid(bytes, start)
            let real = Double(bitPattern: uint64(bytes, start + 16))
            let audio = Double(bitPattern: uint64(bytes, start + 24))
            guard seen.insert(id).inserted, real.isFinite, real > 0,
                audio.isFinite, audio > 0
            else {
                throw ListeningSegmentFailure(.validation, .invalidLineage)
            }
            result.append(
                ListeningSourceContribution(
                    id: id, realSeconds: real,
                    audiobookSeconds: audio,
                    digest: Data(bytes[(start + 32)..<(start + 64)])))
        }
        return result
    }

    private static func uuid(_ bytes: [UInt8], _ i: Int) -> UUID {
        UUID(
            uuid: (
                bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3],
                bytes[i + 4], bytes[i + 5],
                bytes[i + 6], bytes[i + 7], bytes[i + 8], bytes[i + 9],
                bytes[i + 10], bytes[i + 11],
                bytes[i + 12], bytes[i + 13], bytes[i + 14], bytes[i + 15]
            ))
    }

    private static func uint64(_ bytes: [UInt8], _ start: Int) -> UInt64 {
        (0..<8).reduce(0) { $0 | (UInt64(bytes[start + $1]) << ($1 * 8)) }
    }

    static func validate(_ value: ListeningSlice, allowActive: Bool = false)
        throws
    {
        guard let lineage = value.lineage else {
            return try validateObservation(value, allowActive: allowActive)
        }
        guard lineage.version == currentVersion else {
            throw ListeningSegmentFailure(.validation, .unsupportedVersion)
        }
        guard value.recordingState == .finalized,
            value.recordingFormat == .continuousSegment,
            !value.accountID.rawValue.isEmpty,
            value.id == identity(accountID: value.accountID, lineage: lineage)
        else { throw ListeningSegmentFailure(.validation, .identityMismatch) }
        switch lineage.kind {
        case .observations:
            try validateObservation(value)
            let sources = try decodeContributions(lineage.sourceData)
            guard lineage.resetAction == nil,
                value.endedAt
                    <= StatisticsQuery.reportingCalendar.startOfDay(
                        for: value.startedAt
                    ).addingTimeInterval(86_400),
                value.realSeconds == total(sources, \.realSeconds),
                value.audiobookSeconds == total(sources, \.audiobookSeconds)
            else { throw ListeningSegmentFailure(.validation, .invalidLineage) }
        case .resetAnchors:
            guard let action = lineage.resetAction,
                action.issuedAt.timeIntervalSinceReferenceDate.isFinite,
                action.start?.timeIntervalSinceReferenceDate.isFinite != false,
                action.end?.timeIntervalSinceReferenceDate.isFinite != false,
                action.start == nil || action.end == nil
                    || (action.start ?? .distantPast)
                        < (action.end ?? .distantFuture),
                action.selection == .sourceIdentities
                    || reportingRange(start: action.start, end: action.end),
                lineage.sourceData.count / 16 <= maximumSources,
                value.itemID.rawValue.isEmpty, value.sessionID.rawValue.isEmpty,
                value.title.isEmpty, value.author.isEmpty, value.duration == 0,
                value.realSeconds == 0, value.audiobookSeconds == 0,
                value.startPosition == 0, value.endPosition == 0,
                value.startedAt == Date(timeIntervalSince1970: 0),
                value.endedAt == Date(timeIntervalSince1970: 0)
            else { throw ListeningSegmentFailure(.validation, .invalidLineage) }
            _ = try decodeIDs(lineage.sourceData)
        }
    }

    static func reportingRange(start: Date?, end: Date?) -> Bool {
        [start, end].compactMap { $0 }.allSatisfy {
            StatisticsQuery.reportingCalendar.startOfDay(for: $0) == $0
        }
    }

    private static func validateObservation(
        _ value: ListeningSlice, allowActive: Bool = false
    ) throws {
        guard allowActive || value.recordingState != .active else {
            throw ListeningSegmentFailure(.validation, .activeObservation)
        }
        let finite =
            [
                value.startedAt.timeIntervalSinceReferenceDate,
                value.endedAt.timeIntervalSinceReferenceDate,
                value.startPosition, value.endPosition, value.realSeconds,
                value.audiobookSeconds,
                value.playbackRate, value.duration,
            ] + [value.chapterStart, value.chapterEnd].compactMap { $0 }
        guard finite.allSatisfy(\.isFinite), !value.accountID.rawValue.isEmpty,
            !value.itemID.rawValue.isEmpty, !value.sessionID.rawValue.isEmpty,
            value.startedAt <= value.endedAt, value.startPosition >= 0,
            value.endPosition >= value.startPosition,
            value.realSeconds > 0, value.audiobookSeconds > 0,
            value.playbackRate > 0, value.duration > 0
        else { throw ListeningSegmentFailure(.validation, .invalidObservation) }
    }
}
