#if os(macOS)
import AppKit

enum AirportWindowRole {
    case main
    case auxiliary

    func windowIdentifier(icao: String) -> NSUserInterfaceItemIdentifier {
        switch self {
        case .main:
            NSUserInterfaceItemIdentifier("pw-airport-\(icao)")
        case .auxiliary:
            NSUserInterfaceItemIdentifier("pw-aux-\(icao)")
        }
    }

    func icao(from identifier: NSUserInterfaceItemIdentifier) -> String? {
        let raw = identifier.rawValue
        if raw.hasPrefix("pw-airport-") {
            return String(raw.dropFirst("pw-airport-".count))
        }
        if raw.hasPrefix("pw-aux-") {
            return String(raw.dropFirst("pw-aux-".count))
        }
        return nil
    }

    /// Resolve ICAO from our identifier or the standard airport window title.
    static func icaoFromMainWindow(_ window: NSWindow) -> String? {
        if let id = window.identifier, let icao = main.icao(from: id) {
            return icao
        }
        guard let dashRange = window.title.range(of: " — ") else { return nil }
        let icao = window.title[..<dashRange.lowerBound]
        guard icao.count == 4 else { return nil }
        return String(icao)
    }
}
#endif
