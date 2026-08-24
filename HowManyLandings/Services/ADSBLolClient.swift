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
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw OpenSkyError.invalidResponse
                }
                let decoded = ADSBLolDecoder.decodePoll(from: json)
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
}

enum TrafficFeedSource: String, CaseIterable, Identifiable {
    case automatic
    case adsbLol
    case opensky
    case recorded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic (recommended)"
        case .adsbLol: return "Live ADS-B (adsb.lol)"
        case .opensky: return "OpenSky Network"
        case .recorded: return "Recorded file (debug)"
        }
    }

    /// Live network sources shown in Settings; recorded is activated by loading a file.
    static var liveCases: [TrafficFeedSource] {
        [.automatic, .adsbLol, .opensky]
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
