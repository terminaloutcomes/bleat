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

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "book.closed.fill")
                    .font(.system(size: 88))
                    .foregroundStyle(.secondary)

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
