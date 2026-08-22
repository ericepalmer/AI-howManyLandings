import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TrackingEngine.self) private var engine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredAirport.addedAt) private var storedAirports: [StoredAirport]
    @Query(sort: \StoredTrafficEvent.timestamp, order: .reverse) private var events: [StoredTrafficEvent]

    private var airports: [Airport] {
        storedAirports.map(\.asAirport)
    }

    var body: some View {
        @Bindable var engine = engine
        NavigationSplitView {
            AirportSidebar(
                airports: airports,
                events: events,
                selectedICAO: $engine.selectedICAO,
                onDelete: deleteAirports
            )
        } detail: {
            if let airport = engine.selectedAirport(from: airports) {
                AirportDetailView(airport: airport, events: events.filter { $0.airportICAO == airport.icao })
            } else {
                EmptyTrackingView()
            }
        }
        .onAppear {
            engine.attach(modelContext: modelContext)
            engine.start(airports: airports)
        }
        .onChange(of: storedAirports.map(\.icao)) { _, _ in
            engine.start(airports: airports)
        }
        .sheet(isPresented: $engine.showingAddAirport) {
            AddAirportSheet(existingICAOs: Set(airports.map(\.icao)))
        }
        .sheet(isPresented: $engine.showingSettings) {
            SettingsView()
                .presentationDetents([.medium, .large])
        }
    }

    private func deleteAirports(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(storedAirports[index])
        }
        try? modelContext.save()
    }
}

private struct AirportDetailView: View {
    let airport: Airport
    let events: [StoredTrafficEvent]
    @Environment(TrackingEngine.self) private var engine

    var body: some View {
        HStack(spacing: 0) {
            AirportMapView(airport: airport, aircraft: engine.selectedAircraft)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            StatsPanelView(
                airport: airport,
                events: events,
                sessionStartedAt: engine.sessionStartedAt ?? Date()
            )
            .frame(width: 320)
        }
        .navigationTitle(airport.icao)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    engine.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .status) {
                HStack(spacing: 8) {
                    if engine.lastError != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                    }
                    Text(engine.statusText)
                        .font(.caption)
                        .foregroundStyle(engine.lastError == nil ? Color.secondary : Color.red)
                    Button("Refresh", action: engine.refreshNow)
                }
            }
        }
    }
}

private struct EmptyTrackingView: View {
    @Environment(TrackingEngine.self) private var engine

    var body: some View {
        ContentUnavailableView {
            Label("No airport selected", systemImage: "airplane.circle")
        } description: {
            Text("Add an airport by ICAO, FAA ID, or name to start counting landings — including each touch-and-go in the pattern.")
        } actions: {
            Button {
                engine.showingAddAirport = true
            } label: {
                Label("Add Airport", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

#Preview {
    ContentView()
        .environment(TrackingEngine())
        .modelContainer(for: [StoredAirport.self, StoredTrafficEvent.self], inMemory: true)
}
