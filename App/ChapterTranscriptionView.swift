import AVFAudio
import BleatCore
import BleatTranscription
import Foundation
import Observation
import SwiftUI

struct ChapterAudioSlice: Equatable, Sendable {
    let trackIndex: Int
    let audioStartSeconds: Double
    let durationSeconds: Double
    let wholeBookStartSeconds: Double
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
        guard chapter.start.isFinite,
            chapter.end.isFinite,
            chapter.start >= 0,
            chapter.end > chapter.start
        else {
            throw .invalidChapter
        }
        guard !trackDurations.isEmpty,
            trackDurations.allSatisfy({ $0.isFinite && $0 > 0 })
        else {
            throw .invalidTrackDurations
        }

        var trackStart = 0.0
        var slices: [ChapterAudioSlice] = []
        for (trackIndex, trackDuration) in trackDurations.enumerated() {
            let trackEnd = trackStart + trackDuration
            let intersectionStart = max(chapter.start, trackStart)
            let intersectionEnd = min(chapter.end, trackEnd)
            if intersectionEnd > intersectionStart {
                slices.append(
                    ChapterAudioSlice(
                        trackIndex: trackIndex,
                        audioStartSeconds: intersectionStart - trackStart,
                        durationSeconds:
                            intersectionEnd - intersectionStart,
                        wholeBookStartSeconds: intersectionStart
                    )
                )
            }
            trackStart = trackEnd
            if trackStart >= chapter.end {
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
            ) < 0.01
        else {
            throw .incompleteChapterCoverage
        }
        return slices
    }
}

enum ChapterTranscriptionViewFailure: Error, Equatable, Sendable {
    case audioNotDownloaded
    case playbackActive
    case localAudioUnavailable
    case invalidChapterRange
    case transcription(ChapterTranscriptionFailure)
    case cancelled

    var message: String {
        switch self {
        case .audioNotDownloaded:
            "Download this audiobook before transcribing a chapter."
        case .playbackActive:
            "Pause playback before starting transcription."
        case .localAudioUnavailable:
            "The downloaded audio could not be verified."
        case .invalidChapterRange:
            "This chapter could not be mapped to the downloaded audio."
        case .transcription(let failure):
            failure.localizedDescription
        case .cancelled:
            "Transcription was cancelled."
        }
    }
}

enum ChapterTranscriptionViewState: Equatable, Sendable {
    case ready
    case preparingAudio
    case transcribing(completedSlices: Int, totalSlices: Int)
    case saving
    case complete([TranscriptSegment])
    case failed(ChapterTranscriptionViewFailure)
}

enum ChapterTranscriptCacheViewFailure: Equatable, Sendable {
    case loadFailed
    case saveFailed

    var message: String {
        switch self {
        case .loadFailed:
            "Saved transcriptions could not be loaded."
        case .saveFailed:
            "The transcription was created but could not be saved."
        }
    }
}

@MainActor
@Observable
final class ChapterTranscriptionModel {
    private(set) var state: ChapterTranscriptionViewState = .ready
    private(set) var cachedTranscripts: [CachedChapterTranscript] = []
    private(set) var cacheFailure: ChapterTranscriptCacheViewFailure?
    private var transcriptionTask: Task<Void, Never>?

    var isWorking: Bool {
        switch state {
        case .preparingAudio, .transcribing, .saving:
            true
        case .ready, .complete, .failed:
            false
        }
    }

    func loadCachedTranscripts(
        detail: LibraryBookDetail,
        account: ServerAccount,
        appModel: AppModel,
        selectedChapterID: Int?
    ) async {
        do {
            cachedTranscripts =
                try await appModel
                .cachedChapterTranscripts(
                    for: account,
                    itemID: detail.id
                )
            cacheFailure = nil
            if !isWorking, let selectedChapterID {
                showChapter(selectedChapterID)
            }
        } catch is CancellationError {
            return
        } catch {
            cacheFailure = .loadFailed
        }
    }

    func showChapter(_ chapterID: Int) {
        cancel()
        guard
            let transcript = cachedTranscripts.first(where: {
                $0.chapterID == chapterID
            })
        else {
            state = .ready
            return
        }
        state = .complete(
            transcript.segments.map(TranscriptSegment.init(cached:))
        )
    }

    func isCached(chapterID: Int) -> Bool {
        cachedTranscripts.contains { $0.chapterID == chapterID }
    }

    func searchResults(
        query: String
    ) -> [CachedChapterTranscriptMatch] {
        CachedChapterTranscriptSearch.matches(
            query: query,
            in: cachedTranscripts
        )
    }

