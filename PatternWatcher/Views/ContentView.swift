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
            if AppSettings.openAirportICAOs.isEmpty {
                coordinator.finishLaunchRestore()
            } else {
                coordinator.beginLaunchRestore(savedICAOs: AppSettings.openAirportICAOs)
                #if os(iOS)
                reconcileWindowsAndTracking()
                #endif
            }
        }
        .sheet(isPresented: bindShowingNewAirportPicker) {
            AddAirportSheet(
                openICAOs: Set(coordinator.openICAOs),
                onOpen: openAirport
            )
        }
    }

    private var bindShowingNewAirportPicker: Binding<Bool> {
        Binding(
            get: {
                coordinator.showingNewAirportPicker
                    && coordinator.newAirportPickerHostICAO == nil
            },
            set: { newValue in
                if !newValue { coordinator.dismissNewAirportPicker() }
            }
        )
    }

    private func restoreAirportWindowsIfNeeded() {
        guard !didRestoreWindows else { return }
        didRestoreWindows = true
        #if os(macOS)
        if coordinator.hasOpenMainAirportWindows {
            coordinator.finishLaunchRestore()
            reconcileWindowsAndTracking()
            dismissWindow(id: "bootstrap")
            return
        }
        #endif
        let toOpen = AppSettings.openAirportICAOs
        guard !toOpen.isEmpty else { return }
        for icao in toOpen {
            openWindow(id: "airport", value: icao)
        }
        coordinator.finishLaunchRestore()
        reconcileWindowsAndTracking()
        dismissWindow(id: "bootstrap")
    }

    private func openAirport(_ airport: Airport) {
        coordinator.dismissNewAirportPicker()
        coordinator.registerOpen(airport.icao)
        reconcileWindowsAndTracking()
        openWindow(id: "airport", value: airport.icao)
        dismissWindow(id: "bootstrap")
    }

    private func reconcileWindowsAndTracking() {
        coordinator.reconcileOpenAirportsAndTracking(engine: engine, airportForICAO: airportForICAO)
    }

    private func syncTrackedAirports() {
        reconcileWindowsAndTracking()
    }

    private func airportForICAO(_ icao: String) -> Airport? {
        storedAirports.first(where: { $0.icao == icao })?.asAirport
            ?? AirportCatalog.shared.airport(code: icao)
    }
}

#if os(iOS)
/// iPad window views can disappear and reappear during launch without the window closing.
private enum AirportWindowPresence {
    private static var depth: [String: Int] = [:]

    static func appear(_ icao: String) {
        depth[icao, default: 0] += 1
    }

    static func disappear(_ icao: String) -> Bool {
        let next = max(0, (depth[icao] ?? 1) - 1)
        if next == 0 {
            depth.removeValue(forKey: icao)
        } else {
            depth[icao] = next
        }
        return next == 0
    }

    static func isVisible(_ icao: String) -> Bool {
        (depth[icao] ?? 0) > 0
    }

