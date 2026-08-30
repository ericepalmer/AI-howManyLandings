#if os(macOS)
import AppKit
import Foundation

@MainActor
enum PatternLogSaveService {
    static func save(
        coordinator: OpenAirportCoordinator?,
        engine: TrackingEngine?,
        focusedAirportICAO: String? = nil
    ) async {
        guard let coordinator, let engine else {
            NSSound.beep()
            return
        }

        let icao = focusedAirportICAO
            ?? coordinator.saveLogTargetICAO
            ?? coordinator.openICAOs.last

        guard let icao else {
            NSSound.beep()
            return
        }

        guard let url = await PatternLogSavePanel.saveLog(airportICAO: icao) else { return }
        do {
            try engine.savePatternLog(for: icao, to: url)
        } catch {
            NSLog("Failed to save pattern log: \(error.localizedDescription)")
            presentError(error)
        }
    }

    private static func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not save pattern log"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
#endif
