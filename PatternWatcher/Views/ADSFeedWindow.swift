import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Live dump of decoded ADS-B polls for one airport window.
struct ADSFeedWindow: View {
    let airportICAO: String
    @Environment(TrackingEngine.self) private var engine
    @State private var showRecordingPicker = false
    /// Empty = all aircraft. Otherwise match ICAO24 / callsign / registration.
    @State private var aircraftFilter = ""
    @State private var selectedRowIDs: Set<ADSFeedRow.ID> = []
    @State private var saveError: String?
    /// Bottom (log) pane height as a fraction of the resizable area below the header.
    @AppStorage(AppSettings.adsFeedLogFractionKey) private var logPaneFraction = 0.32
    @State private var dragStartLogFraction: Double?

    private let splitHandleHeight: CGFloat = 7
    private let minTablePaneHeight: CGFloat = 120
    private let minLogPaneHeight: CGFloat = 80

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                GeometryReader { geo in
                    let logHeight = paneHeight(
                        total: geo.size.height,
                        fraction: logPaneFraction,
                        minimum: minLogPaneHeight
                    )
                    let tableHeight = max(minTablePaneHeight, geo.size.height - splitHandleHeight - logHeight)

                    VStack(spacing: 0) {
                        aircraftTableSection
                            .frame(height: tableHeight)
                        splitDivider(totalHeight: geo.size.height)
                        logSection
                            .frame(height: logHeight)
                    }
                }
            }
            .navigationTitle("ADS-B · \(airportICAO)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Copy") { copySelectionOrVisible() }
                        .disabled(visibleRows.isEmpty && filteredLogText.isEmpty)
                    Button("Save") { saveTrack() }
                        .disabled(engine.adsSavedPolls(for: airportICAO).isEmpty)
                    Button("Clear") {
                        engine.clearADSFeed(for: airportICAO)
                        selectedRowIDs = []
                        saveError = nil
                    }
                    .disabled(
                        engine.adsSavedPolls(for: airportICAO).isEmpty
                            && engine.adsLatestPoll(for: airportICAO) == nil
                    )
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
        .onAppear { engine.setADSFeedWindowOpen(true, airportICAO: airportICAO) }
        .onDisappear { engine.setADSFeedWindowOpen(false, airportICAO: airportICAO) }
    }

    @ViewBuilder
    private var aircraftTableSection: some View {
        if let poll = engine.adsLatestPoll(for: airportICAO), !poll.aircraft.isEmpty {
            let rows = filteredAircraft(from: poll.aircraft)
            if rows.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "airplane",
                    description: Text("No aircraft match “\(aircraftFilter)”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $selectedRowIDs) {
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
                .onChange(of: aircraftFilter) { _, _ in
                    selectedRowIDs = []
                }
            }
        } else {
            ContentUnavailableView(
                "Waiting for ADS-B",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("The next poll for the selected airport will appear here as decoded from the live feed, including the on-ground flag.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func splitDivider(totalHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.06))
            .frame(height: splitHandleHeight)
            .overlay {
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 40, height: 3)
            }
            .contentShape(Rectangle())
            #if os(macOS)
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            #endif
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragStartLogFraction == nil {
                            dragStartLogFraction = logPaneFraction
                        }
                        guard let start = dragStartLogFraction, totalHeight > splitHandleHeight else { return }
                        let usable = totalHeight - splitHandleHeight
                        let delta = Double(value.translation.height / usable)
                        logPaneFraction = clampedLogFraction(start + delta)
                    }
                    .onEnded { _ in
                        dragStartLogFraction = nil
                    }
            )
            .accessibilityLabel("Resize panes")
            .accessibilityAddTraits(.isButton)
    }

    private func paneHeight(total: CGFloat, fraction: Double, minimum: CGFloat) -> CGFloat {
        let usable = max(0, total - splitHandleHeight)
        let maxLog = max(minimum, usable - minTablePaneHeight)
        let desired = usable * fraction
        return min(max(desired, minimum), maxLog)
    }

    private func clampedLogFraction(_ fraction: Double) -> Double {
        min(max(fraction, 0.12), 0.78)
    }

    private var visibleRows: [ADSFeedRow] {
        guard let poll = engine.adsLatestPoll(for: airportICAO) else { return [] }
        return filteredAircraft(from: poll.aircraft)
    }

    private var savedPollCount: Int {
        engine.adsSavedPolls(for: airportICAO).count
    }

    private var header: some View {
        let poll = engine.adsLatestPoll(for: airportICAO)
        let shown = visibleRows.count
        let total = poll?.aircraft.count ?? 0
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(poll.map { "\($0.sourceName) · \($0.airportICAO)" } ?? "No poll yet")
                    .font(.headline)
                if let poll {
                    Text("\(shown)\(shown == total ? "" : " of \(total)") aircraft · \(poll.receivedAt.formatted(date: .omitted, time: .standard)) · \(savedPollCount) saved polls")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if engine.isRecordedReplayActive {
                    Text("Replay · \(engine.recordedPollIndex)/\(engine.recordedPollCount) polls · \(savedPollCount) saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if savedPollCount > 0 {
                    Text("\(savedPollCount) saved polls")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Decoded snapshots as they arrive, before pattern filtering.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            TextField("Aircraft", text: $aircraftFilter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .help("Filter by ICAO24, callsign, or registration")

            if !aircraftFilter.isEmpty {
                Button {
                    aircraftFilter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear aircraft filter")
            }

            if !selectedRowIDs.isEmpty {
                Text("\(selectedRowIDs.count) sel")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let saveError {
                Text(saveError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var normalizedFilter: String {
        aircraftFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var filteredLogText: String {
        let needle = normalizedFilter
        let lines = engine.adsLogLines(for: airportICAO).filter { line in
            if needle.isEmpty { return true }
            return line.lowercased().contains(needle)
        }
        return lines.joined(separator: "\n")
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Incoming log")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(filteredLogText.isEmpty ? " " : filteredLogText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                        .id("log-body")
                }
                .frame(maxHeight: .infinity)
                .background(Color.primary.opacity(0.04))
                .onChange(of: engine.adsLogLines(for: airportICAO).count) { _, _ in
                    proxy.scrollTo("log-body", anchor: .bottom)
                }
            }
        }
    }

    private func filteredAircraft(from rows: [ADSFeedRow]) -> [ADSFeedRow] {
        let needle = normalizedFilter
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.matchesAircraftFilter(needle) }
    }

    private func saveTrack() {
        saveError = nil
        let icao = airportICAO
        #if os(macOS)
        guard let url = ADSSavePanel.saveTrack(
            defaultName: ADSSavedTrackExporter.defaultFileName(airportICAO: icao)
        ) else { return }
        do {
            try engine.saveADSTrack(to: url, airportICAO: icao, aircraftFilter: aircraftFilter)
        } catch {
            saveError = error.localizedDescription
        }
        #else
        saveError = "Save is available on macOS."
        #endif
    }

    private func copySelectionOrVisible() {
        if !selectedRowIDs.isEmpty {
            let rows = visibleRows.filter { selectedRowIDs.contains($0.id) }
            copyText(tsv(for: rows))
        } else if !visibleRows.isEmpty {
            copyText(tsv(for: visibleRows))
        } else {
            copyText(filteredLogText)
        }
    }

    private func tsv(for rows: [ADSFeedRow]) -> String {
        let header = "ICAO24\tCallsign\tType\tGnd\tMSL\tAGL\tGS\tHdg\tVS\tNM\tLat\tLon"
        let body = rows.map { row in
            [
                row.icao24,
                row.callsign,
                row.typeCode,
                row.onGround ? "Y" : "N",
                intString(row.altitudeMSLFt),
                intString(row.altitudeAGLFt),
                intString(row.groundSpeedKt),
                intString(row.trackDeg),
                intString(row.verticalRateFPM),
                String(format: "%.2f", row.distanceNM),
                String(format: "%.5f", row.latitude),
                String(format: "%.5f", row.longitude),
            ].joined(separator: "\t")
        }
        return ([header] + body).joined(separator: "\n")
    }

    private func copyText(_ text: String) {
        guard !text.isEmpty else { return }
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    private func intString(_ value: Double?) -> String {
        value.map { String(Int($0.rounded())) } ?? "—"
    }
}
