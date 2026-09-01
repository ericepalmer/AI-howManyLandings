import SwiftUI

/// App menu commands (attach once per primary scene).
struct AppMenuCommands: Commands {
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
            Button("Save Log…") {
                PatternLogSaveService.save(engine: engine)
            }
        }

        CommandGroup(after: .windowList) {
            ForEach(coordinator.openICAOs, id: \.self) { icao in
                Toggle(
                    miniPlotTitle(icao: icao),
                    isOn: coordinator.miniPlotBinding(for: icao)
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
    private func miniPlotTitle(icao: String) -> String {
        if coordinator.openICAOs.count > 1 {
            return "Show mini-plot (\(icao))"
        }
        return "Show mini-plot"
    }
    #endif
}
