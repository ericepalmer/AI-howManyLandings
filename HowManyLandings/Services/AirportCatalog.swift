import Foundation

final class AirportCatalog: Sendable {
    static let shared = AirportCatalog()

    private let byICAO: [String: Airport]
    private let aliases: [String: String]
    private let all: [Airport]

    var count: Int { all.count }

    private init() {
        guard
            let url = Bundle.main.url(forResource: "Airports", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = payload["airports"] as? [[Any]]
        else {
            byICAO = [:]
            aliases = [:]
            all = []
            return
        }

        var map: [String: Airport] = [:]
        map.reserveCapacity(rows.count)
        for row in rows {
            guard let airport = AirportCatalog.decodeAirport(row) else { continue }
            map[airport.icao] = airport
        }

        var aliasMap: [String: String] = [:]
        if let pairs = payload["aliases"] as? [[Any]] {
            for pair in pairs {
                guard pair.count >= 2,
                      let from = pair[0] as? String,
                      let to = pair[1] as? String
                else { continue }
                aliasMap[from.uppercased()] = to.uppercased()
            }
        }

        byICAO = map
        aliases = aliasMap
        all = map.values.sorted { $0.icao < $1.icao }
    }

    func airport(code raw: String) -> Airport? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return nil }
        if code.count == 3, let airport = byICAO["K\(code)"] { return airport }
        if let airport = byICAO[code] { return airport }
        if let mapped = aliases[code], let airport = byICAO[mapped] { return airport }
        return nil
    }

    /// Overlay FAA-published left/right flags from the bundled catalog.
    /// Stored airports added before this data existed still decode as left-only.
    func overlayPublishedPattern(on runways: [Runway], icao: String) -> [Runway] {
        guard let catalog = airport(code: icao)?.runways, !catalog.isEmpty else { return runways }
        return runways.map { runway in
            guard let match = catalog.first(where: {
                $0.leIdent == runway.leIdent && $0.heIdent == runway.heIdent
            }) else { return runway }
            var copy = runway
            copy.leRightTraffic = match.leRightTraffic
            copy.heRightTraffic = match.heRightTraffic
            return copy
        }
    }

    func search(_ query: String, limit: Int = 40) -> [Airport] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let upper = q.uppercased()
        var seen = Set<String>()
        var results: [Airport] = []

        func append(_ airport: Airport?) {
            guard let airport, seen.insert(airport.icao).inserted else { return }
            results.append(airport)
        }

        append(airport(code: upper))
        if results.count >= limit { return results }

        for airport in all where airport.icao.hasPrefix(upper) {
            append(airport)
            if results.count >= limit { return results }
        }
        for (alias, primary) in aliases where alias.hasPrefix(upper) {
            append(byICAO[primary])
            if results.count >= limit { return results }
        }

        for airport in all {
            if airport.name.localizedCaseInsensitiveContains(q) || airport.city.localizedCaseInsensitiveContains(q) {
                append(airport)
                if results.count >= limit { return results }
            }
        }
        return results
    }

    private static func decodeAirport(_ row: [Any]) -> Airport? {
        guard row.count >= 7,
              let icao = row[0] as? String,
              let name = row[1] as? String,
              let lat = double(row[3]),
              let lon = double(row[4])
        else { return nil }

        let city = row[2] as? String ?? ""
        let elev = int(row[5]) ?? 0
        var runways: [Runway] = []
        if let rwRows = row[6] as? [[Any]] {
            for rw in rwRows {
                guard rw.count >= 8,
                      let hdg = int(rw[2]),
                      let len = int(rw[3]),
                      let leLat = double(rw[4]),
                      let leLon = double(rw[5]),
                      let heLat = double(rw[6]),
                      let heLon = double(rw[7])
                else { continue }
                runways.append(
                    Runway(
                        leIdent: rw[0] as? String ?? "",
                        heIdent: rw[1] as? String ?? "",
                        headingTrue: hdg,
                        lengthFt: len,
                        le: .init(latitude: leLat, longitude: leLon),
                        he: .init(latitude: heLat, longitude: heLon),
                        leRightTraffic: rw.count > 8 ? (int(rw[8]) ?? 0) != 0 : false,
                        heRightTraffic: rw.count > 9 ? (int(rw[9]) ?? 0) != 0 : false
                    )
                )
            }
        }

        return Airport(
            icao: icao,
            name: name,
            city: city,
            coordinate: .init(latitude: lat, longitude: lon),
            elevationFt: elev,
            runways: runways
        )
    }

    private static func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d.rounded()) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }
}
