import Foundation
import CoreLocation

/// One aircraft from a live ADS-B poll, as decoded from the feed (before pattern logic).
struct ADSFeedRow: Identifiable, Sendable, Hashable {
    var id: String { icao24 }
    var icao24: String
    var callsign: String
    var registration: String
    var typeCode: String
    var onGround: Bool
    var altitudeMSLFt: Double?
    var altitudeAGLFt: Double?
    var groundSpeedKt: Double?
    var trackDeg: Double?
    var verticalRateFPM: Double?
    var latitude: Double
    var longitude: Double
    var distanceNM: Double
    var category: String
    var squawk: String
    var timestamp: Date

    init(snapshot: AircraftSnapshot, airport: Airport) {
        icao24 = snapshot.icao24
        callsign = snapshot.callsign?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        registration = snapshot.registration ?? "—"
        typeCode = snapshot.typeCode ?? "—"
        onGround = snapshot.onGround
        altitudeMSLFt = snapshot.altitudeMSLFt
        altitudeAGLFt = snapshot.altitudeAGLFt(airportElevationFt: airport.elevationFt)
        groundSpeedKt = snapshot.groundSpeedKt
        trackDeg = snapshot.trackDeg
        verticalRateFPM = snapshot.verticalRateFPM
        latitude = snapshot.coordinate.latitude
        longitude = snapshot.coordinate.longitude
        distanceNM = Geo.distanceNM(snapshot.coordinate, airport.coordinate)
        category = snapshot.category.displayName
        squawk = snapshot.squawk ?? "—"
        timestamp = snapshot.timestamp
    }

    var logLine: String {
        let gnd = onGround ? "Y" : "N"
        let msl = altitudeMSLFt.map { String(Int($0.rounded())) } ?? "—"
        let agl = altitudeAGLFt.map { String(Int($0.rounded())) } ?? "—"
        let gs = groundSpeedKt.map { String(Int($0.rounded())) } ?? "—"
        let hdg = trackDeg.map { String(Int($0.rounded())) } ?? "—"
        let vs = verticalRateFPM.map { String(Int($0.rounded())) } ?? "—"
        let nm = String(format: "%.2f", distanceNM)
        let lat = String(format: "%.5f", latitude)
        let lon = String(format: "%.5f", longitude)
        return "\(icao24)  \(callsign.prefix(8))  \(typeCode.prefix(5))  gnd=\(gnd)  msl=\(msl)  agl=\(agl)  gs=\(gs)  hdg=\(hdg)  vs=\(vs)  \(nm)NM  \(lat) \(lon)"
    }
}

struct ADSFeedPoll: Identifiable, Sendable {
    var id: UUID
    var receivedAt: Date
    var sourceName: String
    var airportICAO: String
    var aircraft: [ADSFeedRow]
}
