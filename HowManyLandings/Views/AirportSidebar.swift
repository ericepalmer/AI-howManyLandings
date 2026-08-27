import SwiftUI

struct AirportSidebar: View {
    let airports: [Airport]
    let events: [StoredTrafficEvent]
    @Binding var selectedICAO: String?
    @Binding var selectedEventIDs: Set<UUID>
    var sessionStartedAt: Date
    var onRemove: (Airport) -> Void
    @Environment(TrackingEngine.self) private var engine

    private var selectedAirport: Airport? {
        airports.first { $0.icao == selectedICAO } ?? airports.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Build")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(AppBuild.number)
                    .font(.body.monospacedDigit().weight(.bold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .help("This running app’s build number. It increments every time you build.")

            GeometryReader { geo in
                VStack(spacing: 0) {
                    airportList
                        .frame(height: geo.size.height / 3)

                    Divider()

                    EventLogPanel(
                        airport: selectedAirport,
                        events: events,
                        sessionStartedAt: sessionStartedAt,
                        selectedEventIDs: $selectedEventIDs
                    )
                    .frame(height: geo.size.height * 2 / 3)
                }
            }
        }
        .navigationTitle("Landings")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Text(AppBuild.label)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("This running app’s build number. It increments every time you build.")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    engine.showingAddAirport = true
                } label: {
                    Label("Add Airport", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    engine.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 260)
        #endif
    }

    private var airportList: some View {
        List(selection: $selectedICAO) {
            Section("Tracked airports") {
                if airports.isEmpty {
                    Text("None yet. Tap + to add an airport by ICAO, FAA ID, or name.")
                        .foregroundStyle(.secondary)
                }
                ForEach(airports) { airport in
                    HStack(alignment: .center, spacing: 8) {
                        AirportRow(
                            airport: airport,
                            patternCount: engine.aircraftByAirport[airport.icao]?.filter(\.appearsInTracker).count ?? 0,
                            landingsLastHour: landings(airport.icao, since: engine.simulationNow.addingTimeInterval(-3600))
                        )
                        Button {
                            onRemove(airport)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .imageScale(.medium)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Stop tracking \(airport.icao)")
                        .accessibilityLabel("Stop tracking \(airport.icao)")
                    }
                    .tag(airport.icao)
                    .contextMenu {
                        Button("Stop tracking", role: .destructive) {
                            onRemove(airport)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button("Stop tracking", role: .destructive) {
                            onRemove(airport)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func landings(_ icao: String, since date: Date) -> Int {
        events.filter { $0.airportICAO == icao && $0.kind.countsAsLanding && $0.timestamp >= date }.count
    }
}

private struct AirportRow: View {
    let airport: Airport
    let patternCount: Int
    let landingsLastHour: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(airport.icao)
                    .font(.headline.monospaced())
                Spacer()
                if landingsLastHour > 0 {
                    Text("\(landingsLastHour)")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.2), in: Capsule())
                }
            }
            Text(airport.city.isEmpty ? airport.name : airport.city)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(airport.patternDirectionSummary)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(patternCount) in pattern")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
