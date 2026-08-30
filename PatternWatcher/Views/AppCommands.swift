import SwiftUI

/// File menu commands (safe to attach to bootstrap and airport scenes).
struct FileCommands: Commands {
    @FocusedValue(\.airportWindowICAO) private var focusedAirportICAO
    var coordinator: OpenAirportCoordinator
    var engine: TrackingEngine

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Airport") {
                coordinator.requestNewAirport()
            }
        }

        #if os(macOS)
        CommandGroup(after: .newItem) {
            Button(saveLogTitle) {
                Task {
                    await PatternLogSaveService.save(
                        coordinator: coordinator,
                        engine: engine,
                        focusedAirportICAO: focusedAirportICAO
                    )
                }
            }
            .disabled(saveLogICAO == nil)
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
            EmptyView()
        }

        CommandGroup(replacing: .sidebar) {
            EmptyView()
        }
    }

    #if os(macOS)
    private var saveLogICAO: String? {
        focusedAirportICAO
            ?? coordinator.saveLogTargetICAO
            ?? coordinator.openICAOs.last
    }

    private var saveLogTitle: String {
        if let icao = saveLogICAO {
            return "Save Log for \(icao)…"
        }
        return "Save Log…"
    }
    #endif
}
