import SwiftData
import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let unwantedTopLevelMenus = ["Edit"]
    /// Set before windows close on quit so we keep the restore list in UserDefaults.
    static var isTerminating = false
    static weak var coordinator: OpenAirportCoordinator?
    static weak var engine: TrackingEngine?

    private var menuObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        removeUnwantedMenus()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let menu = notification.object as? NSMenu,
                  menu === NSApp.mainMenu?.item(withTitle: "Window")?.submenu
            else { return }
            if menu.items.contains(where: { $0.tag == 9_401 }) { return }
            WindowMenuController.shared.scheduleRebuild()
        }

        Task { @MainActor in
            removeUnwantedMenus()
            WindowMenuController.shared.scheduleRebuild()
        }
    }

    deinit {
        if let menuObserver {
            NotificationCenter.default.removeObserver(menuObserver)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.isTerminating = true
        Self.coordinator?.snapshotRestoreList()
        return .terminateNow
    }

    private func removeUnwantedMenus() {
        guard let mainMenu = NSApp.mainMenu else { return }
        for title in Self.unwantedTopLevelMenus {
            while let index = mainMenu.items.firstIndex(where: { $0.title == title }) {
                mainMenu.removeItem(at: index)
            }
        }
    }
}
#endif

@main
struct PatternWatcherApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @State private var engine = TrackingEngine()
    @State private var coordinator = OpenAirportCoordinator()

    init() {
        print("\(AppIdentity.name) \(AppBuild.label)")
        #if os(macOS)
        NSWindow.allowsAutomaticWindowTabbing = false
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "bootstrap") {
            BootstrapView()
                .environment(engine)
                .environment(coordinator)
        }
        .modelContainer(for: [StoredAirport.self])
        .defaultSize(width: 480, height: 360)
        .commands {
            FileCommands(coordinator: coordinator, engine: engine)
        }

        WindowGroup(id: "airport", for: String.self) { $icao in
            if let icao {
                AirportWindowView(icao: icao)
                    .environment(engine)
                    .environment(coordinator)
            }
        }
        .modelContainer(for: [StoredAirport.self])
        .defaultSize(width: 1240, height: 820)
        .commands {
            FileCommands(coordinator: coordinator, engine: engine)
        }

        WindowGroup(id: "ads-feed", for: String.self) { $icao in
            if let icao {
                ADSFeedWindow(airportICAO: icao)
                    .tracksSupplementaryWindow(icao: icao, kind: .adsFeed, coordinator: coordinator)
            }
        }
        .environment(engine)
        .environment(coordinator)
        #if os(macOS)
        .defaultSize(width: 920, height: 560)
        #endif

        WindowGroup(id: "pattern-occupancy", for: String.self) { $icao in
            if let icao {
                PatternOccupancyWindow(airportICAO: icao)
                    .tracksSupplementaryWindow(icao: icao, kind: .patternGraph, coordinator: coordinator)
            }
        }
        .environment(engine)
        .environment(coordinator)
        #if os(macOS)
        .defaultSize(width: 720, height: 460)
        #endif

        WindowGroup(id: "pattern-stats", for: String.self) { $icao in
            if let icao {
                PatternStatsWindow(airportICAO: icao)
                    .tracksSupplementaryWindow(icao: icao, kind: .stats, coordinator: coordinator)
            }
        }
        .environment(engine)
        .environment(coordinator)
        #if os(macOS)
        .defaultSize(width: 720, height: 560)
        #endif

        WindowGroup(id: "metar", for: String.self) { $station in
            if let station {
                METARWindow(station: station)
                    .tracksSupplementaryWindow(icao: station, kind: .metar, coordinator: coordinator)
            }
        }
        .environment(engine)
        .environment(coordinator)
        #if os(macOS)
        .defaultSize(width: 480, height: 420)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
        }
        .defaultSize(width: 460, height: 520)
        #endif
    }
}
