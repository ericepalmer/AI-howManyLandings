import SwiftUI
import UniformTypeIdentifiers

struct RecordedADSControlsView: View {
    @Environment(TrackingEngine.self) private var engine
    @AppStorage(AppSettings.replaySpeedKey) private var replaySpeed = 1.0
    @State private var showFilePicker = false
    @State private var loadError: String?

    var body: some View {
        Button("Choose ADS-B file…") {
            showFilePicker = true
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.json, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try engine.loadRecordedFile(from: url)
                    loadError = nil
                } catch {
                    loadError = error.localizedDescription
                }
            case .failure(let error):
                loadError = error.localizedDescription
            }
        }

        if let loadError {
            Text(loadError)
                .font(.caption)
                .foregroundStyle(.red)
        }

        if engine.isRecordedReplayActive {
            LabeledContent("File", value: engine.recordedReplayFileName ?? "—")
            if let format = engine.recordedFormatDescription {
                LabeledContent("Format", value: format)
            }
            LabeledContent("Progress") {
                if engine.recordedReplayFinished {
                    Text("Finished · \(engine.recordedPollIndex)/\(engine.recordedPollCount)")
                } else {
                    Text("\(engine.recordedPollIndex)/\(engine.recordedPollCount) polls")
                }
            }
            Picker("Replay speed", selection: $replaySpeed) {
                Text("Real time").tag(1.0)
                Text("2×").tag(2.0)
                Text("5×").tag(5.0)
                Text("10×").tag(10.0)
                Text("Instant").tag(100.0)
            }
            .onChange(of: replaySpeed) { _, newValue in
                AppSettings.replaySpeedMultiplier = newValue
            }
            HStack {
                Button("Restart") {
                    engine.restartRecordedReplay()
                }
                Button("Stop replay", role: .destructive) {
                    engine.stopRecordedReplay()
                }
            }
        }
    }
}
