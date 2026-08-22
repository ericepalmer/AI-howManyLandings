import Foundation

actor OpenSkyClient {
    static let shared = OpenSkyClient()

    private let session: URLSession
    private var accessToken: String?
    private var tokenExpiresAt: Date = .distantPast

    private let tokenURL = URL(string: "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token")!

    init(session: URLSession = OpenSkyClient.makeSession()) {
        self.session = session
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": "HowManyLandings/1.0 (aviation traffic monitor)",
        ]
        return URLSession(configuration: config)
    }

    struct FetchResult: Sendable {
        var snapshots: [AircraftSnapshot]
        var serverTime: Date
        var creditsRemaining: Int?
        var retryAfter: TimeInterval?
    }

    func fetchStates(bbox: Geo.BoundingBox, clientID: String, clientSecret: String) async throws -> FetchResult {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "opensky-network.org"
        components.path = "/api/states/all"
        components.queryItems = [
            URLQueryItem(name: "lamin", value: String(bbox.lamin)),
            URLQueryItem(name: "lomin", value: String(bbox.lomin)),
            URLQueryItem(name: "lamax", value: String(bbox.lamax)),
            URLQueryItem(name: "lomax", value: String(bbox.lomax)),
        ]
        guard let url = components.url else { throw OpenSkyError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let token = try await validToken(clientID: clientID, clientSecret: clientSecret) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenSkyError.invalidResponse }

        let remaining = http.value(forHTTPHeaderField: "X-Rate-Limit-Remaining").flatMap(Int.init)
        let retryAfter = http.value(forHTTPHeaderField: "X-Rate-Limit-Retry-After-Seconds").flatMap(Double.init)

        if http.statusCode == 401 {
            accessToken = nil
            tokenExpiresAt = .distantPast
            throw OpenSkyError.unauthorized
        }
        if http.statusCode == 429 {
            throw OpenSkyError.rateLimited(retryAfter: retryAfter ?? 30)
        }
        if http.statusCode == 404 {
            return FetchResult(snapshots: [], serverTime: Date(), creditsRemaining: remaining, retryAfter: retryAfter)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenSkyError.httpStatus(http.statusCode)
        }

        let decoded = try OpenSkyDecoder.decodeStates(data)
        return FetchResult(
            snapshots: decoded.snapshots,
            serverTime: decoded.time,
            creditsRemaining: remaining,
            retryAfter: retryAfter
        )
    }

    private func validToken(clientID: String, clientSecret: String) async throws -> String? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !secret.isEmpty else { return nil }

        if let accessToken, Date() < tokenExpiresAt {
            return accessToken
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "grant_type": "client_credentials",
            "client_id": id,
            "client_secret": secret,
        ]
        .map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value)"
        }
        .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenSkyError.authFailed
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["access_token"] as? String
        else {
            throw OpenSkyError.authFailed
        }
        let expires = (json["expires_in"] as? Int) ?? 1800
        accessToken = token
        tokenExpiresAt = Date().addingTimeInterval(TimeInterval(expires - 30))
        return token
    }
}

enum OpenSkyError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case authFailed
    case rateLimited(retryAfter: TimeInterval)
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Could not build the OpenSky request."
        case .invalidResponse: return "OpenSky returned an invalid response."
        case .unauthorized: return "OpenSky credentials were rejected. Check client ID and secret."
        case .authFailed: return "Could not sign in to OpenSky. Check client ID and secret."
        case .rateLimited(let retryAfter):
            let minutes = max(1, Int((retryAfter / 60).rounded(.up)))
            return "OpenSky rate limit reached. Retrying in about \(minutes) min."
        case .httpStatus(let code): return "OpenSky HTTP \(code)."
        }
    }
}

enum OpenSkyDecoder {
    static func decodeStates(_ data: Data) throws -> (time: Date, snapshots: [AircraftSnapshot]) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenSkyError.invalidResponse
        }
        let epoch = json["time"] as? Double ?? (json["time"] as? Int).map(Double.init) ?? Date().timeIntervalSince1970
        let time = Date(timeIntervalSince1970: epoch)
        if json["states"] is NSNull {
            return (time, [])
        }
        guard let rows = json["states"] as? [Any] else {
            return (time, [])
        }
        let snapshots = rows.compactMap { row -> AircraftSnapshot? in
            guard let row = row as? [Any] else { return nil }
            return decodeSnapshot(row, fallbackTime: time)
        }
        return (time, snapshots)
    }

    private static func decodeSnapshot(_ row: [Any], fallbackTime: Date) -> AircraftSnapshot? {
        guard row.count >= 17, let icao24 = string(row[0])?.lowercased() else { return nil }
        let lon = double(row[safe: 5])
        let lat = double(row[safe: 6])
        guard let lon, let lat else { return nil }

        let lastContact = double(row[safe: 4]).map { Date(timeIntervalSince1970: $0) } ?? fallbackTime
        return AircraftSnapshot(
            icao24: icao24,
            callsign: string(row[safe: 1]),
            originCountry: string(row[safe: 2]) ?? "",
            coordinate: .init(latitude: lat, longitude: lon),
            baroAltitudeMeters: double(row[safe: 7]),
            geoAltitudeMeters: double(row[safe: 13]),
            onGround: bool(row[safe: 8]) ?? false,
            velocityMPS: double(row[safe: 9]),
            trackDeg: double(row[safe: 10]),
            verticalRateMPS: double(row[safe: 11]),
            squawk: string(row[safe: 14]),
            category: AircraftCategory(rawValue: int(row[safe: 17]) ?? 0) ?? .unknown,
            timestamp: lastContact,
            registration: nil,
            typeCode: nil
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let b = value as? Bool { return b }
        if let i = value as? Int { return i != 0 }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
