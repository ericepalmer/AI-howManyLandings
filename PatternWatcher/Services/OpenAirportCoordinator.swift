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
    /// Last airport or supplementary window that was active (save-log target).
    var saveLogTargetICAO: String?
    private var showMiniPatternPlotByICAO: [String: Bool] = [:]
    private var openSupplementaryByICAO: [String: Set<SupplementaryWindowKind>] = [:]

    func beginLaunchRestore(savedICAOs: [String]) {
        launchRestoreComplete = false
        openICAOs = savedICAOs
    }

    func finishLaunchRestore() {
        launchRestoreComplete = true
        persistOpenICAOs()
        refreshWindowMenu()
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
        refreshWindowMenu()
    }

    /// User closed an airport window (not app quit).
    func closeAirportWindow(icao: String) {
        #if os(macOS)
        guard !AppDelegate.isTerminating else { return }
        #endif
        guard openICAOs.contains(icao) else { return }
        openICAOs.removeAll { $0 == icao }
        openSupplementaryByICAO.removeValue(forKey: icao)
        showMiniPatternPlotByICAO.removeValue(forKey: icao)
        if saveLogTargetICAO == icao {
            saveLogTargetICAO = openICAOs.last
        }
        persistOpenICAOs()
        refreshWindowMenu()
        #if os(macOS)
        syncActiveAirportFromKeyWindow()
        FileMenuController.syncSaveLogTitle(icao: activeSaveLogICAO)
        #endif
    }

    func unregisterOpen(_ icao: String) {
        openICAOs.removeAll { $0 == icao }
        openSupplementaryByICAO.removeValue(forKey: icao)
        showMiniPatternPlotByICAO.removeValue(forKey: icao)
        if saveLogTargetICAO == icao {
            saveLogTargetICAO = openICAOs.last
        }
        #if os(macOS)
        if !AppDelegate.isTerminating {
            persistOpenICAOs()
        }
        #else
        persistOpenICAOs()
        #endif
        refreshWindowMenu()
    }

    /// Airport for File → Save Log (key window, must still be open).
    var activeSaveLogICAO: String? {
        if let target = saveLogTargetICAO, openICAOs.contains(target) {
            return target
        }
        return openICAOs.last
    }

    private func persistOpenICAOs() {
        AppSettings.openAirportICAOs = openICAOs
        #if os(macOS)
        UserDefaults.standard.synchronize()
        #endif
    }

    /// Persist open airports for next launch (on quit).
    func snapshotRestoreList() {
        persistOpenICAOs()
    }

    #if os(macOS)
    func syncActiveAirportFromKeyWindow() {
        guard let window = NSApp.keyWindow, let id = window.identifier else { return }
        let icao = AirportWindowRole.main.icao(from: id)
            ?? AirportWindowRole.auxiliary.icao(from: id)
        guard let icao, openICAOs.contains(icao) else { return }
        setSaveLogTarget(icao)
    }
    #endif

    func requestNewAirport() {
        showingNewAirportPicker = true
    }

    func setSaveLogTarget(_ icao: String) {
        saveLogTargetICAO = icao
        #if os(macOS)
        FileMenuController.syncSaveLogTitle(icao: icao)
        #endif
    }

    func showMiniPatternPlot(for icao: String) -> Bool {
        showMiniPatternPlotByICAO[icao] ?? AppSettings.showMiniPatternPlot
    }

    func setShowMiniPatternPlot(_ show: Bool, for icao: String) {
        guard showMiniPatternPlot(for: icao) != show else { return }
        showMiniPatternPlotByICAO[icao] = show
        refreshWindowMenu()
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

    #if os(macOS)
    private func refreshWindowMenu() {
        WindowMenuController.shared.scheduleSyncMenu()
    }
    #endif
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
                WindowMenuController.shared.scheduleSyncMenu()
                #endif
            }
            #if os(macOS)
            .background(AirportWindowCloseTracker(icao: icao, role: .auxiliary, coordinator: coordinator))
            #endif
            .onDisappear { coordinator.unregisterSupplementaryOpen(icao: icao, kind: kind) }
    }
}
