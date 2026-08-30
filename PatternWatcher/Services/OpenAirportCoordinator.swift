import Foundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Supplementary windows toggled per airport from the Window menu.
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
        case .adsFeed: return "Display ADS"
        }
    }
}

/// Tracks which airport windows are open and coordinates File → New Airport.
@MainActor
@Observable
final class OpenAirportCoordinator {
    /// Open airport ICAOs in window-open order (restored from last session).
    private(set) var openICAOs: [String] = AppSettings.openAirportICAOs
    var showingNewAirportPicker = false
    /// Last airport or supplementary window that was active (save-log target).
    var saveLogTargetICAO: String?
    /// Mini pattern plot in the airport right panel (persisted; default on).
    var showMiniPatternPlot: Bool = AppSettings.showMiniPatternPlot
    private var openSupplementaryByICAO: [String: Set<SupplementaryWindowKind>] = [:]

    func registerOpen(_ icao: String) {
        if !openICAOs.contains(icao) {
            openICAOs.append(icao)
        }
        addToRestoreList(icao)
        refreshWindowMenu()
    }

    func unregisterOpen(_ icao: String) {
        openICAOs.removeAll { $0 == icao }
        openSupplementaryByICAO.removeValue(forKey: icao)
        refreshWindowMenu()
    }

    /// Drop an airport from the launch-restore list (user closed the window).
    func removeFromRestoreList(_ icao: String) {
        var list = AppSettings.openAirportICAOs
        list.removeAll { $0 == icao }
        AppSettings.openAirportICAOs = list
    }

    private func addToRestoreList(_ icao: String) {
        var list = AppSettings.openAirportICAOs
        guard !list.contains(icao) else { return }
        list.append(icao)
        AppSettings.openAirportICAOs = list
    }

    /// Persist open airports for next launch (e.g. on quit while windows are still open).
    func snapshotRestoreList() {
        guard !openICAOs.isEmpty else { return }
        AppSettings.openAirportICAOs = openICAOs
    }

    func requestNewAirport() {
        showingNewAirportPicker = true
    }

    func setSaveLogTarget(_ icao: String) {
        saveLogTargetICAO = icao
    }

    func setShowMiniPatternPlot(_ show: Bool) {
        guard showMiniPatternPlot != show else { return }
        showMiniPatternPlot = show
        AppSettings.showMiniPatternPlot = show
        refreshWindowMenu()
    }

    func miniPlotBinding() -> Binding<Bool> {
        Binding(
            get: { self.showMiniPatternPlot },
            set: { self.setShowMiniPatternPlot($0) }
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
        refreshWindowMenu()
    }

    func unregisterSupplementaryOpen(icao: String, kind: SupplementaryWindowKind) {
        guard var set = openSupplementaryByICAO[icao], set.contains(kind) else { return }
        set.remove(kind)
        if set.isEmpty {
            openSupplementaryByICAO.removeValue(forKey: icao)
        } else {
            openSupplementaryByICAO[icao] = set
        }
        refreshWindowMenu()
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
        AirportWindowMenuController.shared.scheduleRebuild()
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
                coordinator.setSaveLogTarget(icao)
                coordinator.registerSupplementaryOpen(icao: icao, kind: kind)
            }
            .onDisappear { coordinator.unregisterSupplementaryOpen(icao: icao, kind: kind) }
    }
}
