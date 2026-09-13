import AVFAudio
import BleatCore
import BleatTranscription
import Foundation
import Observation
import SwiftUI

#if canImport(UIKit)
    import UIKit
#endif

struct ChapterAudioSlice: Equatable, Sendable {
    let trackIndex: Int
    let audioStartSeconds: Double
    let durationSeconds: Double
    let wholeBookStartSeconds: Double
}

struct ChapterAudioTrack: Equatable, Sendable {
    let trackIndex: Int
    let startOffsetSeconds: Double
    let durationSeconds: Double
}

enum ChapterAudioSlicePlanFailure: Error, Equatable, Sendable {
    case invalidChapter
    case invalidTrackDurations
    case incompleteChapterCoverage
}

enum ChapterAudioSlicePlanner {
    static func slices(
        for chapter: PlaybackChapter,
        trackDurations: [Double]
    ) throws(ChapterAudioSlicePlanFailure) -> [ChapterAudioSlice] {
        var nextStartOffset = 0.0
        let tracks = trackDurations.enumerated().map { index, duration in
            defer { nextStartOffset += duration }
            return ChapterAudioTrack(
                trackIndex: index,
                startOffsetSeconds: nextStartOffset,
                durationSeconds: duration
            )
        }
        return try slices(for: chapter, tracks: tracks)
    }

    static func slices(
        for chapter: PlaybackChapter,
        tracks: [ChapterAudioTrack]
    ) throws(ChapterAudioSlicePlanFailure) -> [ChapterAudioSlice] {
        guard chapter.start.isFinite,
            chapter.end.isFinite,
            chapter.start >= 0,
            chapter.end > chapter.start
        else {
            throw .invalidChapter
        }
        guard !tracks.isEmpty,
            tracks.allSatisfy({
                $0.trackIndex >= 0
                    && $0.startOffsetSeconds.isFinite
                    && $0.startOffsetSeconds >= 0
                    && $0.durationSeconds.isFinite
                    && $0.durationSeconds > 0
            })
        else {
            throw .invalidTrackDurations
        }

        var slices: [ChapterAudioSlice] = []
        for track in tracks.sorted(by: {
            ($0.startOffsetSeconds, $0.trackIndex)
                < ($1.startOffsetSeconds, $1.trackIndex)
        }) {
            let trackEnd = track.startOffsetSeconds + track.durationSeconds
            let intersectionStart = max(
                chapter.start,
                track.startOffsetSeconds
            )
            let intersectionEnd = min(chapter.end, trackEnd)
            if intersectionEnd > intersectionStart {
                slices.append(
                    ChapterAudioSlice(
                        trackIndex: track.trackIndex,
                        audioStartSeconds:
                            intersectionStart - track.startOffsetSeconds,
                        durationSeconds:
                            intersectionEnd - intersectionStart,
                        wholeBookStartSeconds: intersectionStart
                    )
                )
            }
            if trackEnd >= chapter.end {
                break
            }
        }
        guard let first = slices.first,
            let last = slices.last,
            abs(first.wholeBookStartSeconds - chapter.start) < 0.01,
            abs(
                last.wholeBookStartSeconds
                    + last.durationSeconds
                    - chapter.end
            ) < 0.01,
            abs(
                slices.reduce(0) { $0 + $1.durationSeconds }
                    - (chapter.end - chapter.start)
            ) < 0.01,
            zip(slices, slices.dropFirst()).allSatisfy({ current, next in
                abs(
                    current.wholeBookStartSeconds
                        + current.durationSeconds
                        - next.wholeBookStartSeconds
                ) < 0.01
            })
        else {
            throw .incompleteChapterCoverage
        }
        return slices
    }
}

struct ChapterTranscriptionBookKey: Hashable, Sendable {
    let accountID: AccountID
    let itemID: LibraryItemID
}

struct ChapterTranscriptNavigationTarget: Hashable, Sendable, Identifiable {
    let chapterID: Int
    let segmentIndex: Int
    let startMilliseconds: Int64
    let endMilliseconds: Int64

    var id: Self { self }
}

enum ChapterTranscriptPositionResolution: Equatable, Sendable {
    case target(ChapterTranscriptNavigationTarget)
    case invalidPosition
    case chapterNotTranscribed(chapterID: Int)
    case noSpeechDetected(chapterID: Int)
}

enum ChapterTranscriptNavigationMessage: Equatable, Sendable {
    case noPosition
    case invalidPosition
    case chapterNotTranscribed(title: String)
    case noSpeechDetected(title: String)

    var text: String {
        switch self {
        case .noPosition:
            "No playback position is available for this audiobook."
        case .invalidPosition:
            "The playback position is outside this audiobook."
        case .chapterNotTranscribed(let title):
            "Chapter ‘\(title)’ has not been transcribed."
        case .noSpeechDetected(let title):
            "No speech was detected in \(title)."
        }
    }
}

enum ChapterTranscriptPositionResolver {
    private struct Candidate {
        let target: ChapterTranscriptNavigationTarget
        let distanceMilliseconds: Double
        let chapterOrder: Int
    }

    static func resolve(
        position: Double,
        chapters: [PlaybackChapter],
        transcripts: [CachedChapterTranscript]
    ) -> ChapterTranscriptPositionResolution {
        guard position.isFinite,
            position >= 0,
            position <= Double(Int64.max) / 1_000
        else {
            return .invalidPosition
        }
        let orderedChapters = chapters.sorted {
            ($0.start, $0.end, $0.id) < ($1.start, $1.end, $1.id)
        }
        guard
            let containingChapter = orderedChapters.first(where: {
                $0.start.isFinite
                    && $0.end.isFinite
                    && $0.start >= 0
                    && $0.end > $0.start
                    && $0.start <= position
                    && position < $0.end
            })
        else {
            return .invalidPosition
        }
        guard
            let containingTranscript = transcripts.first(where: {
                $0.chapterID == containingChapter.id
            })
        else {
            return .chapterNotTranscribed(chapterID: containingChapter.id)
        }
        guard !containingTranscript.segments.isEmpty else {
            return .noSpeechDetected(chapterID: containingChapter.id)
        }

        let positionMilliseconds = position * 1_000
        var chapterOrder: [Int: Int] = [:]
        for (index, chapter) in orderedChapters.enumerated()
        where chapterOrder[chapter.id] == nil {
            chapterOrder[chapter.id] = index
        }
        let candidates: [Candidate] = transcripts.flatMap {
            transcript -> [Candidate] in
            transcript.segments.enumerated().compactMap {
                index, segment -> Candidate? in
                guard segment.startMilliseconds >= 0,
                    segment.endMilliseconds >= segment.startMilliseconds,
                    let order = chapterOrder[transcript.chapterID]
                else {
                    return nil
                }
                let start = Double(segment.startMilliseconds)
                let end = Double(segment.endMilliseconds)
                let distance: Double
                if positionMilliseconds < start {
                    distance = start - positionMilliseconds
                } else if positionMilliseconds > end {
                    distance = positionMilliseconds - end
                } else {
                    distance = 0
                }
                return Candidate(
                    target: ChapterTranscriptNavigationTarget(
                        chapterID: transcript.chapterID,
                        segmentIndex: index,
                        startMilliseconds: segment.startMilliseconds,
                        endMilliseconds: segment.endMilliseconds
                    ),
                    distanceMilliseconds: distance,
                    chapterOrder: order
                )
            }
        }
        guard
            let target = candidates.min(by: { lhs, rhs in
                (
                    lhs.distanceMilliseconds,
                    lhs.chapterOrder,
                    lhs.target.startMilliseconds,
                    lhs.target.endMilliseconds,
                    lhs.target.segmentIndex
                ) < (
                    rhs.distanceMilliseconds,
                    rhs.chapterOrder,
                    rhs.target.startMilliseconds,
                    rhs.target.endMilliseconds,
                    rhs.target.segmentIndex
                )
            })?.target
        else {
            return .noSpeechDetected(chapterID: containingChapter.id)
        }
        return .target(target)
    }
}

