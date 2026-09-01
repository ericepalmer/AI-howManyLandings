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

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        removeUnwantedMenus()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.disallowTabbingOnAllWindows()
        AirportWindowCloseObserver.install()
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppDelegate.disallowTabbingOnAllWindows()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppDelegate.snapshotOpenWindowsForNextLaunch()
            }
        }

        Task { @MainActor in
            removeUnwantedMenus()
        }
    }

    @MainActor
    static func snapshotOpenWindowsForNextLaunch() {
        isTerminating = true
        coordinator?.snapshotRestoreList()
    }

    @MainActor
    static func reconcileOpenAirportsAndTracking() {
        guard let coordinator, let engine else { return }
        coordinator.reconcileOpenAirportsAndTracking(
            engine: engine,
            airportForICAO: { icao in
                AirportCatalog.shared.airport(code: icao)
            }
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Self.snapshotOpenWindowsForNextLaunch()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.snapshotOpenWindowsForNextLaunch()
    }

    @MainActor
    static func disallowTabbingOnAllWindows() {
        for window in NSApp.windows {
            window.tabbingMode = .disallowed
        }
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
            AppMenuCommands(coordinator: coordinator, engine: engine)
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
