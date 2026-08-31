#if os(macOS)
import AppKit
import SwiftUI

/// Window close, key-window tracking, and identifiers for airport persistence.
struct AirportWindowCloseTracker: NSViewRepresentable {
    let icao: String
    var role: AirportWindowRole = .main
    let coordinator: OpenAirportCoordinator

    func makeCoordinator() -> Coordinator {
        Coordinator(icao: icao, role: role, coordinator: coordinator)
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
        context.coordinator.role = role
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView)
        }
    }

    final class Coordinator: NSObject, NSWindowDelegate {
        var icao: String
        var role: AirportWindowRole
        let coordinator: OpenAirportCoordinator
        private weak var attachedWindow: NSWindow?
        private weak var previousDelegate: NSWindowDelegate?

        init(icao: String, role: AirportWindowRole, coordinator: OpenAirportCoordinator) {
            self.icao = icao
            self.role = role
            self.coordinator = coordinator
        }

        func attach(to view: NSView) {
            guard let window = view.window else { return }
            guard attachedWindow !== window else { return }
            attachedWindow = window
            previousDelegate = window.delegate
            window.delegate = self
            window.identifier = role.windowIdentifier(icao: icao)
            if window.isKeyWindow {
                Task { @MainActor in
                    coordinator.setSaveLogTarget(icao)
                }
            }
        }

        func windowDidBecomeKey(_ notification: Notification) {
            Task { @MainActor in
                coordinator.setSaveLogTarget(icao)
            }
        }

        func windowWillClose(_ notification: Notification) {
            guard !AppDelegate.isTerminating else { return }
            guard role == .main else { return }
            DispatchQueue.main.async {
                self.coordinator.closeAirportWindow(icao: self.icao)
            }
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
