import CoreLocation
import Foundation

/// Shared adsb.lol / readsb JSON decoding for live fetch and recorded files.
enum ADSBLolDecoder {
    static func decodePoll(from json: [String: Any]) -> (time: Date, snapshots: [AircraftSnapshot]) {
        let nowRaw = JSONValue.double(json["now"]) ?? (Date().timeIntervalSince1970 * 1000)
        let epoch = nowRaw > 1_000_000_000_000 ? nowRaw / 1000 : nowRaw
        let time = Date(timeIntervalSince1970: epoch)
        let rows = (json["ac"] as? [Any]) ?? (json["aircraft"] as? [Any]) ?? []
        let snapshots = rows.compactMap { row -> AircraftSnapshot? in
            guard let row = row as? [String: Any] else { return nil }
            return decodeAircraft(row, pollTime: time)
        }
        return (time, snapshots)
    }

    static func decodeAircraft(_ row: [String: Any], pollTime: Date, ignoreStale: Bool = false) -> AircraftSnapshot? {
        guard let hex = JSONValue.string(row["hex"])?.lowercased() else { return nil }

        let lat = JSONValue.double(row["lat"])
            ?? JSONValue.double((row["lastPosition"] as? [String: Any])?["lat"])
        let lon = JSONValue.double(row["lon"])
            ?? JSONValue.double((row["lastPosition"] as? [String: Any])?["lon"])
        guard let lat, let lon else { return nil }

        let altBaro = row["alt_baro"]
        let onGround = (altBaro as? String)?.lowercased() == "ground"
            || JSONValue.bool(row["ground"]) == true
        let baroFt = onGround ? nil : JSONValue.double(altBaro)
        let geoFt = JSONValue.double(row["alt_geom"])
        let gsKt = JSONValue.double(row["gs"])
        let rateFPM = JSONValue.double(row["baro_rate"]) ?? JSONValue.double(row["geom_rate"])
        let seenPos = JSONValue.double(row["seen_pos"])
        let seen = seenPos ?? JSONValue.double(row["seen"]) ?? 0
        if !ignoreStale, seen > 120 { return nil }

        let timestamp: Date
        if let explicit = JSONValue.double(row["timestamp"]) {
            let epoch = explicit > 1_000_000_000_000 ? explicit / 1000 : explicit
            timestamp = Date(timeIntervalSince1970: epoch)
        } else if seen > 0 {
            timestamp = pollTime.addingTimeInterval(-seen)
        } else {
            timestamp = pollTime
        }

        return AircraftSnapshot(
            icao24: hex,
            callsign: JSONValue.string(row["flight"]),
            originCountry: JSONValue.string(row["originCountry"]) ?? "",
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
