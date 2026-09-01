import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum PatternLogSavePanel {
    struct SaveLogSelection {
        let icao: String
        let url: URL
    }

    struct AirportOption {
        let icao: String
        let label: String
    }

    #if os(macOS)
    @MainActor
    static func saveLog(airportOptions: [AirportOption]) -> SaveLogSelection? {
        guard !airportOptions.isEmpty else { return nil }

        NSApp.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.title = "Save pattern log"
        panel.message =
            "Saves up to \(PatternOccupancy.maxRetentionDays) days of pattern data for the selected airfield: occupancy counts, hourly statistics, landings, departures, and each aircraft’s tail/callsign and pattern state."
        panel.nameFieldStringValue = PatternLogExporter.defaultFileName(
            airportICAO: airportOptions[0].icao
        )
        if let jsonType = UTType(filenameExtension: "json") {
            panel.allowedContentTypes = [jsonType]
        }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false

        let accessoryWidth: CGFloat = 420
        let accessoryHeight: CGFloat = 52
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: accessoryHeight))

        let airfieldLabel = NSTextField(labelWithString: "Airfield:")
        airfieldLabel.frame = NSRect(x: 0, y: 22, width: 56, height: 20)

        let popup = NSPopUpButton(
            frame: NSRect(x: 60, y: 16, width: accessoryWidth - 60, height: 26),
            pullsDown: false
        )
        for option in airportOptions {
            popup.addItem(withTitle: option.label)
        }

        accessory.addSubview(airfieldLabel)
        accessory.addSubview(popup)
        panel.accessoryView = accessory

        let filenameSync = SavePanelAirfieldCoordinator(
            panel: panel,
            airportOptions: airportOptions,
            popup: popup
        )
        popup.target = filenameSync
        popup.action = #selector(SavePanelAirfieldCoordinator.syncFileName)

        guard panel.runModal() == .OK else { return nil }
        guard var url = panel.url else { return nil }
        if url.pathExtension.lowercased() != "json" {
            url = url.appendingPathExtension("json")
        }
        let icao = airportOptions[popup.indexOfSelectedItem].icao
        return SaveLogSelection(icao: icao, url: url)
    }

    @MainActor
    private final class SavePanelAirfieldCoordinator: NSObject {
        let panel: NSSavePanel
        let airportOptions: [AirportOption]
        let popup: NSPopUpButton

        init(panel: NSSavePanel, airportOptions: [AirportOption], popup: NSPopUpButton) {
            self.panel = panel
            self.airportOptions = airportOptions
            self.popup = popup
        }

        @objc func syncFileName() {
            let index = popup.indexOfSelectedItem
            guard airportOptions.indices.contains(index) else { return }
            let icao = airportOptions[index].icao
            panel.nameFieldStringValue = PatternLogExporter.defaultFileName(airportICAO: icao)
        }
    }
    #endif
}
