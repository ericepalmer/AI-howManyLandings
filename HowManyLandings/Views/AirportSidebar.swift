import SwiftUI

struct AirportSidebar: View {
    let airports: [Airport]
    let events: [StoredTrafficEvent]
    @Binding var selectedICAO: String?
    var onDelete: (IndexSet) -> Void
    @Environment(TrackingEngine.self) private var engine

    var body: some View {
        List(selection: $selectedICAO) {
            Section("Tracked airports") {
                if airports.isEmpty {
                    Text("None yet. Tap + to add an airport by ICAO, FAA ID, or name.")
                        .foregroundStyle(.secondary)
                }
                ForEach(airports) { airport in
                    AirportRow(
                        airport: airport,
                        aircraftCount: engine.aircraftByAirport[airport.icao]?.filter(\.inRange).count ?? 0,
                        landingsLastHour: landings(airport.icao, since: Date().addingTimeInterval(-3600))
                    )
                    .tag(airport.icao)
                    .contextMenu {
                        Button("Remove", role: .destructive) {
                            if let index = airports.firstIndex(of: airport) {
                                onDelete(IndexSet(integer: index))
                            }
                        }
                    }
                }
                .onDelete(perform: onDelete)
            }
        }
        .navigationTitle("Landings")
        .listStyle(.sidebar)
        .toolbar {
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
        .frame(minWidth: 240)
        #endif
    }

    private func landings(_ icao: String, since date: Date) -> Int {
        events.filter { $0.airportICAO == icao && $0.kind.countsAsLanding && $0.timestamp >= date }.count
    }
}

private struct AirportRow: View {
    let airport: Airport
    let aircraftCount: Int
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
            Text("\(aircraftCount) aircraft nearby")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
