import SwiftUI

/// Current METAR for the selected airport (Aviation Weather Center).
struct METARWindow: View {
    var station: String?

    @State private var observation: METARObservation?
    @State private var errorText: String?
    @State private var isLoading = true

    private var icao: String {
        (station ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    var body: some View {
        NavigationStack {
            Group {
                if icao.isEmpty {
                    ContentUnavailableView(
                        "No airport selected",
                        systemImage: "cloud.sun",
                        description: Text("Select an airport to load its METAR.")
                    )
                } else if let observation {
                    observationView(observation)
                } else if let errorText {
                    ContentUnavailableView(
                        "METAR unavailable",
                        systemImage: "cloud.slash",
                        description: Text(errorText)
                    )
                } else {
                    ProgressView("Loading METAR…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(icao.isEmpty ? "METAR" : "METAR · \(icao)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await load() }
                    } label: {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(icao.isEmpty || isLoading)
                }
            }
            .task(id: icao) {
                await load()
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
    }

    private func observationView(_ observation: METARObservation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(observation)
                decoded(observation)
                raw(observation)
                if let errorText {
                    Text(errorText)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ observation: METARObservation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(observation.station)
                    .font(.title2.weight(.semibold).monospaced())
                if let cat = observation.flightCategory, !cat.isEmpty {
                    Text(cat)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(flightCategoryColor(cat).opacity(0.22), in: Capsule())
                        .foregroundStyle(flightCategoryColor(cat))
                }
            }
            if let name = observation.name, !name.isEmpty {
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let observedAt = observation.observedAt {
                Text(observedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func decoded(_ observation: METARObservation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            metarRow("Wind", observation.wind)
            metarRow("Visibility", observation.visibility)
            metarRow("Weather", observation.weather)
            metarRow("Clouds", observation.clouds)
            metarRow("Temp / dew", observation.temperature)
            metarRow("Altimeter", observation.altimeter)
        }
    }

    private func raw(_ observation: METARObservation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Raw")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(observation.raw.isEmpty ? "—" : observation.raw)
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func metarRow(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)
            Text(value?.isEmpty == false ? value! : "—")
                .font(.body)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func flightCategoryColor(_ cat: String) -> Color {
        switch cat.uppercased() {
        case "VFR": return .green
        case "MVFR": return .blue
        case "IFR": return .red
        case "LIFR": return .purple
        default: return .secondary
        }
    }

    private func load() async {
        guard !icao.isEmpty else {
            isLoading = false
            observation = nil
            errorText = nil
            return
        }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            observation = try await METARClient.shared.fetch(station: icao)
        } catch {
            observation = nil
            errorText = error.localizedDescription
        }
    }
}
