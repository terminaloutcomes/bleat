#if DEBUG
    import BleatCore
    import Foundation
    import XCTest

    @testable import Bleat

    final class DiagnosticLogStoreTests: XCTestCase {
        func testExportKeepsExactWindowAcrossRelaunchAndRecoversInvalidData()
            async throws
        {
            let root = try temporaryDirectory()
            let fileURL = root.appendingPathComponent("recent.jsonl")
            let generatedAt = Date(timeIntervalSince1970: 2_000_000_000)
            let clock = LockedDiagnosticClock(generatedAt)
            var store = PersistentDiagnosticLogStore(
                fileURL: fileURL,
                now: clock.now
            )

            clock.set(
                generatedAt.addingTimeInterval(
                    -PersistentDiagnosticLogStore.retentionInterval - 0.001
                )
            )
            await store.record(.started(.search, category: .api))
            clock.set(
                generatedAt.addingTimeInterval(
                    -PersistentDiagnosticLogStore.retentionInterval
                )
            )
            await store.record(.started(.login, category: .auth))
            clock.set(generatedAt.addingTimeInterval(-30))
            await store.record(.completed(.play, category: .playback))

            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            var futureRecord = try encoder.encode(
                DiagnosticRecord(
                    timestamp: generatedAt.addingTimeInterval(1),
                    event: .started(.removeAccount, category: .auth)
                )
            )
            futureRecord.append(0x0A)
            try handle.write(contentsOf: futureRecord)
            try handle.write(contentsOf: Data("not-json\n".utf8))
            try handle.close()

            store = PersistentDiagnosticLogStore(
                fileURL: fileURL,
                now: clock.now
            )
            let artifact = try await store.export(
                generatedAt: generatedAt,
                environment: Self.environment
            )
            let text = try XCTUnwrap(
                String(data: artifact.data, encoding: .utf8)
            )

            XCTAssertTrue(artifact.filename.hasPrefix("Bleat-logs-"))
            XCTAssertTrue(artifact.filename.hasSuffix(".txt"))
            XCTAssertTrue(text.contains("operation=login"))
            XCTAssertTrue(text.contains("operation=play"))
            XCTAssertFalse(text.contains("operation=search"))
            XCTAssertFalse(text.contains("operation=remove_account"))
            XCTAssertTrue(text.contains("Truncated: yes"))
            XCTAssertLessThan(
                try XCTUnwrap(text.range(of: "operation=login")?.lowerBound),
                try XCTUnwrap(text.range(of: "operation=play")?.lowerBound)
            )

            let backupValues = try root.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            )
            XCTAssertEqual(backupValues.isExcludedFromBackup, true)
        }

        func testSizeLimitKeepsNewestRecordsAndMarksExport() async throws {
            let root = try temporaryDirectory()
            let fileURL = root.appendingPathComponent("recent.jsonl")
            let generatedAt = Date(timeIntervalSince1970: 2_000_000_000)
            let clock = LockedDiagnosticClock(generatedAt)
            var store = PersistentDiagnosticLogStore(
                fileURL: fileURL,
                maximumBytes: 1_024,
                now: clock.now
            )
            let correlationIDs = (0..<20).map { _ in UUID() }

            for (index, correlationID) in correlationIDs.enumerated() {
                clock.set(
                    generatedAt.addingTimeInterval(
                        TimeInterval(index - 30)
                    )
                )
                await store.record(
                    .started(
                        .httpRequest,
                        category: .api,
                        endpoint: .libraries,
                        method: .get,
                        correlationID: correlationID
                    )
                )
            }

            store = PersistentDiagnosticLogStore(
                fileURL: fileURL,
                maximumBytes: 1_024,
                now: clock.now
            )
            let artifact = try await store.export(
                generatedAt: generatedAt,
                environment: Self.environment
            )
            let text = try XCTUnwrap(
                String(data: artifact.data, encoding: .utf8)
            )

            XCTAssertTrue(text.contains("Truncated: yes"))
            XCTAssertFalse(
                text.contains(
                    correlationIDs[0].uuidString.lowercased()
                )
            )
            XCTAssertTrue(
                text.contains(
                    correlationIDs[19].uuidString.lowercased()
                )
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fileURL.path
            )
            XCTAssertLessThanOrEqual(
                try XCTUnwrap(attributes[.size] as? Int),
                1_024
            )
        }

        @MainActor
        func testExportModelCreatesAndCleansOnlyItsTemporaryArtifact()
            async throws
        {
            let root = try temporaryDirectory()
            let store = PersistentDiagnosticLogStore(
                fileURL: root.appendingPathComponent("recent.jsonl")
            )
            await store.record(.started(.appStart, category: .app))
            let model = RecentLogExportModel(store: store)

            await model.prepare(environment: Self.environment)

            let fileURL = try XCTUnwrap(model.sharingURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.path)
            )

            model.finishSharing()

            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fileURL.deletingLastPathComponent().path
                )
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.path)
            )
            XCTAssertEqual(model.state, .idle)
        }

        private func temporaryDirectory() throws -> URL {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "DiagnosticLogStoreTests-\(UUID().uuidString)",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: false
            )
            addTeardownBlock {
                try? FileManager.default.removeItem(at: root)
            }
            return root
        }

        private static let environment = DiagnosticsEnvironment(
            appVersion: "1.2.3",
            appBuild: "45",
            operatingSystem: "iOS Test"
        )
    }

    private final class LockedDiagnosticClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date

        init(_ date: Date) {
            self.date = date
        }

        func set(_ date: Date) {
            lock.withLock {
                self.date = date
            }
        }

        func now() -> Date {
            lock.withLock {
                date
            }
        }
    }
#endif
