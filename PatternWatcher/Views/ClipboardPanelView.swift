import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
struct ClipboardPanelView: View {
    @State private var text = ""

    var body: some View {
        Group {
            if text.isEmpty {
                ContentUnavailableView(
                    "Clipboard is empty",
                    systemImage: "doc.on.clipboard",
                    description: Text("Copy track data or text from another app, then open this window again.")
                )
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color.primary.opacity(0.04))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refresh() }
    }

    private func refresh() {
        text = Clipboard.pasteboardString() ?? ""
    }
}

enum ClipboardPresenter {
    private static var panel: NSPanel?

    @MainActor
    static func show() {
        NSApp.activate(ignoringOtherApps: true)

        if panel == nil {
            let clipboardPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            clipboardPanel.title = "Clipboard"
            clipboardPanel.isReleasedWhenClosed = false
            clipboardPanel.minSize = NSSize(width: 360, height: 240)
            panel = clipboardPanel
        }

        guard let panel else { return }
        panel.contentView = NSHostingView(rootView: ClipboardPanelView())
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }
}
#endif
