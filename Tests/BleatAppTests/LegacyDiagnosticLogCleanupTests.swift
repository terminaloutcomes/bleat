import Foundation
import XCTest

@testable import Bleat

final class LegacyDiagnosticLogCleanupTests: XCTestCase {
    func testRemovesSeededLegacyDiagnosticHistoryDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "LegacyDiagnosticLogCleanupTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let legacyDirectory = root.appendingPathComponent(
            "BleatDiagnostics",
            isDirectory: true
        )
        let legacyLogURL = legacyDirectory.appendingPathComponent("recent.jsonl")
        defer {
            try? fileManager.removeItem(at: root)
        }
        try fileManager.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        try Data("legacy diagnostic event\n".utf8).write(to: legacyLogURL)

        XCTAssertEqual(
            LegacyDiagnosticLogCleanup.removeLegacyDirectory(
                at: legacyDirectory,
                fileManager: fileManager
            ),
            .removed
        )
        XCTAssertFalse(fileManager.fileExists(atPath: legacyDirectory.path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyLogURL.path))
        XCTAssertEqual(
            LegacyDiagnosticLogCleanup.removeLegacyDirectory(
                at: legacyDirectory,
                fileManager: fileManager
            ),
            .notPresent
        )
    }
}
