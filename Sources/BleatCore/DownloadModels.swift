import Foundation

public enum SafeAudioExtension: String, Codable, CaseIterable, Sendable {
    case aac
    case flac
    case m4a
    case m4b
    case mp3
    case ogg
    case opus
    case wav
    case webm
}

public enum DownloadPlanError: Error, Equatable, Sendable {
    case malformedExpandedItem
    case emptyItemID
    case noAudioFiles
    case emptyInode(trackIndex: Int)
    case unsafeFilename(trackIndex: Int)
    case invalidExpectedByteLength(trackIndex: Int)
    case unsupportedMediaType(trackIndex: Int, mimeType: String)
    case incompatibleExtension(trackIndex: Int, mimeType: String)
}

public struct DownloadTrackPlan: Equatable, Sendable {
    public let index: Int
    public let inode: String
    public let expectedByteLength: Int64
    public let mimeType: String
    public let safeExtension: SafeAudioExtension
    public let destinationEntry: String
}

public struct DownloadPlan: Equatable, Sendable {
    public let itemID: LibraryItemID
    public let tracks: [DownloadTrackPlan]

    public static func decodeExpandedItem(
        from data: Data
    ) throws(DownloadPlanError) -> DownloadPlan {
        let payload: ExpandedDownloadItem
        do {
            payload = try JSONDecoder().decode(
                ExpandedDownloadItem.self,
                from: data
            )
        } catch {
            throw .malformedExpandedItem
        }
        guard !payload.id.rawValue.isEmpty else {
            throw .emptyItemID
        }
        guard !payload.media.audioFiles.isEmpty else {
            throw .noAudioFiles
        }

        var tracks: [DownloadTrackPlan] = []
        tracks.reserveCapacity(payload.media.audioFiles.count)
        for (index, audioFile) in payload.media.audioFiles.enumerated() {
            guard !audioFile.ino.isEmpty else {
                throw .emptyInode(trackIndex: index)
            }
            guard audioFile.metadata.size >= 0 else {
                throw .invalidExpectedByteLength(trackIndex: index)
            }
            guard isSafeServerFilename(audioFile.metadata.filename) else {
                throw .unsafeFilename(trackIndex: index)
            }
            let safeExtension = try safeExtension(
                filename: audioFile.metadata.filename,
                mimeType: audioFile.mimeType,
                trackIndex: index
            )
            tracks.append(DownloadTrackPlan(
                index: index,
                inode: audioFile.ino,
                expectedByteLength: audioFile.metadata.size,
                mimeType: normalizedMimeType(audioFile.mimeType),
                safeExtension: safeExtension,
                destinationEntry: String(
                    format: "%05d.%@",
                    index,
                    safeExtension.rawValue
                )
            ))
        }
        return DownloadPlan(itemID: payload.id, tracks: tracks)
    }

    private static func isSafeServerFilename(_ filename: String) -> Bool {
        !filename.isEmpty
            && filename != "."
            && filename != ".."
            && !filename.contains("/")
            && !filename.contains("\\")
            && filename.rangeOfCharacter(
                from: .controlCharacters
            ) == nil
    }

    private static func normalizedMimeType(_ mimeType: String) -> String {
        mimeType
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func safeExtension(
        filename: String,
        mimeType: String,
        trackIndex: Int
    ) throws(DownloadPlanError) -> SafeAudioExtension {
        let normalizedMimeType = normalizedMimeType(mimeType)
        let allowed: Set<SafeAudioExtension>
        switch normalizedMimeType {
        case "audio/aac", "audio/x-aac":
            allowed = [.aac]
        case "audio/flac", "audio/x-flac":
            allowed = [.flac]
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/m4b",
             "audio/x-m4b":
            allowed = [.m4a, .m4b]
        case "audio/mpeg", "audio/mp3":
            allowed = [.mp3]
        case "audio/ogg":
            allowed = [.ogg, .opus]
        case "audio/opus":
            allowed = [.opus]
        case "audio/wav", "audio/x-wav", "audio/wave":
            allowed = [.wav]
        case "audio/webm":
            allowed = [.webm]
        default:
            throw .unsupportedMediaType(
                trackIndex: trackIndex,
                mimeType: normalizedMimeType
            )
        }

        let rawExtension = URL(fileURLWithPath: filename)
            .pathExtension
            .lowercased()
        guard let candidate = SafeAudioExtension(rawValue: rawExtension),
              allowed.contains(candidate)
        else {
            throw .incompatibleExtension(
                trackIndex: trackIndex,
                mimeType: normalizedMimeType
            )
        }
        return candidate
    }
}

public enum DownloadTaskIdentityError: Error, Equatable, Sendable {
    case invalidDownloadID
    case invalidAccountID
    case invalidItemID
    case invalidTrackIndex
    case invalidInode
    case invalidExpectedByteLength
    case invalidDestinationEntry
    case encodingFailed
    case invalidTaskDescription
}

public struct DownloadTaskIdentity: Codable, Equatable, Sendable {
    public static let taskDescriptionPrefix = "bleat-download-v1:"

