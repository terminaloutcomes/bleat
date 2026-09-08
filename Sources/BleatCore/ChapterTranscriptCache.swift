import Foundation
import SwiftData

public struct CachedTranscriptSegment: Codable, Equatable, Sendable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let text: String

    public init(
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        text: String
    ) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
    }
}

public struct CachedChapterTranscript: Codable, Equatable, Sendable {
    public let chapterID: Int
    public let chapterTitle: String
    public let chapterStartMilliseconds: Int64
    public let chapterEndMilliseconds: Int64
    public let localeIdentifier: String
    public let segments: [CachedTranscriptSegment]
    public let updatedAt: Date

    public init(
        chapterID: Int,
        chapterTitle: String,
        chapterStartMilliseconds: Int64,
        chapterEndMilliseconds: Int64,
        localeIdentifier: String,
        segments: [CachedTranscriptSegment],
        updatedAt: Date = Date()
    ) {
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.chapterStartMilliseconds = chapterStartMilliseconds
        self.chapterEndMilliseconds = chapterEndMilliseconds
        self.localeIdentifier = localeIdentifier
        self.segments = segments
        self.updatedAt = updatedAt
    }
}

public struct CachedChapterTranscriptMatch: Equatable, Sendable {
    public let chapterID: Int
    public let chapterTitle: String
    public let segment: CachedTranscriptSegment

    public init(
        chapterID: Int,
        chapterTitle: String,
        segment: CachedTranscriptSegment
    ) {
        self.chapterID = chapterID
        self.chapterTitle = chapterTitle
        self.segment = segment
    }
}

public enum CachedChapterTranscriptionTaskOutcome:
    String, Codable, Equatable, Sendable
{
    case succeeded
    case failed
    case cancelled
}

public enum CachedChapterTranscriptionTaskFailure:
    String, Codable, Equatable, Sendable
{
    case jobMissingAudio
    case jobSourceChanged
    case jobChapterLayoutChanged
    case jobInsufficientSourceIdentity
    case jobInvalidCheckpoint
    case jobStaleRevision
    case jobPersistenceFailed
    case audioNotDownloaded
    case localAudioUnavailable
    case invalidChapterRange
    case cacheSaveFailed
    case cancelled
    case operatingSystemUnsupported
    case unavailableOnDevice
    case unsupportedLocale
    case languageAssetsUnavailable
    case languageAssetInstallationFailed
    case audioFileUnreadable
    case chapterExtractionUnavailable
    case chapterExtractionFailed
    case analyzerInputFailed
    case analyzerFinalizationFailed
    case resultStreamFailed
}

public struct CachedChapterTranscriptionTaskState:
    Codable, Equatable, Sendable
{
    public let taskID: UUID
    public let selectedChapterIDs: [Int]
    public let completedChapterIDs: [Int]
    public let currentChapterID: Int?
    public let outcome: CachedChapterTranscriptionTaskOutcome
    public let failure: CachedChapterTranscriptionTaskFailure?
    public let startedAt: Date
    public let finishedAt: Date
    public let durationMilliseconds: Int64

    public init(
        taskID: UUID,
        selectedChapterIDs: [Int],
        completedChapterIDs: [Int],
        currentChapterID: Int?,
        outcome: CachedChapterTranscriptionTaskOutcome,
        failure: CachedChapterTranscriptionTaskFailure?,
        startedAt: Date,
        finishedAt: Date,
        durationMilliseconds: Int64
    ) {
        self.taskID = taskID
        self.selectedChapterIDs = selectedChapterIDs
        self.completedChapterIDs = completedChapterIDs
        self.currentChapterID = currentChapterID
        self.outcome = outcome
        self.failure = failure
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.durationMilliseconds = durationMilliseconds
    }
}

public enum CachedChapterTranscriptSearch {
    public static func matches(
        query: String,
        in transcripts: [CachedChapterTranscript]
    ) -> [CachedChapterTranscriptMatch] {
        let terms = query.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            return []
        }

