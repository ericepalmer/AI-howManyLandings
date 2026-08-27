import SwiftData
import SwiftUI

@main
struct HowManyLandingsApp: App {
    @State private var engine = TrackingEngine()

    init() {
        print("How Many Landings \(AppBuild.label)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
        }
        .modelContainer(for: [StoredAirport.self, StoredTrafficEvent.self])
        .defaultSize(width: 1240, height: 820)

        WindowGroup("ADS-B Feed", id: "ads-feed") {
            ADSFeedWindow()
                .environment(engine)
        }
        #if os(macOS)
        .defaultSize(width: 920, height: 560)
        #endif

        WindowGroup("Pattern Occupancy", id: "pattern-occupancy") {
            PatternOccupancyWindow()
                .environment(engine)
        }
        #if os(macOS)
        .defaultSize(width: 720, height: 460)
        #endif

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
        }
        .defaultSize(width: 520, height: 680)
        #endif
    }
}
