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
        let runways = (try? JSONDecoder().decode([Runway].self, from: runwaysJSON)) ?? []
        return Airport(
            icao: icao,
            name: name,
            city: city,
            coordinate: .init(latitude: latitude, longitude: longitude),
            elevationFt: elevationFt,
            runways: runways
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

    init(
        airportICAO: String,
        aircraftICAO24: String,
        tailNumber: String,
        aircraftType: String,
        kind: TrafficEventKind,
        timestamp: Date,
        altitudeAGLFt: Double?,
        groundSpeedKt: Double?
    ) {
        eventID = UUID()
        self.airportICAO = airportICAO
        self.aircraftICAO24 = aircraftICAO24
        self.tailNumber = tailNumber
        self.aircraftType = aircraftType
        kindRaw = kind.rawValue
        self.timestamp = timestamp
        self.altitudeAGLFt = altitudeAGLFt
        self.groundSpeedKt = groundSpeedKt
    }

    var kind: TrafficEventKind {
        TrafficEventKind(rawValue: kindRaw) ?? .fullStop
    }
}