    func start(
        chapter: PlaybackChapter,
        detail: LibraryBookDetail,
        account: ServerAccount,
        downloads: DownloadModel,
        playback: PlaybackModel,
        appModel: AppModel
    ) {
        guard !isWorking else {
            return
        }
        guard !playback.isPlaybackRequested else {
            state = .failed(.playbackActive)
            return
        }
        transcriptionTask = Task(priority: .utility) {
            state = .preparingAudio
            do {
                guard
                    let record = downloads.record(
                        accountID: account.id,
                        itemID: detail.id
                    ), downloads.isFullBookAvailable(record)
                else {
                    state = .failed(.audioNotDownloaded)
                    return
                }
                let urls = try await downloads.localTrackURLs(for: record)
                let durations = try await Self.audioDurations(for: urls)
                let slices: [ChapterAudioSlice]
                do {
                    slices = try ChapterAudioSlicePlanner.slices(
                        for: chapter,
                        trackDurations: durations
                    )
                } catch {
                    state = .failed(.invalidChapterRange)
                    return
                }

                var transcript: [TranscriptSegment] = []
                let transcriber = SpeechChapterTranscriber()
                for (index, slice) in slices.enumerated() {
                    try Task.checkCancellation()
                    state = .transcribing(
                        completedSlices: index,
                        totalSlices: slices.count
                    )
                    let segments = try await transcriber.transcribe(
                        ChapterTranscriptionRequest(
                            audioFileURL: urls[slice.trackIndex],
                            locale: .current,
                            audioStartSeconds: slice.audioStartSeconds,
                            audioDurationSeconds: slice.durationSeconds,
                            chapterStartSeconds:
                                slice.wholeBookStartSeconds
                        )
                    )
                    transcript.append(contentsOf: segments)
                }
                let sortedTranscript = transcript.sorted {
                    ($0.startMilliseconds, $0.endMilliseconds)
                        < ($1.startMilliseconds, $1.endMilliseconds)
                }
                guard
                    let chapterStartMilliseconds = Self.milliseconds(
                        chapter.start
                    ),
                    let chapterEndMilliseconds = Self.milliseconds(
                        chapter.end
                    )
                else {
                    state = .failed(.invalidChapterRange)
                    return
                }
                state = .saving
                let cachedTranscript = CachedChapterTranscript(
                    chapterID: chapter.id,
                    chapterTitle: chapter.title,
                    chapterStartMilliseconds: chapterStartMilliseconds,
                    chapterEndMilliseconds: chapterEndMilliseconds,
                    localeIdentifier: Locale.current.identifier,
                    segments: sortedTranscript.map(
                        CachedTranscriptSegment.init(transcript:)
                    )
                )
                do {
                    try await appModel.saveCachedChapterTranscript(
                        cachedTranscript,
                        for: account,
                        itemID: detail.id
                    )
                    cachedTranscripts.removeAll {
                        $0.chapterID == chapter.id
                    }
                    cachedTranscripts.append(cachedTranscript)
                    cachedTranscripts.sort {
                        ($0.chapterStartMilliseconds, $0.chapterID)
                            < ($1.chapterStartMilliseconds, $1.chapterID)
                    }
                    cacheFailure = nil
                } catch is CancellationError {
                    state = .failed(.cancelled)
                    return
                } catch {
                    cacheFailure = .saveFailed
                }
                state = .complete(sortedTranscript)
            } catch is CancellationError {
                state = .failed(.cancelled)
            } catch let failure as ChapterTranscriptionFailure {
                state = .failed(.transcription(failure))
            } catch {
                state = .failed(.localAudioUnavailable)
            }
        }
    }

    func cancel() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }

    private static func audioDurations(
        for urls: [URL]
    ) async throws -> [Double] {
        try await Task.detached(priority: .utility) {
            try urls.map { url in
                let file = try AVAudioFile(forReading: url)
                let sampleRate = file.processingFormat.sampleRate
                guard sampleRate.isFinite, sampleRate > 0 else {
                    throw ChapterAudioSlicePlanFailure
                        .invalidTrackDurations
                }
                return Double(file.length) / sampleRate
            }
        }.value
    }

    private static func milliseconds(_ seconds: Double) -> Int64? {
        guard seconds.isFinite,
            seconds >= 0,
            seconds <= Double(Int64.max) / 1_000
        else {
            return nil
        }
        return Int64((seconds * 1_000).rounded())
    }
}

extension TranscriptSegment {
    fileprivate init(cached: CachedTranscriptSegment) {
        self.init(
            startMilliseconds: cached.startMilliseconds,
            endMilliseconds: cached.endMilliseconds,
            text: cached.text
        )
    }
}

extension CachedTranscriptSegment {
    fileprivate init(transcript: TranscriptSegment) {
        self.init(
            startMilliseconds: transcript.startMilliseconds,
            endMilliseconds: transcript.endMilliseconds,
            text: transcript.text
        )
    }
}

struct ChapterTranscriptionView: View {
    let detail: LibraryBookDetail
    let account: ServerAccount
    let appModel: AppModel
    @Bindable var downloads: DownloadModel
    @Bindable var playback: PlaybackModel
    @State private var model = ChapterTranscriptionModel()
    @State private var selectedChapterID: Int?
    @State private var searchQuery = ""
    @State private var showDownloadConfirmation = false
    @Environment(\.dismiss) private var dismiss

