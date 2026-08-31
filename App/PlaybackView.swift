import AVKit
import BleatCore
import SwiftUI

struct PendingScrubberSeek: Equatable {
    let origin: Double
    let target: Double

    var distance: Double {
        abs(target - origin)
    }

    var isForward: Bool {
        target > origin
    }
}

// How long (in seconds) the user must scrub before we ask for confirmation
enum ScrubberSeekDecision: Equatable {
    static let confirmationThreshold: TimeInterval = 300

    case seekImmediately(Double)
    case confirm(PendingScrubberSeek)

    static func decide(origin: Double, target: Double) -> Self {
        let pending = PendingScrubberSeek(
            origin: origin,
            target: target
        )
        guard pending.distance >= confirmationThreshold else {
            return .seekImmediately(target)
        }
        return .confirm(pending)
    }
}

struct PlaybackScrubberChapterWindow: Equatable {
    let start: Double
    let end: Double

    var range: ClosedRange<Double> {
        start...end
    }

    static func select(
        chapter: PlaybackChapter?,
        duration: Double
    ) -> Self {
        let bookEnd = max(duration.isFinite ? duration : 0, 1)
        guard let chapter,
            chapter.start.isFinite,
            chapter.end.isFinite,
            chapter.start >= 0,
            chapter.end > chapter.start,
            chapter.start < bookEnd
        else {
            return Self(start: 0, end: bookEnd)
        }
        return Self(
            start: chapter.start,
            end: min(chapter.end, bookEnd)
        )
    }

    func elapsed(at wholeBookTime: Double) -> Double {
        min(max(wholeBookTime, start), end) - start
    }

    func remaining(at wholeBookTime: Double) -> Double {
        end - min(max(wholeBookTime, start), end)
    }
}

enum MiniPlayerSwipeDecision: Equatable {
    static let dismissalDistanceFraction: CGFloat = 0.05
    static let minimumDismissalDistance: CGFloat = 28
    static let flickPredictionDistanceFraction: CGFloat = 0.12

    case ignore
    case showPlayer
    case stopAndDismiss

    static func decide(
        translation: CGSize,
        predictedEndTranslation: CGSize,
        height: CGFloat
    ) -> Self {
        guard height > 0 else {
            return .ignore
        }
        let isVertical = abs(translation.height) > abs(translation.width)
        guard isVertical else {
            return .ignore
        }
        let action: Self =
            translation.height < 0
            ? .showPlayer
            : .stopAndDismiss
        let dismissalDistance = max(
            minimumDismissalDistance,
            height * dismissalDistanceFraction
        )
        if abs(translation.height) >= dismissalDistance {
            return action
        }
        let flickDistance = height * flickPredictionDistanceFraction
        if (translation.height < 0) == (predictedEndTranslation.height < 0),
            abs(predictedEndTranslation.height)
                > abs(predictedEndTranslation.width),
            abs(predictedEndTranslation.height) >= flickDistance
        {
            return action
        }
        return .ignore
    }
}

enum MiniPlayerContrast {
    static let backgroundOpacity = 0.85
    static let secondaryTextOpacity = 0.85
}

private struct PlaybackScrubberView: View {
    @Bindable var playback: PlaybackModel
    @State private var scrubTime: Double = 0
    @State private var isScrubbing = false
    @State private var scrubOriginTime: Double?
    @State private var pendingSeek: PendingScrubberSeek?

    @ColourSchemePreference private var colourScheme