enum ChapterTranscriptionBatchPlanner {
    static func orderedChapters(
        selectedChapterIDs: Set<Int>,
        from chapters: [PlaybackChapter]
    ) -> [PlaybackChapter] {
        chapters
            .filter { selectedChapterIDs.contains($0.id) }
            .sorted {
                ($0.id, $0.start, $0.end)
                    < ($1.id, $1.start, $1.end)
            }
    }
}

struct ChapterTranscriptionBatchProgress: Equatable, Sendable {
    let bookKey: ChapterTranscriptionBookKey
    let chapterID: Int
    let chapterTitle: String
    let completedChapters: Int
    let totalChapters: Int
}

enum ChapterTranscriptionViewFailure: Error, Equatable, Sendable {
    case job(ChapterTranscriptionJobFailure)
    case audioNotDownloaded
    case localAudioUnavailable
    case invalidChapterRange
    case cacheSaveFailed
    case transcription(ChapterTranscriptionFailure)
    case cancelled

    var message: String {
        switch self {
        case .job(let failure): failure.message
        case .audioNotDownloaded:
            "Download this chapter or the full audiobook before transcribing."
        case .localAudioUnavailable:
            "The downloaded audio could not be verified."
        case .invalidChapterRange:
            "This chapter could not be mapped to the downloaded audio."
        case .cacheSaveFailed:
            "The transcription was created but could not be saved."
        case .transcription(let failure):
            failure.localizedDescription
        case .cancelled:
            "Transcription was cancelled."
        }
    }

    var cachedTaskFailure: CachedChapterTranscriptionTaskFailure {
        switch self {
        case .job(let failure): failure.cachedTaskFailure
        case .audioNotDownloaded:
            .audioNotDownloaded
        case .localAudioUnavailable:
            .localAudioUnavailable
        case .invalidChapterRange:
            .invalidChapterRange
        case .cacheSaveFailed:
            .cacheSaveFailed
        case .cancelled:
            .cancelled
        case .transcription(let failure):
            failure.cachedTaskFailure
        }
    }
}

extension ChapterTranscriptionViewFailure {
    var remoteTelemetryOutcome: RemoteTelemetryOutcome {
        switch self {
        case .job: .failed(.localStorage)
        case .cancelled:
            .cancelled
        case .audioNotDownloaded:
            .failed(.offline)
        case .localAudioUnavailable, .invalidChapterRange:
            .failed(.media)
        case .cacheSaveFailed:
            .failed(.localStorage)
        case .transcription(let failure):
            .failed(failure.remoteTelemetryFailureCategory)
        }
    }
}

extension ChapterTranscriptionFailure {
    var remoteTelemetryFailureCategory: RemoteTelemetryFailureCategory {
        switch self {
        case .operatingSystemUnsupported, .unavailableOnDevice,
            .unsupportedLocale, .languageAssetsUnavailable:
            .unsupported
        case .languageAssetInstallationFailed:
            .transport
        case .audioFileUnreadable, .invalidChapterStart,
            .invalidAudioRange, .chapterExtractionUnavailable,
            .chapterExtractionFailed, .analyzerInputFailed,
            .analyzerFinalizationFailed, .resultStreamFailed:
            .media
        }
    }
}

extension ChapterTranscriptionFailure {
    var cachedTaskFailure: CachedChapterTranscriptionTaskFailure {
        switch self {
        case .invalidChapterStart, .invalidAudioRange:
            .invalidChapterRange
        case .operatingSystemUnsupported:
            .operatingSystemUnsupported
        case .unavailableOnDevice:
            .unavailableOnDevice
        case .unsupportedLocale:
            .unsupportedLocale
        case .languageAssetsUnavailable:
            .languageAssetsUnavailable
        case .languageAssetInstallationFailed:
            .languageAssetInstallationFailed
        case .audioFileUnreadable:
            .audioFileUnreadable
        case .chapterExtractionUnavailable:
            .chapterExtractionUnavailable
        case .chapterExtractionFailed:
            .chapterExtractionFailed
        case .analyzerInputFailed:
            .analyzerInputFailed
        case .analyzerFinalizationFailed:
            .analyzerFinalizationFailed
        case .resultStreamFailed:
            .resultStreamFailed
        }
    }
}

extension CachedChapterTranscriptionTaskFailure {
    var supportsImmediateRetry: Bool {
        switch self {
        case .jobPersistenceFailed, .cacheSaveFailed,
            .languageAssetInstallationFailed, .chapterExtractionFailed,
            .analyzerInputFailed, .analyzerFinalizationFailed,
            .resultStreamFailed:
            true
        case .jobMissingAudio, .jobSourceChanged, .jobChapterLayoutChanged,
            .jobInsufficientSourceIdentity, .jobInvalidCheckpoint,
            .jobStaleRevision, .audioNotDownloaded, .localAudioUnavailable,
            .invalidChapterRange, .cancelled, .operatingSystemUnsupported,
            .unavailableOnDevice, .unsupportedLocale,
            .languageAssetsUnavailable, .audioFileUnreadable,
            .chapterExtractionUnavailable:
            false
        }
    }

