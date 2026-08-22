import CoreLocation
import Foundation

enum AircraftCategory: Int, Sendable, Codable, Hashable {
    case unknown = 0
    case noInfo = 1
    case light = 2
    case small = 3
    case large = 4
    case highVortexLarge = 5
    case heavy = 6
    case highPerformance = 7
    case rotorcraft = 8
    case glider = 9
    case lighterThanAir = 10
    case parachutist = 11
    case ultralight = 12
    case reserved = 13
    case uav = 14
    case space = 15
    case emergencyVehicle = 16
    case serviceVehicle = 17
    case pointObstacle = 18
    case clusterObstacle = 19
    case lineObstacle = 20

    var displayName: String {
        switch self {
        case .unknown, .noInfo, .reserved: return "Unknown"
        case .light: return "Light"
        case .small: return "Small"
        case .large: return "Large"
        case .highVortexLarge: return "High Vortex"
        case .heavy: return "Heavy"
        case .highPerformance: return "High Performance"
        case .rotorcraft: return "Rotorcraft"
        case .glider: return "Glider"
        case .lighterThanAir: return "Lighter-than-air"
        case .parachutist: return "Parachutist"
        case .ultralight: return "Ultralight"
        case .uav: return "UAV"
        case .space: return "Space"
        case .emergencyVehicle: return "Emergency Vehicle"
        case .serviceVehicle: return "Service Vehicle"
        case .pointObstacle, .clusterObstacle, .lineObstacle: return "Obstacle"
        }
    }

    var isAircraft: Bool {
        switch self {
        case .emergencyVehicle, .serviceVehicle, .pointObstacle, .clusterObstacle, .lineObstacle, .parachutist:
            return false
        default:
            return true
        }
    }
}

struct AircraftSnapshot: Identifiable, Hashable, Sendable {
    var id: String { icao24 }
    var icao24: String
    var callsign: String?
    var originCountry: String
    var coordinate: CLLocationCoordinate2D
    var baroAltitudeMeters: Double?
    var geoAltitudeMeters: Double?
    var onGround: Bool
    var velocityMPS: Double?
    var trackDeg: Double?
    var verticalRateMPS: Double?
    var squawk: String?
    var category: AircraftCategory
    var timestamp: Date
    var registration: String?
    var typeCode: String?

    var tailNumber: String {
        AircraftIdentity.registrationTail(icao24: icao24, registration: registration)
    }

    var displayLabel: String {
        AircraftIdentity.displayLabel(callsign: callsign, registration: registration, icao24: icao24)
    }

    var typeDisplay: String {
        if let typeCode, !typeCode.isEmpty { return typeCode }
        return category.displayName
    }

    var groundSpeedKt: Double? {
        velocityMPS.map { Geo.knots(fromMetersPerSecond: $0) }
    }

    var altitudeMSLFt: Double? {
        if let geo = geoAltitudeMeters { return Geo.feet(fromMeters: geo) }
        if let baro = baroAltitudeMeters { return Geo.feet(fromMeters: baro) }
        return nil
    }

    func altitudeAGLFt(airportElevationFt: Int) -> Double? {
        if onGround { return 0 }
        guard let msl = altitudeMSLFt else { return nil }
        return msl - Double(airportElevationFt)
    }

    var verticalRateFPM: Double? {
        verticalRateMPS.map { $0 * Geo.feetPerMeter * 60 }
    }
}

struct TrackPoint: Hashable, Sendable {
    var timestamp: Date
    var coordinate: CLLocationCoordinate2D
    var altitudeAGLFt: Double?
    var onGround: Bool
    var groundSpeedKt: Double?
    var trackDeg: Double?
    var verticalRateFPM: Double?
}

enum TrafficEventKind: String, Codable, CaseIterable, Sendable {
    case touchAndGo
    case fullStop
    case takeoff

    var title: String {
        switch self {
        case .touchAndGo: return "Touch-and-go"
        case .fullStop: return "Full-stop landing"
        case .takeoff: return "Takeoff"
        }
    }

    var countsAsLanding: Bool {
        self == .touchAndGo || self == .fullStop
    }

    var systemImage: String {
        switch self {
        case .touchAndGo: return "arrow.uturn.up"
        case .fullStop: return "airplane.arrival"
        case .takeoff: return "airplane.departure"
        }
    }
}
