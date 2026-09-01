import BleatCore
import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

extension UTType {
    static let webVTT =
        UTType(filenameExtension: "vtt", conformingTo: .plainText)
        ?? .plainText
    static let subRip =
        UTType(filenameExtension: "srt", conformingTo: .plainText)
        ?? .plainText
}

extension TranscriptExportFormat {
    var title: String {
        switch self {
        case .webVTT:
            "WebVTT"
        case .subRip:
            "SRT"
        }
    }

    var contentType: UTType {
        switch self {
        case .webVTT:
            .webVTT
        case .subRip:
            .subRip
        }
    }
}

struct ChapterTranscriptExportSnapshot: Equatable {
    let transcripts: [CachedChapterTranscript]
    let availableChapterCount: Int
    let totalChapterCount: Int

    init(
        transcripts: [CachedChapterTranscript],
        expectedChapterIDs: [Int]
    ) {
        self.transcripts = transcripts
        let available = Set(
            transcripts.lazy
                .filter { !$0.segments.isEmpty }
                .map(\.chapterID)
        )
        let expected = Set(expectedChapterIDs)
        availableChapterCount = available.intersection(expected).count
        totalChapterCount = expected.count
    }

    var hasSegments: Bool {
        transcripts.contains { !$0.segments.isEmpty }
    }

    var isIncomplete: Bool {
        totalChapterCount == 0 || availableChapterCount < totalChapterCount
    }
}

struct TranscriptExportArtifact: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let format: TranscriptExportFormat
    let contentType: UTType
    let isIncomplete: Bool
    private let lease: TranscriptExportArtifactLease?

    init(
        id: UUID = UUID(),
        url: URL,
        format: TranscriptExportFormat,
        contentType: UTType,
        isIncomplete: Bool,
        lease: TranscriptExportArtifactLease? = nil
    ) {
        self.id = id
        self.url = url
        self.format = format
        self.contentType = contentType
        self.isIncomplete = isIncomplete
        self.lease = lease
    }

    static func == (
        lhs: TranscriptExportArtifact,
        rhs: TranscriptExportArtifact
    ) -> Bool {
        lhs.id == rhs.id
            && lhs.url == rhs.url
            && lhs.format == rhs.format
            && lhs.contentType == rhs.contentType
            && lhs.isIncomplete == rhs.isIncomplete
    }
}

final class TranscriptExportArtifactLease: @unchecked Sendable {
    private let directoryURL: URL

    init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

enum TranscriptExportArtifactError: Error, Equatable {
    case invalidTranscript(TranscriptExportError)
    case cannotPrepareDirectory
    case cannotRemoveOrphanedArtifacts
    case cannotWriteArtifact
}

extension TranscriptExportArtifactError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidTranscript:
            "The available transcript data could not be exported."
        case .cannotPrepareDirectory:
            "Bleat could not prepare a temporary export location."
        case .cannotRemoveOrphanedArtifacts:
            "Bleat could not remove orphaned temporary transcript exports."
        case .cannotWriteArtifact:
            "Bleat could not write the temporary transcript export."
        }
    }
}

struct TranscriptExportArtifactWriter: Sendable {
    private static let sessionID = UUID().uuidString
    private static let cleanupLock = NSLock()
    private let rootURL: URL

    init(
        rootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BleatTranscriptExports", isDirectory: true)
    ) {
        self.rootURL = rootURL
    }

    func write(
        title: String,
        transcripts: [CachedChapterTranscript],
        format: TranscriptExportFormat,
        isIncomplete: Bool
    ) throws -> TranscriptExportArtifact {
        let data: Data
        do {
            data = try TranscriptExporter.export(
                transcripts: transcripts,
                format: format
            )
        } catch let error as TranscriptExportError {
            throw TranscriptExportArtifactError.invalidTranscript(error)
        }

        try Self.cleanupLock.withLock {
            try prepareRootAndRemoveOrphans()
        }
        let artifactDirectory = rootURL.appendingPathComponent(
            "\(Self.sessionID)-\(UUID().uuidString)",
            isDirectory: true
        )
        try prepareDirectory(at: artifactDirectory)
        let maximumStemBytes = 255 - format.fileExtension.utf8.count - 1
        let url = artifactDirectory.appendingPathComponent(
            "\(sanitizedFilename(title, maximumUTF8Bytes: maximumStemBytes)).\(format.fileExtension)",
            isDirectory: false
        )
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: artifactDirectory)
            throw TranscriptExportArtifactError.cannotWriteArtifact
        }
        return TranscriptExportArtifact(
            url: url,
            format: format,
            contentType: format.contentType,
            isIncomplete: isIncomplete,
            lease: TranscriptExportArtifactLease(
                directoryURL: artifactDirectory
            )
        )
    }

    private func prepareRootAndRemoveOrphans() throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw TranscriptExportArtifactError.cannotPrepareDirectory
        }

        let artifacts: [URL]
        do {
            artifacts = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw TranscriptExportArtifactError.cannotRemoveOrphanedArtifacts
        }
        do {
            for artifact in artifacts
            where !artifact.lastPathComponent.hasPrefix("\(Self.sessionID)-") {
                try fileManager.removeItem(at: artifact)
            }
        } catch {
            throw TranscriptExportArtifactError.cannotRemoveOrphanedArtifacts
        }
    }

    private func prepareDirectory(at artifactDirectory: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw TranscriptExportArtifactError.cannotPrepareDirectory
        }
    }

    private func sanitizedFilename(
        _ title: String,
        maximumUTF8Bytes: Int
    ) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.controlCharacters)
            .union(.newlines)
        let replaced = title.unicodeScalars.map { scalar in
            invalid.contains(scalar) ? "-" : String(scalar)
        }.joined()
        let trimmed = replaced.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ".")
            )
        )
        let filename = trimmed.isEmpty ? "Transcript" : trimmed
        var bounded = ""
        for character in filename {
            let candidate = bounded + String(character)
            guard candidate.utf8.count <= maximumUTF8Bytes else {
                break
            }
            bounded = candidate
        }
        return bounded.isEmpty ? "Transcript" : bounded
    }
}

