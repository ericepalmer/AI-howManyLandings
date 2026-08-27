import SwiftUI

/// Live dump of decoded ADS-B polls for the selected airport.
struct ADSFeedWindow: View {
    @Environment(TrackingEngine.self) private var engine
    @State private var showRecordingPicker = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if let poll = engine.adsLatestPoll, !poll.aircraft.isEmpty {
                    Table(poll.aircraft) {
                        TableColumn("ICAO24") { row in
                            Text(row.icao24).font(.caption.monospaced())
                        }
                        .width(ideal: 70)
                        TableColumn("Callsign") { row in
                            Text(row.callsign).font(.caption.monospaced())
                        }
                        .width(ideal: 80)
                        TableColumn("Type") { row in
                            Text(row.typeCode).font(.caption.monospaced())
                        }
                        .width(ideal: 56)
                        TableColumn("Gnd") { row in
                            Text(row.onGround ? "Y" : "N")
                                .font(.caption.monospaced().weight(.semibold))
                                .foregroundStyle(row.onGround ? TrackPalette.ground : Color.secondary)
                        }
                        .width(ideal: 36)
                        TableColumn("MSL") { row in
                            Text(intString(row.altitudeMSLFt)).font(.caption.monospaced())
                        }
                        .width(ideal: 50)
                        TableColumn("AGL") { row in
                            Text(intString(row.altitudeAGLFt)).font(.caption.monospaced())
                        }
                        .width(ideal: 50)
                        TableColumn("GS") { row in
                            Text(intString(row.groundSpeedKt)).font(.caption.monospaced())
                        }
                        .width(ideal: 40)
                        TableColumn("Hdg") { row in
                            Text(intString(row.trackDeg)).font(.caption.monospaced())
                        }
                        .width(ideal: 40)
                        TableColumn("VS") { row in
                            Text(intString(row.verticalRateFPM)).font(.caption.monospaced())
                        }
                        .width(ideal: 48)
                        TableColumn("NM") { row in
                            Text(String(format: "%.2f", row.distanceNM)).font(.caption.monospaced())
                        }
                        .width(ideal: 48)
                    }
                    .font(.caption)
                } else {
                    ContentUnavailableView(
                        "Waiting for ADS-B",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("The next poll for the selected airport will appear here as decoded from the live feed, including the on-ground flag.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()
                logSection
            }
            .navigationTitle("ADS-B Feed")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Clear") { engine.clearADSFeed() }
                        .disabled(engine.adsLatestPoll == nil && engine.adsLogLines.isEmpty)
                }
                ToolbarItem(placement: .automatic) {
                    Button("Load file…") {
                        #if os(macOS)
                        if let url = RecordedADSFilePicker.chooseFile() {
                            try? RecordedADSFilePicker.load(from: url, engine: engine)
                        }
                        #else
                        showRecordingPicker = true
                        #endif
                    }
                }
            }
            .modifier(RecordedADSFileImporter(isPresented: $showRecordingPicker, onError: { _ in }))
        }
        #if os(macOS)
        .frame(minWidth: 860, minHeight: 480)
        #endif
    }

    private var header: some View {
        let poll = engine.adsLatestPoll
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(poll.map { "\($0.sourceName) · \($0.airportICAO)" } ?? "No poll yet")
                    .font(.headline)
                if let poll {
                    Text("\(poll.aircraft.count) aircraft · \(poll.receivedAt.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if engine.isRecordedReplayActive {
                    Text("Replay · \(engine.recordedPollIndex)/\(engine.recordedPollCount) polls")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Decoded snapshots as they arrive, before pattern filtering.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Incoming log")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(engine.adsLogLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .frame(minHeight: 140, maxHeight: 220)
                .background(Color.primary.opacity(0.04))
                .onChange(of: engine.adsLogLines.count) { _, _ in
                    if let last = engine.adsLogLines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func intString(_ value: Double?) -> String {
        value.map { String(Int($0.rounded())) } ?? "—"
    }
}
