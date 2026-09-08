import BleatCore
import Foundation

/// The main actor only snapshots download state. All filesystem inspection runs on the worker actor.
enum ChapterTranscriptionSourceValidator {
    private static let worker = ChapterTranscriptionMetadataWorker()

    @MainActor
    static func load(
        audio: PreparedChapterTranscriptionAudio,
        detail: LibraryBookDetail,
        account: ServerAccount,
        downloads: DownloadModel
    ) async throws -> ChapterTranscriptionSourceIdentity {
        guard
            let record = downloads.record(
                accountID: account.id, itemID: detail.id)
        else {
            throw ChapterTranscriptionJobFailure.missingAudio
        }
        return try await worker.inspect(
            manifest: record.manifest, tracks: audio.tracks)
    }
}

/// Approved synchronous boundary (2026-09-08): Foundation has no asynchronous local
/// file metadata API. Only stat metadata is read on this actor, never file contents.
/// Remove this exception when Foundation exposes native asynchronous metadata reads.
actor ChapterTranscriptionMetadataWorker {
    func inspect(
        manifest: DownloadManifest, tracks: [PreparedChapterTranscriptionTrack]
    ) throws -> ChapterTranscriptionSourceIdentity {
        try Task.checkCancellation()
        guard !tracks.isEmpty,
            Set(tracks.map { $0.timeline.trackIndex }).count == tracks.count,
            Set(manifest.entries.map(\.trackIndex)).count
                == manifest.entries.count
        else { throw ChapterTranscriptionJobFailure.insufficientSourceIdentity }
        var identities: [ChapterTranscriptionSourceTrack] = []
        for track in tracks {
            try Task.checkCancellation()
            guard
                let entry = manifest.entries.first(where: {
                    $0.trackIndex == track.timeline.trackIndex
                }),
                entry.state == .complete, entry.placement == .finalized,
                entry.observedByteLength == entry.expectedByteLength
            else { throw ChapterTranscriptionJobFailure.missingAudio }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(
                    atPath: track.url.path)
            } catch let error as CocoaError
                where error.code == .fileReadNoSuchFile
                || error.code == .fileNoSuchFile
            {
                throw ChapterTranscriptionJobFailure.missingAudio
            } catch {
                throw ChapterTranscriptionJobFailure.insufficientSourceIdentity
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                let size = attributes[.size] as? NSNumber,
                let identifier = attributes[.systemFileNumber] as? NSNumber,
                let modifiedAt = attributes[.modificationDate] as? Date
            else {
                throw ChapterTranscriptionJobFailure.insufficientSourceIdentity
            }
            guard size.int64Value == entry.expectedByteLength else {
                throw ChapterTranscriptionJobFailure.sourceChanged
            }
            let start = track.timeline.startOffsetSeconds
            let duration = track.timeline.durationSeconds
            guard start.isFinite, start >= 0, duration.isFinite, duration > 0,
                entry.startOffset == nil || entry.startOffset == start,
                entry.duration == nil || entry.duration == duration
            else { throw ChapterTranscriptionJobFailure.sourceChanged }
            identities.append(
                ChapterTranscriptionSourceTrack(
                    index: entry.trackIndex, inode: entry.inode,
                    expectedBytes: entry.expectedByteLength,
                    observedBytes: size.int64Value,
                    start: start, duration: duration,
                    validator: entry.validator,
                    fileIdentifier: identifier.uint64Value,
                    modifiedAt: modifiedAt))
        }
        return ChapterTranscriptionSourceIdentity(
            downloadID: manifest.downloadID, tracks: identities)
    }
}