struct TranscriptSharePayload: Equatable {
    private let artifact: TranscriptExportArtifact

    var fileURL: URL { artifact.url }
    var contentType: UTType { artifact.contentType }

    init(artifact: TranscriptExportArtifact) {
        self.artifact = artifact
    }

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let artifact = self.artifact
        provider.suggestedName = artifact.url.lastPathComponent
        let result: Result<Data, any Error>
        do {
            result = .success(try Data(contentsOf: artifact.url))
        } catch {
            result = .failure(error)
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: contentType.identifier,
            visibility: .all
        ) { completion in
            switch result {
            case .success(let data):
                completion(data, nil)
            case .failure(let error):
                completion(nil, error)
            }
            return nil
        }
        return provider
    }
}

#if os(iOS)
    struct TranscriptShareSheet: UIViewControllerRepresentable {
        let payload: TranscriptSharePayload

        func makeUIViewController(context: Context) -> UIActivityViewController
        {
            let configuration = UIActivityItemsConfiguration(
                itemProviders: [payload.itemProvider()]
            )
            return UIActivityViewController(
                activityItemsConfiguration: configuration
            )
        }

        func updateUIViewController(
            _ viewController: UIActivityViewController,
            context: Context
        ) {}
    }
#elseif os(macOS)
    struct TranscriptShareSheet: NSViewRepresentable {
        let payload: TranscriptSharePayload
        @Environment(\.dismiss) private var dismiss

        func makeCoordinator() -> Coordinator {
            Coordinator(dismiss: dismiss)
        }

        func makeNSView(context: Context) -> NSView {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            context.coordinator.present(payload: payload, from: view)
            return view
        }

        func updateNSView(_ nsView: NSView, context: Context) {}

        @MainActor
        final class Coordinator:
            NSObject, @preconcurrency NSSharingServicePickerDelegate,
            NSSharingServiceDelegate
        {
            private let onDismiss: @MainActor () -> Void
            private var picker: NSSharingServicePicker?
            private var payload: TranscriptSharePayload?
            private var itemProvider: NSItemProvider?

            init(dismiss: DismissAction) {
                onDismiss = { dismiss() }
            }

            init(onDismiss: @escaping @MainActor () -> Void) {
                self.onDismiss = onDismiss
            }

            func present(payload: TranscriptSharePayload, from view: NSView) {
                self.payload = payload
                DispatchQueue.main.async { [weak self, weak view] in
                    guard let self, let view else {
                        return
                    }
                    let itemProvider = payload.itemProvider()
                    let picker = NSSharingServicePicker(items: [itemProvider])
                    picker.delegate = self
                    self.picker = picker
                    self.itemProvider = itemProvider
                    picker.show(
                        relativeTo: view.bounds,
                        of: view,
                        preferredEdge: .minY
                    )
                }
            }

            func sharingServicePicker(
                _ sharingServicePicker: NSSharingServicePicker,
                didChoose service: NSSharingService?
            ) {
                if service == nil {
                    finishSharing()
                }
            }

            func sharingServicePicker(
                _ sharingServicePicker: NSSharingServicePicker,
                delegateFor sharingService: NSSharingService
            ) -> NSSharingServiceDelegate? {
                self
            }

            func sharingService(
                _ sharingService: NSSharingService,
                didShareItems items: [Any]
            ) {
                finishSharing()
            }

            func sharingService(
                _ sharingService: NSSharingService,
                didFailToShareItems items: [Any],
                error: any Error
            ) {
                finishSharing()
            }

            private func finishSharing() {
                payload = nil
                itemProvider = nil
                picker = nil
                onDismiss()
            }
        }
    }
#endif
