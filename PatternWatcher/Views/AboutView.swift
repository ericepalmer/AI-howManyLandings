import SwiftUI
#if os(macOS)
import AppKit
#endif

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            #if os(macOS)
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            #else
            Image(systemName: "airplane.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            #endif

            Text(AppIdentity.name)
                .font(.title2.weight(.semibold))

            Text("Version \(AppBuild.shortVersion)")
                .font(.subheadline)

            Text("Build \(AppBuild.number)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if os(macOS)
enum AboutPresenter {
  private static var panel: NSPanel?

  @MainActor
  static func show() {
    NSApp.activate(ignoringOtherApps: true)

    if panel == nil {
      let aboutPanel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      aboutPanel.title = "About \(AppIdentity.name)"
      aboutPanel.isReleasedWhenClosed = false
      panel = aboutPanel
    }

    guard let panel else { return }
    panel.contentView = NSHostingView(rootView: AboutView())
    panel.center()
    panel.makeKeyAndOrderFront(nil)
  }
}
#endif
