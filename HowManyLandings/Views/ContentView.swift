import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(TrackingEngine.self) private var engine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \StoredAirport.addedAt) private var storedAirports: [StoredAirport]

    private var airports: [Airport] {
        storedAirports.map(\.asAirport)
    }

    var body: some View {
        @Bindable var engine = engine
        NavigationSplitView {
            AirportSidebar(
                airports: airports,
                selectedICAO: $engine.selectedICAO,
                onRemove: removeAirport
            )
        } detail: {
            if let airport = engine.selectedAirport(from: airports) {
                AirportDetailView(airport: airport)
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
            #if os(iOS)
                .presentationDetents([.medium, .large])
            #endif
        }
    }

    private func removeAirport(_ airport: Airport) {
        guard let stored = storedAirports.first(where: { $0.icao == airport.icao }) else { return }
        if engine.selectedICAO == airport.icao {
            engine.selectedICAO = storedAirports.first { $0.icao != airport.icao }?.icao
        }
        modelContext.delete(stored)
        try? modelContext.save()
    }
}

private struct AirportDetailView: View {
    let airport: Airport
    @Environment(TrackingEngine.self) private var engine
    @Environment(\.openWindow) private var openWindow
    @State private var trackDump: TrackDumpPayload?

    var body: some View {
        @Bindable var engine = engine
        let selectedICAO24s: Set<String> = {
            if let tracker = engine.selectedTrackerICAO24 {
                return [tracker]
            }
            return []
        }()

        HStack(spacing: 0) {
            AirportMapView(
                airport: airport,
                aircraft: engine.selectedAircraft,
                activeRunwayDirection: engine.selectedActiveRunway,
                highlightedTracks: [],
                selectedICAO24s: selectedICAO24s,
                selectedTrackerICAO24: engine.selectedTrackerICAO24,
                onSelectAircraft: { icao in
                    if engine.selectedTrackerICAO24 == icao {
                        engine.selectedTrackerICAO24 = nil
                    } else {
                        engine.selectedTrackerICAO24 = icao
                    }
                },
                onHoverAircraft: { icao in
                    engine.hoveredTrackerICAO24 = icao
                },
                externalTrackDump: $trackDump
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            PatternTrackerView(
                airport: airport,
                aircraft: engine.selectedAircraft,
                selectedICAO24: $engine.selectedTrackerICAO24,
                onDump: { ac in
                    trackDump = TrackDumpPayload(
                        id: UUID(),
                        title: ac.snapshot.displayLabel,
                        subtitle: "Pattern track",
                        airportICAO: airport.icao,
                        airportElevationFt: airport.elevationFt,
                        icao24: ac.id,
                        reportedKind: ac.flightState?.rawValue,
                        reportedTime: ac.lastSeen,
                        points: ac.track
                    )
                },
                onPlanePicked: {},
                onShowADS: { openWindow(id: "ads-feed") },
                onShowOccupancy: { openWindow(id: "pattern-occupancy") },
                onShowMETAR: { openWindow(id: "metar", value: airport.icao) }
            )
            .frame(width: 300)
        }
        .overlay {
            if !engine.hasLiveFeed(for: airport.icao), !engine.isRecordedReplayActive {
                ZStack {
                    Color.black.opacity(0.32)
                    ConnectionOverlay(airport: airport)
                }
                .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            if engine.isRecordedReplayActive {
                ReplayPaletteView()
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.28), value: engine.liveAirportICAOs.contains(airport.icao))
        .animation(.easeInOut(duration: 0.22), value: engine.isRecordedReplayActive)
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
        .onChange(of: airport.icao) { _, _ in
            engine.selectedTrackerICAO24 = nil
            engine.hoveredTrackerICAO24 = nil
        }
        .sheet(item: $trackDump) { dump in
            TrackDumpSheet(dump: dump)
        }
    }
}

private struct EmptyTrackingView: View {
    @Environment(TrackingEngine.self) private var engine

    var body: some View {
        ContentUnavailableView {
            Label("No airport selected", systemImage: "airplane.circle")
        } description: {
            Text("Add an airport by ICAO, FAA ID, or name to start tracking pattern traffic.")
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
        .modelContainer(for: [StoredAirport.self], inMemory: true)
}
