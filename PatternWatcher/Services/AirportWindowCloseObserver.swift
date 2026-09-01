#if os(macOS)
import AppKit

/// Defers airport/tracking reconciliation when a main window closes (SwiftUI delegates can be unreliable).
enum AirportWindowCloseObserver {
    static func install() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { notification in
            Task { @MainActor in
                guard !AppDelegate.isTerminating,
                      let window = notification.object as? NSWindow,
                      let icao = AirportWindowRole.icaoFromMainAirportWindow(window)
                else { return }
                AppDelegate.coordinator?.noteMainAirportWillClose(icao: icao)
                DispatchQueue.main.async {
                    AppDelegate.reconcileOpenAirportsAndTracking()
                }
            }
        }
    }
}
#endif
