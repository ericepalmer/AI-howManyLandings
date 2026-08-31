#if os(macOS)
import AppKit
import Foundation

@MainActor
enum PatternLogSaveService {
    static func save(
        coordinator: OpenAirportCoordinator?,
        engine: TrackingEngine?,
        focusedAirportICAO: String? = nil
    ) {
        guard let coordinator, let engine else {
            presentMessage(
                "Save Log unavailable",
                informative: "Open an airport window and try again."
            )
            return
        }

        let icao = focusedAirportICAO
            ?? coordinator.saveLogTargetICAO
            ?? coordinator.openICAOs.last

        guard let icao else {
            presentMessage(
                "No airport selected",
                informative: "Open an airport window before saving a pattern log."
            )
            return
        }

        guard let url = PatternLogSavePanel.saveLog(airportICAO: icao) else { return }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            try engine.savePatternLog(for: icao, to: url)
        } catch {
            NSLog("Failed to save pattern log: \(error.localizedDescription)")
            presentError(error)
        }
    }

    private static func presentError(_ error: Error) {
        presentMessage(
            "Could not save pattern log",
            informative: error.localizedDescription
        )
    }

    private static func presentMessage(_ message: String, informative: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .warning
        alert.runModal()
    }
}
#endif
