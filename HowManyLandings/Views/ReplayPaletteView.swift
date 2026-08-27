import SwiftUI

/// Floating transport controls shown while a recorded ADS-B file is loaded.
struct ReplayPaletteView: View {
    @Environment(TrackingEngine.self) private var engine
    @AppStorage(AppSettings.replaySpeedKey) private var replaySpeed = 1.0

    private let speeds: [(label: String, value: Double)] = [
        ("1×", 1.0),
        ("2×", 2.0),
        ("5×", 5.0),
        ("10×", 10.0),
        ("∞", 100.0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.fill.badge.play")
                    .foregroundStyle(.secondary)
                Text(engine.recordedReplayFileName ?? "Recording")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(progressLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                transportButton(
                    "backward.end.fill",
                    disabled: engine.recordedPollIndex == 0 && !engine.recordedReplayFinished
                ) {
                    engine.restartRecordedReplay(autoplay: false)
                }
                .help("Restart")

                transportButton(
                    "backward.frame.fill",
                    disabled: engine.recordedPollIndex <= 0
                ) {
                    engine.stepRecordedReplayBackward()
                }
                .help("Step back one poll")

                Button {
                    engine.toggleRecordedReplayPlaying()
                } label: {
                    Image(systemName: playPauseSymbol)
                        .font(.title2)
                        .frame(width: 36, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .help(engine.isRecordedReplayPlaying ? "Pause" : "Play")

                transportButton(
                    "forward.frame.fill",
                    disabled: engine.recordedReplayFinished
                ) {
                    engine.stepRecordedReplayForward()
                }
                .help("Step forward one poll")

                Spacer(minLength: 4)

                Picker("Speed", selection: $replaySpeed) {
                    ForEach(speeds, id: \.value) { speed in
                        Text(speed.label).tag(speed.value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 220)
                .onChange(of: replaySpeed) { _, newValue in
                    AppSettings.replaySpeedMultiplier = newValue
                }

                Button("Stop", role: .destructive) {
                    engine.stopRecordedReplay()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(minWidth: 420, maxWidth: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
    }

    private var progressLabel: String {
        if engine.recordedReplayFinished {
            return "Finished · \(engine.recordedPollIndex)/\(engine.recordedPollCount)"
        }
        let state = engine.isRecordedReplayPlaying ? "Playing" : "Paused"
        return "\(state) · \(engine.recordedPollIndex)/\(engine.recordedPollCount)"
    }

    private var playPauseSymbol: String {
        if engine.recordedReplayFinished {
            return "arrow.counterclockwise"
        }
        return engine.isRecordedReplayPlaying ? "pause.fill" : "play.fill"
    }

    private func transportButton(
        _ systemName: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body.weight(.semibold))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.bordered)
        .disabled(disabled)
    }
}
