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

    enum CodingKeys: String, CodingKey {
        case leIdent, heIdent, headingTrue, lengthFt, leLat, leLon, heLat, heLon
    }

    init(leIdent: String, heIdent: String, headingTrue: Int, lengthFt: Int, le: CLLocationCoordinate2D, he: CLLocationCoordinate2D) {
        self.leIdent = leIdent
        self.heIdent = heIdent
        self.headingTrue = headingTrue
        self.lengthFt = lengthFt
        self.le = le
        self.he = he
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

    func boundingBox(radiusNM: Double = Geo.trackingRadiusNM) -> Geo.BoundingBox {
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
