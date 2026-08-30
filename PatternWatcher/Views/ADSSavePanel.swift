import Foundation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum ADSSavePanel {
    #if os(macOS)
    @MainActor
    static func saveTrack(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.title = "Save ADS-B track"
        panel.message = "Exports all saved polls plus the current aircraft filter as a separate section."
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
    #endif
}
