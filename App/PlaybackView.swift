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
                Button {
                    playback.togglePlayback()
                } label: {
                    Image(
                        systemName: playback.isPlaying
                            ? "pause.fill"
                            : "play.fill"
                    )
                    .font(.title2)
                }
                .accessibilityLabel(
                    playback.isPlaying ? "Pause" : "Play"
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
            VStack(spacing: 24) {
                Spacer()

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

                HStack(spacing: 40) {
                    Button {
                        Task {
                            await playback.skipBackward()
                        }
                    } label: {
                        Image(systemName: "gobackward.15")
                            .font(.largeTitle)
                    }
                    .disabled(playback.state == .preparing)

                    Button {
                        playback.togglePlayback()
                    } label: {
                        Image(
                            systemName: playback.isPlaying
                                ? "pause.circle.fill"
                                : "play.circle.fill"
                        )
                        .font(.system(size: 72))
                    }
                    .disabled(playback.state == .preparing)
                    .accessibilityLabel(
                        playback.isPlaying ? "Pause" : "Play"
                    )
                    .accessibilityIdentifier("player.toggle")

                    Button {
                        Task {
                            await playback.skipForward()
                        }
                    } label: {
                        Image(systemName: "goforward.30")
                            .font(.largeTitle)
                    }
                    .disabled(playback.state == .preparing)
                }

                HStack(spacing: 24) {
                    Menu {
                        ForEach(
                            [0.5, 0.75, 1, 1.25, 1.5, 2, 2.5, 3],
                            id: \.self
                        ) { speed in
                            Button(formatRate(speed)) {
                                playback.setRate(Float(speed))
                            }
                        }
                    } label: {
                        Text(formatRate(Double(playback.rate)))
                            .font(.headline)
                            .frame(minWidth: 72)
                    }
                    .accessibilityIdentifier("player.rate")

                    Menu {
                        ForEach([15, 30, 45, 60], id: \.self) {
                            minutes in
                            Button("\(minutes) minutes") {
                                playback.setSleepTimer(
                                    minutes: minutes
                                )
                            }
                        }
                        if playback.sleepTimerEnd != nil {
                            Button("Cancel Timer", role: .destructive) {
                                playback.setSleepTimer(minutes: nil)
                            }
                        }
                    } label: {
                        Label(
                            playback.sleepTimerEnd == nil
                                ? "Sleep Timer"
                                : "Timer Set",
                            systemImage: "moon.zzz"
                        )
                    }
                    .accessibilityIdentifier("player.sleepTimer")

                    Menu {
                        Button("Add at \(playbackTime(playback.currentTime))") {
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
                    } label: {
                        Label("Bookmarks", systemImage: "bookmark")
                    }
                    .disabled(
                        playback.bookmarkState == .loading
                            || playback.bookmarkState == .saving
                    )
                    .accessibilityIdentifier("player.bookmarks")
                }

                if case .failed(let failure) = playback.bookmarkState {
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("player.bookmarkError")
                }

                Spacer()
            }
            .padding()
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