        return transcripts.flatMap { transcript in
            transcript.segments.compactMap { segment in
                guard
                    terms.allSatisfy({ term in
                        segment.text.range(
                            of: term,
                            options: .caseInsensitive
                        ) != nil
                    })
                else {
                    return nil
                }
                return CachedChapterTranscriptMatch(
                    chapterID: transcript.chapterID,
                    chapterTitle: transcript.chapterTitle,
                    segment: segment
                )
            }
        }
    }
}

public enum ChapterTranscriptCacheError: Error, Equatable, Sendable {
    case job(ChapterTranscriptionJobFailure)
    case invalidAccountID
    case invalidItemID
    case invalidTranscript
    case invalidStoredTranscript
    case invalidTaskState
    case invalidStoredTaskState
    case encodingFailed
    case persistenceFailed
}

@Model
public final class CachedChapterTranscriptRecord {
    @Attribute(.unique)
    var cacheKey: String
    var accountID: String
    var libraryItemID: String
    var chapterID: Int
    var payload: Data
    var updatedAt: Date

    init(
        cacheKey: String,
        accountID: String,
        libraryItemID: String,
        chapterID: Int,
        payload: Data,
        updatedAt: Date
    ) {
        self.cacheKey = cacheKey
        self.accountID = accountID
        self.libraryItemID = libraryItemID
        self.chapterID = chapterID
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

@Model
public final class CachedChapterTranscriptionTaskRecord {
    @Attribute(.unique)
    var taskKey: String
    var accountID: String
    var libraryItemID: String
    var payload: Data
    var finishedAt: Date

    init(
        taskKey: String,
        accountID: String,
        libraryItemID: String,
        payload: Data,
        finishedAt: Date
    ) {
        self.taskKey = taskKey
        self.accountID = accountID
        self.libraryItemID = libraryItemID
        self.payload = payload
        self.finishedAt = finishedAt
    }
}

/// Approved synchronous SwiftData boundary (2026-09-08). Contexts are created
/// lazily on this actor rather than by an initializer that may run on MainActor.
/// SwiftData has no native asynchronous fetch/save API; replace this boundary
/// when one becomes available. No model instances leave the actor.
public actor ChapterTranscriptCache {
    public nonisolated let modelContainer: ModelContainer
    lazy var modelContext = ModelContext(modelContainer)

    public init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    public func save(
        _ transcript: CachedChapterTranscript,
        accountID: AccountID,
        itemID: LibraryItemID
    ) throws(ChapterTranscriptCacheError) {
        try validate(accountID: accountID, itemID: itemID)
        guard Self.isValid(transcript) else {
            throw .invalidTranscript
        }

        try stageTranscript(transcript, accountID: accountID, itemID: itemID)
        try saveContext()
    }

    func stageTranscript(
        _ transcript: CachedChapterTranscript, accountID: AccountID,
        itemID: LibraryItemID, context: ModelContext? = nil
    ) throws(ChapterTranscriptCacheError) {
        let context = context ?? modelContext
        let payload: Data
        do {
            payload = try JSONEncoder().encode(transcript)
        } catch {
            throw .encodingFailed
        }
        let key = Self.key(
            accountID: accountID,
            itemID: itemID,
            chapterID: transcript.chapterID
        )
        let records = try records(context: context)
        if let record = records.first(where: { $0.cacheKey == key }) {
            record.payload = payload
            record.updatedAt = transcript.updatedAt
        } else {
            context.insert(
                CachedChapterTranscriptRecord(
                    cacheKey: key,
                    accountID: accountID.rawValue,
                    libraryItemID: itemID.rawValue,
                    chapterID: transcript.chapterID,
                    payload: payload,
                    updatedAt: transcript.updatedAt
                ))
        }
    }

    public func transcripts(
        accountID: AccountID,
        itemID: LibraryItemID
    ) throws(ChapterTranscriptCacheError) -> [CachedChapterTranscript] {
        try validate(accountID: accountID, itemID: itemID)
        let readContext = ModelContext(modelContainer)
        let scopedRecords = try records(context: readContext).filter {
            $0.accountID == accountID.rawValue
                && $0.libraryItemID == itemID.rawValue
        }
        var transcripts: [CachedChapterTranscript] = []
        for record in scopedRecords {
            let transcript: CachedChapterTranscript
            do {
                transcript = try JSONDecoder().decode(
                    CachedChapterTranscript.self,
                    from: record.payload
                )
            } catch {
                throw ChapterTranscriptCacheError.invalidStoredTranscript
            }
            guard Self.isValid(transcript),
                transcript.chapterID == record.chapterID,
                record.cacheKey
                    == Self.key(
                        accountID: accountID,
                        itemID: itemID,
                        chapterID: transcript.chapterID
                    )
            else {
                throw ChapterTranscriptCacheError.invalidStoredTranscript
            }
            transcripts.append(transcript)
        }
        return transcripts.sorted {
            ($0.chapterStartMilliseconds, $0.chapterID)
                < ($1.chapterStartMilliseconds, $1.chapterID)
        }
    }

    public func saveTaskState(
        _ state: CachedChapterTranscriptionTaskState,
        accountID: AccountID,
        itemID: LibraryItemID
    ) throws(ChapterTranscriptCacheError) {
        try validate(accountID: accountID, itemID: itemID)
        guard Self.isValid(state) else {
            throw .invalidTaskState
        }
        let payload: Data
        do {
            payload = try JSONEncoder().encode(state)
        } catch {
            throw .encodingFailed
        }
        let key = Self.taskKey(accountID: accountID, itemID: itemID)
        if let record = try taskRecords().first(where: {
            $0.taskKey == key
        }) {
            guard record.finishedAt <= state.finishedAt else {
                return
            }
            record.payload = payload
            record.finishedAt = state.finishedAt
        } else {
            modelContext.insert(
                CachedChapterTranscriptionTaskRecord(
                    taskKey: key,
                    accountID: accountID.rawValue,
                    libraryItemID: itemID.rawValue,
                    payload: payload,
                    finishedAt: state.finishedAt
                ))
        }
        try saveContext()
    }

    public func taskState(
        accountID: AccountID,
        itemID: LibraryItemID
    ) throws(ChapterTranscriptCacheError)
        -> CachedChapterTranscriptionTaskState?
    {
        try validate(accountID: accountID, itemID: itemID)
        let key = Self.taskKey(accountID: accountID, itemID: itemID)
        guard
            let record = try taskRecords().first(where: {
                $0.taskKey == key
            })
        else {
            return nil
        }
        let state: CachedChapterTranscriptionTaskState
        do {
            state = try JSONDecoder().decode(
                CachedChapterTranscriptionTaskState.self,
                from: record.payload
            )
        } catch {
            throw .invalidStoredTaskState
        }
        guard Self.isValid(state),
            record.accountID == accountID.rawValue,
            record.libraryItemID == itemID.rawValue,
            record.taskKey == key,
            record.finishedAt == state.finishedAt
        else {
            throw .invalidStoredTaskState
        }
        return state
    }

    public func removeBook(
        accountID: AccountID,
        itemID: LibraryItemID
    ) throws(ChapterTranscriptCacheError) {
        try validate(accountID: accountID, itemID: itemID)
        for record in try records()
        where record.accountID == accountID.rawValue
            && record.libraryItemID == itemID.rawValue
        {
            modelContext.delete(record)
        }
        for record in try jobRecords()
        where record.accountID == accountID.rawValue
            && record.libraryItemID == itemID.rawValue
        { modelContext.delete(record) }
        for record in try taskRecords()
        where record.accountID == accountID.rawValue
            && record.libraryItemID == itemID.rawValue
        {
            modelContext.delete(record)
        }
        try saveContext()
    }

    public func containsData(
        accountID: AccountID,
        itemID: LibraryItemID
    ) throws(ChapterTranscriptCacheError) -> Bool {
        try validate(accountID: accountID, itemID: itemID)
        let hasTranscript = try records().contains {
            $0.accountID == accountID.rawValue
                && $0.libraryItemID == itemID.rawValue
        }
        if hasTranscript {
            return true
        }
        if try jobRecords().contains(where: {
            $0.accountID == accountID.rawValue
                && $0.libraryItemID == itemID.rawValue
        }) {
            return true
        }
        return try taskRecords().contains {
            $0.accountID == accountID.rawValue
                && $0.libraryItemID == itemID.rawValue
        }
    }

    public func removeAccount(
        _ accountID: AccountID
    ) throws(ChapterTranscriptCacheError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        for record in try records()
        where record.accountID == accountID.rawValue {
            modelContext.delete(record)
        }
        for record in try jobRecords()
        where record.accountID == accountID.rawValue {
            modelContext.delete(record)
        }
        for record in try taskRecords()
        where record.accountID == accountID.rawValue {
            modelContext.delete(record)
        }
        try saveContext()
    }

    func validate(
        accountID: AccountID,
        itemID: LibraryItemID
    ) throws(ChapterTranscriptCacheError) {
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !itemID.rawValue.isEmpty else {
            throw .invalidItemID
        }
    }

    private func records(context: ModelContext? = nil)
        throws(ChapterTranscriptCacheError)
        -> [CachedChapterTranscriptRecord]
    {
        do {
            return try (context ?? modelContext).fetch(
                FetchDescriptor<CachedChapterTranscriptRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    func saveContext() throws(ChapterTranscriptCacheError) {
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw .persistenceFailed
        }
    }

    private func taskRecords() throws(ChapterTranscriptCacheError)
        -> [CachedChapterTranscriptionTaskRecord]
    {
        do {
            return try modelContext.fetch(
                FetchDescriptor<CachedChapterTranscriptionTaskRecord>()
            )
        } catch {
            throw .persistenceFailed
        }
    }

    static func isValid(
        _ transcript: CachedChapterTranscript
    ) -> Bool {
        transcript.chapterStartMilliseconds >= 0
            && transcript.chapterEndMilliseconds
                >= transcript.chapterStartMilliseconds
            && !transcript.localeIdentifier.isEmpty
            && transcript.updatedAt.timeIntervalSinceReferenceDate.isFinite
            && transcript.segments.allSatisfy { segment in
                segment.startMilliseconds >= 0
                    && segment.endMilliseconds >= segment.startMilliseconds
                    && !segment.text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            }
    }

    static func isValid(
        _ state: CachedChapterTranscriptionTaskState
    ) -> Bool {
        let selected = state.selectedChapterIDs
        let completed = state.completedChapterIDs
        let selectedSet = Set(selected)
        guard !selected.isEmpty,
            selected == selected.sorted(),
            selectedSet.count == selected.count,
            completed == completed.sorted(),
            Set(completed).count == completed.count,
            completed.allSatisfy({ selectedSet.contains($0) }),
            state.currentChapterID.map({ selectedSet.contains($0) }) != false,
            state.startedAt.timeIntervalSinceReferenceDate.isFinite,
            state.finishedAt.timeIntervalSinceReferenceDate.isFinite,
            state.finishedAt >= state.startedAt,
            state.durationMilliseconds >= 0
        else {
            return false
        }
        switch state.outcome {
        case .succeeded:
            return state.failure == nil && completed == selected
        case .failed:
            return state.failure != nil && state.failure != .cancelled
        case .cancelled:
            return state.failure == .cancelled
        }
    }

    private static func key(
        accountID: AccountID,
        itemID: LibraryItemID,
        chapterID: Int
    ) -> String {
        [
            accountID.rawValue,
            itemID.rawValue,
            String(chapterID),
        ].map {
            "\($0.utf8.count):\($0)"
        }.joined()
    }

    static func taskKey(
        accountID: AccountID,
        itemID: LibraryItemID
    ) -> String {
        [
            accountID.rawValue,
            itemID.rawValue,
        ].map {
            "\($0.utf8.count):\($0)"
        }.joined()
    }
}
