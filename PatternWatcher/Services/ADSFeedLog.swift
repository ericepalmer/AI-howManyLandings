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

    func matchesAircraftFilter(_ needle: String) -> Bool {
        let q = needle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return icao24.lowercased().contains(q)
            || callsign.lowercased().contains(q)
            || registration.lowercased().contains(q)
    }
}

extension ADSFeedRow: Codable {}

struct ADSFeedPoll: Identifiable, Sendable, Hashable {
    var id: UUID
    var receivedAt: Date
    var sourceName: String
    var airportICAO: String
    var aircraft: [ADSFeedRow]

    func filtered(by aircraftFilter: String) -> ADSFeedPoll {
        var copy = self
        copy.aircraft = aircraft.filter { $0.matchesAircraftFilter(aircraftFilter) }
        return copy
    }
}

extension ADSFeedPoll: Codable {}

/// Bounds in-memory ADS-B history while the feed window is open (~1 hour at a 10 s poll).
enum ADSFeedBuffer {
    static let maxSavedPolls = 360
    static let maxLogLines = 8_000

    struct PollPackage: Sendable {
        var poll: ADSFeedPoll
        var logLines: [String]
    }

    static func makePoll(
        snapshots: [AircraftSnapshot],
        airport: Airport,
        sourceName: String,
        receivedAt: Date
    ) -> PollPackage {
        let rows = snapshots
            .map { ADSFeedRow(snapshot: $0, airport: airport) }
            .sorted { $0.distanceNM < $1.distanceNM }
        let poll = ADSFeedPoll(
            id: UUID(),
            receivedAt: receivedAt,
            sourceName: sourceName,
            airportICAO: airport.icao,
            aircraft: rows
        )
        let stamp = receivedAt.formatted(date: .omitted, time: .standard)
        var logLines: [String] = []
        logLines.append("[\(stamp)] \(sourceName) \(airport.icao)  \(rows.count) aircraft")
        logLines.append(contentsOf: rows.map { "  \($0.logLine)" })
        return PollPackage(poll: poll, logLines: logLines)
    }

    static func trimSavedPolls(_ polls: [ADSFeedPoll]) -> [ADSFeedPoll] {
        guard polls.count > maxSavedPolls else { return polls }
        return Array(polls.suffix(maxSavedPolls))
    }

    static func trimLogLines(_ lines: [String]) -> [String] {
        guard lines.count > maxLogLines else { return lines }
        return Array(lines.suffix(maxLogLines))
    }

    static func appendSavedPolls(_ existing: [ADSFeedPoll], poll: ADSFeedPoll) -> [ADSFeedPoll] {
        trimSavedPolls(existing + [poll])
    }

    static func appendLogLines(_ existing: [String], newLines: [String]) -> [String] {
        guard !newLines.isEmpty else { return existing }
        return trimLogLines(existing + newLines)
    }
}

struct ADSSavedTrackExport: Codable, Sendable {
    var exportedAt: Date
    var airportICAO: String
    var aircraftFilter: String?
    var pollCount: Int
    var polls: [ADSFeedPoll]
    var filteredPolls: [ADSFeedPoll]?
}

enum ADSSavedTrackExporter {
    static func export(
        polls: [ADSFeedPoll],
        aircraftFilter: String
    ) throws -> Data {
        guard let airportICAO = polls.last?.airportICAO ?? polls.first?.airportICAO else {
            throw ADSSavedTrackError.empty
        }
        let trimmedFilter = aircraftFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [ADSFeedPoll]? = trimmedFilter.isEmpty
            ? nil
            : polls
                .map { $0.filtered(by: trimmedFilter) }
                .filter { !$0.aircraft.isEmpty }
        let payload = ADSSavedTrackExport(
            exportedAt: Date(),
            airportICAO: airportICAO,
            aircraftFilter: trimmedFilter.isEmpty ? nil : trimmedFilter,
            pollCount: polls.count,
            polls: polls,
            filteredPolls: filtered
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    static func defaultFileName(airportICAO: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "")
        return "\(airportICAO)_ADS_\(stamp).json"
    }
}

enum ADSSavedTrackError: LocalizedError {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty: return "No ADS-B polls have been saved yet."
        }
    }
}
