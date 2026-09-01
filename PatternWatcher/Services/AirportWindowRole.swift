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
        switch self {
        case .main:
            guard raw.hasPrefix("pw-airport-") else { return nil }
            return String(raw.dropFirst("pw-airport-".count))
        case .auxiliary:
            guard raw.hasPrefix("pw-aux-") else { return nil }
            return String(raw.dropFirst("pw-aux-".count))
        }
    }

    /// ICAO for a main airport window (`pw-airport-*` or `KPAO — …` title).
    static func icaoFromMainAirportWindow(_ window: NSWindow) -> String? {
        if let id = window.identifier, let icao = main.icao(from: id) {
            return icao
        }
        guard let dashRange = window.title.range(of: " — ") else { return nil }
        let icao = window.title[..<dashRange.lowerBound]
        guard icao.count == 4 else { return nil }
        return String(icao)
    }

    /// ICAO for any airport-tied window (main or supplementary).
    static func icaoFromAirportWindow(_ window: NSWindow) -> String? {
        if let id = window.identifier {
            if let icao = main.icao(from: id) ?? auxiliary.icao(from: id) {
                return icao
            }
        }
        return icaoFromMainAirportWindow(window)
    }
}
#endif
