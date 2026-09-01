#if os(macOS)
import AppKit
import Foundation

@MainActor
enum PatternLogSaveService {
    static func save(engine: TrackingEngine?) {
        guard let engine else {
            presentMessage(
                "Save Log unavailable",
                informative: "The tracking engine is not available."
            )
            return
        }

        let options = engine.trackedAirports.map { airport in
            PatternLogSavePanel.AirportOption(
                icao: airport.icao,
                label: "\(airport.icao) — \(airport.displayName)"
            )
        }

        guard !options.isEmpty else {
            presentMessage(
                "No airfields to save",
                informative: "Open an airport window so pattern data is being tracked, then try again."
            )
            return
        }

        guard let selection = PatternLogSavePanel.saveLog(airportOptions: options) else { return }

        let url = selection.url
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        do {
            try engine.savePatternLog(for: selection.icao, to: url)
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
