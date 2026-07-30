import AVKit
import BleatCore
import SwiftUI

struct MiniPlayerView: View {
    @Bindable var playback: PlaybackModel
    let showPlayer: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: showPlayer) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(playback.title)
                        .font(.headline)
                        .lineLimit(1)
                    if !playback.author.isEmpty {
                        Text(playback.author)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

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
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .accessibilityIdentifier("player.mini")
    }
}

struct PlayerView: View {
    @Bindable var playback: PlaybackModel
    @Environment(\.dismiss) private var dismiss
    @State private var scrubTime: Double = 0
    @State private var isScrubbing = false
    @State private var bookmarkDraft: BookmarkDraft?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    BookCoverView(
                        url: playback.coverURL,
                        cornerRadius: 16
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: 320)

                    VStack(spacing: 6) {
                        Text(playback.title)
                            .font(.title2.bold())
                            .multilineTextAlignment(.center)
                        if !playback.author.isEmpty {
                            Text(playback.author)
                                .foregroundStyle(.secondary)
                        }
                        if !playback.narrator.isEmpty {
                            Text("Narrated by \(playback.narrator)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if let chapter = playback.currentChapter {
                            Text(chapter.title)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                                .accessibilityIdentifier(
                                    "player.currentChapter"
                                )
                        }
                    }

                    VStack(spacing: 6) {
                        Slider(
                            value: $scrubTime,
                            in: 0...max(playback.duration, 1)
                        ) { editing in
                            isScrubbing = editing
                            guard !editing else {
                                return
                            }
                            Task {
                                await playback.seek(to: scrubTime)
                            }
                        }
                        .disabled(playback.state == .preparing)
                        .accessibilityIdentifier("player.position")

                        HStack {
                            Text(playbackTime(scrubTime))
                            Spacer()
                            Text(
                                "-"
                                    + playbackTime(
                                        max(playback.duration - scrubTime, 0)
                                    ))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }

                    if case .failed(let failure) = playback.state {
                        Text(failure.message)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("player.error")
                    }
                    if playback.syncState == .failed {
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

                    ScrollView(.horizontal) {
                        HStack(spacing: 24) {
                            Menu {
                                ForEach(
                                    PlaybackPreferencesStore.featuredRates,
                                    id: \.self
                                ) { speed in
                                    Button(formatRate(Double(speed))) {
                                        playback.setRate(speed)
                                    }
                                }
                                Divider()
                                Button("Slower by 0.05×") {
                                    playback.setRate(playback.rate - 0.05)
                                }
                                .disabled(playback.rate <= 0.5)
                                Button("Faster by 0.05×") {
                                    playback.setRate(playback.rate + 0.05)
                                }
                                .disabled(playback.rate >= 3)
                            } label: {
                                Text(formatRate(Double(playback.rate)))
                                    .font(.headline)
                                    .frame(minWidth: 72)
                            }
                            .accessibilityIdentifier("player.rate")

                            if !playback.chapters.isEmpty {
                                Menu {
                                    ForEach(playback.chapters, id: \.id) {
                                        chapter in
                                        Button {
                                            Task {
                                                await playback.seek(
                                                    to: chapter.start
                                                )
                                            }
                                        } label: {
                                            if chapter.id
                                                == playback.currentChapter?.id
                                            {
                                                Label(
                                                    chapter.title,
                                                    systemImage: "checkmark"
                                                )
                                            } else {
                                                Text(chapter.title)
                                            }
                                        }
                                    }
                                } label: {
                                    Label(
                                        "Chapters",
                                        systemImage: "list.bullet"
                                    )
                                }
                                .accessibilityIdentifier("player.chapters")
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

                            Menu {
                                ForEach(
                                    [5, 10, 15, 30, 45, 60, 90, 120],
                                    id: \.self
                                ) {
                                    minutes in
                                    Button("\(minutes) minutes") {
                                        playback.setSleepTimer(
                                            minutes: minutes
                                        )
                                    }
                                }
                                if playback.canSetEndOfChapterSleepTimer {
                                    Button("End of Chapter") {
                                        playback.setSleepTimerToEndOfChapter()
                                    }
                                }
                                if playback.sleepTimer != nil {
                                    Button(
                                        "Cancel Timer",
                                        role: .destructive
                                    ) {
                                        playback.setSleepTimer(minutes: nil)
                                    }
                                }
                            } label: {
                                Label(
                                    playback.sleepTimer == nil
                                        ? "Sleep Timer"
                                        : "Timer Set",
                                    systemImage: "moon.zzz"
                                )
                            }
                            .accessibilityIdentifier("player.sleepTimer")

                            Menu {
                                Button(
                                    "Add at \(playbackTime(playback.currentTime))"
                                ) {
                                    bookmarkDraft = BookmarkDraft(
                                        bookmark: nil,
                                        title: "Bookmark at "
                                            + playbackTime(playback.currentTime)
                                    )
                                }
                                if !playback.bookmarks.isEmpty {
                                    Divider()
                                }
                                ForEach(playback.bookmarks) { bookmark in
                                    Menu {
                                        Button("Rename") {
                                            bookmarkDraft = BookmarkDraft(
                                                bookmark: bookmark,
                                                title: bookmark.title
                                            )
                                        }
                                        Button("Delete", role: .destructive) {
                                            Task {
                                                await playback.deleteBookmark(
                                                    bookmark
                                                )
                                            }
                                        }
                                    } label: {
                                        Text(
                                            playbackTime(bookmark.time)
                                                + "  " + bookmark.title
                                        )
                                    }
                                }
                                if case .failed = playback.bookmarkState {
                                    Divider()
                                    Button("Retry Loading") {
                                        Task {
                                            await playback.loadBookmarks()
                                        }
                                    }
                                }
                                if !playback.pendingBookmarkMutations.isEmpty {
                                    Divider()
                                    Text(
                                        "\(playback.pendingBookmarkMutations.count) stored locally"
                                    )
                                    if playback.pendingBookmarkMutations
                                        .contains(
                                            where: { $0.status == .failed }
                                        ), playback.canSyncBookmarks
                                    {
                                        Button("Retry Pending Changes") {
                                            Task {
                                                await playback
                                                    .retryPendingBookmarks()
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Label("Bookmarks", systemImage: "bookmark")
                            }
                            .disabled(
                                playback.bookmarkState == .loading
                                    || playback.bookmarkState == .saving
                            )
                            .accessibilityIdentifier("player.bookmarks")

                            AirPlayRoutePicker()
                                .frame(width: 44, height: 44)
                                .accessibilityLabel("AirPlay")
                                .accessibilityIdentifier("player.airPlay")
                        }
                    }
                    .scrollIndicators(.hidden)

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
            .navigationTitle("Now Playing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop", role: .destructive) {
                        Task {
                            await playback.stop()
                            dismiss()
                        }
                    }
                }
            }
            .task {
                scrubTime = playback.currentTime
            }
            .onChange(of: playback.currentTime) { _, newValue in
                if !isScrubbing {
                    scrubTime = newValue
                }
            }
            .sheet(item: $bookmarkDraft) { draft in
                BookmarkEditorView(
                    playback: playback,
                    draft: draft
                )
            }
        }
        .accessibilityIdentifier("player.screen")
    }

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

    private func formatRate(_ value: Double) -> String {
        value.formatted(
            .number
                .precision(.fractionLength(value.rounded() == value ? 0 : 2))
        ) + "×"
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