    var body: some View {
        let chapterWindow = PlaybackScrubberChapterWindow.select(
            chapter: playback.currentChapter,
            duration: playback.duration
        )
        VStack(spacing: 6) {
            Slider(
                value: $scrubTime,
                in: chapterWindow.range
            ) { editing in
                isScrubbing = editing
                if editing {
                    scrubOriginTime = playback.currentTime
                } else {
                    finishScrubbing()
                }
            }
            .disabled(playback.state == .preparing)
            .accessibilityIdentifier("player.position")
            // .sliderThumbVisibility(Visibility.hidden)
            .sliderThumbVisibility(.hidden)
            .tint(colourScheme.color)

            HStack {
                Text(
                    playbackTime(
                        chapterWindow.elapsed(at: scrubTime)
                    )
                )
                Spacer()
                Text(
                    "-"
                        + playbackTime(
                            chapterWindow.remaining(at: scrubTime)
                        )
                )
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .task {
            scrubTime = playback.currentTime
        }
        .onChange(of: playback.currentTime) { _, newValue in
            if !isScrubbing {
                scrubTime = newValue
            }
        }
        .alert(
            "Confirm Position Change",
            isPresented: Binding(
                get: {
                    pendingSeek != nil
                },
                set: { isPresented in
                    if !isPresented {
                        pendingSeek = nil
                    }
                }
            ),
            presenting: pendingSeek
        ) { pending in
            Button("Jump") {
                Task {
                    await playback.seek(to: pending.target)
                }
            }
            .accessibilityIdentifier("player.scrub.confirm")
            Button("Cancel", role: .cancel) {
                scrubTime = playback.currentTime
            }
            .accessibilityIdentifier("player.scrub.cancel")
        } message: { pending in
            Text(confirmationMessage(for: pending))
        }
    }

    private func finishScrubbing() {
        let origin = scrubOriginTime ?? playback.currentTime
        scrubOriginTime = nil
        switch ScrubberSeekDecision.decide(
            origin: origin,
            target: scrubTime
        ) {
        case .seekImmediately(let target):
            Task {
                await playback.seek(to: target)
            }
        case .confirm(let pending):
            pendingSeek = pending
        }
    }

    private func confirmationMessage(
        for pending: PendingScrubberSeek
    ) -> String {
        "Jump \(pending.isForward ? "forward" : "backward") "
            + "by \(playbackTime(pending.distance)) "
            + "to \(playbackTime(pending.target))?"
    }

    private func playbackTime(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(
            format: "%d:%02d",
            minutes,
            remainingSeconds
        )
    }
}

struct MiniPlayerView: View {
    @Bindable var playback: PlaybackModel
    let containerHeight: CGFloat
    let showPlayer: () -> Void
    @State private var isDismissing = false

    var miniPlayerRoundingRadius: CGFloat = 8

    var body: some View {

        if !isDismissing {
            HStack(spacing: 12) {
                Button(action: showPlayer) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.title)
                            .font(.headline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if !playback.author.isEmpty {
                            Text(playback.author)
                                .font(.caption)
                                .foregroundStyle(
                                    .white.opacity(
                                        MiniPlayerContrast.secondaryTextOpacity
                                    )
                                )
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityValue(
                    playback.currentChapter?.title ?? "No current chapter"
                )
                .accessibilityIdentifier("player.mini.open")
                .simultaneousGesture(miniPlayerGesture)

                if playback.state == .preparing {
                    ProgressView()
                        .accessibilityIdentifier("player.preparing")
                } else {
                    if playback.state == .buffering {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Buffering")
                            .accessibilityIdentifier("player.buffering")
                    }
                    Button {
                        playback.togglePlayback()
                    } label: {
                        Image(
                            systemName: playback.isPlaybackRequested
                                ? "pause.fill"
                                : "play.fill"
                        )
                        .font(.title2)
                    }
                    .accessibilityLabel(
                        playback.isPlaybackRequested ? "Pause" : "Play"
                    )
                    .accessibilityIdentifier("player.mini.toggle")
                    .simultaneousGesture(miniPlayerGesture)
                    .tint(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Color.black.opacity(MiniPlayerContrast.backgroundOpacity),
                in: RoundedRectangle(
                    cornerRadius: miniPlayerRoundingRadius,
                    style: .continuous
                )
            )
            .shadow(
                color: .black.opacity(0.12),
                radius: miniPlayerRoundingRadius,
                y: 2
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .highPriorityGesture(miniPlayerGesture)
            .accessibilityElement(children: .contain)
            .accessibilityAction(named: "Stop and Dismiss Playback") {
                stopAndDismiss()
            }
            .accessibilityIdentifier("player.mini")
        }
    }

    private var miniPlayerGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onEnded { value in
                switch MiniPlayerSwipeDecision.decide(
                    translation: value.translation,
                    predictedEndTranslation: value.predictedEndTranslation,
                    height: containerHeight
                ) {
                case .ignore:
                    break
                case .showPlayer:
                    showPlayer()
                case .stopAndDismiss:
                    stopAndDismiss()
                }
            }
    }

    private func stopAndDismiss() {
        guard !isDismissing else {
            return
        }
        withAnimation(.easeOut(duration: 0.2)) {
            isDismissing = true
        }
        Task {
            await playback.stop()
            guard playback.hasActiveBook else {
                return
            }
            withAnimation(.easeIn(duration: 0.2)) {
                isDismissing = false
            }
        }
    }
}

struct NowPlaying: View {
    @Bindable var playback: PlaybackModel
    @Environment(\.dismiss) private var dismiss
    @State private var bookmarkDraft: BookmarkDraft?

    @ColourSchemePreference private var colourScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    BookCoverView(
                        accountID: playback.accountID,
                        url: playback.coverURL,
                        cornerRadius: 16,
                        loadPolicy: playback.coverLoadPolicy
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 300)

                    VStack(spacing: 4) {
                        Text(playback.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        // if !playback.author.isEmpty {
                        //     Text(playback.author)
                        //         .foregroundStyle(.secondary)
                        // }
                        // if !playback.narrator.isEmpty {
                        //     Text("Narrated by \(playback.narrator)")
                        //         .font(.subheadline)
                        //         .foregroundStyle(.secondary)
                        // }
                        if let chapter = playback.currentChapter {
                            Text(chapter.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .accessibilityIdentifier(
                                    "player.currentChapter"
                                )
                        }
                    }

                    PlaybackScrubberView(playback: playback)

                    if case .failed(let failure) = playback.state {
                        Text(failure.message)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("player.error")
                    }
                    if playback.syncState == .failed {
                        // TODO have a button to force-sync the position, and show a progress indicator while syncing
                        Label(
                            "Position has not synced",
                            systemImage: "icloud.slash"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("player.syncError")
                    }
                    if let conflict = playback.positionConflict {
                        VStack(spacing: 10) {
                            // TODO have a button to force-sync the position or overwrite
                            Text("Playback position changed in two places.")
                                .font(.headline)
                            HStack {
                                Button(
                                    "This device (\(playbackTime(conflict.localTime)))"
                                ) {
                                    Task {
                                        await playback.resolvePositionConflict(
                                            useLocalPosition: true
                                        )
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                Button(
                                    "Server (\(playbackTime(conflict.serverTime)))"
                                ) {
                                    Task {
                                        await playback.resolvePositionConflict(
                                            useLocalPosition: false
                                        )
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .accessibilityIdentifier("player.positionConflict")
                    }

                    HStack(spacing: 22) {
                        Button {
                            Task {
                                await playback.previousChapter()
                            }
                        } label: {
                            Image(systemName: "backward.end.fill")
                                .font(.title2)
                        }
                        .disabled(
                            playback.state == .preparing
                                || !playback.canMoveToPreviousChapter
                        )
                        .accessibilityLabel("Previous Chapter")
                        .accessibilityIdentifier("player.previousChapter")

                        Button {
                            Task {
                                await playback.skipBackward()
                            }
                        } label: {
                            Image(
                                systemName:
                                    "gobackward.\(playback.skipBackwardInterval.rawValue)"
                            )
                            .font(.title)
                        }
                        .disabled(playback.state == .preparing)
                        .accessibilityLabel(
                            "Back \(playback.skipBackwardInterval.rawValue) seconds"
                        )
                        .accessibilityIdentifier("player.skipBackward")

                        Button {
                            playback.togglePlayback()
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                Image(
                                    systemName:
                                        playback.isPlaybackRequested
                                        ? "pause.circle.fill"
                                        : "play.circle.fill"
                                )
                                .font(.system(size: 64))
                                if playback.state == .buffering {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel("Buffering")
                                        .accessibilityIdentifier(
                                            "player.full.buffering"
                                        )
                                }
                            }
                        }
                        .disabled(playback.state == .preparing)
                        .accessibilityLabel(
                            playback.isPlaybackRequested ? "Pause" : "Play"
                        )
                        .accessibilityIdentifier("player.toggle")

                        Button {
                            Task {
                                await playback.skipForward()
                            }
                        } label: {
                            Image(
                                systemName:
                                    "goforward.\(playback.skipForwardInterval.rawValue)"
                            )
                            .font(.title)
                        }
                        .disabled(playback.state == .preparing)
                        .accessibilityLabel(
                            "Forward \(playback.skipForwardInterval.rawValue) seconds"
                        )
                        .accessibilityIdentifier("player.skipForward")

                        Button {
                            Task {
                                await playback.nextChapter()
                            }
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.title2)
                        }
                        .disabled(
                            playback.state == .preparing
                                || !playback.canMoveToNextChapter
                        )
                        .accessibilityLabel("Next Chapter")
                        .accessibilityIdentifier("player.nextChapter")
                    }

                    HStack(spacing: 24) {
                        PlaybackRateMenu(
                            sourceID: ObjectIdentifier(playback),
                            rate: playback.rate
                        ) { rate in
                            playback.setRate(rate)
                        }
                        .equatable()

                        if !playback.chapters.isEmpty {
                            PlaybackChaptersPicker(
                                sourceID: ObjectIdentifier(playback),
                                chapters: playback.chapters,
                                currentChapterIndex:
                                    playback.currentChapterIndex
                            ) { time in
                                Task {
                                    await playback.seek(to: time)
                                }
                            }
                            .equatable()
                        }

                        if playback.audioFiles.count > 1 {
                            Menu {
                                ForEach(
                                    Array(
                                        playback.audioFiles.enumerated()
                                    ),
                                    id: \.offset
                                ) { index, file in
                                    Button {
                                        Task {
                                            await playback
                                                .seekToAudioFile(at: index)
                                        }
                                    } label: {
                                        if index
                                            == playback
                                            .currentAudioFileIndex
                                        {
                                            Label(
                                                audioFileLabel(
                                                    file,
                                                    index: index
                                                ),
                                                systemImage: "checkmark"
                                            )
                                        } else {
                                            Text(
                                                audioFileLabel(
                                                    file,
                                                    index: index
                                                )
                                            )
                                        }
                                    }
                                    .accessibilityIdentifier(
                                        "player.audioFile.\(index)"
                                    )
                                }
                            } label: {
                                Label(
                                    "Audio Files",
                                    systemImage: "waveform"
                                )
                            }
                            .accessibilityIdentifier("player.audioFiles")
                        }

                        PlaybackSleepTimerMenu(
                            sourceID: ObjectIdentifier(playback),
                            hasTimer: playback.sleepTimer != nil,
                            canSetEndOfChapter:
                                playback.canSetEndOfChapterSleepTimer,
                            onSetDuration: { minutes in
                                playback.setSleepTimer(minutes: minutes)
                            },
                            onSetEndOfChapter: {
                                playback.setSleepTimerToEndOfChapter()
                            }
                        )
                        .equatable()

                        PlaybackBookmarksMenu(
                            sourceID: ObjectIdentifier(playback),
                            bookmarks: playback.bookmarks,
                            state: playback.bookmarkState,
                            pendingMutations:
                                playback.pendingBookmarkMutations,
                            canSync: playback.canSyncBookmarks,
                            onAdd: {
                                let time = playback.currentTime
                                bookmarkDraft = BookmarkDraft(
                                    bookmark: nil,
                                    title: "Bookmark at " + playbackTime(time)
                                )
                            },
                            onRename: { bookmark in
                                bookmarkDraft = BookmarkDraft(
                                    bookmark: bookmark,
                                    title: bookmark.title
                                )
                            },
                            onDelete: { bookmark in
                                Task {
                                    await playback.deleteBookmark(bookmark)
                                }
                            },
                            onRetryLoading: {
                                Task {
                                    await playback.loadBookmarks()
                                }
                            },
                            onRetryPending: {
                                Task {
                                    await playback.retryPendingBookmarks()
                                }
                            },
                            formatTime: playbackTime
                        )
                        .equatable()

                        #if os(iOS)
                            AirPlayRoutePicker()
                                .frame(width: 44, height: 44)
                                .accessibilityLabel("AirPlay")
                                .accessibilityIdentifier("player.airPlay")
                                .tint(colourScheme.color)
                        #endif
                    }

                    if case .failed(let failure) = playback.bookmarkState {
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("player.bookmarkError")
                    }
                    if !playback.pendingBookmarkMutations.isEmpty {
                        let failedCount =
                            playback.pendingBookmarkMutations.filter {
                                $0.status == .failed
                            }.count
                        Text(
                            failedCount == 0
                                ? "Bookmark changes are stored on this device."
                                : "\(failedCount) bookmark change \(failedCount == 1 ? "has" : "have") not synced."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("player.bookmarkPending")
                    }

                }
                .padding()
            }
            .accessibilityIdentifier("player.scroll")
            .toolbar {
                playerToolbar
            }
            .sheet(item: $bookmarkDraft) { draft in
                BookmarkEditorView(
                    playback: playback,
                    draft: draft
                )
            }
        }
        .accessibilityIdentifier("player.screen").tint(colourScheme.color)
    }

    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .accessibilityLabel("Close")
        }
    }

    #if os(iOS)
        private struct AirPlayRoutePicker: UIViewRepresentable {
            func makeUIView(context: Context) -> AVRoutePickerView {
                let picker = AVRoutePickerView()
                picker.prioritizesVideoDevices = false
                return picker
            }

            func updateUIView(
                _ picker: AVRoutePickerView,
                context: Context
            ) {}
        }
    #endif

    private func playbackTime(_ value: Double) -> String {
        let seconds = max(0, Int(value))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(
                format: "%d:%02d:%02d",
                hours,
                minutes,
                remainingSeconds
            )
        }
        return String(
            format: "%d:%02d",
            minutes,
            remainingSeconds
        )
    }

    private func audioFileLabel(
        _ file: AppPlaybackTrack,
        index: Int
    ) -> String {
        let title = file.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let displayTitle = title.isEmpty ? "File \(index + 1)" : title
        return "\(displayTitle) · \(playbackTime(file.duration))"
    }
}

private struct PlaybackChaptersPicker: View, @MainActor Equatable {
    let sourceID: ObjectIdentifier
    let chapters: [PlaybackChapter]
    let currentChapterIndex: Int?
    let onSelect: (Double) -> Void
    @State private var isPresented = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceID == rhs.sourceID
            && lhs.chapters == rhs.chapters
            && lhs.currentChapterIndex == rhs.currentChapterIndex
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "list.bullet")
        }
        .accessibilityLabel("Chapters")
        .accessibilityIdentifier("player.chapters")
        .sheet(isPresented: $isPresented) {
            PlaybackChapterPickerSheet(
                chapters: chapters,
                currentChapterIndex: currentChapterIndex
            ) { time in
                isPresented = false
                onSelect(time)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct PlaybackChapterPickerSheet: View {
    let chapters: [PlaybackChapter]
    let currentChapterIndex: Int?
    let onSelect: (Double) -> Void
    @State private var scrollPosition: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(
                        Array(chapters.enumerated()),
                        id: \.offset
                    ) { index, chapter in
                        Button {
                            onSelect(chapter.start)
                        } label: {
                            HStack {
                                Text(chapter.title)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                if index == currentChapterIndex {
                                    Image(systemName: "checkmark")
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .padding(.horizontal)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("player.chapter.\(index)")
                        .accessibilityAddTraits(
                            index == currentChapterIndex
                                ? .isSelected : []
                        )

                        if index < chapters.count - 1 {
                            Divider()
                                .padding(.leading)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollPosition, anchor: .center)
            .navigationTitle("Chapters")
            .iOSInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                scrollPosition = currentChapterIndex
            }
            .onChange(of: currentChapterIndex) { _, newIndex in
                scrollPosition = newIndex
            }
        }
        .accessibilityIdentifier("player.chapterPicker")
    }
}

private struct PlaybackSleepTimerMenu: View, @MainActor Equatable {
    let sourceID: ObjectIdentifier
    let hasTimer: Bool
    let canSetEndOfChapter: Bool
    let onSetDuration: (Int?) -> Void
    let onSetEndOfChapter: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceID == rhs.sourceID
            && lhs.hasTimer == rhs.hasTimer
            && lhs.canSetEndOfChapter == rhs.canSetEndOfChapter
    }

    var body: some View {
        Menu {
            ForEach([5, 10, 15, 30, 45, 60, 90, 120], id: \.self) {
                minutes in
                Button("\(minutes) minutes") {
                    onSetDuration(minutes)
                }
            }
            if canSetEndOfChapter {
                Button("End of Chapter") {
                    onSetEndOfChapter()
                }
            }
            if hasTimer {
                Button("Cancel Timer", role: .destructive) {
                    onSetDuration(nil)
                }
            }
        } label: {
            Image(systemName: hasTimer ? "moon.zzz.fill" : "moon.zzz")
        }
        .accessibilityLabel(hasTimer ? "Timer Set" : "Sleep Timer")
        .accessibilityIdentifier("player.sleepTimer")
    }
}

private struct PlaybackBookmarksMenu: View, @MainActor Equatable {
    let sourceID: ObjectIdentifier
    let bookmarks: [AudioBookmark]
    let state: BookmarkState
    let pendingMutations: [QueuedBookmarkMutation]
    let canSync: Bool
    let onAdd: () -> Void
    let onRename: (AudioBookmark) -> Void
    let onDelete: (AudioBookmark) -> Void
    let onRetryLoading: () -> Void
    let onRetryPending: () -> Void
    let formatTime: (Double) -> String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceID == rhs.sourceID
            && lhs.bookmarks == rhs.bookmarks
            && lhs.state == rhs.state
            && lhs.pendingMutations == rhs.pendingMutations
            && lhs.canSync == rhs.canSync
    }

    var body: some View {
        Menu {
            Button("Add Bookmark") {
                onAdd()
            }
            if !bookmarks.isEmpty {
                Divider()
            }
            ForEach(bookmarks) { bookmark in
                Menu {
                    Button("Rename") {
                        onRename(bookmark)
                    }
                    Button("Delete", role: .destructive) {
                        onDelete(bookmark)
                    }
                } label: {
                    Text(formatTime(bookmark.time) + "  " + bookmark.title)
                }
            }
            if case .failed = state {
                Divider()
                Button("Retry Loading") {
                    onRetryLoading()
                }
            }
            if !pendingMutations.isEmpty {
                Divider()
                Text("\(pendingMutations.count) stored locally")
                if pendingMutations.contains(
                    where: { $0.status == .failed }
                ), canSync {
                    Button("Retry Pending Changes") {
                        onRetryPending()
                    }
                }
            }
        } label: {
            Image(systemName: "bookmark")
        }
        .accessibilityLabel("Bookmarks")
        .disabled(state == .loading || state == .saving)
        .accessibilityIdentifier("player.bookmarks")
    }
}

private struct PlaybackRateMenu: View, @MainActor Equatable {
    let sourceID: ObjectIdentifier
    let rate: Float
    let onSetRate: (Float) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceID == rhs.sourceID && lhs.rate == rhs.rate
    }

    var body: some View {
        Menu {
            ForEach(
                PlaybackPreferencesStore.featuredRates,
                id: \.self
            ) { speed in
                Button(formatRate(speed)) {
                    onSetRate(speed)
                }
            }
            Divider()
            Button("Slower by 0.05×") {
                onSetRate(rate - 0.05)
            }
            .disabled(rate <= 0.5)
            Button("Faster by 0.05×") {
                onSetRate(rate + 0.05)
            }
            .disabled(rate >= 3)
        } label: {
            Text(formatRate(rate))
                .font(.headline)
                .frame(minWidth: 72)
        }
        .accessibilityIdentifier("player.rate")
    }

    private func formatRate(_ value: Float) -> String {
        Double(value).formatted(
            .number
                .precision(
                    .fractionLength(
                        value.rounded() == value ? 0 : 2
                    )
                )
        ) + "×"
    }
}

private struct BookmarkDraft: Identifiable {
    let id = UUID()
    let bookmark: AudioBookmark?
    let title: String
}

private struct BookmarkEditorView: View {
    @Bindable var playback: PlaybackModel
    @Environment(\.dismiss) private var dismiss
    let bookmark: AudioBookmark?
    @State private var title: String

    init(
        playback: PlaybackModel,
        draft: BookmarkDraft
    ) {
        self.playback = playback
        bookmark = draft.bookmark
        _title = State(initialValue: draft.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .accessibilityIdentifier("bookmark.title")
                if let bookmark {
                    LabeledContent(
                        "Position",
                        value: bookmark.time.formatted(
                            .number.precision(.fractionLength(0...1))
                        ) + " seconds"
                    )
                }
            }
            .navigationTitle(bookmark == nil ? "New Bookmark" : "Rename")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let saved: Bool
                            if let bookmark {
                                saved = await playback.renameBookmark(
                                    bookmark,
                                    title: title
                                )
                            } else {
                                saved = await playback.createBookmark(
                                    title: title
                                )
                            }
                            if saved {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        title.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty || playback.bookmarkState == .saving
                    )
                    .accessibilityIdentifier("bookmark.save")
                }
            }
        }
    }
}
