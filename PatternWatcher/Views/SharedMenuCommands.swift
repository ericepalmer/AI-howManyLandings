import SwiftUI

/// Menu customizations applied on every scene so the Window menu stays consistent.
struct SharedMenuCommands: Commands {
    var body: some Commands {
        #if os(macOS)
        CommandGroup(replacing: .windowArrangement) {
            EmptyView()
        }
        CommandGroup(replacing: .windowSize) {
            EmptyView()
        }
        #endif
    }
}