    init(
        detail: LibraryBookDetail,
        account: ServerAccount,
        appModel: AppModel,
        downloads: DownloadModel,
        playback: PlaybackModel
    ) {
        self.detail = detail
        self.account = account
        self.appModel = appModel
        self.downloads = downloads
        self.playback = playback
        _selectedChapterID = State(initialValue: detail.chapters.first?.id)
    }

    var body: some View {
        NavigationStack {
            List {
                if hasSearchQuery {
                    searchContent
                } else {
                    chapterSelector
                    cacheFailureContent
                    transcriptionContent
                }
            }
            .navigationTitle("Transcription")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchQuery,
                prompt: "Search Transcriptions"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        model.cancel()
                        dismiss()
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
        }
        .accessibilityIdentifier("transcription.view")
        .task(id: "\(account.id.rawValue):\(detail.id.rawValue)") {
            await model.loadCachedTranscripts(
                detail: detail,
                account: account,
                appModel: appModel,
                selectedChapterID: selectedChapterID
            )
        }
        .onChange(of: playback.isPlaybackRequested) { _, isPlaying in
            if isPlaying, model.isWorking {
                model.cancel()
            }
        }
    }

    @ViewBuilder
    private var chapterSelector: some View {
        Section("Chapter") {
            ForEach(detail.chapters, id: \.id) { chapter in
                Button {
                    selectedChapterID = chapter.id
                    model.showChapter(chapter.id)
                } label: {
                    HStack {
                        Text(chapter.title)
                            .foregroundStyle(.primary)
                        Spacer()
                        if model.isCached(chapterID: chapter.id) {
                            Image(systemName: "text.badge.checkmark")
                                .accessibilityLabel("Transcribed")
                        }
                        if selectedChapterID == chapter.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .accessibilityIdentifier(
                    "transcription.chapter.\(chapter.id)"
                )
            }
        }
    }

    @ViewBuilder
    private var cacheFailureContent: some View {
        if let failure = model.cacheFailure {
            Section {
                Label(
                    failure.message,
                    systemImage: "exclamationmark.triangle"
                )
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let matches = model.searchResults(query: searchQuery)
        Section("Search Results") {
            if matches.isEmpty {
                Text("No cached transcription matches this search.")
            } else {
                ForEach(Array(matches.enumerated()), id: \.offset) {
                    _, match in
                    Button {
                        selectedChapterID = match.chapterID
                        model.showChapter(match.chapterID)
                        searchQuery = ""
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(match.chapterTitle)
                                .font(.headline)
                            Text(timestamp(match.segment.startMilliseconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(match.segment.text)
                                .foregroundStyle(.primary)
                        }
                    }
                    .accessibilityIdentifier(
                        "transcription.searchResult.\(match.chapterID)"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var transcriptionContent: some View {
        switch model.state {
        case .ready:
            EmptyView()
        case .preparingAudio:
            Section {
                ProgressView("Preparing local audio")
            }
        case .transcribing(let completed, let total):
            Section {
                ProgressView(
                    value: Double(completed),
                    total: Double(max(total, 1))
                )
                Text("Transcribing audio \(completed + 1) of \(total)")
            }
        case .saving:
            Section {
                ProgressView("Saving transcription")
            }
        case .complete(let segments):
            Section("Transcript") {
                if segments.isEmpty {
                    Text("No speech was detected in this chapter.")
                } else {
                    ForEach(
                        Array(segments.enumerated()),
                        id: \.offset
                    ) { _, segment in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(timestamp(segment.startMilliseconds))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(segment.text)
                        }
                    }
                }
            }
        case .failed(let failure):
            Section {
                Label(
                    failure.message,
                    systemImage: "exclamationmark.triangle"
                )
                if failure == .audioNotDownloaded {
                    Button("Download Audiobook") {
                        showDownloadConfirmation = true
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if hasSearchQuery {
            EmptyView()
        } else if model.isWorking {
            Button("Cancel", role: .cancel) {
                model.cancel()
            }
            .buttonStyle(.borderedProminent)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        } else {
            Button(
                model.isCached(chapterID: selectedChapterID ?? Int.min)
                    ? "Transcribe Again"
                    : "Start Transcription",
                systemImage: "waveform.badge.mic"
            ) {
                guard let chapter = selectedChapter else {
                    return
                }
                model.start(
                    chapter: chapter,
                    detail: detail,
                    account: account,
                    downloads: downloads,
                    playback: playback,
                    appModel: appModel
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedChapter == nil)
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityIdentifier("transcription.start")
        }
    }

    private var selectedChapter: PlaybackChapter? {
        detail.chapters.first { $0.id == selectedChapterID }
    }

    private var hasSearchQuery: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
