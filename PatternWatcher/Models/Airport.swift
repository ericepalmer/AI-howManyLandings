import Foundation
import CoreLocation

struct Runway: Identifiable, Hashable, Sendable, Codable {
    var id: String { "\(leIdent)-\(heIdent)-\(lengthFt)" }
    var leIdent: String
    var heIdent: String
    var headingTrue: Int
    var lengthFt: Int
    var le: CLLocationCoordinate2D
    var he: CLLocationCoordinate2D

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (le.latitude + he.latitude) / 2,
            longitude: (le.longitude + he.longitude) / 2
        )
    }

    var lengthMeters: Double { Double(lengthFt) * 0.3048 }

    /// Both landing directions for this strip (`headingTrue` is the LE course).
    var approaches: [RunwayApproach] {
        [
            RunwayApproach(
                ident: leIdent,
                headingDeg: Double(headingTrue),
                threshold: le,
                farEnd: he,
                runway: self
            ),
            RunwayApproach(
                ident: heIdent,
                headingDeg: Geo.normalizeHeading(Double(headingTrue) + 180),
                threshold: he,
                farEnd: le,
                runway: self
            ),
        ]
    }

    enum CodingKeys: String, CodingKey {
        case leIdent, heIdent, headingTrue, lengthFt, leLat, leLon, heLat, heLon, leRightTraffic, heRightTraffic
    }

    /// FAA NASR: this landing direction uses right traffic. Default (false) is left.
    var leRightTraffic: Bool
    var heRightTraffic: Bool

    init(
        leIdent: String,
        heIdent: String,
        headingTrue: Int,
        lengthFt: Int,
        le: CLLocationCoordinate2D,
        he: CLLocationCoordinate2D,
        leRightTraffic: Bool = false,
        heRightTraffic: Bool = false
    ) {
        self.leIdent = leIdent
        self.heIdent = heIdent
        self.headingTrue = headingTrue
        self.lengthFt = lengthFt
        self.le = le
        self.he = he
        self.leRightTraffic = leRightTraffic
        self.heRightTraffic = heRightTraffic
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        leIdent = try container.decode(String.self, forKey: .leIdent)
        heIdent = try container.decode(String.self, forKey: .heIdent)
        headingTrue = try container.decode(Int.self, forKey: .headingTrue)
        lengthFt = try container.decode(Int.self, forKey: .lengthFt)
        le = CLLocationCoordinate2D(
            latitude: try container.decode(Double.self, forKey: .leLat),
            longitude: try container.decode(Double.self, forKey: .leLon)
        )
        he = CLLocationCoordinate2D(
            latitude: try container.decode(Double.self, forKey: .heLat),
            longitude: try container.decode(Double.self, forKey: .heLon)
        )
        leRightTraffic = try container.decodeIfPresent(Bool.self, forKey: .leRightTraffic) ?? false
        heRightTraffic = try container.decodeIfPresent(Bool.self, forKey: .heRightTraffic) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(leIdent, forKey: .leIdent)
        try container.encode(heIdent, forKey: .heIdent)
        try container.encode(headingTrue, forKey: .headingTrue)
        try container.encode(lengthFt, forKey: .lengthFt)
        try container.encode(le.latitude, forKey: .leLat)
        try container.encode(le.longitude, forKey: .leLon)
        try container.encode(he.latitude, forKey: .heLat)
        try container.encode(he.longitude, forKey: .heLon)
        try container.encode(leRightTraffic, forKey: .leRightTraffic)
        try container.encode(heRightTraffic, forKey: .heRightTraffic)
    }

    /// Geometric pattern sides to draw for published per-end traffic.
    /// Left traffic on the high-end is the opposite side of the strip from left traffic on the low-end.
    var publishedPatternSides: [TrafficPattern.Side] {
        var sides = Set<TrafficPattern.Side>()
        sides.insert(leRightTraffic ? .right : .left)
        sides.insert(heRightTraffic ? .left : .right)
        return [TrafficPattern.Side.left, .right].filter { sides.contains($0) }
    }

    /// Pilot-relative published traffic for this landing ident (`true` = right traffic).
    func usesRightTraffic(forApproachIdent ident: String) -> Bool {
        if ident.caseInsensitiveCompare(leIdent) == .orderedSame { return leRightTraffic }
        if ident.caseInsensitiveCompare(heIdent) == .orderedSame { return heRightTraffic }
        let direction = RunwayApproach.directionIdent(ident)
        let leDir = RunwayApproach.directionIdent(leIdent)
        let heDir = RunwayApproach.directionIdent(heIdent)
        if direction == leDir, direction != heDir { return leRightTraffic }
        if direction == heDir, direction != leDir { return heRightTraffic }
        return false
    }

    var patternDirectionLine: String {
        "\(leIdent) \(leRightTraffic ? "right" : "left") · \(heIdent) \(heRightTraffic ? "right" : "left")"
    }
}

struct Airport: Identifiable, Hashable, Sendable {
    var id: String { icao }
    var icao: String
    var name: String
    var city: String
    var coordinate: CLLocationCoordinate2D
    var elevationFt: Int
    var runways: [Runway]

    var displayName: String {
        city.isEmpty ? name : "\(name) — \(city)"
    }

    /// Compact published-pattern line, e.g. `Left 13 · Right 31` or `Left traffic`.
    var patternDirectionSummary: String {
        let ends = runways.flatMap { runway in
            [(runway.leIdent, runway.leRightTraffic), (runway.heIdent, runway.heRightTraffic)]
        }
        .filter { !$0.0.isEmpty }
        guard !ends.isEmpty else { return "Left traffic" }
        let lefts = ends.filter { !$0.1 }.map(\.0)
        let rights = ends.filter(\.1).map(\.0)
        if rights.isEmpty { return "Left traffic" }
        if lefts.isEmpty { return "Right traffic" }
        return "Left \(lefts.joined(separator: "/")) · Right \(rights.joined(separator: "/"))"
    }

    func boundingBox(radiusNM: Double = Geo.defaultTrackingRadiusNM) -> Geo.BoundingBox {
        Geo.boundingBox(around: coordinate, radiusNM: radiusNM)
    }
}

extension CLLocationCoordinate2D: @retroactive Equatable {
    public static func == (lhs: CLLocationCoordinate2D, rhs: CLLocationCoordinate2D) -> Bool {
        lhs.latitude == rhs.latitude && lhs.longitude == rhs.longitude
    }
}

extension CLLocationCoordinate2D: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(latitude)
        hasher.combine(longitude)
    }
}
