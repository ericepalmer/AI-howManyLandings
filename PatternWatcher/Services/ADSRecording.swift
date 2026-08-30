import Foundation

struct ADSRecordedPoll: Sendable {
    var time: Date
    var snapshots: [AircraftSnapshot]
}

struct ADSRecordingManifest: Sendable {
    var fileName: String
    var format: String
    var suggestedAirportICAO: String?
    var suggestedElevationFt: Int?
    var polls: [ADSRecordedPoll]
}

enum ADSRecordingError: LocalizedError {
    case unreadableFile
    case unsupportedFormat
    case noFileLoaded
    case endOfRecording

    var errorDescription: String? {
        switch self {
        case .unreadableFile: return "Could not read the ADS-B recording file."
        case .unsupportedFormat: return "Unsupported recording format. Use adsb.lol JSON, JSONL, OpenSky JSON, or a track-dump JSON export."
        case .noFileLoaded: return "No ADS-B recording is loaded. Choose a file in Settings → Recorded ADS-B."
        case .endOfRecording: return "End of recording."
        }
    }
}

enum ADSRecordingLoader {
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func load(data: Data, fileName: String) throws -> ADSRecordingManifest {
        let trimmed = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { throw ADSRecordingError.unreadableFile }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let json = try? JSONSerialization.jsonObject(with: data) {
                if let manifest = tryParseJSONObject(json, fileName: fileName) {
                    return manifest
                }
            }
        }

