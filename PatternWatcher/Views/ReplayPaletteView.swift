import SwiftUI

/// Inline replay transport controls in the pattern panel while a recording is loaded.
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack.fill.badge.play")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(engine.recordedReplayFileName ?? "Recording")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(progressLabel)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
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
                .help("Step back")

                Button {
                    engine.toggleRecordedReplayPlaying()
                } label: {
                    Image(systemName: playPauseSymbol)
                        .font(.body.weight(.semibold))
                        .frame(width: 32, height: 26)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(engine.isRecordedReplayPlaying ? "Pause" : "Play")

                transportButton(
                    "forward.frame.fill",
                    disabled: engine.recordedReplayFinished
                ) {
                    engine.stepRecordedReplayForward()
                }
                .help("Step forward")

                Spacer(minLength: 0)

                Picker("Speed", selection: $replaySpeed) {
                    ForEach(speeds, id: \.value) { speed in
                        Text(speed.label).tag(speed.value)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: replaySpeed) { _, newValue in
                    AppSettings.replaySpeedMultiplier = newValue
                }
            }

            Button("Stop replay", role: .destructive) {
                engine.stopRecordedReplay()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        }
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
                .font(.caption.weight(.semibold))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(disabled)
    }
}
