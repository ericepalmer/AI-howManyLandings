#if os(macOS)
import AppKit

/// Window menu: flat mini-plot toggles and strip tiling / tabbing items.
@MainActor
final class WindowMenuController: NSObject, NSMenuDelegate {
    static let shared = WindowMenuController()

    private static let customTag = 9_401
    private var syncWorkItem: DispatchWorkItem?

    static func installObservers() {
        NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let menu = notification.object as? NSMenu,
                  menu === NSApp.mainMenu?.item(withTitle: "Window")?.submenu
            else { return }
            Task { @MainActor in
                WindowMenuController.shared.scheduleSyncMenu()
            }
        }
    }

    func scheduleSyncMenu() {
        syncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.syncMenu()
        }
        syncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    func syncMenu() {
        guard let menu = windowSubmenu() else { return }
        if menu.delegate !== self {
            menu.delegate = self
        }
        stripUnwantedItems(from: menu)
        rebuildMiniPlotItems(in: menu)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === windowSubmenu() else { return }
        stripUnwantedItems(from: menu)
        rebuildMiniPlotItems(in: menu)
    }

    private func windowSubmenu() -> NSMenu? {
        NSApp.mainMenu?.item(withTitle: "Window")?.submenu
    }

    private func rebuildMiniPlotItems(in menu: NSMenu) {
        guard let coordinator = AppDelegate.coordinator else {
            removeCustomItems(from: menu)
            return
        }

        let icaos = coordinator.openICAOs
        if icaos.isEmpty {
            removeCustomItems(from: menu)
            return
        }

        let miniPlotItems = menu.items.filter { $0.tag == Self.customTag && !$0.isSeparatorItem }
        let existingIcaos = miniPlotItems.compactMap { ($0.representedObject as? MiniPlotMenuTarget)?.icao }

        if existingIcaos == icaos {
            updateMiniPlotStates(in: menu, coordinator: coordinator)
            return
        }

        removeCustomItems(from: menu)
        menu.addItem(taggedSeparator())
        let multi = icaos.count > 1
        for icao in icaos {
            let item = NSMenuItem(
                title: miniPlotTitle(icao: icao, multipleAirports: multi),
                action: #selector(toggleMiniPlot(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = MiniPlotMenuTarget(icao: icao)
            item.state = coordinator.showMiniPatternPlot(for: icao) ? .on : .off
            item.tag = Self.customTag
            menu.addItem(item)
        }
    }

    private func updateMiniPlotStates(in menu: NSMenu, coordinator: OpenAirportCoordinator) {
        for item in menu.items where item.tag == Self.customTag && !item.isSeparatorItem {
            guard let icao = (item.representedObject as? MiniPlotMenuTarget)?.icao else { continue }
            item.state = coordinator.showMiniPatternPlot(for: icao) ? .on : .off
        }
    }

    private func miniPlotTitle(icao: String, multipleAirports: Bool) -> String {
        if multipleAirports {
            return "Show mini-plot (\(icao))"
        }
        return "Show mini-plot"
    }

    private func stripUnwantedItems(from menu: NSMenu) {
        var index = 0
        while index < menu.items.count {
            let item = menu.items[index]
            if item.tag == Self.customTag {
                index += 1
                continue
            }
            if shouldRemove(item) {
                menu.removeItem(at: index)
                continue
            }
            if let submenu = item.submenu {
                stripUnwantedItems(from: submenu)
                if submenu.items.isEmpty {
                    menu.removeItem(at: index)
                    continue
                }
            }
            index += 1
        }
    }

    private func shouldRemove(_ item: NSMenuItem) -> Bool {
        let lower = item.title.lowercased()
        if lower.contains("mini-plot") { return true }
        if lower.contains("tile") { return true }
        if lower.contains("tab") { return true }
        if lower.contains("merge") && lower.contains("window") { return true }
        if lower.contains("full screen") { return true }
        if lower == "fill" || lower == "center" || lower == "move" { return true }
        if lower.contains("move") && lower.contains("resize") { return true }
        return false
    }

    private func removeCustomItems(from menu: NSMenu) {
        for item in menu.items where item.tag == Self.customTag {
            menu.removeItem(item)
        }
    }

    private func taggedSeparator() -> NSMenuItem {
        let item = NSMenuItem.separator()
        item.tag = Self.customTag
        return item
    }

    @objc private func toggleMiniPlot(_ sender: NSMenuItem) {
        guard let coordinator = AppDelegate.coordinator,
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
