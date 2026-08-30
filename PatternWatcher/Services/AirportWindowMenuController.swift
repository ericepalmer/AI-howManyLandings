#if os(macOS)
import AppKit
import SwiftUI

/// Stable Window-menu airport toggles (avoids SwiftUI `Commands` rebuild flicker).
@MainActor
final class AirportWindowMenuController: NSObject {
    static let shared = AirportWindowMenuController()

    weak var coordinator: OpenAirportCoordinator?
    var openWindow: OpenWindowAction?
    var dismissWindow: DismissWindowAction?

    private static let airportSectionTag = 9_401
    private var rebuildWorkItem: DispatchWorkItem?
    private var installed = false

    func installIfNeeded() {
        guard !installed else { return }
        installed = true
        rebuildAirportMenus()
    }

    func scheduleRebuild() {
        rebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.rebuildAirportMenus()
        }
        rebuildWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func rebuildAirportMenus() {
        guard let windowMenu = NSApp.mainMenu?
            .items
            .first(where: { $0.title == "Window" })?
            .submenu
        else { return }

        removeAirportSection(from: windowMenu)

        guard let coordinator, !coordinator.openICAOs.isEmpty else { return }

        windowMenu.addItem(separatorItem())
        for icao in coordinator.openICAOs {
            let submenu = NSMenu()
            let miniPlot = NSMenuItem(
                title: "Mini plot",
                action: #selector(toggleMiniPlot(_:)),
                keyEquivalent: ""
            )
            miniPlot.target = self
            miniPlot.state = coordinator.showMiniPatternPlot ? .on : .off
            miniPlot.tag = Self.airportSectionTag
            submenu.addItem(miniPlot)

            for kind in SupplementaryWindowKind.allCases {
                let item = NSMenuItem(
                    title: kind.menuTitle,
                    action: #selector(toggleSupplementary(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = SupplementaryMenuTarget(icao: icao, kind: kind)
                item.state = coordinator.isSupplementaryOpen(icao: icao, kind: kind) ? .on : .off
                item.tag = Self.airportSectionTag
                submenu.addItem(item)
            }

            let airportItem = NSMenuItem(title: icao, action: nil, keyEquivalent: "")
            airportItem.submenu = submenu
            airportItem.tag = Self.airportSectionTag
            windowMenu.addItem(airportItem)
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
        guard let coordinator else { return }
        coordinator.setShowMiniPatternPlot(!coordinator.showMiniPatternPlot)
        sender.state = coordinator.showMiniPatternPlot ? .on : .off
    }

    @objc private func toggleSupplementary(_ sender: NSMenuItem) {
        guard let coordinator,
              let target = sender.representedObject as? SupplementaryMenuTarget,
              let openWindow,
              let dismissWindow
        else { return }

        let open = !coordinator.isSupplementaryOpen(icao: target.icao, kind: target.kind)
        coordinator.setSupplementaryOpen(
            open,
            icao: target.icao,
            kind: target.kind,
            openWindow: openWindow,
            dismissWindow: dismissWindow
        )
        sender.state = open ? .on : .off
        scheduleRebuild()
    }
}

private final class SupplementaryMenuTarget: NSObject {
    let icao: String
    let kind: SupplementaryWindowKind

    init(icao: String, kind: SupplementaryWindowKind) {
        self.icao = icao
        self.kind = kind
    }
}
#endif
