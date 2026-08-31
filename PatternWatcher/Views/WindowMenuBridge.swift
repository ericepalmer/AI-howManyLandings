#if os(macOS)
import SwiftUI

/// Syncs the AppKit Window menu when a root window appears.
struct WindowMenuBridge: View {
    @Environment(OpenAirportCoordinator.self) private var coordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                AppDelegate.coordinator = coordinator
                WindowMenuController.shared.scheduleSyncMenu()
            }
    }
}
#endif
