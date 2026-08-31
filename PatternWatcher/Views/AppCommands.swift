import SwiftUI

/// File menu commands (attach to airport scene).
struct FileCommands: Commands {
    @FocusedValue(\.airportWindowICAO) private var focusedAirportICAO
    @Bindable var coordinator: OpenAirportCoordinator
    var engine: TrackingEngine

    var body: some Commands {
        #if os(macOS)
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppIdentity.name)") {
                AboutPresenter.show()
            }
        }
        #endif

        CommandGroup(replacing: .newItem) {
            Button("New Airport") {
                coordinator.requestNewAirport()
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        #if os(macOS)
        CommandGroup(after: .newItem) {
            Button(saveLogTitle) {
                PatternLogSaveService.save(
                    coordinator: coordinator,
                    engine: engine,
                    focusedAirportICAO: focusedAirportICAO
                )
            }
        }
        #endif

        CommandGroup(replacing: .undoRedo) {
            EmptyView()
        }

        CommandGroup(replacing: .pasteboard) {
            EmptyView()
        }

        CommandGroup(replacing: .textEditing) {
            EmptyView()
        }

        CommandGroup(replacing: .toolbar) {
            #if os(macOS)
            Button("Show Clipboard") {
                ClipboardPresenter.show()
            }
            #endif
        }

        CommandGroup(replacing: .sidebar) {
            EmptyView()
        }
    }

    #if os(macOS)
    private var saveLogICAO: String? {
        if let focused = focusedAirportICAO, coordinator.openICAOs.contains(focused) {
            return focused
        }
        return coordinator.activeSaveLogICAO
    }

    private var saveLogTitle: String {
        if let icao = saveLogICAO {
            return "Save Log for \(icao)…"
        }
        return "Save Log…"
    }
    #endif
}
