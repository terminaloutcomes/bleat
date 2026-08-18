#if DEBUG
    import BleatCore
    import Foundation
    import Observation
    import SwiftUI
    import UIKit

    enum DiagnosticLogStoreError: Error, Equatable, Sendable {
        case storageUnavailable
        case exportUnavailable
        case temporaryFileUnavailable

        var message: String {
            switch self {
            case .storageUnavailable:
                "Bleat could not read its recent diagnostic history."
            case .exportUnavailable:
                "Bleat could not prepare the recent logs."
            case .temporaryFileUnavailable:
                "Bleat could not create the temporary log file."
            }
        }
    }

    struct DiagnosticLogExportArtifact: Equatable, Sendable {
        let filename: String
        let data: Data
    }

    actor PersistentDiagnosticLogStore: DiagnosticRecording {
        static let retentionInterval: TimeInterval = 15 * 60
        static let maximumBytes = 5 * 1_024 * 1_024

        private let fileURL: URL
        private let maximumBytes: Int
        private let now: @Sendable () -> Date
        private var records: [DiagnosticRecord]?
        private var historyWasTruncated = false

        init(
            fileURL: URL = PersistentDiagnosticLogStore.defaultFileURL,
            maximumBytes: Int =
                PersistentDiagnosticLogStore.maximumBytes,
            now: @escaping @Sendable () -> Date = Date.init
        ) {
            self.fileURL = fileURL
            self.maximumBytes = maximumBytes
            self.now = now
        }

        func record(_ event: DiagnosticEvent) {
            let referenceDate = now()
            do {
                try loadIfNeeded(referenceDate: referenceDate)
                let record = DiagnosticRecord(
                    timestamp: referenceDate,
                    event: event
                )
                let line = try encodedLine(record)
                records?.append(record)
                let requiresRewrite =
                    try prune(referenceDate: referenceDate)
                    || currentFileSize + line.count > maximumBytes

                if requiresRewrite {
                    _ = try enforceSizeLimit(referenceDate: referenceDate)
                    try rewriteFile()
                } else {
                    try append(line)
                }
            } catch {
                historyWasTruncated = true
            }
        }

        func export(
            generatedAt: Date,
            environment: DiagnosticsEnvironment
        ) throws(DiagnosticLogStoreError) -> DiagnosticLogExportArtifact {
            do {
                try loadIfNeeded(referenceDate: generatedAt)
                let pruned = try prune(referenceDate: generatedAt)
                let sizeLimited = try enforceSizeLimit(
                    referenceDate: generatedAt
                )
                if pruned || sizeLimited {
                    try rewriteFile()
                }
                let text = renderExport(
                    generatedAt: generatedAt,
                    environment: environment
                )
                guard let data = text.data(using: .utf8) else {
                    throw DiagnosticLogStoreError.exportUnavailable
                }
                return DiagnosticLogExportArtifact(
                    filename: Self.filename(for: generatedAt),
                    data: data
                )
            } catch let error as DiagnosticLogStoreError {
                throw error
            } catch {
                throw .storageUnavailable
            }
        }

        private func loadIfNeeded(referenceDate: Date) throws {
            guard records == nil else {
                return
            }
            try prepareDirectory()
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                records = []
                try rewriteFile()
                return
            }

            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            var loaded: [DiagnosticRecord] = []
            var invalidRecordFound = false
            for line in data.split(separator: 0x0A) where !line.isEmpty {
                do {
                    loaded.append(
                        try decoder.decode(
                            DiagnosticRecord.self,
                            from: Data(line)
                        )
                    )
                } catch {
                    invalidRecordFound = true
                }
            }
            records = loaded.sorted { $0.timestamp < $1.timestamp }
            historyWasTruncated =
                invalidRecordFound
                || loaded.contains {
                    $0.event.name == .historyTruncated
                }
            if invalidRecordFound,
                records?.contains(where: {
                    $0.event.name == .historyTruncated
                }) != true
            {
                records?.append(
                    DiagnosticRecord(
                        timestamp: referenceDate,
                        event: .historyTruncated
                    )
                )
            }
            let pruned = try prune(referenceDate: referenceDate)
            let sizeLimited = try enforceSizeLimit(
                referenceDate: referenceDate
            )
            if invalidRecordFound || pruned || sizeLimited {
                try rewriteFile()
            }
        }

        @discardableResult
        private func prune(referenceDate: Date) throws -> Bool {
            guard var records else {
                return false
            }
            let cutoff = referenceDate.addingTimeInterval(
                -Self.retentionInterval
            )
            let originalCount = records.count
            let hadFutureRecord = records.contains {
                $0.timestamp > referenceDate
            }
            records.removeAll {
                $0.timestamp < cutoff || $0.timestamp > referenceDate
            }
            if hadFutureRecord {
                historyWasTruncated = true
                records.append(
                    DiagnosticRecord(
                        timestamp: referenceDate,
                        event: .historyTruncated
                    )
                )
            }
            records.sort { $0.timestamp < $1.timestamp }
            self.records = records
            return originalCount != records.count || hadFutureRecord
        }

        @discardableResult
        private func enforceSizeLimit(referenceDate: Date) throws -> Bool {
            guard var records else {
                return false
            }
            var lines = try records.map(encodedLine)
            var byteCount = lines.reduce(0) { $0 + $1.count }
            var removedRecord = false
            while byteCount > maximumBytes, !records.isEmpty {
                byteCount -= lines.removeFirst().count
                records.removeFirst()
                removedRecord = true
            }
            if removedRecord {
                historyWasTruncated = true
                let marker = DiagnosticRecord(
                    timestamp: records.first?.timestamp ?? referenceDate,
                    event: .historyTruncated
                )
                records.insert(marker, at: 0)
                while try encodedSize(records) > maximumBytes,
                    records.count > 1
                {
                    records.remove(at: 1)
                }
            }
            self.records = records
            return removedRecord
        }

        private func prepareDirectory() throws {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(values)
        }

        private func append(_ data: Data) throws {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try applyFileProtection()
        }

        private func rewriteFile() throws {
            try prepareDirectory()
            let data = try (records ?? []).reduce(into: Data()) {
                $0.append(try encodedLine($1))
            }
            try data.write(to: fileURL, options: .atomic)
            try applyFileProtection()
        }

        private func applyFileProtection() throws {
            #if os(iOS)
                try FileManager.default.setAttributes(
                    [
                        .protectionKey:
                            FileProtectionType
                            .completeUntilFirstUserAuthentication
                    ],
                    ofItemAtPath: fileURL.path
                )
            #endif
        }

        private func encodedLine(_ record: DiagnosticRecord) throws -> Data {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            var data = try encoder.encode(record)
            data.append(0x0A)
            return data
        }

        private func encodedSize(
            _ records: [DiagnosticRecord]
        ) throws -> Int {
            try records.reduce(0) {
                $0 + (try encodedLine($1).count)
            }
        }

        private var currentFileSize: Int {
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: fileURL.path
            )
            return attributes?[.size] as? Int ?? 0
        }

        private func renderExport(
            generatedAt: Date,
            environment: DiagnosticsEnvironment
        ) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            let cutoff = generatedAt.addingTimeInterval(
                -Self.retentionInterval
            )
            let entries = (records ?? [])
                .filter {
                    $0.timestamp >= cutoff && $0.timestamp <= generatedAt
                }
                .map {
                    "\(formatter.string(from: $0.timestamp)) \($0.event.text)"
                }
                .joined(separator: "\n")
            let body = entries.isEmpty ? "(no events recorded)" : entries
            return """
                Bleat Recent Logs
                Generated: \(formatter.string(from: generatedAt))
                Window start: \(formatter.string(from: cutoff))
                Window end: \(formatter.string(from: generatedAt))
                App: \(environment.appVersion)
                Operating system: \(environment.operatingSystem)
                Truncated: \(historyWasTruncated ? "yes" : "no")

                Privacy: These logs exclude account names, server addresses, \
                credentials, tokens, response bodies, media titles and URLs, \
                remote identifiers, playback session IDs, listening \
                positions, and local file paths.

                \(body)
                """
        }

        private static func filename(for date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd-HHmmss'Z'"
            return "Bleat-logs-\(formatter.string(from: date)).txt"
        }

        private static var defaultFileURL: URL {
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            return root
                .appendingPathComponent(
                    "BleatDiagnostics",
                    isDirectory: true
                )
                .appendingPathComponent("recent.jsonl")
        }
    }

    enum RecentLogExportState: Equatable {
        case idle
        case preparing
        case sharing(URL)
        case failed(DiagnosticLogStoreError)
    }

    @MainActor
    @Observable
    final class RecentLogExportModel {
        private let store: PersistentDiagnosticLogStore
        private(set) var state: RecentLogExportState = .idle
        private var temporaryDirectoryURL: URL?

        init(store: PersistentDiagnosticLogStore) {
            self.store = store
        }

        var failure: DiagnosticLogStoreError? {
            guard case .failed(let failure) = state else {
                return nil
            }
            return failure
        }

        var sharingURL: URL? {
            guard case .sharing(let url) = state else {
                return nil
            }
            return url
        }

        func prepare(environment: DiagnosticsEnvironment) async {
            guard state == .idle || failure != nil else {
                return
            }
            cleanupTemporaryFile()
            state = .preparing
            do {
                let generatedAt = Date()
                let artifact = try await store.export(
                    generatedAt: generatedAt,
                    environment: environment
                )
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent(
                        "BleatDiagnostics-\(UUID().uuidString)",
                        isDirectory: true
                    )
                do {
                    try FileManager.default.createDirectory(
                        at: directory,
                        withIntermediateDirectories: false
                    )
                    let fileURL = directory.appendingPathComponent(
                        artifact.filename
                    )
                    try artifact.data.write(to: fileURL, options: .atomic)
                    #if os(iOS)
                        try FileManager.default.setAttributes(
                            [
                                .protectionKey:
                                    FileProtectionType
                                    .completeUntilFirstUserAuthentication
                            ],
                            ofItemAtPath: fileURL.path
                        )
                    #endif
                    temporaryDirectoryURL = directory
                    state = .sharing(fileURL)
                } catch {
                    try? FileManager.default.removeItem(at: directory)
                    throw DiagnosticLogStoreError.temporaryFileUnavailable
                }
            } catch let error as DiagnosticLogStoreError {
                state = .failed(error)
            } catch {
                state = .failed(.exportUnavailable)
            }
        }

        func finishSharing() {
            cleanupTemporaryFile()
            state = .idle
        }

        func dismissFailure() {
            if failure != nil {
                state = .idle
            }
        }

        private func cleanupTemporaryFile() {
            guard let temporaryDirectoryURL else {
                return
            }
            try? FileManager.default.removeItem(at: temporaryDirectoryURL)
            self.temporaryDirectoryURL = nil
        }
    }

    struct DiagnosticActivityView: UIViewControllerRepresentable {
        let fileURL: URL
        let onCompletion: @MainActor @Sendable () -> Void

        func makeUIViewController(
            context: Context
        ) -> UIActivityViewController {
            let controller = UIActivityViewController(
                activityItems: [fileURL],
                applicationActivities: nil
            )
            controller.completionWithItemsHandler = {
                _, _, _, _ in
                Task { @MainActor in
                    onCompletion()
                }
            }
            return controller
        }

        func updateUIViewController(
            _ uiViewController: UIActivityViewController,
            context: Context
        ) {}
    }
#endif
