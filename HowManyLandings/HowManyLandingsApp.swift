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

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
                .frame(width: 460, height: 320)
        }
        #endif
    }
}
