import Foundation

enum LegacyDiagnosticLogCleanupResult: Equatable {
    case removed
    case notPresent
    case applicationSupportUnavailable
    case removalFailed
}

enum LegacyDiagnosticLogCleanup {
    static func removeLegacyDirectory(
        fileManager: FileManager = .default
    ) -> LegacyDiagnosticLogCleanupResult {
        guard let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return .applicationSupportUnavailable
        }
        return removeLegacyDirectory(
            at: applicationSupportURL.appendingPathComponent(
                "BleatDiagnostics",
                isDirectory: true
            ),
            fileManager: fileManager
        )
    }

    static func removeLegacyDirectory(
        at directoryURL: URL,
        fileManager: FileManager = .default
    ) -> LegacyDiagnosticLogCleanupResult {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return .notPresent
        }
        do {
            try fileManager.removeItem(at: directoryURL)
            return .removed
        } catch {
            return .removalFailed
        }
    }
}
