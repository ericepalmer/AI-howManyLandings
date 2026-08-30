import Foundation

struct METARObservation: Sendable, Equatable {
    var station: String
    var name: String?
    var raw: String
    var observedAt: Date?
    var flightCategory: String?
    var wind: String?
    var visibility: String?
    var weather: String?
    var clouds: String?
    var temperature: String?
    var altimeter: String?
}

enum METARError: LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case noObservation(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not build the METAR request."
        case .httpStatus(let code): return "METAR service HTTP \(code)."
        case .noObservation(let id): return "No current METAR for \(id)."
        case .invalidResponse: return "METAR service returned an invalid response."
        }
    }
}

actor METARClient {
    static let shared = METARClient()

    private let session: URLSession

    init(session: URLSession = METARClient.makeSession()) {
        self.session = session
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": AppIdentity.userAgent,
        ]
        return URLSession(configuration: config)
    }

    func fetch(station: String) async throws -> METARObservation {
        let id = station.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !id.isEmpty else { throw METARError.invalidURL }

        var components = URLComponents(string: "https://aviationweather.gov/api/data/metar")
        components?.queryItems = [
            URLQueryItem(name: "ids", value: id),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "hours", value: "2"),
        ]
        guard let url = components?.url else { throw METARError.invalidURL }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw METARError.invalidResponse }
        if http.statusCode == 204 || data.isEmpty {
            throw METARError.noObservation(id)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw METARError.httpStatus(http.statusCode)
        }

        let json = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]
        if let array = json as? [[String: Any]] {
            rows = array
        } else if let dict = json as? [String: Any],
                  let array = dict["data"] as? [[String: Any]] {
            rows = array
        } else {
            throw METARError.invalidResponse
        }
        guard let row = rows.first else { throw METARError.noObservation(id) }
        return Self.decode(row, fallbackStation: id)
    }

    private static func decode(_ row: [String: Any], fallbackStation: String) -> METARObservation {
        let raw = string(row["rawOb"]) ?? string(row["raw"]) ?? ""
        let obsTime: Date?
        if let epoch = number(row["obsTime"]) {
            obsTime = Date(timeIntervalSince1970: epoch)
        } else {
            obsTime = nil
        }

        let temp = number(row["temp"])
        let dew = number(row["dewp"])
        let temperature: String?
        if let temp {
            if let dew {
                temperature = "\(formatTemp(temp)) / \(formatTemp(dew))"
            } else {
                temperature = formatTemp(temp)
            }
        } else {
            temperature = nil
        }

        let altimHPa = number(row["altim"])
        let altimeter: String?
        if let altimHPa {
            let inHg = altimHPa / 33.8639
            altimeter = String(format: "%.2f inHg (%.0f hPa)", inHg, altimHPa)
        } else {
            altimeter = nil
        }

        return METARObservation(
            station: string(row["icaoId"]) ?? fallbackStation,
            name: string(row["name"]),
            raw: raw,
            observedAt: obsTime,
            flightCategory: string(row["fltCat"]),
            wind: windText(row),
            visibility: visibilityText(row["visib"]),
            weather: string(row["wxString"]),
            clouds: cloudsText(row["clouds"]),
            temperature: temperature,
            altimeter: altimeter
        )
    }

    private static func windText(_ row: [String: Any]) -> String? {
        let speed = int(row["wspd"])
        let gust = int(row["wgst"])
        let dirRaw = row["wdir"]
        let dir: String?
        if let s = dirRaw as? String, !s.isEmpty {
            dir = s.uppercased()
        } else if let n = number(dirRaw) {
            dir = String(format: "%03.0f", n)
        } else {
            dir = nil
        }
        guard speed != nil || dir != nil else { return nil }
        if dir == "VRB" || dir == "0" {
            if let speed, let gust {
                return "Variable \(speed)G\(gust) kt"
            }
            if let speed { return "Variable \(speed) kt" }
        }
        if let dir, let speed, let gust {
            return "\(dir)° at \(speed)G\(gust) kt"
        }
        if let dir, let speed {
            return "\(dir)° at \(speed) kt"
        }
        if let speed { return "\(speed) kt" }
        return dir.map { "\($0)°" }
    }

    private static func visibilityText(_ value: Any?) -> String? {
        if let s = string(value) { return s.hasSuffix("SM") ? s : "\(s) SM" }
        if let n = number(value) { return String(format: n == n.rounded() ? "%.0f SM" : "%.1f SM", n) }
        return nil
    }

    private static func cloudsText(_ value: Any?) -> String? {
        guard let layers = value as? [[String: Any]], !layers.isEmpty else { return nil }
        let parts = layers.compactMap { layer -> String? in
            guard let cover = string(layer["cover"]) else { return nil }
            if cover == "CLR" || cover == "CAVOK" { return cover }
            if let base = int(layer["base"]) {
                return "\(cover) \(base.formatted()) ft"
            }
            return cover
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatTemp(_ celsius: Double) -> String {
        let f = celsius * 9 / 5 + 32
        return String(format: "%.0f°C (%.0f°F)", celsius, f)
    }

    private static func string(_ value: Any?) -> String? {
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d.rounded()) }
        if let s = value as? String { return Int(s) }
        return nil
    }
}
