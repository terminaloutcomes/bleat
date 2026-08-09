import BleatTranscription
import Foundation

enum CLIOutput {
    static func transcriptLine(for segment: TranscriptSegment) -> String {
        "[\(timestamp(segment.startMilliseconds))–\(timestamp(segment.endMilliseconds))] \(segment.text)"
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = (milliseconds / 60_000) % 60
        let seconds = (milliseconds / 1_000) % 60
        let remainder = milliseconds % 1_000
        return String(
            format: "%02lld:%02lld:%02lld.%03lld",
            hours,
            minutes,
            seconds,
            remainder
        )
    }
}
