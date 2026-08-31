import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum PatternLogSavePanel {
    #if os(macOS)
    @MainActor
    static func saveLog(airportICAO: String) -> URL? {
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.title = "Save pattern log"
        panel.message =
            "Saves up to \(PatternOccupancy.maxRetentionDays) days of pattern data for \(airportICAO): occupancy counts, hourly statistics, landings, departures, and each aircraft’s tail/callsign and pattern state."
        panel.nameFieldStringValue = PatternLogExporter.defaultFileName(airportICAO: airportICAO)
        if let jsonType = UTType(filenameExtension: "json") {
            panel.allowedContentTypes = [jsonType]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false

        guard panel.runModal() == .OK else { return nil }
        guard var url = panel.url else { return nil }
        if url.pathExtension.lowercased() != "json" {
            url = url.appendingPathExtension("json")
        }
        return url
    }
    #endif
}
