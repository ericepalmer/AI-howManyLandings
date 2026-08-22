import Foundation
import CoreLocation

/// Community ADS-B snapshot API (readsb / adsb.lol). Used when OpenSky is unreachable.
actor ADSBLolClient {
    static let shared = ADSBLolClient()

    private let session: URLSession

    init(session: URLSession = ADSBLolClient.makeSession()) {
        self.session = session
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 15
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "HowManyLandings/1.0 (aviation traffic monitor)",
        ]
        return URLSession(configuration: config)
    }

    func fetchStates(center: CLLocationCoordinate2D, radiusNM: Double) async throws -> OpenSkyClient.FetchResult {
        let lat = String(format: "%.5f", center.latitude)
        let lon = String(format: "%.5f", center.longitude)
        let dist = String(format: "%.1f", max(1, radiusNM))
        let endpoints = [
            "https://api.adsb.lol/v2/lat/\(lat)/lon/\(lon)/dist/\(dist)",
            "https://opendata.adsb.fi/api/v2/lat/\(lat)/lon/\(lon)/dist/\(dist)",
        ]

        var lastError: Error = OpenSkyError.invalidURL
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { throw OpenSkyError.invalidResponse }
                guard (200..<300).contains(http.statusCode) else { throw OpenSkyError.httpStatus(http.statusCode) }
                let decoded = try decode(data)
                return OpenSkyClient.FetchResult(
                    snapshots: decoded.snapshots,
                    serverTime: decoded.time,
                    creditsRemaining: nil,
                    retryAfter: nil
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func decode(_ data: Data) throws -> (time: Date, snapshots: [AircraftSnapshot]) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenSkyError.invalidResponse
        }
        let nowRaw = JSONValue.double(json["now"]) ?? (Date().timeIntervalSince1970 * 1000)
        let epoch = nowRaw > 1_000_000_000_000 ? nowRaw / 1000 : nowRaw
        let time = Date(timeIntervalSince1970: epoch)
        let rows = (json["ac"] as? [Any]) ?? (json["aircraft"] as? [Any]) ?? []
        let snapshots = rows.compactMap { row -> AircraftSnapshot? in
            guard let row = row as? [String: Any] else { return nil }
            return decodeAircraft(row, time: time)
        }
        return (time, snapshots)
    }

    private func decodeAircraft(_ row: [String: Any], time: Date) -> AircraftSnapshot? {
        guard let hex = JSONValue.string(row["hex"])?.lowercased() else { return nil }
        guard let lat = JSONValue.double(row["lat"]), let lon = JSONValue.double(row["lon"]) else { return nil }

        let altBaro = row["alt_baro"]
        let onGround = (altBaro as? String)?.lowercased() == "ground"
            || JSONValue.bool(row["ground"]) == true
        let baroFt = onGround ? nil : JSONValue.double(altBaro)
        let geoFt = JSONValue.double(row["alt_geom"])
        let gsKt = JSONValue.double(row["gs"])
        let rateFPM = JSONValue.double(row["baro_rate"]) ?? JSONValue.double(row["geom_rate"])
        let seen = JSONValue.double(row["seen"]) ?? 0
        let timestamp = time.addingTimeInterval(-seen)

        return AircraftSnapshot(
            icao24: hex,
            callsign: JSONValue.string(row["flight"]),
            originCountry: "",
            coordinate: .init(latitude: lat, longitude: lon),
            baroAltitudeMeters: baroFt.map { $0 / Geo.feetPerMeter },
            geoAltitudeMeters: geoFt.map { $0 / Geo.feetPerMeter },
            onGround: onGround,
            velocityMPS: gsKt.map { $0 / Geo.knotsPerMetersPerSecond },
            trackDeg: JSONValue.double(row["track"]) ?? JSONValue.double(row["true_heading"]),
            verticalRateMPS: rateFPM.map { $0 / (Geo.feetPerMeter * 60) },
            squawk: JSONValue.string(row["squawk"]),
            category: AircraftCategory.fromADSBlol(JSONValue.string(row["category"])),
            timestamp: timestamp,
            registration: JSONValue.string(row["r"]),
            typeCode: JSONValue.string(row["t"])
        )
    }
}

enum TrafficFeedSource: String, CaseIterable, Identifiable {
    case automatic
    case adsbLol
    case opensky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic (recommended)"
        case .adsbLol: return "Live ADS-B (adsb.lol)"
        case .opensky: return "OpenSky Network"
        }
    }
}

enum JSONValue {
    static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        return nil
    }
}

extension AircraftCategory {
    static func fromADSBlol(_ raw: String?) -> AircraftCategory {
        switch raw?.uppercased() {
        case "A1": return .light
        case "A2": return .small
        case "A3": return .large
        case "A4": return .highVortexLarge
        case "A5": return .heavy
        case "A6": return .highPerformance
        case "A7": return .rotorcraft
        case "B1": return .glider
        case "B2": return .lighterThanAir
        case "B3": return .parachutist
        case "B4": return .ultralight
        case "B6": return .uav
        case "B7": return .space
        case "C1": return .emergencyVehicle
        case "C2": return .serviceVehicle
        case "C3": return .pointObstacle
        default: return .unknown
        }
    }
}
