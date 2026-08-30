import Foundation

public struct ChapterTranscriptionRequest: Equatable, Sendable {
    public let audioFileURL: URL
    public let locale: Locale
    public let audioStartSeconds: Double
    public let audioDurationSeconds: Double?
    public let chapterStartSeconds: Double

    public init(
        audioFileURL: URL,
        locale: Locale,
        audioStartSeconds: Double = 0,
        audioDurationSeconds: Double? = nil,
        chapterStartSeconds: Double = 0
    ) {
        self.audioFileURL = audioFileURL
        self.locale = locale
        self.audioStartSeconds = audioStartSeconds
        self.audioDurationSeconds = audioDurationSeconds
        self.chapterStartSeconds = chapterStartSeconds
    }
}

public struct TranscriptSegment: Equatable, Sendable {
    public let startMilliseconds: Int64
    public let endMilliseconds: Int64
    public let text: String

    public init(
        startMilliseconds: Int64,
        endMilliseconds: Int64,
        text: String
    ) {
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
        self.text = text
    }
}

public enum ChapterTranscriptionAudioContainer: String, Sendable {
    case m4a
}

public enum ChapterTranscriptionAudioCodec: String, Sendable {
    case aac
    case alac
    case linearPCM = "linear_pcm"
    case other
}

public struct ChapterTranscriptionInput: Equatable, Sendable {
    public let durationMilliseconds: Int64
    public let byteCount: Int64
    public let container: ChapterTranscriptionAudioContainer
    public let codec: ChapterTranscriptionAudioCodec
    public let sampleRateHz: Int
    public let channelCount: Int

    public init(
        durationMilliseconds: Int64,
        byteCount: Int64,
        container: ChapterTranscriptionAudioContainer,
        codec: ChapterTranscriptionAudioCodec,
        sampleRateHz: Int,
        channelCount: Int
    ) {
        self.durationMilliseconds = durationMilliseconds
        self.byteCount = byteCount
        self.container = container
        self.codec = codec
        self.sampleRateHz = sampleRateHz
        self.channelCount = channelCount
    }
}

public struct ChapterTranscriptionResult: Equatable, Sendable {
    public let segments: [TranscriptSegment]
    public let input: ChapterTranscriptionInput

    public init(
        segments: [TranscriptSegment],
        input: ChapterTranscriptionInput
    ) {
        self.segments = segments
        self.input = input
    }
}

public protocol ChapterTranscribing: Sendable {
    func transcribe(
        _ request: ChapterTranscriptionRequest
    ) async throws -> ChapterTranscriptionResult
}

public struct ChapterTranscriptionDiagnostic: Equatable, Sendable {
    public let domain: String
    public let code: Int

    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }

    init(_ error: any Error) {
        let error = error as NSError
        domain = error.domain
        code = error.code
    }

    var description: String {
        "\(domain) \(code)"
    }
}

public enum ChapterTranscriptionFailure: Error, Equatable, Sendable {
    case invalidChapterStart
    case invalidAudioRange
    case operatingSystemUnsupported
    case unavailableOnDevice
    case unsupportedLocale(String)
    case languageAssetsUnavailable
    case languageAssetInstallationFailed
    case audioFileUnreadable(String)
    case chapterExtractionUnavailable
    case chapterExtractionFailed(ChapterTranscriptionDiagnostic)
    case analyzerInputFailed(ChapterTranscriptionDiagnostic)
    case analyzerFinalizationFailed(ChapterTranscriptionDiagnostic)
    case resultStreamFailed(ChapterTranscriptionDiagnostic)
}

extension ChapterTranscriptionFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidChapterStart:
            "Chapter start must be a finite, non-negative number of seconds."
        case .invalidAudioRange:
            "The selected chapter range is outside the local audio file."
        case .operatingSystemUnsupported:
            "SpeechTranscriber requires macOS 26 or newer."
        case .unavailableOnDevice:
            "SpeechTranscriber is unavailable on this device."
        case .unsupportedLocale(let identifier):
            "SpeechTranscriber does not support locale \(identifier) on this device."
        case .languageAssetsUnavailable:
            "SpeechTranscriber language assets are unavailable for this locale."
        case .languageAssetInstallationFailed:
            "SpeechTranscriber language assets could not be installed."
        case .audioFileUnreadable(let filename):
            "The audio file \(filename) could not be read."
        case .chapterExtractionUnavailable:
            "This chapter cannot be extracted from the local audio file."
        case .chapterExtractionFailed(let diagnostic):
            "The selected chapter could not be extracted for transcription (\(diagnostic.description))."
        case .analyzerInputFailed(let diagnostic):
            "SpeechTranscriber rejected the audio input (\(diagnostic.description))."
        case .analyzerFinalizationFailed(let diagnostic):
            "SpeechTranscriber could not finish analyzing the audio (\(diagnostic.description))."
        case .resultStreamFailed(let diagnostic):
            "SpeechTranscriber could not deliver transcription results (\(diagnostic.description))."
        }
    }
}

public enum WholeBookTranscriptTimeline {
    public static func segment(
        relativeStartSeconds: Double,
        relativeDurationSeconds: Double,
        chapterStartSeconds: Double,
        text: String
    ) -> TranscriptSegment? {
        guard relativeStartSeconds.isFinite,
            relativeDurationSeconds.isFinite,
            chapterStartSeconds.isFinite,
            relativeStartSeconds >= 0,
            relativeDurationSeconds >= 0,
            chapterStartSeconds >= 0
        else {
            return nil
        }

        let startSeconds = chapterStartSeconds + relativeStartSeconds
        let endSeconds = startSeconds + relativeDurationSeconds
        guard startSeconds <= Double(Int64.max) / 1_000,
            endSeconds <= Double(Int64.max) / 1_000
        else {
            return nil
        }

        return TranscriptSegment(
            startMilliseconds: Int64((startSeconds * 1_000).rounded()),
            endMilliseconds: Int64((endSeconds * 1_000).rounded()),
            text: text
        )
    }
}
