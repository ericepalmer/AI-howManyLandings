import Foundation
import Observation
import SwiftUI

/// Supplementary windows opened from airport panel buttons.
enum SupplementaryWindowKind: String, CaseIterable, Hashable, Sendable {
    case patternGraph
    case stats
    case metar
    case adsFeed

    var windowID: String {
        switch self {
        case .patternGraph: return "pattern-occupancy"
        case .stats: return "pattern-stats"
        case .metar: return "metar"
        case .adsFeed: return "ads-feed"
        }
    }

    var menuTitle: String {
        switch self {
        case .patternGraph: return "Pattern"
        case .stats: return "Stats"
        case .metar: return "METAR"
        case .adsFeed: return "ADS"
        }
    }
}

/// Tracks which airport windows are open and coordinates File → New Airport.
@MainActor
@Observable
final class OpenAirportCoordinator {
    /// Open airport ICAOs in window-open order.
    private(set) var openICAOs: [String] = []
    /// False during launch until saved airports are opened (blocks stray restored windows).
    private(set) var launchRestoreComplete = false
    var showingNewAirportPicker = false
    /// Which airport window presents the new-airport sheet (`nil` = bootstrap welcome).
    var newAirportPickerHostICAO: String?
    #if os(iOS)
    var showingSettings = false
    /// Which airport window presents the settings sheet.
    var settingsHostICAO: String?
    #endif
    private var showMiniPatternPlotByICAO: [String: Bool] = [:]
    private var openSupplementaryByICAO: [String: Set<SupplementaryWindowKind>] = [:]

    func beginLaunchRestore(savedICAOs: [String]) {
        launchRestoreComplete = false
        openICAOs = savedICAOs
    }

    func finishLaunchRestore() {
        launchRestoreComplete = true
        persistOpenICAOs()
    }

    func registerOpen(_ icao: String) {
        if !launchRestoreComplete {
            guard openICAOs.contains(icao) else { return }
        }
        if !openICAOs.contains(icao) {
            openICAOs.append(icao)
        }
        if launchRestoreComplete {
            persistOpenICAOs()
        }
    }

    /// User closed an airport window (not app quit). Cleans per-airport UI state; call reconcile after the window is gone.
    func noteMainAirportWillClose(icao: String) {
        #if os(macOS)
        guard !AppDelegate.isTerminating else { return }
        #endif
        openSupplementaryByICAO.removeValue(forKey: icao)
        showMiniPatternPlotByICAO.removeValue(forKey: icao)
    }

    /// Replace open-airport state and polling with main airport windows currently on screen.
    func reconcileOpenAirportsAndTracking(
        engine: TrackingEngine,
        airportForICAO: (String) -> Airport?
    ) {
        #if os(macOS)
        let windowICAOs = mainWindowICAOsOrdered()
        openICAOs = windowICAOs
        if launchRestoreComplete {
            writePersistedOpenAirports(windowICAOs)
        }
        let airports = windowICAOs.compactMap(airportForICAO)
        engine.updateTrackedAirports(airports)
        #else
        let airports = openICAOs.compactMap(airportForICAO)
        engine.updateTrackedAirports(airports)
        #endif
    }

    #if os(macOS)
    var hasOpenMainAirportWindows: Bool {
        !mainWindowICAOsOrdered().isEmpty
    }
    #endif

    /// User closed an airport window (not app quit).
    func closeAirportWindow(icao: String) {
        noteMainAirportWillClose(icao: icao)
        #if os(macOS)
        guard !AppDelegate.isTerminating else { return }
        #endif
        openICAOs.removeAll { $0 == icao }
        if launchRestoreComplete {
            writePersistedOpenAirports(openICAOs)
        }
    }

    func unregisterOpen(_ icao: String) {
        openICAOs.removeAll { $0 == icao }
        openSupplementaryByICAO.removeValue(forKey: icao)
        showMiniPatternPlotByICAO.removeValue(forKey: icao)
        #if os(macOS)
        if !AppDelegate.isTerminating {
            persistOpenICAOs()
        }
        #else
        persistOpenICAOs()
        #endif
    }

    private func persistOpenICAOs() {
        writePersistedOpenAirports(openICAOs)
    }

    /// On quit: discard the previous restore list and persist only main airport windows open now.
    func snapshotRestoreList() {
        #if os(macOS)
        let snapshot = mainWindowICAOsOrdered()
        openICAOs = snapshot
        writePersistedOpenAirports(snapshot)
        #else
        persistOpenICAOs()
        #endif
    }

    private func writePersistedOpenAirports(_ icaos: [String]) {
        AppSettings.openAirportICAOs = icaos
        #if os(macOS)
        UserDefaults.standard.synchronize()
        #endif
    }

    #if os(macOS)
    /// ICAO for the key window when it belongs to an open airport (main or supplementary).
    func keyWindowAirportICAO() -> String? {
        guard let window = NSApp.keyWindow else { return nil }
        if let id = window.identifier {
            let icao = AirportWindowRole.main.icao(from: id)
                ?? AirportWindowRole.auxiliary.icao(from: id)
            if let icao, openICAOs.contains(icao) {
                return icao
            }
        }
        if let icao = AirportWindowRole.icaoFromMainWindow(window),
           openICAOs.contains(icao) {
            return icao
        }
        return nil
    }