    static func replace(_ old: String, with new: String) {
        guard old != new else { return }
        let count = max(depth.removeValue(forKey: old) ?? 1, 1)
        depth[new, default: 0] += count
    }
}
#endif

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
    @Binding var icao: String

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
        .background(
            AirportWindowCloseTracker(
                icao: icao,
                role: .main,
                coordinator: coordinator,
                onMainWindowWillClose: handleMainAirportWindowClose
            )
        )
        #endif
        .onAppear {
            engine.attach(modelContext: modelContext)
            #if os(macOS)
            AppDelegate.coordinator = coordinator
            AppDelegate.engine = engine
            if !coordinator.launchRestoreComplete {
                let saved = AppSettings.openAirportICAOs
                if saved.contains(icao) {
                    coordinator.registerOpen(icao)
                } else {
                    DispatchQueue.main.async {
                        dismissWindow(id: "airport", value: icao)
                    }
                    return
                }
            } else {
                coordinator.registerOpen(icao)
            }
            #else
            AirportWindowPresence.appear(icao)
            coordinator.ensureOpen(icao)
            #endif
            reconcileWindowsAndTracking()
            #if os(macOS)
            if coordinator.hasOpenMainAirportWindows {
                dismissWindow(id: "bootstrap")
            }
            #endif
        }
        #if os(iOS)
        .onDisappear {
            let shouldClose = AirportWindowPresence.disappear(icao)
            guard shouldClose else { return }
            DispatchQueue.main.async {
                guard !AirportWindowPresence.isVisible(icao) else { return }
                coordinator.closeAirportWindow(icao: icao)
                coordinator.dismissAllSupplementary(for: icao, dismissWindow: dismissWindow)
                syncTrackedAirports()
            }
        }
        #endif
        #if os(iOS)
        .sheet(isPresented: supplementaryPresented(.patternGraph)) {
            PatternOccupancyWindow(airportICAO: icao)
                .tracksSupplementaryWindow(icao: icao, kind: .patternGraph, coordinator: coordinator)
        }
        .sheet(isPresented: supplementaryPresented(.stats)) {
            PatternStatsWindow(airportICAO: icao)
                .tracksSupplementaryWindow(icao: icao, kind: .stats, coordinator: coordinator)
        }
        .sheet(isPresented: supplementaryPresented(.metar)) {
            METARWindow(station: icao)
                .tracksSupplementaryWindow(icao: icao, kind: .metar, coordinator: coordinator)
        }
        .sheet(isPresented: supplementaryPresented(.adsFeed)) {
            ADSFeedWindow(airportICAO: icao)
                .tracksSupplementaryWindow(icao: icao, kind: .adsFeed, coordinator: coordinator)
        }
        .sheet(isPresented: bindShowingSettings) {
            SettingsView()
                .presentationDetents([.medium, .large])
        }
        #endif
        .sheet(isPresented: bindShowingNewAirportPicker) {
            AddAirportSheet(
                openICAOs: Set(coordinator.openICAOs),
                title: coordinator.replaceCurrentAirportOnPick ? "Change Airport" : "New Airport",
                onOpen: { airport in
                    if coordinator.replaceCurrentAirportOnPick {
                        replaceCurrentAirport(with: airport)
                    } else {
                        openAnotherAirport(airport)
                    }
                }
            )
        }
    }

    #if os(iOS)
    private func supplementaryPresented(_ kind: SupplementaryWindowKind) -> Binding<Bool> {
        coordinator.supplementaryBinding(
            icao: icao,
            kind: kind,
            openWindow: openWindow,
            dismissWindow: dismissWindow
        )
    }
    #endif

    private var bindShowingNewAirportPicker: Binding<Bool> {
        Binding(
            get: {
                coordinator.showingNewAirportPicker
                    && coordinator.newAirportPickerHostICAO == icao
            },
            set: { newValue in
                if !newValue { coordinator.dismissNewAirportPicker() }
            }
        )
    }

    #if os(iOS)
    private var bindShowingSettings: Binding<Bool> {
        Binding(
            get: {
                coordinator.showingSettings
                    && coordinator.settingsHostICAO == icao
            },
            set: { newValue in
                if !newValue { coordinator.dismissSettings() }
            }
        )
    }
    #endif

    private var windowTitle: String {
        if let airport {
            return "\(airport.icao) — \(airport.displayName)"
        }
        return icao
    }

    private func syncTrackedAirports() {
        reconcileWindowsAndTracking()
    }

    private func reconcileWindowsAndTracking() {
        coordinator.reconcileOpenAirportsAndTracking(engine: engine, airportForICAO: { icao in
            storedAirports.first(where: { $0.icao == icao })?.asAirport
                ?? AirportCatalog.shared.airport(code: icao)
        })
    }

    private func openAnotherAirport(_ airport: Airport) {
        coordinator.dismissNewAirportPicker()
        coordinator.registerOpen(airport.icao)
        reconcileWindowsAndTracking()
        openWindow(id: "airport", value: airport.icao)
    }

    /// Confirmed airport change. Cancel never calls this, so the current field and its feed stay put.
    private func replaceCurrentAirport(with airport: Airport) {
        let previous = icao
        coordinator.dismissNewAirportPicker()
        guard airport.icao != previous else { return }
        coordinator.dismissAllSupplementary(for: previous, dismissWindow: dismissWindow)
        coordinator.closeAirportWindow(icao: previous)
        #if os(iOS)
        AirportWindowPresence.replace(previous, with: airport.icao)
        #elseif os(macOS)
        if let window = NSApp.windows.first(where: {
            AirportWindowRole.icaoFromMainAirportWindow($0) == previous
        }) {
            window.identifier = AirportWindowRole.main.windowIdentifier(icao: airport.icao)
        }
        #endif
        coordinator.ensureOpen(airport.icao)
        icao = airport.icao
        reconcileWindowsAndTracking()
    }

    #if os(macOS)
    private func handleMainAirportWindowClose() {
        coordinator.dismissAllSupplementary(for: icao, dismissWindow: dismissWindow)
        coordinator.noteMainAirportWillClose(icao: icao)
        DispatchQueue.main.async {
            reconcileWindowsAndTracking()
            if coordinator.hasOpenMainAirportWindows {
                dismissWindow(id: "bootstrap")
            } else {
                coordinator.dismissNewAirportPicker()
                openWindow(id: "bootstrap")
            }
        }
    }
    #endif
}

private struct AirportDetailView: View {
    let airport: Airport
    @Environment(TrackingEngine.self) private var engine
    @Environment(OpenAirportCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    #if os(macOS)
    @Environment(\.openSettings) private var openSettings
    #endif
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
                    coordinator.requestAirportChange(from: airport.icao)
                } label: {
                    Label("Change Airport", systemImage: "airport.tower")
                        .labelStyle(.iconOnly)
                }
                .help("Change airport")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    #if os(macOS)
                    openSettings()
                    #else
                    coordinator.requestSettings(hostICAO: airport.icao)
                    #endif
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
    AirportWindowView(icao: .constant("KPAO"))
        .environment(TrackingEngine())
        .environment(OpenAirportCoordinator())
        .modelContainer(for: [StoredAirport.self], inMemory: true)
}
