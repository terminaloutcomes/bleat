import BleatCore
import Foundation

extension ChapterTranscriptionJobFailure {
    var message: String {
        switch self {
        case .missingAudio:
            "Download the selected source audio before resuming."
        case .sourceChanged:
            "The downloaded source audio has changed. This job cannot resume."
        case .chapterLayoutChanged:
            "The selected chapters have changed. This job cannot resume."
        case .insufficientSourceIdentity:
            "The local audio identity could not be verified. This job cannot resume."
        case .invalidCheckpoint:
            "The saved transcription checkpoint is invalid. Its transcript text has been preserved."
        case .staleRevision:
            "The transcription job changed before this update could be saved. Reload its progress."
        case .persistenceFailed:
            "Transcription progress could not be saved. Resume will use the last saved checkpoint."
        }
    }

    var diagnosticCode: DiagnosticFailureCode {
        switch self {
        case .missingAudio: .transcriptionJobMissingAudio
        case .sourceChanged: .transcriptionJobSourceChanged
        case .chapterLayoutChanged: .transcriptionJobChapterLayoutChanged
        case .insufficientSourceIdentity:
            .transcriptionJobInsufficientSourceIdentity
        case .invalidCheckpoint: .transcriptionJobInvalidCheckpoint
        case .staleRevision: .transcriptionJobStaleRevision
        case .persistenceFailed: .transcriptionJobPersistenceFailed
        }
    }

    var cachedTaskFailure: CachedChapterTranscriptionTaskFailure {
        switch self {
        case .missingAudio: .jobMissingAudio
        case .sourceChanged: .jobSourceChanged
        case .chapterLayoutChanged: .jobChapterLayoutChanged
        case .insufficientSourceIdentity: .jobInsufficientSourceIdentity
        case .invalidCheckpoint: .jobInvalidCheckpoint
        case .staleRevision: .jobStaleRevision
        case .persistenceFailed: .jobPersistenceFailed
        }
    }
}

/// Job completion is authoritative even when an older transcript has the same chapter ID.
enum ChapterTranscriptionResumePlanner {
    static func selectedChapters(
        job: ChapterTranscriptionJob, detail: LibraryBookDetail
    ) throws(ChapterTranscriptionJobFailure) -> [PlaybackChapter] {
        guard job.isValid else { throw .invalidCheckpoint }
        return try job.chapters.map {
            saved throws(ChapterTranscriptionJobFailure) in
            let matches = detail.chapters.filter { $0.id == saved.id }
            guard matches.count == 1, let chapter = matches.first,
                chapter.start == saved.start, chapter.end == saved.end
            else { throw .chapterLayoutChanged }
            return chapter
        }
    }
}

typealias ChapterTranscriptionSourceLoader =
    @MainActor @Sendable (
        PreparedChapterTranscriptionAudio, LibraryBookDetail, ServerAccount,
        DownloadModel
    ) async throws -> ChapterTranscriptionSourceIdentity
