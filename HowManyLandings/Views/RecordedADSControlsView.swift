import SwiftUI

struct RecordedADSControlsView: View {
    @Environment(TrackingEngine.self) private var engine
    @State private var showFilePicker = false
    @State private var loadError: String?

    var body: some View {
        Button("Choose ADS-B file…") {
            #if os(macOS)
            loadError = nil
            guard let url = RecordedADSFilePicker.chooseFile() else { return }
            do {
                try RecordedADSFilePicker.load(from: url, engine: engine)
            } catch {
                loadError = error.localizedDescription
            }
            #else
            showFilePicker = true
            #endif
        }
        .modifier(RecordedADSFileImporter(isPresented: $showFilePicker, onError: { loadError = $0 }))

        if let loadError {
            Text(loadError)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        if engine.isRecordedReplayActive {
            LabeledContent("File", value: engine.recordedReplayFileName ?? "—")
            if let format = engine.recordedFormatDescription {
                LabeledContent("Format", value: format)
            }
            LabeledContent("Progress") {
                Text("\(engine.recordedPollIndex)/\(engine.recordedPollCount)")
            }
            Text("Use the floating replay palette on the map for play, speed, and stepping.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Stop replay", role: .destructive) {
                engine.stopRecordedReplay()
            }
        }
    }
}