        let lines = trimmed.split(whereSeparator: \.isNewline).map(String.init)
        if lines.count > 1, lines.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }) {
            var polls: [ADSRecordedPoll] = []
            for line in lines {
                let lineData = Data(line.utf8)
                guard let obj = try? JSONSerialization.jsonObject(with: lineData) else { continue }
                if let poll = parsePollObject(obj) {
                    polls.append(poll)
                }
            }
            if !polls.isEmpty {
                return ADSRecordingManifest(
                    fileName: fileName,
                    format: "JSONL (\(polls.count) polls)",
                    suggestedAirportICAO: nil,
                    suggestedElevationFt: nil,
                    polls: sortPolls(polls)
                )
            }
        }

        if let manifest = tryParseTrackDumpText(trimmed, fileName: fileName) {
            return manifest
        }

        throw ADSRecordingError.unsupportedFormat
    }

    private static func tryParseJSONObject(_ json: Any, fileName: String) -> ADSRecordingManifest? {
        if let array = json as? [Any] {
            if let polls = parsePollArray(array), !polls.isEmpty {
                return ADSRecordingManifest(
                    fileName: fileName,
                    format: "JSON array (\(polls.count) polls)",
                    suggestedAirportICAO: nil,
                    suggestedElevationFt: nil,
                    polls: sortPolls(polls)
                )
            }
        }

        if let dict = json as? [String: Any] {
            if let poll = parsePollObject(dict) {
                return ADSRecordingManifest(
                    fileName: fileName,
                    format: "adsb.lol poll",
                    suggestedAirportICAO: nil,
                    suggestedElevationFt: nil,
                    polls: [poll]
                )
            }
            if let states = dict["states"] as? [[Any]] {
                let epoch = JSONValue.double(dict["time"]) ?? Date().timeIntervalSince1970
                if let poll = parseOpenSkyStates(states, time: Date(timeIntervalSince1970: epoch)) {
                    return ADSRecordingManifest(
                        fileName: fileName,
                        format: "OpenSky snapshot",
                        suggestedAirportICAO: nil,
                        suggestedElevationFt: nil,
                        polls: [poll]
                    )
                }
            }
            if let points = dict["points"] as? [[String: Any]] {
                let airport = JSONValue.string(dict["airport"])
                let elev = JSONValue.double(dict["elevFt"]).map { Int($0.rounded()) }
                let icao = JSONValue.string(dict["icao24"])
                if let polls = pollsFromTrackDumpPoints(points, icao24: icao, elevationFt: elev ?? 0), !polls.isEmpty {
                    return ADSRecordingManifest(
                        fileName: fileName,
                        format: "Track dump JSON (\(polls.count) polls)",
                        suggestedAirportICAO: airport,
                        suggestedElevationFt: elev,
                        polls: polls
                    )
                }
            }
        }
        return nil
    }

    private static func parsePollArray(_ array: [Any]) -> [ADSRecordedPoll]? {
        var polls: [ADSRecordedPoll] = []
        for element in array {
            if let poll = parsePollObject(element) {
                polls.append(poll)
            }
        }
        return polls.isEmpty ? nil : polls
    }

    private static func parsePollObject(_ object: Any) -> ADSRecordedPoll? {
        guard let dict = object as? [String: Any] else { return nil }
        if dict["ac"] != nil || dict["aircraft"] != nil {
            let decoded = ADSBLolDecoder.decodePoll(from: dict)
            return ADSRecordedPoll(time: decoded.time, snapshots: decoded.snapshots)
        }
        if let states = dict["states"] as? [[Any]] {
            let epoch = JSONValue.double(dict["time"]) ?? Date().timeIntervalSince1970
            if let poll = parseOpenSkyStates(states, time: Date(timeIntervalSince1970: epoch)) {
                return poll
            }
        }
        return nil
    }

    private static func parseOpenSkyStates(_ states: [[Any]], time: Date) -> ADSRecordedPoll? {
        let snapshots = states.compactMap { row -> AircraftSnapshot? in
            guard row.count >= 17, let icao24 = JSONValue.string(row[0])?.lowercased() else { return nil }
            let lon = JSONValue.double(row[5])
            let lat = JSONValue.double(row[6])
            guard let lon, let lat else { return nil }
            let lastContact = JSONValue.double(row[4]).map { Date(timeIntervalSince1970: $0) } ?? time
            return AircraftSnapshot(
                icao24: icao24,
                callsign: JSONValue.string(row[1]),
                originCountry: JSONValue.string(row[2]) ?? "",
                coordinate: .init(latitude: lat, longitude: lon),
                baroAltitudeMeters: JSONValue.double(row[7]),
                geoAltitudeMeters: JSONValue.double(row[13]),
                onGround: JSONValue.bool(row[8]) ?? false,
                velocityMPS: JSONValue.double(row[9]),
                trackDeg: JSONValue.double(row[10]),
                verticalRateMPS: JSONValue.double(row[11]),
                squawk: JSONValue.string(row[14]),
                category: AircraftCategory(rawValue: Int(JSONValue.double(row[17])?.rounded() ?? 0)) ?? .unknown,
                timestamp: lastContact,
                registration: nil,
                typeCode: nil
            )
        }
        guard !snapshots.isEmpty else { return nil }
        return ADSRecordedPoll(time: time, snapshots: snapshots)
    }

    private static func tryParseTrackDumpText(_ text: String, fileName: String) -> ADSRecordingManifest? {
        guard let range = text.range(of: "# json") ?? text.range(of: "\n{") else { return nil }
        let jsonPart = String(text[range.lowerBound...])
            .replacingOccurrences(of: "# json", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonPart.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let points = json["points"] as? [[String: Any]] else {
            return nil
        }
        let airport = JSONValue.string(json["airport"])
        let elev = JSONValue.double(json["elevFt"]).map { Int($0.rounded()) }
        let icao = JSONValue.string(json["icao24"])
        guard let polls = pollsFromTrackDumpPoints(points, icao24: icao, elevationFt: elev ?? 0), !polls.isEmpty else {
            return nil
        }
        return ADSRecordingManifest(
            fileName: fileName,
            format: "Track dump export (\(polls.count) polls)",
            suggestedAirportICAO: airport,
            suggestedElevationFt: elev,
            polls: polls
        )
    }

    private static func pollsFromTrackDumpPoints(
        _ points: [[String: Any]],
        icao24: String?,
        elevationFt: Int
    ) -> [ADSRecordedPoll]? {
        struct Row {
            var time: Date
            var point: TrackPoint
        }
        var rows: [Row] = []
        for dict in points {
            guard let timeStr = JSONValue.string(dict["time"]),
                  let lat = JSONValue.double(dict["lat"]),
                  let lon = JSONValue.double(dict["lon"]) else { continue }
            let time = parseDate(timeStr) ?? Date()
            let agl = JSONValue.double(dict["aglFt"])
            let onGround = JSONValue.bool(dict["onGround"]) ?? false
            rows.append(
                Row(
                    time: time,
                    point: TrackPoint(
                        timestamp: time,
                        coordinate: .init(latitude: lat, longitude: lon),
                        altitudeAGLFt: agl,
                        onGround: onGround,
                        groundSpeedKt: JSONValue.double(dict["gsKt"]),
                        trackDeg: JSONValue.double(dict["trackDeg"]),
                        verticalRateFPM: JSONValue.double(dict["vsFpm"])
                    )
                )
            )
        }
        guard !rows.isEmpty else { return nil }

        let hex = icao24?.lowercased() ?? "replay"
        let grouped = Dictionary(grouping: rows) { row in
            row.time.timeIntervalSince1970.rounded()
        }
        let polls = grouped.keys.sorted().compactMap { key -> ADSRecordedPoll? in
            guard let group = grouped[key] else { return nil }
            let time = Date(timeIntervalSince1970: key)
            let snapshots = group.map { row in
                snapshot(from: row.point, icao24: hex, elevationFt: elevationFt)
            }
            return ADSRecordedPoll(time: time, snapshots: snapshots)
        }
        return polls.isEmpty ? nil : sortPolls(polls)
    }

    static func snapshot(from point: TrackPoint, icao24: String, elevationFt: Int) -> AircraftSnapshot {
        let mslFt: Double?
        if point.onGround {
            mslFt = Double(elevationFt)
        } else if let agl = point.altitudeAGLFt {
            mslFt = agl + Double(elevationFt)
        } else {
            mslFt = nil
        }
        return AircraftSnapshot(
            icao24: icao24,
            callsign: nil,
            originCountry: "",
            coordinate: point.coordinate,
            baroAltitudeMeters: mslFt.map { $0 / Geo.feetPerMeter },
            geoAltitudeMeters: mslFt.map { $0 / Geo.feetPerMeter },
            onGround: point.onGround,
            velocityMPS: point.groundSpeedKt.map { $0 / Geo.knotsPerMetersPerSecond },
            trackDeg: point.trackDeg,
            verticalRateMPS: point.verticalRateFPM.map { $0 / (Geo.feetPerMeter * 60) },
            squawk: nil,
            category: .unknown,
            timestamp: point.timestamp,
            registration: nil,
            typeCode: nil
        )
    }

    private static func sortPolls(_ polls: [ADSRecordedPoll]) -> [ADSRecordedPoll] {
        polls.sorted { $0.time < $1.time }
    }

    private static func parseDate(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? isoBasic.date(from: raw)
    }
}
