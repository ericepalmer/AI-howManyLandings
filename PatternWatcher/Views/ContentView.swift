import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Launches airport windows on startup or shows welcome when no airports are stored.
struct BootstrapView: View {
    @Environment(TrackingEngine.self) private var engine
    @Environment(OpenAirportCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Query(sort: \StoredAirport.addedAt) private var storedAirports: [StoredAirport]
    @State private var didRestoreWindows = false

    var body: some View {
        Group {
            if AppSettings.openAirportICAOs.isEmpty {
                WelcomeView()
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
                    .onAppear { restoreAirportWindowsIfNeeded() }
            }
        }
        .onAppear {
            engine.attach(modelContext: modelContext)
            #if os(macOS)
            AppDelegate.coordinator = coordinator
            AppDelegate.engine = engine
            #endif
        }
        .background(WindowMenuBridge())
        .sheet(isPresented: bindShowingNewAirportPicker) {
            AddAirportSheet(
                openICAOs: Set(coordinator.openICAOs),
                onOpen: openAirport
            )
        }
    }

    private var bindShowingNewAirportPicker: Binding<Bool> {
        Binding(
            get: { coordinator.showingNewAirportPicker },
            set: { coordinator.showingNewAirportPicker = $0 }
        )
    }

    private func restoreAirportWindowsIfNeeded() {
        guard !didRestoreWindows else { return }
        didRestoreWindows = true
        let toOpen = AppSettings.openAirportICAOs
        guard !toOpen.isEmpty else { return }
        for icao in toOpen {
            coordinator.registerOpen(icao)
            openWindow(id: "airport", value: icao)
        }
        syncTrackedAirports()
        dismissWindow(id: "bootstrap")
    }

    private func openAirport(_ airport: Airport) {
        coordinator.registerOpen(airport.icao)
        syncTrackedAirports()
        openWindow(id: "airport", value: airport.icao)
        dismissWindow(id: "bootstrap")
    }

    private func syncTrackedAirports() {
        let airports = coordinator.openICAOs.compactMap { icao in
            airportForICAO(icao)
        }
        engine.updateTrackedAirports(airports)
    }

    private func airportForICAO(_ icao: String) -> Airport? {
        storedAirports.first(where: { $0.icao == icao })?.asAirport
            ?? AirportCatalog.shared.airport(code: icao)
    }
}

private struct WelcomeView: View {
    @Environment(OpenAirportCoordinator.self) private var coordinator