    var message: String {
        switch self {
        case .jobMissingAudio:
            ChapterTranscriptionJobFailure.missingAudio.message
        case .jobSourceChanged:
            ChapterTranscriptionJobFailure.sourceChanged.message
        case .jobChapterLayoutChanged:
            ChapterTranscriptionJobFailure.chapterLayoutChanged.message
        case .jobInsufficientSourceIdentity:
            ChapterTranscriptionJobFailure.insufficientSourceIdentity.message
        case .jobInvalidCheckpoint:
            ChapterTranscriptionJobFailure.invalidCheckpoint.message
        case .jobStaleRevision:
            ChapterTranscriptionJobFailure.staleRevision.message
        case .jobPersistenceFailed:
            ChapterTranscriptionJobFailure.persistenceFailed.message

        case .audioNotDownloaded:
            "Download this chapter or the full audiobook before transcribing."
        case .localAudioUnavailable:
            "The downloaded audio could not be verified."
        case .invalidChapterRange:
            "A selected chapter could not be mapped to the downloaded audio."
        case .cacheSaveFailed:
            "A transcription was created but could not be saved."
        case .cancelled:
            "Transcription was cancelled."
        case .operatingSystemUnsupported:
            "SpeechTranscriber requires iOS 26 or newer."
        case .unavailableOnDevice:
            "SpeechTranscriber is unavailable on this device."
        case .unsupportedLocale:
            "SpeechTranscriber does not support the selected locale on this device."
        case .languageAssetsUnavailable:
            "SpeechTranscriber language assets are unavailable for this locale."
        case .languageAssetInstallationFailed:
            "SpeechTranscriber language assets could not be installed."
        case .audioFileUnreadable:
            "The downloaded audio file could not be read."
        case .chapterExtractionUnavailable:
            "A selected chapter could not be extracted from the local audio file."
        case .chapterExtractionFailed:
            "A selected chapter could not be extracted for transcription."
        case .analyzerInputFailed:
            "SpeechTranscriber rejected the audio input."
        case .analyzerFinalizationFailed:
            "SpeechTranscriber could not finish analyzing the audio."
        case .resultStreamFailed:
            "SpeechTranscriber could not deliver transcription results."
        }
    }
}

enum ChapterTranscriptionViewState: Equatable, Sendable {
    case ready
    case preparingAudio(
        bookKey: ChapterTranscriptionBookKey,
        totalChapters: Int
    )
    case transcribing(
        progress: ChapterTranscriptionBatchProgress,
        completedSlices: Int,
        totalSlices: Int
    )
    case saving(ChapterTranscriptionBatchProgress)
    case cancelling(
        bookKey: ChapterTranscriptionBookKey,
        chapterID: Int?
    )
    case complete(
        bookKey: ChapterTranscriptionBookKey,
        chapterIDs: [Int]
    )
    case failed(
        bookKey: ChapterTranscriptionBookKey,
        chapterID: Int?,
        failure: ChapterTranscriptionViewFailure
    )

    var bookKey: ChapterTranscriptionBookKey? {
        switch self {
        case .ready:
            nil
        case .preparingAudio(let bookKey, _),
            .cancelling(let bookKey, _),
            .complete(let bookKey, _),
            .failed(let bookKey, _, _):
            bookKey
        case .transcribing(let progress, _, _),
            .saving(let progress):
            progress.bookKey
        }
    }

    var currentChapterID: Int? {
        switch self {
        case .transcribing(let progress, _, _), .saving(let progress):
            progress.chapterID
        case .failed(_, let chapterID, _):
            chapterID
        case .cancelling(_, let chapterID):
            chapterID
        case .ready, .preparingAudio, .complete:
            nil
        }
    }
}

enum ChapterTranscriptCacheViewFailure: Equatable, Sendable {
    case job(ChapterTranscriptionJobFailure)
    case loadFailed
    case saveFailed
    case taskStateLoadFailed
    case taskStateSaveFailed

    var message: String {
        switch self {
        case .job(let failure): failure.message
        case .loadFailed:
            "Saved transcriptions could not be loaded."
        case .saveFailed:
            "The transcription was created but could not be saved."
        case .taskStateLoadFailed:
            "The previous transcription result could not be loaded."
        case .taskStateSaveFailed:
            "The transcription result could not be saved."
        }
    }
}

enum ChapterTranscriptLocalDataStage: Equatable, Sendable {
    case presenceInspection
    case deletion
}

struct ChapterTranscriptLocalDataFailure: Equatable, Sendable {
    let stage: ChapterTranscriptLocalDataStage
    let cause: AppServiceError

    var title: String {
        switch stage {
        case .presenceInspection: "Transcript Data Status Unavailable"
        case .deletion: "Transcript Data Not Deleted"
        }
    }

    var message: String {
        let action =
            switch stage {
            case .presenceInspection: "check"
            case .deletion: "delete"
            }
        guard case .transcriptCache(let error) = cause else {
            return
                "Bleat could not \(action) the local transcript data because of an unexpected application error."
        }
        return switch error {
        case .job(let cause): cause.message
        case .invalidAccountID:
            "Bleat could not \(action) the local transcript data because its saved account identity is invalid."
        case .invalidItemID:
            "Bleat could not \(action) the local transcript data because its saved audiobook identity is invalid."
        case .invalidTranscript:
            "Bleat could not \(action) the local transcript data because a transcript is invalid."
        case .invalidStoredTranscript:
            "Bleat could not \(action) the local transcript data because the saved transcript is invalid."
        case .invalidTaskState:
            "Bleat could not \(action) the local transcript data because its transcription history is invalid."
        case .invalidStoredTaskState:
            "Bleat could not \(action) the local transcript data because the saved transcription history is invalid."
        case .encodingFailed:
            "Bleat could not \(action) the local transcript data because it could not be encoded."
        case .persistenceFailed:
            "Bleat could not \(action) the local transcript data because the local transcript store is unavailable."
        }
    }
}

enum ChapterTranscriptDeletionState: Equatable, Sendable {
    case idle
    case deleting
    case failed(ChapterTranscriptLocalDataFailure)
}

struct ActiveChapterTranscriptionBatch {
    let taskID: UUID
    let persistenceToken: UUID
    let bookKey: ChapterTranscriptionBookKey
    let account: ServerAccount
    let selectedChapterIDs: [Int]
    let startedAt: Date
    let startedInstant: ContinuousClock.Instant
}

struct PreparedChapterTranscriptionTrack: Equatable, Sendable {
    let timeline: ChapterAudioTrack
    let url: URL
}

struct PreparedChapterTranscriptionAudio: Sendable {
    let tracks: [PreparedChapterTranscriptionTrack]
    let cachePin: AutomaticCachePin?
}

