import Foundation
import SwiftData

public enum ChapterTranscriptionJobFailure: String, Codable, Error, Equatable,
    Sendable
{
    case missingAudio
    case sourceChanged
    case chapterLayoutChanged
    case insufficientSourceIdentity
    case invalidCheckpoint
    case staleRevision
    case persistenceFailed
}

public enum ChapterTranscriptionJobChapterState: Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed(CachedChapterTranscriptionTaskFailure)
}

public struct ChapterTranscriptionJobChapter: Codable, Equatable, Sendable {
    public let id: Int
    public let start: Double
    public let end: Double
    public var state: ChapterTranscriptionJobChapterState

    public init(
        id: Int, start: Double, end: Double,
        state: ChapterTranscriptionJobChapterState = .pending
    ) {
        self.id = id
        self.start = start
        self.end = end
        self.state = state
    }
}

/// Local metadata identity, deliberately not a content digest. No paths are stored.
public struct ChapterTranscriptionSourceTrack: Codable, Equatable, Sendable {
    public let index: Int
    public let inode: String?
    public let expectedBytes: Int64
    public let observedBytes: Int64
    public let start: Double
    public let duration: Double
    public let validator: DownloadValidator?
    public let fileIdentifier: UInt64
    public let modifiedAt: Date

    public init(
        index: Int, inode: String?, expectedBytes: Int64, observedBytes: Int64,
        start: Double, duration: Double, validator: DownloadValidator?,
        fileIdentifier: UInt64, modifiedAt: Date
    ) {
        self.index = index
        self.inode = inode
        self.expectedBytes = expectedBytes
        self.observedBytes = observedBytes
        self.start = start
        self.duration = duration
        self.validator = validator
        self.fileIdentifier = fileIdentifier
        self.modifiedAt = modifiedAt
    }
}

public struct ChapterTranscriptionSourceIdentity: Codable, Equatable, Sendable {
    public let downloadID: DownloadID
    public let tracks: [ChapterTranscriptionSourceTrack]

    public init(
        downloadID: DownloadID, tracks: [ChapterTranscriptionSourceTrack]
    ) {
        self.downloadID = downloadID
        self.tracks = tracks.sorted { $0.index < $1.index }
    }
}

public struct ChapterTranscriptionJob: Codable, Equatable, Sendable {
    public let id: UUID
    public var revision: Int
    public let localeIdentifier: String
    public var chapters: [ChapterTranscriptionJobChapter]
    public var source: ChapterTranscriptionSourceIdentity?
    public let startedAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(), localeIdentifier: String,
        chapters: [ChapterTranscriptionJobChapter], startedAt: Date = Date()
    ) {
        self.id = id
        revision = 0
        self.localeIdentifier = localeIdentifier
        self.chapters = chapters.sorted { $0.id < $1.id }
        source = nil
        self.startedAt = startedAt
        updatedAt = startedAt
    }

    public var completedChapterIDs: [Int] {
        chapters.filter { $0.state == .completed }.map(\.id)
    }

    public var unfinishedChapters: [ChapterTranscriptionJobChapter] {
        chapters.filter { $0.state != .completed }
    }

    public var isValid: Bool {
        !chapters.isEmpty && !localeIdentifier.isEmpty && revision >= 0
            && revision < Int.max
            && chapters.map(\.id) == chapters.map(\.id).sorted()
            && Set(chapters.map(\.id)).count == chapters.count
            && chapters.allSatisfy {
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                    && $0.end > $0.start
            }
            && chapters.filter { $0.state == .running }.count <= 1
            && (source != nil || chapters.allSatisfy { $0.state == .pending })
            && startedAt.timeIntervalSinceReferenceDate.isFinite
            && updatedAt.timeIntervalSinceReferenceDate.isFinite
            && updatedAt >= startedAt
            && (source.map { source in
                !source.downloadID.rawValue.isEmpty && !source.tracks.isEmpty
                    && Set(source.tracks.map(\.index)).count
                        == source.tracks.count
                    && source.tracks.allSatisfy {
                        $0.expectedBytes > 0
                            && $0.observedBytes == $0.expectedBytes
                            && $0.start.isFinite && $0.start >= 0
                            && $0.duration.isFinite && $0.duration > 0
                            && $0.modifiedAt.timeIntervalSinceReferenceDate
                                .isFinite
                    }
            } ?? true)
    }
}

@Model
public final class CachedChapterTranscriptionJobRecord {
    @Attribute(.unique) var jobKey: String
    var accountID: String
    var libraryItemID: String
    var payload: Data
    var updatedAt: Date

