import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum RecordedADSFilePicker {
    static let allowedExtensions: Set<String> = ["jsonl", "lol", "json", "txt"]

    static func isAllowed(_ url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }

    #if os(macOS)
    @MainActor
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose ADS-B recording"
        panel.message = "Select a .jsonl, .lol, or .json capture file."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        // Do not set allowedContentTypes. Dynamic UTTypes for .jsonl/.lol do not
        // match Launch Services tags, so the panel shows the files but greys them out.
        panel.allowedContentTypes = [.item]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
    #endif

    @MainActor
    static func load(from url: URL, engine: TrackingEngine) throws {
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty, !isAllowed(url) {
            throw ADSRecordingError.unsupportedFormat
        }
        try engine.loadRecordedFile(from: url)
    }
}

struct RecordedADSFileImporter: ViewModifier {
    @Binding var isPresented: Bool
    @Environment(TrackingEngine.self) private var engine
    var onError: (String) -> Void

    func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        content.fileImporter(
            isPresented: $isPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            isPresented = false
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try RecordedADSFilePicker.load(from: url, engine: engine)
                } catch {
                    onError(error.localizedDescription)
                }
            case .failure(let error):
                onError(error.localizedDescription)
            }
        }
        #endif
    }
}
