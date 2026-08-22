import SwiftData
import SwiftUI

@main
struct HowManyLandingsApp: App {
    @State private var engine = TrackingEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(engine)
        }
        .modelContainer(for: [StoredAirport.self, StoredTrafficEvent.self])
        .defaultSize(width: 1240, height: 820)

        #if os(macOS)
        Settings {
            SettingsView()
                .environment(engine)
                .frame(width: 460, height: 320)
        }
        #endif
    }
}
