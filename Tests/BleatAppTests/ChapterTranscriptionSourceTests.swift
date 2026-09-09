import BleatCore
import Foundation
import XCTest

@testable import Bleat

@MainActor
final class ChapterTranscriptionSourceTests: XCTestCase {
    func testMetadataInspectionRunsOffMainAndDetectsSameSizeChanges()
        async throws
    {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try Data("12345".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: url.path)
        let manifest = try manifest()
        let tracks = [
            PreparedChapterTranscriptionTrack(
                timeline: ChapterAudioTrack(
                    trackIndex: 0, startOffsetSeconds: 0, durationSeconds: 10),
                url: url)
        ]
        let worker = ChapterTranscriptionMetadataWorker()
        let first = try await worker.inspectWithThread(
            manifest: manifest, tracks: tracks)
        XCTAssertFalse(first.wasMain)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2)],
            ofItemAtPath: url.path)
        let changed = try await worker.inspect(
            manifest: manifest, tracks: tracks)
        XCTAssertNotEqual(changed, first.identity)
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await worker.inspect(manifest: manifest, tracks: tracks)
            XCTFail("Missing audio must not validate")
        } catch {
            XCTAssertEqual(
                error as? ChapterTranscriptionJobFailure, .missingAudio)
        }
    }

    private func manifest() throws -> DownloadManifest {
        let plan = DownloadPlan(
            itemID: LibraryItemID(rawValue: "book"),
            tracks: [
                DownloadTrackPlan(
                    index: 0, inode: "remote-inode", expectedByteLength: 5,
                    mimeType: "audio/mp4", safeExtension: .m4b,
                    destinationEntry: "track.m4b", startOffset: 0, duration: 10)
            ])
        var manifest = try DownloadManifest(
            downloadID: DownloadID(rawValue: "download"),
            accountID: AccountID(rawValue: "account"), plan: plan)
        try manifest.markComplete(
            trackIndex: 0, observedByteLength: 5, placement: .finalized)
        return manifest
    }
}

extension ChapterTranscriptionMetadataWorker {
    fileprivate func inspectWithThread(
        manifest: DownloadManifest, tracks: [PreparedChapterTranscriptionTrack]
    ) throws -> (wasMain: Bool, identity: ChapterTranscriptionSourceIdentity) {
        let wasMain = Thread.isMainThread
        return (wasMain, try inspect(manifest: manifest, tracks: tracks))
    }
}