struct ChapterTelemetryInputAccumulator {
    private var durationMilliseconds: Int64 = 0
    private var byteCount: Int64 = 0
    private var sliceCount = 0
    private var codec: RemoteTelemetryTranscriptionAudioCodec?
    private var sampleRateHz: Int?
    private var channelCount: Int?
    private var hasMixedSampleRates = false
    private var hasMixedChannelCounts = false
    private var isValid = true

    mutating func append(_ input: ChapterTranscriptionInput) {
        let duration = durationMilliseconds.addingReportingOverflow(
            input.durationMilliseconds
        )
        let bytes = byteCount.addingReportingOverflow(input.byteCount)
        guard !duration.overflow, !bytes.overflow else {
            isValid = false
            return
        }
        durationMilliseconds = duration.partialValue
        byteCount = bytes.partialValue
        sliceCount += 1

        let nextCodec = RemoteTelemetryTranscriptionAudioCodec(input.codec)
        if let codec, codec != nextCodec {
            self.codec = .mixed
        } else if codec == nil {
            codec = nextCodec
        }
        if let sampleRateHz, sampleRateHz != input.sampleRateHz {
            hasMixedSampleRates = true
        } else if sampleRateHz == nil {
            sampleRateHz = input.sampleRateHz
        }
        if let channelCount, channelCount != input.channelCount {
            hasMixedChannelCounts = true
        } else if channelCount == nil {
            channelCount = input.channelCount
        }
    }

    var telemetryInput: RemoteTelemetryTranscriptionInput? {
        guard isValid, let codec else { return nil }
        return RemoteTelemetryTranscriptionInput(
            durationMilliseconds: durationMilliseconds,
            byteCount: byteCount,
            sliceCount: sliceCount,
            container: .m4a,
            codec: codec,
            sampleRateHz: hasMixedSampleRates ? nil : sampleRateHz,
            channelCount: hasMixedChannelCounts ? nil : channelCount
        )
    }
}

extension RemoteTelemetryTranscriptionAudioCodec {
    fileprivate init(_ codec: ChapterTranscriptionAudioCodec) {
        switch codec {
        case .aac:
            self = .aac
        case .alac:
            self = .alac
        case .linearPCM:
            self = .linearPCM
        case .other:
            self = .other
        }
    }
}

enum ChapterTranscriptionAudioLoadFailure: Error, Equatable, Sendable {
    case audioNotDownloaded
    case localAudioUnavailable
}

typealias ChapterTranscriptionAudioLoader =
    @MainActor @Sendable (
        _ detail: LibraryBookDetail,
        _ account: ServerAccount,
        _ downloads: DownloadModel,
        _ chapters: [PlaybackChapter]
    ) async throws -> PreparedChapterTranscriptionAudio

typealias ChapterTranscriberFactory = @Sendable () -> any ChapterTranscribing

struct ChapterTranscriptionView: View {
    let detail: LibraryBookDetail
    let account: ServerAccount
    let appModel: AppModel
    @Bindable var downloads: DownloadModel
    let model: ChapterTranscriptionModel
    @State private var selectedChapterID: Int?
    @State private var selectedChapterIDs: Set<Int> = []
    @State private var isSelectingChapters = false
    @State private var searchQuery = ""
    @State private var showDownloadConfirmation = false
    @State private var playbackFailure: AppFailure?
    @State private var pendingExportFormat: TranscriptExportFormat?
    @State private var exportArtifact: TranscriptExportArtifact?
    @State private var exportFailure: TranscriptExportArtifactError?
    @State private var showTranscriptDeletionConfirmation = false
    @State private var pendingReplacement: [PlaybackChapter]?
    @State private var currentPositionMessage:
        ChapterTranscriptNavigationMessage?
    @State private var highlightedTarget: ChapterTranscriptNavigationTarget?
    @State private var chapterNavigationRequest: ChapterNavigationRequest?
    @State private var pendingTranscriptionChapter: PlaybackChapter?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct ChapterNavigationRequest: Equatable {
        let id = UUID()
        let chapterID: Int
        let offerTranscription: Bool
    }