    init(
        jobKey: String, accountID: String, libraryItemID: String, payload: Data,
        updatedAt: Date
    ) {
        self.jobKey = jobKey
        self.accountID = accountID
        self.libraryItemID = libraryItemID
        self.payload = payload
        self.updatedAt = updatedAt
    }
}

extension ChapterTranscriptCache {
    public func job(accountID: AccountID, itemID: LibraryItemID)
        throws(ChapterTranscriptCacheError) -> ChapterTranscriptionJob?
    {
        try validate(accountID: accountID, itemID: itemID)
        let context = ModelContext(modelContainer)
        guard
            let record = try jobRecords(context: context).first(where: {
                $0.accountID == accountID.rawValue
                    && $0.libraryItemID == itemID.rawValue
            })
        else { return nil }
        let job: ChapterTranscriptionJob
        do {
            job = try JSONDecoder().decode(
                ChapterTranscriptionJob.self, from: record.payload)
        } catch { throw .job(.invalidCheckpoint) }
        guard job.isValid,
            record.jobKey == Self.taskKey(accountID: accountID, itemID: itemID),
            record.updatedAt == job.updatedAt
        else { throw .job(.invalidCheckpoint) }
        return job
    }

    /// Compare-and-swap the checkpoint. A chapter transcript and its completion share one commit.
    public func saveJob(
        _ job: ChapterTranscriptionJob,
        replacing expected: ChapterTranscriptionJob?,
        transcript: CachedChapterTranscript? = nil,
        accountID: AccountID, itemID: LibraryItemID
    ) throws(ChapterTranscriptCacheError) {
        try validate(accountID: accountID, itemID: itemID)
        let current = try self.job(accountID: accountID, itemID: itemID)
        guard current == expected else { throw .job(.staleRevision) }
        guard job.isValid else { throw .job(.invalidCheckpoint) }
        if let expected, expected.id == job.id {
            guard expected.revision < Int.max,
                job.revision == expected.revision + 1,
                expected.localeIdentifier == job.localeIdentifier,
                expected.chapters.map({ [$0.start, $0.end] })
                    == job.chapters.map({ [$0.start, $0.end] }),
                expected.chapters.map(\.id) == job.chapters.map(\.id),
                expected.source == nil || expected.source == job.source,
                expected.completedChapterIDs.allSatisfy({
                    job.completedChapterIDs.contains($0)
                })
            else { throw .job(.invalidCheckpoint) }
        } else {
            guard job.revision == 0, job.source == nil,
                job.chapters.allSatisfy({ $0.state == .pending }),
                transcript == nil
            else { throw .job(.invalidCheckpoint) }
        }
        let newCompleted = Set(job.completedChapterIDs).subtracting(
            expected?.completedChapterIDs ?? [])
        if let transcript {
            guard Self.isValid(transcript),
                newCompleted == [transcript.chapterID],
                let chapter = job.chapters.first(where: {
                    $0.id == transcript.chapterID
                }),
                Double(transcript.chapterStartMilliseconds)
                    == (chapter.start * 1_000).rounded(),
                Double(transcript.chapterEndMilliseconds)
                    == (chapter.end * 1_000).rounded(),
                transcript.localeIdentifier == job.localeIdentifier
            else { throw .job(.invalidCheckpoint) }
        } else if !newCompleted.isEmpty {
            throw .job(.invalidCheckpoint)
        }
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        do {
            let payload = try JSONEncoder().encode(job)
            let key = Self.taskKey(accountID: accountID, itemID: itemID)
            if let record = try jobRecords(context: context).first(where: {
                $0.jobKey == key
            }) {
                record.payload = payload
                record.updatedAt = job.updatedAt
            } else {
                context.insert(
                    CachedChapterTranscriptionJobRecord(
                        jobKey: key,
                        accountID: accountID.rawValue,
                        libraryItemID: itemID.rawValue,
                        payload: payload, updatedAt: job.updatedAt))
            }
            if let transcript {
                try stageTranscript(
                    transcript, accountID: accountID, itemID: itemID,
                    context: context)
            }
            do { try context.save() } catch {
                throw ChapterTranscriptCacheError.persistenceFailed
            }
        } catch let error as ChapterTranscriptCacheError {
            context.rollback()
            throw error
        } catch {
            context.rollback()
            throw .encodingFailed
        }
    }

    func jobRecords(context: ModelContext? = nil)
        throws(ChapterTranscriptCacheError)
        -> [CachedChapterTranscriptionJobRecord]
    {
        do {
            return try (context ?? modelContext).fetch(
                FetchDescriptor<CachedChapterTranscriptionJobRecord>())
        } catch { throw .persistenceFailed }
    }
}
