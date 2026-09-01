import BleatCore
import Foundation
import UniformTypeIdentifiers
import XCTest

@testable import Bleat

#if os(macOS)
    import AppKit
#endif

final class TranscriptExportArtifactTests: XCTestCase {
    func testWriterCreatesSanitizedTypedUTF8ArtifactWithoutNetwork() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = TranscriptExportArtifactWriter(rootURL: root)

        let artifact = try writer.write(
            title: "  A/B: Café?  ",
            transcripts: [transcript(text: "Héllo")],
            format: .webVTT,
            isIncomplete: false
        )

        XCTAssertEqual(artifact.url.lastPathComponent, "A-B- Café-.vtt")
        XCTAssertEqual(artifact.format, .webVTT)
        XCTAssertEqual(artifact.contentType, .webVTT)
        XCTAssertFalse(artifact.isIncomplete)
        XCTAssertEqual(
            try String(contentsOf: artifact.url, encoding: .utf8),
            "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nHéllo\n"
        )
    }

    func testWriterKeepsEveryActiveExportAliveAndUsesIsolatedArtifacts() throws
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let writer = TranscriptExportArtifactWriter(rootURL: root)
        let firstArtifact = try writer.write(
            title: "Book",
            transcripts: [transcript(text: "First")],
            format: .webVTT,
            isIncomplete: false
        )

        let secondArtifact = try writer.write(
            title: "Book",
            transcripts: [transcript(text: "Current")],
            format: .subRip,
            isIncomplete: true
        )

        XCTAssertNotEqual(firstArtifact.url, secondArtifact.url)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: firstArtifact.url.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: secondArtifact.url.path)
        )
        XCTAssertEqual(secondArtifact.contentType, .subRip)
        XCTAssertTrue(secondArtifact.isIncomplete)
    }

    func testWriterRemovesArtifactsOrphanedByAnEarlierProcessSession() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent(
            "earlier-session-orphan",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: orphan,
            withIntermediateDirectories: true
        )

        let artifact = try TranscriptExportArtifactWriter(rootURL: root).write(
            title: "Book",
            transcripts: [transcript(text: "Current")],
            format: .webVTT,
            isIncomplete: false
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
    }

    func testConcurrentFirstWritesSafelyShareOrphanCleanup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let orphan = root.appendingPathComponent(
            "earlier-session-orphan",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: orphan,
            withIntermediateDirectories: true
        )
        let writer = TranscriptExportArtifactWriter(rootURL: root)
        let transcript = transcript(text: "Concurrent")

        let completedWrites = try await withThrowingTaskGroup(
            of: Bool.self
        ) { group in
            for index in 0..<8 {
                group.addTask {
                    let artifact = try writer.write(
                        title: "Book \(index)",
                        transcripts: [transcript],
                        format: .webVTT,
                        isIncomplete: false
                    )
                    return FileManager.default.fileExists(
                        atPath: artifact.url.path
                    )
                }
            }

            var results: [Bool] = []
            for try await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(completedWrites, Array(repeating: true, count: 8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    #if os(macOS)
        @MainActor
        func testMacShareDismissesAfterCompletionRatherThanSelection() {
            var dismissCount = 0
            let coordinator = TranscriptShareSheet.Coordinator {
                dismissCount += 1
            }
            let picker = NSSharingServicePicker(items: [])
            let service = NSSharingService(
                title: "Test Share",
                image: NSImage(),
                alternateImage: nil
            ) {}

            coordinator.sharingServicePicker(picker, didChoose: service)
            XCTAssertEqual(dismissCount, 0)

            coordinator.sharingService(service, didShareItems: [])
            XCTAssertEqual(dismissCount, 1)
        }
    #endif

    func testWriterBoundsMultibyteFilenameToFilesystemComponentLimit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let artifact = try TranscriptExportArtifactWriter(rootURL: root).write(
            title: String(repeating: "🐐", count: 120),
            transcripts: [transcript(text: "Bounded")],
            format: .webVTT,
            isIncomplete: false
        )

        XCTAssertLessThanOrEqual(artifact.url.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.url.path))
    }

    func testSnapshotOnlyCompletesWhenEveryBookChapterIsCanonical() {
        let partial = ChapterTranscriptExportSnapshot(
            transcripts: [transcript(chapterID: 2, text: "Available")],
            expectedChapterIDs: [1, 2]
        )
        XCTAssertTrue(partial.hasSegments)
        XCTAssertTrue(partial.isIncomplete)
        XCTAssertEqual(partial.availableChapterCount, 1)
        XCTAssertEqual(partial.totalChapterCount, 2)

        let emptyChapter = CachedChapterTranscript(
            chapterID: 1,
            chapterTitle: "Chapter 1",
            chapterStartMilliseconds: 0,
            chapterEndMilliseconds: 1_000,
            localeIdentifier: "en_AU",
            segments: [],
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let emptyCoverage = ChapterTranscriptExportSnapshot(
            transcripts: [
                emptyChapter, transcript(chapterID: 2, text: "Available"),
            ],
            expectedChapterIDs: [1, 2]
        )
        XCTAssertTrue(emptyCoverage.isIncomplete)
        XCTAssertEqual(emptyCoverage.availableChapterCount, 1)

        let complete = ChapterTranscriptExportSnapshot(
            transcripts: [
                transcript(chapterID: 2, text: "Second"),
                transcript(chapterID: 1, text: "First"),
            ],
            expectedChapterIDs: [1, 2]
        )
        XCTAssertFalse(complete.isIncomplete)
    }

    func testSharePayloadProvidesTypedFileRepresentation() {
        let url = URL(fileURLWithPath: "/tmp/Book.srt")
        let artifact = TranscriptExportArtifact(
            url: url,
            format: .subRip,
            contentType: .subRip,
            isIncomplete: false
        )

        let payload = TranscriptSharePayload(artifact: artifact)

        XCTAssertEqual(payload.fileURL, url)
        XCTAssertEqual(payload.contentType, .subRip)
        XCTAssertEqual(
            payload.itemProvider().registeredTypeIdentifiers,
            [UTType.subRip.identifier]
        )
        XCTAssertEqual(payload.itemProvider().suggestedName, "Book.srt")
    }

    func testItemProviderCopiesDataForReceivingActivity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }

        let sharedItem = try makeSharedItem(root: root)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: sharedItem.url.path),
            "The provider must not depend on the disposable source artifact."
        )
        let loaded = expectation(description: "data representation loaded")
        sharedItem.provider.loadDataRepresentation(
            forTypeIdentifier: UTType.webVTT.identifier
        ) { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(
                data.flatMap { String(data: $0, encoding: .utf8) },
                "WEBVTT\n\n00:00:00.000 --> 00:00:01.000\nShared\n"
            )
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 3)
    }

    private func makeSharedItem(
        root: URL
    ) throws -> (provider: NSItemProvider, url: URL) {
        let artifact = try TranscriptExportArtifactWriter(rootURL: root).write(
            title: "Book",
            transcripts: [transcript(text: "Shared")],
            format: .webVTT,
            isIncomplete: false
        )
        return (
            TranscriptSharePayload(artifact: artifact).itemProvider(),
            artifact.url
        )
    }

    private func transcript(
        chapterID: Int = 1,
        text: String
    ) -> CachedChapterTranscript {
        CachedChapterTranscript(
            chapterID: chapterID,
            chapterTitle: "Chapter \(chapterID)",
            chapterStartMilliseconds: 0,
            chapterEndMilliseconds: 1_000,
            localeIdentifier: "en_AU",
            segments: [
                CachedTranscriptSegment(
                    startMilliseconds: 0,
                    endMilliseconds: 1_000,
                    text: text
                )
            ],
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }
}
