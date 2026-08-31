#if os(macOS)
import SwiftUI

/// Wires the stable AppKit Window menu (avoids SwiftUI menu flicker).
struct WindowMenuBridge: View {
    @Environment(OpenAirportCoordinator.self) private var coordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                let menu = WindowMenuController.shared
                menu.coordinator = coordinator
                AppDelegate.coordinator = coordinator
                menu.scheduleRebuild()
            }
    }
}
#endif
