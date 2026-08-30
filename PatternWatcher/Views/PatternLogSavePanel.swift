import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum PatternLogSavePanel {
    #if os(macOS)
    @MainActor
    static func saveLog(airportICAO: String) async -> URL? {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.title = "Save pattern log"
        panel.message =
            "Saves up to \(PatternOccupancy.maxRetentionDays) days of pattern data for \(airportICAO): occupancy counts, hourly statistics, landings, departures, and each aircraft’s tail/callsign and pattern state."
        panel.nameFieldStringValue = PatternLogExporter.defaultFileName(airportICAO: airportICAO)
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
            let response = await panel.beginSheetModal(for: window)
            guard response == .OK else { return nil }
            return panel.url
        }

        let response = await panel.begin()
        guard response == .OK else { return nil }
        return panel.url
    }
    #endif
}

#if os(macOS)
extension NSSavePanel {
    @MainActor
    func beginSheetModal(for window: NSWindow) async -> NSApplication.ModalResponse {
        await withCheckedContinuation { continuation in
            beginSheetModal(for: window) { response in
                continuation.resume(returning: response)
            }
        }
    }
}
#endif
