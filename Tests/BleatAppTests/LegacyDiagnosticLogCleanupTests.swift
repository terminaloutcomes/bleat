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

    func testRemovalFailureEmitsSpecificCleanupDiagnostic() throws {
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

        let result = LegacyDiagnosticLogCleanup.removeLegacyDirectory(
            at: legacyDirectory,
            fileManager: fileManager,
            removeItem: { _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        )

        XCTAssertEqual(result, .removalFailed)
        XCTAssertTrue(fileManager.fileExists(atPath: legacyLogURL.path))
        let event = try XCTUnwrap(result.failureDiagnosticEvent)
        XCTAssertEqual(event.name, .operationFailed)
        XCTAssertEqual(
            event.operation,
            .removeLegacyDiagnosticDirectory
        )
        XCTAssertEqual(
            event.failureCode,
            .legacyDiagnosticDirectoryRemovalFailed
        )
        XCTAssertEqual(
            event.operation?.rawValue,
            "remove_legacy_diagnostic_directory"
        )
        XCTAssertEqual(
            event.failureCode?.rawValue,
            "legacy_diagnostic_directory_removal_failed"
        )
    }

    func testApplicationSupportFailureEmitsSpecificCleanupDiagnostic() throws {
        let event = try XCTUnwrap(
            LegacyDiagnosticLogCleanupResult.applicationSupportUnavailable
                .failureDiagnosticEvent
        )

        XCTAssertEqual(event.name, .operationFailed)
        XCTAssertEqual(
            event.operation,
            .removeLegacyDiagnosticDirectory
        )
        XCTAssertEqual(
            event.failureCode,
            .legacyDiagnosticDirectoryUnavailable
        )
        XCTAssertEqual(
            event.operation?.rawValue,
            "remove_legacy_diagnostic_directory"
        )
        XCTAssertEqual(
            event.failureCode?.rawValue,
            "legacy_diagnostic_directory_unavailable"
        )
    }
}
