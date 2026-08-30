#if os(macOS)
import SwiftUI

/// Wires SwiftUI window actions into the AppKit Window menu controller.
struct WindowMenuBridge: View {
    let icao: String
    @Environment(TrackingEngine.self) private var engine
    @Environment(OpenAirportCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let menu = AirportWindowMenuController.shared
                menu.coordinator = coordinator
                menu.openWindow = openWindow
                menu.dismissWindow = dismissWindow
                AppDelegate.coordinator = coordinator
                AppDelegate.engine = engine
                coordinator.setSaveLogTarget(icao)
                menu.installIfNeeded()
                menu.scheduleRebuild()
            }
    }
}
#endif
