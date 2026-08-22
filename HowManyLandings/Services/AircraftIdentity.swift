import Foundation

enum AircraftIdentity {
    /// Registration or derived tail — never the ADS-B callsign/flight ID.
    static func tailNumber(icao24: String, registration: String? = nil, callsign: String? = nil) -> String {
        registrationTail(icao24: icao24, registration: registration)
    }

    static func registrationTail(icao24: String, registration: String? = nil) -> String {
        if let registration {
            let trimmed = registration.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed.uppercased() }
        }
        if let nNumber = nNumber(fromICAO24: icao24) {
            return nNumber
        }
        return icao24.uppercased()
    }

    /// Callsign first when present, then the tail/registration (e.g. `SWA1234 N567CD`).
    static func displayLabel(callsign: String?, registration: String?, icao24: String) -> String {
        let tail = registrationTail(icao24: icao24, registration: registration)
        if let callsign, let cleaned = cleanedCallsign(callsign), cleaned != tail {
            return "\(cleaned) \(tail)"
        }
        return tail
    }

    static func cleanedCallsign(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("N"), trimmed.count >= 2, trimmed.count <= 6 {
            let rest = trimmed.dropFirst()
            if rest.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return trimmed
            }
        }
        return trimmed
    }

    /// FAA ICAO24 ↔ N-number mapping for addresses in A00001...ADF7C7.
    static func nNumber(fromICAO24 hex: String) -> String? {
        guard let value = Int(hex, radix: 16) else { return nil }
        let firstUS = 0xA00001
        let lastUS = 0xADF7C7
        guard value >= firstUS, value <= lastUS else { return nil }

        var n = value - firstUS
        var result = "N"

        let digit1 = n / 101_711
        n %= 101_711
        if digit1 > 0 { result.append(String(digit1)) }

        let digit2 = n / 10_111
        n %= 10_111
        if digit2 > 0 || result.count > 1 { result.append(String(digit2)) }

        let digit3 = n / 951
        n %= 951
        if digit3 > 0 || result.count > 1 { result.append(String(digit3)) }

        let digit4 = n / 35
        n %= 35
        if digit4 > 0 || result.count > 1 { result.append(String(digit4)) }

        if n > 0 {
            if n < 25 {
                result.append(letter(n))
            } else {
                n -= 25
                let first = n / 24
                let second = n % 24
                result.append(letter(first + 1))
                result.append(letter(second + 1))
            }
        }

        return result
    }

    private static func letter(_ index: Int) -> Character {
        // ICAO mapping skips I and O.
        let letters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let clamped = min(max(index, 1), letters.count) - 1
        return letters[clamped]
    }
}