    public let downloadID: DownloadID
    public let accountID: AccountID
    public let itemID: LibraryItemID
    public let trackIndex: Int
    public let inode: String
    public let expectedByteLength: Int64
    public let destinationEntry: String

    public init(
        downloadID: DownloadID,
        accountID: AccountID,
        itemID: LibraryItemID,
        track: DownloadTrackPlan
    ) throws(DownloadTaskIdentityError) {
        guard !downloadID.rawValue.isEmpty else {
            throw .invalidDownloadID
        }
        guard !accountID.rawValue.isEmpty else {
            throw .invalidAccountID
        }
        guard !itemID.rawValue.isEmpty else {
            throw .invalidItemID
        }
        guard track.index >= 0 else {
            throw .invalidTrackIndex
        }
        guard !track.inode.isEmpty else {
            throw .invalidInode
        }
        guard track.expectedByteLength >= 0 else {
            throw .invalidExpectedByteLength
        }
        guard Self.isValidDestinationEntry(track.destinationEntry) else {
            throw .invalidDestinationEntry
        }

        self.downloadID = downloadID
        self.accountID = accountID
        self.itemID = itemID
        trackIndex = track.index
        inode = track.inode
        expectedByteLength = track.expectedByteLength
        destinationEntry = track.destinationEntry
    }

    public func taskDescription() throws(DownloadTaskIdentityError) -> String {
        let data: Data
        do {
            data = try JSONEncoder().encode(self)
        } catch {
            throw .encodingFailed
        }
        return Self.taskDescriptionPrefix + data.base64EncodedString()
    }

    public static func decodeTaskDescription(
        _ description: String
    ) throws(DownloadTaskIdentityError) -> DownloadTaskIdentity {
        guard description.hasPrefix(taskDescriptionPrefix),
              let data = Data(
                  base64Encoded: String(
                      description.dropFirst(taskDescriptionPrefix.count)
                  )
              ),
              let decoded = try? JSONDecoder().decode(
                  DownloadTaskIdentity.self,
                  from: data
              ),
              decoded.isValid
        else {
            throw .invalidTaskDescription
        }
        return decoded
    }

    private var isValid: Bool {
        !downloadID.rawValue.isEmpty
            && !accountID.rawValue.isEmpty
            && !itemID.rawValue.isEmpty
            && trackIndex >= 0
            && !inode.isEmpty
            && expectedByteLength >= 0
            && Self.isValidDestinationEntry(destinationEntry)
    }

    static func isValidDestinationEntry(_ entry: String) -> Bool {
        guard !entry.isEmpty,
              !entry.contains("/"),
              !entry.contains("\\"),
              entry.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            return false
        }
        let components = entry.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].allSatisfy(\.isNumber),
              let safeExtension = SafeAudioExtension(
                  rawValue: String(components[1])
              )
        else {
            return false
        }
        return SafeAudioExtension.allCases.contains(safeExtension)
    }
}

private struct ExpandedDownloadItem: Decodable {
    let id: LibraryItemID
    let media: ExpandedDownloadMedia
}

private struct ExpandedDownloadMedia: Decodable {
    let audioFiles: [ExpandedDownloadAudioFile]
}

private struct ExpandedDownloadAudioFile: Decodable {
    let ino: String
    let metadata: ExpandedDownloadFileMetadata
    let mimeType: String
}

private struct ExpandedDownloadFileMetadata: Decodable {
    let filename: String
    let size: Int64
}
