#if os(macOS)
import AppKit

/// Updates File → Save Log title when the active airport changes (SwiftUI Commands do not refresh reliably).
@MainActor
enum FileMenuController {
    private static let saveLogMenuTag = 9_402

    static func syncSaveLogTitle(icao: String?) {
        guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu else { return }
        guard let item = fileMenu.items.first(where: {
            $0.tag == saveLogMenuTag || $0.title.hasPrefix("Save Log")
        }) else { return }
        item.tag = saveLogMenuTag
        if let icao {
            item.title = "Save Log for \(icao)…"
        } else {
            item.title = "Save Log…"
        }
    }
}
#endif
