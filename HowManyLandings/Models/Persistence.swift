import Foundation
import SwiftData

@Model
final class StoredAirport {
    @Attribute(.unique) var icao: String
    var name: String
    var city: String
    var latitude: Double
    var longitude: Double
    var elevationFt: Int
    var runwaysJSON: Data
    var addedAt: Date

    init(airport: Airport) {
        icao = airport.icao
        name = airport.name
        city = airport.city
        latitude = airport.coordinate.latitude
        longitude = airport.coordinate.longitude
        elevationFt = airport.elevationFt
        runwaysJSON = (try? JSONEncoder().encode(airport.runways)) ?? Data()
        addedAt = Date()
    }

    var asAirport: Airport {
        let decoded = (try? JSONDecoder().decode([Runway].self, from: runwaysJSON)) ?? []
        return Airport(
            icao: icao,
            name: name,
            city: city,
            coordinate: .init(latitude: latitude, longitude: longitude),
            elevationFt: elevationFt,
            runways: AirportCatalog.shared.overlayPublishedPattern(on: decoded, icao: icao)
        )
    }
}

@Model
final class StoredTrafficEvent {
    @Attribute(.unique) var eventID: UUID
    var airportICAO: String
    var aircraftICAO24: String
    var tailNumber: String
    var aircraftType: String
    var kindRaw: String
    var timestamp: Date
    var altitudeAGLFt: Double?
    var groundSpeedKt: Double?
    /// Encoded `[TrackPoint]` captured when the event was logged.
    var trackJSON: Data?

    init(
        eventID: UUID = UUID(),
        airportICAO: String,
        aircraftICAO24: String,
        tailNumber: String,
        aircraftType: String,
        kind: TrafficEventKind,
        timestamp: Date,
        altitudeAGLFt: Double?,
        groundSpeedKt: Double?,
        track: [TrackPoint] = []
    ) {
        self.eventID = eventID
        self.airportICAO = airportICAO
        self.aircraftICAO24 = aircraftICAO24
        self.tailNumber = tailNumber
        self.aircraftType = aircraftType
        kindRaw = kind.rawValue
        self.timestamp = timestamp
        self.altitudeAGLFt = altitudeAGLFt
        self.groundSpeedKt = groundSpeedKt
        trackJSON = Self.encodeTrack(track)
    }

    var kind: TrafficEventKind {
        get { TrafficEventKind(rawValue: kindRaw) ?? .fullStop }
        set { kindRaw = newValue.rawValue }
    }

    var track: [TrackPoint] {
        guard let trackJSON,
              let decoded = try? JSONDecoder().decode([TrackPoint].self, from: trackJSON) else {
            return []
        }
        return decoded
    }

    var hasSavedTrack: Bool { !(trackJSON?.isEmpty ?? true) }

    static func encodeTrack(_ points: [TrackPoint]) -> Data? {
        let copy = TrackPoint.detachedCopy(points)
        guard !copy.isEmpty else { return nil }
        return try? JSONEncoder().encode(copy)
    }
}
