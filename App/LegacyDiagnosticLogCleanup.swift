import Foundation
import BleatCore

enum LegacyDiagnosticLogCleanupResult: Equatable {
    case removed
    case notPresent
    case applicationSupportUnavailable
    case removalFailed

    var failureDiagnosticEvent: DiagnosticEvent? {
        let failureCode: DiagnosticFailureCode?
        switch self {
        case .removed, .notPresent:
            failureCode = nil
        case .applicationSupportUnavailable:
            failureCode = .legacyDiagnosticDirectoryUnavailable
        case .removalFailed:
            failureCode = .legacyDiagnosticDirectoryRemovalFailed
        }
        return failureCode.map {
            .failed(
                .removeLegacyDiagnosticDirectory,
                category: .app,
                failureCode: $0
            )
        }
    }
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
        fileManager: FileManager = .default,
        removeItem: ((URL) throws -> Void)? = nil
    ) -> LegacyDiagnosticLogCleanupResult {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return .notPresent
        }
        do {
            if let removeItem {
                try removeItem(directoryURL)
            } else {
                try fileManager.removeItem(at: directoryURL)
            }
            return .removed
        } catch {
            return .removalFailed
        }
    }
}