    var body: some View {
        ContentUnavailableView {
            Label(AppIdentity.name, systemImage: "airplane.circle")
        }         description: {
            Text("Open an airport with File → New Airport. Only airports left open when you quit are restored next launch.")
        } actions: {
            Button("New Airport") {
                coordinator.requestNewAirport()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AirportWindowView: View {
    let icao: String

    @Environment(TrackingEngine.self) private var engine
    @Environment(OpenAirportCoordinator.self) private var coordinator
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Query(sort: \StoredAirport.addedAt) private var storedAirports: [StoredAirport]

    private var airport: Airport? {
        storedAirports.first(where: { $0.icao == icao })?.asAirport
            ?? AirportCatalog.shared.airport(code: icao)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let airport {
                    AirportDetailView(airport: airport)
                } else {
                    ContentUnavailableView(
                        "Airport not found",
                        systemImage: "airplane.circle",
                        description: Text("No data for \(icao). Close this window and open the airport again.")
                    )
                }
            }
            .navigationTitle(windowTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .focusedValue(\.airportWindowICAO, icao)
        #if os(macOS)
        .background(WindowMenuBridge())
        .background(AirportWindowCloseTracker(icao: icao, coordinator: coordinator))
        #endif
        .onAppear {
            engine.attach(modelContext: modelContext)
            AppDelegate.coordinator = coordinator
            AppDelegate.engine = engine
            coordinator.setSaveLogTarget(icao)
            coordinator.registerOpen(icao)
            syncTrackedAirports()
        }
        .onDisappear {
            #if os(macOS)
            guard !AppDelegate.isTerminating else { return }
            #endif
            coordinator.unregisterOpen(icao)
            coordinator.dismissAllSupplementary(for: icao, dismissWindow: dismissWindow)
            syncTrackedAirports()
        }
        .sheet(isPresented: bindShowingSettings) {
            SettingsView()
            #if os(iOS)
                .presentationDetents([.medium, .large])
            #endif
        }
        .sheet(isPresented: bindShowingNewAirportPicker) {
            AddAirportSheet(
                openICAOs: Set(coordinator.openICAOs),
                onOpen: openAnotherAirport
            )
        }
    }

    private var windowTitle: String {
        if let airport {
            return "\(airport.icao) — \(airport.displayName)"
        }
        return icao
    }

    private var bindShowingSettings: Binding<Bool> {
        Binding(
            get: { engine.showingSettings },
            set: { engine.showingSettings = $0 }
        )
    }

    private var bindShowingNewAirportPicker: Binding<Bool> {
        Binding(
            get: { coordinator.showingNewAirportPicker },
            set: { coordinator.showingNewAirportPicker = $0 }
        )
    }

    private func syncTrackedAirports() {
        let airports = coordinator.openICAOs.compactMap { openICAO in
            storedAirports.first(where: { $0.icao == openICAO })?.asAirport
                ?? AirportCatalog.shared.airport(code: openICAO)
        }
        engine.updateTrackedAirports(airports)
    }

    private func openAnotherAirport(_ airport: Airport) {
        coordinator.registerOpen(airport.icao)
        syncTrackedAirports()
        openWindow(id: "airport", value: airport.icao)
    }
}

private struct AirportDetailView: View {
    let airport: Airport
    @Environment(TrackingEngine.self) private var engine
    @Environment(OpenAirportCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var trackDump: TrackDumpPayload?
    @State private var showRightPanel = true

    var body: some View {
        @Bindable var engine = engine
        let icao = airport.icao
        let selectedTracker = engine.selectedTrackerICAO24(for: icao)
        let selectedICAO24s: Set<String> = selectedTracker.map { [$0] } ?? []

        HStack(spacing: 0) {
            AirportMapView(
                airport: airport,
                aircraft: engine.aircraft(for: icao),
                activeRunwayDirection: engine.activeRunway(for: icao),
                highlightedTracks: [],
                selectedICAO24s: selectedICAO24s,
                selectedTrackerICAO24: selectedTracker,
                onSelectAircraft: { aircraftICAO24 in
                    if engine.selectedTrackerICAO24(for: icao) == aircraftICAO24 {
                        engine.setSelectedTrackerICAO24(nil, airportICAO: icao)
                    } else {
                        engine.setSelectedTrackerICAO24(aircraftICAO24, airportICAO: icao)
                    }
                },
                onHoverAircraft: { aircraftICAO24 in
                    engine.setHoveredTrackerICAO24(aircraftICAO24, airportICAO: icao)
                },
                externalTrackDump: $trackDump
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showRightPanel {
                Divider()

                PatternTrackerView(
                    airport: airport,
                    aircraft: engine.aircraft(for: icao),
                    selectedICAO24: selectedTrackerBinding,
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
                    onShowOccupancy: {
                        coordinator.setSupplementaryOpen(
                            true,
                            icao: icao,
                            kind: .patternGraph,
                            openWindow: openWindow,
                            dismissWindow: dismissWindow
                        )
                    },
                    onShowStats: {
                        coordinator.setSupplementaryOpen(
                            true,
                            icao: icao,
                            kind: .stats,
                            openWindow: openWindow,
                            dismissWindow: dismissWindow
                        )
                    },
                    onShowMETAR: {
                        coordinator.setSupplementaryOpen(
                            true,
                            icao: icao,
                            kind: .metar,
                            openWindow: openWindow,
                            dismissWindow: dismissWindow
                        )
                    },
                    onShowADS: {
                        coordinator.setSupplementaryOpen(
                            true,
                            icao: icao,
                            kind: .adsFeed,
                            openWindow: openWindow,
                            dismissWindow: dismissWindow
                        )
                    },
                    onHidePanel: { showRightPanel = false }
                )
                .frame(width: 300)
                .frame(maxHeight: .infinity, alignment: .top)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: showRightPanel)
        .overlay(alignment: .trailing) {
            if !showRightPanel {
                Button {
                    showRightPanel = true
                } label: {
                    Image(systemName: "sidebar.right")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .help("Show pattern panel")
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
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
        .animation(.easeInOut(duration: 0.28), value: engine.liveAirportICAOs.contains(airport.icao))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showRightPanel.toggle()
                } label: {
                    Label(
                        showRightPanel ? "Hide Panel" : "Show Panel",
                        systemImage: "sidebar.right"
                    )
                }
                .help(showRightPanel ? "Hide pattern panel" : "Show pattern panel")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    engine.showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onChange(of: airport.icao) { _, _ in
            engine.setSelectedTrackerICAO24(nil, airportICAO: icao)
            engine.setHoveredTrackerICAO24(nil, airportICAO: icao)
        }
        .sheet(item: $trackDump) { dump in
            TrackDumpSheet(dump: dump)
        }
    }

    private var selectedTrackerBinding: Binding<String?> {
        Binding(
            get: { engine.selectedTrackerICAO24(for: airport.icao) },
            set: { engine.setSelectedTrackerICAO24($0, airportICAO: airport.icao) }
        )
    }
}

#Preview {
    AirportWindowView(icao: "KPAO")
        .environment(TrackingEngine())
        .environment(OpenAirportCoordinator())
        .modelContainer(for: [StoredAirport.self], inMemory: true)
}
