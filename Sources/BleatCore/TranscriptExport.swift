import Foundation

public enum TranscriptExportFormat: String, CaseIterable, Sendable {
    case webVTT
    case subRip

    public var fileExtension: String {
        switch self {
        case .webVTT:
            "vtt"
        case .subRip:
            "srt"
        }
    }
}

public enum TranscriptExportError: Error, Equatable, Sendable {
    case noSegments
    case invalidSegment
}

public enum TranscriptExporter {
    public static func export(
        transcripts: [CachedChapterTranscript],
        format: TranscriptExportFormat
    ) throws -> Data {
        let segments = transcripts
            .flatMap(\.segments)
            .enumerated()
            .map { IndexedSegment(index: $0.offset, segment: $0.element) }
            .sorted {
                let left = $0.segment
                let right = $1.segment
                return (left.startMilliseconds, left.endMilliseconds, $0.index)
                    < (right.startMilliseconds, right.endMilliseconds, $1.index)
            }

        guard !segments.isEmpty else {
            throw TranscriptExportError.noSegments
        }
        guard segments.allSatisfy({ indexed in
            let segment = indexed.segment
            return segment.startMilliseconds >= 0
                && segment.endMilliseconds > segment.startMilliseconds
        }) else {
            throw TranscriptExportError.invalidSegment
        }

        let text: String
        switch format {
        case .webVTT:
            text = webVTT(segments.map(\.segment))
        case .subRip:
            text = subRip(segments.map(\.segment))
        }
        return Data(text.utf8)
    }

    private static func webVTT(_ segments: [CachedTranscriptSegment]) -> String {
        let cues = segments.map { segment in
            """
            \(timestamp(segment.startMilliseconds, separator: ".")) --> \(timestamp(segment.endMilliseconds, separator: "."))
            \(webVTTCueText(segment.text))

            """
        }
        return "WEBVTT\n\n" + cues.joined(separator: "\n")
    }

    private static func subRip(_ segments: [CachedTranscriptSegment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\r\n"
                + "\(timestamp(segment.startMilliseconds, separator: ",")) --> "
                + "\(timestamp(segment.endMilliseconds, separator: ","))\r\n"
                + "\(normalizedCueText(segment.text, newline: "\r\n"))\r\n\r\n"
        }.joined()
    }

    private static func timestamp(
        _ milliseconds: Int64,
        separator: Character
    ) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(
            format: "%02lld:%02lld:%02lld%@%03lld",
            hours,
            minutes,
            seconds,
            String(separator),
            remainder
        )
    }

    private static func webVTTCueText(_ text: String) -> String {
        normalizedCueText(text, newline: "\n")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func normalizedCueText(
        _ text: String,
        newline: String
    ) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n")
            .filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .joined(separator: newline)
    }
}

private struct IndexedSegment {
    let index: Int
    let segment: CachedTranscriptSegment
}
