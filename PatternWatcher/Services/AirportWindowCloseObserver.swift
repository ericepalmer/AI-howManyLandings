#if os(macOS)
import AppKit

/// Persists airport closes via NSWindow.willClose (SwiftUI often bypasses window delegates).
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
                      let icao = AirportWindowRole.icaoFromMainWindow(window)
                else { return }
                AppDelegate.coordinator?.closeAirportWindow(icao: icao)
            }
        }
    }
}
#endif
