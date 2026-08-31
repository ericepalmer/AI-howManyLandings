#if os(macOS)
import AppKit
import SwiftUI

/// Stable Window-menu airport toggles (SwiftUI `Commands` rebuilds cause flicker).
@MainActor
final class WindowMenuController: NSObject {
    static let shared = WindowMenuController()

    weak var coordinator: OpenAirportCoordinator?

    private static let airportSectionTag = 9_401
    private var rebuildWorkItem: DispatchWorkItem?

    func scheduleRebuild() {
        if let coordinator = AppDelegate.coordinator {
            self.coordinator = coordinator
        }
        rebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildAirportMenus()
        }
        rebuildWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func rebuildAirportMenus() {
        guard let windowMenu = NSApp.mainMenu?.item(withTitle: "Window")?.submenu else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.rebuildAirportMenus()
            }
            return
        }

        stabilizeWindowMenu(windowMenu)
        removeAirportSection(from: windowMenu)

        guard let coordinator, !coordinator.openICAOs.isEmpty else { return }

        windowMenu.addItem(separatorItem())
        for icao in coordinator.openICAOs {
            let submenu = NSMenu()
            let miniPlot = NSMenuItem(
                title: "Show mini-plot",
                action: #selector(toggleMiniPlot(_:)),
                keyEquivalent: ""
            )
            miniPlot.target = self
            miniPlot.representedObject = MiniPlotMenuTarget(icao: icao)
            miniPlot.state = coordinator.showMiniPatternPlot(for: icao) ? .on : .off
            miniPlot.tag = Self.airportSectionTag
            submenu.addItem(miniPlot)

            let airportItem = NSMenuItem(title: icao, action: nil, keyEquivalent: "")
            airportItem.submenu = submenu
            airportItem.tag = Self.airportSectionTag
            windowMenu.addItem(airportItem)
        }
    }

    private func stabilizeWindowMenu(_ menu: NSMenu) {
        for item in menu.items where item.tag != Self.airportSectionTag {
            if item.title == "Move & Resize" || item.title.contains("Tile") {
                item.isHidden = true
            }
            if let submenu = item.submenu {
                for sub in submenu.items {
                    if sub.title.contains("Tile") || sub.title == "Fill" || sub.title == "Center" {
                        sub.isHidden = true
                    }
                }
            }
        }
    }

    private func removeAirportSection(from menu: NSMenu) {
        for item in menu.items where item.tag == Self.airportSectionTag {
            menu.removeItem(item)
        }
    }

    private func separatorItem() -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.tag = Self.airportSectionTag
        return item
    }

    @objc private func toggleMiniPlot(_ sender: NSMenuItem) {
        guard let coordinator,
              let target = sender.representedObject as? MiniPlotMenuTarget
        else { return }
        let icao = target.icao
        let show = !coordinator.showMiniPatternPlot(for: icao)
        coordinator.setShowMiniPatternPlot(show, for: icao)
        sender.state = show ? .on : .off
    }
}

private final class MiniPlotMenuTarget: NSObject {
    let icao: String
    init(icao: String) { self.icao = icao }
}
#endif
