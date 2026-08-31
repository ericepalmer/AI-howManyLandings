import SwiftUI

/// Hides tiling / resize groups on every scene so the Window menu does not change with focus.
struct WindowStabilizerCommands: Commands {
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