    init(
        detail: LibraryBookDetail,
        account: ServerAccount,
        appModel: AppModel,
        downloads: DownloadModel
    ) {
        self.detail = detail
        self.account = account
        self.appModel = appModel
        self.downloads = downloads
        model = appModel.transcription
        _selectedChapterID = State(initialValue: detail.chapters.first?.id)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                List {
                    cacheFailureContent
                    if let job = model.resumableJob(for: bookKey),
                        !model.isWorking(for: bookKey)
                    {
                        resumableJobContent(job)
                    }
                    transcriptionStatusContent
                    playbackFailureContent
                    if model.hasLoadedTranscriptCache(for: bookKey) {
                        currentPositionContent
                    }
                    if hasSearchQuery {
                        searchContent
                    } else {
                        chapterSelector
                        selectedTranscriptContent
                    }
                }
                .confirmationDialog(
                    "Replace the unfinished transcription selection?",
                    isPresented: Binding(
                        get: { pendingReplacement != nil },
                        set: { if !$0 { pendingReplacement = nil } }),
                    titleVisibility: .visible
                ) {
                    Button("Replace Selection") {
                        if let chapters = pendingReplacement {
                            startSelection(chapters, replacePending: true)
                        }
                        pendingReplacement = nil
                    }
                    Button("Cancel", role: .cancel) { pendingReplacement = nil }
                } message: {
                    Text("Saved transcript text will be kept.")
                }
                .navigationTitle("Transcription")
                .iOSInlineNavigationTitle()
                .searchable(
                    text: $searchQuery,
                    prompt: "Search Transcriptions"
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button(isSelectingChapters ? "Cancel" : "Select") {
                            if isSelectingChapters {
                                selectedChapterIDs.removeAll()
                            }
                            isSelectingChapters.toggle()
                        }
                        .disabled(
                            model.isWorking || hasSearchQuery
                                || !model.hasLoadedTranscriptCache(for: bookKey)
                                || (!isSelectingChapters
                                    && chaptersNeedingTranscription.isEmpty)
                        )
                        .accessibilityIdentifier("transcription.select")
                    }
                    if exportSnapshot.hasSegments {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                Button("WebVTT") {
                                    chooseExportFormat(.webVTT)
                                }
                                .accessibilityIdentifier(
                                    "transcription.export.webVTT"
                                )
                                Button("SRT") {
                                    chooseExportFormat(.subRip)
                                }
                                .accessibilityIdentifier(
                                    "transcription.export.subRip"
                                )
                            } label: {
                                Label(
                                    "Export Transcript",
                                    systemImage: "square.and.arrow.up"
                                )
                            }
                            .disabled(hasSearchQuery)
                            .accessibilityIdentifier("transcription.export")
                        }
                    }
                    if model.hasLocalData(for: bookKey) {
                        ToolbarItem(placement: .primaryAction) {
                            Button(
                                "Delete Transcript Data",
                                systemImage: "trash",
                                role: .destructive
                            ) {
                                showTranscriptDeletionConfirmation = true
                            }
                            .disabled(isDeletingTranscript)
                            .accessibilityIdentifier(
                                "transcription.delete"
                            )
                        }
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    actionBar
                }
                .confirmationDialog(
                    "Download Audiobook?",
                    isPresented: $showDownloadConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Download Audiobook") {
                        Task {
                            await downloads.download(
                                detail: detail,
                                account: account
                            )
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Transcription uses verified audio stored on this device."
                    )
                }
                #if DEBUG || BLEAT_UI_TESTING
                    .overlay {
                        if ProcessInfo.processInfo.arguments.contains(
                            "--ui-testing-accessibility-audit"
                        ) {
                            Text(reduceMotion ? "enabled" : "disabled")
                            .accessibilityIdentifier(
                                "transcription.reduceMotion"
                            )
                            .opacity(0)
                            .allowsHitTesting(false)
                        }
                    }
                #endif
                .alert(
                    "Start Transcription?",
                    isPresented: Binding(
                        get: { pendingTranscriptionChapter != nil },
                        set: { if !$0 { pendingTranscriptionChapter = nil } }
                    )
                ) {
                    if let chapter = pendingTranscriptionChapter {
                        Button("Start Transcription") {
                            pendingTranscriptionChapter = nil
                            startChapterTranscription(chapter)
                        }
                    }
                    Button("Cancel", role: .cancel) {
                        pendingTranscriptionChapter = nil
                    }
                } message: {
                    if let chapter = pendingTranscriptionChapter {
                        Text(
                            ChapterTranscriptNavigationMessage
                                .chapterNotTranscribed(
                                    title: chapter.title
                                ).text
                        )
                    }
                }
                .task(id: chapterNavigationRequest) {
                    guard let request = chapterNavigationRequest else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    scrollProxy.scrollTo(request.chapterID, anchor: .center)
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    if request.offerTranscription,
                        let chapter = detail.chapters.first(where: {
                            $0.id == request.chapterID
                        }), canStartChapterTranscription(chapter)
                    {
                        pendingTranscriptionChapter = chapter
                    }
                }
                .task(id: highlightedTarget) {
                    guard let target = highlightedTarget else {
                        return
                    }
                    await Task.yield()
                    withAnimation(reduceMotion ? nil : .default) {
                        scrollProxy.scrollTo(target, anchor: .center)
                    }
                    do {
                        try await Task.sleep(for: .seconds(2))
                    } catch {
                        return
                    }
                    if highlightedTarget == target {
                        highlightedTarget = nil
                    }
                }
            }
            .confirmationDialog(
                "Export Incomplete Transcript?",
                isPresented: incompleteExportConfirmation,
                titleVisibility: .visible
            ) {
                if let pendingExportFormat {
                    Button("Export \(pendingExportFormat.title)") {
                        export(pendingExportFormat)
                    }
                }
                Button("Cancel", role: .cancel) {
                    pendingExportFormat = nil
                }
            } message: {
                Text(
                    "Only \(exportSnapshot.availableChapterCount) of \(exportSnapshot.totalChapterCount) chapters have transcript data. Bleat will export the available transcript."
                )
            }
            .alert(
                "Export Failed",
                isPresented: exportFailurePresentation
            ) {
                Button("OK") {
                    exportFailure = nil
                }
            } message: {
                Text(
                    exportFailure?.localizedDescription
                        ?? "The transcript could not be exported."
                )
            }
            .confirmationDialog(
                "Delete Transcript Data?",
                isPresented: $showTranscriptDeletionConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Transcript Data", role: .destructive) {
                    deleteTranscriptData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This deletes the local transcript and transcription history for this audiobook. Downloaded audio, bookmarks, and playback position are not affected."
                )
            }
            .alert(
                deletionFailure?.title ?? "Transcript Data Not Deleted",
                isPresented: deletionFailurePresentation
            ) {
                Button("OK") {
                    model.dismissDeletionFailure(for: bookKey)
                }
            } message: {
                Text(
                    deletionFailure?.message
                        ?? "Bleat could not delete the local transcript data."
                )
            }
        }
        .sheet(item: $exportArtifact) { artifact in
            TranscriptShareSheet(
                payload: TranscriptSharePayload(artifact: artifact)
            )
        }
        .accessibilityIdentifier("transcription.view")
        .onAppear {
            model.retainTranscriptCache(for: bookKey)
        }
        .onDisappear {
            model.releaseTranscriptCache(for: bookKey)
        }
        .task(id: "\(account.id.rawValue):\(detail.id.rawValue)") {
            await model.loadCachedTranscripts(
                detail: detail,
                account: account,
                appModel: appModel
            )
        }
    }

    @ViewBuilder
    private var chapterSelector: some View {
        Section {
            ForEach(detail.chapters, id: \.id) { chapter in
                let isCached = model.isCached(
                    chapterID: chapter.id,
                    for: bookKey
                )
                Button {
                    if isSelectingChapters {
                        guard !isCached else { return }
                        if selectedChapterIDs.contains(chapter.id) {
                            selectedChapterIDs.remove(chapter.id)
                        } else {
                            selectedChapterIDs.insert(chapter.id)
                        }
                    } else {
                        selectedChapterID = chapter.id
                    }
                } label: {
                    HStack {
                        Text(chapter.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if isCached {
                            Image(systemName: "text.badge.checkmark")
                                .accessibilityLabel("Transcribed")
                        }
                        if model.state.currentChapterID == chapter.id,
                            model.isWorking(for: bookKey)
                        {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Transcribing")
                        }
                        if isSelectingChapters, !isCached {
                            Image(
                                systemName: selectedChapterIDs.contains(
                                    chapter.id
                                )
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(
                                selectedChapterIDs.contains(chapter.id)
                                    ? Color.accentColor
                                    : Color.secondary
                            )
                        } else if selectedChapterID == chapter.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityIdentifier(
                    "transcription.chapter.\(chapter.id)"
                )
                .id(chapter.id)
                .accessibilityAddTraits(
                    selectedChapterID == chapter.id ? .isSelected : []
                )
                .buttonStyle(.plain)
                .disabled(isSelectingChapters && isCached)
            }
        } header: {
            HStack {
                Text("Chapters")
                Spacer()
                if isSelectingChapters {
                    Button("Select All") {
                        selectedChapterIDs = Set(
                            chaptersNeedingTranscription.map(\.id)
                        )
                    }
                    .disabled(
                        chaptersNeedingTranscription.isEmpty
                            || selectedUncachedChapterIDs.count
                                == chaptersNeedingTranscription.count
                    )
                    .accessibilityIdentifier("transcription.selectAll")
                }
            }
        }
    }

    @ViewBuilder
    private var cacheFailureContent: some View {
        if let failure = model.cacheFailure(for: bookKey) {
            Section {
                Label(
                    failure.message,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    @ViewBuilder
    private func resumableJobContent(
        _ job: ChapterTranscriptionJob
    ) -> some View {
        Section {
            Text(
                "\(job.completedChapterIDs.count) completed, \(job.unfinishedChapters.count) remaining"
            )
            .accessibilityIdentifier("transcription.resumeProgress")

            VStack(alignment: .leading, spacing: 6) {
                Text("Remaining chapters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(job.unfinishedChapters, id: \.id) { chapter in
                    Text(chapterTitle(chapter.id))
                        .accessibilityIdentifier(
                            "transcription.resumeChapter.\(chapter.id)"
                        )
                }
            }

            Button("Retry Remaining Chapters", systemImage: "arrow.clockwise") {
                retryResumableJob()
            }
            .disabled(
                model.isWorking
                    || !model.hasLoadedTranscriptCache(for: bookKey)
            )
            .accessibilityIdentifier("transcription.retryRemaining")
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let matches = model.searchResults(
            query: searchQuery,
            for: bookKey
        )
        Section("Search Results") {
            if matches.isEmpty {
                Text("No cached transcription matches this search.")
            } else {
                ForEach(Array(matches.enumerated()), id: \.offset) {
                    index, match in
                    transcriptSegmentMenu(
                        segment: TranscriptSegment(cached: match.segment),
                        identifier: "transcription.searchResult.\(index)",
                        beforeMovingPlayback: {
                            selectedChapterID = match.chapterID
                            searchQuery = ""
                        }
                    ) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(
                                "\(match.chapterTitle) - \(timestamp(match.segment.startMilliseconds))"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            Text(match.segment.text)
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var playbackFailureContent: some View {
        if let playbackFailure {
            Section {
                Label(
                    playbackFailure.message,
                    systemImage: playbackFailure.systemImage
                )
                .foregroundStyle(.red)
                .accessibilityIdentifier("transcription.playbackError")
            }
        }
    }

    @ViewBuilder
    private var transcriptionStatusContent: some View {
        if isDeletingTranscript {
            Section {
                ProgressView("Deleting transcript data")
            }
        } else if model.isWorking, !model.isWorking(for: bookKey) {
            Section {
                Label(
                    "Another audiobook is being transcribed.",
                    systemImage: "waveform.badge.mic"
                )
            }
        } else if let state = model.state(for: bookKey) {
            switch state {
            case .ready:
                EmptyView()
            case .preparingAudio(_, let totalChapters):
                Section {
                    ProgressView("Preparing \(chapterCountText(totalChapters))")
                }
            case .transcribing(
                let progress,
                let completedSlices,
                let totalSlices
            ):
                Section {
                    ProgressView(
                        value: Double(progress.completedChapters),
                        total: Double(max(progress.totalChapters, 1))
                    )
                    Text(
                        "Transcribing \(progress.chapterTitle) (\(progress.completedChapters + 1) of \(progress.totalChapters))"
                    )
                    if totalSlices > 1 {
                        Text(
                            "Audio file \(completedSlices + 1) of \(totalSlices)"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            case .saving(let progress):
                Section {
                    ProgressView(
                        "Saving \(progress.chapterTitle) (\(progress.completedChapters + 1) of \(progress.totalChapters))"
                    )
                }
            case .cancelling:
                Section {
                    ProgressView("Cancelling transcription")
                }
            case .complete(_, let chapterIDs):
                if let terminalState = model.terminalState(for: bookKey) {
                    terminalStateContent(terminalState)
                } else {
                    Section {
                        Label(
                            "Transcribed \(chapterCountText(chapterIDs.count)).",
                            systemImage: "checkmark.circle"
                        )
                    }
                }
            case .failed(_, _, let failure):
                if let terminalState = model.terminalState(for: bookKey) {
                    terminalStateContent(terminalState)
                } else {
                    Section {
                        Label(
                            failure.message,
                            systemImage: "exclamationmark.triangle"
                        )
                        if failure == .audioNotDownloaded
                            || failure == .job(.missingAudio)
                        {
                            Button("Download Audiobook") {
                                showDownloadConfirmation = true
                            }
                        }
                    }
                }
            }
        } else if let terminalState = model.terminalState(for: bookKey) {
            terminalStateContent(terminalState)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func terminalStateContent(
        _ terminalState: CachedChapterTranscriptionTaskState
    ) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                switch terminalState.outcome {
                case .succeeded:
                    Label(
                        "Transcribed \(chapterCountText(terminalState.completedChapterIDs.count)) in \(elapsedTime(terminalState.durationMilliseconds)).",
                        systemImage: "checkmark.circle"
                    )
                    .accessibilityIdentifier("transcription.terminalState")
                case .failed:
                    Label(
                        terminalState.failure?.message
                            ?? "Transcription failed.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .accessibilityIdentifier("transcription.terminalState")
                    Text(
                        "Failed after \(elapsedTime(terminalState.durationMilliseconds))."
                    )
                    .foregroundStyle(.secondary)
                    attemptedChapterContent(terminalState)
                case .cancelled:
                    Label(
                        "Transcription was cancelled.",
                        systemImage: "xmark.circle"
                    )
                    .accessibilityIdentifier("transcription.terminalState")
                    Text(
                        "Cancelled after \(elapsedTime(terminalState.durationMilliseconds))."
                    )
                    .foregroundStyle(.secondary)
                }
                if terminalState.completedChapterIDs.count
                    < terminalState.selectedChapterIDs.count
                {
                    Text(
                        "\(terminalState.completedChapterIDs.count) of \(terminalState.selectedChapterIDs.count) chapters completed."
                    )
                    .foregroundStyle(.secondary)
                }
                Text(
                    "Finished \(terminalState.finishedAt.formatted(date: .abbreviated, time: .shortened))"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if terminalState.failure == .audioNotDownloaded
                || terminalState.failure == .jobMissingAudio
            {
                Button("Download Audiobook") {
                    showDownloadConfirmation = true
                }
            }
            if terminalState.outcome == .failed,
                terminalState.failure?.supportsImmediateRetry == true,
                !terminalRetryChapters(terminalState).isEmpty
            {
                Button(
                    "Retry Failed Transcription",
                    systemImage: "arrow.clockwise"
                ) {
                    retry(terminalState)
                }
                .disabled(
                    model.isWorking
                        || !model.hasLoadedTranscriptCache(for: bookKey)
                )
                .accessibilityIdentifier("transcription.retryFailure")
            }
        }
    }

    @ViewBuilder
    private func attemptedChapterContent(
        _ terminalState: CachedChapterTranscriptionTaskState
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Attempted chapters")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(terminalState.selectedChapterIDs, id: \.self) { chapterID in
                if terminalState.currentChapterID == chapterID {
                    Label(
                        chapterTitle(chapterID),
                        systemImage: "exclamationmark.circle"
                    )
                    .accessibilityIdentifier(
                        "transcription.failedChapter.\(chapterID)"
                    )
                } else {
                    Text(chapterTitle(chapterID))
                        .accessibilityIdentifier(
                            "transcription.attemptedChapter.\(chapterID)"
                        )
                }
            }
        }
    }

    @ViewBuilder
    private var currentPositionContent: some View {
        Section {
            Button("Go to current position", systemImage: "scope") {
                goToCurrentPosition()
            }
            .accessibilityIdentifier("transcription.goToCurrentPosition")

            if let currentPositionMessage {
                Text(currentPositionMessage.text)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(
                        "transcription.currentPositionMessage"
                    )
            }
        }
    }

    @ViewBuilder
    private var selectedTranscriptContent: some View {
        if let selectedChapterID,
            let segments = model.transcriptSegments(
                chapterID: selectedChapterID,
                for: bookKey
            )
        {
            Section("Transcript") {
                if segments.isEmpty {
                    Text("No speech was detected in this chapter.")
                } else {
                    ForEach(
                        Array(segments.enumerated()),
                        id: \.offset
                    ) { index, segment in
                        let target = ChapterTranscriptNavigationTarget(
                            chapterID: selectedChapterID,
                            segmentIndex: index,
                            startMilliseconds: segment.startMilliseconds,
                            endMilliseconds: segment.endMilliseconds
                        )
                        transcriptSegmentRow(
                            segment: segment,
                            target: target,
                            identifier:
                                "transcription.segment.\(selectedChapterID).\(index)"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func transcriptSegmentRow(
        segment: TranscriptSegment,
        target: ChapterTranscriptNavigationTarget,
        identifier: String
    ) -> some View {
        let isHighlighted = highlightedTarget == target
        let row = transcriptSegmentMenu(
            segment: segment,
            identifier: isHighlighted
                ? "transcription.currentPositionHighlight"
                : identifier
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(timestamp(segment.startMilliseconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(segment.text)
                    .foregroundStyle(.primary)
            }
        }
        .id(target)

        if isHighlighted {
            row.listRowBackground(Color.accentColor.opacity(0.2))
        } else {
            row
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if hasSearchQuery {
            EmptyView()
        } else if isDeletingTranscript {
            Button("Deleting Transcript Data…") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
        } else if model.isCancelling(for: bookKey) {
            Button("Cancelling…") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
        } else if model.isWorking(for: bookKey) {
            Button("Cancel", role: .cancel) {
                model.cancel()
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        } else if model.isWorking {
            Button("Transcription in Progress") {}
                .buttonStyle(.borderedProminent)
                .disabled(true)
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
        } else if !isSelectingChapters, model.resumableJob(for: bookKey) != nil
        {
            EmptyView()
        } else if isSelectingChapters {
            Button(
                "Transcribe \(chapterCountText(selectedUncachedChapterIDs.count))",
                systemImage: "waveform.badge.mic"
            ) {
                let chapters =
                    ChapterTranscriptionBatchPlanner
                    .orderedChapters(
                        selectedChapterIDs: selectedUncachedChapterIDs,
                        from: detail.chapters
                    )
                selectedChapterID = chapters.first?.id
                startSelection(chapters)
                isSelectingChapters = false
                selectedChapterIDs.removeAll()
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedUncachedChapterIDs.isEmpty)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("transcription.startBatch")
        } else {
            let hasLoadedCache = model.hasLoadedTranscriptCache(for: bookKey)
            let selectedChapterIsCached = model.isCached(
                chapterID: selectedChapterID ?? Int.min,
                for: bookKey
            )
            Button(
                !hasLoadedCache
                    ? "Loading Transcriptions"
                    : selectedChapterIsCached
                        ? "Transcribed"
                        : "Start Transcription",
                systemImage: "waveform.badge.mic"
            ) {
                guard let chapter = selectedChapter else {
                    return
                }
                startChapterTranscription(chapter)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                selectedChapter == nil || !hasLoadedCache
                    || selectedChapterIsCached
            )
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("transcription.start")
        }
    }

    private func startSelection(
        _ chapters: [PlaybackChapter], replacePending: Bool = false
    ) {
        if let job = model.resumableJob(for: bookKey), !replacePending {
            if ChapterTranscriptionResumePlanner.canResumeSelection(
                chapters, job: job, detail: detail)
            {
                model.start(
                    chapters: [], detail: detail, account: account,
                    downloads: downloads, appModel: appModel, resume: true)
            } else {
                pendingReplacement = chapters
            }
            return
        }
        model.start(
            chapters: chapters, detail: detail, account: account,
            downloads: downloads, appModel: appModel,
            replacePending: replacePending)
    }

    private func retryResumableJob() {
        model.start(
            chapters: [], detail: detail, account: account,
            downloads: downloads, appModel: appModel, resume: true)
    }

    private func retry(
        _ terminalState: CachedChapterTranscriptionTaskState
    ) {
        startSelection(terminalRetryChapters(terminalState))
    }

    private func terminalRetryChapters(
        _ terminalState: CachedChapterTranscriptionTaskState
    ) -> [PlaybackChapter] {
        let completedChapterIDs = Set(terminalState.completedChapterIDs)
        let retryChapterIDs = Set(terminalState.selectedChapterIDs).subtracting(
            completedChapterIDs
        )
        return ChapterTranscriptionBatchPlanner.orderedChapters(
            selectedChapterIDs: retryChapterIDs,
            from: detail.chapters
        )
    }

    private var selectedChapter: PlaybackChapter? {
        detail.chapters.first { $0.id == selectedChapterID }
    }

    private var chaptersNeedingTranscription: [PlaybackChapter] {
        model.chaptersNeedingTranscription(
            detail.chapters,
            for: bookKey
        )
    }

    private var selectedUncachedChapterIDs: Set<Int> {
        selectedChapterIDs.intersection(
            chaptersNeedingTranscription.map(\.id)
        )
    }

    private var bookKey: ChapterTranscriptionBookKey {
        ChapterTranscriptionBookKey(
            accountID: account.id,
            itemID: detail.id
        )
    }

    private var exportSnapshot: ChapterTranscriptExportSnapshot {
        model.transcriptExportSnapshot(
            for: bookKey,
            expectedChapterIDs: detail.chapters.map(\.id)
        )
    }

    private var incompleteExportConfirmation: Binding<Bool> {
        Binding(
            get: { pendingExportFormat != nil },
            set: { isPresented in
                if !isPresented {
                    pendingExportFormat = nil
                }
            }
        )
    }

    private var exportFailurePresentation: Binding<Bool> {
        Binding(
            get: { exportFailure != nil },
            set: { isPresented in
                if !isPresented {
                    exportFailure = nil
                }
            }
        )
    }

    private var deletionFailurePresentation: Binding<Bool> {
        Binding(
            get: {
                if case .failed = model.deletionState(for: bookKey) {
                    return true
                }
                return false
            },
            set: { isPresented in
                if !isPresented {
                    model.dismissDeletionFailure(for: bookKey)
                }
            }
        )
    }

    private var deletionFailure: ChapterTranscriptLocalDataFailure? {
        guard case .failed(let failure) = model.deletionState(for: bookKey)
        else {
            return nil
        }
        return failure
    }

    private var isDeletingTranscript: Bool {
        model.deletionState(for: bookKey) == .deleting
    }

    private func deleteTranscriptData() {
        Task {
            let deleted = await model.deleteLocalData(
                detail: detail,
                account: account,
                appModel: appModel
            )
            guard deleted else {
                return
            }
            searchQuery = ""
            selectedChapterIDs.removeAll()
            isSelectingChapters = false
            currentPositionMessage = nil
            highlightedTarget = nil
            pendingExportFormat = nil
            exportArtifact = nil
            exportFailure = nil
        }
    }

    private func chooseExportFormat(_ format: TranscriptExportFormat) {
        if exportSnapshot.isIncomplete {
            pendingExportFormat = format
        } else {
            export(format)
        }
    }

    private func export(_ format: TranscriptExportFormat) {
        let snapshot = exportSnapshot
        let title = detail.title
        pendingExportFormat = nil
        Task {
            do {
                let artifact = try await Task.detached(priority: .utility) {
                    try TranscriptExportArtifactWriter().write(
                        title: title,
                        transcripts: snapshot.transcripts,
                        format: format,
                        isIncomplete: snapshot.isIncomplete
                    )
                }.value
                exportArtifact = artifact
            } catch let failure as TranscriptExportArtifactError {
                exportFailure = failure
            } catch {
                exportFailure = .cannotWriteArtifact
            }
        }
    }

    private var hasSearchQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canStartChapterTranscription(_ chapter: PlaybackChapter)
        -> Bool
    {
        !model.isWorking && !isDeletingTranscript
            && model.hasLoadedTranscriptCache(for: bookKey)
            && !model.isCached(chapterID: chapter.id, for: bookKey)
    }

    private func startChapterTranscription(_ chapter: PlaybackChapter) {
        guard canStartChapterTranscription(chapter) else { return }
        startSelection([chapter])
    }

    private func revealChapter(_ chapterID: Int, offerTranscription: Bool) {
        searchQuery = ""
        isSelectingChapters = false
        selectedChapterIDs.removeAll()
        selectedChapterID = chapterID
        chapterNavigationRequest = ChapterNavigationRequest(
            chapterID: chapterID, offerTranscription: offerTranscription
        )
    }

    private func goToCurrentPosition() {
        pendingTranscriptionChapter = nil
        chapterNavigationRequest = nil
        currentPositionMessage = nil
        highlightedTarget = nil
        guard
            let position = appModel.playback.transcriptNavigationPosition(
                accountID: account.id,
                itemID: detail.id,
                serverProgress: detail.progress.map { (account.id, $0) }
            )
        else {
            currentPositionMessage = .noPosition
            return
        }
        switch model.resolveTranscriptPosition(
            position.wholeBookTime,
            detail: detail,
            account: account
        ) {
        case .target(let target):
            searchQuery = ""
            isSelectingChapters = false
            selectedChapterIDs.removeAll()
            selectedChapterID = target.chapterID
            highlightedTarget = target
        case .invalidPosition:
            currentPositionMessage = .invalidPosition
        case .chapterNotTranscribed(let chapterID):
            revealChapter(chapterID, offerTranscription: true)
            currentPositionMessage = .chapterNotTranscribed(
                title: chapterTitle(chapterID)
            )
        case .noSpeechDetected(let chapterID):
            revealChapter(chapterID, offerTranscription: false)
            currentPositionMessage = .noSpeechDetected(
                title: chapterTitle(chapterID)
            )
        }
    }

    private func chapterTitle(_ chapterID: Int) -> String {
        detail.chapters.first(where: { $0.id == chapterID })?.title
            ?? "This chapter"
    }

    private func transcriptSegmentMenu<Label: View>(
        segment: TranscriptSegment,
        identifier: String,
        beforeMovingPlayback: @escaping () -> Void = {},
        @ViewBuilder label: () -> Label
    ) -> some View {
        Menu {
            Button("Copy Text", systemImage: "doc.on.doc") {
                PlatformClipboard.copy(segment.text)
            }
            .accessibilityIdentifier("transcription.copyText")

            Button("Move Playback Here", systemImage: "playhead.right") {
                beforeMovingPlayback()
                Task {
                    playbackFailure = nil
                    let outcome = await appModel.startPlayback(
                        detail: detail,
                        account: account,
                        position: .absoluteTime(
                            Double(segment.startMilliseconds) / 1_000
                        )
                    )
                    if case .failed(let failure) = outcome {
                        playbackFailure = failure
                    }
                }
            }
            .accessibilityIdentifier("transcription.movePlayback")
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    private func chapterCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "chapter" : "chapters")"
    }

    private func elapsedTime(_ milliseconds: Int64) -> String {
        let roundedSeconds = max(
            1,
            milliseconds / 1_000 + (milliseconds % 1_000 == 0 ? 0 : 1)
        )
        let hours = roundedSeconds / 3_600
        let minutes = (roundedSeconds / 60) % 60
        let seconds = roundedSeconds % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append("\(hours)h")
        }
        if minutes > 0 {
            parts.append("\(minutes)m")
        }
        if seconds > 0 || parts.isEmpty {
            parts.append("\(seconds)s")
        }
        return parts.joined(separator: " ")
    }

    private func timestamp(_ milliseconds: Int64) -> String {
        let totalSeconds = milliseconds / 1_000
        return String(
            format: "%02lld:%02lld:%02lld",
            totalSeconds / 3_600,
            (totalSeconds / 60) % 60,
            totalSeconds % 60
        )
    }
}
