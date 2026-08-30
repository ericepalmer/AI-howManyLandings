#if os(macOS)
import AppKit
import SwiftUI

/// Removes an airport from the launch-restore list when the user closes its window (not on app quit).
struct AirportWindowCloseTracker: NSViewRepresentable {
    let icao: String
    let coordinator: OpenAirportCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(icao: icao, coordinator: coordinator)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(to: view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.icao = icao
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView)
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var icao: String
        let coordinator: OpenAirportCoordinator
        private weak var attachedWindow: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        init(icao: String, coordinator: OpenAirportCoordinator) {
            self.icao = icao
            self.coordinator = coordinator
        }

        func attach(to view: NSView) {
            guard let window = view.window else { return }
            guard attachedWindow !== window else { return }
            attachedWindow = window
            previousDelegate = window.delegate
            window.delegate = self
        }

        func windowWillClose(_ notification: Notification) {
            guard !AppDelegate.isTerminating else { return }
            coordinator.removeFromRestoreList(icao)
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if let previousDelegate, previousDelegate !== self {
                return previousDelegate.windowShouldClose?(sender) ?? true
            }
            return true
        }
    }
}
#endif