    /// Open main airport windows in window-list order (identifier `pw-airport-*` or title).
    func mainWindowICAOsOrdered() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for window in NSApp.windows {
            guard window.isVisible || window.isMiniaturized else { continue }
            let icao: String?
            if let id = window.identifier,
               let fromID = AirportWindowRole.main.icao(from: id) {
                icao = fromID
            } else {
                icao = AirportWindowRole.icaoFromMainWindow(window)
            }
            guard let icao, icao.count == 4 else { continue }
            guard !seen.contains(icao) else { continue }
            seen.insert(icao)
            ordered.append(icao)
        }
        return ordered
    }

    func reconcileOpenMainWindows() {
        openICAOs = mainWindowICAOsOrdered()
    }
    #endif

    func requestNewAirport() {
        #if os(macOS)
        newAirportPickerHostICAO = keyWindowAirportICAO() ?? openICAOs.last
        #else
        newAirportPickerHostICAO = openICAOs.last
        #endif
        showingNewAirportPicker = true
    }

    func dismissNewAirportPicker() {
        showingNewAirportPicker = false
        newAirportPickerHostICAO = nil
    }

    #if os(iOS)
    func requestSettings(hostICAO: String) {
        settingsHostICAO = hostICAO
        showingSettings = true
    }

    func dismissSettings() {
        showingSettings = false
        settingsHostICAO = nil
    }
    #endif

    func showMiniPatternPlot(for icao: String) -> Bool {
        showMiniPatternPlotByICAO[icao] ?? AppSettings.showMiniPatternPlot
    }

    func setShowMiniPatternPlot(_ show: Bool, for icao: String) {
        guard showMiniPatternPlot(for: icao) != show else { return }
        showMiniPatternPlotByICAO[icao] = show
    }

    func miniPlotBinding(for icao: String) -> Binding<Bool> {
        Binding(
            get: { self.showMiniPatternPlot(for: icao) },
            set: { self.setShowMiniPatternPlot($0, for: icao) }
        )
    }

    func isSupplementaryOpen(icao: String, kind: SupplementaryWindowKind) -> Bool {
        openSupplementaryByICAO[icao]?.contains(kind) ?? false
    }

    func registerSupplementaryOpen(icao: String, kind: SupplementaryWindowKind) {
        var set = openSupplementaryByICAO[icao] ?? []
        guard !set.contains(kind) else { return }
        set.insert(kind)
        openSupplementaryByICAO[icao] = set
    }

    func unregisterSupplementaryOpen(icao: String, kind: SupplementaryWindowKind) {
        guard var set = openSupplementaryByICAO[icao], set.contains(kind) else { return }
        set.remove(kind)
        if set.isEmpty {
            openSupplementaryByICAO.removeValue(forKey: icao)
        } else {
            openSupplementaryByICAO[icao] = set
        }
    }

    func setSupplementaryOpen(
        _ open: Bool,
        icao: String,
        kind: SupplementaryWindowKind,
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) {
        if open {
            registerSupplementaryOpen(icao: icao, kind: kind)
            openWindow(id: kind.windowID, value: icao)
        } else {
            unregisterSupplementaryOpen(icao: icao, kind: kind)
            dismissWindow(id: kind.windowID, value: icao)
        }
    }

    func dismissAllSupplementary(for icao: String, dismissWindow: DismissWindowAction) {
        for kind in SupplementaryWindowKind.allCases where isSupplementaryOpen(icao: icao, kind: kind) {
            unregisterSupplementaryOpen(icao: icao, kind: kind)
            dismissWindow(id: kind.windowID, value: icao)
        }
    }

    func supplementaryBinding(
        icao: String,
        kind: SupplementaryWindowKind,
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) -> Binding<Bool> {
        Binding(
            get: { self.isSupplementaryOpen(icao: icao, kind: kind) },
            set: { newValue in
                let currentlyOpen = self.isSupplementaryOpen(icao: icao, kind: kind)
                guard newValue != currentlyOpen else { return }
                self.setSupplementaryOpen(
                    newValue,
                    icao: icao,
                    kind: kind,
                    openWindow: openWindow,
                    dismissWindow: dismissWindow
                )
            }
        )
    }

}

extension View {
    func tracksSupplementaryWindow(
        icao: String,
        kind: SupplementaryWindowKind,
        coordinator: OpenAirportCoordinator
    ) -> some View {
        modifier(SupplementaryWindowLifecycleModifier(icao: icao, kind: kind, coordinator: coordinator))
    }
}

private struct SupplementaryWindowLifecycleModifier: ViewModifier {
    let icao: String
    let kind: SupplementaryWindowKind
    let coordinator: OpenAirportCoordinator

    func body(content: Content) -> some View {
        content
            .focusedValue(\.airportWindowICAO, icao)
            .onAppear {
                coordinator.registerSupplementaryOpen(icao: icao, kind: kind)
                #if os(macOS)
                AppDelegate.coordinator = coordinator
                #endif
            }
            #if os(macOS)
            .background(AirportWindowCloseTracker(icao: icao, role: .auxiliary, coordinator: coordinator))
            #endif
            .onDisappear { coordinator.unregisterSupplementaryOpen(icao: icao, kind: kind) }
    }
}
